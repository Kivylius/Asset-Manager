@tool
extends EditorPlugin

## EditorPlugin entry point. Instantiates the main screen panel and forwards
## visibility changes so it can sync when the user switches back to it.

var main_panel_instance: Control

func _enter_tree() -> void:
	main_panel_instance = preload("res://addons/asset_manager/ui/main_screen/main_screen.tscn").instantiate()
	EditorInterface.get_editor_main_screen().add_child(main_panel_instance)
	_make_visible(false)

func _exit_tree() -> void:
	if main_panel_instance:
		main_panel_instance.queue_free()

func _has_main_screen() -> bool:
	return true

func _make_visible(visible: bool) -> void:
	if main_panel_instance:
		var was_visible := main_panel_instance.visible
		main_panel_instance.visible = visible
		if visible and not was_visible and main_panel_instance.has_method("sync_if_stale"):
			main_panel_instance.sync_if_stale()
			main_panel_instance.focus_search()

func _get_plugin_name() -> String:
	return "AssetManager"

func _get_plugin_icon() -> Texture2D:
	return IconHelper.get_icon("Load")
