extends CharacterBody3D

const Protocol = preload("res://RTVCoop8/core/CoopProtocol.gd")
const DamageTargetScript = preload("res://RTVCoop8/presentation/RemoteDamageTarget.gd")

const BUFFER_LIMIT := 32
const INTERPOLATION_DELAY_MS := 100
const TELEPORT_DISTANCE := 15.0
const COOP_COLLISION_LAYER := 1 << 30
const RIG_PATHS := [
	"res://AI/Guard/AI_Guard.tscn",
	"res://AI/Military/AI_Military.tscn",
	"res://AI/Bandit/AI_Bandit.tscn",
]

var peer_id: int
var display_name := "Survivor"
var current_map := ""
var downed := false
var health := 100.0
var _receiver: Object
var _snapshots: Array[Dictionary] = []
var _label: Label3D
var _rig: Node3D
var _animations: AnimationPlayer
var _skeleton: Skeleton3D
var _bones: Dictionary = {}
var _clip := ""
var _reload_time := 0.0
var _recoil := 0.0
var _last_shot := -1
var _last_step := -1
var _weapon_mount: Node3D
var _weapon_transform := Transform3D.IDENTITY
var _weapon_visual: Node3D
var _weapon_key := ""
var _weapon_changed_at := -1000
var _lower_body_yaw := 0.0
var _attachment_state := ""
var _backpack_mount: Node3D
var _weapon_data: Resource
static var _safe_libraries: Dictionary = {}
static var _weapon_transforms: Dictionary = {}
static var _weapon_transforms_ready := false

func configure(new_peer_id: int, new_name: String, receiver: Object = null) -> void:
	peer_id = new_peer_id
	set_display_name(new_name)
	_receiver = receiver
	name = "RemotePlayer_%d" % peer_id
	set_meta("coop_peer_id", peer_id)
	add_to_group("Player")
	collision_layer = COOP_COLLISION_LAYER
	collision_mask = 0
	_build_target()
	_build_visuals()

func set_display_name(new_name: String) -> void:
	display_name = Protocol.sanitize_player_name(new_name)
	_refresh_label()

func push_snapshot(frame: Dictionary) -> void:
	var stamped := frame.duplicate(true)
	stamped["received_at"] = Time.get_ticks_msec()
	current_map = String(stamped.map)
	health = float(stamped.get("health", health))
	set_downed(bool(stamped.get("downed", downed)))
	if _snapshots.is_empty():
		global_position = Vector3(stamped.position)
		rotation.y = float(stamped.yaw)
	_snapshots.append(stamped)
	while _snapshots.size() > BUFFER_LIMIT:
		_snapshots.pop_front()

func set_visible_for_map(local_map: String) -> void:
	visible = not current_map.is_empty() and current_map == local_map

func set_downed(value: bool) -> void:
	if downed == value:
		return
	downed = value
	var shape := get_node_or_null("CoopCollision") as CollisionShape3D
	if shape != null:
		shape.position = Vector3(0, 0.3, -0.75) if downed else Vector3(0, 0.88, 0)
		shape.rotation.x = PI / 2.0 if downed else 0.0
	_refresh_label()

func UpdateTooltip() -> void:
	if not downed:
		return
	var data: Resource = load("res://Resources/GameData.tres")
	if data != null:
		data.set("tooltip", "Revive %s" % display_name)

func Interact() -> void:
	if downed and _receiver != null and _receiver.has_method("request_remote_revive"):
		_receiver.call("request_remote_revive", peer_id)

func _process(delta: float) -> void:
	if _snapshots.is_empty() or not visible:
		return
	var render_time := Time.get_ticks_msec() - INTERPOLATION_DELAY_MS
	while _snapshots.size() >= 2 and int(_snapshots[1].received_at) <= render_time:
		_snapshots.pop_front()
	var from_frame: Dictionary = _snapshots[0]
	var to_frame: Dictionary = _snapshots[min(1, _snapshots.size() - 1)]
	var span := maxi(1, int(to_frame.received_at) - int(from_frame.received_at))
	var alpha := clampf(float(render_time - int(from_frame.received_at)) / float(span), 0.0, 1.0)
	var target_position: Vector3 = Vector3(from_frame.position).lerp(Vector3(to_frame.position), alpha)
	if global_position.distance_to(target_position) > TELEPORT_DISTANCE:
		global_position = target_position
	else:
		global_position = global_position.lerp(target_position, 1.0 - exp(-delta * 24.0))
	rotation.y = lerp_angle(rotation.y, lerp_angle(float(from_frame.yaw), float(to_frame.yaw), alpha), 1.0 - exp(-delta * 18.0))
	_apply_pose(to_frame, delta)

func _apply_pose(frame: Dictionary, delta: float) -> void:
	if not is_instance_valid(_rig):
		return
	_rig.rotation.x = PI / 2.0 if downed else 0.0
	_rig.position.y = 0.22 if downed else 0.0
	if _animations == null:
		return
	_update_weapon(String(frame.get("weapon", "")))
	_update_attachments(frame.get("attachments", []), float(frame.get("optic_position", 0.0)))
	_update_backpack(String(frame.get("backpack", "")))
	var next_clip := select_clip(frame)
	if not _animations.has_animation(next_clip):
		next_clip = "Trader" if is_unarmed(frame) else ("Pistol_Idle" if int(frame.get("weapon_type", 1)) == 2 else "Rifle_Idle")
	if next_clip != _clip and _animations.has_animation(next_clip):
		_clip = next_clip
		_animations.play(_clip, 0.0 if downed else 0.15)
	var speed := Vector2(Vector3(frame.velocity).x, Vector3(frame.velocity).z).length()
	var local_velocity := Basis(Vector3.UP, -float(frame.yaw)) * Vector3(frame.velocity)
	var leg_direction := -local_velocity if local_velocity.z > 0.1 else local_velocity
	var leg_yaw := clampf(atan2(-leg_direction.x, -leg_direction.z), -PI / 3.0, PI / 3.0) if speed > 0.15 else 0.0
	_lower_body_yaw = lerp_angle(_lower_body_yaw, leg_yaw, 1.0 - exp(-delta * 10.0))
	if downed:
		_lower_body_yaw = 0.0
	# The AI mesh faces +Z, while the local controller looks along -Z.
	_rig.rotation.y = PI + _lower_body_yaw
	_animations.speed_scale = clampf(speed / (5.5 if _clip.contains("Sprint") else (3.5 if _clip.contains("Run") else 1.5)), 0.65, 1.6) if speed > 0.15 else 1.0
	# Reset overlays before evaluating the next frame, including unkeyed bones.
	if _skeleton != null:
		_skeleton.reset_bone_poses()
	if downed:
		_animations.seek(0.0, true)
	else:
		_animations.advance(minf(delta, 0.1))
	var shot := int(frame.get("shot", 0))
	if shot != _last_shot:
		if _last_shot >= 0:
			_recoil = 0.08
			_play_shot_audio(frame)
		_last_shot = shot
	var step := int(frame.get("step", 0))
	if step != _last_step:
		_last_step = step
	_recoil = move_toward(_recoil, 0.0, delta * 0.7)
	var reloading := not downed and (int(frame.actions) & 4) != 0
	_reload_time = _reload_time + delta if reloading else 0.0
	_apply_upper_body_aim(0.0 if downed else float(frame.pitch))
	if not downed and is_unarmed(frame) and speed > 0.15:
		_apply_unarmed_idle()
	if reloading:
		_rotate_bone("Arm_Upper_L", Vector3.RIGHT, -0.45 + sin(_reload_time * 5.0) * 0.15)
		_rotate_bone("Arm_Lower_01_L", Vector3.UP, 0.5 + sin(_reload_time * 5.0) * 0.25)
	if bool(frame.get("airborne", false)):
		_rotate_bone("Leg_Upper_L", Vector3.RIGHT, -0.25)
		_rotate_bone("Leg_Upper_R", Vector3.RIGHT, -0.15)
	if _skeleton != null:
		_skeleton.advance(minf(delta, 0.1))

static func select_clip(frame: Dictionary) -> String:
	var weapon_type := int(frame.get("weapon_type", 1))
	var prefix := "Pistol" if weapon_type == 2 else "Rifle"
	var velocity := Vector3(frame.get("velocity", Vector3.ZERO))
	var local_velocity := Basis(Vector3.UP, -float(frame.get("yaw", 0.0))) * velocity
	var speed := Vector2(velocity.x, velocity.z).length()
	var suffix := "B" if local_velocity.z > 0.1 else "F"
	if bool(frame.get("downed", false)):
		return prefix + "_Idle"
	if int(frame.get("stance", 0)) == 1:
		return prefix + "_Aim_Crouch_" + (suffix if speed > 0.15 else "Idle")
	if (int(frame.get("actions", 0)) & 3) != 0:
		return prefix + ("_Aim_Run_" + suffix if speed > 2.8 else ("_Aim_Walk_" + suffix if speed > 0.15 else "_Aim_Idle"))
	if speed > 4.5:
		return prefix + "_Sprint_F"
	if speed > 2.8:
		return prefix + "_Run_F"
	if speed > 0.15:
		return prefix + ("_Aim_Walk_B" if suffix == "B" else "_Walk_F")
	if weapon_type == 0 or (frame.has("weapon") and String(frame.weapon).is_empty()):
		return "Trader"
	return prefix + "_Idle"

static func is_unarmed(frame: Dictionary) -> bool:
	return int(frame.get("weapon_type", 1)) == 0 or (frame.has("weapon") and String(frame.weapon).is_empty())

func _apply_unarmed_idle() -> void:
	if _skeleton == null or not _animations.has_animation("Trader"): return
	var idle := _animations.get_animation("Trader")
	for track in range(idle.get_track_count()):
		var path := idle.track_get_path(track)
		if path.get_subname_count() == 0: continue
		var bone_name := String(path.get_subname(0))
		if bone_name in ["Root", "Spine_01"] or bone_name.begins_with("Leg_") or bone_name.begins_with("Foot_") or bone_name.begins_with("Toes_"): continue
		var bone := _skeleton.find_bone(bone_name)
		if bone >= 0 and idle.track_get_type(track) == Animation.TYPE_ROTATION_3D:
			_skeleton.set_bone_pose_rotation(bone, idle.rotation_track_interpolate(track, 0.0))

func _rotate_bone(bone_name: String, axis: Vector3, angle: float) -> void:
	var index := int(_bones.get(bone_name, -1))
	if _skeleton != null and index >= 0:
		_skeleton.set_bone_pose_rotation(index, _skeleton.get_bone_pose_rotation(index) * Quaternion(axis, angle))

func _apply_upper_body_aim(pitch: float) -> void:
	var index := int(_bones.get("Spine_03", -1))
	if _skeleton == null or index < 0:
		return
	# Local rotations preserve the animated joint origin. A global override can
	# pin the spine to a stale origin while the legs continue their animation.
	_rotate_bone("Spine_03", Vector3.UP, -_lower_body_yaw)
	_rotate_bone("Spine_03", Vector3.RIGHT, -clampf(pitch, -0.9, 0.9) * 0.55 - _recoil)

func _build_target() -> void:
	var damage_target := DamageTargetScript.new()
	damage_target.name = "DamageTarget"
	damage_target.configure(peer_id, _receiver)
	add_child(damage_target)
	var shape := CollisionShape3D.new()
	shape.name = "CoopCollision"
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.34
	capsule.height = 1.75
	shape.shape = capsule
	shape.position.y = 0.88
	add_child(shape)

func _build_visuals() -> void:
	_scan_weapon_transforms()
	for path in RIG_PATHS:
		if not ResourceLoader.exists(path):
			continue
		var packed: PackedScene = load(path)
		if packed == null:
			continue
		var candidate := packed.instantiate() as Node3D
		if candidate == null:
			continue
		_prepare_visual_tree(candidate)
		_rig = candidate
		_rig.name = "CharacterRig"
		_rig.rotation.y = PI
		_rig.show()
		add_child(_rig)
		_initialize_animation(_rig)
		break
	_label = Label3D.new()
	_label.text = display_name
	_label.position.y = 2.05
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.font_size = 24
	_label.outline_size = 6
	_label.no_depth_test = true
	add_child(_label)
	_refresh_label()

func _refresh_label() -> void:
	if _label == null:
		return
	_label.text = "%s [DOWN]" % display_name if downed else display_name
	_label.position.y = 0.7 if downed else 2.05
	_label.modulate = Color(1.0, 0.38, 0.32) if downed else Color.WHITE

func _prepare_visual_tree(root: Node) -> void:
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is PhysicalBone3D or node is PhysicalBoneSimulator3D:
			# The visual clone must not retain the NPC's physics skeleton.
			node.get_parent().remove_child(node)
			node.free()
			continue
		for group in node.get_groups():
			node.remove_from_group(group)
		if node.get_script() != null:
			if node is RigidBody3D:
				var slot: Variant = node.get("slotData")
				if slot != null and slot.get("itemData") != null:
					node.set_meta("coop_item_key", String(slot.get("itemData").get("file")))
			node.set_script(null)
		if node is CollisionObject3D:
			(node as CollisionObject3D).collision_layer = 0
			(node as CollisionObject3D).collision_mask = 0
		if node is RigidBody3D:
			(node as RigidBody3D).freeze = true
		if node is Area3D:
			(node as Area3D).monitoring = false
			(node as Area3D).monitorable = false
		if node is RayCast3D:
			(node as RayCast3D).enabled = false
		if node is Label3D or String(node.name) in ["Gizmo", "Poles", "Container", "Backpacks", "Weapons"]:
			(node as Node3D).hide()
		if node is Skeleton3D:
			(node as Skeleton3D).show_rest_only = false
			(node as Skeleton3D).clear_bones_global_pose_override()
		if node is BoneAttachment3D:
			(node as BoneAttachment3D).override_pose = false
		if node is NavigationAgent3D:
			(node as NavigationAgent3D).debug_enabled = false
		if node is AnimationTree:
			(node as AnimationTree).active = false
		node.process_mode = Node.PROCESS_MODE_INHERIT if node is Node3D else Node.PROCESS_MODE_DISABLED
		stack.append_array(node.get_children())

func _initialize_animation(root: Node) -> void:
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is AnimationPlayer and _animations == null:
			_animations = node
		if node is Skeleton3D and _skeleton == null:
			_skeleton = node
		if node is BoneAttachment3D and String(node.name) == "Weapons":
			_weapon_mount = node
			if node.get_child_count() > 0 and node.get_child(0) is Node3D:
				_weapon_transform = (node.get_child(0) as Node3D).transform
		if node is BoneAttachment3D and String(node.name) == "Backpacks":
			_backpack_mount = node
		stack.append_array(node.get_children())
	if _skeleton != null:
		_skeleton.show_rest_only = false
		_skeleton.process_mode = Node.PROCESS_MODE_INHERIT
		_skeleton.modifier_callback_mode_process = Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_MANUAL
		for bone_name in ["Spine_03", "Arm_Upper_L", "Arm_Lower_01_L", "Leg_Upper_L", "Leg_Upper_R"]:
			_bones[bone_name] = _skeleton.find_bone(bone_name)
	if _animations == null:
		push_warning("[RTVCoop8] Character rig has no animation library")
		return
	_animations.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	for library_name in _animations.get_animation_library_list():
		var original := _animations.get_animation_library(library_name)
		var key := original.get_instance_id()
		if not _safe_libraries.has(key):
			var safe := AnimationLibrary.new()
			for animation_name in original.get_animation_list():
				var clip := original.get_animation(animation_name).duplicate() as Animation
				for track in range(clip.get_track_count() - 1, -1, -1):
					if clip.track_get_type(track) not in [Animation.TYPE_POSITION_3D, Animation.TYPE_ROTATION_3D, Animation.TYPE_SCALE_3D]:
						clip.remove_track(track)
				clip.loop_mode = Animation.LOOP_LINEAR
				safe.add_animation(animation_name, clip)
			_safe_libraries[key] = safe
		_animations.remove_animation_library(library_name)
		_animations.add_animation_library(library_name, _safe_libraries[key])
	if _animations.has_animation("Rifle_Idle"):
		_clip = "Rifle_Idle"
		_animations.play(_clip)
		_animations.advance(0.0)

func _update_weapon(key: String) -> void:
	if _weapon_mount == null or key == _weapon_key or (not key.is_empty() and Time.get_ticks_msec() - _weapon_changed_at < 200):
		return
	_weapon_changed_at = Time.get_ticks_msec()
	_weapon_key = key
	_attachment_state = ""
	if is_instance_valid(_weapon_visual):
		_weapon_visual.hide()
		_weapon_visual.queue_free()
	_weapon_visual = null
	_weapon_data = null
	_weapon_mount.hide()
	if key.is_empty() or not Protocol.valid_weapon_key(key):
		return
	var database := get_node_or_null("/root/Database")
	var resource: Variant = database.get(key) if database != null else null
	if not resource is PackedScene:
		return
	var candidate := (resource as PackedScene).instantiate() as Node3D
	if candidate == null:
		return
	var slot: Variant = candidate.get("slotData")
	_weapon_data = slot.get("itemData") if slot != null else null
	_prepare_visual_tree(candidate)
	if candidate is RigidBody3D:
		(candidate as RigidBody3D).freeze = true
	candidate.transform = _weapon_transforms.get(key, _weapon_transform)
	_weapon_mount.add_child(candidate)
	candidate.show()
	_weapon_mount.show()
	_weapon_visual = candidate

func _play_shot_audio(frame: Dictionary) -> void:
	if _weapon_data == null:
		return
	var event: Resource
	if bool(frame.get("suppressed", false)):
		event = _weapon_data.get("fireSuppressed")
	else:
		event = _weapon_data.get("fireAuto") if int(frame.get("fire_mode", 1)) == 2 else _weapon_data.get("fireSemi")
	_play_audio_event(event, 50.0, 400.0)
	var game_data: Resource = load("res://Resources/GameData.tres") if ResourceLoader.exists("res://Resources/GameData.tres") else null
	var indoor := bool(game_data.get("indoor")) if game_data != null else false
	var tail: Resource
	if bool(frame.get("suppressed", false)):
		tail = _weapon_data.get("tailIndoorSuppressed") if indoor else _weapon_data.get("tailOutdoorSuppressed")
	else:
		tail = _weapon_data.get("tailIndoor") if indoor else _weapon_data.get("tailOutdoor")
	_play_audio_event(tail, 100.0, 400.0)

func _play_footstep_audio(frame: Dictionary) -> void:
	if not ResourceLoader.exists("res://Resources/AudioLibrary.tres"):
		return
	var library: Resource = load("res://Resources/AudioLibrary.tres")
	var kind := clampi(int(frame.get("step_kind", 0)), 0, 2)
	var event_name := ""
	if bool(frame.get("water", false)):
		event_name = "footstepWaterLand" if kind == 2 else "footstepWater"
	else:
		var surface := String(frame.get("surface", "Generic"))
		if int(frame.get("season", 1)) == 2 and surface in ["Grass", "Dirt"]:
			surface = "SnowHard"
		if surface not in ["Grass", "Dirt", "Asphalt", "Rock", "Wood", "Metal", "Concrete", "Generic", "SnowHard"]:
			surface = "Generic"
		event_name = "footstep" + surface + ("Land" if kind == 2 else "")
	var event: Variant = library.get(event_name)
	_play_audio_event(event as Resource, 8.0 if kind == 2 else 5.0, 60.0)

func play_network_footstep(event: Dictionary) -> void:
	_play_footstep_audio({
		"step_kind": int(event.get("kind", 0)),
		"surface": String(event.get("surface", "Generic")),
		"water": bool(event.get("water", false)),
		"season": int(event.get("season", 1)),
	})

func _play_audio_event(event: Resource, unit_size: float, max_distance: float) -> void:
	if event == null or not ResourceLoader.exists("res://Resources/AudioInstance3D.tscn"):
		return
	var packed: PackedScene = load("res://Resources/AudioInstance3D.tscn")
	var player := packed.instantiate() as AudioStreamPlayer3D
	if player == null:
		return
	add_child(player)
	player.position.y = 1.2
	player.call("PlayInstance", event, unit_size, max_distance)

static func _scan_weapon_transforms() -> void:
	if _weapon_transforms_ready:
		return
	_weapon_transforms_ready = true
	for path in RIG_PATHS:
		if not ResourceLoader.exists(path):
			continue
		var packed: PackedScene = load(path)
		var root := packed.instantiate() as Node3D
		if root == null:
			continue
		var stack: Array[Node] = [root]
		while not stack.is_empty():
			var node: Node = stack.pop_back()
			if node.get_parent() is BoneAttachment3D and String(node.get_parent().name) == "Weapons":
				var slot: Variant = node.get("slotData")
				var data: Variant = slot.get("itemData") if slot != null else null
				if data != null:
					_weapon_transforms[String(data.get("file"))] = (node as Node3D).transform
			stack.append_array(node.get_children())
		root.free()

func _update_attachments(keys: Array, optic_position: float) -> void:
	if not is_instance_valid(_weapon_visual):
		return
	var signature := str(keys) + str(optic_position)
	if signature == _attachment_state:
		return
	_attachment_state = signature
	var attachments := _weapon_visual.get_node_or_null("Attachments")
	if attachments == null:
		return
	var needs_mount := false
	for part in attachments.get_children():
		if not part is Node3D:
			continue
		part.visible = keys.has(String(part.name))
		if not part.has_meta("coop_attachment_origin"):
			part.set_meta("coop_attachment_origin", part.position)
		part.position = part.get_meta("coop_attachment_origin")
		if part.visible:
			# Pickup scenes already contain correctly fitted attachment meshes.
			var database := get_node_or_null("/root/Database")
			var packed: Variant = database.get(String(part.name)) if database != null else null
			if packed is PackedScene:
				var item: Node = packed.instantiate()
				var slot: Variant = item.get("slotData")
				var data: Variant = slot.get("itemData") if slot != null else null
				if data != null and String(data.get("subtype")) == "Optic":
					part.position.z += optic_position
					needs_mount = not bool(data.get("hasMount"))
				item.free()
	var mount := attachments.get_node_or_null("Mount")
	if mount is Node3D:
		mount.visible = needs_mount

func _update_backpack(key: String) -> void:
	if _backpack_mount == null:
		return
	var found := false
	for child in _backpack_mount.get_children():
		if child is Node3D:
			child.visible = not key.is_empty() and String(child.get_meta("coop_item_key", "")) == key
			found = found or child.visible
	_backpack_mount.visible = found
