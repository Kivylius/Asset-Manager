@tool
class_name ObjMeshLoader
extends RefCounted
## Builds an ArrayMesh from a Wavefront .obj file.
## Godot only reads .obj at import time (ResourceImporterOBJ, an editor
## class), so there's no runtime loader for a file outside res://.
## Supports the subset real exporters emit: v/vt/vn, f with any of the
## 1, 1/2, 1//3 and 1/2/3 index forms, negative (relative) indices, polygons
## of any size (fan-triangulated), and per-object/group splitting into
## separate surfaces. Materials are ignored, .mtl describes them and the
## scenes referencing these meshes assign their own material anyway.

static func load_external(path: String) -> ArrayMesh:
	var text := FileAccess.get_file_as_string(path)
	if text.is_empty():
		push_warning("AssetManager: could not read " + path)
		return null

	var positions: PackedVector3Array = []
	var uvs: PackedVector2Array = []
	var normals: PackedVector3Array = []

	var mesh := ArrayMesh.new()
	var surface := SurfaceTool.new()
	var surface_started := false
	var surface_has_faces := false

	for raw_line in text.split("\n"):
		var line := raw_line.strip_edges()
		if line.is_empty() or line.begins_with("#"):
			continue

		var parts := line.split(" ", false)
		if parts.size() < 2:
			continue

		match parts[0]:
			"v":
				positions.append(_to_vector3(parts))
			"vt":
				# .obj's V axis points up, Godot's points down.
				uvs.append(Vector2(float(parts[1]), 1.0 - float(parts[2]) if parts.size() > 2 else 0.0))
			"vn":
				normals.append(_to_vector3(parts))
			"o", "g":
				# A new object/group closes the current surface, so each one
				# keeps its own material slot instead of merging into a blob.
				if surface_has_faces:
					_commit_surface(surface, mesh)
					surface_started = false
					surface_has_faces = false
			"f":
				if not surface_started:
					surface.begin(Mesh.PRIMITIVE_TRIANGLES)
					surface_started = true
				_add_face(surface, parts, positions, uvs, normals)
				surface_has_faces = true

	if surface_has_faces:
		_commit_surface(surface, mesh)

	if mesh.get_surface_count() == 0:
		push_warning("AssetManager: no geometry in " + path)
		return null

	return mesh

static func _commit_surface(surface: SurfaceTool, mesh: ArrayMesh) -> void:
	surface.index()
	var arrays := surface.commit_to_arrays()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	surface.clear()

## Polygons are fan-triangulated (v0,v1,v2 / v0,v2,v3 / ...), correct for the
## convex faces exporters produce, and quads are by far the common case.
static func _add_face(surface: SurfaceTool, parts: PackedStringArray, positions: PackedVector3Array, uvs: PackedVector2Array, normals: PackedVector3Array) -> void:
	var corners := parts.slice(1)
	for i in range(1, corners.size() - 1):
		for corner in [corners[0], corners[i], corners[i + 1]]:
			_add_vertex(surface, corner, positions, uvs, normals)

static func _add_vertex(surface: SurfaceTool, corner: String, positions: PackedVector3Array, uvs: PackedVector2Array, normals: PackedVector3Array) -> void:
	var indices := corner.split("/")

	var uv_index := _resolve_index(indices[1] if indices.size() > 1 else "", uvs.size())
	if uv_index >= 0:
		surface.set_uv(uvs[uv_index])

	var normal_index := _resolve_index(indices[2] if indices.size() > 2 else "", normals.size())
	if normal_index >= 0:
		surface.set_normal(normals[normal_index])

	# Position last: set_uv/set_normal describe the vertex that add_vertex emits.
	var position_index := _resolve_index(indices[0], positions.size())
	if position_index >= 0:
		surface.add_vertex(positions[position_index])

## .obj indices are 1-based, and negative values count backwards from the
## most recently declared element rather than from the start.
static func _resolve_index(token: String, count: int) -> int:
	if token.is_empty() or not token.is_valid_int():
		return -1
	var index := token.to_int()
	if index < 0:
		index = count + index
	else:
		index -= 1
	return index if index >= 0 and index < count else -1

static func _to_vector3(parts: PackedStringArray) -> Vector3:
	return Vector3(
		float(parts[1]),
		float(parts[2]) if parts.size() > 2 else 0.0,
		float(parts[3]) if parts.size() > 3 else 0.0,
	)
