extends Node

const SETTINGS_PATH := "user://rtv_coop_8/settings.cfg"
const CHECKPOINT_INTERVAL := 60.0
const Protocol = preload("res://RTVCoop8/core/CoopProtocol.gd")
const CapabilityRegistryScript = preload("res://RTVCoop8/compatibility/CapabilityRegistry.gd")
const SessionScript = preload("res://RTVCoop8/network/CoopSession.gd")
const HostAddressServiceScript = preload("res://RTVCoop8/network/HostAddressService.gd")
const SteamBridgeScript = preload("res://RTVCoop8/network/SteamBridge.gd")
const PanelScript = preload("res://RTVCoop8/ui/CoopPanel.gd")
const RemotePlayerScript = preload("res://RTVCoop8/presentation/RemotePlayer.gd")
const GameplaySyncScript = preload("res://RTVCoop8/gameplay/GameplaySync.gd")
const TravelVoteScript = preload("res://RTVCoop8/core/TravelVote.gd")
const RunState = preload("res://RTVCoop8/gameplay/RunState.gd")

var _library: Variant
var _capabilities := CapabilityRegistryScript.new()
var _session: Node
var _address_service: Node
var _steam: Node
var _panel: CanvasLayer
var _hud: Label
var _local_player: Node3D
var _game_data: Resource
var _remote_players: Dictionary = {}
var _pending_footsteps: Dictionary = {}
var _snapshot_accumulator := 0.0
var _snapshot_sequence := 0
var _display_name := "Vostok Survivor"
var _port := Protocol.DEFAULT_PORT
var _address_active := false
var _world_accumulator := 0.0
var _pending_remote_scene := ""
var _applying_remote_scene := false
var _scene_replace_available := false
var _share_info: Dictionary = {}
var _checkpoint_accumulator := 0.0
var _was_online := false
var _menu_button: Button
var _steam_session := false
var _steam_lobby_id := ""
var _pending_steam_lobby := ""
var _gameplay: Node
var _local_downed := false
var _player_state_accumulator := 0.0
var _travel_vote := TravelVoteScript.new()
var _travel_label: Label
var _travel_revision := -1
var _prepared_revision := -1
var _committed_revision := -1
var _travel_frozen := false
var _loading_scene := ""
var _loading_from_id := 0
var _loading_since := 0
var _allowed_scene := ""
var _local_shots := 0
var _expected_host_map := ""
var _run_id := ""
var _local_body: Dictionary = {}
var _body_frames: Dictionary = {}
var _character_ready_at := 0
var _local_steps := 0
var _step_kind := 0
var _step_surface := "Generic"
var _step_water := false
var _step_season := 1
var _ending_run := false
var _downed_screen: CanvasLayer
var _traders: Node
var _restore_profile_on_join := true
var _checkpoint_pending := false
var _checkpoint_retry_at := 0
var _group_sleep: Node
var _shelter: Node
var _travel_commit_pending := false

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	Engine.set_meta("RTVCoop8API", self)
	_load_settings()
	_run_id = RunState.load_id()
	_session = SessionScript.new()
	_session.name = "Session"
	add_child(_session)
	_session.configure(_display_name, _port, _capabilities)
	_session.state_changed.connect(_on_session_state_changed)
	_session.roster_changed.connect(_on_roster_changed)
	_session.snapshot_received.connect(_on_snapshot_received)
	_session.checkpoint_requested.connect(func(): _checkpoint_pending = true)
	_session.footstep_received.connect(_on_remote_footstep)
	_session.compatibility_warning.connect(_on_compatibility_warning)
	_session.world_state_received.connect(_on_world_state_received)
	_session.travel_requested.connect(_on_travel_requested)
	_session.traversal_vote_requested.connect(_on_traversal_vote)
	_session.traversal_state_received.connect(_on_traversal_state)
	_session.traversal_ready_requested.connect(_on_traversal_ready)
	_session.game_over_received.connect(_on_game_over_received)
	_gameplay = GameplaySyncScript.new()
	_gameplay.name = "GameplaySync"
	add_child(_gameplay)
	_gameplay.configure(_session, self)
	_traders = preload("res://RTVCoop8/gameplay/TraderSync.gd").new()
	_traders.name = "TraderSync"
	_traders.session = _session
	_traders.api = self
	add_child(_traders)
	_group_sleep = preload("res://RTVCoop8/gameplay/GroupSleep.gd").new()
	_group_sleep.name = "GroupSleep"
	_group_sleep.session = _session
	_group_sleep.api = self
	add_child(_group_sleep)
	_shelter = preload("res://RTVCoop8/gameplay/ShelterSync.gd").new()
	_shelter.name = "ShelterSync"
	_shelter.session = _session
	_shelter.api = self
	add_child(_shelter)

	_address_service = HostAddressServiceScript.new()
	_address_service.name = "HostAddressService"
	add_child(_address_service)
	_address_service.share_info_changed.connect(_on_share_info_changed)

	_panel = PanelScript.new()
	_panel.name = "Panel"
	add_child(_panel)
	_panel.host_requested.connect(_on_direct_host_requested)
	_panel.join_requested.connect(_on_direct_join_requested)
	_panel.leave_requested.connect(_on_leave_requested)
	_panel.steam_host_requested.connect(_on_steam_host_requested)
	_panel.steam_join_requested.connect(_on_steam_join_requested)
	_panel.steam_invite_requested.connect(_on_steam_friend_invite)
	_panel.steam_overlay_requested.connect(_on_steam_overlay_requested)
	_panel.steam_friends_requested.connect(_on_steam_friends_requested)

	_steam = SteamBridgeScript.new()
	_steam.name = "SteamBridge"
	_steam.status_changed.connect(_on_steam_status_changed)
	_steam.user_ready.connect(_on_steam_user_ready)
	_steam.invite_received.connect(_on_steam_invite_received)
	add_child(_steam)

	_build_hud()
	_downed_screen = preload("res://RTVCoop8/ui/DownedScreen.gd").new()
	add_child(_downed_screen)
	get_tree().node_added.connect(_on_node_added)
	_connect_loader()
	_apply_command_line()

func _exit_tree() -> void:
	if Engine.has_meta("RTVCoop8API") and Engine.get_meta("RTVCoop8API") == self:
		Engine.remove_meta("RTVCoop8API")
	if _session != null:
		if _gameplay == null or not _gameplay.has_pending_transfers():
			_checkpoint_game_state(false)
		_session.leave()

func api_version() -> int:
	return 2

func register_adapter(mod_id: String, adapter: Object) -> bool:
	return _capabilities.register_adapter(mod_id, adapter)

func session_state() -> Dictionary:
	return {
		"online": _session != null and _session.is_online(),
		"host": _session != null and _session.is_online() and _session.multiplayer.is_server(),
		"peer_count": _session.peer_count() if _session != null else 0,
		"max_players": Protocol.MAX_PLAYERS,
		"protocol": Protocol.PROTOCOL_VERSION,
		"mod_version": Protocol.MOD_VERSION,
		"world": _session.current_world_state() if _session != null else {},
		"share": _share_info.duplicate(true),
	}

func _process(delta: float) -> void:
	if _downed_screen != null:
		_downed_screen.visible = _local_downed and _session.is_online() and not _ending_run
	if Input.is_key_pressed(KEY_F10) and not bool(get_meta("f10_down", false)):
		set_meta("f10_down", true)
		_hud.visible = not _hud.visible
	elif not Input.is_key_pressed(KEY_F10):
		set_meta("f10_down", false)

	if scene_is_loading():
		_poll_scene_ready()
		return
	if not _session.is_online():
		return
	if _checkpoint_pending and Time.get_ticks_msec() >= _checkpoint_retry_at and _local_player != null and not _gameplay.has_pending_transfers():
		_checkpoint_retry_at = Time.get_ticks_msec() + 2000
		_checkpoint_pending = not _checkpoint_game_state(false)
	if _session.state == SessionScript.State.HOSTING and _travel_vote.expire(Time.get_ticks_msec()):
		_session.publish_traversal(_travel_vote.snapshot())
	_checkpoint_accumulator += delta
	if _checkpoint_accumulator >= CHECKPOINT_INTERVAL:
		_checkpoint_accumulator = fmod(_checkpoint_accumulator, CHECKPOINT_INTERVAL)
		if _gameplay == null or not _gameplay.has_pending_transfers():
			_checkpoint_game_state(false)
	if _session.state == SessionScript.State.HOSTING:
		_world_accumulator += delta
		if _world_accumulator >= 1.0 / Protocol.WORLD_STATE_HZ:
			_world_accumulator = fmod(_world_accumulator, 1.0 / Protocol.WORLD_STATE_HZ)
			_publish_world_state()
	_validate_local_player()
	_player_state_accumulator += delta
	if _player_state_accumulator >= 0.25 and _local_player != null:
		_player_state_accumulator = fmod(_player_state_accumulator, 0.25)
		_gameplay.submit_local_state(_local_player.global_position, _current_map())
	_snapshot_accumulator += delta
	var interval := 1.0 / Protocol.SNAPSHOT_HZ
	if _snapshot_accumulator >= interval and _local_player != null:
		_snapshot_accumulator = fmod(_snapshot_accumulator, interval)
		_submit_pose()
	_update_remote_visibility()

func _connect_loader() -> void:
	if not Engine.has_meta("RTVModLib"):
		push_warning("[RTVCoop8] RTVModLib unavailable; player discovery fallback active")
		return
	_library = Engine.get_meta("RTVModLib")
	if bool(_library._is_ready):
		_on_frameworks_ready()
	else:
		_library.frameworks_ready.connect(_on_frameworks_ready, CONNECT_ONE_SHOT)

func _on_frameworks_ready() -> void:
	_capabilities.discover(_library)
	var ready_hook: int = _library.hook("controller-_ready-post", _on_controller_ready, 800)
	_library.hook("controller-playfootstep-post", _on_footstep, 800)
	_library.hook("controller-playfootstepjump-post", _on_footstep_jump, 800)
	_library.hook("controller-playfootstepland-post", _on_footstep_land, 800)
	var scene_hook: int = _library.hook("loader-loadscene-post", _on_scene_loaded, 800)
	var scene_replace: int = _library.hook("loader-loadscene", _on_load_scene_replace, 100)
	var new_game_replace: int = _library.hook("loader-newgame", _on_new_game_replace, 100)
	_library.hook("loader-newgame-post", _on_new_game_post, 800)
	_library.hook("loader-loadcharacter-post", _on_character_loaded, 800)
	_library.hook("loader-savecharacter-post", _on_character_saved, 800)
	_group_sleep.register_hooks(_library)
	_shelter.register_hooks(_library)
	_library.hook("interface-complete", _on_personal_completion, 90)
	_library.hook("interface-complete-post", _on_personal_completion_post, 800)
	var format_save_replace: int = _library.hook("loader-formatsave", _on_format_save_replace, 100)
	var menu_ready_hook: int = _library.hook("menu-_ready-post", _on_menu_ready, 800)
	var transition_hook: int = _library.hook("transition-interact", _on_transition_interact, 90)
	if transition_hook < 0:
		push_warning("[RTVCoop8] Transition vote hook unavailable; co-op exits are blocked")
	_gameplay.register_hooks(_library)
	_traders.register_hooks(_library)
	_scene_replace_available = scene_replace >= 0
	if ready_hook < 0 or scene_hook < 0 or scene_replace < 0 or new_game_replace < 0 or format_save_replace < 0 or menu_ready_hook < 0:
		push_warning("[RTVCoop8] One or more observation hooks failed to register")
	if not _scene_replace_available:
		push_warning("[RTVCoop8] Another mod owns Loader.LoadScene; travel will converge after local transitions instead of being intercepted")
	_session.configure(_display_name, _port, _capabilities)

func _on_controller_ready() -> void:
	var caller: Variant = _library._caller
	if caller is Node3D:
		_local_player = caller

func _on_footstep() -> void:
	_note_local_footstep(0)

func _on_footstep_jump() -> void:
	_note_local_footstep(1)

func _on_footstep_land() -> void:
	_note_local_footstep(2)

func _note_local_footstep(kind: int) -> void:
	if _session == null or not _session.is_online():
		return
	_local_steps += 1
	_step_kind = clampi(kind, 0, 2)
	if _game_data == null:
		_game_data = load("res://Resources/GameData.tres")
	if _game_data != null:
		_step_surface = String(_game_data.get("surface")).left(24)
		if _step_surface.is_empty():
			_step_surface = "Generic"
		_step_water = bool(_game_data.get("isWater"))
		_step_season = clampi(int(_game_data.get("season")), 1, 2)
	_session.submit_footstep(_current_map(), _step_kind, _step_surface, _step_water, _step_season)

func _on_scene_loaded(_scene: String) -> void:
	# The loader hook can return before its fade and scene swap finish.
	# Readiness is checked against the new scene instance and Compiler state.
	if not _session.is_online():
		call_deferred("_rescan_local_player")

func _on_load_scene_replace(raw_scene: String) -> void:
	if not _session.is_online():
		return
	var scene := Protocol.sanitize_map(raw_scene)
	if scene == _allowed_scene:
		_allowed_scene = ""
		_prepare_scene_load(scene)
		return
	if _session.state == SessionScript.State.HOSTING and not scene_is_loading() and _current_map() in ["", "Menu", "Intro", "Death"]:
		_prepare_scene_load(scene)
		return
	_library.skip_super()
	_panel.set_status("Use the same exit to vote for travel")

func _on_new_game_replace(_difficulty: Variant, _season: Variant) -> void:
	if _session.state != SessionScript.State.CONNECTED:
		return
	_library.skip_super()
	_panel.set_status("Only the host can create the co-op world", true)

func _on_new_game_post(_difficulty: Variant, _season: Variant) -> void:
	if _session.state != SessionScript.State.HOSTING:
		return
	_run_id = "%d-%d" % [int(Time.get_unix_time_from_system()), randi()]
	RunState.save_id(_run_id)
	_reset_run_lives()

func _reset_run_lives() -> void:
	_local_downed = false
	_local_body.clear()
	_body_frames.clear()
	_clear_remote_players()
	_gameplay.reset_run(_run_id)

func _on_character_loaded() -> void:
	# The vanilla function awaits 0.1 seconds; its wrapper's post-hook can run
	# before that continuation. Delay readiness past that load as well.
	_character_ready_at = Time.get_ticks_msec() + 250

func _on_format_save_replace() -> void:
	if _session.state != SessionScript.State.CONNECTED or _ending_run:
		return
	_library.skip_super()
	_panel.set_status("Client save formatting blocked while connected", true)

func _on_menu_ready() -> void:
	var menu: Variant = _library._caller
	if not menu is Control:
		return
	var buttons := (menu as Node).get_node_or_null("Main/Buttons")
	if buttons == null or buttons.has_node("RTVCoopMultiplayer"):
		return
	var reference := buttons.get_node_or_null("Load") as Button
	_menu_button = Button.new()
	_menu_button.name = "RTVCoopMultiplayer"
	_menu_button.text = "MULTIPLAYER"
	if reference != null:
		_menu_button.theme = reference.theme
		_menu_button.theme_type_variation = reference.theme_type_variation
		_menu_button.custom_minimum_size = reference.custom_minimum_size
		_menu_button.size_flags_horizontal = reference.size_flags_horizontal
		_menu_button.size_flags_vertical = reference.size_flags_vertical
	buttons.add_child(_menu_button)
	var load_index := reference.get_index() if reference != null else 0
	buttons.move_child(_menu_button, mini(load_index + 1, buttons.get_child_count() - 1))
	_menu_button.pressed.connect(func():
		if menu.has_method("PlayClick"):
			menu.call("PlayClick")
		_panel.show_panel()
	)

func _on_node_added(node: Node) -> void:
	if node is Node3D and _is_controller(node):
		_local_player = node

func _is_controller(node: Node) -> bool:
	var script: Script = node.get_script()
	return script != null and script.resource_path == "res://Scripts/Controller.gd"

func _rescan_local_player() -> void:
	_local_player = null
	var root := get_tree().current_scene
	if root == null:
		return
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is Node3D and _is_controller(node):
			_local_player = node
			return
		stack.append_array(node.get_children())

func _validate_local_player() -> void:
	if _local_player != null and is_instance_valid(_local_player):
		return
	_rescan_local_player()

func _submit_pose() -> void:
	_snapshot_sequence += 1
	var head := _local_player.get_node_or_null("Pelvis/Riser/Head") as Node3D
	var pitch := head.rotation.x if head != null else 0.0
	var velocity: Vector3 = (_local_player as CharacterBody3D).velocity if _local_player is CharacterBody3D else Vector3.ZERO
	var actions := 0
	var stance := 0
	if _game_data != null:
		if bool(_game_data.get("isAiming")):
			actions |= 1
		if bool(_game_data.get("isFiring")):
			actions |= 2
		if bool(_game_data.get("isReloading")):
			actions |= 4
		if bool(_game_data.get("isCrouching")):
			stance = 1
	var frame := {
		"peer": 0,
		"seq": _snapshot_sequence,
		"map": _current_map(),
		"position": _local_player.global_position,
		"yaw": _local_player.global_rotation.y,
		"pitch": pitch,
		"velocity": velocity,
		"stance": stance,
		"actions": actions,
		"health": clampf(float(_game_data.get("health")), 0.0, 100.0) if _game_data != null else 100.0,
		"downed": _local_downed,
		"weapon_type": _equipped_weapon_type(),
		"airborne": not (_local_player as CharacterBody3D).is_on_floor() if _local_player is CharacterBody3D else false,
		"shot": _local_shots,
			"weapon": _equipped_weapon_key(),
			"step": _local_steps,
			"step_kind": _step_kind,
			"surface": _step_surface,
			"water": _step_water,
			"season": _step_season,
	}
	_gameplay.note_player_pose(_session.multiplayer.get_unique_id(), frame)
	frame.merge(_equipped_appearance())
	if _local_downed and not _local_body.is_empty():
		frame.map = _local_body.map
		frame.position = _local_body.position
		frame.yaw = float(_local_body.get("yaw", frame.yaw))
		frame.velocity = Vector3.ZERO
	_session.submit_local_snapshot(frame)

func _current_map() -> String:
	# Every playable scene uses the generic root name "Map". Map.gd exposes the
	# actual network-safe destination through mapName.
	var map_root := get_node_or_null("/root/Map")
	var scene := get_tree().current_scene
	if _game_data == null:
		_game_data = load("res://Resources/GameData.tres")
	return Protocol.resolve_scene_name(
		String(scene.name) if scene != null else "",
		String(map_root.get("mapName")) if map_root != null else "",
		String(_game_data.get("currentMap")) if _game_data != null else ""
	)

func _on_snapshot_received(peer_id: int, frame: Dictionary) -> void:
	if bool(frame.get("downed", false)):
		if not _body_frames.has(peer_id):
			_body_frames[peer_id] = frame.duplicate(true)
		frame = _body_frames[peer_id].duplicate(true)
	else:
		_body_frames.erase(peer_id)
	if scene_is_loading() or String(frame.map) != _current_map():
		return
	_gameplay.note_player_pose(peer_id, frame)
	var remote: Variant = _remote_players.get(peer_id)
	if not is_instance_valid(remote):
		remote = RemotePlayerScript.new()
		var entry: Dictionary = _session.roster.get(peer_id, {})
		remote.configure(peer_id, String(entry.get("name", "Survivor %d" % peer_id)), _gameplay)
		_remote_players[peer_id] = remote
		var parent := get_tree().current_scene
		if parent == null:
			parent = self
		parent.add_child(remote)
	remote.push_snapshot(frame)
	_flush_pending_footsteps(peer_id, remote)

func _on_remote_footstep(peer_id: int, map_name: String, kind: int, surface: String, water: bool, season: int) -> void:
	if scene_is_loading() or map_name != _current_map():
		return
	var event := {"kind": kind, "surface": surface, "water": water, "season": season, "received_at": Time.get_ticks_msec()}
	var remote: Variant = _remote_players.get(peer_id)
	if is_instance_valid(remote):
		remote.call("play_network_footstep", event)
		return
	var pending: Array = _pending_footsteps.get(peer_id, [])
	pending.append(event)
	while pending.size() > 4:
		pending.pop_front()
	_pending_footsteps[peer_id] = pending

func _flush_pending_footsteps(peer_id: int, remote: Node) -> void:
	for event in _pending_footsteps.get(peer_id, []):
		if Time.get_ticks_msec() - int(event.get("received_at", 0)) <= 500:
			remote.call("play_network_footstep", event)
	_pending_footsteps.erase(peer_id)

func _on_roster_changed(new_roster: Dictionary) -> void:
	if _session.state == SessionScript.State.HOSTING:
		refresh_travel_members()
		_gameplay.call_deferred("on_roster_changed")
	elif new_roster.is_empty():
		_expected_host_map = ""
		_travel_revision = -1
		_prepared_revision = -1
		_committed_revision = -1
		_release_travel_freeze()
		if _travel_label != null:
			_travel_label.hide()
	_panel.set_roster(new_roster)
	_panel.set_online(_session.is_online())
	for raw_peer_id in _remote_players.keys():
		var peer_id := int(raw_peer_id)
		if not new_roster.has(peer_id):
			var remote: Variant = _remote_players[peer_id]
			if is_instance_valid(remote):
				remote.queue_free()
			_remote_players.erase(peer_id)
			_pending_footsteps.erase(peer_id)
		else:
			var remote: Variant = _remote_players[peer_id]
			if is_instance_valid(remote):
				var entry: Dictionary = new_roster[peer_id]
				remote.call("set_display_name", String(entry.get("name", "Survivor %d" % peer_id)))
	_update_hud()

func _on_session_state_changed(new_state: int, detail: String) -> void:
	var online_now: bool = _session.is_online()
	var starting_session := online_now and not _was_online
	if starting_session:
		_restore_profile_on_join = true
	if _was_online and not online_now and not _ending_run and (_gameplay == null or not _gameplay.has_pending_transfers()):
		_checkpoint_game_state(false, true)
	_was_online = online_now
	_panel.set_status(detail, new_state == SessionScript.State.ERROR)
	_panel.set_online(online_now)
	if new_state == SessionScript.State.HOSTING:
		if starting_session:
			_session.reset_player_lives(_run_id)
		if not _address_active:
			_address_active = true
			_address_service.begin(_port)
		call_deferred("_publish_world_state")
	elif _address_active:
		_address_active = false
		_address_service.stop()
	_update_hud()

func _on_game_over_received(reason: String) -> void:
	if _ending_run:
		return
	_ending_run = true
	if _game_data != null:
		_game_data.set("freeze", true)
	_panel.set_status((reason if not reason.is_empty() else "Everyone is down") + " — the co-op run is over", true)
	call_deferred("_finish_failed_run")

func _finish_failed_run() -> void:
	if _session != null and _session.is_online() and _session.multiplayer.is_server():
		# Give ENet time to place the reliable game-over packet on every peer before
		# the host closes its transport and changes scene.
		await get_tree().create_timer(0.75, true, false, true).timeout
	var loader := get_node_or_null("/root/Loader")
	if loader != null and loader.has_method("FormatSave"):
		loader.call("FormatSave")
	RunState.discard_character(_run_id, _save_identity())
	RunState.clear_id()
	_run_id = ""
	_local_downed = false
	_local_body.clear()
	_body_frames.clear()
	if _steam_session:
		_steam.close_session()
		_steam_session = false
		_steam_lobby_id = ""
	_session.leave()
	if loader != null and loader.has_method("LoadScene"):
		loader.call("LoadScene", "Menu")

func _on_leave_requested() -> void:
	if scene_is_loading():
		_panel.set_status("Wait for the area to finish loading before leaving", true)
		return
	if _gameplay != null and _gameplay.has_pending_transfers():
		_panel.set_status("Close containers and traders, then wait for item transfers to finish", true)
		return
	_checkpoint_game_state(true)
	if _steam_session:
		_steam.close_session()
		_steam_session = false
		_steam_lobby_id = ""
		_panel.set_steam_lobby("", false)
	_session.leave()

func _on_direct_host_requested() -> void:
	_ending_run = false
	_steam.close_session()
	_steam_session = false
	_session.host()

func _on_direct_join_requested(address: String) -> void:
	_ending_run = false
	_steam.close_session()
	_steam_session = false
	_session.join(address)

func _on_steam_host_requested() -> void:
	_ending_run = false
	if not _steam.is_ready():
		_panel.set_status("Steam is still starting. Check that Steam is running.", true)
		return
	_panel.set_status("Creating an eight-player Steam lobby…")
	if _session.host() != OK:
		return
	_steam.create_lobby(_on_steam_lobby_created)

func _on_steam_lobby_created(response: Dictionary) -> void:
	if not bool(response.get("ok", false)):
		_session.leave()
		_panel.set_status("Steam lobby failed: %s" % String(response.get("error", "unknown error")), true)
		return
	var data: Dictionary = response.get("data", {})
	_steam_lobby_id = String(data.get("lobby_id", ""))
	_steam_session = true
	_panel.set_steam_lobby(_steam_lobby_id, true)
	_panel.set_status("Steam lobby ready — invite friends, then start or load your world")
	_steam.start_p2p_host(_port, _on_steam_host_tunnel)
	_refresh_steam_friends()

func _on_steam_host_tunnel(response: Dictionary) -> void:
	if not bool(response.get("ok", false)):
		_panel.set_status("Steam relay failed: %s" % String(response.get("error", "unknown error")), true)
		_on_leave_requested()

func _on_steam_join_requested(lobby_id: String) -> void:
	_ending_run = false
	var normalized := lobby_id.strip_edges()
	if normalized.is_empty() or not normalized.is_valid_int():
		_panel.set_status("Enter a valid Steam lobby ID", true)
		return
	_panel.set_status("Joining Steam lobby…")
	_steam.join_lobby(normalized, _on_steam_lobby_joined)

func _on_steam_lobby_joined(response: Dictionary) -> void:
	if not bool(response.get("ok", false)):
		_panel.set_status("Could not join Steam lobby: %s" % String(response.get("error", "unknown error")), true)
		return
	var data: Dictionary = response.get("data", {})
	_steam_lobby_id = String(data.get("lobby_id", ""))
	var owner := String(data.get("owner_steam_id", ""))
	_panel.set_steam_lobby(_steam_lobby_id, false)
	_panel.set_status("Securing Steam P2P route to host…")
	_steam.start_p2p_client(owner, _on_steam_client_tunnel)

func _on_steam_client_tunnel(response: Dictionary) -> void:
	if not bool(response.get("ok", false)):
		_panel.set_status("Steam route failed: %s" % String(response.get("error", "unknown error")), true)
		_steam.close_session()
		return
	var data: Dictionary = response.get("data", {})
	var tunnel_port := int(data.get("tunnel_port", 0))
	if not Protocol.is_valid_port(tunnel_port):
		_panel.set_status("Steam returned an invalid local route", true)
		_steam.close_session()
		return
	_steam_session = true
	_session.join(Protocol.format_endpoint("127.0.0.1", tunnel_port))

func _on_steam_overlay_requested() -> void:
	_steam.open_invite_dialog(_on_steam_action)

func _on_steam_friend_invite(steam_id: String) -> void:
	_steam.invite_friend(steam_id, _on_steam_action)

func _on_steam_action(response: Dictionary) -> void:
	if not bool(response.get("ok", false)):
		_panel.set_status("Steam action failed: %s" % String(response.get("error", "unknown error")), true)

func _on_steam_friends_requested() -> void:
	_steam.open_friends()
	_refresh_steam_friends()

func _refresh_steam_friends() -> void:
	if _steam.is_ready():
		_steam.get_friends(_on_steam_friends)

func _on_steam_friends(response: Dictionary) -> void:
	if bool(response.get("ok", false)):
		_panel.set_friends(Array(response.get("data", [])))

func _on_steam_status_changed(_status: String, detail: String) -> void:
	_panel.set_steam_status(detail, _status == "ready")

func _on_steam_user_ready(user: Dictionary) -> void:
	var steam_name := Protocol.sanitize_player_name(String(user.get("name", "")))
	_display_name = steam_name
	_session.update_display_name(_display_name)
	_panel.set_steam_status("Steam: %s" % steam_name, true)
	_refresh_steam_friends()
	if not _pending_steam_lobby.is_empty():
		var lobby_id := _pending_steam_lobby
		_pending_steam_lobby = ""
		_on_steam_join_requested(lobby_id)

func _on_steam_invite_received(lobby_id: String) -> void:
	_panel.show_panel()
	_panel.set_status("Steam invitation accepted — joining lobby…")
	_on_steam_join_requested(lobby_id)

func _checkpoint_game_state(show_status: bool, allow_offline := false) -> bool:
	if _session == null or (not _session.is_online() and not allow_offline):
		return false
	if _ending_run or scene_is_loading() or (_gameplay != null and _gameplay.has_pending_transfers()):
		_checkpoint_pending = not _ending_run
		return false
	var loader := get_node_or_null("/root/Loader")
	if loader == null:
		return false
	var saved := false
	# Loader.SaveCharacter expects the live inventory interface and otherwise
	# throws on menus, intros, and loading screens.
	if get_node_or_null("/root/Map/Core/UI/Interface") != null and loader.has_method("SaveCharacter"):
		loader.call("SaveCharacter")
		saved = true
	if _session.state == SessionScript.State.HOSTING and Protocol.is_valid_scene(_current_map()) and loader.has_method("SaveWorld"):
		loader.call("SaveWorld")
		saved = true
	if show_status:
		_panel.set_status("Progress checkpoint saved; session closed safely" if saved else "Session closed (no playable save was loaded)")
	return saved

func _save_identity() -> String:
	if _steam != null:
		var account: Dictionary = _steam.get("user")
		var identity := String(account.get("steam_id", ""))
		if not identity.is_empty():
			return identity
	return "local"

func _on_personal_completion(resource: Resource) -> void:
	if not _session.is_online(): return
	var ui: Node = _library._caller
	var target: Node = ui.get("inputTarget")
	if target == null or resource == null or _local_downed:
		_library.skip_super()
		return
	# Vanilla completion consumes and awards through this player's interface.
	# Never broadcast its inventory outputs to the party.
	var script: Script = resource.get_script()
	if script != null and script.resource_path.ends_with("/TaskData.gd"):
		var trader: Node = ui.get("trader")
		if trader == null or target.get("taskData") != resource or Array(trader.get("tasksCompleted")).has(resource.get("name")):
			_library.skip_super()

func _on_personal_completion_post(_resource: Resource) -> void:
	if _session.is_online():
		_checkpoint_pending = true

func _on_character_saved() -> void:
	if _ending_run or _session == null or not _session.is_online() or _run_id.is_empty():
		return
	if _gameplay != null and _gameplay.has_pending_transfers():
		_checkpoint_pending = true
		return
	if RunState.checkpoint_character(_run_id, _save_identity()) != OK:
		show_gameplay_status("Co-op character checkpoint failed", true)
	if _session.multiplayer.is_server():
		_session.request_group_checkpoint()

func _on_share_info_changed(info: Dictionary) -> void:
	_share_info = info.duplicate(true)
	_panel.set_share_info(info)

func _on_world_state_received(state: Dictionary) -> void:
	if _session.state == SessionScript.State.HOSTING:
		return
	if not _expected_host_map.is_empty():
		if String(state.get("map", "")) != _expected_host_map:
			return
		_expected_host_map = ""
	_apply_world_state(state)

func _on_travel_requested(peer_id: int, scene: String) -> void:
	_panel.set_status("%s requested %s; everyone must use the exit" % [_peer_name(peer_id), scene])

func _publish_world_state() -> void:
	if _session.state != SessionScript.State.HOSTING or scene_is_loading():
		return
	var map_name := _current_map()
	if not Protocol.is_valid_scene(map_name):
		return
	if _game_data == null:
		_game_data = load("res://Resources/GameData.tres")
	var simulation := get_node_or_null("/root/Simulation")
	var state := {
		"run": _run_id,
		"revision": 0,
		"map": map_name,
		"difficulty": int(_game_data.get("difficulty")) if _game_data != null else 1,
		"season": int(simulation.get("season")) if simulation != null else 1,
		"day": int(simulation.get("day")) if simulation != null else 1,
		"time": int(simulation.get("time")) if simulation != null else 1200,
		"weather": String(simulation.get("weather")) if simulation != null else "Neutral",
		"weather_time": float(simulation.get("weatherTime")) if simulation != null else 0.0,
	}
	_session.publish_world_state(state)

func _apply_world_state(state: Dictionary) -> void:
	if not Protocol.is_valid_world_state(state):
		return
	if String(state.map) in ["Menu", "Intro", "Death"]:
		return
	var fresh_run := not String(state.get("run", "")).is_empty() and String(state.run) != _run_id
	if not fresh_run and _restore_profile_on_join and not _run_id.is_empty():
		var restored := RunState.restore_character(_run_id, _save_identity())
		if restored != OK and restored != ERR_FILE_NOT_FOUND:
			show_gameplay_status("Could not restore the co-op character", true)
			return
	_restore_profile_on_join = false
	if fresh_run:
		var loader := get_node_or_null("/root/Loader")
		var restored := RunState.restore_character(String(state.run), _save_identity())
		if restored != OK and restored != ERR_FILE_NOT_FOUND:
			show_gameplay_status("Could not restore the co-op character", true)
			return
		if restored != OK and (loader == null or not RunState.initialize_character(int(state.difficulty), loader)):
			show_gameplay_status("Could not prepare the new character. Your previous save was kept.", true)
			return
		_run_id = String(state.run)
		RunState.save_id(_run_id)
		_reset_run_lives()
	elif not _run_id.is_empty() and String(_session.get("_run_id")) != _run_id:
		_session.reset_player_lives(_run_id)
	if _game_data == null:
		_game_data = load("res://Resources/GameData.tres")
	if _game_data != null:
		_game_data.set("difficulty", int(state.difficulty))
		_game_data.set("season", int(state.season))
	var simulation := get_node_or_null("/root/Simulation")
	if simulation != null:
		simulation.set("season", int(state.season))
		simulation.set("day", int(state.day))
		simulation.set("time", int(state.time))
		simulation.set("weather", String(state.weather))
		simulation.set("weatherTime", float(state.weather_time))
	var target_map := String(state.map)
	if (target_map == _current_map() and not fresh_run) or _applying_remote_scene:
		return
	if target_map == "Intro":
		_panel.set_status("Host is creating the world… waiting for the playable map")
		return
	var loader := get_node_or_null("/root/Loader")
	if loader == null or not loader.has_method("LoadScene"):
		_panel.set_status("Host moved to %s, but the game Loader is unavailable" % target_map, true)
		return
	_pending_remote_scene = target_map
	RunState.save_world(state)
	_applying_remote_scene = true
	_panel.set_status("Following host to %s…" % target_map)
	call_deferred("_load_coop_scene", target_map)

func _peer_name(peer_id: int) -> String:
	var entry: Dictionary = _session.roster.get(peer_id, {})
	return String(entry.get("name", "Player %d" % peer_id))

func _on_compatibility_warning(peer_id: int, report: Dictionary) -> void:
	push_warning("[RTVCoop8] Peer %d has a different mod manifest: %s" % [peer_id, JSON.stringify(report)])
	_panel.set_status("Connected — mod differences detected; unsupported state will remain host-authoritative")

func _update_remote_visibility() -> void:
	var local_map := _current_map()
	for remote in _remote_players.values():
		if is_instance_valid(remote):
			remote.set_visible_for_map(local_map)

func _build_hud() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 119
	add_child(layer)
	_hud = Label.new()
	_hud.position = Vector2(20, 4)
	_hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud.add_theme_font_size_override("font_size", 14)
	_hud.add_theme_color_override("font_color", Color(0.75, 0.92, 0.80))
	_hud.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	_hud.add_theme_constant_override("shadow_offset_x", 2)
	_hud.add_theme_constant_override("shadow_offset_y", 2)
	layer.add_child(_hud)
	_travel_label = Label.new()
	_travel_label.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	_travel_label.offset_top = 24
	_travel_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_travel_label.add_theme_font_size_override("font_size", 18)
	_travel_label.add_theme_color_override("font_shadow_color", Color.BLACK)
	_travel_label.add_theme_constant_override("shadow_offset_x", 1)
	_travel_label.add_theme_constant_override("shadow_offset_y", 1)
	_travel_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_travel_label.hide()
	layer.add_child(_travel_label)
	_update_hud()

func _update_hud() -> void:
	if _hud == null or _session == null:
		return
	_hud.text = "Multiplayer: %d/%d (%s)" % [_session.peer_count(), Protocol.MAX_PLAYERS, _state_label(_session.state).capitalize()]

func _state_label(value: int) -> String:
	match value:
		SessionScript.State.HOSTING:
			return "HOST"
		SessionScript.State.CONNECTING:
			return "CONNECTING"
		SessionScript.State.CONNECTED:
			return "CONNECTED"
		SessionScript.State.ERROR:
			return "ERROR"
		_:
			return "OFFLINE"

func current_map_name() -> String:
	return "" if scene_is_loading() else _current_map()

func note_local_shot() -> void:
	_local_shots += 1

func _equipped_weapon_key() -> String:
	var slot: Variant = _equipped_slot()
	var data: Variant = slot.get("itemData") if slot != null else null
	var key := String(data.get("file")) if data != null else ""
	return key if Protocol.valid_weapon_key(key) else ""

func _equipped_slot() -> Variant:
	var interface := get_node_or_null("/root/Map/Core/UI/Interface")
	if interface == null or _game_data == null:
		return null
	var equipment: Node = interface.get("equipmentUI")
	if equipment == null:
		return null
	var flags := ["primary", "secondary", "knife", "grenade1", "grenade2"]
	for index in flags.size():
		if bool(_game_data.get(flags[index])) and equipment.get_child_count() > index + 1:
			var holder := equipment.get_child(index + 1)
			if holder.get_child_count() > 0:
				return holder.get_child(0).get("slotData")
	return null

func _equipped_weapon_type() -> int:
	var slot: Variant = _equipped_slot()
	var data: Variant = slot.get("itemData") if slot != null else null
	if data == null or String(data.get("type")) != "Weapon":
		return 0
	return 2 if String(data.get("weaponType")) == "Pistol" else 1

func _equipped_appearance() -> Dictionary:
	var result := {"attachments": [], "optic_position": 0.0, "backpack": "", "suppressed": false, "fire_mode": 1}
	var interface := get_node_or_null("/root/Map/Core/UI/Interface")
	var equipment: Node = interface.get("equipmentUI") if interface != null else null
	if equipment != null:
		for holder in equipment.get_children():
			if holder.get_child_count() == 0:
				continue
			var worn: Variant = holder.get_child(0).get("slotData")
			var data: Variant = worn.get("itemData") if worn != null else null
			if data != null and String(data.get("type")) == "Backpack":
				var key := String(data.get("file"))
				if Protocol.valid_weapon_key(key):
					result.backpack = key
	var slot: Variant = _equipped_slot()
	if slot == null:
		return result
	result.fire_mode = clampi(int(slot.get("mode")), 1, 2)
	var weapon_data: Variant = slot.get("itemData")
	result.suppressed = bool(weapon_data.get("nativeSuppressor")) if weapon_data != null else false
	for item in slot.get("nested"):
		var key := String(item.get("file"))
		if Protocol.valid_weapon_key(key):
			result.attachments.append(key)
		if String(item.get("subtype")) == "Muzzle":
			result.suppressed = true
	result.optic_position = clampf(float(slot.get("position")), -2.0, 2.0)
	return result

func scene_is_loading() -> bool:
	return not _loading_scene.is_empty()

func _clear_remote_players() -> void:
	for remote in _remote_players.values():
		if is_instance_valid(remote):
			remote.hide()
			remote.queue_free()
	_remote_players.clear()
	_pending_footsteps.clear()

func _prepare_scene_load(scene: String) -> void:
	if _panel != null:
		_panel.hide_panel()
	_loading_scene = scene
	_loading_since = Time.get_ticks_msec()
	_character_ready_at = 0
	var current := get_tree().current_scene
	_loading_from_id = current.get_instance_id() if current != null else 0
	_clear_remote_players()
	_local_player = null
	_gameplay.reset_scene()
	if _traders != null:
		_traders.reset_scene()
	if _group_sleep != null:
		_group_sleep.cancel_group()
	if _shelter != null:
		_shelter.reset_scene()
	print("[RTVCoop8] Loading scene: %s" % scene)

func _load_coop_scene(scene: String) -> void:
	if scene_is_loading() or not Protocol.is_valid_scene(scene):
		return
	var loader := get_node_or_null("/root/Loader")
	if loader == null:
		return
	_allowed_scene = scene
	if not _scene_replace_available:
		_prepare_scene_load(scene)
	loader.call("LoadScene", scene)
	_allowed_scene = ""

func _poll_scene_ready() -> void:
	var current := get_tree().current_scene
	if current == null or current.get_instance_id() == _loading_from_id or _current_map() != _loading_scene:
		if Time.get_ticks_msec() - _loading_since > 45000:
			_panel.set_status("Area loading is taking too long. Save the game log before restarting.", true)
		return
	if _loading_scene not in ["Menu", "Intro", "Death"] and _game_data != null:
		if not bool(_game_data.get("isCaching")) and not bool(_game_data.get("isTransitioning")) and (bool(_game_data.get("interface")) or bool(_game_data.get("settings"))):
			_close_startup_ui()
		if bool(_game_data.get("isCaching")) or bool(_game_data.get("isTransitioning")) or (bool(_game_data.get("freeze")) and not _local_downed):
			return
		if _character_ready_at == 0:
			_character_ready_at = Time.get_ticks_msec() + 250
			return
		if Time.get_ticks_msec() < _character_ready_at:
			return
	_loading_scene = ""
	_applying_remote_scene = false
	_pending_remote_scene = ""
	if _gameplay != null and _gameplay.has_method("scene_ready"):
		_gameplay.scene_ready()
	_travel_frozen = false
	if _current_map() not in ["Menu", "Intro", "Death"]:
		_close_startup_ui()
	_rescan_local_player()
	if _local_downed and not _local_body.is_empty():
		apply_authoritative_player_state(_local_body)
		if is_instance_valid(_local_player) and String(_local_body.map) == _current_map():
			_local_player.global_position = Vector3(_local_body.position)
	for peer_id in _body_frames.keys():
		_on_snapshot_received(int(peer_id), _body_frames[peer_id].duplicate(true))
	_travel_label.hide()
	if _session.state == SessionScript.State.HOSTING:
		_travel_vote.reset(_living_travel_members())
		_session.publish_traversal(_travel_vote.snapshot())
		_publish_world_state()
	else:
		var world: Dictionary = _session.current_world_state()
		if not world.is_empty():
			_on_world_state_received(world)

func _close_startup_ui() -> void:
	_panel.hide_panel()
	var ui := get_node_or_null("/root/Map/Core/UI")
	if ui != null and ui.has_method("Return"):
		ui.call("Return")
	if _game_data != null:
		_game_data.set("interface", false)
		_game_data.set("settings", false)
		_game_data.set("isTrading", false)
		_game_data.set("freeze", _local_downed)
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

func _on_transition_interact() -> void:
	if not _session.is_online():
		return
	var transition: Node = _library._caller
	if bool(transition.get("locked")) and not scene_is_loading():
		return
	_library.skip_super()
	if _game_data != null and not scene_is_loading():
		_game_data.set("isTransitioning", false)
	if scene_is_loading() or _travel_frozen or _local_downed:
		return
	var scene := get_tree().current_scene
	if scene != null:
		_session.vote_traversal(String(scene.get_path_to(transition)), _current_map())

func _resolve_exit(exit_id: String, source: String) -> Node3D:
	if scene_is_loading() or not TravelVoteScript.valid_exit_id(exit_id) or source != _current_map():
		return null
	var scene := get_tree().current_scene
	var node := scene.get_node_or_null(NodePath(exit_id)) if scene != null else null
	if not node is Node3D or not node.has_method("UpdateSimulation") or not node.has_method("Interact"):
		return null
	if not Protocol.is_valid_scene(String(node.get("nextMap"))):
		return null
	return node

func _on_traversal_vote(peer_id: int, exit_id: String, source: String) -> void:
	if _session.state != SessionScript.State.HOSTING:
		return
	if _gameplay.has_pending_transfers():
		show_gameplay_status("Finish the item transfer before travelling.", true)
		return
	refresh_travel_members()
	var transition := _resolve_exit(exit_id, source)
	if transition == null or bool(transition.get("locked")):
		return
	var pose: Dictionary = _session.latest_pose(peer_id)
	if pose.is_empty() or String(pose.map) != source or bool(pose.get("downed", false)) or Vector3(pose.position).distance_to(transition.global_position) > 12.0:
		return
	if _travel_vote.vote(peer_id, exit_id, source, String(transition.get("nextMap")), Time.get_ticks_msec()):
		_session.publish_traversal(_travel_vote.snapshot())

func _on_traversal_ready(peer_id: int, revision: int, ready: bool) -> void:
	if not ready and _session.state == SessionScript.State.HOSTING:
		show_gameplay_status("Travel cancelled: a player is not ready. Close interactions and retry.", true)
	if _session.state == SessionScript.State.HOSTING and _travel_vote.acknowledge(peer_id, revision, ready):
		_session.publish_traversal(_travel_vote.snapshot())

func _on_traversal_state(value: Dictionary) -> void:
	var revision := int(value.get("revision", -1))
	if revision < _travel_revision:
		return
	_travel_revision = revision
	var phase := String(value.get("phase", "idle"))
	if phase == "idle":
		if _travel_commit_pending: return
		if not scene_is_loading():
			_release_travel_freeze()
			_travel_label.hide()
		return
	_travel_label.text = "Travel to %s: %d/%d" % [String(value.get("destination", "")), int(value.get("votes", 0)), int(value.get("total", 0))]
	_travel_label.show()
	if phase == "preparing" and _prepared_revision != revision:
		_prepared_revision = revision
		call_deferred("_prepare_traversal", value.duplicate(true))
	elif phase == "committed" and _committed_revision != revision:
		_committed_revision = revision
		_travel_commit_pending = true
		call_deferred("_commit_traversal", value.duplicate(true))

func _prepare_traversal(value: Dictionary) -> void:
	if int(value.revision) != _travel_revision:
		return
	if _local_downed:
		_travel_frozen = true
		return
	var transition := _resolve_exit(String(value.exit), String(value.source))
	var ready := transition != null and not _local_downed and is_instance_valid(_local_player)
	ready = ready and not _gameplay.has_pending_transfers()
	if ready:
		ready = not bool(transition.get("locked")) and String(transition.get("nextMap")) == String(value.destination) and _local_player.global_position.distance_to(transition.global_position) <= 12.0
	if ready and _game_data != null:
		_travel_frozen = true
		_game_data.set("freeze", true)
	if not ready:
		show_gameplay_status("Travel not ready: %s" % ("finish pending interactions" if _gameplay.has_pending_transfers() else "move to the exit and wait for loading to finish"), true)
	_session.acknowledge_traversal(int(value.revision), ready)

func _release_travel_freeze() -> void:
	if _travel_frozen and not scene_is_loading() and _game_data != null:
		_game_data.set("freeze", _local_downed)
		_game_data.set("isTransitioning", false)
	_travel_frozen = false

func _commit_traversal(value: Dictionary) -> void:
	if int(value.revision) != _committed_revision or not _travel_frozen:
		_travel_commit_pending = false
		return
	_travel_commit_pending = false
	if _local_downed:
		if _session.state == SessionScript.State.CONNECTED:
			_expected_host_map = String(value.destination)
		_load_coop_scene(String(value.destination))
		return
	var transition := _resolve_exit(String(value.exit), String(value.source))
	if transition == null:
		_release_travel_freeze()
		return
	var loader := get_node_or_null("/root/Loader")
	if loader == null or _game_data == null:
		_release_travel_freeze()
		return
	_game_data.set("isTransitioning", true)
	_game_data.set("previousMap", String(value.source))
	_game_data.set("currentMap", String(value.destination))
	if _session.state == SessionScript.State.CONNECTED:
		_expected_host_map = String(value.destination)
	if not bool(transition.get("tutorialExit")):
		_game_data.set("energy", maxf(0.0, float(_game_data.get("energy")) - float(transition.get("energy"))))
		_game_data.set("hydration", maxf(0.0, float(_game_data.get("hydration")) - float(transition.get("hydration"))))
		if _session.state == SessionScript.State.HOSTING:
			transition.call("UpdateSimulation")
		loader.call("SaveCharacter")
		if _session.state == SessionScript.State.HOSTING:
			loader.call("SaveWorld")
			if bool(transition.get("shelterExit")):
				loader.call("SaveShelter", String(value.source))
	_travel_label.text = "Loading %s…" % String(value.destination)
	_load_coop_scene(String(value.destination))

func enter_local_downed_state() -> void:
	if _local_downed:
		return
	if _game_data == null:
		_game_data = load("res://Resources/GameData.tres")
	if _game_data == null:
		return
	_local_downed = true
	_game_data.set("health", 0.0)
	_game_data.set("isDead", false)
	_game_data.set("freeze", true)
	if _local_player != null:
		_local_body = {"health": 0.0, "downed": true, "map": _current_map(), "position": _local_player.global_position, "yaw": _local_player.global_rotation.y}
		_gameplay.submit_local_state(_local_player.global_position, _current_map())
	show_gameplay_status("You are down. A teammate can revive you with a bandage or medical kit.", true)

func apply_authoritative_player_state(state: Dictionary) -> void:
	if _game_data == null:
		_game_data = load("res://Resources/GameData.tres")
	if _game_data == null:
		return
	var was_downed := _local_downed
	_local_downed = bool(state.get("downed", false))
	if _local_downed and _local_body.is_empty():
		_local_body = state.duplicate(true)
		_local_body["yaw"] = _local_player.global_rotation.y if is_instance_valid(_local_player) else 0.0
	_game_data.set("health", float(state.get("health", 100.0)))
	_game_data.set("isDead", false)
	if _local_downed:
		_game_data.set("freeze", true)
	elif was_downed:
		if is_instance_valid(_local_player) and String(state.map) == _current_map():
			_local_player.global_position = Vector3(state.position)
		_local_body.clear()
		_game_data.set("freeze", false)
		show_gameplay_status("Revived with %d health" % int(state.get("health", 0.0)))
	var manager := get_node_or_null("/root/Map/Core/Camera/Manager") as Node3D
	if manager != null:
		manager.visible = not _local_downed

func apply_remote_player_state(peer_id: int, state: Dictionary) -> void:
	if not bool(state.get("downed", false)):
		_body_frames.erase(peer_id)
	var remote: Variant = _remote_players.get(peer_id)
	if remote != null and is_instance_valid(remote):
		remote.set_downed(bool(state.get("downed", false)))

func _living_travel_members() -> Array:
	var members: Array = []
	for peer_id in _session.roster:
		var life: Dictionary = _session.authoritative_player_state(int(peer_id))
		if not bool(life.get("downed", false)):
			members.append(peer_id)
	members.sort()
	return members

func refresh_travel_members() -> void:
	if _session.state != SessionScript.State.HOSTING:
		return
	var members := _living_travel_members()
	if members != _travel_vote.members:
		_travel_vote.reset(members)
		_session.publish_traversal(_travel_vote.snapshot())

func show_gameplay_status(text: String, is_error := false) -> void:
	if _panel != null:
		_panel.set_status(text, is_error)
	var loader := get_node_or_null("/root/Loader")
	if loader != null and loader.has_method("Message") and is_instance_valid(_local_player):
		loader.call("Message", text, Color.ORANGE_RED if is_error else Color.WHITE)

func _load_settings() -> void:
	var settings := ConfigFile.new()
	if settings.load(SETTINGS_PATH) == OK:
		_display_name = Protocol.sanitize_player_name(String(settings.get_value("identity", "display_name", _display_name)))
		_port = int(settings.get_value("network", "port", _port))
	if not Protocol.is_valid_port(_port):
		_port = Protocol.DEFAULT_PORT

func _apply_command_line() -> void:
	var arguments := OS.get_cmdline_args()
	for index in range(arguments.size()):
		var argument := String(arguments[index])
		if argument == "--rtv-host":
			_session.host.call_deferred()
		elif argument.begins_with("--rtv-join="):
			_session.join.call_deferred(argument.trim_prefix("--rtv-join="))
		elif argument == "+connect_lobby" and index + 1 < arguments.size():
			_pending_steam_lobby = String(arguments[index + 1]).strip_edges()
		elif argument.begins_with("+connect_lobby="):
			_pending_steam_lobby = argument.trim_prefix("+connect_lobby=").strip_edges()
