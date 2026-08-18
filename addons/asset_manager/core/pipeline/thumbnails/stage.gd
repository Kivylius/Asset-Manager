@tool
class_name ThumbnailStage
extends RefCounted

## Third import stage: generates thumbnails for everything the scan found.
## Not an import runner. Runners execute inside WorkerThreadPool.add_task()
## (import.gd), and viewport capture is main-thread only
## (scene/main/node.h's thread guards), so a runner physically cannot do the
## 3D half of this work. Runners also run per-type in parallel, while
## thumbnails need the finished index.
## Two kinds of renderer, declared by each type's thumb.gd:
##   WORK_WORKER  , pure decode/resize, safe to fan out across threads
##   WORK_VIEWPORT, needs a live viewport, main thread only, drained in order

enum { WORK_WORKER, WORK_VIEWPORT }

const RENDERERS: Dictionary = {
	"images": preload("res://addons/asset_manager/core/types/images/thumb.gd"),
	"models": preload("res://addons/asset_manager/core/types/models/thumb.gd"),
	"materials": preload("res://addons/asset_manager/core/types/materials/thumb.gd"),
	"scenes": preload("res://addons/asset_manager/core/types/scenes/thumb.gd"),
	"effects": preload("res://addons/asset_manager/core/types/effects/thumb.gd"),
	"shaders": preload("res://addons/asset_manager/core/types/shaders/thumb.gd"),
	"sounds": preload("res://addons/asset_manager/core/types/audio/thumb.gd"),
	"music": preload("res://addons/asset_manager/core/types/audio/thumb.gd"),
	"videos": preload("res://addons/asset_manager/core/types/videos/thumb.gd"),
}

## Renderers that detect a subtype park it per path while they work. The mode
## is known only where the capture path is chosen, and the image is all they
## can return, so each renderer hands its subtypes back at the end. A new type
## needs no change here.
func take_subtypes() -> Dictionary:
	var collected: Dictionary = {}
	for renderer: Variant in RENDERERS.values():
		if renderer.has_method("take_subtype"):
			collected.merge(renderer.take_subtype())
	return collected

signal progress(info: Dictionary)

var _cache: ThumbnailCache
## Viewport captures need a node already in the tree to parent to.
var _host: Node = null
var _counter_mutex: Mutex = Mutex.new()
var _generated: int = 0
var _skipped: int = 0
var _failed: int = 0

func setup(p_cache: ThumbnailCache, p_host: Node) -> void:
	_cache = p_cache
	_host = p_host

## `assets` is the scan result, {path, type, tags} entries, already deduped.
func run(assets: Array[Dictionary]) -> Dictionary:
	_generated = 0
	_skipped = 0
	_failed = 0

	var started := Time.get_ticks_msec()
	var pending: Array[Dictionary] = _collect_pending(assets)

	# Worker-safe types first: they fan out and finish fast, so the slow
	# main-thread captures aren't sitting behind them.
	var worker_jobs: Array[Dictionary] = []
	var viewport_jobs: Array[Dictionary] = []
	for job in pending:
		if job["work"] == WORK_WORKER:
			worker_jobs.append(job)
		else:
			viewport_jobs.append(job)

	await _run_worker_jobs(worker_jobs)
	await _run_viewport_jobs(viewport_jobs)

	# Resources are cached across the whole run, release them here rather
	# than holding until the next import.
	TscnSceneLoader.clear_cache()

	var elapsed := Time.get_ticks_msec() - started

	return {
		"generated": _generated,
		"skipped": _skipped,
		"failed": _failed,
		"elapsed_ms": elapsed,
	}

## Anything already cached at its current mtime+size is skipped here, so an
## import that changed nothing costs one stat() per asset and no rendering.
func _collect_pending(assets: Array[Dictionary]) -> Array[Dictionary]:
	var pending: Array[Dictionary] = []
	for entry in assets:
		var type_id: String = entry["type"]
		var renderer: Variant = RENDERERS.get(type_id)
		if renderer == null:
			continue

		var path: String = entry["path"]
		if _cache.has_current_thumbnail(path, type_id):
			_skipped += 1
			continue

		pending.append({
			"path": path,
			"type": type_id,
			"renderer": renderer,
			"work": renderer.work_kind(),
		})
	return pending

## One group task for the whole batch, decodes run across every core at once.
## Awaiting each task individually cost a full frame (~16ms) per image no
## matter how fast the decode was, measured at ~10ms/image for ~4ms of real
## work.
func _run_worker_jobs(jobs: Array[Dictionary]) -> void:
	if jobs.is_empty():
		return

	var total := jobs.size()
	var group_id := WorkerThreadPool.add_group_task(
		func(i: int) -> void: _render_worker_job(jobs[i]),
		total
	)

	# Yield while the pool drains so the editor keeps redrawing, reporting
	# progress from whatever has finished rather than in dispatch order.
	while not WorkerThreadPool.is_group_task_completed(group_id):
		_emit_progress_count(WorkerThreadPool.get_group_processed_element_count(group_id), total)
		await Engine.get_main_loop().process_frame

	WorkerThreadPool.wait_for_group_task_completion(group_id)
	_emit_progress_count(total, total)

## Runs on a pool thread, several at once. The counters are shared, so they're
## guarded rather than incremented directly.
func _render_worker_job(job: Dictionary) -> void:
	var image: Image = job["renderer"].render(job["path"], ThumbnailCache.THUMB_SIZE)
	var ok := image != null and _cache.store(job["path"], job["type"], image)
	_record(job, ok)

## How many assets are decoded ahead of the capture loop. Everything a chunk
## prepares is held in memory at once, and a 4K material is ~50MB per channel,
## so this is a memory ceiling, not a speed dial. Raising it doesn't make the
## capture half go faster.
const PREPARE_CHUNK: int = 8

## Per type, because the right size differs by what dominates: a batch is one
## frame that must render every viewport in it, so more per batch is not
## simply better. Anything unlisted uses PREPARE_CHUNK.
const CHUNK_OVERRIDES: Dictionary = {
	"models": 16,
	"effects": 16,
}

func _chunk_size(type_id: String) -> int:
	return int(CHUNK_OVERRIDES.get(type_id, PREPARE_CHUNK))

## The capture half is main-thread only (viewport guards + a synchronous GPU
## readback), but the loading half usually isn't: GLTF parsing and image
## decode are both thread-safe. So each chunk is decoded across every core,
## then captured one at a time here.
func _run_viewport_jobs(jobs: Array[Dictionary]) -> void:
	if jobs.is_empty():
		return

	if _host == null:
		push_error("AssetManager: no host node for thumbnail viewport, skipping ", jobs.size(), " thumbnails")
		return

	# Grouped by type so the detail bar fills and resets once per type. Jobs
	# arrive in scan order, which interleaves types and would leave that bar
	# creeping across the whole run instead.
	var by_type := _group_by_type(jobs)
	var overall_total := jobs.size()
	var overall_done := 0

	for type_id: String in by_type:
		var type_jobs: Array[Dictionary] = by_type[type_id]
		var type_total := type_jobs.size()
		var type_done := 0

		# A viewport per type, built and torn down with it. Sharing one
		# viewport across types doesn't work, sky/fog captures reconfigure it
		# in ways that cost other types seconds of recovery.
		var viewport := ThumbnailViewport.new()
		# A type that never reconfigures the viewport in place can batch into
		# it directly, saving one built viewport per batch.
		var renderer_for_type: Variant = type_jobs[0]["renderer"]
		if renderer_for_type.has_method("reuses_main_viewport"):
			viewport.reuse_main_viewport = renderer_for_type.reuses_main_viewport()
		if renderer_for_type.has_method("wants_animation"):
			viewport.animate = renderer_for_type.wants_animation()

		# After the flags above, the size follows from whether the type animates.
		var size: int = ThumbnailCache.size_for(viewport.animate)
		viewport.setup(_host, size)

		var chunk_size := _chunk_size(type_id)
		for chunk_start in range(0, type_total, chunk_size):
			var chunk: Array[Dictionary] = []
			for i in range(chunk_start, mini(chunk_start + chunk_size, type_total)):
				chunk.append(type_jobs[i])

			# Anything a renderer needs loaded on the main thread has to
			# happen before the workers start, see TscnSceneLoader.preload_binaries.
			var renderer_pre: Variant = chunk[0]["renderer"]
			if renderer_pre.has_method("preload_main_thread"):
				for job in chunk:
					renderer_pre.preload_main_thread(job["path"])

			await _prepare_chunk(chunk)

			# A renderer that can build its subject without capturing hands
			# the whole chunk over at once, so one drawn frame produces the
			# lot. Waiting for that frame is 72% of all capture time.
			var batched: Array[Image] = []
			var renderer: Variant = chunk[0]["renderer"]
			if renderer.has_method("build_subject"):
				var subjects: Array[Node3D] = []
				for job in chunk:
					subjects.append(renderer.build_subject(job.get("prepared"), job["path"]))
				batched = await viewport.capture_batch(subjects)

			for idx in range(chunk.size()):
				var job: Dictionary = chunk[idx]
				# A null here means the renderer declined to batch this one
				# (a 2D effect, say), it still needs its own capture below.
				var was_batched: bool = idx < batched.size() and batched[idx] != null
				var image: Image = null
				if was_batched:
					image = batched[idx]
				else:
					image = await job["renderer"].render_prepared(job.get("prepared"), viewport, job["path"])
				var ok := false
				if image != null:
					# An animated capture comes back as a vertical strip of
					# frames, which fit_to_square would scale down to a
					# single tile.
					var square: bool = image.get_height() <= image.get_width()
					var stored: Image = ThumbnailCache.fit_to_square(image, size) if square else image
					ok = _cache.store(job["path"], job["type"], stored)
				_record(job, ok)
				type_done += 1
				overall_done += 1
				_emit_progress(job, type_done, type_total, overall_done, overall_total)

		viewport.teardown()

func _group_by_type(jobs: Array[Dictionary]) -> Dictionary:
	var grouped: Dictionary = {}
	for job in jobs:
		var type_id: String = job["type"]
		if not grouped.has(type_id):
			grouped[type_id] = [] as Array[Dictionary]
		grouped[type_id].append(job)
	return grouped

## Decodes a chunk in parallel. A renderer that fails just leaves a null in
## "prepared", which render_prepared turns into a skipped thumbnail.
func _prepare_chunk(chunk: Array[Dictionary]) -> void:
	var group_id := WorkerThreadPool.add_group_task(
		func(i: int) -> void:
			var job: Dictionary = chunk[i]
			job["prepare_started_ms"] = Time.get_ticks_msec()
			job["prepared"] = job["renderer"].prepare(job["path"]),
		chunk.size()
	)

	while not WorkerThreadPool.is_group_task_completed(group_id):
		await Engine.get_main_loop().process_frame

	WorkerThreadPool.wait_for_group_task_completion(group_id)

func _record(job: Dictionary, ok: bool) -> void:
	if not ok:
		push_warning("AssetManager: no thumbnail generated for ", job["path"])

	_counter_mutex.lock()
	if ok:
		_generated += 1
	else:
		_failed += 1
	_counter_mutex.unlock()

## Batched work finishes out of order, so there's no single "current file" to
## name, the count is the honest thing to report.
func _emit_progress_count(current: int, total: int) -> void:
	progress.emit({
		"stage": "thumbnails",
		"label": "",
		"current": current,
		"total": total,
		"overall_current": current,
		"overall_total": total,
	})

## current/total are within the type being processed (the detail bar);
## overall_* span the whole stage (the top bar).
func _emit_progress(job: Dictionary, current: int, total: int, overall_current: int, overall_total: int) -> void:
	progress.emit({
		"stage": "thumbnails",
		"label": String(job["path"]).get_file(),
		"type": job["type"],
		"current": current,
		"total": total,
		"overall_current": overall_current,
		"overall_total": overall_total,
	})
