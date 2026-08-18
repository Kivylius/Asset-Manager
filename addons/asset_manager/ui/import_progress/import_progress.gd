@tool
class_name ImportProgressDialog
extends AcceptDialog

## Modal progress for Rebuild Index. Blocking and not cancellable by design,
## a half-finished index is worse than a slow one.
## Two tiers, mirroring how the work actually runs: the top row is which stage
## we're in, the bottom is progress within it. Import dispatches every type in
## parallel, so the detail line names the most recent thing to finish rather
## than pretending there's one current file.

## Ordered, so the top bar can show real overall progress rather than just
## naming a stage. Thumbnails is by far the longest, hence the weighting.
const STAGES: Array[Dictionary] = [
	{"id": "scan", "label": "Scanning files", "weight": 1.0},
	{"id": "database", "label": "Writing index", "weight": 0.2},
	{"id": "thumbnails", "label": "Generating thumbnails", "weight": 8.0},
]

@onready var _stage_label: Label = $Margin/VBox/StageRow/StageLabel
@onready var _elapsed_label: Label = $Margin/VBox/StageRow/ElapsedLabel
@onready var _stage_bar: ProgressBar = $Margin/VBox/StageBar
@onready var _detail_label: Label = $Margin/VBox/DetailRow/DetailLabel
@onready var _count_label: Label = $Margin/VBox/DetailRow/CountLabel
@onready var _detail_bar: ProgressBar = $Margin/VBox/DetailBar

var _started_ms: int = 0
var _current_stage: String = ""
var _current_type: String = ""
var _ticker: Timer

func _ready() -> void:
	if EditorGuard.is_scene_tab(self):
		return

	# Nothing to confirm, the run can't be cancelled, so an OK button would
	# either lie or dismiss a dialog whose work is still going.
	get_ok_button().visible = false
	exclusive = true

	_ticker = Timer.new()
	_ticker.wait_time = 0.5
	_ticker.timeout.connect(_update_elapsed)
	add_child(_ticker)

func start() -> void:
	_started_ms = Time.get_ticks_msec()
	_current_stage = ""
	_current_type = ""
	_stage_label.text = "Starting..."
	_detail_label.text = ""
	_count_label.text = ""
	_stage_bar.value = 0.0
	_detail_bar.value = 0.0
	_elapsed_label.text = "0:00"
	_ticker.start()
	popup_centered()

func finish() -> void:
	_ticker.stop()
	hide()

## Fed straight from AssetImporter.progress, unknown keys are ignored so the
## reporting side can add fields without breaking this.
func on_progress(info: Dictionary) -> void:
	var stage_id: String = info.get("stage", "")
	var type_id: String = info.get("type", "")

	# The detail bar resets per type, so the heading names which one it's on.
	# Otherwise a bar that jumps back to zero looks like something went wrong.
	if stage_id != _current_stage or type_id != _current_type:
		_current_stage = stage_id
		_current_type = type_id
		var heading := _stage_label_for(stage_id)
		if not type_id.is_empty():
			heading += ": " + type_id
		_stage_label.text = heading

	var current: int = int(info.get("current", 0))
	var total: int = int(info.get("total", 0))
	var fraction: float = float(current) / float(total) if total > 0 else 0.0

	# Detail bar fills and resets once per type; the top bar spans everything,
	# falling back to the type's own numbers for stages that report no overall.
	var overall_current: int = int(info.get("overall_current", current))
	var overall_total: int = int(info.get("overall_total", total))
	var overall_fraction: float = float(overall_current) / float(overall_total) if overall_total > 0 else 0.0

	_detail_bar.value = fraction
	_stage_bar.value = _overall_fraction(stage_id, overall_fraction)

	var parts: Array[String] = []
	if not type_id.is_empty():
		parts.append(type_id)

	var label: String = info.get("label", "")
	if not label.is_empty():
		parts.append(label)

	_detail_label.text = "  ·  ".join(parts)

	# Position within this type, then the whole run in brackets. Its own
	# label, pinned right, so a changing filename can't shift it sideways.
	if total > 0:
		var text := "%d / %d" % [current, total]
		if overall_total > 0 and overall_total != total:
			text += " (%d)" % overall_total
		_count_label.text = text
	else:
		_count_label.text = ""

## Weighted so the bar tracks real time rather than jumping to 90% and sitting
## there through the one stage that actually takes a while.
func _overall_fraction(stage_id: String, stage_fraction: float) -> float:
	var total_weight: float = 0.0
	for stage in STAGES:
		total_weight += float(stage["weight"])
	if total_weight <= 0.0:
		return 0.0

	var accumulated: float = 0.0
	for stage in STAGES:
		var weight: float = float(stage["weight"])
		if stage["id"] == stage_id:
			return (accumulated + weight * stage_fraction) / total_weight
		accumulated += weight

	return accumulated / total_weight

func _stage_label_for(stage_id: String) -> String:
	for stage in STAGES:
		if stage["id"] == stage_id:
			return String(stage["label"])
	return stage_id.capitalize()

func _update_elapsed() -> void:
	var seconds: int = (Time.get_ticks_msec() - _started_ms) / 1000
	_elapsed_label.text = "%d:%02d" % [seconds / 60, seconds % 60]
