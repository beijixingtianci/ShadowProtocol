## TitleScreen — 타이틀 화면: 움직이는 배경 + 입자 + 스캔라인 + 제목 글리치
## 임무 시작 → 생성 설정(StartScreen), 빠른 시작 → 기존 레벨로 바로 시작, 종료 → 프로그램 종료
extends Control

## class_name 대신 preload (전역 클래스 캐시에 의존하지 않도록)
const SettingsPanel := preload("res://scripts/SettingsPanel.gd")

# ── 색 ──
const BG := Color(0.03, 0.04, 0.06)          # 배경
const TEAL := Color(0.25, 0.75, 0.70)        # 강조색 (청록)
const TEAL_DIM := Color(0.12, 0.38, 0.35)    # 약한 강조색 (장식선)
const GRID_COLOR := Color(0.08, 0.12, 0.14)  # 격자선
const SCAN_COLOR := Color(0.15, 0.55, 0.50, 0.06)  # 스캔 띠

# ── 떠오르는 입자 ──
var _particles: Array = []
const PARTICLE_COUNT := 40

var _scan_y: float = 0.0        # 스캔 띠 Y 위치
var _grid_offset: float = 0.0   # 격자 스크롤
var _title_time: float = 0.0    # 제목 애니메이션 시간
var _title_glitch: float = 0.0  # 제목 글리치 세기

var _title_label: Label = null  # 주 제목 (글리치용)
var _bg_canvas: Control = null  # 배경 그리기 레이어


func _ready() -> void:
	# 입자: 무작위 위치에서 천천히 떠오르는 빛 점
	for i in range(PARTICLE_COUNT):
		_particles.append({
			"pos": Vector2(randf() * 1280, randf() * 720),
			"vel": Vector2(randf_range(-8, 8), randf_range(-12, -3)),
			"size": randf_range(1.0, 3.0),
			"alpha": randf_range(0.15, 0.50),
		})
	_build_ui()


func _process(delta: float) -> void:
	# ── 입자 이동, 화면 밖으로 나가면 아래에서 다시 ──
	for p in _particles:
		p["pos"] += p["vel"] * delta
		if p["pos"].y < -10:
			p["pos"].y = 730
			p["pos"].x = randf() * 1280
		if p["pos"].x < -10 or p["pos"].x > 1290:
			p["pos"].x = randf() * 1280
			p["pos"].y = 730

	# ── 스캔 띠: 위 → 아래 반복 ──
	_scan_y += delta * 120.0
	if _scan_y > 740:
		_scan_y = -20.0

	# ── 격자 천천히 스크롤 ──
	_grid_offset += delta * 6.0

	# ── 제목 글리치: 가끔 붉게 흔들린다 ──
	_title_time += delta
	if randf() < 0.006:
		_title_glitch = randf_range(0.08, 0.20)
	_title_glitch = maxf(0.0, _title_glitch - delta * 2.0)
	if _title_label != null:
		if _title_glitch > 0.05:
			_title_label.modulate = Color(1.0, 0.55, 0.55)
			_title_label.position.x = randf_range(-3, 3)
		else:
			_title_label.modulate = Color(0.88, 0.95, 0.93)
			_title_label.position.x = 0.0

	if _bg_canvas != null:
		_bg_canvas.queue_redraw()


# ═══════════════════════════════════════
#  UI 구성
# ═══════════════════════════════════════

func _build_ui() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)

	# ── 배경 ──
	var bg := ColorRect.new()
	bg.color = BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	# ── 움직이는 배경 (격자 / 입자 / 스캔 띠) ──
	_bg_canvas = Control.new()
	_bg_canvas.set_anchors_preset(Control.PRESET_FULL_RECT)
	_bg_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bg_canvas.draw.connect(_draw_background)
	add_child(_bg_canvas)

	# ── 내용 ──
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var root := VBoxContainer.new()
	root.custom_minimum_size = Vector2(520, 0)
	root.add_theme_constant_override("separation", 0)
	root.alignment = BoxContainer.ALIGNMENT_CENTER
	center.add_child(root)

	# 위 장식선
	var top_line := ColorRect.new()
	top_line.color = TEAL_DIM
	top_line.custom_minimum_size = Vector2(0, 1)
	root.add_child(top_line)

	root.add_child(_spacer(30))

	# 위 작은 제목
	var sub_top := _make_label("PROCEDURAL STEALTH FRAMEWORK", 11)
	sub_top.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub_top.modulate = Color(0.35, 0.55, 0.52)
	root.add_child(sub_top)

	root.add_child(_spacer(8))

	# 주 제목 (글리치 때 위치를 흔든다)
	_title_label = _make_label("SHADOW PROTOCOL", 52)
	_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title_label.modulate = Color(0.88, 0.95, 0.93)
	root.add_child(_title_label)

	# 제목 아래 장식선 + ◆
	var title_under := HBoxContainer.new()
	title_under.alignment = BoxContainer.ALIGNMENT_CENTER
	title_under.add_theme_constant_override("separation", 0)
	root.add_child(title_under)

	var line_l := ColorRect.new()
	line_l.color = TEAL_DIM
	line_l.custom_minimum_size = Vector2(120, 1)
	title_under.add_child(line_l)
	var dot := _make_label(" ◆ ", 10)
	dot.modulate = TEAL
	title_under.add_child(dot)
	var line_r := ColorRect.new()
	line_r.color = TEAL_DIM
	line_r.custom_minimum_size = Vector2(120, 1)
	title_under.add_child(line_r)

	root.add_child(_spacer(12))

	# 버전
	var ver := _make_label("v0.9  —  GRADUATION PROJECT 2026", 10)
	ver.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	ver.modulate = Color(0.30, 0.42, 0.40)
	root.add_child(ver)

	root.add_child(_spacer(40))

	# ── 메뉴 버튼 ──
	var menu_box := VBoxContainer.new()
	menu_box.add_theme_constant_override("separation", 8)
	root.add_child(menu_box)

	var btn_start := _make_menu_button("▶   임무 시작", true)
	btn_start.pressed.connect(_on_start_pressed)
	menu_box.add_child(btn_start)

	var btn_quick := _make_menu_button("⚡   빠른 시작", false)
	btn_quick.pressed.connect(_on_quick_start_pressed)
	menu_box.add_child(btn_quick)

	var btn_settings := _make_menu_button("⚙   설  정", false)
	btn_settings.pressed.connect(_on_settings_pressed)
	menu_box.add_child(btn_settings)

	var btn_quit := _make_menu_button("✕   종료", false)
	btn_quit.pressed.connect(_on_quit_pressed)
	menu_box.add_child(btn_quit)

	root.add_child(_spacer(30))

	# 아래 장식선
	var bot_line := ColorRect.new()
	bot_line.color = TEAL_DIM
	bot_line.custom_minimum_size = Vector2(0, 1)
	root.add_child(bot_line)

	# 조작 안내
	var footer := _make_label("WASD 이동 · F 상호작용 · E 암살 · Shift 달리기 · Ctrl 은신", 10)
	footer.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	footer.modulate = Color(0.25, 0.35, 0.33)
	root.add_child(footer)


## 높이만 차지하는 빈 컨트롤
func _spacer(height: float) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, height)
	return c


# ═══════════════════════════════════════
#  배경 그리기 (격자 + 입자 + 스캔 띠 + CRT 줄무늬)
# ═══════════════════════════════════════

func _draw_background() -> void:
	var sz := _bg_canvas.size

	# ── 스크롤 격자 ──
	var spacing := 48.0
	var off := fmod(_grid_offset, spacing)
	var x := off
	while x < sz.x:
		_bg_canvas.draw_line(Vector2(x, 0), Vector2(x, sz.y), GRID_COLOR, 1.0)
		x += spacing
	var y := off
	while y < sz.y:
		_bg_canvas.draw_line(Vector2(0, y), Vector2(sz.x, y), GRID_COLOR, 1.0)
		y += spacing

	# ── 입자 (밝은 점 + 바깥 번짐) ──
	for p in _particles:
		var pos: Vector2 = p["pos"]
		var s: float = p["size"]
		var a: float = p["alpha"]
		_bg_canvas.draw_circle(pos, s, Color(TEAL.r, TEAL.g, TEAL.b, a))
		_bg_canvas.draw_circle(pos, s * 2.5, Color(TEAL.r, TEAL.g, TEAL.b, a * 0.15))

	# ── 스캔 띠 (가운데 밝고 양끝 흐림) ──
	var scan_h := 40.0
	for i in range(int(scan_h)):
		var fy: float = float(i) / scan_h
		var alpha: float = SCAN_COLOR.a * sin(fy * PI)
		_bg_canvas.draw_line(
			Vector2(0, _scan_y - scan_h * 0.5 + i),
			Vector2(sz.x, _scan_y - scan_h * 0.5 + i),
			Color(SCAN_COLOR.r, SCAN_COLOR.g, SCAN_COLOR.b, alpha), 1.0)

	# ── CRT 줄무늬 (3px 마다 어두운 선) ──
	var crt_y := 0.0
	while crt_y < sz.y:
		_bg_canvas.draw_line(Vector2(0, crt_y), Vector2(sz.x, crt_y),
			Color(0, 0, 0, 0.06), 1.0)
		crt_y += 3.0


# ═══════════════════════════════════════
#  UI 컴포넌트
# ═══════════════════════════════════════

func _make_label(text: String, size: int) -> Label:
	var l := Label.new()
	l.text = Settings.tr_ko(text)
	l.add_theme_font_size_override("font_size", size)
	return l


func _make_menu_button(text: String, primary: bool) -> Button:
	var b := Button.new()
	b.text = Settings.tr_ko(text)
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(320, 48)
	b.add_theme_font_size_override("font_size", 18 if primary else 15)

	var border_color := TEAL if primary else Color(1, 1, 1, 0.12)
	var bg_color := Color(0.06, 0.10, 0.10) if primary else Color(0.05, 0.06, 0.08)

	# 기본
	var style_normal := StyleBoxFlat.new()
	style_normal.bg_color = bg_color
	style_normal.border_color = border_color
	style_normal.set_border_width_all(2 if primary else 1)
	style_normal.set_corner_radius_all(4)
	style_normal.content_margin_left = 16
	style_normal.content_margin_right = 16
	style_normal.content_margin_top = 10
	style_normal.content_margin_bottom = 10

	# 마우스 오버 (배경·테두리 밝게)
	var style_hover := style_normal.duplicate()
	style_hover.bg_color = bg_color.lightened(0.12 if primary else 0.08)
	style_hover.border_color = border_color.lightened(0.30) if primary else Color(1, 1, 1, 0.25)

	# 눌림
	var style_pressed := style_normal.duplicate()
	style_pressed.bg_color = bg_color.darkened(0.20)

	b.add_theme_stylebox_override("normal", style_normal)
	b.add_theme_stylebox_override("hover", style_hover)
	b.add_theme_stylebox_override("pressed", style_pressed)

	if primary:
		b.add_theme_color_override("font_color", Color(0.80, 1.0, 0.95))
		b.add_theme_color_override("font_hover_color", Color(0.90, 1.0, 0.97))
	else:
		b.add_theme_color_override("font_color", Color(0.55, 0.62, 0.60))
		b.add_theme_color_override("font_hover_color", Color(0.75, 0.85, 0.82))

	return b


# ═══════════════════════════════════════
#  버튼 이벤트
# ═══════════════════════════════════════

## 임무 시작 → 생성 설정 화면 (StartScreen)
func _on_start_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/StartScreen.tscn")


## 빠른 시작 → 생성 없이 기존 levels/level_data.json 으로 시작
func _on_quick_start_pressed() -> void:
	GameState.generation_params = {}
	GameState.menu_params = {}
	GameState.difficulty_override = 1
	get_tree().change_scene_to_file("res://scenes/Main.tscn")


## 설정 → 설정 창 (언어 / 볼륨)
func _on_settings_pressed() -> void:
	# 설정 창은 자체 CanvasLayer 라 현재 씬에 붙이기만 하면 맨 위에 뜬다
	var panel := SettingsPanel.new()
	add_child(panel)


## 게임 종료
func _on_quit_pressed() -> void:
	get_tree().quit()
