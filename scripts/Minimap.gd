## Minimap — M 으로 여닫는 전체 지도. 열려 있는 동안 게임은 일시정지된다.
##
## 표시: 방(타입 색, 방문한 방은 밝게) · 복도(실제 L자 구간, 잠금 간선은 붉게) ·
##       잠금문(붉은 막대, 열리면 청록) · 남은 키/목표 · 경비(상태별 색, 쓰러진 경비는 회색) · 플레이어
## 아직 발견하지 못한 숨은 통로는 그리지 않는다. 운반 중인 시체도 표시하지 않는다.
extends CanvasLayer

const TILE: float = 32.0

const COL_PLAYER := Color(0.3, 0.9, 0.85)
const COL_ALERT := Color(0.95, 0.30, 0.30)
const COL_SUS := Color(1.0, 0.62, 0.22)
const COL_INVEST := Color(0.60, 0.75, 0.95)
const COL_PATROL := Color(0.85, 0.75, 0.35)
const COL_DOWN := Color(0.45, 0.45, 0.45)
const COL_KEY := Color(1.0, 0.85, 0.3)
const COL_OBJ := Color(0.30, 0.90, 0.85)
const COL_LOCK := Color(0.9, 0.3, 0.25)

const SHORT := {
	"ENTRY": "ENTRY", "EXIT": "EXIT", "OBJECTIVE": "OBJ", "SIDE_OBJECTIVE": "SIDE",
	"TRANSIT": "", "OBSERVATION": "OBS", "HIGH_SECURITY": "HSEC", "CHOKE": "CHOKE",
	"KEY_ROOM": "KEY", "ALT_PATH": "ALT",
}

var _visible: bool = false
var _panel: Control = null


func _ready() -> void:
	layer = 100
	# 일시정지 중에도 입력을 받고 다시 그려야 한다
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_panel()
	_panel.visible = false


func _process(_delta: float) -> void:
	if _visible:
		_panel.queue_redraw()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("map_toggle"):
		# 일시정지 메뉴(ESC) 등으로 이미 멈춘 상태에서는 열지 않는다 — 지도를 닫으며
		# paused 를 풀면 일시정지 메뉴가 떠 있는 채로 게임이 다시 돌아가 버린다
		if _visible or (GameState.is_playing and not get_tree().paused):
			_toggle()
			get_viewport().set_input_as_handled()
	elif _visible and event.is_action_pressed("ui_cancel"):
		# ESC 는 지도만 닫는다 (일시정지 메뉴가 겹쳐 뜨지 않게)
		_toggle()
		get_viewport().set_input_as_handled()


func _toggle() -> void:
	_visible = not _visible
	_panel.visible = _visible
	get_tree().paused = _visible
	if _visible:
		_panel.queue_redraw()


func _exit_tree() -> void:
	# 지도를 연 채로 씬이 바뀌어도 일시정지가 남지 않게
	if _visible and get_tree() != null:
		get_tree().paused = false


func _build_panel() -> void:
	_panel = Control.new()
	_panel.name = "MapPanel"
	_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.process_mode = Node.PROCESS_MODE_ALWAYS
	_panel.draw.connect(_draw_map)
	add_child(_panel)


static func _room_color(room_type: String) -> Color:
	match room_type:
		"ENTRY":
			return Color(0.2, 0.55, 0.35, 0.7)
		"EXIT":
			return Color(0.2, 0.6, 0.6, 0.7)
		"OBJECTIVE":
			return Color(0.7, 0.45, 0.15, 0.7)
		"SIDE_OBJECTIVE":
			return Color(0.6, 0.55, 0.2, 0.6)
		"TRANSIT":
			return Color(0.3, 0.32, 0.38, 0.5)
		"OBSERVATION":
			return Color(0.25, 0.4, 0.55, 0.6)
		"HIGH_SECURITY":
			return Color(0.6, 0.2, 0.2, 0.7)
		"CHOKE":
			return Color(0.7, 0.15, 0.2, 0.7)
		"KEY_ROOM":
			return Color(0.5, 0.6, 0.25, 0.6)
		"ALT_PATH":
			return Color(0.42, 0.32, 0.6, 0.6)
		_:
			return Color(0.3, 0.3, 0.3, 0.5)


func _draw_map() -> void:
	var loader: Node = get_tree().get_first_node_in_group("level_loader")
	if loader == null:
		return
	var rooms: Array = loader.rooms
	if rooms.is_empty():
		return

	var p: Control = _panel
	var font := ThemeDB.fallback_font
	p.draw_rect(Rect2(Vector2.ZERO, p.size), Color(0.02, 0.03, 0.06, 0.92), true)

	# ── 월드 → 화면 변환 (레벨 전체가 화면의 85% 안에 들어오게) ──
	var bounds: Rect2 = loader.map_bounds()
	var area: Vector2 = p.size * 0.85
	var sc: float = minf(area.x / maxf(bounds.size.x, 1.0), area.y / maxf(bounds.size.y, 1.0))
	var off: Vector2 = (p.size - bounds.size * sc) * 0.5
	var to_screen := func(w: Vector2) -> Vector2:
		return (w - bounds.position) * sc + off

	# ── 복도 (실제 구간) ──
	var hidden: Dictionary = loader.unrevealed_edge_ids()
	for rec in loader.corridor_records():
		var e: Dictionary = rec.get("edge", {})
		if hidden.has(str(e.get("id", ""))):
			continue
		var ccol := Color(0.40, 0.42, 0.48, 0.75)
		if bool(e.get("locked", false)):
			ccol = Color(0.55, 0.28, 0.26, 0.8)
		for sg in rec.get("segs", []):
			var a: Vector2 = to_screen.call(Vector2(float(sg["x"]), float(sg["y"])) * TILE)
			var sz: Vector2 = Vector2(float(sg["w"]), float(sg["h"])) * TILE * sc
			p.draw_rect(Rect2(a, sz), ccol, true)

	# ── 방 ──
	for room in rooms:
		var ra: Vector2 = to_screen.call(Vector2(float(room["tx"]), float(room["ty"])) * TILE)
		var rsz: Vector2 = Vector2(float(room["w"]), float(room["h"])) * TILE * sc
		var rect := Rect2(ra, rsz)
		var col: Color = _room_color(str(room["type"]))
		var visited: bool = GameState.visited_rooms.has(str(room["id"]))
		if not visited:
			col = col.darkened(0.5)
		p.draw_rect(rect, col, true)
		p.draw_rect(rect, Color(0.7, 0.72, 0.78, 0.55 if visited else 0.25), false, 1.0)
		if bool(room.get("safe_zone", false)):
			p.draw_rect(rect.grow(-2.0), Color(0.3, 0.85, 0.8, 0.6), false, 1.2)

		var label: String = str(SHORT.get(str(room["type"]), str(room["type"]).substr(0, 5)))
		if font != null and label != "":
			var fs: int = 10
			var tw: float = font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
			p.draw_string(font, rect.get_center() + Vector2(-tw * 0.5, -rsz.y * 0.5 + 12.0),
				label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(1, 1, 1, 0.75 if visited else 0.4))

	# ── 잠금문 ──
	for door in get_tree().get_nodes_in_group("doors"):
		if not is_instance_valid(door) or door.modulate.a < 0.5:
			continue  # 숨은 통로의 문은 발견 전까지 숨김
		var dp: Vector2 = to_screen.call(door.global_position)
		var span: float = maxf(float(door.get("span")) * sc, 4.0)
		var dcol: Color = COL_PLAYER if door.get("is_open") == true else COL_LOCK
		var hb: bool = door.get("horizontal_block") == true
		var dsz: Vector2 = Vector2(span, 3.0) if hb else Vector2(3.0, span)
		p.draw_rect(Rect2(dp - dsz * 0.5, dsz), dcol, true)

	# ── 남은 아이템 ──
	for it in get_tree().get_nodes_in_group("items"):
		if not is_instance_valid(it) or it.get("collected") == true:
			continue
		var ip: Vector2 = to_screen.call(it.global_position)
		match str(it.get("item_kind")):
			"key":
				p.draw_circle(ip, 3.5, COL_KEY)
			"objective":
				p.draw_colored_polygon(PackedVector2Array([
					ip + Vector2(0, -5), ip + Vector2(5, 0), ip + Vector2(0, 5), ip + Vector2(-5, 0)]),
					COL_OBJ)

	# ── 경비 ──
	for enemy in get_tree().get_nodes_in_group("enemies"):
		if not is_instance_valid(enemy):
			continue
		if not enemy.alive and not enemy.is_in_group("corpses"):
			continue  # 운반 중인 시체
		var ecol: Color = COL_PATROL
		if not enemy.alive:
			ecol = COL_DOWN
		else:
			match int(enemy.state):
				3:
					ecol = COL_ALERT
				2:
					ecol = COL_SUS
				1:
					ecol = COL_INVEST
		p.draw_circle(to_screen.call(enemy.global_position), 3.0, ecol)

	# ── 플레이어 ──
	var player = get_tree().get_first_node_in_group("player")
	if player != null:
		var ps: Vector2 = to_screen.call(player.global_position)
		p.draw_circle(ps, 5.0, COL_PLAYER)
		var pulse: float = 0.5 + sin(Time.get_ticks_msec() * 0.005) * 0.3
		p.draw_arc(ps, 8.0 + pulse * 3.0, 0.0, TAU, 24, Color(COL_PLAYER.r, COL_PLAYER.g, COL_PLAYER.b, pulse), 1.5, true)

	# ── 범례 / 안내 ──
	if font != null:
		var entries := [
			[COL_PLAYER, Settings.tr_ko("플레이어")],
			[COL_ALERT, Settings.tr_ko("경비 (추격)")],
			[COL_SUS, Settings.tr_ko("경비 (의심)")],
			[COL_INVEST, Settings.tr_ko("경비 (조사)")],
			[COL_PATROL, Settings.tr_ko("경비 (순찰)")],
			[COL_DOWN, Settings.tr_ko("쓰러진 경비")],
			[COL_KEY, Settings.tr_ko("키")],
			[COL_OBJ, Settings.tr_ko("목표")],
			[COL_LOCK, Settings.tr_ko("잠긴 문")],
		]
		var lx: float = 20.0
		var ly: float = p.size.y - 20.0 - float(entries.size()) * 15.0
		for i in range(entries.size()):
			var y: float = ly + float(i) * 15.0
			p.draw_circle(Vector2(lx, y), 3.5, entries[i][0])
			p.draw_string(font, Vector2(lx + 10, y + 4), entries[i][1],
				HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.8, 0.8, 0.8))
		p.draw_string(font, Vector2(20, 30), Settings.tr_ko("지도  —  M / ESC 로 닫기   (일시정지 중)"),
			HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.75, 0.8, 0.88))
