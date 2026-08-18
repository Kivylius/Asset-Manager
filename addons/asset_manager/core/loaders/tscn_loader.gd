@tool
class_name TscnSceneLoader
extends RefCounted

## Loads a .tscn from an absolute filesystem path outside any res:// project.
## Mirrors Godot's own ResourceLoaderText (scene/resources/resource_format_text.cpp):
## generic ClassDB.instantiate(type) + obj.set(property, value) per resource/node,
## same as the engine does, not a hand-rolled per-type interpreter.
## ext_resource/sub_resource path= that starts with the pack's fake "res://<Root>/"
## prefix is resolved against the real folder the .tscn actually sits in on disk.

## Which workspace bucket a scene lives under. Passed in rather than hardcoded so
## scenes/ and effects/ share one loader, find_pack_root climbs until it sees
## this folder name.
const DEFAULT_BUCKET: String = "effects"

## Godot's text resource formats, same grammar as .tscn, so _load_resource_file
## can build any of them regardless of what the ext_resource claims the type is.
const TEXT_RESOURCE_EXTENSIONS: PackedStringArray = ["tres", "res"]

## Guard against a shader include cycle, which would otherwise recurse forever.
const MAX_INCLUDE_DEPTH: int = 8

## Applies its own deferred writes before returning, but only on the main
## thread. Off-thread the batch is left for the caller to replay later, because
## some writes compile a shader as a side effect and that is not thread-safe:
##   obj.set("process_material", …)
##     -> GPUParticles3D::set_process_material
##     -> ParticleProcessMaterial::_update_shader
##     -> ShaderLanguage::compile   <- crashes when two threads are in it
## Node.is_accessible_from_caller_thread() permits the write (the node isn't in a
## tree yet), so nothing warns, the shader compiler underneath simply isn't
## guarded. Confirmed from a dev build's symbolicated stack.
static func load_external(path: String, bucket: String = DEFAULT_BUCKET) -> Node:
	var batch := _begin_batch()
	var node := _load_external_inner(path, bucket)
	_end_batch(batch)
	apply_deferred_writes(batch)
	return node

static func _load_external_inner(path: String, bucket: String = DEFAULT_BUCKET) -> Node:

	var text := FileAccess.get_file_as_string(path)
	if text.is_empty():
		push_error("AssetManager: could not read " + path)
		return null

	var base_dir := path.get_base_dir()
	var pack_root := find_pack_root(base_dir, bucket)

	var ext_resources: Dictionary = {}   # id -> resolved Resource
	var sub_resources: Dictionary = {}   # id -> resolved Resource
	var root: Node = null
	var node_by_path: Dictionary = {}    # "." / "Child" / "Child/Grand" -> Node

	var lines := text.split("\n")
	var i := 0
	while i < lines.size():
		var line: String = lines[i].strip_edges()

		if line.begins_with("[ext_resource"):
			var fields := _parse_tag_fields(line)
			var id: String = fields.get("id", "")
			var res := _load_ext_resource(fields, base_dir, pack_root)
			if res != null:
				ext_resources[id] = res

		elif line.begins_with("[sub_resource"):
			var fields := _parse_tag_fields(line)
			var type: String = fields.get("type", "")
			var id: String = fields.get("id", "")
			var obj: Object = ClassDB.instantiate(type) if ClassDB.class_exists(type) else null
			if obj == null:
				i = _skip_block(lines, i + 1)
				continue
			i = _apply_properties(lines, i + 1, obj, ext_resources, sub_resources) - 1
			sub_resources[id] = obj

		el		if line.begins_with("[node"):
			var fields := _parse_tag_fields(line)
			var type: String = fields.get("type", "")
			var name: String = fields.get("name", "")
			var parent_path: String = fields.get("parent", "")
			# A node built from another scene has no type= at all, just
			# instance=ExtResource("id"), packs that compose effects out of
			# sub-scenes (showcase/demo scenes especially) are made almost
			# entirely of these, and skipping them leaves an empty root.
			var node: Node = null
			if fields.has("instance"):
				node = _instantiate_scene_ref(fields["instance"], ext_resources)
			elif ClassDB.class_exists(type):
				node = ClassDB.instantiate(type)

			if node == null:
				i = _skip_block(lines, i + 1)
				continue
			node.name = name

			if root == null:
				root = node
				node_by_path["."] = root
			else:
				var parent: Node = node_by_path.get(parent_path, root)
				parent.add_child(node)
				var full_path: String = name if parent_path == "." else parent_path + "/" + name
				node_by_path[full_path] = node

			i = _apply_properties(lines, i + 1, node, ext_resources, sub_resources) - 1

		i += 1

	return root

## A pack is whatever folder sits directly inside the workspace's effects/
## bucket, a structural fact of the workspace layout, so it holds regardless of
## which folders a pack happens to use internally.
## Sniffing for a known subfolder name instead (assets/, source_files/) breaks on
## any pack that uses neither: the search runs off the top of the pack and keeps
## climbing to the workspace root, which is itself literally .../assets/, so
## every path then resolves against the wrong folder.
## Keeps walking to the LAST match rather than returning the first: a pack with
## its own effects/ subfolder (GodotFireVFX, GodotImpactVFX) would otherwise
## match that one and treat a folder deep inside the pack as its root. The
## workspace bucket is always the outermost one on the path.
static func find_pack_root(start_dir: String, bucket: String = DEFAULT_BUCKET) -> String:
	var dir := start_dir
	var found := ""
	while dir != "" and dir != "/":
		var parent := dir.get_base_dir()
		if parent.get_file() == bucket:
			found = dir
		if parent == dir:
			break
		dir = parent
	return found if not found.is_empty() else start_dir

static func _set_owner_recursive(node: Node, owner: Node) -> void:
	for child in node.get_children():
		if child != owner:
			child.owner = owner
		_set_owner_recursive(child, owner)

## Builds a node from an `instance=ExtResource("id")` reference. The referenced
## PackedScene is already loaded by the ext_resource pass above (via
## _load_resource_file), so this only has to look it up and instantiate it.
static func _instantiate_scene_ref(raw_ref: String, ext_resources: Dictionary) -> Node:
	var regex := RegEx.new()
	regex.compile('ExtResource\\("([^"]+)"\\)')
	var m := regex.search(raw_ref)
	if m == null:
		return null

	var resource: Variant = ext_resources.get(m.get_string(1))
	if resource is PackedScene:
		return (resource as PackedScene).instantiate()

	return null

static func _parse_tag_fields(tag_line: String) -> Dictionary:
	var fields: Dictionary = {}
	var inner := tag_line.trim_prefix("[").trim_suffix("]")
	var regex := RegEx.new()
	regex.compile('(\\w+)="([^"]*)"|(\\w+)=([^\\s\\]]+)')
	for m in regex.search_all(inner):
		if m.get_string(1) != "":
			fields[m.get_string(1)] = m.get_string(2)
		else:
			fields[m.get_string(3)] = m.get_string(4)
	return fields

## Resources resolved during the current load_external, keyed by real path.
## A pack's scenes share textures and sub-scenes heavily, and nested scenes each
## re-resolve their own, measured at 384 texture loads for 107 distinct files.
## Reusing them is safe because nothing here mutates a loaded resource; the
## exception is PackedScene, which is instantiated per use rather than shared.
static var _resource_cache: Dictionary = {}
## Paths another thread is currently loading, so we wait instead of duplicating.
static var _in_flight: Dictionary = {}
## The cache is now written from several loader threads at once.
static var _cache_mutex: Mutex = Mutex.new()

## ResourceLoader.load() is the one thing here that isn't ours, it pulls in
## Godot's whole import/UID subsystem, which is not written for arbitrary
## threads. Everything else in this file builds objects directly.
## False keeps ResourceLoader.load() on the main thread only, preload_binaries()
## fills the cache first, so a worker finds what it needs already loaded.
const ALLOW_THREADED_RESOURCE_LOAD: bool = false

## Skip every ext_resource when off the main thread, so a threaded load builds
## nodes and nothing else. Debug aid for narrowing down what's unsafe off-thread.
const SKIP_EXT_RESOURCES_OFF_THREAD: bool = false

## Property writes collected during an off-thread load, replayed by
## apply_deferred_writes() once back on the main thread.
## thread_local in spirit, each worker loads one scene at a time, so a plain
## static would have them trampling each other. Keyed by thread id instead.
## Serialises the writes that aren't safe concurrently, see _apply_properties.
static var _mesh_mutex: Mutex = Mutex.new()

## Properties whose setters do something thread-unsafe underneath. See the note
## in _apply_properties for what each one does and why.
const SERIALISED_PROPERTIES: PackedStringArray = [
	"process_material",
	"material",
	"material_override",
	"shader",
	"_surfaces",
]

static var _deferred_by_thread: Dictionary = {}
static var _deferred_mutex: Mutex = Mutex.new()

## Which batch the calling thread is currently filling. A nested load keeps using
## its parent's batch, so a whole scene tree replays as one unit.
static var _batch_by_thread: Dictionary = {}
## batch -> the batch that was open when it started, restored when it ends
static var _batch_parent: Dictionary = {}
static var _next_batch_id: int = 0

## The list for the batch this thread is filling, created on first use.
static var _deferred_writes: Array:
	get:
		var tid := OS.get_thread_caller_id()
		_deferred_mutex.lock()
		var batch: int = int(_batch_by_thread.get(tid, -1))
		if batch == -1:
			_deferred_mutex.unlock()
			return []
		if not _deferred_by_thread.has(batch):
			_deferred_by_thread[batch] = []
		var list: Array = _deferred_by_thread[batch]
		_deferred_mutex.unlock()
		return list

## Claims a fresh batch for this thread, remembering whichever was open so it
## can be restored on _end_batch.
static func _begin_batch() -> int:
	var tid := OS.get_thread_caller_id()
	_deferred_mutex.lock()
	var previous: int = int(_batch_by_thread.get(tid, -1))
	_next_batch_id += 1
	var batch := _next_batch_id
	_batch_by_thread[tid] = batch
	_batch_parent[batch] = previous
	_deferred_mutex.unlock()
	return batch

static func _end_batch(batch: int) -> void:
	if batch == -1:
		return
	_deferred_mutex.lock()
	var previous: int = int(_batch_parent.get(batch, -1))
	_batch_parent.erase(batch)
	if previous == -1:
		_batch_by_thread.erase(OS.get_thread_caller_id())
	else:
		_batch_by_thread[OS.get_thread_caller_id()] = previous
	_deferred_mutex.unlock()

## Main thread only. Applies everything one load collected, in the order the
## file declared it, then discards that batch.
## Keyed per load, not per thread: a worker handles many effects in a row, so
## a thread-keyed list would mix one scene's writes into the next.
static func apply_deferred_writes(batch_id: int) -> void:
	_deferred_mutex.lock()
	var list: Array = _deferred_by_thread.get(batch_id, [])
	_deferred_by_thread.erase(batch_id)
	_deferred_mutex.unlock()

	for write in list:
		# Check by id, not by touching the reference, reading a freed object
		# out of the array is itself the error we're guarding against.
		if not is_instance_id_valid(write[3]):
			continue
		var obj: Object = write[0]
		obj.set(write[1], write[2])

## Sharing one Resource between threads is safe to *refcount* (SafeRefCount is
## atomic) but not safe to *use*, two threads packing and instantiating the same
## PackedScene will corrupt it.
const ALLOW_RESOURCE_CACHE: bool = true

static func _can_use_resource_loader() -> bool:
	return ALLOW_THREADED_RESOURCE_LOAD or Thread.is_main_thread()

## Binary resources (.material/.mesh/.res) have to go through ResourceLoader,
## which is roughly 70x slower called off the main thread, 73ms a call versus
## well under one. So they're loaded up front, on the main thread, and the
## threaded parse reads them from here instead of calling load() itself.
## Call preload_binaries(path) on the main thread before handing a file to a
## worker. Scenes not preloaded still work; they just pay the slow path.
static func preload_binaries(path: String, bucket: String = DEFAULT_BUCKET, seen: Dictionary = {}) -> void:
	if seen.has(path):
		return
	seen[path] = true

	var text := FileAccess.get_file_as_string(path)
	if text.is_empty():
		return

	var base_dir := path.get_base_dir()
	var pack_root := find_pack_root(base_dir, bucket)

	var regex := RegEx.new()
	regex.compile('\\[ext_resource[^\\]]*path="([^"]+)"')
	for m in regex.search_all(text):
		var real_path := resolve_pack_path(m.get_string(1), base_dir, pack_root)
		if real_path.is_empty() or not FileAccess.file_exists(real_path):
			continue

		# Nested scenes bring their own binaries, and they're parsed on the
		# worker too, so walk into them here rather than discovering them late.
		if real_path.get_extension().to_lower() == "tscn":
			preload_binaries(real_path, bucket, seen)
			continue

		if not BinaryResource.is_binary(real_path):
			continue

		_cache_mutex.lock()
		var already := _resource_cache.has(real_path)
		_cache_mutex.unlock()
		if already:
			continue

		var loaded: Resource = load(real_path)
		if loaded != null:
			_cache_mutex.lock()
			_resource_cache[real_path] = loaded
			_cache_mutex.unlock()

## Lives for a whole import rather than one effect: packs share textures across
## their scenes far more than within any single one, so a per-effect cache only
## caught a fraction of the reuse. The stage clears it when the run finishes,
## nothing on disk changes mid-import, so entries can't go stale during one.
static func clear_cache() -> void:
	_cache_mutex.lock()
	_resource_cache.clear()
	_in_flight.clear()
	_cache_mutex.unlock()

static func _load_ext_resource(fields: Dictionary, base_dir: String, pack_root: String) -> Resource:
	var type: String = fields.get("type", "unknown")

	var cache_key := resolve_pack_path(String(fields.get("path", "")), base_dir, pack_root) if ALLOW_RESOURCE_CACHE else ""

	# A cached PackedScene gets instantiate()d per use, and two threads doing that
	# to the same one at once is the sharing this cache is otherwise careful to
	# avoid. Nested scenes reload instead, they're expensive, but correct.
	if String(fields.get("type", "")) == "PackedScene":
		cache_key = ""

	# Threads that want the same file wait for whichever got there first, rather
	# than all loading it themselves. Without this the cache only helps once a
	# load has already finished, measured 149 loads of 22 distinct files.
	if not cache_key.is_empty():
		while true:
			_cache_mutex.lock()
			if _resource_cache.has(cache_key):
				var cached: Variant = _resource_cache[cache_key]
				_cache_mutex.unlock()
				return cached
			if not _in_flight.has(cache_key):
				_in_flight[cache_key] = true
				_cache_mutex.unlock()
				break
			_cache_mutex.unlock()
			OS.delay_msec(1)

	# Not locked here: _load_ext_resource_inner recurses into nested scenes, whose
	# property writes take _mesh_mutex, taking it here too would have a thread
	# waiting on a lock it already holds. The writes inside are what's guarded.
	var result := _load_ext_resource_inner(fields, base_dir, pack_root)

	if not cache_key.is_empty():
		_cache_mutex.lock()
		if result != null:
			_resource_cache[cache_key] = result
		_in_flight.erase(cache_key)
		_cache_mutex.unlock()

	return result

static func _load_ext_resource_inner(fields: Dictionary, base_dir: String, pack_root: String) -> Resource:
	if SKIP_EXT_RESOURCES_OFF_THREAD and not Thread.is_main_thread():
		return null

	var type: String = fields.get("type", "")
	var raw_path: String = fields.get("path", "")
	var real_path := resolve_pack_path(raw_path, base_dir, pack_root)
	if real_path.is_empty() or not FileAccess.file_exists(real_path):
		push_warning("AssetManager: missing ext_resource (" + type + "): " + raw_path)
		return null

	match type:
		"Texture2D":
			# A Texture2D isn't necessarily an image file, procedural ones
			# (NoiseTexture2D, GradientTexture2D) are text resources describing
			# how to generate the pixels, which Image.load_from_file can't read
			# (ERR_FILE_UNRECOGNIZED) but the generic .tres path builds fine.
			if real_path.get_extension().to_lower() in TEXT_RESOURCE_EXTENSIONS:
				if BinaryResource.is_binary(real_path):
					if not _can_use_resource_loader():
						return null
					var loaded_tex := load(real_path)
					return loaded_tex
				return _load_resource_file(real_path, pack_root)
			var img := Image.load_from_file(real_path)
			return ImageTexture.create_from_image(img) if img else null
		"Shader":
			# A Shader ext_resource isn't always raw .gdshader source, a
			# VisualShader (node graph) is a text resource that extends Shader,
			# and feeding its .tres text to shader.code would just fail to compile.
			if real_path.get_extension().to_lower() in TEXT_RESOURCE_EXTENSIONS:
				return _load_resource_file(real_path, pack_root)
			var shader := Shader.new()
			shader.code = resolve_shader_includes(FileAccess.get_file_as_string(real_path), real_path, pack_root)
			return shader
		"Script":
			push_warning("AssetManager: skipping script (not executed in preview): " + real_path)
			return null
		"PackedScene":
			# load_external applies its own writes before returning, which matters
			# here: this tree is packed and freed immediately, so anything left
			# deferred would point at freed nodes, and pack() would capture the
			# scene before its properties were set.
			var nested := load_external(real_path)
			if nested == null:
				return null

			# pack() only keeps descendants owned by the root (packed_scene.cpp
			# skips anything else), and nothing sets owner while parsing, so
			# without this the nested scene packs down to a bare root node.
			_set_owner_recursive(nested, nested)
			var packed := PackedScene.new()
			packed.pack(nested)
			nested.queue_free()
			return packed
		"Environment", "Resource", "ArrayMesh", "Material":
			# .obj is a Wavefront file, not a Godot resource, the engine only
			# reads it through an editor-side importer, so parse it ourselves.
			if real_path.get_extension().to_lower() == "obj":
				return ObjMeshLoader.load_external(real_path)
			# These types get saved as either plain-text .tres (readable, same
			# grammar as .tscn) or Godot's compressed binary format (RSCC magic
			# bytes), only the text form can be hand-parsed; binary has no
			# decoder exposed to GDScript and can't go through load() either
			# (requires the file to be import-registered in an open project).
			if BinaryResource.is_binary(real_path):
				if not _can_use_resource_loader():
					return null
				var direct: Resource = load(real_path)
				if direct == null:
					push_warning("AssetManager: binary resource not supported: " + real_path)
				return direct
			return _load_resource_file(real_path, pack_root)
		"AudioStream":
			return _load_audio_file(real_path)
		_:
			push_warning("AssetManager: unsupported ext_resource type: " + type)
			return null

## Substitutes #include directives with the file they point at, before the code
## reaches Shader.set_code().
## Godot's own preprocessor already handles #include, but it resolves relative to
## the Shader's resource path (scene/resources/shader.cpp), and a Shader built
## with Shader.new() has none, so it silently fails and the raw '#' reaches the
## tokenizer ("Unknown character #35"). The include paths are baked absolutes
## like every other path in these packs (often naming a *different* pack the
## author shipped alongside this one), so they get the same resolve_pack_path
## treatment rather than being trusted as written.
static func resolve_shader_includes(code: String, shader_path: String, pack_root: String = "", depth: int = 0) -> String:
	if depth > MAX_INCLUDE_DEPTH:
		push_warning("AssetManager: shader include nested too deeply: " + shader_path)
		return code

	# a standalone shader (shaders/ bucket) has no pack, resolve baked absolute
	# includes against its own folder instead, which is as far up as we can trust
	var search_root := pack_root if not pack_root.is_empty() else shader_path.get_base_dir()

	var regex := RegEx.new()
	regex.compile('#include\\s+"([^"]+)"')

	var out := code
	for m in regex.search_all(code):
		var raw_path: String = m.get_string(1)
		var include_path := resolve_pack_path(raw_path, shader_path.get_base_dir(), search_root)
		if include_path.is_empty() or not FileAccess.file_exists(include_path):
			push_warning("AssetManager: missing shader include: " + raw_path)
			out = out.replace(m.get_string(0), "")
			continue

		var included := FileAccess.get_file_as_string(include_path)
		out = out.replace(m.get_string(0), resolve_shader_includes(included, include_path, pack_root, depth + 1))

	return out

## Standalone text resource files ([gd_resource type="X"] header) share the same
## ext_resource/sub_resource grammar as .tscn, reuse the same block-walking
## engine, just build the single top-level resource instead of a node tree.
static func _load_resource_file(real_path: String, pack_root: String) -> Resource:
	var text := FileAccess.get_file_as_string(real_path)
	if text.is_empty():
		return null

	var header_match := RegEx.new()
	header_match.compile('type="([^"]+)"')
	var m := header_match.search(text.split("\n")[0])
	if not m:
		push_warning("AssetManager: unrecognized resource header: " + real_path)
		return null
	var top_type := m.get_string(1)
	if not ClassDB.class_exists(top_type):
		push_warning("AssetManager: unknown resource type: " + top_type)
		return null

	var base_dir := real_path.get_base_dir()
	var ext_resources: Dictionary = {}
	var sub_resources: Dictionary = {}
	var top_obj: Resource = ClassDB.instantiate(top_type)

	var lines := text.split("\n")
	var i := 1
	while i < lines.size():
		var line: String = lines[i].strip_edges()

		if line.begins_with("[ext_resource"):
			var fields := _parse_tag_fields(line)
			var id: String = fields.get("id", "")
			var res := _load_ext_resource(fields, base_dir, pack_root)
			if res != null:
				ext_resources[id] = res

		elif line.begins_with("[sub_resource"):
			var fields := _parse_tag_fields(line)
			var type: String = fields.get("type", "")
			var id: String = fields.get("id", "")
			var obj: Object = ClassDB.instantiate(type) if ClassDB.class_exists(type) else null
			if obj == null:
				i = _skip_block(lines, i + 1)
				continue
			i = _apply_properties(lines, i + 1, obj, ext_resources, sub_resources) - 1
			sub_resources[id] = obj

		elif line.begins_with("[resource"):
			i = _apply_properties(lines, i + 1, top_obj, ext_resources, sub_resources) - 1

		i += 1

	return top_obj

## Audio has no raw-file decoder exposed to GDScript per format the way Image
## does, build the right AudioStream subtype from the extension and hand it
## the bytes directly (these load the data eagerly, no import step needed).
static func _load_audio_file(real_path: String) -> AudioStream:
	var ext := real_path.get_extension().to_lower()
	var bytes := FileAccess.get_file_as_bytes(real_path)
	match ext:
		"wav":
			return AudioStreamWAV.load_from_file(real_path)
		"ogg":
			return AudioStreamOggVorbis.load_from_buffer(bytes)
		"mp3":
			var stream := AudioStreamMP3.new()
			stream.data = bytes
			return stream
		_:
			push_warning("AssetManager: unsupported audio extension: " + ext)
			return null

static func resolve_pack_path(raw_path: String, base_dir: String, pack_root: String) -> String:
	if not raw_path.begins_with("res://"):
		return base_dir.path_join(raw_path)
	var stripped := raw_path.trim_prefix("res://")
	var segments := stripped.split("/")
	# Fake root is an unknown number of leading segments (e.g. "PolyBlocks/EffectBlocks/"
	# or "Starter_Vfx/" or "addons/vfx_library/"), walk from the back to find a suffix
	# that actually exists under pack_root, since we don't know the fake root's depth.
	# Starts at 0, not 1: a pack authored with everything in the project root has no
	# leading segment to strip at all ("res://tornado.obj"), and skipping cut=0 meant
	# the loop never ran for those.
	for cut in range(0, segments.size()):
		var suffix := "/".join(segments.slice(cut))
		var candidate := pack_root.path_join(suffix)
		if FileAccess.file_exists(candidate):
			return candidate
	return ""

static func _apply_properties(lines: PackedStringArray, start_i: int, obj: Object, ext_resources: Dictionary, sub_resources: Dictionary) -> int:
	var i := start_i
	while i < lines.size():
		var line: String = lines[i].strip_edges()
		if line.begins_with("[") or (line.is_empty() and i + 1 < lines.size() and lines[i + 1].strip_edges().begins_with("[")):
			break
		if line.is_empty():
			i += 1
			continue

		var eq := line.find(" = ")
		if eq == -1:
			i += 1
			continue

		var prop_name := line.substr(0, eq)
		var value_str := line.substr(eq + 3)

		# Multi-line values (e.g. ArrayMesh _surfaces = [{...}] spanning many
		# lines), keep appending lines until brackets/braces/parens balance,
		# same idea as Godot's own tokenizer, before handing to str_to_var().
		while not _is_balanced(value_str) and i + 1 < lines.size():
			i += 1
			value_str += "\n" + lines[i]

		var value: Variant = _parse_value(value_str, ext_resources, sub_resources)
		# Only NODE writes are deferred, obj.set() on a node reaches into
		# transforms, visibility and notifications. Resources are plain data
		# and write fine anywhere, they also can't be postponed: a
		# ShaderMaterial only accepts shader_parameter/* once its shader is
		# assigned, and a sub-resource referenced by another must already
		# hold its values when that reference is resolved.
		#
		# SERIALISED_PROPERTIES are the writes that can't happen off-thread at
		# all, even on resources:
		#   - ShaderLanguage::compile is not thread-safe and nothing guards it.
		#     A dev build's stack showed two workers inside it via:
		#       set("process_material") -> ParticleProcessMaterial::_update_shader
		#         -> shader_create_from_code -> ShaderLanguage::compile  <- crash
		#   - ArrayMesh._surfaces pushes mesh_initialize, blend_shape_count,
		#     then one mesh_add_surface per surface, as SEPARATE commands
		#     (rendering_server_default.h:363-386). Two threads doing that at
		#     once interleave their pushes into one queue, and a mesh_initialize
		#     landing between another mesh's add_surface calls corrupts both.
		#     texture_2d_create is a single push, which is why it's fine
		#     off-thread and this isn't.
		var needs_serialising := not Thread.is_main_thread() and prop_name in SERIALISED_PROPERTIES

		# Checked before the Node deferral, so a node property that compiles a
		# shader is serialised here rather than replayed later. Nested scenes
		# are packed inside the loader and never see their deferred writes.
		if needs_serialising:
			_mesh_mutex.lock()
			obj.set(prop_name, value)
			_mesh_mutex.unlock()
		elif obj is Node and not Thread.is_main_thread():
			_deferred_writes.append([obj, prop_name, value, obj.get_instance_id()])
		else:
			obj.set(prop_name, value)
		i += 1
	return i

static func _is_balanced(s: String) -> bool:
	return s.count("[") == s.count("]") \
		and s.count("(") == s.count(")") \
		and s.count("{") == s.count("}")

static func _parse_value(value_str: String, ext_resources: Dictionary, sub_resources: Dictionary) -> Variant:
	var placeholders: Dictionary = {}

	var ext_re := RegEx.new()
	ext_re.compile('ExtResource\\("([^"]+)"\\)')
	for m in ext_re.search_all(value_str):
		var token := "__EXTRES_%d__" % placeholders.size()
		placeholders[token] = ext_resources.get(m.get_string(1))
		value_str = value_str.replace(m.get_string(0), "\"%s\"" % token)

	var sub_re := RegEx.new()
	sub_re.compile('SubResource\\("([^"]+)"\\)')
	for m in sub_re.search_all(value_str):
		var token := "__SUBRES_%d__" % placeholders.size()
		placeholders[token] = sub_resources.get(m.get_string(1))
		value_str = value_str.replace(m.get_string(0), "\"%s\"" % token)

	var result: Variant = str_to_var(value_str)
	if result == null:
		return placeholders.values()[0] if placeholders.size() == 1 else value_str

	return _replace_placeholders(result, placeholders)

static func _replace_placeholders(value: Variant, placeholders: Dictionary) -> Variant:
	if value is String and placeholders.has(value):
		return placeholders[value]
	if value is Array:
		var out := []
		for item in value:
			out.append(_replace_placeholders(item, placeholders))
		return out
	if value is Dictionary:
		var out := {}
		for key in value:
			out[_replace_placeholders(key, placeholders)] = _replace_placeholders(value[key], placeholders)
		return out
	return value

static func _skip_block(lines: PackedStringArray, start_i: int) -> int:
	var i := start_i
	while i < lines.size() and not lines[i].strip_edges().begins_with("["):
		i += 1
	return i
