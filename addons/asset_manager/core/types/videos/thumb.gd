@tool
extends RefCounted

## Thumbnail renderer for videos: one frame from the middle of the clip.
## No viewport capture, VideoStreamPlayer hands back its own texture.
## Main thread only, VideoStreamPlayer is a Control and has to be in the tree
## to decode at all.

## Theora decodes on its own schedule; poll until a frame actually lands.
const MAX_WAIT_FRAMES: int = 60

static func work_kind() -> int:
	return ThumbnailStage.WORK_VIEWPORT

static func prepare(_path: String) -> Variant:
	return null

## Borrows the viewport's host node so the player can sit in the tree.
static func render_prepared(_prepared: Variant, viewport: ThumbnailViewport, path: String) -> Image:
	# .ogv is the only container Godot decodes natively.
	if path.get_extension().to_lower() != "ogv":
		return null

	var host := viewport.host()
	if host == null:
		return null

	var stream := VideoStreamTheora.new()
	stream.file = path

	var player := VideoStreamPlayer.new()
	player.stream = stream
	player.autoplay = false
	player.volume_db = -80.0
	# Has to be in the tree to decode, so keep it out of sight rather than out
	# of the scene.
	player.modulate = Color(1, 1, 1, 0)
	host.add_child(player)

	player.play()

	# length is 0 until the stream opens; seeking past the end of a very short
	# clip leaves nothing to decode.
	var length := player.get_stream_length()
	if length > 0.0:
		player.set_stream_position(length * 0.5)

	var image := await _first_decoded_frame(player)

	player.stop()
	host.remove_child(player)
	player.queue_free()

	return image

## Texture exists immediately but is empty until the first decode lands.
static func _first_decoded_frame(player: VideoStreamPlayer) -> Image:
	for _i in range(MAX_WAIT_FRAMES):
		await Engine.get_main_loop().process_frame

		var texture := player.get_video_texture()
		if texture == null:
			continue

		var image := texture.get_image()
		if image != null and not image.is_empty():
			return image

	return null
