extends RefCounted

const CORE_CAPABILITIES: Array[String] = [
	"pose.v1",
	"roster.v1",
	"maps.v1",
]

var _local_manifest: Array[Dictionary] = []
var _peer_manifests: Dictionary = {}
var _adapters: Dictionary = {}

func discover(loader_library: Variant) -> void:
	_local_manifest.clear()
	if loader_library == null or not loader_library.has_method("loaded_mods"):
		return
	var ids: Array = loader_library.loaded_mods()
	ids.sort()
	for raw_id in ids:
		var mod_id := String(raw_id)
		var info: Dictionary = loader_library.mod_info(mod_id)
		_local_manifest.append({
			"id": mod_id,
			"version": String(info.get("version", "0")),
		})

func local_manifest() -> Array[Dictionary]:
	return _local_manifest.duplicate(true)

func remember_peer(peer_id: int, manifest: Array[Dictionary]) -> void:
	_peer_manifests[peer_id] = manifest.duplicate(true)

func forget_peer(peer_id: int) -> void:
	_peer_manifests.erase(peer_id)

func register_adapter(mod_id: String, adapter: Object) -> bool:
	var normalized := mod_id.strip_edges().to_lower()
	if normalized.is_empty() or adapter == null:
		return false
	_adapters[normalized] = adapter
	return true

func compatibility_report(peer_id: int) -> Dictionary:
	var remote: Array = _peer_manifests.get(peer_id, [])
	var local_by_id := _index_manifest(_local_manifest)
	var remote_by_id := _index_manifest(remote)
	var missing_local: Array[String] = []
	var missing_remote: Array[String] = []
	var version_mismatch: Array[String] = []
	for mod_id in remote_by_id:
		if not local_by_id.has(mod_id):
			missing_local.append(mod_id)
		elif local_by_id[mod_id] != remote_by_id[mod_id]:
			version_mismatch.append(mod_id)
	for mod_id in local_by_id:
		if not remote_by_id.has(mod_id):
			missing_remote.append(mod_id)
	return {
		"exact": missing_local.is_empty() and missing_remote.is_empty() and version_mismatch.is_empty(),
		"missing_local": missing_local,
		"missing_remote": missing_remote,
		"version_mismatch": version_mismatch,
	}

func _index_manifest(manifest: Array) -> Dictionary:
	var indexed := {}
	for entry in manifest:
		if typeof(entry) == TYPE_DICTIONARY:
			indexed[String(entry.get("id", "")).to_lower()] = String(entry.get("version", "0"))
	return indexed
