## SoundSystem — 소음 전파 + 벽 감쇠 (Autoload)
##
## 소음은 발생 지점을 중심으로 한 원이다. 발생 지점과 적 사이에 벽이 있으면
## 그 방향의 유효 반경이 재질별 계수만큼 줄어든다.
##   Player(걷기 90 / 달리기 280 / 암살 120), Door(해제 200) 등이 emit_noise 를 부른다.
##
## F3: 디버그 표시 토글 (소음 원 + 들은 적까지의 선)
extends Node

## 벽 몇 겹까지 따질지
const MAX_WALLS: int = 4

## 같은 벽을 이루는 인접 콜리전(행 단위로 쪼개진 벽 등)을 한 겹으로 보는 거리
const SAME_WALL_DIST: float = 40.0

var debug_draw: bool = false


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F3:
		debug_draw = not debug_draw
		print("[SoundSystem] 디버그 표시 ", "ON" if debug_draw else "OFF")


## Player, Door 등이 소리를 낼 때 호출한다.
## radius: 기본 전파 거리(px). 벽 감쇠 후 반경 안에 있는 적은 hear_noise 를 받는다.
func emit_noise(source_pos: Vector2, radius: float) -> void:
	if radius <= 0.0:
		return
	var heard: Array = []
	for enemy in get_tree().get_nodes_in_group("enemies"):
		if not is_instance_valid(enemy) or not enemy.alive:
			continue
		var dist: float = source_pos.distance_to(enemy.global_position)
		# 감쇠는 반경을 줄이기만 하므로, 기본 반경 밖이면 레이캐스트할 필요가 없다
		if dist > radius:
			continue

		var effective_radius: float = _attenuate(source_pos, enemy.global_position, radius)
		if effective_radius > 0.0 and dist <= effective_radius:
			enemy.hear_noise(source_pos, clampf(1.0 - dist / effective_radius, 0.0, 1.0))
			heard.append(enemy.global_position)

	if debug_draw:
		_debug_ring(source_pos, radius, heard)


## 발생 지점 → 청자 방향으로 레이를 쏘아, 벽을 하나 지날 때마다 재질 계수를 곱한다.
func _attenuate(source: Vector2, listener: Vector2, radius: float) -> float:
	var vp := get_viewport()
	if vp == null:
		return radius
	var space := vp.get_world_2d().direct_space_state
	var r: float = radius

	var exclude: Array[RID] = []
	var last_hit := Vector2.INF
	var last_factor: float = 1.0

	for i in range(MAX_WALLS * 3):
		var query := PhysicsRayQueryParameters2D.create(source, listener, 1, exclude)
		var hit: Dictionary = space.intersect_ray(query)
		if hit.is_empty():
			break
		exclude.append(hit["rid"])

		var factor: float = _get_wall_factor(hit.get("collider"))
		var pos: Vector2 = hit["position"]
		if last_hit != Vector2.INF and pos.distance_to(last_hit) < SAME_WALL_DIST:
			# 같은 벽의 다른 조각 — 더 강한 차음 쪽만 반영
			if factor < last_factor:
				r = r / last_factor * factor
				last_factor = factor
		else:
			r *= factor
			last_factor = factor
		last_hit = pos
		if r < 1.0:
			return 0.0
	return r


## 벽·물체의 소리 투과 계수. 0.0 = 완전 차단, 1.0 = 감쇠 없음.
func _get_wall_factor(collider) -> float:
	if collider == null or not (collider is Node):
		return 1.0
	var node: Node = collider

	# proximity 로 재질이 정해진 벽 (Wall.wall_type)
	var wt = node.get("wall_type")
	if wt != null:
		match str(wt):
			"thick":
				return 0.20    # 기본 벽 / 콘크리트
			"thin":
				return 0.50    # 석고보드
			"glass":
				return 0.35    # 유리
			"fence":
				return 0.85    # 철망
			"vent_shaft":
				return 0.65    # 환기구
			"metal":
				return 0.40    # 철판

	if node.is_in_group("covers"):
		return 0.70        # 상자·가구
	if node.is_in_group("doors"):
		return 0.60 if node.get("is_open") == true else 0.40

	return 0.20            # 그 밖의 단단한 벽


func _debug_ring(pos: Vector2, radius: float, heard: Array) -> void:
	var scene := get_tree().current_scene
	if scene == null:
		return
	var root := Node2D.new()
	root.z_index = 30
	scene.add_child(root)

	var ring := Line2D.new()
	ring.width = 2.0
	ring.default_color = Color(1.0, 0.85, 0.3, 0.6)
	var seg: int = 48
	for i in range(seg + 1):
		var a: float = TAU * float(i) / float(seg)
		ring.add_point(pos + Vector2(cos(a), sin(a)) * radius)
	root.add_child(ring)

	for hp in heard:
		var ln := Line2D.new()
		ln.width = 2.0
		ln.default_color = Color(0.4, 0.9, 1.0, 0.8)
		ln.add_point(pos)
		ln.add_point(hp)
		root.add_child(ln)

	var tw := root.create_tween()
	tw.tween_property(root, "modulate:a", 0.0, 0.6)
	tw.tween_callback(root.queue_free)
