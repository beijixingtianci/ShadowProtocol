## WallVariant — proximity 로 연결된 두 방 사이 벽면의 외형 (벽 위에 덧그림)
##   thin       조금 밝은 벽
##   glass      반투명 유리 (visual_leak 이 클수록 더 투명하게)
##   fence      철창
##   vent_shaft 환기구 그릴
##   metal      철판 (파이프라인 재질 metal)
## 충돌·차광은 원래 벽(Wall)이 그대로 담당한다.
extends Node2D

var box: Vector2 = Vector2(32, 32)
var wall_type: String = "thin"
var vertical: bool = true      ## 벽면이 세로로 이어지는가
var leak: float = 0.5          ## visual_leak


func _ready() -> void:
	queue_redraw()


func _draw() -> void:
	var r := Rect2(-box.x * 0.5, -box.y * 0.5, box.x, box.y)
	match wall_type:
		"thin":
			draw_rect(r, Color(0.16, 0.165, 0.19), true)
			draw_rect(r, Color(0, 0, 0, 0.6), false, 1.2)
		"glass":
			draw_rect(r, Color(0.36, 0.55, 0.64, 0.35 + leak * 0.35), true)
			draw_rect(r, Color(0.70, 0.88, 0.95, 0.55), false, 1.4)
			# 사선 반사광
			var n: int = int(maxf(box.x, box.y) / 40.0) + 1
			for i in range(n):
				var f: float = (float(i) + 0.35) / float(n)
				if vertical:
					var y: float = r.position.y + r.size.y * f
					draw_line(Vector2(r.position.x + 3.0, y + 6.0), Vector2(r.end.x - 3.0, y - 6.0),
						Color(1, 1, 1, 0.35), 1.4)
				else:
					var x: float = r.position.x + r.size.x * f
					draw_line(Vector2(x - 6.0, r.end.y - 3.0), Vector2(x + 6.0, r.position.y + 3.0),
						Color(1, 1, 1, 0.35), 1.4)
		"fence":
			draw_rect(r, Color(0.10, 0.11, 0.12), true)
			var step: float = 7.0
			if vertical:
				draw_line(Vector2(r.position.x + 3.0, r.position.y), Vector2(r.position.x + 3.0, r.end.y), Color(0.55, 0.57, 0.60), 1.6)
				draw_line(Vector2(r.end.x - 3.0, r.position.y), Vector2(r.end.x - 3.0, r.end.y), Color(0.55, 0.57, 0.60), 1.6)
				var y2: float = r.position.y + step * 0.5
				while y2 < r.end.y:
					draw_line(Vector2(r.position.x, y2), Vector2(r.end.x, y2), Color(0.62, 0.64, 0.68), 2.0)
					y2 += step
			else:
				draw_line(Vector2(r.position.x, r.position.y + 3.0), Vector2(r.end.x, r.position.y + 3.0), Color(0.55, 0.57, 0.60), 1.6)
				draw_line(Vector2(r.position.x, r.end.y - 3.0), Vector2(r.end.x, r.end.y - 3.0), Color(0.55, 0.57, 0.60), 1.6)
				var x2: float = r.position.x + step * 0.5
				while x2 < r.end.x:
					draw_line(Vector2(x2, r.position.y), Vector2(x2, r.end.y), Color(0.62, 0.64, 0.68), 2.0)
					x2 += step
		"metal":
			# 철판 — 리벳 박힌 금속판
			draw_rect(r, Color(0.24, 0.26, 0.29), true)
			draw_rect(r, Color(0, 0, 0, 0.7), false, 1.2)
			var span: float = r.size.y if vertical else r.size.x
			var k: int = int(span / 16.0)
			for i3 in range(k):
				var f3: float = (float(i3) + 0.5) * 16.0
				var rv: Vector2 = Vector2(0.0, r.position.y + f3) if vertical else Vector2(r.position.x + f3, 0.0)
				draw_circle(rv, 1.8, Color(0.55, 0.58, 0.62))
		"vent_shaft":
			# 벽 한가운데 환기구 그릴 하나
			draw_rect(r, Color(0.08, 0.085, 0.10), true)
			var c: Vector2 = Vector2.ZERO
			var g := Rect2(c.x - 12.0, c.y - 12.0, 24.0, 24.0)
			if vertical:
				g = Rect2(c.x - 11.0, c.y - 16.0, 22.0, 32.0)
			else:
				g = Rect2(c.x - 16.0, c.y - 11.0, 32.0, 22.0)
			draw_rect(g, Color(0.35, 0.38, 0.42), true)
			for i2 in range(1, 5):
				if vertical:
					var yy: float = g.position.y + g.size.y * float(i2) / 5.0
					draw_line(Vector2(g.position.x + 2.0, yy), Vector2(g.end.x - 2.0, yy), Color(0.10, 0.11, 0.13), 2.0)
				else:
					var xx: float = g.position.x + g.size.x * float(i2) / 5.0
					draw_line(Vector2(xx, g.position.y + 2.0), Vector2(xx, g.end.y - 2.0), Color(0.10, 0.11, 0.13), 2.0)
			draw_rect(g, Color(0, 0, 0), false, 1.2)
