@tool
class_name WaveformGenerator
extends RefCounted

const WAVE_COLOR: Color = Color(0.55, 0.55, 0.55, 0.9)
const PLAYED_COLOR: Color = Color(0.35, 0.65, 1.0, 0.95)
const PLACEHOLDER_COLOR: Color = Color(0.5, 0.5, 0.5, 0.5)
const BG_COLOR: Color = Color(0, 0, 0, 0)
const TARGET_SAMPLES_PER_BUCKET: int = 200
const DECODE_CHUNK_FRAMES: int = 65536
const MAX_DECODE_FRAMES: int = 44100 * 60 * 20 # 20 minutes @ 44.1kHz

## Each yield waits a full engine frame (~16ms @ 60fps) regardless of how
## little work happened. Yielding too often turns into the dominant cost.
const YIELD_EVERY_N_CHUNKS: int = 200

## Fake, deterministic bar pattern shown while the real waveform is still loading.
static func generate_placeholder(width: int, height: int) -> ImageTexture:
	var peaks: Array[Vector2] = []
	var rng := RandomNumberGenerator.new()
	rng.seed = 1337 ## nice
	for x in range(width):
		var amplitude: float = rng.randf_range(0.15, 0.75)
		peaks.append(Vector2(-amplitude, amplitude))
	return paint(peaks, width, height, PLACEHOLDER_COLOR)

func generate_peaks_async(stream: AudioStream, width: int) -> Array[Vector2]:
	if stream is AudioStreamWAV:
		var frames := _frames_from_wav(stream as AudioStreamWAV)
		return _bucket_peaks(frames, width)
	elif stream is AudioStreamOggVorbis or stream is AudioStreamMP3:
		var estimated_frames := int(stream.get_length() * 44100.0)
		return await _decode_and_bucket_async(stream, width, estimated_frames)
	return []

static func _frames_from_wav(wav: AudioStreamWAV) -> PackedVector2Array:
	var frames := PackedVector2Array()
	var raw: PackedByteArray = wav.data
	if raw.is_empty():
		return frames

	var is_16_bit := wav.format == AudioStreamWAV.FORMAT_16_BITS
	var bytes_per_sample := 2 if is_16_bit else 1
	var channels := 2 if wav.stereo else 1
	var frame_count := raw.size() / (bytes_per_sample * channels)
	frames.resize(frame_count)

	for frame in range(frame_count):
		var sample := _read_sample(raw, frame, channels, bytes_per_sample, is_16_bit)
		frames[frame] = Vector2(sample, sample)

	return frames

func _decode_and_bucket_async(stream: AudioStream, width: int, estimated_total_frames: int) -> Array[Vector2]:
	var peaks: Array[Vector2] = []
	var playback := stream.instantiate_playback()
	if playback == null:
		return peaks

	playback.start(0.0)

	var frames_per_column := maxf(1.0, float(maxi(1, estimated_total_frames)) / float(width))
	var stride := maxi(1, int(frames_per_column / TARGET_SAMPLES_PER_BUCKET))

	var current_column := 0
	var column_end_frame := int(frames_per_column)
	var min_val := 1.0
	var max_val := -1.0
	var global_frame := 0
	var chunks_since_yield := 0

	while global_frame < MAX_DECODE_FRAMES:
		var chunk: PackedVector2Array = playback.mix_audio(1.0, DECODE_CHUNK_FRAMES)
		if chunk.is_empty():
			break

		var i := 0
		while i < chunk.size():
			while global_frame + i >= column_end_frame and current_column < width:
				peaks.append(Vector2(min_val, max_val))
				current_column += 1
				column_end_frame = int((current_column + 1) * frames_per_column)
				min_val = 1.0
				max_val = -1.0

			var sample: float = chunk[i].x
			min_val = minf(min_val, sample)
			max_val = maxf(max_val, sample)
			i += stride

		global_frame += chunk.size()
		if chunk.size() < DECODE_CHUNK_FRAMES:
			break # short chunk = end of stream.

		chunks_since_yield += 1
		if chunks_since_yield >= YIELD_EVERY_N_CHUNKS:
			chunks_since_yield = 0
			await Engine.get_main_loop().process_frame

	playback.stop()

	if current_column < width and (min_val <= max_val):
		peaks.append(Vector2(min_val, max_val))
		current_column += 1
	while current_column < width:
		peaks.append(Vector2(0.0, 0.0))
		current_column += 1

	return peaks

static func _bucket_peaks(frames: PackedVector2Array, width: int) -> Array[Vector2]:
	var peaks: Array[Vector2] = []
	var frame_count := frames.size()
	if frame_count <= 0:
		return peaks

	var frames_per_column := maxf(1.0, float(frame_count) / float(width))
	var step := maxi(1, int(frames_per_column / TARGET_SAMPLES_PER_BUCKET))

	for x in range(width):
		var start_frame := int(x * frames_per_column)
		var end_frame := mini(frame_count, int((x + 1) * frames_per_column))
		if end_frame <= start_frame:
			end_frame = mini(frame_count, start_frame + 1)

		var min_val := 1.0
		var max_val := -1.0
		var frame := start_frame
		while frame < end_frame:
			var sample: float = frames[frame].x
			min_val = minf(min_val, sample)
			max_val = maxf(max_val, sample)
			frame += step

		peaks.append(Vector2(min_val, max_val))

	return peaks

static func paint(peaks: Array[Vector2], width: int, height: int, color: Color) -> ImageTexture:
	var img := Image.create(width, height, false, Image.FORMAT_RGBA8)
	img.fill(BG_COLOR)

	var mid_y := height / 2.0

	for x in range(mini(width, peaks.size())):
		var min_val: float = peaks[x].x
		var max_val: float = peaks[x].y

		var y_top := int(mid_y - max_val * mid_y)
		var y_bottom := int(mid_y - min_val * mid_y)
		y_top = clampi(y_top, 0, height - 1)
		y_bottom = clampi(maxi(y_bottom, y_top + 1), 0, height - 1)

		for y in range(y_top, y_bottom + 1):
			img.set_pixel(x, y, color)

	return ImageTexture.create_from_image(img)

static func _read_sample(raw: PackedByteArray, frame: int, channels: int, bytes_per_sample: int, is_16_bit: bool) -> float:
	var byte_offset := frame * channels * bytes_per_sample
	if is_16_bit:
		var raw_value := raw.decode_s16(byte_offset)
		return raw_value / 32768.0
	else:
		var raw_value := raw[byte_offset]
		return (raw_value - 128) / 128.0
