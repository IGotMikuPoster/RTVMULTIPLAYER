extends RefCounted

static func reconcile(paused: bool, online: bool, settings_open: bool, forced_unpause: bool, group_active := false, group_forced := false) -> Dictionary:
	if online and group_active:
		return {"paused": true, "forced": false, "group_forced": true}
	if online:
		if group_forced:
			paused = false
		if settings_open:
			return {"paused": false, "forced": true, "group_forced": false}
		return {"paused": paused, "forced": false, "group_forced": false}
	if (forced_unpause or group_forced) and settings_open:
		return {"paused": true, "forced": false, "group_forced": false}
	return {"paused": paused, "forced": false if not settings_open else forced_unpause, "group_forced": false}
