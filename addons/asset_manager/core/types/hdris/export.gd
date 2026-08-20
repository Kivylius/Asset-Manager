@tool
class_name HdrisExportHandler
extends RefCounted

## Copies the panorama into the project and writes a WorldEnvironment beside it,
## so the HDRI drops in as working lighting rather than as an image the user has
## to wire into an Environment by hand. Same companion-scene shape as
## ShadersExportHandler's sky mode.

## Environment ordinals (scene/resources/environment.h): BG_SKY,
## AMBIENT_SOURCE_SKY and REFLECTION_SOURCE_SKY. Written as numbers because
## that is what the .tscn format stores.
const BG_SKY: int = 2
const AMBIENT_SOURCE_SKY: int = 3
const REFLECTION_SOURCE_SKY: int = 2

static func export_asset(source_path: String, dest_path: String) -> Dictionary:
	var result := AssetExporter.new_result()

	AssetExporter.copy_one_file(source_path, dest_path, result)
	if not FileAccess.file_exists(dest_path):
		return result

	_write_environment_tscn(dest_path, result)
	return result

## Tonemapping is left alone: an HDRI's highlights run far above 1.0 and want
## AgX or ACES to hold, but that is a project-wide look the user owns, not
## something an imported asset should decide for them.
static func _write_environment_tscn(dest_path: String, result: Dictionary) -> void:
	var panorama_filename := dest_path.get_file()
	var tscn_path := dest_path.get_basename() + ".tscn"
	if FileAccess.file_exists(tscn_path):
		result["skipped_existing_count"] += 1
		return

	var file := FileAccess.open(tscn_path, FileAccess.WRITE)
	if not file:
		result["errors"].append("Failed to write companion .tscn: " + tscn_path)
		return

	var node_name := dest_path.get_basename().get_file().capitalize().replace(" ", "")

	file.store_line('[gd_scene format=3 uid="%s"]' % ResourceUidText.generate())
	file.store_line("")
	file.store_line('[ext_resource type="Texture2D" path="./%s" id="1_panorama"]' % panorama_filename)
	file.store_line("")
	file.store_line('[sub_resource type="PanoramaSkyMaterial" id="PanoramaSkyMaterial_1"]')
	file.store_line('panorama = ExtResource("1_panorama")')
	file.store_line("")
	file.store_line('[sub_resource type="Sky" id="Sky_1"]')
	file.store_line('sky_material = SubResource("PanoramaSkyMaterial_1")')
	file.store_line("")
	file.store_line('[sub_resource type="Environment" id="Environment_1"]')
	file.store_line("background_mode = %d" % BG_SKY)
	file.store_line('sky = SubResource("Sky_1")')
	file.store_line("ambient_light_source = %d" % AMBIENT_SOURCE_SKY)
	file.store_line("reflected_light_source = %d" % REFLECTION_SOURCE_SKY)
	file.store_line("")
	file.store_line('[node name="%s" type="WorldEnvironment"]' % node_name)
	file.store_line('environment = SubResource("Environment_1")')

	result["copied_count"] += 1
	result["copied_paths"].append(ProjectSettings.localize_path(tscn_path))
