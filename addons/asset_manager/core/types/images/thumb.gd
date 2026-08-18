@tool
extends RefCounted

## Decode + resize, no viewport capture.

static func work_kind() -> int:
	return ThumbnailStage.WORK_WORKER

static func render(path: String, size: int, _viewport: ThumbnailViewport = null) -> Image:
	var image := Image.load_from_file(path)
	if image == null or image.is_empty():
		return null
	return ThumbnailCache.fit_to_square(image, size)
