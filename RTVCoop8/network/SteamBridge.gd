extends Node

signal status_changed(status: String, detail: String)
signal user_ready(user: Dictionary)
signal invite_received(lobby_id: String)

const APP_ID := "1963610"
const HELPER_SOURCE := "res://RTVCoop8/bin/rtv_coop_steam.exe"
const DLL_SOURCE := "res://RTVCoop8/bin/steam_api64.dll"
const APPID_SOURCE := "res://RTVCoop8/bin/steam_appid.txt"
const RUNTIME_DIR := "user://rtv_coop_8/steam"

enum State { OFFLINE, STARTING, CONNECTING, READY, ERROR }

var state := State.OFFLINE
var user: Dictionary = {}
var _pid := -1
var _port := 27108
var _tcp := StreamPeerTCP.new()
var _buffer := PackedByteArray()
var _next_request := 1
var _callbacks: Dictionary = {}
var _connect_elapsed := 0.0
var _started_connect := false

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	launch()

func launch() -> void:
	if state != State.OFFLINE and state != State.ERROR:
		return
	state = State.STARTING
	status_changed.emit("starting", "Starting Steam services…")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(RUNTIME_DIR))
	if not _extract(HELPER_SOURCE, RUNTIME_DIR.path_join("rtv_coop_steam.exe")) \
		or not _extract(DLL_SOURCE, RUNTIME_DIR.path_join("steam_api64.dll")) \
		or not _extract(APPID_SOURCE, RUNTIME_DIR.path_join("steam_appid.txt")):
		_fail("Steam companion files could not be installed")
		return
	OS.set_environment("SteamAppId", APP_ID)
	OS.set_environment("SteamGameId", APP_ID)
	_port = 27108 + (OS.get_process_id() % 700)
	var helper := ProjectSettings.globalize_path(RUNTIME_DIR.path_join("rtv_coop_steam.exe"))
	_pid = OS.create_process(helper, PackedStringArray(["--port", str(_port)]), false)
	if _pid < 0:
		_fail("Steam companion could not start")
		return
	state = State.CONNECTING
	_connect_elapsed = 0.0
	_started_connect = false

func _process(delta: float) -> void:
	if state == State.CONNECTING:
		_connect_elapsed += delta
		if _connect_elapsed > 12.0:
			_fail("Steam did not answer. Make sure Steam is running and restart the game.")
			return
		if not _started_connect:
			_started_connect = true
			_tcp.connect_to_host("127.0.0.1", _port)
		_tcp.poll()
		if _tcp.get_status() == StreamPeerTCP.STATUS_ERROR:
			_tcp = StreamPeerTCP.new()
			_started_connect = false
		elif _tcp.get_status() == StreamPeerTCP.STATUS_CONNECTED:
			state = State.READY
			status_changed.emit("ready", "Steam connected")
			request("get_user", {}, _on_user)
	elif state == State.READY:
		_tcp.poll()
		if _tcp.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			_fail("Steam companion disconnected")
			return
		_read_responses()

func is_ready() -> bool:
	return state == State.READY and not user.is_empty()

func request(command: String, params: Dictionary, callback := Callable()) -> void:
	if state != State.READY:
		if callback.is_valid():
			callback.call({"cmd": command, "ok": false, "error": "Steam is not ready"})
		return
	var request_id := _next_request
	_next_request += 1
	var message := {"cmd": command, "req_id": request_id, "params": params}
	if callback.is_valid():
		_callbacks[request_id] = callback
	_tcp.put_data((JSON.stringify(message) + "\n").to_utf8_buffer())

func create_lobby(callback: Callable) -> void:
	request("create_lobby", {"max_players": 8, "visibility": "friends"}, callback)

func join_lobby(lobby_id: String, callback: Callable) -> void:
	request("join_lobby", {"lobby_id": lobby_id.strip_edges()}, callback)

func start_p2p_host(enet_port: int, callback: Callable) -> void:
	request("start_p2p_host", {"enet_port": enet_port}, callback)

func start_p2p_client(host_steam_id: String, callback: Callable) -> void:
	request("start_p2p_client", {"host_steam_id": host_steam_id}, callback)

func get_friends(callback: Callable) -> void:
	request("get_friends", {}, callback)

func invite_friend(steam_id: String, callback := Callable()) -> void:
	request("invite_friend", {"steam_id": steam_id}, callback)

func open_invite_dialog(callback := Callable()) -> void:
	request("open_invite_dialog", {}, callback)

func open_friends() -> void:
	if is_ready():
		request("open_friends", {}, Callable())
	# Always open the desktop friends window too; this works even when the
	# overlay is disabled in Steam settings.
	OS.shell_open("steam://open/friends")

func close_session() -> void:
	if state == State.READY:
		request("stop_p2p", {}, Callable())
		request("leave_lobby", {}, Callable())

func shutdown() -> void:
	close_session()
	if _tcp.get_status() == StreamPeerTCP.STATUS_CONNECTED:
		_tcp.disconnect_from_host()
	if _pid >= 0:
		OS.kill(_pid)
		_pid = -1
	state = State.OFFLINE
	user.clear()
	_callbacks.clear()

func _exit_tree() -> void:
	shutdown()

func _on_user(response: Dictionary) -> void:
	if not bool(response.get("ok", false)):
		_fail(String(response.get("error", "Steam identity unavailable")))
		return
	user = Dictionary(response.get("data", {})).duplicate(true)
	if not bool(user.get("owns_game", false)):
		_fail("Steam account does not own Road to Vostok")
		return
	status_changed.emit("ready", "Steam: %s" % String(user.get("name", "Connected")))
	user_ready.emit(user.duplicate(true))

func _read_responses() -> void:
	var available := _tcp.get_available_bytes()
	if available > 0:
		_buffer.append_array(_tcp.get_data(available)[1])
	while true:
		var newline := _buffer.find(10)
		if newline < 0:
			return
		var line := _buffer.slice(0, newline).get_string_from_utf8()
		_buffer = _buffer.slice(newline + 1)
		var parsed: Variant = JSON.parse_string(line)
		if not parsed is Dictionary:
			continue
		var response: Dictionary = parsed
		if String(response.get("cmd", "")) == "invite_received":
			var data: Dictionary = response.get("data", {})
			var lobby_id := String(data.get("lobby_id", ""))
			if not lobby_id.is_empty():
				invite_received.emit(lobby_id)
			continue
		var request_id := int(response.get("req_id", 0))
		var callback: Callable = _callbacks.get(request_id, Callable())
		_callbacks.erase(request_id)
		if callback.is_valid():
			callback.call(response)

func _extract(source: String, destination: String) -> bool:
	var data := _read_source(source)
	if data.is_empty():
		return false
	var absolute_destination := ProjectSettings.globalize_path(destination)
	if FileAccess.file_exists(destination):
		var existing := FileAccess.open(destination, FileAccess.READ)
		if existing != null and existing.get_length() == data.size():
			existing.close()
			return true
		if existing != null:
			existing.close()
	var output := FileAccess.open(absolute_destination, FileAccess.WRITE)
	if output == null:
		return false
	output.store_buffer(data)
	output.close()
	return true

func _read_source(source: String) -> PackedByteArray:
	var input := FileAccess.open(source, FileAccess.READ)
	if input != null:
		var mounted_data := input.get_buffer(input.get_length())
		input.close()
		return mounted_data
	# Godot resource packs do not always expose native executable extensions to
	# FileAccess. Read our binary directly from the VMZ as a safe fallback.
	var mods_path := OS.get_executable_path().get_base_dir().path_join("mods")
	var mods := DirAccess.open(mods_path)
	if mods == null:
		return PackedByteArray()
	var archive_path := source.trim_prefix("res://")
	for file_name in mods.get_files():
		if file_name.get_extension().to_lower() != "vmz":
			continue
		var zip := ZIPReader.new()
		if zip.open(mods_path.path_join(file_name)) == OK:
			if zip.file_exists(archive_path):
				var archive_data := zip.read_file(archive_path)
				zip.close()
				return archive_data
			zip.close()
	return PackedByteArray()

func _fail(detail: String) -> void:
	state = State.ERROR
	status_changed.emit("error", detail)
