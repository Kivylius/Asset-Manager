@tool
class_name PackPaths
extends RefCounted

## Resolves the baked res:// paths inside a pack against where its files
## actually sit on disk.

## Guard against a shader include cycle, which would otherwise recurse forever.
const MAX_INCLUDE_DEPTH: int = 8

## A pack is whatever folder sits directly inside the bucket, so the walk climbs
## until the parent is the bucket itself rather than sniffing for a subfolder
## name a pack may not use.
## Keeps walking to the LAST match: a pack containing a folder named after its
## own bucket would otherwise match that one and treat a folder deep inside the
## pack as its root.
static func find_pack_root(start_dir: String, bucket: String) -> String:
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

static func resolve_pack_path(raw_path: String, base_dir: String, pack_root: String, search_full_path: bool = false) -> String:
	if not raw_path.begins_with("res://") and not search_full_path:
		return base_dir.path_join(raw_path)

	# The baked path starts with however many folders the author's project had
	# above the file, which we can't know. Joining what is left onto pack_root
	# only finds the file where the root sits exactly at the top of that tree,
	# and a pack nested any deeper never matches however many segments come off.
	# So the pack's own files are searched instead, keeping the longest tail of
	# the baked path that names exactly one of them. Length is what makes it
	# safe: a reference that named folders has to match them, and only a
	# reference that was never more than a filename matches on the name alone.
	var segments := raw_path.trim_prefix("res://").split("/", false)
	var files := _pack_files(pack_root)

	for cut in range(0, segments.size()):
		var tail := "/".join(segments.slice(cut))
		var found := ""
		for path: String in files:
			if not path.ends_with("/" + tail):
				continue
			if not found.is_empty():
				return ""     # the tail names more than one file, don't guess
			found = path
		if not found.is_empty():
			return found

	return ""

## Locked because model thumbnails read this from worker threads.
static var _files_by_pack: Dictionary = {}
static var _files_mutex: Mutex = Mutex.new()

static func clear_pack_files() -> void:
	_files_mutex.lock()
	_files_by_pack.clear()
	_files_mutex.unlock()

static func _pack_files(pack_root: String) -> PackedStringArray:
	_files_mutex.lock()
	if not _files_by_pack.has(pack_root):
		var files := PackedStringArray()
		_collect_files(pack_root, files)
		_files_by_pack[pack_root] = files
	var result: PackedStringArray = _files_by_pack[pack_root]
	_files_mutex.unlock()
	return result

static func _collect_files(dir_path: String, into: PackedStringArray) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return

	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		var full := dir_path.path_join(entry)
		if dir.current_is_dir():
			_collect_files(full, into)
		else:
			into.append(full)
		entry = dir.get_next()
	dir.list_dir_end()


## Substitutes #include directives with the file they point at, before the code
## reaches Shader.set_code().
## Godot's own preprocessor already handles #include, but it resolves relative to
## the Shader's resource path (scene/resources/shader.cpp), and a Shader built
## with Shader.new() has none, so it silently fails and the raw '#' reaches the
## tokenizer ("Unknown character #35"). Include paths are baked absolutes like
## every other path in a pack, so they get the same resolve_pack_path treatment
## rather than being trusted as written.
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

