## Cover — 엄폐물 (금속 상자). 시선 차단 + 은신 지점
extends StaticBody2D

const BODY := Color(0.255, 0.268, 0.278)
const TOP := Color(0.355, 0.370, 0.382)
const EDGE := Color(0.075, 0.080, 0.090)
const BAND := Color(0.72, 0.60, 0.20, 0.55)

const S: float = 28.0


func _ready() -> void:
	add_to_group("covers")
	queue_redraw()


func _draw() -> void:
	var r := Rect2(-S * 0.5, -S * 0.5, S, S)

	# 바닥 그림자
	draw_rect(Rect2(-S * 0.5 + 2.5, -S * 0.5 + 3.5, S, S), Color(0, 0, 0, 0.26), true)

	# 몸체
	draw_rect(r, BODY, true)
	# 윗면 하이라이트
	draw_rect(Rect2(r.position.x, r.position.y, S, 6.0), TOP, true)
	# 외곽선
	draw_rect(r, EDGE, false, 2.0)

	# 보강 리브
	draw_line(Vector2(-S * 0.5 + 4, -S * 0.5 + 9), Vector2(S * 0.5 - 4, -S * 0.5 + 9),
		Color(0, 0, 0, 0.30), 1.4)
	draw_line(Vector2(-S * 0.5 + 4, S * 0.5 - 6), Vector2(S * 0.5 - 4, S * 0.5 - 6),
		Color(0, 0, 0, 0.30), 1.4)
	# 노란 표식 띠
	draw_line(Vector2(-S * 0.5 + 4, S * 0.5 - 2.5), Vector2(S * 0.5 - 4, S * 0.5 - 2.5),
		BAND, 2.0)
