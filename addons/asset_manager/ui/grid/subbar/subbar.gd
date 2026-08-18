@tool
class_name GridSubbar
extends HBoxContainer

signal sort_changed(mode: int)
signal page_changed(delta: int)
signal per_page_changed(count: int)
signal tile_size_changed(size: int)
signal view_mode_changed(is_grid: bool)
signal subtype_changed(subtype: String)

enum Sort { NAME, RECENT, SIZE }

const SORT_LABELS: Array[String] = ["Name", "Recently added", "File size"]

## Matches the range the +/- buttons stepped through.
const MIN_TILE_SIZE: int = 16
const MAX_TILE_SIZE: int = 256

## Godot's own thumbnail-size slider is 64 wide (filesystem_dock.cpp:4623).
const BASE_SLIDER_WIDTH: int = 96

@onready var _sort_option: OptionButton = $SortOption
@onready var _filter_slot: OptionButton = $FilterSlot
@onready var _per_page_option: OptionButton = $Pager/PerPageOption
@onready var _prev_button: Button = $Pager/PrevButton
@onready var _page_label: Label = $Pager/PageLabel
@onready var _next_button: Button = $Pager/NextButton
@onready var _size_slider: HSlider = $SizeBox/SizeSlider
@onready var _view_button: Button = $ViewButton

var _is_grid: bool = true

func _ready() -> void:
	if EditorGuard.is_scene_tab(self):
		return

	for i in SORT_LABELS.size():
		_sort_option.add_item(SORT_LABELS[i], i)
	# Selecting copies the item's icon onto the button (option_button.cpp:464),
	# so the button's own icon has to go back each time.
	_sort_option.item_selected.connect(func(idx: int) -> void:
		sort_changed.emit(idx)
		_set_icon(_sort_option, "Sort")
	)

	_prev_button.pressed.connect(func() -> void: page_changed.emit(-1))
	_next_button.pressed.connect(func() -> void: page_changed.emit(1))
	_per_page_option.item_selected.connect(func(idx: int) -> void:
		per_page_changed.emit(_per_page_option.get_item_id(idx))
	)

	var scale := EditorInterface.get_editor_scale() if Engine.is_editor_hint() else 1.0
	_size_slider.custom_minimum_size = Vector2(BASE_SLIDER_WIDTH * scale, 0)
	_size_slider.min_value = MIN_TILE_SIZE
	_size_slider.max_value = MAX_TILE_SIZE
	_size_slider.step = 8
	_size_slider.value_changed.connect(func(v: float) -> void: tile_size_changed.emit(int(v)))

	_view_button.pressed.connect(func() -> void: view_mode_changed.emit(not _is_grid))

	_filter_slot.item_selected.connect(func(idx: int) -> void:
		subtype_changed.emit(_filter_slot.get_item_metadata(idx))
		_set_icon(_filter_slot, "AnimationFilter")
	)
	_filter_slot.visible = false

	_apply_icons()

## Only types that declare subtypes get the dropdown, everything else has one
## option, which is no filter at all. "All" carries an empty id so the grid can
## treat it as "don't filter" without a special case.
func set_subtypes(type_id: String) -> void:
	_filter_slot.clear()

	var subtypes: Dictionary = AssetTypes.get_by_id(type_id).get("subtypes", {})
	var options: Dictionary = subtypes.get("options", {})
	if options.is_empty():
		_filter_slot.visible = false
		return

	_filter_slot.add_item("All " + String(subtypes.get("label", "")))
	_filter_slot.set_item_metadata(0, "")
	for id: String in options:
		_filter_slot.add_item(options[id])
		_filter_slot.set_item_metadata(_filter_slot.item_count - 1, id)

	_filter_slot.selected = 0
	_set_icon(_filter_slot, "AnimationFilter")
	_filter_slot.visible = true

func _apply_icons() -> void:
	_set_icon(_prev_button, "Back")
	_set_icon(_next_button, "Forward")
	_set_icon(_sort_option, "Sort")
	_set_icon(_filter_slot, "AnimationFilter")

## The pager arrows lose their text; the sort dropdown keeps its label and just
## gains an icon beside it.
func _set_icon(button: Button, icon_name: String) -> void:
	var icon := IconHelper.get_icon(icon_name)
	if icon == null:
		return
	button.icon = icon
	if not button is OptionButton:
		button.text = ""

func set_sort(mode: int) -> void:
	_sort_option.selected = mode

func set_per_page(count: int) -> void:
	var idx := _per_page_option.get_item_index(count)
	if idx != -1:
		_per_page_option.selected = idx

func set_page(current: int, total: int) -> void:
	_page_label.text = "%d / %d" % [current + 1, total]
	_prev_button.disabled = current <= 0
	_next_button.disabled = current >= total - 1

func set_tile_size(size: int) -> void:
	_size_slider.set_value_no_signal(size)

## Tile size is meaningless in list view, where rows are a fixed height.
## A plain button rather than a toggle: a toggle draws a pressed background,
## which reads as "selected" for something that isn't a selection. The icon
## shows which view you're in instead, same as the sidebar collapse button.
func set_view_mode(is_grid: bool) -> void:
	_is_grid = is_grid
	$SizeBox.visible = is_grid

	var icon := IconHelper.get_icon("FileThumbnail" if is_grid else "FileList")
	if icon != null:
		_view_button.icon = icon
		_view_button.text = ""
