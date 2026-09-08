extends Node

const Protocol = preload("res://RTVCoop8/core/CoopProtocol.gd")
const MarkerScript = preload("res://RTVCoop8/presentation/SquadMarker.gd")

var session: Node
var api: Node
var _ping_serial := 0
var _ping_markers: Dictionary = {}
var _rescue_markers: Dictionary = {}
var _rescue_accumulator := 0.0

func configure(coop_session: Node, owner_api: Node) -> void:
	session = coop_session
	api = owner_api
	process_mode = Node.PROCESS_MODE_ALWAYS
	if not InputMap.has_action("rtv_coop_ping"):
		InputMap.add_action("rtv_coop_ping")
		var key := InputEventKey.new()
		key.physical_keycode = KEY_T
		InputMap.action_add_event("rtv_coop_ping", key)
	if not session.ping_requested.is_connected(_on_ping_requested):
		session.ping_requested.connect(_on_ping_requested)
	if not session.ping_received.is_connected(_on_ping_received):
		session.ping_received.connect(_on_ping_received)
	if not session.roster_changed.is_connected(_on_roster_changed):
		session.roster_changed.connect(_on_roster_changed)

func _process(delta: float) -> void:
	var now := Time.get_ticks_msec()
	for raw_peer_id in _ping_markers.keys():
		var marker: Node = _ping_markers[raw_peer_id]
		if not is_instance_valid(marker) or marker.expired(now):
			if is_instance_valid(marker):
				marker.queue_free()
			_ping_markers.erase(raw_peer_id)
	_rescue_accumulator += delta
	if _rescue_accumulator >= 0.25:
		_rescue_accumulator = fmod(_rescue_accumulator, 0.25)
		_refresh_rescue_markers()

func _input(event: InputEvent) -> void:
	if is_ping_key_event(event):
		call_deferred("_try_local_ping")

static func is_ping_key_event(event: InputEvent) -> bool:
	if not event is InputEventKey:
		return false
	var key_event := event as InputEventKey
	return key_event.pressed and not key_event.echo and (key_event.keycode == KEY_T or key_event.physical_keycode == KEY_T)

func reset_scene() -> void:
	_clear_markers(_ping_markers)
	_clear_markers(_rescue_markers)

func _try_local_ping() -> void:
	if session == null or api == null or not session.is_online() or api.scene_is_loading():
		return
	if bool(api.get("_local_downed")) or _typing_or_blocked():
		return
	var map_name := String(api.call("current_map_name"))
	if not Protocol.is_valid_scene(map_name):
		return
	var hit := _aim_hit()
	if hit.is_empty():
		api.call("show_gameplay_status", "No surface in range")
		return
	session.request_ping(map_name, Vector3(hit.position))

func _typing_or_blocked() -> bool:
	var focus := get_viewport().gui_get_focus_owner()
	if (focus is LineEdit or focus is TextEdit) and focus.is_visible_in_tree():
		return true
	var game_data: Variant = api.get("_game_data")
	return game_data != null and (bool(game_data.get("settings")) or bool(game_data.get("interface")) or bool(game_data.get("isCaching")) or bool(game_data.get("isTransitioning")))

func _aim_hit() -> Dictionary:
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return {}
	var screen_center := get_viewport().get_visible_rect().size * 0.5
	var origin := camera.project_ray_origin(screen_center)
	var destination := origin + camera.project_ray_normal(screen_center) * Protocol.PING_DISTANCE
	var query := PhysicsRayQueryParameters3D.create(origin, destination)
	query.collide_with_areas = true
	var local_player: Variant = api.get("_local_player")
	if local_player is CollisionObject3D:
		query.exclude = [(local_player as CollisionObject3D).get_rid()]
	return camera.get_world_3d().direct_space_state.intersect_ray(query)

func _on_ping_requested(source_peer: int, map_name: String, position: Vector3) -> void:
	if not session.multiplayer.is_server() or not session.roster.has(source_peer):
		return
	var state: Dictionary = session.authoritative_player_state(source_peer)
	if state.is_empty() or bool(state.get("downed", true)) or String(state.get("map", "")) != map_name:
		return
	if Vector3(state.get("position", Vector3.ZERO)).distance_to(position) > Protocol.PING_DISTANCE + 3.0:
		return
	_ping_serial += 1
	session.publish_ping({"peer": source_peer, "serial": _ping_serial, "map": map_name, "position": position})

func _on_ping_received(value: Dictionary) -> void:
	if String(value.get("map", "")) != String(api.call("current_map_name")):
		return
	var peer_id := int(value.get("peer", 0))
	var entry: Dictionary = session.roster.get(peer_id, {})
	var title := "▲ %s" % String(entry.get("name", "Player"))
	_replace_marker(_ping_markers, peer_id, title, Color(0.93, 0.82, 0.33), Vector3(value.position), Protocol.PING_LIFETIME_MS)

func _refresh_rescue_markers() -> void:
	if session == null or api == null or not session.is_online() or api.scene_is_loading():
		_clear_markers(_rescue_markers)
		return
	var local_id := session.multiplayer.get_unique_id()
	var local_map := String(api.call("current_map_name"))
	var wanted: Dictionary = {}
	for raw_peer_id in session.roster.keys():
		var peer_id := int(raw_peer_id)
		if peer_id == local_id:
			continue
		var state: Dictionary = session.authoritative_player_state(peer_id)
		if state.is_empty() or not bool(state.get("downed", false)) or String(state.get("map", "")) != local_map:
			continue
		wanted[peer_id] = true
		var entry: Dictionary = session.roster.get(peer_id, {})
		var title := "▼ %s" % String(entry.get("name", "Player"))
		if not _rescue_markers.has(peer_id) or not is_instance_valid(_rescue_markers[peer_id]):
			_replace_marker(_rescue_markers, peer_id, title, Color(0.94, 0.28, 0.24), Vector3(state.position), 0)
		else:
			var marker: Node3D = _rescue_markers[peer_id]
			marker.global_position = Vector3(state.position) + Vector3.UP * 0.25
			marker.set_viewer(api.get("_local_player"))
	for raw_peer_id in _rescue_markers.keys():
		if not wanted.has(raw_peer_id):
			var marker: Node = _rescue_markers[raw_peer_id]
			if is_instance_valid(marker):
				marker.queue_free()
			_rescue_markers.erase(raw_peer_id)

func _replace_marker(collection: Dictionary, peer_id: int, title: String, color: Color, position: Vector3, lifetime_ms: int) -> void:
	var old: Variant = collection.get(peer_id)
	if is_instance_valid(old):
		old.queue_free()
	var marker := MarkerScript.new()
	var parent := get_tree().current_scene
	if parent == null:
		parent = api
	parent.add_child(marker)
	marker.configure(title, color, position, api.get("_local_player"), lifetime_ms)
	collection[peer_id] = marker

func _on_roster_changed(roster: Dictionary) -> void:
	for collection in [_ping_markers, _rescue_markers]:
		for raw_peer_id in collection.keys():
			if not roster.has(raw_peer_id):
				var marker: Node = collection[raw_peer_id]
				if is_instance_valid(marker):
					marker.queue_free()
				collection.erase(raw_peer_id)

func _clear_markers(collection: Dictionary) -> void:
	for marker in collection.values():
		if is_instance_valid(marker):
			marker.queue_free()
	collection.clear()
