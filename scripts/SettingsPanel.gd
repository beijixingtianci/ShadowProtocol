## SettingsPanel — 설정 창 (언어 / 볼륨)
## 사용 (어느 화면에서든):
##     var p := preload("res://scripts/SettingsPanel.gd").new()
##     add_child(p)          # 자체 CanvasLayer 라 모든 것 위에 뜬다
## ESC 또는 바깥 빈 곳 클릭으로 닫는다.
##
## class_name 을 쓰지 않는다 (에디터가 전역 클래스 캐시를 다시 스캔하기 전에는
## "not declared" 파서 오류가 난다 — RoomTemplates 와 같은 이유). 쓰는 쪽에서 preload 한다.
extends CanvasLayer

const PANEL_BG := Color(0.055, 0.065, 0.085, 0.98)
const PANEL_BORDER := Color(0.25, 0.75, 0.70, 0.55)
const OVERLAY := Color(0.0, 0.0, 0.0, 0.72)
const TEAL := Color(0.25, 0.75, 0.70)
const TEXT_DIM := Color(0.55, 0.62, 0.60)
const TEXT_BRIGHT := Color(0.85, 0.92, 0.90)

var _lang_buttons: Dictionary = {}
var _sliders: Dictionary = {}
var _value_labels: Dictionary = {}
var _music_toggle: Button = null
var _overlay: Control = null

## 창이 닫힐 때 발생
signal closed


func _init() -> void:
	layer = 100


func _ready() -> void:
	_build()
	_sync_from_settings()


func _unhandled_input(event: InputEvent) -> void:
	# ESC 로 닫기
	if event.is_action_pressed("ui_cancel"):
		_close()
		get_viewport().set_input_as_handled()


# ═══════════════════════════════════════
#  UI 구성
# ═══════════════════════════════════════

func _build() -> void:
	# ── 반투명 오버레이 (빈 곳 클릭 시 닫기) ──
	_overlay = Control.new()
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	_overlay.gui_input.connect(_on_overlay_input)
	add_child(_overlay)
	_overlay.draw.connect(_draw_overlay)

	# ── 가운데 정렬 ──
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.add_child(center)

	# ── 패널 ──
	var panel := PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	panel.custom_minimum_size = Vector2(520, 0)
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
	var title := _label("설  정", 26)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.modulate = TEXT_BRIGHT
	root.add_child(title)

	var sub := _label("SETTINGS", 10)
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.modulate = Color(0.35, 0.50, 0.48)
	root.add_child(sub)

	root.add_child(_sep())

	# ── 언어 ──
	root.add_child(_section_label("언어 / Language"))

	var lang_row := HBoxContainer.new()
	lang_row.add_theme_constant_override("separation", 8)
	root.add_child(lang_row)

	for code in Settings.LANGUAGES.keys():
		var ready: bool = Settings.is_language_ready(code)
		var text: String = str(Settings.LANGUAGES[code])
		if not ready:
			text += "  (번역 준비 중)"
		var b := _make_button(text, false)
		b.disabled = not ready
		b.tooltip_text = "" if ready else "이 언어의 번역이 아직 완료되지 않았습니다"
		b.pressed.connect(_on_language_pressed.bind(code))
		lang_row.add_child(b)
		_lang_buttons[code] = b

	# ── 사운드 ──
	root.add_child(_sep())
	root.add_child(_section_label("사운드 / Sound"))

	var note := _label("※ BGM은 긴장도(alert)에 따라 자동으로 전환됩니다. 스위치로 켜고 끌 수 있습니다.", 10)
	note.modulate = Color(0.42, 0.48, 0.46)
	root.add_child(note)

	root.add_child(_slider_row("master", "전체 볼륨", "Master"))
	root.add_child(_slider_row("bgm", "BGM", "BGM"))
	root.add_child(_slider_row("sfx", "효과음", "SFX"))

	# ── BGM On/Off 토글 ──
	var music_row := HBoxContainer.new()
	music_row.add_theme_constant_override("separation", 12)
	var music_label := _label("BGM 스위치", 13)
	music_label.custom_minimum_size = Vector2(96, 0)
	music_label.modulate = Color(0.78, 0.84, 0.82)
	music_row.add_child(music_label)
	_music_toggle = _make_button("켜짐", false)
	_music_toggle.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_music_toggle.pressed.connect(_on_music_toggled)
	music_row.add_child(_music_toggle)
	root.add_child(music_row)

	# ── 하단 버튼 ──
	root.add_child(_sep())

	var btn_row := HBoxContainer.new()
	btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
	btn_row.add_theme_constant_override("separation", 10)
	root.add_child(btn_row)

	var reset_btn := _make_button("기본값 복원", false)
	reset_btn.pressed.connect(_on_reset_pressed)
	btn_row.add_child(reset_btn)

	var close_btn := _make_button("닫  기", true)
	close_btn.pressed.connect(_close)
	btn_row.add_child(close_btn)


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


func _section_label(text: String) -> Label:
	var l := _label(text, 13)
	l.modulate = TEAL
	return l


func _sep() -> HSeparator:
	var s := HSeparator.new()
	s.add_theme_stylebox_override("separator", _sep_style())
	s.add_theme_constant_override("separation", 12)
	return s


func _sep_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(1, 1, 1, 0.08)
	sb.content_margin_top = 1
	sb.content_margin_bottom = 1
	return sb


func _slider_row(key: String, display: String, bus_name: String) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)

	var name_l := _label(display, 13)
	name_l.custom_minimum_size = Vector2(96, 0)
	name_l.modulate = Color(0.78, 0.84, 0.82)
	name_l.tooltip_text = "AudioServer bus: " + bus_name
	row.add_child(name_l)

	var sl := HSlider.new()
	sl.min_value = 0
	sl.max_value = 100
	sl.step = 1
	sl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	sl.custom_minimum_size = Vector2(0, 22)
	sl.focus_mode = Control.FOCUS_NONE
	row.add_child(sl)

	var val_l := _label("80%", 13)
	val_l.custom_minimum_size = Vector2(46, 0)
	val_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	val_l.modulate = TEXT_DIM
	row.add_child(val_l)

	_sliders[key] = sl
	_value_labels[key] = val_l
	sl.value_changed.connect(_on_slider_changed.bind(key))
	return row


func _make_button(text: String, primary: bool) -> Button:
	var b := Button.new()
	b.text = Settings.tr_ko(text)
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(0 if not primary else 140, 38)
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

	var disabled := normal.duplicate()
	disabled.bg_color = Color(0.05, 0.055, 0.07)
	disabled.border_color = Color(1, 1, 1, 0.06)

	b.add_theme_stylebox_override("normal", normal)
	b.add_theme_stylebox_override("hover", hover)
	b.add_theme_stylebox_override("pressed", pressed)
	b.add_theme_stylebox_override("disabled", disabled)

	b.add_theme_color_override("font_color", TEXT_BRIGHT if primary else Color(0.62, 0.68, 0.66))
	b.add_theme_color_override("font_hover_color", Color(0.92, 1.0, 0.97))
	b.add_theme_color_override("font_pressed_color", TEXT_BRIGHT)
	b.add_theme_color_override("font_disabled_color", Color(0.32, 0.36, 0.35))
	return b


# ═══════════════════════════════════════
#  Settings 값과 동기화
# ═══════════════════════════════════════

func _sync_from_settings() -> void:
	# 볼륨 슬라이더
	_sliders["master"].value = round(Settings.master_volume * 100.0)
	_sliders["bgm"].value = round(Settings.bgm_volume * 100.0)
	_sliders["sfx"].value = round(Settings.sfx_volume * 100.0)
	_refresh_language_buttons()
	_refresh_music_toggle()


func _refresh_language_buttons() -> void:
	for code in _lang_buttons.keys():
		var b: Button = _lang_buttons[code]
		var selected: bool = (code == Settings.language)
		var sb: StyleBoxFlat = b.get_theme_stylebox("normal").duplicate()
		if selected:
			sb.bg_color = Color(0.10, 0.20, 0.20)
			sb.border_color = TEAL
			sb.set_border_width_all(2)
			b.add_theme_color_override("font_color", Color(0.85, 1.0, 0.96))
		else:
			sb.bg_color = Color(0.07, 0.08, 0.11)
			sb.border_color = Color(1, 1, 1, 0.14)
			sb.set_border_width_all(1)
			b.add_theme_color_override("font_color", Color(0.62, 0.68, 0.66))
		b.add_theme_stylebox_override("normal", sb)
		if selected:
			b.add_theme_stylebox_override("hover", sb)
			b.add_theme_stylebox_override("pressed", sb)


# ═══════════════════════════════════════
#  이벤트
# ═══════════════════════════════════════

func _on_slider_changed(value: float, key: String) -> void:
	var v: float = clampf(value / 100.0, 0.0, 1.0)
	_value_labels[key].text = "%d%%" % int(round(value))
	match key:
		"master":
			Settings.set_master_volume(v)
		"bgm":
			Settings.set_bgm_volume(v)
		"sfx":
			Settings.set_sfx_volume(v)


func _on_language_pressed(code: String) -> void:
	Settings.set_language(code)
	_refresh_language_buttons()


func _on_music_toggled() -> void:
	Settings.set_music_enabled(not Settings.music_enabled)
	_refresh_music_toggle()


## BGM 스위치 버튼 라벨/색상 갱신
func _refresh_music_toggle() -> void:
	if _music_toggle == null:
		return
	var on: bool = Settings.music_enabled
	_music_toggle.text = Settings.tr_ko("켜짐") if on else Settings.tr_ko("꺼짐")
	var sb: StyleBoxFlat = _music_toggle.get_theme_stylebox("normal").duplicate()
	if on:
		sb.bg_color = Color(0.10, 0.20, 0.20)
		sb.border_color = TEAL
		sb.set_border_width_all(2)
	else:
		sb.bg_color = Color(0.07, 0.08, 0.11)
		sb.border_color = Color(1, 1, 1, 0.14)
		sb.set_border_width_all(1)
	_music_toggle.add_theme_stylebox_override("normal", sb)
	_music_toggle.add_theme_stylebox_override("hover", sb)
	_music_toggle.add_theme_stylebox_override("pressed", sb)


func _on_reset_pressed() -> void:
	Settings.reset_to_defaults()
	_sync_from_settings()


func _on_overlay_input(event: InputEvent) -> void:
	# 바깥 빈 곳을 클릭하면 닫는다 (패널은 mouse_filter=STOP 이라 해당 없음)
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_close()


func _close() -> void:
	closed.emit()
	queue_free()
