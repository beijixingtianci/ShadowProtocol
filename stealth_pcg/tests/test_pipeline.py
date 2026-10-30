"""
End-to-end test: full pipeline from seed to optimised level.

Run with:  python -m stealth_pcg.tests.test_pipeline
"""

from __future__ import annotations

import sys
import time

from stealth_pcg.grammar.generator import LevelGenerator, GenerationConfig
from stealth_pcg.curves.templates import TensionCurve, CurveBuilder
from stealth_pcg.simulation.agent import (
    LevelSimulator, ShortestPathAgent, CautiousAgent, ExplorerAgent,
)
from stealth_pcg.evolution.optimizer import Optimizer, EvolutionConfig, EvolutionResult
from stealth_pcg.evolution.fitness import FitnessEvaluator


def test_simulation_on_generated_level() -> None:
    """Generate a level, simulate all three agents, print traces."""
    gen = LevelGenerator(GenerationConfig(seed=42))
    graph = gen.generate()

    print(f"  Graph: {graph.summary()}")
    print(f"  Critical path: {graph.critical_path()}")

    sim = LevelSimulator()
    results = sim.simulate_multi(graph)

    for r in results:
        agent_name = r.path[0] if r.path else "?"
        print(f"\n  Agent: {sim.strategy.name if hasattr(sim, '_last') else '?'}")
        print(f"  {r.summary()}")
        trace_str = " → ".join(f"{t:.2f}" for t in r.tension_trace[:15])
        if len(r.tension_trace) > 15:
            trace_str += f" ... ({len(r.tension_trace)} total)"
        print(f"  Trace: {trace_str}")

    print("\n  [PASS] test_simulation_on_generated_level")


def test_curve_templates() -> None:
    """Verify all preset curves produce valid samples."""
    presets = TensionCurve.all_presets()

    for name, curve in presets.items():
        samples = curve.sample(10)
        assert len(samples) == 10, f"{name}: wrong sample count"
        assert all(0 <= v <= 1 for v in samples), f"{name}: out of range"
        print(f"  {name:15s}: {' '.join(f'{v:.2f}' for v in samples)}")

    print("  [PASS] test_curve_templates")


def test_custom_curve_builder() -> None:
    """Build a custom curve and verify it works."""
    builder = CurveBuilder()
    builder.add(0.0, 0.1)
    builder.add(0.3, 0.9)
    builder.add(0.7, 0.2)
    builder.add(1.0, 0.8)
    curve = builder.build(name="my_custom")

    samples = curve.sample(8)
    assert len(samples) == 8
    assert samples[0] < 0.2   # should start low
    print(f"  Custom curve: {' '.join(f'{v:.2f}' for v in samples)}")

    # Test serialization round-trip
    data = curve.to_dict()
    curve2 = TensionCurve.from_dict(data)
    samples2 = curve2.sample(8)
    assert samples == samples2, "Round-trip failed"

    print("  [PASS] test_custom_curve_builder")


def test_fitness_evaluator() -> None:
    """Evaluate fitness of a generated level against different curves."""
    gen = LevelGenerator(GenerationConfig(seed=42))
    graph = gen.generate()

    presets = TensionCurve.all_presets()
    for name, curve in presets.items():
        evaluator = FitnessEvaluator(curve)
        fitness = evaluator.evaluate(graph)
        print(f"  {name:15s} → fitness = {fitness:.4f}")

    print("  [PASS] test_fitness_evaluator")


def test_full_evolution() -> None:
    """Run the full evolutionary optimisation pipeline."""
    # Step 1: Generate structure
    gen_config = GenerationConfig(
        num_extra_objectives=1,
        num_key_locks=2,
        num_choke_points=1,
        num_corridor_expansions=2,
        seed=42,
    )
    gen = LevelGenerator(gen_config)
    base_graph = gen.generate()
    print(f"  Base graph: {base_graph.summary()}")

    # Step 2: Choose target curve
    target = TensionCurve.double_peak()
    print(f"  Target curve: {target.name}")

    # Step 3: Evaluate baseline fitness
    evaluator = FitnessEvaluator(target)
    baseline_fitness = evaluator.evaluate(base_graph)
    print(f"  Baseline fitness: {baseline_fitness:.4f}")

    # Step 4: Run evolution
    evo_config = EvolutionConfig(
        population_size=30,
        num_generations=40,
        seed=42,
        patience=15,
    )

    def on_gen(g: int, best: float, avg: float) -> None:
        if g % 10 == 0 or g == evo_config.num_generations - 1:
            print(f"    Gen {g:3d}: best={best:.4f}  avg={avg:.4f}")

    start_time = time.time()
    optimizer = Optimizer(
        base_graph=base_graph,
        target_curve=target,
        config=evo_config,
        on_generation=on_gen,
    )
    result = optimizer.run()
    elapsed = time.time() - start_time

    print(f"\n  Evolution completed in {elapsed:.1f}s")
    print(f"  Generations: {result.total_generations}")
    print(f"  Converged: {result.converged}")
    print(f"  Best fitness: {result.best_fitness:.4f}")
    print(f"  Improvement: {baseline_fitness:.4f} → {result.best_fitness:.4f} "
          f"({(1 - result.best_fitness / baseline_fitness) * 100:.1f}%)")

    # Step 5: Verify the optimised level
    best_graph = result.best_individual.graph
    assert best_graph.is_solvable(), "Optimised level must still be solvable"

    # Step 6: Show the optimised level's tension trace
    details = evaluator.evaluate_detailed(best_graph)
    for agent_data in details["agent_results"]:
        agent_name = agent_data["agent"]
        trace = agent_data["result"].tension_trace
        target_samples = agent_data["target_sampled"]
        trace_str = " ".join(f"{v:.2f}" for v in trace[:12])
        target_str = " ".join(f"{v:.2f}" for v in target_samples[:12])
        print(f"\n  Agent: {agent_name}")
        print(f"    Actual:  {trace_str}")
        print(f"    Target:  {target_str}")

    assert result.best_fitness < baseline_fitness, \
        "Evolution should improve over baseline"

    print("\n  [PASS] test_full_evolution")


def main() -> None:
    tests = [
        test_curve_templates,
        test_custom_curve_builder,
        test_simulation_on_generated_level,
        test_fitness_evaluator,
        test_full_evolution,
    ]

    print("=" * 60)
    print("Stealth PCG Full Pipeline Tests")
    print("=" * 60)

    passed = 0
    failed = 0

    for test in tests:
        print(f"\n{test.__name__}:")
        try:
            test()
            passed += 1
        except Exception as e:
            print(f"  [FAIL] {e}")
            import traceback
            traceback.print_exc()
            failed += 1

    print(f"\n{'=' * 60}")
    print(f"Results: {passed} passed, {failed} failed")
    print("=" * 60)

    if failed > 0:
        sys.exit(1)


if __name__ == "__main__":
    main()
