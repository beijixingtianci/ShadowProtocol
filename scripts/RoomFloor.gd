## RoomFloor — 방 바닥
## 32px 체크무늬 대신, 큼직한 콘크리트 슬래브 + 이음새로 실제 바닥처럼 보이게 한다.
## 방 타입 색은 바닥 전체를 물들이지 않고 테두리 띠와 모서리 마커로만 드러낸다.
extends Node2D

var box: Vector2 = Vector2(480, 352)
var base_color: Color = Color(0.47, 0.48, 0.50)
var accent_color: Color = Color(0.55, 0.55, 0.58)
var room_type: String = "TRANSIT"
var tile_size: float = 32.0

## 슬래브 한 변 = 타일 4개분
const SLAB: float = 128.0

var _font: Font = null


func _ready() -> void:
	_font = ThemeDB.fallback_font
	queue_redraw()


## 위치로부터 결정적인 0~1 난수 (슬래브마다 아주 미세한 명암 차)
func _hash01(ix: int, iy: int) -> float:
	var h: int = ix * 374761393 + iy * 668265263
	h = (h ^ (h >> 13)) * 1274126177
	h = h ^ (h >> 16)
	return float(absi(h) % 1000) / 1000.0


func _draw() -> void:
	var w: float = box.x
	var h: float = box.y

	# ── 바탕 ──
	draw_rect(Rect2(0, 0, w, h), base_color, true)

	# ── 콘크리트 슬래브: 큼직하게, 명암차는 아주 작게 ──
	var cols: int = int(ceil(w / SLAB))
	var rows: int = int(ceil(h / SLAB))
	for r in range(rows):
		for c in range(cols):
			var x: float = c * SLAB
			var y: float = r * SLAB
			var sw: float = minf(SLAB, w - x)
			var sh: float = minf(SLAB, h - y)
			# ±3% 이내의 미세한 밝기 차이만 준다
			var v: float = (_hash01(c, r) - 0.5) * 0.06
			var col := Color(
				clampf(base_color.r + v, 0.0, 1.0),
				clampf(base_color.g + v, 0.0, 1.0),
				clampf(base_color.b + v, 0.0, 1.0)
			)
			draw_rect(Rect2(x, y, sw, sh), col, true)

	# ── 슬래브 이음새 ──
	var seam := Color(0, 0, 0, 0.17)
	var seam_hi := Color(1, 1, 1, 0.045)
	for c in range(1, cols):
		var x2: float = c * SLAB
		draw_line(Vector2(x2, 0), Vector2(x2, h), seam, 1.6)
		draw_line(Vector2(x2 + 1.2, 0), Vector2(x2 + 1.2, h), seam_hi, 1.0)
	for r in range(1, rows):
		var y2: float = r * SLAB
		draw_line(Vector2(0, y2), Vector2(w, y2), seam, 1.6)
		draw_line(Vector2(0, y2 + 1.2), Vector2(w, y2 + 1.2), seam_hi, 1.0)

	# ── 바닥에 각인된 방 이름 ──
	if _font != null:
		var size: int = 40
		var tw: float = _font.get_string_size(room_type, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
		var pos := Vector2((w - tw) * 0.5, h * 0.5 + size * 0.34)
		draw_string(_font, pos, room_type, HORIZONTAL_ALIGNMENT_LEFT, -1, size,
			Color(0, 0, 0, 0.10))

	# ── 방 타입 색은 테두리 띠로만 ──
	var inset: float = 14.0
	var band := Rect2(inset, inset, w - inset * 2.0, h - inset * 2.0)
	draw_rect(band, Color(accent_color.r, accent_color.g, accent_color.b, 0.55), false, 2.6)

	# 안쪽 얇은 보조선
	draw_rect(Rect2(inset + 5.0, inset + 5.0, w - (inset + 5.0) * 2.0, h - (inset + 5.0) * 2.0),
		Color(0, 0, 0, 0.10), false, 1.0)

	# ── 모서리 마커 ──
	var m: float = 26.0
	var mc := Color(accent_color.r, accent_color.g, accent_color.b, 0.85)
	var pts := [
		[Vector2(inset, inset), Vector2(1, 0), Vector2(0, 1)],
		[Vector2(w - inset, inset), Vector2(-1, 0), Vector2(0, 1)],
		[Vector2(inset, h - inset), Vector2(1, 0), Vector2(0, -1)],
		[Vector2(w - inset, h - inset), Vector2(-1, 0), Vector2(0, -1)],
	]
	for p in pts:
		var o: Vector2 = p[0]
		draw_line(o, o + p[1] * m, mc, 3.0)
		draw_line(o, o + p[2] * m, mc, 3.0)

	# ── 바닥 경계 근처 어둡게 (벽에 닿는 느낌) ──
	draw_rect(Rect2(0, 0, w, h), Color(0, 0, 0, 0.20), false, 6.0)
