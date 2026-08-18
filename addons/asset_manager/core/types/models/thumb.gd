@tool
extends RefCounted

## Thumbnail renderer for models. Same load path as models.gd's preview, then
## hands the node tree to the shared viewport for capture.
## Parsing runs on a worker; only the capture is main-thread. Safe because
## GLTFDocument's only shared state is its document-extension list, mutexed
## (gltf_document.cpp:6965), and embedded-texture creation goes through
## RenderingServer::texture_2d_create (rendering_server_default.h:147), which
## pushes onto the command queue when called off the render thread.
## Worth ~4 seconds on a few hundred models.

static func work_kind() -> int:
	return ThumbnailStage.WORK_VIEWPORT

static func prepare(path: String) -> Variant:
	return _load(path)

## Models only capture plain geometry, nothing here reconfigures the viewport
## like sky/fog, the batch can use the main one as a slot.
static func reuses_main_viewport() -> bool:
	return true

## Already parsed by prepare() on a worker, hands it over so the stage can
## render a whole chunk in one frame (ThumbnailViewport.capture_batch).
static func build_subject(prepared: Variant, path: String) -> Node3D:
	if prepared is Node3D:
		return prepared as Node3D
	# prepare() failed or wasn't run for this one.
	return _load(path)

static func render_prepared(prepared: Variant, viewport: ThumbnailViewport, path: String = "") -> Image:
	var subject: Node3D = prepared as Node3D if prepared is Node3D else _load(path)
	if subject == null:
		return null
	return await viewport.capture(subject)

static func _load(path: String) -> Node3D:
	var state := GLTFState.new()
	state.handle_binary_image_mode = GLTFState.HANDLE_BINARY_IMAGE_MODE_EMBED_AS_UNCOMPRESSED

	var err: int = FAILED
	var node: Node = null

	if path.get_extension().to_lower() == "fbx":
		var fbx := FBXDocument.new()
		err = fbx.append_from_file(path, state)
		if err == OK:
			node = fbx.generate_scene(state)
	else:
		var gltf := GLTFDocument.new()
		err = gltf.append_from_file(path, state)
		if err == OK:
			node = gltf.generate_scene(state)

	if err != OK or node == null:
		return null

	# GLTF hands back ImporterMeshInstance3D, which carries no drawable mesh.
	# Same conversion models.gd's preview does, or the capture comes out empty.
	return _convert_importer_meshes(node) as Node3D

static func _convert_importer_meshes(node: Node) -> Node:
	if not is_instance_valid(node):
		return node

	var result: Node = node

	if node.get_class() == "ImporterMeshInstance3D":
		var mesh_instance := MeshInstance3D.new()
		mesh_instance.name = node.name
		if node is Node3D:
			mesh_instance.transform = (node as Node3D).transform

		var importer_mesh: Variant = node.get("mesh")
		if importer_mesh != null and importer_mesh.has_method("get_mesh"):
			mesh_instance.mesh = importer_mesh.get_mesh()

		for child in node.get_children():
			node.remove_child(child)
			mesh_instance.add_child(child)

		var parent := node.get_parent()
		if parent != null:
			var index := node.get_index()
			parent.remove_child(node)
			parent.add_child(mesh_instance)
			parent.move_child(mesh_instance, index)
		node.free()

		result = mesh_instance

	for child in result.get_children():
		_convert_importer_meshes(child)

	return result
