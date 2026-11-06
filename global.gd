extends Node
## Escena GLOBAL (autoload). Estado compartido entre jugador, enemigo y HUD + control de rounds.

signal player_hit(blocked: bool)
signal enemy_hit(blocked: bool)
signal player_died
signal enemy_died
signal notice(text: String)

enum Phase { INTRO, FIGHTING, ROUND_END, MATCH_END }

const MAX_HEALTH := 100.0
const ROUND_TIME := 60.0
const INTRO_TIME := 3.0
const ROUND_END_TIME := 3.5
const ROUNDS_TO_WIN := 2   # mejor de tres

# --- Rounds ---
var phase: Phase = Phase.INTRO
var phase_time := INTRO_TIME
var round_number := 1
var player_wins := 0
var enemy_wins := 0
var last_winner := 0       # 1 = jugador, -1 = enemigo, 0 = empate
var match_won := false
var round_time_left := ROUND_TIME

# --- Estado del jugador (lo escribe player.gd, lo lee el enemigo) ---
var player_health := MAX_HEALTH
var player_blocking := false
var player_punching := false
var player_position := Vector3(0, 0, 3)
var player_stun_until := 0     # ms: mientras tanto no podés pegar (te contragolpearon)

# --- Estado del enemigo (lo escribe enemy.gd) ---
var enemy_health := MAX_HEALTH
var enemy_blocking := false
var enemy_punching := false
var enemy_parrying := false    # ventana de contragolpe al cubrirse justo a tiempo
var enemy_position := Vector3(0, 0, -2)


# --- Valores ajustables ---
var player_punch_damage := 15
var enemy_punch_damage := 8.0
var block_reduction := 0.8     # 0.8 = el enemigo cubierto recibe solo el 20% del daño
var enemy_attack_range := 1.8


func _ready() -> void:
	_setup_input()


func _process(delta: float) -> void:
	match phase:
		Phase.INTRO:
			phase_time -= delta
			if phase_time <= 0.0:
				phase = Phase.FIGHTING
				round_time_left = ROUND_TIME
		Phase.FIGHTING:
			round_time_left -= delta
			if round_time_left <= 0.0:
				round_time_left = 0.0
				_time_up()
		Phase.ROUND_END:
			phase_time -= delta
			if phase_time <= 0.0:
				_next_round()
		Phase.MATCH_END:
			phase_time = maxf(phase_time - delta, 0.0)


func is_fighting() -> bool:
	return phase == Phase.FIGHTING


func phase_name() -> String:
	return str(Phase.keys()[phase])


# ---------------------------------------------------------------- Input
func _setup_input() -> void:
	_add_key("move_forward", KEY_W)
	_add_key("move_back", KEY_S)
	_add_key("move_left", KEY_A)
	_add_key("move_right", KEY_D)
	_add_key("block", KEY_E)
	_add_mouse("punch_left", MOUSE_BUTTON_LEFT)
	_add_mouse("punch_right", MOUSE_BUTTON_RIGHT)


func _add_key(action: String, keycode: Key) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action)
	var ev := InputEventKey.new()
	ev.physical_keycode = keycode
	InputMap.action_add_event(action, ev)


func _add_mouse(action: String, button: MouseButton) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action)
	var ev := InputEventMouseButton.new()
	ev.button_index = button
	InputMap.action_add_event(action, ev)


# ---------------------------------------------------------------- Daño
## mult: multiplicador de daño. pierce: se mantiene por compatibilidad con el enemigo.
func damage_player(mult := 1.0, pierce := false) -> void:
	if not is_fighting():
		return
	# Cubriéndote sos inmortal: el golpe no cuenta
	if player_blocking:
		player_hit.emit(true)
		return
	var dmg := enemy_punch_damage * mult
	player_health = maxf(player_health - dmg, 0.0)
	player_hit.emit(false)
	if player_health <= 0.0:
		player_died.emit()
		_end_round(-1)


func hit_enemy() -> void:
	if not is_fighting():
		return
	var blocked := enemy_blocking
	# Contragolpe: el enemigo se cubrió justo cuando pegaste
	if blocked and enemy_parrying:
		player_stun_until = Time.get_ticks_msec() + 900
		enemy_hit.emit(true)
		notice.emit("¡TE CONTRAGOLPEÓ! No podés pegar un momento")
		return
	var dmg := player_punch_damage
	if blocked:
		dmg *= (1.0 - block_reduction)
	enemy_health = maxf(enemy_health - dmg, 0.0)
	enemy_hit.emit(blocked)
	if enemy_health <= 0.0:
		enemy_died.emit()
		_end_round(1)


# ---------------------------------------------------------------- Rounds
func _time_up() -> void:
	if player_health > enemy_health:
		_end_round(1)
	elif player_health < enemy_health:
		_end_round(-1)
	else:
		_end_round(0)


func _end_round(winner: int) -> void:
	if phase != Phase.FIGHTING:
		return
	last_winner = winner
	if winner > 0:
		player_wins += 1
	elif winner < 0:
		enemy_wins += 1
	if player_wins >= ROUNDS_TO_WIN or enemy_wins >= ROUNDS_TO_WIN:
		match_won = player_wins > enemy_wins
		phase = Phase.MATCH_END
		phase_time = 1.5
	else:
		phase = Phase.ROUND_END
		phase_time = ROUND_END_TIME


func _next_round() -> void:
	round_number += 1
	_reset_round_state()
	phase = Phase.INTRO
	phase_time = INTRO_TIME
	get_tree().reload_current_scene()


func reset_match() -> void:
	round_number = 1
	player_wins = 0
	enemy_wins = 0
	last_winner = 0
	match_won = false
	_reset_round_state()
	phase = Phase.INTRO
	phase_time = INTRO_TIME
	get_tree().reload_current_scene()


func _reset_round_state() -> void:
	player_health = MAX_HEALTH
	player_blocking = false
	player_punching = false
	player_position = Vector3(0, 0, 3)
	player_stun_until = 0
	enemy_health = MAX_HEALTH
	enemy_blocking = false
	enemy_punching = false
	enemy_parrying = false
	enemy_position = Vector3(0, 0, -2)
	round_time_left = ROUND_TIME
