@tool
class_name DefaultImportRunner
extends RefCounted

## Walks the type bucket recursively and returns one entry per file matched
## by extension. Used by any type that doesn't declare its own runner in
## AssetTypes.ALL.

static func run(bucket_root_path: String, type_entry: Dictionary) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var dir := DirAccess.open(bucket_root_path)
	if dir == null:
		push_error("AssetManager: failed to open type folder: ", bucket_root_path)
		return result
	_walk_recursive(dir, bucket_root_path, bucket_root_path, type_entry, result)
	return result

static func _walk_recursive(dir: DirAccess, current_path: String, bucket_root_path: String, type_entry: Dictionary, result: Array[Dictionary]) -> void:
	dir.list_dir_begin()
	var file_name := dir.get_next()

	while file_name != "":
		if dir.current_is_dir():
			if file_name != "." and file_name != "..":
				var next_dir_path := current_path.path_join(file_name)
				var next_dir := DirAccess.open(next_dir_path)
				if next_dir:
					_walk_recursive(next_dir, next_dir_path, bucket_root_path, type_entry, result)
		else:
			if _matches_type(file_name, type_entry):
				var full_path := current_path.path_join(file_name)
				result.append({
					"path": full_path,
					"type": type_entry["id"],
					"tags": _build_auto_tags(current_path, bucket_root_path),
				})

		file_name = dir.get_next()

	dir.list_dir_end()

static func _matches_type(file_name: String, type_entry: Dictionary) -> bool:
	var extensions: Array = type_entry["extensions"]
	if extensions.is_empty():
		return true
	var ext := file_name.get_extension().to_lower()
	return extensions.has(ext)

const TAG_BLOCKLIST: PackedStringArray = [
	"obj", "gltf", "glb", "fbx", "blend", "dae", "usd", "usda", "usdc",
	"usdz", "stl", "ply", "abc", "3ds", "max", "ma", "mb",
	"png", "jpg", "jpeg", "tga", "bmp", "webp", "exr", "hdr", "tiff", "tif",
	"wav", "ogg", "mp3", "flac", "aiff", "ogv", "mp4", "webm",
	"tres", "res", "tscn", "gdshader",
	"glb_format", "gltf_format", "fbx_format", "obj_format", "blend_format",
	"jpg_format", "png_format",
	"texture", "map", "asset", "sound", "audio", "game_kit", "tile",
	"src", "source", "file", "export",
	"exported", "output", "data", "content", "raw", "new", "old", "temp",
	"tmp", "misc", "other", "stuff", "backup", "archive", "archived",
	"final", "wip", "test", "sample", "preview", "thumbnail", "render",
	"extra", "common", "shared", "lib", "library", "pack", "bundle",
	"collection", "download", "unzipped", "converted", "shader_cache",
	"1k", "2k", "4k", "8k", "16k", "sd", "hd", "uhd",
	"lq", "mq", "hq", "low", "mid", "high", "lod",
	"red", "green", "blue", "yellow", "orange", "purple", "pink",
	"brown", "black", "white", "grey", "gray", "cyan", "magenta",
	"gold", "silver", "bronze", "beige", "tan", "teal", "violet",
	"maroon", "navy", "olive", "lime", "indigo", "turquoise",
	"colour", "color", "colours", "colors", "colored", "coloured",
]

static func _build_auto_tags(current_path: String, bucket_root_path: String) -> Array[String]:
	var relative_dir := current_path.trim_prefix(bucket_root_path).trim_prefix("/")
	if relative_dir.is_empty():
		return []

	var tags: Array[String] = []
	for segment in relative_dir.split("/"):
		var tag := segment.strip_edges().to_lower().replace(" ", "_")
		if not tag.is_empty() and not _is_noise(tag) and not tags.has(tag):
			tags.append(tag)
	return tags

static func _is_noise(tag: String) -> bool:
	return tag.begins_with(".") \
		or tag.is_valid_int() \
		or TAG_BLOCKLIST.has(tag) \
		or TAG_BLOCKLIST.has(tag.trim_suffix("s")) \
		or AssetTypes.ALL.any(func(e: Dictionary) -> bool: return e["id"] == tag)
