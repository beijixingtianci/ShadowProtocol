## Main — 진입점. 레벨 / 플레이어 / 조명환경 / HUD 구성
extends Node2D

@export var level_path: String = "res://levels/level_data.json"
@export var layout_seed: int = 42

## 0=EASY  1=NORMAL  2=HARD  3=BRUTAL
@export_range(0, 3) var difficulty: int = 1

## 전역 밝기 — 회색 바닥이 회색으로 보이도록 밝게 잡는다
const AMBIENT := Color(0.80, 0.81, 0.84)

## 장면 바깥(벽 너머) 붉은 영역
const VOID_RED := Color(0.86, 0.09, 0.06)

## class_name 대신 preload (전역 클래스 캐시에 의존하지 않도록)
const PauseMenu := preload("res://scripts/PauseMenu.gd")
const TensionTracker := preload("res://scripts/TensionTracker.gd")

var loader: Node2D = null
var player: CharacterBody2D = null

var _hp_lbl: Label = null
var _kill_lbl: Label = null
var _key_lbl: Label = null
var _alert_bar: ProgressBar = null
var _room_lbl: Label = null
var _obj_lbl: Label = null
var _msg_box: VBoxContainer = null
var _curve_lbl: Label = null

var _overlay: ColorRect = null
var _over_title: Label = null
var _over_msg: Label = null
var _chart: Control = null
var _stats_grid: GridContainer = null

var _tension_bar: ProgressBar = null
var _tension_lbl: Label = null

## 마지막으로 밟은 복도 타일의 간선들 — 방에 들어설 때 "어느 복도로 왔는가" 판정용
var _last_corridor_edges: Array = []

var _exit_marker: Node2D = null
var _exit_pos: Vector2 = Vector2.ZERO

var _shake: float = 0.0
var _last_room_id: String = ""
var _cam: Camera2D = null


func _ready() -> void:
	randomize()

	# 전역 밝기
	var ambient := CanvasModulate.new()
	ambient.color = AMBIENT
	add_child(ambient)

	_build_hud()

	loader = Node2D.new()
	loader.name = "Loader"
	loader.set_script(load("res://scripts/LevelLoader.gd"))
	loader.add_to_group("level_loader")
	add_child(loader)

	# JSON 의 meta.difficulty 가 있으면 그것을 쓰고, 없으면 인스펙터 값
	var use_diff: int = difficulty
	var peek: Dictionary = loader.peek_meta(level_path)
	if peek.has("difficulty"):
		use_diff = int(peek["difficulty"])
	# 시작 화면에서 고른 난이도가 가장 우선
	if GameState.difficulty_override >= 0:
		use_diff = GameState.difficulty_override
	var from_file: bool = loader.build(level_path, layout_seed, use_diff)

	# 장면 바깥 붉은 영역 — CanvasModulate 영향을 받지 않도록 별도 레이어
	_build_void()

	# 난이도에 따른 시작 스탯
	GameState.start_hp = loader.difficulty_hp()
	GameState.start_kills = loader.difficulty_kills()
	GameState.alert_mul = loader.difficulty_alert_mul()

	# 통과 가능성 실제 검사
	var check: Dictionary = loader.verify_solvable(loader.door_plans())
	if bool(check.get("ok", false)):
		print("[검증] %s 난이도 — 클리어 가능 ✓  (도달 타일 %d/%d)" % [
			loader.difficulty_name(), check.get("reachable", 0), check.get("total", 0)])
	else:
		push_warning("[검증] 문제 발견: " + str(check.get("problems", [])))

	player = Entities.make_player()
	add_child(player)
	player.global_position = loader.entry_position()
	_cam = player.get_node_or_null("Cam")

	_exit_pos = loader.exit_position()
	_make_exit_marker()

	# 미니맵 (M) — 게임을 일시정지하고 전체 지도를 보여 준다
	var minimap = preload("res://scripts/Minimap.gd").new()
	minimap.name = "Minimap"
	add_child(minimap)

	GameState.reset_run()
	GameState.game_finished.connect(_on_finished)
	GameState.message_posted.connect(_on_message)

	var diff_txt: String = Settings.tr_ko("난이도  ") + loader.difficulty_name()
	if from_file:
		diff_txt += Settings.tr_ko("      곡선  ") + _curve_label()
		if GameState.dtw_fitness >= 0.0:
			diff_txt += "   DTW %.3f" % GameState.dtw_fitness
	else:
		diff_txt += Settings.tr_ko("      내장 레벨")
	_curve_lbl.text = diff_txt


## 벽 바깥을 붉게 칠한다. CanvasModulate 가 적용되지 않는 별도 레이어에 둔다.
func _build_void() -> void:
	var void_layer := CanvasLayer.new()
	void_layer.name = "VoidLayer"
	void_layer.layer = -20
	void_layer.follow_viewport_enabled = true
	add_child(void_layer)

	var b: Rect2 = loader.map_bounds()
	var pad: float = 2400.0

	var rect := ColorRect.new()
	rect.color = VOID_RED
	rect.position = b.position - Vector2(pad, pad)
	rect.size = b.size + Vector2(pad * 2.0, pad * 2.0)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	void_layer.add_child(rect)


func _process(delta: float) -> void:
	if player == null:
		return

	var room: Dictionary = loader.room_at(player.global_position)
	if room.is_empty():
		# 복도 위 — 어느 간선의 복도인지 기억해 둔다
		var ce: Array = loader.corridor_edges_at(player.global_position)
		if not ce.is_empty():
			_last_corridor_edges = ce
	else:
		var rid: String = str(room.get("id", ""))
		GameState.enter_room(rid, str(room.get("type", "")), bool(room.get("safe_zone", false)))
		if rid != _last_room_id:
			var prev_id: String = _last_room_id
			_last_room_id = rid
			if GameState.is_playing:
				var edge: Dictionary = _resolve_entry_edge(prev_id, rid)
				GameState.record_room_entry(room, edge, loader.out_edges_of(rid), loader.proximity_of(rid))
			_last_corridor_edges = []
			_on_player_enter_room(room)
	loader.update_reveal(player.global_position, GameState.current_room_id)

	# 실시간 긴장도 — 주변 경비의 상태·거리
	GameState.update_live_tension(delta,
		TensionTracker.guard_threat(player.global_position, get_tree().get_nodes_in_group("enemies")))

	_refresh_hud()
	_tick_shake(delta)

	if _exit_marker != null:
		_exit_marker.queue_redraw()

	if not GameState.is_playing:
		return

	if GameState.all_objectives_done():
		if player.global_position.distance_to(_exit_pos) < 46.0:
			GameState.finish(true)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		_handle_esc()
		get_viewport().set_input_as_handled()


## ESC: 게임 중이면 일시정지, 종료 화면이면 재시작 ("RETRY ( ESC )" 버튼과 동일)
func _handle_esc() -> void:
	if GameState.is_playing:
		_open_pause_menu()
	else:
		_on_retry()


## ESC → 일시정지 메뉴. (기존에는 reload_current_scene 로 게임이 재시작되었음)
func _open_pause_menu() -> void:
	if not GameState.is_playing:
		return
	if get_tree().paused:   # 지도(M) 등으로 이미 정지 중이면 중복 생성 방지
		return
	get_tree().paused = true
	add_child(PauseMenu.new())


# ═══════════════════════════════════════
#  화면 흔들림
# ═══════════════════════════════════════

func kick_shake(amount: float) -> void:
	_shake = maxf(_shake, amount)


func _tick_shake(delta: float) -> void:
	if _cam == null:
		return
	if _shake <= 0.01:
		_cam.offset = _cam.offset.lerp(Vector2.ZERO, delta * 12.0)
		return
	_shake = maxf(0.0, _shake - delta * 26.0)
	_cam.offset = Vector2(randf_range(-_shake, _shake), randf_range(-_shake, _shake))


# ═══════════════════════════════════════
#  HUD
# ═══════════════════════════════════════

func _build_hud() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 10
	add_child(layer)

	# ── 상단 패널 ──
	var top_panel := PanelContainer.new()
	top_panel.position = Vector2(16, 14)
	top_panel.add_theme_stylebox_override("panel",
		VisualKit.panel_style(Color(0.04, 0.05, 0.08, 0.80), Color(1, 1, 1, 0.10), 8))
	layer.add_child(top_panel)

	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 20)
	top_panel.add_child(top)

	_hp_lbl = _stat_label("HP 3")
	top.add_child(_hp_lbl)
	top.add_child(_divider())

	_kill_lbl = _stat_label("KILL 3")
	top.add_child(_kill_lbl)
	top.add_child(_divider())

	_key_lbl = _stat_label("KEY -")
	top.add_child(_key_lbl)
	top.add_child(_divider())

	var alert_box := HBoxContainer.new()
	alert_box.add_theme_constant_override("separation", 8)
	top.add_child(alert_box)

	var alert_cap := _stat_label("ALERT")
	alert_cap.modulate = Color(0.55, 0.57, 0.64)
	alert_box.add_child(alert_cap)

	_alert_bar = ProgressBar.new()
	_alert_bar.max_value = 1.0
	_alert_bar.value = 0.0
	_alert_bar.show_percentage = false
	_alert_bar.custom_minimum_size = Vector2(130, 12)

	var bar_bg := StyleBoxFlat.new()
	bar_bg.bg_color = Color(0.10, 0.11, 0.15)
	bar_bg.set_corner_radius_all(6)
	var bar_fg := StyleBoxFlat.new()
	bar_fg.bg_color = Color(1, 1, 1)
	bar_fg.set_corner_radius_all(6)
	_alert_bar.add_theme_stylebox_override("background", bar_bg)
	_alert_bar.add_theme_stylebox_override("fill", bar_fg)
	alert_box.add_child(_alert_bar)

	# ── 긴장도 T(t) — Python 파이프라인과 같은 공식 (TensionTracker) ──
	top.add_child(_divider())
	var t_box := HBoxContainer.new()
	t_box.add_theme_constant_override("separation", 8)
	top.add_child(t_box)
	var t_cap := _stat_label("TENSION")
	t_cap.modulate = Color(0.55, 0.57, 0.64)
	t_box.add_child(t_cap)
	_tension_bar = ProgressBar.new()
	_tension_bar.max_value = 1.0
	_tension_bar.show_percentage = false
	_tension_bar.custom_minimum_size = Vector2(130, 12)
	_tension_bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_tension_bar.add_theme_stylebox_override("background", bar_bg)
	_tension_bar.add_theme_stylebox_override("fill", bar_fg)
	t_box.add_child(_tension_bar)
	_tension_lbl = _stat_label("0.00")
	_tension_lbl.custom_minimum_size = Vector2(36, 0)
	t_box.add_child(_tension_lbl)

	# ── 현재 방 (우상단) ──
	var room_panel := PanelContainer.new()
	room_panel.anchor_left = 1.0
	room_panel.anchor_right = 1.0
	room_panel.offset_left = -220.0
	room_panel.offset_right = -16.0
	room_panel.offset_top = 14.0
	room_panel.add_theme_stylebox_override("panel",
		VisualKit.panel_style(Color(0.04, 0.05, 0.08, 0.80), Color(1, 1, 1, 0.10), 8))
	layer.add_child(room_panel)

	_room_lbl = _stat_label("")
	_room_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_room_lbl.modulate = Color(0.70, 0.74, 0.84)
	room_panel.add_child(_room_lbl)

	# ── 좌하단 목표 패널 ──
	var obj_panel := PanelContainer.new()
	obj_panel.anchor_top = 1.0
	obj_panel.anchor_bottom = 1.0
	obj_panel.offset_left = 16.0
	obj_panel.offset_right = 330.0
	obj_panel.offset_top = -84.0
	obj_panel.offset_bottom = -16.0
	obj_panel.add_theme_stylebox_override("panel",
		VisualKit.panel_style(Color(0.04, 0.05, 0.08, 0.80), Color(1, 1, 1, 0.10), 8))
	layer.add_child(obj_panel)

	var obj_box := VBoxContainer.new()
	obj_box.add_theme_constant_override("separation", 4)
	obj_panel.add_child(obj_box)

	_obj_lbl = _mk_label("목표 0/0", 15)
	obj_box.add_child(_obj_lbl)

	_curve_lbl = _mk_label("", 11)
	_curve_lbl.modulate = Color(0.48, 0.55, 0.68)
	obj_box.add_child(_curve_lbl)

	# ── 조작 안내 (우하단) ──
	var help := _mk_label(
		"WASD 이동     Shift 달리기     Ctrl 은신 (엄폐물 옆: 안 보임)     마우스 조준     F 상호작용     E 암살(배후) · F 시체 운반     M 지도     F3 소음 표시", 11)
	help.modulate = Color(0.38, 0.40, 0.47)
	help.anchor_left = 0.0
	help.anchor_right = 1.0
	help.anchor_top = 1.0
	help.anchor_bottom = 1.0
	help.offset_right = -18.0
	help.offset_top = -30.0
	help.offset_bottom = -14.0
	help.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	layer.add_child(help)

	# ── 메시지 ──
	_msg_box = VBoxContainer.new()
	_msg_box.anchor_left = 0.5
	_msg_box.anchor_right = 0.5
	_msg_box.offset_left = -180.0
	_msg_box.offset_right = 180.0
	_msg_box.offset_top = 74.0
	_msg_box.offset_bottom = 240.0
	_msg_box.add_theme_constant_override("separation", 5)
	layer.add_child(_msg_box)

	# ── 비네트 (게임 화면 위, HUD 아래) ──
	var vig_layer := CanvasLayer.new()
	vig_layer.layer = 5
	add_child(vig_layer)
	vig_layer.add_child(VisualKit.make_vignette())

	# ── 종료 / 결과 화면 ──
	_overlay = ColorRect.new()
	_overlay.color = Color(0.01, 0.01, 0.03, 0.94)
	_overlay.anchor_right = 1.0
	_overlay.anchor_bottom = 1.0
	_overlay.visible = false
	layer.add_child(_overlay)

	var center := CenterContainer.new()
	center.anchor_right = 1.0
	center.anchor_bottom = 1.0
	_overlay.add_child(center)

	var panel := VBoxContainer.new()
	panel.custom_minimum_size = Vector2(760, 0)
	panel.add_theme_constant_override("separation", 10)
	center.add_child(panel)

	_over_title = _mk_label("", 40)
	_over_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	panel.add_child(_over_title)

	_over_msg = _mk_label("", 14)
	_over_msg.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_over_msg.modulate = Color(0.68, 0.72, 0.80)
	panel.add_child(_over_msg)

	# 경험 곡선 비교 그래프
	var chart_panel := PanelContainer.new()
	chart_panel.add_theme_stylebox_override("panel",
		VisualKit.panel_style(Color(0.05, 0.06, 0.09, 1.0), Color(1, 1, 1, 0.10), 8))
	panel.add_child(chart_panel)
	var chart_box := VBoxContainer.new()
	chart_box.add_theme_constant_override("separation", 4)
	chart_panel.add_child(chart_box)
	var chart_head := _mk_label("경험 곡선 비교", 13)
	chart_head.modulate = Color(0.35, 0.85, 0.80)
	chart_box.add_child(chart_head)
	_chart = Control.new()
	_chart.custom_minimum_size = Vector2(0, 250)
	_chart.draw.connect(_draw_result_chart)
	chart_box.add_child(_chart)

	# 통계
	var stats_panel := PanelContainer.new()
	stats_panel.add_theme_stylebox_override("panel",
		VisualKit.panel_style(Color(0.05, 0.06, 0.09, 1.0), Color(1, 1, 1, 0.10), 8))
	panel.add_child(stats_panel)
	var stats_box := VBoxContainer.new()
	stats_box.add_theme_constant_override("separation", 4)
	stats_panel.add_child(stats_box)
	var stats_head := _mk_label("통계", 13)
	stats_head.modulate = Color(0.35, 0.85, 0.80)
	stats_box.add_child(stats_head)
	_stats_grid = GridContainer.new()
	_stats_grid.columns = 4
	_stats_grid.add_theme_constant_override("h_separation", 18)
	_stats_grid.add_theme_constant_override("v_separation", 3)
	stats_box.add_child(_stats_grid)

	var btn_row := HBoxContainer.new()
	btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
	btn_row.add_theme_constant_override("separation", 14)
	panel.add_child(btn_row)

	var menu_btn := Button.new()
	menu_btn.text = Settings.tr_ko("메인 메뉴")
	menu_btn.add_theme_font_size_override("font_size", 15)
	menu_btn.custom_minimum_size = Vector2(220, 44)
	menu_btn.add_theme_stylebox_override("normal",
		VisualKit.panel_style(Color(0.07, 0.08, 0.11, 1.0), Color(1, 1, 1, 0.18), 8))
	menu_btn.add_theme_stylebox_override("hover",
		VisualKit.panel_style(Color(0.12, 0.13, 0.17, 1.0), Color(1, 1, 1, 0.35), 8))
	menu_btn.add_theme_stylebox_override("pressed",
		VisualKit.panel_style(Color(0.05, 0.06, 0.08, 1.0), Color(1, 1, 1, 0.18), 8))
	menu_btn.pressed.connect(_on_return_to_menu)
	btn_row.add_child(menu_btn)

	var btn := Button.new()
	btn.text = Settings.tr_ko("같은 레벨 재시도   ( ESC )")
	btn.add_theme_font_size_override("font_size", 15)
	btn.custom_minimum_size = Vector2(260, 44)
	btn.add_theme_stylebox_override("normal",
		VisualKit.panel_style(Color(0.08, 0.12, 0.13, 1.0), Color(0.28, 0.66, 0.60), 8))
	btn.add_theme_stylebox_override("hover",
		VisualKit.panel_style(Color(0.14, 0.26, 0.25, 1.0), Color(0.42, 0.86, 0.78), 8))
	btn.add_theme_stylebox_override("pressed",
		VisualKit.panel_style(Color(0.06, 0.10, 0.10, 1.0), Color(0.28, 0.66, 0.60), 8))
	btn.pressed.connect(_on_retry)
	btn_row.add_child(btn)


func _stat_label(text: String) -> Label:
	var l := _mk_label(text, 14)
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return l


func _divider() -> Label:
	var d := _mk_label("|", 14)
	d.modulate = Color(1, 1, 1, 0.13)
	return d


func _mk_label(text: String, size: int) -> Label:
	var l := Label.new()
	l.text = Settings.tr_ko(text)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.6))
	l.add_theme_constant_override("shadow_offset_x", 1)
	l.add_theme_constant_override("shadow_offset_y", 1)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


func _refresh_hud() -> void:
	_hp_lbl.text = "HP %d" % GameState.player_hp
	if GameState.player_hp <= 1:
		_hp_lbl.modulate = Color(1, 0.35, 0.35)
	else:
		_hp_lbl.modulate = Color(0.52, 0.95, 0.62)

	_kill_lbl.text = "KILL %d" % GameState.kill_charges
	if GameState.kill_charges <= 0:
		_kill_lbl.modulate = Color(0.62, 0.35, 0.35)
	else:
		_kill_lbl.modulate = Color(0.96, 0.76, 0.40)

	if GameState.keys_held.is_empty():
		_key_lbl.text = "KEY -"
		_key_lbl.modulate = Color(0.50, 0.52, 0.58)
	else:
		_key_lbl.text = "KEY " + ", ".join(GameState.keys_held)
		_key_lbl.modulate = Color(0.98, 0.82, 0.28)

	# HUD 는 실시간 긴장도 (구조 긴장도 + 경보 + 주변 경비)
	var tv: float = GameState.tension.live_tension
	_tension_bar.value = tv
	_tension_bar.modulate = _tension_color(tv)
	_tension_lbl.text = "%.2f" % tv
	_tension_lbl.modulate = _tension_color(tv)

	_alert_bar.value = GameState.alert_level
	if GameState.alert_level > 0.65:
		_alert_bar.modulate = Color(1, 0.28, 0.28)
	elif GameState.alert_level > 0.3:
		_alert_bar.modulate = Color(1, 0.78, 0.25)
	else:
		_alert_bar.modulate = Color(0.38, 0.88, 0.48)

	if GameState.current_room_safe:
		_room_lbl.text = GameState.current_room_type + Settings.tr_ko("  ·  안전 구역")
		_room_lbl.modulate = Color(0.3, 0.85, 0.8)
	else:
		_room_lbl.text = GameState.current_room_type
		_room_lbl.modulate = Color(0.70, 0.74, 0.84)

	var line: String = Settings.tr_ko("목표  %d / %d" % [GameState.objectives_done, GameState.objectives_total])
	var missing: Array = GameState.missing_required_keys()
	if GameState.objectives_done >= GameState.objectives_total and not missing.is_empty():
		line += Settings.tr_ko("        ▸  필요 키  ") + ", ".join(missing)
	if GameState.all_objectives_done():
		line += Settings.tr_ko("        ▸  EXIT 로 탈출")
		_obj_lbl.modulate = Color(0.40, 0.95, 0.85)
	else:
		_obj_lbl.modulate = Color(0.86, 0.88, 0.90)
	_obj_lbl.text = line


# ═══════════════════════════════════════
#  출구 마커
# ═══════════════════════════════════════

func _make_exit_marker() -> void:
	_exit_marker = Node2D.new()
	_exit_marker.position = _exit_pos
	_exit_marker.z_index = 2
	_exit_marker.set_script(load("res://scripts/ExitMarker.gd"))
	add_child(_exit_marker)

	var light := VisualKit.make_room_light(140.0, 0.9, Color(0.40, 1.0, 0.86))
	light.shadow_enabled = false
	_exit_marker.add_child(light)


# ═══════════════════════════════════════
#  이벤트
# ═══════════════════════════════════════

## 방에 들어설 때 지나온 간선을 정한다.
## 1) 방금 걸어온 복도의 간선 중 이 방에 닿는 것 (이전 방에도 닿으면 우선)
## 2) 복도를 밟지 않았으면 이전 방 → 이 방 간선
## 3) 복도가 다른 방을 관통해 그 방에 지나가다 들어온 경우 — 걷고 있던 복도의 간선
## 4) 아무것도 없으면 {} (시작 방과 같은 처리). 첫 방(ENTRY 스폰)도 {}.
func _resolve_entry_edge(prev_id: String, rid: String) -> Dictionary:
	if prev_id == "":
		return {}
	var touching: Array = []
	for e in _last_corridor_edges:
		var s: String = str(e.get("source", ""))
		var t: String = str(e.get("target", ""))
		if s == rid or t == rid:
			if s == prev_id or t == prev_id:
				return e
			touching.append(e)
	if not touching.is_empty():
		return touching[0]
	var direct: Dictionary = loader.edge_between(prev_id, rid)
	if not direct.is_empty():
		return direct
	if not _last_corridor_edges.is_empty():
		return _last_corridor_edges[0]
	return {}


## 목표 곡선 이름 — 시작 화면에서 직접 그린 곡선(custom)은 "사용자 정의" 로 보인다
func _curve_label() -> String:
	if GameState.dtc_name == "custom":
		return Settings.tr_ko("사용자 정의")
	return GameState.dtc_name


## 긴장도 색: 0 초록 → 0.5 노랑 → 1 빨강
func _tension_color(t: float) -> Color:
	if t < 0.5:
		return Color(0.3, 0.8, 0.4).lerp(Color(0.9, 0.8, 0.3), t * 2.0)
	return Color(0.9, 0.8, 0.3).lerp(Color(0.9, 0.25, 0.2), (t - 0.5) * 2.0)


## 플레이어가 다른 방으로 넘어간 순간 한 번 호출
func _on_player_enter_room(room: Dictionary) -> void:
	if not GameState.is_playing:
		return
	if bool(room.get("safe_zone", false)):
		GameState.enter_safe_zone()


func _on_message(text: String, color: Color) -> void:
	if _msg_box == null:
		return

	# post_message 가 번역된 문구를 보내므로, 현재 언어의 "피격!" 과도 비교한다
	if text.begins_with("피격") or text == Settings.tr_ko("피격!"):
		kick_shake(9.0)

	var pc := PanelContainer.new()
	pc.add_theme_stylebox_override("panel",
		VisualKit.panel_style(Color(0.03, 0.04, 0.07, 0.82), Color(color.r, color.g, color.b, 0.45), 6))
	_msg_box.add_child(pc)

	var l := Label.new()
	l.text = text
	l.modulate = color
	l.add_theme_font_size_override("font_size", 15)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pc.add_child(l)

	pc.modulate.a = 0.0
	var tw := create_tween()
	tw.tween_property(pc, "modulate:a", 1.0, 0.12)
	tw.tween_interval(1.7)
	tw.tween_property(pc, "modulate:a", 0.0, 0.45)
	tw.tween_callback(pc.queue_free)


func _on_finished(won: bool) -> void:
	_overlay.visible = true
	_overlay.modulate.a = 0.0
	var tw := create_tween()
	tw.tween_property(_overlay, "modulate:a", 1.0, 0.35)

	if won:
		_over_title.text = "MISSION COMPLETE"
		_over_title.modulate = Color(0.38, 0.92, 0.80)
		_over_msg.text = Settings.tr_ko("탈출 성공")
	else:
		_over_title.text = "MISSION FAILED"
		_over_title.modulate = Color(1, 0.35, 0.35)
		_over_msg.text = Settings.tr_ko("임무 실패 — 발각되었습니다")
		kick_shake(14.0)

	_fill_stats()
	_chart.queue_redraw()


## 결과 통계 (GameState.result — play_log 의 summary 와 같은 값)
func _fill_stats() -> void:
	for c in _stats_grid.get_children():
		c.queue_free()
	var r: Dictionary = GameState.result
	var ms: int = int(r.get("total_time_ms", 0))
	var keys: Array = r.get("keys_collected", [])
	var dp: float = float(r.get("dtw_player_vs_target", -1.0))
	var dl: float = float(r.get("dtw_live_vs_target", -1.0))
	var da: float = float(r.get("dtw_ai_vs_target", -1.0))
	var rows := [
		["DTW (구조 ↔ 목표)", "%.4f" % dp if dp >= 0.0 else "-"],
		["DTW (실시간 ↔ 목표)", "%.4f" % dl if dl >= 0.0 else "-"],
		["DTW (AI ↔ 목표)", "%.4f" % da if da >= 0.0 else "-"],
		["방문한 방", "%d / %d" % [int(r.get("unique_rooms", 0)), loader.rooms.size()]],
		["이동 걸음", str(int(r.get("total_rooms_visited", 0)))],
		["암살", str(int(r.get("kill_count", 0)))],
		["발각", str(int(r.get("detection_count", 0)))],
		["소요 시간", "%d:%02d" % [ms / 60000, (ms / 1000) % 60]],
		["수집 키", ", ".join(keys) if not keys.is_empty() else Settings.tr_ko("없음")],
	]
	for row in rows:
		var k := _mk_label(str(row[0]), 13)
		k.modulate = Color(0.55, 0.60, 0.70)
		_stats_grid.add_child(k)
		var v := Label.new()
		v.text = str(row[1])
		v.add_theme_font_size_override("font_size", 13)
		v.modulate = Color(0.90, 0.92, 0.95)
		_stats_grid.add_child(v)
	var note := _mk_label("DTW 는 낮을수록 목표 곡선에 가깝다", 11)
	note.modulate = Color(0.45, 0.50, 0.58)
	_stats_grid.add_child(note)
	if bool(r.get("partial", false)):
		var pn := Label.new()
		pn.text = Settings.tr_ko("사망 — 진행 %d%% 까지의 구간만 목표와 비교") % int(round(float(r.get("progress_at_end", 0.0)) * 100.0))
		pn.add_theme_font_size_override("font_size", 11)
		pn.modulate = Color(1.0, 0.55, 0.5)
		_stats_grid.add_child(pn)


## 곡선 비교: 목표(파랑 점선) · AI 예측(초록) · 플레이어 구조(주황) · 플레이어 실시간 최고값(빨강).
## x = 진행도 0–100%. 탈출하면 플레이어 곡선은 전 구간, 도중에 죽으면 AI 경로 길이 기준으로
## 간 데까지만 그리고, 그 뒤는 어둡게 가린다.
func _draw_result_chart() -> void:
	var c: Control = _chart
	var font := ThemeDB.fallback_font
	var full := Rect2(Vector2.ZERO, c.size)
	var plot := Rect2(full.position + Vector2(40, 10), full.size - Vector2(56, 52))
	c.draw_rect(plot, Color(0.06, 0.07, 0.10), true)

	# 격자 + 눈금
	for g in [0.0, 0.25, 0.5, 0.75, 1.0]:
		var gy: float = plot.end.y - g * plot.size.y
		c.draw_line(Vector2(plot.position.x, gy), Vector2(plot.end.x, gy), Color(1, 1, 1, 0.06 if g > 0.0 else 0.18), 1.0)
		if font != null:
			c.draw_string(font, Vector2(plot.position.x - 30, gy + 4), "%.2f" % g,
				HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(1, 1, 1, 0.35))
	if font != null:
		for q in [0.0, 0.5, 1.0]:
			var gx: float = plot.position.x + q * plot.size.x
			c.draw_string(font, Vector2(gx - 12, plot.end.y + 14), "%d%%" % int(q * 100),
				HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(1, 1, 1, 0.35))
		c.draw_string(font, Vector2(plot.end.x - 110, plot.end.y + 14), Settings.tr_ko("진행도 →"),
			HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(1, 1, 1, 0.35))

	# span: 곡선이 차지하는 x 구간 (0..span). 목표·AI 는 1, 플레이어는 도달 진행도
	var to_pts := func(arr: Array, span: float = 1.0) -> PackedVector2Array:
		var pts := PackedVector2Array()
		var n: int = arr.size()
		for i in range(n):
			var x: float = plot.position.x + (float(i) / float(maxi(n - 1, 1))) * span * plot.size.x
			var y: float = plot.end.y - clampf(float(arr[i]), 0.0, 1.0) * plot.size.y
			pts.append(Vector2(x, y))
		return pts

	var col_target := Color(0.4, 0.65, 0.95, 0.9)
	var col_ai := Color(0.4, 0.85, 0.5, 0.85)
	var col_player := Color(0.95, 0.6, 0.3)
	var col_live := Color(0.98, 0.32, 0.38)
	var p_end: float = float(GameState.result.get("progress_at_end", 1.0))
	var partial: bool = bool(GameState.result.get("partial", false))

	# 1) 목표 곡선 — 제어점에서 촘촘히 샘플링한 매끈한 선을 점선으로
	var target_line: PackedVector2Array = to_pts.call(TensionTracker.curve_sample(GameState.target_points, 80))
	for i in range(0, target_line.size() - 1, 2):
		c.draw_line(target_line[i], target_line[i + 1], col_target, 2.0, true)
	# 2) AI 예측
	var ai_line: PackedVector2Array = to_pts.call(GameState.simulated_curve)
	if ai_line.size() >= 2:
		c.draw_polyline(ai_line, col_ai, 2.0, true)
	# 3) 플레이어 — 구조 긴장도 (Python 과 같은 공식, 가는 선)
	var pl_line: PackedVector2Array = to_pts.call(GameState.tension.tension_trace, p_end)
	if pl_line.size() >= 2:
		c.draw_polyline(pl_line, col_player, 1.6, true)
	for pt in pl_line:
		c.draw_circle(pt, 2.0, col_player)
	# 4) 플레이어 — 실시간 긴장도 걸음별 최고값 (굵은 선)
	var lv_line: PackedVector2Array = to_pts.call(GameState.tension.live_peak_trace, p_end)
	if lv_line.size() >= 2:
		c.draw_polyline(lv_line, col_live, 2.6, true)
	for pt2 in lv_line:
		c.draw_circle(pt2, 2.8, col_live)

	# 도중 사망: 사망 지점 세로선 + ✕, 그 뒤 구간은 어둡게
	if partial:
		var dx: float = plot.position.x + p_end * plot.size.x
		c.draw_rect(Rect2(Vector2(dx, plot.position.y), Vector2(plot.end.x - dx, plot.size.y)),
			Color(0.02, 0.02, 0.04, 0.55), true)
		var yy: float = plot.position.y
		while yy < plot.end.y:
			c.draw_line(Vector2(dx, yy), Vector2(dx, minf(yy + 5.0, plot.end.y)), Color(1.0, 0.35, 0.35, 0.8), 1.4)
			yy += 9.0
		if lv_line.size() > 0:
			var lp: Vector2 = lv_line[lv_line.size() - 1]
			c.draw_line(lp + Vector2(-6, -6), lp + Vector2(6, 6), Color(1.0, 0.35, 0.35), 2.6, true)
			c.draw_line(lp + Vector2(-6, 6), lp + Vector2(6, -6), Color(1.0, 0.35, 0.35), 2.6, true)
		if font != null:
			c.draw_string(font, Vector2(dx + 4, plot.position.y + 12), Settings.tr_ko("사망"),
				HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(1.0, 0.45, 0.45))

	# 범례
	if font != null:
		var ly: float = full.end.y - 8.0
		var entries := [
			[col_target, Settings.tr_ko("목표 곡선 (%s)") % _curve_label()],
			[col_ai, Settings.tr_ko("AI 예측 (shortest_path)")],
			[col_player, Settings.tr_ko("플레이어 · 구조")],
			[col_live, Settings.tr_ko("플레이어 · 실시간 (최고값)")],
		]
		var lx: float = plot.position.x
		for en in entries:
			c.draw_line(Vector2(lx, ly - 4), Vector2(lx + 22, ly - 4), en[0], 2.5, true)
			c.draw_string(font, Vector2(lx + 28, ly), str(en[1]), HORIZONTAL_ALIGNMENT_LEFT, -1, 11,
				Color(0.85, 0.87, 0.92))
			lx += 28.0 + font.get_string_size(str(en[1]), HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x + 26.0


func _on_return_to_menu() -> void:
	# "메인 메뉴" = 타이틀 화면 (StartScreen 은 생성 파라미터 설정 화면이므로 아님)
	get_tree().change_scene_to_file("res://scenes/TitleScreen.tscn")


func _on_retry() -> void:
	get_tree().reload_current_scene()
