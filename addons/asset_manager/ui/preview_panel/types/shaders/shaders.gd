@tool
class_name ShadersPreview
extends Control

@onready var _viewport_container: SubViewportContainer = $SubViewportContainer
@onready var _viewport: SubViewport = $SubViewportContainer/SubViewport
@onready var _world_environment: WorldEnvironment = $SubViewportContainer/SubViewport/WorldEnvironment
@onready var _camera: Camera3D = $SubViewportContainer/SubViewport/Camera3D
@onready var _pivot: Node3D = $SubViewportContainer/SubViewport/SubjectPivot
@onready var _spatial_subject: MeshInstance3D = $SubViewportContainer/SubViewport/SubjectPivot/SpatialSubject
@onready var _particles_subject: GPUParticles3D = $SubViewportContainer/SubViewport/SubjectPivot/ParticlesSubject
@onready var _fog_subject: FogVolume = $SubViewportContainer/SubViewport/SubjectPivot/FogSubject
@onready var _cityblock_subject: Node3D = $SubViewportContainer/SubViewport/SubjectPivot/CityblockSubject
@onready var _canvas_overlay: ColorRect = $SubViewportContainer/SubViewport/CanvasOverlay
@onready var _canvas_item_fullscreen: ColorRect = $CanvasItemFullscreen
@onready var _canvas_item_aspect: AspectRatioContainer = $CanvasItemAspect
@onready var _canvas_item_display: ColorRect = $CanvasItemAspect/CanvasItemDisplay
@onready var _canvas_item_fixed_center: CenterContainer = $CanvasItemFixedCenter
@onready var _canvas_item_fixed_display: ColorRect = $CanvasItemFixedCenter/CanvasItemFixedDisplay
@onready var _unsupported_label: Label = $SubViewportContainer/UnsupportedLabel
@onready var _fog_shape_option: OptionButton = $ViewportToolbar/HBox/ModeControlsContainer/FogShapeOption
@onready var _spatial_shape_option: OptionButton = $ViewportToolbar/HBox/ModeControlsContainer/SpatialShapeOption
@onready var _flip_faces_check_box: CheckBox = $ViewportToolbar/HBox/ModeControlsContainer/FlipFacesCheckBox
@onready var _canvas_display_mode_option: OptionButton = $ViewportToolbar/HBox/ModeControlsContainer/CanvasDisplayModeOption
@onready var _options_toggle_btn: Button = $ViewportToolbar/HBox/OptionsToggleBtn
@onready var _mode_label: Label = $ViewportToolbar/HBox/ModeLabel
@onready var _viewport_toolbar: MarginContainer = $ViewportToolbar

const OPTIONS_SCENE := preload("res://addons/asset_manager/ui/preview_panel/types/shaders/options.tscn")
var _options_panel: ShaderOptionsPanel
var _current_material: ShaderMaterial
var _current_shader: Shader

enum CanvasDisplayMode { FULLSCREEN, COVER, FIT, FIXED_SMALL }
const CANVAS_DISPLAY_MODE_NAMES: PackedStringArray = ["Fullscreen", "Cover", "Fit", "Fixed"]
const FIXED_SIZE_RATIO: float = 0.5

const SPATIAL_SHAPE_NAMES: PackedStringArray = ["Sphere", "Cube", "Plane", "Fullscreen Plane"]
const FULLSCREEN_QUAD_INDEX: int = 3
var _spatial_shape_meshes: Array[Mesh] = []

const MODE_LABELS: Dictionary = {
	Shader.MODE_SPATIAL: "Spatial",
	Shader.MODE_CANVAS_ITEM: "Canvas Item",
	Shader.MODE_PARTICLES: "Particles",
	Shader.MODE_SKY: "Sky",
	Shader.MODE_FOG: "Fog",
}

var _mode_controls: Array[Control]

const FOG_SHAPE_NAMES: PackedStringArray = ["Box", "Ellipsoid", "Cone", "Cylinder", "World"]

const FOG_SHAPES: Array[RenderingServer.FogVolumeShape] = [
	RenderingServer.FOG_VOLUME_SHAPE_BOX,
	RenderingServer.FOG_VOLUME_SHAPE_ELLIPSOID,
	RenderingServer.FOG_VOLUME_SHAPE_CONE,
	RenderingServer.FOG_VOLUME_SHAPE_CYLINDER,
	RenderingServer.FOG_VOLUME_SHAPE_WORLD,
]
const FOG_SIZES: Array[Vector3] = [
	Vector3(2.5, 2, 2.5),
	Vector3(2.5, 2, 2.5),
	Vector3(2.2, 2.2, 2.2),
	Vector3(2.2, 2.2, 2.2),
	Vector3(2.5, 2, 2.5),
]

var _default_sky_material: ProceduralSkyMaterial

var _settings: SettingsManager

func setup(p_settings: SettingsManager) -> void:
	_settings = p_settings
	_canvas_display_mode_option.selected = _settings.get_shader_canvas_display_mode_idx()
	_apply_canvas_display_mode(_canvas_display_mode_option.selected)
	_options_toggle_btn.button_pressed = _settings.get_shader_options_open()

## Shaders show one centred subject, so no panning.
var _orbit := PreviewOrbitCamera.new()

var _ready_once: bool = false

func _ready() -> void:
	if EditorGuard.is_scene_tab(self):
		return

	if _ready_once:
		return
	_ready_once = true

	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	_default_sky_material = ProceduralSkyMaterial.new()
	_default_sky_material.sky_top_color = Color(0.38, 0.45, 0.55)
	_default_sky_material.sky_horizon_color = Color(0.55, 0.56, 0.58)
	_default_sky_material.ground_bottom_color = Color(0.15, 0.15, 0.15)
	_default_sky_material.ground_horizon_color = Color(0.3, 0.3, 0.3)
	var sky := Sky.new()
	sky.sky_material = _default_sky_material
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	_world_environment.environment = env

	var isolated_world := World3D.new()
	isolated_world.environment = env
	_viewport.world_3d = isolated_world

	_viewport_container.mouse_filter = Control.MOUSE_FILTER_IGNORE

	_orbit.setup(_camera, _pivot)
	_orbit.pan_enabled = false

	_build_cityblock()

	var cube := BoxMesh.new()
	cube.size = Vector3(1.6, 1.6, 1.6)
	var plane := PlaneMesh.new()
	plane.size = Vector2(2, 2)
	plane.orientation = PlaneMesh.FACE_Z
	var fullscreen_quad := QuadMesh.new()
	fullscreen_quad.size = Vector2(4, 4)
	fullscreen_quad.flip_faces = _flip_faces_check_box.button_pressed
	_spatial_shape_meshes = [_spatial_subject.mesh, cube, plane, fullscreen_quad]
	for shape_name in SPATIAL_SHAPE_NAMES:
		_spatial_shape_option.add_item(shape_name)
	_spatial_shape_option.item_selected.connect(_on_spatial_shape_selected)
	_flip_faces_check_box.toggled.connect(_on_flip_faces_toggled)

	for shape_name in FOG_SHAPE_NAMES:
		_fog_shape_option.add_item(shape_name)
	_fog_shape_option.selected = FOG_SHAPES.find(RenderingServer.FOG_VOLUME_SHAPE_WORLD)
	_fog_shape_option.item_selected.connect(_on_fog_shape_selected)

	for display_mode_name in CANVAS_DISPLAY_MODE_NAMES:
		_canvas_display_mode_option.add_item(display_mode_name)
	_canvas_display_mode_option.selected = CanvasDisplayMode.FIT
	_canvas_display_mode_option.item_selected.connect(_on_canvas_display_mode_selected)
	resized.connect(_update_fixed_display_size)

	_mode_controls = [_fog_shape_option, _spatial_shape_option, _flip_faces_check_box, _canvas_display_mode_option]

	var tools_icon := IconHelper.get_icon("Tools")
	if tools_icon != null:
		_options_toggle_btn.icon = tools_icon
		_options_toggle_btn.text = ""
		_options_toggle_btn.tooltip_text = "Shader Options"

	_options_panel = OPTIONS_SCENE.instantiate()
	add_child(_options_panel)
	_options_panel.set_scene_texture_provider(_get_scene_render_texture)
	_options_toggle_btn.pressed.connect(_on_options_toggle_pressed)
	_viewport_toolbar.resized.connect(func() -> void: _options_panel.set_top_offset(_viewport_toolbar.size.y))
	_options_panel.set_top_offset(_viewport_toolbar.size.y)

func _get_scene_render_texture() -> Texture2D:
	return _viewport.get_texture()

func _on_options_toggle_pressed() -> void:
	if not _options_toggle_btn.button_pressed:
		_options_panel.close()
		if _settings:
			_settings.set_shader_options_open(false)
		return
	if _current_shader == null or _current_material == null:
		_options_toggle_btn.button_pressed = false
		return
	_options_panel.open(_current_shader, _current_material, MODE_LABELS.get(_current_shader.get_mode(), "Shader") + " Options")
	if _settings:
		_settings.set_shader_options_open(true)

func _build_cityblock() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 1
	for i in range(14):
		var box := BoxMesh.new()
		var width := rng.randf_range(0.15, 0.35)
		var height := rng.randf_range(0.3, 1.4)
		box.size = Vector3(width, height, width)

		var mesh_instance := MeshInstance3D.new()
		mesh_instance.mesh = box

		var angle := rng.randf_range(0.0, TAU)
		var radius := rng.randf_range(0.3, 1.0)
		mesh_instance.position = Vector3(cos(angle) * radius, height * 0.5 - 1.0, sin(angle) * radius)

		_cityblock_subject.add_child(mesh_instance)

func show_asset(path: String, _type_entry: Dictionary = {}) -> void:
	visible = true
	_orbit.snap_to_look_at()

	var text := TscnSceneLoader.resolve_shader_includes(FileAccess.get_file_as_string(path), path)
	var shader := Shader.new()
	shader.code = text
	var mode := shader.get_mode()

	_apply_mode(mode, shader)

func _apply_mode(mode: Shader.Mode, shader: Shader) -> void:
	_mode_label.text = MODE_LABELS.get(mode, "Unsupported")
	_current_shader = shader
	_current_material = null
	_options_panel.close()
	_options_toggle_btn.button_pressed = false

	_spatial_subject.visible = false
	_particles_subject.visible = false
	_particles_subject.emitting = false
	_fog_subject.visible = false
	_cityblock_subject.visible = false
	_canvas_overlay.visible = false
	_canvas_item_fullscreen.visible = false
	_canvas_item_aspect.visible = false
	_canvas_item_fixed_center.visible = false
	_viewport_container.visible = true
	_unsupported_label.visible = false
	for control in _mode_controls:
		control.visible = false
	_world_environment.environment.sky.sky_material = _default_sky_material
	_world_environment.environment.background_mode = Environment.BG_SKY
	_world_environment.environment.volumetric_fog_enabled = false

	match mode:
		Shader.MODE_SPATIAL:
			var material := ShaderMaterial.new()
			material.shader = shader
			_current_material = material
			_options_panel.apply_default_placeholders(shader, material)
			_spatial_subject.material_override = material
			_spatial_subject.visible = true
			_spatial_shape_option.visible = true
			_apply_spatial_shape(_spatial_shape_option.selected if _spatial_shape_option.selected >= 0 else 0)

		Shader.MODE_CANVAS_ITEM:
			_cityblock_subject.visible = true
			var material := ShaderMaterial.new()
			material.shader = shader
			_current_material = material
			_options_panel.apply_default_placeholders(shader, material)
			_canvas_item_fullscreen.material = material
			_canvas_item_display.material = material
			_canvas_item_fixed_display.material = material
			_canvas_display_mode_option.visible = true
			_apply_canvas_display_mode(_canvas_display_mode_option.selected if _canvas_display_mode_option.selected >= 0 else CanvasDisplayMode.FIT)

		Shader.MODE_PARTICLES:
			var material := ShaderMaterial.new()
			material.shader = shader
			_current_material = material
			_options_panel.apply_default_placeholders(shader, material)
			var draw_mesh := SphereMesh.new()
			var draw_material := StandardMaterial3D.new()
			draw_material.vertex_color_use_as_albedo = true
			draw_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			draw_mesh.material = draw_material
			_particles_subject.draw_pass_1 = draw_mesh
			_particles_subject.process_material = material
			_particles_subject.visible = true
			_particles_subject.emitting = true

		Shader.MODE_SKY:
			var material := ShaderMaterial.new()
			material.shader = shader
			_current_material = material
			_options_panel.apply_default_placeholders(shader, material)
			_world_environment.environment.sky.sky_material = material

		Shader.MODE_FOG:
			if not _is_forward_plus_renderer():
				_unsupported_label.text = "Fog shader previews need the Forward+ renderer.\nThis project uses a different rendering method."
				_unsupported_label.visible = true
				return
			var material := ShaderMaterial.new()
			material.shader = shader
			_current_material = material
			_options_panel.apply_default_placeholders(shader, material)
			_fog_subject.material = material
			_fog_subject.visible = true
			_cityblock_subject.visible = true
			_world_environment.environment.volumetric_fog_enabled = true
			_fog_shape_option.visible = true
			_apply_fog_shape(_fog_shape_option.selected if _fog_shape_option.selected >= 0 else 0)

		_:
			_unsupported_label.text = "This shader type isn't supported for preview yet."
			_unsupported_label.visible = true

func _is_forward_plus_renderer() -> bool:
	return ProjectSettings.get_setting("rendering/renderer/rendering_method", "") == "forward_plus"

func _on_fog_shape_selected(index: int) -> void:
	_apply_fog_shape(index)

func _apply_fog_shape(index: int) -> void:
	_fog_subject.shape = FOG_SHAPES[index]
	_fog_subject.size = FOG_SIZES[index]

func _on_flip_faces_toggled(pressed: bool) -> void:
	(_spatial_shape_meshes[FULLSCREEN_QUAD_INDEX] as QuadMesh).flip_faces = pressed

func _on_canvas_display_mode_selected(index: int) -> void:
	_apply_canvas_display_mode(index)
	if _settings:
		_settings.set_shader_canvas_display_mode_idx(index)

func _apply_canvas_display_mode(mode: int) -> void:
	_canvas_item_fullscreen.visible = mode == CanvasDisplayMode.FULLSCREEN
	_canvas_item_aspect.visible = mode == CanvasDisplayMode.COVER or mode == CanvasDisplayMode.FIT
	_canvas_item_fixed_center.visible = mode == CanvasDisplayMode.FIXED_SMALL

	if mode == CanvasDisplayMode.COVER:
		_canvas_item_aspect.stretch_mode = AspectRatioContainer.STRETCH_COVER
	elif mode == CanvasDisplayMode.FIT:
		_canvas_item_aspect.stretch_mode = AspectRatioContainer.STRETCH_FIT
	elif mode == CanvasDisplayMode.FIXED_SMALL:
		_update_fixed_display_size()

func _update_fixed_display_size() -> void:
	if not _canvas_item_fixed_center.visible:
		return
	var side := minf(size.x, size.y) * FIXED_SIZE_RATIO
	_canvas_item_fixed_display.custom_minimum_size = Vector2(side, side)

## press p to toggle wireframe debug draw
func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_P:
		_viewport.debug_draw = Viewport.DEBUG_DRAW_DISABLED if _viewport.debug_draw == Viewport.DEBUG_DRAW_WIREFRAME else Viewport.DEBUG_DRAW_WIREFRAME

func _on_spatial_shape_selected(index: int) -> void:
	_apply_spatial_shape(index)

const SPHERE_INDEX: int = 0
const CUBE_INDEX: int = 1
const PLANE_INDEX: int = 2

func _apply_spatial_shape(index: int) -> void:
	_spatial_subject.mesh = _spatial_shape_meshes[index]

	match index:
		FULLSCREEN_QUAD_INDEX:
			if _spatial_subject.get_parent() != _camera:
				_spatial_subject.reparent(_camera, false)
			_spatial_subject.transform = Transform3D(Basis(), Vector3(0, 0, -1))
			_spatial_subject.extra_cull_margin = 16384.0
			_cityblock_subject.visible = true
			_flip_faces_check_box.visible = true

		PLANE_INDEX:
			if _spatial_subject.get_parent() != _pivot:
				_spatial_subject.reparent(_pivot, false)
			_spatial_subject.transform = Transform3D(Basis(Vector3.RIGHT, deg_to_rad(-45)), Vector3.ZERO)
			_spatial_subject.extra_cull_margin = 0.0
			_cityblock_subject.visible = false

		SPHERE_INDEX, CUBE_INDEX, _:
			if _spatial_subject.get_parent() != _pivot:
				_spatial_subject.reparent(_pivot, false)
			_spatial_subject.transform = Transform3D()
			_spatial_subject.extra_cull_margin = 0.0
			_cityblock_subject.visible = false

func hide_asset() -> void:
	visible = false
	_spatial_subject.material_override = null
	_particles_subject.process_material = null
	_particles_subject.emitting = false
	_fog_subject.material = null
	_canvas_overlay.material = null
	_canvas_item_fullscreen.material = null
	_canvas_item_display.material = null
	_canvas_item_fixed_display.material = null
	_options_panel.close()
	_options_toggle_btn.button_pressed = false
	_current_shader = null
	_current_material = null
	_orbit.reset_views()

func handle_gui_input(event: InputEvent) -> void:
	_orbit.handle_input(event)
