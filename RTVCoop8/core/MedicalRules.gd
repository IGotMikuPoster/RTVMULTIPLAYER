extends RefCounted

const HEALTH := {"Bandage": 20.0, "Bandage_Improvised": 20.0,
	"Medkit": 100.0, "IFAK": 100.0, "AFAK": 100.0}

static func revive_health(item_key: String) -> float:
	return float(HEALTH.get(item_key, 0.0))

static func clear_debuffs(data: Resource) -> void:
	for field in ["starvation", "dehydration", "bleeding", "fracture", "burn", "frostbite", "insanity", "poisoning", "rupture", "headshot"]:
		data.set(field, false)
	# Empty survival meters immediately recreate their corresponding debuffs.
	for field in ["energy", "hydration", "mental", "temperature"]:
		data.set(field, maxf(float(data.get(field)), 20.0))
	# Overweight is derived from inventory mass, not a curable injury.
