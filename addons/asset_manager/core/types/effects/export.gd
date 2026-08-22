@tool
class_name EffectsExportHandler
extends RefCounted
## Exports a .tscn outside res:// plus everything it depends on.
## Used by effects and scenes (scenes/export.gd).
##
## Can't use get_dependencies(), it wants a real res:// path. Packs bake
## res://<PackRoot>/... paths that only resolved on the author's machine, so
## we walk ext_resource tags out of the raw text and resolve them against the
## pack on disk (same resolve_pack_path() the preview uses).
##
## Files mirror their layout in the pack, so two effects from the same pack
## share already-copied textures/meshes. The .tscn the user picked gets
## promoted to the pack folder's root, where they'd actually look for it.
##
## After copy, the baked paths still point at the wrong place, so every
## .tscn/.tres gets rewritten. rename_dependencies() would do this but isn't
## exposed to GDScript (checked core/core_bind.cpp). Binary .material/.mesh
## pass through as opaque bytes, the packs' ones embed no paths of their own
## (verified), nothing to rewrite.

const REFERENCING_EXTENSIONS: PackedStringArray = ["tscn", "tres", "material", "mesh", "res"]
const REWRITABLE_EXTENSIONS: PackedStringArray = ["tscn", "tres"]

static func export_asset(source_path: String, dest_path: String) -> Dictionary:
	var result := AssetExporter.new_result()

	var pack_root := _pack_root_for(source_path, dest_path)
	var pack_dest_root := dest_path.get_base_dir()

	# Source file -> destination file, for every file this effect needs.
	var copy_map: Dictionary = {source_path: dest_path}
	_collect_dependencies(source_path, pack_root, pack_dest_root, copy_map)

	for dep_source: String in copy_map:
		AssetExporter.copy_one_file(dep_source, str(copy_map[dep_source]), result)

	_rewrite_dependencies(copy_map, pack_root, result)
	_repoint_binaries(copy_map, pack_root, result)

	return result

## A copied .material/.mesh still points at the author's machine, the baked
## paths live in compressed bytes. BinaryResource rewrites them in place,
## doing the job rename_dependencies would if it were exposed to GDScript.
static func _repoint_binaries(copy_map: Dictionary, pack_root: String, result: Dictionary) -> void:
	for dep_source: String in copy_map:
		if not BinaryResource.is_binary(dep_source):
			continue

		var referencing_dest := str(copy_map[dep_source])
		var path_map: Dictionary = {}
		for baked_path in _baked_paths_in(dep_source):
			var real_source := TscnSceneLoader.resolve_pack_path(baked_path, dep_source.get_base_dir(), pack_root)
			if real_source.is_empty() or not copy_map.has(real_source):
				continue
			path_map[baked_path] = _resource_path(referencing_dest, str(copy_map[real_source]))

		if path_map.is_empty():
			continue

		var dest := str(copy_map[dep_source])
		if BinaryResource.rewrite(dest, path_map) != OK:
			result["errors"].append("Could not repoint binary resource: " + dest)

## Runs before the copy pass so anything a binary references gets exported
## too. The .tscn walk can't see them, a shader used only by a .material
## would otherwise get left behind silently.
static func _collect_binary_dependencies(file_path: String, pack_root: String, pack_dest_root: String, copy_map: Dictionary) -> void:
	for baked_path in _baked_paths_in(file_path):
		var dep_source := TscnSceneLoader.resolve_pack_path(baked_path, file_path.get_base_dir(), pack_root)
		if dep_source.is_empty() or not FileAccess.file_exists(dep_source):
			push_warning("AssetManager: binary resource wants a file the pack doesn't ship: " + baked_path)
			continue
		if copy_map.has(dep_source):
			continue
		copy_map[dep_source] = _mirrored_dest(dep_source, pack_root, pack_dest_root)
		_collect_dependencies(dep_source, pack_root, pack_dest_root, copy_map)

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

## Walks up from source_path looking for the pack folder name, which is
## already known from dest_path (AssetExporter set it as
## <dest>/<pack folder>/<file>). TscnSceneLoader.find_pack_root() reaches the
## same answer a different way, walking up for the bucket folder's child,
## but we already have the name, no need to re-derive it.
static func _pack_root_for(source_path: String, dest_path: String) -> String:
	var pack_folder := dest_path.get_base_dir().get_file()
	var dir := source_path.get_base_dir()
	while dir != "" and dir != "/":
		if dir.get_file() == pack_folder:
			return dir
		var parent := dir.get_base_dir()
		if parent == dir:
			break
		dir = parent
	return source_path.get_base_dir()

## Depth-first walk of the dependency tree, each resolved file lands in
## copy_map. copy_map is the visited set too, a pack where two scenes share
## a texture (or reference each other) would loop forever without it.
static func _collect_dependencies(file_path: String, pack_root: String, pack_dest_root: String, copy_map: Dictionary) -> void:
	if not _can_contain_references(file_path):
		return

	if BinaryResource.is_binary(file_path):
		_collect_binary_dependencies(file_path, pack_root, pack_dest_root, copy_map)
		return

	for raw_path in _read_ext_resource_paths(file_path):
		var dep_source := TscnSceneLoader.resolve_pack_path(raw_path, file_path.get_base_dir(), pack_root)
		if dep_source.is_empty() or not FileAccess.file_exists(dep_source):
			push_warning("AssetManager: missing dependency, not exported: " + raw_path)
			continue
		if copy_map.has(dep_source):
			continue

		copy_map[dep_source] = _mirrored_dest(dep_source, pack_root, pack_dest_root)
		_collect_dependencies(dep_source, pack_root, pack_dest_root, copy_map)

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
static func _rewrite_dependencies(copy_map: Dictionary, pack_root: String, result: Dictionary) -> void:
	for dep_source: String in copy_map:
		var dest := str(copy_map[dep_source])
		if not REWRITABLE_EXTENSIONS.has(dest.get_extension().to_lower()):
			continue
		if not FileAccess.file_exists(dest):
			continue

		var text := FileAccess.get_file_as_string(dest)
		if text.is_empty():
			continue

		var rewritten := _rewrite_text(text, dep_source, pack_root, copy_map)
		if rewritten == text:
			continue

		var file := FileAccess.open(dest, FileAccess.WRITE)
		if not file:
			result["errors"].append("Could not rewrite paths: " + dest)
			continue
		file.store_string(rewritten)
		file.close()

static func _rewrite_text(text: String, dep_source: String, pack_root: String, copy_map: Dictionary) -> String:
	var base_dir := dep_source.get_base_dir()
	var referencing_dest := str(copy_map[dep_source])

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
		var resolved := TscnSceneLoader.resolve_pack_path(raw_path, base_dir, pack_root)
		if resolved.is_empty() or not copy_map.has(resolved):
			continue

		var new_path := _resource_path(referencing_dest, str(copy_map[resolved]))
		var new_tag := tag.replace('path="' + raw_path + '"', 'path="' + new_path + '"')
		new_tag = _strip_uid_attribute(new_tag)
		out = out.replace(tag, new_tag)

	return out

static func _resource_path(from_file: String, to_file: String) -> String:
	var localized := ProjectSettings.localize_path(to_file)
	if localized.begins_with("res://"):
		return localized

	var from_parts := from_file.get_base_dir().simplify_path().split("/", false)
	var to_parts := to_file.simplify_path().split("/", false)
	while not from_parts.is_empty() and not to_parts.is_empty() and from_parts[0] == to_parts[0]:
		from_parts.remove_at(0)
		to_parts.remove_at(0)
	var relative: Array[String] = []
	for _i in range(from_parts.size()):
		relative.append("..")
	relative.append_array(to_parts)
	return "/".join(relative)

static func _strip_uid_attribute(tag: String) -> String:
	var uid_re := RegEx.new()
	uid_re.compile('\\s*uid="[^"]*"')
	return uid_re.sub(tag, "", true)
