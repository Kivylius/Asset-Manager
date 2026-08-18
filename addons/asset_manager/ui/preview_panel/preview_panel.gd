@tool
class_name PreviewPanel
extends PanelContainer

signal send_to_project_pressed
signal open_external_pressed
signal open_location_pressed
signal add_tag_requested(tag_text: String)
signal remove_tag_requested(tag_text: String)
signal tag_search_changed

const TYPE_SCENES: Dictionary = {
	"models": preload("res://addons/asset_manager/ui/preview_panel/types/models/models.tscn"),
	"sounds": preload("res://addons/asset_manager/ui/preview_panel/types/audio/audio.tscn"),
	"music": preload("res://addons/asset_manager/ui/preview_panel/types/audio/audio.tscn"),
	"images": preload("res://addons/asset_manager/ui/preview_panel/types/images/images.tscn"),
	"videos": preload("res://addons/asset_manager/ui/preview_panel/types/videos/videos.tscn"),
	"materials": preload("res://addons/asset_manager/ui/preview_panel/types/materials/materials.tscn"),
	"shaders": preload("res://addons/asset_manager/ui/preview_panel/types/shaders/shaders.tscn"),
	"effects": preload("res://addons/asset_manager/ui/preview_panel/types/effects/effects.tscn"),
	"scenes": preload("res://addons/asset_manager/ui/preview_panel/types/scenes/scenes.tscn"),
}
const OTHER_SCENE := preload("res://addons/asset_manager/ui/preview_panel/types/other/other.tscn")

## Wider than the sidebar because it holds a viewport rather than a tree, but
## only a little, the grid is what the space is for. Same minimum as the sidebar.
const BASE_MIN_WIDTH: int = 170
const BASE_DEFAULT_WIDTH: int = -320

var database: AssetDatabase

var _bodies: Dictionary = {}
var _current_type: String = ""

@onready var _stage: PanelContainer = $VBox/Stage
@onready var _slot: Control = $VBox/Stage/PreviewSlot
@onready var _card: PanelContainer = $VBox/Card
@onready var _name_label: Label = $VBox/Card/CardBox/Meta/FileNameLabel
@onready var _detail_label: Label = $VBox/Card/CardBox/Meta/DetailLabel
@onready var _tag_editor: TagEditor = $VBox/Card/CardBox/TagEditor
@onready var _send_button: Button = $VBox/Actions/SendToProjectButton
@onready var _external_button: Button = $VBox/Actions/OpenExternalButton
@onready var _location_button: Button = $VBox/Actions/OpenLocationButton

func _ready() -> void:
	if EditorGuard.is_scene_tab(self):
		return

	_stage.gui_input.connect(_on_stage_gui_input)

	_send_button.pressed.connect(func() -> void: send_to_project_pressed.emit())
	_external_button.pressed.connect(func() -> void: open_external_pressed.emit())
	_location_button.pressed.connect(func() -> void: open_location_pressed.emit())

	_tag_editor.add_tag_requested.connect(func(t: String) -> void: add_tag_requested.emit(t))
	_tag_editor.remove_tag_requested.connect(func(t: String) -> void: remove_tag_requested.emit(t))
	_tag_editor.search_text_changed.connect(func() -> void: tag_search_changed.emit())

	if Engine.is_editor_hint():
		custom_minimum_size = Vector2(BASE_MIN_WIDTH * EditorInterface.get_editor_scale(), 0)

	_apply_style()

## Send to Project is what the panel is for, so it takes the width and the accent
## icon. Reveal and open-external are occasional, so they shrink to icons.
func _apply_style() -> void:
	if not Engine.is_editor_hint():
		return
	var theme := EditorInterface.get_editor_theme()
	if theme == null:
		return

	if theme.has_stylebox("panel", "TreeSecondary"):
		add_theme_stylebox_override("panel", theme.get_stylebox("panel", "TreeSecondary"))


	_set_icon(_send_button, "Add")
	_set_icon(_external_button, "ExternalLink", true)
	_set_icon(_location_button, "Folder", true)

	if theme.has_color("font_disabled_color", "Editor"):
		_detail_label.add_theme_color_override("font_color", theme.get_color("font_disabled_color", "Editor"))

	# Every Label in the editor theme carries its own content margins
	# (theme_modern.cpp:1239), top and bottom padding inside the label itself,
	# which container separation can't reach. Two stacked labels therefore sit
	# four margins apart however tightly the container is set.
	var flush := StyleBoxEmpty.new()
	_name_label.add_theme_stylebox_override("normal", flush)
	_detail_label.add_theme_stylebox_override("normal", flush)

	var spacing: int = EditorInterface.get_editor_settings().get_setting("interface/theme/base_spacing")
	$VBox.add_theme_constant_override("separation", int(spacing * EditorInterface.get_editor_scale()))

	_style_card(theme, spacing)

## A tier below the panel, not another copy of it, the card has to read as
## sitting inside the panel rather than as a second panel butted against it.
func _style_card(theme: Theme, spacing: int) -> void:
	var scale := EditorInterface.get_editor_scale()
	var radius: int = EditorInterface.get_editor_settings().get_setting("interface/theme/corner_radius")

	var box := StyleBoxFlat.new()
	if theme.has_color("base_color", "Editor"):
		box.bg_color = theme.get_color("base_color", "Editor")
	box.set_corner_radius_all(int(radius * scale))

	var pad := int(spacing * 2 * scale)
	box.content_margin_left = pad
	box.content_margin_right = pad
	box.content_margin_top = pad
	box.content_margin_bottom = pad

	_card.add_theme_stylebox_override("panel", box)
	$VBox/Card/CardBox.add_theme_constant_override("separation", int(spacing * scale))

## clip_contents only clips rectangles, so a SubViewport's texture lands square.
## CLIP_CHILDREN_ONLY instead makes this node a mask from its own alpha, the
## rounded stylebox it draws becomes the shape its children are clipped to.
func _round_stage_corners() -> void:
	var radius: int = EditorInterface.get_editor_settings().get_setting("interface/theme/corner_radius")
	if radius <= 0:
		return

	var mask := StyleBoxFlat.new()
	mask.bg_color = Color.WHITE
	mask.set_corner_radius_all(int(radius * EditorInterface.get_editor_scale()))

	_stage.add_theme_stylebox_override("panel", mask)
	_stage.clip_children = CanvasItem.CLIP_CHILDREN_ONLY

## icon_only is coupled to the icon actually resolving, clearing the text when
## the lookup failed would leave a button with neither.
func _set_icon(button: Button, icon_name: String, icon_only: bool = false) -> void:
	var icon := IconHelper.get_icon(icon_name)
	if icon == null:
		return
	button.icon = icon
	if icon_only:
		button.text = ""

## One body per scene, not per type, sounds and music are both AudioPreview, so
## they share a single instance keyed under both ids.
func setup(settings: SettingsManager) -> void:
	var by_scene: Dictionary = {}

	for type_id: String in TYPE_SCENES:
		var scene: PackedScene = TYPE_SCENES[type_id]

		if not by_scene.has(scene):
			var body: Control = scene.instantiate()
			_slot.add_child(body)
			if body.has_method("setup"):
				body.setup(settings)
			body.visible = false
			by_scene[scene] = body

		_bodies[type_id] = by_scene[scene]

	var other: Control = OTHER_SCENE.instantiate()
	_slot.add_child(other)
	other.visible = false
	_bodies["other"] = other

	# Last, so it draws over every preview body rather than under them.
	_round_stage_corners()

func show_asset(path: String, type_id: String) -> void:
	hide_current()

	_name_label.text = path.get_file()
	_detail_label.text = _describe(path, type_id)
	_current_type = type_id

	var body: Control = _bodies.get(type_id, _bodies["other"])
	body.show_asset(path, AssetTypes.get_by_id(type_id))

## Pack, size and type on one line, the things you'd check before sending an
## asset to a project.
func _describe(path: String, type_id: String) -> String:
	var parts: PackedStringArray = []

	var file := FileAccess.open(path, FileAccess.READ)
	if file:
		parts.append(String.humanize_size(file.get_length()))
		file.close()

	parts.append(path.get_extension().to_upper())

	var label: String = AssetTypes.get_by_id(type_id).get("label", type_id)
	parts.append(label)

	return " · ".join(parts)

func hide_current() -> void:
	if _current_type.is_empty():
		return
	var body: Control = _bodies.get(_current_type, _bodies["other"])
	body.hide_asset()
	_current_type = ""

func clear() -> void:
	hide_current()
	_name_label.text = "No asset selected"
	_detail_label.text = ""

func set_actions_enabled(enabled: bool) -> void:
	_send_button.disabled = not enabled
	_external_button.disabled = not enabled
	_location_button.disabled = not enabled
	_tag_editor.set_input_editable(enabled)

func refresh_tags(selected_paths: Array) -> void:
	_tag_editor.refresh_ui(selected_paths)

func apply_tag_change(selected_paths: Array, tag_text: String, add: bool) -> void:
	_tag_editor.apply_tag_change(selected_paths, tag_text, add)

func set_database(p_database: AssetDatabase) -> void:
	database = p_database
	_tag_editor.database = p_database

func flash_send_result(summary: String) -> void:
	var original := _send_button.text
	_send_button.text = summary
	get_tree().create_timer(2.5).timeout.connect(func() -> void: _send_button.text = original)

func _on_stage_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		_tag_editor.on_preview_clicked()

	var body: Variant = _bodies.get(_current_type, null)
	if body != null and body.has_method("handle_gui_input"):
		body.handle_gui_input(event)
