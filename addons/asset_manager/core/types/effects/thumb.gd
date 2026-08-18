@tool
extends RefCounted

## Thumbnail renderer for effects.
## An effect at frame zero has emitted nothing, a naive capture is an empty
## tile. Every emitter is given a `preprocess` to fast-forward in a single
## frame, rather than waiting real frames for particles to build up.
## Only 3D effects are captured. A 2D effect draws through a Node2D canvas,
## not into the 3D world the shared viewport renders, falls back to the type
## icon.

## Zero, the animated capture starts each strip at the effect's own frame zero,
## a preprocess would skip past the part worth showing. Stays a named constant
## as the knob if a still capture ever needs the effect already developed.
const WARMUP_SECONDS: float = 0.0

static func work_kind() -> int:
	return ThumbnailStage.WORK_VIEWPORT

## Main thread, before the workers start. Binary resources are ~70x slower to
## load off-thread, fetch them here and cache for the parse to find.
## Safe to thread the parse afterwards: RenderingServer::texture_2d_create
## (rendering_server_default.h:147) queues the work when called off the
## render thread, so embedded-texture creation during parse is fine off-thread.
static func preload_main_thread(path: String) -> void:
	TscnSceneLoader.preload_binaries(path)

## Nothing to do off-thread, effects load on the main thread in build_subject.
static func prepare(_path: String) -> Variant:
	return null

## 2D effects fall back to capture_2d, which has its own viewport, nothing here
## reconfigures the 3D one, so the batch can use it as a slot.
static func reuses_main_viewport() -> bool:
	return true

## Only effects move, so only effects are captured as a strip of frames. Every
## other type is a still and would otherwise pay 20 captures and 20 readbacks
## for 20 identical frames.
static func wants_animation() -> bool:
	return true

## Loads and warms an effect without capturing, lets the stage render a whole
## chunk in one frame (ThumbnailViewport.capture_batch).
## 2D effects return null and fall back to render_prepared below, they draw to
## a canvas rather than into the 3D world, can't share a batch.
static func build_subject(_prepared: Variant, path: String) -> Node3D:
	var node: Node = TscnSceneLoader.load_external(path)
	if node == null:
		return null

	subtype[path] = ["3d"] if node is Node3D else ["2d"]

	# A 2D effect can't join the batch, but throwing the loaded node away here
	# meant render_prepared parsed the whole file a second time, hand it over.
	if not (node is Node3D):
		_pending_2d[path] = node
		return null

	_warm_up(node)
	return node as Node3D

static func render_prepared(_prepared: Variant, viewport: ThumbnailViewport, path: String) -> Image:
	# build_subject may already have loaded this one and handed it over.
	var node: Node = _pending_2d.get(path)
	if node != null:
		_pending_2d.erase(path)
	else:
		node = TscnSceneLoader.load_external(path)
	if node == null:
		return null

	_warm_up(node)

	var image: Image = null
	if node is Node3D:
		image = await viewport.capture(node as Node3D)
	elif node is Node2D:
		image = await viewport.capture_2d(node as Node2D, ThumbnailCache.ANIMATED_THUMB_SIZE)
	else:
		node.free()

	return image

## 3d or 2d per effect, recorded while build_subject picks a capture path and
## collected by the stage once the run is done.
static var subtype: Dictionary = {}

static func take_subtype() -> Dictionary:
	var collected := subtype.duplicate()
	subtype.clear()
	return collected

## 2D effects loaded by build_subject, waiting for render_prepared to capture them.
static var _pending_2d: Dictionary = {}

## The grid paints itself with LineEdit's own background (grid.gd's
## _apply_panel_style), so that is what the plane has to match, not the 3D
## preview's backdrop, which is a different colour entirely.
static func _grid_background() -> Color:
	if not Engine.is_editor_hint():
		return Color(0.102, 0.102, 0.122)
	var theme := EditorInterface.get_editor_theme()
	if theme != null and theme.has_stylebox("normal", "LineEdit"):
		var field := theme.get_stylebox("normal", "LineEdit")
		if field is StyleBoxFlat:
			return (field as StyleBoxFlat).bg_color
	return Color(0.102, 0.102, 0.122)

## X and Z are the decal's footprint; Y is how far it projects, not its size,
## a handprint decal is 0.15 across and a full unit deep.
static func _add_decal_surface(decal: Decal) -> void:
	var size: Vector3 = decal.size

	var mesh := PlaneMesh.new()
	# Exactly the decal's footprint: a decal can't project outside its own box,
	# anything wider is plane that will never be drawn on, and the framing
	# below measures the plane, so a larger one just shrinks the decal in the tile.
	mesh.size = Vector2(size.x, size.z)

	var material := StandardMaterial3D.new()
	# A decal needs opaque geometry to shade, transparent renders nothing at
	# all. The plane is baked into the thumbnail and can't follow a theme
	# change, so it takes the grid's own background, right on the default
	# theme and a visible tile on any other.
	material.albedo_color = _grid_background()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

	var plane := MeshInstance3D.new()
	plane.mesh = mesh
	plane.material_override = material
	plane.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	decal.add_child(plane)

## restart() alone isn't enough, it resets the emitter but doesn't advance it,
## so the capture still lands before anything has travelled.
static func _warm_up(node: Node) -> void:
	# Every emitter type carries the same three properties, no branch per class,
	# 2D and 3D warm up identically.
	if node is GPUParticles3D or node is CPUParticles3D \
			or node is GPUParticles2D or node is CPUParticles2D:
		# Every restart re-rolls the seed unless this is set (gpu_particles_3d.cpp:443),
		# the animated capture then samples the same effect at successive moments
		# rather than a fresh one each frame.
		node.set("use_fixed_seed", true)
		# An emitter also advances by the real frame delta every drawn frame
		# (particles_storage.cpp:1615), on top of any time asked for. Each captured
		# frame ran ~15% further than requested and effects looped early, a two
		# second burst restarting a quarter of the way through its strip. At zero
		# that natural advance is scaled away (:1607) while the requested step
		# still applies in full, because the request loop forces the scale to one
		# for its own duration (:1577).
		node.set("speed_scale", 0.0)
		node.set("preprocess", WARMUP_SECONDS)
		node.set("emitting", true)
		node.call("restart")

	# A decal is a texture projected onto whatever geometry sits inside its box
	# (scene_forward_clustered.glsl:1607, mixed into that surface's albedo).
	# Alone in an empty viewport there is nothing to shade, so it renders as
	# almost nothing. The plane is the background colour, only what the decal
	# projects onto it shows.
	if node is Decal:
		_add_decal_surface(node as Decal)

	for child in node.get_children():
		# A WorldEnvironment takes the world's environment over on ENTER_TREE, and
		# on EXIT_TREE the last one out sets it to null rather than restoring what
		# was there before (world_environment.cpp, _update_current_environment).
		# One viewport is shared by every effect of a run, so a single effect
		# carrying one left all the rest on the engine's default grey. Dropped here
		# rather than in its own pass, this walk already visits every node.
		if child is WorldEnvironment:
			node.remove_child(child)
			child.queue_free()
			continue
		_warm_up(child)
