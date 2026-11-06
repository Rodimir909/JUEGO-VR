extends CanvasLayer

# =====================================================================
# Menu de pausa controlado con la mano
#   - Mano arriba ~1 s (gesto detectado por Player) -> pausa
#   - La mano mueve un cursor; PELLIZCO (pulgar + indice) = click
#   - El mouse y la tecla ESC tambien funcionan (para probar sin camara)
# Va como hijo de Player (o en cualquier lado: busca al grupo "player").
# =====================================================================

signal resumed
signal quit_requested

@export var cursor_size := 18.0
@export var cursor_color := Color(0.0, 1.0, 1.0)
@export var hover_color := Color(1.4, 1.4, 0.6)
@export var quit_on_exit := true

var player: Node
var panel: PanelContainer
var cursor: Control
var progress: ProgressBar
var buttons: Array[Button] = []

var cursor_pos := Vector2.ZERO
var hand_visible := false
var pinch := false
var was_pinch := false
var use_mouse := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = 100
	_build_ui()
	_set_open(false)
	# Los hijos hacen _ready antes que el padre: esperamos un frame para que Player ya este en su grupo
	await get_tree().process_frame
	player = get_tree().get_first_node_in_group("player")
	if player == null:
		push_warning("PauseMenu: no encontre al Player (grupo 'player')")
		return
	player.pause_requested.connect(open)
	player.pause_hold_progress.connect(_on_hold_progress)
	player.cursor_updated.connect(_on_cursor_updated)


func _build_ui() -> void:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	# Oscurece el fondo
	var dim := ColorRect.new()
	dim.name = "Dim"
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(dim)

	var center := CenterContainer.new()
	center.name = "Center"
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(center)

	panel = PanelContainer.new()
	panel.custom_minimum_size = Vector2(420, 0)
	center.add_child(panel)

	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 32)
	panel.add_child(margin)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 20)
	margin.add_child(vb)

	var title := Label.new()
	title.text = "PAUSA"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 42)
	vb.add_child(title)

	_add_button(vb, "Reanudar", close)
	if quit_on_exit:
		_add_button(vb, "Salir", _on_quit)

	var hint := Label.new()
	hint.text = "Mové la mano para apuntar · pellizcá para elegir"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.modulate = Color(1, 1, 1, 0.6)
	vb.add_child(hint)

	# Aro/barra de progreso del gesto (visible aunque el juego NO este en pausa)
	progress = ProgressBar.new()
	progress.min_value = 0.0
	progress.max_value = 1.0
	progress.show_percentage = false
	progress.custom_minimum_size = Vector2(240, 12)
	progress.visible = false
	root.add_child(progress)
	progress.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	progress.offset_top = 40.0
	progress.offset_bottom = 52.0

	# Cursor virtual (circulo)
	cursor = Control.new()
	cursor.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cursor.z_index = 100
	cursor.draw.connect(_draw_cursor)
	root.add_child(cursor)


func _add_button(parent: Control, text: String, callback: Callable) -> void:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(0, 64)
	b.add_theme_font_size_override("font_size", 26)
	b.pressed.connect(callback)
	parent.add_child(b)
	buttons.append(b)


func _draw_cursor() -> void:
	if not hand_visible and not use_mouse:
		return
	var r := cursor_size * (0.6 if pinch else 1.0)
	cursor.draw_circle(cursor_pos, r, cursor_color if pinch else Color(cursor_color, 0.0))
	cursor.draw_arc(cursor_pos, r, 0.0, TAU, 32, cursor_color, 3.0, true)


# ---------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		if get_tree().paused:
			close()
		else:
			open()
		get_viewport().set_input_as_handled()


func _input(event: InputEvent) -> void:
	# Si mueves el mouse, el cursor pasa a seguir al mouse (util para probar)
	if get_tree().paused and event is InputEventMouseMotion:
		use_mouse = true
		hand_visible = false


func open() -> void:
	if get_tree().paused:
		return
	progress.visible = false
	get_tree().paused = true
	_set_open(true)


func close() -> void:
	get_tree().paused = false
	_set_open(false)
	resumed.emit()


func _set_open(open_: bool) -> void:
	for n in get_child(0).get_children():
		if n == progress or n == cursor:
			continue
		n.visible = open_
	cursor.visible = open_
	was_pinch = false
	pinch = false
	queue_redraw_cursor()


func _on_quit() -> void:
	quit_requested.emit()
	get_tree().quit()


func _on_hold_progress(p: float) -> void:
	if get_tree().paused:
		progress.visible = false
		return
	progress.value = p
	progress.visible = p > 0.0


func _on_cursor_updated(pos: Vector2, visible_: bool, pinch_: bool) -> void:
	hand_visible = visible_
	pinch = pinch_
	if visible_:
		use_mouse = false
		cursor_pos = pos * get_viewport().get_visible_rect().size


func _process(_delta: float) -> void:
	if not get_tree().paused:
		return
	var pos := cursor_pos
	var clicked := false
	if use_mouse:
		pos = get_viewport().get_mouse_position()
		cursor_pos = pos
		clicked = false   # el mouse hace click por su cuenta (Button normal)
	else:
		# Click = el pellizco se acaba de cerrar
		clicked = hand_visible and pinch and not was_pinch
		was_pinch = pinch

	_update_hover(pos, clicked)
	queue_redraw_cursor()


func _update_hover(pos: Vector2, clicked: bool) -> void:
	for b in buttons:
		var hovered := hand_visible and b.get_global_rect().has_point(pos)
		b.modulate = hover_color if hovered else Color.WHITE
		if hovered and clicked:
			b.pressed.emit()
			return   # puede haber cerrado el menu


func queue_redraw_cursor() -> void:
	if cursor:
		cursor.queue_redraw()
