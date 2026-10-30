## LevelLoader — 레벨 JSON 을 게임 공간으로 변환
##
## 두 가지 형식을 지원한다 (최상위 "version" 으로 구분):
##
## [legacy] export_for_godot.py 출력 (version 없음)
##   nodes[].id / .type / .provides
##   nodes[].room_params.{num_patrols, patrol_speed, patrol_range,
##                        cover_ratio, light_level, resource_pickup,
##                        has_keycard, alarm_increment}
##   edges[].source / .target / .locked / .key_id / .one_way
##   meta.{target_curve, simulated_curve, critical_path, dtc_name, ...}
##
## [v1] stealth_pcg JSON Schema v1/v2 ("version" >= 1; v2 의 layout 블록은 사용하지 않음)
##   nodes{id: {type, threat_level, safe_zone, provides, size_hint, ...}}
##   edges{id: {source, target, locked, key_id, one_way, traversal_type,
##              visibility, patrol_density, cover_availability,
##              exposure_length, noise_level, ...}}
##   proximity{id: {node_a, node_b, wall_type, sound_leak, visual_leak}}
##   meta.{target_curve{name, points}, fitness{final, ...}}
##   simulation_results.shortest_path.tension_trace
##   critical_path, clear_conditions
##   room_params 는 방에 닿는 간선 속성을 모아 유도한다 (_derive_room_params)
extends Node2D

const TILE: int = 32
const ROOM_W: int = 15
const ROOM_H: int = 11
const GAP: int = 5
const CORRIDOR_W: int = 3

## v1: size_hint → 방 크기 (타일)
const ROOM_SIZES := {
	"small": Vector2i(11, 9),
	"medium": Vector2i(15, 11),
	"large": Vector2i(19, 13),
}

const NO_TILE := Vector2i(-99999, -99999)

## 방 템플릿 (class_name 대신 preload — 전역 클래스 캐시에 의존하지 않도록)
const RoomTemplates := preload("res://scripts/RoomTemplates.gd")

## 검증에 실패하면 격자 배치 방향을 바꿔 다시 시도하는 최대 횟수
const MAX_LAYOUT_ATTEMPTS: int = 16

## proximity 재질 → wall_type (export_for_godot.py 가 wall_type 을 넣지만, 없을 때 대비)
const MATERIAL_WALL_TYPE := {
	"concrete": "thick", "drywall": "thin", "glass": "glass",
	"metal": "metal", "mesh": "fence",
}

## ── 난이도 프리셋 ──
## 어떤 값으로 조절하든 아래 "불변 조건"은 항상 지켜진다:
##   · ENTRY / OBSERVATION 방에는 적을 두지 않는다 (안전 지대 보장)
##   · 모든 방에 최소 2개의 엄폐물을 둔다 (은신 수단 보장)
##   · 한 방의 적은 최대 4명 (물리적 회피 공간 확보)
##   · 적·엄폐물은 복도 타일과 복도 입구 주변에 스폰하지 않는다 (통로 막힘 방지)
##   · HP ≥ 1, 암살 기회 ≥ 1
const DIFFICULTY := [
	{
		"name": "EASY",
		"patrol_mul": 0.55, "speed_mul": 0.78, "fov_mul": 0.80,
		"cover_bonus": 2, "hp": 4, "kills": 5, "alert_mul": 0.6,
	},
	{
		"name": "NORMAL",
		"patrol_mul": 1.00, "speed_mul": 1.00, "fov_mul": 1.00,
		"cover_bonus": 0, "hp": 3, "kills": 3, "alert_mul": 1.0,
	},
	{
		"name": "HARD",
		"patrol_mul": 1.45, "speed_mul": 1.18, "fov_mul": 1.22,
		"cover_bonus": -1, "hp": 2, "kills": 2, "alert_mul": 1.4,
	},
	{
		"name": "BRUTAL",
		"patrol_mul": 1.85, "speed_mul": 1.32, "fov_mul": 1.40,
		"cover_bonus": -1, "hp": 1, "kills": 2, "alert_mul": 1.8,
	},
]

## 불변 조건 상수
const MIN_COVER_PER_ROOM: int = 2
const MAX_ENEMY_PER_ROOM: int = 4
const MOUTH_CLEARANCE: int = 2

var rooms: Array = []
var room_by_id: Dictionary = {}

var _rng := RandomNumberGenerator.new()
var _container: Node2D = null

## 걸어갈 수 있는 타일 집합 (벽 자동 생성의 기준)
var _floor_tiles: Dictionary = {}

## 방 id → 그 방이 차지하는 타일 집합
var _room_tile_sets: Dictionary = {}

## 간선별 복도 기록 [{edge, tiles, segs}]
var _corridor_records: Array = []

## 복도가 차지하는 모든 타일 (스폰 금지 구역 계산용)
var _corridor_tiles: Dictionary = {}

## 현재 난이도 인덱스
var difficulty: int = 1

## 설치된 문 계획 (통과 가능성 검증용)
var _door_plans: Array = []

## ── v1 전용 상태 ──
var _is_v1: bool = false

## 방 id → 격자 좌표 (proximity 판정용)
var _grid: Dictionary = {}

## clear_conditions 에서 읽은 목표 / 선택 목표 방 id 집합
var _objective_ids: Dictionary = {}
var _optional_ids: Dictionary = {}

## 복도 타일 → traversal_type (normal 이 아닌 것이 우선)
var _tile_style: Dictionary = {}

## 방 바닥에 속하지 않는 순수 복도 타일
var _pure_corridor: Dictionary = {}

## visibility == "hidden" 인 간선 묶음
## [{edge_id, a, b, tiles, cover, show:[], revealed}]
var _hidden_groups: Array = []

## v1 proximity 원본 / 벽 타일 → wall_type (소리 감쇠용 벽 재질)
var _proximity_data: Dictionary = {}

## 긴장도 계산용 그래프 색인 (_build_tension_index)
var _level_edges: Array = []
var _out_edges_by_room: Dictionary = {}
var _pair_edges: Dictionary = {}      ## "source>target" → 간선
var _prox_by_room: Dictionary = {}
var _tile_edges: Dictionary = {}      ## 순수 복도 타일 → [간선]
var _prox_wall_tiles: Dictionary = {}


func build(level_path: String, seed_value: int, diff: int = 1) -> bool:
	_rng.seed = seed_value
	difficulty = clampi(diff, 0, DIFFICULTY.size() - 1)

	if _container != null and is_instance_valid(_container):
		_container.queue_free()
	_container = Node2D.new()
	_container.name = "Ents"
	add_child(_container)

	rooms.clear()
	room_by_id.clear()
	_is_v1 = false
	_grid.clear()
	_objective_ids.clear()
	_optional_ids.clear()
	_tile_style.clear()
	_pure_corridor.clear()
	_hidden_groups.clear()
	_proximity_data = {}
	_prox_wall_tiles.clear()

	var data: Dictionary = _read_json(level_path)
	var used_fallback: bool = false
	if data.is_empty():
		data = _fallback_data()
		used_fallback = true

	_construct(data)
	return not used_fallback


## 레벨을 짓기 전에 meta 만 먼저 들여다본다
func peek_meta(path: String) -> Dictionary:
	var d: Dictionary = _read_json(path)
	var m = d.get("meta", {})
	if typeof(m) == TYPE_DICTIONARY:
		return m
	return {}


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		push_warning("[LevelLoader] 파일 없음: " + path + " → 내장 레벨 사용")
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var text: String = f.get_as_text()
	f.close()

	var parser := JSON.new()
	if parser.parse(text) != OK:
		push_error("[LevelLoader] JSON 파싱 실패: " + parser.get_error_message())
		return {}
	if typeof(parser.data) != TYPE_DICTIONARY:
		return {}
	return parser.data


func _construct(data: Dictionary) -> void:
	var version: int = int(data.get("version", 0))
	if version >= 1:
		_construct_v1(data)
	else:
		_construct_legacy(data)


## 구형식 (version 없음) — 기존 파싱 그대로
func _construct_legacy(data: Dictionary) -> void:
	_is_v1 = false
	var nodes: Array = data.get("nodes", [])
	var edges: Array = data.get("edges", [])
	if nodes.is_empty():
		push_error("[LevelLoader] nodes 비어 있음")
		return

	var meta: Dictionary = data.get("meta", {})
	GameState.meta = meta
	GameState.target_curve = meta.get("target_curve", [])
	GameState.target_points = _even_points(GameState.target_curve)
	GameState.tension.set_weights(meta.get("tension_weights", {}))
	GameState.simulated_curve = meta.get("simulated_curve", [])
	GameState.dtc_name = str(meta.get("dtc_name", "?"))
	var dist = meta.get("dtw_distance", null)
	GameState.dtw_fitness = float(dist) if dist != null else -1.0
	var cp = meta.get("critical_path", [])
	GameState.critical_path = cp if typeof(cp) == TYPE_ARRAY else []
	GameState.required_keys = []
	GameState.objective_nodes = []
	GameState.optional_objectives = []

	_build_level(nodes, edges)

	var total: int = 0
	for room in rooms:
		if room["type"] == "OBJECTIVE":
			total += 1
	GameState.objectives_total = total


## v1 형식 — 사전형 nodes/edges 를 배열로 풀고, room_params 를 간선에서 유도한 뒤
## 공통 빌드 경로(_build_level)로 넘긴다
func _construct_v1(data: Dictionary) -> void:
	_is_v1 = true

	var nodes_raw = data.get("nodes", {})
	var edges_raw = data.get("edges", {})
	if typeof(nodes_raw) != TYPE_DICTIONARY or nodes_raw.is_empty():
		push_error("[LevelLoader] v1: nodes 비어 있음")
		return
	if typeof(edges_raw) != TYPE_DICTIONARY:
		edges_raw = {}

	# ── 간선: 사전 → 배열 (id 부여) ──
	var edges: Array = []
	for eid in edges_raw.keys():
		var e = edges_raw[eid]
		if typeof(e) != TYPE_DICTIONARY:
			continue
		var ed: Dictionary = e.duplicate()
		ed["id"] = str(eid)
		edges.append(ed)

	# ── 노드: 사전 → 배열, 타입 대문자화, room_params 유도 ──
	var nodes: Array = []
	for nid in nodes_raw.keys():
		var n = nodes_raw[nid]
		if typeof(n) != TYPE_DICTIONARY:
			continue
		var id_s: String = str(nid)
		var ntype: String = str(n.get("type", "transit")).to_upper()
		var safe: bool = bool(n.get("safe_zone", false))
		var params: Dictionary = _derive_room_params(id_s, edges)
		if ntype == "ENTRY" or safe:
			params["num_patrols"] = 0
		nodes.append({
			"id": id_s,
			"type": ntype,
			"provides": n.get("provides", null),
			"room_params": params,
			"safe_zone": safe,
			"threat_level": str(n.get("threat_level", "medium")),
			"size_hint": str(n.get("size_hint", "medium")),
		})

	# ── meta ──
	var meta_raw = data.get("meta", {})
	var meta: Dictionary = meta_raw if typeof(meta_raw) == TYPE_DICTIONARY else {}
	GameState.meta = meta

	var curve_obj = meta.get("target_curve", {})
	var tc: Array = []
	var cname: String = "unknown"
	if typeof(curve_obj) == TYPE_DICTIONARY:
		cname = str(curve_obj.get("name", "unknown"))
		var pts = curve_obj.get("points", [])
		if typeof(pts) == TYPE_ARRAY:
			for p in pts:
				if typeof(p) == TYPE_DICTIONARY:
					tc.append(float(p.get("y", 0.0)))
	elif typeof(curve_obj) == TYPE_ARRAY:
		tc = curve_obj
	GameState.target_curve = tc
	# 긴장도 비교용 제어점 [[x, y], ...] (x 간격이 고르지 않으므로 y 만으로는 샘플링할 수 없다)
	var tp: Array = []
	if typeof(curve_obj) == TYPE_DICTIONARY and typeof(curve_obj.get("points", [])) == TYPE_ARRAY:
		for p2 in curve_obj.get("points", []):
			if typeof(p2) == TYPE_DICTIONARY:
				tp.append([float(p2.get("x", 0.0)), float(p2.get("y", 0.0))])
	GameState.target_points = tp if not tp.is_empty() else _even_points(tc)
	GameState.tension.set_weights(meta.get("tension_weights", {}))
	GameState.dtc_name = cname

	var fit = meta.get("fitness", {})
	GameState.dtw_fitness = -1.0
	if typeof(fit) == TYPE_DICTIONARY and fit.get("final", null) != null:
		GameState.dtw_fitness = float(fit["final"])

	var sim_curve: Array = []
	var sim = data.get("simulation_results", {})
	if typeof(sim) == TYPE_DICTIONARY:
		var sp = sim.get("shortest_path", {})
		if typeof(sp) == TYPE_DICTIONARY:
			var trace = sp.get("tension_trace", [])
			if typeof(trace) == TYPE_ARRAY:
				sim_curve = trace
	GameState.simulated_curve = sim_curve
	GameState.critical_path = _str_array(data.get("critical_path", []))

	# ── clear_conditions ──
	var cc = data.get("clear_conditions", {})
	if typeof(cc) != TYPE_DICTIONARY:
		cc = {}
	GameState.objective_nodes = _str_array(cc.get("objective_nodes", []))
	GameState.optional_objectives = _str_array(cc.get("optional_objectives", []))
	for oid in GameState.objective_nodes:
		if nodes_raw.has(oid):
			_objective_ids[oid] = true
	for oid2 in GameState.optional_objectives:
		if nodes_raw.has(oid2):
			_optional_ids[oid2] = true
	# clear_conditions 가 비어 있으면 타입으로 추론 (구형식과 동일)
	if _objective_ids.is_empty():
		for nd in nodes:
			if nd["type"] == "OBJECTIVE":
				_objective_ids[nd["id"]] = true

	# 필수 키는 실제로 어떤 방이 제공하는 것만 인정 (없으면 클리어 불가가 되므로)
	var provided: Dictionary = {}
	for nd2 in nodes:
		if nd2["provides"] != null:
			provided[str(nd2["provides"])] = true
	var req: Array = []
	for k in _str_array(cc.get("required_keys", [])):
		if provided.has(k):
			req.append(k)
		else:
			push_warning("[LevelLoader] v1: required_key %s 를 제공하는 방이 없음 → 무시" % k)
	GameState.required_keys = req

	var prox = data.get("proximity", {})
	_proximity_data = prox if typeof(prox) == TYPE_DICTIONARY else {}
	_build_level(nodes, edges)

	GameState.objectives_total = _objective_ids.size()
	print("[LevelLoader] v1 레벨: 방 %d, 간선 %d, 목표 %d, 필수 키 %s, 숨은 통로 %d" % [
		rooms.size(), edges.size(), _objective_ids.size(), str(req), _hidden_groups.size()])


## v1: 방에 닿는 모든 간선의 속성을 모아 구형식 room_params 를 만든다.
## (같은 방이라도 들어오는 방향에 따라 위험도가 다르므로 가장 위험한 값을 쓴다)
func _derive_room_params(node_id: String, edges: Array) -> Dictionary:
	var max_patrol: float = 0.0
	var min_cover: float = 1.0
	var max_exposure: int = 1

	for e in edges:
		if str(e.get("source", "")) != node_id and str(e.get("target", "")) != node_id:
			continue
		max_patrol = maxf(max_patrol, float(e.get("patrol_density", 0.0)))
		min_cover = minf(min_cover, float(e.get("cover_availability", 1.0)))
		max_exposure = maxi(max_exposure, int(e.get("exposure_length", 1)))

	return {
		"num_patrols": int(round(max_patrol * 4.0)),    # 0.0→0, 0.5→2, 1.0→4
		"patrol_speed": max_patrol,
		"patrol_range": max_patrol * 0.85,
		"cover_ratio": min_cover,
		"light_level": 1.0 - max_patrol * 0.55,         # 순찰이 많을수록 어둡게
		"resource_pickup": 0.0,
		"has_keycard": false,
		"alarm_increment": max_patrol * 0.15,
		"exposure_length": max_exposure,
	}


func _str_array(v) -> Array:
	var out: Array = []
	if typeof(v) != TYPE_ARRAY:
		return out
	for x in v:
		if x != null:
			out.append(str(x))
	return out


## 방 크기 — 구형식은 고정, v1 은 size_hint
func _room_size(n: Dictionary) -> Vector2i:
	if not _is_v1:
		return Vector2i(ROOM_W, ROOM_H)
	var hint: String = str(n.get("size_hint", "medium"))
	return ROOM_SIZES.get(hint, ROOM_SIZES["medium"])


## 두 형식이 공유하는 빌드 경로
## 1) 배치 계획(순수 데이터) → verify_solvable 로 검사, 실패하면 격자 배치를 바꿔 재시도
## 2) 통과한 계획을 실제 노드로 렌더링
func _build_level(nodes: Array, edges: Array) -> void:
	_level_edges = edges
	var door_plans: Array = []
	for attempt in range(MAX_LAYOUT_ATTEMPTS):
		door_plans = _plan_layout(nodes, edges, attempt)
		var check: Dictionary = verify_solvable(door_plans)
		if bool(check.get("ok", false)):
			if attempt > 0:
				print("[LevelLoader] 배치 %d회 재시도 후 클리어 가능한 배치 확보" % attempt)
			break
		if attempt == MAX_LAYOUT_ATTEMPTS - 1:
			push_warning("[LevelLoader] %d회 배치 모두 검증 실패 — 마지막 배치를 사용: %s" % [
				MAX_LAYOUT_ATTEMPTS, str(check.get("problems", []))])

	# 방 바닥에 속하지 않는 복도 타일 (봉쇄 후 기준)
	var room_all: Dictionary = {}
	for rid in _room_tile_sets.keys():
		for t in _room_tile_sets[rid].keys():
			room_all[t] = true
	for t in _corridor_tiles.keys():
		if _floor_tiles.has(t) and not room_all.has(t):
			_pure_corridor[t] = true

	if _is_v1:
		_collect_hidden_groups()

	# ── 4단계: 바닥 렌더링 ──
	for room in rooms:
		_paint_room_floor(room)
	_paint_corridor_field()
	if _is_v1:
		_paint_corridor_decor()

	# ── 5단계: proximity 벽 재질 + 벽 자동 생성 + 문 설치 ──
	_prox_wall_tiles.clear()
	if _is_v1:
		_build_proximity(_proximity_data)
	_build_walls()
	for plan in door_plans:
		var door: Node2D = _spawn_door(plan)
		if door != null and _is_v1:
			var g = _hidden_group_for(plan.get("edge", {}))
			if g != null:
				_hide_node(door)
				g["show"].append(door)
	_door_plans = door_plans

	# ── 6단계: 방 내용물 ──
	for room in rooms:
		_fill_room(room)

	_build_tension_index()


## 배치 계획: 방·복도·템플릿 내부벽·잠금 봉쇄까지 타일 데이터만 만든다 (노드 생성 없음)
func _plan_layout(nodes: Array, edges: Array, attempt: int) -> Array:
	rooms.clear()
	room_by_id.clear()
	_tile_style.clear()
	_pure_corridor.clear()
	_hidden_groups.clear()

	var grid: Dictionary = _assign_grid(nodes, edges, attempt)
	_grid = grid

	# 격자 한 칸 크기 = 가장 큰 방 크기. 작은 방은 칸 안에서 가운데 정렬한다.
	# (구형식은 모든 방이 ROOM_W×ROOM_H 이므로 기존 배치와 동일)
	var cell := Vector2i(ROOM_W, ROOM_H)
	for n0 in nodes:
		var s0: Vector2i = _room_size(n0)
		cell.x = maxi(cell.x, s0.x)
		cell.y = maxi(cell.y, s0.y)

	# ── 1단계: 방 정보 수집 + 바닥 타일 등록 ──
	_floor_tiles.clear()
	_room_tile_sets.clear()
	_corridor_tiles.clear()
	_door_plans.clear()

	for n in nodes:
		var nid: String = str(n.get("id", ""))
		var ntype: String = str(n.get("type", "TRANSIT"))
		var gpos: Vector2i = grid.get(nid, Vector2i.ZERO)
		var size: Vector2i = _room_size(n)

		var tx: int = 3 + gpos.x * (cell.x + GAP) + int((cell.x - size.x) / 2.0)
		var ty: int = 3 + gpos.y * (cell.y + GAP) + int((cell.y - size.y) / 2.0)
		var center := Vector2(
			(float(tx) + size.x * 0.5) * TILE,
			(float(ty) + size.y * 0.5) * TILE
		)

		var params: Dictionary = n.get("room_params", {})
		if typeof(params) != TYPE_DICTIONARY:
			params = {}

		var provides_raw = n.get("provides", null)
		var provides: String = ""
		if provides_raw != null:
			provides = str(provides_raw)

		var room := {
			"id": nid,
			"type": ntype,
			"provides": provides,
			"params": params,
			"tx": tx,
			"ty": ty,
			"w": size.x,
			"h": size.y,
			"ctx": tx + int(size.x / 2.0),
			"cty": ty + int(size.y / 2.0),
			"center": center,
			"safe_zone": bool(n.get("safe_zone", false)),
			"threat_level": str(n.get("threat_level", "")),
			"template": {},
		}
		rooms.append(room)
		room_by_id[nid] = room

		# 방 바닥 타일 등록
		var rset: Dictionary = {}
		for y in range(ty, ty + size.y):
			for x in range(tx, tx + size.x):
				var t := Vector2i(x, y)
				_floor_tiles[t] = true
				rset[t] = true
		_room_tile_sets[nid] = rset

	# ── 2단계: 복도 타일 등록 ──
	_corridor_records.clear()
	for e in edges:
		var sid: String = str(e.get("source", ""))
		var tid: String = str(e.get("target", ""))
		var r1 = room_by_id.get(sid, null)
		var r2 = room_by_id.get(tid, null)
		if r1 == null or r2 == null:
			continue
		var rec := _register_corridor(r1, r2, _corridor_width(e))
		rec["edge"] = e
		_corridor_records.append(rec)
		if _is_v1:
			var style: String = str(e.get("traversal_type", "normal"))
			for t in rec["tiles"].keys():
				if style != "normal" or not _tile_style.has(t):
					_tile_style[t] = style

	# ── 2.5단계: 방 템플릿 내부벽 (복도 타일은 건드리지 않는다) ──
	for room in rooms:
		_apply_room_template(room)

	# ── 3단계: 잠금 구역 봉쇄 + 문 위치 결정 ──
	return _plan_locks(nodes, edges)


## 방 타입에 맞는 템플릿을 골라 내부벽 타일을 바닥에서 뺀다.
## 템플릿 좌표는 15×11 기준이며, 크기가 다른 방(v1 size_hint)에는 비율로 맞춘다.
## 복도 타일 위에는 벽을 두지 않는다 (통로 차단 방지).
func _apply_room_template(room: Dictionary) -> void:
	var trng := RandomNumberGenerator.new()
	trng.seed = _rng.seed ^ hash(room["id"])
	var tmpl: Dictionary = RoomTemplates.get_template(room["type"], trng)
	room["template"] = tmpl
	if tmpl.is_empty():
		return
	var sx: float = float(room["w"]) / float(RoomTemplates.BASE_W)
	var sy: float = float(room["h"]) / float(RoomTemplates.BASE_H)
	var rset: Dictionary = _room_tile_sets.get(room["id"], {})
	for wr in tmpl.get("walls", []):
		var r: Rect2 = wr
		var x0: int = int(round(r.position.x * sx))
		var y0: int = int(round(r.position.y * sy))
		var x1: int = maxi(x0 + 1, int(round(r.end.x * sx)))
		var y1: int = maxi(y0 + 1, int(round(r.end.y * sy)))
		for y in range(y0, y1):
			for x in range(x0, x1):
				var t := Vector2i(room["tx"] + x, room["ty"] + y)
				if not rset.has(t) or _corridor_tiles.has(t):
					continue
				_floor_tiles.erase(t)


## 간선별 복도 폭 (타일).
## 구형식: 항상 CORRIDOR_W.
## v1: vent / stealth_required 는 좁게(2), exposure_length 가 길수록 넓게 (노출 구간 표현).
##     exposure 1–2 → 3, 3–4 → 4, 5 → 5
func _corridor_width(e: Dictionary) -> int:
	if not _is_v1:
		return CORRIDOR_W
	var style: String = str(e.get("traversal_type", "normal"))
	if style == "vent" or style == "stealth_required":
		return 2
	var exposure: int = clampi(int(e.get("exposure_length", 1)), 1, 5)
	# TODO(v2): exposure_length 를 복도의 실제 길이/굴곡 수로 표현
	return CORRIDOR_W + clampi(int((exposure - 1) / 2.0), 0, 2)


## 두 방을 잇는 L자 복도의 타일을 등록하고, 렌더링용 구간 목록을 돌려준다
## width 가 짝수면 중심선 기준 +쪽으로 한 칸 더 넓힌다
func _register_corridor(r1: Dictionary, r2: Dictionary, width: int = CORRIDOR_W) -> Dictionary:
	var c1 := Vector2i(r1["ctx"], r1["cty"])
	var c2 := Vector2i(r2["ctx"], r2["cty"])
	var mid_x: int = int((c1.x + c2.x) / 2.0)
	var lo: int = -int((width - 1) / 2.0)
	var hi: int = lo + width - 1

	var segs: Array = []
	var tiles: Dictionary = {}

	var ax1: int = mini(c1.x, mid_x)
	var ax2: int = maxi(c1.x, mid_x)
	for x in range(ax1, ax2 + 1):
		for dy in range(lo, hi + 1):
			var t1 := Vector2i(x, c1.y + dy)
			_floor_tiles[t1] = true
			tiles[t1] = true
	segs.append({"x": ax1, "y": c1.y + lo, "w": ax2 - ax1 + 1, "h": width})

	var ay1: int = mini(c1.y, c2.y)
	var ay2: int = maxi(c1.y, c2.y)
	for y in range(ay1, ay2 + 1):
		for dx in range(lo, hi + 1):
			var t2 := Vector2i(mid_x + dx, y)
			_floor_tiles[t2] = true
			tiles[t2] = true
	segs.append({"x": mid_x + lo, "y": ay1, "w": width, "h": ay2 - ay1 + 1})

	var bx1: int = mini(c2.x, mid_x)
	var bx2: int = maxi(c2.x, mid_x)
	for x in range(bx1, bx2 + 1):
		for dy in range(lo, hi + 1):
			var t3 := Vector2i(x, c2.y + dy)
			_floor_tiles[t3] = true
			tiles[t3] = true
	segs.append({"x": bx1, "y": c2.y + lo, "w": bx2 - bx1 + 1, "h": width})

	for t in tiles.keys():
		_corridor_tiles[t] = true

	return {"segs": segs, "tiles": tiles}


## 잠금 간선마다 "보호 구역"을 계산하고, 그 구역으로 들어가는 모든 입구를
## 정식 입구(문 설치) 와 비정식 입구(벽으로 봉쇄) 로 나눈다.
## 복도끼리 교차해서 생기는 우회로를 이 단계에서 제거한다.
func _plan_locks(nodes: Array, edges: Array) -> Array:
	var plans: Array = []

	var entry_id: String = ""
	for n in nodes:
		if str(n.get("type", "")) == "ENTRY":
			entry_id = str(n.get("id", ""))
			break
	if entry_id.is_empty():
		return plans

	# 잠금 간선을 전부 뺀 인접 리스트
	var open_adj: Dictionary = {}
	for n in nodes:
		open_adj[str(n.get("id", ""))] = []
	for e in edges:
		if bool(e.get("locked", false)):
			continue
		var a: String = str(e.get("source", ""))
		var b: String = str(e.get("target", ""))
		if open_adj.has(a):
			open_adj[a].append(b)
		if open_adj.has(b):
			open_adj[b].append(a)

	var entry_comp: Dictionary = _component(open_adj, entry_id)

	for e in edges:
		if not bool(e.get("locked", false)):
			continue
		var src: String = str(e.get("source", ""))
		var dst: String = str(e.get("target", ""))

		# ENTRY 쪽에 없는 끝점이 보호 대상
		var root: String = ""
		if not entry_comp.has(dst):
			root = dst
		elif not entry_comp.has(src):
			root = src
		if root.is_empty():
			continue  # 게이트 역할을 하지 않는 잠금 간선

		var prot_rooms: Dictionary = _component(open_adj, root)

		# 보호 타일 = 그 구역의 방 + 양끝이 구역 안인 복도
		var prot: Dictionary = {}
		for rid in prot_rooms.keys():
			var rset = _room_tile_sets.get(rid, null)
			if rset != null:
				for t in rset.keys():
					prot[t] = true
		for rec in _corridor_records:
			var re2: Dictionary = rec["edge"]
			if prot_rooms.has(str(re2.get("source", ""))) and prot_rooms.has(str(re2.get("target", ""))):
				for t in rec["tiles"].keys():
					prot[t] = true

		# 입구 = 보호 밖이면서 보호 타일에 4-인접한 바닥
		var entrances: Dictionary = {}
		for t in prot.keys():
			for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var nb: Vector2i = t + d
				if _floor_tiles.has(nb) and not prot.has(nb):
					entrances[nb] = true

		# 잠금 간선의 복도 타일
		var locked_tiles: Dictionary = {}
		for rec2 in _corridor_records:
			if rec2["edge"] == e:
				locked_tiles = rec2["tiles"]
				break

		# 이 구역에서 다른 잠금 구역으로 이어지는 잠금 복도 (다단 잠금).
		# 그 입구는 해당 간선을 처리할 때 문이 생기므로 여기서 봉쇄하면 안 된다.
		var onward_tiles: Dictionary = {}
		for rec3 in _corridor_records:
			var oe: Dictionary = rec3["edge"]
			if oe == e or not bool(oe.get("locked", false)):
				continue
			if prot_rooms.has(str(oe.get("source", ""))) != prot_rooms.has(str(oe.get("target", ""))):
				for t4 in rec3["tiles"].keys():
					onward_tiles[t4] = true

		# 입구를 연결 성분으로 묶는다
		var remaining: Dictionary = entrances.duplicate()
		while not remaining.is_empty():
			var seed_t: Vector2i = remaining.keys()[0]
			remaining.erase(seed_t)
			var cluster: Array = [seed_t]
			var queue: Array = [seed_t]
			while not queue.is_empty():
				var cur: Vector2i = queue.pop_front()
				for d2 in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
					var nb2: Vector2i = cur + d2
					if remaining.has(nb2):
						remaining.erase(nb2)
						cluster.append(nb2)
						queue.append(nb2)

			# 잠금 복도와 겹치면 정식 입구 → 문, 다른 잠금 복도면 그대로 둠, 아니면 봉쇄
			var legit: bool = false
			var onward: bool = false
			for t2 in cluster:
				if locked_tiles.has(t2):
					legit = true
					break
				if onward_tiles.has(t2):
					onward = true

			if legit:
				var kid_raw = e.get("key_id", null)
				var kid: String = "K1"
				if kid_raw != null:
					kid = str(kid_raw)
				plans.append({"tiles": cluster, "key_id": kid, "edge": e})
			elif onward:
				pass
			else:
				for t3 in cluster:
					_floor_tiles.erase(t3)

	return plans


func _component(adjacency: Dictionary, root: String) -> Dictionary:
	var comp: Dictionary = {root: true}
	var queue: Array = [root]
	while not queue.is_empty():
		var cur: String = queue.pop_front()
		for nb in adjacency.get(cur, []):
			if not comp.has(nb):
				comp[nb] = true
				queue.append(nb)
	return comp


## 입구 타일 묶음의 모양을 보고 문의 방향과 위치를 정한다
func _spawn_door(plan: Dictionary) -> Node2D:
	var tiles: Array = plan["tiles"]
	if tiles.is_empty():
		return null

	var min_x: int = 99999
	var max_x: int = -99999
	var min_y: int = 99999
	var max_y: int = -99999
	for t in tiles:
		min_x = mini(min_x, t.x)
		max_x = maxi(max_x, t.x)
		min_y = mini(min_y, t.y)
		max_y = maxi(max_y, t.y)

	var tw: int = max_x - min_x + 1
	var th: int = max_y - min_y + 1

	# 입구가 세로로 길면 복도는 가로 방향 → 세로 막대 문
	var horizontal_block: bool = tw > th
	var span: float = float(maxi(tw, th)) * TILE

	var cx: float = (float(min_x) + tw * 0.5) * TILE
	var cy: float = (float(min_y) + th * 0.5) * TILE

	var door := Entities.make_door(str(plan["key_id"]), horizontal_block, span)
	door.position = Vector2(cx, cy)
	_container.add_child(door)
	return door


## 바닥에 인접한 빈 타일을 찾아 벽으로 만든다.
## 가로로 이어진 벽 타일은 하나의 큰 콜리전으로 합쳐 노드 수를 줄인다.
func _build_walls() -> void:
	# 바닥에 8방향 인접한 빈 타일 수집
	var wall_tiles: Dictionary = {}
	for tile in _floor_tiles.keys():
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				if dx == 0 and dy == 0:
					continue
				var nb := Vector2i(tile.x + dx, tile.y + dy)
				if not _floor_tiles.has(nb):
					wall_tiles[nb] = true

	if wall_tiles.is_empty():
		return

	# 행 단위로 묶기 (재질이 바뀌는 곳에서 구간을 끊는다)
	var rows: Dictionary = {}
	for t in wall_tiles.keys():
		if not rows.has(t.y):
			rows[t.y] = []
		rows[t.y].append(t.x)

	var made: int = 0
	for y in rows.keys():
		var xs: Array = rows[y]
		xs.sort()
		var run_start: int = xs[0]
		var prev: int = xs[0]
		var run_type: String = str(_prox_wall_tiles.get(Vector2i(xs[0], y), "thick"))
		for i in range(1, xs.size()):
			var cur: int = xs[i]
			var cur_type: String = str(_prox_wall_tiles.get(Vector2i(cur, y), "thick"))
			if cur == prev + 1 and cur_type == run_type:
				prev = cur
				continue
			_spawn_wall_run(run_start, y, prev - run_start + 1, run_type)
			made += 1
			run_start = cur
			prev = cur
			run_type = cur_type
		_spawn_wall_run(run_start, y, prev - run_start + 1, run_type)
		made += 1

	print("[LevelLoader] 바닥 %d타일, 벽 %d구간 생성" % [_floor_tiles.size(), made])


func _spawn_wall_run(tx: int, ty: int, length: int, wall_type: String = "thick") -> void:
	var w: float = length * TILE
	var h: float = float(TILE)
	var wall := Entities.make_wall(tx * TILE, ty * TILE, w, h)
	wall.set("wall_type", wall_type)
	_container.add_child(wall)


# ═══════════════════════════════════════
#  그래프 → 격자 배치 (BFS)
# ═══════════════════════════════════════

func _assign_grid(nodes: Array, edges: Array, attempt: int = 0) -> Dictionary:
	var adjacency: Dictionary = {}
	for n in nodes:
		adjacency[str(n.get("id", ""))] = []

	for e in edges:
		var s: String = str(e.get("source", ""))
		var t: String = str(e.get("target", ""))
		if adjacency.has(s):
			adjacency[s].append(t)
		if adjacency.has(t) and not bool(e.get("one_way", false)):
			adjacency[t].append(s)

	var start_id: String = str(nodes[0].get("id", ""))
	for n in nodes:
		if str(n.get("type", "")) == "ENTRY":
			start_id = str(n.get("id", ""))
			break

	var placed: Dictionary = {}
	var taken: Dictionary = {}
	placed[start_id] = Vector2i.ZERO
	taken["0,0"] = true

	var directions: Array = [
		Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(0, -1),
		Vector2i(1, 1), Vector2i(-1, 1), Vector2i(1, -1), Vector2i(-1, -1),
	]
	# 재시도 때는 방향 순서를 결정적으로 섞어 다른 배치를 만든다 (attempt 0 = 기존 배치)
	if attempt > 0:
		var drng := RandomNumberGenerator.new()
		drng.seed = attempt * 7919
		for i in range(directions.size() - 1, 0, -1):
			var j: int = drng.randi_range(0, i)
			var tmp = directions[i]
			directions[i] = directions[j]
			directions[j] = tmp

	var queue: Array = [start_id]
	var seen: Dictionary = {start_id: true}
	var rotate: int = 0

	while queue.size() > 0:
		var current: String = queue.pop_front()
		var cpos: Vector2i = placed[current]

		for nid in adjacency.get(current, []):
			if seen.has(nid):
				continue
			var spot: Vector2i = cpos
			var found: bool = false
			for offset in range(directions.size()):
				var d: Vector2i = directions[(rotate + offset) % directions.size()]
				var candidate: Vector2i = cpos + d
				var key: String = "%d,%d" % [candidate.x, candidate.y]
				if not taken.has(key):
					spot = candidate
					taken[key] = true
					found = true
					rotate = (rotate + 1) % directions.size()
					break
			if not found:
				# 2칸 반경까지 확장 탐색
				for radius in range(2, 5):
					for dy in range(-radius, radius + 1):
						for dx in range(-radius, radius + 1):
							var candidate2: Vector2i = cpos + Vector2i(dx, dy)
							var key2: String = "%d,%d" % [candidate2.x, candidate2.y]
							if not taken.has(key2):
								spot = candidate2
								taken[key2] = true
								found = true
								break
						if found:
							break
					if found:
						break

			placed[nid] = spot
			seen[nid] = true
			queue.append(nid)

	# 좌상단을 (0,0) 으로 정규화
	var min_x: int = 99999
	var min_y: int = 99999
	for p in placed.values():
		min_x = mini(min_x, p.x)
		min_y = mini(min_y, p.y)

	var result: Dictionary = {}
	for id in placed:
		result[id] = placed[id] - Vector2i(min_x, min_y)
	return result


# ═══════════════════════════════════════
#  렌더링
# ═══════════════════════════════════════

## 방 타입별 기본 색상 (light_level 로 명암 조절)
## 방 바닥은 거의 중성 회색. 타입 구분은 accent(테두리 띠) 로만 드러낸다.
func _room_color(room_type: String, light: float) -> Color:
	var base := Color(0.475, 0.480, 0.492)
	# 타입별로 아주 살짝만 색온도를 틀어 준다 (±2% 이내)
	match room_type:
		"ENTRY":
			base = Color(0.470, 0.487, 0.474)
		"EXIT":
			base = Color(0.489, 0.472, 0.474)
		"OBJECTIVE":
			base = Color(0.489, 0.482, 0.466)
		"KEY_ROOM":
			base = Color(0.487, 0.483, 0.466)
		"OBSERVATION":
			base = Color(0.466, 0.479, 0.494)
		"CHOKE":
			base = Color(0.494, 0.470, 0.472)
		"HIGH_SECURITY":
			base = Color(0.498, 0.466, 0.468)
		"ALT_PATH":
			base = Color(0.478, 0.470, 0.492)
		"SIDE_OBJECTIVE":
			base = Color(0.471, 0.486, 0.475)
		_:
			base = Color(0.475, 0.480, 0.492)
	# 밝기 변화 폭도 좁게 (바닥이 얼룩져 보이지 않도록)
	var factor: float = 0.90 + light * 0.18
	return Color(base.r * factor, base.g * factor, base.b * factor, 1.0)


## 방 타입을 알려 주는 테두리 띠 색 (여기만 선명하게)
func _room_accent(room_type: String) -> Color:
	match room_type:
		"ENTRY":
			return Color(0.32, 0.78, 0.45)
		"EXIT":
			return Color(0.30, 0.82, 0.72)
		"OBJECTIVE":
			return Color(0.95, 0.72, 0.22)
		"KEY_ROOM":
			return Color(0.95, 0.82, 0.25)
		"OBSERVATION":
			return Color(0.34, 0.68, 0.92)
		"CHOKE":
			return Color(0.92, 0.28, 0.25)
		"HIGH_SECURITY":
			return Color(0.95, 0.18, 0.18)
		"ALT_PATH":
			return Color(0.62, 0.42, 0.92)
		"SIDE_OBJECTIVE":
			return Color(0.55, 0.85, 0.40)
		_:
			return Color(0.62, 0.64, 0.68)


## 방 바닥 렌더링 + 조명 (벽은 _build_walls 가 따로 처리)
func _paint_room_floor(room: Dictionary) -> void:
	var params: Dictionary = room["params"]
	var room_type: String = room["type"]
	var light: float = float(params.get("light_level", 0.5))

	var px: float = room["tx"] * TILE
	var py: float = room["ty"] * TILE
	var w: float = float(room["w"]) * TILE
	var h: float = float(room["h"]) * TILE

	var floor_node := Node2D.new()
	floor_node.position = Vector2(px, py)
	floor_node.z_index = -20
	floor_node.set_script(load("res://scripts/RoomFloor.gd"))
	floor_node.set("box", Vector2(w, h))
	floor_node.set("base_color", _room_color(room_type, light))
	floor_node.set("accent_color", _room_accent(room_type))
	floor_node.set("room_type", room_type)
	floor_node.set("tile_size", float(TILE))
	_container.add_child(floor_node)

	# 방 조명 — 밝기는 light_level, 색온도는 방 타입
	var energy: float = 0.22 + light * 0.30
	var tint := Color(1.0, 0.975, 0.94)
	if room_type == "OBSERVATION":
		tint = Color(0.88, 0.95, 1.0)
	elif room_type == "CHOKE" or room_type == "HIGH_SECURITY":
		tint = Color(1.0, 0.90, 0.87)
	elif room_type == "EXIT":
		tint = Color(0.92, 1.0, 0.97)
	elif room_type == "ENTRY":
		tint = Color(0.94, 1.0, 0.95)

	# v1: threat_level 로 조명 세기·색온도 보정
	match str(room.get("threat_level", "")):
		"low":
			energy *= 1.2
			tint = tint.lerp(Color(1.0, 0.94, 0.84), 0.5)
		"medium":
			pass
		"high":
			energy *= 0.7
			tint = tint.lerp(Color(1.0, 0.78, 0.76), 0.7)
		"variable":
			energy *= 0.9

	# v1: 안전 구역 — 바닥에 청록색 링
	if bool(room.get("safe_zone", false)):
		var ring := VisualKit.make_safe_zone_glow(minf(w, h) * 0.36)
		ring.position = Vector2(px + w * 0.5, py + h * 0.5)
		_container.add_child(ring)

	# 방 중앙 주광 (그림자 O)
	var lamp := VisualKit.make_room_light(w * 0.95, energy, tint)
	lamp.position = Vector2(px + w * 0.5, py + h * 0.5)
	_container.add_child(lamp)

	# 대각 보조광 2개 (그림자 X) — 바닥이 고르게 깔리도록
	var corner_e: float = energy * 0.40
	var offs := [Vector2(0.25, 0.27), Vector2(0.75, 0.73)]
	for o in offs:
		var l2 := VisualKit.make_room_light(w * 0.62, corner_e, tint)
		l2.position = Vector2(px + w * o.x, py + h * o.y)
		l2.shadow_enabled = false
		_container.add_child(l2)


## 복도 전체를 하나의 노드에서 타일 단위로 그린다 (구간 겹침 아티팩트 제거)
func _paint_corridor_field() -> void:
	# 방 안에 들어간 복도 타일은 방 바닥이 이미 칠하므로 제외 (_build_level 에서 계산)
	var pure: Dictionary = _pure_corridor

	if pure.is_empty():
		return

	var node := Node2D.new()
	node.z_index = -21
	node.set_script(load("res://scripts/CorridorField.gd"))
	node.set("tiles", pure)
	node.set("tile_size", float(TILE))
	_container.add_child(node)

	# 복도 조명 — 타일 묶음의 무게중심마다 하나씩, 간격을 두고
	var lit: Dictionary = {}
	for t in pure.keys():
		var cell := Vector2i(int(floor(t.x / 7.0)), int(floor(t.y / 7.0)))
		if lit.has(cell):
			continue
		lit[cell] = true
		var energy: float = 0.16
		if str(_tile_style.get(t, "normal")) == "stealth_required":
			energy *= 0.5
		var lamp := VisualKit.make_room_light(190.0, energy, Color(0.90, 0.92, 1.0))
		lamp.position = Vector2((float(t.x) + 0.5) * TILE, (float(t.y) + 0.5) * TILE)
		lamp.shadow_enabled = false
		_container.add_child(lamp)
		# 숨은 통로 위의 조명은 발견 전까지 꺼 둔다
		for g in _hidden_groups:
			if g["tiles"].has(t):
				lamp.visible = false
				g["show"].append(lamp)
				break


# ═══════════════════════════════════════
#  v1: 복도 종류 / 숨은 통로 / proximity
# ═══════════════════════════════════════

## traversal_type 별 복도 장식 + 숨은 통로 덮개
func _paint_corridor_decor() -> void:
	var styled: Dictionary = {}
	for t in _pure_corridor.keys():
		var st: String = str(_tile_style.get(t, "normal"))
		if st != "normal":
			styled[t] = st

	# hack: 복도 양 끝(방과 맞닿는 곳)에 단말기 아이콘
	var glyphs: Array = []
	for rec in _corridor_records:
		var e: Dictionary = rec["edge"]
		if str(e.get("traversal_type", "normal")) != "hack":
			continue
		for rid in [str(e.get("source", "")), str(e.get("target", ""))]:
			var room = room_by_id.get(rid, null)
			if room == null:
				continue
			var mouth: Vector2i = _corridor_mouth(rec["tiles"], room)
			if mouth != NO_TILE:
				glyphs.append({"tile": mouth, "kind": "hack"})

	if not styled.is_empty() or not glyphs.is_empty():
		var deco := Node2D.new()
		deco.z_index = -21
		deco.set_script(load("res://scripts/CorridorDecor.gd"))
		deco.set("mode", "style")
		deco.set("tiles", styled)
		deco.set("glyphs", glyphs)
		deco.set("tile_size", float(TILE))
		_container.add_child(deco)

	# 숨은 통로: 벽과 같은 색의 덮개를 씌워 두었다가 발견 시 걷어낸다
	for g in _hidden_groups:
		var cover := Node2D.new()
		cover.z_index = 4
		cover.set_script(load("res://scripts/CorridorDecor.gd"))
		cover.set("mode", "cover")
		cover.set("tiles", g["tiles"])
		cover.set("tile_size", float(TILE))
		_container.add_child(cover)
		g["cover"] = cover


## 복도 타일 중 해당 방 바닥에 4-인접한 순수 복도 타일 (방 중심에 가장 가까운 것)
func _corridor_mouth(ctiles: Dictionary, room: Dictionary) -> Vector2i:
	var rset: Dictionary = _room_tile_sets.get(room["id"], {})
	var c := Vector2i(room["ctx"], room["cty"])
	var best: Vector2i = NO_TILE
	var best_d: int = 1 << 30
	for t in ctiles.keys():
		if not _pure_corridor.has(t):
			continue
		for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			if rset.has(t + d):
				var dd: int = (t - c).length_squared()
				if dd < best_d:
					best_d = dd
					best = t
				break
	return best


## visibility == "hidden" 간선마다, 다른(보이는) 복도와 겹치지 않는 순수 복도 타일을 묶는다
## "conditional" 은 아직 조건 시스템이 없으므로 "obvious" 로 취급한다
## TODO(v2): conditional 가시성 (경보 해제·해킹 등 조건부 노출)
func _collect_hidden_groups() -> void:
	var visible_tiles: Dictionary = {}
	for rec in _corridor_records:
		if str(rec["edge"].get("visibility", "obvious")) != "hidden":
			for t in rec["tiles"].keys():
				visible_tiles[t] = true

	for rec2 in _corridor_records:
		var e: Dictionary = rec2["edge"]
		if str(e.get("visibility", "obvious")) != "hidden":
			continue
		var own: Dictionary = {}
		for t2 in rec2["tiles"].keys():
			if _pure_corridor.has(t2) and not visible_tiles.has(t2):
				own[t2] = true
		_hidden_groups.append({
			"edge_id": str(e.get("id", "")),
			"a": str(e.get("source", "")),
			"b": str(e.get("target", "")),
			"tiles": own,
			"cover": null,
			"show": [],
			"revealed": false,
		})


func _hidden_group_for(edge):
	if typeof(edge) != TYPE_DICTIONARY:
		return null
	var eid: String = str(edge.get("id", ""))
	for g in _hidden_groups:
		if g["edge_id"] == eid:
			return g
	return null


func _hide_node(n: Node) -> void:
	if n is CanvasItem:
		n.set("modulate", Color(1, 1, 1, 0))
	for c in n.get_children():
		if c is Light2D:
			c.visible = false


## 매 프레임 Main 이 호출. 플레이어가 숨은 통로의 양끝 방에 들어가거나
## 통로 타일 가까이 오면 0.5초에 걸쳐 드러낸다.
func update_reveal(world_pos: Vector2, room_id: String) -> void:
	if _hidden_groups.is_empty():
		return
	var pt := Vector2i(int(floor(world_pos.x / TILE)), int(floor(world_pos.y / TILE)))
	for g in _hidden_groups:
		if g["revealed"]:
			continue
		var hit: bool = room_id != "" and (room_id == g["a"] or room_id == g["b"])
		if not hit:
			var tiles: Dictionary = g["tiles"]
			for dy in range(-2, 3):
				for dx in range(-2, 3):
					if tiles.has(pt + Vector2i(dx, dy)):
						hit = true
						break
				if hit:
					break
		if hit:
			_reveal_group(g)


func _reveal_group(g: Dictionary) -> void:
	g["revealed"] = true
	var cover = g["cover"]
	if cover != null and is_instance_valid(cover):
		var tw := create_tween()
		tw.tween_property(cover, "modulate:a", 0.0, 0.5)
		tw.tween_callback(Callable(cover, "hide"))
	for n in g["show"]:
		if not is_instance_valid(n):
			continue
		if n is Light2D:
			n.visible = true
			continue
		for c in n.get_children():
			if c is Light2D:
				c.visible = true
		var tw2 := create_tween()
		tw2.tween_property(n, "modulate:a", 1.0, 0.5)


## proximity — 통과 불가능한 인접 벽. 최소 구현: 두 방이 격자상 이웃일 때
## 서로 마주 보는 벽면을 wall_type 에 맞는 외형으로 덧그리고, 그 벽 타일의
## wall_type 을 기록해 _build_walls 가 재질별 벽(Wall.wall_type)으로 만든다.
## (SoundSystem 이 wall_type 으로 소리 감쇠를 계산한다)
## TODO(v2): visual_leak 기반 시야 투과(차광체 제거)
func _build_proximity(prox) -> void:
	if typeof(prox) != TYPE_DICTIONARY or prox.is_empty():
		return
	var drawn: int = 0
	var skipped: int = 0
	for pid in prox.keys():
		var p = prox[pid]
		if typeof(p) != TYPE_DICTIONARY:
			continue
		var wall_type: String = str(p.get("wall_type", ""))
		if wall_type == "":
			wall_type = str(MATERIAL_WALL_TYPE.get(str(p.get("material", "")), "thick"))
		if wall_type == "thick":
			continue  # 기본 벽과 동일
		var ra = room_by_id.get(str(p.get("node_a", "")), null)
		var rb = room_by_id.get(str(p.get("node_b", "")), null)
		if ra == null or rb == null:
			continue
		var ga: Vector2i = _grid.get(ra["id"], Vector2i.ZERO)
		var gb: Vector2i = _grid.get(rb["id"], Vector2i.ZERO)
		if maxi(absi(ga.x - gb.x), absi(ga.y - gb.y)) > 1:
			skipped += 1  # 배치상 멀리 떨어짐 — 마주 보는 벽이 없다
			continue
		var leak: float = clampf(float(p.get("visual_leak", 0.5)), 0.0, 1.0)
		_mark_facing_wall(ra, rb, wall_type, leak)
		_mark_facing_wall(rb, ra, wall_type, leak)
		drawn += 1
	print("[LevelLoader] proximity 벽 %d개 표시, %d개는 배치상 인접하지 않아 생략" % [drawn, skipped])


func _mark_facing_wall(room: Dictionary, other: Dictionary, wall_type: String, leak: float) -> void:
	var d: Vector2 = other["center"] - room["center"]
	var tx: int = room["tx"]
	var ty: int = room["ty"]
	var w: int = room["w"]
	var h: int = room["h"]

	var vertical: bool = absf(d.x) >= absf(d.y)
	var line: Array = []
	if vertical:
		var x: int = tx + w if d.x > 0.0 else tx - 1
		for y in range(ty, ty + h):
			line.append(Vector2i(x, y))
	else:
		var y2: int = ty + h if d.y > 0.0 else ty - 1
		for x2 in range(tx, tx + w):
			line.append(Vector2i(x2, y2))

	# 연속된 벽 타일(바닥이 아닌 칸)만 묶어서 덧그린다
	var run: Array = []
	for i in range(line.size() + 1):
		if i < line.size() and not _floor_tiles.has(line[i]):
			run.append(line[i])
			continue
		if run.size() >= 2:
			var a: Vector2i = run[0]
			var b: Vector2i = run[run.size() - 1]
			var rect := Rect2(
				float(mini(a.x, b.x)) * TILE, float(mini(a.y, b.y)) * TILE,
				float(absi(b.x - a.x) + 1) * TILE, float(absi(b.y - a.y) + 1) * TILE)
			_container.add_child(Entities.make_wall_variant(wall_type, rect, vertical, leak))
			# 실제 벽 콜리전에도 재질을 기록 → SoundSystem 이 감쇠 계수로 사용
			for rt in run:
				_prox_wall_tiles[rt] = wall_type
		run = []


# ═══════════════════════════════════════
#  room_params 기반 배치
# ═══════════════════════════════════════

## 그 방에서 적·엄폐물을 놓아도 안전한 타일 목록
## 복도 타일과 복도 입구 주변을 제외해 통로가 막히는 일을 방지한다
func _safe_spawn_tiles(room: Dictionary) -> Array:
	var tx: int = room["tx"]
	var ty: int = room["ty"]

	# 이 방과 복도가 맞닿는 지점(입구) 찾기
	var mouths: Array = []
	var rset: Dictionary = _room_tile_sets.get(room["id"], {})
	for t in rset.keys():
		if _corridor_tiles.has(t):
			mouths.append(t)

	var result: Array = []
	for y in range(ty + 2, ty + int(room["h"]) - 2):
		for x in range(tx + 2, tx + int(room["w"]) - 2):
			var t2 := Vector2i(x, y)
			if not _floor_tiles.has(t2):
				continue
			if _corridor_tiles.has(t2):
				continue
			# 입구에서 충분히 떨어졌는지
			var too_close: bool = false
			for m in mouths:
				if absi(m.x - x) <= MOUTH_CLEARANCE and absi(m.y - y) <= MOUTH_CLEARANCE:
					too_close = true
					break
			if too_close:
				continue
			result.append(Vector2((float(x) + 0.5) * TILE, (float(y) + 0.5) * TILE))

	return result


## 후보 중에서 서로 최대한 멀리 떨어지도록 n개를 고른다 (farthest-point sampling).
## 무작위로 뽑으면 한쪽에 뭉치는 일이 잦아서, 방 전체에 고르게 퍼뜨린다.
func _pick_spread(pool: Array, n: int, seed_pos: Vector2, min_dist: float = 0.0) -> Array:
	var picked: Array = []
	if pool.is_empty() or n <= 0:
		return picked

	var min_d2: float = min_dist * min_dist
	var remaining: Array = pool.duplicate()

	# 첫 점은 seed_pos 에서 가장 먼 곳
	var first: int = 0
	var best: float = -1.0
	for i in range(remaining.size()):
		var d: float = seed_pos.distance_squared_to(remaining[i])
		if d > best:
			best = d
			first = i
	picked.append(remaining[first])
	remaining.remove_at(first)

	# 이후로는 "이미 고른 점들과의 최소 거리"가 최대인 점을 고른다.
	# 그 거리가 min_dist 에도 못 미치면 더 놓지 않는다 (개수보다 간격 우선).
	while picked.size() < n and not remaining.is_empty():
		var best_i: int = 0
		var best_d: float = -1.0
		for i in range(remaining.size()):
			var nearest: float = 1e20
			for pk in picked:
				nearest = minf(nearest, remaining[i].distance_squared_to(pk))
			if nearest > best_d:
				best_d = nearest
				best_i = i
		if best_d < min_d2:
			break
		picked.append(remaining[best_i])
		remaining.remove_at(best_i)

	return picked


## 주어진 중심 주변의 후보 타일만 추린다 (순찰 경로를 자기 구역 안에 묶기 위함)
func _near_spots(spots: Array, center: Vector2, radius: float) -> Array:
	var out: Array = []
	var r2: float = radius * radius
	for sp in spots:
		if sp.distance_squared_to(center) <= r2:
			out.append(sp)
	return out


func _fill_room(room: Dictionary) -> void:
	var params: Dictionary = room["params"]
	var room_type: String = room["type"]
	var center: Vector2 = room["center"]
	var diff: Dictionary = DIFFICULTY[difficulty]

	var spots: Array = _safe_spawn_tiles(room)
	if spots.is_empty():
		spots = [center]

	# ── 1) 엄폐물을 먼저 놓는다 ──
	# (나중에 놓으면 적의 순찰 경로 위에 얹혀 적이 상자에 끼어 멈춘다)
	var cover_ratio: float = float(params.get("cover_ratio", 0.5))
	var cover_count: int = int(round(cover_ratio * 4.0)) + int(diff["cover_bonus"])
	cover_count = maxi(cover_count, MIN_COVER_PER_ROOM)
	cover_count = mini(cover_count, maxi(spots.size() / 5, MIN_COVER_PER_ROOM))

	var cover_spots: Array = _pick_spread(spots, cover_count, center, TILE * 2.4)
	if cover_spots.size() < MIN_COVER_PER_ROOM:
		cover_spots = _pick_spread(spots, MIN_COVER_PER_ROOM, center, TILE * 1.2)

	# 템플릿 선호 위치가 있으면 그 자리를 먼저 쓰고, 모자란 만큼만 기존 방식으로 채운다
	var tmpl: Dictionary = room.get("template", {})
	var pref_cover: Array = _template_spots(room, tmpl.get("cover_zones", []), spots)
	if not pref_cover.is_empty():
		var merged: Array = pref_cover.slice(0, cover_count)
		var rest: Array = _spots_clear_of(spots, merged, TILE * 2.4)
		if merged.size() < cover_count and not rest.is_empty():
			merged.append_array(_pick_spread(rest, cover_count - merged.size(), center, TILE * 2.4))
		if merged.size() >= MIN_COVER_PER_ROOM:
			cover_spots = merged

	for cpos in cover_spots:
		var cv := Entities.make_cover()
		cv.position = cpos
		_container.add_child(cv)

	# ── 2) 엄폐물이 차지한 자리를 뺀 나머지가 적의 활동 공간 ──
	# 공간이 모자라면 제약을 단계적으로 완화한다. 다만 상자와 완전히 겹치는
	# 자리(TILE*1.0 미만)는 어떤 경우에도 쓰지 않는다 — 적이 상자에 낀다.
	var free: Array = _spots_clear_of(spots, cover_spots, TILE * 1.6)
	if free.size() < 4:
		free = _spots_clear_of(spots, cover_spots, TILE * 1.25)
	if free.size() < 3:
		free = _spots_clear_of(spots, cover_spots, TILE * 1.0)
	if free.is_empty():
		free = [center]

	# ── 3) 적 배치 ──
	var patrol_count: int = int(params.get("num_patrols", 0))
	patrol_count = int(round(float(patrol_count) * float(diff["patrol_mul"])))
	if _is_v1:
		# v1: ENTRY 와 safe_zone 방은 적 없음 (OBSERVATION 도 safe_zone 속성을 따른다)
		if room_type == "ENTRY" or bool(room.get("safe_zone", false)):
			patrol_count = 0
	elif room_type == "ENTRY" or room_type == "OBSERVATION":
		patrol_count = 0
	patrol_count = clampi(patrol_count, 0, MAX_ENEMY_PER_ROOM)
	patrol_count = mini(patrol_count, maxi(free.size() / 4, 0))

	var enemy_spots: Array = _pick_spread(free, patrol_count, center, TILE * 2.4)
	var pref_enemy: Array = _template_spots(room, tmpl.get("enemy_zones", []), free)
	if not pref_enemy.is_empty() and patrol_count > 0:
		var e_merged: Array = pref_enemy.slice(0, patrol_count)
		var e_rest: Array = _spots_clear_of(free, e_merged, TILE * 2.4)
		if e_merged.size() < patrol_count and not e_rest.is_empty():
			e_merged.append_array(_pick_spread(e_rest, patrol_count - e_merged.size(), center, TILE * 2.4))
		enemy_spots = e_merged

	var scaled: Dictionary = params.duplicate()
	scaled["patrol_speed"] = clampf(
		float(params.get("patrol_speed", 0.5)) * float(diff["speed_mul"]), 0.0, 1.0)
	scaled["patrol_range"] = clampf(
		float(params.get("patrol_range", 0.5)) * float(diff["fov_mul"]), 0.0, 1.0)

	for pos in enemy_spots:
		var e := Entities.make_enemy(scaled)
		e.position = pos
		e.waypoints = _make_patrol_route(free, pos)
		_container.add_child(e)

	# ── 4) 아이템은 방 중앙 고정 ──
	if room["provides"] != "":
		var key_item := Entities.make_item("key", room["provides"])
		key_item.position = center
		_container.add_child(key_item)

	if _is_objective_room(room):
		var obj := Entities.make_item("objective", "")
		obj.position = center + Vector2(0, TILE * 1.2)
		_container.add_child(obj)

	var pickup: float = float(params.get("resource_pickup", 0.0))
	if room_type == "SIDE_OBJECTIVE" or pickup > 0.55 or _optional_ids.has(room["id"]):
		var bonus := Entities.make_item("bonus", "")
		bonus.position = center + Vector2(TILE * 1.6, -TILE * 1.2)
		_container.add_child(bonus)


## 템플릿의 선호 좌표(15×11 기준 타일)를 방 크기에 맞춰 월드 좌표로 바꾸고,
## 실제 허용 후보(allowed) 중 가장 가까운 자리로 맞춘다 (반 타일 이상 벗어나면 버림)
func _template_spots(room: Dictionary, zones: Array, allowed: Array) -> Array:
	var out: Array = []
	if zones.is_empty() or allowed.is_empty():
		return out
	var sx: float = float(room["w"]) / float(RoomTemplates.BASE_W)
	var sy: float = float(room["h"]) / float(RoomTemplates.BASE_H)
	for z in zones:
		var v: Vector2 = z
		var want := Vector2(
			(float(room["tx"]) + v.x * sx + 0.5) * TILE,
			(float(room["ty"]) + v.y * sy + 0.5) * TILE)
		var best: Vector2 = allowed[0]
		var best_d: float = 1e20
		for a in allowed:
			var d: float = want.distance_squared_to(a)
			if d < best_d:
				best_d = d
				best = a
		if best_d <= pow(TILE * 1.5, 2) and not (best in out):
			out.append(best)
	return out


## 엄폐물에서 min_gap 이상 떨어진 후보만 남긴다
func _spots_clear_of(pool: Array, blockers: Array, min_gap: float) -> Array:
	if blockers.is_empty():
		return pool.duplicate()
	var gap2: float = min_gap * min_gap
	var out: Array = []
	for sp in pool:
		var ok: bool = true
		for b in blockers:
			if sp.distance_squared_to(b) < gap2:
				ok = false
				break
		if ok:
			out.append(sp)
	return out


## 순찰 경로를 만든다. 경유점이 2개 미만이면 반경을 넓혀 가며 다시 시도한다.
## (경유점이 1개면 적이 그 자리에서 영영 제자리걸음을 한다)
func _make_patrol_route(free: Array, origin: Vector2) -> Array:
	var radii := [TILE * 4.0, TILE * 6.0, TILE * 9.0, TILE * 14.0]
	for r in radii:
		var nearby: Array = _near_spots(free, origin, r)
		if nearby.size() < 3:
			continue
		var route: Array = _pick_spread(nearby, 3, origin, TILE * 2.0)
		if route.size() >= 2:
			return route

	# 그래도 부족하면 방 전체에서 가장 먼 두 점
	var fallback: Array = _pick_spread(free, 2, origin, TILE * 1.5)
	if fallback.size() >= 2:
		return fallback

	# 최후: 제자리 좌우 왕복
	return [origin + Vector2(TILE * 1.5, 0), origin - Vector2(TILE * 1.5, 0)]


## 난이도와 무관하게 레벨이 클리어 가능한지 실제로 검사한다.
## 플레이어처럼 "도달 → 키 획득 → 해당 문 개방" 을 더 이상 새 키가 없을 때까지 반복한다.
## (키가 다른 잠금문 뒤에 있는 다단 잠금 레벨도 올바르게 판정)
## 1) 문에 쓰이는 모든 키를 순서대로 얻을 수 있는가
## 2) 모든 목표 방에 도달 가능한가
## 3) EXIT 에 도달 가능한가, 그리고 문을 모두 잠근 상태로는 도달 불가능한가 (잠금 우회 방지)
## 4) (v1) clear_conditions.required_keys 를 모두 얻을 수 있는가
func verify_solvable(door_plans: Array) -> Dictionary:
	var entry_tile := Vector2i(-1, -1)
	for room in rooms:
		if room["type"] == "ENTRY":
			entry_tile = Vector2i(room["ctx"], room["cty"])
			break
	if entry_tile.x < 0:
		return {"ok": false, "reason": "ENTRY 없음"}

	var door_tiles: Dictionary = {}
	var door_keys: Dictionary = {}
	for plan in door_plans:
		door_keys[str(plan["key_id"])] = true
		for t in plan["tiles"]:
			door_tiles[t] = true

	var closed: Dictionary = _flood(entry_tile, door_tiles)

	# 키를 모아 가며 문을 여는 반복 탐색
	var held: Dictionary = {}
	var reach: Dictionary = closed
	while true:
		var gained: bool = false
		for room in rooms:
			var k: String = str(room["provides"])
			if k == "" or held.has(k):
				continue
			if reach.has(Vector2i(room["ctx"], room["cty"])):
				held[k] = true
				gained = true
		if not gained:
			break
		var blocked: Dictionary = {}
		for plan2 in door_plans:
			if held.has(str(plan2["key_id"])):
				continue
			for t2 in plan2["tiles"]:
				blocked[t2] = true
		reach = _flood(entry_tile, blocked)

	var problems: Array = []

	for k2 in door_keys.keys():
		if not held.has(k2):
			problems.append("키 %s 획득 불가 (문 개방 불가)" % k2)
	for rk in GameState.required_keys:
		if not held.has(str(rk)) and not door_keys.has(str(rk)):
			problems.append("필수 키 %s 획득 불가" % str(rk))

	for room in rooms:
		var c := Vector2i(room["ctx"], room["cty"])
		if _is_objective_room(room):
			if not reach.has(c):
				problems.append("OBJECTIVE(%s) 도달 불가" % room["id"])
		if room["type"] == "EXIT":
			if not reach.has(c):
				problems.append("EXIT 도달 불가")
			if door_tiles.size() > 0 and closed.has(c):
				problems.append("EXIT 에 문 없이 도달 가능 (잠금 우회)")

	return {"ok": problems.is_empty(), "problems": problems,
			"reachable": reach.size(), "total": _floor_tiles.size()}


## 목표 방 판정 — v1 은 clear_conditions.objective_nodes, 구형식은 타입
func _is_objective_room(room: Dictionary) -> bool:
	if _is_v1:
		return _objective_ids.has(room["id"])
	return room["type"] == "OBJECTIVE"


func _flood(start: Vector2i, blocked: Dictionary) -> Dictionary:
	var seen: Dictionary = {start: true}
	var queue: Array = [start]
	var dirs := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	while not queue.is_empty():
		var cur: Vector2i = queue.pop_front()
		for d in dirs:
			var nb: Vector2i = cur + d
			if seen.has(nb):
				continue
			if not _floor_tiles.has(nb):
				continue
			if blocked.has(nb):
				continue
			seen[nb] = true
			queue.append(nb)
	return seen


## 맵 전체 픽셀 경계 (바깥 붉은 영역 크기 계산용)
func map_bounds() -> Rect2:
	var min_x: int = 99999
	var min_y: int = 99999
	var max_x: int = -99999
	var max_y: int = -99999
	for t in _floor_tiles.keys():
		min_x = mini(min_x, t.x)
		min_y = mini(min_y, t.y)
		max_x = maxi(max_x, t.x)
		max_y = maxi(max_y, t.y)
	if min_x > max_x:
		return Rect2(0, 0, 1000, 1000)
	return Rect2(
		float(min_x) * TILE, float(min_y) * TILE,
		float(max_x - min_x + 1) * TILE, float(max_y - min_y + 1) * TILE
	)


func door_plans() -> Array:
	return _door_plans


# ═══════════════════════════════════════
#  긴장도 계산용 조회 (TensionTracker 가 쓰는 그래프 정보)
# ═══════════════════════════════════════

func _build_tension_index() -> void:
	_out_edges_by_room.clear()
	_pair_edges.clear()
	_prox_by_room.clear()
	_tile_edges.clear()
	for e in _level_edges:
		var s: String = str(e.get("source", ""))
		var t: String = str(e.get("target", ""))
		if not _out_edges_by_room.has(s):
			_out_edges_by_room[s] = []
		_out_edges_by_room[s].append(e)
		# 같은 방향 간선이 여럿이면 먼저 나온 것을 쓴다
		if not _pair_edges.has(s + ">" + t):
			_pair_edges[s + ">" + t] = e
	if typeof(_proximity_data) == TYPE_DICTIONARY:
		for p in _proximity_data.values():
			if typeof(p) != TYPE_DICTIONARY:
				continue
			var a: String = str(p.get("node_a", ""))
			var b: String = str(p.get("node_b", ""))
			for pair in [[a, b], [b, a]]:
				var nb = room_by_id.get(pair[1], null)
				if nb == null:
					continue
				if not _prox_by_room.has(pair[0]):
					_prox_by_room[pair[0]] = []
				_prox_by_room[pair[0]].append({
					"neighbor": nb,
					"sound_leak": float(p.get("sound_leak", 0.0)),
					"visual_leak": float(p.get("visual_leak", 0.0)),
				})
	for rec in _corridor_records:
		for t2 in rec["tiles"].keys():
			if not _pure_corridor.has(t2):
				continue
			if not _tile_edges.has(t2):
				_tile_edges[t2] = []
			_tile_edges[t2].append(rec["edge"])


## 이 방이 source 인 간선 (Python graph.out_edges)
func out_edges_of(room_id: String) -> Array:
	return _out_edges_by_room.get(room_id, [])


## a → b 로 지나간 간선. 정방향(source=a, target=b)을 먼저, 없으면 역방향 (Python 의 되돌아가기)
func edge_between(a: String, b: String) -> Dictionary:
	if _pair_edges.has(a + ">" + b):
		return _pair_edges[a + ">" + b]
	if _pair_edges.has(b + ">" + a):
		return _pair_edges[b + ">" + a]
	return {}


## 이 방이 낀 공유벽 [{neighbor, sound_leak, visual_leak}]
func proximity_of(room_id: String) -> Array:
	return _prox_by_room.get(room_id, [])


## 월드 좌표가 순수 복도 타일이면 그 복도의 간선들, 아니면 []
func corridor_edges_at(world_pos: Vector2) -> Array:
	var t := Vector2i(int(floor(world_pos.x / TILE)), int(floor(world_pos.y / TILE)))
	return _tile_edges.get(t, [])


func _even_points(ys) -> Array:
	var out: Array = []
	if typeof(ys) != TYPE_ARRAY or ys.is_empty():
		return out
	if ys.size() == 1:
		return [[0.0, float(ys[0])], [1.0, float(ys[0])]]
	for i in range(ys.size()):
		out.append([float(i) / float(ys.size() - 1), float(ys[i])])
	return out


## 미니맵용: 복도 기록 [{edge, tiles, segs}]
func corridor_records() -> Array:
	return _corridor_records


## 미니맵용: 아직 발견하지 못한 숨은 통로의 간선 id 집합
func unrevealed_edge_ids() -> Dictionary:
	var out: Dictionary = {}
	for g in _hidden_groups:
		if not g["revealed"]:
			out[g["edge_id"]] = true
	return out


func difficulty_name() -> String:
	return str(DIFFICULTY[difficulty]["name"])


func difficulty_hp() -> int:
	return maxi(1, int(DIFFICULTY[difficulty]["hp"]))


func difficulty_kills() -> int:
	return maxi(1, int(DIFFICULTY[difficulty]["kills"]))


func difficulty_alert_mul() -> float:
	return float(DIFFICULTY[difficulty]["alert_mul"])


# ═══════════════════════════════════════
#  조회
# ═══════════════════════════════════════

func entry_position() -> Vector2:
	for room in rooms:
		if room["type"] == "ENTRY":
			return room["center"]
	if rooms.size() > 0:
		return rooms[0]["center"]
	return Vector2(400, 300)


func exit_position() -> Vector2:
	for room in rooms:
		if room["type"] == "EXIT":
			return room["center"]
	if rooms.size() > 0:
		return rooms[rooms.size() - 1]["center"]
	return Vector2(800, 600)


func room_at(world_pos: Vector2) -> Dictionary:
	for room in rooms:
		var px: float = room["tx"] * TILE
		var py: float = room["ty"] * TILE
		if world_pos.x >= px and world_pos.x < px + float(room["w"]) * TILE:
			if world_pos.y >= py and world_pos.y < py + float(room["h"]) * TILE:
				return room
	return {}


# ═══════════════════════════════════════
#  JSON 이 없을 때 쓰는 내장 레벨
# ═══════════════════════════════════════

func _mk_params(patrols: int, prange: float, pspeed: float,
		cover: float, light: float, pickup: float, alarm: float) -> Dictionary:
	return {
		"num_patrols": patrols,
		"patrol_range": prange,
		"patrol_speed": pspeed,
		"cover_ratio": cover,
		"light_level": light,
		"resource_pickup": pickup,
		"has_keycard": false,
		"alarm_increment": alarm,
	}


func _fallback_data() -> Dictionary:
	var node_list: Array = []
	node_list.append({"id": "entry", "type": "ENTRY", "provides": null,
		"room_params": _mk_params(0, 0.30, 0.30, 0.70, 0.25, 0.0, 0.00)})
	node_list.append({"id": "t1", "type": "TRANSIT", "provides": null,
		"room_params": _mk_params(1, 0.45, 0.40, 0.50, 0.50, 0.0, 0.02)})
	node_list.append({"id": "choke", "type": "CHOKE", "provides": null,
		"room_params": _mk_params(3, 0.85, 0.75, 0.20, 0.85, 0.0, 0.15)})
	node_list.append({"id": "obj", "type": "OBJECTIVE", "provides": null,
		"room_params": _mk_params(2, 0.60, 0.50, 0.45, 0.60, 0.0, 0.10)})
	node_list.append({"id": "obs", "type": "OBSERVATION", "provides": null,
		"room_params": _mk_params(0, 0.20, 0.20, 0.85, 0.20, 0.3, 0.00)})
	node_list.append({"id": "kr", "type": "KEY_ROOM", "provides": "K1",
		"room_params": _mk_params(1, 0.50, 0.45, 0.55, 0.50, 0.6, 0.05)})
	node_list.append({"id": "t2", "type": "TRANSIT", "provides": null,
		"room_params": _mk_params(1, 0.50, 0.50, 0.50, 0.50, 0.0, 0.03)})
	node_list.append({"id": "side", "type": "SIDE_OBJECTIVE", "provides": null,
		"room_params": _mk_params(1, 0.40, 0.40, 0.60, 0.45, 0.9, 0.00)})
	node_list.append({"id": "exit", "type": "EXIT", "provides": null,
		"room_params": _mk_params(2, 0.60, 0.55, 0.35, 0.65, 0.0, 0.12)})

	var edge_list: Array = []
	edge_list.append({"source": "entry", "target": "t1", "locked": false})
	edge_list.append({"source": "t1", "target": "choke", "locked": false})
	edge_list.append({"source": "choke", "target": "obj", "locked": false})
	edge_list.append({"source": "obj", "target": "obs", "locked": false})
	edge_list.append({"source": "obs", "target": "kr", "locked": false})
	edge_list.append({"source": "kr", "target": "t2", "locked": false})
	edge_list.append({"source": "t2", "target": "exit", "locked": true, "key_id": "K1"})
	edge_list.append({"source": "t1", "target": "side", "locked": false})

	return {
		"nodes": node_list,
		"edges": edge_list,
		"meta": {"dtc_name": "built-in", "target_curve": [], "simulated_curve": []},
	}
