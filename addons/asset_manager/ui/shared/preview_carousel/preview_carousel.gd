@tool
class_name PreviewCarousel
extends VBoxContainer

## Shows a pack's preview images: one, several with dots to step between them,
## or none, in which case the type's own icon stands in so the dialog keeps its
## shape either way.

## Unscaled, so it reads the same size on a 4K display as on a 1080p one.
const BASE_WIDTH: int = 600
const FADE_SECONDS: float = 0.15
const DOT_SIZE: int = 8
const AUTOPLAY_SECONDS: float = 3.0

@onready var _hero: TextureRect = $Hero
@onready var _hero_next: TextureRect = $Hero/HeroNext
@onready var _no_preview: VBoxContainer = $Hero/NoPreview
@onready var _no_preview_icon: TextureRect = $Hero/NoPreview/Icon
@onready var _dots: HBoxContainer = $Dots

var _textures: Array[Texture2D] = []
var _names: PackedStringArray = []
var _index: int = 0
var _fade: Tween
var _autoplay: Timer
var _user_took_over: bool = false

func _ready() -> void:
	if EditorGuard.is_scene_tab(self):
		return

	var scale := EditorInterface.get_editor_scale() if Engine.is_editor_hint() else 1.0
	custom_minimum_size = Vector2(BASE_WIDTH * scale, 0)
	_hero.custom_minimum_size = Vector2(0, BASE_WIDTH * 9.0 / 16.0 * scale)

	_autoplay = Timer.new()
	_autoplay.wait_time = AUTOPLAY_SECONDS
	_autoplay.timeout.connect(_advance)
	add_child(_autoplay)

## Nothing to show but the type it belongs to.
func show_placeholder(icon: Texture2D) -> void:
	_textures.clear()
	_names.clear()
	_index = 0
	_user_took_over = false
	_autoplay.stop()
	_hero.texture = _flat_panel()
	_hero.tooltip_text = ""
	_hero_next.modulate.a = 0.0
	_no_preview_icon.texture = icon
	_no_preview.visible = true
	_dots.visible = false

## The first image the dialog has. More can arrive later through append().
func show_images(images: Array[Image], icon: Texture2D, names: PackedStringArray = []) -> void:
	if images.is_empty():
		show_placeholder(icon)
		return

	_textures.clear()
	_names.clear()
	for i in images.size():
		_textures.append(ImageTexture.create_from_image(images[i]))
		_names.append(names[i] if i < names.size() else "")

	_index = 0
	_user_took_over = false
	_autoplay.stop()
	_no_preview.visible = false
	_hero.texture = _textures[0]
	_hero.tooltip_text = _names[0]
	_hero_next.modulate.a = 0.0
	_rebuild_dots()

## Loaded after the dialog opened, so the first image shows straight away and
## the rest arrive without holding it up.
func append(image: Image, name: String = "") -> void:
	if image == null:
		return
	_textures.append(ImageTexture.create_from_image(image))
	_names.append(name)
	_rebuild_dots()

## Only worth running once there is more than one image to run through, and
## stopped the moment a dot is clicked so it never fights the user.
func _advance() -> void:
	if _textures.size() < 2:
		return
	_show_index((_index + 1) % _textures.size(), false)

## Hidden for a single image: there is nowhere to step to. Removed before being
## freed, since queue_free only takes effect at the end of the frame and these
## are rebuilt several times as previews arrive.
func _rebuild_dots() -> void:
	for child in _dots.get_children():
		_dots.remove_child(child)
		child.queue_free()

	_dots.visible = _textures.size() > 1
	if not _dots.visible:
		return

	if not _user_took_over and _autoplay.is_stopped():
		_autoplay.start()

	var scale := EditorInterface.get_editor_scale() if Engine.is_editor_hint() else 1.0
	var icon := IconHelper.get_icon("GuiRadioChecked")
	for i in _textures.size():
		var dot := Button.new()
		dot.icon = icon
		dot.flat = true
		dot.focus_mode = Control.FOCUS_NONE
		dot.custom_minimum_size = Vector2(DOT_SIZE, DOT_SIZE) * scale
		dot.modulate.a = 1.0 if i == _index else 0.3
		dot.pressed.connect(_show_index.bind(i))
		_dots.add_child(dot)

## The outgoing image stays put while the incoming one fades in over it, so
## there is never a frame with nothing on the stage.
func _show_index(index: int, stop_autoplay: bool = true) -> void:
	if index == _index or index < 0 or index >= _textures.size():
		return

	if stop_autoplay:
		_user_took_over = true
		_autoplay.stop()

	_index = index
	_hero.tooltip_text = _names[index] if index < _names.size() else ""
	_hero_next.texture = _textures[index]
	_hero_next.modulate.a = 0.0

	if _fade != null and _fade.is_valid():
		_fade.kill()
	_fade = create_tween()
	_fade.tween_property(_hero_next, "modulate:a", 1.0, FADE_SECONDS)
	_fade.tween_callback(func() -> void:
		_hero.texture = _textures[_index]
		_hero_next.modulate.a = 0.0
	)

	_refresh_dot_highlight()

func _refresh_dot_highlight() -> void:
	for i in _dots.get_child_count():
		var dot := _dots.get_child(i) as Control
		if dot != null:
			dot.modulate.a = 1.0 if i == _index else 0.35

## The editor's own panel colour, so an empty stage reads as a frame rather
## than a hole.
func _flat_panel() -> ImageTexture:
	var colour := Color(0.16, 0.16, 0.16)
	if Engine.is_editor_hint():
		var theme := EditorInterface.get_editor_theme()
		if theme != null and theme.has_color("dark_color_2", "Editor"):
			colour = theme.get_color("dark_color_2", "Editor")

	var image := Image.create_empty(16, 9, false, Image.FORMAT_RGBA8)
	image.fill(colour)
	return ImageTexture.create_from_image(image)
