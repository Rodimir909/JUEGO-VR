extends Control
const GOLD := Color("efb448")
const MUTED := Color("9aaac1")

func _ready() -> void:
	Global.phase = Global.Phase.MENU
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	var theme := Theme.new()
	theme.default_font = load("res://elementos de hud/BebasNeue-Regular.otf")
	theme.default_font_size = 24
	self.theme = theme
	var background := ColorRect.new()
	background.color = Color("0c101a")
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(background)
	var scroll := ScrollContainer.new()
	add_child(scroll)
	scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var margin := MarginContainer.new()
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for side in ["left", "right"]:
		margin.add_theme_constant_override("margin_" + side, 64)
	for side in ["top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 20)
	scroll.add_child(margin)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	margin.add_child(column)
	var eyebrow := _label("BOXEO MORTAL  /  CAMINO AL CAMPEONATO", 22, GOLD)
	column.add_child(eyebrow)
	var heading := HBoxContainer.new()
	heading.add_theme_constant_override("separation", 30)
	column.add_child(heading)
	var logo := TextureRect.new()
	logo.texture = load("res://elementos de hud/Logo de Boxeo Mortal Ñapi.png")
	logo.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	logo.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	logo.custom_minimum_size = Vector2(230, 130)
	heading.add_child(logo)
	var intro := VBoxContainer.new()
	intro.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	heading.add_child(intro)
	intro.add_child(_label("TRES RIVALES. UN CAMPEÓN.", 46, Color.WHITE))
	intro.add_child(_label("Ganá dos rounds por pelea y avanzá al próximo escenario.\nCada rival exige un poco más. ¿Llegás al estadio?", 25, MUTED))
	var levels := HBoxContainer.new()
	levels.add_theme_constant_override("separation", 18)
	column.add_child(levels)
	for index in Global.LEVELS.size():
		var config: Dictionary = Global.LEVELS[index]
		var card := PanelContainer.new()
		card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var style := StyleBoxFlat.new()
		style.bg_color = Color("171e2d")
		style.border_color = GOLD if index == 0 else Color("314057")
		style.border_width_top = 3
		style.content_margin_left = 20
		style.content_margin_right = 16
		style.content_margin_top = 14
		style.content_margin_bottom = 14
		card.add_theme_stylebox_override("panel", style)
		levels.add_child(card)
		var stack := VBoxContainer.new()
		card.add_child(stack)
		stack.add_child(_label("0%d  /  %s" % [index + 1, config["arena"]], 22, GOLD))
		stack.add_child(_label(str(config["boxer"]), 34, Color.WHITE))
		stack.add_child(_label(["INICIACIÓN", "DESAFÍO", "CAMPEONATO"][index], 20, MUTED))
	column.add_child(_label("CON WEBCAM", 25, GOLD))
	column.add_child(_label("Iniciá el seguimiento de Python y calibrá con las manos en guardia.\nPuños hacia adelante: golpes · Manos junto a la cara: guardia · Cuerpo: esquivar\nMano sobre la cabeza: pausa · Pellizco: elegir en pausa · C: recalibrar", 23, MUTED))
	column.add_child(_label("TAMBIÉN PODÉS JUGAR CON TECLADO Y MOUSE", 25, GOLD))
	column.add_child(_label("WASD: moverte · Clic izq./der.: golpear · E: cubrirte · Espacio: agacharte\nEsc: pausa · K: alternar teclado/webcam", 23, MUTED))
	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 20)
	column.add_child(actions)
	var play := Button.new()
	play.text = "JUGAR  →  NIVEL 1"
	play.custom_minimum_size = Vector2(330, 58)
	play.add_theme_font_size_override("font_size", 32)
	play.pressed.connect(_on_jugar_pressed)
	actions.add_child(play)
	play.grab_focus()
	var quit_button := Button.new()
	quit_button.text = "SALIR"
	quit_button.custom_minimum_size = Vector2(130, 58)
	quit_button.pressed.connect(_on_salir_pressed)
	actions.add_child(quit_button)

func _label(text: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	return label

func _on_jugar_pressed() -> void:
	$AudioStreamPlayer.stop()
	Global.start_campaign()

func _on_salir_pressed() -> void:
	$AudioStreamPlayer.stop()
	get_tree().quit()

func _exit_tree() -> void:
	$AudioStreamPlayer.stop()
	$AudioStreamPlayer.stream = null
