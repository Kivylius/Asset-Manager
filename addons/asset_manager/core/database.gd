@tool
class_name AssetDatabase
extends RefCounted

const INDEX_FILE_NAME: String = ".assetmanager/index.db"

var version: int = 0
var assets: Dictionary = {}
var workspace_path: String = ""

func _get_index_path() -> String:
	return workspace_path.path_join(INDEX_FILE_NAME)

func get_type_for_path(path: String) -> String:
	if assets.has(path):
		return assets[path]["type"]
	return ""

func sync() -> bool:
	var path := _get_index_path()
	if not FileAccess.file_exists(path):
		version = 0
		assets = {}
		return false

	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("AssetManager: failed to open index for reading: ", path)
		return false

	var data: Variant = file.get_var()
	file.close()

	if not (data is Dictionary):
		push_error("AssetManager: index.db content was not a Dictionary: ", path)
		return false

	version = data.get("version", 0)
	var loaded_assets: Variant = data.get("assets", {})
	assets = {}
	if loaded_assets is Dictionary:
		assets = loaded_assets

	return true

func has_newer_version_on_disk() -> bool:
	var path := _get_index_path()
	if not FileAccess.file_exists(path):
		return false

	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return false

	var data: Variant = file.get_var()
	file.close()

	if not (data is Dictionary):
		return false

	var disk_version: int = data.get("version", 0)
	return disk_version > version

## Existing entries are reused verbatim, only date_added is backfilled.
## User-edited tags and type are preserved across rescans.
func rebuild(scanned_assets: Array[Dictionary]) -> bool:
	var new_assets: Dictionary = {}
	var now := int(Time.get_unix_time_from_system())
	for entry in scanned_assets:
		var path: String = entry["path"]
		if assets.has(path):
			var existing: Dictionary = assets[path]
			# Entries written before date_added existed backfill to now, once.
			if not existing.has("date_added"):
				existing["date_added"] = now
			new_assets[path] = existing
		else:
			new_assets[path] = {"type": entry["type"], "tags": entry["tags"], "date_added": now}

	assets = new_assets
	version += 1
	return _write_to_disk()

## Incrementally inserts newly imported assets without rescanning or replacing
## existing entries. Existing tags, subtype, and date_added stay untouched.
func add_entries(scanned_assets: Array[Dictionary]) -> bool:
	if scanned_assets.is_empty():
		return true
	var now := int(Time.get_unix_time_from_system())
	for entry in scanned_assets:
		var path: String = entry["path"]
		if assets.has(path):
			continue
		assets[path] = {
			"type": entry["type"],
			"tags": entry.get("tags", []),
			"date_added": now,
		}

	version += 1
	return _write_to_disk()

func update_subtypes(collected: Dictionary) -> bool:
	if collected.is_empty():
		return true
	for path: String in collected:
		if assets.has(path):
			assets[path]["subtype"] = collected[path]
	version += 1
	return _write_to_disk()

func update_tags(path: String, new_tags: Array[String]) -> bool:
	if assets.has(path):
		assets[path]["tags"] = new_tags
		version += 1
		return _write_to_disk()
	push_error("AssetManager: update_tags called for unknown path: ", path)
	return false

func get_tags_for_path(path: String) -> Array[String]:
	if assets.has(path):
		var tags: Array = assets[path].get("tags", [])
		var result: Array[String] = []
		result.assign(tags)
		return result
	return []

## unix seconds, 0 for entries indexed before this field existed
func get_date_added(path: String) -> int:
	if assets.has(path):
		return int(assets[path].get("date_added", 0))
	return 0

func get_all_known_tags() -> Array[String]:
	var seen: Dictionary = {}
	for path: String in assets:
		var tags: Array = assets[path].get("tags", [])
		for tag in tags:
			seen[tag] = true
	var result: Array[String] = []
	result.assign(seen.keys())
	result.sort()
	return result

func _write_to_disk() -> bool:
	var final_path := _get_index_path()
	var temp_path := final_path + ".tmp"

	var file := FileAccess.open(temp_path, FileAccess.WRITE)
	if file == null:
		push_error("AssetManager: failed to open temp file for writing: ", temp_path)
		return false

	file.store_var({"version": version, "assets": assets})
	file.close()

	var dir := DirAccess.open(workspace_path)
	if dir == null:
		push_error("AssetManager: failed to open workspace dir for rename: ", workspace_path)
		return false

	var err := dir.rename(INDEX_FILE_NAME + ".tmp", INDEX_FILE_NAME)
	if err != OK:
		push_error("AssetManager: failed to rename temp index into place: ", err)
		return false

	return true
