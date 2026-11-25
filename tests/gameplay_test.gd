extends Node
## Ejecutar: godot --headless --path . res://tests/gameplay_test.tscn
var failures := 0

func check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: ", description)
	else:
		failures += 1
		push_error("FAIL: " + description)

func _ready() -> void:
	# La prueba sobrevive a los cambios de escena de la campaña.
	get_parent().remove_child.call_deferred(self)
	get_tree().root.add_child.call_deferred(self)
	call_deferred("run")

func settle() -> void:
	for i in 5:
		await get_tree().process_frame
	await get_tree().physics_frame

func run() -> void:
	await settle()
	Global.start_campaign()
	await settle()
	check(Global.level_index == 0 and Global.phase == Global.Phase.INTRO, "Jugar comienza en nivel 1")
	for level in 3:
		check(get_tree().current_scene.scene_file_path == Global.LEVELS[level]["scene"], "Escenario del nivel %d" % (level + 1))
		var player := get_tree().get_first_node_in_group("player")
		var enemy := get_tree().get_first_node_in_group("enemy")
		check(player != null and enemy != null, "Jugador y rival presentes")
		check(player.get_node("Head/Camera3D").current, "Cámara válida")
		check(str(enemy.get_node("BoxerRig/BoxerBody").mesh.resource_path).contains(str(Global.LEVELS[level]["model"])), "Modelo distinto por nivel")
		Global.phase = Global.Phase.FIGHTING
		enemy.set_physics_process(false)
		# Colocar rival al alcance y ejecutar un golpe con la animación real.
		player.position = Vector3(0, 0.15, 0.6)
		player.rotation = Vector3.ZERO
		enemy.position = Vector3(0, 0.15, -0.6)
		Global.player_position = player.global_position
		Global.enemy_position = enemy.global_position
		player._keyboard_punch("left")
		for i in 22:
			await get_tree().physics_frame
		check(Global.enemy_health < 100.0, "El guante conecta mediante colisión")
		check(Global.enemy_health > 65.0, "Un golpe daña una sola vez")
		# Un paquete inválido o una mano perdida no habilita un golpe fantasma.
		player._reset_punch("left")
		check(player.punches["left"].hit_done and player.punches["left"].grace > 1, "Pérdida de tracking cancela impactos")
		player.set_physics_process(false)
		Global.player_head_offset = Vector3.ZERO
		Global.player_blocking = false
		var before := Global.player_health
		Global.damage_player()
		check(Global.player_health < before, "Daño entrante usa la vida del HUD")
		Global.player_blocking = true
		before = Global.player_health
		Global.damage_player()
		var blocked_damage := before - Global.player_health
		check(blocked_damage > 0 and blocked_damage < Global.enemy_punch_damage, "Guardia reduce daño sin inmortalidad")
		Global.player_blocking = false
		Global.player_head_offset = Vector3(0, -0.35, 0)
		before = Global.player_health
		Global.damage_player()
		check(Global.player_health == before, "Agacharse esquiva jabs")
		Global.damage_player(1.8, true)
		check(Global.player_health < before, "Un pesado puede castigar la esquiva sostenida")
		Global.player_head_offset = Vector3(0.3, 0, 0)
		before = Global.player_health
		Global.damage_player(1, false, Global.player_head_offset)
		check(Global.player_health < before, "El rival puede apuntar a una esquiva sostenida")
		Global.player_head_offset = Vector3.ZERO
		Global.enemy_blocking = false
		Global.damage_enemy(200)
		check(Global.phase == Global.Phase.ROUND_END and Global.player_wins == 1, "KO termina el primer round")
		var frozen_health := Global.player_health
		Global.damage_player(100)
		check(Global.player_health == frozen_health, "No hay daño después de la campana")
		Global.phase_time = 0.001
		await settle()
		check(Global.round_number == 2 and Global.player_health == 100 and Global.enemy_health == 100, "Segundo round restaura la pelea")
		Global.phase = Global.Phase.FIGHTING
		Global.damage_enemy(200)
		check(Global.match_won and Global.phase == Global.Phase.MATCH_END, "Dos rounds ganan el nivel")
		if level < 2:
			Global.phase_time = 0.001
			await settle()
			check(Global.level_index == level + 1 and Global.player_wins == 0, "Avanza automáticamente y reinicia marcador")
	check(Global.level_index == 2 and Global.match_won, "Campeonato termina en nivel 3")
	Global.reset_match()
	await settle()
	check(Global.level_index == 2 and Global.player_wins == 0, "Reintentar conserva nivel actual")
	Global.phase = Global.Phase.FIGHTING
	Global.player_health = 1
	Global.damage_player(10)
	Global.phase_time = 0.001
	await settle()
	Global.phase = Global.Phase.FIGHTING
	Global.player_health = 1
	Global.damage_player(10)
	check(not Global.match_won and Global.phase == Global.Phase.MATCH_END, "Derrota permite reintentar")
	Global.return_to_menu()
	await settle()
	check(Global.phase == Global.Phase.MENU, "Volver al menú detiene el combate")
	Global.start_campaign()
	await settle()
	check(Global.level_index == 0, "Una nueva campaña vuelve a nivel 1")
	print("RESULT: ", failures, " fallos")
	# El servidor de audio libera reproducciones en su propio hilo.
	OS.delay_msec(80)
	get_tree().quit(1 if failures else 0)
