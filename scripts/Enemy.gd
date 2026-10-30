## Enemy — 순찰 AI + 손그림 경비병 렌더링
## patrol_speed / patrol_range / light_level 은 Python 진화 탐색 결과에서 주입
extends CharacterBody2D

enum State { PATROL, INVESTIGATE, SUSPICIOUS, ALERT }

var cfg: Dictionary = {}

var patrol_speed: float = 62.0
var chase_speed: float = 132.0
var fov_half_deg: float = 40.0
var fov_range: float = 168.0

var waypoints: Array = []
var facing: float = 0.0
var alive: bool = true

var state: int = State.PATROL
var suspicion: float = 0.0

const OUTLINE := Color(0.05, 0.06, 0.09)
const BODY_CALM := Color(0.52, 0.24, 0.27)
const BODY_SUS := Color(0.68, 0.48, 0.18)
const BODY_ALERT := Color(0.80, 0.22, 0.22)
const BODY_INVESTIGATE := Color(0.45, 0.55, 0.65)   # 청회색 — 궁금하지만 경계는 아님

## INVESTIGATE — 소리 난 곳으로 가서 둘러본다
const INVESTIGATE_DURATION: float = 3.0     # 도착 후 둘러보는 시간(초)
const INVESTIGATE_SPEED_MULT: float = 0.7   # 조심스럽게 걸어간다
const INVESTIGATE_ARRIVE: float = 20.0
const DOOR_INVESTIGATE_DURATION: float = 2.0  # 열린 문은 시체보다 덜 수상하다
const DOOR_NOTICE_RANGE_MULT: float = 0.7     # 문은 플레이어보다 가까이서야 눈에 띈다

var _wp_index: int = 0
var _wp_wait: float = 0.0
var _alert_timer: float = 0.0
var _player: Node2D = null
var _last_seen: Vector2 = Vector2.ZERO
var _step: float = 0.0
var _body_col: Color = BODY_CALM

## 끼임 감지 — 목표로 가는데 실제로 움직이지 못하면 다음 경유점으로 넘어간다
var _stuck_timer: float = 0.0
var _last_pos: Vector2 = Vector2.ZERO

## 대기 중 두리번거리기
var _look_base: float = 0.0
var _look_phase: float = 0.0
var _look_span: float = 0.9

## SUSPICIOUS 수색 (마지막 목격 지점)
var _sus_search_target: Vector2 = Vector2.ZERO
var _sus_timer: float = 0.0
var _sus_searching: bool = false
const SUS_SEARCH_DURATION: float = 4.0   # 마지막 목격 지점 수색 시간
const ALERT_GRACE: float = 1.5           # 놓친 뒤 계속 추격하는 시간

var _investigate_target: Vector2 = Vector2.ZERO
var _investigate_timer: float = 0.0
var _investigate_arrived: bool = false
## 조사 이유 "noise" / "corpse" / "door" — 머리 위 아이콘 구분용
var _investigate_reason: String = ""

## 이미 확인한 시체(instance_id → 확인 당시 corpse_rev)·열린 문(instance_id)
## — 같은 대상으로 반복 조사하지 않는다. 시체가 옮겨지면 corpse_rev 가 올라 다시 반응한다.
var _inspected_corpses: Dictionary = {}
var _inspected_doors: Dictionary = {}


func _ready() -> void:
	add_to_group("enemies")
	_apply_config()
	_rebuild_cone()
	if waypoints.size() > 0:
		facing = (waypoints[0] - global_position).angle()
	_last_pos = global_position
	_look_base = facing


func _apply_config() -> void:
	var ps: float = float(cfg.get("patrol_speed", 0.5))
	patrol_speed = 42.0 + ps * 76.0
	chase_speed = patrol_speed * 2.1

	var pr: float = float(cfg.get("patrol_range", 0.5))
	fov_range = 110.0 + pr * 150.0

	var light: float = float(cfg.get("light_level", 0.5))
	fov_half_deg = 30.0 + light * 22.0


func _physics_process(delta: float) -> void:
	if not alive:
		return
	if not GameState.is_playing:
		velocity = Vector2.ZERO
		return

	if _player == null or not is_instance_valid(_player):
		var found: Array = get_tree().get_nodes_in_group("player")
		if found.size() > 0:
			_player = found[0]
		else:
			return

	var sees: bool = _can_see_player()

	if state == State.PATROL or state == State.INVESTIGATE:
		_scan_evidence()

	if state == State.PATROL:
		_tick_patrol(delta, sees)
	elif state == State.INVESTIGATE:
		_tick_investigate(delta, sees)
	elif state == State.SUSPICIOUS:
		_tick_suspicious(delta, sees)
	else:
		_tick_alert(delta, sees)

	move_and_slide()

	if velocity.length() > 5.0:
		_step += delta * 9.0
	else:
		_step = lerpf(_step, 0.0, delta * 5.0)

	_refresh_visuals(delta)
	queue_redraw()


func _draw() -> void:
	# 바닥 그림자
	draw_set_transform(Vector2(1.5, 2.5), 0.0, Vector2.ONE)
	draw_circle(Vector2.ZERO, 11.0, Color(0, 0, 0, 0.30))

	draw_set_transform(Vector2.ZERO, facing, Vector2.ONE)
	if alive:
		CharArt.draw_guard(self, _body_col, OUTLINE, _visor_color(), _step, state == State.ALERT)
	else:
		CharArt.draw_downed(self, BODY_CALM.darkened(0.35), OUTLINE)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

	if not alive:
		return

	# 의심 게이지 — 머리 위 호
	if suspicion > 0.04:
		var pct: float = clampf(suspicion, 0.0, 1.0)
		var bg := Color(0, 0, 0, 0.45)
		draw_arc(Vector2(0, -19), 8.0, PI, TAU, 18, bg, 3.4, true)
		var col := Color(1.0, 0.85, 0.2)
		if state == State.ALERT:
			col = Color(1.0, 0.25, 0.25)
		draw_arc(Vector2(0, -19), 8.0, PI, PI + PI * pct, 18, col, 3.0, true)

	# 경계 상태 느낌표
	if state == State.ALERT:
		draw_line(Vector2(0, -32), Vector2(0, -25), Color(1, 0.3, 0.3), 3.0, true)
		draw_circle(Vector2(0, -22), 1.8, Color(1, 0.3, 0.3))
	elif state == State.SUSPICIOUS:
		draw_arc(Vector2(0, -28), 3.4, -PI * 0.9, PI * 0.35, 14, Color(1, 0.85, 0.25), 2.4, true)
		draw_circle(Vector2(0.6, -22.5), 1.5, Color(1, 0.85, 0.25))
	elif state == State.INVESTIGATE:
		var font := ThemeDB.fallback_font
		if font != null:
			# 시체를 보고 조사 중이면 "!?", 그 외(소리·열린 문)는 "?"
			var mark: String = "!?" if _investigate_reason == "corpse" else "?"
			var mw: float = font.get_string_size(mark, HORIZONTAL_ALIGNMENT_LEFT, -1, 16).x
			draw_string(font, Vector2(-mw * 0.5, -26), mark,
				HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color(0.65, 0.78, 0.95))


func _visor_color() -> Color:
	if state == State.ALERT:
		return Color(1.0, 0.42, 0.38)
	if state == State.SUSPICIOUS:
		return Color(1.0, 0.82, 0.38)
	if state == State.INVESTIGATE:
		return Color(0.65, 0.78, 0.92)
	return Color(0.48, 0.86, 0.92)


func _can_see_player() -> bool:
	if _player == null:
		return false
	# 엄폐물 옆에서 은신 중이면 보이지 않는다 (탁 트인 곳의 은신은 보이지만 눈치채는 속도가 느리다)
	if _player.has_method("is_concealed") and _player.call("is_concealed") == true:
		return false

	var to_player: Vector2 = _player.global_position - global_position
	var dist: float = to_player.length()
	if dist > fov_range:
		return false
	if absf(angle_difference(to_player.angle(), facing)) > deg_to_rad(fov_half_deg):
		return false

	var space := get_world_2d().direct_space_state
	var query := PhysicsRayQueryParameters2D.create(global_position, _player.global_position, 1)
	query.exclude = [get_rid()]
	var hit: Dictionary = space.intersect_ray(query)
	if not hit.is_empty():
		return false
	return true


## 보이는 플레이어를 알아채는 속도 배율 — 느리게 은신 이동 중이면 덜 눈에 띈다
const SNEAK_NOTICE_MULT: float = 0.6

func _notice_mult() -> float:
	if _player != null and _player.get("is_hiding") == true:
		return SNEAK_NOTICE_MULT
	return 1.0


func _tick_patrol(delta: float, sees: bool) -> void:
	if sees:
		suspicion += 0.85 * delta * _notice_mult()
		_last_seen = _player.global_position
		if suspicion >= 0.5:
			_enter_suspicious(true)
			GameState.raise_alert(0.06)
	else:
		suspicion = maxf(0.0, suspicion - 0.35 * delta)

	if waypoints.is_empty():
		_idle_look(delta)
		velocity = Vector2.ZERO
		return

	# ── 경유점에서 대기 중 ──
	if _wp_wait > 0.0:
		_wp_wait -= delta
		_idle_look(delta)
		velocity = Vector2.ZERO
		return

	var target: Vector2 = waypoints[_wp_index]
	var to_target: Vector2 = target - global_position

	# 도착
	if to_target.length() < 14.0:
		_advance_waypoint()
		velocity = Vector2.ZERO
		return

	# ── 끼임 감지 ──
	# 목표를 향해 걷고 있는데 실제 이동량이 거의 없으면 상자·벽에 낀 것으로 본다
	var moved: float = global_position.distance_to(_last_pos)
	_last_pos = global_position
	if moved < 0.35:
		_stuck_timer += delta
		if _stuck_timer > 1.1:
			_stuck_timer = 0.0
			_advance_waypoint()
			velocity = Vector2.ZERO
			return
	else:
		_stuck_timer = maxf(0.0, _stuck_timer - delta * 1.5)

	facing = lerp_angle(facing, to_target.angle(), 2.4 * delta)
	velocity = to_target.normalized() * patrol_speed


## 다음 경유점으로. 도착할 때마다 잠깐 멈춰 주변을 살핀다.
func _advance_waypoint() -> void:
	if waypoints.size() > 0:
		_wp_index = (_wp_index + 1) % waypoints.size()
	_wp_wait = randf_range(1.0, 2.8)
	_stuck_timer = 0.0
	# 다음 목표 방향을 기준으로 좌우를 훑는다
	if waypoints.size() > 0:
		var nxt: Vector2 = waypoints[_wp_index]
		_look_base = (nxt - global_position).angle()
	else:
		_look_base = facing
	_look_phase = randf_range(0.0, TAU)
	_look_span = randf_range(0.6, 1.15)


## 제자리에서 고개를 좌우로 훑는 동작 (계속 빙글빙글 도는 것보다 자연스럽다)
func _idle_look(delta: float) -> void:
	_look_phase += delta * 1.25
	var sweep: float = sin(_look_phase) * _look_span
	facing = lerp_angle(facing, _look_base + sweep, 2.2 * delta)


## SoundSystem 이 소리가 이 적에게 닿았을 때 호출한다.
## source_pos: 소리 발생 위치 (월드 좌표)
## intensity:  0.0 (겨우 들림) ~ 1.0 (바로 옆)
func hear_noise(source_pos: Vector2, intensity: float) -> void:
	if not alive:
		return
	if state == State.ALERT:
		return  # 이미 추격 중 — 조사 상태로 내려가지 않는다

	# 이미 의심 중이면 소리가 의심을 키운다
	# 수색 중에 들린 소리는 의심을 크게 올린다 — 가득 차면 소리 난 곳으로 추격
	if state == State.SUSPICIOUS:
		suspicion += intensity * 0.3
		_last_seen = source_pos
		_sus_search_target = source_pos
		_sus_timer = 0.0
		if suspicion >= 1.0:
			_enter_alert()
			_alert_timer = 0.0
		return

	# 이미 조사 중 — 크게 들린 소리면 목표를 갱신하고, 의심은 누적한다
	if state == State.INVESTIGATE:
		if intensity > 0.5:
			_start_investigation(source_pos, INVESTIGATE_DURATION, "noise")
		_add_suspicion(intensity * 0.15)
		return

	# PATROL → 소리 난 곳으로
	_start_investigation(source_pos, INVESTIGATE_DURATION, "noise")

	# 도착 전에도 "?" 와 함께 게이지를 살짝 보여 준다
	suspicion = maxf(suspicion, intensity * 0.25)

	GameState.raise_alert(intensity * 0.03)


func _start_investigation(target: Vector2, duration: float, reason: String) -> void:
	_investigate_target = target
	_investigate_timer = duration
	_investigate_arrived = false
	_investigate_reason = reason
	_stuck_timer = 0.0
	_last_pos = global_position
	state = State.INVESTIGATE


## 조사 중 쌓이는 의심. 조사 상태에서는 보지 않고는 SUSPICIOUS 로 넘어가지 않으므로
## 게이지가 가득 차 보이지 않도록 상한을 둔다 (보는 순간 바로 격상되는 효과는 유지).
func _add_suspicion(amount: float) -> void:
	suspicion = minf(0.95, suspicion + amount)


## 시야 안의 증거(시체, 열린 문)를 찾아 조사를 시작하거나 의심을 누적한다.
## 이미 조사 중이면 목표는 바꾸지 않고 의심만 올린다 — 지금 조사를 먼저 끝낸다.
func _scan_evidence() -> void:
	var corpse: Node2D = _scan_for_corpse()
	if corpse != null:
		_inspected_corpses[corpse.get_instance_id()] = int(corpse.get_meta("corpse_rev", 0))
		if state == State.INVESTIGATE:
			_add_suspicion(0.2)
		else:
			_start_investigation(corpse.global_position, INVESTIGATE_DURATION, "corpse")
			suspicion = maxf(suspicion, 0.4)   # 시체는 경보감
			GameState.raise_alert(0.10)
		return

	var door: Node2D = _scan_for_open_door()
	if door != null:
		_inspected_doors[door.get_instance_id()] = true
		if state == State.INVESTIGATE:
			_add_suspicion(0.2)
		else:
			_start_investigation(door.global_position, DOOR_INVESTIGATE_DURATION, "door")
			suspicion = maxf(suspicion, 0.15)  # 열린 문은 약간 수상하다
			GameState.raise_alert(0.03)


## 시야 원뿔 안에서 보이는 가장 가까운 (아직 확인하지 않은) 시체. 없으면 null.
func _scan_for_corpse() -> Node2D:
	var best: Node2D = null
	var best_dist: float = fov_range
	for body in get_tree().get_nodes_in_group("corpses"):
		if not is_instance_valid(body) or body == self:
			continue
		# 옮겨진 시체(corpse_rev 증가)는 이미 본 것이라도 다시 수상하게 여긴다
		if int(_inspected_corpses.get(body.get_instance_id(), -1)) == int(body.get_meta("corpse_rev", 0)):
			continue
		var dist: float = global_position.distance_to(body.global_position)
		if dist > best_dist:
			continue
		if not _in_view(body.global_position, fov_range):
			continue
		best_dist = dist
		best = body
	return best


## 시야 안(단, 거리는 0.7배)에 보이는 아직 확인하지 않은 열린 문. 없으면 null.
func _scan_for_open_door() -> Node2D:
	for door in get_tree().get_nodes_in_group("open_doors"):
		if not is_instance_valid(door):
			continue
		if _inspected_doors.has(door.get_instance_id()):
			continue
		if _in_view(door.global_position, fov_range * DOOR_NOTICE_RANGE_MULT):
			return door
	return null


## 대상 지점이 시야각·거리 안에 있고 벽에 가리지 않는가 (_can_see_player 와 같은 판정)
func _in_view(target: Vector2, max_range: float) -> bool:
	var to_t: Vector2 = target - global_position
	if to_t.length() > max_range:
		return false
	if absf(angle_difference(to_t.angle(), facing)) > deg_to_rad(fov_half_deg):
		return false
	var space := get_world_2d().direct_space_state
	var query := PhysicsRayQueryParameters2D.create(global_position, target, 1)
	query.exclude = [get_rid()]
	return space.intersect_ray(query).is_empty()


func _tick_investigate(delta: float, sees: bool) -> void:
	# 조사 중 플레이어를 보면 곧바로 격상
	if sees:
		suspicion += 1.2 * delta * _notice_mult()
		_last_seen = _player.global_position
		facing = lerp_angle(facing, (_last_seen - global_position).angle(), 3.0 * delta)
		velocity = Vector2.ZERO
		if suspicion >= 0.5:
			_enter_suspicious(true)
			GameState.raise_alert(0.08)
		return

	var to_target: Vector2 = _investigate_target - global_position

	# 벽 너머에서 들린 소리면 벽에 막혀 못 간다 → 끼면 그 자리에서 둘러본다
	if not _investigate_arrived:
		var moved: float = global_position.distance_to(_last_pos)
		_last_pos = global_position
		if moved < 0.35:
			_stuck_timer += delta
		else:
			_stuck_timer = maxf(0.0, _stuck_timer - delta * 1.5)
		if to_target.length() < INVESTIGATE_ARRIVE or _stuck_timer > 1.0:
			_investigate_arrived = true
			_stuck_timer = 0.0
			_look_base = facing
			_look_phase = 0.0
			_look_span = 1.3

	if _investigate_arrived:
		# 도착 — 둘러보기
		_investigate_timer -= delta
		velocity = Vector2.ZERO
		_idle_look(delta)
		if _investigate_timer <= 0.0:
			# 아무것도 없음 → 순찰 복귀
			state = State.PATROL
			suspicion = maxf(0.0, suspicion - 0.2)
			_wp_wait = 0.4
	else:
		# 소리 난 곳으로 조심스럽게 이동
		facing = lerp_angle(facing, to_target.angle(), 4.0 * delta)
		velocity = to_target.normalized() * patrol_speed * INVESTIGATE_SPEED_MULT

	# 조사 중 의심은 천천히 식는다
	suspicion = maxf(0.0, suspicion - 0.08 * delta)


## SUSPICIOUS 로 올라간다 (마지막 목격 지점을 수색 목표로)
## spotted: 플레이어를 직접 보고 올라간 경우 (발각 횟수에 센다. ALERT 에서 내려온 경우는 아님)
func _enter_suspicious(spotted: bool = false) -> void:
	if spotted:
		GameState.detection_count += 1
	state = State.SUSPICIOUS
	_sus_search_target = _last_seen
	_sus_timer = 0.0
	_sus_searching = false
	_stuck_timer = 0.0
	_last_pos = global_position


func _enter_alert() -> void:
	state = State.ALERT
	_alert_timer = 0.0
	_look_base = facing
	GameState.raise_alert(0.15)


## SUSPICIOUS — 보이면 조심스럽게 다가가며 의심이 차오르고, 놓치면 마지막 목격 지점을
## 4초간 수색한 뒤 INVESTIGATE 로 한 단계 내려간다.
func _tick_suspicious(delta: float, sees: bool) -> void:
	if sees:
		_last_seen = _player.global_position
		_sus_search_target = _last_seen
		_sus_timer = 0.0
		_sus_searching = false
		_stuck_timer = 0.0
		_last_pos = global_position
		suspicion += 1.5 * delta * _notice_mult()
		var to_player: Vector2 = _last_seen - global_position
		facing = lerp_angle(facing, to_player.angle(), 3.4 * delta)
		if suspicion >= 1.0:
			_enter_alert()
		elif to_player.length() > 40.0:
			velocity = to_player.normalized() * patrol_speed * 1.3
		else:
			velocity = Vector2.ZERO
		return

	_sus_timer += delta
	suspicion = maxf(0.0, suspicion - 0.15 * delta)

	# 마지막 목격 지점으로 이동 (벽에 막히면 그 자리에서 수색)
	var to_target: Vector2 = _sus_search_target - global_position
	var moved: float = global_position.distance_to(_last_pos)
	_last_pos = global_position
	if moved < 0.35:
		_stuck_timer += delta
	else:
		_stuck_timer = maxf(0.0, _stuck_timer - delta * 1.5)
	if to_target.length() > 15.0 and _stuck_timer < 1.0 and _sus_timer < SUS_SEARCH_DURATION:
		facing = lerp_angle(facing, to_target.angle(), 4.0 * delta)
		velocity = to_target.normalized() * patrol_speed
	else:
		# 도착(또는 막힘) — 그 자리에서 크게 두리번거린다
		velocity = Vector2.ZERO
		if not _sus_searching:
			_sus_searching = true
			_look_base = facing
			_look_phase = 0.0
		_look_phase += delta * 1.8
		facing = lerp_angle(facing, _look_base + sin(_look_phase) * 1.3, 2.6 * delta)

	# 수색 종료 → INVESTIGATE (같은 지점을 한 번 더 둘러본다)
	if _sus_timer >= SUS_SEARCH_DURATION:
		_start_investigation(_sus_search_target, INVESTIGATE_DURATION, "search")
		suspicion = minf(suspicion, 0.45)


## ALERT — 보이면 전속 추격(근접 시 피해), 놓치면 1.5초간 마지막 목격 지점으로 계속 달린 뒤
## SUSPICIOUS 로 한 단계 내려간다.
func _tick_alert(delta: float, sees: bool) -> void:
	if sees:
		_last_seen = _player.global_position
		_alert_timer = 0.0
		var to_player: Vector2 = _last_seen - global_position
		facing = lerp_angle(facing, to_player.angle(), 5.5 * delta)
		if to_player.length() < 32.0:
			GameState.take_damage()
			velocity = -to_player.normalized() * 90.0
		else:
			velocity = to_player.normalized() * chase_speed
		GameState.raise_alert(0.10 * delta)
		return

	_alert_timer += delta
	if _alert_timer < ALERT_GRACE:
		var to_last: Vector2 = _last_seen - global_position
		if to_last.length() > 15.0:
			facing = lerp_angle(facing, to_last.angle(), 5.0 * delta)
			velocity = to_last.normalized() * chase_speed
		else:
			velocity = Vector2.ZERO
			_idle_look(delta)
	else:
		# ALERT → SUSPICIOUS: 아직 매우 의심스럽다
		_enter_suspicious()
		suspicion = 0.85
		_look_base = facing
		GameState.raise_alert(-0.05)


func die() -> void:
	alive = false
	# 다른 경비병이 시체를 발견할 수 있도록
	add_to_group("corpses")
	velocity = Vector2.ZERO
	collision_layer = 0
	collision_mask = 0
	z_index = 3
	var cone: Polygon2D = get_node_or_null("Cone")
	if cone != null:
		cone.visible = false
	queue_redraw()


func _rebuild_cone() -> void:
	var cone: Polygon2D = get_node_or_null("Cone")
	if cone == null:
		return
	var pts := PackedVector2Array()
	var cols := PackedColorArray()
	pts.append(Vector2.ZERO)
	cols.append(Color(1, 1, 1, 0.34))
	var segments: int = 18
	for i in range(segments + 1):
		var t: float = float(i) / float(segments)
		var ang: float = deg_to_rad(-fov_half_deg + 2.0 * fov_half_deg * t)
		pts.append(Vector2(cos(ang), sin(ang)) * fov_range)
		# 가장자리로 갈수록 투명
		var edge_fade: float = 1.0 - absf(t - 0.5) * 1.1
		cols.append(Color(1, 1, 1, 0.02 * edge_fade))
	cone.polygon = pts
	cone.vertex_colors = cols


func _refresh_visuals(delta: float) -> void:
	var target_col: Color = BODY_CALM
	if state == State.INVESTIGATE:
		target_col = BODY_INVESTIGATE
	elif state == State.SUSPICIOUS:
		target_col = BODY_SUS
	elif state == State.ALERT:
		target_col = BODY_ALERT
	_body_col = _body_col.lerp(target_col, delta * 6.0)

	var cone: Polygon2D = get_node_or_null("Cone")
	if cone != null:
		cone.rotation = facing
		if state == State.PATROL:
			cone.color = Color(0.38, 0.85, 0.55)
		elif state == State.INVESTIGATE:
			cone.color = Color(0.55, 0.72, 0.95)
		elif state == State.SUSPICIOUS:
			cone.color = Color(1.0, 0.78, 0.18)
		else:
			cone.color = Color(1.0, 0.26, 0.24)
