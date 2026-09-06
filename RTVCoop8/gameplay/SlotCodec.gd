extends RefCounted

const MAX_NESTED := 24
const MAX_STORAGE := 128

static func encode(slot: Variant, depth := 0) -> Dictionary:
	if slot == null or depth > 3:
		return {}
	var item: Variant = slot.get("itemData")
	if item == null:
		return {}
	var nested: Array[String] = []
	for nested_item in Array(slot.get("nested")).slice(0, MAX_NESTED):
		if nested_item != null:
			nested.append(String(nested_item.resource_path).left(240))
	var storage: Array[Dictionary] = []
	for stored in Array(slot.get("storage")).slice(0, MAX_STORAGE):
		var encoded := encode(stored, depth + 1)
		if not encoded.is_empty():
			storage.append(encoded)
	return {
		"item": String(item.resource_path).left(240),
		"file": String(item.get("file")).left(80),
		"nested": nested,
		"storage": storage,
		"condition": clampf(float(slot.get("condition")), 0.0, 100.0),
		"amount": clampi(int(slot.get("amount")), 0, 100000),
		"position": clampf(float(slot.get("position")), -2.0, 2.0),
		"mode": clampi(int(slot.get("mode")), 0, 32),
		"zoom": clampi(int(slot.get("zoom")), 0, 32),
		"chamber": bool(slot.get("chamber")),
		"casing": bool(slot.get("casing")),
		"state": String(slot.get("state")).left(40),
		"grid_position": Vector2(slot.get("gridPosition")),
		"grid_rotated": bool(slot.get("gridRotated")),
		"slot": String(slot.get("slot")).left(80),
	}

static func decode(data: Dictionary, depth := 0) -> Variant:
	if not is_valid(data) or depth > 3:
		return null
	var slot_script := load("res://Scripts/SlotData.gd")
	if slot_script == null:
		return null
	var slot: Variant = slot_script.new()
	var item: Resource = load(String(data.item))
	if item == null:
		return null
	slot.set("itemData", item)
	var nested: Array = slot.get("nested")
	for path in Array(data.get("nested", [])).slice(0, MAX_NESTED):
		var nested_item: Resource = load(String(path))
		if nested_item != null:
			nested.append(nested_item)
	slot.set("nested", nested)
	var storage: Array = slot.get("storage")
	for stored in Array(data.get("storage", [])).slice(0, MAX_STORAGE):
		if stored is Dictionary:
			var decoded: Variant = decode(stored, depth + 1)
			if decoded != null:
				storage.append(decoded)
	slot.set("storage", storage)
	slot.set("condition", clampf(float(data.get("condition", 100.0)), 0.0, 100.0))
	slot.set("amount", clampi(int(data.get("amount", 0)), 0, 100000))
	slot.set("position", clampf(float(data.get("position", 0)), -2.0, 2.0))
	slot.set("mode", clampi(int(data.get("mode", 1)), 0, 32))
	slot.set("zoom", clampi(int(data.get("zoom", 1)), 0, 32))
	slot.set("chamber", bool(data.get("chamber", false)))
	slot.set("casing", bool(data.get("casing", false)))
	slot.set("state", String(data.get("state", "")).left(40))
	slot.set("gridPosition", Vector2(data.get("grid_position", Vector2.ZERO)))
	slot.set("gridRotated", bool(data.get("grid_rotated", false)))
	slot.set("slot", String(data.get("slot", "")).left(80))
	return slot

static func is_valid(data: Variant, depth := 0) -> bool:
	if typeof(data) != TYPE_DICTIONARY or depth > 3:
		return false
	var value: Dictionary = data
	if typeof(value.get("item", null)) != TYPE_STRING:
		return false
	var path := String(value.item)
	if not _valid_item_path(path):
		return false
	if typeof(value.get("nested", [])) != TYPE_ARRAY or Array(value.get("nested", [])).size() > MAX_NESTED:
		return false
	for nested_path in Array(value.get("nested", [])):
		if typeof(nested_path) != TYPE_STRING or not _valid_item_path(String(nested_path)):
			return false
	if typeof(value.get("storage", [])) != TYPE_ARRAY or Array(value.get("storage", [])).size() > MAX_STORAGE:
		return false
	for stored in value.get("storage", []):
		if not is_valid(stored, depth + 1):
			return false
	for key in ["condition", "amount", "position", "mode", "zoom"]:
		var number: Variant = value.get(key, 0)
		if typeof(number) not in [TYPE_FLOAT, TYPE_INT] or not is_finite(float(number)):
			return false
	if typeof(value.get("grid_position", Vector2.ZERO)) != TYPE_VECTOR2 or not Vector2(value.get("grid_position", Vector2.ZERO)).is_finite():
		return false
	return true

static func _valid_item_path(path: String) -> bool:
	return path.begins_with("res://Items/") and not path.contains("..") and not path.contains("\\") and path.length() <= 240 and path.get_extension() in ["tres", "res"]
