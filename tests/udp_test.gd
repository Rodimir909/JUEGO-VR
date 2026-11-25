extends Node
## Contrato real del emisor UDP: timestamps, manos perdidas, pausa y recuperación.
var failures := 0
var sender := PacketPeerUDP.new()
var frame_number := 0
var capture := 10.0

func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: ", description)
	else:
		failures += 1
		push_error("FAIL: " + description)

func _ready() -> void:
	get_parent().remove_child.call_deferred(self)
	get_tree().root.add_child.call_deferred(self)
	call_deferred("run")

func packet() -> Dictionary:
	frame_number += 1
	capture += 1.0 / 30.0
	return {"t": capture, "frame": frame_number, "calibrated": true,
		"left": {"rel": {"x": 0.15, "y": 0.35, "z": -0.45}, "wrist": {"visibility": 1.0}},
		"right": {"rel": {"x": -0.15, "y": 0.35, "z": -0.45}, "wrist": {"visibility": 1.0}},
		"head": {"valid": true, "x": 0.0, "y": 0.0, "z": 0.0}, "guard": true}

func send(data: Dictionary) -> void:
	sender.put_packet(JSON.stringify(data).to_utf8_buffer())
	for i in 3:
		await get_tree().process_frame
	await get_tree().physics_frame

func run() -> void:
	await get_tree().process_frame
	sender.set_dest_address("127.0.0.1", 4242)
	Global.start_campaign()
	for i in 8:
		await get_tree().process_frame
	var player := get_tree().get_first_node_in_group("player")
	var enemy := get_tree().get_first_node_in_group("enemy")
	enemy.set_physics_process(false)
	Global.phase = Global.Phase.FIGHTING
	await send(packet())
	check(Global.camera_active and Global.tracking_ready, "Webcam se activa mediante UDP local")
	await send(packet())
	check(Global.player_blocking, "Guardia recibida participa del combate")
	check(not player.punches["left"].active, "Reconectar no inicia un golpe")
	# Recorrido de un puño real: posición y tiempo de captura viajan por UDP.
	enemy.position = Vector3(0, 0.15, 0.3)
	Global.enemy_position = enemy.global_position
	for depth in [-0.45, -0.55, -0.8, -1.25, -1.5]:
		var moving := packet()
		moving["left"]["rel"]["z"] = depth
		moving["guard"] = false
		await send(moving)
	check(Global.enemy_health < 100, "Un puño de webcam conecta usando su velocidad")
	var after_punch := Global.enemy_health
	for i in 4:
		var held := packet()
		held["left"]["rel"]["z"] = -1.5
		held["guard"] = false
		await send(held)
	check(Global.enemy_health == after_punch, "Sostener el puño extendido no repite daño")
	for depth in [-1.2, -0.8, -0.45]:
		var returning := packet()
		returning["left"]["rel"]["z"] = depth
		returning["guard"] = false
		await send(returning)
	check(Global.enemy_health == after_punch, "Retirar la mano no cuenta como otro golpe")

	var missing := packet()
	missing["left"] = {}
	missing["guard"] = false
	await send(missing)
	check(not Global.player_blocking and player.punches["left"].hit_done, "Mano perdida elimina guardia y golpes")
	var remembered: float = player.last_capture
	await send({"t": remembered - 10, "frame": 1, "calibrated": true, "guard": true})
	check(player.last_capture == remembered, "Descarta paquetes anteriores")
	sender.put_packet("{invalid".to_utf8_buffer())
	await get_tree().process_frame
	check(player.last_capture == remembered, "JSON inválido no cambia el seguimiento")
	await send(packet())
	var paused_time := Global.round_time_left
	await get_tree().create_timer(0.7, true).timeout
	check(get_tree().paused, "Desconexión pausa automáticamente la pelea")
	var remaining := Global.round_time_left
	await get_tree().create_timer(0.1, true).timeout
	check(Global.round_time_left == remaining and remaining < paused_time, "Pausa congela el reloj")
	await send(packet())
	check(Global.camera_active, "Webcam puede recuperarse con el menú abierto")
	get_tree().paused = false
	await send(packet())
	check(not player.punches["left"].active and player.punches["left"].grace > 1, "Reanudar no deja impactos pendientes")
	sender.close()
	print("RESULT: ", failures, " fallos UDP")
	get_tree().quit(1 if failures else 0)
