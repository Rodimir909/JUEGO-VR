extends Control

func _ready() -> void:
	$AudioStreamPlayer.play()

func _on_jugar_pressed() -> void:
	pass #change_scene NIVEL 1


func _on_salir_pressed() -> void:
	get_tree().quit()
