## CharArt.gd — 손그림 느낌의 캐릭터 드로잉 라이브러리
## 굵은 외곽선 + 머리/몸통/팔/무기 구성. 모든 좌표는 "오른쪽(+X)을 바라보는" 기준.
## 호출부에서 draw_set_transform(Vector2.ZERO, facing, Vector2.ONE) 로 회전시킨다.
extends Node
class_name CharArt


## 굵은 외곽선이 있는 원
static func outlined_circle(ci: CanvasItem, center: Vector2, radius: float,
		fill: Color, outline: Color, thickness: float = 2.2) -> void:
	ci.draw_circle(center, radius, fill)
	ci.draw_arc(center, radius, 0.0, TAU, 24, outline, thickness, true)


## 외곽선이 있는 캡슐 (몸통·팔다리용)
static func outlined_capsule(ci: CanvasItem, a: Vector2, b: Vector2, radius: float,
		fill: Color, outline: Color, thickness: float = 2.2) -> void:
	ci.draw_line(a, b, outline, radius * 2.0 + thickness * 2.0, true)
	ci.draw_line(a, b, fill, radius * 2.0, true)


## 외곽선이 있는 다각형
static func outlined_poly(ci: CanvasItem, pts: PackedVector2Array,
		fill: Color, outline: Color, thickness: float = 2.2) -> void:
	if pts.size() < 3:
		return
	ci.draw_colored_polygon(pts, fill)
	var loop := PackedVector2Array(pts)
	loop.append(pts[0])
	ci.draw_polyline(loop, outline, thickness, true)


# ═══════════════════════════════════════════════
#  플레이어 — 날씬한 잠입 요원. 단검을 든 자세.
# ═══════════════════════════════════════════════

static func draw_agent(ci: CanvasItem, skin: Color, cloth: Color,
		outline: Color, accent: Color, step: float, blade_out: float) -> void:

	# 걷기 모션: 팔다리가 살짝 흔들림
	var sway: float = sin(step) * 2.0
	var sway2: float = sin(step + PI) * 2.0

	# ── 다리 (몸통 뒤) ──
	outlined_capsule(ci, Vector2(-1.0, 4.5), Vector2(-5.5, 6.0 + sway), 2.0, cloth, outline, 1.6)
	outlined_capsule(ci, Vector2(-1.0, -4.5), Vector2(-5.5, -6.0 + sway2), 2.0, cloth, outline, 1.6)

	# ── 망토/외투 (몸통 뒤로 흩날림) ──
	var cape := PackedVector2Array([
		Vector2(-2.0, -6.0),
		Vector2(-11.0 - absf(sway) * 0.4, -4.0 + sway * 0.5),
		Vector2(-12.5 - absf(sway) * 0.4, 0.0),
		Vector2(-11.0 - absf(sway) * 0.4, 4.0 + sway * 0.5),
		Vector2(-2.0, 6.0),
	])
	outlined_poly(ci, cape, cloth.darkened(0.25), outline, 1.8)

	# ── 몸통 ──
	var torso := PackedVector2Array([
		Vector2(4.0, -5.2),
		Vector2(6.2, 0.0),
		Vector2(4.0, 5.2),
		Vector2(-3.0, 4.6),
		Vector2(-4.2, 0.0),
		Vector2(-3.0, -4.6),
	])
	outlined_poly(ci, torso, cloth, outline, 2.2)

	# 가슴 벨트
	ci.draw_line(Vector2(3.0, -4.0), Vector2(-1.0, 3.2), accent, 1.8, true)

	# ── 뒤쪽 팔 ──
	outlined_capsule(ci, Vector2(2.0, -4.0), Vector2(5.0, -7.5 + sway2 * 0.6), 1.8, cloth, outline, 1.5)

	# ── 머리 (두건 + 얼굴) ──
	outlined_circle(ci, Vector2(3.4, 0.0), 5.4, cloth, outline, 2.2)
	# 얼굴 노출부
	var face := PackedVector2Array([
		Vector2(5.2, -2.6),
		Vector2(8.4, -1.4),
		Vector2(8.4, 1.4),
		Vector2(5.2, 2.6),
	])
	ci.draw_colored_polygon(face, skin)
	ci.draw_polyline(PackedVector2Array([
		Vector2(5.2, -2.6), Vector2(8.4, -1.4),
		Vector2(8.4, 1.4), Vector2(5.2, 2.6),
	]), outline, 1.6, true)
	# 눈
	ci.draw_circle(Vector2(7.0, -0.9), 0.85, outline)
	ci.draw_circle(Vector2(7.0, 1.1), 0.85, outline)

	# 두건 꼬리
	ci.draw_line(Vector2(0.5, -3.0), Vector2(-4.5, -5.5 + sway2), cloth.darkened(0.15), 2.4, true)

	# ── 앞쪽 팔 + 단검 ──
	var hand := Vector2(7.5 + blade_out * 2.0, 5.2)
	outlined_capsule(ci, Vector2(2.5, 4.2), hand, 1.8, cloth, outline, 1.5)

	# 단검
	var blade_tip := hand + Vector2(9.0 + blade_out * 6.0, -1.5)
	ci.draw_line(hand, blade_tip, outline, 3.4, true)
	ci.draw_line(hand, blade_tip, Color(0.86, 0.92, 0.98), 1.8, true)
	# 손잡이 가드
	ci.draw_line(hand + Vector2(-1.0, -2.0), hand + Vector2(1.0, 2.0), outline, 2.2, true)


# ═══════════════════════════════════════════════
#  적 — 덩치 큰 경비병. 손전등과 무전기.
# ═══════════════════════════════════════════════

static func draw_guard(ci: CanvasItem, body_col: Color, outline: Color,
		visor: Color, step: float, alerted: bool) -> void:

	var sway: float = sin(step) * 1.8
	var sway2: float = sin(step + PI) * 1.8

	# ── 다리 ──
	outlined_capsule(ci, Vector2(-1.0, 4.8), Vector2(-5.0, 6.4 + sway), 2.3, body_col.darkened(0.3), outline, 1.7)
	outlined_capsule(ci, Vector2(-1.0, -4.8), Vector2(-5.0, -6.4 + sway2), 2.3, body_col.darkened(0.3), outline, 1.7)

	# ── 배낭 ──
	var pack := PackedVector2Array([
		Vector2(-3.5, -4.5),
		Vector2(-9.0, -3.5),
		Vector2(-9.5, 3.5),
		Vector2(-3.5, 4.5),
	])
	outlined_poly(ci, pack, body_col.darkened(0.4), outline, 1.8)

	# ── 몸통 (어깨 넓게) ──
	var torso := PackedVector2Array([
		Vector2(4.5, -6.6),
		Vector2(7.0, 0.0),
		Vector2(4.5, 6.6),
		Vector2(-3.5, 5.6),
		Vector2(-4.8, 0.0),
		Vector2(-3.5, -5.6),
	])
	outlined_poly(ci, torso, body_col, outline, 2.4)

	# 방탄조끼 라인
	ci.draw_line(Vector2(3.5, -4.6), Vector2(3.5, 4.6), outline * Color(1, 1, 1, 0.55), 1.6, true)
	ci.draw_line(Vector2(0.0, -5.0), Vector2(0.0, 5.0), outline * Color(1, 1, 1, 0.35), 1.2, true)

	# ── 어깨 견장 ──
	outlined_circle(ci, Vector2(2.6, -6.4), 2.6, body_col.lightened(0.12), outline, 1.6)
	outlined_circle(ci, Vector2(2.6, 6.4), 2.6, body_col.lightened(0.12), outline, 1.6)

	# ── 헬멧 ──
	outlined_circle(ci, Vector2(3.8, 0.0), 6.0, body_col.lightened(0.06), outline, 2.4)
	# 바이저
	var vis := PackedVector2Array([
		Vector2(6.0, -3.2),
		Vector2(9.6, -1.8),
		Vector2(9.6, 1.8),
		Vector2(6.0, 3.2),
	])
	ci.draw_colored_polygon(vis, visor)
	ci.draw_polyline(PackedVector2Array([
		Vector2(6.0, -3.2), Vector2(9.6, -1.8),
		Vector2(9.6, 1.8), Vector2(6.0, 3.2),
	]), outline, 1.7, true)
	# 바이저 반사광
	ci.draw_line(Vector2(7.0, -2.2), Vector2(8.8, -1.4), Color(1, 1, 1, 0.45), 1.2, true)

	# 헬멧 안테나
	ci.draw_line(Vector2(0.5, -4.5), Vector2(-2.5, -9.5), outline, 1.6, true)
	ci.draw_circle(Vector2(-2.5, -9.5), 1.3, Color(1.0, 0.35, 0.3) if alerted else Color(0.4, 0.9, 0.5))

	# ── 손전등을 든 팔 ──
	var hand := Vector2(9.0, 4.6)
	outlined_capsule(ci, Vector2(3.0, 5.0), hand, 2.0, body_col.darkened(0.15), outline, 1.6)
	# 손전등 본체
	ci.draw_line(hand, hand + Vector2(6.0, -1.0), outline, 4.2, true)
	ci.draw_line(hand, hand + Vector2(6.0, -1.0), Color(0.24, 0.26, 0.32), 2.6, true)
	# 렌즈
	ci.draw_circle(hand + Vector2(6.2, -1.0), 1.9, Color(1.0, 0.95, 0.72))

	# ── 반대쪽 팔 ──
	outlined_capsule(ci, Vector2(3.0, -5.0), Vector2(7.0, -7.2 + sway2 * 0.5), 2.0, body_col.darkened(0.15), outline, 1.6)


# ═══════════════════════════════════════════════
#  쓰러진 적
# ═══════════════════════════════════════════════

static func draw_downed(ci: CanvasItem, body_col: Color, outline: Color) -> void:
	# 바닥에 누운 실루엣
	outlined_capsule(ci, Vector2(-6.0, 0.0), Vector2(5.0, 0.0), 5.2, body_col, outline, 1.8)
	outlined_circle(ci, Vector2(7.0, 0.0), 4.6, body_col.lightened(0.05), outline, 1.8)
	# X 눈
	var e1 := Vector2(8.0, -1.4)
	var e2 := Vector2(8.0, 1.4)
	ci.draw_line(e1 + Vector2(-1, -1), e1 + Vector2(1, 1), outline, 1.3, true)
	ci.draw_line(e1 + Vector2(-1, 1), e1 + Vector2(1, -1), outline, 1.3, true)
	ci.draw_line(e2 + Vector2(-1, -1), e2 + Vector2(1, 1), outline, 1.3, true)
	ci.draw_line(e2 + Vector2(-1, 1), e2 + Vector2(1, -1), outline, 1.3, true)


# ═══════════════════════════════════════════════
#  아이템 아이콘
# ═══════════════════════════════════════════════

static func draw_keycard(ci: CanvasItem, tint: Color, outline: Color) -> void:
	var r := Rect2(-7.0, -5.0, 14.0, 10.0)
	ci.draw_rect(r, tint, true)
	ci.draw_rect(r, outline, false, 1.8)
	# 칩
	ci.draw_rect(Rect2(-4.5, -2.5, 4.0, 5.0), outline * Color(1, 1, 1, 0.75), true)
	# 스트라이프
	ci.draw_line(Vector2(1.0, -3.0), Vector2(5.5, -3.0), outline, 1.2, true)
	ci.draw_line(Vector2(1.0, 0.0), Vector2(5.5, 0.0), outline, 1.2, true)
	ci.draw_line(Vector2(1.0, 3.0), Vector2(5.5, 3.0), outline, 1.2, true)


static func draw_intel(ci: CanvasItem, tint: Color, outline: Color, spin: float) -> void:
	# 회전하는 데이터 큐브
	var s: float = 6.5
	var c: float = cos(spin)
	var pts := PackedVector2Array([
		Vector2(0.0, -s),
		Vector2(s * c, -s * 0.45),
		Vector2(s * c, s * 0.45),
		Vector2(0.0, s),
		Vector2(-s * c, s * 0.45),
		Vector2(-s * c, -s * 0.45),
	])
	outlined_poly(ci, pts, tint, outline, 1.9)
	ci.draw_line(Vector2(0, -s), Vector2(0, s), outline * Color(1, 1, 1, 0.6), 1.2, true)


static func draw_ampoule(ci: CanvasItem, tint: Color, outline: Color) -> void:
	# 보너스 앰플
	var body := Rect2(-3.0, -6.0, 6.0, 10.0)
	ci.draw_rect(body, tint, true)
	ci.draw_rect(body, outline, false, 1.7)
	ci.draw_rect(Rect2(-1.6, -8.0, 3.2, 2.5), outline, true)
	ci.draw_line(Vector2(-3.0, -1.0), Vector2(3.0, -1.0), outline * Color(1, 1, 1, 0.5), 1.1, true)
