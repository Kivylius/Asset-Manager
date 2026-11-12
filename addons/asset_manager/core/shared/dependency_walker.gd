@tool
class_name DependencyWalker
extends RefCounted

## Finds every file an asset needs, mirrors them into a destination root, and
## repoints the references afterwards. Works in either direction.

const REFERENCING_EXTENSIONS: PackedStringArray = ["tscn", "tres", "material", "mesh", "res", "gd", "gltf", "fbx"]
const REWRITABLE_EXTENSIONS: PackedStringArray = ["tscn", "tres", "gd"]

## A res:// literal in a script is only followed when it names something we'd
## treat as an asset. A .cfg or .json is as likely to be written at runtime as
## read, and repointing one into the pack would send the user's saved settings
## somewhere they'd never look.
const SCRIPT_PATH_EXTENSIONS: PackedStringArray = [
	"tscn", "tres", "res", "png", "jpg", "jpeg", "webp", "svg", "exr", "hdr",
	"mp3", "ogg", "wav", "ttf", "otf", "gdshader", "glb", "gltf", "obj",
	"material", "mesh", "theme",
]

## A copied .material/.mesh still points at the author's machine, the baked
## paths live in compressed bytes. BinaryResource rewrites them in place,
## doing the job rename_dependencies would if it were exposed to GDScript.
static func repoint_binaries(copy_map: Dictionary, pack_root: String, result: Dictionary, path_map: Dictionary = {}) -> void:
	if path_map.is_empty():
		for dep_source: String in copy_map:
			path_map[dep_source] = ProjectSettings.localize_path(str(copy_map[dep_source]))

	for dep_source: String in copy_map:
		if not BinaryResource.is_binary(dep_source):
			continue

		var baked_map: Dictionary = {}
		for baked_path in _baked_paths_in(dep_source):
			var real_source := PackPaths.resolve_pack_path(baked_path, dep_source.get_base_dir(), pack_root)
			if real_source.is_empty() or not path_map.has(real_source):
				continue
			baked_map[baked_path] = str(path_map[real_source])

		if baked_map.is_empty():
			continue

		var dest := str(copy_map[dep_source])
		if BinaryResource.rewrite(dest, baked_map) != OK:
			result["errors"].append("Could not repoint binary resource: " + dest)

## Runs before the copy pass so anything a binary references gets exported
## too. The .tscn walk can't see them, a shader used only by a .material
## would otherwise get left behind silently.
static func _collect_binary_dependencies(file_path: String, pack_root: String, pack_dest_root: String, copy_map: Dictionary) -> void:
	for baked_path in _baked_paths_in(file_path):
		var dep_source := PackPaths.resolve_pack_path(baked_path, file_path.get_base_dir(), pack_root)
		if dep_source.is_empty() or not FileAccess.file_exists(dep_source):
			push_warning("AssetManager: binary resource wants a file the pack doesn't ship: " + baked_path)
			continue
		if copy_map.has(dep_source):
			continue
		copy_map[dep_source] = _mirrored_dest(dep_source, pack_root, pack_dest_root)
		collect_dependencies(dep_source, pack_root, pack_dest_root, copy_map)

## Paths survive decompression as plain strings, no need to decode the format.
## A resource also stores its own path, but the normal copy already handles
## that, no point remapping it to itself.
static func _baked_paths_in(file_path: String) -> PackedStringArray:
	var paths := PackedStringArray()
	if not BinaryResource.is_binary(file_path):
		return paths

	for found in BinaryResource.referenced_paths(file_path):
		if found.get_file() == file_path.get_file():
			continue
		if not paths.has(found):
			paths.append(found)
	return paths

## The pack is the folder holding everything this asset can reference, so
## baked res://<Root>/... paths resolve against it. dest_path mirrors the
## asset's path below the bucket, so both roots are the same walk: climb the
## source until the parent is the bucket, and drop as many segments from the
## destination.
static func pack_root_for(source_path: String, bucket: String) -> String:
	var dir := source_path.get_base_dir()
	var found := ""
	while dir != "" and dir != "/":
		var parent := dir.get_base_dir()
		if parent.get_file() == bucket:
			found = dir
		if parent == dir:
			break
		dir = parent
	return found if not found.is_empty() else source_path.get_base_dir()

static func pack_dest_root_for(source_path: String, pack_root: String, dest_path: String) -> String:
	var below := source_path.trim_prefix(pack_root).trim_prefix("/")
	var depth := below.split("/").size() - 1

	var dest := dest_path.get_base_dir()
	for i in range(depth):
		dest = dest.get_base_dir()
	return dest

## Depth-first walk of the dependency tree, each resolved file lands in
## copy_map. copy_map is the visited set too, a pack where two scenes share
## a texture (or reference each other) would loop forever without it.
static func collect_dependencies(file_path: String, pack_root: String, pack_dest_root: String, copy_map: Dictionary, class_map: Dictionary = {}) -> void:
	if not _can_contain_references(file_path):
		return

	if BinaryResource.is_binary(file_path):
		_collect_binary_dependencies(file_path, pack_root, pack_dest_root, copy_map)
		return

	if file_path.get_extension().to_lower() == "gd":
		_collect_script_dependencies(file_path, pack_root, pack_dest_root, copy_map, class_map)
		return

	if file_path.get_extension().to_lower() == "gltf":
		_collect_gltf_dependencies(file_path, pack_root, pack_dest_root, copy_map)
		return

	if file_path.get_extension().to_lower() == "fbx":
		_collect_fbx_dependencies(file_path, pack_root, pack_dest_root, copy_map)
		return

	for raw_path in _read_ext_resource_paths(file_path):
		var dep_source := PackPaths.resolve_pack_path(raw_path, file_path.get_base_dir(), pack_root)
		if dep_source.is_empty() or not FileAccess.file_exists(dep_source):
			push_warning("AssetManager: missing dependency, not exported: " + raw_path)
			continue
		if copy_map.has(dep_source):
			continue

		copy_map[dep_source] = _mirrored_dest(dep_source, pack_root, pack_dest_root)
		collect_dependencies(dep_source, pack_root, pack_dest_root, copy_map, class_map)

## A .gltf names its geometry and textures in JSON rather than in ext_resource
## tags, so the model handler's own discovery is used to read them.
static func _collect_gltf_dependencies(file_path: String, pack_root: String, pack_dest_root: String, copy_map: Dictionary) -> void:
	for dep_source in ModelsExportHandler.discover_gltf_dependencies(file_path):
		if not FileAccess.file_exists(dep_source):
			push_warning("AssetManager: missing model dependency, not copied: " + dep_source)
			continue
		if copy_map.has(dep_source):
			continue
		copy_map[dep_source] = _mirrored_dest(dep_source, pack_root, pack_dest_root)

static func _collect_fbx_dependencies(file_path: String, pack_root: String, pack_dest_root: String, copy_map: Dictionary) -> void:
	var fbx_dest := str(copy_map.get(file_path, _mirrored_dest(file_path, pack_root, pack_dest_root)))
	var textures_dir := fbx_dest.get_base_dir().path_join("textures")
	for dep_source in ModelsExportHandler.discover_fbx_dependencies(file_path, pack_root):
		if copy_map.has(dep_source):
			continue
		copy_map[dep_source] = textures_dir.path_join(dep_source.get_file())

## Binary resources can reference other files too, but their paths are in
## compressed bytes, so nothing nested under one is discoverable here. They're
## treated as leaves, _collect_binary_dependencies handles their internals.
static func _read_ext_resource_paths(file_path: String) -> PackedStringArray:
	var paths := PackedStringArray()
	if BinaryResource.is_binary(file_path):
		return paths

	var text := FileAccess.get_file_as_string(file_path)
	if text.is_empty():
		return paths

	var regex := RegEx.new()
	regex.compile('\\[ext_resource[^\\]]*path="([^"]+)"')
	for m in regex.search_all(text):
		paths.append(m.get_string(1))
	return paths

## A script names what it needs three ways, none of them a path Godot would
## report: a class name (resolved through the global registry, which only
## exists inside a project), a res:// literal, or a res:// folder whose files
## are picked at runtime. All three are read out of the source text here.
static func _collect_script_dependencies(file_path: String, pack_root: String, pack_dest_root: String, copy_map: Dictionary, class_map: Dictionary) -> void:
	if class_map.is_empty():
		_build_class_map(pack_root, class_map)

	var text := FileAccess.get_file_as_string(file_path)

	for dep_source in _script_dependencies(text, file_path, pack_root, class_map):
		if copy_map.has(dep_source):
			continue

		copy_map[dep_source] = _mirrored_dest(dep_source, pack_root, pack_dest_root)
		collect_dependencies(dep_source, pack_root, pack_dest_root, copy_map, class_map)

## Resolves all three forms to real files in the pack. A folder literal yields
## everything directly inside it: the filename is built at runtime ("icons/" +
## name + ".svg"), so nothing names those files individually.
static func _script_dependencies(text: String, file_path: String, pack_root: String, class_map: Dictionary) -> PackedStringArray:
	var found := PackedStringArray()
	var base_dir := file_path.get_base_dir()

	for class_ref in _read_script_class_refs(text):
		if class_map.has(class_ref):
			found.append(_nearest_class_file(class_map[class_ref], file_path))

	for raw_path in _read_script_res_paths_in(text):
		var resolved := PackPaths.resolve_pack_path(raw_path, base_dir, pack_root)
		if not resolved.is_empty() and FileAccess.file_exists(resolved):
			found.append(resolved)

	for raw_dir in _read_script_res_dirs_in(text):
		var dir_source := _resolve_pack_dir(raw_dir, pack_root)
		if not dir_source.is_empty():
			found.append_array(_files_directly_under(dir_source))

	var out := PackedStringArray()
	for path in found:
		if path != file_path and not out.has(path):
			out.append(path)
	return out

## Only a literal ending in "/" is treated as a folder: it can't be a file, and
## the trailing slash is what a concatenated path looks like.
static func _read_script_res_dirs_in(text: String) -> PackedStringArray:
	var dirs := PackedStringArray()

	var regex := RegEx.new()
	regex.compile('"(res://[^"]*/)"')
	for m in regex.search_all(text):
		var raw: String = m.get_string(1)
		if not dirs.has(raw):
			dirs.append(raw)
	return dirs

## resolve_pack_path only answers for files, so the same backwards walk is done
## here against directories.
static func _resolve_pack_dir(raw_dir: String, pack_root: String) -> String:
	var stripped := raw_dir.trim_prefix("res://").trim_suffix("/")
	if stripped.is_empty():
		return ""

	var segments := stripped.split("/")
	for cut in range(0, segments.size()):
		var candidate := pack_root.path_join("/".join(segments.slice(cut)))
		if DirAccess.dir_exists_absolute(candidate):
			return candidate
	return ""

static func _files_directly_under(dir_path: String) -> PackedStringArray:
	var paths := PackedStringArray()
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return paths

	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if not dir.current_is_dir() and not entry.ends_with(".import"):
			paths.append(dir_path.path_join(entry))
		entry = dir.get_next()
	dir.list_dir_end()
	return paths

## A class_name is global, so it can be used without extending it and without
## naming a file. Any identifier before a dot is a candidate; the caller keeps
## only those the pack actually declares, which drops Node3D and the like.
static func _read_script_class_refs(text: String) -> PackedStringArray:
	var names := PackedStringArray()

	var extends_re := RegEx.new()
	extends_re.compile('(?m)^\\s*extends\\s+([A-Za-z_]\\w*)\\s*$')
	var found := extends_re.search(text)
	if found:
		names.append(found.get_string(1))

	var used_re := RegEx.new()
	used_re.compile('\\b([A-Za-z_]\\w*)\\s*\\.')
	for m in used_re.search_all(text):
		var used: String = m.get_string(1)
		if not names.has(used):
			names.append(used)
	return names

## Walks the pack once, mapping every class_name declaration to its file. Filled
## in place so one export builds it once and shares it down the recursion.
static func _build_class_map(pack_root: String, class_map: Dictionary) -> void:
	var regex := RegEx.new()
	regex.compile('(?m)^\\s*class_name\\s+([A-Za-z_]\\w*)')

	for path in _script_paths_under(pack_root):
		var found := regex.search(FileAccess.get_file_as_string(path))
		if found == null:
			continue
		var name := found.get_string(1)
		if not class_map.has(name):
			class_map[name] = PackedStringArray()
		class_map[name].append(path)

## Two packs from one vendor share a pack root, so the same class_name can be
## declared in both. The one in the asking script's own folders is the one it
## means, and that is whichever shares the most folders with it.
static func _nearest_class_file(candidates: PackedStringArray, asked_from: String) -> String:
	if candidates.size() == 1:
		return candidates[0]

	var asking := asked_from.get_base_dir().split("/")
	var best := candidates[0]
	var best_shared := -1

	for candidate: String in candidates:
		var parts := candidate.get_base_dir().split("/")
		var shared := 0
		while shared < asking.size() and shared < parts.size() and asking[shared] == parts[shared]:
			shared += 1
		if shared > best_shared:
			best_shared = shared
			best = candidate

	return best

static func _script_paths_under(dir_path: String) -> PackedStringArray:
	var paths := PackedStringArray()
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return paths

	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		var full := dir_path.path_join(entry)
		if dir.current_is_dir():
			paths.append_array(_script_paths_under(full))
		elif entry.get_extension().to_lower() == "gd":
			paths.append(full)
		entry = dir.get_next()
	dir.list_dir_end()
	return paths

static func _can_contain_references(file_path: String) -> bool:
	return REFERENCING_EXTENSIONS.has(file_path.get_extension().to_lower())

## Strips the pack root from the file's path, so shared dependencies from one
## pack always land on the same dest path and dedupe naturally.
static func _mirrored_dest(dep_source: String, pack_root: String, pack_dest_root: String) -> String:
	var relative := dep_source.trim_prefix(pack_root)
	if relative.begins_with("/"):
		relative = relative.substr(1)
	if relative.is_empty():
		relative = dep_source.get_file()
	return pack_dest_root.path_join(relative)

## Rewrites each copied .tscn/.tres so ext_resource paths point at the
## exported files. Also strips the uid= attribute: it's the pack author's,
## refers to nothing in this project, and Godot resolves uid before path,
## leaving it in would re-break a reference we just fixed.
## path_map says what each copied file should now be called from inside the
## other copied files. Export builds it with localize_path, since its
## destination is a project; ingest builds it from the bucket, since
## localize_path leaves a path outside the project alone.
static func rewrite_dependencies(copy_map: Dictionary, pack_root: String, result: Dictionary, path_map: Dictionary = {}) -> void:
	if path_map.is_empty():
		for dep_source: String in copy_map:
			path_map[dep_source] = ProjectSettings.localize_path(str(copy_map[dep_source]))

	for dep_source: String in copy_map:
		var dest := str(copy_map[dep_source])
		if not REWRITABLE_EXTENSIONS.has(dest.get_extension().to_lower()):
			continue
		if not FileAccess.file_exists(dest):
			continue

		var text := FileAccess.get_file_as_string(dest)
		if text.is_empty():
			continue

		var rewritten := _rewrite_text(text, dep_source, pack_root, copy_map, path_map)
		if rewritten == text:
			continue

		var file := FileAccess.open(dest, FileAccess.WRITE)
		if not file:
			result["errors"].append("Could not rewrite paths: " + dest)
			continue
		file.store_string(rewritten)
		file.close()

static func _rewrite_text(text: String, dep_source: String, pack_root: String, copy_map: Dictionary, path_map: Dictionary) -> String:
	var base_dir := dep_source.get_base_dir()

	if dep_source.get_extension().to_lower() == "gd":
		return _rewrite_script_text(text, base_dir, pack_root, copy_map, path_map)

	var regex := RegEx.new()
	regex.compile('\\[ext_resource[^\\]]*\\]')
	var out := text

	for m in regex.search_all(text):
		var tag: String = m.get_string(0)
		var path_match := RegEx.new()
		path_match.compile('path="([^"]+)"')
		var pm := path_match.search(tag)
		if not pm:
			continue

		var raw_path: String = pm.get_string(1)
		var resolved := PackPaths.resolve_pack_path(raw_path, base_dir, pack_root)
		if resolved.is_empty() or not copy_map.has(resolved):
			continue

		var new_tag := tag.replace('path="' + raw_path + '"', 'path="' + str(path_map[resolved]) + '"')
		new_tag = strip_uid_attribute(new_tag)
		out = out.replace(tag, new_tag)

	return out

## Only literals naming a file the export actually copied are repointed, so a
## path built at runtime or one the pack doesn't ship is left as the author
## wrote it.
static func _rewrite_script_text(text: String, base_dir: String, pack_root: String, copy_map: Dictionary, path_map: Dictionary) -> String:
	var out := text
	for raw_path in _read_script_res_paths_in(text):
		var resolved := PackPaths.resolve_pack_path(raw_path, base_dir, pack_root)
		if resolved.is_empty() or not copy_map.has(resolved):
			continue

		out = out.replace('"' + raw_path + '"', '"' + str(path_map[resolved]) + '"')

	for raw_dir in _read_script_res_dirs_in(text):
		var dir_source := _resolve_pack_dir(raw_dir, pack_root)
		if dir_source.is_empty():
			continue

		var copied := ""
		for entry in _files_directly_under(dir_source):
			if path_map.has(entry):
				copied = str(path_map[entry])
				break
		if copied.is_empty():
			continue

		var new_dir := copied.get_base_dir() + "/"
		out = out.replace('"' + raw_dir + '"', '"' + new_dir + '"')
	return out

static func _read_script_res_paths_in(text: String) -> PackedStringArray:
	var paths := PackedStringArray()

	var regex := RegEx.new()
	regex.compile('"(res://[^"]+)"')
	for m in regex.search_all(text):
		var raw: String = m.get_string(1)
		if not SCRIPT_PATH_EXTENSIONS.has(raw.get_extension().to_lower()):
			continue
		if not paths.has(raw):
			paths.append(raw)
	return paths

static func strip_uid_attribute(tag: String) -> String:
	var uid_re := RegEx.new()
	uid_re.compile('\\s*uid="[^"]*"')
	return uid_re.sub(tag, "", true)
