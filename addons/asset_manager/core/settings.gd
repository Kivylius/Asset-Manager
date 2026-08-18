@tool
class_name SettingsManager
extends RefCounted

## Per-user preferences; per-machine; global across every workspace.
const SECTION: String = "user_prefs"

const KEY_ITEMS_PER_PAGE: String = "items_per_page"
const KEY_GRID_ICON_SIZE: String = "grid_icon_size"
const KEY_IS_GRID_VIEW: String = "is_grid_view"
const KEY_AUDIO_VOLUME: String = "audio_volume"
const KEY_LIGHT_MODE_IDX: String = "light_mode_idx"
const KEY_GRID_VISIBLE: String = "preview_grid_visible"
const KEY_CHECKERBOARD_VISIBLE: String = "image_checkerboard_visible"
const KEY_MATERIAL_SHAPE_IDX: String = "material_shape_idx"
const KEY_SHADER_OPTIONS_OPEN: String = "shader_options_open"
const KEY_SHADER_CANVAS_DISPLAY_MODE_IDX: String = "shader_canvas_display_mode_idx"
const KEY_SIDEBAR_WIDTH: String = "sidebar_width"
const KEY_PREVIEW_WIDTH: String = "preview_width"

const DEFAULT_ITEMS_PER_PAGE: int = 100
const DEFAULT_GRID_ICON_SIZE: int = 40
const DEFAULT_IS_GRID_VIEW: bool = true
const DEFAULT_AUDIO_VOLUME: float = 25.0
const DEFAULT_LIGHT_MODE_IDX: int = 0
const DEFAULT_GRID_VISIBLE: bool = true
const DEFAULT_CHECKERBOARD_VISIBLE: bool = true
const DEFAULT_MATERIAL_SHAPE_IDX: int = 0
const DEFAULT_SHADER_OPTIONS_OPEN: bool = true
const DEFAULT_SHADER_CANVAS_DISPLAY_MODE_IDX: int = 2

func _set_pref(key: String, value: Variant) -> void:
	AssetManagerConfig.set_value(SECTION, key, value)

func get_items_per_page() -> int:
	return AssetManagerConfig.get_value(SECTION, KEY_ITEMS_PER_PAGE, DEFAULT_ITEMS_PER_PAGE)

func set_items_per_page(value: int) -> void:
	_set_pref(KEY_ITEMS_PER_PAGE, value)

func get_grid_icon_size() -> int:
	return AssetManagerConfig.get_value(SECTION, KEY_GRID_ICON_SIZE, DEFAULT_GRID_ICON_SIZE)

func set_grid_icon_size(value: int) -> void:
	_set_pref(KEY_GRID_ICON_SIZE, value)

func get_is_grid_view() -> bool:
	return AssetManagerConfig.get_value(SECTION, KEY_IS_GRID_VIEW, DEFAULT_IS_GRID_VIEW)

func set_is_grid_view(value: bool) -> void:
	_set_pref(KEY_IS_GRID_VIEW, value)

func get_audio_volume() -> float:
	return AssetManagerConfig.get_value(SECTION, KEY_AUDIO_VOLUME, DEFAULT_AUDIO_VOLUME)

func set_audio_volume(value: float) -> void:
	_set_pref(KEY_AUDIO_VOLUME, value)

func get_light_mode_idx() -> int:
	return AssetManagerConfig.get_value(SECTION, KEY_LIGHT_MODE_IDX, DEFAULT_LIGHT_MODE_IDX)

func set_light_mode_idx(value: int) -> void:
	_set_pref(KEY_LIGHT_MODE_IDX, value)

func get_preview_grid_visible() -> bool:
	return AssetManagerConfig.get_value(SECTION, KEY_GRID_VISIBLE, DEFAULT_GRID_VISIBLE)

func set_preview_grid_visible(value: bool) -> void:
	_set_pref(KEY_GRID_VISIBLE, value)

func get_checkerboard_visible() -> bool:
	return AssetManagerConfig.get_value(SECTION, KEY_CHECKERBOARD_VISIBLE, DEFAULT_CHECKERBOARD_VISIBLE)

func set_checkerboard_visible(value: bool) -> void:
	_set_pref(KEY_CHECKERBOARD_VISIBLE, value)

func get_material_shape_idx() -> int:
	return AssetManagerConfig.get_value(SECTION, KEY_MATERIAL_SHAPE_IDX, DEFAULT_MATERIAL_SHAPE_IDX)

func set_material_shape_idx(value: int) -> void:
	_set_pref(KEY_MATERIAL_SHAPE_IDX, value)

func get_shader_options_open() -> bool:
	return AssetManagerConfig.get_value(SECTION, KEY_SHADER_OPTIONS_OPEN, DEFAULT_SHADER_OPTIONS_OPEN)

func set_shader_options_open(value: bool) -> void:
	_set_pref(KEY_SHADER_OPTIONS_OPEN, value)

func get_shader_canvas_display_mode_idx() -> int:
	return AssetManagerConfig.get_value(SECTION, KEY_SHADER_CANVAS_DISPLAY_MODE_IDX, DEFAULT_SHADER_CANVAS_DISPLAY_MODE_IDX)

func set_shader_canvas_display_mode_idx(value: int) -> void:
	_set_pref(KEY_SHADER_CANVAS_DISPLAY_MODE_IDX, value)

## Panel widths are stored unscaled. A workspace opened on a 4K machine and a
## 1080p one each get the size the user set on that machine, rather than one
## multiplied twice.
func get_sidebar_width(fallback: int) -> int:
	return AssetManagerConfig.get_value(SECTION, KEY_SIDEBAR_WIDTH, fallback)

func set_sidebar_width(value: int) -> void:
	_set_pref(KEY_SIDEBAR_WIDTH, value)

func get_preview_width(fallback: int) -> int:
	return AssetManagerConfig.get_value(SECTION, KEY_PREVIEW_WIDTH, fallback)

func set_preview_width(value: int) -> void:
	_set_pref(KEY_PREVIEW_WIDTH, value)
