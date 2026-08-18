@tool
class_name AssetManagerConfig
extends RefCounted

## Per-machine settings, stored outside any project so they follow the user
## across every Godot project rather than living in one project's user://.
const CONFIG_SUBDIR: String = "AssetManager"
const CONFIG_FILE_NAME: String = "settings.cfg"

static func _path() -> String:
	return OS.get_config_dir().path_join(CONFIG_SUBDIR).path_join(CONFIG_FILE_NAME)

static func get_value(section: String, key: String, default: Variant) -> Variant:
	var cfg := ConfigFile.new()
	if cfg.load(_path()) != OK:
		return default
	return cfg.get_value(section, key, default)

static func set_value(section: String, key: String, value: Variant) -> void:
	var cfg := ConfigFile.new()
	cfg.load(_path())
	cfg.set_value(section, key, value)

	var dir_path := OS.get_config_dir().path_join(CONFIG_SUBDIR)
	if not DirAccess.dir_exists_absolute(dir_path):
		DirAccess.make_dir_recursive_absolute(dir_path)

	cfg.save(_path())
