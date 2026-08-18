@tool
class_name ThumbnailViewport
extends RefCounted

## Shared offscreen viewport for every 3D thumbnail type. One instance is reused
## across a whole import, creating and freeing a viewport per model is far more
## expensive than swapping what's inside it.
## Main thread only. Viewport methods are guarded (scene/main/node.h), readback
## is a synchronous GPU stall.
## Framing and lighting are lifted from the engine's own thumbnail generator
## (editor/editor_interface.cpp, make_mesh_previews): AABB fit with an
## orthographic camera, key light at (-2,-1,-1) plus a dimmer fill at
## (+1,-1,-2).

## Same view the models preview uses (its camera sits at (2,2,3) looking at the
## origin), 29 degrees above the horizon, 34 around it.
const CAMERA_YAW: float = deg_to_rad(34.0)
const CAMERA_ELEVATION: float = deg_to_rad(29.0)

## Empty margin around the subject, so nothing touches the tile edge.
const FIT_MARGIN: float = 1.0

## Frames in an animated thumbnail, stacked vertically into one image.
## Rate an effect is both captured and played back at, so a strip runs at the
## speed the effect really does.
const ANIM_FPS: float = 15.0

## Frames for an effect we can't measure (mesh or shader driven). One second,
## rather than paying three for a guess.
const ANIM_DEFAULT_FRAMES: int = 15

## Fewer than this and a strip loops fast enough to strobe: a 0.12s muzzle flash
## is two frames, and two frames at 15fps is an eighth of a second.
const ANIM_MIN_FRAMES: int = 8

## Most effects here loop rather than end (24s black hole, 12s snow), so a cap
## costs only frames, since a cycle reads the same at two seconds as at twenty.
## Over half the library finishes inside this.
const ANIM_MAX_FRAMES: int = 30

var _viewport: SubViewport
var _pivot: Node3D
var _camera: Camera3D
var _host: Node

var _viewport_2d: SubViewport
var _pivot_2d: Node2D
var _camera_2d: Camera2D

## One entry per parallel capture slot; slot 0 is the main viewport above.
var _slots: Array[Dictionary] = []

## Host is any node already in the tree, the viewport has to be inside one to
## render at all.
func setup(host: Node, size: int) -> void:
	_host = host

	_viewport = SubViewport.new()
	_viewport.size = Vector2i(size, size)
	_viewport.transparent_bg = true
	# Idle between captures, this viewport lives for the whole import, and on
	# UPDATE_ALWAYS it re-rendered every frame of the entire run rather than only
	# when something was actually in it. _read_back flips it on for one frame.
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED

	var world := World3D.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(1, 1, 1)
	env.ambient_light_energy = 0.4
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	world.environment = env
	_viewport.world_3d = world

	_pivot = Node3D.new()
	_viewport.add_child(_pivot)

	_camera = Camera3D.new()
	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_viewport.add_child(_camera)

	var key := DirectionalLight3D.new()
	key.transform = Transform3D().looking_at(Vector3(-2, -1, -1), Vector3.UP)
	_viewport.add_child(key)

	var fill := DirectionalLight3D.new()
	fill.light_color = Color(0.7, 0.7, 0.7)
	fill.transform = Transform3D().looking_at(Vector3(1, -1, -2), Vector3.UP)
	_viewport.add_child(fill)

	_host.add_child(_viewport)

## For renderers that don't capture through a viewport but still need somewhere
## in the tree to live, a VideoStreamPlayer only decodes once it's parented.
func host() -> Node:
	return _host

func teardown() -> void:
	for slot in _slots:
		var viewport: SubViewport = slot["viewport"]
		# slot 0 may be the main viewport, which is freed below
		if viewport != _viewport and is_instance_valid(viewport):
			viewport.queue_free()
	_slots.clear()

	if is_instance_valid(_viewport):
		_viewport.queue_free()
	if is_instance_valid(_viewport_2d):
		_viewport_2d.queue_free()
	_viewport = null
	_pivot = null
	_camera = null
	_viewport_2d = null
	_pivot_2d = null
	_camera_2d = null

## A Node2D draws to the viewport's canvas, not into the 3D world, so it can't
## share the camera above, needs its own viewport. Built on first use so an
## import with no 2D effects never pays for it.
func _ensure_2d(size: int) -> void:
	if is_instance_valid(_viewport_2d):
		return

	_viewport_2d = SubViewport.new()
	_viewport_2d.size = Vector2i(size, size)
	_viewport_2d.transparent_bg = true
	_viewport_2d.render_target_update_mode = SubViewport.UPDATE_DISABLED

	_pivot_2d = Node2D.new()
	# Canvas origin is the top-left corner, so an effect emitting at (0,0) would
	# sit in the corner with three quarters of it off-screen.
	_pivot_2d.position = Vector2(size, size) * 0.5
	_viewport_2d.add_child(_pivot_2d)

	_camera_2d = Camera2D.new()
	_camera_2d.position = Vector2(size, size) * 0.5
	_viewport_2d.add_child(_camera_2d)

	_host.add_child(_viewport_2d)

## 2D counterpart of capture() currently just 1 as that works.
func capture_2d(subject: Node2D, size: int) -> Image:
	if subject == null:
		return null

	_ensure_2d(size)
	subject.position = Vector2.ZERO
	_pivot_2d.add_child(subject)

	var zoom := _fit_zoom_2d(subject, size)
	_camera_2d.zoom = Vector2(zoom, zoom)

	if not animate:
		var single := await _read_back(_viewport_2d)
		_pivot_2d.remove_child(subject)
		subject.queue_free()
		return single

	# Its own loop rather than capture_batch's: a Node2D draws to the viewport's
	# canvas instead of into a 3D world, so it can't share a slot. Only the
	# per-frame readback and blit are common, in _grab_frame.
	var frames := _anim_frames_for(subject)
	var step: float = 1.0 / ANIM_FPS
	var strip: Image = null

	for frame in range(frames):
		_advance_emitters(subject, step)
		_viewport_2d.render_target_update_mode = SubViewport.UPDATE_ONCE

		await RenderingServer.frame_post_draw

		strip = _grab_frame(_viewport_2d, strip, frame, frames)

	_viewport_2d.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_pivot_2d.remove_child(subject)
	subject.queue_free()

	return strip

func _fit_zoom_2d(subject: Node, size: int) -> float:
	# Works for most 2D nodes atm, may need improvements later.
	return 1

## Particle properties differ per emitter type, so a missing one reads as null.
func _number(obj: Object, property: String) -> float:
	var value: Variant = obj.get(property)
	return float(value) if value is float or value is int else 0.0

## Renders several subjects in ONE frame instead of one each.
## Measured: 72% of all capture time was waiting on frame_post_draw, 9.4ms per
## thumbnail spent idle while the editor drew everything else. That wait is per
## frame, not per thumbnail, so N viewports drawing together share one wait. The
## GPU readback after it is a synchronous stall (texture_2d_get is FUNC1RC),
## batching amortises that too.
## Extra viewports are built on demand and kept for the rest of the run.
## Subjects are freed here, callers hand over ownership, same as capture().
func capture_batch(subjects: Array[Node3D]) -> Array[Image]:
	var results: Array[Image] = []
	results.resize(subjects.size())

	if subjects.is_empty():
		return results

	# Frame each subject into its own viewport first, so the single frame that
	# follows draws all of them at once.
	var used: Array[int] = []
	for i in range(subjects.size()):
		var subject := subjects[i]
		if subject == null:
			continue

		var slot := _ensure_slot(i)
		if slot.is_empty():
			continue

		var pivot: Node3D = slot["pivot"]
		pivot.add_child(subject)

		var bounds := _visual_bounds(subject)
		# Temporary: what the framing actually sees, per subject.
		if bounds.size == Vector3.ZERO:
			pivot.remove_child(subject)
			subject.queue_free()
			continue

		_frame_camera(slot["camera"], bounds)
		slot["viewport"].render_target_update_mode = SubViewport.UPDATE_ONCE
		used.append(i)

	if used.is_empty():
		return results

	# One strip per subject, allocated once and filled in as each frame arrives,
	# no list of loose frames to join at the end.
	var strips: Array[Image] = []
	strips.resize(subjects.size())

	# Frames are per effect, not per batch: a muzzle flash is over in an eighth of
	# a second and a plume runs for three, so a fixed count either strobes the one
	# or cuts the other off. The batch runs as long as its longest, and a subject
	# that has all its frames drops out below rather than being drawn for nothing.
	var wanted: Dictionary = {}
	var longest: int = 1
	for i in used:
		wanted[i] = _anim_frames_for(subjects[i]) if animate else 1
		longest = maxi(longest, int(wanted[i]))

	var step: float = 1.0 / ANIM_FPS
	var live: Array[int] = used.duplicate()

	for frame in range(longest):
		for i in live:
			if animate:
				_advance_emitters(subjects[i], step)
			_slots[i]["viewport"].render_target_update_mode = SubViewport.UPDATE_ONCE

		await RenderingServer.frame_post_draw

		var still_live: Array[int] = []
		for i in live:
			if frame + 1 < int(wanted[i]):
				still_live.append(i)
			strips[i] = _grab_frame(_slots[i]["viewport"], strips[i], frame, int(wanted[i]))

		# Finished subjects stop being advanced, drawn and read back.
		live = still_live
		for i in used:
			if not live.has(i):
				_slots[i]["viewport"].render_target_update_mode = SubViewport.UPDATE_DISABLED
		if live.is_empty():
			break

	for i in used:
		results[i] = strips[i]

		var pivot: Node3D = _slots[i]["pivot"]
		var subject := subjects[i]
		if is_instance_valid(subject):
			pivot.remove_child(subject)
			subject.queue_free()

	return results

## Reads one frame off a viewport and writes it into a strip, allocating the strip
## on the first frame.
## Shared by both capture paths: the 3D batch drives many viewports through this
## per frame, the 2D one drives a single viewport. Returns the strip so the
## caller can hold it, null when the viewport gave nothing back.
func _grab_frame(viewport: SubViewport, strip: Image, frame: int, frames: int) -> Image:
	var texture: ViewportTexture = viewport.get_texture()
	var image: Image = texture.get_image() if texture else null

	if image == null or image.is_empty():
		return strip

	# Vertical: every frame is full width, so each blit is one contiguous run of
	# bytes and takes Image::blit_rect's single-memcpy path (image.cpp:3177)
	# rather than a copy per row.
	if strip == null:
		strip = Image.create_empty(
			image.get_width(),
			image.get_height() * frames,
			false,
			image.get_format()
		)
	strip.blit_rect(
		image,
		Rect2i(0, 0, image.get_width(), image.get_height()),
		Vector2i(0, image.get_height() * frame)
	)
	return strip

## Steps every emitter under a subject forward by `seconds`.
## request_particles_process advances the particles that already exist
## (gpu_particles_3d.cpp:485, "we assume to be in a controlled process
## situation"), which is what a scrub needs to keep consecutive frames as one
## run moving on, not separate replays from zero.
func _advance_emitters(node: Node, seconds: float) -> void:
	if node == null:
		return
	if node is GPUParticles3D or node is GPUParticles2D \
			or node is CPUParticles3D or node is CPUParticles2D:
		node.call("request_particles_process", seconds)
	for child in node.get_children():
		_advance_emitters(child, seconds)

## How many frames an effect is worth, from how long it has anything to show.
##
## active_time = lifetime * (2 - explosiveness) is the engine's own measure of
## when an emitter is done (gpu_particles_3d.cpp:454): at full explosiveness
## everything leaves at once and it ends in one lifetime, at zero they trickle out
## and it runs about twice that. The longest emitter under the subject wins, and
## an effect with none at all gets the default rather than a guess.
func _anim_frames_for(node: Node) -> int:
	var longest := _longest_active_time(node)
	if longest <= 0.0:
		return ANIM_DEFAULT_FRAMES
	return clampi(int(round(longest * ANIM_FPS)), ANIM_MIN_FRAMES, ANIM_MAX_FRAMES)

func _longest_active_time(node: Node) -> float:
	var longest: float = 0.0
	if node is GPUParticles3D or node is CPUParticles3D \
			or node is GPUParticles2D or node is CPUParticles2D:
		var lifetime := _number(node, "lifetime")
		var explosiveness := _number(node, "explosiveness")
		longest = lifetime * (2.0 - explosiveness)
	for child in node.get_children():
		longest = maxf(longest, _longest_active_time(child))
	return longest

## Whether the batch may use the main viewport as its first slot.
##
## Off by default because capture_sky and capture_fog reconfigure the main
## viewport in place, swapping its environment, turning off transparency,
## switching the camera to perspective, so a batch sharing it renders nothing.
## Types that never call those (models, scenes) turn it on and save building one
## viewport per batch.
var reuse_main_viewport: bool = false

## Whether captures come back as a strip of frames rather than a single image.
## Off by default: a model or a material doesn't move, so animating it would pay
## a capture and a readback per frame for that many identical frames.
var animate: bool = false

func _ensure_slot(index: int) -> Dictionary:
	while _slots.size() <= index:
		if _slots.is_empty() and reuse_main_viewport:
			_slots.append({"viewport": _viewport, "pivot": _pivot, "camera": _camera})
			continue
		_slots.append(_build_slot())
	return _slots[index]

## A clone of the main viewport's setup, own world, own lights, own camera, so
## the subjects in a batch can't light or occlude each other.
func _build_slot() -> Dictionary:
	var viewport := SubViewport.new()
	viewport.size = _viewport.size
	viewport.transparent_bg = true
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED

	var world := World3D.new()
	# Its own copy, not the main viewport's, sky and fog captures mutate the
	# environment they're given, and a shared one would leak that everywhere.
	var env: Environment = _viewport.world_3d.environment.duplicate()
	env.background_mode = Environment.BG_CLEAR_COLOR
	world.environment = env
	viewport.world_3d = world

	var pivot := Node3D.new()
	viewport.add_child(pivot)

	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	viewport.add_child(camera)

	var key := DirectionalLight3D.new()
	key.transform = Transform3D().looking_at(Vector3(-2, -1, -1), Vector3.UP)
	viewport.add_child(key)

	var fill := DirectionalLight3D.new()
	fill.light_color = Color(0.7, 0.7, 0.7)
	fill.transform = Transform3D().looking_at(Vector3(1, -1, -2), Vector3.UP)
	viewport.add_child(fill)

	_host.add_child(viewport)
	return {"viewport": viewport, "pivot": pivot, "camera": camera}

## Puts a subject in the viewport, frames it, renders, and returns the image.
## The subject is freed before returning, callers hand over ownership.
func capture(subject: Node3D) -> Image:
	if not is_instance_valid(_viewport) or subject == null:
		return null

	_pivot.add_child(subject)
	var bounds := _visual_bounds(subject)

	if bounds.size == Vector3.ZERO:
		_pivot.remove_child(subject)
		subject.queue_free()
		return null

	_frame(bounds)

	var image := await _read_back()

	_pivot.remove_child(subject)
	subject.queue_free()

	return image

## A sky has no subject to frame, it *is* the background. The camera stays put
## and looks slightly above the horizon, which is where a sky shader's gradient
## and horizon band are, rather than straight up at flat zenith colour.
func capture_sky(material: Material) -> Image:
	if not is_instance_valid(_viewport):
		return null

	var env := _viewport.world_3d.environment
	var previous_background := env.background_mode
	var previous_sky := env.sky

	# The viewport is transparent for models, but a sky IS the background, with
	# transparency on, the alpha channel wins and the tile comes back empty.
	_viewport.transparent_bg = false

	var sky := Sky.new()
	sky.sky_material = material
	env.sky = sky
	env.background_mode = Environment.BG_SKY

	_camera.projection = Camera3D.PROJECTION_PERSPECTIVE
	_camera.fov = 75.0
	_camera.global_position = Vector3.ZERO
	_camera.look_at(Vector3(0, 0.25, -1), Vector3.UP)

	var image := await _read_back()

	env.background_mode = previous_background
	env.sky = previous_sky
	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_viewport.transparent_bg = true

	return image

## Volumetric fog only accumulates where the camera is actually looking through
## it, so the camera sits back from the volume rather than framing it tightly.
## The clear colour is lightened too, fog is bright particulate, and against
## this viewport's near-black background it would be almost invisible.
func capture_fog(volume: Node3D) -> Image:
	if not is_instance_valid(_viewport) or volume == null:
		return null

	var env := _viewport.world_3d.environment
	var previous_fog := env.volumetric_fog_enabled
	var previous_colour := env.background_color
	env.volumetric_fog_enabled = true
	env.background_color = Color(0.18, 0.19, 0.22)
	# Fog is only visible against something, a transparent background would
	# leave it floating on alpha and mostly wash out.
	_viewport.transparent_bg = false

	_pivot.add_child(volume)

	var extent: float = 4.0
	var size: Variant = volume.get("size")
	if size is Vector3:
		extent = maxf(maxf(size.x, size.y), size.z)

	_camera.projection = Camera3D.PROJECTION_PERSPECTIVE
	_camera.fov = 60.0
	_camera.global_position = Vector3(0, extent * 0.2, extent * 1.4)
	_camera.look_at(Vector3.ZERO, Vector3.UP)

	var image := await _read_back()

	_pivot.remove_child(volume)
	volume.queue_free()
	env.volumetric_fog_enabled = previous_fog
	env.background_color = previous_colour
	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_viewport.transparent_bg = true

	return image

## Shared tail of every capture: draw the viewport exactly once, then pull the
## texture back off the GPU.
## UPDATE_ONCE consumes itself after one drawn frame, so the viewport goes back
## to idle on its own. frame_post_draw is the documented signal to wait on here,
## process_frame fires at the *start* of a frame, before rendering.
func _read_back(viewport: SubViewport = null) -> Image:
	var target := viewport if viewport != null else _viewport
	if not is_instance_valid(target):
		return null

	target.render_target_update_mode = SubViewport.UPDATE_ONCE

	await RenderingServer.frame_post_draw

	var texture := target.get_texture()
	var image: Image = texture.get_image() if texture else null
	if image == null or image.is_empty():
		return null
	return image

## Orthographic size comes from the AABB rotated into view space, so the subject
## fills the frame at any orientation without ever being clipped.
func _frame(bounds: AABB) -> void:
	_frame_camera(_camera, bounds)

func _frame_camera(camera: Camera3D, bounds: AABB) -> void:
	var center := bounds.get_center()

	# Place the camera on a sphere around the subject, then aim it, the same
	# position-and-look_at the models preview uses, rather than composing a basis
	# by hand (easy to get inverted, looks like a model filmed from underneath).
	var direction := Vector3(
		sin(CAMERA_YAW) * cos(CAMERA_ELEVATION),
		sin(CAMERA_ELEVATION),
		cos(CAMERA_YAW) * cos(CAMERA_ELEVATION)
	)

	var distance: float = maxf(bounds.size.length(), 0.001) * 2.0
	camera.transform = Transform3D(Basis(), center + direction * distance)
	camera.look_at(center, Vector3.UP)

	# Measure the subject in the camera's own space so the fit is exact at this
	# angle, rather than assuming a worst-case bounding sphere.
	var local: AABB = camera.global_transform.affine_inverse() * bounds
	var extent: float = maxf(local.size.x, local.size.y) * 0.5 * FIT_MARGIN
	if extent <= 0.0:
		extent = 1.0

	camera.size = extent * 2.0
	camera.near = 0.001
	camera.far = distance * 4.0

## Particle emitters report an empty AABB from get_aabb() (it is literally
## `return AABB()` in gpu_particles_3d.cpp) because their real extent lives on
## the GPU. Their authored visibility_aabb is the only bound available, and an
## emitter that never set one falls back to a small box around its origin,
## without this every effect frames as zero-size and gets skipped entirely.
const PARTICLE_FALLBACK_EXTENT: float = 2.0

## GPUParticles3D's constructor default (gpu_particles_3d.cpp:955). An emitter
## reporting exactly this never had one authored, so it says nothing about where
## the particles actually are, treating it as real bounds framed an ammo pickup
## 0.4 units across inside an 8-unit box, rendering it as a speck.
const PARTICLE_DEFAULT_AABB: AABB = AABB(Vector3(-4, -4, -4), Vector3(8, 8, 8))


## with_fallback=false ignores emitters that declare no bounds of their own, so
## real geometry can be measured without their guessed box in the way.
static func _node_aabb(node: Node, with_fallback: bool = true) -> AABB:
	if node is GPUParticles3D or node is CPUParticles3D:
		var visibility: AABB = node.get("visibility_aabb")
		if visibility != null and visibility.size != Vector3.ZERO \
				and visibility != PARTICLE_DEFAULT_AABB:
			return visibility
		if not with_fallback:
			return AABB()
		var extent := PARTICLE_FALLBACK_EXTENT
		return AABB(Vector3.ONE * -extent * 0.5, Vector3.ONE * extent)

	# A Decal is a VisualInstance3D, so its own AABB is the whole projection box,
	# and Y is how far it projects, not how big it is. A handprint 0.15 across is a
	# full unit deep, so fitting that box frames mostly empty space and the mark
	# lands as a speck. The plane added under it is the real footprint, and
	# _bounds_pass finds it as a child.
	if node is Decal:
		return AABB()

	if node is VisualInstance3D:
		return (node as VisualInstance3D).get_aabb()

	return AABB()

## Measures real geometry first and only falls back to the guessed particle box
## if there is none.
## An emitter with no visibility_aabb gets a fixed 4-unit box, fine on its own
## but swamps anything else: an ammo pickup barely a unit across framed as 8x8x8
## and rendered as a speck. Effects that are only particles still need the guess,
## so it stays, just as a last resort.
func _visual_bounds(node: Node, transform: Transform3D = Transform3D()) -> AABB:
	var real := _bounds_pass(node, transform, false)
	if real.size != Vector3.ZERO:
		return real
	return _bounds_pass(node, transform, true)

## Only visual geometry counts, a collision shape or an off-screen marker would
## otherwise pad the bounds and shrink the model to a dot in the middle.
func _bounds_pass(node: Node, transform: Transform3D, with_fallback: bool) -> AABB:
	var result := AABB()
	var found := false

	var local := transform
	if node is Node3D:
		local = transform * (node as Node3D).transform

	var own := _node_aabb(node, with_fallback)
	if own.size != Vector3.ZERO:
		result = local * own
		found = true

	for child in node.get_children():
		var child_aabb := _bounds_pass(child, local, with_fallback)
		if child_aabb.size == Vector3.ZERO:
			continue
		result = result.merge(child_aabb) if found else child_aabb
		found = true

	return result if found else AABB()
