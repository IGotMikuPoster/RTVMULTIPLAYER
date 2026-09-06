extends Node

const ITEMS := ["Sleeping_Bag", "Mattress", "Blanket", "Pillow", "Melatonin"]
var session: Node
var api: Node
var library: Variant
var votes: Dictionary = {}
var waiting := false
var sleeping := false
var elapsed := 0.0
var duration := 0
var item: Node
var grid: Node
var bed: Node
var warmth := 0.0
var label: Label
var data: Resource
var map_name := ""
var coordinating := false
var clock_elapsed := 0.0
var previous_simulate := true
var preparing := false
var round_id := 0
var participants: Array[int] = []
var acknowledgements: Dictionary = {}

func busy() -> bool:
	return waiting or sleeping or preparing or coordinating or not votes.is_empty()

func _ready() -> void:
	session.roster_changed.connect(func(_roster): cancel_group())
	var layer := CanvasLayer.new()
	layer.layer = 125
	add_child(layer)
	label = Label.new()
	label.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	label.offset_top = 60
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 16)
	label.add_theme_color_override("font_shadow_color", Color.BLACK)
	label.add_theme_constant_override("shadow_offset_x", 1)
	label.add_theme_constant_override("shadow_offset_y", 1)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(label)

func register_hooks(value: Variant) -> void:
	library = value
	library.hook("bed-interact", _bed, 80)
	library.hook("interface-contextsleep", _item, 80)

func _bed() -> void:
	if not session.is_online(): return
	library.skip_super()
	var target: Node = library._caller
	if bool(target.get("canSleep")) and not waiting and not sleeping:
		bed = target
		item = null
		_begin_wait()

func _item() -> void:
	if not session.is_online(): return
	library.skip_super()
	if waiting or sleeping: return
	var ui: Node = library._caller
	var selected: Node = ui.get("contextItem")
	if selected == null or ui.get("contextGrid") != ui.get("inventoryGrid"):
		api.show_gameplay_status("Move the sleep item into your inventory first.")
		return
	if String(selected.get("slotData").get("itemData").get("file")) not in ITEMS: return
	item = selected
	grid = ui.get("contextGrid")
	bed = null
	_begin_wait()

func _begin_wait() -> void:
	if api.scene_is_loading() or api._local_downed or api._gameplay.has_pending_transfers(false):
		api.show_gameplay_status("Finish interactions before sleeping.")
		return
	data = load("res://Resources/GameData.tres")
	if bool(data.get("isOccupied")): return
	map_name = api.current_map_name()
	var ui := get_node_or_null("/root/Map/Core/UI")
	if ui != null: ui.call("Return")
	waiting = true
	elapsed = 0.0
	data.set("freeze", true)
	data.set("isSleeping", true)
	if multiplayer.is_server(): _vote(map_name)
	else: _vote.rpc_id(1, map_name)

func _input(event: InputEvent) -> void:
	if waiting and event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		get_viewport().set_input_as_handled()
		if multiplayer.is_server(): cancel_group()
		else: _cancel.rpc_id(1)

func _process(delta: float) -> void:
	if coordinating:
		if not session.is_online() or api.scene_is_loading():
			cancel_group()
			return
		clock_elapsed += delta
		if clock_elapsed >= float(duration):
			var ui := get_node_or_null("/root/Map/Core/UI/Interface")
			if ui != null: ui.call("UpdateSimulation", duration * 100)
			_finish.rpc()
			_finish()
			return
	if not waiting and not sleeping: return
	elapsed += delta
	if not session.is_online() or api.scene_is_loading() or api.current_map_name() != map_name or api._local_downed:
		if session.is_online():
			if multiplayer.is_server(): cancel_group()
			else: _cancel.rpc_id(1)
		_clear()
		return
	if waiting and elapsed >= 60.0:
		if multiplayer.is_server(): cancel_group()
		else: _cancel.rpc_id(1)
		_clear()

@rpc("any_peer", "call_remote", "reliable", 0)
func _vote(scene: String) -> void:
	if not multiplayer.is_server() or coordinating or preparing: return
	var peer := multiplayer.get_remote_sender_id()
	if peer == 0: peer = 1
	if not session.roster.has(peer) or scene != api.current_map_name(): return
	var pose: Dictionary = session.latest_pose(peer)
	if pose.is_empty() or bool(pose.get("downed", false)) or String(pose.get("map", "")) != scene: return
	votes[peer] = true
	var needed: Array[int] = []
	for member in session.roster:
		var state: Dictionary = session.latest_pose(int(member))
		if state.is_empty() or String(state.get("map", "")) != scene: return
		if not bool(state.get("downed", false)): needed.append(int(member))
	var count := 0
	for member in needed:
		if votes.has(member): count += 1
	_progress.rpc(count, needed.size())
	_progress(count, needed.size())
	if count == needed.size() and count > 0:
		preparing = true
		participants = needed
		round_id += 1
		_prepare.rpc(round_id)
		_prepare(round_id)

@rpc("authority", "call_remote", "reliable", 0)
func _prepare(token: int) -> void:
	if api._local_downed: return
	var valid := waiting and _valid_source()
	if multiplayer.is_server(): _accept_ack(1, token, valid)
	else: _ack.rpc_id(1, token, valid)

@rpc("any_peer", "call_remote", "reliable", 0)
func _ack(token: int, valid: bool) -> void:
	var peer := multiplayer.get_remote_sender_id()
	if peer == 0: peer = 1
	_accept_ack(peer, token, valid)

func _accept_ack(peer: int, token: int, valid: bool) -> void:
	if not multiplayer.is_server() or not preparing or token != round_id: return
	if peer not in participants: return
	if not valid:
		cancel_group()
		return
	acknowledgements[peer] = true
	if acknowledgements.size() != participants.size(): return
	preparing = false
	coordinating = true
	clock_elapsed = 0.0
	duration = randi_range(6, 12)
	var simulation := get_node_or_null("/root/Simulation")
	if simulation != null:
		previous_simulate = bool(simulation.get("simulate"))
		simulation.set("simulate", false)
	_start.rpc(duration)
	_start(duration)

@rpc("authority", "call_remote", "reliable", 0)
func _progress(count: int, total: int) -> void:
	label.text = "Waiting for players to sleep: %d/%d%s" % [count, total, " · Esc to cancel" if waiting else ""]

@rpc("authority", "call_remote", "reliable", 0)
func _start(hours: int) -> void:
	if not waiting or sleeping: return
	if api._local_downed or api.scene_is_loading() or not _valid_source():
		if multiplayer.is_server(): cancel_group()
		else: _cancel.rpc_id(1)
		return
	warmth = 0.0
	if is_instance_valid(item):
		warmth = float(item.get("slotData").get("itemData").get("temperature"))
		grid.call("Pick", item)
		item.queue_free()
		item = null
	duration = clampi(hours, 6, 12)
	waiting = false
	sleeping = true
	elapsed = 0.0
	label.text = "Sleeping…"
	var ui := get_node_or_null("/root/Map/Core/UI/Interface")
	if ui != null: ui.call("PlaySleep")

func _valid_source() -> bool:
	if is_instance_valid(bed): return bool(bed.get("canSleep"))
	return is_instance_valid(item) and not item.is_queued_for_deletion() and is_instance_valid(grid) and item.get_parent() == grid

@rpc("authority", "call_remote", "reliable", 0)
func _finish() -> void:
	if sleeping and data != null and not api._local_downed:
		data.set("energy", float(data.get("energy")) - 20.0)
		data.set("hydration", float(data.get("hydration")) - 20.0)
		data.set("mental", float(data.get("mental")) + 20.0)
		var simulation := get_node_or_null("/root/Simulation")
		if warmth > 0.0:
			data.set("temperature", float(data.get("temperature")) + warmth)
		elif not bool(data.get("shelter")) and simulation != null and int(simulation.get("season")) == 2:
			data.set("temperature", float(data.get("temperature")) - warmth)
		if is_instance_valid(bed): bed.set("canSleep", false)
		api.show_gameplay_status("You slept %d hours" % duration)
		api._checkpoint_pending = true
	_clear()

@rpc("any_peer", "call_remote", "reliable", 0)
func _cancel() -> void:
	if multiplayer.is_server() and session.roster.has(multiplayer.get_remote_sender_id()): cancel_group()

func cancel_group() -> void:
	if multiplayer.is_server() and session.is_online(): _clear.rpc()
	_clear()

@rpc("authority", "call_remote", "reliable", 0)
func _clear() -> void:
	if coordinating:
		var simulation := get_node_or_null("/root/Simulation")
		if simulation != null: simulation.set("simulate", previous_simulate)
	coordinating = false
	preparing = false
	participants.clear()
	acknowledgements.clear()
	round_id += 1
	if (waiting or sleeping) and data != null:
		data.set("isSleeping", false)
		data.set("freeze", bool(api._local_downed))
	waiting = false
	sleeping = false
	votes.clear()
	item = null
	grid = null
	bed = null
	if label != null: label.text = ""
