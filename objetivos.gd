extends Area3D

func _physics_process(delta: float) -> void:
	global_position.z+=1


func _on_area_entered(area: Area3D) -> void:
	if area.is_in_group("puño"):
		print("FIN")
		queue_free()
