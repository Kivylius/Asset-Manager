@tool
class_name ModelsExportHandler
extends RefCounted
## Copies a model file plus any external file it depends on (e.g. a .glb's
## external texture), so the copy isn't broken once it's inside the project.
## Dependency discovery reads GLTFState.json rather than hand-parsing
## GLB/GLTF, Godot's own parser already exposes the original URIs there
## untouched.

const DEPENDENCY_URI_KEYS: PackedStringArray = ["images", "buffers"]

## dest_path is the FULL final destination path for source_path itself
## (already computed by export.gd's export_asset(), subfolder and all),
## not a directory to join a filename onto. Handlers only re-derive a path
## for their own DEPENDENCIES, off of dest_path's base dir.
static func export_asset(source_path: String, dest_path: String) -> Dictionary:
	var result := AssetExporter.new_result()

	AssetExporter.copy_one_file(source_path, dest_path, result)

	var ext := source_path.get_extension().to_lower()
	if ext == "glb" or ext == "gltf":
		var dependencies := _discover_gltf_dependencies(source_path)
		for dep_source_path in dependencies:
			var dep_dest_path := _mirror_relative_path(source_path, dep_source_path, dest_path)
			AssetExporter.copy_one_file(dep_source_path, dep_dest_path, result)

	return result

## Reads GLTFState.json (populated by GLTFDocument.append_from_file, same call
## the preview uses) and returns absolute paths to every external
## images[]/buffers[] dependency. Skips data: URIs (embedded, nothing to copy)
## and entries with no "uri" key (embedded via bufferView, or the .glb's own
## binary chunk).
static func _discover_gltf_dependencies(source_path: String) -> Array[String]:
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
