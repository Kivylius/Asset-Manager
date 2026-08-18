@tool
class_name PreviewTheme
extends RefCounted

## Shared look for the 3D preview viewports, so models, effects and scenes
## agree rather than each carrying its own copy of the same colour.
## The thumbnail pipeline doesn't read this: changing it would mean
## regenerating every cached thumbnail, a separate decision from what the
## live preview looks like.

## Matching sky, for the previews that render a procedural sky rather than a
## flat colour (node_3d_editor_plugin.cpp:2995).
const SKY: Color = Color(0.385, 0.454, 0.55)

## The theme's base_color, the value every editor surface is derived from
## (editor_theme_manager.cpp:249), so this follows a theme or preset change
## instead of being a colour we picked.
## Not "background": that is base_color dimmed by 1.7, the near black
## behind the whole editor, models disappear into it.
static func background() -> Color:
	if Engine.is_editor_hint():
		var theme := EditorInterface.get_editor_theme()
		if theme and theme.has_color("base_color", "Editor"):
			return theme.get_color("base_color", "Editor")
	return Color(0.21, 0.24, 0.29)
