extends CanvasLayer

@onready var overlay: ColorRect = $RedOverlay
@onready var label: Label = $GameOverLabel   # mensaje central

var info_label: Label
var notice_label: Label
var enemy_bar: ProgressBar
var base_alpha := 0.0
var flash := 0.0
var notice_time := 0.0


func _ready() -> void:
	label.visible = false
	label.add_theme_constant_override("outline_size", 8)
	label.add_theme_color_override("font_outline_color", Color.BLACK)

	info_label = _make_label(26, VERTICAL_ALIGNMENT_TOP)
	notice_label = _make_label(34, VERTICAL_ALIGNMENT_BOTTOM)

	enemy_bar = ProgressBar.new()
	enemy_bar.max_value = Global.MAX_HEALTH
	enemy_bar.show_percentage = false
	enemy_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(enemy_bar)
	enemy_bar.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	enemy_bar.offset_left = -150.0
	enemy_bar.offset_right = 150.0
	enemy_bar.offset_top = 44.0
	enemy_bar.offset_bottom = 58.0

	Global.player_hit.connect(_on_player_hit)
	Global.notice.connect(_on_notice)


func _make_label(font_size: int, v_align: VerticalAlignment) -> Label:
	var l := Label.new()
	add_child(l)
	l.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = v_align
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_constant_override("outline_size", 6)
	l.add_theme_color_override("font_outline_color", Color.BLACK)
	return l


func _process(delta: float) -> void:
	# Cuanta menos vida, más roja la pantalla (a 0 vida no se ve nada)
	var target: float = 1.0 - Global.player_health / Global.MAX_HEALTH
	base_alpha = move_toward(base_alpha, target, delta * 1.2)
	flash = move_toward(flash, 0.0, delta * 1.5)
	var c := overlay.color
	c.a = clampf(base_alpha + flash, 0.0, 1.0)
	overlay.color = c

	var t := int(ceilf(Global.round_time_left))
	info_label.text = "ROUND %d   |   VOS %d - %d ENEMIGO   |   %d:%02d" % [
		Global.round_number, Global.player_wins, Global.enemy_wins, t / 60, t % 60]
	enemy_bar.value = Global.enemy_health

	if notice_time > 0.0:
		notice_time -= delta
		if notice_time <= 0.0:
			notice_label.text = ""

	_update_message()


func _update_message() -> void:
	match Global.phase_name():
		"INTRO":
			label.visible = true
			label.text = "ROUND %d\n\n%d" % [Global.round_number, ceili(Global.phase_time)]
		"FIGHTING":
			label.visible = Global.round_time_left > Global.ROUND_TIME - 0.8
			label.text = "¡PELEA!"
		"ROUND_END":
			label.visible = true
			var msg := "EMPATE"
			if Global.last_winner > 0:
				msg = "¡GANASTE EL ROUND!"
			elif Global.last_winner < 0:
				msg = "PERDISTE EL ROUND"
			label.text = "%s\n\nVOS %d - %d ENEMIGO" % [msg, Global.player_wins, Global.enemy_wins]
		"MATCH_END":
			label.visible = true
			var title := "GAME OVER"
			if Global.match_won:
				title = "¡GANASTE LA PELEA!"
			label.text = "%s\n\nVOS %d - %d ENEMIGO" % [title, Global.player_wins, Global.enemy_wins]
			if Global.phase_time <= 0.0:
				label.text += "\n\nClick o R para reiniciar"


func _on_player_hit(blocked: bool) -> void:
	flash = 0.1 if blocked else 0.3


func _on_notice(text: String) -> void:
	notice_label.text = text + "\n\n"
	notice_time = 1.2


func _input(event: InputEvent) -> void:
	if Global.phase_name() != "MATCH_END" or Global.phase_time > 0.0:
		return
	var pressed: bool = false
	if event is InputEventMouseButton:
		pressed = event.pressed
	elif event is InputEventKey:
		pressed = event.pressed and event.keycode == KEY_R
	if pressed:
		Global.reset_match()
