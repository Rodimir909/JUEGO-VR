extends Node

func _ready() -> void:
	get_parent().remove_child.call_deferred(self)
	get_tree().root.add_child.call_deferred(self)
	call_deferred("run")

func shot(name: String) -> void:
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("res://tests/" + name + ".png")

func run() -> void:
	await get_tree().process_frame
	Global.return_to_menu()
	await get_tree().create_timer(0.5).timeout
	await shot("menu_preview")
	for index in 3:
		Global.level_index = index
		Global.reset_match()
		await get_tree().create_timer(0.5).timeout
		await shot("intro_preview_%d" % index)
		Global.phase = Global.Phase.FIGHTING
		await get_tree().create_timer(2.0).timeout
		await shot("fight_preview_%d" % index)
		var player := get_tree().get_first_node_in_group("player")
		var enemy := get_tree().get_first_node_in_group("enemy")
		print("LEVEL ", index, " PLAYER ", player.global_position, " ENEMY ", enemy.global_position, " DIST ", player.global_position.distance_to(enemy.global_position))
		Global.enemy_health = 1
		Global.player_wins = 1
		Global.enemy_blocking = false
		Global.damage_enemy(100)
		Global.phase_time = 0
		if index == 2:
			await shot("champion_preview")
	get_tree().quit()
