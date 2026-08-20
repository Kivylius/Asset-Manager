@tool
extends RefCounted

## Thumbnail renderer for HDRI panoramas. The file is rendered as the viewport's
## sky and captured from inside it, rather than decoded and scaled flat: an
## equirectangular image is 2:1, so a square tile would either letterbox it
## into half the space or stretch it, and most of those pixels are the smeared
## zenith and nadir anyway.
## Decoding is the expensive half and is thread safe, so it happens in
## prepare(). Only the capture is main thread.

const FOV: float = 120.0

static func work_kind() -> int:
	return ThumbnailStage.WORK_VIEWPORT

static func prepare(path: String) -> Variant:
	var image := Image.load_from_file(path)
	if image == null or image.is_empty():
		return null
	return image

## No build_subject: a sky is a property of the environment rather than a node,
## so one viewport shows one sky and these can't be batched into a single frame.
static func render_prepared(prepared: Variant, viewport: ThumbnailViewport, _path: String) -> Image:
	if prepared == null:
		return null

	var material := PanoramaSkyMaterial.new()
	material.panorama = ImageTexture.create_from_image(prepared)

	return await viewport.capture_sky(material, FOV, Environment.TONE_MAPPER_AGX)
