"""
stealth_pcg.simulation.tension
===============================
Per-node tension function T(t) based on the research report formula.

T(t) = max( weighted_sum_of_components,  decay_carry * T(t-1) )

Components (all normalised to [0, 1] before weighting):
  D — threat proximity (dominant per Tremblay et al. 2014)
  A — alert/alarm state
  E — escape time pressure
  R — resource scarcity
  L — line-of-sight exposure
  C — cover availability (inverted: less cover = more tension)
  K — cumulative risk (how long since last safe zone)

The weights are designer-tunable parameters, NOT hard-coded constants.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

from stealth_pcg.core.graph import LevelGraph, Node, Edge
from stealth_pcg.core.types import (
    NodeType, NoiseLevel, ThreatLevel, TraversalType, DEFAULT_THREAT,
)


@dataclass
class TensionWeights:
    """Weights for the tension function components.

    Defaults based on the literature survey (Tremblay dominant,
    Smith's macro pacing, Booth's decay).  Tunable by designer or
    by evolutionary search.
    """

    w_patrol: float = 0.22       # D: patrol_density of incoming edge
    w_exposure: float = 0.12     # L: exposure_length of incoming edge
    w_cover: float = 0.12        # C: 1 - cover_availability (inverted)
    w_node_threat: float = 0.13  # A: node's base threat level
    w_cumulative: float = 0.12   # K: steps since last safe zone
    w_lock_pressure: float = 0.08  # E: are we near a locked door without the key?
    w_noise: float = 0.05        # noise_level of the traversal
    # 환경 위협은 청각과 시각으로 분리한다. 합은 0.16 으로 구버전의
    # w_ambient 와 같게 두어 기존 실험 결과와 비교 가능하도록 하였다.
    # 시각 쪽 가중이 낮은 것은 Tremblay 등(2014)에서 '보일 가능성'이
    # '근처의 순찰'보다 주관적 위험감에 덜 기여한 결과를 따른 것이다.
    w_ambient_audio: float = 0.10   # 공유벽 너머의 소리
    w_ambient_visual: float = 0.06  # 공유벽 너머의 시선

    decay_tau: float = 0.6       # Booth-style carry-over: T(t) >= decay * T(t-1)
    cumulative_cap: int = 8      # max steps for cumulative risk normalisation


@dataclass
class AgentState:
    """Mutable state carried by the agent during simulation."""

    current_node: str = ""
    steps_since_safe: int = 0
    held_keys: set[str] = field(default_factory=set)
    visited_nodes: list[str] = field(default_factory=list)
    tension_trace: list[float] = field(default_factory=list)
    previous_tension: float = 0.0


class TensionCalculator:
    """Computes tension at each step of a simulated playthrough."""

    def __init__(self, weights: TensionWeights | None = None) -> None:
        self.w = weights or TensionWeights()

    @staticmethod
    def _is_safe_zone(node: Node) -> bool:
        """Check whether this node resets the cumulative risk counter.

        Uses the ``safe_zone`` attribute set during generation (S3, S5)
        and potentially toggled by the evolutionary search.
        ENTRY is always safe (hardcoded).
        """
        if node.node_type == NodeType.ENTRY:
            return True
        return node.attrs.get("safe_zone", False)

    def compute(
        self,
        graph: LevelGraph,
        node: Node,
        incoming_edge: Edge | None,
        state: AgentState,
    ) -> float:
        """Compute tension for arriving at *node* via *incoming_edge*.

        Returns a value in [0, 1].
        """
        # ── Component D: patrol density ──
        if incoming_edge is not None:
            d_patrol = incoming_edge.patrol_density
        else:
            # Starting node — average of outgoing edges
            out = graph.out_edges(node.id)
            d_patrol = (sum(e.patrol_density for e in out) / len(out)) if out else 0.0

        # ── Component L: exposure length ──
        if incoming_edge is not None:
            d_exposure = min(incoming_edge.exposure_length / 5.0, 1.0)
        else:
            d_exposure = 0.0

        # ── Component C: cover deficit (inverted) ──
        if incoming_edge is not None:
            d_cover_deficit = 1.0 - incoming_edge.cover_availability
        else:
            d_cover_deficit = 0.0

        # ── Component A: node threat level ──
        threat = DEFAULT_THREAT.get(node.node_type, ThreatLevel.LOW)
        threat_map = {
            ThreatLevel.LOW: 0.1,
            ThreatLevel.MEDIUM: 0.4,
            ThreatLevel.HIGH: 0.8,
            ThreatLevel.VARIABLE: 0.5,
        }
        d_node_threat = threat_map.get(threat, 0.3)

        # ── Component K: cumulative risk ──
        if self._is_safe_zone(node):
            state.steps_since_safe = 0
        else:
            state.steps_since_safe += 1
        d_cumulative = min(state.steps_since_safe / self.w.cumulative_cap, 1.0)

        # ── Component E: lock pressure ──
        # If outgoing edges are locked and we don't have the key, tension rises
        d_lock_pressure = 0.0
        for e in graph.out_edges(node.id):
            if e.locked and e.key_id and e.key_id not in state.held_keys:
                d_lock_pressure = 0.8
                break

        # ── Component: noise ──
        if incoming_edge is not None:
            noise_map = {
                NoiseLevel.SILENT: 0.0,
                NoiseLevel.LOW: 0.2,
                NoiseLevel.MEDIUM: 0.5,
                NoiseLevel.HIGH: 0.9,
            }
            d_noise = noise_map.get(incoming_edge.noise_level, 0.2)
        else:
            d_noise = 0.0

        # ── Component: ambient threat from shared walls ──
        d_ambient_audio, d_ambient_visual = graph.ambient_threat(node.id)

        # ── Weighted sum ──
        weighted = (
            self.w.w_patrol * d_patrol
            + self.w.w_exposure * d_exposure
            + self.w.w_cover * d_cover_deficit
            + self.w.w_node_threat * d_node_threat
            + self.w.w_cumulative * d_cumulative
            + self.w.w_lock_pressure * d_lock_pressure
            + self.w.w_noise * d_noise
            + self.w.w_ambient_audio * d_ambient_audio
            + self.w.w_ambient_visual * d_ambient_visual
        )

        # ── Booth-style decay carry-over ──
        decay_carry = self.w.decay_tau * state.previous_tension
        tension = max(weighted, decay_carry)

        # Clamp to [0, 1]
        tension = max(0.0, min(1.0, tension))

        state.previous_tension = tension
        return tension
