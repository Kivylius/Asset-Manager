@tool
extends RefCounted

## Thumbnail renderer for materials: the .tres applied to a sphere.
## Split in two: prepare() decodes channels on a worker, render_prepared()
## uploads and captures on the main thread. A 4K channel is ~50MB of pixels,
## a material usually has five or six.

const SPHERE_RADIUS: float = 0.5
const SPHERE_RINGS: int = 32
const SPHERE_SEGMENTS: int = 64

## Channels not worth decoding for a 256px sphere. Across a real library these
## two are 30% of all texture bytes (heightmap alone is 23%) and neither shows
## at this size: heightmap drives parallax mapping (needs pixels to displace),
## AO is nearly invisible under the viewport's uniform ambient light.
## Roughness and metallic stay, they change what a material *is* rather than
## adding detail, without metallic every metal renders as painted plastic.
## orm_texture packs both plus AO into one image's channels, so it stays too.
const SKIP_CHANNELS: PackedStringArray = ["heightmap_texture", "ao_texture"]

## Only the channels StandardMaterial3D needs told to switch on, the rest are
## read straight from the texture slot.
const ENABLE_FLAGS: Dictionary = {
	"normal_texture": "normal_enabled",
	"ao_texture": "ao_enabled",
	"heightmap_texture": "heightmap_enabled",
	"emission_texture": "emission_enabled",
	"subsurf_scatter_texture": "subsurf_scatter_enabled",
}

static func work_kind() -> int:
	return ThumbnailStage.WORK_VIEWPORT

## Decode only, no ImageTexture (registers with the rendering server, main
## thread only).
static func prepare(path: String) -> Variant:
	var texture_paths := TresMaterialLoader.parse_texture_paths(path)
	if texture_paths.is_empty():
		return null

	var images: Dictionary = {}
	for property_name: String in texture_paths:
		if SKIP_CHANNELS.has(property_name):
			continue
		var image := TresMaterialLoader.load_image_blocking(texture_paths[property_name])
		if image != null and not image.is_empty():
			images[property_name] = _shrink(image)

	# A material whose textures all failed would render as a plain grey ball,
	# which is worse than falling back to the type icon.
	if images.is_empty():
		return null

	return {"images": images, "transparency": TresMaterialLoader.parse_transparency(path)}

## The rasterizer discards every texel past the thumbnail's own size, so shrink
## here on the worker (Image.resize is pure CPU, no thread guard). Bilinear, not
## trilinear, trilinear generates mipmaps first which we have no use for.
static func _shrink(image: Image) -> Image:
	var longest := maxi(image.get_width(), image.get_height())
	if longest <= ThumbnailCache.THUMB_SIZE:
		return image

	var scale := float(ThumbnailCache.THUMB_SIZE) / float(longest)
	image.resize(
		maxi(1, int(image.get_width() * scale)),
		maxi(1, int(image.get_height() * scale)),
		Image.INTERPOLATE_BILINEAR
	)
	return image

## Nothing here reconfigures the viewport like sky/fog, the batch can use the
## main one as a slot.
static func reuses_main_viewport() -> bool:
	return true

## Build without capturing, lets the stage render a whole chunk in one frame
## (ThumbnailViewport.capture_batch).
static func build_subject(prepared: Variant, _path: String) -> Node3D:
	return _build(prepared)

static func render_prepared(prepared: Variant, viewport: ThumbnailViewport, _path: String = "") -> Image:
	var subject := _build(prepared)
	if subject == null:
		return null
	return await viewport.capture(subject)

static func _build(prepared: Variant) -> Node3D:
	if prepared == null or not (prepared is Dictionary):
		return null

	var material := StandardMaterial3D.new()
	material.transparency = int(prepared["transparency"])

	var images: Dictionary = prepared["images"]
	for property_name: String in images:
		material.set(property_name, ImageTexture.create_from_image(images[property_name]))
		if ENABLE_FLAGS.has(property_name):
			material.set(ENABLE_FLAGS[property_name], true)

	var mesh := SphereMesh.new()
	mesh.radius = SPHERE_RADIUS
	mesh.height = SPHERE_RADIUS * 2.0
	mesh.rings = SPHERE_RINGS
	mesh.radial_segments = SPHERE_SEGMENTS

	var subject := MeshInstance3D.new()
	subject.mesh = mesh
	subject.material_override = material

	return subject
