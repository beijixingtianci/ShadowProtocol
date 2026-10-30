## Wall — 벽. 상단 하이라이트로 입체감 표현
extends StaticBody2D

var box: Vector2 = Vector2(32, 32)

## 벽 재질 — SoundSystem 의 소리 감쇠 계수에 쓰인다.
## 기본 벽은 "thick", proximity 공유벽은 LevelLoader 가 thin/glass/fence/vent_shaft/metal 로 지정
var wall_type: String = "thick"

const FACE := Color(0.035, 0.035, 0.045)
const TOP := Color(0.105, 0.108, 0.130)
const EDGE := Color(0.0, 0.0, 0.0)


func _ready() -> void:
	queue_redraw()


func _draw() -> void:
	var w: float = box.x
	var h: float = box.y
	var r := Rect2(-w * 0.5, -h * 0.5, w, h)

	# 본체
	draw_rect(r, FACE, true)

	# 상단 하이라이트 (빛이 위에서 온다는 가정)
	var lip: float = minf(4.0, h * 0.35)
	draw_rect(Rect2(r.position.x, r.position.y, w, lip), TOP, true)

	# 하단 어두운 경계
	draw_rect(Rect2(r.position.x, r.position.y + h - 2.0, w, 2.0), EDGE, true)
