@tool
class_name MaterialsPreview
extends Control

signal _texture_decoded(token: int, image: Image)

@onready var _viewport_container: SubViewportContainer = $SubViewportContainer
@onready var _viewport: SubViewport = $SubViewportContainer/SubViewport
@onready var _camera: Camera3D = $SubViewportContainer/SubViewport/Camera3D
@onready var _pivot: Node3D = $SubViewportContainer/SubViewport/MaterialPivot
@onready var _mesh_instance: MeshInstance3D = $SubViewportContainer/SubViewport/MaterialPivot/PreviewMesh
@onready var _shape_toggle_btn: OptionButton = $ViewportToolbar/HBox/ShapeToggleBtn

const SHAPE_NAMES: PackedStringArray = ["Sphere", "Cube", "Plane"]

var _settings: SettingsManager
var _load_token: int = 0
var _decode_call_id: int = 0
var _shape_meshes: Array[Mesh] = []
var _shape_idx: int = 0
## Materials show one centred subject, so no panning.
var _orbit := PreviewOrbitCamera.new()

func _ready() -> void:
	if EditorGuard.is_scene_tab(self):
		return

	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky_material := ProceduralSkyMaterial.new()
	sky_material.sky_top_color = Color(0.38, 0.45, 0.55)
	sky_material.sky_horizon_color = Color(0.55, 0.56, 0.58)
	sky_material.ground_bottom_color = Color(0.15, 0.15, 0.15)
	sky_material.ground_horizon_color = Color(0.3, 0.3, 0.3)
	var sky := Sky.new()
	sky.sky_material = sky_material
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR

	var isolated_world := World3D.new()
	isolated_world.environment = env
	_viewport.world_3d = isolated_world

	_viewport_container.mouse_filter = Control.MOUSE_FILTER_IGNORE

	_orbit.setup(_camera, _pivot)
	_orbit.pan_enabled = false

	var sphere := _mesh_instance.mesh
	var cube := BoxMesh.new()
	cube.size = Vector3(1.6, 1.6, 1.6)
	var plane := PlaneMesh.new()
	plane.size = Vector2(2, 2)
	_shape_meshes = [sphere, cube, plane]

	for shape_name in SHAPE_NAMES:
		_shape_toggle_btn.add_item(shape_name)
	_shape_toggle_btn.item_selected.connect(_on_shape_selected)

func setup(p_settings: SettingsManager) -> void:
	_settings = p_settings
	set_shape_idx(_settings.get_material_shape_idx())

func show_asset(path: String, _type_entry: Dictionary = {}) -> void:
	visible = true
	_orbit.snap_to_look_at()

	_load_token += 1
	var my_token := _load_token

	var material := StandardMaterial3D.new()
	material.transparency = TresMaterialLoader.parse_transparency(path)
	_mesh_instance.material_override = material

	var texture_paths := TresMaterialLoader.parse_texture_paths(path)

	for property_name in texture_paths:
		_load_and_apply_texture(material, property_name, texture_paths[property_name], my_token)

func _load_and_apply_texture(material: StandardMaterial3D, property_name: String, texture_path: String, my_token: int) -> void:
	var img := await _await_threaded_load(texture_path)

	if my_token != _load_token:
		return

	if not img:
		return

	material.set(property_name, ImageTexture.create_from_image(img))
	match property_name:
		"normal_texture":
			material.normal_enabled = true
		"ao_texture":
			material.ao_enabled = true
		"heightmap_texture":
			material.heightmap_enabled = true



func _await_threaded_load(texture_path: String) -> Image:
	_decode_call_id += 1
	var call_id := _decode_call_id

	WorkerThreadPool.add_task(func() -> void:
		var img := TresMaterialLoader.load_image_blocking(texture_path)
		call_deferred("emit_signal", "_texture_decoded", call_id, img)
	)

	var image: Image = null
	var received := false
	while not received:
		var result: Array = await _texture_decoded
		if result[0] == call_id:
			image = result[1]
			received = true
	return image

func hide_asset() -> void:
	visible = false
	_mesh_instance.material_override = null
	_orbit.reset_views()

func _on_shape_selected(idx: int) -> void:
	set_shape_idx(idx)
	if _settings:
		_settings.set_material_shape_idx(_shape_idx)

func set_shape_idx(idx: int) -> void:
	_shape_idx = idx
	_mesh_instance.mesh = _shape_meshes[_shape_idx]
	_shape_toggle_btn.selected = _shape_idx

func handle_gui_input(event: InputEvent) -> void:
	_orbit.handle_input(event)
