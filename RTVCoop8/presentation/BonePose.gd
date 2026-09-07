extends RefCounted

const MAX_BONES := 128

static func capture(skeleton: Skeleton3D, ragdoll := false) -> PackedFloat32Array:
	var result := PackedFloat32Array()
	if skeleton == null or skeleton.get_bone_count() > MAX_BONES:
		return result
	var poses: Array[Transform3D] = []
	for index in skeleton.get_bone_count():
		poses.append(skeleton.get_bone_global_pose(index))
	if ragdoll:
		# Physics modifiers can reset the readable skeleton pose after rendering.
		# Read the actual rigid bodies, removing each body's bone offset.
		var bodies: Dictionary = {}
		for body in skeleton.find_children("*", "PhysicalBone3D", true, false):
			var index: int = body.get_bone_id()
			if index >= 0 and index < poses.size():
				bodies[index] = skeleton.global_transform.affine_inverse() * body.global_transform * body.body_offset.affine_inverse()
		var original := poses.duplicate()
		for index in poses.size():
			var parent := skeleton.get_bone_parent(index)
			if bodies.has(index):
				poses[index] = bodies[index]
			elif parent >= 0:
				poses[index] = poses[parent] * original[parent].affine_inverse() * original[index]
	for index in skeleton.get_bone_count():
		var pose := poses[index]
		var parent := skeleton.get_bone_parent(index)
		if parent >= 0:
			pose = poses[parent].affine_inverse() * pose
		var q := pose.basis.orthonormalized().get_rotation_quaternion()
		result.append_array(PackedFloat32Array([pose.origin.x, pose.origin.y, pose.origin.z, q.x, q.y, q.z, q.w]))
	return result

static func valid(value: Variant) -> bool:
	if not value is PackedFloat32Array or value.size() == 0 or value.size() > MAX_BONES * 7 or value.size() % 7 != 0:
		return false
	for number in value:
		if not is_finite(number) or absf(number) > 1000.0:
			return false
	for offset in range(0, value.size(), 7):
		var q := Quaternion(value[offset + 3], value[offset + 4], value[offset + 5], value[offset + 6])
		if q.length_squared() < 0.9 or q.length_squared() > 1.1:
			return false
	return true

static func apply(skeleton: Skeleton3D, value: PackedFloat32Array, weight: float) -> void:
	if skeleton == null or value.size() != skeleton.get_bone_count() * 7:
		return
	skeleton.clear_bones_global_pose_override()
	skeleton.show_rest_only = false
	for index in skeleton.get_bone_count():
		var offset := index * 7
		var position := Vector3(value[offset], value[offset + 1], value[offset + 2])
		var rotation := Quaternion(value[offset + 3], value[offset + 4], value[offset + 5], value[offset + 6]).normalized()
		skeleton.set_bone_pose_position(index, skeleton.get_bone_pose_position(index).lerp(position, weight))
		skeleton.set_bone_pose_rotation(index, skeleton.get_bone_pose_rotation(index).slerp(rotation, weight))
