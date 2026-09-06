extends RefCounted

const Protocol = preload("res://RTVCoop8/core/CoopProtocol.gd")
const VOTE_TIMEOUT_MS := 60000
const READY_TIMEOUT_MS := 15000

var revision := 0
var phase := "idle"
var exit_id := ""
var source := ""
var destination := ""
var voters: Dictionary = {}
var ready: Dictionary = {}
var members: Array = []
var deadline := 0

func reset(peers: Array) -> void:
	revision += 1
	phase = "idle"
	exit_id = ""
	source = ""
	destination = ""
	voters.clear()
	ready.clear()
	members = peers.duplicate()
	members.sort()
	deadline = 0

func vote(peer: int, exit_path: String, from_map: String, to_map: String, now: int) -> bool:
	if not members.has(peer) or phase == "preparing" or phase == "committed":
		return false
	if not valid_exit_id(exit_path) or not Protocol.is_valid_scene(from_map) or not Protocol.is_valid_scene(to_map) or from_map == to_map:
		return false
	if phase == "idle" or exit_id != exit_path or source != from_map or destination != to_map:
		reset(members)
		phase = "voting"
		exit_id = exit_path
		source = from_map
		destination = to_map
		deadline = now + VOTE_TIMEOUT_MS
	if voters.has(peer):
		return false
	voters[peer] = true
	if voters.size() == members.size():
		phase = "preparing"
		deadline = now + READY_TIMEOUT_MS
	return true

func acknowledge(peer: int, ticket: int, success: bool) -> bool:
	if phase != "preparing" or ticket != revision or not members.has(peer):
		return false
	if not success:
		reset(members)
		return true
	ready[peer] = true
	if ready.size() == members.size():
		phase = "committed"
	return true

func expire(now: int) -> bool:
	if phase in ["voting", "preparing"] and now >= deadline:
		reset(members)
		return true
	return false

func snapshot() -> Dictionary:
	return {"revision": revision, "phase": phase, "exit": exit_id, "source": source,
		"destination": destination, "votes": voters.size(), "total": members.size()}

static func valid_exit_id(value: String) -> bool:
	return not value.is_empty() and value.length() <= 256 and not value.begins_with("/") and not value.contains("..") and not value.contains(":")
