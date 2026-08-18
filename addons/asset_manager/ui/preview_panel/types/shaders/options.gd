@tool
class_name ShaderOptionsPanel
extends Control

signal uniform_changed(uniform_name: String, value: Variant)

@onready var _panel: PanelContainer = $Panel
@onready var _scroll: ScrollContainer = $Panel/VBox/Scroll
@onready var _rows_container: VBoxContainer = $Panel/VBox/Scroll/Rows
@onready var _title_label: Label = $Panel/VBox/Header/TitleLabel

var _material: ShaderMaterial
var _shader: Shader

var _name_label_width: float = 120.0

## shader default (not material's null) when unset
func _get_current_value(uniform_name: String) -> Variant:
	var material_value: Variant = _material.get_shader_parameter(uniform_name)
	if material_value != null:
		return material_value
	return RenderingServer.shader_get_parameter_default(_shader.get_rid(), uniform_name)

var _texture_hints: Dictionary = {}

enum PlaceholderTexture { NONE, WHITE, BLACK, GRAY, CHECKER, NOISE, NOISE_HARD, NORMAL_FLAT, UV_GRADIENT }
const PLACEHOLDER_NAMES: PackedStringArray = ["None", "White", "Black", "Gray", "Checker", "Noise (Smooth)", "Noise (Hard)", "Flat Normal", "UV Gradient"]
var _placeholder_cache: Dictionary = {}

var _scene_texture_provider: Callable = Callable()

func _ready() -> void:
	if EditorGuard.is_scene_tab(self):
		return

	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_apply_panel_style()

## The panel floats over the shader preview, so it has to stay see-through, and
## no editor stylebox is. PanelForeground is the variation the editor uses for
## exactly this shape (theme_modern.cpp:2277, the export dialog and the floating
## window wrapper), so it supplies the colour and corners and only the alpha is
## ours.
const PANEL_ALPHA: float = 0.82

func _apply_panel_style() -> void:
	if not Engine.is_editor_hint():
		return
	var theme := EditorInterface.get_editor_theme()
	if theme == null or not theme.has_stylebox("panel", "PanelForeground"):
		return

	# Duplicated because get_stylebox hands back the shared theme resource,
	# writing to it would make every PanelForeground in the editor translucent.
	var style: StyleBox = theme.get_stylebox("panel", "PanelForeground").duplicate()
	if style is StyleBoxFlat:
		(style as StyleBoxFlat).bg_color.a = PANEL_ALPHA
		_panel.add_theme_stylebox_override("panel", style)

const TOP_GAP: float = 12.0

func set_top_offset(p_offset: float) -> void:
	_panel.offset_top = p_offset + TOP_GAP

func set_scene_texture_provider(p_provider: Callable) -> void:
	_scene_texture_provider = p_provider

## auto-fills unset texture uniforms once per shader load, never on panel open
func apply_default_placeholders(p_shader: Shader, p_material: ShaderMaterial) -> void:
	var hints := _scan_texture_hints(p_shader.code)
	for uniform in p_shader.get_shader_uniform_list():
		var uniform_name: String = uniform.get("name", "")
		var type: int = uniform.get("type", TYPE_NIL)
		var hint_string: String = uniform.get("hint_string", "")
		if type != TYPE_OBJECT or (hint_string != "Texture2D" and not hint_string.begins_with("Texture")):
			continue
		var hint_keyword: String = hints.get(uniform_name, "")
		if hint_keyword == "hint_screen_texture" or hint_keyword == "hint_depth_texture" or hint_keyword == "hint_normal_roughness_texture":
			continue
		if p_material.get_shader_parameter(uniform_name) != null:
			continue

		var placeholder_kind := PlaceholderTexture.WHITE
		if hint_keyword == "hint_normal" or hint_keyword == "hint_roughness_normal":
			placeholder_kind = PlaceholderTexture.NORMAL_FLAT
		elif hint_keyword == "source_color":
			placeholder_kind = PlaceholderTexture.CHECKER
		elif hint_keyword == "hint_default_white":
			placeholder_kind = PlaceholderTexture.WHITE
		elif hint_keyword == "hint_default_black":
			placeholder_kind = PlaceholderTexture.BLACK

		p_material.set_shader_parameter(uniform_name, _get_placeholder_texture(placeholder_kind))

func open(p_shader: Shader, p_material: ShaderMaterial, p_title: String = "") -> void:
	_shader = p_shader
	_material = p_material
	_title_label.text = p_title if not p_title.is_empty() else "Shader Options"

	_texture_hints = _scan_texture_hints(p_shader.code)

	for child in _rows_container.get_children():
		child.queue_free()

	var uniforms := p_shader.get_shader_uniform_list(true)
	_name_label_width = _measure_max_label_width(uniforms)
	if uniforms.is_empty():
		var empty_label := Label.new()
		empty_label.text = "This shader has no uniforms to configure."
		empty_label.modulate.a = 0.7
		_rows_container.add_child(empty_label)
	else:
		var current_group := ""
		for uniform in uniforms:
			var usage: int = uniform.get("usage", PROPERTY_USAGE_DEFAULT)
			if usage & PROPERTY_USAGE_GROUP:
				current_group = String(uniform.get("name", ""))
				if not current_group.is_empty():
					_add_group_header(current_group)
				continue
			if usage & PROPERTY_USAGE_SUBGROUP:
				continue
			_add_row_for_uniform(uniform)

	visible = true

func close() -> void:
	visible = false

func toggle() -> void:
	visible = not visible

func _measure_max_label_width(uniforms: Array) -> float:
	var font := get_theme_default_font()
	var font_size := get_theme_default_font_size()
	var max_width := 60.0
	for uniform in uniforms:
		var usage: int = uniform.get("usage", PROPERTY_USAGE_DEFAULT)
		if usage & (PROPERTY_USAGE_GROUP | PROPERTY_USAGE_SUBGROUP):
			continue
		var uniform_name: String = uniform.get("name", "")
		if uniform_name.is_empty():
			continue
		var text_width := font.get_string_size(uniform_name.capitalize(), HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
		max_width = maxf(max_width, text_width)
	return max_width + 12.0

func _add_group_header(group_name: String) -> void:
	var label := Label.new()
	label.text = group_name
	var sep := HSeparator.new()
	_rows_container.add_child(sep)
	_rows_container.add_child(label)

func _add_row_for_uniform(uniform: Dictionary) -> void:
	var uniform_name: String = uniform.get("name", "")
	if uniform_name.is_empty():
		return

	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var name_label := Label.new()
	name_label.text = uniform_name.capitalize()
	name_label.custom_minimum_size = Vector2(_name_label_width, 0)
	name_label.tooltip_text = uniform_name
	name_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(name_label)

	var control := _build_control_for_uniform(uniform)
	if control == null:
		var unsupported := Label.new()
		unsupported.text = "Unsupported"
		unsupported.modulate.a = 0.5
		control = unsupported
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(control)

	_rows_container.add_child(row)

func _build_control_for_uniform(uniform: Dictionary) -> Control:
	var uniform_name: String = uniform.get("name", "")
	var type: int = uniform.get("type", TYPE_NIL)
	var hint: int = uniform.get("hint", PROPERTY_HINT_NONE)
	var hint_string: String = uniform.get("hint_string", "")

	match type:
		TYPE_BOOL:
			return _build_bool_control(uniform_name)
		TYPE_INT:
			if hint == PROPERTY_HINT_ENUM:
				return _build_enum_control(uniform_name, hint_string)
			return _build_number_control(uniform_name, hint, hint_string, true)
		TYPE_FLOAT:
			return _build_number_control(uniform_name, hint, hint_string, false)
		TYPE_COLOR:
			return _build_color_control(uniform_name)
		TYPE_VECTOR2:
			return _build_vector_control(uniform_name, 2)
		TYPE_VECTOR3:
			return _build_vector_control(uniform_name, 3)
		TYPE_VECTOR4:
			return _build_vector_control(uniform_name, 4)
		TYPE_OBJECT:
			if hint_string == "Texture2D" or hint_string.begins_with("Texture"):
				return _build_texture_control(uniform_name)
			return null
		_:
			return null

func _build_bool_control(uniform_name: String) -> Control:
	var check := CheckBox.new()
	check.button_pressed = bool(_get_current_value(uniform_name))
	check.toggled.connect(func(pressed: bool) -> void:
		_material.set_shader_parameter(uniform_name, pressed)
		uniform_changed.emit(uniform_name, pressed))
	return check

func _build_enum_control(uniform_name: String, hint_string: String) -> Control:
	var option := OptionButton.new()
	var current_value: int = int(_get_current_value(uniform_name))
	var selected_index := 0
	var index := 0
	for entry in hint_string.split(","):
		var label := entry
		var value := index
		if entry.find(":") != -1:
			var parts := entry.split(":")
			label = parts[0]
			value = int(parts[1]) if parts.size() > 1 else index
		option.add_item(label)
		option.set_item_metadata(index, value)
		if value == current_value:
			selected_index = index
		index += 1
	option.selected = selected_index
	option.item_selected.connect(func(idx: int) -> void:
		var value: int = option.get_item_metadata(idx)
		_material.set_shader_parameter(uniform_name, value)
		uniform_changed.emit(uniform_name, value))
	return option

func _build_number_control(uniform_name: String, hint: int, hint_string: String, is_int: bool) -> Control:
	var spin := SpinBox.new()
	spin.step = 1.0 if is_int else 0.01
	spin.allow_greater = true
	spin.allow_lesser = true

	if hint == PROPERTY_HINT_RANGE and not hint_string.is_empty():
		var parts := hint_string.split(",")
		if parts.size() >= 2:
			spin.min_value = float(parts[0])
			spin.max_value = float(parts[1])
			spin.allow_greater = false
			spin.allow_lesser = false
		if parts.size() >= 3:
			spin.step = float(parts[2])
	else:
		spin.min_value = -100000.0
		spin.max_value = 100000.0

	var current: Variant = _get_current_value(uniform_name)
	spin.value = float(current) if current != null else 0.0

	spin.value_changed.connect(func(value: float) -> void:
		var applied: Variant = int(value) if is_int else value
		_material.set_shader_parameter(uniform_name, applied)
		uniform_changed.emit(uniform_name, applied))
	return spin

func _build_color_control(uniform_name: String) -> Control:
	var picker := ColorPickerButton.new()
	var current: Variant = _get_current_value(uniform_name)
	picker.color = current if current is Color else Color.WHITE
	picker.custom_minimum_size = Vector2(0, 28)
	picker.color_changed.connect(func(color: Color) -> void:
		_material.set_shader_parameter(uniform_name, color)
		uniform_changed.emit(uniform_name, color))
	return picker

func _build_vector_control(uniform_name: String, dims: int) -> Control:
	var box := HBoxContainer.new()
	var current: Variant = _get_current_value(uniform_name)

	var components: PackedFloat64Array = PackedFloat64Array()
	if current != null:
		match dims:
			2:
				var v: Vector2 = current
				components = [v.x, v.y]
			3:
				var v: Vector3 = current
				components = [v.x, v.y, v.z]
			4:
				var v: Vector4 = current
				components = [v.x, v.y, v.z, v.w]

	var spins: Array[SpinBox] = []
	for i in range(dims):
		var spin := SpinBox.new()
		spin.step = 0.01
		spin.min_value = -100000.0
		spin.max_value = 100000.0
		spin.allow_greater = true
		spin.allow_lesser = true
		spin.custom_minimum_size = Vector2(60, 0)
		if i < components.size():
			spin.value = components[i]
		spins.append(spin)
		box.add_child(spin)

	for i in range(dims):
		spins[i].value_changed.connect(func(_value: float) -> void:
			var new_value: Variant
			match dims:
				2: new_value = Vector2(spins[0].value, spins[1].value)
				3: new_value = Vector3(spins[0].value, spins[1].value, spins[2].value)
				4: new_value = Vector4(spins[0].value, spins[1].value, spins[2].value, spins[3].value)
			_material.set_shader_parameter(uniform_name, new_value)
			uniform_changed.emit(uniform_name, new_value))
	return box

func _build_texture_control(uniform_name: String) -> Control:
	var option := OptionButton.new()
	var hint_keyword: String = _texture_hints.get(uniform_name, "")

	if hint_keyword == "hint_screen_texture" or hint_keyword == "hint_depth_texture" or hint_keyword == "hint_normal_roughness_texture":
		var auto_label := Label.new()
		auto_label.text = "Auto (engine-supplied)"
		auto_label.modulate.a = 0.7
		return auto_label

	for i in range(PLACEHOLDER_NAMES.size()):
		option.add_item(PLACEHOLDER_NAMES[i])
	var scene_render_item_index := -1
	if _scene_texture_provider.is_valid():
		option.add_item("Scene Render")
		scene_render_item_index = PLACEHOLDER_NAMES.size()

	var already_set: Variant = _material.get_shader_parameter(uniform_name)
	if already_set != null:
		var matched_index := _find_placeholder_index_for_texture(already_set, scene_render_item_index)
		option.selected = matched_index if matched_index != -1 else PlaceholderTexture.NONE
	else:
		option.selected = PlaceholderTexture.NONE

	option.item_selected.connect(func(idx: int) -> void:
		_apply_texture_choice(uniform_name, idx, scene_render_item_index))
	return option

func _find_placeholder_index_for_texture(texture: Variant, scene_render_item_index: int) -> int:
	if scene_render_item_index != -1 and _scene_texture_provider.is_valid() and texture == _scene_texture_provider.call():
		return scene_render_item_index
	for kind in _placeholder_cache:
		if _placeholder_cache[kind] == texture:
			return kind
	return -1

func _apply_texture_choice(uniform_name: String, choice_index: int, scene_render_item_index: int) -> void:
	var texture: Texture2D = null
	if scene_render_item_index != -1 and choice_index == scene_render_item_index:
		texture = _scene_texture_provider.call()
	elif choice_index != PlaceholderTexture.NONE:
		texture = _get_placeholder_texture(choice_index)
	_material.set_shader_parameter(uniform_name, texture)
	uniform_changed.emit(uniform_name, texture)

func _get_placeholder_texture(kind: int) -> Texture2D:
	if _placeholder_cache.has(kind):
		return _placeholder_cache[kind]
	var tex := _build_placeholder_texture(kind)
	_placeholder_cache[kind] = tex
	return tex

const PLACEHOLDER_SIZE: int = 64

func _build_placeholder_texture(kind: int) -> Texture2D:
	var img := Image.create(PLACEHOLDER_SIZE, PLACEHOLDER_SIZE, false, Image.FORMAT_RGBA8)
	match kind:
		PlaceholderTexture.WHITE:
			img.fill(Color.WHITE)
		PlaceholderTexture.BLACK:
			img.fill(Color.BLACK)
		PlaceholderTexture.GRAY:
			img.fill(Color(0.5, 0.5, 0.5, 1.0))
		PlaceholderTexture.NORMAL_FLAT:
			img.fill(Color(0.5, 0.5, 1.0, 1.0))
		PlaceholderTexture.CHECKER:
			var tile := 8
			for y in range(PLACEHOLDER_SIZE):
				for x in range(PLACEHOLDER_SIZE):
					var is_light := (x / tile + y / tile) % 2 == 0
					img.set_pixel(x, y, Color(0.8, 0.8, 0.8) if is_light else Color(0.35, 0.35, 0.35))
		PlaceholderTexture.NOISE:
			var cell := 8
			var rng := RandomNumberGenerator.new()
			rng.seed = 1
			var grid_size := PLACEHOLDER_SIZE / cell
			var grid: Array[float] = []
			grid.resize(grid_size * grid_size)
			for i in range(grid.size()):
				grid[i] = rng.randf()
			for y in range(PLACEHOLDER_SIZE):
				for x in range(PLACEHOLDER_SIZE):
					var gx := float(x) / cell
					var gy := float(y) / cell
					var ix := int(gx)
					var iy := int(gy)
					var fx := gx - ix
					var fy := gy - iy
					var ix1 := (ix + 1) % grid_size
					var iy1 := (iy + 1) % grid_size
					var v00 := grid[iy * grid_size + ix]
					var v10 := grid[iy * grid_size + ix1]
					var v01 := grid[iy1 * grid_size + ix]
					var v11 := grid[iy1 * grid_size + ix1]
					var sx := smoothstep(0.0, 1.0, fx)
					var sy := smoothstep(0.0, 1.0, fy)
					var v := lerp(lerp(v00, v10, sx), lerp(v01, v11, sx), sy)
					img.set_pixel(x, y, Color(v, v, v))
		PlaceholderTexture.NOISE_HARD:
			var rng := RandomNumberGenerator.new()
			rng.seed = 1
			for y in range(PLACEHOLDER_SIZE):
				for x in range(PLACEHOLDER_SIZE):
					var v := rng.randf()
					img.set_pixel(x, y, Color(v, v, v))
		PlaceholderTexture.UV_GRADIENT:
			for y in range(PLACEHOLDER_SIZE):
				for x in range(PLACEHOLDER_SIZE):
					img.set_pixel(x, y, Color(float(x) / PLACEHOLDER_SIZE, float(y) / PLACEHOLDER_SIZE, 0.5))
		_:
			img.fill(Color(0.5, 0.5, 0.5, 1.0))
	return ImageTexture.create_from_image(img)

const _KNOWN_HINTS: PackedStringArray = [
	"hint_screen_texture", "hint_depth_texture", "hint_normal_roughness_texture",
	"hint_normal", "hint_roughness_normal", "hint_anisotropy",
	"source_color", "hint_default_white", "hint_default_black", "hint_default_transparent",
	"hint_roughness_r", "hint_roughness_g", "hint_roughness_b", "hint_roughness_a", "hint_roughness_gray",
]

func _scan_texture_hints(shader_code: String) -> Dictionary:
	var result: Dictionary = {}
	var rx := RegEx.new()
	rx.compile("uniform\\s+sampler2D\\s+(\\w+)\\s*(?:\\[[^\\]]*\\])?\\s*:\\s*([^;=]+)")
	for m in rx.search_all(shader_code):
		var uniform_name := m.get_string(1)
		var hints := m.get_string(2)
		for known in _KNOWN_HINTS:
			if hints.find(known) != -1:
				result[uniform_name] = known
				break
	return result
