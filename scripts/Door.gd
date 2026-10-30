## Door — 잠금문. 복도 폭 전체를 막는다.
extends StaticBody2D

var key_id: String = ""
var is_open: bool = false
## 잠금 여부 — 키 id 가 있는 문은 잠긴 채로 시작한다 (현재 생성되는 문은 모두 잠금문)
var is_locked: bool = true
var horizontal_block: bool = true
var span: float = 96.0

const OUTLINE := Color(0.05, 0.06, 0.09)
const LOCKED := Color(0.62, 0.26, 0.10)
const OPENED := Color(0.22, 0.48, 0.42)
const THICK: float = 20.0

## 소음 반경 (px)
const NOISE_OPEN: float = 140.0     ## 잠기지 않은 문 열림
const NOISE_UNLOCK: float = 200.0   ## 잠금문 해제 (은신 중이면 둘 다 0)

var _t: float = 0.0


func _ready() -> void:
	add_to_group("doors")
	is_locked = key_id != ""


func _process(delta: float) -> void:
	_t += delta
	if not is_open:
		var lamp: PointLight2D = get_node_or_null("Lamp")
		if lamp != null:
			lamp.energy = 1.0 + sin(_t * 4.0) * 0.45
	queue_redraw()


func _box() -> Vector2:
	if horizontal_block:
		return Vector2(span, THICK)
	return Vector2(THICK, span)


func _draw() -> void:
	var b: Vector2 = _box()
	var col: Color = OPENED if is_open else LOCKED

	if is_open:
		# 열린 문 — 양쪽 벽으로 후퇴한 모습
		var stub: float = 0.18
		if horizontal_block:
			draw_rect(Rect2(-b.x * 0.5, -b.y * 0.5, b.x * stub, b.y), col, true)
			draw_rect(Rect2(b.x * 0.5 - b.x * stub, -b.y * 0.5, b.x * stub, b.y), col, true)
			draw_rect(Rect2(-b.x * 0.5, -b.y * 0.5, b.x * stub, b.y), OUTLINE, false, 1.6)
			draw_rect(Rect2(b.x * 0.5 - b.x * stub, -b.y * 0.5, b.x * stub, b.y), OUTLINE, false, 1.6)
		else:
			draw_rect(Rect2(-b.x * 0.5, -b.y * 0.5, b.x, b.y * stub), col, true)
			draw_rect(Rect2(-b.x * 0.5, b.y * 0.5 - b.y * stub, b.x, b.y * stub), col, true)
			draw_rect(Rect2(-b.x * 0.5, -b.y * 0.5, b.x, b.y * stub), OUTLINE, false, 1.6)
			draw_rect(Rect2(-b.x * 0.5, b.y * 0.5 - b.y * stub, b.x, b.y * stub), OUTLINE, false, 1.6)
		return

	# 닫힌 문
	var r := Rect2(-b.x * 0.5, -b.y * 0.5, b.x, b.y)
	draw_rect(r, col, true)
	draw_rect(r, OUTLINE, false, 2.2)

	# 중앙 분할선
	if horizontal_block:
		draw_line(Vector2(0, -b.y * 0.5), Vector2(0, b.y * 0.5), OUTLINE, 1.8, true)
	else:
		draw_line(Vector2(-b.x * 0.5, 0), Vector2(b.x * 0.5, 0), OUTLINE, 1.8, true)

	# 경고 스트라이프
	var stripe := Color(0.95, 0.78, 0.22, 0.70)
	var count: int = 6
	if horizontal_block:
		for i in range(count):
			var x: float = -b.x * 0.5 + 6.0 + i * (b.x - 12.0) / float(count - 1)
			draw_line(Vector2(x - 4, -b.y * 0.5 + 2), Vector2(x + 4, b.y * 0.5 - 2), stripe, 2.4, true)
	else:
		for i in range(count):
			var y: float = -b.y * 0.5 + 6.0 + i * (b.y - 12.0) / float(count - 1)
			draw_line(Vector2(-b.x * 0.5 + 2, y - 4), Vector2(b.x * 0.5 - 2, y + 4), stripe, 2.4, true)

	# 잠금 표시등
	var pulse: float = 0.55 + sin(_t * 4.0) * 0.45
	draw_circle(Vector2.ZERO, 5.0, Color(1.0, 0.45, 0.18, pulse))
	draw_arc(Vector2.ZERO, 5.0, 0, TAU, 16, OUTLINE, 1.6, true)

	# 키 이름
	var font := ThemeDB.fallback_font
	if font != null:
		var tw: float = font.get_string_size(key_id, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x
		var off := Vector2(-tw * 0.5, -b.y * 0.5 - 8.0)
		if not horizontal_block:
			off = Vector2(-tw * 0.5, -b.y * 0.5 - 8.0)
		draw_string(font, off, key_id, HORIZONTAL_ALIGNMENT_LEFT, -1, 12,
			Color(1.0, 0.72, 0.35, 0.9))


func interact() -> void:
	if is_open:
		return

	# 은신(Ctrl) 중이면 소리 없이 연다
	var player = get_tree().get_first_node_in_group("player")
	var sneaking: bool = player != null and player.get("is_hiding") == true

	if is_locked:
		if not GameState.has_key(key_id):
			# 키 이름이 들어가므로 %s 템플릿으로 번역한 뒤 끼워 넣는다 (GameState.collect_key 와 같은 방식)
			GameState.post_message(Settings.tr_ko("%s 키가 필요합니다") % key_id, Color(1, 0.35, 0.35))
			return
		is_locked = false
		if sneaking:
			GameState.post_message(Settings.tr_ko("%s 조용히 잠금 해제") % key_id, Color(0.5, 0.85, 0.7))
		else:
			SoundSystem.emit_noise(global_position, NOISE_UNLOCK)
			GameState.post_message(Settings.tr_ko("%s 문 해제") % key_id, Color(0.35, 0.8, 0.7))
	elif not sneaking:
		SoundSystem.emit_noise(global_position, NOISE_OPEN)

	_open()


## 문을 연 상태로 바꾼다. "open_doors" 그룹에 넣어 경비병이 열린 문을 알아챌 수 있게 한다.
func _open() -> void:
	is_open = true
	add_to_group("open_doors")

	var col: CollisionShape2D = get_node_or_null("Col")
	if col != null:
		col.set_deferred("disabled", true)

	var occ: LightOccluder2D = get_node_or_null("Occ")
	if occ != null:
		occ.visible = false

	var lamp: PointLight2D = get_node_or_null("Lamp")
	if lamp != null:
		lamp.color = Color(0.35, 0.9, 0.75)
		lamp.energy = 0.8

	var parent := get_parent()
	if parent != null:
		parent.add_child(VisualKit.burst(position, Color(0.4, 0.9, 0.8), 18, 150.0))
