extends CanvasLayer

const Protocol = preload("res://RTVCoop8/core/CoopProtocol.gd")

signal host_requested
signal join_requested(address: String)
signal leave_requested
signal steam_host_requested
signal steam_join_requested(lobby_id: String)
signal steam_invite_requested(steam_id: String)
signal steam_overlay_requested
signal steam_friends_requested

const PANEL := Color("18191b")
const FIELD := Color("101113")
const CONTROL := Color("252629")
const BORDER := Color("3a3b3f")
const TEXT := Color("ededed")
const MUTED := Color("999b9f")
const ERROR := Color("df7a7a")

var _backdrop: ColorRect
var _status: Label
var _roster: Label
var _address: LineEdit
var _lobby_id: LineEdit
var _host_button: Button
var _join_button: Button
var _steam_host_button: Button
var _steam_join_button: Button
var _invite_button: Button
var _leave_button: Button
var _share: Label
var _copy_button: Button
var _steam_status: Label
var _friends_box: VBoxContainer
var _share_value := ""
var _steam_ready := false
var _online := false
var _previous_mouse_mode := Input.MOUSE_MODE_VISIBLE

func _ready() -> void:
	layer = 120
	_build()
	_backdrop.visible = false

func show_panel() -> void:
	if _backdrop.visible:
		return
	_previous_mouse_mode = Input.mouse_mode
	_backdrop.visible = true
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

func hide_panel() -> void:
	if not _backdrop.visible:
		return
	var focus := get_viewport().gui_get_focus_owner()
	if focus != null and _backdrop.is_ancestor_of(focus):
		focus.release_focus()
	_backdrop.visible = false
	Input.set_mouse_mode(_previous_mouse_mode)

func set_status(text: String, is_error := false) -> void:
	_status.text = text
	_status.add_theme_color_override("font_color", ERROR if is_error else MUTED)

func set_steam_status(text: String, ready: bool) -> void:
	_steam_ready = ready
	_steam_status.text = text
	_steam_status.add_theme_color_override("font_color", TEXT if ready else MUTED)
	_steam_host_button.disabled = _online or not ready
	_steam_join_button.disabled = _online or not ready

func set_roster(entries: Dictionary, states := {}, local_map := "") -> void:
	_roster.text = "%d / %d\n" % [entries.size(), Protocol.MAX_PLAYERS]
	var ids := entries.keys()
	ids.sort()
	for peer_id in ids:
		var entry: Dictionary = entries[peer_id]
		var host_marker := " (host)" if int(peer_id) == 1 else ""
		var state: Dictionary = states.get(peer_id, {}) if states is Dictionary else {}
		var detail := ""
		if not state.is_empty():
			var location := "here" if not local_map.is_empty() and String(state.get("map", "")) == local_map else String(state.get("map", ""))
			if location.is_empty():
				location = "loading"
			detail = "downed • %s" % location if bool(state.get("downed", false)) else "%d HP • %s" % [int(round(float(state.get("health", 100.0)))), location]
		_roster.text += "%s%s\n" % [String(entry.get("name", "Player")), host_marker]
		if not detail.is_empty():
			_roster.text += "  %s\n" % detail

func set_friends(entries: Array) -> void:
	for child in _friends_box.get_children():
		child.queue_free()
	if entries.is_empty():
		var empty := Label.new()
		empty.text = "No online friends"
		empty.add_theme_color_override("font_color", MUTED)
		_friends_box.add_child(empty)
		return
	for raw_entry in entries:
		if not raw_entry is Dictionary:
			continue
		var entry: Dictionary = raw_entry
		var row := HBoxContainer.new()
		var friend_name := Label.new()
		friend_name.text = String(entry.get("name", "Steam friend"))
		friend_name.add_theme_color_override("font_color", TEXT)
		friend_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(friend_name)
		var invite := _button("Invite")
		invite.disabled = not _online
		var steam_id := String(entry.get("steam_id", ""))
		invite.pressed.connect(func(): steam_invite_requested.emit(steam_id))
		row.add_child(invite)
		_friends_box.add_child(row)

func set_online(online: bool) -> void:
	_online = online
	_host_button.disabled = online
	_join_button.disabled = online
	_steam_host_button.disabled = online or not _steam_ready
	_steam_join_button.disabled = online or not _steam_ready
	_address.editable = not online
	_lobby_id.editable = not online
	_leave_button.disabled = not online

func set_steam_lobby(lobby_id: String, host: bool) -> void:
	_lobby_id.text = lobby_id
	_invite_button.disabled = lobby_id.is_empty() or not host

func set_share_info(info: Dictionary) -> void:
	var status := String(info.get("status", "offline"))
	var lan: Array = info.get("lan", [])
	_share_value = String(info.get("share", ""))
	_copy_button.disabled = _share_value.is_empty()
	match status:
		"discovering":
			_share.text = "Address: checking..."
		"ready":
			_share.text = "Address: %s (mapped)" % _share_value
		"manual":
			_share.text = "LAN: %s   UDP %d" % [", ".join(lan) if not lan.is_empty() else "unavailable", int(info.get("port", Protocol.DEFAULT_PORT))]
		"cgnat":
			_share.text = "LAN: %s   use Steam or VPN" % (_share_value if not _share_value.is_empty() else "unavailable")
		"vpn":
			_share.text = "VPN: %s" % _share_value
		_:
			_share.text = "Address: available after hosting"

func _unhandled_input(event: InputEvent) -> void:
	if _backdrop.visible and event.is_action_pressed("ui_cancel"):
		hide_panel()
		get_viewport().set_input_as_handled()

func _build() -> void:
	_backdrop = ColorRect.new()
	_backdrop.name = "RTVCoopLobbyBackdrop"
	_backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_backdrop.color = Color(0, 0, 0, 0.72)
	_backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_backdrop)

	var panel := PanelContainer.new()
	panel.name = "RTVCoopLobby"
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.offset_left = -390
	panel.offset_top = -270
	panel.offset_right = 390
	panel.offset_bottom = 270
	panel.add_theme_stylebox_override("panel", _box(PANEL, BORDER, 1, 4))
	_backdrop.add_child(panel)

	var outer := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		outer.add_theme_constant_override("margin_" + side, 20)
	panel.add_child(outer)
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 14)
	outer.add_child(root)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 12)
	root.add_child(header)
	var title := Label.new()
	title.text = Protocol.public_title()
	title.add_theme_font_size_override("font_size", 20)
	title.add_theme_color_override("font_color", TEXT)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	_steam_status = Label.new()
	_steam_status.text = "Steam starting…"
	_steam_status.add_theme_color_override("font_color", MUTED)
	_steam_status.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	header.add_child(_steam_status)
	var close := _button("Close")
	close.pressed.connect(hide_panel)
	header.add_child(close)
	root.add_child(HSeparator.new())

	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 18)
	root.add_child(body)

	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.add_theme_constant_override("separation", 12)
	body.add_child(left)
	var steam_box := _add_group(left, "Steam")
	var steam_host_row := HBoxContainer.new()
	steam_host_row.add_theme_constant_override("separation", 6)
	steam_box.add_child(steam_host_row)
	_steam_host_button = _button("Host")
	_steam_host_button.disabled = true
	_steam_host_button.pressed.connect(func(): steam_host_requested.emit())
	steam_host_row.add_child(_steam_host_button)
	_invite_button = _button("Invite")
	_invite_button.disabled = true
	_invite_button.pressed.connect(func(): steam_overlay_requested.emit())
	steam_host_row.add_child(_invite_button)
	var lobby_row := HBoxContainer.new()
	lobby_row.add_theme_constant_override("separation", 6)
	steam_box.add_child(lobby_row)
	_lobby_id = LineEdit.new()
	_lobby_id.placeholder_text = "Lobby ID"
	_lobby_id.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_lobby_id.text_submitted.connect(func(value: String): steam_join_requested.emit(value))
	_style_field(_lobby_id)
	lobby_row.add_child(_lobby_id)
	_steam_join_button = _button("Join")
	_steam_join_button.disabled = true
	_steam_join_button.pressed.connect(func(): steam_join_requested.emit(_lobby_id.text))
	lobby_row.add_child(_steam_join_button)

	left.add_child(HSeparator.new())
	var direct_box := _add_group(left, "Direct / LAN")
	var direct_row := HBoxContainer.new()
	direct_row.add_theme_constant_override("separation", 6)
	direct_box.add_child(direct_row)
	_address = LineEdit.new()
	_address.text = "127.0.0.1"
	_address.placeholder_text = "IP or host name"
	_address.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_address.text_submitted.connect(func(value: String): join_requested.emit(value))
	_style_field(_address)
	direct_row.add_child(_address)
	_join_button = _button("Join")
	_join_button.pressed.connect(func(): join_requested.emit(_address.text))
	direct_row.add_child(_join_button)
	_host_button = _button("Host")
	_host_button.pressed.connect(func(): host_requested.emit())
	direct_row.add_child(_host_button)
	var address_row := HBoxContainer.new()
	address_row.add_theme_constant_override("separation", 6)
	direct_box.add_child(address_row)
	_share = Label.new()
	_share.text = "Address available after hosting"
	_share.add_theme_color_override("font_color", MUTED)
	_share.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	address_row.add_child(_share)
	_copy_button = _button("Copy")
	_copy_button.disabled = true
	_copy_button.pressed.connect(_copy_share_address)
	address_row.add_child(_copy_button)

	body.add_child(VSeparator.new())
	var right := VBoxContainer.new()
	right.custom_minimum_size.x = 260
	right.add_theme_constant_override("separation", 12)
	body.add_child(right)
	var players_box := _add_group(right, "Players")
	var roster_scroll := ScrollContainer.new()
	roster_scroll.custom_minimum_size.y = 125
	roster_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	players_box.add_child(roster_scroll)
	_roster = Label.new()
	_roster.add_theme_color_override("font_color", TEXT)
	_roster.custom_minimum_size.x = 240
	_roster.text = "0 / 8"
	_roster.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	roster_scroll.add_child(_roster)

	right.add_child(HSeparator.new())
	var friends_box := _add_group(right, "Friends")
	var friends_header := HBoxContainer.new()
	friends_header.add_theme_constant_override("separation", 6)
	friends_box.add_child(friends_header)
	var open_friends := _button("Open")
	open_friends.pressed.connect(func(): steam_friends_requested.emit())
	friends_header.add_child(open_friends)
	var refresh := _button("Refresh")
	refresh.pressed.connect(func(): steam_friends_requested.emit())
	friends_header.add_child(refresh)
	var friend_scroll := ScrollContainer.new()
	friend_scroll.custom_minimum_size.y = 100
	friend_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	friends_box.add_child(friend_scroll)
	_friends_box = VBoxContainer.new()
	_friends_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	friend_scroll.add_child(_friends_box)
	set_friends([])

	root.add_child(HSeparator.new())
	var footer := HBoxContainer.new()
	footer.add_theme_constant_override("separation", 12)
	root.add_child(footer)
	_status = Label.new()
	_status.text = "Ready"
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_status.add_theme_color_override("font_color", MUTED)
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer.add_child(_status)
	_leave_button = _button("Leave")
	_leave_button.disabled = true
	_leave_button.pressed.connect(func(): leave_requested.emit())
	footer.add_child(_leave_button)

func _add_group(parent: Container, title: String) -> VBoxContainer:
	var block := VBoxContainer.new()
	block.add_theme_constant_override("separation", 7)
	block.size_flags_vertical = Control.SIZE_EXPAND_FILL
	parent.add_child(block)
	var label := Label.new()
	label.text = title
	label.add_theme_color_override("font_color", MUTED)
	block.add_child(label)
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 6)
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	block.add_child(content)
	return content

func _button(text: String) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(72, 30)
	_classic_button(button)
	return button

func _classic_button(button: Button) -> void:
	button.add_theme_color_override("font_color", TEXT)
	button.add_theme_color_override("font_hover_color", TEXT)
	button.add_theme_color_override("font_pressed_color", TEXT)
	button.add_theme_color_override("font_disabled_color", Color("66676a"))
	button.add_theme_stylebox_override("normal", _box(CONTROL, BORDER, 1, 3))
	button.add_theme_stylebox_override("hover", _box(Color("303136"), Color("55575c"), 1, 3))
	button.add_theme_stylebox_override("pressed", _box(FIELD, Color("55575c"), 1, 3))
	button.add_theme_stylebox_override("disabled", _box(Color("1d1e20"), Color("2c2d30"), 1, 3))
	button.add_theme_stylebox_override("focus", _box(Color.TRANSPARENT, Color("74767c"), 1, 3))

func _style_field(field: LineEdit) -> void:
	field.custom_minimum_size.y = 30
	field.add_theme_color_override("font_color", TEXT)
	field.add_theme_color_override("font_uneditable_color", Color("66676a"))
	field.add_theme_color_override("font_placeholder_color", Color("707277"))
	field.add_theme_stylebox_override("normal", _box(FIELD, BORDER, 1, 3))
	field.add_theme_stylebox_override("focus", _box(FIELD, Color("74767c"), 1, 3))
	field.add_theme_stylebox_override("read_only", _box(Color("1d1e20"), Color("2c2d30"), 1, 3))

func _box(color: Color, border: Color, width: int, radius := 0) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.border_color = border
	style.set_border_width_all(width)
	style.set_corner_radius_all(radius)
	style.content_margin_left = 8
	style.content_margin_right = 8
	style.content_margin_top = 5
	style.content_margin_bottom = 5
	return style

func _copy_share_address() -> void:
	if _share_value.is_empty():
		return
	DisplayServer.clipboard_set(_share_value)
	_copy_button.text = "Copied"
	get_tree().create_timer(1.2).timeout.connect(func():
		if is_instance_valid(_copy_button):
			_copy_button.text = "Copy"
	)
