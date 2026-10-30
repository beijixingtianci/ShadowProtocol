## StartScreen — 생성 파라미터·경험 곡선·난이도를 고르고 레벨을 만들어 시작한다.
##
## "생성 및 시작": export_for_godot.py 를 시스템 Python 으로 실행 (별도 스레드) → Main.tscn
## "빠른 시작":    생성 없이 levels/level_data.json (없으면 내장 레벨) 로 바로 시작
##
## Python 경로 (Option A): 프로젝트 루트의 export_for_godot.py 를 실행한다.
## stealth_pcg/ 패키지는 프로젝트 루트 또는 그 상위 폴더에 있으면 된다.
extends Control

const BG := Color(0.05, 0.06, 0.09)
const TEAL := Color(0.35, 0.85, 0.80)

## 실행할 Python 후보 — 앞에서부터 시도한다 (Windows: python / py 런처)
const PYTHON_CANDIDATES := ["python", "py", "python3"]

## 목표 긴장도 곡선 프리셋의 제어점 (stealth_pcg/curves/templates.py 와 동일)
const CURVE_POINTS := {
	"escalating": [[0.0, 0.1], [0.5, 0.5], [1.0, 0.95]],
	"v_shape": [[0.0, 0.7], [0.2, 0.4], [0.5, 0.15], [0.8, 0.5], [1.0, 0.9]],
	"inverted_v": [[0.0, 0.1], [0.3, 0.4], [0.5, 0.95], [0.7, 0.4], [1.0, 0.15]],
	"double_peak": [[0.0, 0.1], [0.25, 0.8], [0.45, 0.2], [0.75, 0.9], [1.0, 0.7]],
	"late_climax": [[0.0, 0.1], [0.6, 0.2], [0.8, 0.5], [0.95, 0.95], [1.0, 0.85]],
	"roller_coaster": [[0.0, 0.1], [0.15, 0.7], [0.3, 0.2], [0.45, 0.8], [0.6, 0.15],
		[0.75, 0.85], [0.9, 0.3], [1.0, 0.9]],
	"flat_high": [[0.0, 0.7], [0.5, 0.8], [1.0, 0.85]],
}
const CURVE_ORDER := ["escalating", "v_shape", "inverted_v", "double_peak",
	"late_climax", "roller_coaster", "flat_high"]

const DIFF_NAMES := ["EASY", "NORMAL", "HARD", "BRUTAL"]

## 곡선 편집기: 점을 잡는 반경(px), 이웃 점과의 최소 x 간격
const POINT_PICK: float = 10.0
const MIN_GAP: float = 0.02

const DEFAULT_PARAMS := {
	"seed": 42,
	"curve": "double_peak",       # 프리셋 이름, 또는 직접 손댄 곡선이면 "custom"
	"curve_points": [],           # 목표 곡선 제어점 [[x, y], ...] — 편집기가 다루는 실제 값
	"num_extra_objectives": 1,
	"num_key_locks": 2,
	"num_choke_points": 1,
	"num_corridor_expansions": 3,
	"corridor_length": 2,
	"path_diversity_prob": 0.4,
	"side_objective_prob": 0.5,
	"proximity_rate": 0.35,   # 공유벽 중 소리가 새는 벽의 비율 (파이프라인 기본값 0.35)
	"population": 30,
	"generations": 40,
	"difficulty": 1,
}

var params: Dictionary = {}

var _curve_btns: Dictionary = {}
var _diff_btns: Array = []
var _preview: Control = null
var _custom_btn: Button = null
var _drag_idx: int = -1
var _hover_idx: int = -1
## 마지막으로 직접 만든 곡선 (프리셋을 눌렀다가 "사용자 정의" 로 되돌아올 때)
var _last_custom: Array = []
var _seed_box: SpinBox = null
var _status: Label = null
var _gen_btn: Button = null
var _quick_btn: Button = null

var _thread: Thread = null
var _generating: bool = false


func _ready() -> void:
	params = DEFAULT_PARAMS.duplicate(true)
	# 메뉴로 돌아온 경우 직전 설정을 유지
	for k in GameState.menu_params.keys():
		if params.has(k):
			params[k] = GameState.menu_params[k]
	params = params.duplicate(true)
	if params["curve_points"].size() < 2:
		params["curve_points"] = _preset_points(str(params["curve"]))
	if str(params["curve"]) == "custom":
		_last_custom = params["curve_points"].duplicate(true)

	_build_ui()
	_refresh_curve_buttons()
	_refresh_diff_buttons()


func _exit_tree() -> void:
	if _thread != null and _thread.is_started():
		_thread.wait_to_finish()


func _process(_delta: float) -> void:
	if _generating:
		var dots: String = ".".repeat(int(fmod(Time.get_ticks_msec() / 500.0, 4.0)))
		_status.text = Settings.tr_ko("레벨 생성 중") + dots
		_status.modulate = Color(0.75, 0.80, 0.88)


# ═══════════════════════════════════════
#  UI 구성
# ═══════════════════════════════════════

func _build_ui() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)

	var bg := ColorRect.new()
	bg.color = BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var root := VBoxContainer.new()
	root.custom_minimum_size = Vector2(1040, 0)
	root.add_theme_constant_override("separation", 12)
	center.add_child(root)

	# ── 제목 ──
	var title := _label("SHADOW PROTOCOL", 40)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.modulate = Color(0.90, 0.93, 0.97)
	root.add_child(title)
	var sub := _label("Procedural Stealth Game", 14)
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.modulate = Color(0.48, 0.55, 0.68)
	root.add_child(sub)

	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", 14)
	root.add_child(cols)

	# ── 왼쪽: 곡선 + 난이도 ──
	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.add_theme_constant_override("separation", 12)
	cols.add_child(left)

	var curve_box := _section(left, "경험 곡선")
	var flow := HFlowContainer.new()
	flow.add_theme_constant_override("h_separation", 6)
	flow.add_theme_constant_override("v_separation", 6)
	curve_box.add_child(flow)
	for cname in CURVE_ORDER:
		var b := _toggle_button(cname)
		b.pressed.connect(_on_curve_pressed.bind(cname))
		flow.add_child(b)
		_curve_btns[cname] = b
	_custom_btn = _toggle_button("✎ 사용자 정의")
	_custom_btn.pressed.connect(_on_custom_pressed)
	flow.add_child(_custom_btn)

	_preview = Control.new()
	_preview.custom_minimum_size = Vector2(0, 150)
	_preview.mouse_filter = Control.MOUSE_FILTER_STOP
	_preview.draw.connect(_draw_curve_preview)
	_preview.gui_input.connect(_on_preview_input)
	_preview.mouse_exited.connect(func():
		_hover_idx = -1
		_preview.queue_redraw())
	curve_box.add_child(_preview)

	var hint := _label("드래그: 점 이동 · 빈 곳 클릭: 점 추가 · 우클릭: 점 삭제", 11)
	hint.modulate = Color(0.45, 0.50, 0.58)
	curve_box.add_child(hint)

	var diff_box := _section(left, "난이도")
	var diff_row := HBoxContainer.new()
	diff_row.add_theme_constant_override("separation", 6)
	diff_box.add_child(diff_row)
	for i in range(DIFF_NAMES.size()):
		var db := _toggle_button(DIFF_NAMES[i])
		db.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		db.pressed.connect(_on_diff_pressed.bind(i))
		diff_row.add_child(db)
		_diff_btns.append(db)

	# ── 오른쪽: 생성 파라미터 + 진화 설정 ──
	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_theme_constant_override("separation", 12)
	cols.add_child(right)

	var gen_box := _section(right, "생성 파라미터")
	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 4)
	gen_box.add_child(grid)

	# Seed + Random
	grid.add_child(_row_label("Seed"))
	_seed_box = _spin("seed", 0, 2147483647)
	grid.add_child(_seed_box)
	var rnd := Button.new()
	rnd.text = "Random"
	rnd.focus_mode = Control.FOCUS_NONE
	rnd.pressed.connect(_on_random_seed)
	grid.add_child(rnd)

	_int_row(grid, "Objectives", "num_extra_objectives", 0, 4)
	_int_row(grid, "Key-Locks", "num_key_locks", 0, 4)
	_int_row(grid, "Choke Points", "num_choke_points", 0, 3)
	_int_row(grid, "Corridors", "num_corridor_expansions", 0, 8)
	_int_row(grid, "Corridor Len", "corridor_length", 1, 5)
	_pct_row(grid, "Alt Path %", "path_diversity_prob")
	_pct_row(grid, "Side Obj %", "side_objective_prob")
	_pct_row(grid, "Proximity %", "proximity_rate",
		"맞닿은 벽 중 소리가 새는 벽(얇은 벽·유리·철망 등)의 비율")

	var evo_box := _section(right, "진화 설정")
	var grid2 := GridContainer.new()
	grid2.columns = 3
	grid2.add_theme_constant_override("h_separation", 10)
	grid2.add_theme_constant_override("v_separation", 4)
	evo_box.add_child(grid2)
	_int_row(grid2, "Population", "population", 8, 100)
	_int_row(grid2, "Generations", "generations", 5, 200)

	# ── 하단: 버튼 + 상태 ──
	var btn_row := HBoxContainer.new()
	btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
	btn_row.add_theme_constant_override("separation", 12)
	root.add_child(btn_row)

	_gen_btn = _big_button("▶  생성 및 시작", true)
	_gen_btn.pressed.connect(_on_generate_pressed)
	btn_row.add_child(_gen_btn)

	_quick_btn = _big_button("빠른 시작 (기존 레벨)", false)
	_quick_btn.pressed.connect(_on_quick_start_pressed)
	btn_row.add_child(_quick_btn)

	# ── 타이틀로 돌아가기 ──
	var back_btn := _small_button("↩  되돌아가기")
	back_btn.pressed.connect(_on_return_to_title)
	btn_row.add_child(back_btn)

	_status = _label("", 12)
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.custom_minimum_size = Vector2(0, 36)
	_status.modulate = Color(0.55, 0.60, 0.70)
	root.add_child(_status)


func _section(parent: Control, title: String) -> VBoxContainer:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel",
		VisualKit.panel_style(Color(0.07, 0.08, 0.11, 0.95), Color(1, 1, 1, 0.10), 8))
	parent.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	panel.add_child(box)
	var head := _label(title, 14)
	head.modulate = TEAL
	box.add_child(head)
	return box


func _label(text: String, size: int) -> Label:
	var l := Label.new()
	l.text = Settings.tr_ko(text)
	l.add_theme_font_size_override("font_size", size)
	return l


func _row_label(text: String) -> Label:
	var l := _label(text, 13)
	l.custom_minimum_size = Vector2(110, 0)
	l.modulate = Color(0.78, 0.81, 0.87)
	return l


func _spin(key: String, lo: int, hi: int) -> SpinBox:
	var sb := SpinBox.new()
	sb.min_value = lo
	sb.max_value = hi
	sb.step = 1
	sb.rounded = true
	sb.value = int(params[key])
	sb.custom_minimum_size = Vector2(130, 0)
	sb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sb.value_changed.connect(func(v: float): params[key] = int(v))
	return sb


func _int_row(grid: GridContainer, text: String, key: String, lo: int, hi: int) -> void:
	grid.add_child(_row_label(text))
	grid.add_child(_spin(key, lo, hi))
	grid.add_child(Control.new())


func _pct_row(grid: GridContainer, text: String, key: String, tip: String = "") -> void:
	var lab := _row_label(text)
	lab.tooltip_text = tip
	lab.mouse_filter = Control.MOUSE_FILTER_PASS
	grid.add_child(lab)

	var sl := HSlider.new()
	sl.min_value = 0
	sl.max_value = 100
	sl.step = 5
	sl.value = round(float(params[key]) * 100.0)
	sl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	sl.focus_mode = Control.FOCUS_NONE
	sl.tooltip_text = tip
	grid.add_child(sl)

	var val := _label("%d%%" % int(sl.value), 13)
	val.custom_minimum_size = Vector2(48, 0)
	val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	grid.add_child(val)

	sl.value_changed.connect(func(v: float):
		params[key] = v / 100.0
		val.text = "%d%%" % int(v))


func _toggle_button(text: String) -> Button:
	var b := Button.new()
	b.text = Settings.tr_ko(text)
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_size_override("font_size", 13)
	return b


func _style_toggle(b: Button, selected: bool) -> void:
	var sb: StyleBoxFlat
	var hv: StyleBoxFlat
	if selected:
		sb = VisualKit.panel_style(Color(0.10, 0.20, 0.20, 1.0), TEAL, 6)
		sb.set_border_width_all(2)
		hv = sb
		b.add_theme_color_override("font_color", Color(0.85, 1.0, 0.97))
		b.add_theme_color_override("font_hover_color", Color(0.85, 1.0, 0.97))
	else:
		sb = VisualKit.panel_style(Color(0.10, 0.11, 0.15, 1.0), Color(1, 1, 1, 0.14), 6)
		hv = VisualKit.panel_style(Color(0.14, 0.16, 0.21, 1.0), Color(1, 1, 1, 0.30), 6)
		b.add_theme_color_override("font_color", Color(0.72, 0.76, 0.84))
		b.add_theme_color_override("font_hover_color", Color(0.92, 0.94, 0.98))
	for sb_pad in [sb, hv]:
		sb_pad.content_margin_top = 5
		sb_pad.content_margin_bottom = 5
	b.add_theme_stylebox_override("normal", sb)
	b.add_theme_stylebox_override("hover", hv)
	b.add_theme_stylebox_override("pressed", sb)


func _big_button(text: String, primary: bool) -> Button:
	var b := Button.new()
	b.text = Settings.tr_ko(text)
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(260, 46)
	b.add_theme_font_size_override("font_size", 16 if primary else 14)
	var border: Color = Color(0.28, 0.66, 0.60) if primary else Color(1, 1, 1, 0.18)
	var bg: Color = Color(0.08, 0.12, 0.13) if primary else Color(0.07, 0.08, 0.11)
	b.add_theme_stylebox_override("normal", VisualKit.panel_style(bg, border, 8))
	b.add_theme_stylebox_override("hover",
		VisualKit.panel_style(bg.lightened(0.10), border.lightened(0.25), 8))
	b.add_theme_stylebox_override("pressed", VisualKit.panel_style(bg.darkened(0.2), border, 8))
	b.add_theme_stylebox_override("disabled",
		VisualKit.panel_style(Color(0.06, 0.07, 0.09), Color(1, 1, 1, 0.06), 8))
	return b


## 작은 버튼 (돌아가기 등 보조 동작)
func _small_button(text: String) -> Button:
	var b := Button.new()
	b.text = Settings.tr_ko(text)
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(140, 36)
	b.add_theme_font_size_override("font_size", 13)
	var border := Color(1, 1, 1, 0.12)
	var bg := Color(0.07, 0.08, 0.11)
	b.add_theme_stylebox_override("normal", VisualKit.panel_style(bg, border, 6))
	b.add_theme_stylebox_override("hover",
		VisualKit.panel_style(bg.lightened(0.08), Color(1, 1, 1, 0.22), 6))
	b.add_theme_stylebox_override("pressed", VisualKit.panel_style(bg.darkened(0.2), border, 6))
	b.add_theme_color_override("font_color", Color(0.55, 0.60, 0.65))
	b.add_theme_color_override("font_hover_color", Color(0.80, 0.85, 0.88))
	return b


# ═══════════════════════════════════════
#  곡선 / 난이도 선택
# ═══════════════════════════════════════

## 프리셋 → 그 제어점을 편집기에 싣는다 (이후 손대면 custom)
func _on_curve_pressed(cname: String) -> void:
	params["curve"] = cname
	params["curve_points"] = _preset_points(cname)
	_refresh_curve_buttons()


## 마지막으로 직접 만든 곡선으로 돌아간다 (아직 없으면 지금 곡선을 custom 으로)
func _on_custom_pressed() -> void:
	if not _last_custom.is_empty():
		params["curve_points"] = _last_custom.duplicate(true)
	params["curve"] = "custom"
	_last_custom = params["curve_points"].duplicate(true)
	_refresh_curve_buttons()


func _preset_points(cname: String) -> Array:
	return CURVE_POINTS.get(cname, CURVE_POINTS["double_peak"]).duplicate(true)


func _refresh_curve_buttons() -> void:
	for cname in _curve_btns.keys():
		_style_toggle(_curve_btns[cname], cname == params["curve"])
	if _custom_btn != null:
		_style_toggle(_custom_btn, str(params["curve"]) == "custom")
	if _preview != null:
		_preview.queue_redraw()


func _on_diff_pressed(i: int) -> void:
	params["difficulty"] = i
	_refresh_diff_buttons()


func _refresh_diff_buttons() -> void:
	for i in range(_diff_btns.size()):
		_style_toggle(_diff_btns[i], i == int(params["difficulty"]))


## 곡선 미리보기 — 파이썬 TensionCurve 와 같은 코사인 보간
func _curve_value(pts: Array, t: float) -> float:
	for i in range(pts.size() - 1):
		var a: Array = pts[i]
		var b: Array = pts[i + 1]
		if t <= float(b[0]):
			var span: float = maxf(float(b[0]) - float(a[0]), 1e-6)
			var u: float = (t - float(a[0])) / span
			var k: float = (1.0 - cos(u * PI)) * 0.5
			return lerpf(float(a[1]), float(b[1]), k)
	return float(pts[pts.size() - 1][1])


# ═══════════════════════════════════════
#  곡선 편집기 — 제어점을 끌어 목표 곡선을 직접 만든다
#  params["curve_points"] = [[x, y], ...]  (x: 진행도 0→1, y: 긴장도 0→1)
#  프리셋을 고르면 그 점들이 들어오고, 손대면 "custom" 이 된다.
# ═══════════════════════════════════════

## 편집 영역 (미리보기 컨트롤 안쪽 여백을 뺀 사각형)
func _editor_rect() -> Rect2:
	var pad := Vector2(12, 12)
	return Rect2(pad, _preview.size - pad * 2.0)


func _pt_to_px(p: Array) -> Vector2:
	var r: Rect2 = _editor_rect()
	return Vector2(r.position.x + float(p[0]) * r.size.x, r.end.y - float(p[1]) * r.size.y)


func _px_to_pt(pos: Vector2) -> Vector2:
	var r: Rect2 = _editor_rect()
	return Vector2(clampf((pos.x - r.position.x) / r.size.x, 0.0, 1.0),
		clampf((r.end.y - pos.y) / r.size.y, 0.0, 1.0))


## pos 근처(POINT_PICK px 이내)의 제어점 번호, 없으면 -1
func _pick_point(pos: Vector2) -> int:
	var pts: Array = params["curve_points"]
	var best: int = -1
	var best_d: float = POINT_PICK
	for i in range(pts.size()):
		var d: float = pos.distance_to(_pt_to_px(pts[i]))
		if d <= best_d:
			best_d = d
			best = i
	return best


func _on_preview_input(event: InputEvent) -> void:
	var pts: Array = params["curve_points"]
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT:
			var idx: int = _pick_point(event.position)
			if idx < 0:
				idx = _insert_point(_px_to_pt(event.position))
			_drag_idx = idx
			if idx >= 0:
				_move_point(idx, _px_to_pt(event.position))
			_preview.accept_event()
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			var ridx: int = _pick_point(event.position)
			# 양 끝점은 지울 수 없다 (곡선은 x=0 에서 시작해 x=1 에서 끝나야 한다)
			if ridx > 0 and ridx < pts.size() - 1:
				pts.remove_at(ridx)
				_mark_custom()
			_preview.accept_event()
	elif event is InputEventMouseButton and not event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_drag_idx = -1
		_preview.queue_redraw()
	elif event is InputEventMouseMotion:
		if _drag_idx >= 0:
			_move_point(_drag_idx, _px_to_pt(event.position))
		else:
			var h: int = _pick_point(event.position)
			if h != _hover_idx:
				_hover_idx = h
				_preview.queue_redraw()


## 빈 곳에 점을 끼워 넣고 그 번호를 돌려준다 (이웃과 너무 가까우면 그 이웃을 잡는다)
func _insert_point(p: Vector2) -> int:
	var pts: Array = params["curve_points"]
	var at: int = pts.size() - 1
	for i in range(1, pts.size()):
		if p.x < float(pts[i][0]):
			at = i
			break
	if p.x - float(pts[at - 1][0]) < MIN_GAP:
		return at - 1
	if float(pts[at][0]) - p.x < MIN_GAP:
		return at
	pts.insert(at, [snappedf(p.x, 0.001), snappedf(p.y, 0.001)])
	_mark_custom()
	return at


## 점 이동 — 끝점은 x 고정, 가운데 점은 이웃을 넘지 못한다
func _move_point(idx: int, p: Vector2) -> void:
	var pts: Array = params["curve_points"]
	var x: float = p.x
	if idx == 0:
		x = 0.0
	elif idx == pts.size() - 1:
		x = 1.0
	else:
		x = clampf(x, float(pts[idx - 1][0]) + MIN_GAP, float(pts[idx + 1][0]) - MIN_GAP)
	var nx: float = snappedf(x, 0.001)
	var ny: float = snappedf(clampf(p.y, 0.0, 1.0), 0.001)
	if nx == float(pts[idx][0]) and ny == float(pts[idx][1]):
		return
	pts[idx] = [nx, ny]
	_mark_custom()


## 손을 댄 곡선은 custom — 프리셋 강조를 끄고 마지막 사용자 곡선으로 보관
func _mark_custom() -> void:
	params["curve"] = "custom"
	_last_custom = params["curve_points"].duplicate(true)
	_refresh_curve_buttons()


## Python 으로 넘길 "x:y,x:y,..." (export_for_godot.py --curve-points)
func _points_arg() -> String:
	var parts: PackedStringArray = []
	for p in params["curve_points"]:
		parts.append("%.3f:%.3f" % [float(p[0]), float(p[1])])
	return ",".join(parts)


func _draw_curve_preview() -> void:
	var pts: Array = params["curve_points"]
	if pts.size() < 2:
		return
	var r := Rect2(Vector2.ZERO, _preview.size)
	var inner: Rect2 = _editor_rect()

	_preview.draw_rect(r, Color(0.08, 0.09, 0.12), true)
	for g in [0.25, 0.5, 0.75]:
		var gy: float = inner.end.y - g * inner.size.y
		_preview.draw_line(Vector2(inner.position.x, gy), Vector2(inner.end.x, gy),
			Color(1, 1, 1, 0.08), 1.0)
	_preview.draw_rect(inner, Color(1, 1, 1, 0.06), false, 1.0)

	var line := PackedVector2Array()
	var steps: int = 120
	for i in range(steps + 1):
		var t: float = float(i) / float(steps)
		line.append(_pt_to_px([t, _curve_value(pts, t)]))
	_preview.draw_polyline(line, TEAL, 2.5, true)

	# 제어점 — 잡은 점·마우스 아래 점은 크게, 끝점(위아래로만 이동)은 네모
	for i in range(pts.size()):
		var c: Vector2 = _pt_to_px(pts[i])
		var active: bool = i == _drag_idx or i == _hover_idx
		var rad: float = 6.5 if active else 4.5
		var col := Color(1.0, 0.85, 0.4) if active else Color(0.9, 0.97, 0.95)
		if i == 0 or i == pts.size() - 1:
			_preview.draw_rect(Rect2(c - Vector2(rad, rad), Vector2(rad, rad) * 2.0), col, true)
		else:
			_preview.draw_circle(c, rad, col)
		if active:
			var font0 := ThemeDB.fallback_font
			if font0 != null:
				_preview.draw_string(font0, c + Vector2(8, -8), "(%.2f, %.2f)" % [float(pts[i][0]), float(pts[i][1])],
					HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(1.0, 0.85, 0.4))

	var font := ThemeDB.fallback_font
	if font != null:
		_preview.draw_string(font, Vector2(inner.position.x + 4, inner.position.y + 12),
			Settings.tr_ko("긴장도"), HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(1, 1, 1, 0.35))
		_preview.draw_string(font, Vector2(inner.end.x - 44, inner.end.y - 4),
			Settings.tr_ko("진행 →"), HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(1, 1, 1, 0.35))
		if str(params["curve"]) == "custom":
			var tag: String = Settings.tr_ko("사용자 정의 곡선")
			var tw: float = font.get_string_size(tag, HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x
			_preview.draw_string(font, Vector2(inner.end.x - tw - 4, inner.position.y + 12),
				tag, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(1.0, 0.85, 0.4, 0.8))


func _on_random_seed() -> void:
	var s: int = randi() % 2147483647
	params["seed"] = s
	_seed_box.value = s


# ═══════════════════════════════════════
#  생성 / 시작
# ═══════════════════════════════════════

func _on_generate_pressed() -> void:
	if _generating:
		return
	var exporter: String = ProjectSettings.globalize_path("res://export_for_godot.py")
	if not FileAccess.file_exists("res://export_for_godot.py"):
		_show_error(Settings.tr_ko("export_for_godot.py 를 찾을 수 없습니다: ") + exporter)
		return

	var out_path: String = ProjectSettings.globalize_path("res://levels/level_data.json")
	var args: PackedStringArray = [
		exporter,
		"--seed", str(params["seed"]),
		"--pop", str(params["population"]),
		"--gens", str(params["generations"]),
		"--difficulty", str(params["difficulty"]),
		"--objectives", str(params["num_extra_objectives"]),
		"--keylocks", str(params["num_key_locks"]),
		"--chokes", str(params["num_choke_points"]),
		"--corridors", str(params["num_corridor_expansions"]),
		"--corridor-len", str(params["corridor_length"]),
		"--alt-path", str(params["path_diversity_prob"]),
		"--side-obj", str(params["side_objective_prob"]),
		"--proximity", str(params["proximity_rate"]),
		"--no-layout",
		"--out", out_path,
	]
	# 프리셋 그대로면 이름으로, 손댄 곡선이면 제어점으로 넘긴다
	if str(params["curve"]) == "custom":
		args.append_array(["--curve-points", _points_arg()])
	else:
		args.append_array(["--curve", str(params["curve"])])

	# 파이썬 출력(한글 포함)을 UTF-8 로 받는다
	OS.set_environment("PYTHONIOENCODING", "utf-8")
	OS.set_environment("PYTHONUTF8", "1")

	_generating = true
	_gen_btn.disabled = true
	_quick_btn.disabled = true
	_thread = Thread.new()
	_thread.start(_run_generator.bind(args))


## 스레드에서 실행 — 첫 번째로 실행되는 Python 을 쓴다
func _run_generator(args: PackedStringArray) -> void:
	var exit_code: int = -1
	var text: String = ""
	var tried: Array = []
	for py in PYTHON_CANDIDATES:
		var output: Array = []
		exit_code = OS.execute(py, args, output, true)
		text = "\n".join(output)
		tried.append(py)
		# -1: 실행 파일 없음, 9009: Windows 의 "python 을 찾을 수 없음" (스토어 별칭)
		if exit_code != -1 and exit_code != 9009:
			break
	if exit_code == -1 or exit_code == 9009:
		text = Settings.tr_ko("Python 실행 파일을 찾지 못했습니다 (시도: %s). Python 을 설치하고 PATH 에 추가하세요.") % ", ".join(tried)
	call_deferred("_on_generation_done", exit_code, text)


func _on_generation_done(exit_code: int, text: String) -> void:
	if _thread != null:
		_thread.wait_to_finish()
		_thread = null
	_generating = false

	if exit_code != 0:
		_gen_btn.disabled = false
		_quick_btn.disabled = false
		# 긴 트레이스백은 마지막 몇 줄만
		var lines: PackedStringArray = text.strip_edges().split("\n")
		var tail: PackedStringArray = lines.slice(maxi(0, lines.size() - 6))
		_show_error(Settings.tr_ko("생성 실패 (exit %d):\n%s") % [exit_code, "\n".join(tail)])
		push_warning("[StartScreen] 생성 실패:\n" + text)
		return

	print("[StartScreen] ", text.strip_edges())
	GameState.generation_params = params.duplicate(true)
	GameState.menu_params = params.duplicate(true)
	GameState.difficulty_override = int(params["difficulty"])
	get_tree().change_scene_to_file("res://scenes/Main.tscn")


func _on_quick_start_pressed() -> void:
	if _generating:
		return
	# 생성 없이 기존 levels/level_data.json (없으면 내장 레벨). 고른 난이도만 적용한다.
	GameState.generation_params = {}
	GameState.menu_params = params.duplicate(true)
	GameState.difficulty_override = int(params["difficulty"])
	get_tree().change_scene_to_file("res://scenes/Main.tscn")


func _on_return_to_title() -> void:
	if _generating:
		return
	get_tree().change_scene_to_file("res://scenes/TitleScreen.tscn")


func _show_error(msg: String) -> void:
	_status.text = msg
	_status.modulate = Color(1.0, 0.45, 0.42)
