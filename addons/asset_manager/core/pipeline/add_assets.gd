@tool
class_name AssetLibraryAdder
extends RefCounted

const AssetTypesRegistry = preload("res://addons/asset_manager/core/asset_types.gd")
const IGNORED_FILE_NAMES: PackedStringArray = [".DS_Store", "Thumbs.db", "desktop.ini"]
const IGNORED_EXTENSIONS: PackedStringArray = ["import", "uid"]
const MUSIC_PATH_HINTS: PackedStringArray = ["music", "bgm", "soundtrack", "songs"]
const EFFECT_PATH_HINTS: PackedStringArray = ["effect", "effects", "vfx", "particle", "particles"]

## Adds individually selected files to their matching workspace buckets. A
## duplicate filename is numbered instead of overwriting the existing asset.
static func add_files(source_paths: PackedStringArray, workspace_path: String) -> Dictionary:
	var result := _new_result()
	for raw_source_path in source_paths:
		var source_path := raw_source_path.simplify_path()
		if not FileAccess.file_exists(source_path):
			result["errors"].append("File does not exist: " + source_path)
			continue
		if _should_ignore_file(source_path.get_file()):
			result["ignored_paths"].append(source_path)
			continue

		var type_id := type_id_for_path(source_path)
		var destination_root := workspace_path.path_join(type_id).simplify_path()
		if not _ensure_directory(destination_root, result["errors"]):
			continue

		var destination_path := destination_root.path_join(source_path.get_file()).simplify_path()
		if source_path == destination_path:
			result["already_present_paths"].append(destination_path)
			continue

		destination_path = _available_destination(destination_path)
		_copy(source_path, destination_path, result)
	return result

## Ambiguous audio and scene extensions use folder names as a hint. Everything
## unknown belongs to Other, whose scanner intentionally accepts the remainder.
static func type_id_for_path(path: String) -> String:
	var extension := path.get_extension().to_lower()
	var lower_path := path.to_lower().replace("\\", "/")
	if extension in ["ogg", "mp3", "wav"]:
		return "music" if _path_has_hint(lower_path, MUSIC_PATH_HINTS) else "sounds"
	if extension == "tscn":
		return "effects" if _path_has_hint(lower_path, EFFECT_PATH_HINTS) else "scenes"

	for entry in AssetTypesRegistry.ALL:
		if entry["id"] == AssetTypesRegistry.FALLBACK_ID:
			continue
		if extension in entry["extensions"]:
			return entry["id"]
	return AssetTypesRegistry.FALLBACK_ID

static func _should_ignore_file(file_name: String) -> bool:
	return IGNORED_FILE_NAMES.has(file_name) or IGNORED_EXTENSIONS.has(file_name.get_extension().to_lower())

static func _path_has_hint(path: String, hints: PackedStringArray) -> bool:
	var padded_path := "/" + path.trim_prefix("/").trim_suffix("/") + "/"
	for hint in hints:
		if padded_path.contains("/" + hint + "/"):
			return true
	return false

static func _ensure_directory(path: String, errors: Array[String]) -> bool:
	var mkdir_error := DirAccess.make_dir_recursive_absolute(path)
	if mkdir_error == OK or DirAccess.dir_exists_absolute(path):
		return true
	errors.append("Could not create library folder: " + path)
	return false

static func _copy(source_path: String, destination_path: String, result: Dictionary) -> void:
	var copy_error := DirAccess.copy_absolute(source_path, destination_path)
	if copy_error == OK:
		result["added_paths"].append(destination_path)
	else:
		result["errors"].append("Could not copy %s (error %d)" % [source_path.get_file(), copy_error])

static func _available_destination(candidate: String) -> String:
	if not FileAccess.file_exists(candidate) and not DirAccess.dir_exists_absolute(candidate):
		return candidate

	var directory := candidate.get_base_dir()
	var file_name := candidate.get_file()
	var stem := file_name.get_basename()
	var extension := file_name.get_extension()
	var suffix := 2
	while true:
		var numbered_name := "%s_%d" % [stem, suffix]
		if not extension.is_empty():
			numbered_name += "." + extension
		var numbered_path := directory.path_join(numbered_name)
		if not FileAccess.file_exists(numbered_path) and not DirAccess.dir_exists_absolute(numbered_path):
			return numbered_path
		suffix += 1
	return candidate

static func _new_result() -> Dictionary:
	return {
		"added_paths": Array([], TYPE_STRING, "", null),
		"already_present_paths": Array([], TYPE_STRING, "", null),
		"skipped_existing_paths": Array([], TYPE_STRING, "", null),
		"ignored_paths": Array([], TYPE_STRING, "", null),
		"errors": Array([], TYPE_STRING, "", null),
	}
