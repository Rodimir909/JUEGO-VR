extends Node3D

func _enter_tree() -> void:
	# También elegir el rival correcto al ejecutar un escenario con F6.
	for index in Global.LEVELS.size():
		if Global.LEVELS[index]["scene"] == scene_file_path:
			Global.level_index = index
			break

func _ready() -> void:
	$Player.position = Vector3(0, 0.15, 1.5)
	$Enemy.position = Vector3(0, 0.15, -1.5)
	Global.player_position = $Player.global_position
	Global.enemy_position = $Enemy.global_position
	Global.level_ready()
	var environment := WorldEnvironment.new()
	var settings := Environment.new()
	settings.background_mode = Environment.BG_COLOR
	settings.background_color = Color(0.035, 0.045, 0.07)
	settings.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	settings.ambient_light_color = Color(0.75, 0.82, 1.0)
	settings.ambient_light_energy = 0.65
	environment.environment = settings
	add_child(environment)
