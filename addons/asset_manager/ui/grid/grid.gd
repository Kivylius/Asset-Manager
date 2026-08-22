@tool
class_name AssetGrid
extends PanelContainer

## The grid's only outward contract. Listeners bind to this signal rather
## than reaching into ItemList, so the widget underneath can change without
## touching the preview or the tag editor.
signal selection_changed(path: String)
signal item_activated(path: String)

var database: AssetDatabase
var settings: SettingsManager
var thumbnails: ThumbnailCache

var _animator: ThumbnailAnimator = ThumbnailAnimator.new()
var _blank_texture: ImageTexture

var _filter: Dictionary = {}
var _subtype: String = ""
var _sort_mode: int = GridSubbar.Sort.NAME
var _page: int = 0
var _total_pages: int = 1

@onready var _subbar: GridSubbar = $VBox/Subbar
@onready var _list: ItemList = $VBox/GridStack/AssetGrid
@onready var _empty_state: CenterContainer = $VBox/GridStack/EmptyState
@onready var _empty_title: Label = $VBox/GridStack/EmptyState/EmptyBox/TitleLabel
@onready var _empty_body: Label = $VBox/GridStack/EmptyState/EmptyBox/BodyLabel
@onready var _open_folder_button: Button = $VBox/GridStack/EmptyState/EmptyBox/OpenFolderButton

func _ready() -> void:
	if EditorGuard.is_scene_tab(self):
		return

	_list.item_selected.connect(_on_item_selected)
	_list.item_activated.connect(_on_item_activated)
	_list.gui_input.connect(_on_list_gui_input)

	_subbar.sort_changed.connect(_on_sort_changed)
	_subbar.page_changed.connect(_on_page_changed)
	_subbar.per_page_changed.connect(_on_per_page_changed)
	_subbar.tile_size_changed.connect(_on_tile_size_changed)
	_subbar.view_mode_changed.connect(_on_view_mode_changed)
	_subbar.subtype_changed.connect(_on_subtype_changed)
	_open_folder_button.pressed.connect(func() -> void:
		if database != null and not database.workspace_path.is_empty():
			OS.shell_open(database.workspace_path)
	)

	var blank := Image.create_empty(1, 1, false, Image.FORMAT_RGBA8)
	_blank_texture = ImageTexture.create_from_image(blank)

	_apply_panel_style()

## The grid panel holds the sub-toolbar and the list together, so the controls
## read as belonging to the content below them rather than floating above it.
## The ItemList inside draws no background of its own, the panel is the surface.
func _apply_panel_style() -> void:
	if not Engine.is_editor_hint():
		return
	var theme := EditorInterface.get_editor_theme()
	if theme == null:
		return

	# TreeSecondary's shape, with the background a text field uses. Both come
	# from the theme rather than being picked: LineEdit's normal style is built
	# on surface_lower (theme_modern.cpp:891), one step darker than the
	# sidebar's surface_low, which is the separation the editor itself uses
	# between a list and the content beside it.
	# Duplicated because get_stylebox returns the shared theme resource, writing
	# to it would repaint every Tree in the editor, sidebar included.
	if theme.has_stylebox("panel", "TreeSecondary"):
		var style: StyleBox = theme.get_stylebox("panel", "TreeSecondary").duplicate()
		var field: StyleBox = theme.get_stylebox("normal", "LineEdit")
		if style is StyleBoxFlat and field is StyleBoxFlat:
			(style as StyleBoxFlat).bg_color = (field as StyleBoxFlat).bg_color
		add_theme_stylebox_override("panel", style)

	_list.add_theme_stylebox_override("panel", StyleBoxEmpty.new())

	var spacing: int = EditorInterface.get_editor_settings().get_setting("interface/theme/base_spacing")
	$VBox.add_theme_constant_override("separation", int(spacing * EditorInterface.get_editor_scale()))

func setup(p_database: AssetDatabase, p_settings: SettingsManager, p_thumbnails: ThumbnailCache) -> void:
	database = p_database
	settings = p_settings
	thumbnails = p_thumbnails

	_animator.setup(_list, self)
	_subbar.set_tile_size(settings.get_grid_icon_size())
	_subbar.set_per_page(settings.get_items_per_page())
	_subbar.set_view_mode(settings.get_is_grid_view())
	_apply_view_mode()

## Everything the grid filters by, handed in rather than read from the sidebar,
## the grid never learns what a sidebar is.
func set_filter(prefix: String, tags: Array, extensions: Array, search: String, type_id: String = "") -> void:
	_filter = {"prefix": prefix, "tags": tags, "extensions": extensions, "search": search}
	_page = 0
	# A subtype only means something within one type, so changing folder
	# drops it.
	_subtype = ""
	_subbar.set_subtypes(type_id)
	refresh()

func refresh() -> void:
	if database == null:
		return

	_list.clear()
	_animator.clear()

	var matched := _matching_assets()
	_sort(matched)

	var per_page: int = settings.get_items_per_page()
	_total_pages = maxi(1, ceili(matched.size() / float(per_page)))
	_page = clampi(_page, 0, _total_pages - 1)
	_subbar.set_page(_page, _total_pages)

	var start := _page * per_page
	var end := mini(start + per_page, matched.size())

	for i in range(start, end):
		var entry: Dictionary = matched[i]
		var path: String = entry["path"]
		var icon := _icon_for(path, entry["type"])
		var idx := _list.add_item(path.get_file(), icon)
		_list.set_item_icon(idx, _animator.register(idx, icon))
		_list.set_item_metadata(idx, path)
		_list.set_item_tooltip(idx, path)

	_animator.start()
	_update_empty_state(matched.size())

## Two different nothings: a workspace with no assets at all needs telling where
## assets come from, a filter that matched nothing just needs saying so.
func _update_empty_state(matched_count: int) -> void:
	if matched_count > 0:
		_empty_state.visible = false
		return

	if database.assets.is_empty():
		_empty_title.text = "This workspace is empty"
		_empty_body.text = "Use Add Files or Add Folder above, or copy assets into\n%s\nthen press Rebuild Index." % database.workspace_path
		_open_folder_button.visible = true
	else:
		_empty_title.text = "Nothing to show"
		_empty_body.text = "No assets match the current filters."
		_open_folder_button.visible = false

	_empty_state.visible = true

func _matching_assets() -> Array[Dictionary]:
	var result: Array[Dictionary] = []

	var search: String = _filter.get("search", "")
	var exact := false
	if search.length() >= 2 and search.begins_with("\"") and search.ends_with("\""):
		exact = true
		search = search.substr(1, search.length() - 2)

	var prefix: String = _filter.get("prefix", "")
	var tags: Array = _filter.get("tags", [])
	var extensions: Array = _filter.get("extensions", [])

	for path: String in database.assets:
		if not prefix.is_empty() and not path.begins_with(prefix):
			continue

		var stored: Dictionary = database.assets[path]

		if not tags.is_empty():
			var asset_tags: Array = stored.get("tags", [])
			var has_all := true
			for t in tags:
				if not asset_tags.has(t):
					has_all = false
					break
			if not has_all:
				continue

		if not extensions.is_empty() and not extensions.has(path.get_extension().to_lower()):
			continue

		# An array so a type could gain a second axis later, "spatial" then
		# still finds a shader that is also something else.
		if not _subtype.is_empty() and not stored.get("subtype", []).has(_subtype):
			continue

		var entry: Dictionary = {"path": path, "type": stored["type"], "tags": stored.get("tags", [])}

		if not search.is_empty() and not _matches_search(entry, search, exact):
			continue

		result.append(entry)

	return result

func _matches_search(entry: Dictionary, query: String, exact: bool) -> bool:
	var filename: String = String(entry["path"]).get_file()
	var tags: Array = entry.get("tags", [])

	if exact:
		if filename.findn(query) != -1:
			return true
		for tag in tags:
			if String(tag).findn(query) != -1:
				return true
		return false

	if query.is_subsequence_ofn(filename):
		return true
	for tag in tags:
		if query.is_subsequence_ofn(String(tag)):
			return true
	return false

## A search puts exact substring matches first, because a fuzzy match on a long
## name otherwise outranks the file the user actually typed.
func _sort(assets: Array[Dictionary]) -> void:
	var search: String = _filter.get("search", "")

	if not search.is_empty():
		assets.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			var file_a := String(a["path"]).get_file()
			var file_b := String(b["path"]).get_file()
			var exact_a := file_a.findn(search) != -1
			var exact_b := file_b.findn(search) != -1
			if exact_a != exact_b:
				return exact_a
			return file_a.nocasecmp_to(file_b) < 0
		)
		return

	match _sort_mode:
		GridSubbar.Sort.RECENT:
			assets.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
				return database.get_date_added(a["path"]) > database.get_date_added(b["path"])
			)
		GridSubbar.Sort.SIZE:
			assets.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
				return _file_size(a["path"]) > _file_size(b["path"])
			)
		_:
			assets.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
				return String(a["path"]).get_file().nocasecmp_to(String(b["path"]).get_file()) < 0
			)

func _file_size(path: String) -> int:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return 0
	var size := file.get_length()
	file.close()
	return size

## A real thumbnail if one was generated, the type icon otherwise, a missing
## thumbnail is normal, not a failure.
func _icon_for(path: String, type_id: String) -> Texture2D:
	if thumbnails:
		var thumb := thumbnails.load_texture(path, type_id)
		if thumb:
			return thumb

	if not Engine.is_editor_hint():
		return _blank_texture

	var type_entry := AssetTypes.get_by_id(type_id)
	var icon := IconHelper.get_icon(type_entry.get("default_icon", "File"))
	if icon != null:
		return icon
	return _blank_texture

func _apply_view_mode() -> void:
	var is_grid := settings.get_is_grid_view()
	var scale := EditorInterface.get_editor_scale() if Engine.is_editor_hint() else 1.0

	if is_grid:
		var size := settings.get_grid_icon_size()
		_list.max_columns = 0
		_list.same_column_width = true
		# The column is the icon's width, h_separation already puts space
		# between tiles, so padding here only widens the selection box around
		# the image.
		_list.fixed_column_width = size
		_list.icon_mode = ItemList.ICON_MODE_TOP
		_list.max_text_lines = 2
		_list.fixed_icon_size = Vector2i(size, size)
		_list.add_theme_constant_override("h_separation", int(12 * scale))
		_list.add_theme_constant_override("v_separation", int(12 * scale))
	else:
		_list.max_columns = 1
		_list.same_column_width = false
		_list.fixed_column_width = 0
		_list.icon_mode = ItemList.ICON_MODE_LEFT
		_list.max_text_lines = 1
		_list.fixed_icon_size = Vector2i(24, 24) * scale
		_list.add_theme_constant_override("h_separation", int(8 * scale))
		_list.add_theme_constant_override("v_separation", int(4 * scale))

	_list.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS

func selected_path() -> String:
	var selected := _list.get_selected_items()
	if selected.is_empty():
		return ""
	return _list.get_item_metadata(selected[0])

func _on_item_selected(index: int) -> void:
	selection_changed.emit(_list.get_item_metadata(index))

func _on_item_activated(index: int) -> void:
	item_activated.emit(_list.get_item_metadata(index))

## Shift+scroll resizes tiles, the same gesture every canvas app trains, the
## slider in the sub-toolbar is the discoverable version of it.
func _on_list_gui_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton and event.pressed and event.shift_pressed):
		return
	if not settings.get_is_grid_view():
		return

	var step := 0
	if event.button_index == MOUSE_BUTTON_WHEEL_UP:
		step = 8
	elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		step = -8
	else:
		return

	var size := clampi(settings.get_grid_icon_size() + step, GridSubbar.MIN_TILE_SIZE, GridSubbar.MAX_TILE_SIZE)
	settings.set_grid_icon_size(size)
	_subbar.set_tile_size(size)
	_apply_view_mode()
	_list.accept_event()

func _on_sort_changed(mode: int) -> void:
	_sort_mode = mode
	_page = 0
	refresh()

func _on_subtype_changed(subtype: String) -> void:
	_subtype = subtype
	_page = 0
	refresh()

func _on_page_changed(delta: int) -> void:
	_page = clampi(_page + delta, 0, _total_pages - 1)
	refresh()

func _on_per_page_changed(count: int) -> void:
	settings.set_items_per_page(count)
	_page = 0
	refresh()

func _on_tile_size_changed(size: int) -> void:
	settings.set_grid_icon_size(size)
	_apply_view_mode()

func _on_view_mode_changed(is_grid: bool) -> void:
	settings.set_is_grid_view(is_grid)
	_subbar.set_view_mode(is_grid)
	_apply_view_mode()
