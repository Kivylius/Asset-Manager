@tool
class_name IconHelper
extends RefCounted

## Every icon in the addon comes from the same place, and the lookup was the same
## three lines in fourteen files: fetch the theme, check the icon is there, assign
## it. The editor-only guard lives here too. EditorInterface doesn't exist at
## runtime, so without it a preview scene opened outside the editor errors.

const SET: StringName = &"EditorIcons"

static func get_icon(icon_name: String) -> Texture2D:
	if not Engine.is_editor_hint():
		return null
	var theme := EditorInterface.get_editor_theme()
	if theme == null or not theme.has_icon(icon_name, SET):
		return null
	return theme.get_icon(icon_name, SET)

## Leaves the button untouched when the icon is missing, so a renamed editor icon
## degrades to the button's existing look rather than blanking it.
static func apply(button: Button, icon_name: String) -> void:
	var icon := get_icon(icon_name)
	if icon != null:
		button.icon = icon
