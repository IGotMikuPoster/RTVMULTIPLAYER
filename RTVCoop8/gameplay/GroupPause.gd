extends Node

var session: Node
var api: Node
var votes: Dictionary = {}
var active := false
var revision := 0
var count := 0
var total := 0
var label: Label
var _local_intent := false
var _was_online := false

func configure(coop_session: Node, owner_api: Node) -> void:
	session = coop_session
	api = owner_api
	process_mode = Node.PROCESS_MODE_ALWAYS
	session.roster_changed.connect(_on_roster_changed)
	session.player_state_received.connect(_on_player_state_received)

func _ready() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 126
	add_child(layer)
	label = Label.new()
	label.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	label.offset_top = 8
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 16)
	label.add_theme_color_override("font_color", Color(0.82, 0.90, 0.84))
	label.add_theme_color_override("font_shadow_color", Color.BLACK)
	label.add_theme_constant_override("shadow_offset_x", 1)
	label.add_theme_constant_override("shadow_offset_y", 1)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(label)

func _process(_delta: float) -> void:
	if session == null or api == null:
		return
	var online: bool = session.is_online()
	if not online:
		if _was_online:
			_clear_local()
		_was_online = false
		return
	_was_online = true
	var data: Variant = api.get("_game_data")
	var wants_pause := data != null and bool(data.get("settings"))
	if wants_pause != _local_intent:
		_local_intent = wants_pause
		if session.multiplayer.is_server():
			_accept_vote(1, wants_pause)
		else:
			_vote.rpc_id(1, wants_pause)

func cancel_group() -> void:
	if session != null and session.is_online():
		if session.multiplayer.is_server():
			votes.clear()
			_publish()
		elif _local_intent:
			_vote.rpc_id(1, false)
	_local_intent = false
	active = false
	count = 0
	if label != null:
		label.text = ""

@rpc("any_peer", "call_remote", "reliable", 0)
func _vote(wants_pause: bool) -> void:
	if session == null or not session.multiplayer.is_server():
		return
	var peer_id := multiplayer.get_remote_sender_id()
	if not session.roster.has(peer_id):
		return
	_accept_vote(peer_id, wants_pause)

func _accept_vote(peer_id: int, wants_pause: bool) -> void:
	if not session.multiplayer.is_server() or not session.roster.has(peer_id):
		return
	if wants_pause and not _living_members().has(peer_id):
		return
	if wants_pause:
		votes[peer_id] = true
	else:
		votes.erase(peer_id)
	_publish()

func _publish() -> void:
	if not session.multiplayer.is_server():
		return
	var members := _living_members()
	for raw_peer_id in votes.keys():
		if not members.has(int(raw_peer_id)):
			votes.erase(raw_peer_id)
	var next_count := 0
	for peer_id in members:
		if votes.has(peer_id):
			next_count += 1
	revision += 1
	var next_active := not members.is_empty() and next_count == members.size()
	_state.rpc(revision, next_count, members.size(), next_active)
	_state(revision, next_count, members.size(), next_active)

@rpc("authority", "call_remote", "reliable", 0)
func _state(next_revision: int, next_count: int, next_total: int, next_active: bool) -> void:
	if next_revision < revision or next_count < 0 or next_total < 0 or next_total > 8 or next_count > next_total:
		return
	revision = next_revision
	count = next_count
	total = next_total
	active = next_active and next_total > 0 and next_count == next_total
	if label == null:
		return
	if count <= 0:
		label.text = ""
	elif active:
		label.text = "Game paused: %d/%d" % [count, total]
	else:
		label.text = "Waiting to pause: %d/%d" % [count, total]

func _living_members() -> Array[int]:
	var members: Array[int] = []
	for raw_peer_id in session.roster.keys():
		var peer_id := int(raw_peer_id)
		var state: Dictionary = session.authoritative_player_state(peer_id)
		if not bool(state.get("downed", false)):
			members.append(peer_id)
	members.sort()
	return members

func _on_roster_changed(roster: Dictionary) -> void:
	if roster.is_empty():
		_clear_local()
	elif session.multiplayer.is_server():
		_publish()

func _on_player_state_received(_peer_id: int, _state_value: Dictionary) -> void:
	if session.multiplayer.is_server() and not votes.is_empty():
		_publish()

func _clear_local() -> void:
	votes.clear()
	active = false
	revision = 0
	count = 0
	total = 0
	_local_intent = false
	if label != null:
		label.text = ""
