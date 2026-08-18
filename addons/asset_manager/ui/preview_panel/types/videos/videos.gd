@tool
class_name VideosPreview
extends Control

const PLAY_ICON_SVG_NAME: String = "Play"
const PAUSE_ICON_SVG_NAME: String = "Pause"
const STOP_ICON_SVG_NAME: String = "Stop"

@onready var _video_fit: AspectRatioContainer = $VBox/VideoPanel/VideoFit
@onready var _player: VideoStreamPlayer = $VBox/VideoPanel/VideoFit/VideoStreamPlayer
@onready var _unsupported_label: Label = $VBox/UnsupportedLabel
@onready var _play_pause_button: Button = $VBox/TransportCard/TransportBox/ControlsRow/PlayPauseButton
@onready var _stop_button: Button = $VBox/TransportCard/TransportBox/ControlsRow/StopButton
@onready var _scrub_slider: HSlider = $VBox/TransportCard/TransportBox/ScrubRow/ScrubSlider
@onready var _current_time_label: Label = $VBox/TransportCard/TransportBox/ScrubRow/CurrentTimeLabel
@onready var _total_time_label: Label = $VBox/TransportCard/TransportBox/ScrubRow/TotalTimeLabel
@onready var _volume_slider: HSlider = $VBox/TransportCard/TransportBox/ControlsRow/VolumeSlider

var _settings: SettingsManager
var _play_icon: Texture2D
var _pause_icon: Texture2D

var _is_scrubbing: bool = false

func _ready() -> void:
	if EditorGuard.is_scene_tab(self):
		return

	_player.finished.connect(_on_finished)
	_play_pause_button.pressed.connect(_on_play_pause_pressed)
	_stop_button.pressed.connect(_on_stop_pressed)
	_scrub_slider.drag_started.connect(func() -> void: _is_scrubbing = true)
	_scrub_slider.drag_ended.connect(_on_scrub_drag_ended)
	_scrub_slider.value_changed.connect(_on_scrub_value_changed)
	_volume_slider.value_changed.connect(_on_volume_changed)
	set_process(false)
	_setup_icons()
	_style_transport()

## The editor's own background colour, surface_lowest_color, base_color dimmed
## by 1.7 (theme_modern.cpp:192), the darkest surface the theme defines. Follows
## a theme change rather than staying flat black. Only the bottom corners round,
## so card and panel above read as one surface.
func _style_transport() -> void:
	if not Engine.is_editor_hint():
		return
	var scale := EditorInterface.get_editor_scale()
	var radius: int = EditorInterface.get_editor_settings().get_setting("interface/theme/corner_radius")
	var spacing: int = EditorInterface.get_editor_settings().get_setting("interface/theme/base_spacing")

	var box := StyleBoxFlat.new()
	box.bg_color = Color.BLACK
	var editor_theme := EditorInterface.get_editor_theme()
	if editor_theme != null and editor_theme.has_color("background", "Editor"):
		box.bg_color = editor_theme.get_color("background", "Editor")
	box.corner_radius_bottom_left = int(radius * scale)
	box.corner_radius_bottom_right = int(radius * scale)

	var pad := int(spacing * scale)
	box.content_margin_left = pad
	box.content_margin_right = pad
	box.content_margin_top = pad
	box.content_margin_bottom = pad

	$VBox/TransportCard.add_theme_stylebox_override("panel", box)
	$VBox/TransportCard/TransportBox.add_theme_constant_override("separation", pad)

	# the panel above takes the same radius on its top corners, so the video and
	# the transport read as one stacked surface
	if editor_theme != null and editor_theme.has_color("base_color", "Editor"):
		var top := StyleBoxFlat.new()
		top.bg_color = editor_theme.get_color("base_color", "Editor")
		top.corner_radius_top_left = int(radius * scale)
		top.corner_radius_top_right = int(radius * scale)
		$VBox/VideoPanel.add_theme_stylebox_override("panel", top)

func _setup_icons() -> void:
	IconHelper.apply(_stop_button, STOP_ICON_SVG_NAME)
	_play_icon = IconHelper.get_icon(PLAY_ICON_SVG_NAME)
	_pause_icon = IconHelper.get_icon(PAUSE_ICON_SVG_NAME)
	_play_pause_button.icon = _play_icon

func setup(p_settings: SettingsManager) -> void:
	_settings = p_settings
	_volume_slider.value = _settings.get_audio_volume()
	_player.volume_db = linear_to_db(maxf(0.001, _settings.get_audio_volume() / 100.0))

func show_asset(path: String, _type_entry: Dictionary = {}) -> void:
	visible = true

	if path.get_extension().to_lower() != "ogv":
		_player.visible = false
		_unsupported_label.visible = true
		_set_controls_enabled(false)
		return

	_unsupported_label.visible = false
	_player.visible = true
	_set_controls_enabled(true)

	var stream := VideoStreamTheora.new()
	stream.file = path
	_player.stream = stream
	_player.play()
	_play_pause_button.icon = _pause_icon
	set_process(true)

func hide_asset() -> void:
	visible = false
	_player.stop()
	_player.stream = null
	_play_pause_button.icon = _play_icon
	_scrub_slider.value = 0.0
	_current_time_label.text = "0:00"
	_total_time_label.text = "0:00"
	set_process(false)

func _set_controls_enabled(enabled: bool) -> void:
	_play_pause_button.disabled = not enabled
	_stop_button.disabled = not enabled
	_scrub_slider.editable = enabled

## AspectRatioContainer does the letterboxing, but the number has to come from
## somewhere. VideoStreamPlayer only stretches or draws at native size
## (video_stream_player.cpp:186), and the stream's dimensions aren't known until
## the first frame is decoded.
func _fit_to_video() -> void:
	var texture := _player.get_video_texture()
	if texture == null:
		return
	var size := texture.get_size()
	if size.y <= 0:
		return
	_video_fit.ratio = size.x / size.y

func _process(_delta: float) -> void:
	_fit_to_video()
	if _is_scrubbing or not _player.is_playing():
		return
	_scrub_slider.max_value = maxf(0.01, _player.get_stream_length())
	_scrub_slider.value = _player.get_stream_position()
	_current_time_label.text = _format_time(_player.get_stream_position())
	_total_time_label.text = _format_time(_player.get_stream_length())

func _on_volume_changed(value: float) -> void:
	_player.volume_db = linear_to_db(maxf(0.001, value / 100.0)) if value > 0 else -80.0
	if _settings:
		_settings.set_audio_volume(value)

func _on_finished() -> void:
	_play_pause_button.icon = _play_icon
	_scrub_slider.value = 0.0
	_current_time_label.text = "0:00"

func _on_play_pause_pressed() -> void:
	if not _player.stream:
		return
	if _player.is_playing() and not _player.paused:
		_player.paused = true
		_play_pause_button.icon = _play_icon
	elif _player.paused:
		_player.paused = false
		_play_pause_button.icon = _pause_icon
	else:
		_player.play()
		_play_pause_button.icon = _pause_icon

func _on_stop_pressed() -> void:
	_player.stop()
	_play_pause_button.icon = _play_icon
	_scrub_slider.value = 0.0
	_current_time_label.text = "0:00"

func _on_scrub_value_changed(value: float) -> void:
	if not _is_scrubbing:
		return
	_current_time_label.text = _format_time(value)

func _on_scrub_drag_ended(_value_changed: bool) -> void:
	_is_scrubbing = false
	if _player.stream:
		_player.set_stream_position(_scrub_slider.value)

func _format_time(seconds: float) -> String:
	var total_seconds := int(seconds)
	return "%d:%02d" % [total_seconds / 60, total_seconds % 60]
