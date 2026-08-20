@tool
class_name MaterialClassifier
extends RefCounted

const IMAGE_EXTENSIONS: PackedStringArray = ["jpg", "jpeg", "png", "webp", "tga", "bmp"]
const PREVIEW_TOKENS: PackedStringArray = ["preview", "preview1", "preview2", "thumb", "thumbnail", "sphere", "swatch", "card", "translucency"]
const SIXTEEN_BIT_TOKENS: PackedStringArray = ["bump16", "disp16", "height16", "displacement16"]

const CHANNEL_SYNONYMS: Dictionary = {
	"albedo": ["basecolor", "base_color", "albedo", "diffuse", "diff", "color", "col"],
	"normal": ["normalgl", "normal_gl", "normaldx", "normal_dx", "nrm", "normal", "nor_gl", "nor"],
	"roughness": ["roughness", "rough", "gloss", "glossiness"],
	"metallic": ["metalness", "metallic", "metal"],
	"ambient_occlusion": ["ambientocclusion", "ambient_occlusion", "occlusion", "ao"],
	"height": ["displacement", "disp", "bump", "height"],
	"emission": ["emissive", "emission"],
	"opacity": ["opacity", "alpha", "transparency"],
	"reflectivity": ["reflectivity", "refl", "specular", "spec"],
	"arm_packed": ["arm"],
	"id_map": ["idmap", "id_map"],
	"sss": ["scatteringcolor", "sss", "subsurface"],
}

const HEIGHT_CHANNEL_PRIORITY: PackedStringArray = ["bump", "displacement", "disp", "height"]
const NORMAL_CHANNEL_PRIORITY: PackedStringArray = ["normalgl", "normal", "normaldx"]
const REQUIRED_CHANNELS: Dictionary = {"albedo": true}
const RESOLUTION_TOKEN_REGEX_PATTERN: String = "^\\d+k?$|^k$"

static var _resolution_regex: RegEx
static var _sorted_synonyms: Dictionary = {}

static func _ensure_static_state() -> void:
	if _resolution_regex == null:
		_resolution_regex = RegEx.new()
		_resolution_regex.compile(RESOLUTION_TOKEN_REGEX_PATTERN)
	if _sorted_synonyms.is_empty():
		for channel in CHANNEL_SYNONYMS:
			var fragments: Array = CHANNEL_SYNONYMS[channel].duplicate()
			fragments.sort_custom(func(a: String, b: String) -> bool: return a.length() > b.length())
			_sorted_synonyms[channel] = fragments

static func classify_folder(filenames: PackedStringArray) -> Dictionary:
	_ensure_static_state()

	var image_files: Array = []
	for f in filenames:
		var ext := f.get_extension().to_lower()
		if IMAGE_EXTENSIONS.has(ext) and not _is_sixteen_bit_file(f):
			image_files.append(f)

	var report := {
		"files": {},
		"conflicts": {},
		"universal_tokens_stripped": [],
	}

	# stage 1 pass: exact/substring match on each file's own tokens.
	var stage1_results: Dictionary = {}
	for f in image_files:
		if _is_preview_file(f):
			stage1_results[f] = {"channel": "preview", "fragment": ""}
			continue
		stage1_results[f] = _match_tokens(_tokenize(f))

	# collisions: more than one file landing on the same real channel.
	var channel_owners: Dictionary = {}
	for f in stage1_results:
		var m: Dictionary = stage1_results[f]
		if not m.is_empty() and m["channel"] != "preview":
			channel_owners.get_or_add(m["channel"], []).append(f)

	var needs_stage2: Dictionary = {}
	for f in stage1_results:
		if stage1_results[f].is_empty():
			needs_stage2[f] = true
	for channel in channel_owners:
		if channel_owners[channel].size() > 1:
			for f in channel_owners[channel]:
				needs_stage2[f] = true

	var final_results: Dictionary = stage1_results.duplicate()

	if not needs_stage2.is_empty():
		var all_tokens: Dictionary = {}
		for f in image_files:
			all_tokens[f] = _tokenize(f)
		var universal := _find_universal_tokens(all_tokens)
		for f in needs_stage2:
			var tokens: Array = all_tokens[f].filter(func(t: String) -> bool: return not universal.has(t))
			final_results[f] = _match_tokens(tokens)
		report["universal_tokens_stripped"] = universal.keys()

	# final collision check, after the stage-2 retry.
	var final_owners: Dictionary = {}
	for f in final_results:
		var m: Dictionary = final_results[f]
		if not m.is_empty() and m["channel"] != "preview":
			final_owners.get_or_add(m["channel"], []).append(f)

	# height (bump vs disp) and normal (GL vs DX)
	var tie_break_losers: Dictionary = {}
	for channel in final_owners:
		var owners: Array = final_owners[channel]
		if owners.size() <= 1:
			continue
		if channel == "height":
			var winner := _pick_priority_winner(owners, HEIGHT_CHANNEL_PRIORITY)
			for f in owners:
				if f != winner:
					tie_break_losers[f] = true
		elif channel == "normal":
			var winner := _pick_priority_winner(owners, NORMAL_CHANNEL_PRIORITY)
			for f in owners:
				if f != winner:
					tie_break_losers[f] = true
		else:
			report["conflicts"][channel] = owners

	for f in image_files:
		var m: Dictionary = final_results.get(f, {})
		var status: String
		if tie_break_losers.has(f):
			status = "PREVIEW"
		elif not m.is_empty() and report["conflicts"].has(m["channel"]) and report["conflicts"][m["channel"]].has(f):
			status = "CONFLICT"
		elif m.is_empty():
			status = "UNKNOWN"
		elif m["channel"] == "preview":
			status = "PREVIEW"
		else:
			status = "OK"
		report["files"][f] = {
			"channel": m.get("channel", ""),
			"matched_fragment": m.get("fragment", ""),
			"status": status,
		}

	return report

static func is_fully_resolved(report: Dictionary) -> bool:
	if not report["conflicts"].is_empty():
		return false
	var resolved_channels: Dictionary = {}
	for f in report["files"]:
		var info: Dictionary = report["files"][f]
		if info["status"] == "OK":
			resolved_channels[info["channel"]] = true
	for channel in REQUIRED_CHANNELS:
		if not resolved_channels.has(channel):
			return false
	return true

static func _is_sixteen_bit_file(filename: String) -> bool:
	for token in _tokenize(filename):
		if SIXTEEN_BIT_TOKENS.has(token):
			return true
	return false

static func is_albedo_file(filename: String) -> bool:
	_ensure_static_state()
	if _is_preview_file(filename):
		return false
	var match := _match_tokens(_tokenize(filename))
	return not match.is_empty() and match["channel"] == "albedo"

static func _is_preview_file(filename: String) -> bool:
	for token in _tokenize(filename):
		if PREVIEW_TOKENS.has(token):
			return true
	return false

static func _tokenize(filename: String) -> Array:
	_ensure_static_state()
	var stem := filename.get_basename().to_lower()
	var raw_tokens := stem.split("_")
	var tokens: Array = []
	for chunk in raw_tokens:
		for piece in chunk.split("-"):
			for word in piece.split(" "):
				if word.is_empty():
					continue
				if _resolution_regex.search(word):
					continue
				tokens.append(word)
	return tokens

static func _match_tokens(tokens: Array) -> Dictionary:
	if tokens.is_empty():
		return {}
	var start: int = maxi(0, tokens.size() - 3)
	for i in range(tokens.size() - 1, start - 1, -1):
		var exact := _match_fragment_exact(tokens[i])
		if not exact.is_empty():
			return exact
	if tokens.size() == 1:
		var loose := _match_fragment_substring(tokens[0])
		if not loose.is_empty():
			return loose
	return {}

static func _match_fragment_exact(token: String) -> Dictionary:
	for channel in _sorted_synonyms:
		for frag in _sorted_synonyms[channel]:
			if frag == token:
				return {"channel": channel, "fragment": frag}
	return {}

static func _match_fragment_substring(token: String) -> Dictionary:
	for channel in _sorted_synonyms:
		for frag in _sorted_synonyms[channel]:
			if token.contains(frag):
				return {"channel": channel, "fragment": frag}
	return {}

static func _find_universal_tokens(all_tokens: Dictionary) -> Dictionary:
	var n: int = all_tokens.size()
	if n <= 2:
		return {}
	var counts: Dictionary = {}
	for f in all_tokens:
		var seen: Dictionary = {}
		for token in all_tokens[f]:
			if not seen.has(token):
				seen[token] = true
				counts[token] = counts.get(token, 0) + 1
	var universal: Dictionary = {}
	for token in counts:
		if counts[token] >= n - 1:
			universal[token] = true
	return universal

static func _pick_priority_winner(owners: Array, priority_list: PackedStringArray) -> String:
	var best_file: String = owners[0]
	var best_rank: int = _priority_rank(owners[0], priority_list)
	for f in owners:
		var rank := _priority_rank(f, priority_list)
		if rank < best_rank:
			best_rank = rank
			best_file = f
	return best_file

static func _priority_rank(filename: String, priority_list: PackedStringArray) -> int:
	var tokens := _tokenize(filename)
	for i in range(priority_list.size()):
		if tokens.has(priority_list[i]):
			return i
	return priority_list.size()
