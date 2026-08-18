@tool
class_name AssetTypes
extends RefCounted

## Asset types: id, label, extensions, default_icon, default_export_path,
## optional runners (custom import handler) and subtypes (filter category).

const ALL: Array[Dictionary] = [
	{
		"id": "models",
		"label": "3D Models",
		"extensions": ["glb", "gltf", "fbx"],
		"default_icon": "MeshInstance3D",
		"default_export_path": "res://assets/models"
	},
	{
		"id": "images",
		"label": "2D Images",
		"extensions": ["png", "jpg", "jpeg", "webp"],
		"default_icon": "Texture2D",
		"default_export_path": "res://assets/images"
	},
	{
		"id": "sounds",
		"label": "Sounds",
		"extensions": ["ogg", "mp3", "wav"],
		"default_icon": "AudioStreamPlayer",
		"default_export_path": "res://assets/sounds"
	},
	{
		"id": "music",
		"label": "Music",
		"extensions": ["ogg", "mp3", "wav"],
		"default_icon": "AudioStreamMP3",
		"default_export_path": "res://assets/music"
	},
	{
		"id": "videos",
		"label": "Videos",
		"extensions": ["ogv"],
		"default_icon": "VideoStreamPlayer",
		"default_export_path": "res://assets/videos"
	},
	{
		"id": "materials",
		"label": "Materials",
		"extensions": ["tres"],
		"default_icon": "StandardMaterial3D",
		"default_export_path": "res://assets/materials",
		"runners": ["materials"]
	},
	{
		"id": "effects",
		"label": "Effects",
		"extensions": ["tscn"],
		"default_icon": "GPUParticles3D",
		"default_export_path": "res://assets/effects",
		"subtypes": {
			"label": "Dimension",
			"options": {"3d": "3D", "2d": "2D"}
		}
	},
	{
		"id": "shaders",
		"label": "Shaders",
		"extensions": ["gdshader"],
		"default_icon": "Shader",
		"default_export_path": "res://assets/shaders",
		"subtypes": {
			"label": "Mode",
			"options": {
				"spatial": "Spatial",
				"canvas_item": "Canvas Item",
				"particles": "Particles",
				"sky": "Sky",
				"fog": "Fog",
				"texture_blit": "Texture Blit"
			}
		}
	},
	{
		"id": "scenes",
		"label": "Scenes",
		"extensions": ["tscn"],
		"default_icon": "PackedScene",
		"default_export_path": "res://assets/scenes"
	},
	{
		"id": "other",
		"label": "Other",
		"extensions": [""],
		"default_icon": "File",
		"default_export_path": "res://assets/other"
	},
]

const FALLBACK_ID: String = "other"

static func get_folder_names() -> PackedStringArray:
	var names := PackedStringArray()
	for entry in ALL:
		names.append(entry["id"])
	return names

static func get_by_id(id: String) -> Dictionary:
	for entry in ALL:
		if entry["id"] == id:
			return entry
	return {}

static func get_subtype_ids(type_id: String) -> Array:
	var subtypes: Dictionary = get_by_id(type_id).get("subtypes", {})
	return subtypes.get("options", {}).keys()

static func folder_to_type_id(folder_name: String) -> String:
	for entry in ALL:
		if entry["id"] == folder_name:
			return entry["id"]
	return FALLBACK_ID
