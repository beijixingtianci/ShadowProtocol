"""
Quick smoke test for the stealth PCG grammar pipeline.

Run with:  python -m stealth_pcg.tests.test_grammar
"""

from __future__ import annotations

import json
import sys
import traceback

from stealth_pcg.core.graph import LevelGraph, reset_id_generator
from stealth_pcg.core.types import NodeType, TraversalType, Visibility
from stealth_pcg.grammar.generator import LevelGenerator, GenerationConfig
from stealth_pcg.grammar.structural import S2_KeyLock


def test_seed_graph() -> None:
    """Test that the seed graph is created correctly."""
    reset_id_generator()
    g = LevelGraph.make_initial()
    assert g.node_count == 2, f"Expected 2 nodes, got {g.node_count}"
    assert g.edge_count == 1, f"Expected 1 edge, got {g.edge_count}"
    assert g.is_solvable(), "Seed graph should be solvable"
    path = g.critical_path()
    assert path is not None and len(path) == 2
    print("  [PASS] test_seed_graph")


def test_graph_serialization() -> None:
    """Test JSON round-trip."""
    reset_id_generator()
    g = LevelGraph.make_initial()
    data = g.to_dict()
    json_str = json.dumps(data, indent=2, default=str)
    g2 = LevelGraph.from_dict(json.loads(json_str))
    assert g2.node_count == g.node_count
    assert g2.edge_count == g.edge_count
    assert g2.is_solvable()
    print("  [PASS] test_graph_serialization")


def test_deep_copy() -> None:
    """Test that deep copy is independent."""
    reset_id_generator()
    g = LevelGraph.make_initial()
    g2 = g.deep_copy()
    g2.add_node(NodeType.TRANSIT)
    assert g.node_count == 2, "Original should be unchanged"
    assert g2.node_count == 3
    print("  [PASS] test_deep_copy")


def test_full_generation() -> None:
    """Test the full generation pipeline."""
    config = GenerationConfig(
        num_extra_objectives=1,
        num_key_locks=2,
        num_choke_points=1,
        num_corridor_expansions=3,
        corridor_length=2,
        path_diversity_prob=0.5,
        side_objective_prob=0.5,
        seed=42,
    )
    gen = LevelGenerator(config)
    graph = gen.generate()

    # Basic sanity
    assert graph.node_count >= 10, f"Too few nodes: {graph.node_count}"
    assert graph.edge_count >= 8, f"Too few edges: {graph.edge_count}"
    assert graph.is_solvable(), "Generated level should be solvable"

    # Should have at least one of each core type
    entry = graph.nodes_of_type(NodeType.ENTRY)
    exit_ = graph.nodes_of_type(NodeType.EXIT)
    obj = graph.nodes_of_type(NodeType.OBJECTIVE)
    assert len(entry) == 1, "Should have exactly one ENTRY"
    assert len(exit_) == 1, "Should have exactly one EXIT"
    assert len(obj) >= 1, "Should have at least one OBJECTIVE"

    # Critical path should exist
    path = graph.critical_path()
    assert path is not None, "Critical path should exist"
    assert path[0] == entry[0].id, "Path should start at ENTRY"
    assert path[-1] == exit_[0].id, "Path should end at EXIT"

    # Print generation log
    print("  Generation log:")
    for line in gen.generation_log:
        print(f"    {line}")
    print(f"  Final: {graph.summary()}")
    print(f"  Critical path length: {len(path)} nodes")
    print("  [PASS] test_full_generation")


def test_multiple_seeds() -> None:
    """Generate with different seeds and verify all are solvable."""
    success_count = 0
    total = 20
    sizes = []
    for seed in range(total):
        config = GenerationConfig(
            num_extra_objectives=1,
            num_key_locks=2,
            num_choke_points=1,
            num_corridor_expansions=3,
            corridor_length=2,
            path_diversity_prob=0.5,
            side_objective_prob=0.5,
            seed=seed,
        )
        gen = LevelGenerator(config)
        try:
            graph = gen.generate()
            assert graph.is_solvable()
            sizes.append(graph.node_count)
            success_count += 1
        except Exception as e:
            print(f"    Seed {seed} failed: {e}")

    avg_size = sum(sizes) / len(sizes) if sizes else 0
    print(f"  Solvable: {success_count}/{total}")
    print(f"  Node counts: min={min(sizes)}, max={max(sizes)}, avg={avg_size:.1f}")
    assert success_count == total, f"Some seeds failed"
    print("  [PASS] test_multiple_seeds")


def test_graph_printout() -> None:
    """Generate a level and print its full structure for visual inspection."""
    config = GenerationConfig(seed=7)
    gen = LevelGenerator(config)
    graph = gen.generate()

    print("  Full graph structure:")
    print(f"  {repr(graph)}")

    # Print serialized JSON
    data = graph.to_dict()
    print(f"\n  JSON (truncated):")
    json_str = json.dumps(data, indent=2, default=str)
    lines = json_str.split("\n")
    for line in lines[:40]:
        print(f"    {line}")
    if len(lines) > 40:
        print(f"    ... ({len(lines) - 40} more lines)")
    print("  [PASS] test_graph_printout")


def main() -> None:
    tests = [
        test_seed_graph,
        test_graph_serialization,
        test_deep_copy,
        test_full_generation,
        test_multiple_seeds,
        test_graph_printout,
    ]

    print("=" * 60)
    print("Stealth PCG Grammar Tests")
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
            traceback.print_exc()
            failed += 1

    print(f"\n{'=' * 60}")
    print(f"Results: {passed} passed, {failed} failed")
    print("=" * 60)

    if failed > 0:
        sys.exit(1)


if __name__ == "__main__":
    main()
