extends Node

const Codec = preload("res://RTVCoop8/gameplay/SlotCodec.gd")
var session: Node
var api: Node
var library: Variant
var traders: Dictionary = {}
var holders: Dictionary = {}
var active_id := ""

func _ready() -> void:
	session.roster_changed.connect(_roster_changed)

func _roster_changed(roster: Dictionary) -> void:
	if not multiplayer.is_server(): return
	for id in holders.keys():
		if not roster.has(int(holders[id])):
			holders.erase(id)
			var trader: Variant = traders.get(id)
			if is_instance_valid(trader) and session.is_online():
				_state.rpc(id, 0, _encode(trader), 0)

func register_hooks(value: Variant) -> void:
	library = value
	library.hook("trader-interact", _interact, 100)
	library.hook("trader-updatetooltip-post", _tooltip, 800)
	library.hook("trader-createsupply", _supply, 100)
	library.hook("interface-close-post", _closed, 800)

func busy() -> bool:
	return not active_id.is_empty() or (session.multiplayer.is_server() and not holders.is_empty())

func reset_scene() -> void:
	traders.clear()
	holders.clear()
	active_id = ""

func _id(trader: Node) -> String:
	var id := String(trader.get_path())
	traders[id] = trader
	return id

func _tooltip() -> void:
	if not session.is_online(): return
	var id := _id(library._caller)
	if int(holders.get(id, 0)) not in [0, multiplayer.get_unique_id()]:
		var data: Resource = load("res://Resources/GameData.tres")
		data.set("tooltip", "Occupied")

func _supply() -> void:
	if not session.is_online(): return
	if not multiplayer.is_server() or holders.has(_id(library._caller)):
		library.skip_super()

func _interact() -> void:
	if not session.is_online(): return
	var trader := library._caller as Node3D
	var id := _id(trader)
	if trader.has_meta("coop_trade_allowed"):
		trader.remove_meta("coop_trade_allowed")
		active_id = id
		return
	library.skip_super()
	if multiplayer.is_server():
		_request_open(id)
	else:
		_request_open.rpc_id(1, id)

@rpc("any_peer", "call_remote", "reliable", 0)
func _request_open(id: String) -> void:
	if not multiplayer.is_server() or id.length() > 256: return
	var peer := multiplayer.get_remote_sender_id()
	if peer == 0: peer = 1
	if not session.roster.has(peer): return
	var trader := get_node_or_null(NodePath(id)) as Node3D
	if trader == null or not trader.has_method("CreateSupply") or not id.begins_with("/root/Map/"): return
	var pose: Dictionary = session.latest_pose(peer)
	if pose.is_empty() or bool(pose.get("downed", false)) or String(pose.get("map", "")) != String(api.call("current_map_name")) or Vector3(pose.position).distance_to(trader.global_position) > 5.0: return
	_id(trader)
	for held_id in holders:
		if int(holders[held_id]) == peer and held_id != id:
			return
	if holders.has(id):
		_state.rpc(id, int(holders[id]), _encode(trader), 0)
		return
	holders[id] = peer
	_state.rpc(id, peer, _encode(trader), peer)
	_state(id, peer, _encode(trader), peer)

func _encode(trader: Node) -> Array:
	var result: Array = []
	for slot in trader.get("supply"):
		result.append(Codec.encode(slot))
	return result

@rpc("authority", "call_remote", "reliable", 0)
func _state(id: String, holder: int, slots: Array, open_peer: int) -> void:
	var trader := get_node_or_null(NodePath(id))
	if trader == null or not trader.has_method("CreateSupply"): return
	_id(trader)
	if holder == 0: holders.erase(id)
	else: holders[id] = holder
	if not multiplayer.is_server() and not (active_id == id and holder == multiplayer.get_unique_id()):
		var supply: Array = trader.get("supply")
		supply.clear()
		for raw in slots:
			var slot: Variant = Codec.decode(raw)
			if slot != null: supply.append(slot)
	if open_peer == multiplayer.get_unique_id():
		trader.set_meta("coop_trade_allowed", true)
		trader.call("Interact")

func _closed() -> void:
	if active_id.is_empty(): return
	var trader: Variant = traders.get(active_id)
	if not is_instance_valid(trader): return
	if multiplayer.is_server():
		_commit(active_id, _encode(trader))
	else:
		_commit.rpc_id(1, active_id, _encode(trader))

@rpc("any_peer", "call_remote", "reliable", 0)
func _commit(id: String, slots: Array) -> void:
	if not multiplayer.is_server(): return
	var peer := multiplayer.get_remote_sender_id()
	if peer == 0: peer = 1
	if int(holders.get(id, 0)) != peer or slots.size() > 128: return
	var decoded: Array = []
	for raw in slots:
		if not raw is Dictionary or not Codec.is_valid(raw): return
		var slot: Variant = Codec.decode(raw)
		if slot == null: return
		decoded.append(slot)
	var trader: Variant = traders.get(id)
	if not is_instance_valid(trader): return
	var supply: Array = trader.get("supply")
	supply.clear()
	supply.append_array(decoded)
	holders.erase(id)
	_state.rpc(id, 0, slots, 0)
	_state(id, 0, slots, 0)
	if peer == 1: active_id = ""
	else: _committed.rpc_id(peer, id)

@rpc("authority", "call_remote", "reliable", 0)
func _committed(id: String) -> void:
	if active_id == id: active_id = ""
