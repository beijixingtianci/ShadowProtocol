## GameState — 전역 상태 (Autoload)
## Python agent.py 의 플레이어 상태 모델과 1:1 대응
extends Node

const TensionTracker := preload("res://scripts/TensionTracker.gd")

signal game_finished(won: bool)
signal message_posted(text: String, color: Color)

var player_hp: int = 3
var kill_charges: int = 3

## 난이도에서 주입되는 시작 스탯
var start_hp: int = 3
var start_kills: int = 3
var alert_mul: float = 1.0
var keys_held: Array = []
var objectives_done: int = 0
var objectives_total: int = 0

## 긴장도 공식의 Â(t) 성분
var alert_level: float = 0.0

## 피격 후 무적 시간(초) — 여러 경비가 동시에 붙어도 이 간격으로만 HP 가 준다
const HURT_COOLDOWN: float = 1.0
var _hurt_cd: float = 0.0

var is_playing: bool = false
var current_room_type: String = ""
var current_room_id: String = ""
var current_room_safe: bool = false

## export_for_godot.py 가 실어 보낸 meta
var meta: Dictionary = {}
var target_curve: Array = []        ## 목표 곡선 제어점의 y 값 (로그 호환용)
var target_points: Array = []       ## 목표 곡선 제어점 [[x, y], ...] — 샘플링·DTW 는 이것을 쓴다
var simulated_curve: Array = []     ## AI(shortest_path) 의 긴장도 궤적

## 플레이어가 실제로 겪은 긴장도 (Python 과 같은 공식, 방에 들어설 때마다 한 값)
var tension = TensionTracker.new()

## 플레이 통계
var detection_count: int = 0   ## 경비가 플레이어를 보고 SUSPICIOUS 로 올라간 횟수
var kill_count: int = 0        ## 암살 성공 횟수 (보너스로 횟수가 늘어도 정확하도록 따로 센다)
var start_ms: int = 0
## 종료 시 계산한 결과 (결과 화면과 play_log 가 같이 쓴다)
var result: Dictionary = {}

## HUD 표시용 곡선 이름과 DTW 적합도 (구형식: meta.dtc_name / dtw_distance,
## v1: meta.target_curve.name / meta.fitness.final). 없으면 -1
var dtc_name: String = ""
var dtw_fitness: float = -1.0
var critical_path: Array = []

## v1 clear_conditions (구형식에서는 비어 있음 → 기존 판정과 동일)
var required_keys: Array = []
var objective_nodes: Array = []
var optional_objectives: Array = []

## 시작 화면에서 넘어온 설정 (생성 파라미터 / 난이도). 빠른 시작이면 비어 있음.
var generation_params: Dictionary = {}
## 시작 화면의 마지막 설정 (메뉴로 돌아왔을 때 복원용)
var menu_params: Dictionary = {}
## 시작 화면에서 고른 난이도 (-1 = JSON meta / 인스펙터 값 사용)
var difficulty_override: int = -1

## 실제 플레이 중 방문한 방과 그때의 경보값 기록 (검증용)
var visit_log: Array = []

## 한 번이라도 들어간 방 (room_id → true) — 미니맵에서 밝게 표시
var visited_rooms: Dictionary = {}
var _visited_ids: Dictionary = {}


func reset_run() -> void:
	player_hp = maxi(1, start_hp)
	_hurt_cd = 0.0
	kill_charges = maxi(1, start_kills)
	keys_held.clear()
	objectives_done = 0
	alert_level = 0.0
	current_room_safe = false
	visit_log.clear()
	_visited_ids.clear()
	visited_rooms.clear()
	tension.reset()
	detection_count = 0
	kill_count = 0
	result = {}
	start_ms = Time.get_ticks_msec()
	is_playing = true


func _process(delta: float) -> void:
	if not is_playing:
		return
	_hurt_cd = maxf(0.0, _hurt_cd - delta)
	if alert_level > 0.0:
		alert_level = maxf(0.0, alert_level - 0.06 * delta)


func raise_alert(amount: float) -> void:
	alert_level = minf(1.0, alert_level + amount * alert_mul)


func has_key(k: String) -> bool:
	return k in keys_held


func all_objectives_done() -> bool:
	return objectives_done >= objectives_total and missing_required_keys().is_empty()


## clear_conditions.required_keys 중 아직 없는 키
func missing_required_keys() -> Array:
	var out: Array = []
	for k in required_keys:
		if not (k in keys_held):
			out.append(k)
	return out


func collect_key(k: String) -> void:
	if not (k in keys_held):
		keys_held.append(k)
	# 키 이름이 들어가므로 원문 키로는 사전 검색이 안 된다 → %s 템플릿으로 번역 후 삽입
	post_message(Settings.tr_ko("KEY %s 획득") % k, Color(1, 0.85, 0.2))


func collect_objective() -> void:
	objectives_done += 1
	post_message("목표 %d/%d 수집" % [objectives_done, objectives_total], Color(0.3, 0.9, 0.9))


func take_damage() -> void:
	# 추격 중인 경비는 붙어 있는 동안 매 물리 프레임 take_damage 를 부른다.
	# 무적 시간이 없으면 0.05초 만에 HP 3 이 모두 사라지므로, 맞은 뒤 잠시 피해를 받지 않는다.
	if _hurt_cd > 0.0:
		return
	_hurt_cd = HURT_COOLDOWN
	player_hp -= 1
	post_message("피격!", Color(1, 0.3, 0.3))
	if player_hp <= 0:
		finish(false)


func use_kill_charge() -> bool:
	if kill_charges <= 0:
		post_message("암살 횟수 소진", Color(1, 0.4, 0.4))
		return false
	kill_charges -= 1
	kill_count += 1
	post_message("암살 성공", Color(1, 0.45, 0.45))
	return true


func visit_room(room_id: String) -> void:
	visited_rooms[room_id] = true


## 매 프레임 — 현재 방 정보만 갱신한다 (기록은 record_room_entry)
func enter_room(room_id: String, room_type: String, safe_zone: bool = false) -> void:
	visit_room(room_id)
	current_room_id = room_id
	current_room_type = room_type
	current_room_safe = safe_zone


## 다른 방으로 넘어간 순간 한 번 — 긴장도를 계산하고 visit_log 에 남긴다.
## 같은 방에 다시 들어와도 기록한다 (Python 시뮬레이션도 되돌아간 방을 한 걸음으로 센다).
func record_room_entry(room: Dictionary, entry_edge: Dictionary, out_edges: Array,
		prox_links: Array) -> float:
	# Python 에이전트는 키 방에 도착하면 키를 먼저 줍고 긴장도를 계산한다 → 같은 규칙
	var keys: Array = keys_held.duplicate()
	var provides: String = str(room.get("provides", ""))
	if provides != "" and not (provides in keys):
		keys.append(provides)

	_close_live_step()
	var t: float = tension.on_enter_room(room, entry_edge, keys, out_edges, prox_links)
	var step: int = tension.tension_trace.size() - 1
	var rid: String = str(room.get("id", ""))
	var safe: bool = bool(room.get("safe_zone", false))
	_visited_ids[rid] = true

	visit_log.append({
		"room_id": rid,
		"room_type": str(room.get("type", "")),
		"entry_edge": str(entry_edge.get("id", "")),
		"alert": snappedf(alert_level, 0.001),
		"tension": snappedf(t, 0.001),
		"target_tension": snappedf(target_at_step(step), 0.001),
		"hp": player_hp,
		"kills_left": kill_charges,
		"keys_held": keys_held.duplicate(),
		"safe_zone": safe,
		"is_safe_zone": safe,
		"detection_count": detection_count,
		"ms": Time.get_ticks_msec() - start_ms,
	})
	return t


## 직전 걸음의 실시간 긴장도 최고값·평균을 그 걸음의 visit_log 에 채운다
func _close_live_step() -> void:
	var st: Dictionary = tension.close_step()
	if st.is_empty() or visit_log.is_empty():
		return
	visit_log[visit_log.size() - 1]["live_peak"] = snappedf(float(st["peak"]), 0.001)
	visit_log[visit_log.size() - 1]["live_mean"] = snappedf(float(st["mean"]), 0.001)


## 매 프레임 (Main) — 주변 경비 위협을 받아 실시간 긴장도 갱신
func update_live_tension(delta: float, guard_threat: float) -> void:
	if is_playing:
		tension.update_live(delta, alert_level, guard_threat)


## AI 경로 길이 (없으면 critical_path 길이) — 진행도 축의 기준 길이
func expected_steps() -> int:
	var expected: int = simulated_curve.size()
	if expected < 2:
		expected = critical_path.size()
	if expected < 2:
		expected = 10
	return expected


## 결과 화면 x 축에서 플레이어 곡선이 끝나는 진행도.
## 탈출하면 1 (Python 처럼 전 구간에 맞춘다), 도중에 죽으면 AI 경로 길이 기준으로 어디까지 갔는지.
func player_progress_end(won: bool) -> float:
	if won:
		return 1.0
	var n: int = tension.tension_trace.size()
	var big_l: int = maxi(expected_steps(), n + 1)
	return clampf(float(n - 1) / float(big_l - 1), 0.0, 1.0)


## 플레이 도중 "지금 이 진행도에서 목표 긴장도" — 최종 길이를 모르므로
## AI 경로 길이(없으면 critical_path 길이)를 예상 길이로 삼는다.
## (결과 화면의 DTW 는 실제 궤적 길이로 다시 샘플링하므로 이 값과 무관하다)
func target_at_step(step: int) -> float:
	if target_points.is_empty():
		return 0.0
	return TensionTracker.curve_evaluate(target_points, float(step) / float(expected_steps() - 1))


## 종료 시 결과 계산 — 결과 화면과 play_log 가 함께 쓴다
func _compute_result(won: bool) -> Dictionary:
	_close_live_step()
	var player_trace: Array = tension.tension_trace.duplicate()
	var live_peak: Array = tension.live_peak_trace.duplicate()
	var live_mean: Array = tension.live_mean_trace.duplicate()
	var keys: Array = keys_held.duplicate()
	# 도중에 죽으면 목표 곡선도 그 진행도까지만 잘라 비교한다
	var p_end: float = player_progress_end(won)
	return {
		"result": "clear" if won else "dead",
		"partial": not won,
		"progress_at_end": snappedf(p_end, 0.001),
		"total_rooms_visited": visit_log.size(),
		"unique_rooms": _visited_ids.size(),
		"total_time_ms": Time.get_ticks_msec() - start_ms,
		"dtw_player_vs_target": snappedf(TensionTracker.fitness_vs_target_prefix(player_trace, target_points, p_end), 0.0001),
		"dtw_live_vs_target": snappedf(TensionTracker.fitness_vs_target_prefix(live_peak, target_points, p_end), 0.0001),
		"dtw_ai_vs_target": snappedf(TensionTracker.fitness_vs_target(simulated_curve, target_points), 0.0001),
		"player_tension_trace": player_trace,
		"player_live_peak_trace": live_peak,
		"player_live_mean_trace": live_mean,
		"ai_tension_trace": simulated_curve,
		"target_curve_name": dtc_name,
		"target_curve_points": target_points,
		"target_sampled_for_player": TensionTracker.curve_sample_range(target_points, maxi(player_trace.size(), 1), p_end),
		"detection_count": detection_count,
		"kill_count": kill_count,
		"keys_collected": keys,
		"hp_left": player_hp,
		"tension_weights": tension.weights,
	}


## 안전 구역에 들어설 때마다 호출 — 경보 초기화
func enter_safe_zone() -> void:
	alert_level = 0.0
	post_message("안전 구역", Color(0.3, 0.85, 0.8))


func finish(won: bool) -> void:
	if not is_playing:
		return
	is_playing = false
	result = _compute_result(won)
	_write_log(won)
	game_finished.emit(won)


func post_message(text: String, color: Color = Color.WHITE) -> void:
	# 여기서 한 번에 번역하므로, post_message 를 부르는 모든 안내 문구가 따라온다
	message_posted.emit(Settings.tr_ko(text), color)


func _write_log(won: bool) -> void:
	var payload := {
		"won": won,
		"meta": meta,
		"target_curve": target_curve,
		"simulated_curve": simulated_curve,
		"dtc_name": dtc_name,
		"generation_params": generation_params,
		"critical_path": critical_path,
		"player_visit_log": visit_log,
		"summary": result,
	}
	var f := FileAccess.open("user://play_log.json", FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(payload, "  "))
		f.close()
		print("[ShadowProtocol] 플레이 로그 저장: ", ProjectSettings.globalize_path("user://play_log.json"))
