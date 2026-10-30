## SafeZoneRing — 안전 구역 바닥 표시. ExitMarker 의 링과 비슷하지만 느리고 차분하게.
extends Node2D

var radius: float = 120.0

const COL := Color(0.30, 0.85, 0.80)

var _t: float = 0.0


func _process(delta: float) -> void:
	_t += delta
	queue_redraw()


func _draw() -> void:
	var breathe: float = 0.5 + sin(_t * 1.1) * 0.5

	# 옅은 바닥 채움
	draw_circle(Vector2.ZERO, radius, Color(COL.r, COL.g, COL.b, 0.035 + breathe * 0.025))

	# 바깥 링
	draw_arc(Vector2.ZERO, radius, 0, TAU, 64, Color(COL.r, COL.g, COL.b, 0.30 + breathe * 0.12), 2.4, true)

	# 천천히 도는 점선 안쪽 링
	var seg: int = 12
	var inner: float = radius * 0.86
	for i in range(seg):
		var a0: float = _t * 0.25 + TAU * float(i) / float(seg)
		draw_arc(Vector2.ZERO, inner, a0, a0 + TAU / float(seg) * 0.5, 8,
			Color(COL.r, COL.g, COL.b, 0.22), 1.6, true)
