extends CharacterBody3D
## Rival con anticipación visible, impactos al extender el brazo y recuperación.
enum State { APPROACH, CIRCLE, WINDUP, STRIKE, RECOVER, BLOCK, DODGE }
@onready var rig: Node3D = $BoxerRig
@onready var arm_left: Node3D = $BoxerRig/ArmLeftPivot
@onready var arm_right: Node3D = $BoxerRig/ArmRightPivot
var config: Dictionary
var state: State = State.RECOVER
var state_time := 0.8
var heavy := false
var use_left := false
var combo_left := 0
var impact_done := false
var ko := false
var circle_dir := 1.0
var idle_time := 0.0
var reaction_cooldown := 0.0
var previous_punch := false
var attack_tween: Tween
var flash_tween: Tween
var rest_left := Vector3.ZERO
var rest_right := Vector3.ZERO
var warning_material: StandardMaterial3D
var aimed_offset := Vector3.ZERO

func _ready() -> void:
	config = Global.level_config()
	_load_boxer(str(config["model"]))
	rest_left = arm_left.position
	rest_right = arm_right.position
	collision_layer = 2
	collision_mask = 5
	Global.enemy_hit.connect(_on_hit)
	Global.enemy_died.connect(_on_died)
	warning_material = StandardMaterial3D.new()
	warning_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	warning_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	warning_material.albedo_color = Color(1.0, 0.5, 0.05, 0.35)

func _load_boxer(model: String) -> void:
	var prefix := "res://Texturas/boxeador_%s_" % model
	$BoxerRig/BoxerBody.mesh = load(prefix + "body.obj")
	$BoxerRig/ArmLeftPivot/ArmLeftMesh.mesh = load(prefix + "left_arm.obj")
	$BoxerRig/ArmRightPivot/ArmRightMesh.mesh = load(prefix + "right_arm.obj")

func take_punch(damage: float, _force: float = 0.0, _side: String = "") -> void:
	if not ko:
		Global.damage_enemy(damage)

func _physics_process(delta: float) -> void:
	Global.enemy_position = global_position
	velocity.y = 0.0 if is_on_floor() else velocity.y - 9.8 * delta
	velocity.x = 0.0
	velocity.z = 0.0
	if ko or not Global.is_fighting():
		move_and_slide()
		return
	idle_time += delta
	rig.position.y = sin(idle_time * 4.0) * 0.018
	rig.rotation.z = sin(idle_time * 2.0) * 0.02
	var offset := Global.player_position - global_position
	offset.y = 0
	var distance := offset.length()
	var direction := offset.normalized()
	if distance > 0.1:
		rotation.y = lerp_angle(rotation.y, atan2(-direction.x, -direction.z), 1.0 - exp(-9 * delta))
	state_time -= delta
	reaction_cooldown = maxf(reaction_cooldown - delta, 0.0)
	var new_punch := Global.player_punching and not previous_punch
	previous_punch = Global.player_punching
	if new_punch and reaction_cooldown <= 0 and state in [State.APPROACH, State.CIRCLE] and distance < 1.9:
		_react()
	var speed := 1.55 + float(Global.level_index) * 0.25
	match state:
		State.APPROACH:
			if distance > 1.15:
				velocity += direction * speed
			if distance <= 1.25:
				_decide()
		State.CIRCLE:
			velocity += Vector3(-direction.z, 0, direction.x) * circle_dir * speed * 0.45
			velocity += direction * clampf(distance - 1.2, -0.5, 0.6)
			if state_time <= 0:
				_decide()
		State.WINDUP:
			if state_time <= 0:
				_start_strike()
		State.STRIKE:
			if not impact_done and state_time <= 0.12:
				impact_done = true
				if distance <= Global.enemy_attack_range + (0.1 if heavy else 0.0):
					Global.damage_player(1.8 if heavy else 1.0, heavy, aimed_offset)
			if state_time <= 0 and Global.is_fighting():
				if combo_left > 0 and not heavy:
					combo_left -= 1
					use_left = not use_left
					_start_attack(false, true)
				else:
					_set_state(State.RECOVER, float(config["recover"]) * (1.35 if heavy else 1.0))
		State.RECOVER, State.BLOCK:
			if state_time <= 0:
				_decide()
		State.DODGE:
			velocity += Vector3(-direction.z, 0, direction.x) * circle_dir * 2.8
			if state_time <= 0:
				_set_state(State.RECOVER, 0.6)
	# No superponer cuerpos y mantener el combate al alcance de los guantes.
	if distance < 1.02:
		velocity -= direction * 1.3
	move_and_slide()
	position.x = clampf(position.x, -3.7, 3.7)
	position.z = clampf(position.z, -3.7, 3.7)
	Global.enemy_position = global_position

func _decide() -> void:
	if not Global.is_fighting():
		return
	if global_position.distance_to(Global.player_position) > 1.5:
		_set_state(State.APPROACH, 1.0)
		return
	var roll := randf()
	if roll < 0.12 + Global.level_index * 0.05:
		_set_state(State.BLOCK, randf_range(0.45, 0.7))
	elif roll < 0.3:
		circle_dir = -1.0 if randf() < 0.5 else 1.0
		_set_state(State.CIRCLE, randf_range(0.4, 0.7))
	else:
		use_left = randf() < 0.5
		var is_heavy := randf() < (0.15 + Global.level_index * 0.09 + (0.15 if Global.player_blocking else 0.0))
		combo_left = randi_range(0, int(config["combos"]) - 1) if not is_heavy else 0
		_start_attack(is_heavy)

func _react() -> void:
	reaction_cooldown = 1.6
	var roll := randf()
	if roll < 0.08 + Global.level_index * 0.09:
		_set_state(State.BLOCK, 0.5)
	elif Global.level_index > 0 and roll < 0.17 + Global.level_index * 0.09:
		circle_dir = -1.0 if randf() < 0.5 else 1.0
		_set_state(State.DODGE, 0.22)

func _start_attack(is_heavy: bool, combo := false) -> void:
	aimed_offset = Global.player_head_offset
	heavy = is_heavy
	impact_done = false
	var windup := float(config["windup"]) * (1.5 if heavy else 1.0)
	if combo:
		windup = maxf(windup * 0.8, 0.32)
	_set_state(State.WINDUP, windup)
	var arm := arm_left if use_left else arm_right
	if attack_tween:
		attack_tween.kill()
	attack_tween = create_tween()
	attack_tween.tween_property(arm, "rotation:y", 0.3 if use_left else -0.3, windup)
	if heavy:
		Global.notice.emit("¡GOLPE PESADO! Alejate o esquivá de costado")
		_set_warning(true)

func _start_strike() -> void:
	_set_state(State.STRIKE, 0.24)
	var arm := arm_left if use_left else arm_right
	var rest := rest_left if use_left else rest_right
	if attack_tween:
		attack_tween.kill()
	attack_tween = create_tween()
	attack_tween.tween_property(arm, "position", rest + Vector3(0, 0, 0.95), 0.12)
	attack_tween.parallel().tween_property(arm, "rotation:y", -0.35 if use_left else 0.35, 0.12)
	attack_tween.tween_property(arm, "position", rest, 0.12)
	attack_tween.parallel().tween_property(arm, "rotation:y", 0.0, 0.12)

func _set_state(next: State, duration: float) -> void:
	state = next
	state_time = duration
	Global.enemy_blocking = state == State.BLOCK
	Global.enemy_punching = state in [State.WINDUP, State.STRIKE]
	Global.enemy_parrying = false
	if state not in [State.WINDUP, State.STRIKE]:
		_set_warning(false)
		if attack_tween:
			attack_tween.kill()
		arm_left.position = rest_left
		arm_right.position = rest_right
		arm_left.rotation = Vector3(0, 0.25 if state == State.BLOCK else 0.0, 0)
		arm_right.rotation = Vector3(0, -0.25 if state == State.BLOCK else 0.0, 0)

func _set_warning(active: bool) -> void:
	$BoxerRig/ArmLeftPivot/ArmLeftMesh.material_overlay = warning_material if active else null
	$BoxerRig/ArmRightPivot/ArmRightMesh.material_overlay = warning_material if active else null

func _on_hit(blocked: bool) -> void:
	if ko:
		return
	if flash_tween:
		flash_tween.kill()
	rig.scale = Vector3(-0.62, 0.62, -0.62) * (1.015 if blocked else 1.035)
	flash_tween = create_tween()
	flash_tween.tween_property(rig, "scale", Vector3(-0.62, 0.62, -0.62), 0.15)
	# Interrumpir un jab recompensa pegar a tiempo. Un pesado sigue anunciado.
	if not blocked and state == State.WINDUP and not heavy:
		combo_left = 0
		_set_state(State.RECOVER, 0.6)

func _on_died() -> void:
	ko = true
	_set_state(State.RECOVER, 99)
	$CollisionShape3D.set_deferred("disabled", true)
	var tween := create_tween().set_parallel(true)
	tween.tween_property(self, "rotation:x", deg_to_rad(85), 0.55)
	tween.tween_property(self, "position:y", 0.3, 0.55)
