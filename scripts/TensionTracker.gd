## TensionTracker — 긴장도 T(t) 를 Python 파이프라인과 같은 공식으로 계산한다
##
## stealth_pcg/simulation/tension.py  TensionCalculator.compute() 의 GDScript 이식:
##
##   T(t) = clamp( max( Σ wᵢ·dᵢ(t),  τ·T(t-1) ), 0, 1 )
##
##   d_patrol         들어온 간선의 patrol_density  (시작 방: 나가는 간선 평균)
##   d_exposure       min(exposure_length / 5, 1)
##   d_cover_deficit  1 - cover_availability
##   d_node_threat    방의 threat_level → low 0.1 / medium 0.4 / high 0.8 / variable 0.5
##   d_cumulative     마지막 안전 구역 이후 걸음 수 / cumulative_cap (ENTRY·safe_zone 에서 0)
##   d_lock_pressure  이 방에서 나가는(source) 잠금 간선의 키가 없으면 0.8
##   d_noise          들어온 간선 noise_level → silent 0 / low 0.2 / medium 0.5 / high 0.9
##   d_ambient_audio  공유벽마다 sound_leak × 이웃 방 위협 의 최댓값
##   d_ambient_visual 공유벽마다 visual_leak × 이웃 방 위협 의 최댓값
##
## 가중치는 레벨 JSON 의 meta.tension_weights 를 그대로 쓴다 (없으면 Python 기본값).
## 시작 방(들어온 간선 없음)은 Python 과 같이 노출·엄폐·소음 항이 0 이다.
##
## 곡선 샘플링(TensionCurve.evaluate/sample)과 DTW(curves/dtw_wrapper.py) 도 여기 있다.
##
## ── 실시간 긴장도 (게임 전용 — Python 에는 없는 층) ──
## 위의 "구조 긴장도" 는 지도만 보고 방에 들어설 때 한 번 정해진다. 경비가 실제로 무엇을
## 하는지는 모른다. 실시간 긴장도는 그 위에 지금 상황을 얹은 값으로, 매 프레임 갱신한다:
##
##   raw  = clamp( T_room + LIVE_W_ALERT·alert_level + LIVE_W_GUARD·guard_threat, 0, 1 )
##   guard_threat = max_경비( 상태 가중치 × (1 - 거리/GUARD_RANGE) )
##                  상태 가중치: 순찰 0.15 / 조사 0.35 / 의심 0.65 / 추격 1.0
##   live: raw 보다 낮으면 빠르게 따라 오르고, 높으면 1.5초마다 0.6 배로 천천히 내려간다
##         (Python 의 τ=0.6 이월을 시간 축으로 옮긴 것). 방에 들어서면 최소 T_room.
##
## 방(걸음)마다 live 의 최고값·평균을 남긴다 → 결과 화면 / play_log 의 "실시간" 곡선.
##
## class_name 을 쓰지 않는다 — 쓰는 쪽에서 preload 한다.
extends RefCounted

## Python TensionWeights 기본값
const DEFAULT_WEIGHTS := {
	"w_patrol": 0.22,
	"w_exposure": 0.12,
	"w_cover": 0.12,
	"w_node_threat": 0.13,
	"w_cumulative": 0.12,
	"w_lock_pressure": 0.08,
	"w_noise": 0.05,
	"w_ambient_audio": 0.10,
	"w_ambient_visual": 0.06,
	"decay_tau": 0.6,
	"cumulative_cap": 8,
}

## ThreatLevel → 수치 (tension.py threat_map / graph.py _THREAT_VAL)
const THREAT_VALUE := {"low": 0.1, "medium": 0.4, "high": 0.8, "variable": 0.5}

## NodeType → 기본 ThreatLevel (core/types.py DEFAULT_THREAT) — threat_level 필드가 없는 구형식용
const DEFAULT_THREAT := {
	"ENTRY": "low", "EXIT": "variable", "OBJECTIVE": "high", "SIDE_OBJECTIVE": "medium",
	"TRANSIT": "low", "OBSERVATION": "low", "HIGH_SECURITY": "high", "CHOKE": "high",
	"ALT_PATH": "low", "KEY_ROOM": "medium",
}

const NOISE_VALUE := {"silent": 0.0, "low": 0.2, "medium": 0.5, "high": 0.9}

## Sakoe-Chiba 밴드 폭 (dtw_wrapper.dtw_distance 기본값)
const DTW_WINDOW_FRACTION: float = 0.12

## 실시간 긴장도
const LIVE_W_ALERT: float = 0.25
const LIVE_W_GUARD: float = 0.35
const GUARD_STATE_WEIGHT := [0.15, 0.35, 0.65, 1.0]   ## Enemy.State 순서: PATROL, INVESTIGATE, SUSPICIOUS, ALERT
const GUARD_RANGE: float = 480.0                      ## 이 거리(px) 밖의 경비는 체감에 영향 없음
const LIVE_RISE_RATE: float = 8.0                     ## 상승 추종 속도 (1/초)
const LIVE_DECAY: float = 0.6                         ## LIVE_DECAY_SEC 마다 이 배율로 감쇠
const LIVE_DECAY_SEC: float = 1.5

var weights: Dictionary = DEFAULT_WEIGHTS.duplicate()

var current_tension: float = 0.0
var tension_trace: Array = []      ## 방에 들어설 때마다 한 값
var components: Array = []         ## 각 걸음의 성분 {d_patrol, ...} (로그·디버그용)

var _prev_tension: float = 0.0
var _steps_since_safe: int = 0

var live_tension: float = 0.0
var live_peak_trace: Array = []    ## 걸음마다 실시간 긴장도 최고값
var live_mean_trace: Array = []    ## 걸음마다 실시간 긴장도 시간 평균
var _step_open: bool = false
var _step_peak: float = 0.0
var _step_sum: float = 0.0
var _step_time: float = 0.0


func reset() -> void:
	current_tension = 0.0
	_prev_tension = 0.0
	_steps_since_safe = 0
	tension_trace.clear()
	components.clear()
	live_tension = 0.0
	live_peak_trace.clear()
	live_mean_trace.clear()
	_step_open = false


## meta.tension_weights 로 가중치를 맞춘다 (모르는 키는 무시, 없는 키는 기본값)
func set_weights(w) -> void:
	weights = DEFAULT_WEIGHTS.duplicate()
	if typeof(w) != TYPE_DICTIONARY:
		return
	for k in w.keys():
		if weights.has(k):
			weights[k] = float(w[k])


func _w(key: String) -> float:
	return float(weights.get(key, DEFAULT_WEIGHTS.get(key, 0.0)))


static func threat_of(room: Dictionary) -> float:
	var lvl: String = str(room.get("threat_level", ""))
	if lvl == "":
		lvl = str(DEFAULT_THREAT.get(str(room.get("type", "")), "low"))
	return float(THREAT_VALUE.get(lvl, 0.3))


## 방에 들어설 때 호출한다.
##   room          LevelLoader 의 방 사전 (id, type, safe_zone, threat_level)
##   entry_edge    지나온 간선 ({} 이면 시작 방과 같은 처리)
##   held_keys     지금 가진 키 (Python 처럼 이 방이 주는 키는 호출 쪽에서 미리 넣는다)
##   out_edges     이 방이 source 인 간선들 (lock pressure, 시작 방 patrol 평균)
##   prox_links    이 방이 낀 공유벽들 [{neighbor: 방 사전, sound_leak, visual_leak}]
func on_enter_room(room: Dictionary, entry_edge: Dictionary, held_keys: Array,
		out_edges: Array, prox_links: Array) -> float:
	var has_edge: bool = not entry_edge.is_empty()

	# ── D: patrol density ──
	var d_patrol: float = 0.0
	if has_edge:
		d_patrol = float(entry_edge.get("patrol_density", 0.0))
	elif not out_edges.is_empty():
		var s: float = 0.0
		for e in out_edges:
			s += float(e.get("patrol_density", 0.0))
		d_patrol = s / float(out_edges.size())

	# ── L: exposure / C: cover deficit / noise ──
	var d_exposure: float = 0.0
	var d_cover: float = 0.0
	var d_noise: float = 0.0
	if has_edge:
		d_exposure = minf(float(entry_edge.get("exposure_length", 1)) / 5.0, 1.0)
		d_cover = 1.0 - float(entry_edge.get("cover_availability", 1.0))
		d_noise = float(NOISE_VALUE.get(str(entry_edge.get("noise_level", "low")), 0.2))

	# ── A: node threat ──
	var d_threat: float = threat_of(room)

	# ── K: cumulative risk ──
	if str(room.get("type", "")) == "ENTRY" or bool(room.get("safe_zone", false)):
		_steps_since_safe = 0
	else:
		_steps_since_safe += 1
	var d_cum: float = minf(float(_steps_since_safe) / maxf(_w("cumulative_cap"), 1.0), 1.0)

	# ── E: lock pressure ──
	var d_lock: float = 0.0
	for e2 in out_edges:
		if bool(e2.get("locked", false)):
			var kid = e2.get("key_id", null)
			if kid != null and str(kid) != "" and not (str(kid) in held_keys):
				d_lock = 0.8
				break

	# ── 공유벽 너머 환경 위협 (청각 / 시각) ──
	var d_audio: float = 0.0
	var d_visual: float = 0.0
	for p in prox_links:
		var tv: float = threat_of(p.get("neighbor", {}))
		d_audio = maxf(d_audio, float(p.get("sound_leak", 0.0)) * tv)
		d_visual = maxf(d_visual, float(p.get("visual_leak", 0.0)) * tv)

	var weighted: float = (
		_w("w_patrol") * d_patrol
		+ _w("w_exposure") * d_exposure
		+ _w("w_cover") * d_cover
		+ _w("w_node_threat") * d_threat
		+ _w("w_cumulative") * d_cum
		+ _w("w_lock_pressure") * d_lock
		+ _w("w_noise") * d_noise
		+ _w("w_ambient_audio") * d_audio
		+ _w("w_ambient_visual") * d_visual
	)

	# ── Booth 식 감쇠 이월 ──
	var t: float = maxf(weighted, _w("decay_tau") * _prev_tension)
	t = clampf(t, 0.0, 1.0)
	_prev_tension = t
	current_tension = t
	tension_trace.append(t)

	# 실시간 층: 새 걸음 시작 — 방에 들어선 순간 최소 구조 긴장도
	live_tension = maxf(live_tension, t)
	_step_open = true
	_step_peak = live_tension
	_step_sum = 0.0
	_step_time = 0.0
	components.append({
		"d_patrol": d_patrol, "d_exposure": d_exposure, "d_cover_deficit": d_cover,
		"d_node_threat": d_threat, "d_cumulative": d_cum, "d_lock_pressure": d_lock,
		"d_noise": d_noise, "d_ambient_audio": d_audio, "d_ambient_visual": d_visual,
	})
	return t


# ═══════════════════════════════════════
#  실시간 긴장도
# ═══════════════════════════════════════

## 플레이어 주변 경비가 주는 위협 (0..1)
static func guard_threat(player_pos: Vector2, enemies: Array) -> float:
	var best: float = 0.0
	for e in enemies:
		if not is_instance_valid(e) or not e.alive:
			continue
		var prox: float = clampf(1.0 - player_pos.distance_to(e.global_position) / GUARD_RANGE, 0.0, 1.0)
		if prox <= 0.0:
			continue
		var w: float = float(GUARD_STATE_WEIGHT[clampi(int(e.state), 0, GUARD_STATE_WEIGHT.size() - 1)])
		best = maxf(best, w * prox)
	return best


## 매 프레임 — 실시간 긴장도를 갱신하고 지금 걸음의 최고값·평균에 반영한다
func update_live(delta: float, alert_level: float, threat: float) -> float:
	if not _step_open:
		return live_tension
	var raw: float = clampf(current_tension + LIVE_W_ALERT * alert_level + LIVE_W_GUARD * threat, 0.0, 1.0)
	if raw >= live_tension:
		live_tension = lerpf(live_tension, raw, 1.0 - exp(-LIVE_RISE_RATE * delta))
	else:
		live_tension = maxf(raw, live_tension * pow(LIVE_DECAY, delta / LIVE_DECAY_SEC))
	_step_peak = maxf(_step_peak, live_tension)
	_step_sum += live_tension * delta
	_step_time += delta
	return live_tension


## 지금 걸음을 닫고 {peak, mean} 을 돌려준다 (다음 방에 들어가기 직전 / 게임 종료 시)
func close_step() -> Dictionary:
	if not _step_open:
		return {}
	_step_open = false
	var mean: float = _step_sum / _step_time if _step_time > 0.0 else _step_peak
	live_peak_trace.append(_step_peak)
	live_mean_trace.append(mean)
	return {"peak": _step_peak, "mean": mean}


# ═══════════════════════════════════════
#  목표 곡선 (TensionCurve) — 제어점 [[x, y], ...], 코사인 보간
# ═══════════════════════════════════════

static func curve_evaluate(points: Array, t: float) -> float:
	if points.is_empty():
		return 0.0
	t = clampf(t, 0.0, 1.0)
	for i in range(points.size() - 1):
		var x0: float = float(points[i][0])
		var x1: float = float(points[i + 1][0])
		if x0 <= t and t <= x1:
			var y0: float = float(points[i][1])
			var y1: float = float(points[i + 1][1])
			if x1 == x0:
				return y0
			var u: float = (t - x0) / (x1 - x0)
			u = (1.0 - cos(u * PI)) / 2.0
			return y0 + (y1 - y0) * u
	return float(points[points.size() - 1][1])


## n 개 균등 샘플 (n < 2 이면 가운데 한 점) — TensionCurve.sample 과 동일
static func curve_sample(points: Array, n: int) -> Array:
	if n < 2:
		return [curve_evaluate(points, 0.5)]
	var out: Array = []
	for i in range(n):
		out.append(curve_evaluate(points, float(i) / float(n - 1)))
	return out


# ═══════════════════════════════════════
#  DTW — dtw_wrapper.py 의 순수 Python 구현과 동일
#  (|a-b| 누적, Sakoe-Chiba 밴드, normalised = raw / (len(a) + len(b)))
# ═══════════════════════════════════════

static func dtw_distance(a: Array, b: Array) -> float:
	var n: int = a.size()
	var m: int = b.size()
	if n == 0 or m == 0:
		return INF
	var window: int = maxi(1, int(ceil(DTW_WINDOW_FRACTION * float(maxi(n, m)))))
	var prev: Array = []
	var curr: Array = []
	prev.resize(m + 1)
	curr.resize(m + 1)
	prev.fill(INF)
	curr.fill(INF)
	prev[0] = 0.0
	for i in range(1, n + 1):
		curr[0] = INF
		var j_start: int = maxi(1, i - window)
		var j_end: int = mini(m, i + window)
		for j in range(1, m + 1):
			if j < j_start or j > j_end:
				curr[j] = INF
			else:
				var cost: float = absf(float(a[i - 1]) - float(b[j - 1]))
				curr[j] = cost + minf(float(prev[j]), minf(float(curr[j - 1]), float(prev[j - 1])))
		var tmp: Array = prev
		prev = curr
		curr = tmp
	return float(prev[m])


static func normalised_dtw(a: Array, b: Array) -> float:
	var total: int = a.size() + b.size()
	if total == 0:
		return 0.0
	return dtw_distance(a, b) / float(total)


## 궤적 하나를 목표 곡선과 비교 — Python FitnessEvaluator 와 같이
## 목표 곡선을 궤적 길이만큼 샘플링한 뒤 normalised DTW (길이 벌점 없음 = 기본 설정)
static func fitness_vs_target(trace: Array, points: Array) -> float:
	return fitness_vs_target_prefix(trace, points, 1.0)


## 목표 곡선의 [0, p_end] 구간을 n 개로 샘플링 (p_end = 1 이면 curve_sample 과 같다)
static func curve_sample_range(points: Array, n: int, p_end: float) -> Array:
	if n < 2:
		return [curve_evaluate(points, 0.5 if p_end >= 1.0 else 0.0)]
	var out: Array = []
	for i in range(n):
		out.append(curve_evaluate(points, p_end * float(i) / float(n - 1)))
	return out


## 도중에 죽은 경우: 목표 곡선도 그 진행도(p_end)까지만 잘라 비교한다
static func fitness_vs_target_prefix(trace: Array, points: Array, p_end: float) -> float:
	if trace.is_empty() or points.is_empty():
		return -1.0
	return normalised_dtw(trace, curve_sample_range(points, trace.size(), clampf(p_end, 0.0, 1.0)))
