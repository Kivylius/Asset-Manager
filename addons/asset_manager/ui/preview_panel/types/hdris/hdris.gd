@tool
class_name HdrisPreview
extends Control

## HDRI preview. The panorama becomes the viewport's sky and a sphere sits in
## front of it, the same presentation Blender and Substance use: an HDRI is for
## lighting and reflection, and a mirror ball is the only way to see that
## directly. It also gives the camera something to orbit, so this behaves like
## every other 3D preview rather than turning in an empty void.

const SURFACE_NAMES: PackedStringArray = ["Chrome", "Glossy", "Matte", "Glass", "Sky only"]

const SURFACE_SKY_ONLY: int = 4

const MATTE_ALBEDO: Color = Color(0.8, 0.8, 0.8)
const GLOSSY_ALBEDO: Color = Color(0.15, 0.55, 0.62)
const GLOSSY_ROUGHNESS: float = 0.15

const GLASS_ALBEDO: Color = Color(0.9, 0.95, 1.0, 0.15)
const GLASS_REFRACTION: float = 0.12

@onready var _viewport_container: SubViewportContainer = $SubViewportContainer
@onready var _viewport: SubViewport = $SubViewportContainer/SubViewport
@onready var _camera: Camera3D = $SubViewportContainer/SubViewport/Camera3D
@onready var _pivot: Node3D = $SubViewportContainer/SubViewport/HdriPivot
@onready var _mesh_instance: MeshInstance3D = $SubViewportContainer/SubViewport/HdriPivot/PreviewMesh
@onready var _surface_toggle_btn: OptionButton = $ViewportToolbar/HBox/SurfaceToggleBtn

var _settings: SettingsManager
var _sky_material: PanoramaSkyMaterial
var _surface_materials: Array[StandardMaterial3D] = []
var _surface_idx: int = 0
## One centred subject, so no panning, same as materials.
var _orbit := PreviewOrbitCamera.new()

func _ready() -> void:
	if EditorGuard.is_scene_tab(self):
		return

	_sky_material = PanoramaSkyMaterial.new()
	var sky := Sky.new()
	sky.sky_material = _sky_material

	# AgX rather than the LINEAR the other previews use: an HDRI's highlights
	# run far above 1.0 (a clear-sky sun measures ~160), and LINEAR is a
	# passthrough (tonemap.glsl:247), so the sun and much of the sky would clip
	# to flat white.
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	# Defaults to REFLECTION_SOURCE_BG, which resolves to the same sky here, but
	# the reflection is the point of this preview, so it says so.
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_AGX

	var isolated_world := World3D.new()
	isolated_world.environment = env
	_viewport.world_3d = isolated_world

	_viewport_container.mouse_filter = Control.MOUSE_FILTER_IGNORE

	_orbit.setup(_camera, _pivot)
	_orbit.pan_enabled = false

	_surface_materials = [_build_chrome(), _build_glossy(), _build_matte(), _build_glass()]

	for surface_name in SURFACE_NAMES:
		_surface_toggle_btn.add_item(surface_name)
	_surface_toggle_btn.item_selected.connect(_on_surface_selected)

## A perfect mirror: what you see on it is the panorama, unsoftened.
func _build_chrome() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.metallic = 1.0
	material.roughness = 0.0
	return material

## Where the key light is and how hard it is, which a mirror shows as scenery
## and a matte surface doesn't show at all.
func _build_glossy() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = GLOSSY_ALBEDO
	material.metallic = 0.0
	material.roughness = GLOSSY_ROUGHNESS
	return material

func _build_matte() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = MATTE_ALBEDO
	material.metallic = 0.0
	material.roughness = 1.0
	return material

## Godot's refraction is screen space, so this bends the sky already drawn
## behind the sphere rather than tracing through glass. Close enough to read as
## glass, not a match for an offline render of one.
func _build_glass() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = GLASS_ALBEDO
	material.metallic = 0.0
	material.roughness = 0.0
	material.refraction_enabled = true
	material.refraction_scale = GLASS_REFRACTION
	return material

func setup(p_settings: SettingsManager) -> void:
	_settings = p_settings
	set_surface_idx(_settings.get_hdri_surface_idx())

func show_asset(path: String, _type_entry: Dictionary = {}) -> void:
	visible = true
	_orbit.snap_to_look_at()

	var image := Image.load_from_file(path)
	if image == null or image.is_empty():
		_sky_material.panorama = null
		return

	_sky_material.panorama = ImageTexture.create_from_image(image)

func hide_asset() -> void:
	visible = false
	_sky_material.panorama = null
	_orbit.reset_views()

func _on_surface_selected(idx: int) -> void:
	set_surface_idx(idx)
	if _settings:
		_settings.set_hdri_surface_idx(_surface_idx)

func set_surface_idx(idx: int) -> void:
	_surface_idx = idx
	_surface_toggle_btn.selected = _surface_idx

	_mesh_instance.visible = _surface_idx != SURFACE_SKY_ONLY
	if _mesh_instance.visible:
		_mesh_instance.material_override = _surface_materials[_surface_idx]

func handle_gui_input(event: InputEvent) -> void:
	_orbit.handle_input(event)
