extends CharacterBody3D


enum State { APPROACH, CIRCLE, WINDUP, RECOVER, BLOCK, DODGE, LUNGE }
enum Attack { JAB, HEAVY, FEINT }

const REST_R := Vector3(0.35, 1.2, -0.4)
const REST_L := Vector3(-0.35, 1.2, -0.4)
const GUARD_R := Vector3(0.12, 1.5, -0.45)
const GUARD_L := Vector3(-0.12, 1.5, -0.45)
const WINDUP_R := Vector3(0.45, 1.3, -0.1)
const WINDUP_L := Vector3(-0.45, 1.3, -0.1)
const PUNCH_R := Vector3(0.1, 1.4, -1.1)
const PUNCH_L := Vector3(-0.1, 1.4, -1.1)
const GLOVE_COLOR := Color(0.1, 0.1, 0.1)
const HEAVY_COLOR := Color(1.0, 0.5, 0.05)
const RAGE_COLOR := Color(1.0, 0.25, 0.25)

@export var base_move_speed := 2.8
@export var base_circle_speed := 1.8
@export var base_windup := 0.32
@export var base_recover := 0.4
@export var jab_damage := 1.0
@export var heavy_damage := 2.2
@export var rage_health := 40.0   # por debajo de esta vida entra en furia

@onready var glove_r: MeshInstance3D = $GloveR
@onready var glove_l: MeshInstance3D = $GloveL
@onready var body: MeshInstance3D = $Body

var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")
var base_diff := 1.0
var diff := 1.0           
var move_speed := 2.8
var circle_speed := 1.8
var rage := false

var state: State = State.RECOVER
var attack: Attack = Attack.JAB
var state_time := 0.5
var circle_dir := 1.0
var combo_left := 0
var did_combo := false
var use_left := false
var no_block_until := 0
var no_dodge_until := 0
var no_lunge_until := 0
var parry_time := 0.0
var dodge_dir := Vector3.ZERO
var block_habit := 0.0     # cuánto te cubrís (0 a 1)
var punch_habit := 0.0     # cuánto pegás
var retreat_habit := 0.0   # cuánto te alejás (0 a 1)
var prev_player_punching := false
var prev_dist := 0.0
var ko := false
var body_color: Color
var flash_tween: Tween
var tweens: Dictionary = {}


func _ready() -> void:
	# Dificultad según el round (arranca más alta y sube más)
	base_diff = minf(1.25 + 0.25 * float(Global.round_number - 1), 2.0)
	_update_difficulty()
	body_color = (body.material_override as StandardMaterial3D).albedo_color
	Global.enemy_hit.connect(_on_enemy_hit)
	Global.enemy_died.connect(_on_died)
	_set_state(State.RECOVER, 0.35)


func _update_difficulty() -> void:
	diff = base_diff * (1.25 if rage else 1.0)
	move_speed = base_move_speed * diff
	circle_speed = base_circle_speed * diff


# Tiempo escalado por dificultad, con un mínimo para que siempre se pueda reaccionar
func _w(t: float, min_t := 0.15) -> float:
	return maxf(t / diff, min_t)


func _physics_process(delta: float) -> void:
	Global.enemy_position = global_position

	if not is_on_floor():
		velocity.y -= gravity * delta
	else:
		velocity.y = 0.0

	if ko:
		velocity.x = 0.0
		velocity.z = 0.0
		move_and_slide()
		return

	var to_player := Global.player_position - global_position
	to_player.y = 0.0
	var dist := to_player.length()
	var dir := to_player.normalized() if dist > 0.01 else Vector3.ZERO

	# Mirar al jugador
	if dist > 0.05:
		rotation.y = lerp_angle(rotation.y, atan2(-dir.x, -dir.z), 12.0 * delta)

	if not Global.is_fighting():
		velocity.x = 0.0
		velocity.z = 0.0
		move_and_slide()
		return

	# Furia: cuando está herido se vuelve más rápido y agresivo
	if not rage and Global.enemy_health < rage_health:
		rage = true
		_update_difficulty()
		_set_glove_color(RAGE_COLOR)
		Global.notice.emit("¡Se enfureció!")

	# Aprende tus hábitos
	block_habit = lerpf(block_habit, 1.0 if Global.player_blocking else 0.0, delta * 0.6)
	punch_habit = maxf(punch_habit - delta * 0.2, 0.0)
	var retreating := dist > prev_dist + 0.002 and dist > 1.2
	retreat_habit = lerpf(retreat_habit, 1.0 if retreating else 0.0, delta * 0.8)
	prev_dist = dist

	if parry_time > 0.0:
		parry_time -= delta
		if parry_time <= 0.0:
			Global.enemy_parrying = false

	# Reacciona cuando empezás o terminás de pegar
	var p_now := Global.player_punching
	if p_now and not prev_player_punching:
		punch_habit = minf(punch_habit + 1.0, 4.0)
		_react_to_punch(dist)
	elif not p_now and prev_player_punching:
		_try_counter(dist)
	prev_player_punching = p_now

	var wish := Vector3.ZERO
	state_time -= delta
	match state:
		State.APPROACH:
			if dist > Global.enemy_attack_range * 0.8:
				wish = dir * move_speed
			# Si te alejás, te corta el paso con un salto hacia adelante
			if dist > Global.enemy_attack_range + 0.6 and _can_lunge():
				_start_lunge()
			elif dist <= Global.enemy_attack_range or state_time <= 0.0:
				_decide()
		State.CIRCLE:
			wish = Vector3(-dir.z, 0.0, dir.x) * circle_dir * circle_speed
			if dist < 1.2:
				wish -= dir * circle_speed
			elif dist > Global.enemy_attack_range:
				wish += dir * circle_speed * 0.7
			if state_time <= 0.0:
				_decide()
		State.WINDUP:
			# Sigue persiguiéndote un poco mientras carga el golpe
			if dist > Global.enemy_attack_range * 0.9:
				wish = dir * move_speed * 0.6
			if state_time <= 0.0:
				_windup_done()
		State.RECOVER:
			if state_time <= 0.0:
				_decide()
		State.BLOCK:
			if state_time <= 0.0:
				no_block_until = Time.get_ticks_msec() + 500
				_decide()
		State.DODGE:
			wish = dodge_dir * 9.0
			if state_time <= 0.0:
				_after_dodge()
		State.LUNGE:
			wish = dir * 13.0
			if dist <= Global.enemy_attack_range * 0.85 or state_time <= 0.0:
				_after_lunge()

	velocity.x = wish.x
	velocity.z = wish.z
	move_and_slide()


# ------------------------------------------------------------ Decisiones
func _decide() -> void:
	if not Global.is_fighting():
		return
	var dist := _flat_distance()
	if dist > Global.enemy_attack_range:
		if dist < Global.enemy_attack_range + 3.0 and _can_lunge() and randf() < 0.4 + retreat_habit * 0.4:
			_start_lunge()
		else:
			_set_state(State.APPROACH, randf_range(0.3, 0.7))
		return

	var w_attack := 0.60
	var w_block := 0.12
	var w_move := 0.18

	if Global.player_punching:
		w_block += 0.3
		w_attack -= 0.15
	if Global.player_blocking:
		w_attack += 0.1    # si te cubrís, te castiga igual (pesados y fintas)
		w_move += 0.1
	else:
		w_attack += 0.2
	if Global.player_health < 40.0:
		w_attack += 0.25   # te ve débil: te remata
	if Global.enemy_health < 40.0:
		w_block += 0.1     # herido: se cubre un poco más, pero la furia lo hace atacar
		w_attack += 0.1
	if Time.get_ticks_msec() < no_block_until:
		w_block = 0.0

	w_attack = maxf(w_attack, 0.2)
	w_move = maxf(w_move, 0.05)
	var roll := randf() * (w_attack + w_block + w_move)
	if roll < w_attack:
		_choose_attack()
	elif roll < w_attack + w_block:
		_set_state(State.BLOCK, randf_range(0.5, 1.0))
	else:
		circle_dir = 1.0 if randf() < 0.5 else -1.0
		_set_state(State.CIRCLE, randf_range(0.3, 0.7))


func _choose_attack() -> void:
	var p_heavy := 0.22 + block_habit * 0.5
	if Global.player_blocking:
		p_heavy += 0.25
	if rage:
		p_heavy += 0.12
	var p_feint := 0.12 + punch_habit * 0.05
	var r := randf()
	combo_left = 0
	did_combo = false
	use_left = randf() < 0.5
	if r < p_heavy:
		_start_attack(Attack.HEAVY, _w(0.6, 0.3))
	elif r < p_heavy + p_feint:
		_start_attack(Attack.FEINT, _w(0.25, 0.14))
	else:
		combo_left = randi() % (mini(Global.round_number + 1, 4) + 1)
		_start_attack(Attack.JAB, _w(base_windup, 0.12))


func _start_attack(kind: Attack, windup: float) -> void:
	attack = kind
	_set_state(State.WINDUP, windup)


func _windup_done() -> void:
	if attack == Attack.FEINT:
		# Finta: si te cubrís o pegás, te castiga con el pesado
		if Global.player_blocking or Global.player_punching:
			_start_attack(Attack.HEAVY, _w(0.4, 0.25))
		else:
			# Si no mordiste la finta, entra directo con un jab rápido
			use_left = randf() < 0.5
			_start_attack(Attack.JAB, _w(0.18, 0.1))
	else:
		_strike()


func _strike() -> void:
	var heavy := attack == Attack.HEAVY
	var mult := 1.2 if rage else 1.0
	if _flat_distance() <= Global.enemy_attack_range + 0.4:
		Global.damage_player((heavy_damage if heavy else jab_damage) * mult, heavy)

	var punching_left := use_left and not heavy
	var glove := glove_l if punching_left else glove_r
	var punch_pos := PUNCH_L if punching_left else PUNCH_R
	var rest_pos := REST_L if punching_left else REST_R

	if combo_left > 0 and not heavy and Global.is_fighting():
		combo_left -= 1
		did_combo = true
		use_left = not use_left
		_start_attack(Attack.JAB, _w(0.18, 0.1))
	elif did_combo and not heavy and Global.is_fighting() and randf() < 0.4:
		# Remate: termina el combo con un golpe pesado
		did_combo = false
		_start_attack(Attack.HEAVY, _w(0.45, 0.25))
	else:
		combo_left = 0
		did_combo = false
		_set_state(State.RECOVER, _w(base_recover) * (1.5 if heavy else 1.0))
	_punch_glove(glove, punch_pos, rest_pos)


func _react_to_punch(dist: float) -> void:
	if state in [State.WINDUP, State.BLOCK, State.DODGE, State.LUNGE]:
		return
	# Después de un golpe pesado queda expuesto: ahí podés castigarlo
	if state == State.RECOVER and attack == Attack.HEAVY:
		return
	if dist > Global.enemy_attack_range + 0.7:
		return
	var now := Time.get_ticks_msec()
	var scale := 0.5 if state == State.RECOVER else 1.0
	var roll := randf()
	var p_dodge := minf(0.4 * diff, 0.7) * scale
	var p_block := 0.3 * scale
	if now >= no_dodge_until and roll < p_dodge:
		_start_dodge()
	elif now >= no_block_until and roll < p_dodge + p_block:
		_set_state(State.BLOCK, randf_range(0.4, 0.8))
		parry_time = 0.3
		Global.enemy_parrying = true


func _try_counter(dist: float) -> void:
	if state in [State.WINDUP, State.RECOVER, State.DODGE, State.LUNGE]:
		return
	if dist > Global.enemy_attack_range + 0.4:
		return
	if randf() < minf(0.65 * diff, 0.95):
		combo_left = 0
		did_combo = false
		use_left = randf() < 0.5
		# A veces el contraataque es pesado
		if randf() < 0.2:
			_start_attack(Attack.HEAVY, _w(0.45, 0.25))
		else:
			_start_attack(Attack.JAB, _w(0.2, 0.1))


func _start_dodge() -> void:
	var dir := _dir_to_player()
	var side := Vector3(-dir.z, 0.0, dir.x) * (1.0 if randf() < 0.5 else -1.0)
	# A veces esquiva hacia atrás, a veces de costado
	var back := 0.5 if randf() < 0.6 else 1.1
	dodge_dir = (side - dir * back).normalized()
	no_dodge_until = Time.get_ticks_msec() + 900
	_set_state(State.DODGE, 0.22)


func _after_dodge() -> void:
	if _flat_distance() <= Global.enemy_attack_range + 0.7 and randf() < 0.85:
		combo_left = 0
		did_combo = false
		use_left = randf() < 0.5
		if randf() < 0.25:
			_start_attack(Attack.HEAVY, _w(0.45, 0.25))
		else:
			combo_left = randi() % 2
			_start_attack(Attack.JAB, _w(0.18, 0.1))
	else:
		_decide()


# Salto hacia adelante para cerrar distancia
func _can_lunge() -> bool:
	return Time.get_ticks_msec() >= no_lunge_until


func _start_lunge() -> void:
	no_lunge_until = Time.get_ticks_msec() + 2500
	_set_state(State.LUNGE, 0.3)


func _after_lunge() -> void:
	if _flat_distance() <= Global.enemy_attack_range + 0.4:
		combo_left = 1
		did_combo = false
		use_left = randf() < 0.5
		_start_attack(Attack.JAB, _w(0.14, 0.1))
	else:
		_decide()


# ------------------------------------------------------------ Estados y animación
func _set_state(new_state: State, duration: float) -> void:
	state = new_state
	state_time = duration
	Global.enemy_blocking = (new_state == State.BLOCK)
	Global.enemy_punching = (new_state == State.WINDUP)
	Global.enemy_parrying = false
	parry_time = 0.0
	var heavy := new_state == State.WINDUP and attack == Attack.HEAVY
	var normal_color := RAGE_COLOR if rage else GLOVE_COLOR
	_set_glove_color(HEAVY_COLOR if heavy else normal_color)
	match new_state:
		State.BLOCK:
			_move_glove(glove_r, GUARD_R, 0.12)
			_move_glove(glove_l, GUARD_L, 0.12)
		State.WINDUP:
			if attack == Attack.HEAVY or not use_left:
				_move_glove(glove_r, WINDUP_R, duration)
				_move_glove(glove_l, REST_L, 0.15)
			else:
				_move_glove(glove_l, WINDUP_L, duration)
				_move_glove(glove_r, REST_R, 0.15)
		_:
			_move_glove(glove_r, REST_R, 0.2)
			_move_glove(glove_l, REST_L, 0.2)
	if heavy:
		Global.notice.emit("¡GOLPE PESADO! ¡Alejate!")


func _move_glove(g: MeshInstance3D, pos: Vector3, t: float) -> void:
	if tweens.has(g.name):
		(tweens[g.name] as Tween).kill()
	var tw := create_tween()
	tw.tween_property(g, "position", pos, t)
	tweens[g.name] = tw


func _punch_glove(g: MeshInstance3D, punch_pos: Vector3, rest_pos: Vector3) -> void:
	if tweens.has(g.name):
		(tweens[g.name] as Tween).kill()
	var tw := create_tween()
	tw.tween_property(g, "position", punch_pos, 0.07)
	tw.tween_property(g, "position", rest_pos, 0.2)
	tweens[g.name] = tw


func _set_glove_color(c: Color) -> void:
	(glove_r.material_override as StandardMaterial3D).albedo_color = c


func _flat_distance() -> float:
	var d := Global.player_position - global_position
	d.y = 0.0
	return d.length()


func _dir_to_player() -> Vector3:
	var d := Global.player_position - global_position
	d.y = 0.0
	return d.normalized()


func _on_enemy_hit(blocked: bool) -> void:
	var mat := body.material_override as StandardMaterial3D
	if flash_tween:
		flash_tween.kill()
	mat.albedo_color = Color(0.6, 0.7, 1.0) if blocked else Color(1, 1, 1)
	flash_tween = create_tween()
	flash_tween.tween_property(mat, "albedo_color", body_color, 0.2)
	# Un golpe limpio interrumpe el ataque, salvo el pesado (super armadura).
	# Además, a mayor dificultad y en furia, a veces aguanta el golpe y sigue.
	if not blocked and state == State.WINDUP and attack != Attack.HEAVY:
		var armor := 0.15 * (diff - 1.0) + (0.35 if rage else 0.0)
		if randf() >= armor:
			combo_left = 0
			did_combo = false
			_set_state(State.RECOVER, 0.3)
	# Si lo golpeás, a veces devuelve el golpe enseguida
	elif not blocked and (state == State.APPROACH or state == State.CIRCLE) and randf() < 0.5:
		use_left = randf() < 0.5
		combo_left = 0
		_start_attack(Attack.JAB, _w(0.2, 0.1))


func _on_died() -> void:
	ko = true
	_set_state(State.RECOVER, 99.0)
	$CollisionShape3D.set_deferred("disabled", true)
	var t := create_tween().set_parallel(true)
	t.tween_property(self, "rotation:x", deg_to_rad(90.0), 0.6)
	t.tween_property(self, "position:y", 0.3, 0.6)
