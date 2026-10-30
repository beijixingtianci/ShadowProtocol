"""
stealth_pcg.demo
================
Full pipeline demo: generate → simulate → evolve → visualize.

Outputs PNG figures to /mnt/user-data/outputs/ for review.

Run:  python -m stealth_pcg.demo
"""

from __future__ import annotations

import os
import time

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

from stealth_pcg.grammar.generator import LevelGenerator, GenerationConfig
from stealth_pcg.curves.templates import TensionCurve
from stealth_pcg.simulation.agent import (
    LevelSimulator, ShortestPathAgent, CautiousAgent, ExplorerAgent,
)
from stealth_pcg.simulation.tension import TensionWeights
from stealth_pcg.evolution.optimizer import Optimizer, EvolutionConfig
from stealth_pcg.evolution.fitness import FitnessEvaluator
from stealth_pcg.visualization.graph_viz import draw_graph
from stealth_pcg.visualization.curve_viz import (
    draw_curve_comparison,
    draw_all_presets,
    draw_fitness_history,
    draw_combined_report,
)

OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "pcg_output")


def save(fig: plt.Figure, name: str) -> str:
    os.makedirs(OUT_DIR, exist_ok=True)
    path = os.path.join(OUT_DIR, name)
    fig.savefig(path, dpi=150, bbox_inches="tight", facecolor="white")
    plt.close(fig)
    print(f"  Saved: {name}")
    return path


def main() -> None:
    print("=" * 60)
    print("Stealth PCG — Full Pipeline Demo")
    print("=" * 60)

    # ─────────────────────────────────────────
    # 1. Generate structure
    # ─────────────────────────────────────────
    print("\n[1/5] Generating level structure...")
    gen_config = GenerationConfig(
        num_extra_objectives=1,
        num_key_locks=2,
        num_choke_points=1,
        num_corridor_expansions=3,
        corridor_length=2,
        path_diversity_prob=0.5,
        side_objective_prob=0.5,
        seed=42,
    )
    gen = LevelGenerator(gen_config)
    base_graph = gen.generate()
    print(f"  {base_graph.summary()}")
    print(f"  Critical path: {len(base_graph.critical_path() or [])} nodes")

    for line in gen.generation_log:
        print(f"    {line}")

    # ─────────────────────────────────────────
    # 2. Visualize graph structure
    # ─────────────────────────────────────────
    print("\n[2/5] Drawing graph visualizations...")
    fig = draw_graph(base_graph, title="Generated Level (Before Optimization)")
    save(fig, "01_graph_structure.png")

    # ── Stage 2-3: 공간 배치 → 인접 도출 ──
    # 공유벽은 배치 결과에서 읽어낸다. 무작위 지정이 아니므로
    # '지정했으나 구현하지 못한 링크'가 원리적으로 생기지 않는다.
    from stealth_pcg.layout import solve_layout, LayoutConfig
    from stealth_pcg.grammar.adjacency import (derive_shared_walls,
                                               AdjacencyConfig,
                                               adjacency_summary)
    layout_cfg = LayoutConfig(seed=42)
    coarse = solve_layout(base_graph, layout_cfg)[1]
    nwalls = derive_shared_walls(base_graph, coarse, AdjacencyConfig(seed=42))
    _asum = adjacency_summary(base_graph)
    print(f"\n[2-3] layout: {int(coarse.stats['rooms'])} rooms, "
          f"{int(coarse.stats['doors'])} doors, "
          f"{int(coarse.stats['corridors_routed'])} corridors")
    print(f"      walls: {nwalls} derived, {int(_asum['leaky'])} leaky, "
          f"{int(_asum['windows_total'])} windows")

    # With critical path highlighted
    crit_path = base_graph.critical_path()
    fig = draw_graph(base_graph, path=crit_path,
                     title="Critical Path Highlighted")
    save(fig, "02_graph_critical_path.png")

    # ─────────────────────────────────────────
    # 3. Simulate with multiple agents
    # ─────────────────────────────────────────
    print("\n[3/5] Running simulations...")
    strategies = [ShortestPathAgent(), CautiousAgent(), ExplorerAgent()]
    agent_names = ["Shortest Path", "Cautious", "Explorer"]

    sim = LevelSimulator()
    results_before: list = []
    for strat, name in zip(strategies, agent_names):
        sim.strategy = strat
        r = sim.simulate(base_graph)
        results_before.append(r)
        status = "✓ EXIT" if r.reached_exit else "✗ stuck"
        print(f"  {name:15s}: {r.total_steps} steps, {status}, "
              f"tension [{min(r.tension_trace):.2f}—{max(r.tension_trace):.2f}]")

    # Draw simulation paths on graph
    for r, name in zip(results_before, agent_names):
        if r.reached_exit:
            fig = draw_graph(base_graph, path=r.path,
                             title=f"Agent Path: {name}")
            save(fig, f"03_path_{name.lower().replace(' ', '_')}.png")

    # ─────────────────────────────────────────
    # 4. Choose target curve and evolve
    # ─────────────────────────────────────────
    print("\n[4/5] Running evolutionary optimization...")
    target = TensionCurve.double_peak()

    # Draw preset templates
    fig = draw_all_presets()
    save(fig, "04_preset_curves.png")

    # Baseline curves before optimization
    fig = draw_curve_comparison(
        target, results_before, agent_names,
        title="Before Optimization: Tension vs Target"
    )
    save(fig, "05_curves_before.png")

    # Run evolution
    evo_config = EvolutionConfig(
        population_size=50,
        num_generations=60,
        seed=42,
        patience=20,
    )

    t0 = time.time()
    optimizer = Optimizer(
        base_graph, target,
        config=evo_config,
        on_generation=lambda g, b, a: print(
            f"    Gen {g:3d}: best={b:.4f}  avg={a:.4f}"
        ) if g % 10 == 0 else None,
    )
    evo_result = optimizer.run()
    elapsed = time.time() - t0
    print(f"\n  Completed in {elapsed:.1f}s")
    print(f"  Generations: {evo_result.total_generations}")
    print(f"  Best fitness: {evo_result.best_fitness:.4f}")

    # ─────────────────────────────────────────
    # 5. Visualize optimized results
    # ─────────────────────────────────────────
    print("\n[5/5] Generating final visualizations...")
    best_graph = evo_result.best_individual.graph

    # Simulate the optimized graph
    results_after: list = []
    for strat, name in zip(strategies, agent_names):
        sim.strategy = strat
        r = sim.simulate(best_graph)
        results_after.append(r)
        status = "✓ EXIT" if r.reached_exit else "✗ stuck"
        print(f"  {name:15s}: {r.total_steps} steps, {status}, "
              f"tension [{min(r.tension_trace):.2f}—{max(r.tension_trace):.2f}]")

    # Optimized graph with path
    for r, name in zip(results_after, agent_names):
        if r.reached_exit:
            fig = draw_graph(best_graph, path=r.path,
                             title=f"Optimized Level — {name} Path")
            save(fig, f"06_optimized_path_{name.lower().replace(' ', '_')}.png")

    # Curves after optimization
    fig = draw_curve_comparison(
        target, results_after, agent_names,
        title="After Optimization: Tension vs Target"
    )
    save(fig, "07_curves_after.png")

    # Fitness convergence
    fig = draw_fitness_history(evo_result)
    save(fig, "08_fitness_history.png")

    # Combined report
    fig = draw_combined_report(
        target, results_after, agent_names, evo_result,
    )
    save(fig, "09_combined_report.png")

    # Before/after side-by-side
    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(16, 5))
    draw_curve_comparison(target, results_before, agent_names,
                          ax=ax1, title="BEFORE Optimization")
    draw_curve_comparison(target, results_after, agent_names,
                          ax=ax2, title="AFTER Optimization")
    save(fig, "10_before_after_comparison.png")

    # ── Stage 7: L3 refinement + export ──
    print("\n[7] Refining tile geometry and exporting...")
    from stealth_pcg.layout import layout_to_json, from_level_graph
    from stealth_pcg.layout.refine import refine as refine_layout
    from stealth_pcg.layout.render_html import write_report as write_plan
    from stealth_pcg.export.serializer import LevelSerializer

    best_graph = evo_result.best_individual.graph
    wall_sep = {frozenset((w.node_a, w.node_b)): {"separation": w.separation}
                for w in best_graph.proximity_links.values()}
    layout_data = from_level_graph(best_graph)
    tile_layout = refine_layout(layout_data, coarse, layout_cfg, walls=wall_sep)

    write_plan(tile_layout, layout_data, f"{OUT_DIR}/11_layout_plan.html",
               meta={"seed": "42"})
    LevelSerializer(best_graph).write(
        f"{OUT_DIR}/level.json", meta={"seed": 42},
        layout=layout_to_json(coarse, best_graph, refine_seed=42))
    print("    -> 11_layout_plan.html, level.json")

    print(f"\n{'=' * 60}")
    print(f"All outputs saved to {OUT_DIR}/")
    print("=" * 60)


if __name__ == "__main__":
    main()
