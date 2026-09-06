extends Node

signal share_info_changed(info: Dictionary)

var _thread: Thread
var _hosting := false
var _port := 0
var _mapped_upnp: UPNP
var _mapped_port := 0

func _process(_delta: float) -> void:
	if _thread == null or _thread.is_alive():
		return
	var result: Dictionary = _thread.wait_to_finish()
	_thread = null
	var upnp: UPNP = result.get("upnp")
	if not _hosting:
		if bool(result.get("mapped", false)) and upnp != null:
			upnp.delete_port_mapping(int(result.get("port", 0)), "UDP")
		return
	if bool(result.get("mapped", false)):
		_mapped_upnp = upnp
		_mapped_port = int(result.get("port", 0))
	var addresses := _local_addresses()
	var external := String(result.get("external", ""))
	var share := _format_endpoint(external, _port) if not external.is_empty() else _first_endpoint(addresses, _port)
	var routable := _is_public_routable(external)
	share_info_changed.emit({
		"status": "ready" if bool(result.get("mapped", false)) and routable else ("cgnat" if not external.is_empty() and not routable else "manual"),
		"lan": addresses,
		"external": external,
		"share": share,
		"port": _port,
		"mapped": bool(result.get("mapped", false)),
		"upnp_error": int(result.get("error", UPNP.UPNP_RESULT_UNKNOWN_ERROR)),
	})

func begin(port: int) -> void:
	stop()
	_hosting = true
	_port = port
	var addresses := _local_addresses()
	var overlay := _first_overlay_address(addresses)
	if not overlay.is_empty():
		share_info_changed.emit({
			"status": "vpn",
			"lan": addresses,
			"external": "",
			"share": _format_endpoint(overlay, port),
			"port": port,
			"mapped": false,
		})
		return
	share_info_changed.emit({
		"status": "discovering",
		"lan": addresses,
		"external": "",
		"share": _first_endpoint(addresses, port),
		"port": port,
		"mapped": false,
	})
	_thread = Thread.new()
	var error := _thread.start(_discover_and_map.bind(port))
	if error != OK:
		_thread = null
		share_info_changed.emit({
			"status": "manual",
			"lan": addresses,
			"external": "",
			"share": _first_endpoint(addresses, port),
			"port": port,
			"mapped": false,
			"upnp_error": error,
		})

func stop() -> void:
	_hosting = false
	if _mapped_upnp != null and _mapped_port > 0:
		_mapped_upnp.delete_port_mapping(_mapped_port, "UDP")
	_mapped_upnp = null
	_mapped_port = 0
	share_info_changed.emit({"status": "offline", "share": "", "lan": [], "external": "", "mapped": false})

func _exit_tree() -> void:
	_hosting = false
	if _thread != null:
		var result: Dictionary = _thread.wait_to_finish()
		var upnp: UPNP = result.get("upnp")
		if bool(result.get("mapped", false)) and upnp != null:
			upnp.delete_port_mapping(int(result.get("port", 0)), "UDP")
		_thread = null
	if _mapped_upnp != null and _mapped_port > 0:
		_mapped_upnp.delete_port_mapping(_mapped_port, "UDP")

func _discover_and_map(port: int) -> Dictionary:
	var upnp := UPNP.new()
	var error := upnp.discover(2500, 2, "InternetGatewayDevice")
	if error != UPNP.UPNP_RESULT_SUCCESS:
		return {"error": error, "external": "", "mapped": false, "port": port, "upnp": upnp}
	var gateway := upnp.get_gateway()
	if gateway == null or not gateway.is_valid_gateway():
		return {"error": UPNP.UPNP_RESULT_INVALID_GATEWAY, "external": "", "mapped": false, "port": port, "upnp": upnp}
	var external := upnp.query_external_address()
	var map_error := upnp.add_port_mapping(port, port, "RTV Co-op", "UDP", 0)
	return {
		"error": map_error,
		"external": external,
		"mapped": map_error == UPNP.UPNP_RESULT_SUCCESS,
		"port": port,
		"upnp": upnp,
	}

func _local_addresses() -> Array[String]:
	var overlay_ipv4: Array[String] = []
	var private_ipv4: Array[String] = []
	var other_ipv4: Array[String] = []
	for raw_address in IP.get_local_addresses():
		var address := String(raw_address)
		if address == "127.0.0.1" or address == "0.0.0.0" or address.contains(":"):
			continue
		if address.begins_with("169.254."):
			continue
		if _is_overlay_ipv4(address):
			overlay_ipv4.append(address)
		elif _is_private_ipv4(address):
			private_ipv4.append(address)
		else:
			other_ipv4.append(address)
	overlay_ipv4.sort()
	private_ipv4.sort()
	other_ipv4.sort()
	overlay_ipv4.append_array(private_ipv4)
	overlay_ipv4.append_array(other_ipv4)
	return overlay_ipv4

func _is_private_ipv4(address: String) -> bool:
	if address.begins_with("10.") or address.begins_with("192.168."):
		return true
	if not address.begins_with("172."):
		return false
	var parts := address.split(".")
	return parts.size() == 4 and int(parts[1]) >= 16 and int(parts[1]) <= 31

func _is_public_routable(address: String) -> bool:
	if address.is_empty() or address == "0.0.0.0" or address.begins_with("127.") or address.begins_with("169.254."):
		return false
	if _is_private_ipv4(address):
		return false
	if _is_overlay_ipv4(address):
		return false
	return true

func _is_overlay_ipv4(address: String) -> bool:
	if not address.begins_with("100."):
		return false
	var parts := address.split(".")
	return parts.size() == 4 and int(parts[1]) >= 64 and int(parts[1]) <= 127

func _first_overlay_address(addresses: Array[String]) -> String:
	for address in addresses:
		if _is_overlay_ipv4(address):
			return address
	return ""

func _first_endpoint(addresses: Array[String], port: int) -> String:
	return _format_endpoint(addresses[0], port) if not addresses.is_empty() else ""

func _format_endpoint(address: String, port: int) -> String:
	return "%s:%d" % [address, port]
