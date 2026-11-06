extends CharacterBody3D

# =====================================================================
# Jugador en PRIMERA PERSONA controlado por webcam (MediaPipe via UDP)
#   - Brazos   -> guantes + FUERZA de cada piña (velocidad del guante)
#   - Cabeza   -> rotacion de camara + esquivar/agacharse
#   - Guardia  -> manos en la cara = invulnerable a golpes
#   - Pausa    -> mano arriba ~1 s = pausa; en el menu la mano mueve un cursor
# Todos los valores de abajo se pueden ajustar desde el Inspector.
#
# CONTRATO CON LOS ENEMIGOS
#   - Para RECIBIR piñas, el enemigo (cuerpo o area) necesita el metodo:
#         func take_punch(damage: float, force: float, side: String) -> void
#   - Para GOLPEAR al jugador, el enemigo llama:
#         var bloqueado: bool = player.take_hit(damage, self)
# =====================================================================

signal punch_thrown(side: String, force: float)                       # termino una piña (force 0..1)
signal punch_landed(target: Node, side: String, damage: float, force: float)
signal guard_changed(active: bool)
signal blocked(damage: float, attacker: Node)                         # un golpe fue bloqueado por la guardia
signal damaged(damage: float, current_health: float)
signal died
signal pause_requested
signal pause_hold_progress(progress: float)                           # 0..1 mientras mantenes la mano arriba
signal cursor_updated(pos: Vector2, hand_visible: bool, pinch: bool)  # pos normalizada 0..1

@export_group("Red")
@export var udp_port := 4242

@export_group("Camara - rotacion")
# Se multiplica el giro real de tu cabeza: como miras la pantalla, giros poco.
@export var yaw_gain := 1.0
@export var pitch_gain := 0.8
@export var roll_gain := 0.3
@export var max_yaw := 40.0     # grados
@export var max_pitch := 30.0
@export var max_roll := 15.0
@export var angle_deadzone := 2.0   # grados que se ignoran (quita temblor)

@export_group("Camara - movimiento (esquivar)")
# Metros reales que te mueves * move_gain = metros que se mueve la camara
@export var move_gain := 1.0
@export var lean_gain := 0.4    # adelante/atras (es lo mas ruidoso)
@export var max_sway := 0.30    # izquierda / derecha
@export var max_duck := 0.45    # agacharse
@export var max_rise := 0.15    # subir
@export var max_lean := 0.15    # adelante / atras
@export var move_deadzone := 0.02   # metros

@export_group("Suavizado")
# Mas alto = mas rapido y mas ruido. Mas bajo = mas suave y mas lag.
@export var head_smoothing := 1000.0
@export var glove_smoothing := 30.0

@export_group("Guantes")
# Metros de juego por cada "ancho de hombros" que se mueve tu muneca.
# Tu brazo mide ~1.7 anchos de hombros, asi que x=0.65 -> brazo de ~1.1 m.
@export var glove_scale := Vector3(0.65, 0.65, 0.75)
@export var min_visibility := 0.5
@export var lost_timeout := 0.4     # seg sin ver la muneca antes de volver a guardia
# Donde estan los "hombros" en el espacio del jugador (el guante parte de ahi)
@export var left_shoulder_anchor := Vector3(-0.25, 0.40, 0.0)
@export var right_shoulder_anchor := Vector3(0.25, 0.40, 0.0)
# Posicion de guardia cuando se pierde el tracking
@export var left_rest := Vector3(-0.25, 0.55, -0.40)
@export var right_rest := Vector3(0.25, 0.55, -0.40)
# Limites de recorrido del guante respecto al hombro (en metros)
@export var glove_limit_min := Vector3(-0.9, -0.7, -1.3)
@export var glove_limit_max := Vector3(0.9, 0.7, 0.2)

@export_group("Piñas - fuerza")
# La fuerza sale de la VELOCIDAD del guante (m/s de juego), medida con los tiempos reales de Python.
@export var punch_start_speed := 1.8    # por encima de esto arranca una piña (y es fuerza 0)
@export var punch_end_speed := 0.9      # por debajo de esto la piña termina
@export var punch_max_speed := 8.0      # a esta velocidad la fuerza es 1.0 (maxima)
@export var speed_smoothing := 0.6      # peso de la muestra nueva (1 = sin suavizar)
@export var punch_grace := 0.12         # seg despues del pico en los que todavia puede conectar (lag del guante)
@export var punch_max_duration := 0.7   # una piña no dura mas que esto
@export var min_damage := 5.0           # daño con fuerza 0
@export var max_damage := 30.0          # daño con fuerza 1
@export var damage_curve := 1.5         # >1: las piñas flojas dañan poco, las fuertes mucho
@export var debug_punch := false        # imprime velocidad pico y fuerza de cada piña (para calibrar)

@export_group("Guardia y vida")
@export var max_health := 100.0
@export var guard_damage_multiplier := 0.0   # 0 = invulnerable en guardia; 0.2 = pasa un 20 %
@export var guard_glow := true               # los guantes brillan mientras estas en guardia

@export_group("Pausa (gesto)")
@export var pause_hold_time := 1.0       # seg con la mano arriba para pausar
@export var pause_release_grace := 0.2   # tolerancia a parpadeos del tracking

const RETRACT_RATIO := 0.5     # si el guante vuelve hacia el cuerpo a mas de esto de su velocidad, no cuenta como piña
const PACKET_TIMEOUT := 0.5    # seg sin paquetes = Python caido / sin tracking

@onready var left_glove: Area3D = $LeftGlove
@onready var right_glove: Area3D = $RightGlove
@onready var head: Node3D = $Head
@onready var camera: Camera3D = $Head/Camera3D

var udp := PacketPeerUDP.new()

var left_target := Vector3.ZERO
var right_target := Vector3.ZERO
var left_lost := 0.0
var right_lost := 0.0

var head_rest := Vector3.ZERO
var head_target_pos := Vector3.ZERO
var head_target_rot := Vector3.ZERO   # (pitch, yaw, roll) en radianes
var head_lost := 0.0

var packet_age := 0.0
var health := 0.0
var guarding := false

var pause_pose := false
var pause_hold := 0.0
var pause_idle := 0.0
var pause_latched := false    # tras pausar hay que bajar la mano antes de poder volver a disparar el gesto


class PunchState:
	var last_pos := Vector3.ZERO
	var last_t := -1.0
	var vel := Vector3.ZERO       # velocidad suavizada (m/s)
	var speed := 0.0
	var peak := 0.0               # velocidad pico de la piña actual
	var active := false
	var elapsed := 0.0
	var since_end := 999.0
	var hit_done := false         # una piña pega una sola vez


var punch := {
	"left": PunchState.new(),
	"right": PunchState.new()
}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS   # sigue leyendo la webcam aunque el juego este en pausa
	add_to_group("player")
	health = max_health

	var error := udp.bind(udp_port, "127.0.0.1")

	if error != OK:
		push_error("No se pudo abrir el puerto UDP %d" % udp_port)
	else:
		print("Esperando datos de Python en el puerto %d..." % udp_port)

	head_rest = head.position
	head_target_pos = head_rest

	left_target = left_rest
	right_target = right_rest
	left_glove.position = left_rest
	right_glove.position = right_rest


func _exit_tree() -> void:
	udp.close()


func _process(delta: float) -> void:
	# Nos quedamos solo con el ULTIMO paquete y lo parseamos UNA vez: si Godot se atrasa,
	# los viejos solo agregan latencia (y parsearlos para tirarlos es CPU desperdiciada).
	var latest: Variant = _read_latest_packet()

	packet_age += delta
	left_lost += delta
	right_lost += delta
	head_lost += delta

	if latest != null:
		packet_age = 0.0
		_read_packet(latest)

	if packet_age > PACKET_TIMEOUT:
		_on_tracking_lost()

	# Si se pierde el tracking, volver a guardia / posicion neutra
	if left_lost > lost_timeout:
		left_target = left_rest
	if right_lost > lost_timeout:
		right_target = right_rest
	if head_lost > 0.6:
		head_target_pos = head_rest
		head_target_rot = Vector3.ZERO

	_tick_punches(delta)
	_update_pause_gesture(delta)

	# En pausa el cuerpo queda congelado; solo seguimos leyendo la webcam (para el cursor)
	if get_tree().paused:
		return

	_update_gloves(delta)
	_update_head(delta)


func _physics_process(_delta: float) -> void:
	if get_tree().paused:
		return
	_check_hits("left", left_glove)
	_check_hits("right", right_glove)


# ---------------------------------------------------------------------
# Lectura del paquete
# ---------------------------------------------------------------------

func _read_latest_packet() -> Variant:
	var count := udp.get_available_packet_count()
	if count == 0:
		return null

	# Se descartan los viejos sin decodificarlos: solo el ultimo se convierte a texto y JSON.
	var bytes := PackedByteArray()
	for i in count:
		bytes = udp.get_packet()

	var parsed: Variant = JSON.parse_string(bytes.get_string_from_utf8())
	if typeof(parsed) == TYPE_DICTIONARY:
		return parsed
	return null


func _read_packet(data: Dictionary) -> void:
	# Reloj de Python (segundos): sirve para calcular velocidades sin depender de los FPS de Godot
	var t := float(data.get("t", Time.get_ticks_msec() / 1000.0))

	var l: Variant = _arm_target(data.get("left"), left_shoulder_anchor)
	if l != null:
		left_target = l
		left_lost = 0.0
		_track_punch("left", l, t)
	else:
		_reset_punch("left")

	var r: Variant = _arm_target(data.get("right"), right_shoulder_anchor)
	if r != null:
		right_target = r
		right_lost = 0.0
		_track_punch("right", r, t)
	else:
		_reset_punch("right")

	_read_head(data.get("head"))

	_set_guard(bool(data.get("guard", false)))
	pause_pose = bool(data.get("pause_pose", false))

	var c: Variant = data.get("cursor")
	if typeof(c) == TYPE_DICTIONARY and bool(c.get("visible", false)):
		cursor_updated.emit(Vector2(float(c["x"]), float(c["y"])), true, bool(c.get("pinch", false)))
	else:
		cursor_updated.emit(Vector2.ZERO, false, false)


func _on_tracking_lost() -> void:
	_set_guard(false)
	pause_pose = false
	cursor_updated.emit(Vector2.ZERO, false, false)


func _arm_target(arm: Variant, anchor: Vector3) -> Variant:

	if typeof(arm) != TYPE_DICTIONARY or not arm.has("rel") or not arm.has("wrist"):
		return null

	var wrist: Variant = arm["wrist"]
	if typeof(wrist) != TYPE_DICTIONARY or float(wrist.get("visibility", 0.0)) < min_visibility:
		return null

	var rel: Dictionary = arm["rel"]

	# rel.x: derecha+ | rel.y: arriba+ | rel.z: negativo = hacia la pantalla
	# En Godot adelante es -Z, asi que el signo de z ya coincide.
	var offset := Vector3(
		float(rel["x"]) * glove_scale.x,
		float(rel["y"]) * glove_scale.y,
		float(rel["z"]) * glove_scale.z
	)

	offset = offset.clamp(glove_limit_min, glove_limit_max)

	return anchor + offset


func _read_head(h: Variant) -> void:

	if typeof(h) != TYPE_DICTIONARY or not h.get("valid", false):
		return

	var yaw := clampf(_deadzone(float(h["yaw"]), angle_deadzone) * yaw_gain, -max_yaw, max_yaw)
	var pitch := clampf(_deadzone(float(h["pitch"]), angle_deadzone) * pitch_gain, -max_pitch, max_pitch)
	var roll := clampf(_deadzone(float(h["roll"]), angle_deadzone) * roll_gain, -max_roll, max_roll)

	# Python: yaw+ = giras a tu derecha, pitch+ = miras arriba, roll+ = inclinas a la derecha
	# Godot:  girar a la derecha = rotation.y NEGATIVO, mirar arriba = rotation.x POSITIVO,
	#         inclinar a la derecha = rotation.z NEGATIVO
	head_target_rot = Vector3(
		deg_to_rad(pitch),
		deg_to_rad(-yaw),
		deg_to_rad(-roll)
	)

	var sway := clampf(_deadzone(float(h["x"]), move_deadzone) * move_gain, -max_sway, max_sway)
	var rise := clampf(_deadzone(float(h["y"]), move_deadzone) * move_gain, -max_duck, max_rise)
	var lean := clampf(_deadzone(float(h["z"]), move_deadzone) * lean_gain, -max_lean, max_lean)

	# lean+ = te acercas a la pantalla = camara hacia adelante (-Z)
	head_target_pos = head_rest + Vector3(sway, rise, -lean)

	head_lost = 0.0


func _deadzone(value: float, zone: float) -> float:
	if absf(value) <= zone:
		return 0.0
	return value - signf(value) * zone


# ---------------------------------------------------------------------
# Fuerza de la piña
# ---------------------------------------------------------------------
# Cada paquete trae la posicion objetivo del guante y el tiempo real de captura (t).
# Velocidad = distancia / tiempo entre paquetes. Cuando supera punch_start_speed arranca
# una piña, se guarda la velocidad PICO y al bajar de punch_end_speed la piña termina.
# La fuerza (0..1) sale de ese pico y se convierte en daño cuando el guante toca un enemigo.

func _track_punch(side: String, pos: Vector3, t: float) -> void:
	if get_tree().paused:
		_reset_punch(side)
		return

	var s: PunchState = punch[side]
	if s.last_t >= 0.0:
		var dt := t - s.last_t
		if dt > 0.001 and dt < 0.25:
			var raw_vel := (pos - s.last_pos) / dt
			s.vel = s.vel.lerp(raw_vel, speed_smoothing)
			s.speed = s.vel.length()
			_step_punch(side, s)
		elif dt >= 0.25:
			s.vel = Vector3.ZERO
			s.speed = 0.0
	s.last_pos = pos
	s.last_t = t


func _step_punch(side: String, s: PunchState) -> void:
	# +Z = el guante vuelve hacia tu cuerpo (retroceso de la piña, no cuenta)
	var retracting: bool = s.vel.z > RETRACT_RATIO * s.speed

	if not s.active:
		if s.speed >= punch_start_speed and not retracting:
			s.active = true
			s.hit_done = false
			s.elapsed = 0.0
			s.peak = s.speed
	else:
		s.peak = maxf(s.peak, s.speed)
		if s.speed <= punch_end_speed or retracting:
			_end_punch(side, s)


func _end_punch(side: String, s: PunchState) -> void:
	s.active = false
	s.since_end = 0.0
	var f := _force_from_speed(s.peak)
	if debug_punch:
		print("[%s] piña: pico %.2f m/s -> fuerza %.2f -> daño %.1f" % [side, s.peak, f, force_to_damage(f)])
	punch_thrown.emit(side, f)


func _reset_punch(side: String) -> void:
	var s: PunchState = punch[side]
	s.last_t = -1.0
	s.vel = Vector3.ZERO
	s.speed = 0.0
	s.active = false


func _tick_punches(delta: float) -> void:
	for side in punch:
		var s: PunchState = punch[side]
		if s.active:
			s.elapsed += delta
			if s.elapsed > punch_max_duration:
				_end_punch(side, s)
		else:
			s.since_end += delta


func _force_from_speed(speed: float) -> float:
	return clampf(inverse_lerp(punch_start_speed, punch_max_speed, speed), 0.0, 1.0)


func force_to_damage(force: float) -> float:
	return lerpf(min_damage, max_damage, pow(force, damage_curve))


# Fuerza (0..1) de la piña en curso de ese lado; 0 si no hay piña.
func get_punch_force(side: String) -> float:
	var s: PunchState = punch[side]
	if s.active or s.since_end <= punch_grace:
		return _force_from_speed(s.peak)
	return 0.0


func _check_hits(side: String, glove: Area3D) -> void:
	var s: PunchState = punch[side]
	if s.hit_done or not (s.active or s.since_end <= punch_grace):
		return

	var candidates: Array = []
	candidates.append_array(glove.get_overlapping_bodies())
	candidates.append_array(glove.get_overlapping_areas())

	for target in candidates:
		if target == self or not target.has_method("take_punch"):
			continue
		var force := _force_from_speed(s.peak)
		var damage := force_to_damage(force)
		target.take_punch(damage, force, side)
		s.hit_done = true
		if debug_punch:
			print("[%s] CONECTA en %s: fuerza %.2f, daño %.1f" % [side, target.name, force, damage])
		punch_landed.emit(target, side, damage, force)
		return


# ---------------------------------------------------------------------
# Guardia y daño recibido
# ---------------------------------------------------------------------

func _set_guard(active: bool) -> void:
	if active == guarding:
		return
	guarding = active
	if guard_glow:
		_set_glove_glow(left_glove, active)
		_set_glove_glow(right_glove, active)
	guard_changed.emit(active)


func _set_glove_glow(glove: Node3D, on: bool) -> void:
	var mi := glove.get_node_or_null("MeshInstance3D") as MeshInstance3D
	if mi == null or not (mi.mesh is PrimitiveMesh):
		return
	var mat := (mi.mesh as PrimitiveMesh).material as StandardMaterial3D
	if mat == null:
		return
	mat.emission_enabled = on
	mat.emission = mat.albedo_color
	mat.emission_energy_multiplier = 0.8


# Los enemigos llaman a esto. Devuelve true si el golpe fue bloqueado por completo.
func take_hit(damage: float, attacker: Node = null) -> bool:
	if guarding:
		blocked.emit(damage, attacker)
		damage *= guard_damage_multiplier
		if damage <= 0.0:
			return true

	health = maxf(0.0, health - damage)
	damaged.emit(damage, health)
	if health <= 0.0:
		died.emit()
	return false


# ---------------------------------------------------------------------
# Gesto de pausa: mano arriba mantenida
# ---------------------------------------------------------------------

func _update_pause_gesture(delta: float) -> void:
	if get_tree().paused:
		# Mientras el menu esta abierto no se dispara; al reanudar hay que bajar la mano
		pause_hold = 0.0
		pause_latched = true
		return

	if pause_pose and not pause_latched:
		pause_idle = 0.0
		pause_hold += delta
		if pause_hold >= pause_hold_time:
			pause_hold = 0.0
			pause_latched = true
			pause_hold_progress.emit(0.0)
			pause_requested.emit()
		else:
			pause_hold_progress.emit(pause_hold / pause_hold_time)
	else:
		pause_idle += delta
		if pause_idle > pause_release_grace:
			if pause_hold > 0.0:
				pause_hold = 0.0
				pause_hold_progress.emit(0.0)
			if not pause_pose:
				pause_latched = false


# ---------------------------------------------------------------------
# Actualizacion (independiente de los FPS)
# ---------------------------------------------------------------------

func _update_gloves(delta: float) -> void:
	var w := 1.0 - exp(-glove_smoothing * delta)
	left_glove.position = left_glove.position.lerp(left_target, w)
	right_glove.position = right_glove.position.lerp(right_target, w)


func _update_head(delta: float) -> void:
	var w := 1.0 - exp(-head_smoothing * delta)
	head.position = head.position.lerp(head_target_pos, w)
	head.rotation = head.rotation.lerp(head_target_rot, w)
