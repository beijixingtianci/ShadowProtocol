## Player — 플레이어 컨트롤러 + 손그림 캐릭터 렌더링
extends CharacterBody2D

const WALK_SPEED: float = 130.0       # 기본 걸음 (이전 SPEED=205 보다 느림)
const SPRINT_SPEED: float = 235.0     # 달리기 (이전 기본 속도보다 빠름)
const HIDE_MULT: float = 0.38         # 은신 이동 배율

## 이동 소음 반경 (px). 은신 중에는 소리를 내지 않는다.
const NOISE_SPRINT: float = 280.0
const NOISE_WALK: float = 90.0
const NOISE_ASSASSINATE: float = 120.0
## 이동 소음은 매 물리 프레임 대신 이 간격으로 낸다 (레이캐스트 부하 절감, 체감 차이 없음)
const NOISE_INTERVAL: float = 0.15

## 시체 운반 — 속도 60% (은신과 곱해짐), 달리기·암살 불가, 끄는 소리
const CARRY_SPEED_MULT: float = 0.60
const CARRY_NOISE_MULT: float = 1.5     # 걷기 소음 반경 ×1.5
const NOISE_CARRY_SNEAK: float = 45.0   # 은신 중에도 완전히 조용히 끌 수는 없다
const BODY_PICK_RANGE: float = 64.0     # 시체를 드는 거리 (문 상호작용 거리와 같음)
const BODY_TRAIL: float = 18.0          # 플레이어 뒤로 끌리는 거리
const ASSASSIN_RANGE: float = 56.0      # 암살 유효 거리
const ASSASSIN_ARC_DEG: float = 62.0    # 암살 판정 각도 (적 뒤쪽 부채꼴)

# 캐릭터 색상
const SKIN := Color(0.92, 0.80, 0.68)      # 피부
const CLOTH := Color(0.22, 0.62, 0.60)     # 옷
const OUTLINE := Color(0.05, 0.07, 0.11)   # 외곽선
const ACCENT := Color(0.95, 0.78, 0.30)    # 강조색 (단검 등)

var facing: float = 0.0        # 현재 바라보는 각도 (라디안)
var is_hiding: bool = false    # 은신 중인가 (Ctrl)
var is_sprinting: bool = false # 달리는 중인가 (Shift)

## 현재 이동 소음 반경 (HUD/디버그 링 표시용)
var noise_radius: float = 0.0

## 운반 중인 시체 (쓰러진 Enemy). 없으면 null
var carrying_body: Node2D = null
var _noise_cd: float = 0.0    # 소음 발생 간격 타이머

## 엄폐물 감지 반경(CoverDet) 안의 엄폐물 수 — 은신 시 시야 차단 판정에 쓴다
var _near_covers: int = 0
var _step: float = 0.0     # 걷기 모션 위상 (팔다리 흔들림)
var _blade: float = 0.0    # 단검 내밀기 (암살 시 1 → 0 으로 감쇠)

## 현재 상호작용 가능한 대상 (F 프롬프트 표시용)
var _focus: Node = null
var _focus_pos: Vector2 = Vector2.ZERO
## "body" 면 시체 (배지 옆에 "운반" 표시)
var _focus_kind: String = ""
var _prompt_t: float = 0.0 # 프롬프트 흔들림 애니메이션 시간


# ──────────────────────────────────────────────
# 초기화
# ──────────────────────────────────────────────

func _ready() -> void:
	add_to_group("player")
	# 엄폐물 감지 영역 신호 연결
	var cover_det: Area2D = get_node_or_null("CoverDet")
	if cover_det != null:
		cover_det.body_entered.connect(_on_cover_enter)
		cover_det.body_exited.connect(_on_cover_exit)


# ──────────────────────────────────────────────
# 물리 프레임 — 이동 / 상태 / 소음 / 애니메이션
# ──────────────────────────────────────────────

func _physics_process(delta: float) -> void:
	# 게임 중이 아니면 멈춘다
	if not GameState.is_playing:
		velocity = Vector2.ZERO
		return

	# WASD 입력 방향
	var dir: Vector2 = Input.get_vector("move_left", "move_right", "move_up", "move_down")

	# Shift = 달리기, Ctrl = 은신(어디서나: 느리고 무음). 둘 다 누르면 은신 우선.
	# 엄폐물 옆에서 은신하면 적 시야에서도 사라진다 (is_concealed)
	var wants_sprint: bool = Input.is_action_pressed("sprint") and dir.length() > 0.1
	var wants_sneak: bool = Input.is_action_pressed("hide")

	# 운반 중인 시체가 사라졌으면 참조를 비운다
	if carrying_body != null and not is_instance_valid(carrying_body):
		carrying_body = null

	is_hiding = wants_sneak
	# 운반 중에는 달릴 수 없다
	is_sprinting = wants_sprint and not is_hiding and carrying_body == null

	# ── 실제 이동 속도 ──
	var speed: float = WALK_SPEED
	if is_hiding:
		speed = WALK_SPEED * HIDE_MULT      # 은신: 130 × 0.38 ≈ 49 px/s
	elif is_sprinting:
		speed = SPRINT_SPEED                 # 달리기: 235 px/s
	if carrying_body != null:
		speed *= CARRY_SPEED_MULT            # 운반 중이면 ×0.6
	velocity = dir * speed
	move_and_slide()

	# ── 이동 소음 ──
	noise_radius = 0.0
	if velocity.length() > 5.0:
		if is_sprinting:
			noise_radius = NOISE_SPRINT      # 달리기 280px
		elif is_hiding:
			noise_radius = 0.0               # 은신은 무음
		else:
			noise_radius = NOISE_WALK        # 걷기 90px
		# 시체를 끄는 소리 — 걷기는 더 시끄럽고, 은신 중에도 완전히 조용하지는 않다
		if carrying_body != null:
			noise_radius *= CARRY_NOISE_MULT
			if is_hiding:
				noise_radius = NOISE_CARRY_SNEAK
	# 매 프레임이 아니라 일정 간격으로 소음을 낸다 (부하 절감)
	_noise_cd -= delta
	if noise_radius > 0.0 and _noise_cd <= 0.0:
		_noise_cd = NOISE_INTERVAL
		SoundSystem.emit_noise(global_position, noise_radius)

	# ── 걷기 모션 ──
	# 상태별 걸음 빈도: 은신 5 / 걷기 9 / 달리기 14
	if velocity.length() > 5.0:
		_step += delta * (5.0 if is_hiding else (14.0 if is_sprinting else 9.0))
	else:
		_step = lerpf(_step, 0.0, delta * 6.0) # 멈추면 부드럽게 0 으로

	# 단검 내밀기 애니메이션 감쇠
	_blade = maxf(0.0, _blade - delta * 3.4)

	# 마우스 쪽을 바라본다
	facing = (get_global_mouse_position() - global_position).angle()

	# 운반 중인 시체는 플레이어 뒤로 끌려온다
	if carrying_body != null:
		carrying_body.global_position = global_position + Vector2.from_angle(facing + PI) * BODY_TRAIL

	# 은신 중이면 반투명
	var target_alpha: float = 0.5 if is_hiding else 1.0
	modulate.a = lerpf(modulate.a, target_alpha, delta * 10.0)

	# 은신 중이면 주변 조명을 약하게
	var glow: PointLight2D = get_node_or_null("Glow")
	if glow != null:
		glow.energy = lerpf(glow.energy, 0.12 if is_hiding else 0.32, delta * 6.0)

	# 상호작용 대상 갱신 (F 프롬프트용)
	_update_focus()
	_prompt_t += delta

	# 다시 그리기 (_draw)
	queue_redraw()


# ──────────────────────────────────────────────
# 상호작용 대상 — 범위 안에서 가장 가까운 것
# ──────────────────────────────────────────────

func _update_focus() -> void:
	_focus = null
	_focus_kind = ""
	# 운반 중에는 F = 내려놓기 뿐
	if carrying_body != null:
		return
	# 근처 시체가 최우선
	var nearby: Node2D = _find_nearby_body()
	if nearby != null:
		_focus = nearby
		_focus_pos = nearby.global_position
		_focus_kind = "body"
		return

	# InterDet 영역 안의 문·아이템
	var det: Area2D = get_node_or_null("InterDet")
	if det == null:
		return

	var best_dist: float = 1e9
	for body in det.get_overlapping_bodies():
		var target: Node = body
		if not target.has_method("interact"):
			target = body.get_parent()
		if target == null or not target.has_method("interact"):
			continue
		# 이미 주운 아이템은 제외
		if target.get("collected") == true:
			continue
		# 이미 열린 문은 제외
		if target.get("is_open") == true:
			continue

		var tpos: Vector2 = target.global_position
		var d: float = global_position.distance_to(tpos)
		if d < best_dist:
			best_dist = d
			_focus = target
			_focus_pos = tpos


# ──────────────────────────────────────────────
# 손그림 렌더링 — 코드로 캐릭터를 그린다 (이미지 리소스 없음)
# ──────────────────────────────────────────────

func _draw() -> void:
	# 바닥 그림자
	draw_set_transform(Vector2(1.5, 2.5), 0.0, Vector2.ONE)
	draw_circle(Vector2.ZERO, 10.0, Color(0, 0, 0, 0.28))

	# 캐릭터 본체 (바라보는 방향으로 회전)
	draw_set_transform(Vector2.ZERO, facing, Vector2.ONE)
	CharArt.draw_agent(self, SKIN, CLOTH, OUTLINE, ACCENT, _step, _blade)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE) # 변환 초기화

	# 달리기 소음 범위 (희미한 링)
	if is_sprinting:
		var pulse: float = 0.5 + sin(_prompt_t * 9.0) * 0.5
		draw_arc(Vector2.ZERO, noise_radius, 0.0, TAU, 64,
			Color(1.0, 0.85, 0.45, 0.07 + pulse * 0.05), 1.4, true)

	# 은신 중 표시
	if is_hiding:
		draw_arc(Vector2.ZERO, 17.0, 0.0, TAU, 28, Color(0.35, 0.85, 0.85, 0.5), 1.6, true)

	# 시체를 끄는 줄
	if carrying_body != null and is_instance_valid(carrying_body):
		draw_line(Vector2.ZERO, to_local(carrying_body.global_position),
			Color(0.5, 0.2, 0.2, 0.4), 2.0, true)

	# 상호작용 프롬프트
	if carrying_body != null:
		_draw_prompt(Vector2.ZERO, Settings.tr_ko("내려놓기"), false)
	elif _focus != null:
		_draw_prompt(to_local(_focus_pos), Settings.tr_ko("운반") if _focus_kind == "body" else "")


## 대상 위에 F 키 배지를 그린다. label 이 있으면 배지 오른쪽에 동작 이름을 쓴다.
func _draw_prompt(local_pos: Vector2, label: String = "", ring: bool = true) -> void:
	# 위아래 흔들림
	var bob: float = sin(_prompt_t * 4.0) * 2.0
	var badge := local_pos + Vector2(0, -30.0 + bob)

	# 대상 강조 링
	if ring:
		var ring_a: float = 0.35 + sin(_prompt_t * 4.0) * 0.18
		draw_arc(local_pos, 20.0, 0.0, TAU, 28, Color(1, 1, 1, ring_a), 1.8, true)

	# 연결선
	draw_line(local_pos + Vector2(0, -20.0), badge + Vector2(0, 7.0),
		Color(1, 1, 1, 0.30), 1.2, true)

	# 배지 본체
	draw_circle(badge, 10.0, Color(0.05, 0.06, 0.09, 0.92))
	# 배지 테두리
	draw_arc(badge, 10.0, 0.0, TAU, 24, Color(0.98, 0.86, 0.35, 0.95), 2.0, true)

	# "F" 글자
	var font := ThemeDB.fallback_font
	if font != null:
		var size: int = 14
		var tw: float = font.get_string_size("F", HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
		draw_string(font, badge + Vector2(-tw * 0.5, size * 0.36), "F",
			HORIZONTAL_ALIGNMENT_LEFT, -1, size, Color(0.98, 0.90, 0.45))
		# 동작 이름 ("운반" / "내려놓기")
		if label != "":
			draw_string(font, badge + Vector2(14.0, 5.0), label,
				HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.95, 0.92, 0.80, 0.95))


# ──────────────────────────────────────────────
# 키 입력
# ──────────────────────────────────────────────

func _unhandled_input(event: InputEvent) -> void:
	if not GameState.is_playing:
		return
	if event.is_action_pressed("interact"):    # F
		_do_interact()
	elif event.is_action_pressed("assassinate"): # E
		_do_assassinate()


# ──────────────────────────────────────────────
# F 상호작용
# 우선순위: 1) 운반 중이면 내려놓기  2) 근처 시체 들기  3) 문·아이템 상호작용
# ──────────────────────────────────────────────

func _do_interact() -> void:
	# 1) 운반 중 → 내려놓기
	if carrying_body != null:
		_drop_body()
		return

	# 2) 근처 시체 → 들기
	var nearby: Node2D = _find_nearby_body()
	if nearby != null:
		_pick_up_body(nearby)
		return

	# 3) 문·아이템 상호작용
	_update_focus()
	if _focus == null:
		GameState.post_message("주변에 상호작용할 대상이 없습니다", Color(0.6, 0.6, 0.6))
		return
	_focus.interact()
	_focus = null


## 가장 가까운 시체
func _find_nearby_body() -> Node2D:
	var best: Node2D = null
	var best_dist: float = BODY_PICK_RANGE
	# "corpses" 그룹에서 가장 가까운 것
	for body in get_tree().get_nodes_in_group("corpses"):
		if not is_instance_valid(body):
			continue
		var d: float = global_position.distance_to(body.global_position)
		if d < best_dist:
			best_dist = d
			best = body
	return best


## 시체 들기
func _pick_up_body(body: Node2D) -> void:
	carrying_body = body
	# 운반 중인 시체는 "carried" 그룹으로 — 경비병이 "시체"로 보지 않는다
	body.remove_from_group("corpses")
	body.add_to_group("carried")
	GameState.post_message("시체 운반 중 (F: 내려놓기)", Color(0.7, 0.75, 0.6))


## 시체 내려놓기
func _drop_body() -> void:
	if carrying_body == null:
		return
	var body: Node2D = carrying_body
	carrying_body = null
	if not is_instance_valid(body):
		return

	# 앞쪽 20px 에 내려놓되, 벽 너머로 넘어가면 발밑에 둔다
	var want: Vector2 = global_position + Vector2.from_angle(facing) * 20.0
	var space := get_world_2d().direct_space_state
	var q := PhysicsRayQueryParameters2D.create(global_position, want, 1)
	q.exclude = [get_rid()]
	if not space.intersect_ray(q).is_empty():
		want = global_position  # 앞이 막혀 있으면 발밑
	body.global_position = want

	body.remove_from_group("carried")
	body.add_to_group("corpses")
	# 옮겨진 시체 — corpse_rev 를 올려 이미 본 경비병도 다시 수상하게 여기게 한다
	body.set_meta("corpse_rev", int(body.get_meta("corpse_rev", 0)) + 1)
	GameState.post_message("시체를 내려놓았습니다", Color(0.6, 0.6, 0.6))


# ──────────────────────────────────────────────
# 암살
# ──────────────────────────────────────────────

func _do_assassinate() -> void:
	# 운반 중에는 암살 불가
	if carrying_body != null:
		GameState.post_message("시체를 운반 중에는 암살할 수 없습니다", Color(0.6, 0.6, 0.6))
		return
	# 암살 횟수 소진
	if GameState.kill_charges <= 0:
		GameState.post_message("암살 횟수 소진", Color(1, 0.4, 0.4))
		return

	var best: Node2D = null
	var best_dist: float = ASSASSIN_RANGE

	# 가장 가깝고, 적의 등 뒤 부채꼴 안에 있는 대상
	for e in get_tree().get_nodes_in_group("enemies"):
		if not is_instance_valid(e):
			continue
		if not e.alive:
			continue
		var dist: float = global_position.distance_to(e.global_position)
		if dist > best_dist:
			continue
		# 적 기준 플레이어 방향이 등 뒤인가 (정면에서 180° - 62° 이상 벗어남)
		var angle_to_me: float = (global_position - e.global_position).angle()
		var diff: float = absf(angle_difference(angle_to_me, e.facing))
		if diff > deg_to_rad(180.0 - ASSASSIN_ARC_DEG):
			best = e
			best_dist = dist

	# 단검 내밀기
	_blade = 1.0

	# 대상 없음
	if best == null:
		GameState.post_message("적의 뒤에서 접근하세요", Color(0.6, 0.6, 0.6))
		return

	# 암살 횟수 소모 → 처치 → 소음
	if GameState.use_kill_charge():
		best.die()
		SoundSystem.emit_noise(global_position, NOISE_ASSASSINATE)


# ──────────────────────────────────────────────
# 은폐 판정 + 엄폐물 감지 신호
# ──────────────────────────────────────────────

## 적 시야에서 완전히 가려지는가 — 은신 + 엄폐물 근처
func is_concealed() -> bool:
	return is_hiding and _near_covers > 0


## 엄폐물이 감지 범위에 들어옴
func _on_cover_enter(body: Node2D) -> void:
	if body.is_in_group("covers"):
		_near_covers += 1


## 엄폐물이 감지 범위를 벗어남
func _on_cover_exit(body: Node2D) -> void:
	if body.is_in_group("covers"):
		_near_covers = maxi(0, _near_covers - 1)
