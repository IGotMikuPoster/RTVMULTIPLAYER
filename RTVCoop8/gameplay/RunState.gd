extends RefCounted

const DIRECTORY := "user://rtv_coop_8"
const PATH := DIRECTORY + "/run.cfg"

static func profile_path(run_id: String, identity: String) -> String:
	return DIRECTORY + "/characters/" + (run_id + "/" + identity).sha256_text() + ".tres"

static func checkpoint_character(run_id: String, identity: String) -> Error:
	if run_id.is_empty() or identity.is_empty() or not FileAccess.file_exists("user://Character.tres"):
		return ERR_UNAVAILABLE
	var target := profile_path(run_id, identity)
	DirAccess.make_dir_recursive_absolute(target.get_base_dir())
	var pending := target + ".pending"
	var result := DirAccess.copy_absolute("user://Character.tres", pending)
	if result != OK:
		return result
	return DirAccess.rename_absolute(pending, target)

static func restore_character(run_id: String, identity: String) -> Error:
	if run_id.is_empty() or identity.is_empty():
		return ERR_INVALID_PARAMETER
	var source := profile_path(run_id, identity)
	if not FileAccess.file_exists(source):
		return ERR_FILE_NOT_FOUND
	if FileAccess.get_file_as_bytes(source).is_empty():
		return ERR_FILE_CORRUPT
	# Validate before replacing the current character with a stored checkpoint.
	if ResourceLoader.load(source, "", ResourceLoader.CACHE_MODE_IGNORE) == null:
		return ERR_FILE_CORRUPT
	var pending := DIRECTORY + "/restore.pending"
	var result := DirAccess.copy_absolute(source, pending)
	if result != OK:
		return result
	result = DirAccess.rename_absolute(pending, "user://Character.tres")
	if result == OK:
		ResourceLoader.load("user://Character.tres", "", ResourceLoader.CACHE_MODE_REPLACE)
	return result

static func discard_character(run_id: String, identity: String) -> void:
	var target := profile_path(run_id, identity)
	if FileAccess.file_exists(target):
		DirAccess.remove_absolute(target)

static func load_id() -> String:
	var config := ConfigFile.new()
	return String(config.get_value("run", "id", "")) if config.load(PATH) == OK else ""

static func save_id(id: String) -> void:
	DirAccess.make_dir_recursive_absolute(DIRECTORY)
	var config := ConfigFile.new()
	config.set_value("run", "id", id)
	config.save(PATH)

static func clear_id() -> void:
	if FileAccess.file_exists(PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(PATH))

static func initialize_character(difficulty: int, loader: Node) -> bool:
	var script := load("res://Scripts/CharacterSave.gd")
	if script == null:
		return false
	var character: Resource = script.new()
	var kits: Variant = loader.get("startingKits")
	apply_preset(character, difficulty, kits if kits is Array else [])
	# New co-op runs should not erase the previous local character without a copy.
	DirAccess.make_dir_recursive_absolute(DIRECTORY + "/backups")
	if FileAccess.file_exists("user://Character.tres"):
		var backup := DIRECTORY + "/backups/Character-%d.tres" % int(Time.get_unix_time_from_system())
		if DirAccess.copy_absolute("user://Character.tres", backup) != OK:
			return false
	if ResourceSaver.save(character, "user://Character.tres") != OK:
		return false
	ResourceLoader.load("user://Character.tres", "", ResourceLoader.CACHE_MODE_REPLACE)
	return true

static func apply_preset(character: Resource, difficulty: int, kits: Array) -> void:
	if difficulty == 1:
		character.set("initialSpawn", true)
		if not kits.is_empty():
			character.set("startingKit", kits.pick_random())
	else:
		for field in ["health", "hydration", "energy", "mental", "temperature"]:
			character.set(field, float(randi_range(25, 100)))

static func save_world(state: Dictionary) -> void:
	var script := load("res://Scripts/WorldSave.gd")
	if script == null:
		return
	var world: Resource = script.new()
	for field in ["difficulty", "season", "day", "time", "weather"]:
		world.set(field, state[field])
	world.set("weatherTime", state.weather_time)
	ResourceSaver.save(world, "user://World.tres")
	ResourceLoader.load("user://World.tres", "", ResourceLoader.CACHE_MODE_REPLACE)
