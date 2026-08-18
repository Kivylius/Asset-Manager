@tool
class_name CoverArtExtractor
extends RefCounted

static func extract(path: String) -> Texture2D:
	var file := FileAccess.open(path, FileAccess.READ)
	if not file:
		return null

	if file.get_buffer(3).get_string_from_ascii() != "ID3":
		return null

	var major_version := file.get_8()
	file.get_8() # Minor version, unused.
	var flags := file.get_8()
	var tag_size := _read_synchsafe_32(file)

	if flags & 0x40: # Extended header present, skip it.
		var ext_size := _read_synchsafe_32(file) if major_version >= 4 else _read_be_32(file)
		file.seek(file.get_position() + ext_size - 4)

	var tag_end := file.get_position() + tag_size

	while file.get_position() < tag_end - 10:
		var frame_id := file.get_buffer(4).get_string_from_ascii()
		if frame_id.length() < 4 or frame_id.unicode_at(0) == 0:
			break # Padding reached, no more real frames.

		# Frame sizes are synchsafe only in ID3v2.4+; v2.3 and earlier use
		# plain big-endian 32-bit.
		var frame_size: int = _read_synchsafe_32(file) if major_version >= 4 else _read_be_32(file)
		file.get_16() # Frame flags, unused.

		if frame_id == "APIC":
			return _parse_apic(file, frame_size)

		file.seek(file.get_position() + frame_size)

	return null

static func _parse_apic(file: FileAccess, frame_size: int) -> Texture2D:
	var frame_start := file.get_position()
	var frame_end := frame_start + frame_size

	var text_encoding := file.get_8()
	var mime_type := _read_null_terminated_ascii(file)
	file.get_8() # Picture type byte, unused; we don't distinguish cover/other art.

	_skip_null_terminated_string(file, text_encoding)

	var image_start := file.get_position()
	var image_size := frame_end - image_start
	if image_size <= 0:
		return null

	var image_bytes := file.get_buffer(image_size)

	var img := Image.new()
	var err: int
	if mime_type.containsn("png"):
		err = img.load_png_from_buffer(image_bytes)
	else:
		err = img.load_jpg_from_buffer(image_bytes)

	if err != OK:
		return null

	return ImageTexture.create_from_image(img)

## Plain big-endian 32-bit read.
static func _read_be_32(file: FileAccess) -> int:
	var b0 := file.get_8()
	var b1 := file.get_8()
	var b2 := file.get_8()
	var b3 := file.get_8()
	return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3

static func _read_synchsafe_32(file: FileAccess) -> int:
	var b0 := file.get_8()
	var b1 := file.get_8()
	var b2 := file.get_8()
	var b3 := file.get_8()
	return (b0 << 21) | (b1 << 14) | (b2 << 7) | b3

static func _read_null_terminated_ascii(file: FileAccess) -> String:
	var bytes := PackedByteArray()
	while true:
		var b := file.get_8()
		if b == 0:
			break
		bytes.append(b)
	return bytes.get_string_from_ascii()

static func _skip_null_terminated_string(file: FileAccess, text_encoding: int) -> void:
	if text_encoding == 1 or text_encoding == 2:
		while true:
			var b0 := file.get_8()
			var b1 := file.get_8()
			if b0 == 0 and b1 == 0:
				break
	else:
		while file.get_8() != 0:
			pass
