extends CharacterBody3D

# =====================================================================
# Jugador en PRIMERA PERSONA controlado por webcam (MediaPipe via UDP)
#   - Brazos  -> guantes
#   - Cabeza  -> rotacion de camara + esquivar/agacharse
# Todos los valores de abajo se pueden ajustar desde el Inspector.
# =====================================================================

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

@onready var left_glove: Node3D = $LeftGlove
@onready var right_glove: Node3D = $RightGlove
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


func _ready() -> void:
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

	left_lost += delta
	right_lost += delta
	head_lost += delta

	if latest != null:
		_read_packet(latest)

	# Si se pierde el tracking, volver a guardia / posicion neutra
	if left_lost > lost_timeout:
		left_target = left_rest
	if right_lost > lost_timeout:
		right_target = right_rest
	if head_lost > 0.6:
		head_target_pos = head_rest
		head_target_rot = Vector3.ZERO

	_update_gloves(delta)
	_update_head(delta)


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

	var l: Variant = _arm_target(data.get("left"), left_shoulder_anchor)
	if l != null:
		left_target = l
		left_lost = 0.0

	var r: Variant = _arm_target(data.get("right"), right_shoulder_anchor)
	if r != null:
		right_target = r
		right_lost = 0.0

	_read_head(data.get("head"))


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
