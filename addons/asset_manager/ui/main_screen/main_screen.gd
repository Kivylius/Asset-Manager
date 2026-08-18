@tool
@static_unload
class_name AssetManager
extends Control

## The shell. Owns the workspace, the database and the current selection, and
## wires the four components together, it draws nothing itself.
## Selection lives here rather than in the grid: the preview, the tag editor
## and the action buttons all need it, and having each reach into the grid to
## ask would couple them to whatever widget the grid happens to use.

signal asset_selected(path: String)

var current_selected_path: String = ""
var current_workspace_path: String = ""

var _workspace_picker: WorkspacePicker
var _database: AssetDatabase
var _settings: SettingsManager = SettingsManager.new()
var _thumbnails: ThumbnailCache = ThumbnailCache.new()
var _progress_dialog: ImportProgressDialog

const PROGRESS_DIALOG_SCENE := preload("res://addons/asset_manager/ui/import_progress/import_progress.tscn")

@onready var toolbar: AssetToolbar = $MarginContainer/RootVBox/Toolbar
@onready var main_split: HSplitContainer = $MarginContainer/RootVBox/MainSplit
@onready var content_split: HSplitContainer = $MarginContainer/RootVBox/MainSplit/ContentSplit
@onready var _sidebar: SidebarNavigator = $MarginContainer/RootVBox/MainSplit/Sidebar
@onready var _grid: AssetGrid = $MarginContainer/RootVBox/MainSplit/ContentSplit/CenterPanel
@onready var _preview: PreviewPanel = $MarginContainer/RootVBox/MainSplit/ContentSplit/PreviewPanel
@onready var folder_dialog: FileDialog = $FolderDialog
@onready var project_settings_dialog: ProjectSettingsDialog = $ProjectSettingsDialog
@onready var tag_context_menu: PopupMenu = $TagContextMenu

func _notification(what: int) -> void:
	# Fires only when focus returns from outside the godot process.
	if what == NOTIFICATION_APPLICATION_FOCUS_IN:
		sync_if_stale()

func _ready() -> void:
	if EditorGuard.is_scene_tab(self):
		return

	_apply_outer_margin()
	_restore_panel_widths()

	_progress_dialog = PROGRESS_DIALOG_SCENE.instantiate()
	add_child(_progress_dialog)

	_sidebar.filter_changed.connect(_on_filter_changed)
	_grid.selection_changed.connect(_on_selection_changed)

	_preview.send_to_project_pressed.connect(_on_send_to_project_pressed)
	_preview.open_external_pressed.connect(_on_open_external_pressed)
	_preview.open_location_pressed.connect(_on_open_location_pressed)
	_preview.add_tag_requested.connect(_on_add_tag_requested)
	_preview.remove_tag_requested.connect(_on_remove_tag_requested)
	_preview.tag_search_changed.connect(_on_tag_input_text_changed)

	toolbar.search_changed.connect(func(_text: String) -> void: _on_filter_changed())
	toolbar.rebuild_pressed.connect(_on_rebuild_pressed)
	toolbar.settings_pressed.connect(func() -> void: project_settings_dialog.open())
	toolbar.sidebar_toggled.connect(func(collapsed: bool) -> void: _sidebar.visible = not collapsed)

	_preview.setup(_settings)
	_init_workspace_picker()

## The plugin fills the main screen the way 2D/3D/Script do, so it should sit
## as flush to the edges as they do. interface/theme/base_spacing is the
## user's own setting, the same value the editor derives its own margins from.
func _apply_outer_margin() -> void:
	var margin := 0
	if Engine.is_editor_hint():
		var spacing: int = EditorInterface.get_editor_settings().get_setting("interface/theme/base_spacing")
		margin = int(spacing * EditorInterface.get_editor_scale())

	var container: MarginContainer = $MarginContainer
	for side in ["left", "top", "right", "bottom"]:
		container.add_theme_constant_override("margin_" + side, margin)

## Widths are stored unscaled and multiplied on the way out, so a workspace
## moved between a 4K and a 1080p machine gets a sane size on each.
func _restore_panel_widths() -> void:
	var scale := EditorInterface.get_editor_scale() if Engine.is_editor_hint() else 1.0

	main_split.split_offset = int(_settings.get_sidebar_width(SidebarNavigator.BASE_DEFAULT_WIDTH) * scale)
	content_split.split_offset = int(_settings.get_preview_width(PreviewPanel.BASE_DEFAULT_WIDTH) * scale)

	main_split.dragged.connect(func(offset: int) -> void:
		_settings.set_sidebar_width(int(offset / scale))
	)
	content_split.dragged.connect(func(offset: int) -> void:
		_settings.set_preview_width(int(offset / scale))
	)

## Called by plugin.gd when the tab is switched to.
func focus_search() -> void:
	if toolbar:
		toolbar.focus_search()

func _shortcut_input(event: InputEvent) -> void:
	if not visible or not is_visible_in_tree():
		return
	var key := event as InputEventKey
	if key == null or not key.pressed:
		return
	if key.keycode == KEY_F and (key.ctrl_pressed or key.meta_pressed):
		toolbar.focus_search_and_select()
		get_viewport().set_input_as_handled()

## Only reads index.db's version field, not the full asset list.
func sync_if_stale() -> void:
	if _database == null:
		return
	if _database.has_newer_version_on_disk():
		_database.sync()
		_refresh_all_after_index_change()
		print("AssetManager: synced, version ", _database.version, ", assets: ", _database.assets.size())

func _refresh_all_after_index_change() -> void:
	_sidebar.refresh()
	_on_filter_changed()

## The one place the sidebar's filter state and the toolbar's search meet, the
## grid is handed a plain description of what to show and never reads either.
func _on_filter_changed() -> void:
	_grid.set_filter(
		_sidebar.active_folder_prefix,
		_sidebar.active_tags,
		_sidebar.active_extensions,
		toolbar.search_text(),
		_sidebar.active_type_id
	)

func _on_rebuild_pressed() -> void:
	if current_workspace_path.is_empty():
		return

	# Sync must always happen before rebuild, so a rebuild from a stale local
	# base can't silently drop tag changes a teammate wrote since our last sync.
	sync_if_stale()

	toolbar.set_rebuilding(true)

	var importer := AssetImporter.new()
	importer.progress.connect(_progress_dialog.on_progress)
	_progress_dialog.start()

	var started := Time.get_ticks_msec()
	var ok := await importer.run_import(current_workspace_path, _database, self)
	var elapsed := (Time.get_ticks_msec() - started) / 1000.0

	_progress_dialog.finish()
	toolbar.set_rebuilding(false)

	if ok:
		print("AssetManager: rebuilt index: %d assets in %.1fs (by type: %s), version %d"
			% [_database.assets.size(), elapsed, importer.per_type_counts, _database.version])
		_refresh_all_after_index_change()
	else:
		push_error("AssetManager: failed to write index.db")

func _on_add_tag_requested(tag_text: String) -> void:
	sync_if_stale()
	_preview.apply_tag_change(_selected_paths(), tag_text, true)
	_sidebar.refresh()

func _on_remove_tag_requested(tag_text: String) -> void:
	sync_if_stale()
	_preview.apply_tag_change(_selected_paths(), tag_text, false)

	# The tag just removed may have been the last instance anywhere.
	if not _database.get_all_known_tags().has(tag_text) and _sidebar.active_tags.has(tag_text):
		_sidebar.active_tags.erase(tag_text)
		_on_filter_changed()

	_sidebar.refresh()

func _on_tag_input_text_changed() -> void:
	_preview.refresh_tags(_selected_paths())

func _init_workspace_picker() -> void:
	_workspace_picker = preload("res://addons/asset_manager/ui/workspace_picker/workspace_picker.tscn").instantiate()
	_workspace_picker.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_workspace_picker)
	# Only a real click builds a missing index, opening the editor on some
	# other tab shouldn't kick off a long import nobody asked for.
	_workspace_picker.workspace_opened.connect(func(path: String) -> void:
		_on_workspace_opened(path, true)
	)

	var remembered_path := _workspace_picker.try_auto_load()
	if remembered_path.is_empty():
		_show_workspace_picker(true)
	else:
		_on_workspace_opened(remembered_path, false)

func _show_workspace_picker(is_visible: bool) -> void:
	_workspace_picker.visible = is_visible
	$MarginContainer.visible = not is_visible

func _on_workspace_opened(path: String, from_picker: bool = false) -> void:
	current_workspace_path = path
	_show_workspace_picker(false)

	_database = AssetDatabase.new()
	_database.workspace_path = path
	_preview.set_database(_database)
	_sidebar.database = _database
	_sidebar.workspace_path = path
	_thumbnails.setup(path)
	_grid.setup(_database, _settings, _thumbnails)

	var had_index := _database.sync()
	print("AssetManager: workspace opened, index found: ", had_index, ", version: ", _database.version, ", assets: ", _database.assets.size())
	_refresh_all_after_index_change()

	# A workspace with no index is brand new or had one deleted, and building
	# it is the only useful next step. Deferred so the empty grid paints first:
	# going straight from the picker to a progress dialog looks like the picker
	# hung.
	if not had_index and from_picker:
		call_deferred("_on_rebuild_pressed")

## Multi-select is gone, the preview never supported it. Kept as an array
## because the tag editor still takes one.
func _selected_paths() -> Array:
	return [current_selected_path] if not current_selected_path.is_empty() else []

func _on_selection_changed(path: String) -> void:
	current_selected_path = path

	var has_selection := not path.is_empty()
	_preview.set_actions_enabled(has_selection)

	if has_selection:
		_preview.show_asset(path, _database.get_type_for_path(path))
		asset_selected.emit(path)
	else:
		_preview.clear()

	_preview.refresh_tags(_selected_paths())

func _on_open_external_pressed() -> void:
	if not current_selected_path.is_empty():
		OS.shell_open(current_selected_path)

func _on_open_location_pressed() -> void:
	if not current_selected_path.is_empty():
		OS.shell_show_in_file_manager(current_selected_path)

func _on_send_to_project_pressed() -> void:
	if current_selected_path.is_empty():
		return

	var type_id := _database.get_type_for_path(current_selected_path)
	if type_id.is_empty():
		return

	var dest_dir := project_settings_dialog.get_export_root(type_id)
	var result := AssetExporter.export_asset(current_selected_path, dest_dir, type_id, current_workspace_path)

	for error_msg in result["errors"]:
		push_error("AssetManager: ", error_msg)

	# Copied files don't show up in the FileSystem dock otherwise.
	_notify_filesystem_of_new_files(result["copied_paths"])

	var summary := str(result["copied_count"]) + " file(s) copied"
	if result["skipped_existing_count"] > 0:
		summary += ", " + str(result["skipped_existing_count"]) + " already present"
	if not result["errors"].is_empty():
		summary += ", " + str(result["errors"].size()) + " error(s)"
	_preview.flash_send_result(summary)

## scan_sources() + awaiting resources_reimported works around a Godot core
## reentrancy bug (godotengine/godot#54864). Re-test before changing it.
func _notify_filesystem_of_new_files(paths: Array) -> void:
	if paths.is_empty() or not Engine.is_editor_hint():
		return

	var efs := EditorInterface.get_resource_filesystem()
	efs.scan_sources()
	await efs.resources_reimported
