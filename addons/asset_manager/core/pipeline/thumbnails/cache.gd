@tool
class_name ThumbnailCache
extends RefCounted

## On-disk thumbnail store, living inside the workspace so a whole team shares
## one cache the same way they share index.db.
## Files are keyed by a hash of path + mtime + size, so re-exporting an asset
## (same name, same location) changes the key and the old thumbnail is simply
## never asked for again. That check is a stat() the import scan already makes,
## unlike hashing file contents, which would mean reading every byte of the
## workspace on every import.

const CACHE_DIR_NAME: String = ".assetmanager/thumbnails"
const THUMB_SIZE: int = 256
const ANIMATED_THUMB_SIZE: int = 128

## An animated type stores a strip of up to ANIM_MAX_FRAMES rather than one image,
## so its pixels cost that multiple to read back and encode, most of an import.
## Stills stay large because they're cheap either way.
static func size_for(animated: bool) -> int:
	return ANIMATED_THUMB_SIZE if animated else THUMB_SIZE
const EXTENSION: String = "webp"

## WebP is lossy here on purpose: this is a regenerable cache, not an archive,
## and nothing is pixel-peeped at 256px. Verified against engine source that
## save_webp/load are available outside res://.
const LOSSY: bool = true
const QUALITY: float = 0.75

## 256 shards keeps any one directory small; a flat folder of 100k files makes
## directory listings slow, and some NAS setups struggle badly with it.
const SHARD_LENGTH: int = 2

var workspace_path: String = ""

func setup(p_workspace_path: String) -> void:
	workspace_path = p_workspace_path

func cache_root() -> String:
	return workspace_path.path_join(CACHE_DIR_NAME)

## path + mtime + size. Returns "" when the file is gone, which callers treat as
## "nothing to generate" rather than an error.
func key_for(asset_path: String) -> String:
	if not FileAccess.file_exists(asset_path):
		return ""

	var modified := FileAccess.get_modified_time(asset_path)
	var size := 0
	var file := FileAccess.open(asset_path, FileAccess.READ)
	if file:
		size = file.get_length()
		file.close()

	return (asset_path + "|" + str(modified) + "|" + str(size)).md5_text()

## Grouped by type first, then sharded, a flat folder of 100k files is slow to
## list and impossible to clear selectively, and "regenerate just the materials"
## is a real thing to want.
func path_for_key(key: String, type_id: String) -> String:
	if key.is_empty():
		return ""
	return cache_root() \
		.path_join(type_id if not type_id.is_empty() else "other") \
		.path_join(key.substr(0, SHARD_LENGTH)) \
		.path_join(key + "." + EXTENSION)

func path_for_asset(asset_path: String, type_id: String) -> String:
	return path_for_key(key_for(asset_path), type_id)

func has_current_thumbnail(asset_path: String, type_id: String) -> bool:
	var thumb_path := path_for_asset(asset_path, type_id)
	return not thumb_path.is_empty() and FileAccess.file_exists(thumb_path)

## Writes the image for an asset, creating the shard folder on demand.
func store(asset_path: String, type_id: String, image: Image) -> bool:
	if image == null or image.is_empty():
		return false

	var thumb_path := path_for_asset(asset_path, type_id)
	if thumb_path.is_empty():
		return false

	var err := DirAccess.make_dir_recursive_absolute(thumb_path.get_base_dir())
	if err != OK and err != ERR_ALREADY_EXISTS:
		push_error("AssetManager: could not create thumbnail folder: ", thumb_path.get_base_dir())
		return false

	err = image.save_webp(thumb_path, LOSSY, QUALITY)
	if err != OK:
		push_error("AssetManager: could not write thumbnail: ", thumb_path)
		return false

	return true

## Null when there's no current thumbnail, callers fall back to the type icon
## rather than treating it as a failure.
func load_texture(asset_path: String, type_id: String) -> Texture2D:
	var thumb_path := path_for_asset(asset_path, type_id)
	if thumb_path.is_empty() or not FileAccess.file_exists(thumb_path):
		return null

	var image := Image.load_from_file(thumb_path)
	if image == null or image.is_empty():
		return null

	return ImageTexture.create_from_image(image)

## Square canvas, asset scaled to fit inside it with aspect preserved and
## transparent padding around it, never cropped, never stretched, so the grid
## stays aligned whatever shape the source is.
static func fit_to_square(image: Image, size: int = THUMB_SIZE) -> Image:
	if image == null or image.is_empty():
		return image

	var source_size := Vector2(image.get_width(), image.get_height())
	var scale: float = minf(size / source_size.x, size / source_size.y)
	var target := Vector2i(
		maxi(1, int(round(source_size.x * scale))),
		maxi(1, int(round(source_size.y * scale)))
	)

	var scaled := image.duplicate() as Image
	# Pixel art loses its edges to smooth filtering, and upscaling is the
	# case where that's visible, so keep it blocky when enlarging.
	var interpolation := Image.INTERPOLATE_NEAREST if scale > 1.0 else Image.INTERPOLATE_LANCZOS
	scaled.resize(target.x, target.y, interpolation)

	if scaled.get_format() != Image.FORMAT_RGBA8:
		scaled.convert(Image.FORMAT_RGBA8)

	var canvas := Image.create_empty(size, size, false, Image.FORMAT_RGBA8)
	canvas.fill(Color(0, 0, 0, 0))
	canvas.blit_rect(
		scaled,
		Rect2i(0, 0, target.x, target.y),
		Vector2i((size - target.x) / 2, (size - target.y) / 2)
	)

	return canvas
