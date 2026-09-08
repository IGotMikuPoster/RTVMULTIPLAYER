extends Node3D

var _label: Label3D
var _title := ""
var _viewer: Node3D
var _expires_at := 0

func configure(title: String, color: Color, world_position: Vector3, viewer: Node3D, lifetime_ms := 0) -> void:
	_title = title
	_viewer = viewer
	_expires_at = Time.get_ticks_msec() + lifetime_ms if lifetime_ms > 0 else 0
	global_position = world_position + Vector3.UP * 0.25
	_label = Label3D.new()
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.no_depth_test = true
	_label.fixed_size = true
	_label.font_size = 14
	_label.outline_size = 3
	_label.pixel_size = 0.003
	_label.scale = Vector3.ONE * 0.45
	_label.modulate = color
	_label.outline_modulate = Color(0.0, 0.0, 0.0, 0.92)
	add_child(_label)
	_refresh_text()

func set_viewer(viewer: Node3D) -> void:
	_viewer = viewer

func expired(now := Time.get_ticks_msec()) -> bool:
	return _expires_at > 0 and now >= _expires_at

func _process(_delta: float) -> void:
	_refresh_text()

func _refresh_text() -> void:
	if _label == null:
		return
	var distance_text := ""
	if is_instance_valid(_viewer):
		distance_text = " · %dm" % int(round(global_position.distance_to(_viewer.global_position)))
	_label.text = _title + distance_text
