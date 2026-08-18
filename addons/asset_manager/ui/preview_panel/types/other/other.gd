@tool
class_name OtherPreview
extends Control

## Fallback

@onready var _icon: TextureRect = $CenterContainer/VBox/Icon

func _ready() -> void:
	if EditorGuard.is_scene_tab(self):
		return

	_icon.texture = IconHelper.get_icon("File")

func show_asset(_path: String, _type_entry: Dictionary = {}) -> void:
	visible = true

func hide_asset() -> void:
	visible = false
