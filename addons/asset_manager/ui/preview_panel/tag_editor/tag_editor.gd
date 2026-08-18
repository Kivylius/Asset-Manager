@tool
class_name TagEditor
extends VBoxContainer

signal add_tag_requested(tag_text: String)
signal remove_tag_requested(tag_text: String)

signal search_text_changed

var database: AssetDatabase

var _last_shared_tags: Array[String] = []

@onready var _current_tags_container: HFlowContainer = $VBox/TagFlowContainer
@onready var _available_tags_container: HBoxContainer = $VBox/ExpandPanel/SuggestionCard/SuggestionScroll/AvailableTagsFlowContainer
@onready var _tag_input_field: LineEdit = $VBox/TagsRow/TagInputField
@onready var _add_tag_button: Button = $VBox/TagsRow/AddTagButton
@onready var _expand_panel: MarginContainer = $VBox/ExpandPanel
@onready var _tags_row: HBoxContainer = $VBox/TagsRow
@onready var _display_row: HFlowContainer = $VBox/DisplayRow
@onready var _edit_button: Button = $VBox/DisplayRow/EditButton

func _ready() -> void:
	if EditorGuard.is_scene_tab(self):
		return

	_tag_input_field.text_submitted.connect(on_tag_input_submitted)
	_tag_input_field.text_changed.connect(func(_new_text: String) -> void:
		_update_add_tag_button()
		search_text_changed.emit()
	)
	_add_tag_button.pressed.connect(func() -> void: on_tag_input_submitted(_tag_input_field.text))
	_tag_input_field.focus_entered.connect(func() -> void: _expand_panel.visible = true)
	_tag_input_field.focus_exited.connect(func() -> void: call_deferred("_hide_expand_panel"))
	_edit_button.pressed.connect(_enter_edit_mode)

	_apply_style()
	_set_editing(false)

func _apply_style() -> void:
	if not Engine.is_editor_hint():
		return
	var theme := EditorInterface.get_editor_theme()
	if theme == null:
		return

	if theme.has_color("font_disabled_color", "Editor"):
		var dim := theme.get_color("font_disabled_color", "Editor")
		_edit_button.add_theme_color_override("font_color", dim)
		_edit_button.add_theme_color_override("font_hover_color", theme.get_color("font_color", "Editor"))

	_style_suggestions(theme)

## The suggestions belong to the field above them, so they borrow the
## LineEdit's own background and are pulled up by the field's corner radius,
## enough to sit flush against it and read as one control rather than two
## stacked boxes.
func _style_suggestions(theme: Theme) -> void:
	var scale := EditorInterface.get_editor_scale()
	var spacing: int = EditorInterface.get_editor_settings().get_setting("interface/theme/base_spacing")

	# The field's own stylebox, not the global corner_radius setting, the
	# theme builds LineEdit with its own radius, already scaled.
	var radius := 0
	var box := StyleBoxFlat.new()
	if theme.has_stylebox("normal", "LineEdit"):
		var field_box := theme.get_stylebox("normal", "LineEdit")
		if field_box is StyleBoxFlat:
			var flat := field_box as StyleBoxFlat
			box.bg_color = flat.bg_color
			radius = flat.corner_radius_bottom_left

	box.corner_radius_bottom_left = radius
	box.corner_radius_bottom_right = radius

	var pad := int(spacing * scale)
	box.content_margin_left = int(spacing * 2 * scale)
	box.content_margin_right = int(spacing * 2 * scale)
	box.content_margin_top = pad
	box.content_margin_bottom = pad

	$VBox/ExpandPanel/SuggestionCard.add_theme_stylebox_override("panel", box)
	_expand_panel.add_theme_constant_override("margin_top", -radius)



func _set_editing(editing: bool) -> void:
	_display_row.visible = not editing
	_tags_row.visible = editing
	_current_tags_container.visible = editing
	if not editing:
		_expand_panel.visible = false

func _enter_edit_mode() -> void:
	_set_editing(true)
	_tag_input_field.grab_focus()

func _hide_expand_panel() -> void:
	_expand_panel.visible = false
	# Leaving the field is the only exit, no close button.
	if not _tag_input_field.has_focus():
		_set_editing(false)

## Toggling visibility pulls the button out of the container's layout, which
## resizes the input field on every keystroke, disabling keeps its width.
func _update_add_tag_button() -> void:
	var clean_text := _tag_input_field.text.strip_edges().to_lower().replace(" ", "_")
	_add_tag_button.disabled = clean_text.is_empty() or _last_shared_tags.has(clean_text)

func on_preview_clicked() -> void:
	if _tag_input_field.has_focus():
		_tag_input_field.clear()
		_tag_input_field.release_focus()

func refresh_ui(selected_paths: Array) -> void:
	visible = not selected_paths.is_empty()
	if not visible:
		return

	for child in _current_tags_container.get_children():
		child.queue_free()
	for child in _available_tags_container.get_children():
		child.queue_free()

	if database == null:
		_update_display_row([])
		return

	var shared_tags: Array[String] = _get_shared_tags(selected_paths)

	var chip_dim := Color.WHITE
	if Engine.is_editor_hint():
		var chip_theme := EditorInterface.get_editor_theme()
		if chip_theme != null and chip_theme.has_color("font_disabled_color", "Editor"):
			chip_dim = chip_theme.get_color("font_disabled_color", "Editor")

	# The same dot-separated line as the collapsed row, with × standing in for
	# the separator. Editing should read as that row with handles, not a
	# second style.
	for tag in shared_tags:
		var btn := Button.new()
		btn.text = tag + " ×"
		btn.flat = true
		btn.focus_mode = Control.FOCUS_NONE
		btn.add_theme_stylebox_override("normal", StyleBoxEmpty.new())
		btn.add_theme_color_override("font_color", chip_dim)
		btn.add_theme_color_override("font_hover_color", Color.WHITE)
		var captured_tag := tag
		btn.pressed.connect(func() -> void: remove_tag_requested.emit(captured_tag))
		btn.tooltip_text = "Click to remove"
		_current_tags_container.add_child(btn)

	_last_shared_tags = shared_tags
	_update_add_tag_button()
	_update_display_row(shared_tags)

	var search_text := _tag_input_field.text.strip_edges().to_lower().replace(" ", "_")
	var available_tags: Array[String] = []

	for tag in database.get_all_known_tags():
		if available_tags.size() >= 3:
			break
		if not shared_tags.has(tag):
			if search_text.is_empty() or search_text.is_subsequence_ofn(tag):
				available_tags.append(tag)

	# Suggestions are a menu, your tags are data. Styling both as chips makes
	# the six suggestions shout louder than the three real tags, so these stay
	# flat and dim to read as a hint rather than a row of controls.
	var dim := Color.WHITE
	if Engine.is_editor_hint():
		var editor_theme := EditorInterface.get_editor_theme()
		if editor_theme != null and editor_theme.has_color("font_disabled_color", "Editor"):
			dim = editor_theme.get_color("font_disabled_color", "Editor")

	for i in available_tags.size():
		var tag: String = available_tags[i]
		var btn := Button.new()
		btn.text = tag
		btn.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		btn.focus_mode = Control.FOCUS_NONE
		btn.theme_type_variation = "FlatButton"
		btn.add_theme_color_override("font_color", dim)
		btn.add_theme_color_override("font_hover_color", Color.WHITE)
		var captured_tag := tag
		btn.pressed.connect(func() -> void:
			add_tag_requested.emit(captured_tag)
			_tag_input_field.clear()
			_tag_input_field.release_focus()
		)
		btn.tooltip_text = "Click to add"
		_available_tags_container.add_child(btn)

## With no tags the button carries the empty state itself ("Add tag") rather
## than a pencil sitting next to an empty line, which reads as broken.
## One Label per tag rather than one Label holding the joined string: a short
## label sits at its natural width without argument, whereas a long one can
## neither shrink (its minimum is its text) nor be given a width without
## taking the whole row. Split up, the flow container wraps to a second line.
func _update_display_row(tags: Array[String]) -> void:
	for child in _display_row.get_children():
		if child != _edit_button:
			_display_row.remove_child(child)
			child.queue_free()

	# Editor Labels carry their own content margins (theme_modern.cpp:1239),
	# which container separation can't reach, so the gap is cleared per label
	# and the separator carried in the text instead.
	var flush := StyleBoxEmpty.new()

	var dim := Color.WHITE
	if Engine.is_editor_hint():
		var row_theme := EditorInterface.get_editor_theme()
		if row_theme != null and row_theme.has_color("font_disabled_color", "Editor"):
			dim = row_theme.get_color("font_disabled_color", "Editor")

	for i in tags.size():
		var tag_label := Label.new()
		tag_label.text = tags[i] if i == tags.size() - 1 else tags[i] + " · "
		tag_label.add_theme_stylebox_override("normal", flush)
		tag_label.add_theme_color_override("font_color", dim)
		_display_row.add_child(tag_label)

	_display_row.move_child(_edit_button, -1)

	var empty := tags.is_empty()
	_edit_button.text = "Add tag" if empty else ""

	IconHelper.apply(_edit_button, "Add" if empty else "Edit")

func on_tag_input_submitted(new_text: String) -> void:
	_tag_input_field.clear()
	add_tag_requested.emit(new_text)
	_tag_input_field.release_focus()

func set_input_editable(editable: bool) -> void:
	_tag_input_field.editable = editable

func apply_tag_change(selected_paths: Array, tag_text: String, add: bool) -> void:
	var clean_tag := tag_text.strip_edges().to_lower().replace(" ", "_") if add else tag_text
	if add and clean_tag.is_empty():
		return
	if selected_paths.is_empty():
		return

	for path in selected_paths:
		var tags := database.get_tags_for_path(path)
		if add and not tags.has(clean_tag):
			tags.append(clean_tag)
			database.update_tags(path, tags)
		elif not add and tags.has(clean_tag):
			tags.erase(clean_tag)
			database.update_tags(path, tags)

	refresh_ui(selected_paths)

func _get_shared_tags(selected_paths: Array) -> Array[String]:
	var shared_tags := database.get_tags_for_path(selected_paths[0])

	for i in range(1, selected_paths.size()):
		var current_tags := database.get_tags_for_path(selected_paths[i])
		var intersection: Array[String] = []
		for tag in shared_tags:
			if current_tags.has(tag):
				intersection.append(tag)
		shared_tags = intersection

	return shared_tags
