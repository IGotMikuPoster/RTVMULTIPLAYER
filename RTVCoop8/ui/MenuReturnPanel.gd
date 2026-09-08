extends CanvasLayer

signal confirmed
signal canceled
var message: Label
var continue_button: Button
var cancel_button: Button
var previous_mouse_mode := Input.MOUSE_MODE_VISIBLE

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = 150
	var overlay := ColorRect.new()
	overlay.color = Color(0, 0, 0, 0.65)
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(overlay)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.add_child(center)
	var panel := PanelContainer.new()
	panel.custom_minimum_size.x = minf(600, get_viewport().get_visible_rect().size.x - 40)
	var style := StyleBoxFlat.new()
	style.bg_color = Color("202020")
	style.border_color = Color("686868")
	style.set_border_width_all(1)
	style.set_content_margin_all(20)
	panel.add_theme_stylebox_override("panel", style)
	center.add_child(panel)
	var layout := VBoxContainer.new()
	layout.add_theme_constant_override("separation", 16)
	panel.add_child(layout)
	var title := Label.new()
	title.text = "Return group to main menu?"
	layout.add_child(title)
	message = Label.new()
	message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	layout.add_child(message)
	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_END
	buttons.add_theme_constant_override("separation", 12)
	layout.add_child(buttons)
	continue_button = Button.new()
	continue_button.text = "Continue to Main Menu"
	continue_button.pressed.connect(accept)
	buttons.add_child(continue_button)
	cancel_button = Button.new()
	cancel_button.text = "Cancel"
	cancel_button.pressed.connect(cancel)
	buttons.add_child(cancel_button)
	hide()

func show_text(text: String) -> void:
	if visible: return
	previous_mouse_mode = Input.mouse_mode
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	message.text = text
	show()
	cancel_button.grab_focus()

func accept() -> void:
	if not visible: return
	hide()
	Input.mouse_mode = previous_mouse_mode
	confirmed.emit()

func cancel() -> void:
	if not visible: return
	hide()
	Input.mouse_mode = previous_mouse_mode
	canceled.emit()

func _input(event: InputEvent) -> void:
	if visible and event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		cancel()
