@tool
extends RefCounted

## Thumbnail renderer for shaders. What gets rendered depends on the file's
## declared shader_type: spatial wants a mesh, canvas_item wants a flat rect,
## particles want an emitter.
##   spatial      sphere
##   canvas_item  flat 2D rect (2D viewport)
##   particles    emitter driven by the shader as its process material
##   sky          the viewport's environment background
##   fog          FogVolume (needs volumetric fog, Forward+ only)
## texture_blit is the sixth Shader.Mode and not rendered here.
## Main thread only, building a Shader compiles it (rendering server).

static var subtype: Dictionary = {}

static func take_subtype() -> Dictionary:
	var collected := subtype.duplicate()
	subtype.clear()
	return collected

const SPHERE_RADIUS: float = 0.5
const SPHERE_RINGS: int = 32
const SPHERE_SEGMENTS: int = 64

const CANVAS_RECT_SIZE: float = 220.0

## Particle shaders need visible particles by capture time, same as effects.
const PARTICLE_WARMUP: float = 1.0
const PARTICLE_AMOUNT: int = 64
const PARTICLE_LIFETIME: float = 2.0

static func work_kind() -> int:
	return ThumbnailStage.WORK_VIEWPORT

static func prepare(_path: String) -> Variant:
	return null

## Only spatial batches, the others fall back to render_prepared below.
static func build_subject(_prepared: Variant, path: String) -> Node3D:
	var material := _material_for(path)
	if material == null:
		return null

	var mode := material.shader.get_mode()
	var ids := AssetTypes.get_subtype_ids("shaders")
	if mode < ids.size():
		subtype[path] = [ids[mode]]

	# A particle emitter has emitted nothing on the frame it's added, a batched
	# capture renders that same frame and catches an empty tile. It needs its
	# own capture, where the frames it waits through let the emitter actually run.
	if mode == Shader.MODE_SPATIAL:
		return _spatial_subject(material)

	return null

static func _material_for(path: String) -> ShaderMaterial:
	var source := FileAccess.get_file_as_string(path)
	if source.is_empty():
		return null

	var shader := Shader.new()
	shader.code = TscnSceneLoader.resolve_shader_includes(source, path)

	var material := ShaderMaterial.new()
	material.shader = shader
	return material

## Compiles the shader and builds a subject for the mode.
static func render_prepared(_prepared: Variant, viewport: ThumbnailViewport, path: String) -> Image:
	var source := FileAccess.get_file_as_string(path)
	if source.is_empty():
		return null

	var shader := Shader.new()
	# Includes resolve against a resource path the in-memory shader doesn't
	# have, substitute them first.
	shader.code = TscnSceneLoader.resolve_shader_includes(source, path)

	var material := ShaderMaterial.new()
	material.shader = shader

	match shader.get_mode():
		Shader.MODE_SPATIAL:
			return await viewport.capture(_spatial_subject(material))
		Shader.MODE_PARTICLES:
			return await viewport.capture(_particles_subject(material))
		Shader.MODE_CANVAS_ITEM:
			return await viewport.capture_2d(_canvas_subject(material), ThumbnailCache.THUMB_SIZE)
		Shader.MODE_SKY:
			return await viewport.capture_sky(material)
		Shader.MODE_FOG:
			if not _is_forward_plus():
				return null
			return await viewport.capture_fog(_fog_subject(material))

	return null

## Volumetric fog is Forward+ only. Same check the preview makes before showing
## its "needs Forward+" message.
static func _is_forward_plus() -> bool:
	return ProjectSettings.get_setting("rendering/renderer/rendering_method", "") == "forward_plus"

static func _fog_subject(material: ShaderMaterial) -> FogVolume:
	var subject := FogVolume.new()
	subject.shape = RenderingServer.FOG_VOLUME_SHAPE_BOX
	subject.size = Vector3(4, 4, 4)
	subject.material = material
	return subject

static func _spatial_subject(material: ShaderMaterial) -> MeshInstance3D:
	var mesh := SphereMesh.new()
	mesh.radius = SPHERE_RADIUS
	mesh.height = SPHERE_RADIUS * 2.0
	mesh.rings = SPHERE_RINGS
	mesh.radial_segments = SPHERE_SEGMENTS

	var subject := MeshInstance3D.new()
	subject.mesh = mesh
	subject.material_override = material
	return subject

## Shader is the process material here, draw pass needs its own plain material.
## Without vertex colours the particles render untinted.
static func _particles_subject(material: ShaderMaterial) -> GPUParticles3D:
	var draw_material := StandardMaterial3D.new()
	draw_material.vertex_color_use_as_albedo = true
	draw_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA

	var draw_mesh := SphereMesh.new()
	draw_mesh.radius = 0.05
	draw_mesh.height = 0.1
	draw_mesh.material = draw_material

	var subject := GPUParticles3D.new()
	subject.draw_pass_1 = draw_mesh
	subject.process_material = material
	subject.amount = PARTICLE_AMOUNT
	subject.lifetime = PARTICLE_LIFETIME
	subject.preprocess = PARTICLE_WARMUP
	# A shader-driven emitter reports no bounds of its own, give it one or the
	# capture frames as zero-size and gets skipped.
	subject.visibility_aabb = AABB(Vector3.ONE * -2.0, Vector3.ONE * 4.0)
	subject.emitting = true
	return subject

static func _canvas_subject(material: ShaderMaterial) -> Node2D:
	var rect := ColorRect.new()
	rect.material = material
	rect.size = Vector2(CANVAS_RECT_SIZE, CANVAS_RECT_SIZE)
	rect.position = Vector2(-CANVAS_RECT_SIZE, -CANVAS_RECT_SIZE) * 0.5

	# capture_2d works with Node2D, a bare Control isn't one.
	var holder := Node2D.new()
	holder.add_child(rect)
	return holder
