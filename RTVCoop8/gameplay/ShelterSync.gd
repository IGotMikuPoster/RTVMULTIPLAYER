extends Node

const Codec = preload("res://RTVCoop8/gameplay/SlotCodec.gd")
const Protocol = preload("res://RTVCoop8/core/CoopProtocol.gd")
var session: Node
var api: Node
var library: Variant
var nodes: Dictionary = {}
var serial := 0
var holder := 0
var target_id := ""
var pending: Node
var pending_method := ""
var local_edit := false
var accumulator := 0.0
var map_name := ""
var initialized := false
var pending_since := 0
var original_transform := Transform3D.IDENTITY
var layout_digest := 0

func active() -> bool:
	return session.is_online() and api._game_data != null and bool(api._game_data.get("shelter"))

func busy() -> bool:
	return holder != 0 or pending != null or local_edit

func _ready() -> void:
	session.roster_changed.connect(_roster)

func register_hooks(value: Variant) -> void:
	library = value
	library.hook("loader-loadshelter", _load_shelter, 80)
	library.hook("loader-saveshelter", _save_shelter, 80)
	library.hook("interface-contextplace", _place, 80)
	library.hook("furniture-startmove", _move, 80)
	library.hook("furniture-resetmove-post", _placed, 800)
	library.hook("furniture-catalog", _catalog, 80)

func _load_shelter(_name: String) -> void:
	if session.is_online() and not multiplayer.is_server(): library.skip_super()

func _save_shelter(_name: String) -> void:
	if session.is_online() and not multiplayer.is_server(): library.skip_super()

func reset_scene() -> void:
	nodes.clear()
	holder = 0
	target_id = ""
	pending = null
	local_edit = false
	initialized = false
	map_name = ""
	layout_digest = 0

func _roster(roster: Dictionary) -> void:
	if session.is_online() and multiplayer.is_server() and holder != 0 and not roster.has(holder):
		holder = 0
		target_id = ""

func _components() -> Array[Node]:
	var result: Array[Node] = []
	var seen: Dictionary = {}
	for collider in get_tree().get_nodes_in_group("Furniture"):
		var root_node: Node = collider.owner
		if not is_instance_valid(root_node) or seen.has(root_node): continue
		seen[root_node] = true
		for child in root_node.get_children():
			if child.has_method("StartMove") and child.has_method("Catalog"):
				result.append(child)
	return result

func _scan() -> void:
	for component in _components():
		var object: Node3D = component.owner
		if object.is_queued_for_deletion() or object.global_position.y < -50.0 or bool(component.get("isMoving")): continue
		if not object.has_meta("coop_furniture_id"):
			serial += 1
			object.set_meta("coop_furniture_id", "S%d" % serial)
		var id := String(object.get_meta("coop_furniture_id"))
		nodes[id] = object
		if object.has_method("Storage"):
			object.set_meta("coop_container_id", "C:" + id)
			api._gameplay._register_container(object)

func _process(delta: float) -> void:
	if not active() or api.scene_is_loading(): return
	accumulator += delta
	if accumulator < 1.0: return
	accumulator = 0.0
	map_name = api.current_map_name()
	if multiplayer.is_server():
		_scan()
		if holder == 0: _publish()
	elif not initialized:
		_request_snapshot.rpc_id(1, map_name)
	if pending != null and Time.get_ticks_msec() - pending_since > 10000:
		api.show_gameplay_status("Waiting for the host to finish the furniture request…", true)
		pending_since = Time.get_ticks_msec()

func _publish(force := false) -> void:
	map_name = api.current_map_name()
	var entries: Array = []
	for id in nodes.keys():
		var object: Variant = nodes[id]
		if not is_instance_valid(object) or object.is_queued_for_deletion():
			nodes.erase(id)
			continue
		var component := _component(object)
		if component == null: continue
		entries.append({"id": id, "file": String(component.get("itemData").get("file")), "transform": object.transform})
	var digest := hash(entries)
	if not force and digest == layout_digest: return
	layout_digest = digest
	_snapshot.rpc(map_name, entries)
	for object in nodes.values():
		if is_instance_valid(object) and object.has_method("Storage"):
			api._gameplay._publish_container(object, true)

static func _component(object: Node) -> Node:
	for child in object.get_children():
		if child.has_method("StartMove") and child.has_method("Catalog"): return child
	return null

@rpc("any_peer", "call_remote", "reliable", 0)
func _request_snapshot(scene: String) -> void:
	if multiplayer.is_server() and session.roster.has(multiplayer.get_remote_sender_id()) and scene == api.current_map_name() and holder == 0:
		_scan()
		_publish(true)

@rpc("authority", "call_remote", "reliable", 0)
func _snapshot(scene: String, entries: Array) -> void:
	if not active() or api.scene_is_loading() or scene != api.current_map_name() or entries.size() > 512: return
	if local_edit: return
	var database := get_node_or_null("/root/Database")
	if database == null: return
	for entry in entries:
		if not valid_entry(entry): return
		if not database.get(entry.file) is PackedScene: return
	if not initialized:
		for component in _components():
			var object: Node = component.owner
			if not object.has_meta("coop_furniture_id"):
				_retire(object)
		initialized = true
	var present: Dictionary = {}
	for entry in entries:
		var id := String(entry.id)
		present[id] = true
		var object: Variant = nodes.get(id)
		if not is_instance_valid(object):
			object = database.get(entry.file).instantiate()
			object.set_meta("coop_furniture_id", id)
			object.set_meta("coop_container_id", "C:" + id)
			object.name = "SharedFurniture_" + id
			get_node("/root/Map").add_child(object)
			nodes[id] = object
		object.transform = entry.transform
	for id in nodes.keys():
		if not present.has(id):
			if is_instance_valid(nodes[id]): _retire(nodes[id])
			nodes.erase(id)

static func _retire(object: Node) -> void:
	var component := _component(object)
	if component != null:
		var hint: Variant = component.get("hint")
		if is_instance_valid(hint) and hint.get_parent() != component:
			hint.reparent(component)
	if object.get_parent() != null: object.get_parent().remove_child(object)
	object.queue_free()

static func valid_entry(entry: Variant) -> bool:
	return entry is Dictionary and entry.get("id") is String and String(entry.id).begins_with("S") and String(entry.id).length() <= 32 and Protocol.valid_weapon_key(String(entry.get("file", ""))) and entry.get("transform") is Transform3D and Transform3D(entry.transform).is_finite()

func _place() -> void:
	if not active() or not bool(api._game_data.get("decor")): return
	var ui: Node = library._caller
	if ui.has_meta("coop_edit_allowed"):
		ui.remove_meta("coop_edit_allowed")
		return
	library.skip_super()
	if ui.get("contextItem") == null or ui.get("contextGrid") != ui.get("catalogGrid"): return
	if not multiplayer.is_server() and not initialized:
		api.show_gameplay_status("Wait for the shelter to synchronize.", true)
		return
	_request_local(ui, "ContextPlace", "")

func _move() -> void:
	if not active(): return
	var component: Node = library._caller
	if local_edit: return
	library.skip_super()
	if _has_surface_items(component):
		_reset_placer()
		api.show_gameplay_status("Remove loose items sitting on this furniture before moving it.", true)
		return
	_request_local(component, "StartMove", String(component.owner.get_meta("coop_furniture_id", "")))

static func _has_surface_items(component: Node) -> bool:
	var area: Variant = component.get("parenter")
	if not is_instance_valid(area): return false
	for body in area.get_overlapping_bodies():
		if body.has_method("UpdateAttachments"): return true
	return false

func _request_local(object: Node, method: String, id: String) -> void:
	if pending != null: return
	pending = object
	pending_method = method
	pending_since = Time.get_ticks_msec()
	api._game_data.set("freeze", true)
	if multiplayer.is_server(): _request_edit(id)
	else: _request_edit.rpc_id(1, id)

@rpc("any_peer", "call_remote", "reliable", 0)
func _request_edit(id: String) -> void:
	if not multiplayer.is_server(): return
	var peer := multiplayer.get_remote_sender_id()
	if peer == 0: peer = 1
	var allowed := _can_edit(peer, id)
	if allowed:
		holder = peer
		target_id = id
		if not id.is_empty(): original_transform = nodes[id].transform
	if peer == 1: _edit_answer(allowed)
	else: _edit_answer.rpc_id(peer, allowed)

func _can_edit(peer: int, id: String) -> bool:
	if not active() or not session.roster.has(peer) or holder != 0 or api._gameplay.has_pending_transfers(true, false): return false
	var pose: Dictionary = session.latest_pose(peer)
	if pose.is_empty() or bool(pose.get("downed", false)) or String(pose.get("map", "")) != api.current_map_name(): return false
	_scan()
	if id.is_empty(): return true
	var object: Variant = nodes.get(id)
	return is_instance_valid(object) and not _has_surface_items(_component(object)) and Vector3(pose.position).distance_to(object.global_position) < 6.0

@rpc("authority", "call_remote", "reliable", 0)
func _edit_answer(allowed: bool) -> void:
	api._game_data.set("freeze", bool(api._local_downed))
	var object := pending
	pending = null
	if not allowed or not is_instance_valid(object):
		_reset_placer()
		api.show_gameplay_status("Shelter busy. Close storage and try again.", true)
		return
	if pending_method == "ContextPlace" and object.get("contextItem") == null:
		if multiplayer.is_server():
			holder = 0
			target_id = ""
		else: _release.rpc_id(1)
		return
	local_edit = true
	object.set_meta("coop_edit_allowed", true)
	object.call(pending_method)

func _reset_placer() -> void:
	var ui := get_node_or_null("/root/Map/Core/UI/Interface")
	if ui != null:
		var placer: Node = ui.get("placer")
		placer.set("placable", null)
		placer.set("furniture", null)
	api._game_data.set("isPlacing", false)

func _placed() -> void:
	if not active() or not local_edit: return
	var component: Node = library._caller
	var object: Node3D = component.owner
	var storage: Array = []
	if object.has_method("Storage"):
		for slot in object.get("storage"): storage.append(Codec.encode(slot))
	var request := {"id": String(object.get_meta("coop_furniture_id", "")), "file": String(component.get("itemData").get("file")), "transform": object.transform, "storage": storage}
	pending = object
	pending_since = Time.get_ticks_msec()
	pending_method = "finish"
	if multiplayer.is_server(): _finish_edit(request)
	else: _finish_edit.rpc_id(1, request)

@rpc("any_peer", "call_remote", "reliable", 0)
func _finish_edit(request: Dictionary) -> void:
	if not multiplayer.is_server(): return
	var peer := multiplayer.get_remote_sender_id()
	if peer == 0: peer = 1
	if holder != peer: return
	if var_to_bytes(request).size() > 262144:
		_reject_edit(peer)
		return
	var check := request.duplicate()
	check.id = "S0"
	if not valid_entry(check) or String(request.get("id", "")) != target_id:
		_reject_edit(peer)
		return
	var pose: Dictionary = session.latest_pose(peer)
	if pose.is_empty() or bool(pose.get("downed", false)) or String(pose.get("map", "")) != api.current_map_name() or Vector3(pose.position).distance_to(Transform3D(request.transform).origin) > 8.0:
		_reject_edit(peer)
		return
	var decoded: Array = []
	if not request.get("storage", []) is Array or request.get("storage", []).size() > 128:
		_reject_edit(peer)
		return
	for raw in request.get("storage", []):
		var slot: Variant = Codec.decode(raw) if raw is Dictionary else null
		if slot == null:
			_reject_edit(peer)
			return
		decoded.append(slot)
	var object: Variant = nodes.get(target_id)
	if target_id.is_empty():
		var packed: Variant = get_node("/root/Database").get(String(request.file))
		if not packed is PackedScene:
			_reject_edit(peer)
			return
		if peer == 1:
			object = pending
		else:
			object = packed.instantiate()
			if _component(object) == null:
				object.free()
				_reject_edit(peer)
				return
			get_node("/root/Map").add_child(object)
			if object.has_method("Storage"):
				api._gameplay._replace_container_slots(object, decoded, true)
	if not is_instance_valid(object): return
	object.transform = request.transform
	holder = 0
	target_id = ""
	_scan()
	if peer == 1: _finished()
	else: _finished.rpc_id(peer)
	_publish()
	_save.call_deferred()

func _save() -> void:
	if active() and multiplayer.is_server() and not busy() and not api.scene_is_loading():
		get_node("/root/Loader").call("SaveShelter", api.current_map_name())

func _reject_edit(peer: int) -> void:
	if not target_id.is_empty() and is_instance_valid(nodes.get(target_id)):
		nodes[target_id].transform = original_transform
	holder = 0
	target_id = ""
	if peer == 1: _rejected()
	else: _rejected.rpc_id(peer)
	_publish()

@rpc("authority", "call_remote", "reliable", 0)
func _rejected() -> void:
	# Return an unplaced personal item instead of discarding it on rejection.
	if is_instance_valid(pending) and not pending.has_meta("coop_furniture_id"):
		var component := _component(pending)
		if component != null:
			var storage: Variant = pending.get("storage") if pending.has_method("Storage") else null
			get_node("/root/Map/Core/UI/Interface").call("AddToCatalog", component.get("itemData"), storage)
		pending.queue_free()
	pending = null
	local_edit = false
	_reset_placer()
	api.show_gameplay_status("Furniture placement rejected; your catalog item was kept.", true)

@rpc("authority", "call_remote", "reliable", 0)
func _finished() -> void:
	if pending_method == "finish" and is_instance_valid(pending) and not pending.has_meta("coop_furniture_id"):
		pending.queue_free()
	pending = null
	local_edit = false
	api._checkpoint_pending = true

func _catalog() -> void:
	if not active(): return
	var component: Node = library._caller
	var object: Node = component.owner
	if _has_surface_items(component):
		library.skip_super()
		api.show_gameplay_status("Remove loose items sitting on this furniture before storing it.", true)
		return
	var id := String(object.get_meta("coop_furniture_id", ""))
	if id.is_empty() and local_edit:
		local_edit = false
		if multiplayer.is_server():
			holder = 0
			target_id = ""
		else: _release.rpc_id(1)
		return
	library.skip_super()
	if multiplayer.is_server(): _pack(id)
	else: _pack.rpc_id(1, id)

@rpc("any_peer", "call_remote", "reliable", 0)
func _pack(id: String) -> void:
	if not multiplayer.is_server(): return
	var peer := multiplayer.get_remote_sender_id()
	if peer == 0: peer = 1
	if holder != 0:
		if holder != peer or target_id != id: return
	elif not _can_edit(peer, id): return
	var object: Variant = nodes.get(id)
	if not is_instance_valid(object): return
	var component := _component(object)
	var storage: Array = []
	if object.has_method("Storage"):
		var source: Array = object.get("storage") if bool(object.get("storaged")) else object.get("loot")
		if source.size() > 128: return
		for slot in source:
			var encoded := Codec.encode(slot)
			if not Codec.is_valid(encoded): return
			storage.append(encoded)
	var key := String(component.get("itemData").get("file"))
	_retire(object)
	nodes.erase(id)
	holder = 0
	target_id = ""
	if peer == 1: _packed(key, storage)
	else: _packed.rpc_id(peer, key, storage)
	_publish()
	_save.call_deferred()

@rpc("authority", "call_remote", "reliable", 0)
func _packed(key: String, storage: Array) -> void:
	var sample: Node = get_node("/root/Database").get(key).instantiate()
	var item_data: Resource = _component(sample).get("itemData")
	var slots: Array = []
	for raw in storage:
		var slot: Variant = Codec.decode(raw)
		if slot != null: slots.append(slot)
	var carrier: Resource = load("res://Scripts/SlotData.gd").new()
	carrier.get("storage").append_array(slots)
	get_node("/root/Map/Core/UI/Interface").call("AddToCatalog", item_data, carrier.get("storage"))
	sample.free()
	local_edit = false
	_reset_placer()
	api._checkpoint_pending = true

@rpc("any_peer", "call_remote", "reliable", 0)
func _release() -> void:
	if multiplayer.is_server() and holder == multiplayer.get_remote_sender_id():
		holder = 0
		target_id = ""
