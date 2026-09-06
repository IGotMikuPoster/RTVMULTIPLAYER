extends CanvasLayer

signal selected(item: Node)
signal closed
var _dialog: PanelContainer
var _options: VBoxContainer
var _title: Label
var _mouse_mode := Input.MOUSE_MODE_CAPTURED

func _ready() -> void:
	layer = 110
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)
	_dialog = PanelContainer.new()
	_dialog.custom_minimum_size.x = 310
	var style := StyleBoxFlat.new()
	style.bg_color = Color("202020")
	style.border_color = Color("656565")
	style.set_border_width_all(1)
	style.set_content_margin_all(16)
	_dialog.add_theme_stylebox_override("panel", style)
	center.add_child(_dialog)
	var layout := VBoxContainer.new()
	layout.add_theme_constant_override("separation", 10)
	_dialog.add_child(layout)
	_title = Label.new()
	layout.add_child(_title)
	_options = VBoxContainer.new()
	layout.add_child(_options)
	var close_button := Button.new()
	close_button.text = "Cancel"
	close_button.pressed.connect(close)
	layout.add_child(close_button)
	hide()

func open(player_name: String, options: Array) -> void:
	for child in _options.get_children():
		_options.remove_child(child)
		child.queue_free()
	_title.text = "Revive " + player_name
	for option in options:
		var button := Button.new()
		button.text = "%s — %d HP" % [option.label, option.health]
		button.pressed.connect(func(): selected.emit(option.item))
		_options.add_child(button)
	if options.is_empty():
		var empty := Label.new()
		empty.text = "No bandage or medical kit."
		_options.add_child(empty)
	_mouse_mode = Input.mouse_mode
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	show()

func close() -> void:
	if not visible:
		return
	hide()
	Input.mouse_mode = _mouse_mode
	closed.emit()

func _input(event: InputEvent) -> void:
	if visible and event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		close()
