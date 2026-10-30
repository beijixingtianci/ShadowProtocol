## Item — 키카드 / 정보 / 보너스 앰플
extends Node2D

var item_kind: String = "key"
var key_id: String = ""
var collected: bool = false

const OUTLINE := Color(0.05, 0.06, 0.09)

var _base_y: float = 0.0
var _t: float = 0.0
var _tint: Color = Color.WHITE


func _ready() -> void:
	add_to_group("items")
	_base_y = position.y

	if item_kind == "key":
		_tint = Color(0.98, 0.80, 0.22)
	elif item_kind == "objective":
		_tint = Color(0.28, 0.88, 0.85)
	else:
		_tint = Color(0.55, 0.90, 0.38)

	var glow: PointLight2D = get_node_or_null("Glow")
	if glow != null:
		glow.color = _tint


func _process(delta: float) -> void:
	if collected:
		return
	_t += delta
	position.y = _base_y + sin(_t * 2.1) * 3.4

	var glow: PointLight2D = get_node_or_null("Glow")
	if glow != null:
		glow.energy = 0.5 + sin(_t * 3.0) * 0.16

	queue_redraw()


func _draw() -> void:
	if collected:
		return

	# 바닥 그림자 (부유 높이에 따라 크기 변화)
	var lift: float = position.y - _base_y
	draw_set_transform(Vector2(0, 10.0 - lift), 0.0, Vector2(1.0, 0.45))
	draw_circle(Vector2.ZERO, 7.5 - lift * 0.2, Color(0, 0, 0, 0.26))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

	if item_kind == "key":
		CharArt.draw_keycard(self, _tint, OUTLINE)
	elif item_kind == "objective":
		CharArt.draw_intel(self, _tint, OUTLINE, _t * 1.6)
	else:
		CharArt.draw_ampoule(self, _tint, OUTLINE)

	# 회전하는 수집 링
	var ring_a: float = 0.25 + sin(_t * 3.0) * 0.12
	draw_arc(Vector2.ZERO, 14.0, _t * 1.4, _t * 1.4 + PI * 1.3, 20,
		Color(_tint.r, _tint.g, _tint.b, ring_a), 1.5, true)


func interact() -> void:
	if collected:
		return
	collected = true

	if item_kind == "key":
		GameState.collect_key(key_id)
	elif item_kind == "objective":
		GameState.collect_objective()
	else:
		GameState.kill_charges += 1
		GameState.post_message("암살 기회 +1", Color(0.55, 0.9, 0.3))

	var solid: StaticBody2D = get_node_or_null("Solid")
	if solid != null:
		solid.collision_layer = 0

	var parent := get_parent()
	if parent != null:
		parent.add_child(VisualKit.burst(position, _tint, 16, 130.0))

	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(self, "scale", Vector2(1.8, 1.8), 0.22)
	tw.tween_property(self, "modulate:a", 0.0, 0.22)
	tw.chain().tween_callback(queue_free)
