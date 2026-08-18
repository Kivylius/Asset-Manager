@tool
class_name TresMaterialLoader
extends RefCounted

const KNOWN_TEXTURE_PROPERTIES: PackedStringArray = [
	"albedo_texture",
	"normal_texture",
	"roughness_texture",
	"metallic_texture",
	"ao_texture",
	"heightmap_texture",
	"emission_texture",
]

static func parse_transparency(tres_path: String) -> int:
	var file := FileAccess.open(tres_path, FileAccess.READ)
	if not file:
		return 0

	while not file.eof_reached():
		var line := file.get_line()
		if line.begins_with("transparency = "):
			return line.trim_prefix("transparency = ").to_int()

	return 0

static func parse_texture_paths(tres_path: String) -> Dictionary:
	var file := FileAccess.open(tres_path, FileAccess.READ)
	if not file:
		return {}

	var base_dir := tres_path.get_base_dir()
	var id_to_path: Dictionary = {}
	var property_to_id: Dictionary = {}

	while not file.eof_reached():
		var line := file.get_line()

		if line.begins_with("[ext_resource"):
			# " id=" (leading space) required
			var id := _extract_quoted(line, " id=")
			var rel_path := _extract_quoted(line, "path=")
			if not id.is_empty() and not rel_path.is_empty():
				id_to_path[id] = base_dir.path_join(rel_path.trim_prefix("./"))
			continue

		if line.begins_with("["):
			continue

		for property_name in KNOWN_TEXTURE_PROPERTIES:
			if line.begins_with(property_name + " = ExtResource("):
				var id := _extract_quoted(line, "ExtResource(")
				if not id.is_empty():
					property_to_id[property_name] = id

	var property_to_path: Dictionary = {}
	for property_name in KNOWN_TEXTURE_PROPERTIES:
		if property_to_id.has(property_name) and id_to_path.has(property_to_id[property_name]):
			property_to_path[property_name] = id_to_path[property_to_id[property_name]]
	return property_to_path


static func load_image_blocking(path: String) -> Image:
	return Image.load_from_file(path)

static func _extract_quoted(line: String, marker: String) -> String:
	var marker_pos := line.find(marker)
	if marker_pos == -1:
		return ""
	var quote_start := line.find("\"", marker_pos)
	if quote_start == -1:
		return ""
	var quote_end := line.find("\"", quote_start + 1)
	if quote_end == -1:
		return ""
	return line.substr(quote_start + 1, quote_end - quote_start - 1)
