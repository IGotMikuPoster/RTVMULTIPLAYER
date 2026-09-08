extends RefCounted

const PROTOCOL_VERSION := 20
const MOD_VERSION := "0.5.0"

static func public_title() -> String:
	var manifest := ConfigFile.new()
	if manifest.load("res://mod.txt") == OK:
		return String(manifest.get_value("mod", "name", "RTV Co-op"))
	return "RTV Co-op"
const MAX_PLAYERS := 8
const DEFAULT_PORT := 9058
const SNAPSHOT_HZ := 20.0
const MAX_SNAPSHOT_RATE := 35.0
const MAX_PLAYER_SPEED := 16.0
const MAX_TELEPORT_DISTANCE := 12.0
const MAX_NAME_LENGTH := 32
const MAX_MAP_LENGTH := 64
const MAX_WEATHER_LENGTH := 40
const WORLD_STATE_HZ := 1.0
const AI_STATE_HZ := 15.0
const LOOT_STATE_HZ := 2.0
const MAX_AI_ENTITIES := 64
const MAX_LOOT_ENTITIES := 256
const MAX_DAMAGE := 250.0
const MAX_COMBAT_DISTANCE := 300.0
const REVIVE_DISTANCE := 3.0
const PING_DISTANCE := 150.0
const PING_LIFETIME_MS := 12000
const MELEE_DISTANCE := 3.5
const MELEE_DAMAGE := 25.0
const EXPLOSION_DAMAGE := 40.0
const MAX_EXPLOSION_SIZE := 25.0
const MAX_THROW_DISTANCE := 80.0
const EXPLOSION_DEDUP_MS := 750
const EXPLOSION_DEDUP_DISTANCE := 1.5
const AI_DEATH_POSE_PHASES_MS := [0, 300, 900, 2000, 5000, 10500]
const FOOTSTEP_SURFACES := ["Grass", "Dirt", "Asphalt", "Rock", "Wood", "Metal", "Concrete", "Generic", "SnowHard"]
const ALLOWED_SCENES := [
	"Menu", "Intro", "Death", "Tutorial", "Cabin", "Attic", "Classroom",
	"Tent", "Bunker", "Village", "School", "Highway", "Outpost",
	"Minefield", "Apartments", "Terminal", "Template",
]

static func sanitize_player_name(raw_name: String) -> String:
	var cleaned := raw_name.strip_edges()
	cleaned = cleaned.replace("\n", " ").replace("\r", " ").replace("\t", " ")
	if cleaned.is_empty():
		cleaned = "Vostok Survivor"
	return cleaned.left(MAX_NAME_LENGTH)

static func sanitize_map(raw_map: String) -> String:
	var cleaned := raw_map.strip_edges()
	if cleaned.length() > MAX_MAP_LENGTH:
		cleaned = cleaned.left(MAX_MAP_LENGTH)
	return cleaned

static func is_valid_port(port: int) -> bool:
	return port >= 1024 and port <= 65535

static func parse_endpoint(raw_endpoint: String, fallback_port: int = DEFAULT_PORT) -> Dictionary:
	var text := raw_endpoint.strip_edges()
	var host := text
	var port := fallback_port
	if text.begins_with("["):
		var closing := text.find("]")
		if closing > 1:
			host = text.substr(1, closing - 1)
			if text.length() > closing + 2 and text[closing + 1] == ":":
				port = int(text.substr(closing + 2))
	elif text.count(":") == 1:
		var separator := text.rfind(":")
		var candidate := text.substr(separator + 1)
		if candidate.is_valid_int():
			host = text.left(separator)
			port = int(candidate)
	host = host.strip_edges().left(253)
	return {"host": host, "port": port, "valid": not host.is_empty() and is_valid_port(port)}

static func format_endpoint(host: String, port: int) -> String:
	return "[%s]:%d" % [host, port] if host.contains(":") else "%s:%d" % [host, port]

static func is_valid_scene(scene: String) -> bool:
	return ALLOWED_SCENES.has(sanitize_map(scene))

static func is_valid_footstep(map_name: String, kind: int, surface: String, water: bool, season: int) -> bool:
	return is_valid_scene(map_name) and kind in [0, 1, 2] and surface in FOOTSTEP_SURFACES and typeof(water) == TYPE_BOOL and season in [1, 2]

static func resolve_scene_name(scene_root_name: String, map_export_name: String, configured_map: String) -> String:
	for candidate in [map_export_name, scene_root_name, configured_map]:
		var normalized := sanitize_map(String(candidate))
		if is_valid_scene(normalized):
			return normalized
	return ""

static func is_valid_snapshot(frame: Dictionary) -> bool:
	if not frame.has_all(["peer", "seq", "map", "position", "yaw", "pitch", "velocity", "stance", "actions"]):
		return false
	if typeof(frame.peer) != TYPE_INT or int(frame.peer) <= 0:
		return false
	if typeof(frame.seq) != TYPE_INT or int(frame.seq) < 0:
		return false
	if typeof(frame.map) != TYPE_STRING or String(frame.map).length() > MAX_MAP_LENGTH:
		return false
	if typeof(frame.position) != TYPE_VECTOR3 or not Vector3(frame.position).is_finite():
		return false
	if typeof(frame.velocity) != TYPE_VECTOR3 or not Vector3(frame.velocity).is_finite():
		return false
	if Vector3(frame.velocity).length() > MAX_PLAYER_SPEED * 2.0:
		return false
	if typeof(frame.yaw) != TYPE_FLOAT and typeof(frame.yaw) != TYPE_INT:
		return false
	if typeof(frame.pitch) != TYPE_FLOAT and typeof(frame.pitch) != TYPE_INT:
		return false
	if not is_finite(float(frame.yaw)) or not is_finite(float(frame.pitch)):
		return false
	if absf(float(frame.pitch)) > PI * 0.6:
		return false
	if typeof(frame.stance) != TYPE_INT or int(frame.stance) < 0 or int(frame.stance) > 2:
		return false
	if typeof(frame.actions) != TYPE_INT or int(frame.actions) < 0 or int(frame.actions) > 255:
		return false
	if frame.has("health") and ((typeof(frame.health) != TYPE_FLOAT and typeof(frame.health) != TYPE_INT) or not is_finite(float(frame.health)) or float(frame.health) < 0.0 or float(frame.health) > 100.0):
		return false
	if frame.has("downed") and typeof(frame.downed) != TYPE_BOOL:
		return false
	if frame.has("weapon_type") and (typeof(frame.weapon_type) != TYPE_INT or int(frame.weapon_type) < 0 or int(frame.weapon_type) > 2):
		return false
	if frame.has("airborne") and typeof(frame.airborne) != TYPE_BOOL:
		return false
	if frame.has("shot") and (typeof(frame.shot) != TYPE_INT or int(frame.shot) < 0):
		return false
	if frame.has("weapon") and (typeof(frame.weapon) != TYPE_STRING or (not String(frame.weapon).is_empty() and not valid_weapon_key(String(frame.weapon)))):
		return false
	for field in ["backpack", "run"]:
		if not frame.get(field, "") is String or String(frame.get(field, "")).length() > 80:
			return false
	if not frame.get("attachments", []) is Array or frame.get("attachments", []).size() > 24:
		return false
	for key in frame.get("attachments", []):
		if not key is String or not valid_weapon_key(key):
			return false
	var optic: Variant = frame.get("optic_position", 0.0)
	if typeof(optic) not in [TYPE_FLOAT, TYPE_INT] or not is_finite(float(optic)) or absf(float(optic)) > 2.0:
		return false
	if typeof(frame.get("suppressed", false)) != TYPE_BOOL:
		return false
	if typeof(frame.get("fire_mode", 1)) != TYPE_INT or int(frame.get("fire_mode", 1)) not in [1, 2]:
		return false
	if typeof(frame.get("step", 0)) != TYPE_INT or int(frame.get("step", 0)) < 0:
		return false
	if typeof(frame.get("step_kind", 0)) != TYPE_INT or int(frame.get("step_kind", 0)) not in [0, 1, 2]:
		return false
	if not frame.get("surface", "Generic") is String or String(frame.get("surface", "Generic")).length() > 24:
		return false
	if typeof(frame.get("water", false)) != TYPE_BOOL:
		return false
	if typeof(frame.get("season", 1)) != TYPE_INT or int(frame.get("season", 1)) not in [1, 2]:
		return false
	return true

static func valid_weapon_key(value: String) -> bool:
	if value.is_empty() or value.length() > 80 or value.ends_with("_Rig"):
		return false
	for character in value:
		if not (character >= "a" and character <= "z") and not (character >= "A" and character <= "Z") and not (character >= "0" and character <= "9") and character not in ["_", "-"]:
			return false
	return true

static func is_valid_traversal_state(value: Dictionary) -> bool:
	if not value.has_all(["revision", "phase", "exit", "source", "destination", "votes", "total"]):
		return false
	for key in ["revision", "votes", "total"]:
		if typeof(value[key]) != TYPE_INT or int(value[key]) < 0:
			return false
	for key in ["phase", "exit", "source", "destination"]:
		if typeof(value[key]) != TYPE_STRING:
			return false
	if int(value.total) > MAX_PLAYERS or int(value.votes) > int(value.total):
		return false
	if value.phase == "idle":
		return String(value.exit).is_empty() and int(value.votes) == 0
	if value.phase not in ["voting", "preparing", "committed"] or int(value.total) == 0:
		return false
	var exit_path := String(value.exit)
	return not exit_path.is_empty() and exit_path.length() <= 256 and not exit_path.begins_with("/") and not exit_path.contains("..") and not exit_path.contains(":") and is_valid_scene(String(value.source)) and is_valid_scene(String(value.destination))

static func sanitize_player_state(raw: Variant) -> Dictionary:
	if typeof(raw) != TYPE_DICTIONARY:
		return {}
	var value: Dictionary = raw
	if typeof(value.get("life_revision", 0)) != TYPE_INT or not value.get("run", "") is String or String(value.get("run", "")).length() > 80:
		return {}
	if (typeof(value.get("health", null)) != TYPE_FLOAT and typeof(value.get("health", null)) != TYPE_INT):
		return {}
	if typeof(value.get("downed", null)) != TYPE_BOOL or typeof(value.get("map", null)) != TYPE_STRING:
		return {}
	if typeof(value.get("position", null)) != TYPE_VECTOR3 or not Vector3(value.position).is_finite():
		return {}
	return {
		"run": String(value.get("run", "")).left(80),
		"life_revision": maxi(0, int(value.get("life_revision", 0))),
		"revive_item": String(value.get("revive_item", "")) if value.get("revive_item", "") in ["Bandage", "Bandage_Improvised", "Medkit", "IFAK", "AFAK"] else "",
		"health": clampf(float(value.get("health", 100.0)), 0.0, 100.0),
		"downed": bool(value.get("downed", false)),
		"map": sanitize_map(String(value.get("map", ""))),
		"position": Vector3(value.get("position", Vector3.ZERO)),
	}

static func is_valid_player_state(raw: Variant) -> bool:
	if typeof(raw) != TYPE_DICTIONARY:
		return false
	var value: Dictionary = raw
	if not value.has_all(["health", "downed", "map", "position"]):
		return false
	if (typeof(value.health) != TYPE_FLOAT and typeof(value.health) != TYPE_INT) or not is_finite(float(value.health)):
		return false
	if float(value.health) < 0.0 or float(value.health) > 100.0 or typeof(value.downed) != TYPE_BOOL:
		return false
	if typeof(value.map) != TYPE_STRING or not is_valid_scene(String(value.map)):
		return false
	return typeof(value.position) == TYPE_VECTOR3 and Vector3(value.position).is_finite()

static func sanitize_ping(raw: Variant) -> Dictionary:
	if typeof(raw) != TYPE_DICTIONARY:
		return {}
	var value: Dictionary = raw
	if typeof(value.get("peer", null)) != TYPE_INT or typeof(value.get("serial", null)) != TYPE_INT:
		return {}
	if typeof(value.get("map", null)) != TYPE_STRING or typeof(value.get("position", null)) != TYPE_VECTOR3:
		return {}
	return {
		"peer": int(value.peer),
		"serial": int(value.serial),
		"map": sanitize_map(String(value.map)),
		"position": Vector3(value.position),
	}

static func is_valid_ping(raw: Variant) -> bool:
	if typeof(raw) != TYPE_DICTIONARY:
		return false
	var value: Dictionary = raw
	if not value.has_all(["peer", "serial", "map", "position"]):
		return false
	if typeof(value.peer) != TYPE_INT or int(value.peer) <= 0:
		return false
	if typeof(value.serial) != TYPE_INT or int(value.serial) < 0:
		return false
	if typeof(value.map) != TYPE_STRING or not is_valid_scene(String(value.map)):
		return false
	return typeof(value.position) == TYPE_VECTOR3 and Vector3(value.position).is_finite()

static func valid_entity_id(raw: Variant) -> bool:
	if typeof(raw) != TYPE_STRING:
		return false
	var value := String(raw)
	return not value.is_empty() and value.length() <= 120 and not value.contains("..")

static func mod_manifest_digest(manifest: Array) -> String:
	var normalized: Array[String] = []
	for entry in manifest:
		if typeof(entry) == TYPE_DICTIONARY:
			var mod_id := String(entry.get("id", "unknown")).to_lower()
			var version := String(entry.get("version", "0"))
			normalized.append("%s@%s" % [mod_id, version])
	normalized.sort()
	return "|".join(normalized).sha256_text()

static func bounded_manifest(raw_manifest: Variant) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if typeof(raw_manifest) != TYPE_ARRAY:
		return result
	for raw_entry in raw_manifest:
		if result.size() >= 256:
			break
		if typeof(raw_entry) != TYPE_DICTIONARY:
			continue
		var mod_id := String(raw_entry.get("id", "")).strip_edges().left(80)
		var version := String(raw_entry.get("version", "0")).strip_edges().left(40)
		if not mod_id.is_empty():
			result.append({"id": mod_id, "version": version})
	return result

static func sanitize_world_state(raw_state: Variant) -> Dictionary:
	if typeof(raw_state) != TYPE_DICTIONARY:
		return {}
	var raw: Dictionary = raw_state
	var state := {
		"run": String(raw.get("run", "")).left(80),
		"revision": maxi(0, int(raw.get("revision", 0))),
		"map": sanitize_map(String(raw.get("map", ""))),
		"difficulty": clampi(int(raw.get("difficulty", 1)), 1, 3),
		"season": clampi(int(raw.get("season", 1)), 1, 2),
		"day": clampi(int(raw.get("day", 1)), 1, 1000000),
		"time": clampi(int(raw.get("time", 1200)), 0, 2400),
		"weather": String(raw.get("weather", "Neutral")).strip_edges().left(MAX_WEATHER_LENGTH),
		"weather_time": clampf(float(raw.get("weather_time", 0.0)), 0.0, 86400.0),
	}
	return state

static func is_valid_world_state(raw_state: Variant) -> bool:
	if typeof(raw_state) != TYPE_DICTIONARY:
		return false
	var raw: Dictionary = raw_state
	if not raw.has_all(["revision", "map", "difficulty", "season", "day", "time", "weather", "weather_time"]):
		return false
	if not raw.get("run", "") is String or String(raw.get("run", "")).length() > 80:
		return false
	if typeof(raw.revision) != TYPE_INT or int(raw.revision) < 0:
		return false
	if typeof(raw.map) != TYPE_STRING or not is_valid_scene(String(raw.map)):
		return false
	if typeof(raw.difficulty) != TYPE_INT or int(raw.difficulty) < 1 or int(raw.difficulty) > 3:
		return false
	if typeof(raw.season) != TYPE_INT or int(raw.season) < 1 or int(raw.season) > 2:
		return false
	if typeof(raw.day) != TYPE_INT or int(raw.day) < 1 or int(raw.day) > 1000000:
		return false
	if typeof(raw.time) != TYPE_INT or int(raw.time) < 0 or int(raw.time) > 2400:
		return false
	if typeof(raw.weather) != TYPE_STRING or String(raw.weather).is_empty() or String(raw.weather).length() > MAX_WEATHER_LENGTH:
		return false
	if (typeof(raw.weather_time) != TYPE_FLOAT and typeof(raw.weather_time) != TYPE_INT) or not is_finite(float(raw.weather_time)):
		return false
	return float(raw.weather_time) >= 0.0 and float(raw.weather_time) <= 86400.0

static func world_state_digest(raw_state: Dictionary) -> String:
	var state := sanitize_world_state(raw_state)
	state.erase("revision")
	return JSON.stringify(state, "", true).sha256_text()
