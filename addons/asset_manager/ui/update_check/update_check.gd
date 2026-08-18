@tool
class_name UpdateCheck
extends Button

## Nothing tells someone their copy of the plugin is old, the store doesn't
## notify, and neither does dropping the folder in by hand. This asks the
## store once per session and shows itself only when there's something newer.
## Self-contained: it owns its own request, does its own comparison, and
## nothing else in the plugin knows it exists. Fails silently.

const PUBLISHER_SLUG: String = "kivylius"
const ASSET_SLUG: String = "asset-manager"

## Both slugs are known before publishing, the store builds its own URLs from
## them (asset_library_editor_plugin.cpp:1965).
const RELEASES_URL: String = "https://store.godotengine.org/api/v1/releases/%s/%s/"
const STORE_URL: String = "https://store.godotengine.org/asset/%s/%s/"

@onready var _request: HTTPRequest = $Request

func _ready() -> void:
	if EditorGuard.is_scene_tab(self):
		return

	visible = false
	pressed.connect(func() -> void: OS.shell_open(STORE_URL % [PUBLISHER_SLUG, ASSET_SLUG]))
	_request.request_completed.connect(_on_request_completed)
	_request.request(RELEASES_URL % [PUBLISHER_SLUG, ASSET_SLUG])

func _on_request_completed(_result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if response_code != 200:
		return

	var releases: Variant = JSON.parse_string(body.get_string_from_utf8())
	if not (releases is Array):
		return

	var latest := _latest_stable(releases)
	if latest.is_empty() or not _is_newer(latest, _local_version()):
		return

	text = "Update available"
	IconHelper.apply(self, "StatusWarning")
	visible = true

## Newest first, so the first stable entry wins. Pre-releases are skipped rather
## than nagging someone toward a build the author hasn't blessed.
static func _latest_stable(releases: Array) -> String:
	for release: Variant in releases:
		if release is Dictionary and release.get("stable", false):
			return release.get("version", "")
	return ""

func _local_version() -> String:
	var cfg := ConfigFile.new()
	if cfg.load("res://addons/asset_manager/plugin.cfg") != OK:
		return ""
	return cfg.get_value("plugin", "version", "")

## Compared part by part as numbers, not as strings, "1.10.0" is newer than
## "1.9.0" but sorts before it alphabetically.
static func _is_newer(remote: String, local: String) -> bool:
	if local.is_empty():
		return false

	var a := remote.trim_prefix("v").split(".")
	var b := local.trim_prefix("v").split(".")

	for i in maxi(a.size(), b.size()):
		var left := int(a[i]) if i < a.size() else 0
		var right := int(b[i]) if i < b.size() else 0
		if left != right:
			return left > right

	return false
