extends Node

const Protocol = preload("res://RTVCoop8/core/CoopProtocol.gd")
const SlotCodec = preload("res://RTVCoop8/gameplay/SlotCodec.gd")
const BonePose = preload("res://RTVCoop8/presentation/BonePose.gd")
const MedicalRules = preload("res://RTVCoop8/core/MedicalRules.gd")
const RevivePanel = preload("res://RTVCoop8/ui/RevivePanel.gd")
const COOP_COLLISION_LAYER := 1 << 30
const SHARED_WORLD_SCRIPTS := {
	"res://Scripts/Fire.gd": "fire",
	"res://Scripts/Switch.gd": "switch",
	"res://Scripts/Radio.gd": "radio",
	"res://Scripts/Television.gd": "television",
}

var _session: Node
var _owner_api: Node
var _library: Variant
var _game_data: Resource
var _player_states: Dictionary = {}
var _ai_index: Dictionary = {}
var _ai_targets: Dictionary = {}
var _ai_revision := 0
var _ai_accumulator := 0.0
var _loot_nodes: Dictionary = {}
var _client_loot_nodes: Dictionary = {}
var _loot_revision := 0
var _loot_accumulator := 0.0
var _loot_serial := 0
var _loot_reservations: Dictionary = {}
var _containers: Dictionary = {}
var _container_revisions: Dictionary = {}
var _container_digests: Dictionary = {}
var _pending_medical := ""
var _loot_scanned := false
var _revive_panel: CanvasLayer
var _revive_target := 0
var _medical_item: Node
var _revive_was_frozen := false
var _grant_results: Dictionary = {}
var _last_loot_revision := -1
var _drop_active := false
var _drop_expected: Array[Dictionary] = []
var _drop_serial := 0
var _drop_seen: Dictionary = {}
var _pending_drops: Dictionary = {}
var _medical_refund: Dictionary = {}
var _pending_container_states: Dictionary = {}
var _ai_death_started: Dictionary = {}
var _ai_death_pose_phase: Dictionary = {}
var _doors: Dictionary = {}
var _pending_door_states: Dictionary = {}
var _pending_door_keys: Dictionary = {}
var _door_revision := 0
var _door_digest := ""
var _game_over_sent := false
var _door_snapshot_requested := false
var _container_leases: Dictionary = {}
var _pending_container_opens: Dictionary = {}
var _pending_container_commits: Dictionary = {}
var _client_open_container := ""
var _shared_nodes: Dictionary = {}
var _pending_shared_states: Dictionary = {}
var _shared_revision := 0
var _shared_digest := ""
var _shared_snapshot_requested := false
var _explosion_serial := 0
var _explosion_seen: Dictionary = {}
var _recent_explosions: Array[Dictionary] = []

func configure(session: Node, owner_api: Node) -> void:
	_session = session
	_owner_api = owner_api
	_game_data = load("res://Resources/GameData.tres")
	_session.player_state_received.connect(_on_player_state_received)
	_session.player_hit_requested.connect(_on_player_hit_requested)
	_session.melee_hit_requested.connect(_on_melee_hit_requested)
	_session.ai_hit_requested.connect(_on_ai_hit_requested)
	_session.revive_requested.connect(_on_revive_requested)
	_session.revive_result.connect(_on_revive_result)
	_session.ai_state_received.connect(_on_ai_state_received)
	_session.loot_state_received.connect(_on_loot_state_received)
	_session.loot_pickup_requested.connect(_on_loot_pickup_requested)
	_session.loot_grant_received.connect(_on_loot_grant_received)
	_session.loot_grant_result_requested.connect(_on_loot_grant_result_requested)
	_session.container_state_received.connect(_on_container_state_received)
	_session.container_update_requested.connect(_on_container_update_requested)
	_session.container_snapshot_requested.connect(_on_container_snapshot_requested)
	_session.container_open_requested.connect(_on_container_open_requested)
	_session.container_open_cancelled.connect(_on_container_open_cancelled)
	_session.container_open_result.connect(_on_container_open_result)
	_session.container_update_result.connect(_on_container_update_result)
	_session.loot_drop_requested.connect(_on_loot_drop_requested)
	_session.loot_drop_result.connect(_on_loot_drop_result)
	_session.door_state_received.connect(_on_door_state_received)
	_session.door_interaction_requested.connect(_on_door_interaction_requested)
	_session.door_interaction_result.connect(_on_door_interaction_result)
	_session.door_snapshot_requested.connect(_on_door_snapshot_requested)
	_session.shared_world_state_received.connect(_on_shared_world_state_received)
	_session.shared_interaction_requested.connect(_on_shared_interaction_requested)
	_session.shared_interaction_result.connect(_on_shared_interaction_result)
	_session.shared_snapshot_requested.connect(_on_shared_snapshot_requested)
	_session.explosion_requested.connect(_on_explosion_requested)
	_session.explosion_received.connect(_on_explosion_received)
	_revive_panel = RevivePanel.new()
	add_child(_revive_panel)
	_revive_panel.selected.connect(_select_revive_item)
	_revive_panel.closed.connect(_close_revive)

func register_hooks(library: Variant) -> void:
	_library = library
	var hooks := [
		["ai-_ready-post", _on_ai_ready_post],
		["ai-_physics_process", _on_ai_physics],
		["ai-parameters-post", _on_ai_parameters_post],
		["ai-weapondamage", _on_ai_weapon_damage],
		["ai-playfire-post", _on_ai_fire_post],
		["aispawner-_physics_process", _on_ai_spawner_physics],
		["aispawner-spawnwanderer", _on_ai_spawn_gate],
		["aispawner-spawnguard", _on_ai_spawn_gate],
		["aispawner-spawnhider", _on_ai_spawn_gate],
		["aispawner-spawnminion", _on_ai_spawn_gate_position],
		["aispawner-spawnboss", _on_ai_spawn_gate_position],
		["weaponrig-_ready-post", _on_weapon_ready_post],
		["weaponrig-raycast-post", _on_weapon_raycast_post],
		["interactor-_physics_process", _on_interactor_physics],
		["character-death", _on_character_death],
		["lootsimulation-_ready", _on_loot_simulation_ready],
		["pickup-_ready-post", _on_pickup_ready_post],
		["pickup-interact", _on_pickup_interact],
		["interface-drop", _on_drop],
		["interface-drop-post", _on_drop_post],
		["lootcontainer-_ready", _on_container_ready],
		["lootcontainer-_ready-post", _on_container_ready_post],
		["lootcontainer-interact", _on_container_interact],
		["lootcontainer-updatetooltip-post", _on_container_tooltip],
		["lootcontainer-storage", _on_container_storage],
		["lootcontainer-storage-post", _on_container_storage_post],
		["door-_ready", _on_door_ready],
		["door-_ready-post", _on_door_ready_post],
		["door-interact", _on_door_interact],
		["door-interact-post", _on_door_interact_post],
		["fire-interact", _on_shared_interact],
		["fire-interact-post", _on_shared_interact_post],
		["switch-interact", _on_shared_interact],
		["switch-interact-post", _on_shared_interact_post],
		["radio-interact", _on_shared_interact],
		["radio-interact-post", _on_shared_interact_post],
		["television-interact", _on_shared_interact],
		["television-interact-post", _on_shared_interact_post],
		["explosion-explode", _on_explosion_explode],
		["explosion-checkoverlap", _on_explosion_check_overlap],
		["explosion-checkalert", _on_explosion_check_alert],
		["kniferig-_ready-post", _on_knife_ready_post],
		["kniferig-hitcheck-post", _on_knife_hit_check_post],
	]
	for hook in hooks:
		if int(_library.hook(hook[0], hook[1], 120)) < 0:
			push_warning("[RTVCoop8] Gameplay hook unavailable: %s" % hook[0])

func _process(delta: float) -> void:
	if _session == null or not _session.is_online() or bool(_owner_api.call("scene_is_loading")):
		return
	_expire_container_opens()
	if _session.multiplayer.is_server():
		_expire_loot_reservations()
		_ai_accumulator += delta
		if _ai_accumulator >= 1.0 / Protocol.AI_STATE_HZ:
			_ai_accumulator = fmod(_ai_accumulator, 1.0 / Protocol.AI_STATE_HZ)
			_publish_ai_state()
		_loot_accumulator += delta
		if _loot_accumulator >= 1.0 / Protocol.LOOT_STATE_HZ:
			_loot_accumulator = fmod(_loot_accumulator, 1.0 / Protocol.LOOT_STATE_HZ)
			_publish_loot_state()
			_publish_door_state()
	else:
		_interpolate_client_ai(delta)

func reset_scene() -> void:
	if _revive_panel != null:
		_revive_panel.close()
	_last_loot_revision = -1
	_loot_scanned = false
	_pending_medical = ""
	_ai_index.clear()
	_ai_targets.clear()
	_loot_nodes.clear()
	_loot_reservations.clear()
	_client_loot_nodes.clear()
	_containers.clear()
	_container_revisions.clear()
	_container_digests.clear()
	_pending_container_states.clear()
	_container_leases.clear()
	_pending_container_opens.clear()
	_pending_container_commits.clear()
	_client_open_container = ""
	_ai_death_started.clear()
	_ai_death_pose_phase.clear()
	_doors.clear()
	_pending_door_states.clear()
	_pending_door_keys.clear()
	_door_revision = 0
	_door_digest = ""
	_door_snapshot_requested = false
	_shared_nodes.clear()
	_pending_shared_states.clear()
	_shared_revision = 0
	_shared_digest = ""
	_shared_snapshot_requested = false
	_explosion_seen.clear()
	_recent_explosions.clear()

func note_player_pose(peer_id: int, frame: Dictionary) -> void:
	var authority: Dictionary = _session.authoritative_player_state(peer_id)
	var state := {
		"health": clampf(float(frame.get("health", 100.0)), 0.0, 100.0),
		"downed": bool(frame.get("downed", false)),
		"map": String(frame.get("map", "")),
		"position": Vector3(frame.get("position", Vector3.ZERO)),
	}
	if not authority.is_empty():
		state.health = authority.health
		state.downed = authority.downed
		if bool(authority.downed):
			state.map = authority.map
			state.position = authority.position
	if Protocol.is_valid_player_state(state):
		_player_states[peer_id] = state

func submit_local_state(position: Vector3, map_name: String) -> void:
	if _game_data == null or not Protocol.is_valid_scene(map_name):
		return
	var local_id := _session.multiplayer.get_unique_id()
	var body: Dictionary = _owner_api.get("_local_body")
	if bool(_owner_api.get("_local_downed")) and not body.is_empty():
		position = Vector3(body.position)
		map_name = String(body.map)
	var state := {
		"health": clampf(float(_game_data.get("health")), 0.0, 100.0),
		"downed": bool(_owner_api.get("_local_downed")),
		"map": map_name,
		"position": position,
	}
	_player_states[local_id] = state
	_session.submit_player_state(state)

func report_remote_player_hit(peer_id: int, damage: float, penetration: int) -> void:
	_session.report_player_hit(peer_id, damage, penetration)

func request_remote_revive(peer_id: int) -> void:
	if _pending_medical != "":
		return
	_revive_target = peer_id
	_revive_was_frozen = bool(_game_data.get("freeze"))
	_game_data.set("freeze", true)
	_revive_panel.open(_peer_name(peer_id), _medical_options())

func _select_revive_item(item: Node) -> void:
	if not is_instance_valid(item) or item.is_queued_for_deletion() or _pending_medical != "":
		return
	var slot: Variant = item.get("slotData")
	var kind := String(slot.get("itemData").get("file"))
	if MedicalRules.revive_health(kind) <= 0.0:
		return
	_medical_item = item
	_pending_medical = kind
	_medical_refund = SlotCodec.encode(slot)
	_medical_refund["amount"] = 1
	_consume_medical_item(kind)
	# Keep gameplay frozen until the reliable reply so the selected slot cannot
	# be moved, consumed or dropped while the host validates the revive.
	_revive_panel.hide()
	_session.request_revive(_revive_target, kind)

func _close_revive() -> void:
	if _game_data != null:
		_game_data.set("freeze", _revive_was_frozen or bool(_owner_api.get("_local_downed")))

func _on_player_state_received(peer_id: int, state: Dictionary) -> void:
	_player_states[peer_id] = state.duplicate(true)
	if peer_id == _session.multiplayer.get_unique_id():
		_owner_api.call("apply_authoritative_player_state", state)
	else:
		_owner_api.call("apply_remote_player_state", peer_id, state)
	_owner_api.call("refresh_travel_members")
	_check_all_players_downed()

func reset_run(run_id := "") -> void:
	_player_states.clear()
	_grant_results.clear()
	_drop_seen.clear()
	_game_over_sent = false
	_session.reset_player_lives(run_id)

func on_roster_changed() -> void:
	if _session == null or not _session.multiplayer.is_server():
		return
	_publish_door_state(true)
	_publish_shared_world(true)
	for entity_id in _container_leases.keys():
		if not _session.roster.has(int(_container_leases[entity_id])):
			_container_leases.erase(entity_id)
			var container := _cached_node(_containers, entity_id)
			if container != null:
				_publish_container(container, true)
	_check_all_players_downed()

func scene_ready() -> void:
	if _session == null:
		return
	_scan_shared_world()
	if _session.multiplayer.is_server():
		_publish_shared_world(true)
		return
	for raw_entity_id in _pending_door_states.keys():
		var entity_id := String(raw_entity_id)
		var door := _cached_node(_doors, entity_id)
		if door != null:
			_apply_door_state(door, _pending_door_states[entity_id])
			_pending_door_states.erase(entity_id)
	for raw_entity_id in _pending_shared_states.keys():
		var entity_id := String(raw_entity_id)
		var shared := _cached_node(_shared_nodes, entity_id)
		if shared != null:
			_apply_shared_state(shared, _pending_shared_states[entity_id], false)
			shared.set_meta("coop_shared_seen", true)
			_pending_shared_states.erase(entity_id)
	if not _shared_snapshot_requested:
		_shared_snapshot_requested = true
		_session.request_shared_snapshot()

func _on_player_hit_requested(source_peer: int, target_peer: int, damage: float, _penetration: int) -> void:
	if not _session.multiplayer.is_server() or source_peer == target_peer:
		return
	var source: Dictionary = _player_states.get(source_peer, {})
	var target: Dictionary = _player_states.get(target_peer, {})
	if source.is_empty() or target.is_empty() or bool(source.downed):
		return
	if String(source.map) != String(target.map):
		return
	if Vector3(source.position).distance_to(Vector3(target.position)) > Protocol.MAX_COMBAT_DISTANCE:
		return
	var next := target.duplicate(true)
	next.health = maxf(0.0, float(next.health) - randf_range(damage * 0.25, damage * 0.5))
	next.downed = float(next.health) <= 0.0
	_player_states[target_peer] = next
	_session.broadcast_player_state(target_peer, next)
	_check_all_players_downed()

func _on_melee_hit_requested(source_peer: int, target_peer: int, damage: float) -> void:
	if not _session.multiplayer.is_server() or source_peer == target_peer:
		return
	var source: Dictionary = _player_states.get(source_peer, {})
	var target: Dictionary = _player_states.get(target_peer, {})
	if source.is_empty() or target.is_empty() or bool(source.get("downed", false)) or bool(target.get("downed", false)):
		return
	if String(source.get("map", "")) != String(target.get("map", "")):
		return
	if Vector3(source.position).distance_to(Vector3(target.position)) > Protocol.MELEE_DISTANCE:
		return
	var next := target.duplicate(true)
	next.health = maxf(0.0, float(next.health) - clampf(damage, 0.0, Protocol.MELEE_DAMAGE))
	next.downed = float(next.health) <= 0.0
	_player_states[target_peer] = next
	_session.broadcast_player_state(target_peer, next)
	_check_all_players_downed()

func _on_revive_requested(source_peer: int, target_peer: int, medical: String) -> void:
	if not _session.multiplayer.is_server():
		return
	var source: Dictionary = _player_states.get(source_peer, {})
	var target: Dictionary = _player_states.get(target_peer, {})
	if source.is_empty() or target.is_empty() or not bool(target.downed):
		_session.send_revive_result(source_peer, false, medical, "Target is not downed")
		return
	if bool(source.downed) or String(source.map) != String(target.map) or Vector3(source.position).distance_to(Vector3(target.position)) > Protocol.REVIVE_DISTANCE:
		_session.send_revive_result(source_peer, false, medical, "Move closer to the downed player")
		return
	var next := target.duplicate(true)
	if MedicalRules.revive_health(medical) <= 0.0:
		return
	next.health = MedicalRules.revive_health(medical)
	next.downed = false
	_player_states[target_peer] = next
	_session.broadcast_player_state(target_peer, next)
	_session.send_revive_result(source_peer, true, medical, "%s revived" % _peer_name(target_peer))

func _on_revive_result(success: bool, medical: String, detail: String) -> void:
	if _pending_medical != medical:
		return
	if not success and not _medical_refund.is_empty():
		var interface := get_node_or_null("/root/Map/Core/UI/Interface")
		var slot: Variant = SlotCodec.decode(_medical_refund)
		if interface != null and slot != null:
			var grid: Node = interface.get("inventoryGrid")
			if _stack_whole(slot, grid) or bool(interface.call("Create", slot, grid, false)):
				interface.call("UpdateStats", false)
				_medical_refund.clear()
	else:
		_medical_refund.clear()
	_owner_api.call("show_gameplay_status", detail, not success)
	_pending_medical = ""
	_medical_item = null
	_revive_panel.show()
	_revive_panel.close()

func _on_character_death() -> void:
	if _session == null or not _session.is_online():
		return
	_library.skip_super()
	_owner_api.call("enter_local_downed_state")

func _on_ai_ready_post() -> void:
	var ai := _library._caller as Node3D
	if ai == null:
		return
	_register_ai(ai)
	for field in ["fire", "LOS"]:
		var ray := ai.get(field) as RayCast3D
		if ray != null:
			ray.collision_mask |= COOP_COLLISION_LAYER

func _on_ai_physics(_delta: float) -> void:
	if _session != null and _session.is_online() and bool(_owner_api.call("scene_is_loading")):
		_library.skip_super()
		return
	if _session == null or not _session.is_online() or _session.multiplayer.is_server():
		return
	_library.skip_super()

func _on_ai_parameters_post(_delta: float) -> void:
	if _session == null or not _session.is_online() or not _session.multiplayer.is_server():
		return
	var ai := _library._caller as Node3D
	if ai == null:
		return
	var target: Dictionary = _nearest_live_player(ai.global_position)
	if target.is_empty():
		return
	var target_position: Vector3 = Vector3(target.position)
	ai.set("playerPosition", target_position)
	ai.set("playerDistance3D", ai.global_position.distance_to(target_position))
	ai.set("playerDistance2D", Vector2(ai.global_position.x, ai.global_position.z).distance_to(Vector2(target_position.x, target_position.z)))
	_ai_targets[ai] = int(target.peer)
	var los := ai.get("LOS") as RayCast3D
	if los != null:
		los.look_at(target_position + Vector3.UP * 1.5, Vector3.UP, true)
		los.force_raycast_update()
		var collider: Variant = los.get_collider()
		if collider != null and collider.has_meta("coop_peer_id") and int(collider.get_meta("coop_peer_id")) == int(target.peer):
			ai.set("playerVisible", true)
			ai.set("lastKnownLocation", target_position)

func _on_ai_weapon_damage(hitbox: String, damage: float) -> void:
	if _session == null or not _session.is_online() or _session.multiplayer.is_server():
		return
	_library.skip_super()
	var ai := _library._caller as Node3D
	if ai == null:
		return
	_register_ai(ai)
	var entity_id := String(ai.get_meta("coop_ai_id", ""))
	if not entity_id.is_empty():
		_session.report_ai_hit(entity_id, hitbox, damage)

func _on_ai_fire_post() -> void:
	if _session == null or not _session.is_online() or not _session.multiplayer.is_server():
		return
	var ai := _library._caller as Node3D
	if ai != null:
		ai.set_meta("coop_shots", int(ai.get_meta("coop_shots", 0)) + 1)

func _on_ai_hit_requested(source_peer: int, entity_id: String, hitbox: String, damage: float) -> void:
	if not _session.multiplayer.is_server():
		return
	_refresh_ai_index()
	var ai := _cached_node(_ai_index, entity_id)
	var source: Dictionary = _player_states.get(source_peer, {})
	if ai == null or source.is_empty() or bool(source.downed):
		return
	if String(source.map) != _current_map() or Vector3(source.position).distance_to(ai.global_position) > Protocol.MAX_COMBAT_DISTANCE:
		return
	if ai.has_method("WeaponDamage"):
		ai.call("WeaponDamage", hitbox, damage)

func _on_ai_spawner_physics(_delta: float) -> void:
	if _is_online_client():
		_library.skip_super()

func _on_ai_spawn_gate() -> void:
	if _is_online_client():
		_library.skip_super()

func _on_ai_spawn_gate_position(_position: Variant) -> void:
	if _is_online_client():
		_library.skip_super()

func _publish_ai_state() -> void:
	var map_name := _current_map()
	if not Protocol.is_valid_scene(map_name):
		return
	_refresh_ai_index()
	var entities: Array[Dictionary] = []
	for entity_id in _ai_index:
		var ai := _cached_node(_ai_index, entity_id)
		if ai == null or not is_instance_valid(ai):
			continue
		var parent_name := String(ai.get_parent().name) if ai.get_parent() != null else ""
		if parent_name != "Agents":
			continue
		var weapon: Variant = ai.get("weapon")
		var weapon_slot: Variant = weapon.get("slotData") if weapon != null else null
		var weapon_data: Variant = weapon_slot.get("itemData") if weapon_slot != null else null
		var attachment_keys: Array[String] = []
		if weapon_slot != null:
			for attachment in weapon_slot.get("nested"):
				var attachment_key := String(attachment.get("file"))
				if Protocol.valid_weapon_key(attachment_key):
					attachment_keys.append(attachment_key)
		var entity := {
			"id": entity_id,
			"active": parent_name == "Agents",
			"position": ai.global_position,
			"yaw": ai.global_rotation.y,
			"velocity": ai.get("velocity") if ai is CharacterBody3D else Vector3.ZERO,
			"health": clampf(float(ai.get("health")), -1000.0, 1000.0),
			"dead": bool(ai.get("dead")),
			"state": clampi(int(ai.get("currentState")), 0, 32),
			"bones": BonePose.capture(ai.get("skeleton") as Skeleton3D),
			"weapon": String(weapon_data.get("file")) if weapon_data != null else "",
			"weapon_transform": weapon.transform if weapon is Node3D else Transform3D.IDENTITY,
			"attachments": attachment_keys,
			"shots": int(ai.get_meta("coop_shots", 0)),
		}
		entities.append(entity)
		if bool(entity.dead):
			var now := Time.get_ticks_msec()
			if not _ai_death_started.has(entity_id):
				_ai_death_started[entity_id] = now
			var phase := death_pose_phase(now - int(_ai_death_started[entity_id]))
			if phase > int(_ai_death_pose_phase.get(entity_id, -1)):
				_ai_death_pose_phase[entity_id] = phase
				# Ragdolls keep moving for ten seconds in the base game. Send a
				# handful of reliable poses across that window so packet loss cannot
				# leave a client with only the first upright death frame.
				_session.publish_ai_death(map_name, _ai_revision + 1, entity)
	_ai_revision += 1
	_session.publish_ai_state(map_name, _ai_revision, entities)

func _on_ai_state_received(map_name: String, _revision: int, entities: Array) -> void:
	if map_name != _current_map() or _session.multiplayer.is_server():
		return
	_refresh_ai_index()
	for raw in entities:
		if not raw is Dictionary:
			continue
		var state: Dictionary = raw
		if not _valid_ai_entity(state):
			continue
		var entity_id := String(state.get("id", ""))
		var ai := _cached_node(_ai_index, entity_id)
		if ai == null:
			continue
		if _revision <= int(ai.get_meta("coop_ai_revision", -1)):
			continue
		ai.set_meta("coop_ai_revision", _revision)
		ai.set_meta("coop_ai_target", state.duplicate(true))
		var shots := int(state.get("shots", 0))
		var previous_shots := int(ai.get_meta("coop_shots_received", shots))
		ai.set_meta("coop_shots_received", shots)
		var active := bool(state.get("active", false))
		if active and ai.get_parent() != null and String(ai.get_parent().name) != "Agents":
			var agents := get_node_or_null("/root/Map/AI/Agents")
			if agents != null:
				ai.reparent(agents)
		ai.visible = active
		ai.process_mode = Node.PROCESS_MODE_INHERIT
		ai.set("pause", not active)
		ai.set("dead", bool(state.get("dead", false)))
		ai.set("health", float(state.get("health", 100.0)))
		ai.set("currentState", int(state.get("state", 0)))
		_sync_ai_weapon(ai, state)
		if shots > previous_shots:
			_play_ai_shot(ai)
		var animator := ai.get("animator") as AnimationTree
		if animator != null:
			animator.active = false
		var skeleton := ai.get("skeleton") as Skeleton3D
		if skeleton != null and not skeleton.has_meta("coop_pose_slave"):
			skeleton.process_mode = Node.PROCESS_MODE_INHERIT
			skeleton.modifier_callback_mode_process = Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_MANUAL
			skeleton.physical_bones_stop_simulation()
			skeleton.set_process(false)
			skeleton.set_physics_process(false)
			skeleton.set_meta("coop_pose_slave", true)
			for child in skeleton.get_children():
				if child is PhysicalBone3D and child.get_child_count() > 0 and child.get_child(0) is CollisionShape3D:
					child.get_child(0).set_deferred("disabled", true)
		var collision := ai.get("collision") as CollisionShape3D
		if collision != null:
			collision.set_deferred("disabled", not active or bool(state.dead))
		if bool(state.dead):
			_activate_ai_container(ai)

func _interpolate_client_ai(delta: float) -> void:
	for ai in _ai_index.values():
		if ai == null or not is_instance_valid(ai) or not ai.has_meta("coop_ai_target"):
			continue
		var target: Dictionary = ai.get_meta("coop_ai_target")
		var position := Vector3(target.get("position", ai.global_position))
		if ai.global_position.distance_to(position) > 12.0:
			ai.global_position = position
		else:
			ai.global_position = ai.global_position.lerp(position, 1.0 - exp(-delta * 18.0))
		ai.rotation.y = lerp_angle(ai.rotation.y, float(target.get("yaw", ai.rotation.y)), 1.0 - exp(-delta * 14.0))
		BonePose.apply(ai.get("skeleton") as Skeleton3D, target.get("bones", PackedFloat32Array()), 1.0 - exp(-delta * 20.0))
		var skeleton := ai.get("skeleton") as Skeleton3D
		if skeleton != null:
			skeleton.force_update_all_bone_transforms()

static func death_pose_phase(elapsed_ms: int) -> int:
	var phase := -1
	for index in Protocol.AI_DEATH_POSE_PHASES_MS.size():
		if elapsed_ms >= int(Protocol.AI_DEATH_POSE_PHASES_MS[index]):
			phase = index
	return phase

func _sync_ai_weapon(ai: Node3D, state: Dictionary) -> void:
	var mount := ai.get("weapons") as Node3D
	if mount == null:
		return
	var key := String(state.get("weapon", ""))
	var current := String(mount.get_meta("coop_weapon", ""))
	if current != key:
		for child in mount.get_children():
			mount.remove_child(child)
			child.queue_free()
		mount.set_meta("coop_weapon", key)
		if not key.is_empty():
			var database := get_node_or_null("/root/Database")
			var packed: Variant = database.get(key) if database != null else null
			if packed is PackedScene:
				var visual := packed.instantiate() as Node3D
				var slot: Variant = visual.get("slotData")
				if slot != null:
					visual.set_meta("coop_weapon_data", slot.get("itemData"))
				_prepare_static_visual(visual)
				mount.add_child(visual)
	if mount.get_child_count() == 0:
		return
	var weapon := mount.get_child(0) as Node3D
	weapon.transform = state.get("weapon_transform", weapon.transform)
	var attachments := weapon.get_node_or_null("Attachments")
	if attachments != null:
		var keys: Array = state.get("attachments", [])
		for child in attachments.get_children():
			if child is Node3D:
				child.visible = keys.has(String(child.name))

func _play_ai_shot(ai: Node3D) -> void:
	var mount := ai.get("weapons") as Node3D
	if mount == null or mount.get_child_count() == 0 or not ResourceLoader.exists("res://Resources/AudioInstance3D.tscn"):
		return
	var data: Resource = mount.get_child(0).get_meta("coop_weapon_data", null)
	if data == null:
		return
	var packed: PackedScene = load("res://Resources/AudioInstance3D.tscn")
	for event in [data.get("fireSemi"), data.get("tailOutdoor")]:
		if event == null:
			continue
		var audio := packed.instantiate() as AudioStreamPlayer3D
		ai.add_child(audio)
		audio.position.y = 1.2
		audio.call("PlayInstance", event, 75.0, 400.0)

func _prepare_static_visual(root: Node) -> void:
	if root == null:
		return
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node.get_script() != null:
			node.set_script(null)
		if node is CollisionObject3D:
			node.collision_layer = 0
			node.collision_mask = 0
		if node is RigidBody3D:
			node.freeze = true
		if node is CollisionShape3D:
			node.disabled = true
		if node is AudioStreamPlayer or node is AudioStreamPlayer3D:
			node.process_mode = Node.PROCESS_MODE_DISABLED
		stack.append_array(node.get_children())

func _register_ai(ai: Node3D) -> void:
	if ai.has_meta("coop_ai_id"):
		_ai_index[String(ai.get_meta("coop_ai_id"))] = ai
		return
	var parent := ai.get_parent()
	if parent == null:
		return
	var prefix := "A" if String(parent.name) == "A_Pool" else ("B" if String(parent.name) == "B_Pool" else "")
	if prefix.is_empty():
		return
	var entity_id := "%s:%d" % [prefix, ai.get_index()]
	ai.set_meta("coop_ai_id", entity_id)
	_ai_index[entity_id] = ai

func _refresh_ai_index() -> void:
	for path in ["/root/Map/AI/A_Pool", "/root/Map/AI/B_Pool", "/root/Map/AI/Agents"]:
		var parent: Node = get_node_or_null(path)
		if parent == null:
			continue
		for child in parent.get_children():
			if child is Node3D:
				_register_ai(child)

func _on_weapon_ready_post() -> void:
	var weapon: Variant = _library._caller
	var ray: RayCast3D = weapon.get("raycast") as RayCast3D if weapon != null else null
	if ray != null:
		ray.collision_mask |= COOP_COLLISION_LAYER

func _on_weapon_raycast_post(_spread: float) -> void:
	if _session == null or not _session.is_online():
		return
	_owner_api.call("note_local_shot")
	var weapon: Variant = _library._caller
	var ray: RayCast3D = weapon.get("raycast") as RayCast3D if weapon != null else null
	if ray == null or not ray.is_colliding():
		return
	var collider: Variant = ray.get_collider()
	if collider == null or not collider.has_meta("coop_peer_id"):
		return
	var data: Variant = weapon.get("data")
	if data != null:
		_session.report_player_hit(int(collider.get_meta("coop_peer_id")), float(data.get("damage")), int(data.get("penetration")))

func _on_knife_ready_post() -> void:
	var knife: Variant = _library._caller
	var ray: RayCast3D = knife.get("raycast") as RayCast3D if knife != null else null
	if ray != null:
		ray.collision_mask |= COOP_COLLISION_LAYER

func _on_knife_hit_check_post() -> void:
	if _session == null or not _session.is_online():
		return
	var knife: Variant = _library._caller
	var ray: RayCast3D = knife.get("raycast") as RayCast3D if knife != null else null
	if ray == null or not ray.is_colliding():
		return
	var collider: Variant = ray.get_collider()
	if collider != null and collider.has_meta("coop_peer_id"):
		_session.report_melee_hit(int(collider.get_meta("coop_peer_id")), Protocol.MELEE_DAMAGE)

func _on_explosion_explode() -> void:
	if _session == null or not _session.is_online():
		return
	var effect := _library._caller as Node3D
	if effect == null or effect.has_meta("coop_authoritative_explosion"):
		return
	var position := effect.global_position
	var size := clampf(float(effect.get("size")), 1.0, Protocol.MAX_EXPLOSION_SIZE)
	if _session.multiplayer.is_server():
		effect.set_meta("coop_authoritative_explosion", true)
		_commit_explosion(1, _current_map(), position, size)
	else:
		_library.skip_super()
		_session.request_explosion(_current_map(), position, size)
		effect.call_deferred("queue_free")

func _on_explosion_check_overlap() -> void:
	if _session != null and _session.is_online():
		# Online blast damage is applied once by the host from the reliable event.
		_library.skip_super()

func _on_explosion_check_alert() -> void:
	if _is_online_client():
		# Only the host is allowed to change enemy alert/decision state.
		_library.skip_super()

func _on_explosion_requested(source_peer: int, map_name: String, position: Vector3, size: float) -> void:
	if not _session.multiplayer.is_server() or map_name != _current_map():
		return
	var source: Dictionary = _player_states.get(source_peer, {})
	if source.is_empty() or bool(source.get("downed", false)) or String(source.get("map", "")) != map_name:
		return
	if Vector3(source.position).distance_to(position) > Protocol.MAX_THROW_DISTANCE:
		return
	if _commit_explosion(source_peer, map_name, position, size):
		_spawn_authoritative_explosion(position, size)

func _commit_explosion(_source_peer: int, map_name: String, position: Vector3, size: float) -> bool:
	if map_name != _current_map() or not position.is_finite():
		return false
	var now := Time.get_ticks_msec()
	_prune_recent_explosions(now)
	for entry in _recent_explosions:
		if now - int(entry.get("time", 0)) <= Protocol.EXPLOSION_DEDUP_MS and Vector3(entry.get("position", Vector3.INF)).distance_to(position) <= Protocol.EXPLOSION_DEDUP_DISTANCE:
			return false
	_recent_explosions.append({"time": now, "position": position})
	_explosion_serial += 1
	var event_id := "E:%d" % _explosion_serial
	_explosion_seen[event_id] = true
	_apply_explosion_damage(position, clampf(size, 1.0, Protocol.MAX_EXPLOSION_SIZE))
	_session.publish_explosion(map_name, event_id, position, size)
	return true

func _on_explosion_received(map_name: String, event_id: String, position: Vector3, size: float) -> void:
	if map_name != _current_map() or _explosion_seen.has(event_id):
		return
	_explosion_seen[event_id] = true
	if not _session.multiplayer.is_server():
		_spawn_authoritative_explosion(position, size)

func _spawn_authoritative_explosion(position: Vector3, size: float) -> void:
	if not ResourceLoader.exists("res://Effects/Explosion.tscn"):
		return
	var packed := load("res://Effects/Explosion.tscn") as PackedScene
	var effect := packed.instantiate() as Node3D
	if effect == null:
		return
	effect.set_meta("coop_authoritative_explosion", true)
	get_tree().root.add_child(effect)
	effect.global_position = position
	effect.set("size", clampf(size, 1.0, Protocol.MAX_EXPLOSION_SIZE))
	effect.call_deferred("Explode")

func _apply_explosion_damage(position: Vector3, size: float) -> void:
	var map_name := _current_map()
	for raw_peer_id in _player_states.keys():
		var peer_id := int(raw_peer_id)
		var state: Dictionary = _player_states.get(peer_id, {})
		if state.is_empty() or bool(state.get("downed", false)) or String(state.get("map", "")) != map_name:
			continue
		var target_position := Vector3(state.position) + Vector3.UP * 0.8
		if position.distance_to(target_position) > size or not _blast_has_line_of_sight(position, target_position, peer_id):
			continue
		var next := state.duplicate(true)
		next.health = maxf(0.0, float(next.health) - Protocol.EXPLOSION_DAMAGE)
		next.downed = float(next.health) <= 0.0
		_player_states[peer_id] = next
		_session.broadcast_player_state(peer_id, next)
	_refresh_ai_index()
	for raw_ai in _ai_index.values():
		var ai := raw_ai as Node3D
		if ai == null or not is_instance_valid(ai) or bool(ai.get("dead")) or ai.get_parent() == null or String(ai.get_parent().name) != "Agents":
			continue
		var target_position: Vector3 = ai.global_position + Vector3.UP * 1.2
		if position.distance_to(target_position) <= size and _blast_has_line_of_sight(position, target_position, 0):
			ai.call("ExplosionDamage", (ai.global_position - position).normalized())
	_check_all_players_downed()

func _blast_has_line_of_sight(origin: Vector3, target: Vector3, target_peer: int) -> bool:
	var scene := get_tree().current_scene as Node3D
	if scene == null:
		return true
	var world: World3D = scene.get_world_3d()
	var query := PhysicsRayQueryParameters3D.create(origin, target)
	query.collide_with_areas = false
	query.collide_with_bodies = true
	var hit: Dictionary = world.direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return true
	var collider: Variant = hit.get("collider")
	if collider == null:
		return false
	if target_peer > 0 and collider.has_meta("coop_peer_id"):
		return int(collider.get_meta("coop_peer_id")) == target_peer
	return collider.is_in_group("Player") if target_peer > 0 else collider.is_in_group("AI")

func _prune_recent_explosions(now: int) -> void:
	for index in range(_recent_explosions.size() - 1, -1, -1):
		if now - int(_recent_explosions[index].get("time", 0)) > Protocol.EXPLOSION_DEDUP_MS:
			_recent_explosions.remove_at(index)

func _on_interactor_physics(_delta: float) -> void:
	var ray := _library._caller as RayCast3D
	if ray != null:
		ray.collision_mask |= COOP_COLLISION_LAYER
		if _session != null and _session.is_online() and ray.is_colliding():
			var target: Variant = ray.get_collider()
			if is_instance_valid(target) and target.has_meta("coop_peer_id") and bool(target.get("downed")):
				_library.skip_super()
				if _game_data != null and not bool(_game_data.get("freeze")):
					target.call("UpdateTooltip")
					_game_data.set("interaction", true)
					_game_data.set("transition", false)
					if Input.is_action_just_pressed("interact"):
						target.call("Interact")

func _on_loot_simulation_ready() -> void:
	if not _is_online_client():
		return
	_library.skip_super()
	var simulation := _library._caller as Node
	if simulation != null and simulation.get_child_count() > 0:
		simulation.get_child(0).queue_free()

func _on_pickup_ready_post() -> void:
	var pickup := _library._caller as Node3D
	if pickup == null or _session == null or not _session.is_online():
		return
	if _session.multiplayer.is_server():
		_register_host_loot(pickup)
	elif not pickup.has_meta("coop_loot_id") and not _drop_expected.is_empty():
		# Drop assigns slot data and transform AFTER add_child/_ready.
		pickup.set_meta("coop_drop_slot", _drop_expected.pop_front())
		call_deferred("_submit_dropped_pickup", pickup)
	elif not pickup.has_meta("coop_loot_id"):
		pickup.queue_free()

func _on_drop(target: Variant) -> void:
	_drop_active = _is_online_client()
	_drop_expected.clear()
	if not _drop_active or target == null:
		return
	var encoded := SlotCodec.encode(target.get("slotData"))
	if not SlotCodec.is_valid(encoded):
		return
	if bool(target.get("slotData").get("itemData").get("stackable")):
		var box_size := maxi(1, int(target.get("slotData").get("itemData").get("defaultAmount")))
		_drop_expected = split_drop_payload(encoded, box_size)
	else:
		_drop_expected.append(encoded)

static func split_drop_payload(encoded: Dictionary, box_size: int) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var amount := maxi(0, int(encoded.get("amount", 0)))
	box_size = maxi(1, box_size)
	while amount > 0:
		var chunk := encoded.duplicate(true)
		chunk.amount = mini(amount, box_size)
		result.append(chunk)
		amount -= int(chunk.amount)
	return result

func _on_drop_post(_target: Variant) -> void:
	_drop_active = false
	_drop_expected.clear()

func _submit_dropped_pickup(pickup: Node3D) -> void:
	if not is_instance_valid(pickup):
		return
	var slot: Dictionary = pickup.get_meta("coop_drop_slot", SlotCodec.encode(pickup.get("slotData")))
	if not SlotCodec.is_valid(slot):
		return
	_drop_serial += 1
	var token := "D:%d:%d" % [_session.multiplayer.get_unique_id(), _drop_serial]
	pickup.set_meta("coop_pending_drop", token)
	# Keep the provisional mesh visible until the host accepts it; collision is
	# disabled so it cannot be picked twice during the round trip.
	if pickup is CollisionObject3D:
		pickup.collision_layer = 0
	_pending_drops[token] = pickup
	_session.submit_loot_drop(token, _current_map(), slot, pickup.global_position, pickup.global_rotation)

func _on_loot_drop_requested(source_peer: int, token: String, map_name: String, data: Dictionary, position: Vector3, rotation: Vector3) -> void:
	var key := "%d/%s" % [source_peer, token]
	if _drop_seen.has(key):
		var prior: Dictionary = _drop_seen[key]
		_session.answer_loot_drop(source_peer, token, bool(prior.accepted), String(prior.entity_id))
		return
	var source: Dictionary = _player_states.get(source_peer, {})
	var accepted := false
	var entity_id := ""
	if not source.is_empty() and map_name == _current_map() and String(source.map) == map_name and not bool(source.downed) and Vector3(source.position).distance_to(position) <= 5.0 and SlotCodec.is_valid(data):
		var slot: Variant = SlotCodec.decode(data)
		var database := get_node_or_null("/root/Database")
		var packed: Variant = database.get(String(slot.get("itemData").get("file"))) if slot != null and database != null else null
		if packed is PackedScene:
			var pickup := packed.instantiate() as Node3D
			pickup.set("slotData", slot)
			_loot_root().add_child(pickup)
			pickup.global_position = position
			pickup.global_rotation = rotation
			if pickup.has_method("UpdateAttachments"):
				pickup.call("UpdateAttachments")
			if pickup.has_method("Unfreeze"):
				pickup.call("Unfreeze")
			_register_host_loot(pickup)
			entity_id = String(pickup.get_meta("coop_loot_id", ""))
			accepted = true
	_drop_seen[key] = {"accepted": accepted, "entity_id": entity_id}
	_session.answer_loot_drop(source_peer, token, accepted, entity_id)

func _on_loot_drop_result(token: String, accepted: bool, entity_id: String) -> void:
	var pickup: Variant = _pending_drops.get(token)
	if not is_instance_valid(pickup):
		return
	if not accepted:
		var interface := get_node_or_null("/root/Map/Core/UI/Interface")
		var slot: Variant = pickup.get("slotData")
		var grid: Variant = interface.get("inventoryGrid") if interface != null else null
		if grid == null or not (_stack_whole(slot, grid) or bool(interface.call("Create", slot, grid, false))):
			_owner_api.call("show_gameplay_status", "Drop rejected. Free inventory space and try recovering the pending item before travelling.", true)
			return
		interface.call("UpdateStats", false)
		_pending_drops.erase(token)
		pickup.queue_free()
	else:
		pickup.set_meta("coop_accepted_entity", entity_id)
		if _client_loot_nodes.has(entity_id):
			_pending_drops.erase(token)
			pickup.queue_free()

func has_pending_transfers(include_sleep := true, include_shelter := true) -> bool:
	if _owner_api != null:
		var shelter: Variant = _owner_api.get("_shelter")
		if include_shelter and shelter != null and shelter.busy(): return true
		var sleep: Variant = _owner_api.get("_group_sleep")
		if include_sleep and sleep != null and sleep.busy():
			return true
		var trading: Variant = _owner_api.get("_traders")
		if trading != null and trading.busy():
			return true
	return not _pending_drops.is_empty() or not _loot_reservations.is_empty() or not _pending_medical.is_empty() or not _container_leases.is_empty() or not _pending_container_opens.is_empty() or not _pending_container_commits.is_empty() or not _client_open_container.is_empty()

func _stack_whole(slot: Variant, grid: Node) -> bool:
	var data: Variant = slot.get("itemData")
	if not bool(data.get("stackable")):
		return false
	for item in grid.get_children():
		var existing: Variant = item.get("slotData")
		if String(existing.get("itemData").get("file")) == String(data.get("file")) and int(existing.get("amount")) + int(slot.get("amount")) <= int(data.get("maxAmount")):
			existing.set("amount", int(existing.get("amount")) + int(slot.get("amount")))
			item.call("UpdateDetails")
			return true
	return false

func _on_pickup_interact() -> void:
	if _session == null or not _session.is_online():
		return
	var pickup := _library._caller as Node
	if pickup == null or not pickup.has_meta("coop_loot_id"):
		return
	_library.skip_super()
	_session.request_loot_pickup(String(pickup.get_meta("coop_loot_id")))

func _register_host_loot(pickup: Node3D) -> void:
	if pickup.has_meta("coop_loot_id"):
		_loot_nodes[String(pickup.get_meta("coop_loot_id"))] = pickup
		return
	_loot_serial += 1
	var entity_id := "L:%d" % _loot_serial
	pickup.set_meta("coop_loot_id", entity_id)
	_loot_nodes[entity_id] = pickup

func _publish_loot_state() -> void:
	var map_name := _current_map()
	if not Protocol.is_valid_scene(map_name):
		return
	if not _loot_scanned:
		_scan_host_loot()
		_loot_scanned = true
	var entities: Array[Dictionary] = []
	for entity_id in _loot_nodes.keys():
		if _loot_reservations.has(entity_id):
			continue
		var pickup := _cached_node(_loot_nodes, entity_id)
		if pickup == null or not is_instance_valid(pickup) or pickup.is_queued_for_deletion():
			_loot_nodes.erase(entity_id)
			continue
		var slot := SlotCodec.encode(pickup.get("slotData"))
		if not slot.is_empty():
			entities.append({"id": entity_id, "position": pickup.global_position, "rotation": pickup.global_rotation, "slot": slot})
	_loot_revision += 1
	_session.publish_loot_state(map_name, _loot_revision, entities)
	for container in _containers.values():
		if is_instance_valid(container):
			_publish_container(container)

func _scan_host_loot() -> void:
	var scene: Node = get_tree().current_scene
	if scene == null:
		return
	var stack: Array[Node] = [scene]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		var script: Script = node.get_script()
		if node is Node3D and script != null and script.resource_path == "res://Scripts/Pickup.gd":
			_register_host_loot(node)
		stack.append_array(node.get_children())

func _on_loot_state_received(map_name: String, _revision: int, entities: Array) -> void:
	if _session.multiplayer.is_server() or map_name != _current_map() or _revision <= _last_loot_revision:
		return
	_last_loot_revision = _revision
	var seen: Dictionary = {}
	for raw in entities:
		if not raw is Dictionary:
			continue
		var state: Dictionary = raw
		var entity_id := String(state.get("id", ""))
		if bool(_grant_results.get(entity_id, false)):
			continue
		if not _valid_loot_entity(state) or not SlotCodec.is_valid(state.get("slot", {})):
			continue
		seen[entity_id] = true
		_confirm_provisional_drop(entity_id)
		var pickup := _cached_node(_client_loot_nodes, entity_id)
		if pickup == null or not is_instance_valid(pickup):
			pickup = _spawn_client_loot(entity_id, state)
		if pickup != null:
			pickup.global_position = Vector3(state.get("position", pickup.global_position))
			pickup.global_rotation = Vector3(state.get("rotation", pickup.global_rotation))
	for entity_id in _client_loot_nodes.keys():
		if not seen.has(entity_id):
			var old: Variant = _client_loot_nodes[entity_id]
			if is_instance_valid(old):
				old.queue_free()
			_client_loot_nodes.erase(entity_id)

func _confirm_provisional_drop(entity_id: String) -> void:
	for token in _pending_drops.keys():
		var provisional: Variant = _pending_drops[token]
		if is_instance_valid(provisional) and String(provisional.get_meta("coop_accepted_entity", "")) == entity_id:
			_pending_drops.erase(token)
			provisional.queue_free()
			return

func _spawn_client_loot(entity_id: String, state: Dictionary) -> Node3D:
	var slot: Variant = SlotCodec.decode(state.slot)
	if slot == null:
		return null
	var item: Variant = slot.get("itemData")
	var database: Node = get_node_or_null("/root/Database")
	var packed: PackedScene = database.get(String(item.get("file"))) if database != null else null
	if packed == null:
		return null
	var pickup := packed.instantiate() as Node3D
	if pickup == null:
		return null
	pickup.set("slotData", slot)
	pickup.set_meta("coop_loot_id", entity_id)
	var parent := _loot_root()
	parent.add_child(pickup)
	if pickup.has_method("UpdateAttachments"):
		pickup.call("UpdateAttachments")
	_client_loot_nodes[entity_id] = pickup
	return pickup

func _on_loot_pickup_requested(source_peer: int, entity_id: String) -> void:
	if not _session.multiplayer.is_server():
		return
	var pickup := _cached_node(_loot_nodes, entity_id)
	var source: Dictionary = _player_states.get(source_peer, {})
	if pickup == null or source.is_empty() or String(source.map) != _current_map():
		return
	if _loot_reservations.has(entity_id):
		return
	if Vector3(source.position).distance_to(pickup.global_position) > 4.0:
		return
	var slot: Dictionary = SlotCodec.encode(pickup.get("slotData"))
	if slot.is_empty():
		return
	_loot_reservations[entity_id] = {
		"peer": source_peer,
		"node": pickup,
		"layer": pickup.collision_layer if pickup is CollisionObject3D else 0,
		"mask": pickup.collision_mask if pickup is CollisionObject3D else 0,
		"deadline": Time.get_ticks_msec() + 5000,
		"slot": slot,
		"item_group": pickup.is_in_group("Item"),
	}
	pickup.remove_from_group("Item")
	pickup.hide()
	if pickup is CollisionObject3D:
		pickup.collision_layer = 0
		pickup.collision_mask = 0
	_session.send_loot_grant(source_peer, entity_id, slot)

func _on_loot_grant_received(entity_id: String, data: Dictionary) -> void:
	if _grant_results.has(entity_id):
		_session.report_loot_grant(entity_id, bool(_grant_results[entity_id]))
		return
	var slot: Variant = SlotCodec.decode(data)
	var interface: Node = get_node_or_null("/root/Map/Core/UI/Interface")
	if slot == null or interface == null:
		_session.report_loot_grant(entity_id, false)
		return
	var grid: Variant = interface.get("inventoryGrid")
	# Vanilla AutoStack can drop overflow to the floor while returning success.
	# Only stack if the entire amount fits an existing stack; otherwise Create
	# either places the complete slot or leaves it with the host.
	var accepted := _stack_whole(slot, grid)
	if not accepted:
		accepted = bool(interface.call("Create", slot, grid, false))
	if accepted:
		_grant_results[entity_id] = true
		interface.call("UpdateStats", false)
		var pickup: Variant = _client_loot_nodes.get(entity_id)
		if is_instance_valid(pickup):
			pickup.queue_free()
		_client_loot_nodes.erase(entity_id)
	else:
		_owner_api.call("show_gameplay_status", "Inventory is full; loot grant could not be placed", true)
	_session.report_loot_grant(entity_id, accepted)

func _on_loot_grant_result_requested(source_peer: int, entity_id: String, accepted: bool) -> void:
	if not _session.multiplayer.is_server() or not _loot_reservations.has(entity_id):
		return
	var reservation: Dictionary = _loot_reservations[entity_id]
	if int(reservation.peer) != source_peer:
		return
	var pickup: Variant = reservation.node
	_loot_reservations.erase(entity_id)
	if accepted:
		_loot_nodes.erase(entity_id)
		if is_instance_valid(pickup):
			pickup.queue_free()
	else:
		_restore_reserved_loot(pickup, reservation)

func _expire_loot_reservations() -> void:
	var now := Time.get_ticks_msec()
	for entity_id in _loot_reservations.keys():
		var reservation: Dictionary = _loot_reservations[entity_id]
		if now < int(reservation.deadline):
			continue
		reservation.deadline = now + 5000
		# Never restore a granted item merely because its acknowledgement is late.
		# Reliable, idempotent replay resolves the same transfer without duplication.
		if _session.roster.has(int(reservation.peer)):
			_session.send_loot_grant(int(reservation.peer), entity_id, reservation.slot)

func _restore_reserved_loot(pickup: Variant, reservation: Dictionary) -> void:
	if not is_instance_valid(pickup):
		return
	pickup.show()
	if bool(reservation.get("item_group", false)):
		pickup.add_to_group("Item")
	if pickup is CollisionObject3D:
		pickup.collision_layer = int(reservation.layer)
		pickup.collision_mask = int(reservation.mask)

func _on_container_ready() -> void:
	if not _is_online_client():
		return
	_library.skip_super()
	var container: Variant = _library._caller
	if container != null:
		container.get("loot").clear()
		container.get("storage").clear()
		_register_container(container)

func _on_container_ready_post() -> void:
	if _session != null and _session.is_online() and _session.multiplayer.is_server():
		var container: Variant = _library._caller
		if container != null:
			_register_container(container)
			_publish_container(container)

func _on_container_interact() -> void:
	if _session == null or not _session.is_online():
		return
	var shelter: Variant = _owner_api.get("_shelter")
	if shelter != null and shelter.active():
		if _session.multiplayer.is_server(): shelter._scan()
		if shelter.busy() or (not _session.multiplayer.is_server() and not shelter.initialized):
			_library.skip_super()
			_owner_api.call("show_gameplay_status", "Wait for shelter furniture synchronization or editing to finish.", true)
			return
	var container := _library._caller as Node3D
	if container == null:
		return
	var entity_id := _register_container(container)
	if container.has_meta("coop_open_authorized"):
		container.remove_meta("coop_open_authorized")
		return
	if bool(container.get("locked")):
		return
	if _session.multiplayer.is_server():
		var holder := int(_container_leases.get(entity_id, 0))
		if holder != 0 and holder != 1:
			_library.skip_super()
			_owner_api.call("show_gameplay_status", "That container is being used by another player", true)
			return
		_container_leases[entity_id] = 1
		_publish_container(container, true)
		return
	_library.skip_super()
	if _pending_container_opens.has(entity_id) or not _client_open_container.is_empty():
		return
	_pending_container_opens[entity_id] = Time.get_ticks_msec()
	_session.request_container_open(entity_id)

func _on_container_storage(grid: Variant) -> void:
	if not _is_online_client():
		return
	_library.skip_super()
	var container: Variant = _library._caller
	if container == null:
		return
	var entity_id: String = _register_container(container)
	var slots: Array[Dictionary] = []
	for item in grid.get_children():
		var encoded: Dictionary = SlotCodec.encode(item.get("slotData"))
		if not encoded.is_empty():
			encoded["grid_position"] = Vector2(item.position)
			encoded["grid_rotated"] = bool(item.get("rotated"))
			slots.append(encoded)
	_pending_container_commits[entity_id] = true
	_client_open_container = ""
	_session.submit_container_state(entity_id, slots)

func _on_container_storage_post(_grid: Variant) -> void:
	if _session != null and _session.is_online() and _session.multiplayer.is_server():
		var container: Variant = _library._caller
		var entity_id := _register_container(container)
		_container_leases.erase(entity_id)
		_publish_container(container)

func _on_container_tooltip() -> void:
	if _session == null or not _session.is_online():
		return
	var container := _library._caller as Node
	if container == null:
		return
	var id := _register_container(container)
	var holder := int(_container_leases.get(id, 0)) if _session.multiplayer.is_server() else int(container.get_meta("coop_holder", 0))
	if holder != 0 and holder != _session.multiplayer.get_unique_id():
		_game_data.set("tooltip", "Occupied")

func _register_container(container: Node) -> String:
	if container.has_meta("coop_container_id"):
		var cached_id := String(container.get_meta("coop_container_id"))
		_containers[cached_id] = container
		return cached_id
	# During _ready, current_scene may still be the previous loading scene.
	var scene: Node = container
	while scene.get_parent() != null and scene.get_parent() != get_tree().root:
		scene = scene.get_parent()
	var relative := String(scene.get_path_to(container))
	var entity_id: String = "C:%s" % relative.sha256_text().left(20)
	container.set_meta("coop_container_id", entity_id)
	_containers[entity_id] = container
	if _is_online_client():
		_session.request_container_snapshot(entity_id)
	if _pending_container_states.has(entity_id):
		var pending: Dictionary = _pending_container_states[entity_id]
		_pending_container_states.erase(entity_id)
		_apply_container_state(entity_id, int(pending.revision), pending.slots, pending.properties)
	return entity_id

func _publish_container(container: Node, force := false) -> void:
	if container == null or not is_instance_valid(container):
		return
	var entity_id: String = _register_container(container)
	var source: Array = container.get("storage") if bool(container.get("storaged")) else container.get("loot")
	var slots: Array[Dictionary] = []
	for slot in source:
		var encoded: Dictionary = SlotCodec.encode(slot)
		if not encoded.is_empty():
			slots.append(encoded)
	var properties := {
		"storaged": bool(container.get("storaged")),
		"holder": int(_container_leases.get(entity_id, 0)),
		"visible": container.visible if container is Node3D else true,
		"locked": bool(container.get("locked")),
		"active": _container_collision_active(container),
	}
	var digest := JSON.stringify({"slots": slots, "properties": properties}, "", true).sha256_text()
	if not force and String(_container_digests.get(entity_id, "")) == digest:
		return
	_container_digests[entity_id] = digest
	var revision: int = int(_container_revisions.get(entity_id, 0)) + 1
	_container_revisions[entity_id] = revision
	_session.publish_container_state(entity_id, revision, slots, properties)

func _on_container_state_received(entity_id: String, revision: int, slots: Array, properties: Dictionary) -> void:
	if _session.multiplayer.is_server() or revision <= int(_container_revisions.get(entity_id, -1)):
		return
	var container: Variant = _containers.get(entity_id)
	if container == null or not is_instance_valid(container):
		_pending_container_states[entity_id] = {"revision": revision, "slots": slots.duplicate(true), "properties": properties.duplicate(true)}
		return
	_apply_container_state(entity_id, revision, slots, properties)

func _apply_container_state(entity_id: String, revision: int, slots: Array, properties: Dictionary) -> void:
	var container: Variant = _containers.get(entity_id)
	if container == null or not is_instance_valid(container):
		return
	var decoded: Array = []
	for raw in slots:
		var slot: Variant = SlotCodec.decode(raw) if raw is Dictionary else null
		if slot == null:
			_owner_api.call("show_gameplay_status", "Container item could not be loaded; contents were not replaced", true)
			return
		decoded.append(slot)
	_replace_container_slots(container, decoded, bool(properties.get("storaged", false)))
	container.set("locked", bool(properties.get("locked", false)))
	container.set_meta("coop_holder", int(properties.get("holder", 0)))
	if container is Node3D:
		container.visible = bool(properties.get("visible", true))
		container.process_mode = Node.PROCESS_MODE_INHERIT if container.visible else Node.PROCESS_MODE_DISABLED
	_set_container_collision(container, bool(properties.get("active", true)))
	_container_revisions[entity_id] = revision

func _on_container_update_requested(source_peer: int, entity_id: String, slots: Array) -> void:
	if not _session.multiplayer.is_server():
		return
	var container := _cached_node(_containers, entity_id)
	if container == null or int(_container_leases.get(entity_id, 0)) != source_peer:
		_session.answer_container_update(source_peer, entity_id, false)
		return
	var decoded: Array = []
	for raw in slots:
		var slot: Variant = SlotCodec.decode(raw) if raw is Dictionary else null
		if slot == null:
			_session.answer_container_update(source_peer, entity_id, false)
			return
		decoded.append(slot)
	_replace_container_slots(container, decoded, true)
	_container_leases.erase(entity_id)
	_publish_container(container)
	_session.answer_container_update(source_peer, entity_id, true)

static func _replace_container_slots(container: Node, slots: Array, storaged: bool) -> void:
	# Keep the game's Array[SlotData] instances and their declared element type.
	var loot: Array = container.get("loot")
	var storage: Array = container.get("storage")
	loot.clear()
	storage.clear()
	if storaged:
		storage.append_array(slots)
	else:
		loot.append_array(slots)
	container.set("storaged", storaged)

func _on_container_open_requested(source_peer: int, entity_id: String) -> void:
	if not _session.multiplayer.is_server():
		return
	var shelter: Variant = _owner_api.get("_shelter")
	if shelter != null and shelter.active() and shelter.busy():
		_session.answer_container_open(source_peer, entity_id, false, "Shelter furniture is being edited")
		return
	var container := _cached_node(_containers, entity_id)
	var source: Dictionary = _session.latest_pose(source_peer)
	if container == null or source.is_empty() or bool(source.get("downed", false)) or String(source.get("map", "")) != _current_map() or Vector3(source.position).distance_to(container.global_position) > 5.0:
		_session.answer_container_open(source_peer, entity_id, false, "Move closer to the container")
		return
	if bool(container.get("locked")):
		_session.answer_container_open(source_peer, entity_id, false, "Container is locked")
		return
	var holder := int(_container_leases.get(entity_id, 0))
	if holder != 0 and holder != source_peer:
		_session.answer_container_open(source_peer, entity_id, false, "Another player is using it")
		return
	_container_leases[entity_id] = source_peer
	_publish_container(container, true)
	_session.answer_container_open(source_peer, entity_id, true)

func _on_container_open_result(entity_id: String, accepted: bool, detail: String) -> void:
	if not _pending_container_opens.has(entity_id): return
	_pending_container_opens.erase(entity_id)
	if not accepted:
		_owner_api.call("show_gameplay_status", detail if not detail.is_empty() else "Container is unavailable", true)
		return
	var container := _cached_node(_containers, entity_id)
	if container == null:
		return
	_client_open_container = entity_id
	container.set_meta("coop_open_authorized", true)
	container.call("Interact")

func _expire_container_opens() -> void:
	for entity_id in _pending_container_opens.keys():
		if Time.get_ticks_msec() - int(_pending_container_opens[entity_id]) < 8000: continue
		_pending_container_opens.erase(entity_id)
		_session.cancel_container_open(entity_id)
		_owner_api.call("show_gameplay_status", "Container request timed out. You can retry or travel.", true)

func _on_container_open_cancelled(peer_id: int, entity_id: String) -> void:
	if int(_container_leases.get(entity_id, 0)) != peer_id: return
	_container_leases.erase(entity_id)
	var container := _cached_node(_containers, entity_id)
	if container != null: _publish_container(container, true)

func _on_container_update_result(entity_id: String, accepted: bool) -> void:
	_pending_container_commits.erase(entity_id)
	if not accepted:
		_owner_api.call("show_gameplay_status", "Container update was rejected; reopen it to refresh", true)
		_session.request_container_snapshot(entity_id)

func _on_container_snapshot_requested(_source_peer: int, entity_id: String) -> void:
	if not _session.multiplayer.is_server():
		return
	var container := _cached_node(_containers, entity_id)
	if container != null:
		_publish_container(container, true)

func _container_collision_active(container: Node) -> bool:
	var stack: Array[Node] = [container]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is CollisionShape3D:
			return not (node as CollisionShape3D).disabled
		stack.append_array(node.get_children())
	return true

func _set_container_collision(container: Node, enabled: bool) -> void:
	var stack: Array[Node] = [container]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is CollisionShape3D:
			(node as CollisionShape3D).set_deferred("disabled", not enabled)
		stack.append_array(node.get_children())

func _activate_ai_container(ai: Node) -> void:
	var container: Variant = ai.get("container")
	if container == null or not is_instance_valid(container):
		return
	_set_container_collision(container, true)
	container.process_mode = Node.PROCESS_MODE_INHERIT
	if container is Node3D:
		container.show()

func _on_door_ready() -> void:
	if not _is_online_client():
		return
	var door := _library._caller as Node3D
	if door == null:
		return
	_library.skip_super()
	door.set("animationTime", 0.0)
	door.set("defaultPosition", door.position)
	door.set("defaultRotation", door.rotation_degrees)
	door.set("locked", door.get("key") != null)
	_register_door(door)
	if not _door_snapshot_requested:
		_door_snapshot_requested = true
		_session.request_door_snapshot()

func _on_door_ready_post() -> void:
	if _session == null or not _session.is_online() or not _session.multiplayer.is_server():
		return
	var door := _library._caller as Node3D
	if door != null:
		_register_door(door)
		_publish_door_state(true)

func _on_door_interact() -> void:
	if not _is_online_client():
		return
	_library.skip_super()
	var door := _library._caller as Node3D
	if door == null:
		return
	var entity_id := _register_door(door)
	if _pending_door_keys.has(entity_id):
		return
	var key := ""
	var expected: Variant = door.get("key")
	var item: Node = null
	if bool(door.get("locked")) and expected != null:
		key = String(expected.get("file"))
		item = _find_inventory_item(key)
		if item == null:
			return
	_pending_door_keys[entity_id] = item
	_session.request_door_interaction(entity_id, key)

func _on_door_interact_post() -> void:
	if _session != null and _session.is_online() and _session.multiplayer.is_server():
		_publish_door_state(true)

func _register_door(door: Node3D) -> String:
	if door.has_meta("coop_door_id"):
		return String(door.get_meta("coop_door_id"))
	var scene := get_tree().current_scene
	var relative := String(scene.get_path_to(door)) if scene != null else String(door.get_path())
	var entity_id := "D:%s" % relative.sha256_text().left(20)
	door.set_meta("coop_door_id", entity_id)
	_doors[entity_id] = door
	if _pending_door_states.has(entity_id):
		_apply_door_state(door, _pending_door_states[entity_id])
		_pending_door_states.erase(entity_id)
	return entity_id

func _door_state(door: Node3D) -> Dictionary:
	return {
		"id": _register_door(door),
		"open": bool(door.get("isOpen")),
		"locked": bool(door.get("locked")),
		"jammed": bool(door.get("jammed")),
	}

func _publish_door_state(force := false) -> void:
	if _session == null or not _session.multiplayer.is_server():
		return
	var map_name := _current_map()
	if not Protocol.is_valid_scene(map_name):
		return
	var states: Array[Dictionary] = []
	for entity_id in _doors.keys():
		var door := _cached_node(_doors, String(entity_id))
		if door != null:
			states.append(_door_state(door))
	states.sort_custom(func(a: Dictionary, b: Dictionary): return String(a.id) < String(b.id))
	var digest := JSON.stringify(states, "", true).sha256_text()
	if not force and digest == _door_digest:
		return
	_door_digest = digest
	_door_revision += 1
	_session.publish_door_state(map_name, _door_revision, states)

func _on_door_state_received(map_name: String, _revision: int, states: Array) -> void:
	if _session.multiplayer.is_server():
		return
	for raw in states:
		if not raw is Dictionary or not Protocol.valid_entity_id(raw.get("id")):
			continue
		var state: Dictionary = raw
		if typeof(state.get("open")) != TYPE_BOOL or typeof(state.get("locked")) != TYPE_BOOL or typeof(state.get("jammed")) != TYPE_BOOL:
			continue
		var entity_id := String(state.id)
		var door := _cached_node(_doors, entity_id)
		if door == null or map_name != _current_map():
			_pending_door_states[entity_id] = state.duplicate(true)
		else:
			_apply_door_state(door, state)

func _apply_door_state(door: Node3D, state: Dictionary) -> void:
	var changed := bool(door.get("isOpen")) != bool(state.open)
	door.set("isOpen", bool(state.open))
	door.set("locked", bool(state.locked))
	door.set("jammed", bool(state.jammed))
	if changed:
		door.set("animationTime", 4.0)
		door.set("handleMoving", true)
		var angle: Vector3 = door.get("openAngle")
		door.set("handleTarget", Vector3(0, 0, -45 if angle.y > 0.0 else 45))
		if door.has_method("PlayDoor"):
			door.call("PlayDoor")

func _on_door_interaction_requested(source_peer: int, entity_id: String, supplied_key: String) -> void:
	if not _session.multiplayer.is_server():
		return
	var door := _cached_node(_doors, entity_id)
	var pose: Dictionary = _player_states.get(source_peer, {})
	if door == null or pose.is_empty() or bool(pose.get("downed", false)) or String(pose.get("map", "")) != _current_map() or Vector3(pose.position).distance_to(door.global_position) > 5.0:
		_session.answer_door_interaction(source_peer, entity_id, false, false)
		return
	if bool(door.get("jammed")) or bool(door.get("isOccupied")):
		_session.answer_door_interaction(source_peer, entity_id, false, false)
		return
	var expected: Variant = door.get("key")
	if bool(door.get("locked")) and expected != null:
		if supplied_key != String(expected.get("file")):
			_session.answer_door_interaction(source_peer, entity_id, false, false)
			return
		door.set("locked", false)
		var linked: Variant = door.get("linked")
		if linked != null:
			linked.set("locked", false)
		if door.has_method("PlayUnlock"):
			door.call("PlayUnlock")
		_session.answer_door_interaction(source_peer, entity_id, true, true)
	else:
		door.set("isOpen", not bool(door.get("isOpen")))
		door.set("animationTime", 4.0)
		door.set("handleMoving", true)
		var angle: Vector3 = door.get("openAngle")
		door.set("handleTarget", Vector3(0, 0, -45 if angle.y > 0.0 else 45))
		if door.has_method("PlayDoor"):
			door.call("PlayDoor")
		_session.answer_door_interaction(source_peer, entity_id, true, false)
	_publish_door_state(true)

func _on_door_interaction_result(entity_id: String, accepted: bool, consume_key: bool) -> void:
	var item: Variant = _pending_door_keys.get(entity_id)
	_pending_door_keys.erase(entity_id)
	if not accepted or not consume_key or not is_instance_valid(item):
		return
	var grid: Variant = item.get_parent()
	if grid != null and grid.has_method("Pick"):
		grid.call("Pick", item)
	item.queue_free()

func _on_door_snapshot_requested(_source_peer: int) -> void:
	if _session.multiplayer.is_server():
		_publish_door_state(true)

func _scan_shared_world() -> void:
	var scene := get_tree().current_scene
	if scene == null:
		return
	var stack: Array[Node] = [scene]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is Node3D and _shared_kind(node) != "":
			_register_shared(node)
		stack.append_array(node.get_children())

func _shared_kind(node: Node) -> String:
	var script: Script = node.get_script()
	return String(SHARED_WORLD_SCRIPTS.get(script.resource_path, "")) if script != null else ""

func _register_shared(node: Node3D) -> String:
	if node.has_meta("coop_shared_id"):
		var existing := String(node.get_meta("coop_shared_id"))
		_shared_nodes[existing] = node
		return existing
	var scene := get_tree().current_scene
	var relative := String(scene.get_path_to(node)) if scene != null else String(node.get_path())
	var entity_id := "W:%s" % (String(_shared_kind(node)) + ":" + relative).sha256_text().left(20)
	node.set_meta("coop_shared_id", entity_id)
	_shared_nodes[entity_id] = node
	return entity_id

func _shared_state(node: Node3D) -> Dictionary:
	return {"id": _register_shared(node), "active": bool(node.get("active"))}

func _publish_shared_world(force := false) -> void:
	if _session == null or not _session.multiplayer.is_server():
		return
	var map_name := _current_map()
	if not Protocol.is_valid_scene(map_name):
		return
	_scan_shared_world()
	var states: Array[Dictionary] = []
	for raw_entity_id in _shared_nodes.keys():
		var node := _cached_node(_shared_nodes, String(raw_entity_id))
		if node != null:
			states.append(_shared_state(node))
	states.sort_custom(func(a: Dictionary, b: Dictionary): return String(a.id) < String(b.id))
	var digest := JSON.stringify(states, "", true).sha256_text()
	if not force and digest == _shared_digest:
		return
	_shared_digest = digest
	_shared_revision += 1
	_session.publish_shared_world_state(map_name, _shared_revision, states)

func _on_shared_world_state_received(map_name: String, _revision: int, states: Array) -> void:
	if _session.multiplayer.is_server():
		return
	for raw in states:
		if not raw is Dictionary or not Protocol.valid_entity_id(raw.get("id")) or typeof(raw.get("active")) != TYPE_BOOL:
			continue
		var state: Dictionary = raw
		var entity_id := String(state.id)
		var node := _cached_node(_shared_nodes, entity_id)
		if node == null or map_name != _current_map():
			_pending_shared_states[entity_id] = state.duplicate(true)
		else:
			_apply_shared_state(node, state, node.has_meta("coop_shared_seen"))
			node.set_meta("coop_shared_seen", true)

func _on_shared_interact() -> void:
	if _session == null or not _session.is_online():
		return
	var node := _library._caller as Node3D
	if node == null or _shared_kind(node).is_empty():
		return
	var entity_id := _register_shared(node)
	if node.has_meta("coop_shared_authorized"):
		node.remove_meta("coop_shared_authorized")
		return
	if _session.multiplayer.is_server():
		return
	_library.skip_super()
	var has_required_item := true
	if _shared_kind(node) == "fire" and not bool(node.get("active")):
		has_required_item = bool(node.call("MatchCheck")) if node.has_method("MatchCheck") else false
	_session.request_shared_interaction(entity_id, has_required_item)

func _on_shared_interact_post() -> void:
	if _session != null and _session.is_online() and _session.multiplayer.is_server():
		var node := _library._caller as Node3D
		if node != null:
			_register_shared(node)
			_publish_shared_world()

func _on_shared_interaction_requested(source_peer: int, entity_id: String, has_required_item: bool) -> void:
	if not _session.multiplayer.is_server():
		return
	var node := _cached_node(_shared_nodes, entity_id)
	var source: Dictionary = _player_states.get(source_peer, {})
	if node == null or source.is_empty() or bool(source.get("downed", false)) or String(source.get("map", "")) != _current_map() or Vector3(source.position).distance_to(node.global_position) > 5.0:
		_session.answer_shared_interaction(source_peer, entity_id, false, false, "Move closer to use it")
		return
	var needs_item := _shared_kind(node) == "fire" and not bool(node.get("active"))
	if needs_item and not has_required_item:
		_session.answer_shared_interaction(source_peer, entity_id, false, false, "Equip matches first")
		return
	_apply_shared_state(node, {"active": not bool(node.get("active"))}, true)
	_publish_shared_world()
	_session.answer_shared_interaction(source_peer, entity_id, true, needs_item)

func _on_shared_interaction_result(entity_id: String, accepted: bool, consume_required_item: bool, detail: String) -> void:
	if not accepted:
		_owner_api.call("show_gameplay_status", detail if not detail.is_empty() else "Interaction rejected", true)
		return
	if not consume_required_item:
		return
	var node := _cached_node(_shared_nodes, entity_id)
	if node != null and node.has_method("ConsumeMatch"):
		node.call("ConsumeMatch")

func _on_shared_snapshot_requested(_source_peer: int) -> void:
	if _session.multiplayer.is_server():
		_publish_shared_world(true)

func _apply_shared_state(node: Node3D, state: Dictionary, play_audio: bool) -> void:
	var desired := bool(state.get("active", false))
	var current := bool(node.get("active"))
	if current == desired:
		return
	var kind := _shared_kind(node)
	if kind == "radio":
		node.set_meta("coop_shared_authorized", true)
		node.call("Interact")
		return
	node.set("active", desired)
	if node.has_method("Activate") and desired:
		node.call("Activate")
	elif node.has_method("Deactivate") and not desired:
		node.call("Deactivate")
	if not play_audio:
		return
	if kind == "fire":
		if desired and node.has_method("IgniteAudio"):
			node.call("IgniteAudio")
		elif not desired and node.has_method("ExtinguishAudio"):
			node.call("ExtinguishAudio")
	elif kind == "switch" and node.has_method("PlaySwitch"):
		node.call("PlaySwitch")
	elif kind == "television" and node.has_method("PlayToggle"):
		node.call("PlayToggle")

func _find_inventory_item(key: String) -> Node:
	var interface := get_node_or_null("/root/Map/Core/UI/Interface")
	var grid: Variant = interface.get("inventoryGrid") if interface != null else null
	if grid == null:
		return null
	for item in grid.get_children():
		var slot: Variant = item.get("slotData")
		var data: Variant = slot.get("itemData") if slot != null else null
		if data != null and String(data.get("file")) == key and not item.is_queued_for_deletion():
			return item
	return null

func _check_all_players_downed() -> void:
	if _game_over_sent or _session == null or not _session.multiplayer.is_server() or String(_session.get("_run_id")).is_empty():
		return
	if not all_players_downed(_session.roster, _player_states):
		return
	_game_over_sent = true
	_session.publish_game_over("Everyone is down")

static func all_players_downed(roster: Dictionary, states: Dictionary) -> bool:
	if roster.is_empty():
		return false
	for raw_peer_id in roster.keys():
		var peer_id := int(raw_peer_id)
		var state: Dictionary = states.get(peer_id, {})
		if state.is_empty() or not bool(state.get("downed", false)):
			return false
	return true

func _medical_options() -> Array:
	var interface: Node = get_node_or_null("/root/Map/Core/UI/Interface")
	if interface == null:
		return []
	var grid: Variant = interface.get("inventoryGrid")
	if grid == null:
		return []
	var options: Array = []
	for item in grid.get_children():
		var slot: Variant = item.get("slotData")
		var data: Variant = slot.get("itemData") if slot != null else null
		if data != null and not item.is_queued_for_deletion():
			var hp := MedicalRules.revive_health(String(data.get("file")))
			if hp > 0.0:
				options.append({"item": item, "label": String(data.get("name")), "health": hp})
	return options

func _consume_medical_item(kind: String) -> void:
	if not is_instance_valid(_medical_item) or _medical_item.is_queued_for_deletion():
		return
	var item: Node = _medical_item
	var slot: Variant = item.get("slotData")
	if String(slot.get("itemData").get("file")) != kind:
		return
	if int(slot.get("amount")) > 1:
		slot.set("amount", int(slot.get("amount")) - 1)
		if item.has_method("UpdateDetails"):
			item.call("UpdateDetails")
	else:
		item.get_parent().call("Pick", item)
		item.queue_free()
	var interface := get_node_or_null("/root/Map/Core/UI/Interface")
	if interface != null:
		interface.call("UpdateStats", false)

func _nearest_live_player(origin: Vector3) -> Dictionary:
	var best: Dictionary = {}
	var distance: float = INF
	var map_name: String = _current_map()
	for peer_id in _player_states:
		var state: Dictionary = _player_states[peer_id]
		if bool(state.get("downed", false)) or String(state.get("map", "")) != map_name:
			continue
		var candidate_distance: float = origin.distance_to(Vector3(state.position))
		if candidate_distance < distance:
			distance = candidate_distance
			best = state.duplicate(true)
			best["peer"] = int(peer_id)
	return best

func _valid_ai_entity(state: Dictionary) -> bool:
	if not BonePose.valid(state.get("bones")):
		return false
	var weapon: Variant = state.get("weapon", "")
	if typeof(weapon) != TYPE_STRING or (not String(weapon).is_empty() and not Protocol.valid_weapon_key(String(weapon))):
		return false
	if not state.get("weapon_transform", Transform3D.IDENTITY) is Transform3D or not Transform3D(state.get("weapon_transform")).is_finite():
		return false
	if not state.get("attachments", []) is Array or state.get("attachments", []).size() > 24:
		return false
	for key in state.get("attachments", []):
		if not key is String or not Protocol.valid_weapon_key(key):
			return false
	if typeof(state.get("shots", 0)) != TYPE_INT or int(state.get("shots", 0)) < 0:
		return false
	if not Protocol.valid_entity_id(state.get("id", null)):
		return false
	if typeof(state.get("active", null)) != TYPE_BOOL or typeof(state.get("dead", null)) != TYPE_BOOL:
		return false
	if typeof(state.get("position", null)) != TYPE_VECTOR3 or not Vector3(state.position).is_finite():
		return false
	if typeof(state.get("velocity", null)) != TYPE_VECTOR3 or not Vector3(state.velocity).is_finite():
		return false
	if (typeof(state.get("yaw", null)) != TYPE_FLOAT and typeof(state.get("yaw", null)) != TYPE_INT) or not is_finite(float(state.yaw)):
		return false
	if (typeof(state.get("health", null)) != TYPE_FLOAT and typeof(state.get("health", null)) != TYPE_INT) or not is_finite(float(state.health)):
		return false
	return typeof(state.get("state", null)) == TYPE_INT

func _valid_loot_entity(state: Dictionary) -> bool:
	if not Protocol.valid_entity_id(state.get("id", null)):
		return false
	if typeof(state.get("position", null)) != TYPE_VECTOR3 or not Vector3(state.position).is_finite():
		return false
	return typeof(state.get("rotation", null)) == TYPE_VECTOR3 and Vector3(state.rotation).is_finite()

func _loot_root() -> Node3D:
	var scene: Node = get_tree().current_scene
	var root := scene.get_node_or_null("RTVCoopLoot") as Node3D if scene != null else null
	if root == null:
		root = Node3D.new()
		root.name = "RTVCoopLoot"
		(scene if scene != null else self).add_child(root)
	return root

func _peer_name(peer_id: int) -> String:
	var entry: Dictionary = _session.roster.get(peer_id, {})
	return String(entry.get("name", "Player %d" % peer_id))

func _current_map() -> String:
	return String(_owner_api.call("current_map_name"))

func _is_online_client() -> bool:
	return _session != null and _session.is_online() and not _session.multiplayer.is_server()

func _cached_node(index: Dictionary, key: String) -> Node3D:
	var value: Variant = index.get(key)
	return value as Node3D if is_instance_valid(value) else null
