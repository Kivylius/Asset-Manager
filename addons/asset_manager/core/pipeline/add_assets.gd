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

## Recursively adds every asset in a folder. The selected folder's structure is
## retained below each type bucket, so same-named files in separate subfolders
## stay separate. Existing files are never overwritten on a repeat import.
static func add_folder(source_folder: String, workspace_path: String) -> Dictionary:
	var result := _new_result()
	var source_root := source_folder.simplify_path()
	var workspace_root := workspace_path.simplify_path()
	if not DirAccess.dir_exists_absolute(source_root):
		result["errors"].append("Folder does not exist: " + source_root)
		return result

	var source_files: Array[String] = []
	_collect_files(source_root, source_files, result["ignored_paths"], result["errors"])
	var folder_prefix := _folder_prefix(source_root, workspace_root)

	for source_path in source_files:
		var existing_bucket := _workspace_bucket_for_path(source_path, workspace_root)
		if not existing_bucket.is_empty():
			result["already_present_paths"].append(source_path)
			continue

		var type_id := type_id_for_path(source_path)
		var relative_path := _relative_path(source_path, source_root)
		var destination_relative := relative_path if folder_prefix.is_empty() else folder_prefix.path_join(relative_path)
		var destination_path := workspace_root.path_join(type_id).path_join(destination_relative).simplify_path()
		if FileAccess.file_exists(destination_path) or DirAccess.dir_exists_absolute(destination_path):
			result["skipped_existing_paths"].append(destination_path)
			continue
		if not _ensure_directory(destination_path.get_base_dir(), result["errors"]):
			continue
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

static func _collect_files(folder: String, files: Array[String], ignored_paths: Array[String], errors: Array[String]) -> void:
	var dir := DirAccess.open(folder)
	if dir == null:
		errors.append("Could not read folder: " + folder)
		return

	dir.list_dir_begin()
	var entry_name := dir.get_next()
	while not entry_name.is_empty():
		var entry_path := folder.path_join(entry_name)
		var is_directory := dir.current_is_dir()
		if entry_name.begins_with("."):
			if not is_directory:
				ignored_paths.append(entry_path)
		elif is_directory:
			if not dir.is_link(entry_name):
				_collect_files(entry_path, files, ignored_paths, errors)
		elif _should_ignore_file(entry_name):
			ignored_paths.append(entry_path)
		else:
			files.append(entry_path.simplify_path())
		entry_name = dir.get_next()
	dir.list_dir_end()

static func _should_ignore_file(file_name: String) -> bool:
	return IGNORED_FILE_NAMES.has(file_name) or IGNORED_EXTENSIONS.has(file_name.get_extension().to_lower())

static func _path_has_hint(path: String, hints: PackedStringArray) -> bool:
	var padded_path := "/" + path.trim_prefix("/").trim_suffix("/") + "/"
	for hint in hints:
		if padded_path.contains("/" + hint + "/"):
			return true
	return false

static func _folder_prefix(source_root: String, workspace_root: String) -> String:
	if source_root == workspace_root:
		return ""
	if _is_within(source_root, workspace_root):
		return _relative_path(source_root, workspace_root)
	return source_root.get_file()

static func _workspace_bucket_for_path(path: String, workspace_root: String) -> String:
	if not _is_within(path, workspace_root):
		return ""
	var relative := _relative_path(path, workspace_root)
	var first_segment := relative.get_slice("/", 0)
	return first_segment if AssetTypesRegistry.get_folder_names().has(first_segment) else ""

static func _is_within(path: String, root: String) -> bool:
	return path == root or path.begins_with(root.trim_suffix("/") + "/")

static func _relative_path(path: String, root: String) -> String:
	if path == root:
		return ""
	return path.trim_prefix(root.trim_suffix("/") + "/")

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
