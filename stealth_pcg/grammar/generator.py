"""
stealth_pcg.grammar.generator
=============================
Level generator that orchestrates structural and attribute rule application.

The generation pipeline follows three phases:
1. **Structural expansion**: Apply S-rules to grow the graph from the seed.
2. **Attribute assignment**: Apply A-rules to fill in edge/node attributes.
3. **Validation**: Verify hard constraints (solvability, key-lock consistency).
"""

from __future__ import annotations

import random
from dataclasses import dataclass, field
from typing import Any

from stealth_pcg.core.graph import LevelGraph, reset_id_generator
from stealth_pcg.grammar.rule_base import Rule
from stealth_pcg.grammar.structural import (
    S1_BasicMissionExpand,
    S2_KeyLock,
    S3_RhythmControl,
    S4_PathDiversification,
    S5_SideObjective,
    S6_ChokePoint,
    S7_CorridorExpansion,
    S8_MultiObjective,
    S9_FunctionalNodeBuffer,
)
from stealth_pcg.grammar.attribute import (
    A2_ThreatDerivation,
    A4_KeyLockValidation,
    A5_NoiseConsistency,
    A6_StyleTagPropagation,
)


@dataclass
class GenerationConfig:
    """Parameters controlling the generation pipeline."""

    # ── Structural phase ──
    num_extra_objectives: int = 1    # How many S8 (extra objective segments) to insert
    num_key_locks: int = 2           # How many S2 (key-lock) to apply
    num_choke_points: int = 1        # How many S6 (choke) to apply
    num_corridor_expansions: int = 3 # How many S7 (corridor stretch) to apply
    corridor_length: int = 2         # Nodes per corridor expansion
    path_diversity_prob: float = 0.4 # Per-match probability for S4
    side_objective_prob: float = 0.5 # Per-match probability for S5
    min_styles: int = 2              # Minimum approach styles at EXIT

    # ── Proximity layer ──
    # 공유벽은 더 이상 여기서 만들지 않는다. 제3단계(배치)가 기하를 확정한
    # 뒤 제4단계(인접 도출)가 실제로 맞닿은 면에서 읽어낸다.
    # leak_rate 는 '맞닿은 면 중 실제로 소리가 새도록 만들 비율'이다.
    leak_rate: float = 0.35

    # ── Generation control ──
    max_structural_iterations: int = 50  # Safety limit
    seed: int | None = None              # Random seed for reproducibility


class LevelGenerator:
    """Orchestrates the full level generation pipeline."""

    def __init__(self, config: GenerationConfig | None = None) -> None:
        self.config = config or GenerationConfig()
        self._structural_log: list[str] = []
        self._attribute_log: list[str] = []

    def generate(self) -> LevelGraph:
        """Run the full pipeline and return a validated level graph."""
        if self.config.seed is not None:
            random.seed(self.config.seed)

        reset_id_generator()
        S2_KeyLock.reset_counter()

        self._structural_log.clear()
        self._attribute_log.clear()

        # Phase 0: Seed
        graph = LevelGraph.make_initial()
        self._log_structural("seed", graph)

        # Phase 1: Structural expansion
        graph = self._structural_phase(graph)

        # Phase 2: Attribute assignment
        graph = self._attribute_phase(graph)

        # Phase 3: Proximity generation

        # Phase 4: Validation
        self._validate(graph)

        return graph

    # ── Phase 1: Structural ────────────────────

    def _structural_phase(self, graph: LevelGraph) -> LevelGraph:
        """Apply structural rules in a designed order.

        Order matters — the pipeline is:
        S1 (seed expand) → S8 (extra objectives) → S7 (corridor stretch) →
        S2 (key-locks) → S6 (choke points) → S3 (rhythm fix) →
        S4 (alt paths) → S5 (side objectives)
        """

        # Step 1: Basic mission expansion (S1)
        s1 = S1_BasicMissionExpand()
        if s1.apply_first(graph):
            self._log_structural("S1", graph)

        # Step 2: Extra objectives (S8) — adds TRANSIT-OBJECTIVE-TRANSIT segments
        s8 = S8_MultiObjective()
        for _ in range(self.config.num_extra_objectives):
            matches = s8.find_matches(graph)
            if matches:
                chosen = random.choice(matches)
                s8.apply(graph, chosen)
                self._log_structural("S8", graph)

        # Step 3: Corridor expansion (S7) — stretches transits into corridors
        s7 = S7_CorridorExpansion(expansion_length=self.config.corridor_length)
        for _ in range(self.config.num_corridor_expansions):
            matches = s7.find_matches(graph)
            if matches:
                chosen = random.choice(matches)
                s7.apply(graph, chosen)
                self._log_structural("S7", graph)

        # Step 4: Key-lock mechanisms (S2)
        s2 = S2_KeyLock()
        for _ in range(self.config.num_key_locks):
            matches = s2.find_matches(graph)
            if matches:
                chosen = random.choice(matches)
                s2.apply(graph, chosen)
                self._log_structural("S2", graph)

        # Step 5: Choke points (S6) — before S3 so rhythm control can fix them
        s6 = S6_ChokePoint()
        for _ in range(self.config.num_choke_points):
            matches = s6.find_matches(graph)
            if matches:
                chosen = random.choice(matches)
                s6.apply(graph, chosen)
                self._log_structural("S6", graph)

        # Step 6: Rhythm control (S3) — fix consecutive high-threat zones
        s3 = S3_RhythmControl()
        for _ in range(10):  # limit iterations
            if not s3.apply_first(graph):
                break
            self._log_structural("S3", graph)

        # Step 7: Functional node buffer (S9) — insert TRANSIT between
        # directly connected functional nodes.  Must be AFTER S3.
        s9 = S9_FunctionalNodeBuffer()
        applied = True
        while applied:
            applied = s9.apply_first(graph)
            if applied:
                self._log_structural("S9", graph)

        # Step 8: Path diversification (S4)
        s4 = S4_PathDiversification(apply_probability=self.config.path_diversity_prob)
        matches = s4.find_matches(graph)
        for m in matches:
            if random.random() < self.config.path_diversity_prob:
                s4.apply(graph, m)
                self._log_structural("S4", graph)

        # Step 9: Side objectives (S5)
        s5 = S5_SideObjective()
        matches = s5.find_matches(graph)
        for m in matches:
            if random.random() < self.config.side_objective_prob:
                s5.apply(graph, m)
                self._log_structural("S5", graph)

        return graph

    # ── Phase 2: Attribute ─────────────────────

    def _attribute_phase(self, graph: LevelGraph) -> LevelGraph:
        """Apply attribute rules in order."""

        rules: list[Rule] = [
            A2_ThreatDerivation(),
            A5_NoiseConsistency(),
            A6_StyleTagPropagation(),
        ]

        for rule in rules:
            count = rule.apply_all(graph)
            if count > 0:
                self._log_attribute(rule.name, count)

        return graph

        return graph

    # ── Phase 4: Validation ────────────────────

    def _validate(self, graph: LevelGraph) -> None:
        """Verify hard constraints.  Raises ValueError on failure."""
        # Solvability
        if not graph.is_solvable():
            raise ValueError("Generated level is not solvable (EXIT unreachable)")

        # Key-lock consistency
        a4 = A4_KeyLockValidation()
        violations = a4.validate(graph)
        if violations:
            raise ValueError(
                f"Key-lock validation failed: {'; '.join(violations)}"
            )

        # Style diversity
        a6 = A6_StyleTagPropagation()
        if not a6.check_diversity(graph, self.config.min_styles):
            # Warning, not error — diversity can be improved by evolution
            pass

    # ── Logging ────────────────────────────────

    def _log_structural(self, rule_name: str, graph: LevelGraph) -> None:
        self._structural_log.append(
            f"[{rule_name}] → {graph.node_count} nodes, {graph.edge_count} edges"
        )

    def _log_attribute(self, rule_name: str, count: int) -> None:
        self._attribute_log.append(f"[{rule_name}] applied to {count} match(es)")

    @property
    def generation_log(self) -> list[str]:
        return self._structural_log + ["--- attribute phase ---"] + self._attribute_log
