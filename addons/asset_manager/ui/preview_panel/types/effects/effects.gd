@tool
class_name EffectsPreview
extends Control

@onready var _viewport_container: SubViewportContainer = $SubViewportContainer
@onready var _viewport: SubViewport = $SubViewportContainer/SubViewport
@onready var _camera: Camera3D = $SubViewportContainer/SubViewport/Camera3D
@onready var _pivot: Node3D = $SubViewportContainer/SubViewport/EffectPivot
@onready var _viewport_container_2d: SubViewportContainer = $SubViewportContainer2D
@onready var _viewport_2d: SubViewport = $SubViewportContainer2D/SubViewport2D
@onready var _camera_2d: Camera2D = $SubViewportContainer2D/SubViewport2D/Camera2D
@onready var _pivot_2d: Node2D = $SubViewportContainer2D/SubViewport2D/EffectPivot2D
@onready var _toolbar: Control = $ViewportToolbar
@onready var _reset_origin_btn: Button = $ViewportToolbar/HBox/ResetOriginBtn
@onready var _restart_btn: Button = $ViewportToolbar/HBox/RestartBtn
@onready var _grid_toggle_btn: Button = $ViewportToolbar/HBox/GridToggleBtn

const ZOOM_STEP_2D: float = 1.2
const MIN_ZOOM_2D: float = 0.1
const MAX_ZOOM_2D: float = 50.0
const FIT_RATIO_2D: float = 0.8
const FALLBACK_REACH_2D: float = 32.0

var _settings: SettingsManager

var _loaded_node: Node = null
var _orbit := PreviewOrbitCamera.new()
var _grid := PreviewReferenceGrid.new()

func _ready() -> void:
	if EditorGuard.is_scene_tab(self):
		return

	var clean_env := Environment.new()
	clean_env.background_mode = Environment.BG_COLOR
	clean_env.background_color = PreviewTheme.background()
	clean_env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	clean_env.ambient_light_color = Color(1.0, 1.0, 1.0)
	clean_env.ambient_light_energy = 0.3
	clean_env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	clean_env.glow_enabled = false

	var isolated_world := World3D.new()
	isolated_world.environment = clean_env
	_viewport.world_3d = isolated_world

	_viewport_container.mouse_filter = Control.MOUSE_FILTER_IGNORE

	_grid_toggle_btn.toggled.connect(_on_grid_toggled)
	# Origin restores the whole view, not just the pan pivot, resetting one
	# without the other leaves you recentred but still zoomed into nothing.
	_reset_origin_btn.pressed.connect(func() -> void:
		_orbit.reset_origin()
		_orbit.reset_zoom()
	)
	_restart_btn.pressed.connect(_on_restart_pressed)
	_viewport_container_2d.resized.connect(_apply_fit_zoom_2d)

	IconHelper.apply(_restart_btn, "Play")
	IconHelper.apply(_reset_origin_btn, "CenterView")
	IconHelper.apply(_grid_toggle_btn, "GridToggle")

	_orbit.setup(_camera, _pivot)
	_grid.setup(_pivot)
	_grid.set_enabled(_grid_toggle_btn.button_pressed)

	_build_2d_background()

## The 2D viewport has no World3D, so the Environment above can't give it a
## background, on its own it shows the editor panel behind it and 2D effects
## read as grey while 3D ones are dark.
## In a CanvasLayer because the Camera2D zooms: anything under the camera
## scales with it, so a plain ColorRect would shrink away from the edges as
## the user zooms out. A CanvasLayer ignores the camera, so this stays
## full-bleed at any zoom.
func _build_2d_background() -> void:
	var layer := CanvasLayer.new()
	# Below the effect, which draws on the default layer 0.
	layer.layer = -100

	var background := ColorRect.new()
	background.color = PreviewTheme.background()
	# Follows the viewport rather than a fixed size, the preview panel resizes.
	background.set_anchors_preset(Control.PRESET_FULL_RECT)
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(background)

	_viewport_2d.add_child(layer)

## Gives every Decal something to project onto.
## A decal is a texture painted onto whatever geometry sits inside its box, a
## bullet hole, a scorch mark, applied in the scene shader while a surface is
## being shaded (scene_forward_lights_inc.glsl:723). On its own in an empty
## viewport there is nothing to shade, so it renders as almost nothing.
## The plane is the background colour, so it disappears into the backdrop and
## only what the decal projects onto it is visible.
func _add_decal_surface(node: Node) -> void:
	if node == null:
		return

	for decal in _find_decals(node):
		var size: Vector3 = decal.size
		var plane := MeshInstance3D.new()

		var mesh := PlaneMesh.new()
		# Exactly the decal's footprint, it can't project outside its own box.
		mesh.size = Vector2(size.x, size.z)
		plane.mesh = mesh
		# X and Z are the decal's footprint; Y is how far it projects, not its
		# size, decal_handprint_1 is 0.15 across and a full unit deep.

		var material := StandardMaterial3D.new()
		# Same source as the viewport's own background, so the two can't drift.
		material.albedo_color = PreviewTheme.background()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		plane.material_override = material
		# Unlit and unshadowed, or the plane reads as a dark slab against the
		# background it's meant to disappear into.
		plane.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

		# Through the middle of the box rather than at its floor: the projection
		# is strongest there, and at the very bottom edge it barely lands at all.
		decal.add_child(plane)

func _find_decals(node: Node) -> Array:
	var found: Array = []
	if node is Decal:
		found.append(node)
	for child in node.get_children():
		found.append_array(_find_decals(child))
	return found

## Nested WorldEnvironments are a Godot no-no anyway, the engine takes the
## first node in the group and ignores the rest, but they're stripped at every
## depth so nothing can reach the tree and take the world's environment over.
func _strip_world_environments(node: Node) -> void:
	if node == null:
		return
	for child in node.get_children():
		if child is WorldEnvironment:
			node.remove_child(child)
			child.queue_free()
			continue
		_strip_world_environments(child)

func setup(p_settings: SettingsManager) -> void:
	_settings = p_settings
	set_grid_enabled(_settings.get_preview_grid_visible())

func show_asset(path: String, _type_entry: Dictionary = {}) -> void:
	visible = true

	_loaded_node = TscnSceneLoader.load_external(path)
	if _loaded_node == null:
		return

	# A WorldEnvironment takes the world's environment over on ENTER_TREE, and
	# on EXIT_TREE the last one out sets it to null rather than restoring what
	# was there before (world_environment.cpp, _update_current_environment).
	# Strip them before they reach the tree, which keeps _ready()'s environment.
	_strip_world_environments(_loaded_node)
	_add_decal_surface(_loaded_node)

	if _loaded_node is Node3D:
		_viewport_container.visible = true
		_viewport_container_2d.visible = false
		_toolbar.visible = true
		_grid.set_visible(true)
		_orbit.snap_to_look_at()
		_pivot.add_child(_loaded_node)
	else:
		_viewport_container.visible = false
		_viewport_container_2d.visible = true
		_toolbar.visible = true
		_reset_origin_btn.visible = false
		_grid_toggle_btn.visible = false
		_pivot_2d.add_child(_loaded_node)
		if _loaded_node is Node2D:
			(_loaded_node as Node2D).position = Vector2.ZERO
		_apply_fit_zoom_2d()

	_restart_effect()

func hide_asset() -> void:
	visible = false
	_toolbar.visible = false
	_grid.set_visible(false)
	_reset_origin_btn.visible = true
	_grid_toggle_btn.visible = true
	_viewport_container.visible = true
	_viewport_container_2d.visible = false
	_orbit.reset_views()

	if is_instance_valid(_loaded_node):
		_loaded_node.queue_free()
		_loaded_node = null

func handle_gui_input(event: InputEvent) -> void:
	if _viewport_container_2d.visible:
		if event is InputEventMouseButton and event.pressed:
			if event.button_index == MOUSE_BUTTON_WHEEL_UP:
				_zoom_in_2d()
			elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				_zoom_out_2d()
		return

	_orbit.handle_input(event)

func _on_restart_pressed() -> void:
	_restart_effect()

func _zoom_in_2d() -> void:
	var new_zoom: float = clampf(_camera_2d.zoom.x * ZOOM_STEP_2D, MIN_ZOOM_2D, MAX_ZOOM_2D)
	_camera_2d.zoom = Vector2(new_zoom, new_zoom)

func _zoom_out_2d() -> void:
	var new_zoom: float = clampf(_camera_2d.zoom.x / ZOOM_STEP_2D, MIN_ZOOM_2D, MAX_ZOOM_2D)
	_camera_2d.zoom = Vector2(new_zoom, new_zoom)

## Particle properties differ per emitter type, so a missing one reads as null.
func _get_number(obj: Object, property: String) -> float:
	var value: Variant = obj.get(property)
	return float(value) if value is float or value is int else 0.0

## Rough travel distance of an emitter's particles, ignoring gravity, only
## needs to land the right order of magnitude so small effects aren't dots
## and big ones aren't blown up past the panel.
func _emitter_reach(node: Node) -> float:
	var lifetime: float = _get_number(node, "lifetime")
	var reach: float = _get_number(node, "initial_velocity_max") * lifetime
	reach = maxf(reach, _get_number(node, "emission_sphere_radius"))
	reach = maxf(reach, _get_number(node, "scale_amount_max"))

	# GPUParticles2D keeps emission shape and velocity on its process material
	# rather than on the node, so the node-level properties above read as null.
	var mat: Variant = node.get("process_material")
	if mat is ParticleProcessMaterial:
		reach = maxf(reach, _process_material_reach(mat, lifetime))

	return reach

func _process_material_reach(mat: ParticleProcessMaterial, lifetime: float) -> float:
	var reach: float = mat.initial_velocity_max * lifetime

	match mat.emission_shape:
		ParticleProcessMaterial.EMISSION_SHAPE_SPHERE, \
		ParticleProcessMaterial.EMISSION_SHAPE_SPHERE_SURFACE:
			reach = maxf(reach, mat.emission_sphere_radius)
		ParticleProcessMaterial.EMISSION_SHAPE_BOX:
			reach = maxf(reach, maxf(mat.emission_box_extents.x, mat.emission_box_extents.y))
		ParticleProcessMaterial.EMISSION_SHAPE_RING:
			reach = maxf(reach, mat.emission_ring_radius)

	return reach

func _compute_fit_zoom_2d() -> float:
	var viewport_size: Vector2 = _viewport_container_2d.size
	if viewport_size.x <= 0.0 or viewport_size.y <= 0.0:
		return 1.0

	var reach: float = 0.0
	for emitter in _find_particle_emitters(_loaded_node):
		reach = maxf(reach, _emitter_reach(emitter))
	if reach <= 0.0:
		reach = FALLBACK_REACH_2D

	var content: float = reach * 2.0
	var fit: float = minf(viewport_size.x, viewport_size.y) * FIT_RATIO_2D / content
	return clampf(fit, MIN_ZOOM_2D, MAX_ZOOM_2D)

func _apply_fit_zoom_2d() -> void:
	if not _viewport_container_2d.visible or not is_instance_valid(_loaded_node):
		return
	var fit: float = _compute_fit_zoom_2d()
	_camera_2d.zoom = Vector2(fit, fit)

func _restart_effect() -> void:
	if not is_instance_valid(_loaded_node):
		return
	for emitter in _find_particle_emitters(_loaded_node):
		# An effect whose script starts its emitters ships with emitting = false,
		# and scripts never run here, restart() alone leaves it switched off.
		emitter.set("emitting", true)
		emitter.restart()
	_play_animations(_loaded_node)

## RESET is Godot's convention for the neutral state an effect sits at before
## it plays, for a nuke that means the mesh scaled to zero and every emitter
## turned off. The list comes back alphabetically, so RESET is first and a
## naive pick lands on the one animation guaranteed to show nothing.
func _pick_animation(player: AnimationPlayer) -> String:
	var autoplay: String = String(player.autoplay)
	if not autoplay.is_empty():
		return autoplay

	var names: PackedStringArray = player.get_animation_list()
	for name: String in names:
		if name != "RESET":
			return name
	return ""

## Not every effect is particles, some drive their motion with an
## AnimationPlayer, whose autoplay doesn't fire in the editor.
func _play_animations(node: Node) -> void:
	if node is AnimationPlayer:
		var player := node as AnimationPlayer
		var animation: String = _pick_animation(player)
		if not animation.is_empty():
			player.play(animation)
	for child in node.get_children():
		_play_animations(child)

func _find_particle_emitters(node: Node) -> Array:
	var result: Array = []
	if node is GPUParticles3D or node is GPUParticles2D or node is CPUParticles3D or node is CPUParticles2D:
		result.append(node)
	for child in node.get_children():
		result.append_array(_find_particle_emitters(child))
	return result

func get_grid_enabled() -> bool:
	return _grid.is_enabled()

func _on_grid_toggled(enabled: bool) -> void:
	_grid.set_enabled(enabled)
	if _settings:
		_settings.set_preview_grid_visible(enabled)

func set_grid_enabled(enabled: bool) -> void:
	_grid_toggle_btn.button_pressed = enabled
	_grid.set_enabled(enabled)
