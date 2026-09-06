extends RefCounted

var _windows: Dictionary = {}

func allow(peer_id: int, packets_per_second: float) -> bool:
	var now := Time.get_ticks_msec()
	var window: Dictionary = _windows.get(peer_id, {"start": now, "count": 0})
	if now - int(window.start) >= 1000:
		window = {"start": now, "count": 0}
	window.count = int(window.count) + 1
	_windows[peer_id] = window
	return int(window.count) <= int(ceil(packets_per_second))

func forget(peer_id: int) -> void:
	_windows.erase(peer_id)

func clear() -> void:
	_windows.clear()
