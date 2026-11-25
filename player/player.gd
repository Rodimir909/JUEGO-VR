extends CharacterBody3D
## Un solo jugador para webcam y teclado. Los impactos se resuelven en física.
signal pause_requested
signal pause_hold_progress(progress: float)
signal cursor_updated(pos: Vector2, hand_visible: bool, pinch: bool)
signal punch_landed(target: Node, side: String, damage: float, force: float)

@export var udp_port := 4242
@export var glove_smoothing := 28.0
@export var head_smoothing := 14.0
@export var punch_start_speed := 1.35
@export var punch_max_speed := 6.5
@export var move_speed := 2.6
const PACKET_TIMEOUT := 0.55
const REST_LEFT := Vector3(-0.28, 1.28, -0.42)
const REST_RIGHT := Vector3(0.28, 1.28, -0.42)
const ANCHOR_LEFT := Vector3(-0.25, 1.2, 0)
const ANCHOR_RIGHT := Vector3(0.25, 1.2, 0)

@onready var left_glove: Area3D = $LeftGlove
@onready var right_glove: Area3D = $RightGlove
@onready var head: Node3D = $Head
@onready var camera: Camera3D = $Head/Camera3D
var udp := PacketPeerUDP.new()
var command_udp := PacketPeerUDP.new()
var packet_age := 99.0
var left_age := 99.0
var right_age := 99.0
var left_target := REST_LEFT
var right_target := REST_RIGHT
var head_target := Vector3.ZERO
var rotation_target := Vector3.ZERO
var previous_gloves := {"left": Vector3.ZERO, "right": Vector3.ZERO}
var was_tracking := false
var valid_body_age := 0.0
var had_valid_body := false
var loss_notified := false
var keyboard_override := false
var tracking_guard := false
var pause_pose := false
var pause_hold := 0.0
var pause_latched := false
var pause_release := 0.0
var last_frame := -1
var last_capture := -1.0
var keyboard_cooldown := 0.0
var manual_attack := {"left": 0.0, "right": 0.0}

class PunchState:
	var last_pos := Vector3.ZERO
	var last_t := -1.0
	var velocity := Vector3.ZERO
	var active := false
	var peak := 0.0
	var elapsed := 0.0
	var grace := 99.0
	var hit_done := true
	var cooldown := 0.0

var punches := {"left": PunchState.new(), "right": PunchState.new()}

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	add_to_group("player")
	keyboard_override = Global.keyboard_override
	_style_glove(left_glove, false)
	_style_glove(right_glove, true)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if udp.bind(udp_port, "127.0.0.1") != OK:
		Global.tracking_status = "Puerto de webcam ocupado · Usá teclado y mouse"
	command_udp.set_dest_address("127.0.0.1", udp_port + 1)
	left_glove.position = REST_LEFT
	right_glove.position = REST_RIGHT
	previous_gloves["left"] = left_glove.global_position
	previous_gloves["right"] = right_glove.global_position
	Global.camera_active = false
	Global.tracking_ready = false

func _exit_tree() -> void:
	udp.close()
	command_udp.close()

func _input(event: InputEvent) -> void:
	if event.is_action_pressed("recalibrate"):
		command_udp.put_packet("calibrate".to_utf8_buffer())
		_clear_punches()
	elif event.is_action_pressed("keyboard_mode"):
		keyboard_override = not keyboard_override
		Global.keyboard_override = keyboard_override
		_clear_punches()
		Global.notice.emit("Teclado y mouse" if keyboard_override else "Webcam automática")

func _process(delta: float) -> void:
	packet_age += delta
	valid_body_age += delta
	left_age += delta
	right_age += delta
	var bytes := PackedByteArray()
	while udp.get_available_packet_count() > 0:
		bytes = udp.get_packet()
	if not bytes.is_empty():
		var data: Variant = JSON.parse_string(bytes.get_string_from_utf8())
		if data is Dictionary:
			_read_packet(data)
	var tracking := packet_age < PACKET_TIMEOUT and not keyboard_override
	Global.camera_active = tracking
	if not tracking:
		tracking_guard = false
		pause_pose = false
		Global.tracking_ready = false
		cursor_updated.emit(Vector2.ZERO, false, false)
		if was_tracking and not keyboard_override and Global.is_fighting() and not get_tree().paused:
			_clear_punches()
			Global.notice.emit("Se perdió la webcam. Revisá la cámara o pulsá K para usar teclado.")
			pause_requested.emit()
		Global.tracking_status = "TECLADO Y MOUSE · K: webcam · C: calibrar"
	elif not Global.tracking_ready:
		Global.tracking_status = "WEBCAM · Calibrando: mirá al frente con las manos en guardia · K: teclado"
	else:
		Global.tracking_status = "WEBCAM · Izq. %s / Der. %s · C: calibrar · K: teclado" % ["OK" if left_age < 0.25 else "perdida", "OK" if right_age < 0.25 else "perdida"]
	if tracking and had_valid_body and valid_body_age > 0.8 and not loss_notified and Global.is_fighting() and not get_tree().paused:
		loss_notified = true
		Global.notice.emit("Cuerpo fuera de cámara. Recuperá la pose o pulsá K para usar teclado.")
		pause_requested.emit()
	was_tracking = tracking
	if tracking and left_age > 0.25:
		left_target = REST_LEFT
		_reset_punch("left")
	if tracking and right_age > 0.25:
		right_target = REST_RIGHT
		_reset_punch("right")
	_update_pause(delta)
	if get_tree().paused:
		_clear_punches()
		return
	if tracking and not Global.tracking_ready and Global.phase == Global.Phase.INTRO:
		Global.phase_time = Global.INTRO_TIME

func _physics_process(delta: float) -> void:
	if get_tree().paused:
		return
	var tracking := Global.camera_active
	var fighting := Global.is_fighting()
	keyboard_cooldown = maxf(keyboard_cooldown - delta, 0.0)
	for side in punches:
		var state: PunchState = punches[side]
		state.cooldown = maxf(state.cooldown - delta, 0.0)
		state.grace += delta
		if state.active:
			state.elapsed += delta
			if state.elapsed > 0.45:
				state.active = false
				state.grace = 0.0
		manual_attack[side] = maxf(float(manual_attack[side]) - delta, 0.0)

	var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_back") if fighting else Vector2.ZERO
	var wish := global_basis * Vector3(input_dir.x, 0, input_dir.y)
	velocity.x = wish.x * move_speed
	velocity.z = wish.z * move_speed
	velocity.y = 0.0 if is_on_floor() else velocity.y - 9.8 * delta
	move_and_slide()
	# Las cuerdas de los modelos son finas: este límite mantiene a ambos dentro.
	position.x = clampf(position.x, -3.7, 3.7)
	position.z = clampf(position.z, -3.7, 3.7)
	var to_enemy := Global.enemy_position - global_position
	to_enemy.y = 0.0
	if to_enemy.length() > 0.1:
		rotation.y = lerp_angle(rotation.y, atan2(-to_enemy.x, -to_enemy.z), 1.0 - exp(-8.0 * delta))

	if not tracking:
		head_target = Vector3(0, -0.34 if Input.is_action_pressed("duck") and fighting else 0.0, 0)
		rotation_target = Vector3.ZERO
		left_target = REST_LEFT
		right_target = REST_RIGHT
		if fighting and keyboard_cooldown <= 0.0 and not Input.is_action_pressed("block"):
			if Input.is_action_just_pressed("punch_left"):
				_keyboard_punch("left")
			elif Input.is_action_just_pressed("punch_right"):
				_keyboard_punch("right")
		for side in manual_attack:
			var remaining := float(manual_attack[side])
			if remaining > 0.0:
				var extension := sin(clampf((0.3 - remaining) / 0.3, 0, 1) * PI)
				var target := (REST_LEFT if side == "left" else REST_RIGHT) + Vector3(0, 0.05, -0.95) * extension
				if side == "left":
					left_target = target
				else:
					right_target = target

	Global.player_punching = fighting and (punches["left"].active or punches["right"].active)
	Global.player_blocking = fighting and not Global.player_punching and (tracking_guard if tracking else Input.is_action_pressed("block"))
	if not tracking and Global.player_blocking:
		left_target = Vector3(-0.17, 1.48, -0.42)
		right_target = Vector3(0.17, 1.48, -0.42)
	var head_weight := 1.0 - exp(-head_smoothing * delta)
	head.position = head.position.lerp(Vector3(0, 1.6, 0) + head_target, head_weight)
	head.rotation = head.rotation.lerp(rotation_target, head_weight)
	Global.player_head_offset = head.position - Vector3(0, 1.6, 0)
	Global.player_position = global_position
	# Los guantes acompañan el torso al agacharse sin arrastrar el giro de mirada.
	var body_offset := head_target * Vector3(0.8, 0.85, 0.4)
	var weight := 1.0 - exp(-glove_smoothing * delta)
	left_glove.position = left_glove.position.lerp(left_target + body_offset, weight)
	right_glove.position = right_glove.position.lerp(right_target + body_offset, weight)
	_check_hit("left", left_glove)
	_check_hit("right", right_glove)

func _read_packet(data: Dictionary) -> void:
	var capture := _number(data.get("t"), -1.0)
	if capture < 0.0:
		return
	var sequence := int(_number(data.get("frame"), -1))
	# Aceptar el reinicio del proceso de Python después de una desconexión.
	if packet_age > PACKET_TIMEOUT:
		last_capture = -1.0
		last_frame = -1
	if capture <= last_capture or (sequence >= 0 and sequence <= last_frame):
		return
	last_capture = capture
	last_frame = sequence
	packet_age = 0.0
	if keyboard_override:
		return
	Global.tracking_ready = bool(data.get("calibrated", false))
	for side in punches:
		var arm: Variant = data.get(side)
		if not arm is Dictionary or not arm.get("rel") is Dictionary:
			_reset_punch(side)
			continue
		var wrist: Variant = arm.get("wrist")
		if not wrist is Dictionary or _number(wrist.get("visibility"), 0.0) < 0.5:
			_reset_punch(side)
			continue
		var rel: Dictionary = arm["rel"]
		var offset := Vector3(_number(rel.get("x"), 0), _number(rel.get("y"), 0), _number(rel.get("z"), -0.5))
		offset *= Vector3(0.65, 0.65, 0.95)
		offset = offset.clamp(Vector3(-0.85, -0.55, -1.45), Vector3(0.85, 0.65, -0.12))
		var target := (ANCHOR_LEFT if side == "left" else ANCHOR_RIGHT) + offset
		if side == "left":
			left_target = target
			left_age = 0.0
		else:
			right_target = target
			right_age = 0.0
		if Global.tracking_ready:
			_track_punch(side, target, capture)
	var h: Variant = data.get("head")
	if h is Dictionary and h.get("valid", false):
		valid_body_age = 0.0
		had_valid_body = true
		loss_notified = false
		head_target = Vector3(clampf(_number(h.get("x"), 0) * 1.4, -0.34, 0.34), clampf(_number(h.get("y"), 0) * 1.4, -0.45, 0.12), clampf(-_number(h.get("z"), 0) * 0.4, -0.15, 0.15))
		rotation_target = Vector3(deg_to_rad(clampf(_number(h.get("pitch"), 0), -18, 18)), deg_to_rad(clampf(-_number(h.get("yaw"), 0), -22, 22)), deg_to_rad(clampf(-_number(h.get("roll"), 0) * 0.25, -8, 8)))
	else:
		head_target = Vector3.ZERO
		rotation_target = Vector3.ZERO
	tracking_guard = bool(data.get("guard", false)) and left_age < 0.2 and right_age < 0.2
	pause_pose = bool(data.get("pause_pose", false))
	var cursor: Variant = data.get("cursor")
	if cursor is Dictionary and cursor.get("visible", false):
		cursor_updated.emit(Vector2(clampf(_number(cursor.get("x"), 0.5), 0, 1), clampf(_number(cursor.get("y"), 0.5), 0, 1)), true, bool(cursor.get("pinch", false)))
	else:
		cursor_updated.emit(Vector2.ZERO, false, false)

func _number(value: Variant, fallback: float) -> float:
	if (value is float or value is int) and is_finite(float(value)):
		return float(value)
	return fallback

func _track_punch(side: String, target: Vector3, capture: float) -> void:
	var state: PunchState = punches[side]
	if not Global.is_fighting() or get_tree().paused or Time.get_ticks_msec() < Global.player_stun_until:
		_reset_punch(side)
		return
	if state.last_t >= 0.0:
		var dt := capture - state.last_t
		var movement := target - state.last_pos
		if dt > 0.005 and dt < 0.3 and movement.length() < maxf(0.65, dt * 8.0):
			var alpha := 1.0 - exp(-25.0 * dt)
			state.velocity = state.velocity.lerp(movement / dt, alpha)
			var speed := state.velocity.length()
			var advancing := state.velocity.z < -0.25
			if not state.active and state.cooldown <= 0.0 and speed >= punch_start_speed and advancing:
				state.active = true
				state.hit_done = false
				state.peak = speed
				state.elapsed = 0.0
				state.grace = 99.0
				state.cooldown = 0.28
			elif state.active:
				state.peak = maxf(state.peak, speed)
				if speed < 0.65 or state.velocity.z > 0.35:
					state.active = false
					state.grace = 0.0 if state.velocity.z <= 0.35 else 99.0
		else:
			_reset_punch(side)
	state.last_pos = target
	state.last_t = capture

func _keyboard_punch(side: String) -> void:
	if Time.get_ticks_msec() < Global.player_stun_until:
		return
	keyboard_cooldown = 0.34
	manual_attack[side] = 0.3
	var state: PunchState = punches[side]
	state.active = true
	state.hit_done = false
	state.peak = 4.0
	state.elapsed = 0.0
	state.grace = 99.0

func _reset_punch(side: String) -> void:
	var state: PunchState = punches[side]
	state.last_t = -1.0
	state.velocity = Vector3.ZERO
	state.active = false
	state.hit_done = true
	state.peak = 0.0
	state.grace = 99.0

func _clear_punches() -> void:
	_reset_punch("left")
	_reset_punch("right")

func _check_hit(side: String, glove: Area3D) -> void:
	var previous: Vector3 = previous_gloves[side]
	var current := glove.global_position
	previous_gloves[side] = current
	var state: PunchState = punches[side]
	if not Global.is_fighting() or state.hit_done or not (state.active or state.grace < 0.10):
		return
	# Barrido de todo el recorrido: un puño rápido no atraviesa al rival entre frames.
	var shape := CapsuleShape3D.new()
	shape.radius = 0.15
	shape.height = maxf(0.3, previous.distance_to(current) + 0.3)
	var basis := Basis.IDENTITY
	if previous.distance_to(current) > 0.001:
		basis = Basis(Quaternion(Vector3.UP, (current - previous).normalized()))
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape
	query.transform = Transform3D(basis, (previous + current) * 0.5)
	query.collision_mask = 2
	query.exclude = [get_rid()]
	for result in get_world_3d().direct_space_state.intersect_shape(query, 8):
		var target: Object = result["collider"]
		if target.has_method("take_punch"):
			var force := clampf(inverse_lerp(punch_start_speed, punch_max_speed, state.peak), 0.0, 1.0)
			var damage := lerpf(9.0, 30.0, pow(force, 1.2))
			state.hit_done = true
			target.take_punch(damage, force, side)
			punch_landed.emit(target, side, damage, force)
			return

func _update_pause(delta: float) -> void:
	if get_tree().paused or not Global.camera_active:
		pause_hold = 0.0
		pause_hold_progress.emit(0.0)
		return
	if not pause_pose:
		pause_release += delta
		if pause_release > 0.25:
			pause_hold = 0.0
			pause_latched = false
	else:
		pause_release = 0.0
		if not pause_latched:
			pause_hold += delta
			if pause_hold > 1.2:
				pause_latched = true
				pause_hold = 0.0
				pause_requested.emit()
	pause_hold_progress.emit(pause_hold / 1.2)

func _style_glove(glove: Area3D, right: bool) -> void:
	var main := glove.get_node("MeshInstance3D") as MeshInstance3D
	main.scale = Vector3(1.0, 0.94, 1.25)
	var thumb := MeshInstance3D.new()
	var thumb_mesh := SphereMesh.new()
	thumb_mesh.radius = 0.045
	thumb_mesh.height = 0.12
	thumb_mesh.material = (main.mesh as PrimitiveMesh).material
	thumb.mesh = thumb_mesh
	thumb.position = Vector3(-0.095 if right else 0.095, -0.04, 0.02)
	glove.add_child(thumb)
	var cuff := MeshInstance3D.new()
	var cuff_mesh := CylinderMesh.new()
	cuff_mesh.top_radius = 0.085
	cuff_mesh.bottom_radius = 0.085
	cuff_mesh.height = 0.09
	var cuff_material := StandardMaterial3D.new()
	cuff_material.albedo_color = Color("e5e8ef")
	cuff_mesh.material = cuff_material
	cuff.mesh = cuff_mesh
	cuff.position.z = 0.13
	cuff.rotation.x = PI / 2
	glove.add_child(cuff)
