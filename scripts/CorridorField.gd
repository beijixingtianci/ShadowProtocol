## CorridorField — 모든 복도를 하나의 노드에서 타일 단위로 그린다.
## 구간별 사각형을 겹쳐 그리던 방식은 이음새와 테두리 음영이 중복돼
## 바닥이 조각난 것처럼 보였다. 여기서는 타일 집합을 받아 한 번에 칠한다.
extends Node2D

var tiles: Dictionary = {}      ## Vector2i → true
var tile_size: float = 32.0

const BASE := Color(0.430, 0.437, 0.450)
const SEAM := Color(0, 0, 0, 0.13)
const EDGE := Color(0, 0, 0, 0.30)


func _ready() -> void:
	queue_redraw()


func _hash01(ix: int, iy: int) -> float:
	var h: int = ix * 374761393 + iy * 668265263
	h = (h ^ (h >> 13)) * 1274126177
	h = h ^ (h >> 16)
	return float(absi(h) % 1000) / 1000.0


func _draw() -> void:
	var t: float = tile_size

	# ── 바닥: 3×3 타일 묶음 단위로 아주 미세한 명암차 ──
	for key in tiles.keys():
		var x: float = float(key.x) * t
		var y: float = float(key.y) * t
		var v: float = (_hash01(int(floor(key.x / 3.0)), int(floor(key.y / 3.0))) - 0.5) * 0.045
		draw_rect(Rect2(x, y, t, t),
			Color(BASE.r + v, BASE.g + v, BASE.b + v), true)

	# ── 이음새: 3타일마다 한 줄 (묶음 경계) ──
	for key in tiles.keys():
		var x2: float = float(key.x) * t
		var y2: float = float(key.y) * t
		if key.x % 3 == 0 and tiles.has(Vector2i(key.x - 1, key.y)):
			draw_line(Vector2(x2, y2), Vector2(x2, y2 + t), SEAM, 1.4)
		if key.y % 3 == 0 and tiles.has(Vector2i(key.x, key.y - 1)):
			draw_line(Vector2(x2, y2), Vector2(x2 + t, y2), SEAM, 1.4)

	# ── 바깥 경계선: 복도가 아닌 쪽에만 (벽에 닿는 면) ──
	for key in tiles.keys():
		var x3: float = float(key.x) * t
		var y3: float = float(key.y) * t
		if not tiles.has(Vector2i(key.x, key.y - 1)):
			draw_line(Vector2(x3, y3 + 1.0), Vector2(x3 + t, y3 + 1.0), EDGE, 2.4)
		if not tiles.has(Vector2i(key.x, key.y + 1)):
			draw_line(Vector2(x3, y3 + t - 1.0), Vector2(x3 + t, y3 + t - 1.0), EDGE, 2.4)
		if not tiles.has(Vector2i(key.x - 1, key.y)):
			draw_line(Vector2(x3 + 1.0, y3), Vector2(x3 + 1.0, y3 + t), EDGE, 2.4)
		if not tiles.has(Vector2i(key.x + 1, key.y)):
			draw_line(Vector2(x3 + t - 1.0, y3), Vector2(x3 + t - 1.0, y3 + t), EDGE, 2.4)
