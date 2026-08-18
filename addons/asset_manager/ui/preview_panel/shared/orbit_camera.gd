@tool
class_name PreviewOrbitCamera
extends RefCounted

## Orbit/pan/zoom for a Camera3D looking at a pivot. Shared by every 3D preview.
## Pitch is stored as an absolute elevation angle rather than an offset from
## the camera's starting transform. These cameras start already tilted down,
## so an offset would make the usable range lopsided: +72° goes past vertical
## and flips the view, -72° only reaches 47° below the model.

const MAX_ELEVATION: float = deg_to_rad(85.0)
const ORBIT_SPEED: float = 0.01
const ZOOM_STEP: float = 0.5
const MIN_RADIUS: float = 0.1

## Scenes are whole maps rather than one object, so a fixed step crawls when
## zoomed out and overshoots up close. Non-zero makes the step a fraction of the
## current distance instead.
var zoom_step_ratio: float = 0.0

var _camera: Camera3D
var _pivot: Node3D

var _is_orbiting: bool = false
var _is_panning: bool = false
var _last_mouse_pos: Vector2 = Vector2.ZERO
var _yaw: float = 0.0
var _elevation: float = 0.0
var _initial_transform: Transform3D
var _radius: float = 0.0

func setup(camera: Camera3D, pivot: Node3D) -> void:
	_camera = camera
	_pivot = pivot

## Whether this preview lets the user pan the pivot. Models, effects and scenes
## do; materials and shaders show a single centred subject and don't.
var pan_enabled: bool = true

func handle_input(event: InputEvent) -> bool:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			_is_orbiting = event.pressed
			_last_mouse_pos = event.position
		elif pan_enabled and (event.button_index == MOUSE_BUTTON_RIGHT or event.button_index == MOUSE_BUTTON_MIDDLE):
			_is_panning = event.pressed
			_last_mouse_pos = event.position
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			_zoom(-_zoom_step())
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			_zoom(_zoom_step())
		else:
			return false
		return true

	if event is InputEventMouseMotion and (_is_orbiting or _is_panning):
		var motion := event as InputEventMouseMotion
		var delta: Vector2 = motion.position - _last_mouse_pos
		_last_mouse_pos = motion.position

		if _is_orbiting:
			_orbit(delta)
		else:
			_pan(delta)
		return true

	return false

func _orbit(delta: Vector2) -> void:
	if _initial_transform == Transform3D():
		snap_to_look_at()

	_yaw -= delta.x * ORBIT_SPEED
	_elevation = clampf(_elevation + delta.y * ORBIT_SPEED, -MAX_ELEVATION, MAX_ELEVATION)
	_apply()

## Rebuilds the camera position from yaw and elevation directly, rather than
## rotating the starting direction about a cross-product axis. That axis
## degenerates as the view approaches the pole, and normalized() returns
## either 1 or 0, so a near-zero guard can't catch the flip.
func _apply() -> void:
	var target: Vector3 = _pivot.global_position
	var horizontal := cos(_elevation)
	var offset := Vector3(
		sin(_yaw) * horizontal,
		sin(_elevation),
		cos(_yaw) * horizontal
	)
	_camera.global_position = target + offset * _radius
	_camera.look_at(target, Vector3.UP)

func _pan(delta: Vector2) -> void:
	var right := _camera.global_transform.basis.x
	var up := _camera.global_transform.basis.y
	var dist := _camera.global_position.distance_to(_pivot.global_position)
	var pan_speed := maxf(0.01, dist * 0.003)

	_pivot.global_position += right * delta.x * pan_speed
	_pivot.global_position -= up * delta.y * pan_speed

func _zoom_step() -> float:
	if zoom_step_ratio <= 0.0:
		return ZOOM_STEP
	var dist := _camera.global_position.distance_to(_pivot.global_position)
	return maxf(ZOOM_STEP, dist * zoom_step_ratio)

func _zoom(amount: float) -> void:
	_camera.global_position += _camera.global_transform.basis.z * amount
	_radius = maxf(MIN_RADIUS, _camera.global_position.distance_to(_pivot.global_position))

## Reads the starting camera as yaw + elevation so orbiting continues from where
## the scene author placed it rather than snapping to a fixed angle.
func snap_to_look_at() -> void:
	if _initial_transform == Transform3D():
		_initial_transform = _camera.transform

	_camera.global_position = _initial_transform.origin
	_camera.look_at(_pivot.global_position, Vector3.UP)
	_radius = _camera.global_position.distance_to(_pivot.global_position)

	var dir: Vector3 = (_camera.global_position - _pivot.global_position).normalized()
	_elevation = asin(clampf(dir.y, -1.0, 1.0))
	_yaw = atan2(dir.x, dir.z)

func reset_views() -> void:
	_pivot.transform.basis = Basis.IDENTITY
	_pivot.position = Vector3.ZERO
	if _initial_transform == Transform3D():
		_initial_transform = _camera.transform
	_camera.transform = _initial_transform
	snap_to_look_at()

func reset_origin() -> void:
	_pivot.position = Vector3.ZERO
	if _initial_transform != Transform3D():
		snap_to_look_at()

func reset_zoom() -> void:
	if _initial_transform == Transform3D():
		return
	_radius = _initial_transform.origin.distance_to(_pivot.global_position)
	_apply()
