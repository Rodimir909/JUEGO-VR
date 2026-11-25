extends CanvasLayer
const VIGNETTE := preload("res://scripts/low_health_vignette.gdshader")
@onready var overlay: ColorRect = $RedOverlay
@onready var message: Label = $GameOverLabel
var title: Label
var clock: Label
var player_label: Label
var enemy_label: Label
var status: Label
var notice_label: Label
var player_bar: ProgressBar
var enemy_bar: ProgressBar
var actions: HBoxContainer
var primary: Button
var menu_button: Button
var notice_time := 0.0
var flash := 0.0
var material: ShaderMaterial
var last_phase := ""
var gesture_pinched := false
var cursor: Control
var cursor_position := Vector2.ZERO
var cursor_visible := false

func _ready() -> void:
	material = ShaderMaterial.new()
	material.shader = VIGNETTE
	overlay.material = material
	overlay.color = Color.WHITE
	message.mouse_filter = Control.MOUSE_FILTER_IGNORE
	message.add_theme_font_size_override("font_size", 42)
	message.add_theme_constant_override("outline_size", 8)
	message.add_theme_color_override("font_outline_color", Color.BLACK)
	var root := Control.new()
	add_child(root)
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var margin := MarginContainer.new()
	root.add_child(margin)
	margin.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	margin.offset_bottom = 125
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 22)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var stack := VBoxContainer.new()
	margin.add_child(stack)
	title = _label(22)
	title.text = "NIVEL %d / 3   ·   %s   ·   %s" % [Global.level_index + 1, Global.level_config()["arena"], Global.level_config()["boxer"]]
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	stack.add_child(title)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 35)
	stack.add_child(row)
	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(left)
	player_label = _label(20)
	left.add_child(player_label)
	player_bar = _bar(Color("4ba9e8"))
	left.add_child(player_bar)
	clock = _label(30)
	clock.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	clock.custom_minimum_size.x = 190
	row.add_child(clock)
	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(right)
	enemy_label = _label(20)
	enemy_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	right.add_child(enemy_label)
	enemy_bar = _bar(Color("e85548"))
	right.add_child(enemy_bar)
	status = _label(18)
	root.add_child(status)
	status.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	status.offset_top = -34
	status.offset_left = 22
	status.offset_right = -22
	notice_label = _label(25)
	notice_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(notice_label)
	notice_label.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	notice_label.offset_top = -95
	notice_label.offset_bottom = -48
	actions = HBoxContainer.new()
	actions.alignment = BoxContainer.ALIGNMENT_CENTER
	actions.add_theme_constant_override("separation", 20)
	root.add_child(actions)
	actions.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	actions.offset_left = -360
	actions.offset_right = 360
	actions.offset_top = -165
	actions.offset_bottom = -105
	primary = Button.new()
	primary.custom_minimum_size = Vector2(280, 52)
	primary.pressed.connect(_primary_action)
	actions.add_child(primary)
	menu_button = Button.new()
	menu_button.text = "MENÚ PRINCIPAL"
	menu_button.custom_minimum_size = Vector2(210, 52)
	menu_button.pressed.connect(Global.return_to_menu)
	actions.add_child(menu_button)
	actions.visible = false
	cursor = Control.new()
	cursor.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cursor.draw.connect(_draw_cursor)
	root.add_child(cursor)
	Global.player_hit.connect(_on_player_hit)
	Global.notice.connect(_on_notice)
	await get_tree().process_frame
	var player := get_tree().get_first_node_in_group("player")
	if player:
		player.cursor_updated.connect(_on_cursor)
		player.punch_landed.connect(_on_punch_landed)

func _label(size: int) -> Label:
	var label := Label.new()
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_constant_override("outline_size", 5)
	label.add_theme_color_override("font_outline_color", Color("080c15"))
	return label

func _bar(color: Color) -> ProgressBar:
	var bar := ProgressBar.new()
	bar.custom_minimum_size.y = 16
	bar.max_value = Global.MAX_HEALTH
	bar.show_percentage = false
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var fill := StyleBoxFlat.new()
	fill.bg_color = color
	var background := StyleBoxFlat.new()
	background.bg_color = Color("192333")
	bar.add_theme_stylebox_override("fill", fill)
	bar.add_theme_stylebox_override("background", background)
	return bar

func _process(delta: float) -> void:
	flash = move_toward(flash, 0, delta * 1.5)
	material.set_shader_parameter("intensity", clampf((1 - Global.player_health / Global.MAX_HEALTH) * 0.75 + flash, 0, 0.85))
	player_bar.value = Global.player_health
	enemy_bar.value = Global.enemy_health
	player_label.text = "VOS   %d   %s" % [ceili(Global.player_health), "· GUARDIA" if Global.player_blocking else ""]
	enemy_label.text = "%s   %d" % [Global.level_config()["boxer"], ceili(Global.enemy_health)]
	var seconds := ceili(Global.round_time_left)
	clock.text = "%d:%02d  |  %d - %d" % [seconds / 60, seconds % 60, Global.player_wins, Global.enemy_wins]
	status.text = Global.tracking_status + "    ·    ESC: pausa"
	notice_time = maxf(notice_time - delta, 0)
	if notice_time <= 0:
		notice_label.text = ""
	_update_message()
	cursor.queue_redraw()

func _update_message() -> void:
	var phase := Global.phase_name()
	message.visible = phase != "FIGHTING" or Global.round_time_left > Global.ROUND_TIME - 0.65
	actions.visible = phase == "MATCH_END" and Global.phase_time <= 0 and (not Global.match_won or Global.level_index == 2)
	match phase:
		"INTRO":
			message.text = "NIVEL %d · %s\n%s\nROUND %d   ·   %d\n\n%s" % [Global.level_index + 1, Global.level_config()["arena"], Global.level_config()["boxer"], Global.round_number, ceili(Global.phase_time), Global.level_config()["tip"]]
		"FIGHTING":
			message.text = "¡PELEA!"
		"ROUND_END":
			message.text = "%s\n\nVOS %d - %d RIVAL\nPróximo round en %d" % ["¡ROUND GANADO!" if Global.last_winner > 0 else ("ROUND PERDIDO" if Global.last_winner < 0 else "EMPATE · REPETIMOS EL ROUND"), Global.player_wins, Global.enemy_wins, ceili(Global.phase_time)]
		"MATCH_END":
			if Global.match_won and Global.level_index < 2:
				message.text = "¡NIVEL %d SUPERADO!\n\nPróximo: %s\nNivel %d en %d" % [Global.level_index + 1, Global.LEVELS[Global.level_index + 1]["boxer"], Global.level_index + 2, ceili(Global.phase_time)]
			elif Global.match_won:
				message.text = "¡SOS EL CAMPEÓN!\n\nGimnasio, club y estadio: conquistados.\nCompletaste los tres niveles."
				primary.text = "VOLVER A JUGAR · R"
			else:
				message.text = "ESTA PELEA SE ESCAPÓ\n\n%s ganó el nivel %d.\nPodés volver a intentarlo." % [Global.level_config()["boxer"], Global.level_index + 1]
				primary.text = "REINTENTAR NIVEL · R"
	if phase != last_phase:
		gesture_pinched = false
		last_phase = phase

func _primary_action() -> void:
	if Global.match_won:
		Global.start_campaign()
	else:
		Global.reset_match()

func _unhandled_input(event: InputEvent) -> void:
	if actions.visible and event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_R:
		_primary_action()

func _on_player_hit(blocked: bool) -> void:
	flash = 0.08 if blocked else 0.25
	if blocked:
		_on_notice("GUARDIA · Daño reducido")

func _on_punch_landed(_target: Node, _side: String, damage: float, _force: float) -> void:
	_on_notice("BLOQUEADO" if Global.enemy_blocking else "¡CONECTASTE!  %.0f" % damage)

func _on_notice(text: String) -> void:
	notice_label.text = text
	notice_time = 1.5

func _on_cursor(position: Vector2, visible_: bool, pinch: bool) -> void:
	cursor_position = position * get_viewport().get_visible_rect().size
	cursor_visible = visible_ and actions.visible
	if cursor_visible and pinch and not gesture_pinched:
		for button in [primary, menu_button]:
			if button.get_global_rect().has_point(cursor_position):
				button.pressed.emit()
				break
	gesture_pinched = pinch

func _draw_cursor() -> void:
	if cursor_visible:
		cursor.draw_arc(cursor_position, 14, 0, TAU, 32, Color.CYAN, 3, true)
