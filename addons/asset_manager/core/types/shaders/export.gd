@tool
class_name ShadersExportHandler
extends RefCounted

## Copies a .gdshader into the project and writes a small wrapper beside it
## (a .tres ShaderMaterial for spatial/canvas_item, a .tscn with the right
## subject node for particles/fog/sky) so the shader drops in ready to use
## rather than as raw code the user has to wire up.

static func export_asset(source_path: String, dest_path: String) -> Dictionary:
	var result := AssetExporter.new_result()

	AssetExporter.copy_one_file(source_path, dest_path, result)
	if not FileAccess.file_exists(dest_path):
		return result

	var shader := Shader.new()
	shader.code = FileAccess.get_file_as_string(source_path)
	var mode := shader.get_mode()

	match mode:
		Shader.MODE_SPATIAL, Shader.MODE_CANVAS_ITEM:
			_write_material_tres(dest_path, result)
		Shader.MODE_PARTICLES:
			_write_particles_tscn(dest_path, result)
		Shader.MODE_FOG:
			_write_fog_tscn(dest_path, result)
		Shader.MODE_SKY:
			_write_sky_tscn(dest_path, result)
		_:
			pass

	return result

static func _companion_path(dest_path: String, new_extension: String) -> String:
	return dest_path.get_basename() + "." + new_extension

static func _write_material_tres(dest_path: String, result: Dictionary) -> void:
	var shader_filename := dest_path.get_file()
	var tres_path := _companion_path(dest_path, "tres")
	if FileAccess.file_exists(tres_path):
		result["skipped_existing_count"] += 1
		return

	var file := FileAccess.open(tres_path, FileAccess.WRITE)
	if not file:
		result["errors"].append("Failed to write companion .tres: " + tres_path)
		return

	file.store_line('[gd_resource type="ShaderMaterial" load_steps=2 format=3 uid="%s"]' % ResourceUidText.generate())
	file.store_line("")
	file.store_line('[ext_resource type="Shader" uid="%s" path="./%s" id="1_shader"]' % [ResourceUidText.generate(), shader_filename])
	file.store_line("")
	file.store_line("[resource]")
	file.store_line('shader = ExtResource("1_shader")')

	result["copied_count"] += 1
	result["copied_paths"].append(ProjectSettings.localize_path(tres_path))

static func _write_particles_tscn(dest_path: String, result: Dictionary) -> void:
	var shader_filename := dest_path.get_file()
	var tscn_path := _companion_path(dest_path, "tscn")
	if FileAccess.file_exists(tscn_path):
		result["skipped_existing_count"] += 1
		return

	var file := FileAccess.open(tscn_path, FileAccess.WRITE)
	if not file:
		result["errors"].append("Failed to write companion .tscn: " + tscn_path)
		return

	file.store_line('[gd_scene load_steps=4 format=3 uid="%s"]' % ResourceUidText.generate())
	file.store_line("")
	file.store_line('[ext_resource type="Shader" uid="%s" path="./%s" id="1_shader"]' % [ResourceUidText.generate(), shader_filename])
	file.store_line("")
	file.store_line('[sub_resource type="ShaderMaterial" id="ShaderMaterial_1"]')
	file.store_line('shader = ExtResource("1_shader")')
	file.store_line("")
	file.store_line('[sub_resource type="SphereMesh" id="SphereMesh_1"]')
	file.store_line("radius = 0.1")
	file.store_line("height = 0.2")
	file.store_line("")
	file.store_line('[node name="%s" type="GPUParticles3D"]' % dest_path.get_basename().get_file().capitalize().replace(" ", ""))
	file.store_line("emitting = true")
	file.store_line("amount = 16")
	file.store_line('process_material = SubResource("ShaderMaterial_1")')
	file.store_line('draw_pass_1 = SubResource("SphereMesh_1")')

	result["copied_count"] += 1
	result["copied_paths"].append(ProjectSettings.localize_path(tscn_path))

static func _write_fog_tscn(dest_path: String, result: Dictionary) -> void:
	var shader_filename := dest_path.get_file()
	var tscn_path := _companion_path(dest_path, "tscn")
	if FileAccess.file_exists(tscn_path):
		result["skipped_existing_count"] += 1
		return

	var file := FileAccess.open(tscn_path, FileAccess.WRITE)
	if not file:
		result["errors"].append("Failed to write companion .tscn: " + tscn_path)
		return

	file.store_line('[gd_scene load_steps=3 format=3 uid="%s"]' % ResourceUidText.generate())
	file.store_line("")
	file.store_line('[ext_resource type="Shader" uid="%s" path="./%s" id="1_shader"]' % [ResourceUidText.generate(), shader_filename])
	file.store_line("")
	file.store_line('[sub_resource type="FogMaterial" id="FogMaterial_1"]')
	file.store_line('shader = ExtResource("1_shader")')
	file.store_line("")
	file.store_line('[node name="%s" type="FogVolume"]' % dest_path.get_basename().get_file().capitalize().replace(" ", ""))
	file.store_line("size = Vector3(2, 2, 2)")
	file.store_line('material = SubResource("FogMaterial_1")')

	result["copied_count"] += 1
	result["copied_paths"].append(ProjectSettings.localize_path(tscn_path))

static func _write_sky_tscn(dest_path: String, result: Dictionary) -> void:
	var shader_filename := dest_path.get_file()
	var tscn_path := _companion_path(dest_path, "tscn")
	if FileAccess.file_exists(tscn_path):
		result["skipped_existing_count"] += 1
		return

	var file := FileAccess.open(tscn_path, FileAccess.WRITE)
	if not file:
		result["errors"].append("Failed to write companion .tscn: " + tscn_path)
		return

	file.store_line('[gd_scene load_steps=5 format=3 uid="%s"]' % ResourceUidText.generate())
	file.store_line("")
	file.store_line('[ext_resource type="Shader" uid="%s" path="./%s" id="1_shader"]' % [ResourceUidText.generate(), shader_filename])
	file.store_line("")
	file.store_line('[sub_resource type="ShaderMaterial" id="ShaderMaterial_1"]')
	file.store_line('shader = ExtResource("1_shader")')
	file.store_line("")
	file.store_line('[sub_resource type="Sky" id="Sky_1"]')
	file.store_line('sky_material = SubResource("ShaderMaterial_1")')
	file.store_line("")
	file.store_line('[sub_resource type="Environment" id="Environment_1"]')
	file.store_line("background_mode = 2")
	file.store_line('sky = SubResource("Sky_1")')
	file.store_line("")
	file.store_line('[node name="%s" type="WorldEnvironment"]' % dest_path.get_basename().get_file().capitalize().replace(" ", ""))
	file.store_line('environment = SubResource("Environment_1")')

	result["copied_count"] += 1
	result["copied_paths"].append(ProjectSettings.localize_path(tscn_path))
