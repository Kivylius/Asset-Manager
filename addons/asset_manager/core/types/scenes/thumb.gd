@tool
extends RefCounted

## Thumbnail renderer for scenes (dev/prototype maps). The scene's own lights
## are dropped in favour of the shared viewport's two-light setup, what reads
## as gameplay at full size reads badly at 256px. Scripts never execute.

static func work_kind() -> int:
	return ThumbnailStage.WORK_VIEWPORT

## Loading happens on the main thread. The loader builds ImageTextures and
## compiles Shaders while parsing, both register with the rendering server
## and crash the editor off-thread.
static func prepare(_path: String) -> Variant:
	return null

## Nothing here reconfigures the viewport like sky/fog, the batch can use the
## main one as a slot.
static func reuses_main_viewport() -> bool:
	return true

## Build without capturing, lets the stage render a whole chunk in one frame
## (ThumbnailViewport.capture_batch).
static func build_subject(_prepared: Variant, path: String) -> Node3D:
	var node := TscnSceneLoader.load_external(path, "scenes")
	if node == null:
		return null
	if not (node is Node3D):
		node.free()
		return null
	return node as Node3D

static func render_prepared(_prepared: Variant, viewport: ThumbnailViewport, path: String) -> Image:
	var node := TscnSceneLoader.load_external(path, "scenes")
	if node == null or not (node is Node3D):
		if node != null:
			node.free()
		return null
	return await viewport.capture(node as Node3D)
