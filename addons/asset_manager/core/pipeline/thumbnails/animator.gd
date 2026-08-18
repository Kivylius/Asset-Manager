@tool
class_name ThumbnailAnimator
extends RefCounted

## Cycles the frame on animated thumbnails (vertical strips stored in one
## texture) so effect tiles loop in the grid like they do in the preview.

const FRAME_SECONDS: float = 1.0 / 15.0
const MAX_CATCH_UP_FRAMES: int = 1

var _playing: Dictionary = {}
var _grid: ItemList
var _timer: Timer
var _frame: int = 0
var _last_usec: int = 0

func setup(grid: ItemList, host: Node) -> void:
	_grid = grid
	if is_instance_valid(_timer):
		return
	_timer = Timer.new()
	_timer.wait_time = FRAME_SECONDS
	_timer.timeout.connect(_advance)
	host.add_child(_timer)

func teardown() -> void:
	if is_instance_valid(_timer):
		_timer.queue_free()
	_timer = null
	_playing.clear()

static func is_animated(texture: Texture2D) -> bool:
	return texture != null and texture.get_height() > texture.get_width()

static func frame_count(texture: Texture2D) -> int:
	return maxi(1, texture.get_height() / maxi(1, texture.get_width()))

func register(item_index: int, texture: Texture2D) -> Texture2D:
	if not is_animated(texture):
		return texture

	var size: int = texture.get_width()
	var atlas := AtlasTexture.new()
	atlas.atlas = texture
	atlas.region = Rect2(0, 0, size, size)
	_playing[item_index] = {
		"atlas": atlas,
		"size": float(size),
		"frames": frame_count(texture),
	}
	return atlas

func clear() -> void:
	_playing.clear()
	_frame = 0
	if is_instance_valid(_timer):
		_timer.stop()

func start() -> void:
	if _playing.is_empty() or not is_instance_valid(_timer):
		return
	_last_usec = Time.get_ticks_usec()
	_timer.start()

func _advance() -> void:
	if not is_instance_valid(_grid) or _playing.is_empty():
		return

	var now := Time.get_ticks_usec()
	var elapsed := float(now - _last_usec) / 1000000.0
	var steps := int(elapsed / FRAME_SECONDS)
	if steps < 1:
		return
	_last_usec = now
	_frame += mini(steps, MAX_CATCH_UP_FRAMES)

	var count := _grid.get_item_count()
	for item_index: int in _playing:
		if item_index >= count:
			continue
		var entry: Dictionary = _playing[item_index]
		var atlas: AtlasTexture = entry["atlas"]
		var size: float = entry["size"]
		atlas.region = Rect2(0, size * float(_frame % int(entry["frames"])), size, size)
		_grid.set_item_icon(item_index, atlas)
