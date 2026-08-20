@tool
class_name SidebarNavigator
extends VBoxContainer

signal filter_changed

## Tags past this are hidden behind "Show more", an unbounded list buries
## extensions below the fold.
const TAG_LIMIT: int = 10

## Counts sit in their own right-aligned column so they line up down the panel
## rather than trailing each name at a different x.
const COL_NAME: int = 0
const COL_COUNT: int = 1

var database: AssetDatabase
var workspace_path: String = ""

var active_folder_prefix: String = ""
var active_type_id: String = ""
var active_tags: Array[String] = []
var active_extensions: Array[String] = []

var _tags_expanded: bool = false
var _collapsed_sections: Dictionary = {}

@onready var _tree: Tree = $AssetTree

## Both taken from Godot's own docks, and both scaled by get_editor_scale(),
## a raw pixel value is half its intended size on a 200% display.
## 170 is the floor any docked panel is allowed to shrink to
## (dock_tab_container.cpp:364); 280 is the width the editor opens them at
## (editor_node.cpp:9301).
const BASE_MIN_WIDTH: int = 170
const BASE_DEFAULT_WIDTH: int = 280
const BASE_COUNT_COLUMN_WIDTH: int = 80

## Convert from 1150 => 1.1k to fit the sidebar
static func format_count(count: int) -> String:
	if count < 1000:
		return str(count)
	var unit := 1000 if count < 1000000 else 1000000
	var suffix := "k" if count < 1000000 else "m"
	var whole := count / unit
	if whole >= 100:
		return "%d%s" % [whole, suffix]
	return "%d.%d%s" % [whole, (count % unit) * 10 / unit, suffix]

func _ready() -> void:
	if EditorGuard.is_scene_tab(self):
		return

	_tree.item_selected.connect(_on_item_selected)
	_tree.item_edited.connect(_on_item_edited)
	_tree.item_collapsed.connect(_on_item_collapsed)

	_apply_panel_style()

	var scale := _editor_scale()
	custom_minimum_size = Vector2(BASE_MIN_WIDTH * scale, 0)

	_tree.set_column_expand(COL_NAME, true)
	_tree.set_column_clip_content(COL_NAME, true)
	_tree.set_column_expand(COL_COUNT, false)
	_tree.set_column_custom_minimum_width(COL_COUNT, int(BASE_COUNT_COLUMN_WIDTH * scale))

## The theme variation the editor uses for exactly this, a sidebar list inset
## into the surrounding chrome. Gives the darker surface_low background, a
## border and rounded corners (theme_modern.cpp:2230-2244), and it re-themes
## with the editor rather than being a colour we picked.
## Same mechanism the Script editor's file and method lists use, which set
## "ItemListSecondary" (script_editor_plugin.cpp:578).
func _apply_panel_style() -> void:
	_tree.theme_type_variation = "TreeSecondary"

func _editor_scale() -> float:
	return EditorInterface.get_editor_scale() if Engine.is_editor_hint() else 1.0

func refresh() -> void:
	if database == null:
		return

	var stats := _gather_stats()

	_tree.clear()
	var root := _tree.create_item()

	_build_assets(root, stats)
	_build_tags(root, stats["tags"])
	_build_extensions(root, stats["extensions"])

	# After every section exists, so a later build can't steal the highlight.
	_select_active_folder(root)

## Finds the folder row matching the active filter (Assets when nothing is
## filtered), so there is always exactly one highlighted row.
func _select_active_folder(item: TreeItem) -> bool:
	var child := item.get_first_child()
	while child != null:
		var meta: Variant = child.get_metadata(COL_NAME)
		if meta is Dictionary and meta.get("type") == "folder" and meta.get("path", "") == active_folder_prefix:
			child.select(COL_NAME)
			return true
		if _select_active_folder(child):
			return true
		child = child.get_next()
	return false

## One pass over the index for everything the sidebar needs: folder structure,
## per-type counts, tag counts and extension counts.
func _gather_stats() -> Dictionary:
	var folders: Dictionary = {}
	var tags: Dictionary = {}
	var extensions: Dictionary = {}
	var total: int = 0

	for path: String in database.assets:
		total += 1

		var relative := path.trim_prefix(workspace_path + "/")
		var first_slash := relative.find("/")
		if first_slash != -1:
			var type_id := relative.substr(0, first_slash)
			var rest := relative.substr(first_slash + 1)

			if not folders.has(type_id):
				folders[type_id] = {"subfolders": {}, "count": 0}
			folders[type_id]["count"] += 1

			var second_slash := rest.find("/")
			if second_slash != -1:
				var sub_name := rest.substr(0, second_slash)
				var children: Dictionary = folders[type_id]["subfolders"].get_or_add(sub_name, {})
				var deeper := rest.substr(second_slash + 1)
				var third_slash := deeper.find("/")
				if third_slash != -1:
					children[deeper.substr(0, third_slash)] = true

		# Tag and extension counts are scoped to the active folder, so a count
		# always describes what clicking it would actually give you.
		if not active_folder_prefix.is_empty() and not path.begins_with(active_folder_prefix):
			continue

		for tag in database.assets[path].get("tags", []):
			tags[tag] = tags.get(tag, 0) + 1

		var ext := path.get_extension().to_lower()
		extensions[ext] = extensions.get(ext, 0) + 1

	return {"folders": folders, "tags": tags, "extensions": extensions, "total": total}

## "Assets" is the section row AND the way back to everything, selecting it
## clears the folder filter.
func _build_assets(root: TreeItem, stats: Dictionary) -> void:
	var section := _make_section(root, "assets", "Assets", "Folder")
	section.set_text(COL_COUNT, format_count(stats["total"]))
	section.set_text_alignment(COL_COUNT, HORIZONTAL_ALIGNMENT_RIGHT)
	section.set_custom_color(COL_COUNT, _count_colour())
	# Selectable, so it doesn't fold like the other two headers. Clicking it
	# clears the folder filter.
	section.set_selectable(COL_NAME, true)
	section.set_selectable(COL_COUNT, true)
	section.set_metadata(COL_NAME, {"type": "folder", "path": ""})

	var folders: Dictionary = stats["folders"]

	for type_entry in AssetTypes.ALL:
		var type_id: String = type_entry["id"]
		if not folders.has(type_id):
			continue

		var type_prefix := workspace_path.path_join(type_id)
		var item := _tree.create_item(section)
		item.set_text(COL_NAME, type_id)
		item.set_text(COL_COUNT, format_count(folders[type_id]["count"]))
		item.set_text_alignment(COL_COUNT, HORIZONTAL_ALIGNMENT_RIGHT)
		item.set_custom_color(COL_COUNT, _count_colour())
		item.set_metadata(COL_NAME, {"type": "folder", "path": type_prefix, "type_id": type_id})
		item.set_icon(COL_NAME, _icon_for(type_entry.get("default_icon", "File")))
		item.set_icon_modulate(COL_NAME, _muted_colour())

		var subfolders: Array = folders[type_id]["subfolders"].keys()
		subfolders.sort()
		for name: String in subfolders:
			var sub_prefix := type_prefix.path_join(name)
			var sub := _tree.create_item(item)
			sub.set_text(COL_NAME, name)
			sub.set_metadata(COL_NAME, {"type": "folder", "path": sub_prefix, "type_id": type_id})

			var children: Array = folders[type_id]["subfolders"][name].keys()
			children.sort()
			if children.size() < 2:
				children.clear()
			for child_name: String in children:
				var child := _tree.create_item(sub)
				child.set_text(COL_NAME, child_name)
				child.set_metadata(COL_NAME, {"type": "folder", "path": sub_prefix.path_join(child_name), "type_id": type_id})

			sub.collapsed = not active_folder_prefix.begins_with(sub_prefix)

		# Only the branch you're in opens, so nine types don't fill the panel.
		item.collapsed = not active_folder_prefix.begins_with(type_prefix)

		if type_prefix == active_folder_prefix:
			item.select(COL_NAME)
		else:
			for sub in item.get_children():
				if sub.get_metadata(COL_NAME).get("path") == active_folder_prefix:
					sub.select(COL_NAME)

func _build_tags(root: TreeItem, counts: Dictionary) -> void:
	var names: Array = counts.keys()
	if names.is_empty():
		return

	names.sort_custom(func(a: String, b: String) -> bool: return counts[a] > counts[b])
	active_tags = active_tags.filter(func(tag: String) -> bool: return counts.has(tag))

	var section := _make_section(root, "tags", "Tags", "FileList")

	var shown := names if _tags_expanded else names.slice(0, mini(TAG_LIMIT, names.size()))
	for tag: String in shown:
		_make_checkbox(section, tag, counts[tag], active_tags.has(tag), {"type": "tag", "value": tag})

	var hidden := names.size() - shown.size()
	if hidden > 0 or _tags_expanded:
		var more := _tree.create_item(section)
		more.set_text(COL_NAME, "Show less" if _tags_expanded else "Show %d more…" % hidden)
		more.set_metadata(COL_NAME, {"type": "tags_more"})
		more.set_custom_color(COL_NAME, _muted_colour())

func _build_extensions(root: TreeItem, counts: Dictionary) -> void:
	var names: Array = counts.keys()
	if names.is_empty():
		return

	names.sort()
	active_extensions = active_extensions.filter(func(ext: String) -> bool: return counts.has(ext))

	var section := _make_section(root, "extensions", "Extensions", "Script")

	for ext: String in names:
		_make_checkbox(section, "." + ext, counts[ext], active_extensions.has(ext), {"type": "extension", "value": ext})

## The three top-level rows. Tags and Extensions fold when clicked anywhere,
## non-selectable and non-editable is what triggers that (tree.cpp:3242), and
## folding is the only useful thing a header can do. Assets overrides both
## flags, because selecting it clears the folder filter.
func _make_section(root: TreeItem, id: String, label: String, icon_name: String) -> TreeItem:
	var item := _tree.create_item(root)
	item.set_text(COL_NAME, label)
	item.set_selectable(COL_NAME, false)
	item.set_selectable(COL_COUNT, false)
	item.set_icon(COL_NAME, _icon_for(icon_name))
	item.set_icon_modulate(COL_NAME, _muted_colour())
	item.collapsed = _collapsed_sections.get(id, false)
	item.set_metadata(COL_NAME, {"type": "section", "id": id})
	return item

## Tags and extensions never take the selection: selection means "which folder
## am I looking at", and a tag is a switch, not a location. Without this,
## ticking a tag steals the highlight from the folder that's still filtering
## the grid.
## Safe to make non-selectable here where it wasn't on folder rows, tree.cpp:3242
## only turns a dead cell into a fold target when the item has children, and
## these are leaves.
func _make_checkbox(parent: TreeItem, label: String, count: int, checked: bool, meta: Dictionary) -> void:
	var item := _tree.create_item(parent)
	item.set_cell_mode(COL_NAME, TreeItem.CELL_MODE_CHECK)
	item.set_text(COL_NAME, label)
	item.set_text(COL_COUNT, format_count(count))
	item.set_text_alignment(COL_COUNT, HORIZONTAL_ALIGNMENT_RIGHT)
	item.set_custom_color(COL_COUNT, _count_colour())
	item.set_editable(COL_NAME, true)
	item.set_checked(COL_NAME, checked)
	item.set_selectable(COL_NAME, false)
	item.set_selectable(COL_COUNT, false)
	item.set_metadata(COL_NAME, meta)

func _icon_for(icon_name: String) -> Texture2D:
	return IconHelper.get_icon(icon_name)

## Godot's node icons are strongly coloured, fine in the scene tree where
## colour carries meaning, loud in a filter list where it doesn't.
func _muted_colour() -> Color:
	if not Engine.is_editor_hint():
		return Color(0.7, 0.7, 0.7)
	var theme := EditorInterface.get_editor_theme()
	if theme and theme.has_color("font_disabled_color", "Editor"):
		return theme.get_color("font_disabled_color", "Editor")
	return Color(0.7, 0.7, 0.7)

## Counts are reference, not content, they should read as a whisper next to
## the name rather than competing with it.
func _count_colour() -> Color:
	var base := _muted_colour()
	base.a = 0.4
	return base

func _on_item_collapsed(item: TreeItem) -> void:
	var meta: Variant = item.get_metadata(COL_NAME)
	if meta is Dictionary and meta.get("type") == "section":
		_collapsed_sections[meta.get("id")] = item.collapsed

func _on_item_selected() -> void:
	var item := _tree.get_selected()
	if item == null:
		return
	var meta: Variant = item.get_metadata(COL_NAME)
	if not (meta is Dictionary):
		return

	if meta.get("type") == "tags_more":
		_tags_expanded = not _tags_expanded
		call_deferred("refresh")
		return

	if meta.get("type") != "folder":
		return

	var path: String = meta.get("path", "")
	if path == active_folder_prefix:
		return

	active_folder_prefix = path
	active_type_id = meta.get("type_id", "")
	# Godot refuses to rebuild a Tree while it's dispatching a selection.
	call_deferred("refresh")
	call_deferred("emit_signal", "filter_changed")

func _on_item_edited() -> void:
	var item := _tree.get_edited()
	var meta: Variant = item.get_metadata(COL_NAME)
	if not (meta is Dictionary):
		return

	var checked: bool = item.is_checked(COL_NAME)
	var value: String = meta.get("value", "")

	match meta.get("type"):
		"tag":
			if checked and not active_tags.has(value):
				active_tags.append(value)
			elif not checked and active_tags.has(value):
				active_tags.erase(value)
		"extension":
			if checked and not active_extensions.has(value):
				active_extensions.append(value)
			elif not checked and active_extensions.has(value):
				active_extensions.erase(value)
		_:
			return

	filter_changed.emit()

func clear_folder_filter() -> void:
	if active_folder_prefix.is_empty():
		return
	active_folder_prefix = ""
	refresh()
	filter_changed.emit()
