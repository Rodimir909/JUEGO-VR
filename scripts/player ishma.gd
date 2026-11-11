extends CharacterBody3D

@export var speed := 6.0
@export var mouse_sensitivity := 0.0025
@export var punch_cooldown := 0.2
@export var camera_tracking_speed := 4.0

const REST_R := Vector3(0.3, -0.3, -0.6)
const REST_L := Vector3(-0.3, -0.3, -0.6)
const GUARD_R := Vector3(0.12, -0.08, -0.5)
const GUARD_L := Vector3(-0.12, -0.08, -0.5)
const PUNCH_R := Vector3(0.05, -0.1, -1.1)
const PUNCH_L := Vector3(-0.05, -0.1, -1.1)

@onready var head: Node3D = $Head
@onready var ray: RayCast3D = $Head/Camera3D/RayCast3D
@onready var glove_r: MeshInstance3D = $Head/Camera3D/GloveR
@onready var glove_l: MeshInstance3D = $Head/Camera3D/GloveL

var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")
var can_punch := true
var punch_cooldown_remaining := 0.0
var punch_tween: Tween
var active_glove: MeshInstance3D = null


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	ray.add_exception(self)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		rotate_y(-event.relative.x * mouse_sensitivity)
		head.rotate_x(-event.relative.y * mouse_sensitivity)
		head.rotation.x = clampf(head.rotation.x, deg_to_rad(-60.0), deg_to_rad(60.0))
	elif event.is_action_pressed("ui_cancel"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event is InputEventMouseButton and event.pressed and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _physics_process(delta: float) -> void:
	if not can_punch:
		punch_cooldown_remaining = maxf(punch_cooldown_remaining - delta, 0.0)
		can_punch = punch_cooldown_remaining == 0.0

	if not is_on_floor():
		velocity.y -= gravity * delta
	else:
		velocity.y = 0.0

	var fighting = Global.is_fighting()
	var stunned = Time.get_ticks_msec() < Global.player_stun_until
	var wish := Vector3.ZERO

	if fighting:
		# Cubrirse (tecla E)
		Global.player_blocking = Input.is_action_pressed("block") and not Global.player_punching
		var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
		var spd := speed
		if Global.player_blocking or stunned:
			spd *= 0.5
		wish = (transform.basis * Vector3(input_dir.x, 0.0, input_dir.y)).normalized() * spd
	else:
		Global.player_blocking = false

	velocity.x = wish.x
	velocity.z = wish.z
	move_and_slide()
	Global.player_position = global_position
	_track_enemy(delta)

	# Golpear: clic izquierdo = guante izquierdo, clic derecho = guante derecho
	if fighting and can_punch and not Global.player_blocking and not stunned:
		if Input.is_action_just_pressed("punch_left"):
			_punch(true)
		elif Input.is_action_just_pressed("punch_right"):
			_punch(false)

	# Animación de guantes
	var guard = Global.player_blocking
	if glove_l != active_glove:
		glove_l.position = glove_l.position.lerp(GUARD_L if guard else REST_L, 15.0 * delta)
	if glove_r != active_glove:
		glove_r.position = glove_r.position.lerp(GUARD_R if guard else REST_R, 15.0 * delta)


func _track_enemy(delta: float) -> void:
	if Global.phase not in [Global.Phase.INTRO, Global.Phase.FIGHTING]:
		return

	var target := Global.enemy_position + Vector3.UP * 1.1
	var to_enemy := target - head.global_position
	var horizontal_distance := Vector2(to_enemy.x, to_enemy.z).length()
	if horizontal_distance <= 0.01:
		return

	var target_yaw := atan2(-to_enemy.x, -to_enemy.z)
	var target_pitch := clampf(atan2(to_enemy.y, horizontal_distance), deg_to_rad(-60.0), deg_to_rad(60.0))
	var weight := clampf(camera_tracking_speed * delta, 0.0, 1.0)
	rotation.y = lerp_angle(rotation.y, target_yaw, weight)
	head.rotation.x = lerpf(head.rotation.x, target_pitch, weight)


func _punch(left: bool) -> void:
	can_punch = false
	punch_cooldown_remaining = punch_cooldown
	Global.player_punching = true
	var glove := glove_l if left else glove_r
	var punch_pos := PUNCH_L if left else PUNCH_R
	var rest_pos := REST_L if left else REST_R
	active_glove = glove
	if punch_tween:
		punch_tween.kill()
	punch_tween = create_tween()
	punch_tween.tween_property(glove, "position", punch_pos, 0.08)
	punch_tween.tween_callback(_check_hit)
	punch_tween.tween_property(glove, "position", rest_pos, 0.18)
	punch_tween.tween_callback(_punch_finished)


func _punch_finished() -> void:
	Global.player_punching = false
	active_glove = null


func _check_hit() -> void:
	# RayCast3D ya actualiza su resultado en cada tick de física.
	if ray.is_colliding():
		var target := ray.get_collider()
		if target and target.is_in_group("enemy"):
			Global.hit_enemy()
