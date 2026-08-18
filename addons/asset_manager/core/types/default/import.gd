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

static func _build_auto_tags(current_path: String, bucket_root_path: String) -> Array[String]:
	var tags: Array[String] = []

	var relative_dir := current_path.trim_prefix(bucket_root_path)
	if relative_dir.begins_with("/"):
		relative_dir = relative_dir.substr(1)

	if relative_dir.is_empty():
		return tags

	var first_segment := relative_dir.split("/")[0]
	var clean_part := first_segment.strip_edges().to_lower().replace(" ", "_")
	if not clean_part.is_empty():
		tags.append(clean_part)

	return tags
