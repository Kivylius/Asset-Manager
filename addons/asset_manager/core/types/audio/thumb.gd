@tool
extends RefCounted

## Thumbnail renderer for sounds and music: the waveform, painted into a square.
## Cover art wins when present, the waveform is the fallback.
## Main thread only. OGG/MP3 go through AudioStreamPlayback (audio server),
## and the painter builds an ImageTexture (rendering server).

const WAVE_COLOR: Color = Color(0.45, 0.78, 1.0)
const BG_COLOR: Color = Color(0.12, 0.13, 0.16, 1.0)

static func work_kind() -> int:
	return ThumbnailStage.WORK_VIEWPORT

static func prepare(_path: String) -> Variant:
	return null

static func render_prepared(_prepared: Variant, _viewport: ThumbnailViewport, path: String) -> Image:
	var art := _cover_art(path)
	if art != null:
		return art

	var stream := _load_stream(path)
	if stream == null:
		return null

	var generator := WaveformGenerator.new()
	var peaks: Array[Vector2] = await generator.generate_peaks_async(stream, ThumbnailCache.THUMB_SIZE)
	if peaks.is_empty():
		return null

	return _paint(peaks, ThumbnailCache.THUMB_SIZE)

## Embedded ID3 artwork, MP3 only in practice. The extractor hands back a
## Texture2D for the preview, but the cache stores Images.
static func _cover_art(path: String) -> Image:
	var texture := CoverArtExtractor.extract(path)
	if texture == null:
		return null

	var image := texture.get_image()
	if image == null or image.is_empty():
		return null

	return image

## Same loading as the audio preview. These files live outside res://, no
## imported resource to ask for.
static func _load_stream(path: String) -> AudioStream:
	var ext := path.get_extension().to_lower()

	if ext == "wav":
		# Audio preview hand-parses RIFF (predates this API). Worth revisiting
		# together if a WAV shows up blank here.
		return AudioStreamWAV.load_from_file(path)

	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return null
	var buffer := file.get_buffer(file.get_length())
	file.close()

	if ext == "ogg":
		return AudioStreamOggVorbis.load_from_buffer(buffer)
	if ext == "mp3":
		var stream := AudioStreamMP3.new()
		stream.data = buffer
		return stream

	return null

## WaveformGenerator.paint() returns an ImageTexture for the preview, but the
## cache stores Images, so the drawing is duplicated here rather than pulling
## pixels back off the GPU.
static func _paint(peaks: Array[Vector2], size: int) -> Image:
	var image := Image.create_empty(size, size, false, Image.FORMAT_RGBA8)
	image.fill(BG_COLOR)

	var mid_y := size / 2.0

	for x in range(mini(size, peaks.size())):
		var top := int(mid_y - peaks[x].y * mid_y)
		var bottom := int(mid_y - peaks[x].x * mid_y)
		top = clampi(top, 0, size - 1)
		bottom = clampi(maxi(bottom, top + 1), 0, size - 1)

		for y in range(top, bottom + 1):
			image.set_pixel(x, y, WAVE_COLOR)

	return image
