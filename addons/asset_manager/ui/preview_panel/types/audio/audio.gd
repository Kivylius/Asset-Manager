@tool
class_name AudioPreview
extends Control

@onready var _player: AudioStreamPlayer = $AudioStreamPlayer
@onready var _cover_art_rect: TextureRect = $VBox/WaveformPanel/LayerHost/CoverArtRect
@onready var _cover_art_fallback_label: Label = $VBox/WaveformPanel/LayerHost/CoverArtFallbackLabel
@onready var _waveform_image_rect: TextureRect = $VBox/WaveformPanel/LayerHost/WaveformStrip/WaveformPadding/WaveformImageRect
@onready var _waveform_played_rect: TextureRect = $VBox/WaveformPanel/LayerHost/WaveformStrip/WaveformPadding/PlayedClip/WaveformPlayedRect
@onready var _played_clip: Control = $VBox/WaveformPanel/LayerHost/WaveformStrip/WaveformPadding/PlayedClip
@onready var _playhead: ColorRect = $VBox/WaveformPanel/LayerHost/WaveformStrip/WaveformPadding/Playhead
@onready var _waveform_strip_label: Label = $VBox/WaveformPanel/LayerHost/WaveformStrip/WaveformPadding/WaveformStripLabel
@onready var _play_pause_button: Button = $VBox/TransportCard/TransportBox/ControlsRow/PlayPauseButton
@onready var _stop_button: Button = $VBox/TransportCard/TransportBox/ControlsRow/StopButton
@onready var _scrub_slider: HSlider = $VBox/TransportCard/TransportBox/ScrubRow/ScrubSlider
@onready var _current_time_label: Label = $VBox/TransportCard/TransportBox/ScrubRow/CurrentTimeLabel
@onready var _total_time_label: Label = $VBox/TransportCard/TransportBox/ScrubRow/TotalTimeLabel
@onready var _volume_slider: HSlider = $VBox/TransportCard/TransportBox/ControlsRow/VolumeSlider

var _settings: SettingsManager
var _is_scrubbing: bool = false

var _play_icon: Texture2D
var _pause_icon: Texture2D
var _waveform_pulse_tween: Tween
var _waveform_request_id: int = 0

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

	# The strip fades into the card below it, so the fade has to end in the
	# card's colour, hardcoded black leaves a seam once the theme isn't
	# near-black. The texture re-bakes itself when its gradient changes
	# (gradient_texture.cpp:213), so only the two stops move; width, height
	# and fill_to stay as authored.
	var fade_texture: GradientTexture2D = $VBox/WaveformPanel/LayerHost/WaveformStrip/FadeGradient.texture
	if fade_texture != null and fade_texture.gradient != null:
		fade_texture.gradient.set_color(0, Color(box.bg_color, 0.0))
		fade_texture.gradient.set_color(1, Color(box.bg_color, 1.0))

	# The panel above takes the same radius on its top corners, so cover art,
	# waveform and transport read as one stacked surface.
	if editor_theme != null and editor_theme.has_color("base_color", "Editor"):
		var top := StyleBoxFlat.new()
		top.bg_color = editor_theme.get_color("base_color", "Editor")
		top.corner_radius_top_left = int(radius * scale)
		top.corner_radius_top_right = int(radius * scale)
		$VBox/WaveformPanel.add_theme_stylebox_override("panel", top)

func _setup_icons() -> void:
	IconHelper.apply(_stop_button, "Stop")
	_play_icon = IconHelper.get_icon("Play")
	_pause_icon = IconHelper.get_icon("Pause")
	_play_pause_button.icon = _play_icon

func _update_cover_art(path: String, type_entry: Dictionary) -> void:
	var real_art: Texture2D = null
	if path.get_extension().to_lower() == "mp3":
		real_art = CoverArtExtractor.extract(path)

	if real_art:
		_cover_art_rect.texture = real_art
		_cover_art_rect.modulate = Color(1, 1, 1, 1)
		_cover_art_fallback_label.visible = false
		return

	_cover_art_rect.modulate = Color(1, 1, 1, 0.25)
	_cover_art_fallback_label.visible = true

	if not Engine.is_editor_hint():
		return
	var icon_name: String = type_entry.get("default_icon", "Image")
	var icon := IconHelper.get_icon(icon_name)
	if icon == null:
		icon = IconHelper.get_icon("Image")
	_cover_art_rect.texture = _build_icon_canvas(icon)

const ICON_CANVAS_SIZE: int = 512
const ICON_DISPLAY_SCALE: int = 2

func _build_icon_canvas(icon: Texture2D) -> Texture2D:
	if icon == null:
		return null
	var source_img := icon.get_image()
	if source_img == null:
		return icon
	var icon_img := source_img.duplicate() as Image
	icon_img.resize(icon_img.get_width() * ICON_DISPLAY_SCALE, icon_img.get_height() * ICON_DISPLAY_SCALE, Image.INTERPOLATE_LANCZOS)

	var canvas := Image.create(ICON_CANVAS_SIZE, ICON_CANVAS_SIZE, false, Image.FORMAT_RGBA8)
	canvas.fill(Color(0, 0, 0, 0))
	var offset := Vector2i(
		(ICON_CANVAS_SIZE - icon_img.get_width()) / 2,
		(ICON_CANVAS_SIZE - icon_img.get_height()) / 2
	)
	canvas.blend_rect(icon_img, Rect2i(Vector2i.ZERO, icon_img.get_size()), offset)
	return ImageTexture.create_from_image(canvas)

func setup(p_settings: SettingsManager) -> void:
	_settings = p_settings
	_volume_slider.value = _settings.get_audio_volume()
	set_volume(_settings.get_audio_volume())

func show_asset(path: String, type_entry: Dictionary = {}) -> void:
	var t_click := Time.get_ticks_msec()
	visible = true
	_update_cover_art(path, type_entry)

	var ext := path.get_extension().to_lower()

	if ext == "wav":
		_player.stream = _load_wav_from_file(path)
	else:
		var file := FileAccess.open(path, FileAccess.READ)
		if not file:
			return
		var buffer := file.get_buffer(file.get_length())
		if ext == "ogg":
			_player.stream = AudioStreamOggVorbis.load_from_buffer(buffer)
		elif ext == "mp3":
			var stream := AudioStreamMP3.new()
			stream.data = buffer
			_player.stream = stream

	if not _player.stream:
		return

	_scrub_slider.max_value = maxf(0.01, _player.stream.get_length())
	_total_time_label.text = _format_time(_player.stream.get_length())
	_player.play()
	_play_pause_button.icon = _pause_icon
	set_process(true)
	_update_waveform(t_click)

func _update_waveform(t_click: int = 0) -> void:
	_waveform_request_id += 1
	var this_request := _waveform_request_id
	var stream := _player.stream

	_waveform_strip_label.text = "Loading waveform..."
	_waveform_strip_label.visible = true

	var strip_size := Vector2.ZERO
	var settle_attempts := 0
	while strip_size == Vector2.ZERO and settle_attempts < 30:
		await get_tree().process_frame
		strip_size = _waveform_image_rect.get_parent_area_size()
		settle_attempts += 1
	var width := maxi(1, int(strip_size.x))
	var height := maxi(1, int(strip_size.y))

	_waveform_image_rect.texture = WaveformGenerator.generate_placeholder(width, height)
	_waveform_image_rect.modulate.a = 1.0
	_waveform_pulse_tween = create_tween().set_loops()
	_waveform_pulse_tween.tween_property(_waveform_image_rect, "modulate:a", 0.4, 0.8).set_trans(Tween.TRANS_SINE)
	_waveform_pulse_tween.tween_property(_waveform_image_rect, "modulate:a", 1.0, 0.8).set_trans(Tween.TRANS_SINE)

	var peaks := await WaveformGenerator.new().generate_peaks_async(stream, width)

	if this_request != _waveform_request_id:
		return # A newer asset was opened while this was decoding, discard.

	if _waveform_pulse_tween:
		_waveform_pulse_tween.kill()
		_waveform_pulse_tween = null
	_waveform_image_rect.modulate.a = 1.0

	var texture: ImageTexture = null
	if not peaks.is_empty():
		texture = WaveformGenerator.paint(peaks, width, height, WaveformGenerator.WAVE_COLOR)
		_waveform_played_rect.texture = WaveformGenerator.paint(peaks, width, height, WaveformGenerator.PLAYED_COLOR)
	else:
		_waveform_played_rect.texture = null
		_waveform_strip_label.text = "Waveform (coming soon)"
	_waveform_image_rect.texture = texture
	_waveform_played_rect.size = Vector2(width, height)
	_waveform_strip_label.visible = texture == null
	_played_clip.size.x = 0.0
	_playhead.visible = texture != null

func hide_asset() -> void:
	visible = false
	_waveform_request_id += 1
	if _waveform_pulse_tween:
		_waveform_pulse_tween.kill()
		_waveform_pulse_tween = null
	_player.stop()
	_player.stream = null
	_waveform_image_rect.texture = null
	_waveform_played_rect.texture = null
	_playhead.visible = false
	_waveform_strip_label.visible = true
	_play_pause_button.icon = _play_icon
	_scrub_slider.value = 0.0
	_current_time_label.text = "0:00"
	_total_time_label.text = "0:00"
	set_process(false)

func set_volume(volume_0_to_100: float) -> void:
	if volume_0_to_100 <= 0:
		_player.volume_db = -80.0
	else:
		_player.volume_db = linear_to_db(volume_0_to_100 / 100.0)

func _process(_delta: float) -> void:
	if not _is_scrubbing and _player.playing:
		_scrub_slider.value = _player.get_playback_position()
		_current_time_label.text = _format_time(_player.get_playback_position())
	_update_playhead()

func _update_playhead() -> void:
	if _scrub_slider.max_value <= 0.0:
		return
	var fraction := clampf(_scrub_slider.value / _scrub_slider.max_value, 0.0, 1.0)
	var strip_width := _waveform_image_rect.size.x
	var played_width := strip_width * fraction
	_played_clip.size.x = played_width
	_playhead.position.x = played_width

func _on_volume_changed(value: float) -> void:
	set_volume(value)
	if _settings:
		_settings.set_audio_volume(value)

func _on_finished() -> void:
	_play_pause_button.icon = _play_icon
	_scrub_slider.value = 0.0
	_current_time_label.text = "0:00"

func _on_play_pause_pressed() -> void:
	if not _player.stream:
		return
	if _player.playing:
		_player.stream_paused = true
		_play_pause_button.icon = _play_icon
	elif _player.stream_paused:
		_player.stream_paused = false
		_play_pause_button.icon = _pause_icon
	else:
		_player.play(_scrub_slider.value)
		_play_pause_button.icon = _pause_icon

func _on_stop_pressed() -> void:
	_player.stop()
	_play_pause_button.icon = _play_icon
	_scrub_slider.value = 0.0
	_current_time_label.text = "0:00"

func _on_scrub_drag_ended(_value_changed: bool) -> void:
	_is_scrubbing = false
	if _player.stream:
		_player.seek(_scrub_slider.value)

func _on_scrub_value_changed(value: float) -> void:
	if not _is_scrubbing:
		return
	_current_time_label.text = _format_time(value)

func _format_time(seconds: float) -> String:
	var total_seconds := int(seconds)
	return "%d:%02d" % [total_seconds / 60, total_seconds % 60]

func _load_wav_from_file(path: String) -> AudioStreamWAV:
	var file := FileAccess.open(path, FileAccess.READ)
	if not file: return null

	var stream := AudioStreamWAV.new()

	var riff := file.get_buffer(4).get_string_from_ascii()
	if riff != "RIFF": return null

	file.get_32()

	var wave := file.get_buffer(4).get_string_from_ascii()
	if wave != "WAVE": return null

	var format_found := false
	var data_found := false

	var format_tag: int = 0
	var bits_per_sample: int = 0
	var sample_rate: int = 0
	var channels: int = 0

	while file.get_position() < file.get_length() and not data_found:
		var chunk_id := file.get_buffer(4).get_string_from_ascii()
		if chunk_id.length() < 4:
			break

		var chunk_size := file.get_32()
		var next_chunk_pos := file.get_position() + chunk_size + (chunk_size % 2)

		if chunk_id == "fmt ":
			format_tag = file.get_16()
			channels = file.get_16()
			sample_rate = file.get_32()
			file.get_32()
			file.get_16()
			bits_per_sample = file.get_16()

			stream.mix_rate = sample_rate
			stream.stereo = (channels == 2)

			if format_tag == 1:
				if bits_per_sample == 8:
					stream.format = AudioStreamWAV.FORMAT_8_BITS
				elif bits_per_sample == 16 or bits_per_sample == 24:
					stream.format = AudioStreamWAV.FORMAT_16_BITS
				else:
					push_error("Unsupported WAV bit depth: ", bits_per_sample, " in ", path)
					return null
			elif format_tag == 3 and bits_per_sample == 32:
				stream.format = AudioStreamWAV.FORMAT_16_BITS
			else:
				push_error("Unsupported WAV format tag: ", format_tag, " in ", path)
				return null

			format_found = true

		elif chunk_id == "data":
			var raw_data := file.get_buffer(chunk_size)
			if format_tag == 1 and bits_per_sample == 24:
				stream.data = _convert_24bit_to_16bit(raw_data)
			elif format_tag == 3 and bits_per_sample == 32:
				stream.data = _convert_32bit_float_to_16bit(raw_data)
			else:
				stream.data = raw_data
			data_found = true

		file.seek(next_chunk_pos)

	if not format_found or not data_found:
		push_error("Could not find valid fmt/data chunks in WAV: ", path)
		return null

	return stream

func _convert_24bit_to_16bit(data24: PackedByteArray) -> PackedByteArray:
	var num_samples: int = data24.size() / 3
	var data16 := PackedByteArray()
	data16.resize(num_samples * 2)
	var j: int = 0
	for i in range(0, num_samples * 3, 3):
		data16[j] = data24[i + 1]
		data16[j + 1] = data24[i + 2]
		j += 2
	return data16

func _convert_32bit_float_to_16bit(data32: PackedByteArray) -> PackedByteArray:
	var num_samples: int = data32.size() / 4
	var data16 := PackedByteArray()
	data16.resize(num_samples * 2)
	var j: int = 0
	var offset: int = 0
	for i in range(num_samples):
		var f: float = data32.decode_float(offset)
		offset += 4
		var int_val: int = int(clampf(f, -1.0, 1.0) * 32767.0)
		data16[j] = int_val & 0xFF
		data16[j + 1] = (int_val >> 8) & 0xFF
		j += 2
	return data16
