extends Node3D

var combos : int = 0

func _on_bolsa_area_entered(area: Area3D) -> void:
	if area.is_in_group("puño"):
		$tiempodecombo.start()
		$bolsa/combo.global_position=area.global_position
		$bolsa/combo.visible=true
		combos+=1
		$bolsa/combo.text=str("Combo ", combos)
		
func _on_tiempodecombo_timeout() -> void:
	combos=0
	$bolsa/combo.visible=false
