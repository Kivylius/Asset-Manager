@tool
class_name WorkspacePicker
extends Control

signal workspace_opened(workspace_path: String)

const MARKER_FILE_NAME: String = ".assetmanager/marker"
const MARKER_VERSION: int = 1

@onready var title_label: Label = $CenterContainer/PanelContainer/VBoxContainer/TitleLabel
@onready var version_label: Label = $CenterContainer/PanelContainer/VBoxContainer/VersionLabel
@onready var open_button: Button = $CenterContainer/PanelContainer/VBoxContainer/ButtonRow/OpenButton
@onready var new_button: Button = $CenterContainer/PanelContainer/VBoxContainer/ButtonRow/NewButton
@onready var status_label: Label = $CenterContainer/PanelContainer/VBoxContainer/StatusLabel
@onready var open_dialog: FileDialog = $OpenDialog
@onready var new_dialog: FileDialog = $NewDialog

func _ready() -> void:
	if EditorGuard.is_scene_tab(self):
		return

	title_label.text = "Asset Manager"
	version_label.text = "v" + _get_plugin_version()
	status_label.text = ""

	open_button.pressed.connect(_on_open_pressed)
	new_button.pressed.connect(_on_new_pressed)
	open_dialog.dir_selected.connect(_on_open_dir_selected)
	new_dialog.dir_selected.connect(_on_new_dir_selected)

func try_auto_load() -> String:
	var remembered_path := _read_workspace_pointer()
	if remembered_path.is_empty():
		return ""
	if not is_valid_workspace(remembered_path):
		return ""
	return remembered_path

func is_valid_workspace(path: String) -> bool:
	if not DirAccess.dir_exists_absolute(path):
		return false
	var marker_path := path.path_join(MARKER_FILE_NAME)
	return FileAccess.file_exists(marker_path)

func _on_open_pressed() -> void:
	open_dialog.popup_centered_ratio(0.6)

func _on_new_pressed() -> void:
	new_dialog.popup_centered_ratio(0.6)

func _on_open_dir_selected(path: String) -> void:
	if is_valid_workspace(path):
		_write_workspace_pointer(path)
		status_label.text = ""
		workspace_opened.emit(path)
	else:
		status_label.text = "Not a valid Asset Manager workspace: " + path

func _on_new_dir_selected(path: String) -> void:
	if is_valid_workspace(path):
		status_label.text = "A workspace already exists here. Opening it instead."
		_write_workspace_pointer(path)
		workspace_opened.emit(path)
		return

	var dir := DirAccess.open(path)
	if dir == null:
		status_label.text = "Could not access folder: " + path
		return

	for subfolder in AssetTypes.get_folder_names():
		var err := dir.make_dir_recursive(subfolder)
		if err != OK and err != ERR_ALREADY_EXISTS:
			status_label.text = "Failed to create '" + subfolder + "' folder."
			return

	# everything the plugin owns lives in one folder rather than three loose items
	# beside the user's own asset folders. The leading dot hides it on macOS and
	# Linux; Windows needs the attribute set explicitly.
	var plugin_dir := path.path_join(MARKER_FILE_NAME.get_base_dir())
	if dir.make_dir_recursive(MARKER_FILE_NAME.get_base_dir()) != OK and not DirAccess.dir_exists_absolute(plugin_dir):
		status_label.text = "Failed to create plugin folder."
		return
	FileAccess.set_hidden_attribute(plugin_dir, true)

	var marker_file := FileAccess.open(path.path_join(MARKER_FILE_NAME), FileAccess.WRITE)
	if marker_file == null:
		status_label.text = "Failed to write workspace marker file."
		return
	marker_file.store_var({"version": MARKER_VERSION})
	marker_file.close()

	_write_workspace_pointer(path)
	status_label.text = ""
	workspace_opened.emit(path)

func _get_plugin_version() -> String:
	var cfg := ConfigFile.new()
	var err := cfg.load("res://addons/asset_manager/plugin.cfg")
	if err != OK:
		return "?"
	return cfg.get_value("plugin", "version", "?")

func _read_workspace_pointer() -> String:
	return AssetManagerConfig.get_value("workspace", "path", "")

func _write_workspace_pointer(path: String) -> void:
	AssetManagerConfig.set_value("workspace", "path", path)
