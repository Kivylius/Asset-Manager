@tool
class_name AddDialog
extends ConfirmationDialog

## Shows what a pack holds before any of it is written: its preview, what is
## inside, and which format to take when it ships more than one.

signal confirmed_with_selection(type_id: String, source_path: String, format: String, variant: String, dest_root: String)

@onready var _carousel: PreviewCarousel = $VBox/Carousel
@onready var _name_label: Label = $VBox/NameLabel
@onready var _summary_label: Label = $VBox/SummaryLabel
@onready var _format_row: HBoxContainer = $VBox/FormatRow
@onready var _format_option: OptionButton = $VBox/FormatRow/FormatOption
@onready var _variant_row: HBoxContainer = $VBox/VariantRow
@onready var _variant_option: OptionButton = $VBox/VariantRow/VariantOption
@onready var _vendor_option: VendorPicker = $VBox/VendorRow/VendorOption
@onready var _name_edit: LineEdit = $VBox/NameRow/NameEdit
@onready var _name_error: Label = $VBox/NameError
@onready var _destination_label: Label = $VBox/DestinationLabel
@onready var _warning_label: Label = $VBox/WarningLabel

var _settings: SettingsManager = SettingsManager.new()
var _type_id: String = ""
var _source_path: String = ""
var _workspace_path: String = ""
var _info: Dictionary = {}
var _preview_token: int = 0

## Same rule the vendor picker uses: anything else could walk out of the bucket
## ("../") or nest a folder.
var _name_pattern: RegEx = RegEx.create_from_string("^[A-Za-z0-9 _.\\-]+$")

func _ready() -> void:
	if EditorGuard.is_scene_tab(self):
		return

	_apply_style()
	confirmed.connect(_on_confirmed)
	_format_option.item_selected.connect(func(_index: int) -> void:
		_populate_variants()
		_refresh_summary()
	)
	_variant_option.item_selected.connect(func(_index: int) -> void: _refresh_summary())
	_vendor_option.vendor_changed.connect(_refresh_destination)
	_name_edit.text_changed.connect(func(_text: String) -> void: _refresh_destination())

func _apply_style() -> void:
	if not Engine.is_editor_hint():
		return
	var theme := EditorInterface.get_editor_theme()
	if theme == null:
		return

	if theme.has_color("font_disabled_color", "Editor"):
		var muted := theme.get_color("font_disabled_color", "Editor")
		_summary_label.add_theme_color_override("font_color", muted)
		_destination_label.add_theme_color_override("font_color", muted)
	if theme.has_color("warning_color", "Editor"):
		_warning_label.add_theme_color_override("font_color", theme.get_color("warning_color", "Editor"))
	if theme.has_color("error_color", "Editor"):
		_name_error.add_theme_color_override("font_color", theme.get_color("error_color", "Editor"))

func ask(type_id: String, source_path: String, workspace_path: String) -> void:
	_type_id = type_id
	_source_path = source_path
	_workspace_path = workspace_path

	var entry := AssetTypes.get_by_id(type_id)
	title = "Add %s" % entry.get("label", type_id)
	_name_label.text = source_path.get_file()

	var read := VendorPrefixes.read(source_path.get_file())
	_vendor_option.populate(read["vendor"])
	_name_edit.text = read["name"]

	if source_path.get_extension().to_lower() == "zip":
		_show_archive()
	else:
		_show_single_file()

	reset_size()
	popup_centered()

## A loose file has nothing to inspect: one file, no formats. An image is its
## own preview, anything else falls back to the type icon.
func _show_single_file() -> void:
	_info = {}
	_format_row.visible = false
	_warning_label.visible = false
	_summary_label.text = "1 file"

	var image := Image.new()
	var loaded := image.load(_source_path) == OK
	_show_previews([image] if loaded else [])
	_refresh_destination()

func _show_archive() -> void:
	_info = AssetAdd.inspect(_source_path, _type_id)

	if _info.has("error"):
		_show_previews([])
		_format_row.visible = false
		_summary_label.text = ""
		_destination_label.text = ""
		_warn(_info["error"])
		get_ok_button().disabled = true
		return

	var previews: PackedStringArray = _info.get("previews", PackedStringArray())
	var first: Variant = _info.get("preview_image")
	_show_previews(
		[first] if first != null else [],
		PackedStringArray([previews[0].get_file()]) if not previews.is_empty() else PackedStringArray()
	)
	_load_remaining_previews()

	_populate_formats(_info["formats"])
	_populate_variants()
	_refresh_summary()
	_refresh_destination()

## Ordered by how well the plugin handles each format, which is the order the
## type lists them in. Counts are no guide: a pack shipping both an "fbx" and an
## "fbx unity" folder has twice as many .fbx as .gltf and still wants the .gltf.
func _populate_formats(formats: Dictionary) -> void:
	_format_option.clear()

	var preferred: Array = AssetTypes.get_by_id(_type_id).get("extensions", [])
	var extensions: Array = formats.keys()
	extensions.sort_custom(func(a: String, b: String) -> bool:
		var rank_a := preferred.find(a)
		var rank_b := preferred.find(b)
		if rank_a != rank_b:
			return rank_a < rank_b
		return formats[a] > formats[b]
	)

	for ext: String in extensions:
		_format_option.add_item(".%s  (%d)" % [ext, formats[ext]])
		_format_option.set_item_metadata(_format_option.item_count - 1, ext)

	_format_row.visible = extensions.size() > 1
	if extensions.size() > 0:
		_format_option.selected = 0

## Shown only when the chosen format ships the same filenames in more than one
## folder. The folder name is a label for the user to read, never something the
## code decides from: "Large (2x)" and "GLB format" are the author's words.
func _populate_variants() -> void:
	_variant_option.clear()

	var entries: PackedStringArray = _info.get("entries", PackedStringArray())
	var variants := ArchiveManifest.variants_for(entries, selected_format())

	var folders: Array = variants.keys()
	folders.sort()
	for folder: String in folders:
		var label := folder.trim_prefix(_info.get("root_prefix", ""))
		_variant_option.add_item("%s  (%d)" % [label, variants[folder]])
		_variant_option.set_item_metadata(_variant_option.item_count - 1, folder)

	_variant_row.visible = folders.size() > 1
	if folders.size() > 0:
		_variant_option.selected = 0

## "" when the pack ships no duplicates, which means take every folder.
func selected_variant() -> String:
	if not _variant_row.visible or _variant_option.item_count == 0:
		return ""
	return String(_variant_option.get_item_metadata(_variant_option.selected))

func _refresh_summary() -> void:
	var formats: Dictionary = _info.get("formats", {})
	if formats.is_empty():
		var label: String = AssetTypes.get_by_id(_type_id).get("label", _type_id)
		_summary_label.text = ""
		_warn("No %s found in this archive." % label.to_lower())
		get_ok_button().disabled = true
		return

	var chosen := selected_format()
	var taken: int = formats.get(chosen, 0)
	var extras := 0
	for ext: String in _info.get("others", {}):
		extras += _info["others"][ext]

	var dropped := 0
	for ext: String in formats:
		if ext != chosen:
			dropped += formats[ext]

	# One variant is taken and its siblings left, so they move from the count
	# of what comes to the count of what does not.
	var variant := selected_variant()
	if not variant.is_empty():
		var variants := ArchiveManifest.variants_for(_info.get("entries", PackedStringArray()), chosen)
		var kept: int = variants.get(variant, taken)
		dropped += taken - kept
		taken = kept

	var parts: Array[String] = ["%d .%s" % [taken, chosen]]
	if extras > 0:
		parts.append("%d supporting" % extras)
	if dropped > 0:
		parts.append("%d skipped" % dropped)

	var blocked: int = _info.get("blocked", 0)
	if blocked > 0:
		parts.append("%d ignored" % blocked)

	_summary_label.text = ", ".join(parts)
	_warning_label.visible = false
	get_ok_button().disabled = false

## An empty list falls back to the type's own icon, so the dialog keeps its
## shape whether or not there is anything to look at.
func _show_previews(images: Array, names: PackedStringArray = []) -> void:
	var type_entry := AssetTypes.get_by_id(_type_id)
	var icon := IconHelper.get_icon(type_entry.get("default_icon", "File"))

	var typed: Array[Image] = []
	typed.assign(images)
	_carousel.show_images(typed, icon, names)

## The first preview is already up by now, so the rest can take their time.
## The token drops the loop if another pack is opened while it runs.
func _load_remaining_previews() -> void:
	_preview_token += 1
	var my_token := _preview_token
	var zip_path := _source_path

	var previews: PackedStringArray = _info.get("previews", PackedStringArray())
	for i in range(1, previews.size()):
		await get_tree().process_frame
		if my_token != _preview_token:
			return
		_carousel.append(AssetAdd.load_preview(zip_path, previews[i]), previews[i].get_file())

func _warn(text: String) -> void:
	_warning_label.text = "⚠ " + text
	_warning_label.visible = true

func selected_format() -> String:
	if _format_option.item_count == 0:
		return ""
	return String(_format_option.get_item_metadata(_format_option.selected))

## Named from the archive rather than the folder inside it: wrapper folders are
## often generic ("gui_assets"), while the file itself carries the pack's name.
## The vendor sits above it, so two packs by one author share a folder.
func _destination() -> String:
	var root := _workspace_path.path_join(_type_id)
	var vendor := _vendor_option.selected_vendor()
	if not vendor.is_empty():
		root = root.path_join(vendor)
	return root.path_join(_name_edit.text.strip_edges())

func _refresh_destination() -> void:
	var folder := _name_edit.text.strip_edges()
	_destination_label.text = _destination()
	_destination_label.tooltip_text = _destination()

	# An archive that failed to open, or holds nothing of this type, has already
	# said so and stays refused.
	if _info.has("error") or (_info.has("formats") and _info["formats"].is_empty()):
		return

	if folder.is_empty():
		_name_error.visible = false
		get_ok_button().disabled = true
		return

	if not _name_pattern.search(folder):
		_show_name_error("Only letters, numbers, spaces, dots, dashes and underscores.")
		return

	if DirAccess.dir_exists_absolute(_destination()):
		_show_name_error('"%s" already exists here.' % folder)
		return

	_name_error.visible = false
	get_ok_button().disabled = false

func _show_name_error(text: String) -> void:
	_name_error.text = "⚠ " + text
	_name_error.visible = true
	get_ok_button().disabled = true

func _on_confirmed() -> void:
	_settings.set_vendor_for_type(_type_id, _vendor_option.selected_vendor())
	confirmed_with_selection.emit(_type_id, _source_path, selected_format(), selected_variant(), _destination())
