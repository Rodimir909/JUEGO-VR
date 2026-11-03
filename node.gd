extends Node3D

var server := PacketPeerUDP.new()
var port := 4242

@onready var glove_left: Node3D = $Player/LeftGlove
@onready var glove_right: Node3D = $Player/RightGlove

# Variables para calcular velocidad de golpe (puño)
var last_pos_left := Vector3.ZERO
var last_pos_right := Vector3.ZERO

func _ready() -> void:
	if server.bound(port) == OK:
		print("Conectado al servidor de tracking 3D en puerto ", port)
	else:
		print("Error al abrir puerto UDP")

func _process(delta: float) -> void:
	while server.get_available_packet_count() > 0:
		var packet = server.get_packet()
		var json_data = JSON.parse_string(packet.get_string_from_utf8())
		
		if json_data is Array:
			for hand in json_data:
				var hand_type = hand["hand"] # "Left" o "Right"
				
				# Mapear coordenadas normalizadas a tu espacio 3D en Godot
				# X y Y se invierten/ajustan a la pantalla; Z se usa para profundidad (adelante/atrás)
				var target_x = (hand["x"] - 0.5) * -10.0  # Ancho del ring
				var target_y = (hand["y"] - 0.5) * -6.0   # Alto del ring (invertido)
				var target_z = (hand["z"] * -5.0)         # Profundidad (acercarse a la cámara = golpear)
				
				if hand_type == "Left":
					var new_pos = Vector3(target_x, target_y, target_z)
					calcular_golpe(new_pos, last_pos_left, "Izquierdazo")
					glove_left.position = glove_left.position.lerp(new_pos, 0.2) # Suavizado
					last_pos_left = new_pos
					
				elif hand_type == "Right":
					var new_pos = Vector3(target_x, target_y, target_z)
					calcular_golpe(new_pos, last_pos_right, "Derechazo")
					glove_right.position = glove_right.position.lerp(new_pos, 0.2)
					last_pos_right = new_pos

func calcular_golpe(current_pos: Vector3, last_pos: Vector3, tipo: String) -> void:
	var velocidad = current_pos.distance_to(last_pos) / get_process_delta_time()
	
	# Si la velocidad del guante hacia adelante (eje Z negativo) supera el umbral, es un golpe
	if velocidad > 15.0 and current_pos.z < last_pos.z:
		print("¡", tipo, " lanzado con velocidad: ", velocidad, "!")
		# Aquí activas la Area3D del guante para que detecte colisión con el oponente
