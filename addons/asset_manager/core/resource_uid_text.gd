@tool
class_name ResourceUidText
extends RefCounted

## Builds a uid:// string in Godot's own format for .tres files we hand-write.
## NOT ResourceUID.create_id(), that registers with the editor's uid cache and
## these files live outside any project. Character set matches the engine's
## (core/io/resource_uid.cpp:51) so the result is a well-formed uid Godot will
## accept when the file is later imported.
const _CHARACTERS: String = "abcdefghijklmnopqrstuvwxy012345678"

static func generate() -> String:
	var n := randi() & 0x1FFFFFFF
	n = (n << 24) | (randi() & 0xFFFFFF)
	var digits := ""
	while n > 0:
		digits = _CHARACTERS[n % _CHARACTERS.length()] + digits
		n = n / _CHARACTERS.length()
	if digits.is_empty():
		digits = "a"
	return "uid://" + digits
