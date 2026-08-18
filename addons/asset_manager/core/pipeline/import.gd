@tool
class_name AssetImporter
extends RefCounted

var _runner_registry: Dictionary = {}
const DEFAULT_CHAIN: Array[String] = ["default"]

var _pending_count: int = 0
var _total_types: int = 0
var _completed_types: int = 0
var _scanned: Array[Dictionary] = []
signal _type_done(entries: Array)

var per_type_counts: Dictionary = {}

## Re-emitted from the thumbnail stage so callers have one place to listen
signal progress(info: Dictionary)

func _init() -> void:
	_type_done.connect(_on_type_done)
	_runner_registry = {
		"default": DefaultImportRunner,
		"materials": MaterialsImportRunner,
	}

## Viewport_host is any node in the tree, 3D thumbnails parent an offscreen
## viewport to it, since a viewport outside the tree never renders
func run_import(workspace_path: String, database: AssetDatabase, viewport_host: Node = null) -> bool:
	var dispatched: int = 0
	for type_entry in AssetTypes.ALL:
		var type_id: String = type_entry["id"]
		var bucket_root_path := workspace_path.path_join(type_id)

		if not DirAccess.dir_exists_absolute(bucket_root_path):
			continue

		var chain: Array = type_entry.get("runners", DEFAULT_CHAIN)
		_dispatch_type(bucket_root_path, type_entry, chain)
		dispatched += 1

	_total_types = dispatched
	_completed_types = 0
	_report_scan_progress("")

	while _pending_count > 0:
		await _type_done

	progress.emit({"stage": "database", "label": "index.db", "current": 0, "total": 1})
	if not database.rebuild(_scanned):
		return false
	progress.emit({"stage": "database", "label": "index.db", "current": 1, "total": 1})

	# Stage 3: thumbnails. Runs after the index exists, isn't part of the
	# runner chain above because viewport capture is main-thread only.
	var cache := ThumbnailCache.new()
	cache.setup(workspace_path)
	var stage := ThumbnailStage.new()
	stage.setup(cache, viewport_host)
	stage.progress.connect(func(info: Dictionary) -> void: progress.emit(info))
	await stage.run(_scanned)

	# subtypes are a byproduct of choosing a capture path, so they only exist once
	# the thumbnails have run, the index is already written by then
	database.update_subtypes(stage.take_subtypes())

	return true

func _dispatch_type(bucket_root_path: String, type_entry: Dictionary, chain: Array) -> void:
	_pending_count += 1
	var registry := _runner_registry
	WorkerThreadPool.add_task(func() -> void:
		var entries := _run_chain(bucket_root_path, type_entry, chain, registry)
		call_deferred("emit_signal", "_type_done", entries)
	)

static func _run_chain(bucket_root_path: String, type_entry: Dictionary, chain: Array, registry: Dictionary) -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	for runner_name in chain:
		var runner: Variant = registry.get(runner_name)
		if runner == null:
			push_error("AssetManager: unknown runner name in runners list: ", runner_name)
			continue
		entries.append_array(runner.run(bucket_root_path, type_entry))
	return entries

func _on_type_done(entries: Array) -> void:
	_pending_count -= 1
	_completed_types += 1
	var last_type: String = ""
	for entry in entries:
		_scanned.append(entry)
		var type_id: String = entry["type"]
		last_type = type_id
		per_type_counts[type_id] = per_type_counts.get(type_id, 0) + 1
	_report_scan_progress(last_type)

## Types are scanned in parallel, so this reports how many have finished rather
## than a single "current" one.
func _report_scan_progress(last_type: String) -> void:
	progress.emit({
		"stage": "scan",
		"type": last_type,
		"label": "%d assets" % _scanned.size(),
		"current": _completed_types,
		"total": _total_types,
	})
