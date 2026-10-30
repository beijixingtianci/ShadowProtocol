## CorridorDecor — v1 복도 장식
##   mode "style": traversal_type 별 복도 외형을 CorridorField 위에 덧그린다
##     vent              금속색 + 환기 그릴
##     climb             사다리 (레일 + 가로대)
##     hack              복도 입구의 단말기 아이콘 (glyphs)
##     stealth_required  어둡게
##     takedown_required 붉은 기
##   mode "cover": 숨은 통로를 벽과 같은 색으로 덮는다 (발견 시 LevelLoader 가 걷어냄)
extends Node2D

var mode: String = "style"
var tiles: Dictionary = {}      ## Vector2i → traversal_type (style) / true (cover)
var glyphs: Array = []          ## [{tile: Vector2i, kind: "hack"}]
var tile_size: float = 32.0

const VENT := Color(0.35, 0.38, 0.42)
const VENT_SLAT := Color(0.12, 0.13, 0.15, 0.75)
const TAKEDOWN := Color(0.45, 0.28, 0.28)
const LADDER := Color(0.66, 0.58, 0.36, 0.85)
const COVER := Color(0.035, 0.035, 0.045)


func _ready() -> void:
	queue_redraw()


func _same(key: Vector2i, d: Vector2i) -> bool:
	return tiles.has(key + d) and tiles[key + d] == tiles[key]


## 같은 종류 타일이 좌우로 이어지면 가로 방향 복도
func _is_horizontal(key: Vector2i) -> bool:
	var hx: int = int(_same(key, Vector2i(1, 0))) + int(_same(key, Vector2i(-1, 0)))
	var vy: int = int(_same(key, Vector2i(0, 1))) + int(_same(key, Vector2i(0, -1)))
	return hx >= vy


func _draw() -> void:
	var t: float = tile_size

	if mode == "cover":
		for key in tiles.keys():
			draw_rect(Rect2(float(key.x) * t, float(key.y) * t, t, t), COVER, true)
		return

	for key in tiles.keys():
		var x: float = float(key.x) * t
		var y: float = float(key.y) * t
		var r := Rect2(x, y, t, t)
		match str(tiles[key]):
			"vent":
				draw_rect(r, VENT, true)
				# 복도 방향과 수직인 슬랫
				var horiz: bool = _is_horizontal(key)
				for i in range(1, 5):
					var o: float = t * float(i) / 5.0
					if horiz:
						draw_line(Vector2(x + o, y + 3.0), Vector2(x + o, y + t - 3.0), VENT_SLAT, 1.6)
					else:
						draw_line(Vector2(x + 3.0, y + o), Vector2(x + t - 3.0, y + o), VENT_SLAT, 1.6)
			"takedown_required":
				draw_rect(r, TAKEDOWN, true)
			"stealth_required":
				draw_rect(r, Color(0, 0, 0, 0.28), true)
			"climb":
				_draw_ladder(key, x, y, t)

	for g in glyphs:
		if str(g.get("kind", "")) == "hack":
			var tile: Vector2i = g["tile"]
			_draw_terminal(Vector2((float(tile.x) + 0.5) * t, (float(tile.y) + 0.5) * t))


## 사다리: 복도 바깥 경계에는 레일, 복도를 가로질러 가로대
func _draw_ladder(key: Vector2i, x: float, y: float, t: float) -> void:
	var horiz: bool = _is_horizontal(key)
	if horiz:
		for i in range(2):
			var rx: float = x + t * (0.25 + 0.5 * i)
			draw_line(Vector2(rx, y), Vector2(rx, y + t), LADDER, 2.2)
		if not _same(key, Vector2i(0, -1)):
			draw_line(Vector2(x, y + 3.0), Vector2(x + t, y + 3.0), LADDER, 2.6)
		if not _same(key, Vector2i(0, 1)):
			draw_line(Vector2(x, y + t - 3.0), Vector2(x + t, y + t - 3.0), LADDER, 2.6)
	else:
		for i2 in range(2):
			var ry: float = y + t * (0.25 + 0.5 * i2)
			draw_line(Vector2(x, ry), Vector2(x + t, ry), LADDER, 2.2)
		if not _same(key, Vector2i(-1, 0)):
			draw_line(Vector2(x + 3.0, y), Vector2(x + 3.0, y + t), LADDER, 2.6)
		if not _same(key, Vector2i(1, 0)):
			draw_line(Vector2(x + t - 3.0, y), Vector2(x + t - 3.0, y + t), LADDER, 2.6)


## 작은 단말기 화면 아이콘
func _draw_terminal(c: Vector2) -> void:
	var bezel := Rect2(c.x - 10.0, c.y - 8.0, 20.0, 14.0)
	draw_rect(bezel, Color(0.07, 0.08, 0.10), true)
	draw_rect(Rect2(c.x - 8.0, c.y - 6.0, 16.0, 10.0), Color(0.20, 0.85, 0.55, 0.85), true)
	draw_line(Vector2(c.x - 6.0, c.y - 3.0), Vector2(c.x + 3.0, c.y - 3.0), Color(0.05, 0.25, 0.15), 1.2)
	draw_line(Vector2(c.x - 6.0, c.y), Vector2(c.x + 5.0, c.y), Color(0.05, 0.25, 0.15), 1.2)
	draw_rect(Rect2(c.x - 3.0, c.y + 6.0, 6.0, 3.0), Color(0.07, 0.08, 0.10), true)
	draw_rect(bezel, Color(0, 0, 0), false, 1.2)
