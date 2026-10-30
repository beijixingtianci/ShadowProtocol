## RoomTemplates — 방 내부 구조 템플릿 (정적 헬퍼, autoload 아님)
##
## 각 템플릿은 Dictionary:
##   "walls":       Array[Rect2]   내부벽 (방 좌상단 기준 타일 좌표, 15×11 기준)
##   "cover_zones": Array[Vector2] 엄폐물 선호 위치 (타일)
##   "enemy_zones": Array[Vector2] 적 스폰 선호 위치 (타일)
##   "entry_sides": Array[String]  문이 나기 좋은 면 "N"/"S"/"E"/"W" (현재는 참고용 —
##                                 복도 생성은 건드리지 않는다)
##   "tags":        Array[String]  어울리는 방 타입
##
## 좌표는 15×11 방 기준이다. 크기가 다른 방(v1 size_hint)에서는 LevelLoader 가 비율로 맞춘다.
## 설계 규칙: 방 중앙 3×3 (x 6–8, y 4–6) 과 아이템 자리 (7,5)/(7,6)/(9,4) 는 비워 둔다.
## 복도 타일과 겹치는 벽 타일은 LevelLoader 가 자동으로 생략한다.
##
## 지금은 인프라 단계 — 템플릿은 3–5개로 유지하고 플레이테스트 후 늘린다.
##
## class_name 을 쓰지 않는다 (에디터가 전역 클래스 캐시를 다시 스캔하기 전에는
## "not declared" 파서 오류가 난다). 쓰는 쪽에서 preload 한다:
##   const RoomTemplates := preload("res://scripts/RoomTemplates.gd")
extends RefCounted

const BASE_W: int = 15
const BASE_H: int = 11


## room_type 에 맞는 템플릿 하나를 고른다. 없으면 {} (기존 균일 방).
static func get_template(room_type: String, rng: RandomNumberGenerator) -> Dictionary:
	var pool: Array = []
	for t in _templates():
		if room_type in t["tags"]:
			pool.append(t)
	if pool.is_empty():
		return {}
	return pool[rng.randi() % pool.size()]


static func _templates() -> Array:
	return [
		{
			# 좌상·우하 모서리에 L자 칸막이 → 벽 뒤 은신 구석 두 곳
			"tags": ["OBJECTIVE", "HIGH_SECURITY"],
			"walls": [
				Rect2(3, 2, 1, 4),    # 좌상 L: 세로
				Rect2(3, 2, 3, 1),    # 좌상 L: 가로
				Rect2(11, 5, 1, 4),   # 우하 L: 세로
				Rect2(9, 8, 3, 1),    # 우하 L: 가로
			],
			"cover_zones": [Vector2(4, 4), Vector2(10, 7), Vector2(5, 8)],
			"enemy_zones": [Vector2(12, 3), Vector2(2, 8)],
			"entry_sides": ["W", "S", "E"],
		},
		{
			# 가운데로만 지나가는 십자형 병목
			"tags": ["CHOKE"],
			"walls": [
				Rect2(0, 3, 6, 1),    # 위쪽 벽, 왼편
				Rect2(9, 3, 6, 1),    # 위쪽 벽, 오른편
				Rect2(0, 7, 6, 1),    # 아래쪽 벽, 왼편
				Rect2(9, 7, 6, 1),    # 아래쪽 벽, 오른편
			],
			"cover_zones": [Vector2(4, 2), Vector2(10, 8)],
			"enemy_zones": [Vector2(10, 2), Vector2(4, 8)],
			"entry_sides": ["W", "E"],
		},
		{
			# 네 모서리 기둥 — 시선을 끊는 기둥 뒤 은신
			"tags": ["KEY_ROOM", "ALT_PATH"],
			"walls": [
				Rect2(3, 2, 2, 2),
				Rect2(10, 2, 2, 2),
				Rect2(3, 7, 2, 2),
				Rect2(10, 7, 2, 2),
			],
			"cover_zones": [],
			"enemy_zones": [],
			"entry_sides": ["N", "S", "E", "W"],
		},
		{
			# 열린 방 — 내부벽 없음 (기존과 동일)
			"tags": ["TRANSIT", "OBSERVATION", "SIDE_OBJECTIVE"],
			"walls": [],
			"cover_zones": [],
			"enemy_zones": [],
			"entry_sides": ["N", "S", "E", "W"],
		},
	]
