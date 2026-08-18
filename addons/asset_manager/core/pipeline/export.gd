@tool
class_name AssetExporter
extends RefCounted
## The lookup is NOT automatic, a new type needs its entry adding to HANDLERS
## or it silently exports as a plain file copy. GDScript has no runtime "load
## this script if it exists" that works under export/packing, so the dict is
## the explicit trade for that.

const HANDLERS: Dictionary = {
	"models": preload("res://addons/asset_manager/core/types/models/export.gd"),
	"materials": preload("res://addons/asset_manager/core/types/materials/export.gd"),
	"shaders": preload("res://addons/asset_manager/core/types/shaders/export.gd"),
	"effects": preload("res://addons/asset_manager/core/types/effects/export.gd"),
	"scenes": preload("res://addons/asset_manager/core/types/scenes/export.gd"),
}
const DEFAULT_HANDLER := preload("res://addons/asset_manager/core/types/default/export.gd")

## Shared by every type handler so the result shape and the copy primitive
## live in one place. Fields:
##   copied_count: int
##   skipped_existing_count: int, already present at dest, left untouched
##   errors: Array[String]
##   copied_paths: Array[String], res:// paths (via ProjectSettings.
##     localize_path) of everything actually copied this call, for the
##     caller to update_file()/reimport_files() against instead of a broad
##     EditorFileSystem.scan()
static func new_result() -> Dictionary:
	return {
		"copied_count": 0,
		"skipped_existing_count": 0,
		"errors": [],
		"copied_paths": [],
	}

## Copies one file into dest_path, creating parent folders as needed, and
## records the outcome into result (mutated in place). Skips (not an error)
## if dest_path already exists, "Send to Project" is safe to run repeatedly,
## it never overwrites.
static func copy_one_file(source_path: String, dest_path: String, result: Dictionary) -> void:
	if not FileAccess.file_exists(source_path):
		result["errors"].append("Source file missing, skipped: " + source_path)
		return

	if FileAccess.file_exists(dest_path):
		result["skipped_existing_count"] += 1
		return

	var dest_dir := dest_path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dest_dir):
		DirAccess.make_dir_recursive_absolute(dest_dir)

	var err := DirAccess.copy_absolute(source_path, dest_path)
	if err == OK:
		result["copied_count"] += 1
		result["copied_paths"].append(ProjectSettings.localize_path(dest_path))
	else:
		result["errors"].append("Failed to copy (" + str(err) + "): " + source_path)

## Keeps only the FIRST folder segment below the asset's type root as a
## subfolder in dest_dir, the same one-level-deep convention auto-tags use.
## Without it every material's and model's files land in one flat folder and
## collide.
## e.g. materials/Rock033_2K/Rock033_2K.tres -> dest_dir/Rock033_2K/Rock033_2K.tres
##      models/kenney/a/b/c/prop.glb         -> dest_dir/kenney/prop.glb
## dest_path is computed here, once, then handed to the type handler. Every
## handler builds its dependency copies off that same base dir, so they
## inherit the preserved subfolder for free.
static func export_asset(source_path: String, dest_dir: String, type_id: String, workspace_path: String) -> Dictionary:
	var handler: Variant = HANDLERS.get(type_id, DEFAULT_HANDLER)
	var dest_path := _compute_dest_path(source_path, dest_dir, type_id, workspace_path)
	return handler.export_asset(source_path, dest_path)

static func _compute_dest_path(source_path: String, dest_dir: String, type_id: String, workspace_path: String) -> String:
	var bucket_root := workspace_path.path_join(type_id)
	if not source_path.begins_with(bucket_root):
		return dest_dir.path_join(source_path.get_file())

	var relative := source_path.trim_prefix(bucket_root)
	if relative.begins_with("/"):
		relative = relative.substr(1)
	if relative.is_empty():
		return dest_dir.path_join(source_path.get_file())

	var first_segment := relative.split("/")[0]
	if first_segment == relative:
		# File sits directly in the bucket root, no subfolder to preserve.
		return dest_dir.path_join(source_path.get_file())

	return dest_dir.path_join(first_segment).path_join(source_path.get_file())
