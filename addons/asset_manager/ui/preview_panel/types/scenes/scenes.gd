@tool
class_name ScenesPreview
extends Control

## Preview for whole .tscn scenes (dev/prototype maps) living outside res://.
##
## Differs from the effects preview in two ways that matter:
##  - always 3D, never particles, so no 2D viewport and no restart/emitter code
##  - the scene's own WorldEnvironment/lights win; ours are only a fallback

@onready var _viewport_container: SubViewportContainer = $SubViewportContainer
@onready var _viewport: SubViewport = $SubViewportContainer/SubViewport
@onready var _camera: Camera3D = $SubViewportContainer/SubViewport/Camera3D
@onready var _fallback_light: DirectionalLight3D = $SubViewportContainer/SubViewport/FallbackLight
@onready var _pivot: Node3D = $SubViewportContainer/SubViewport/ScenePivot
@onready var _toolbar: Control = $ViewportToolbar
@onready var _reset_origin_btn: Button = $ViewportToolbar/HBox/ResetOriginBtn
@onready var _grid_toggle_btn: Button = $ViewportToolbar/HBox/GridToggleBtn

var _settings: SettingsManager

var _loaded_node: Node = null
var _fallback_env: Environment
var _orbit := PreviewOrbitCamera.new()
var _grid := PreviewReferenceGrid.new()

func _ready() -> void:
	if EditorGuard.is_scene_tab(self):
		return

	_fallback_env = Environment.new()
	_fallback_env.background_mode = Environment.BG_COLOR
	_fallback_env.background_color = PreviewTheme.background()
	_fallback_env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	_fallback_env.ambient_light_color = Color(1.0, 1.0, 1.0)
	_fallback_env.ambient_light_energy = 0.3
	_fallback_env.tonemap_mode = Environment.TONE_MAPPER_LINEAR

	var isolated_world := World3D.new()
	isolated_world.environment = _fallback_env
	_viewport.world_3d = isolated_world

	_viewport_container.mouse_filter = Control.MOUSE_FILTER_IGNORE

	_grid_toggle_btn.toggled.connect(_on_grid_toggled)
	# origin restores the whole view, not just the pan pivot, resetting one
	# without the other leaves you recentred but still zoomed into nothing
	_reset_origin_btn.pressed.connect(func() -> void:
		_orbit.reset_origin()
		_orbit.reset_zoom()
	)

	IconHelper.apply(_reset_origin_btn, "CenterView")
	IconHelper.apply(_grid_toggle_btn, "GridToggle")

	_orbit.setup(_camera, _pivot)
	_orbit.zoom_step_ratio = 0.1
	_grid.setup(_pivot)
	_grid.set_enabled(_grid_toggle_btn.button_pressed)

func setup(p_settings: SettingsManager) -> void:
	_settings = p_settings
	set_grid_enabled(_settings.get_preview_grid_visible())

func show_asset(path: String, _type_entry: Dictionary = {}) -> void:
	visible = true

	_loaded_node = TscnSceneLoader.load_external(path, "scenes")
	if _loaded_node == null:
		return

	_toolbar.visible = true
	_grid.set_visible(true)
	_orbit.snap_to_look_at()
	_pivot.add_child(_loaded_node)
	_apply_scene_lighting()

func hide_asset() -> void:
	visible = false
	_toolbar.visible = false
	_grid.set_visible(false)
	_orbit.reset_views()

	if is_instance_valid(_loaded_node):
		_loaded_node.queue_free()
		_loaded_node = null

	_viewport.world_3d.environment = _fallback_env
	_fallback_light.visible = true

## A dev map usually ships its own sky and sun. Ours exist so a scene without
## either isn't previewed pitch black, when the scene brings its own, they'd
## just double up, so they step aside.
func _apply_scene_lighting() -> void:
	var world_env := _find_first(_loaded_node, "WorldEnvironment") as WorldEnvironment
	if world_env and world_env.environment:
		_viewport.world_3d.environment = world_env.environment

	_fallback_light.visible = _find_first(_loaded_node, "DirectionalLight3D") == null

func _find_first(node: Node, type_name: String) -> Node:
	if node.is_class(type_name):
		return node
	for child in node.get_children():
		var found := _find_first(child, type_name)
		if found:
			return found
	return null

func handle_gui_input(event: InputEvent) -> void:
	_orbit.handle_input(event)

func get_grid_enabled() -> bool:
	return _grid.is_enabled()

func _on_grid_toggled(enabled: bool) -> void:
	_grid.set_enabled(enabled)
	if _settings:
		_settings.set_preview_grid_visible(enabled)

func set_grid_enabled(enabled: bool) -> void:
	_grid_toggle_btn.button_pressed = enabled
	_grid.set_enabled(enabled)
