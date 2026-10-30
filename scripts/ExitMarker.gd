## ExitMarker — 탈출 지점 표시
extends Node2D

var _t: float = 0.0


func _process(delta: float) -> void:
	_t += delta


func _draw() -> void:
	var ready_state: bool = GameState.all_objectives_done()
	var col := Color(0.35, 0.95, 0.82) if ready_state else Color(0.45, 0.48, 0.55)
	var pulse: float = 0.5 + sin(_t * 2.6) * 0.5

	# 확산 링
	if ready_state:
		for i in range(3):
			var phase: float = fposmod(_t * 0.55 + i * 0.33, 1.0)
			var r: float = 26.0 + phase * 46.0
			var a: float = (1.0 - phase) * 0.35
			draw_arc(Vector2.ZERO, r, 0, TAU, 32, Color(col.r, col.g, col.b, a), 2.2, true)

	# 착륙 패드
	draw_circle(Vector2.ZERO, 30.0, Color(col.r, col.g, col.b, 0.10 + pulse * 0.08))
	draw_arc(Vector2.ZERO, 30.0, 0, TAU, 40, Color(col.r, col.g, col.b, 0.55), 2.4, true)
	draw_arc(Vector2.ZERO, 21.0, _t * 0.9, _t * 0.9 + PI * 1.4, 26,
		Color(col.r, col.g, col.b, 0.42), 1.8, true)

	# 화살표
	var up := PackedVector2Array([
		Vector2(0, -13), Vector2(8, -2), Vector2(3, -2),
		Vector2(3, 10), Vector2(-3, 10), Vector2(-3, -2), Vector2(-8, -2),
	])
	draw_colored_polygon(up, Color(col.r, col.g, col.b, 0.75))

	# 라벨
	var font := ThemeDB.fallback_font
	if font != null:
		var txt := "EXIT" if ready_state else "LOCKED"
		var tw: float = font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 15).x
		draw_string(font, Vector2(-tw * 0.5, -40), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 15,
			Color(col.r, col.g, col.b, 0.9))
