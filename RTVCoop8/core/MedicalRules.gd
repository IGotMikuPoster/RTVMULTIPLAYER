extends RefCounted

const HEALTH := {"Bandage": 20.0, "Bandage_Improvised": 20.0,
	"Medkit": 100.0, "IFAK": 100.0, "AFAK": 100.0}

static func revive_health(item_key: String) -> float:
	return float(HEALTH.get(item_key, 0.0))
