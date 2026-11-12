@tool
class_name ModelsExportHandler
extends RefCounted
## Copies a model file plus any external file it depends on (e.g. a .glb's
## external texture), so the copy isn't broken once it's inside the project.
## Dependency discovery reads GLTFState.json rather than hand-parsing
## GLB/GLTF, Godot's own parser already exposes the original URIs there
## untouched.

const DEPENDENCY_URI_KEYS: PackedStringArray = ["images", "buffers"]

## "tiff" before "tif" so the longer one wins.
const FBX_TEXTURE_EXTENSIONS: PackedStringArray = ["png", "jpeg", "jpg", "tga", "bmp", "webp", "tiff", "tif", "dds", "exr", "hdr", "psd"]
const FBX_EXTENSION_FIRST_LETTERS: String = "pjtbwdeh"
const FBX_GODOT_SUBDIRS: PackedStringArray = ["", "textures/", "Textures/", "images/", "Images/", "materials/", "Materials/", "maps/", "Maps/", "tex/", "Tex/"]
const FBX_MAX_PATH_BYTES: int = 1024

## dest_path is the FULL final destination path for source_path itself
## (already computed by export.gd's export_asset(), subfolder and all),
## not a directory to join a filename onto. Handlers only re-derive a path
## for their own DEPENDENCIES, off of dest_path's base dir.
static func export_asset(source_path: String, dest_path: String, bucket: String = "") -> Dictionary:
	var result := AssetExporter.new_result()

	AssetExporter.copy_one_file(source_path, dest_path, result)

	var ext := source_path.get_extension().to_lower()
	if ext == "glb" or ext == "gltf":
		var dependencies := discover_gltf_dependencies(source_path)
		for dep_source_path in dependencies:
			var dep_dest_path := _mirror_relative_path(source_path, dep_source_path, dest_path)
			AssetExporter.copy_one_file(dep_source_path, dep_dest_path, result)
	elif ext == "fbx":
		var pack_root := PackPaths.find_pack_root(source_path.get_base_dir(), bucket)
		var textures_dir := dest_path.get_base_dir().path_join("textures")
		for dep_source_path in discover_fbx_dependencies(source_path, pack_root):
			AssetExporter.copy_one_file(dep_source_path, textures_dir.path_join(dep_source_path.get_file()), result)

	return result

## Reads GLTFState.json (populated by GLTFDocument.append_from_file, same call
## the preview uses) and returns absolute paths to every external
## images[]/buffers[] dependency. Skips data: URIs (embedded, nothing to copy)
## and entries with no "uri" key (embedded via bufferView, or the .glb's own
## binary chunk).
static func discover_gltf_dependencies(source_path: String) -> Array[String]:
	var deps: Array[String] = []

	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	state.handle_binary_image_mode = GLTFState.HANDLE_BINARY_IMAGE_MODE_EMBED_AS_UNCOMPRESSED

	var err := doc.append_from_file(source_path, state)
	if err != OK:
		push_error("AssetManager: failed to parse for dependency discovery: ", source_path)
		return deps

	var json: Dictionary = state.json
	var base_dir := source_path.get_base_dir()

	for key in DEPENDENCY_URI_KEYS:
		if not json.has(key):
			continue
		var entries: Array = json[key]
		for entry in entries:
			if not (entry is Dictionary) or not entry.has("uri"):
				continue
			var uri: String = entry["uri"]
			if uri.begins_with("data:"):
				continue

			var decoded := uri.uri_file_decode().replace("\\", "/")
			var abs_path := base_dir.path_join(decoded).simplify_path()

			if not deps.has(abs_path):
				deps.append(abs_path)

	return deps

static func discover_fbx_dependencies(source_path: String, pack_root: String) -> Array[String]:
	var deps: Array[String] = []
	var base_dir := source_path.get_base_dir()
	for raw_path in _fbx_texture_paths(source_path):
		var found := _find_like_godot(raw_path, base_dir)
		if found.is_empty():
			found = PackPaths.resolve_pack_path(raw_path, base_dir, pack_root, true)
		if not found.is_empty() and FileAccess.file_exists(found) and not deps.has(found):
			deps.append(found)
	return deps

static func fbx_texture_dir(source_path: String, pack_root: String) -> String:
	var raw_paths := _fbx_texture_paths(source_path)
	var base_dir := source_path.get_base_dir()
	for raw_path in raw_paths:
		if not _find_like_godot(raw_path, base_dir).is_empty():
			return ""
	for raw_path in raw_paths:
		var found := PackPaths.resolve_pack_path(raw_path, base_dir, pack_root, true)
		if not found.is_empty():
			return found.get_base_dir()
	return ""

static func _find_like_godot(raw_path: String, base_dir: String) -> String:
	if raw_path.is_relative_path():
		var direct := base_dir.path_join(raw_path).simplify_path()
		if FileAccess.file_exists(direct):
			return direct

	var file_name := raw_path.get_file()
	var dir := base_dir
	while not dir.is_empty():
		for subdir in FBX_GODOT_SUBDIRS:
			var candidate := dir.path_join(subdir + file_name)
			if FileAccess.file_exists(candidate):
				return candidate
		var parent := dir.get_base_dir()
		if parent == dir:
			break
		dir = parent
	return ""

static func _fbx_texture_paths(source_path: String) -> PackedStringArray:
	var paths := PackedStringArray()
	var bytes := FileAccess.get_file_as_bytes(source_path)

	var dot := bytes.find(0x2E)
	while dot != -1:
		var ext := _image_extension_at(bytes, dot + 1)
		if not ext.is_empty():
			var start := dot
			while start > 0 and dot - start < FBX_MAX_PATH_BYTES and _is_path_byte(bytes[start - 1]):
				start -= 1
			var path := bytes.slice(start, dot + 1 + ext.length()).get_string_from_ascii().replace("\\", "/")
			if path.get_file().length() > ext.length() + 1 and not paths.has(path):
				paths.append(path)
		dot = bytes.find(0x2E, dot + 1)

	return paths

static func _image_extension_at(bytes: PackedByteArray, at: int) -> String:
	if at >= bytes.size() or not FBX_EXTENSION_FIRST_LETTERS.contains(char(bytes[at] | 0x20)):
		return ""
	for ext in FBX_TEXTURE_EXTENSIONS:
		if at + ext.length() > bytes.size():
			continue
		if bytes.slice(at, at + ext.length()).get_string_from_ascii().to_lower() == ext:
			return ext
	return ""

static func _is_path_byte(byte: int) -> bool:
	return byte >= 0x20 and byte < 0x7F and byte != 0x22

## Given the main file's source->dest paths, computes where a dependency
## should land so its path relative to the main file is preserved
## (e.g. main at .../pot.glb -> dest/pot.glb, dependency at
## .../Textures/colormap.png -> dest_dir/Textures/colormap.png).
static func _mirror_relative_path(main_source: String, dep_source: String, main_dest: String) -> String:
	var main_source_dir := main_source.get_base_dir()
	var relative := dep_source.trim_prefix(main_source_dir)
	if relative.begins_with("/"):
		relative = relative.substr(1)
	return main_dest.get_base_dir().path_join(relative)
