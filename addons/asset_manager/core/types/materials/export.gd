@tool
class_name MaterialsExportHandler
extends RefCounted
## Copies a .tres material plus every texture file it references, so the copy
## isn't broken once it's inside the project. Same "main file + its
## dependencies" shape as ModelsExportHandler's GLTF handling, just reading
## a .tres's ext_resource paths instead of a GLTF's JSON. Reuses
## TresMaterialLoader.parse_texture_paths() (already built for the materials
## preview) rather than re-parsing the .tres format a second way.

## dest_path is the FULL final destination path for source_path itself
## (already computed by export.gd's export_asset(), subfolder and all), not
## a directory to join a filename onto. Texture dependencies are re-derived
## off of dest_path's base dir, same as ModelsExportHandler.
static func export_asset(source_path: String, dest_path: String) -> Dictionary:
	var result := AssetExporter.new_result()

	AssetExporter.copy_one_file(source_path, dest_path, result)

	var texture_paths := TresMaterialLoader.parse_texture_paths(source_path)
	for property_name in texture_paths:
		var tex_source_path: String = texture_paths[property_name]
		var tex_dest_path := _mirror_relative_path(source_path, tex_source_path, dest_path)
		AssetExporter.copy_one_file(tex_source_path, tex_dest_path, result)

	return result

static func _mirror_relative_path(main_source: String, dependency_source: String, main_dest: String) -> String:
	var relative := dependency_source.trim_prefix(main_source.get_base_dir())
	if relative.begins_with("/"):
		relative = relative.substr(1)
	return main_dest.get_base_dir().path_join(relative)
