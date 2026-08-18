@tool
class_name ScenesExportHandler
extends RefCounted

## Scenes and effects are both .tscn packs with the same dependency problem,
## and the export walk is byte-identical between them. One implementation
## lives in effects/export.gd; this stays so the HANDLERS dict keeps one
## entry per type.
static func export_asset(source_path: String, dest_path: String) -> Dictionary:
	return EffectsExportHandler.export_asset(source_path, dest_path)
