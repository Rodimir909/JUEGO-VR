extends Node
## Estado único para la campaña, las rondas y el combate.
signal player_hit(blocked: bool)
signal enemy_hit(blocked: bool)
signal player_died
signal enemy_died
signal notice(text: String)

enum Phase { MENU, INTRO, FIGHTING, ROUND_END, MATCH_END }
const MAX_HEALTH := 100.0
const ROUND_TIME := 60.0
const INTRO_TIME := 4.0
const ROUND_END_TIME := 3.0
const ROUNDS_TO_WIN := 2
const MENU_SCENE := "res://elementos de hud/interfaz inicial.tscn"
const LEVELS := [
	{"scene": "res://escenario_4.tscn", "arena": "GIMNASIO", "boxer": "EL TORPE", "model": "torpe", "difficulty": 0.75, "damage": 6.0, "windup": 0.65, "recover": 0.95, "combos": 1, "tip": "Aprendé la distancia. Atacá después de su golpe."},
	{"scene": "res://escenario_2.tscn", "arena": "CLUB", "boxer": "EL RETADOR", "model": "retador", "difficulty": 1.0, "damage": 8.0, "windup": 0.48, "recover": 0.7, "combos": 2, "tip": "Alterná las manos y esquivá los golpes pesados."},
	{"scene": "res://escenario_3.tscn", "arena": "ESTADIO", "boxer": "EL ESTRATEGA", "model": "estratega", "difficulty": 1.2, "damage": 10.0, "windup": 0.42, "recover": 0.6, "combos": 3, "tip": "Buscá sus ventanas de recuperación."},
]
var phase: Phase = Phase.MENU
var phase_time := INTRO_TIME
var level_index := 0
var round_number := 1
var player_wins := 0
var enemy_wins := 0
var last_winner := 0
var match_won := false
var round_time_left := ROUND_TIME
var player_health := MAX_HEALTH
var player_blocking := false
var player_punching := false
var player_position := Vector3.ZERO
var player_head_offset := Vector3.ZERO
var player_stun_until := 0
var enemy_health := MAX_HEALTH
var enemy_blocking := false
var enemy_punching := false
var enemy_parrying := false
var enemy_position := Vector3(0, 0, -2)
var player_punch_damage := 16.0
var enemy_punch_damage := 6.0
var block_reduction := 0.75
var enemy_attack_range := 1.45
var keyboard_override := false
var camera_active := false
var tracking_ready := false
var tracking_status := "TECLADO Y MOUSE · Webcam opcional"
var _loading := false

func _ready() -> void:
	_setup_input()

func level_config() -> Dictionary:
	return LEVELS[level_index]

func _process(delta: float) -> void:
	if _loading:
		return
	match phase:
		Phase.INTRO:
			phase_time = maxf(phase_time - delta, 0.0)
			if phase_time <= 0.0:
				phase = Phase.FIGHTING
		Phase.FIGHTING:
			round_time_left = maxf(round_time_left - delta, 0.0)
			if round_time_left <= 0.0:
				_end_round(1 if player_health > enemy_health else (-1 if player_health < enemy_health else 0))
		Phase.ROUND_END:
			phase_time -= delta
			if phase_time <= 0.0:
				round_number += 1
				_reset_round_state()
				_reload_level()
		Phase.MATCH_END:
			phase_time = maxf(phase_time - delta, 0.0)
			if match_won and level_index < LEVELS.size() - 1 and phase_time <= 0.0:
				level_index += 1
				_prepare_match()
				_reload_level()

func is_fighting() -> bool:
	return phase == Phase.FIGHTING and not _loading

func phase_name() -> String:
	return str(Phase.keys()[phase])

func start_campaign() -> void:
	level_index = 0
	_prepare_match()
	_reload_level()

func reset_match() -> void:
	_prepare_match()
	_reload_level()

func return_to_menu() -> void:
	get_tree().paused = false
	phase = Phase.MENU
	player_punching = false
	player_blocking = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	get_tree().change_scene_to_file(MENU_SCENE)

func _prepare_match() -> void:
	round_number = 1
	player_wins = 0
	enemy_wins = 0
	last_winner = 0
	match_won = false
	enemy_punch_damage = float(level_config()["damage"])
	_reset_round_state()

func _reload_level() -> void:
	get_tree().paused = false
	_loading = true
	phase = Phase.INTRO
	phase_time = INTRO_TIME
	call_deferred("_change_level")

func _change_level() -> void:
	var error := get_tree().change_scene_to_file(str(level_config()["scene"]))
	if error != OK:
		_loading = false
		push_error("No se pudo cargar el nivel: %s" % error_string(error))
		return_to_menu()

func level_ready() -> void:
	_loading = false
	phase = Phase.INTRO
	phase_time = INTRO_TIME
	enemy_punch_damage = float(level_config()["damage"])

func damage_player(mult := 1.0, pierce := false, aimed_offset := Vector3.ZERO) -> void:
	if not is_fighting():
		return
	# Esquivar exige salir de la línea a la que apuntaba el rival.
	var dodge := player_head_offset - aimed_offset
	if absf(dodge.x) > 0.22 or (dodge.y < -0.24 and not pierce):
		notice.emit("¡ESQUIVASTE!")
		return
	var blocked := player_blocking
	var damage := enemy_punch_damage * mult
	if blocked:
		damage *= 0.35 if pierce else 0.12
	player_health = maxf(player_health - damage, 0.0)
	player_hit.emit(blocked)
	if player_health <= 0.0:
		_end_round(-1)
		player_died.emit()

func hit_enemy() -> void:
	damage_enemy(player_punch_damage)

func damage_enemy(damage: float) -> void:
	if not is_fighting() or Time.get_ticks_msec() < player_stun_until:
		return
	var blocked := enemy_blocking
	if blocked and enemy_parrying:
		player_stun_until = Time.get_ticks_msec() + 450
		enemy_hit.emit(true)
		notice.emit("¡CONTRAGOLPE! Recuperá la guardia")
		return
	var actual_damage := maxf(damage, 0.0) * (1.0 - block_reduction if blocked else 1.0)
	enemy_health = maxf(enemy_health - actual_damage, 0.0)
	if enemy_health <= 0.0:
		_end_round(1)
		enemy_died.emit()
	else:
		enemy_hit.emit(blocked)

func _end_round(winner: int) -> void:
	if not is_fighting():
		return
	last_winner = winner
	player_punching = false
	enemy_punching = false
	if winner > 0:
		player_wins += 1
	elif winner < 0:
		enemy_wins += 1
	if player_wins >= ROUNDS_TO_WIN or enemy_wins >= ROUNDS_TO_WIN:
		match_won = player_wins > enemy_wins
		phase = Phase.MATCH_END
		phase_time = 5.0 if match_won else 1.0
	else:
		phase = Phase.ROUND_END
		phase_time = ROUND_END_TIME

func _reset_round_state() -> void:
	player_health = MAX_HEALTH
	enemy_health = MAX_HEALTH
	player_blocking = false
	player_punching = false
	player_head_offset = Vector3.ZERO
	player_stun_until = 0
	enemy_blocking = false
	enemy_punching = false
	enemy_parrying = false
	round_time_left = ROUND_TIME

func _setup_input() -> void:
	var keys := {"move_forward": KEY_W, "move_back": KEY_S, "move_left": KEY_A, "move_right": KEY_D, "block": KEY_E, "duck": KEY_SPACE, "recalibrate": KEY_C, "keyboard_mode": KEY_K}
	for action in keys:
		if not InputMap.has_action(action):
			InputMap.add_action(action)
		var event := InputEventKey.new()
		event.physical_keycode = keys[action]
		InputMap.action_add_event(action, event)
	for action in ["punch_left", "punch_right"]:
		if not InputMap.has_action(action):
			InputMap.add_action(action)
		var event := InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_LEFT if action == "punch_left" else MOUSE_BUTTON_RIGHT
		InputMap.action_add_event(action, event)
