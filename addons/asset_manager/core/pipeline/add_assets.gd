@tool
class_name AssetLibraryAdder
extends RefCounted

signal progress(info: Dictionary)

const IGNORED_FILE_NAMES: PackedStringArray = [".ds_store", "thumbs.db", "desktop.ini"]
const IGNORED_EXTENSIONS: PackedStringArray = ["import", "uid"]
const AMBIGUOUS_TYPE_PRIORITY: PackedStringArray = ["scenes", "sounds"]
const TYPE_NAME_HINTS: Dictionary = {
	"music": ["music", "bgm", "soundtrack", "song", "theme"],
	"effects": ["effect", "effects", "vfx", "particle", "particles"],
}

var _progress_mutex := Mutex.new()
var _processed_count: int = 0
var _current_file: String = ""
var _worker_outcome: Dictionary = {}

## Copies selected files into their matching workspace buckets on a worker
## thread. Type-specific exporters bring dependencies and companion files with
## the selected asset; plain types use the shared single-file copy primitive.
func add_files(source_paths: PackedStringArray, workspace_path: String) -> Dictionary:
	_set_progress(0, "")
	_worker_outcome = {}

	var task_id := WorkerThreadPool.add_task(func() -> void:
		_worker_outcome = _add_files_blocking(source_paths, workspace_path)
	)

	while not WorkerThreadPool.is_task_completed(task_id):
		_emit_progress(source_paths.size())
		await Engine.get_main_loop().process_frame

	WorkerThreadPool.wait_for_task_completion(task_id)
	_emit_progress(source_paths.size())
	return _worker_outcome

## One filter derived from the registry keeps arbitrary files and metadata out
## while automatically following future additions to asset_types.gd.
static func file_dialog_filters() -> PackedStringArray:
	var extensions := _supported_extensions()
	var patterns: Array[String] = []
	for extension in extensions:
		patterns.append("*." + extension)
	return PackedStringArray([", ".join(patterns) + " ; Supported asset files"])

## Resolves duplicate extensions from registry candidates, never from ancestor
## directories. A filename hint can opt into music/effects; otherwise stable
## defaults keep ordinary audio and scenes in sounds/scenes.
static func type_id_for_path(path: String) -> String:
	var extension := path.get_extension().to_lower()
	var candidates := _type_candidates(extension)
	if candidates.is_empty():
		return ""
	if candidates.size() == 1:
		return candidates[0]

	var file_name := path.get_basename().get_file()
	for type_id: String in TYPE_NAME_HINTS:
		if candidates.has(type_id) and _name_has_hint(file_name, TYPE_NAME_HINTS[type_id]):
			return type_id

	for type_id in AMBIGUOUS_TYPE_PRIORITY:
		if candidates.has(type_id):
			return type_id
	return candidates[0]

func _add_files_blocking(source_paths: PackedStringArray, workspace_path: String) -> Dictionary:
	var outcome := {
		"copy": AssetExporter.new_result(),
		"entries": [] as Array[Dictionary],
		"ignored_count": 0,
	}
	var indexed_paths: Dictionary = {}

	for raw_source_path in source_paths:
		var source_path := raw_source_path.simplify_path()
		var copy_result: Dictionary = outcome["copy"]

		if _should_ignore_file(source_path.get_file()):
			outcome["ignored_count"] += 1
			_advance_progress(source_path.get_file())
			continue
		if not _workspace_bucket_for_path(source_path, workspace_path).is_empty():
			copy_result["skipped_existing_count"] += 1
			_advance_progress(source_path.get_file())
			continue

		var type_id := type_id_for_path(source_path)
		if type_id.is_empty():
			outcome["ignored_count"] += 1
			_advance_progress(source_path.get_file())
			continue

		var destination_path := _destination_path(source_path, type_id, workspace_path)
		var file_result := AssetExporter.copy_asset_to_path(source_path, destination_path, type_id)
		_merge_copy_result(copy_result, file_result)

		if FileAccess.file_exists(destination_path) and not indexed_paths.has(destination_path):
			indexed_paths[destination_path] = true
			outcome["entries"].append({
				"path": destination_path,
				"type": type_id,
				"tags": [],
			})
		_advance_progress(source_path.get_file())

	return outcome

static func _supported_extensions() -> PackedStringArray:
	var extensions := PackedStringArray()
	for entry in AssetTypes.ALL:
		if entry["id"] == AssetTypes.FALLBACK_ID:
			continue
		for extension: String in entry["extensions"]:
			var normalized := extension.to_lower()
			if not normalized.is_empty() and not extensions.has(normalized):
				extensions.append(normalized)
	extensions.sort()
	return extensions

static func _type_candidates(extension: String) -> Array[String]:
	var candidates: Array[String] = []
	for entry in AssetTypes.ALL:
		if entry["id"] != AssetTypes.FALLBACK_ID and extension in entry["extensions"]:
			candidates.append(entry["id"])
	return candidates

static func _name_has_hint(file_name: String, hints: Array) -> bool:
	var normalized := file_name.to_lower()
	for separator in ["-", " ", "."]:
		normalized = normalized.replace(separator, "_")
	var tokens := normalized.split("_", false)
	for hint in hints:
		if tokens.has(hint):
			return true
	return false

static func _should_ignore_file(file_name: String) -> bool:
	var lower_name := file_name.to_lower()
	return IGNORED_FILE_NAMES.has(lower_name) \
		or IGNORED_EXTENSIONS.has(lower_name.get_extension())

static func _workspace_bucket_for_path(path: String, workspace_path: String) -> String:
	var normalized_path := path.simplify_path().replace("\\", "/")
	var normalized_workspace := workspace_path.simplify_path().replace("\\", "/").trim_suffix("/")
	var comparison_path := normalized_path.to_lower() if OS.get_name() == "Windows" else normalized_path
	var comparison_workspace := normalized_workspace.to_lower() if OS.get_name() == "Windows" else normalized_workspace
	if not comparison_path.begins_with(comparison_workspace + "/"):
		return ""
	var relative := normalized_path.substr(normalized_workspace.length() + 1)
	var first_segment := relative.get_slice("/", 0)
	return first_segment if AssetTypes.get_folder_names().has(first_segment) else ""

static func _destination_path(source_path: String, type_id: String, workspace_path: String) -> String:
	var bucket_root := workspace_path.path_join(type_id)
	if not AssetExporter.has_handler(type_id):
		return bucket_root.path_join(source_path.get_file()).simplify_path()

	# Handler-backed assets can own dependencies or generated companions. Keep
	# each one in a stable folder; materials also require a child directory to
	# be discoverable by MaterialsImportRunner.
	var asset_folder := source_path.get_basename().get_file()
	if asset_folder.is_empty():
		asset_folder = "asset"
	return bucket_root.path_join(asset_folder).path_join(source_path.get_file()).simplify_path()

static func _merge_copy_result(target: Dictionary, addition: Dictionary) -> void:
	target["copied_count"] += int(addition["copied_count"])
	target["skipped_existing_count"] += int(addition["skipped_existing_count"])
	target["errors"].append_array(addition["errors"])
	target["copied_paths"].append_array(addition["copied_paths"])

func _advance_progress(file_name: String) -> void:
	_progress_mutex.lock()
	_processed_count += 1
	_current_file = file_name
	_progress_mutex.unlock()

func _set_progress(processed: int, file_name: String) -> void:
	_progress_mutex.lock()
	_processed_count = processed
	_current_file = file_name
	_progress_mutex.unlock()

func _emit_progress(total: int) -> void:
	_progress_mutex.lock()
	var processed := _processed_count
	var file_name := _current_file
	_progress_mutex.unlock()
	progress.emit({
		"stage": "scan",
		"stage_label": "Copying files",
		"label": file_name,
		"current": processed,
		"total": total,
	})
