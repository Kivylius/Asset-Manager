@tool
class_name MaterialsImportRunner
extends RefCounted

## Scans the materials/ bucket, one entry per folder. Each folder becomes a
## .tres StandardMaterial3D with its textures auto-wired by classifier output,
## so a downloaded material pack imports as proper Godot resources rather than
## a pile of loose images.

const CHANNEL_TO_PROPERTY: Dictionary = {
	"albedo": "albedo_texture",
	"normal": "normal_texture",
	"roughness": "roughness_texture",
	"metallic": "metallic_texture",
	"ambient_occlusion": "ao_texture",
	"height": "heightmap_texture",
	"emission": "emission_texture",
	"arm_packed": "orm_texture",
	"sss": "subsurf_scatter_texture",
}

const ENABLE_FLAG_FOR_PROPERTY: Dictionary = {
	"normal_texture": "normal_enabled",
	"ao_texture": "ao_enabled",
	"heightmap_texture": "heightmap_enabled",
	"emission_texture": "emission_enabled",
	"subsurf_scatter_texture": "subsurf_scatter_enabled",
}

const TEXTURE_CHANNEL_PROPERTY: Dictionary = {
	"roughness": "roughness_texture_channel",
	"metallic": "metallic_texture_channel",
	"ambient_occlusion": "ao_texture_channel",
}
const TEXTURE_CHANNEL_GRAY: int = 4
const IMAGE_EXTENSIONS: PackedStringArray = MaterialClassifier.IMAGE_EXTENSIONS

static func run(bucket_root_path: String, _type_entry: Dictionary) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var dir := DirAccess.open(bucket_root_path)
	if dir == null:
		push_error("AssetManager: failed to open type folder: ", bucket_root_path)
		return result

	dir.list_dir_begin()
	var folder_name := dir.get_next()
	while folder_name != "":
		if dir.current_is_dir() and folder_name != "." and folder_name != "..":
			var folder_path := bucket_root_path.path_join(folder_name)
			_collect(folder_path, folder_name, result)
		folder_name = dir.get_next()
	dir.list_dir_end()

	return result

static func _collect(folder_path: String, material_name: String, result: Array[Dictionary]) -> void:
	var files := _list_files_flat(folder_path)
	var existing_tres := _find_existing_tres(files)
	if not existing_tres.is_empty():
		result.append(_entry_for_tres(folder_path, existing_tres))
		return

	if _has_usable_images(files):
		result.append_array(_run_one_folder(folder_path, files, material_name))
		return

	for sub in _list_subfolders(folder_path):
		_collect(folder_path.path_join(sub), material_name, result)

static func _has_usable_images(file_names: PackedStringArray) -> bool:
	for f in file_names:
		if not IMAGE_EXTENSIONS.has(f.get_extension().to_lower()):
			continue
		if MaterialClassifier.is_albedo_file(f):
			return true
	return false

static func _list_subfolders(folder_path: String) -> PackedStringArray:
	var names := PackedStringArray()
	var dir := DirAccess.open(folder_path)
	if dir == null:
		return names
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if dir.current_is_dir() and name != "." and name != "..":
			names.append(name)
		name = dir.get_next()
	dir.list_dir_end()
	return names

static func _list_files_flat(folder_path: String) -> PackedStringArray:
	var files := PackedStringArray()
	var dir := DirAccess.open(folder_path)
	if dir == null:
		return files
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if not dir.current_is_dir():
			files.append(name)
		name = dir.get_next()
	dir.list_dir_end()
	return files

static func _run_one_folder(folder_path: String, file_names: PackedStringArray, material_name: String) -> Array[Dictionary]:
	var existing_tres := _find_existing_tres(file_names)
	if not existing_tres.is_empty():
		return [_entry_for_tres(folder_path, existing_tres)]

	var report := MaterialClassifier.classify_folder(file_names)
	if not MaterialClassifier.is_fully_resolved(report):
		return []

	var resolved: Dictionary = {} # channel -> filename
	for f in report["files"]:
		var info: Dictionary = report["files"][f]
		if info["status"] == "OK":
			resolved[info["channel"]] = f

	var albedo_file: String = resolved["albedo"]
	var albedo_rel_path: String = albedo_file
	if resolved.has("opacity"):
		var composited := _composite_opacity(folder_path, albedo_file, resolved["opacity"])
		if not composited.is_empty():
			albedo_rel_path = composited

	var fragment: String = report["files"][albedo_file]["matched_fragment"]
	var derived := "_".join(Array(albedo_file.get_basename().split("_")).filter(
		func(part: String) -> bool: return part.to_lower() != fragment))

	var tres_filename := (derived if not derived.is_empty() else material_name) + ".tres"
	var tres_path := folder_path.path_join(tres_filename)
	_write_tres(tres_path, folder_path, resolved, albedo_rel_path)

	return [_entry_for_tres(folder_path, tres_filename)]

static func _find_existing_tres(file_names: PackedStringArray) -> String:
	for f in file_names:
		if f.get_extension().to_lower() == "tres":
			return f
	return ""

static func _entry_for_tres(folder_path: String, tres_filename: String) -> Dictionary:
	return {
		"path": folder_path.path_join(tres_filename),
		"type": "materials",
		"tags": [],
	}

static func _composite_opacity(folder_path: String, albedo_rel_filename: String, opacity_rel_filename: String) -> String:
	var albedo_img := Image.load_from_file(folder_path.path_join(albedo_rel_filename))
	var opacity_img := Image.load_from_file(folder_path.path_join(opacity_rel_filename))
	if not albedo_img or not opacity_img:
		return ""
	if albedo_img.get_size() != opacity_img.get_size():
		push_error("AssetManager: albedo/opacity size mismatch, skipping composite: ", folder_path)
		return ""

	albedo_img.convert(Image.FORMAT_RGBA8)
	opacity_img.convert(Image.FORMAT_RGBA8)

	var albedo_bytes := albedo_img.get_data()
	var opacity_bytes := opacity_img.get_data()
	var pixel_count := albedo_img.get_width() * albedo_img.get_height()
	for i in range(pixel_count):
		albedo_bytes[i * 4 + 3] = opacity_bytes[i * 4] # opacity's R -> albedo's A

	var composited := Image.create_from_data(albedo_img.get_width(), albedo_img.get_height(), false, Image.FORMAT_RGBA8, albedo_bytes)

	var composited_filename := albedo_rel_filename.get_basename() + "_composited.png"
	var err := composited.save_png(folder_path.path_join(composited_filename))
	if err != OK:
		push_error("AssetManager: failed to save composited albedo (", err, "): ", folder_path)
		return ""

	return composited_filename

static func _write_tres(tres_path: String, folder_path: String, resolved: Dictionary, albedo_rel_path: String) -> void:
	var file := FileAccess.open(tres_path, FileAccess.WRITE)
	if not file:
		push_error("AssetManager: failed to open .tres for writing: ", tres_path)
		return

	var ext_resource_lines: Array[String] = []
	var resource_lines: Array[String] = []
	var id_counter := 0

	for channel in resolved:
		if channel == "opacity":
			continue # merged into albedo above, not its own texture property
		if not CHANNEL_TO_PROPERTY.has(channel):
			continue # reflectivity/id_map no StandardMaterial3D slot exists

		var property_name: String = CHANNEL_TO_PROPERTY[channel]
		var rel_filename: String = albedo_rel_path if channel == "albedo" else resolved[channel]

		id_counter += 1
		var resource_id := "Tex%d" % id_counter
		ext_resource_lines.append('[ext_resource type="Texture2D" id="%s" path="./%s"]' % [resource_id, rel_filename])
		resource_lines.append('%s = ExtResource("%s")' % [property_name, resource_id])

		if ENABLE_FLAG_FOR_PROPERTY.has(property_name):
			resource_lines.append("%s = true" % ENABLE_FLAG_FOR_PROPERTY[property_name])
		if TEXTURE_CHANNEL_PROPERTY.has(channel):
			resource_lines.append("%s = %d" % [TEXTURE_CHANNEL_PROPERTY[channel], TEXTURE_CHANNEL_GRAY])

	if resolved.has("opacity"):
		resource_lines.append("transparency = 1") # Alpha scissor.

	file.store_line('[gd_resource type="StandardMaterial3D" format=3 uid="%s"]' % ResourceUidText.generate())
	file.store_line("")
	for line in ext_resource_lines:
		file.store_line(line)
	file.store_line("[resource]")
	for line in resource_lines:
		file.store_line(line)
