@tool
class_name DefaultExportHandler
extends RefCounted
## Fallback export handler, a plain single-file copy, no dependency awareness.
## Used by every type that doesn't have its own export/types/<id>.gd (see
## export.gd's HANDLERS lookup).

## dest_path is the FULL final destination path for source_path (already
## computed by export.gd's export_asset(), subfolder and all), not a
## directory to join a filename onto.
static func export_asset(source_path: String, dest_path: String) -> Dictionary:
	var result := AssetExporter.new_result()
	AssetExporter.copy_one_file(source_path, dest_path, result)
	return result
