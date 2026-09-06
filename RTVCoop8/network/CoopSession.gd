extends Node

const Protocol = preload("res://RTVCoop8/core/CoopProtocol.gd")
const RateLimiterScript = preload("res://RTVCoop8/core/PacketRateLimiter.gd")

signal state_changed(state: int, detail: String)
signal roster_changed(roster: Dictionary)
signal snapshot_received(peer_id: int, frame: Dictionary)
signal compatibility_warning(peer_id: int, report: Dictionary)
signal world_state_received(state: Dictionary)
signal travel_requested(peer_id: int, scene: String)
signal traversal_vote_requested(peer_id: int, exit_id: String, source: String)
signal traversal_state_received(value: Dictionary)
signal traversal_ready_requested(peer_id: int, revision: int, ready: bool)
signal player_state_received(peer_id: int, state: Dictionary)
signal player_hit_requested(source_peer: int, target_peer: int, damage: float, penetration: int)
signal melee_hit_requested(source_peer: int, target_peer: int, damage: float)
signal ai_hit_requested(source_peer: int, entity_id: String, hitbox: String, damage: float)
signal revive_requested(source_peer: int, target_peer: int, medical: String)
signal revive_result(success: bool, medical: String, detail: String)
signal ai_state_received(map_name: String, revision: int, entities: Array)
signal loot_state_received(map_name: String, revision: int, entities: Array)
signal loot_pickup_requested(source_peer: int, entity_id: String)
signal loot_grant_received(entity_id: String, slot: Dictionary)
signal loot_grant_result_requested(source_peer: int, entity_id: String, accepted: bool)
signal loot_drop_requested(source_peer: int, token: String, map_name: String, slot: Dictionary, position: Vector3, rotation: Vector3)
signal loot_drop_result(token: String, accepted: bool, entity_id: String)
signal container_state_received(entity_id: String, revision: int, slots: Array, properties: Dictionary)
signal container_update_requested(source_peer: int, entity_id: String, slots: Array)
signal container_snapshot_requested(source_peer: int, entity_id: String)
signal container_open_requested(source_peer: int, entity_id: String)
signal container_open_cancelled(source_peer: int, entity_id: String)
signal container_open_result(entity_id: String, accepted: bool, detail: String)
signal container_update_result(entity_id: String, accepted: bool)
signal door_state_received(map_name: String, revision: int, doors: Array)
signal door_interaction_requested(source_peer: int, entity_id: String, key: String)
signal door_interaction_result(entity_id: String, accepted: bool, consume_key: bool)
signal door_snapshot_requested(source_peer: int)
signal game_over_received(reason: String)
signal shared_world_state_received(map_name: String, revision: int, states: Array)
signal shared_interaction_requested(source_peer: int, entity_id: String, has_required_item: bool)
signal shared_interaction_result(entity_id: String, accepted: bool, consume_required_item: bool, detail: String)
signal shared_snapshot_requested(source_peer: int)
signal explosion_requested(source_peer: int, map_name: String, position: Vector3, size: float)
signal explosion_received(map_name: String, event_id: String, position: Vector3, size: float)
signal footstep_received(peer_id: int, map_name: String, kind: int, surface: String, water: bool, season: int)
signal checkpoint_requested

func request_group_checkpoint() -> void:
	if is_online() and multiplayer.is_server():
		_checkpoint.rpc(_run_id)

@rpc("authority", "call_remote", "reliable", 0)
func _checkpoint(run_id: String) -> void:
	if run_id == _run_id:
		checkpoint_requested.emit()

enum State { OFFLINE, HOSTING, CONNECTING, CONNECTED, ERROR }

var state := State.OFFLINE
var port := Protocol.DEFAULT_PORT
var display_name := "Vostok Survivor"
var compatibility: RefCounted
var roster: Dictionary = {}
var _rate_limiter := RateLimiterScript.new()
var _last_frames: Dictionary = {}
var _last_sequences: Dictionary = {}
var _handshaken: Dictionary = {}
var _pending_handshakes: Dictionary = {}
var _intentional_leave := false
var _world_state: Dictionary = {}
var _world_revision := 0
var _last_received_world_revision := -1
var _last_travel_requests: Dictionary = {}
var _last_action_requests: Dictionary = {}
var _player_states: Dictionary = {}
var _player_revisions: Dictionary = {}
var _run_id := ""
var _loot_parts: Dictionary = {}
var _loot_batch_revision := -1
var _loot_batch_map := ""

func _process(_delta: float) -> void:
	if multiplayer.multiplayer_peer == null or not multiplayer.is_server():
		return
	var now := Time.get_ticks_msec()
	for raw_peer_id in _pending_handshakes.keys():
		var peer_id := int(raw_peer_id)
		if now - int(_pending_handshakes[peer_id]) > 10000:
			_pending_handshakes.erase(peer_id)
			multiplayer.multiplayer_peer.disconnect_peer(peer_id)
			print("[RTVCoop8] Disconnected peer %d after handshake timeout" % peer_id)

func configure(new_name: String, new_port: int, registry: RefCounted) -> void:
	display_name = Protocol.sanitize_player_name(new_name)
	port = new_port if Protocol.is_valid_port(new_port) else Protocol.DEFAULT_PORT
	compatibility = registry

func update_display_name(new_name: String) -> void:
	display_name = Protocol.sanitize_player_name(new_name)
	if state == State.HOSTING and multiplayer.is_server():
		var entry := _local_roster_entry(1)
		roster[1] = entry
		_peer_identity_changed.rpc(entry)
		roster_changed.emit(roster.duplicate(true))
	elif state == State.CONNECTED:
		_update_identity.rpc_id(1, display_name)

func host() -> Error:
	leave()
	_intentional_leave = false
	var peer := ENetMultiplayerPeer.new()
	var result := peer.create_server(port, Protocol.MAX_PLAYERS - 1)
	if result != OK:
		_set_state(State.ERROR, "Could not host UDP port %d (%s)" % [port, error_string(result)])
		return result
	multiplayer.multiplayer_peer = peer
	_connect_multiplayer_signals()
	roster[1] = _local_roster_entry(1)
	_handshaken[1] = true
	_set_state(State.HOSTING, "Hosting 1/%d on UDP %d" % [Protocol.MAX_PLAYERS, port])
	roster_changed.emit(roster.duplicate(true))
	return OK

func join(address: String) -> Error:
	leave()
	_intentional_leave = false
	var endpoint := Protocol.parse_endpoint(address, port)
	if not bool(endpoint.valid):
		_set_state(State.ERROR, "Enter a valid host address and port")
		return ERR_INVALID_PARAMETER
	var normalized := String(endpoint.host)
	var remote_port := int(endpoint.port)
	var peer := ENetMultiplayerPeer.new()
	var result := peer.create_client(normalized, remote_port)
	if result != OK:
		_set_state(State.ERROR, "Could not connect to %s (%s)" % [Protocol.format_endpoint(normalized, remote_port), error_string(result)])
		return result
	multiplayer.multiplayer_peer = peer
	_connect_multiplayer_signals()
	_set_state(State.CONNECTING, "Connecting to %s…" % Protocol.format_endpoint(normalized, remote_port))
	return OK

func leave() -> void:
	_intentional_leave = true
	_disconnect_multiplayer_signals()
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
		multiplayer.multiplayer_peer = null
	roster.clear()
	_handshaken.clear()
	_pending_handshakes.clear()
	_last_frames.clear()
	_last_sequences.clear()
	_last_travel_requests.clear()
	_last_action_requests.clear()
	reset_player_lives()
	_loot_parts.clear()
	_loot_batch_revision = -1
	_rate_limiter.clear()
	_world_state.clear()
	_world_revision = 0
	_last_received_world_revision = -1
	_set_state(State.OFFLINE, "Offline")
	roster_changed.emit({})

func submit_local_snapshot(frame: Dictionary) -> void:
	if state != State.HOSTING and state != State.CONNECTED:
		return
	var local_id := multiplayer.get_unique_id()
	frame["peer"] = local_id
	frame["run"] = _run_id
	if not Protocol.is_valid_snapshot(frame):
		return
	if multiplayer.is_server():
		_correct_life_pose(local_id, frame)
		_last_frames[local_id] = frame.duplicate(true)
		_remote_snapshot.rpc(frame)
	else:
		_submit_snapshot.rpc_id(1, frame)

func submit_footstep(map_name: String, kind: int, surface: String, water: bool, season: int) -> void:
	if not is_online() or not Protocol.is_valid_footstep(map_name, kind, surface, water, season):
		return
	if multiplayer.is_server():
		_relay_footstep(1, map_name, kind, surface, water, season)
	else:
		_submit_footstep.rpc_id(1, map_name, kind, surface, water, season)

func _relay_footstep(peer_id: int, map_name: String, kind: int, surface: String, water: bool, season: int) -> void:
	if not multiplayer.is_server() or not roster.has(peer_id):
		return
	_receive_footstep.rpc(peer_id, map_name, kind, surface, water, season)
	if peer_id != multiplayer.get_unique_id():
		footstep_received.emit(peer_id, map_name, kind, surface, water, season)

func peer_count() -> int:
	return roster.size()

func publish_world_state(raw_state: Dictionary) -> void:
	if state != State.HOSTING or not multiplayer.is_server():
		return
	var next_state := Protocol.sanitize_world_state(raw_state)
	if not Protocol.is_valid_world_state(next_state):
		return
	if not _world_state.is_empty() and Protocol.world_state_digest(next_state) == Protocol.world_state_digest(_world_state):
		return
	_world_revision += 1
	next_state["revision"] = _world_revision
	_world_state = next_state.duplicate(true)
	_receive_world_state.rpc(_world_state)
	world_state_received.emit(_world_state.duplicate(true))

func request_travel(scene: String) -> void:
	var normalized := Protocol.sanitize_map(scene)
	if state != State.CONNECTED or not Protocol.is_valid_scene(normalized):
		return
	_request_travel.rpc_id(1, normalized)

func current_world_state() -> Dictionary:
	return _world_state.duplicate(true)

func latest_pose(peer_id: int) -> Dictionary:
	return Dictionary(_last_frames.get(peer_id, {})).duplicate(true)

func vote_traversal(exit_id: String, source: String) -> void:
	if not is_online():
		return
	if multiplayer.is_server():
		traversal_vote_requested.emit(1, exit_id, source)
	else:
		_submit_traversal_vote.rpc_id(1, exit_id, source)

func publish_traversal(value: Dictionary) -> void:
	if state == State.HOSTING:
		_receive_traversal.rpc(value)
		traversal_state_received.emit(value.duplicate(true))

func acknowledge_traversal(revision: int, ready: bool) -> void:
	if not is_online():
		return
	if multiplayer.is_server():
		traversal_ready_requested.emit(1, revision, ready)
	else:
		_submit_traversal_ready.rpc_id(1, revision, ready)

@rpc("any_peer", "call_remote", "reliable", 0)
func _submit_traversal_vote(exit_id: String, source: String) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if _allow_action(sender, "traversal_vote", 3.0) and exit_id.length() <= 256 and Protocol.is_valid_scene(source):
		traversal_vote_requested.emit(sender, exit_id, source)

@rpc("any_peer", "call_remote", "reliable", 0)
func _submit_traversal_ready(revision: int, ready: bool) -> void:
	if multiplayer.is_server() and _handshaken.has(multiplayer.get_remote_sender_id()):
		traversal_ready_requested.emit(multiplayer.get_remote_sender_id(), revision, ready)

@rpc("authority", "call_remote", "reliable", 0)
func _receive_traversal(value: Dictionary) -> void:
	if value.size() <= 8 and Protocol.is_valid_traversal_state(value):
		traversal_state_received.emit(value.duplicate(true))

func is_online() -> bool:
	return state == State.HOSTING or state == State.CONNECTED

func submit_player_state(raw_state: Dictionary) -> void:
	if not is_online():
		return
	var value := Protocol.sanitize_player_state(raw_state)
	if not Protocol.is_valid_player_state(value):
		return
	value["life_revision"] = int(_player_revisions.get(multiplayer.get_unique_id(), 0))
	value["run"] = _run_id
	if multiplayer.is_server():
		_accept_player_state(multiplayer.get_unique_id(), value)
	else:
		_submit_player_state.rpc_id(1, value)

func broadcast_player_state(peer_id: int, raw_state: Dictionary, advance_revision := true) -> void:
	if not multiplayer.is_server() or not roster.has(peer_id):
		return
	var value := Protocol.sanitize_player_state(raw_state)
	if not Protocol.is_valid_player_state(value):
		return
	if advance_revision:
		_player_revisions[peer_id] = int(_player_revisions.get(peer_id, 0)) + 1
	value["life_revision"] = int(_player_revisions.get(peer_id, 0))
	value["run"] = _run_id
	_player_states[peer_id] = value.duplicate(true)
	_receive_player_state.rpc(peer_id, value)
	player_state_received.emit(peer_id, value.duplicate(true))

func _accept_player_state(peer_id: int, value: Dictionary) -> void:
	var previous: Dictionary = _player_states.get(peer_id, {})
	if not previous.is_empty() and (int(value.get("life_revision", 0)) != int(_player_revisions.get(peer_id, 0)) or bool(previous.downed)):
		broadcast_player_state(peer_id, previous, false)
		return
	var newly_downed := bool(value.downed) and (previous.is_empty() or not bool(previous.downed))
	broadcast_player_state(peer_id, value, newly_downed)

func reset_player_lives(run_id := "") -> void:
	_run_id = run_id
	_player_states.clear()
	_player_revisions.clear()
	_last_frames.clear()

func authoritative_player_state(peer_id: int) -> Dictionary:
	return _player_states.get(peer_id, {}).duplicate(true)

func _correct_life_pose(peer_id: int, frame: Dictionary) -> void:
	var life: Dictionary = _player_states.get(peer_id, {})
	if life.is_empty():
		return
	frame["health"] = life.health
	frame["downed"] = life.downed
	if bool(life.downed):
		frame["map"] = life.map
		frame["position"] = life.position
		frame["velocity"] = Vector3.ZERO

func report_player_hit(target_peer: int, damage: float, penetration: int) -> void:
	if not is_online():
		return
	var bounded_damage := clampf(damage, 0.0, Protocol.MAX_DAMAGE)
	var bounded_penetration := clampi(penetration, 0, 1000)
	if multiplayer.is_server():
		player_hit_requested.emit(1, target_peer, bounded_damage, bounded_penetration)
	else:
		_request_player_hit.rpc_id(1, target_peer, bounded_damage, bounded_penetration)

func report_melee_hit(target_peer: int, damage: float) -> void:
	if not is_online():
		return
	var bounded_damage := clampf(damage, 0.0, 100.0)
	if multiplayer.is_server():
		melee_hit_requested.emit(1, target_peer, bounded_damage)
	else:
		_request_melee_hit.rpc_id(1, target_peer, bounded_damage)

func report_ai_hit(entity_id: String, hitbox: String, damage: float) -> void:
	if not is_online() or not Protocol.valid_entity_id(entity_id):
		return
	var bounded_damage := clampf(damage, 0.0, Protocol.MAX_DAMAGE)
	if multiplayer.is_server():
		ai_hit_requested.emit(1, entity_id, hitbox.left(24), bounded_damage)
	else:
		_request_ai_hit.rpc_id(1, entity_id, hitbox.left(24), bounded_damage)

func request_revive(target_peer: int, medical: String) -> void:
	if not is_online() or not ["AFAK", "IFAK", "Medkit", "Bandage", "Bandage_Improvised"].has(medical):
		return
	if multiplayer.is_server():
		revive_requested.emit(1, target_peer, medical)
	else:
		_request_revive.rpc_id(1, target_peer, medical)

func send_revive_result(peer_id: int, success: bool, medical: String, detail: String) -> void:
	if not multiplayer.is_server():
		return
	if peer_id == 1:
		revive_result.emit(success, medical, detail.left(120))
	else:
		_receive_revive_result.rpc_id(peer_id, success, medical, detail.left(120))

func publish_ai_state(map_name: String, revision: int, entities: Array) -> void:
	if not multiplayer.is_server() or not Protocol.is_valid_scene(map_name):
		return
	var bounded := entities.slice(0, Protocol.MAX_AI_ENTITIES)
	# Keep each datagram group small; inactive pooled NPCs are not transmitted.
	for offset in range(0, bounded.size(), 4):
		_receive_ai_state.rpc(map_name, maxi(0, revision), bounded.slice(offset, offset + 4))

func publish_ai_death(map_name: String, revision: int, entity: Dictionary) -> void:
	if multiplayer.is_server() and Protocol.is_valid_scene(map_name) and var_to_bytes(entity).size() <= 65536:
		_receive_ai_death.rpc(map_name, maxi(0, revision), entity)

func publish_loot_state(map_name: String, revision: int, entities: Array) -> void:
	if not multiplayer.is_server() or not Protocol.is_valid_scene(map_name):
		return
	# Never truncate a snapshot that receivers interpret as the complete floor.
	if entities.size() > 4096:
		push_warning("[RTVCoop8] Floor item limit reached; snapshot retained")
		return
	var count := maxi(1, ceili(entities.size() / 32.0))
	for part in count:
		_receive_loot_state.rpc(map_name, maxi(0, revision), entities.slice(part * 32, (part + 1) * 32), part, count)

func request_loot_pickup(entity_id: String) -> void:
	if not is_online() or not Protocol.valid_entity_id(entity_id):
		return
	if multiplayer.is_server():
		loot_pickup_requested.emit(1, entity_id)
	else:
		_request_loot_pickup.rpc_id(1, entity_id)

func send_loot_grant(peer_id: int, entity_id: String, slot: Dictionary) -> void:
	if not multiplayer.is_server() or not Protocol.valid_entity_id(entity_id):
		return
	if peer_id == 1:
		loot_grant_received.emit(entity_id, slot.duplicate(true))
	else:
		_receive_loot_grant.rpc_id(peer_id, entity_id, slot)

func report_loot_grant(entity_id: String, accepted: bool) -> void:
	if not is_online() or not Protocol.valid_entity_id(entity_id):
		return
	if multiplayer.is_server():
		loot_grant_result_requested.emit(1, entity_id, accepted)
	else:
		_report_loot_grant.rpc_id(1, entity_id, accepted)

func submit_loot_drop(token: String, map_name: String, slot: Dictionary, position: Vector3, rotation: Vector3) -> void:
	if is_online() and not multiplayer.is_server():
		_submit_loot_drop.rpc_id(1, token, map_name, slot, position, rotation)

func answer_loot_drop(peer_id: int, token: String, accepted: bool, entity_id := "") -> void:
	if multiplayer.is_server() and roster.has(peer_id):
		_answer_loot_drop.rpc_id(peer_id, token, accepted, entity_id)

@rpc("any_peer", "call_remote", "reliable", 0)
func _submit_loot_drop(token: String, map_name: String, slot: Dictionary, position: Vector3, rotation: Vector3) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if not _handshaken.has(sender) or not Protocol.valid_entity_id(token) or not Protocol.is_valid_scene(map_name) or not position.is_finite() or not rotation.is_finite():
		return
	if var_to_bytes(slot).size() <= 65536:
		loot_drop_requested.emit(sender, token, map_name, slot, position, rotation)

@rpc("authority", "call_remote", "reliable", 0)
func _answer_loot_drop(token: String, accepted: bool, entity_id: String) -> void:
	if Protocol.valid_entity_id(token) and (entity_id.is_empty() or Protocol.valid_entity_id(entity_id)):
		loot_drop_result.emit(token, accepted, entity_id)

func publish_container_state(entity_id: String, revision: int, slots: Array, properties := {}) -> void:
	if not multiplayer.is_server() or not Protocol.valid_entity_id(entity_id):
		return
	var safe_properties := {
		"storaged": bool(properties.get("storaged", false)),
		"holder": maxi(0, int(properties.get("holder", 0))),
		"visible": bool(properties.get("visible", true)),
		"locked": bool(properties.get("locked", false)),
		"active": bool(properties.get("active", true)),
	}
	_receive_container_state.rpc(entity_id, maxi(0, revision), slots.slice(0, 128), safe_properties)
	container_state_received.emit(entity_id, maxi(0, revision), slots.slice(0, 128), safe_properties)

func submit_container_state(entity_id: String, slots: Array) -> void:
	if not is_online() or not Protocol.valid_entity_id(entity_id):
		return
	if multiplayer.is_server():
		container_update_requested.emit(1, entity_id, slots.slice(0, 128))
	else:
		_request_container_state.rpc_id(1, entity_id, slots.slice(0, 128))

func request_container_open(entity_id: String) -> void:
	if not is_online() or not Protocol.valid_entity_id(entity_id):
		return
	if multiplayer.is_server():
		container_open_requested.emit(1, entity_id)
	else:
		_request_container_open.rpc_id(1, entity_id)

func cancel_container_open(entity_id: String) -> void:
	if is_online() and not multiplayer.is_server():
		_cancel_container_open.rpc_id(1, entity_id)

@rpc("any_peer", "call_remote", "reliable", 0)
func _cancel_container_open(entity_id: String) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if multiplayer.is_server() and _handshaken.has(sender) and Protocol.valid_entity_id(entity_id):
		container_open_cancelled.emit(sender, entity_id)

func answer_container_open(peer_id: int, entity_id: String, accepted: bool, detail := "") -> void:
	if not multiplayer.is_server() or not roster.has(peer_id) or not Protocol.valid_entity_id(entity_id):
		return
	if peer_id == 1:
		container_open_result.emit(entity_id, accepted, detail.left(100))
	else:
		_answer_container_open.rpc_id(peer_id, entity_id, accepted, detail.left(100))

func answer_container_update(peer_id: int, entity_id: String, accepted: bool) -> void:
	if not multiplayer.is_server() or not roster.has(peer_id) or not Protocol.valid_entity_id(entity_id):
		return
	if peer_id == 1:
		container_update_result.emit(entity_id, accepted)
	else:
		_answer_container_update.rpc_id(peer_id, entity_id, accepted)

func request_container_snapshot(entity_id: String) -> void:
	if is_online() and not multiplayer.is_server() and Protocol.valid_entity_id(entity_id):
		_request_container_snapshot.rpc_id(1, entity_id)

func publish_door_state(map_name: String, revision: int, doors: Array) -> void:
	if multiplayer.is_server() and Protocol.is_valid_scene(map_name) and doors.size() <= 512:
		_receive_door_state.rpc(map_name, maxi(0, revision), doors)
		door_state_received.emit(map_name, maxi(0, revision), doors.duplicate(true))

func request_door_interaction(entity_id: String, key: String) -> void:
	if not is_online() or not Protocol.valid_entity_id(entity_id):
		return
	var safe_key := key if key.is_empty() or Protocol.valid_weapon_key(key) else ""
	if multiplayer.is_server():
		door_interaction_requested.emit(1, entity_id, safe_key)
	else:
		_request_door_interaction.rpc_id(1, entity_id, safe_key)

func request_door_snapshot() -> void:
	if is_online() and not multiplayer.is_server():
		_request_door_snapshot.rpc_id(1)

func answer_door_interaction(peer_id: int, entity_id: String, accepted: bool, consume_key: bool) -> void:
	if not multiplayer.is_server() or not roster.has(peer_id):
		return
	if peer_id == 1:
		door_interaction_result.emit(entity_id, accepted, consume_key)
	else:
		_answer_door_interaction.rpc_id(peer_id, entity_id, accepted, consume_key)

func publish_game_over(reason: String) -> void:
	if not multiplayer.is_server() or state != State.HOSTING:
		return
	var safe_reason := reason.strip_edges().left(120)
	_receive_game_over.rpc(safe_reason)
	game_over_received.emit(safe_reason)

func publish_shared_world_state(map_name: String, revision: int, states: Array) -> void:
	if not multiplayer.is_server() or not Protocol.is_valid_scene(map_name) or states.size() > 512:
		return
	for state_value in states:
		if not state_value is Dictionary or not Protocol.valid_entity_id(state_value.get("id")) or typeof(state_value.get("active")) != TYPE_BOOL:
			return
	_receive_shared_world_state.rpc(map_name, maxi(0, revision), states)
	shared_world_state_received.emit(map_name, maxi(0, revision), states.duplicate(true))

func request_shared_interaction(entity_id: String, has_required_item: bool) -> void:
	if not is_online() or not Protocol.valid_entity_id(entity_id):
		return
	if multiplayer.is_server():
		shared_interaction_requested.emit(1, entity_id, has_required_item)
	else:
		_request_shared_interaction.rpc_id(1, entity_id, has_required_item)

func answer_shared_interaction(peer_id: int, entity_id: String, accepted: bool, consume_required_item: bool, detail := "") -> void:
	if not multiplayer.is_server() or not roster.has(peer_id) or not Protocol.valid_entity_id(entity_id):
		return
	if peer_id == 1:
		shared_interaction_result.emit(entity_id, accepted, consume_required_item, detail.left(100))
	else:
		_answer_shared_interaction.rpc_id(peer_id, entity_id, accepted, consume_required_item, detail.left(100))

func request_shared_snapshot() -> void:
	if is_online() and not multiplayer.is_server():
		_request_shared_snapshot.rpc_id(1)

func request_explosion(map_name: String, position: Vector3, size: float) -> void:
	if not is_online() or not Protocol.is_valid_scene(map_name) or not position.is_finite():
		return
	var bounded_size := clampf(size, 1.0, 25.0)
	if multiplayer.is_server():
		explosion_requested.emit(1, map_name, position, bounded_size)
	else:
		_request_explosion.rpc_id(1, map_name, position, bounded_size)

func publish_explosion(map_name: String, event_id: String, position: Vector3, size: float) -> void:
	if not multiplayer.is_server() or not Protocol.is_valid_scene(map_name) or not Protocol.valid_entity_id(event_id) or not position.is_finite():
		return
	var bounded_size := clampf(size, 1.0, 25.0)
	_receive_explosion.rpc(map_name, event_id, position, bounded_size)
	explosion_received.emit(map_name, event_id, position, bounded_size)

func _connect_multiplayer_signals() -> void:
	_disconnect_multiplayer_signals()
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)

func _disconnect_multiplayer_signals() -> void:
	for pair in [
		[multiplayer.peer_connected, _on_peer_connected],
		[multiplayer.peer_disconnected, _on_peer_disconnected],
		[multiplayer.connected_to_server, _on_connected_to_server],
		[multiplayer.connection_failed, _on_connection_failed],
		[multiplayer.server_disconnected, _on_server_disconnected],
	]:
		var bus: Signal = pair[0]
		var callback: Callable = pair[1]
		if bus.is_connected(callback):
			bus.disconnect(callback)

func _on_peer_connected(peer_id: int) -> void:
	if multiplayer.is_server():
		_pending_handshakes[peer_id] = Time.get_ticks_msec()
		_set_state(State.HOSTING, "Peer %d connected; negotiating…" % peer_id)

func _on_peer_disconnected(peer_id: int) -> void:
	roster.erase(peer_id)
	_handshaken.erase(peer_id)
	_pending_handshakes.erase(peer_id)
	_last_frames.erase(peer_id)
	_last_sequences.erase(peer_id)
	_rate_limiter.forget(peer_id)
	if compatibility != null:
		compatibility.forget_peer(peer_id)
	roster_changed.emit(roster.duplicate(true))
	if state != State.HOSTING:
		return
	if multiplayer.is_server():
		_set_state(State.HOSTING, "Hosting %d/%d" % [roster.size(), Protocol.MAX_PLAYERS])

func _on_connected_to_server() -> void:
	_set_state(State.CONNECTED, "Connected; negotiating protocol…")
	var manifest: Array = compatibility.local_manifest() if compatibility != null else []
	_server_hello.rpc_id(1, Protocol.PROTOCOL_VERSION, Protocol.MOD_VERSION, display_name, manifest)

func _on_connection_failed() -> void:
	leave()
	_set_state(State.ERROR, "Connection failed")

func _on_server_disconnected() -> void:
	if _intentional_leave or state == State.OFFLINE:
		return
	leave()
	_set_state(State.ERROR, "Host disconnected")

@rpc("any_peer", "call_remote", "reliable", 0)
func _server_hello(protocol: int, mod_version: String, player_name: String, raw_manifest: Array) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender <= 1 or protocol != Protocol.PROTOCOL_VERSION:
		_reject_peer.rpc_id(sender, "Protocol mismatch (host=%d, client=%d)" % [Protocol.PROTOCOL_VERSION, protocol])
		multiplayer.multiplayer_peer.disconnect_peer(sender)
		return
	var manifest := Protocol.bounded_manifest(raw_manifest)
	var entry := {
		"peer": sender,
		"name": Protocol.sanitize_player_name(player_name),
		"version": mod_version.left(40),
		"manifest": manifest,
	}
	roster[sender] = entry
	_handshaken[sender] = true
	_pending_handshakes.erase(sender)
	if compatibility != null:
		compatibility.remember_peer(sender, manifest)
	var report: Dictionary = compatibility.compatibility_report(sender) if compatibility != null else {"exact": true}
	_welcome.rpc_id(sender, Protocol.PROTOCOL_VERSION, roster, report, _world_state)
	_peer_joined.rpc(entry)
	roster_changed.emit(roster.duplicate(true))
	if not bool(report.get("exact", true)):
		compatibility_warning.emit(sender, report)
	_set_state(State.HOSTING, "Hosting %d/%d" % [roster.size(), Protocol.MAX_PLAYERS])

@rpc("authority", "call_remote", "reliable", 0)
func _welcome(protocol: int, server_roster: Dictionary, compatibility_report: Dictionary, server_world_state: Dictionary) -> void:
	if protocol != Protocol.PROTOCOL_VERSION:
		leave()
		_set_state(State.ERROR, "Host protocol changed during negotiation")
		return
	roster = server_roster.duplicate(true)
	var local_id := multiplayer.get_unique_id()
	roster[local_id] = _local_roster_entry(local_id)
	_set_state(State.CONNECTED, "Connected %d/%d" % [roster.size(), Protocol.MAX_PLAYERS])
	roster_changed.emit(roster.duplicate(true))
	# The Steam helper can become ready while the handshake is in flight.
	# Re-submit the current identity so the host never keeps the earlier fallback.
	_update_identity.rpc_id(1, display_name)
	if Protocol.is_valid_world_state(server_world_state):
		_world_state = server_world_state.duplicate(true)
		_last_received_world_revision = int(_world_state.revision)
		world_state_received.emit(_world_state.duplicate(true))
	if not bool(compatibility_report.get("exact", true)):
		compatibility_warning.emit(1, compatibility_report)

@rpc("authority", "call_remote", "reliable", 0)
func _reject_peer(reason: String) -> void:
	leave()
	_set_state(State.ERROR, "Host rejected connection: %s" % reason.left(160))

@rpc("authority", "call_remote", "reliable", 0)
func _peer_joined(entry: Dictionary) -> void:
	var peer_id := int(entry.get("peer", 0))
	if peer_id > 0:
		roster[peer_id] = entry.duplicate(true)
		roster_changed.emit(roster.duplicate(true))

@rpc("any_peer", "call_remote", "reliable", 0)
func _update_identity(player_name: String) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if not _handshaken.has(sender) or not roster.has(sender):
		return
	var entry: Dictionary = roster[sender].duplicate(true)
	entry["name"] = Protocol.sanitize_player_name(player_name)
	roster[sender] = entry
	_peer_identity_changed.rpc(entry)
	roster_changed.emit(roster.duplicate(true))

@rpc("authority", "call_remote", "reliable", 0)
func _peer_identity_changed(entry: Dictionary) -> void:
	var peer_id := int(entry.get("peer", 0))
	if peer_id <= 0 or not roster.has(peer_id):
		return
	var current: Dictionary = roster[peer_id].duplicate(true)
	current["name"] = Protocol.sanitize_player_name(String(entry.get("name", "")))
	roster[peer_id] = current
	roster_changed.emit(roster.duplicate(true))

@rpc("any_peer", "call_remote", "reliable", 0)
func _request_travel(scene: String) -> void:
	if not multiplayer.is_server() or not Protocol.is_valid_scene(scene):
		return
	var sender := multiplayer.get_remote_sender_id()
	if not _handshaken.has(sender):
		return
	var now := Time.get_ticks_msec()
	if now - int(_last_travel_requests.get(sender, 0)) < 1500:
		return
	_last_travel_requests[sender] = now
	travel_requested.emit(sender, Protocol.sanitize_map(scene))

@rpc("authority", "call_remote", "reliable", 0)
func _receive_world_state(server_state: Dictionary) -> void:
	if multiplayer.is_server() or not Protocol.is_valid_world_state(server_state):
		return
	var revision := int(server_state.revision)
	if revision <= _last_received_world_revision:
		return
	_last_received_world_revision = revision
	_world_state = server_state.duplicate(true)
	world_state_received.emit(_world_state.duplicate(true))

@rpc("any_peer", "call_remote", "unreliable_ordered", 1)
func _submit_snapshot(frame: Dictionary) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if not _handshaken.has(sender) or not _rate_limiter.allow(sender, Protocol.MAX_SNAPSHOT_RATE):
		return
	if int(frame.get("peer", 0)) != sender or not Protocol.is_valid_snapshot(frame):
		return
	if String(frame.get("run", "")) != _run_id:
		return
	var seq := int(frame.seq)
	if seq <= int(_last_sequences.get(sender, -1)):
		return
	var previous: Dictionary = _last_frames.get(sender, {})
	if not previous.is_empty() and String(previous.map) == String(frame.map):
		var elapsed := maxf(0.05, float(seq - int(previous.seq)) / Protocol.SNAPSHOT_HZ)
		var allowed_distance := Protocol.MAX_TELEPORT_DISTANCE + Protocol.MAX_PLAYER_SPEED * elapsed
		if Vector3(previous.position).distance_to(Vector3(frame.position)) > allowed_distance:
			return
	_last_sequences[sender] = seq
	_correct_life_pose(sender, frame)
	_last_frames[sender] = frame.duplicate(true)
	_remote_snapshot.rpc(frame)
	snapshot_received.emit(sender, frame)

@rpc("authority", "call_remote", "unreliable_ordered", 1)
func _remote_snapshot(frame: Dictionary) -> void:
	if not Protocol.is_valid_snapshot(frame):
		return
	if String(frame.get("run", "")) != _run_id:
		return
	var peer_id := int(frame.peer)
	if peer_id == multiplayer.get_unique_id():
		return
	_correct_life_pose(peer_id, frame)
	snapshot_received.emit(peer_id, frame)

@rpc("any_peer", "call_remote", "reliable", 0)
func _submit_player_state(raw_state: Dictionary) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if not _handshaken.has(sender):
		return
	var value := Protocol.sanitize_player_state(raw_state)
	if Protocol.is_valid_player_state(value):
		if String(value.get("run", "")) != _run_id:
			return
		_accept_player_state(sender, value)

@rpc("authority", "call_remote", "reliable", 0)
func _receive_player_state(peer_id: int, raw_state: Dictionary) -> void:
	var value := Protocol.sanitize_player_state(raw_state)
	if String(value.get("run", "")) != _run_id:
		return
	if roster.has(peer_id) and Protocol.is_valid_player_state(value):
		if int(value.get("life_revision", 0)) < int(_player_revisions.get(peer_id, 0)):
			return
		_player_revisions[peer_id] = int(value.get("life_revision", 0))
		_player_states[peer_id] = value.duplicate(true)
		player_state_received.emit(peer_id, value)

@rpc("any_peer", "call_remote", "reliable", 0)
func _request_player_hit(target_peer: int, damage: float, penetration: int) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if _allow_action(sender, "player_hit", 40.0) and roster.has(target_peer):
		player_hit_requested.emit(sender, target_peer, clampf(damage, 0.0, Protocol.MAX_DAMAGE), clampi(penetration, 0, 1000))

@rpc("any_peer", "call_remote", "reliable", 0)
func _request_melee_hit(target_peer: int, damage: float) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if _allow_action(sender, "melee_hit", 6.0) and roster.has(target_peer):
		melee_hit_requested.emit(sender, target_peer, clampf(damage, 0.0, 100.0))

@rpc("any_peer", "call_remote", "reliable", 0)
func _request_ai_hit(entity_id: String, hitbox: String, damage: float) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if _allow_action(sender, "ai_hit", 45.0) and Protocol.valid_entity_id(entity_id):
		ai_hit_requested.emit(sender, entity_id, hitbox.left(24), clampf(damage, 0.0, Protocol.MAX_DAMAGE))

@rpc("any_peer", "call_remote", "reliable", 0)
func _request_revive(target_peer: int, medical: String) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if _allow_action(sender, "revive", 2.0) and roster.has(target_peer) and ["AFAK", "IFAK", "Medkit", "Bandage", "Bandage_Improvised"].has(medical):
		revive_requested.emit(sender, target_peer, medical)

@rpc("authority", "call_remote", "reliable", 0)
func _receive_revive_result(success: bool, medical: String, detail: String) -> void:
	revive_result.emit(success, medical.left(20), detail.left(120))

@rpc("authority", "call_remote", "unreliable_ordered", 2)
func _receive_ai_state(map_name: String, revision: int, entities: Array) -> void:
	if Protocol.is_valid_scene(map_name) and entities.size() <= Protocol.MAX_AI_ENTITIES:
		ai_state_received.emit(map_name, maxi(0, revision), entities)

@rpc("authority", "call_remote", "reliable", 0)
func _receive_ai_death(map_name: String, revision: int, entity: Dictionary) -> void:
	if Protocol.is_valid_scene(map_name) and var_to_bytes(entity).size() <= 65536:
		ai_state_received.emit(map_name, maxi(0, revision), [entity])

@rpc("authority", "call_remote", "unreliable_ordered", 2)
func _receive_loot_state(map_name: String, revision: int, entities: Array, part := 0, count := 1) -> void:
	if not Protocol.is_valid_scene(map_name) or entities.size() > 32 or count < 1 or count > 128 or part < 0 or part >= count:
		return
	if revision < _loot_batch_revision:
		return
	if revision > _loot_batch_revision or map_name != _loot_batch_map:
		_loot_parts.clear()
		_loot_batch_revision = revision
		_loot_batch_map = map_name
	_loot_parts[part] = entities
	if _loot_parts.size() != count:
		return
	var complete: Array = []
	for index in count:
		if not _loot_parts.has(index):
			return
		complete.append_array(_loot_parts[index])
	loot_state_received.emit(map_name, revision, complete)

@rpc("any_peer", "call_remote", "reliable", 0)
func _request_loot_pickup(entity_id: String) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if _allow_action(sender, "loot", 8.0) and Protocol.valid_entity_id(entity_id):
		loot_pickup_requested.emit(sender, entity_id)

@rpc("authority", "call_remote", "reliable", 0)
func _receive_loot_grant(entity_id: String, slot: Dictionary) -> void:
	if Protocol.valid_entity_id(entity_id):
		loot_grant_received.emit(entity_id, slot)

@rpc("any_peer", "call_remote", "reliable", 0)
func _report_loot_grant(entity_id: String, accepted: bool) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if _allow_action(sender, "loot_result", 8.0) and Protocol.valid_entity_id(entity_id):
		loot_grant_result_requested.emit(sender, entity_id, accepted)

@rpc("authority", "call_remote", "reliable", 0)
func _receive_container_state(entity_id: String, revision: int, slots: Array, properties: Dictionary) -> void:
	if Protocol.valid_entity_id(entity_id) and slots.size() <= 128:
		container_state_received.emit(entity_id, maxi(0, revision), slots, properties)

@rpc("any_peer", "call_remote", "reliable", 0)
func _request_container_state(entity_id: String, slots: Array) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if _allow_action(sender, "container", 4.0) and Protocol.valid_entity_id(entity_id) and slots.size() <= 128:
		container_update_requested.emit(sender, entity_id, slots)

@rpc("any_peer", "call_remote", "reliable", 0)
func _request_container_open(entity_id: String) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if _allow_action(sender, "container_open", 4.0) and Protocol.valid_entity_id(entity_id):
		container_open_requested.emit(sender, entity_id)
	elif Protocol.valid_entity_id(entity_id):
		answer_container_open(sender, entity_id, false, "Please wait a moment, then try again")

@rpc("authority", "call_remote", "reliable", 0)
func _answer_container_open(entity_id: String, accepted: bool, detail: String) -> void:
	if Protocol.valid_entity_id(entity_id):
		container_open_result.emit(entity_id, accepted, detail.left(100))

@rpc("authority", "call_remote", "reliable", 0)
func _answer_container_update(entity_id: String, accepted: bool) -> void:
	if Protocol.valid_entity_id(entity_id):
		container_update_result.emit(entity_id, accepted)

@rpc("any_peer", "call_remote", "reliable", 0)
func _request_container_snapshot(entity_id: String) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if Protocol.valid_entity_id(entity_id) and _allow_action(sender, "container_snapshot:" + entity_id, 1.0):
		container_snapshot_requested.emit(sender, entity_id)

@rpc("authority", "call_remote", "reliable", 0)
func _receive_door_state(map_name: String, revision: int, doors: Array) -> void:
	if Protocol.is_valid_scene(map_name) and doors.size() <= 512:
		door_state_received.emit(map_name, maxi(0, revision), doors.duplicate(true))

@rpc("any_peer", "call_remote", "reliable", 0)
func _request_door_interaction(entity_id: String, key: String) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if _allow_action(sender, "door", 5.0) and Protocol.valid_entity_id(entity_id) and (key.is_empty() or Protocol.valid_weapon_key(key)):
		door_interaction_requested.emit(sender, entity_id, key)

@rpc("any_peer", "call_remote", "reliable", 0)
func _request_door_snapshot() -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if _allow_action(sender, "door_snapshot", 2.0):
		door_snapshot_requested.emit(sender)

@rpc("authority", "call_remote", "reliable", 0)
func _answer_door_interaction(entity_id: String, accepted: bool, consume_key: bool) -> void:
	if Protocol.valid_entity_id(entity_id):
		door_interaction_result.emit(entity_id, accepted, consume_key)

@rpc("authority", "call_remote", "reliable", 0)
func _receive_game_over(reason: String) -> void:
	game_over_received.emit(reason.left(120))

@rpc("authority", "call_remote", "reliable", 0)
func _receive_shared_world_state(map_name: String, revision: int, states: Array) -> void:
	if not Protocol.is_valid_scene(map_name) or states.size() > 512:
		return
	for state_value in states:
		if not state_value is Dictionary or not Protocol.valid_entity_id(state_value.get("id")) or typeof(state_value.get("active")) != TYPE_BOOL:
			return
	shared_world_state_received.emit(map_name, maxi(0, revision), states.duplicate(true))

@rpc("any_peer", "call_remote", "reliable", 0)
func _request_shared_interaction(entity_id: String, has_required_item: bool) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if Protocol.valid_entity_id(entity_id) and _allow_action(sender, "shared_interaction", 5.0):
		shared_interaction_requested.emit(sender, entity_id, has_required_item)

@rpc("authority", "call_remote", "reliable", 0)
func _answer_shared_interaction(entity_id: String, accepted: bool, consume_required_item: bool, detail: String) -> void:
	if Protocol.valid_entity_id(entity_id):
		shared_interaction_result.emit(entity_id, accepted, consume_required_item, detail.left(100))

@rpc("any_peer", "call_remote", "reliable", 0)
func _request_shared_snapshot() -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if _allow_action(sender, "shared_snapshot", 2.0):
		shared_snapshot_requested.emit(sender)

@rpc("any_peer", "call_remote", "reliable", 0)
func _request_explosion(map_name: String, position: Vector3, size: float) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if Protocol.is_valid_scene(map_name) and position.is_finite() and is_finite(size) and _allow_action(sender, "explosion", 3.0):
		explosion_requested.emit(sender, map_name, position, clampf(size, 1.0, 25.0))

@rpc("authority", "call_remote", "reliable", 0)
func _receive_explosion(map_name: String, event_id: String, position: Vector3, size: float) -> void:
	if Protocol.is_valid_scene(map_name) and Protocol.valid_entity_id(event_id) and position.is_finite() and is_finite(size) and size >= 1.0 and size <= 25.0:
		explosion_received.emit(map_name, event_id, position, size)

@rpc("any_peer", "call_remote", "reliable", 2)
func _submit_footstep(map_name: String, kind: int, surface: String, water: bool, season: int) -> void:
	if not multiplayer.is_server() or not Protocol.is_valid_footstep(map_name, kind, surface, water, season):
		return
	var sender := multiplayer.get_remote_sender_id()
	var pose: Dictionary = _last_frames.get(sender, {})
	if (not pose.is_empty() and (String(pose.get("map", "")) != map_name or bool(pose.get("downed", false)))) or not _allow_action(sender, "footstep", 12.0):
		return
	_relay_footstep(sender, map_name, kind, surface, water, season)

@rpc("authority", "call_remote", "reliable", 2)
func _receive_footstep(peer_id: int, map_name: String, kind: int, surface: String, water: bool, season: int) -> void:
	if multiplayer.is_server() or peer_id == multiplayer.get_unique_id() or not roster.has(peer_id):
		return
	if Protocol.is_valid_footstep(map_name, kind, surface, water, season):
		footstep_received.emit(peer_id, map_name, kind, surface, water, season)

func _allow_action(peer_id: int, action: String, per_second: float) -> bool:
	if not _handshaken.has(peer_id):
		return false
	var key := "%d:%s" % [peer_id, action]
	var now := Time.get_ticks_msec()
	var minimum_gap := int(1000.0 / maxf(0.1, per_second))
	if _last_action_requests.has(key) and now - int(_last_action_requests[key]) < minimum_gap:
		return false
	_last_action_requests[key] = now
	return true

func _local_roster_entry(peer_id: int) -> Dictionary:
	return {
		"peer": peer_id,
		"name": display_name,
		"version": Protocol.MOD_VERSION,
		"manifest": compatibility.local_manifest() if compatibility != null else [],
	}

func _set_state(new_state: int, detail: String) -> void:
	state = new_state
	state_changed.emit(state, detail)
	print("[RTVCoop8] %s" % detail)
