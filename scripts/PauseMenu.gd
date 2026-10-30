## PauseMenu — ESC 로 여는 일시정지 메뉴
##
## Main.gd 의 기존 ESC 동작(reload_current_scene = 게임 재시작)을 대체한다.
## 열려 있는 동안 get_tree().paused = true 이므로, 일반 노드는 _process/_input 이 멈춘다.
## 따라서 이 노드는 반드시 PROCESS_MODE_ALWAYS 여야 버튼과 입력이 동작한다.
##
## 사용: Main.gd 에서 add_child(PauseMenu.new())   (const PauseMenu := preload("res://scripts/PauseMenu.gd"))
## 닫힐 때 paused 는 자동으로 false 로 복구된다 (_close / _exit_tree).
##
## class_name 을 쓰지 않는다 (에디터가 전역 클래스 캐시를 다시 스캔하기 전에는
## "not declared" 파서 오류가 난다 — RoomTemplates 와 같은 이유). 쓰는 쪽에서 preload 한다.
extends CanvasLayer

const SettingsPanel := preload("res://scripts/SettingsPanel.gd")

const PANEL_BG := Color(0.055, 0.065, 0.085, 0.98)
const PANEL_BORDER := Color(0.25, 0.75, 0.70, 0.55)
const OVERLAY := Color(0.0, 0.0, 0.0, 0.62)
const TEAL := Color(0.25, 0.75, 0.70)
const TEXT_DIM := Color(0.55, 0.62, 0.60)
const TEXT_BRIGHT := Color(0.85, 0.92, 0.90)

var _overlay: Control = null

## 메뉴가 닫힐 때 발생 (부모가 필요하면 연결)
signal closed


func _init() -> void:
	# SettingsPanel(100) 보다 아래 → 설정 창이 일시정지 메뉴 위에 그려진다
	layer = 90


func _ready() -> void:
	# ⚠️ 핵심: 일시정지 상태에서도 입력과 버튼이 동작해야 한다
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build()


# ═══════════════════════════════════════
#  UI 구성
# ═══════════════════════════════════════

func _build() -> void:
	# ── 반투명 오버레이 (게임 쪽으로 클릭이 새지 않게 막는다) ──
	_overlay = Control.new()
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	_overlay.draw.connect(_draw_overlay)
	add_child(_overlay)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.add_child(center)

	var panel := PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	panel.custom_minimum_size = Vector2(420, 0)
	var ps := StyleBoxFlat.new()
	ps.bg_color = PANEL_BG
	ps.border_color = PANEL_BORDER
	ps.set_border_width_all(1)
	ps.set_corner_radius_all(6)
	ps.content_margin_left = 26
	ps.content_margin_right = 26
	ps.content_margin_top = 22
	ps.content_margin_bottom = 22
	panel.add_theme_stylebox_override("panel", ps)
	center.add_child(panel)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 10)
	panel.add_child(root)

	# ── 제목 ──
	var title := _label("일시정지", 26)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.modulate = TEXT_BRIGHT
	root.add_child(title)

	var sub := _label("PAUSED", 10)
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.modulate = Color(0.35, 0.50, 0.48)
	root.add_child(sub)

	root.add_child(_sep())

	var hint := _label("ESC 를 다시 누르면 계속합니다", 10)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.modulate = TEXT_DIM
	root.add_child(hint)

	root.add_child(_sep())

	# ── 버튼 ──
	var resume_btn := _make_button("계  속", true)
	resume_btn.pressed.connect(_on_resume)
	root.add_child(resume_btn)

	var settings_btn := _make_button("설  정", false)
	settings_btn.pressed.connect(_on_settings)
	root.add_child(settings_btn)

	var retry_btn := _make_button("다시 시작", false)
	retry_btn.pressed.connect(_on_restart)
	root.add_child(retry_btn)

	var menu_btn := _make_button("메뉴로 나가기", false)
	menu_btn.pressed.connect(_on_menu)
	root.add_child(menu_btn)


func _draw_overlay() -> void:
	_overlay.draw_rect(Rect2(Vector2.ZERO, _overlay.size), OVERLAY, true)


# ═══════════════════════════════════════
#  컴포넌트
# ═══════════════════════════════════════

func _label(text: String, size: int) -> Label:
	var l := Label.new()
	l.text = Settings.tr_ko(text)
	l.add_theme_font_size_override("font_size", size)
	return l


func _sep() -> HSeparator:
	var s := HSeparator.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(1, 1, 1, 0.08)
	sb.content_margin_top = 1
	sb.content_margin_bottom = 1
	s.add_theme_stylebox_override("separator", sb)
	s.add_theme_constant_override("separation", 12)
	return s


func _make_button(text: String, primary: bool) -> Button:
	var b := Button.new()
	b.text = Settings.tr_ko(text)
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(0, 38)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.add_theme_font_size_override("font_size", 14)

	var border := TEAL if primary else Color(1, 1, 1, 0.14)
	var bg := Color(0.08, 0.12, 0.12) if primary else Color(0.07, 0.08, 0.11)

	var normal := StyleBoxFlat.new()
	normal.bg_color = bg
	normal.border_color = border
	normal.set_border_width_all(1)
	normal.set_corner_radius_all(4)
	normal.content_margin_left = 14
	normal.content_margin_right = 14
	normal.content_margin_top = 8
	normal.content_margin_bottom = 8

	var hover := normal.duplicate()
	hover.bg_color = bg.lightened(0.10)
	hover.border_color = border.lightened(0.28)

	var pressed := normal.duplicate()
	pressed.bg_color = bg.darkened(0.22)

	b.add_theme_stylebox_override("normal", normal)
	b.add_theme_stylebox_override("hover", hover)
	b.add_theme_stylebox_override("pressed", pressed)
	b.add_theme_color_override("font_color", TEXT_BRIGHT if primary else Color(0.62, 0.68, 0.66))
	b.add_theme_color_override("font_hover_color", Color(0.92, 1.0, 0.97))
	b.add_theme_color_override("font_pressed_color", TEXT_BRIGHT)
	return b


# ═══════════════════════════════════════
#  입력 / 이벤트
# ═══════════════════════════════════════

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		# 설정 창이 열려 있으면 그쪽이 먼저 닫히도록 이번 ESC 는 넘긴다
		for c in get_children():
			if c is SettingsPanel:
				return
		_close()
		get_viewport().set_input_as_handled()


func _on_resume() -> void:
	_close()


func _on_settings() -> void:
	# PauseMenu 가 PROCESS_MODE_ALWAYS 이므로 자식인 SettingsPanel 도 정지 중 동작한다
	add_child(SettingsPanel.new())


func _on_restart() -> void:
	_close()
	get_tree().reload_current_scene()


func _on_menu() -> void:
	_close()
	# "메뉴" = 타이틀 화면 (StartScreen 은 생성 파라미터 설정 화면)
	get_tree().change_scene_to_file("res://scenes/TitleScreen.tscn")


func _close() -> void:
	var t := get_tree()
	if t != null:
		t.paused = false
	closed.emit()
	queue_free()


func _exit_tree() -> void:
	# 씬이 바뀌는 등으로 그냥 사라져도 일시정지가 남지 않게
	var t := get_tree()
	if t != null:
		t.paused = false
