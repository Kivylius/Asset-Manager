@tool
class_name ImagesPreview
extends Control

## Image preview. Pans and zooms the image, with an optional checkerboard
## backdrop behind transparent PNGs/WebPs so the alpha reads as a surface
## rather than a hole.

const CHECKER_TILE_SIZE_BASE: int = 8
const CHECKER_LIGHT: Color = Color(1, 1, 1, 0.06)
const CHECKER_DARK: Color = Color(0, 0, 0, 0.06)
const TOGGLE_BTN_ICON_SIZE: int = 32

@onready var _texture_rect: TextureRect = $TextureRect
@onready var _checkerboard_rect: TextureRect = $CheckerboardRect
@onready var _checkerboard_toggle_btn: Button = $CheckerboardToggleBtn

var _settings: SettingsManager
var _is_panning: bool = false
var _last_mouse_pos: Vector2 = Vector2.ZERO

func _ready() -> void:
	if EditorGuard.is_scene_tab(self):
		return

	_checkerboard_rect.texture = _build_checker_tile()
	_checkerboard_toggle_btn.toggled.connect(_on_checkerboard_toggled)
	var checker_icon := IconHelper.get_icon("Checkerboard")
	if checker_icon != null:
		_checkerboard_toggle_btn.icon = _resize_icon(checker_icon, TOGGLE_BTN_ICON_SIZE)
		_checkerboard_toggle_btn.text = ""

func setup(p_settings: SettingsManager) -> void:
	_settings = p_settings
	var enabled := _settings.get_checkerboard_visible()
	_checkerboard_toggle_btn.button_pressed = enabled
	_checkerboard_rect.visible = enabled

func _on_checkerboard_toggled(enabled: bool) -> void:
	_checkerboard_rect.visible = enabled
	if _settings:
		_settings.set_checkerboard_visible(enabled)

func _build_checker_tile() -> ImageTexture:
	var editor_scale := EditorInterface.get_editor_scale() if Engine.is_editor_hint() else 1.0
	var tile_size := maxi(1, int(CHECKER_TILE_SIZE_BASE * editor_scale))
	var size := tile_size * 2
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	for y in range(size):
		for x in range(size):
			var is_light := (x / tile_size + y / tile_size) % 2 == 0
			img.set_pixel(x, y, CHECKER_LIGHT if is_light else CHECKER_DARK)
	return ImageTexture.create_from_image(img)

func _resize_icon(icon: Texture2D, target_size: int) -> Texture2D:
	if icon == null:
		return null
	var source_img := icon.get_image()
	if source_img == null:
		return icon
	var img := source_img.duplicate() as Image
	img.resize(target_size, target_size, Image.INTERPOLATE_LANCZOS)
	return ImageTexture.create_from_image(img)

func show_asset(path: String, _type_entry: Dictionary = {}) -> void:
	visible = true
	var img: Image = Image.load_from_file(path)
	if img:
		_texture_rect.texture = ImageTexture.create_from_image(img)
	_reset_views()

func hide_asset() -> void:
	visible = false
	_texture_rect.texture = null
	_reset_views()

func handle_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT or event.button_index == MOUSE_BUTTON_RIGHT or event.button_index == MOUSE_BUTTON_MIDDLE:
			_is_panning = event.pressed
			_last_mouse_pos = event.position
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			_zoom(event.position, 1.1)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			_zoom(event.position, 1.0 / 1.1)

	elif event is InputEventMouseMotion and _is_panning:
		var motion := event as InputEventMouseMotion
		var delta: Vector2 = motion.position - _last_mouse_pos
		_last_mouse_pos = motion.position
		_texture_rect.position += delta

func _zoom(mouse_pos: Vector2, factor: float) -> void:
	var old_scale := _texture_rect.scale
	var new_scale := old_scale * factor

	new_scale.x = clampf(new_scale.x, 0.1, 50.0)
	new_scale.y = clampf(new_scale.y, 0.1, 50.0)

	var mouse_local := mouse_pos - _texture_rect.position
	_texture_rect.position -= mouse_local * ((new_scale / old_scale) - Vector2.ONE)
	_texture_rect.scale = new_scale

func _reset_views() -> void:
	_texture_rect.scale = Vector2.ONE
	_texture_rect.position = Vector2.ZERO
