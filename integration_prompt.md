# Task: ShadowProtocol — Pipeline Integration + Sound System + Guard Upgrade + Room Templates

This prompt covers 5 interconnected changes. Implement them in order — each builds on the previous.

---

## Part 1: Connect stealth_pcg Python Pipeline

### 1.1 Replace export_for_godot.py

The current `export_for_godot.py` imports from a separate codebase (`pipeline`, `evolution`, `agent`). Replace it to import from `stealth_pcg` (the v8 package). The new script should:

```python
# export_for_godot.py — drop this file next to the stealth_pcg/ package folder
# Usage: python export_for_godot.py --seed 42 --curve double_peak --out levels/level_data.json

import argparse, json, sys
from stealth_pcg.grammar.generator import LevelGenerator, GenerationConfig
from stealth_pcg.curves.templates import TensionCurve
from stealth_pcg.evolution.optimizer import Optimizer, EvolutionConfig
from stealth_pcg.evolution.fitness import FitnessEvaluator
from stealth_pcg.simulation.tension import TensionWeights
from stealth_pcg.export.serializer import LevelSerializer

def main():
	parser = argparse.ArgumentParser()
	parser.add_argument("--seed", type=int, default=42)
	parser.add_argument("--curve", type=str, default="double_peak",
						choices=list(TensionCurve.all_presets().keys()))
	parser.add_argument("--gens", type=int, default=40)
	parser.add_argument("--pop", type=int, default=30)
	parser.add_argument("--difficulty", type=int, default=1, choices=[0,1,2,3])
	parser.add_argument("--out", type=str, default="level_data.json")
	args = parser.parse_args()

	config = GenerationConfig(seed=args.seed)
	gen = LevelGenerator(config)
	graph = gen.generate()

	target = TensionCurve.all_presets()[args.curve]
	tw = TensionWeights()
	ev = FitnessEvaluator(target, tension_weights=tw)
	baseline = ev.evaluate(graph)

	evo_config = EvolutionConfig(population_size=args.pop, num_generations=args.gens, seed=args.seed)
	evo = Optimizer(graph, target, config=evo_config, tension_weights=tw)
	result = evo.run()
	best = result.best_individual.graph

	data = LevelSerializer.serialize(best,
		gen_config=config, evo_config=evo_config, evo_result=result,
		target_curve=target, tension_weights=tw, baseline_fitness=baseline)
	
	# Inject difficulty into meta (game reads this)
	data["meta"]["difficulty"] = args.difficulty

	with open(args.out, "w", encoding="utf-8") as f:
		json.dump(data, f, indent=2, ensure_ascii=False, default=str)
	
	fitness = result.best_fitness
	print(f"Done: {best.node_count} nodes, fitness={fitness:.4f}, curve={args.curve}, saved to {args.out}")

if __name__ == "__main__":
	main()
```

### 1.2 LevelLoader.gd — format detection

At the top of `_construct()`, detect schema version and branch:

```gdscript
func _construct(data: Dictionary) -> void:
	var version = data.get("version", 0)
	if version >= 1:
		_construct_v1(data)
	else:
		_construct_legacy(data)  # ← move current _construct body here, untouched
```

### 1.3 _construct_v1 — node/edge parsing

Key differences from legacy:
- `data["nodes"]` is a Dictionary keyed by ID, not an Array
- `data["edges"]` is a Dictionary keyed by ID, not an Array  
- No `room_params` on nodes — derive from edges (see godot_adaptation_prompt.md §2)
- `meta.target_curve` is `{name, points: [{x,y}]}` — extract `.points[].y` as flat array
- `meta.simulated_curve` is in `simulation_results.shortest_path.tension_trace`

Convert v1 dicts to the same internal `rooms[]` / `edges[]` arrays the rest of the code expects:

```gdscript
func _construct_v1(data: Dictionary) -> void:
	# Convert nodes dict → array with derived room_params
	var nodes: Array = []
	var node_dict: Dictionary = data.get("nodes", {})
	var edge_dict: Dictionary = data.get("edges", {})
	
	for nid in node_dict:
		var n: Dictionary = node_dict[nid].duplicate()
		n["id"] = nid
		n["room_params"] = _derive_room_params(nid, edge_dict)
		n["safe_zone"] = n.get("safe_zone", false)   # ← preserve for game use
		nodes.append(n)
	
	# Convert edges dict → array
	var edges: Array = []
	for eid in edge_dict:
		var e: Dictionary = edge_dict[eid].duplicate()
		e["id"] = eid
		edges.append(e)
	
	# Feed into existing layout pipeline
	# (from here, reuse the same _assign_grid, _paint_room, _fill_room, etc.)
	...

	# Store meta for GameState
	var meta: Dictionary = data.get("meta", {})
	var curve_obj = meta.get("target_curve", {})
	GameState.dtc_name = str(curve_obj.get("name", ""))
	var pts = curve_obj.get("points", [])
	GameState.target_curve = []
	for p in pts:
		GameState.target_curve.append(float(p.get("y", 0)))
	
	var sim = data.get("simulation_results", {})
	var sp = sim.get("shortest_path", {})
	GameState.simulated_curve = sp.get("tension_trace", [])
	
	var fitness = meta.get("fitness", {})
	GameState.dtw_distance = float(fitness.get("final", 0))
	
	var cc = data.get("clear_conditions", {})
	GameState.required_keys = cc.get("required_keys", [])
```

### 1.4 _derive_room_params — edge→node aggregation

```gdscript
func _derive_room_params(node_id: String, edge_dict: Dictionary) -> Dictionary:
	var max_patrol: float = 0.0
	var min_cover: float = 1.0
	var max_exposure: int = 1
	
	for eid in edge_dict:
		var e: Dictionary = edge_dict[eid]
		if e.get("source", "") == node_id or e.get("target", "") == node_id:
			max_patrol = maxf(max_patrol, float(e.get("patrol_density", 0.0)))
			min_cover = minf(min_cover, float(e.get("cover_availability", 1.0)))
			max_exposure = maxi(max_exposure, int(e.get("exposure_length", 1)))
	
	return {
		"num_patrols": int(round(max_patrol * 4.0)),
		"patrol_speed": max_patrol,
		"patrol_range": max_patrol * 0.85,
		"cover_ratio": min_cover,
		"light_level": 1.0 - max_patrol * 0.55,
		"resource_pickup": 0.0,
		"alarm_increment": max_patrol * 0.15,
	}
```

---

## Part 2: Sprint + Movement Speed Rework

### 2.1 Input mapping

In `project.godot`, add input action:
```
sprint = Key Shift (physical)
```

### 2.2 Player.gd changes

```gdscript
# Replace constants:
const WALK_SPEED: float = 130.0       # was SPEED=205, now slower default
const SPRINT_SPEED: float = 235.0     # faster than old default
const HIDE_MULT: float = 0.38         # slightly slower sneak

# New state:
var is_sprinting: bool = false

# In _physics_process:
var can_sprint: bool = not is_hiding and dir.length() > 0.1
is_sprinting = can_sprint and Input.is_action_pressed("sprint")

var speed: float = WALK_SPEED
if is_sprinting:
	speed = SPRINT_SPEED
elif is_hiding:
	speed = WALK_SPEED * HIDE_MULT
```

### 2.3 Noise generation

Player emits a noise event each physics frame while moving. Noise level depends on movement state:

```gdscript
# In Player._physics_process, after move_and_slide:
if velocity.length() > 5.0:
	var noise_radius: float = 0.0
	if is_sprinting:
		noise_radius = 280.0     # large radius — guards hear from far away
	elif is_hiding:
		noise_radius = 0.0       # silent
	else:
		noise_radius = 90.0      # normal walk — short range
	
	if noise_radius > 0.0:
		SoundSystem.emit_noise(global_position, noise_radius)
```

Other noise sources (add to relevant scripts):
```gdscript
# Door.gd — when opened
SoundSystem.emit_noise(global_position, 140.0)  # medium range

# Door.gd — when LOCKED door is unlocked  
SoundSystem.emit_noise(global_position, 200.0)  # large range

# Player.gd — assassination
SoundSystem.emit_noise(global_position, 120.0)  # medium range
```

---

## Part 3: Sound System

### 3.1 New autoload: SoundSystem.gd

Create `scripts/SoundSystem.gd` and register as Autoload in project.godot.

```gdscript
## SoundSystem — noise propagation with wall attenuation
## Noise is a circle centered on the source. Walls between source and
## listener shrink the effective radius in that direction.
extends Node

## Called by Player, Door, etc. when they make noise.
## radius: base range in pixels. All enemies within this radius (after
## wall attenuation) receive a hear event.
func emit_noise(source_pos: Vector2, radius: float) -> void:
	for enemy in get_tree().get_nodes_in_group("enemies"):
		if not enemy.alive:
			continue
		var dist: float = source_pos.distance_to(enemy.global_position)
		
		# Effective radius after wall check
		var effective_radius: float = _attenuate(source_pos, enemy.global_position, radius)
		
		if dist <= effective_radius:
			enemy.hear_noise(source_pos, dist / effective_radius)


## Cast a ray from source to listener. Each wall hit reduces the
## effective radius by a material-dependent factor.
func _attenuate(source: Vector2, listener: Vector2, radius: float) -> float:
	var space := get_viewport().get_world_2d().direct_space_state
	var r: float = radius
	
	# Cast ray on collision layer 1 (walls/covers/doors)
	var query := PhysicsRayQueryParameters2D.create(source, listener, 1)
	var pos: Vector2 = source
	
	# Check up to 4 walls between source and listener
	for i in range(4):
		var hit: Dictionary = space.intersect_ray(query)
		if hit.is_empty():
			break
		
		# Determine wall material attenuation
		var collider = hit.get("collider")
		var factor: float = _get_wall_factor(collider)
		r *= factor
		
		# Move past this wall and continue
		var normal: Vector2 = hit["normal"]
		pos = hit["position"] + (listener - source).normalized() * 2.0
		query = PhysicsRayQueryParameters2D.create(pos, listener, 1)
	
	return r


## Returns the sound pass-through factor for a wall/object.
## 0.0 = total block, 1.0 = no reduction.
func _get_wall_factor(collider: Node) -> float:
	if collider == null:
		return 1.0
	
	# If the collider has a wall_type property (from proximity system)
	var wt = collider.get("wall_type")
	if wt != null:
		match str(wt):
			"thick":      return 0.15    # concrete: almost blocks all sound
			"thin":       return 0.50    # drywall: moderate pass
			"glass":      return 0.35    # glass: blocks a bit
			"fence":      return 0.85    # chain-link: mostly passes
			"vent_shaft": return 0.65    # vent: decent pass
	
	# Default walls (no wall_type set)
	if collider.is_in_group("covers"):
		return 0.70    # boxes/furniture: slight reduction
	if collider.is_in_group("doors"):
		return 0.40 if collider.get("is_locked") else 0.60
	
	# Solid wall
	return 0.20
```

### 3.2 Wall.gd — add wall_type property

```gdscript
# Add to Wall.gd:
var wall_type: String = "thick"  # default for standard walls
```

When building walls from proximity data (if implemented), set `wall_type` on the wall node:
```gdscript
var w = Entities.make_wall(x, y, width, height)
w.wall_type = prox.get("wall_type", "thick")
```

---

## Part 4: Guard INVESTIGATE State

### 4.1 Enemy.gd state machine upgrade

```gdscript
enum State { PATROL, INVESTIGATE, SUSPICIOUS, ALERT }
#                    ↑ NEW STATE

# New variables:
var _investigate_target: Vector2 = Vector2.ZERO
var _investigate_timer: float = 0.0
const INVESTIGATE_DURATION: float = 3.0   # seconds to look around at noise source
const INVESTIGATE_SPEED_MULT: float = 0.7 # walks cautiously toward sound
```

### 4.2 hear_noise() — called by SoundSystem

```gdscript
## Called by SoundSystem when a noise reaches this enemy.
## source_pos: where the sound came from (world coordinates)
## intensity: 0.0 (barely heard) to 1.0 (point blank)
func hear_noise(source_pos: Vector2, intensity: float) -> void:
	if not alive:
		return
	if state == State.ALERT:
		return  # already chasing, don't downgrade to investigate
    
    # If already suspicious (saw player), noise makes it worse
    if state == State.SUSPICIOUS:
        suspicion += intensity * 0.3
        return
    
    # PATROL or INVESTIGATE → go to noise source
    _investigate_target = source_pos
    _investigate_timer = INVESTIGATE_DURATION
    state = State.INVESTIGATE
    
    # Visual feedback: show "?" briefly even before arriving
    suspicion = maxf(suspicion, intensity * 0.25)
    
    # Alert contribution
    GameState.raise_alert(intensity * 0.03)
```

### 4.3 _tick_investigate() — new state handler

```gdscript
func _tick_investigate(delta: float, sees: bool) -> void:
    # If we see the player while investigating, escalate immediately
    if sees:
        suspicion += 1.2 * delta
        _last_seen = _player.global_position
        if suspicion >= 0.5:
            state = State.SUSPICIOUS
            GameState.raise_alert(0.08)
        return
    
    var to_target: Vector2 = _investigate_target - global_position
    
    if to_target.length() < 20.0:
        # Arrived at noise source — look around
        _investigate_timer -= delta
        velocity = Vector2.ZERO
        _idle_look(delta)  # reuse existing look-around behavior
        
        if _investigate_timer <= 0.0:
            # Nothing found — return to patrol
            state = State.PATROL
            suspicion = maxf(0.0, suspicion - 0.2)
    else:
        # Walking toward noise source
        facing = to_target.angle()
        velocity = to_target.normalized() * patrol_speed * INVESTIGATE_SPEED_MULT
    
    # Suspicion decays slowly during investigation
    suspicion = maxf(0.0, suspicion - 0.08 * delta)
```

### 4.4 Wire into _physics_process

```gdscript
# In _physics_process, update the state dispatch:
if state == State.PATROL:
    _tick_patrol(delta, sees)
elif state == State.INVESTIGATE:       # ← NEW
    _tick_investigate(delta, sees)      # ← NEW
elif state == State.SUSPICIOUS:
    _tick_suspicious(delta, sees)
else:
    _tick_alert(delta, sees)
```

### 4.5 Visual: INVESTIGATE body color

```gdscript
# Add to _refresh_visuals or equivalent:
const BODY_INVESTIGATE := Color(0.45, 0.55, 0.65)  # blue-grey — curious but not alarmed

# In color selection:
match state:
    State.PATROL:      _body_col = BODY_CALM
    State.INVESTIGATE:  _body_col = BODY_INVESTIGATE
    State.SUSPICIOUS:   _body_col = BODY_SUS
    State.ALERT:        _body_col = BODY_ALERT

# Visor color for INVESTIGATE:
func _visor_color() -> Color:
    if state == State.ALERT:
        return Color(1.0, 0.42, 0.38)       # red
    if state == State.SUSPICIOUS:
        return Color(1.0, 0.82, 0.38)       # yellow
    if state == State.INVESTIGATE:
        return Color(0.65, 0.78, 0.92)      # light blue — curious
    return Color(0.48, 0.86, 0.92)          # teal — calm
```

### 4.6 Head icon for INVESTIGATE

```gdscript
# In _draw(), add between SUSPICIOUS and default:
elif state == State.INVESTIGATE:
    # Draw "?" mark above head
    var font := ThemeDB.fallback_font
    if font != null:
        draw_string(font, Vector2(-4, -26), "?",
            HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color(0.65, 0.78, 0.95))
```

---

## Part 5: Room Templates

### 5.1 Problem

Current rooms are uniform rectangles (15×11 tiles). All rooms feel identical except for enemy/cover count and lighting color. The layout is purely grid-based with no internal structure.

### 5.2 Architecture direction

DO NOT implement full room templates yet. Instead, prepare the infrastructure:

#### 5.2.1 Template data structure

Create `scripts/RoomTemplates.gd` (static helper, not autoload):

```gdscript
## RoomTemplates — predefined internal layouts for rooms
## Each template is a Dictionary with:
##   "walls": Array of Rect2 (internal wall segments, in tile coords relative to room origin)
##   "cover_zones": Array of Vector2 (preferred cover placement spots)
##   "enemy_zones": Array of Vector2 (preferred enemy spawn spots)  
##   "entry_sides": Array of String (which sides can have doors: "N","S","E","W")
##   "tags": Array of String (which room types this template suits)
class_name RoomTemplates

static func get_template(room_type: String, rng: RandomNumberGenerator) -> Dictionary:
    var pool: Array = TEMPLATES.filter(func(t): return room_type in t["tags"])
    if pool.is_empty():
        return {}  # no template → use current uniform layout
    return pool[rng.randi() % pool.size()]

const TEMPLATES := [
    {
        "tags": ["OBJECTIVE", "HIGH_SECURITY"],
        "walls": [
            # L-shaped internal wall creating two zones
            Rect2(4, 0, 1, 6),    # vertical wall from top
            Rect2(4, 6, 5, 1),    # horizontal wall extending right
        ],
        "cover_zones": [Vector2(2, 3), Vector2(7, 2), Vector2(10, 8)],
        "enemy_zones": [Vector2(8, 4), Vector2(12, 7)],
        "entry_sides": ["W", "S", "E"],
    },
    {
        "tags": ["CHOKE"],
        "walls": [
            # Narrow corridor through the middle
            Rect2(0, 3, 6, 1),     # top wall, left side
            Rect2(9, 3, 6, 1),     # top wall, right side
            Rect2(0, 7, 6, 1),     # bottom wall, left side
            Rect2(9, 7, 6, 1),     # bottom wall, right side
        ],
        "cover_zones": [Vector2(7, 5)],
        "enemy_zones": [Vector2(7, 5), Vector2(3, 5)],
        "entry_sides": ["W", "E"],
    },
    {
        "tags": ["TRANSIT", "OBSERVATION", "SIDE_OBJECTIVE"],
        "walls": [],   # open room, no internal walls
        "cover_zones": [],
        "enemy_zones": [],
        "entry_sides": ["N", "S", "E", "W"],
    },
]
```

#### 5.2.2 Integration point in LevelLoader.gd

In `_paint_room_floor()` and `_fill_room()`, check for a template:

```gdscript
func _paint_room_floor(room: Dictionary) -> void:
    var tmpl: Dictionary = RoomTemplates.get_template(room["type"], _rng)
    
    # Draw base floor (existing code)
    ...
    
    # If template has internal walls, draw them
    if tmpl.has("walls"):
        for wall_rect in tmpl["walls"]:
            var wx: int = room["tx"] + int(wall_rect.position.x)
            var wy: int = room["ty"] + int(wall_rect.position.y)
            var ww: float = wall_rect.size.x * TILE
            var wh: float = wall_rect.size.y * TILE
            _container.add_child(Entities.make_wall(wx * TILE, wy * TILE, ww, wh))
			# Remove these tiles from _floor_tiles (they're now walls)
			for y in range(wy, wy + int(wall_rect.size.y)):
				for x in range(wx, wx + int(wall_rect.size.x)):
					_floor_tiles.erase(Vector2i(x, y))
```

#### 5.2.3 What NOT to do now

- Don't create more than 3-5 templates total
- Don't make templates vary room dimensions (keep 15×11 for now)
- Don't attempt procedural internal wall generation
- Don't touch corridor generation — corridors stay uniform

The template system is a hook for future iteration. The current priority is getting sound + guards + pipeline connection working. Templates can be expanded incrementally with playtesting feedback.

---

## Implementation order

1. **export_for_godot.py** rewrite (Part 1.1) — test that it generates valid JSON
2. **LevelLoader.gd** v1 parsing (Parts 1.2-1.4) — test that v1 JSON loads and plays
3. **Sprint** (Part 2) — test movement feels right
4. **SoundSystem.gd** (Part 3) — test noise radius with debug visualization
5. **Enemy INVESTIGATE** (Part 4) — test that guards react to sprint noise
6. **RoomTemplates stub** (Part 5) — test one CHOKE template looks different

## Testing checklist

- [ ] `python export_for_godot.py --seed 42 --curve double_peak` produces valid JSON
- [ ] Game loads v1 JSON correctly (HUD shows curve name + fitness)
- [ ] Game still loads old format JSON (backward compat)
- [ ] Fallback level works with no JSON
- [ ] Walk speed noticeably slower than before, sprint is fast
- [ ] Sprint near a guard → guard shows "?" and walks toward player's position
- [ ] Walking (not sprinting) near a guard → no reaction (range too short)
- [ ] Sneaking (Shift near cover) → completely silent, no guard reaction
- [ ] Guard arrives at noise source, looks around 3s, returns to patrol
- [ ] Guard sees player while investigating → escalates to SUSPICIOUS
- [ ] Sound through walls is attenuated (guard behind thick wall doesn't hear sprint from far away)
- [ ] Assassination produces medium noise (nearby guards investigate)
- [ ] Opening a locked door produces loud noise
- [ ] `verify_solvable()` passes on v1 levels
- [ ] Play log records correctly with v1 node IDs
