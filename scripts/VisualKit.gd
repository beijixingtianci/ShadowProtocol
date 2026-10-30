## VisualKit.gd — 조명·그림자·파티클·셰이더 생성 유틸
extends Node
class_name VisualKit


## 방사형 그라디언트 텍스처 (PointLight2D 용)
static func radial_light_texture(softness: float = 0.55) -> GradientTexture2D:
	var grad := Gradient.new()
	grad.offsets = PackedFloat32Array([0.0, softness, 1.0])
	grad.colors = PackedColorArray([
		Color(1, 1, 1, 1),
		Color(1, 1, 1, 0.55),
		Color(1, 1, 1, 0),
	])

	var tex := GradientTexture2D.new()
	tex.gradient = grad
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(1.0, 0.5)
	tex.width = 256
	tex.height = 256
	return tex


## 부채꼴 시야 텍스처 (플레이어 손전등 용)
static func cone_light_texture() -> GradientTexture2D:
	var grad := Gradient.new()
	grad.offsets = PackedFloat32Array([0.0, 0.35, 1.0])
	grad.colors = PackedColorArray([
		Color(1, 1, 1, 0.95),
		Color(1, 1, 1, 0.45),
		Color(1, 1, 1, 0.0),
	])
	var tex := GradientTexture2D.new()
	tex.gradient = grad
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(1.0, 0.5)
	tex.width = 256
	tex.height = 256
	return tex


## 사각형 그림자 차단체
static func make_occluder(w: float, h: float) -> LightOccluder2D:
	var occ := LightOccluder2D.new()
	var poly := OccluderPolygon2D.new()
	poly.polygon = PackedVector2Array([
		Vector2(-w * 0.5, -h * 0.5),
		Vector2(w * 0.5, -h * 0.5),
		Vector2(w * 0.5, h * 0.5),
		Vector2(-w * 0.5, h * 0.5),
	])
	poly.closed = true
	occ.occluder = poly
	return occ


## 방 조명
static func make_room_light(radius: float, energy: float, tint: Color) -> PointLight2D:
	var light := PointLight2D.new()
	light.texture = radial_light_texture(0.5)
	light.texture_scale = radius / 128.0
	light.energy = energy
	light.color = tint
	light.shadow_enabled = true
	light.shadow_filter = Light2D.SHADOW_FILTER_PCF13
	light.shadow_filter_smooth = 6.0
	light.shadow_color = Color(0, 0, 0, 0.72)
	light.blend_mode = Light2D.BLEND_MODE_ADD
	return light


## 안전 구역 표시 — 청록색 바닥 링 + 은은한 광원 (ExitMarker 보다 차분하게)
static func make_safe_zone_glow(radius: float) -> Node2D:
	var ring := Node2D.new()
	ring.z_index = -19
	ring.set_script(load("res://scripts/SafeZoneRing.gd"))
	ring.set("radius", radius)

	var light := make_room_light(radius * 1.6, 0.28, Color(0.30, 0.85, 0.80))
	light.shadow_enabled = false
	ring.add_child(light)
	return ring


## 비네트 오버레이
static func make_vignette() -> ColorRect:
	var shader := Shader.new()
	shader.code = """
shader_type canvas_item;
render_mode unshaded;

uniform float inner : hint_range(0.0, 1.0) = 0.34;
uniform float outer : hint_range(0.0, 1.5) = 0.85;
uniform vec4 tint : source_color = vec4(0.0, 0.0, 0.02, 1.0);

void fragment() {
	vec2 d = SCREEN_UV - vec2(0.5);
	d.x *= 1.15;
	float r = length(d) * 1.42;
	float a = smoothstep(inner, outer, r);
	COLOR = vec4(tint.rgb, a * 0.82);
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = shader

	var rect := ColorRect.new()
	rect.material = mat
	rect.anchor_right = 1.0
	rect.anchor_bottom = 1.0
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return rect


## 파티클 버스트 — CPUParticles2D 사용 (렌더러 무관하게 동작)
static func burst(pos: Vector2, color: Color, amount: int = 14, speed: float = 110.0) -> CPUParticles2D:
	var p := CPUParticles2D.new()
	p.position = pos
	p.amount = amount
	p.lifetime = 0.55
	p.one_shot = true
	p.explosiveness = 0.95
	p.emitting = true
	p.local_coords = false
	p.z_index = 14

	p.emission_shape = CPUParticles2D.EMISSION_SHAPE_SPHERE
	p.emission_sphere_radius = 4.0
	p.direction = Vector2(1, 0)
	p.spread = 180.0
	p.initial_velocity_min = speed * 0.4
	p.initial_velocity_max = speed
	p.gravity = Vector2.ZERO
	p.damping_min = 70.0
	p.damping_max = 140.0
	p.scale_amount_min = 1.6
	p.scale_amount_max = 3.4

	var ramp := Gradient.new()
	ramp.offsets = PackedFloat32Array([0.0, 1.0])
	ramp.colors = PackedColorArray([color, Color(color.r, color.g, color.b, 0.0)])
	p.color_ramp = ramp

	# 수명이 끝나면 자동 제거
	var timer := Timer.new()
	timer.wait_time = 1.4
	timer.one_shot = true
	timer.autostart = true
	timer.timeout.connect(p.queue_free)
	p.add_child(timer)

	return p


## 둥근 패널 스타일
static func panel_style(bg: Color, border: Color, radius: int = 6) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(radius)
	sb.content_margin_left = 12
	sb.content_margin_right = 12
	sb.content_margin_top = 8
	sb.content_margin_bottom = 8
	return sb
