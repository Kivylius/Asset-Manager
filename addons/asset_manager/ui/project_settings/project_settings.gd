@tool
class_name ProjectSettingsDialog
extends AcceptDialog

const PROJECT_SETTING_EXPORT_ROOTS: String = "asset_manager/export_roots"

var _export_root_edits: Dictionary = {} ## type_id -> LineEdit
var _export_root_dialog: FileDialog
var _export_root_dialog_target: String = ""

@onready var _export_roots_vbox: VBoxContainer = $VBox/ExportRootsVBox
@onready var _version_label: Label = $VBox/Footer/FooterBox/VersionLabel

func _ready() -> void:
	if EditorGuard.is_scene_tab(self):
		return

	_version_label.text = "Asset Manager v" + _get_plugin_version()

	_export_root_dialog = FileDialog.new()
	_export_root_dialog.title = "Choose Export Destination"
	_export_root_dialog.size = Vector2i(600, 400)
	_export_root_dialog.ok_button_text = "Select Folder"
	_export_root_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	_export_root_dialog.access = FileDialog.ACCESS_RESOURCES
	_export_root_dialog.dir_selected.connect(_on_export_root_dir_selected)
	add_child(_export_root_dialog)

	_build_export_root_rows()

func _get_plugin_version() -> String:
	var cfg := ConfigFile.new()
	if cfg.load("res://addons/asset_manager/plugin.cfg") != OK:
		return "?"
	return cfg.get_value("plugin", "version", "?")

func _build_export_root_rows() -> void:
	for child in _export_roots_vbox.get_children():
		child.queue_free()
	_export_root_edits.clear()

	var scale := EditorInterface.get_editor_scale() if Engine.is_editor_hint() else 1.0

	for type_entry in AssetTypes.ALL:
		var type_id: String = type_entry["id"]

		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 12)
		_export_roots_vbox.add_child(row)

		var label := Label.new()
		label.text = type_entry["label"]
		label.custom_minimum_size = Vector2(180, 0)
		row.add_child(label)

		var edit := LineEdit.new()
		edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		# the dialog sizes to its content, so without a floor here the field
		# collapses to whatever the path happens to be and truncates
		edit.custom_minimum_size = Vector2(280 * scale, 0)
		edit.placeholder_text = type_entry["default_export_path"]
		edit.text_submitted.connect(func(text: String) -> void: set_export_root(type_id, text))
		edit.focus_exited.connect(func() -> void: set_export_root(type_id, edit.text))
		row.add_child(edit)
		_export_root_edits[type_id] = edit

		var browse_btn := Button.new()
		browse_btn.text = "Browse"
		browse_btn.pressed.connect(func() -> void:
			_export_root_dialog_target = type_id
			_export_root_dialog.popup_centered()
		)
		row.add_child(browse_btn)

func _on_export_root_dir_selected(dir: String) -> void:
	if _export_root_dialog_target.is_empty():
		return
	_export_root_edits[_export_root_dialog_target].text = dir
	set_export_root(_export_root_dialog_target, dir)

func _populate_ui_from_settings() -> void:
	for type_id: String in _export_root_edits:
		_export_root_edits[type_id].text = get_export_root(type_id)

func open() -> void:
	_populate_ui_from_settings()
	popup_centered(size)

func get_export_root(type_id: String) -> String:
	var roots: Dictionary = _get_export_roots_dict()
	if roots.has(type_id):
		return roots[type_id]
	return AssetTypes.get_by_id(type_id).get("default_export_path", "res://assets")

func set_export_root(type_id: String, value: String) -> void:
	var roots: Dictionary = _get_export_roots_dict()
	roots[type_id] = value
	ProjectSettings.set_setting(PROJECT_SETTING_EXPORT_ROOTS, roots)
	ProjectSettings.save()

func _get_export_roots_dict() -> Dictionary:
	if not ProjectSettings.has_setting(PROJECT_SETTING_EXPORT_ROOTS):
		return {}
	var value: Variant = ProjectSettings.get_setting(PROJECT_SETTING_EXPORT_ROOTS, {})
	if value is Dictionary:
		return value
	return {}
