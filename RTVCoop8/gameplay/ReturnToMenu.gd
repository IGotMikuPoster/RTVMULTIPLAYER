extends Node

const RunState = preload("res://RTVCoop8/gameplay/RunState.gd")
var api: Node
var session: Node
var library: Variant
var pending := false
var token := 0
var replies: Dictionary = {}
var deadline := 0
var was_frozen := false
var settings: Node
var committed := false
var dialog: CanvasLayer
var dialog_frozen := false
var last_save_error := ""
var bound_buttons: Dictionary = {}
const SAVE_RECORD := "user://rtv_coop_8/menu_save.cfg"

func register_hooks(value: Variant) -> void:
	library = value
	library.hook("loader-saveshelter-post", _shelter_saved, 800)

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	get_tree().node_added.connect(_node_added)
	call_deferred("_find_settings")

func _exit_tree() -> void:
	_restore_buttons()
	if get_tree().node_added.is_connected(_node_added):
		get_tree().node_added.disconnect(_node_added)

func _node_added(node: Node) -> void:
	if _is_settings(node):
		call_deferred("bind_settings", node)

func _is_settings(node: Node) -> bool:
	var script := node.get_script() as Script
	return script != null and script.resource_path == "res://Scripts/Settings.gd"

func _find_settings() -> void:
	if not session.is_online():
		return
	var scene := get_tree().current_scene
	if scene == null:
		return
	if _is_settings(scene):
		bind_settings(scene)
		return
	for node in scene.find_children("*", "", true, false):
		if _is_settings(node):
			bind_settings(node)
			return

func bind_settings(node: Node) -> void:
	if not is_instance_valid(node) or not session.is_online():
		return
	settings = node
	for field in ["menu", "exitMenu"]:
		var button := settings.get(field) as Button
		if button == null or bound_buttons.has(button):
			continue
		var removed: Array = []
		for connection in button.pressed.get_connections():
			var callback: Callable = connection.callable
			if callback.get_object() == settings and String(callback.get_method()) in ["_on_menu_pressed", "_on_exit_menu_pressed", "_rtv_vanilla__on_menu_pressed", "_rtv_vanilla__on_exit_menu_pressed"]:
				removed.append(connection)
				button.pressed.disconnect(callback)
		bound_buttons[button] = removed
		button.pressed.connect(_button_pressed)

func _settings_fully_bound() -> bool:
	if not is_instance_valid(settings):
		return false
	for field in ["menu", "exitMenu"]:
		var button := settings.get(field) as Button
		if button == null or not bound_buttons.has(button) or not button.pressed.is_connected(_button_pressed):
			return false
	return true

func _button_pressed() -> void:
	if session.is_online() and session.multiplayer.is_server():
		show_confirmation()

func _restore_buttons() -> void:
	for button in bound_buttons:
		if not is_instance_valid(button): continue
		if button.pressed.is_connected(_button_pressed):
			button.pressed.disconnect(_button_pressed)
		for connection in bound_buttons[button]:
			var callback: Callable = connection.callable
			if callback.is_valid() and not button.pressed.is_connected(callback):
				button.pressed.connect(callback, int(connection.flags))
		if button.has_meta("coop_menu_original"):
			var original: Array = button.get_meta("coop_menu_original")
			button.disabled = bool(original[0])
			button.tooltip_text = String(original[1])
			button.remove_meta("coop_menu_original")
	bound_buttons.clear()

static func elapsed_text(seconds: int) -> String:
	return "%d min %02d seconds ago" % [maxi(seconds, 0) / 60, maxi(seconds, 0) % 60]

static func readable_save(path: String) -> bool:
	return FileAccess.file_exists(path) and not FileAccess.get_file_as_bytes(path).is_empty() and ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) != null

func _shelter_saved(map_name: String) -> void:
	if not session.is_online() or not session.multiplayer.is_server() or not preload("res://RTVCoop8/core/CoopProtocol.gd").is_valid_scene(map_name):
		return
	var timestamp := int(Time.get_unix_time_from_system())
	for path in ["user://Character.tres", "user://World.tres", "user://" + map_name + ".tres"]:
		if not readable_save(path):
			last_save_error = "The latest host shelter save could not be verified."
			return
		timestamp = mini(timestamp, FileAccess.get_modified_time(path))
	var record := ConfigFile.new()
	record.set_value("save", "run", api._run_id)
	record.set_value("save", "time", timestamp)
	record.set_value("save", "map", map_name)
	DirAccess.make_dir_recursive_absolute("user://rtv_coop_8")
	if record.save(SAVE_RECORD) == OK:
		last_save_error = ""
	else:
		last_save_error = "Could not record the last verified save time."

func confirmation_text() -> String:
	var status := "No verified host shelter save recorded for this run."
	var record := ConfigFile.new()
	if record.load(SAVE_RECORD) == OK and String(record.get_value("save", "run", "")) == String(api._run_id):
		status = "Host shelter save verified: " + elapsed_text(int(Time.get_unix_time_from_system()) - int(record.get_value("save", "time", 0)))
	if not last_save_error.is_empty():
		status += "\n" + last_save_error
	var policy := save_policy(bool(api._game_data.get("shelter")), bool(api._game_data.get("tutorial")))
	status += "\n\n" + ("Returning from this shelter saves each character and the host's shelter." if policy == "save" else ("WARNING: returning from the wilderness resets each character, following the game's normal exit rules." if policy == "reset" else "Tutorial exit: no additional character save."))
	return status + "\n\nThis timestamp checks host files, not every teammate's files.\nEveryone will return to the menu and stay connected."

func show_confirmation() -> void:
	if pending or (is_instance_valid(dialog) and dialog.visible):
		return
	if not is_instance_valid(dialog):
		dialog = preload("res://RTVCoop8/ui/MenuReturnPanel.gd").new()
		add_child(dialog)
		dialog.confirmed.connect(func():
			api._game_data.set("freeze", dialog_frozen or api._local_downed)
			request())
		dialog.canceled.connect(func(): api._game_data.set("freeze", dialog_frozen or api._local_downed))
	dialog_frozen = bool(api._game_data.get("freeze"))
	api._game_data.set("freeze", true)
	dialog.show_text(confirmation_text())

func _process(_delta: float) -> void:
	if session.is_online():
		if is_instance_valid(settings) and not _settings_fully_bound():
			bind_settings(settings)
		if not _settings_fully_bound():
			_find_settings()
	else:
		_restore_buttons()
		settings = null
	if is_instance_valid(dialog) and dialog.visible and (not session.is_online() or api.scene_is_loading()):
		dialog.cancel()
	if not session.is_online():
		token = 0
	if is_instance_valid(settings):
		for field in ["menu", "exitMenu"]:
			var button: Button = settings.get(field)
			if button != null:
				if session.is_online():
					if not button.has_meta("coop_menu_original"):
						button.set_meta("coop_menu_original", [button.disabled, button.tooltip_text])
					button.disabled = not session.multiplayer.is_server() or pending or api._current_map() == "Menu"
					button.tooltip_text = "Only the host can return the group to the main menu" if not session.multiplayer.is_server() else "Return everyone to the main menu using normal game save rules"
				elif button.has_meta("coop_menu_original"):
					var original: Array = button.get_meta("coop_menu_original")
					button.disabled = bool(original[0])
					button.tooltip_text = String(original[1])
					button.remove_meta("coop_menu_original")
	if not pending:
		return
	if not session.is_online():
		_cancel_local()
	elif committed:
		if api._current_map() == "Menu" and not api.scene_is_loading():
			pending = false
			committed = false
	elif session.multiplayer.is_server() and Time.get_ticks_msec() >= deadline:
		_cancel.rpc(token)
		_cancel_local()
		api.show_gameplay_status("Menu return cancelled: a player did not respond", true)

func ready_for_return() -> bool:
	return not api.scene_is_loading() and not api._ending_run and not api._gameplay.has_pending_transfers() and get_node_or_null("/root/Loader") != null

func request() -> void:
	if not session.is_online() or not session.multiplayer.is_server() or pending:
		return
	if not ready_for_return():
		api.show_gameplay_status("Finish loading, sleeping, furniture edits and item transfers first", true)
		return
	token += 1
	replies = {1: true}
	deadline = Time.get_ticks_msec() + 10000
	_prepare_local()
	_prepare.rpc(token)
	_try_commit()

func _prepare_local() -> void:
	pending = true
	committed = false
	was_frozen = bool(api._game_data.get("freeze"))
	api._game_data.set("freeze", true)

@rpc("authority", "call_remote", "reliable", 0)
func _prepare(value: int) -> void:
	if pending or value <= token:
		return
	token = value
	var ready := ready_for_return()
	if ready:
		_prepare_local()
	_reply.rpc_id(1, token, ready)

@rpc("any_peer", "call_remote", "reliable", 0)
func _reply(value: int, ready: bool) -> void:
	if not session.multiplayer.is_server() or not pending or committed or value != token:
		return
	var sender := multiplayer.get_remote_sender_id()
	if not session.roster.has(sender):
		return
	if not ready:
		_cancel.rpc(token)
		_cancel_local()
		api.show_gameplay_status("Menu return cancelled: another player is loading or using an item, container or furniture", true)
		return
	replies[sender] = true
	_try_commit()

func _try_commit() -> void:
	for peer in session.roster:
		if not replies.has(peer):
			return
	_commit.rpc(token)
	_commit(token)

@rpc("authority", "call_remote", "reliable", 0)
func _cancel(value: int) -> void:
	if pending and value == token and not committed:
		_cancel_local()

func _cancel_local() -> void:
	pending = false
	committed = false
	if api._game_data != null:
		api._game_data.set("freeze", was_frozen or api._local_downed)

static func save_policy(shelter: bool, tutorial: bool) -> String:
	return "save" if shelter else ("none" if tutorial else "reset")

@rpc("authority", "call_remote", "reliable", 0)
func _commit(value: int) -> void:
	if not pending or committed or value != token:
		return
	committed = true
	if api.has_method("cancel_group_pause"):
		api.call("cancel_group_pause")
	var loader := get_node("/root/Loader")
	var data: Resource = api._game_data
	var policy := save_policy(bool(data.get("shelter")), bool(data.get("tutorial")))
	if policy == "save":
		loader.call("SaveCharacter")
		if session.multiplayer.is_server():
			loader.call("SaveWorld")
			loader.call("SaveShelter", api._current_map())
	elif policy == "reset":
		if session.multiplayer.is_server():
			loader.call("SaveWorld")
		loader.call("ResetCharacter")
	if policy != "none" and not String(api._run_id).is_empty():
		if RunState.checkpoint_character(api._run_id, api._save_identity()) != OK:
			push_error("Menu return: personal checkpoint write failed")
	api._checkpoint_pending = false
	api._checkpoint_accumulator = 0.0
	api._restore_profile_on_join = true
	api._revive_grace_until = 0
	api._reset_run_lives()
	api._allowed_scene = "Menu"
	loader.call("LoadScene", "Menu")
