"""
export_for_godot.py
───────────────────
stealth_pcg 파이프라인을 끝까지 돌려 Godot(ShadowProtocol)이 바로 읽는 JSON 을 만든다.

  1. 그래프 문법 생성          (LevelGenerator)
  2. 공간 배치 → 공유벽 도출    (solve_layout → derive_shared_walls)  ← proximity 가 여기서 생긴다
  3. 진화 최적화               (Optimizer, 목표 긴장도 곡선에 DTW 로 맞춘다)
  4. 최적 그래프 시뮬레이션     (ShortestPath / Cautious)
  5. 직렬화                   (LevelSerializer, schema v2 = v1 + layout)

사용법 (stealth_pcg/ 패키지 옆 또는 demo/ 안 어디서든):
  python export_for_godot.py --seed 42 --curve double_peak
  python export_for_godot.py --seed 7 --curve late_climax --gens 60 --pop 40 --difficulty 2 --out levels/level_data.json
  python export_for_godot.py --seed 42 --curve-points "0:0.1,0.3:0.85,0.55:0.2,1:0.7"   (직접 그린 곡선)

기본 출력 위치는 이 파일 옆의 levels/level_data.json (Godot 이 F5 로 읽는 경로).
"""
from __future__ import annotations

import argparse
import dataclasses
import io
import json
import os
import sys
import time
from contextlib import redirect_stdout

_HERE = os.path.dirname(os.path.abspath(__file__))
# stealth_pcg/ 가 이 파일 옆에 있든, 한 단계 위에 있든 찾을 수 있게 한다
for _p in (_HERE, os.path.dirname(_HERE)):
    if os.path.isdir(os.path.join(_p, "stealth_pcg")) and _p not in sys.path:
        sys.path.insert(0, _p)

from stealth_pcg.grammar.generator import LevelGenerator, GenerationConfig
from stealth_pcg.grammar.adjacency import derive_shared_walls, AdjacencyConfig
from stealth_pcg.layout import solve_layout, LayoutConfig, layout_to_json
from stealth_pcg.curves.templates import TensionCurve
from stealth_pcg.evolution.optimizer import Optimizer, EvolutionConfig
from stealth_pcg.evolution.fitness import FitnessEvaluator
from stealth_pcg.simulation.agent import LevelSimulator, ShortestPathAgent, CautiousAgent
from stealth_pcg.simulation.tension import TensionWeights
from stealth_pcg.export.serializer import LevelSerializer, simulation_block

#: 공유벽 재질 → 게임 쪽 wall_type (Godot 의 WallVariant / SoundSystem 이 읽는다)
MATERIAL_TO_WALL_TYPE = {
    "concrete": "thick",
    "drywall": "thin",
    "glass": "glass",
    "metal": "metal",
    "mesh": "fence",
}


def parse_curve_points(text: str) -> list[tuple[float, float]]:
    """"x:y,x:y,..." → [(x, y), ...].  시작 화면의 곡선 편집기가 넘겨주는 형식.

    TensionCurve 의 조건을 그대로 검사한다: 2개 이상, x 는 0 에서 시작해 1 로 끝나며
    엄격히 증가, 0 ≤ y ≤ 1.  어기면 ValueError (argparse 오류로 보고된다).
    """
    pts: list[tuple[float, float]] = []
    for tok in text.replace(" ", "").split(","):
        if not tok:
            continue
        if ":" not in tok:
            raise ValueError(f"'{tok}' — 점은 x:y 형식이어야 합니다")
        xs, ys = tok.split(":", 1)
        pts.append((float(xs), float(ys)))
    if len(pts) < 2:
        raise ValueError("점이 2개 이상 필요합니다")
    if pts[0][0] != 0.0 or pts[-1][0] != 1.0:
        raise ValueError("첫 점의 x 는 0, 마지막 점의 x 는 1 이어야 합니다")
    for (x0, _), (x1, _) in zip(pts, pts[1:]):
        if not x1 > x0:
            raise ValueError("x 는 엄격히 증가해야 합니다")
    for x, y in pts:
        if not (0.0 <= y <= 1.0):
            raise ValueError(f"y={y} — 0 과 1 사이여야 합니다")
    return pts


def _jsonable(obj):
    """dataclass → dict (Enum/set 등은 문자열·리스트로)."""
    if dataclasses.is_dataclass(obj):
        obj = dataclasses.asdict(obj)
    if isinstance(obj, dict):
        return {str(k): _jsonable(v) for k, v in obj.items()}
    if isinstance(obj, (list, tuple, set, frozenset)):
        return [_jsonable(v) for v in obj]
    return getattr(obj, "value", obj)


def main() -> None:
    presets = TensionCurve.all_presets()
    parser = argparse.ArgumentParser(description="stealth_pcg → Godot level JSON")
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--curve", type=str, default="double_peak", choices=list(presets.keys()))
    parser.add_argument("--curve-points", type=str, default=None,
                        help='직접 그린 목표 곡선 "x:y,x:y,..." (주면 --curve 대신 사용, 이름은 custom)')
    parser.add_argument("--gens", type=int, default=40)
    parser.add_argument("--pop", type=int, default=30)
    parser.add_argument("--difficulty", type=int, default=1, choices=[0, 1, 2, 3],
                        help="0=EASY 1=NORMAL 2=HARD 3=BRUTAL")
    parser.add_argument("--out", type=str,
                        default=os.path.join(_HERE, "levels", "level_data.json"))
    parser.add_argument("--no-layout", action="store_true",
                        help="layout 블록(schema v2 확장)을 생략한다 — 게임은 쓰지 않는다")
    parser.add_argument("--verbose", action="store_true", help="파이프라인 내부 출력 표시")
    # ── 생성 파라미터 (GenerationConfig) — 시작 화면에서 넘겨준다 ──
    parser.add_argument("--objectives", type=int, default=1, help="추가 목표 구간 수 (S8)")
    parser.add_argument("--keylocks", type=int, default=2, help="키-잠금 쌍 수 (S2)")
    parser.add_argument("--chokes", type=int, default=1, help="병목 수 (S6)")
    parser.add_argument("--corridors", type=int, default=3, help="복도 확장 횟수 (S7)")
    parser.add_argument("--corridor-len", type=int, default=2, help="확장당 복도 노드 수")
    parser.add_argument("--alt-path", type=float, default=0.4, help="우회로 확률 (S4)")
    parser.add_argument("--side-obj", type=float, default=0.5, help="보조 목표 확률 (S5)")
    parser.add_argument("--proximity", type=float, default=0.35,
                        help="공유벽 중 소리가 새는 벽의 비율 (GenerationConfig.leak_rate)")
    args = parser.parse_args()

    # 직접 그린 곡선은 생성을 시작하기 전에 검사한다
    custom_points = None
    if args.curve_points:
        try:
            custom_points = parse_curve_points(args.curve_points)
        except ValueError as exc:
            parser.error(f"--curve-points: {exc}")

    quiet = io.StringIO()
    t0 = time.time()

    # ── 1. 구조 생성 ──
    gen_config = GenerationConfig(
        seed=args.seed,
        num_extra_objectives=args.objectives,
        num_key_locks=args.keylocks,
        num_choke_points=args.chokes,
        num_corridor_expansions=args.corridors,
        corridor_length=args.corridor_len,
        path_diversity_prob=args.alt_path,
        side_objective_prob=args.side_obj,
        leak_rate=args.proximity,   # 공유벽 수 자체는 배치 결과에서 도출된다
    )
    with redirect_stdout(sys.stdout if args.verbose else quiet):
        graph = LevelGenerator(gen_config).generate()

        # ── 2. 배치 → 공유벽(proximity) 도출 ──
        layout_cfg = LayoutConfig(seed=args.seed)
        _, coarse = solve_layout(graph, layout_cfg)
        derive_shared_walls(graph, coarse, AdjacencyConfig(seed=args.seed, leak_rate=args.proximity))

    # ── 3. 진화 ──
    if custom_points is not None:
        target = TensionCurve.from_points(custom_points, name="custom")
    else:
        target = presets[args.curve]
    curve_name = target.name
    tw = TensionWeights()
    baseline = FitnessEvaluator(target, tension_weights=tw).evaluate(graph)

    evo_config = EvolutionConfig(population_size=args.pop, num_generations=args.gens,
                                 seed=args.seed)
    with redirect_stdout(sys.stdout if args.verbose else quiet):
        result = Optimizer(graph, target, config=evo_config, tension_weights=tw).run()
    best = result.best_individual.graph
    fitness = float(result.best_fitness)

    # ── 4. 최적 그래프 시뮬레이션 ──
    sim = LevelSimulator()
    sims, names = [], []
    for strat, name in ((ShortestPathAgent(), "shortest_path"), (CautiousAgent(), "cautious")):
        sim.strategy = strat
        sims.append(sim.simulate(best))
        names.append(name)

    # ── 5. 직렬화 ──
    improvement = (baseline - fitness) / baseline * 100.0 if baseline > 0 else 0.0
    meta = {
        "node_count": len(best.nodes),
        "edge_count": len(best.edges),
        "proximity_count": len(best.proximity_links),
        "generation_seed": args.seed,
        "generation_config": _jsonable(gen_config),
        "evolution_seed": args.seed,
        "evolution_config": _jsonable(evo_config),
        "generations": int(result.total_generations),
        "converged": bool(result.converged),
        "target_curve": {
            "name": curve_name,
            "points": [{"x": round(p.x, 4), "y": round(p.y, 4)} for p in target.points],
        },
        "fitness": {
            "final": round(fitness, 6),
            "baseline": round(float(baseline), 6),
            "improvement_pct": round(improvement, 1),
        },
        "tension_weights": _jsonable(tw),
        "difficulty": args.difficulty,   # 게임이 peek_meta 로 읽는다
    }
    layout = None if args.no_layout else layout_to_json(coarse, best, refine_seed=args.seed)
    data = LevelSerializer(best).to_dict(
        meta=meta, layout=layout, simulation_results=simulation_block(sims, names))

    # 재질 → 게임용 wall_type
    for p in data.get("proximity", {}).values():
        p["wall_type"] = MATERIAL_TO_WALL_TYPE.get(str(p.get("material", "")), "thick")

    out_dir = os.path.dirname(os.path.abspath(args.out))
    os.makedirs(out_dir, exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False, default=str)

    sp = data["simulation_results"]["shortest_path"]
    print(f"Done in {time.time() - t0:.1f}s: {len(best.nodes)} nodes, {len(best.edges)} edges, "
          f"{len(best.proximity_links)} walls | curve={curve_name} "
          f"fitness={fitness:.4f} (baseline {baseline:.4f}, {improvement:+.1f}%) | "
          f"agent reached exit={sp['reached_exit']} | saved to {args.out}")


if __name__ == "__main__":
    main()
