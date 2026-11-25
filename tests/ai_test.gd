extends Node
var failures := 0

func _ready() -> void:
	get_parent().remove_child.call_deferred(self)
	get_tree().root.add_child.call_deferred(self)
	call_deferred("run")

func run() -> void:
	await get_tree().process_frame
	seed(2026)
	for level in 3:
		Global.level_index = level
		Global.reset_match()
		for i in 8:
			await get_tree().process_frame
		Global.phase = Global.Phase.FIGHTING
		var player := get_tree().get_first_node_in_group("player")
		var initial := Global.player_health
		for i in 600:
			await get_tree().physics_frame
		if Global.player_health >= initial:
			failures += 1
			push_error("El rival no alcanzó al jugador en nivel %d" % level)
		else:
			print("PASS: Rival %d se acerca y daña al jugador: %.1f" % [level + 1, Global.player_health])
		Global.phase = Global.Phase.FIGHTING
		Global.player_health = 100
		Global.enemy_health = 100
		for i in 540:
			if i % 26 == 0:
				Input.action_press("punch_left" if i % 52 == 0 else "punch_right")
			elif i % 26 == 1:
				Input.action_release("punch_left")
				Input.action_release("punch_right")
			await get_tree().physics_frame
			if not Global.is_fighting():
				break
		Input.action_release("punch_left")
		Input.action_release("punch_right")
		if Global.enemy_health >= 100:
			failures += 1
			push_error("El jugador no pudo conectar usando los controles en nivel %d" % level)
		else:
			print("PASS: Controles de golpe alcanzan al rival %d: %.1f" % [level + 1, Global.enemy_health])
		if not is_instance_valid(player):
			failures += 1
			push_error("El jugador se perdió antes de finalizar el round")
	print("RESULT: ", failures, " fallos de jugabilidad")
	get_tree().quit(1 if failures else 0)
