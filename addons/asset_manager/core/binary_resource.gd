@tool
class_name BinaryResource
extends RefCounted

## Godot writes .material/.mesh/.res as either plain-text .tres or its own
## compressed binary format. Only the magic bytes tell them apart.
static func is_binary(path: String) -> bool:
	var file := FileAccess.open(path, FileAccess.READ)
	if not file:
		return false
	var magic := file.get_buffer(4).get_string_from_ascii()
	file.close()
	return magic == "RSCC" or magic == "RSRC"
## Repoints external resources in a binary .res/.material/.mesh file.
## ResourceLoader.rename_dependencies() does this in C++ but has no GDScript
## binding (godotengine/godot#22480, open since 2018), so this is a direct
## port of ResourceFormatLoaderBinary::rename_dependencies
## (core/io/resource_format_binary.cpp).
##
## Packs bake absolute res://<AuthorProjectRoot>/... paths into their binary
## resources, which only resolve on the author's machine. Text .tscn/.tres can
## be string-replaced, binaries can't.
##
## Doesn't decode the resource. The header, string table and everything past
## the resource index pass through untouched, only the external-resource
## paths change, and internal-resource offsets get shifted by whatever the
## file grew or shrank. That's how this can rewrite meshes full of vertex data
## it has no understanding of.

const MAGIC_UNCOMPRESSED: PackedByteArray = [82, 83, 82, 67]  # "RSRC"
const MAGIC_COMPRESSED: PackedByteArray = [82, 83, 67, 67]    # "RSCC"

## Matches ResourceFormatSaverBinaryInstance's values, a mismatch here
## silently misreads every field after the flags.
const FORMAT_FLAG_UIDS: int = 2
const FORMAT_FLAG_HAS_SCRIPT_CLASS: int = 8
const RESERVED_FIELDS: int = 11
const FORMAT_VERSION_CAN_RENAME_DEPS: int = 1
const INVALID_UID: int = -1
## FileAccessCompressed::configure's default, what Godot writes these files
## with. The reader derives its block count from this.
const DEFAULT_BLOCK_SIZE: int = 4096

## Rewrites path_map's keys to its values inside file_path, in place.
## Returns OK, or an error code on read/write failure or a format too old
## to repoint.
static func rewrite(file_path: String, path_map: Dictionary) -> Error:
	var source := _read_container(file_path)
	if source.is_empty():
		push_error("AssetManager: cannot read binary resource: " + file_path)
		return ERR_CANT_OPEN

	var rewritten := _rewrite_buffer(source, file_path, path_map)
	if rewritten.is_empty():
		return ERR_FILE_CORRUPT

	# Write beside the original and swap, a failure part-way can't leave a
	# half-written resource in place of a working one.
	var temp_path := file_path + ".depren"
	var err := _write_container(temp_path, rewritten, _is_compressed(file_path))
	if err != OK:
		DirAccess.remove_absolute(temp_path)
		return err

	DirAccess.remove_absolute(file_path)
	return DirAccess.rename_absolute(temp_path, file_path)

## Walks the decompressed body, copies every field across, swaps only the
## external-resource paths. Returns an empty buffer if the format can't be
## handled. Little-endian only: every file these packs ship is little-endian
## (big_endian is a stored flag, and PackedByteArray's decode_* helpers assume
## little), a big-endian resource is rejected rather than silently mangled.
static func _rewrite_buffer(source: PackedByteArray, file_path: String, path_map: Dictionary) -> PackedByteArray:
	var out := PackedByteArray()
	var at: int = 0

	var big_endian := source.decode_u32(at); at += 4
	var use_real64 := source.decode_u32(at); at += 4

	if big_endian != 0:
		push_warning("AssetManager: big-endian binary resource not supported: " + file_path)
		return PackedByteArray()

	_push_u32(out, big_endian)
	_push_u32(out, use_real64)

	var ver_major := source.decode_u32(at); at += 4
	var ver_minor := source.decode_u32(at); at += 4
	var ver_format := source.decode_u32(at); at += 4

	if ver_format < FORMAT_VERSION_CAN_RENAME_DEPS:
		push_warning("AssetManager: binary resource too old to repoint: " + file_path)
		return PackedByteArray()

	_push_u32(out, ver_major)
	_push_u32(out, ver_minor)
	_push_u32(out, ver_format)

	var type := _read_ustring(source, at)
	at = _advance_ustring(source, at)
	_push_ustring(out, type)

	# The metadata offset points into the file, so it shifts with everything
	# else, remember where it landed and patch it once size_diff is known.
	var md_ofs := out.size()
	var importmd_ofs := source.decode_u64(at); at += 8
	_push_u64(out, 0)

	var flags := source.decode_u32(at); at += 4
	var using_uids := (flags & FORMAT_FLAG_UIDS) != 0
	var uid_data := source.decode_u64(at); at += 8

	_push_u32(out, flags)
	_push_u64(out, uid_data)

	if flags & FORMAT_FLAG_HAS_SCRIPT_CLASS:
		var script_class := _read_ustring(source, at)
		at = _advance_ustring(source, at)
		_push_ustring(out, script_class)

	for i in RESERVED_FIELDS:
		_push_u32(out, 0)
		at += 4

	var string_table_size := source.decode_u32(at); at += 4
	_push_u32(out, string_table_size)
	for i in string_table_size:
		_push_ustring(out, _read_ustring(source, at))
		at = _advance_ustring(source, at)

	var ext_resources_size := source.decode_u32(at); at += 4
	_push_u32(out, ext_resources_size)
	for i in ext_resources_size:
		var res_type := _read_ustring(source, at)
		at = _advance_ustring(source, at)
		var path := _read_ustring(source, at)
		at = _advance_ustring(source, at)

		if path_map.has(path):
			path = str(path_map[path])

		_push_ustring(out, res_type)
		_push_ustring(out, path)

		# The pack author's uid resolves to nothing here, and Godot prefers uid
		# over path, clear it so the path we just fixed is what gets used.
		if using_uids:
			at += 8
			_push_u64(out, INVALID_UID)

	# Internal resources store absolute offsets into the file, so whatever the
	# paths above gained or lost has to be added back onto every one of them.
	var size_diff: int = out.size() - at

	var int_resources_size := source.decode_u32(at); at += 4
	_push_u32(out, int_resources_size)
	for i in int_resources_size:
		var path := _read_ustring(source, at)
		at = _advance_ustring(source, at)
		var offset := source.decode_u64(at); at += 8
		_push_ustring(out, path)
		_push_u64(out, offset + size_diff)

	# The resource payload itself, never interpreted, just carried across.
	out.append_array(source.slice(at))

	out.encode_u64(md_ofs, importmd_ofs + size_diff)
	return out

## Length-prefixed UTF-8 including the null terminator (get_ustring/save_ustring
## in resource_format_binary.cpp).
static func _read_ustring(buffer: PackedByteArray, at: int) -> String:
	var length := buffer.decode_u32(at)
	if length == 0:
		return ""
	# The stored length counts the null terminator, which must not become part
	# of the String, _push_ustring adds its own back on write, and keeping it
	# here would grow the field by a byte on every rewrite.
	return buffer.slice(at + 4, at + 3 + length).get_string_from_utf8()

static func _advance_ustring(buffer: PackedByteArray, at: int) -> int:
	return at + 4 + buffer.decode_u32(at)

static func _push_ustring(out: PackedByteArray, value: String) -> void:
	var utf8 := value.to_utf8_buffer()
	_push_u32(out, utf8.size() + 1)
	out.append_array(utf8)
	out.append(0)

static func _push_u32(out: PackedByteArray, value: int) -> void:
	var at := out.size()
	out.resize(at + 4)
	out.encode_u32(at, value)

static func _push_u64(out: PackedByteArray, value: int) -> void:
	var at := out.size()
	out.resize(at + 8)
	out.encode_u64(at, value)

static func _is_compressed(file_path: String) -> bool:
	var file := FileAccess.open(file_path, FileAccess.READ)
	if not file:
		return false
	var magic := file.get_buffer(4)
	file.close()
	return magic == MAGIC_COMPRESSED

## The paths this resource depends on, read from its external-resource table.
## Scanning the decompressed bytes for "res://" as text doesn't work, the body
## is binary, so converting it to a String truncates at the first null byte
## and hides everything past it.
##
## FileAccess.open_compressed can't be used for either direction here: it
## hardcodes a "GCPF" magic (see FileAccess::open_compressed), while Godot's
## resource saver configures the same underlying FileAccessCompressed with
## "RSCC". Reading through it fails outright, writing through it would
## produce a container the engine won't load back. The layout is small
## enough to handle directly:
##   "RSCC" | cmode | block_size | total_size | csize per block | zstd blocks
static func referenced_paths(file_path: String) -> PackedStringArray:
	var paths := PackedStringArray()
	var source := _read_container(file_path)
	if source.is_empty():
		return paths

	var at := _skip_to_external_resources(source)
	if at < 0:
		return paths

	var flags := source.decode_u32(_flags_offset)
	var using_uids := (flags & FORMAT_FLAG_UIDS) != 0

	var count := source.decode_u32(at)
	at += 4
	for i in count:
		at = _advance_ustring(source, at)  # type
		paths.append(_read_ustring(source, at))
		at = _advance_ustring(source, at)
		if using_uids:
			at += 8
	return paths

## Set by _skip_to_external_resources so referenced_paths can re-read the flags
## without walking the header twice.
static var _flags_offset: int = 0

## Walks the header up to the start of the external-resource table, which is
## the only part either caller cares about. Returns -1 if the format can't
## be read.
static func _skip_to_external_resources(source: PackedByteArray) -> int:
	if source.size() < 20:
		return -1
	if source.decode_u32(0) != 0:  # big endian
		return -1

	var at := 8
	var ver_format := source.decode_u32(at + 8)
	if ver_format < FORMAT_VERSION_CAN_RENAME_DEPS:
		return -1
	at += 12

	at = _advance_ustring(source, at)  # resource type
	at += 8  # metadata offset

	_flags_offset = at
	var flags := source.decode_u32(at)
	at += 4 + 8  # flags + uid

	if flags & FORMAT_FLAG_HAS_SCRIPT_CLASS:
		at = _advance_ustring(source, at)

	at += RESERVED_FIELDS * 4

	var string_table_size := source.decode_u32(at)
	at += 4
	for i in string_table_size:
		at = _advance_ustring(source, at)

	return at

static func _read_container(file_path: String) -> PackedByteArray:
	var raw := FileAccess.get_file_as_bytes(file_path)
	if raw.slice(0, 4) != MAGIC_COMPRESSED:
		return raw.slice(4)  # uncompressed RSRC, drop the magic

	var block_size := raw.decode_u32(8)
	var total_size := raw.decode_u32(12)
	if block_size == 0:
		push_error("AssetManager: corrupt binary resource (zero block size): " + file_path)
		return PackedByteArray()

	var block_count: int = (total_size / block_size) + 1
	var sizes: Array[int] = []
	for i in block_count:
		sizes.append(raw.decode_u32(16 + i * 4))

	var out := PackedByteArray()
	var offset := 16 + block_count * 4
	for i in block_count:
		var remaining: int = total_size - out.size()
		var expanded: int = block_size if remaining > block_size else remaining
		var block := raw.slice(offset, offset + sizes[i])
		out.append_array(block.decompress(expanded, FileAccess.COMPRESSION_ZSTD))
		offset += sizes[i]

	return out

static func _write_container(file_path: String, data: PackedByteArray, compressed: bool) -> Error:
	var file := FileAccess.open(file_path, FileAccess.WRITE)
	if not file:
		return ERR_CANT_CREATE

	if not compressed:
		file.store_buffer(MAGIC_UNCOMPRESSED)
		file.store_buffer(data)
		file.close()
		return OK

	# block_size must match what the reader assumes per block; the engine's
	# FileAccessCompressed default (4096) is what it writes these files with
	var block_size := DEFAULT_BLOCK_SIZE
	var block_count: int = (data.size() / block_size) + 1
	var blocks: Array[PackedByteArray] = []
	for i in block_count:
		var start: int = i * block_size
		blocks.append(data.slice(start, mini(start + block_size, data.size())).compress(FileAccess.COMPRESSION_ZSTD))

	file.store_buffer(MAGIC_COMPRESSED)
	file.store_32(FileAccess.COMPRESSION_ZSTD)
	file.store_32(block_size)
	file.store_32(data.size())
	for block in blocks:
		file.store_32(block.size())
	for block in blocks:
		file.store_buffer(block)
	file.close()
	return OK
