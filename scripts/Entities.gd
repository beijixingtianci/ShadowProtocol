## Entities.gd — 게임 오브젝트 생성 팩토리
## 외형은 각 스크립트의 _draw() 가 담당 (ColorRect 대신 벡터 드로잉)
extends Node
class_name Entities


static func make_player() -> CharacterBody2D:
	var p := CharacterBody2D.new()
	p.name = "Player"
	p.collision_layer = 2
	p.collision_mask = 1
	p.z_index = 12
	p.set_script(load("res://scripts/Player.gd"))

	var shape := CollisionShape2D.new()
	var circle := CircleShape2D.new()
	circle.radius = 9.0
	shape.shape = circle
	p.add_child(shape)

	var glow := PointLight2D.new()
	glow.name = "Glow"
	glow.texture = VisualKit.radial_light_texture(0.35)
	glow.texture_scale = 1.6
	glow.energy = 0.32
	glow.color = Color(0.62, 0.92, 0.95)
	glow.shadow_enabled = true
	glow.shadow_filter = Light2D.SHADOW_FILTER_PCF13
	glow.shadow_filter_smooth = 8.0
	glow.shadow_color = Color(0, 0, 0, 0.8)
	glow.blend_mode = Light2D.BLEND_MODE_ADD
	p.add_child(glow)

	var cam := Camera2D.new()
	cam.name = "Cam"
	cam.zoom = Vector2(1.55, 1.55)
	cam.position_smoothing_enabled = true
	cam.position_smoothing_speed = 7.0
	p.add_child(cam)

	var cover_area := Area2D.new()
	cover_area.name = "CoverDet"
	cover_area.collision_layer = 0
	cover_area.collision_mask = 1
	var ca_shape := CollisionShape2D.new()
	var ca_circle := CircleShape2D.new()
	ca_circle.radius = 44.0
	ca_shape.shape = ca_circle
	cover_area.add_child(ca_shape)
	p.add_child(cover_area)

	var inter := Area2D.new()
	inter.name = "InterDet"
	inter.collision_layer = 0
	inter.collision_mask = 1 | 8
	var in_shape := CollisionShape2D.new()
	var in_circle := CircleShape2D.new()
	in_circle.radius = 64.0
	in_shape.shape = in_circle
	inter.add_child(in_shape)
	p.add_child(inter)

	return p


static func make_enemy(params: Dictionary) -> CharacterBody2D:
	var e := CharacterBody2D.new()
	e.collision_layer = 4
	e.collision_mask = 1
	e.z_index = 10
	e.set_script(load("res://scripts/Enemy.gd"))

	var cone := Polygon2D.new()
	cone.name = "Cone"
	cone.z_index = -2
	e.add_child(cone)

	var shape := CollisionShape2D.new()
	var circle := CircleShape2D.new()
	circle.radius = 9.0
	shape.shape = circle
	e.add_child(shape)

	e.set("cfg", params)
	return e


static func make_item(kind: String, key_id: String) -> Node2D:
	var it := Node2D.new()
	it.z_index = 6
	it.set_script(load("res://scripts/Item.gd"))
	it.set("item_kind", kind)
	it.set("key_id", key_id)

	var light := PointLight2D.new()
	light.name = "Glow"
	light.texture = VisualKit.radial_light_texture(0.3)
	light.texture_scale = 0.7
	light.energy = 0.55
	light.blend_mode = Light2D.BLEND_MODE_ADD
	it.add_child(light)

	var solid := StaticBody2D.new()
	solid.name = "Solid"
	solid.collision_layer = 8
	solid.collision_mask = 0
	var shape := CollisionShape2D.new()
	var circle := CircleShape2D.new()
	circle.radius = 15.0
	shape.shape = circle
	solid.add_child(shape)
	it.add_child(solid)

	return it


static func make_door(key_id: String, horizontal_block: bool = true,
		span: float = 96.0) -> StaticBody2D:
	var d := StaticBody2D.new()
	d.collision_layer = 1
	d.collision_mask = 0
	d.z_index = 8
	d.set_script(load("res://scripts/Door.gd"))
	d.set("key_id", key_id)
	d.set("horizontal_block", horizontal_block)
	d.set("span", span)

	var thickness: float = 20.0
	var box: Vector2
	if horizontal_block:
		box = Vector2(span, thickness)
	else:
		box = Vector2(thickness, span)

	var shape := CollisionShape2D.new()
	shape.name = "Col"
	var rect := RectangleShape2D.new()
	rect.size = box
	shape.shape = rect
	d.add_child(shape)

	var occ := VisualKit.make_occluder(box.x, box.y)
	occ.name = "Occ"
	d.add_child(occ)

	var light := PointLight2D.new()
	light.name = "Lamp"
	light.texture = VisualKit.radial_light_texture(0.3)
	light.texture_scale = 0.5
	light.energy = 1.3
	light.color = Color(1.0, 0.45, 0.15)
	light.blend_mode = Light2D.BLEND_MODE_ADD
	d.add_child(light)

	return d


static func make_cover() -> StaticBody2D:
	var c := StaticBody2D.new()
	c.collision_layer = 1
	c.collision_mask = 0
	c.z_index = 7
	c.set_script(load("res://scripts/Cover.gd"))

	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(28, 28)
	shape.shape = rect
	c.add_child(shape)

	var occ := VisualKit.make_occluder(28, 28)
	c.add_child(occ)

	return c


static func make_wall(x: float, y: float, w: float, h: float) -> StaticBody2D:
	var wall := StaticBody2D.new()
	wall.position = Vector2(x + w * 0.5, y + h * 0.5)
	wall.collision_layer = 1
	wall.collision_mask = 0
	wall.z_index = 5
	wall.set_script(load("res://scripts/Wall.gd"))
	wall.set("box", Vector2(w, h))

	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(w, h)
	shape.shape = rect
	wall.add_child(shape)

	var occ := VisualKit.make_occluder(w, h)
	wall.add_child(occ)

	return wall


## proximity 벽 외형 (glass / thin / fence / vent_shaft).
## 기존 벽 위에 덧그리는 장식이라 충돌·차광체는 없다.
static func make_wall_variant(wall_type: String, rect: Rect2, vertical: bool, leak: float) -> Node2D:
	var v := Node2D.new()
	v.position = rect.position + rect.size * 0.5
	v.z_index = 6
	v.set_script(load("res://scripts/WallVariant.gd"))
	v.set("box", rect.size)
	v.set("wall_type", wall_type)
	v.set("vertical", vertical)
	v.set("leak", leak)
	return v
