extends Node

var peer_id := 0
var receiver: Object

func configure(target_peer: int, target_receiver: Object) -> void:
	peer_id = target_peer
	receiver = target_receiver

func WeaponDamage(damage: Variant, penetration: Variant) -> void:
	if receiver != null and receiver.has_method("report_remote_player_hit"):
		receiver.call("report_remote_player_hit", peer_id, float(damage), int(penetration))

func ExplosionDamage() -> void:
	if receiver != null and receiver.has_method("report_remote_player_hit"):
		receiver.call("report_remote_player_hit", peer_id, 40.0, 0)
