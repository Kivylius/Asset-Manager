@tool
class_name PreviewReferenceGrid
extends RefCounted

## The ground-plane grid under a 3D preview subject. Shared by models, effects
## and scenes.

const SIZE: float = 10.0
const DIVISIONS: int = 20
const COLOR: Color = Color(1, 1, 1, 0.15)

var _mesh_instance: MeshInstance3D
var _enabled: bool = true

## Builds the grid and parents it to the pivot, so panning the subject moves the
## grid with it.
func setup(pivot: Node3D) -> void:
	_mesh_instance = MeshInstance3D.new()
	_mesh_instance.mesh = _build_mesh()
	pivot.add_child(_mesh_instance)

func set_enabled(enabled: bool) -> void:
	_enabled = enabled
	if _mesh_instance:
		_mesh_instance.visible = enabled

func is_enabled() -> bool:
	return _enabled

## Separate from set_enabled: hiding the grid with the rest of the preview must
## not overwrite the user's preference.
func set_visible(visible: bool) -> void:
	if _mesh_instance:
		_mesh_instance.visible = visible and _enabled

func _build_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_LINES)
	st.set_color(COLOR)

	var half := SIZE / 2.0
	var step := SIZE / DIVISIONS

	for i in range(DIVISIONS + 1):
		var offset := -half + i * step
		st.add_vertex(Vector3(offset, 0, -half))
		st.add_vertex(Vector3(offset, 0, half))
		st.add_vertex(Vector3(-half, 0, offset))
		st.add_vertex(Vector3(half, 0, offset))

	var mesh := st.commit()

	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mesh.surface_set_material(0, mat)

	return mesh
