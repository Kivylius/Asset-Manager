@tool
class_name EditorGuard
extends RefCounted

## A `@tool` script runs when its own scene is opened for editing, not only
## when the plugin instantiates it. Everything `_ready` does then lands on the
## node the editor is about to serialise, so a save writes runtime state into
## the scene file, a scaled `custom_minimum_size`, a theme variation, a
## version string, whichever properties that script happens to set.
## `get_parent() == get_tree().root` looks like the check for this and never
## fires: the editor parents the open scene to a SubViewport of its own
## (editor_node.h:462, added at editor_node.cpp:4683), so the parent is
## never the window root. `set_edited_scene_root` (editor_node.cpp:4679) is
## what actually marks the scene being edited, and it runs on the same path.
static func is_scene_tab(node: Node) -> bool:
	if not Engine.is_editor_hint():
		return false
	var tree := node.get_tree()
	return tree != null and tree.edited_scene_root == node
