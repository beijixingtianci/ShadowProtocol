"""
stealth_pcg.simulation.agent
=============================
AI agents that traverse a level graph and produce tension traces.

The agent walks from ENTRY to EXIT, choosing edges based on a strategy.
At each node it records the tension value computed by
:class:`~stealth_pcg.simulation.tension.TensionCalculator`.

Multiple agent strategies are provided to model different player types
(cautious, aggressive, explorer).  Running the same level with different
agents produces different tension traces — useful for robust evaluation.
"""

from __future__ import annotations

import random
from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from typing import Any

from stealth_pcg.core.graph import LevelGraph, Node, Edge
from stealth_pcg.core.types import NodeType
from stealth_pcg.simulation.tension import (
    TensionCalculator,
    TensionWeights,
    AgentState,
)


@dataclass
class SimulationResult:
    """Output of a single agent simulation run."""

    path: list[str]               # node IDs visited in order
    tension_trace: list[float]    # tension value at each step
    total_steps: int = 0
    reached_exit: bool = False
    keys_collected: list[str] = field(default_factory=list)

    @property
    def critical_path_tension(self) -> list[float]:
        """Alias for tension_trace (the curve used by DTW fitness)."""
        return self.tension_trace

    def summary(self) -> str:
        exit_str = "reached EXIT" if self.reached_exit else "DID NOT reach EXIT"
        return (
            f"SimResult({self.total_steps} steps, {exit_str}, "
            f"keys={self.keys_collected}, "
            f"tension range=[{min(self.tension_trace):.2f}, {max(self.tension_trace):.2f}])"
        )


class AgentStrategy(ABC):
    """Abstract base for agent edge-selection strategies."""

    name: str = "base"

    @abstractmethod
    def choose_edge(
        self,
        graph: LevelGraph,
        current: str,
        available_edges: list[Edge],
        state: AgentState,
    ) -> Edge:
        """Choose which edge to traverse from the current node."""


class ShortestPathAgent(AgentStrategy):
    """Picks the edge leading toward EXIT via shortest reachable path.

    Lock-aware: if the direct path is blocked, detours to KEY_ROOM first.
    Models a player who knows the layout — a "speedrunner" archetype.
    """

    name = "shortest_path"

    def choose_edge(
        self,
        graph: LevelGraph,
        current: str,
        available_edges: list[Edge],
        state: AgentState,
    ) -> Edge:
        exit_id = graph.find_exit().id

        # Try to find the edge whose target is closest to EXIT
        best_edge = available_edges[0]
        best_dist = float("inf")

        for edge in available_edges:
            dist = self._lock_aware_distance(
                graph, edge.target, exit_id, state.held_keys
            )
            if dist < best_dist:
                best_dist = dist
                best_edge = edge

        if best_dist < 999:
            return best_edge

        # EXIT unreachable — find which key we need and pathfind to it
        needed_keys = self._find_needed_keys(graph, state.held_keys)
        if needed_keys:
            # Find KEY_ROOMs providing needed keys
            key_rooms: list[str] = []
            for nid, node in graph.nodes.items():
                if (node.node_type == NodeType.KEY_ROOM
                        and node.provides
                        and node.provides in needed_keys
                        and node.provides not in state.held_keys):
                    key_rooms.append(nid)

            # Pick the edge leading toward the nearest needed KEY_ROOM
            if key_rooms:
                best_kr_edge = available_edges[0]
                best_kr_dist = float("inf")
                for edge in available_edges:
                    for kr_id in key_rooms:
                        d = self._lock_aware_distance(
                            graph, edge.target, kr_id, state.held_keys
                        )
                        if d < best_kr_dist:
                            best_kr_dist = d
                            best_kr_edge = edge
                if best_kr_dist < 999:
                    return best_kr_edge

        # Last resort: pick any edge not recently visited
        non_backtrack = [
            e for e in available_edges
            if e.target not in state.visited_nodes[-8:]
        ]
        if non_backtrack:
            return non_backtrack[0]

        return best_edge

    @staticmethod
    def _find_needed_keys(graph: LevelGraph, held_keys: set[str]) -> set[str]:
        """Find key_ids of locked edges we can't currently pass."""
        needed = set()
        for edge in graph.edges.values():
            if edge.locked and edge.key_id and edge.key_id not in held_keys:
                needed.add(edge.key_id)
        return needed

    @staticmethod
    def _lock_aware_distance(
        graph: LevelGraph,
        start: str,
        goal: str,
        held_keys: set[str],
    ) -> int:
        """BFS distance respecting locks, including reverse traversal."""
        if start == goal:
            return 0
        visited = {start}
        frontier = [(start, 0)]
        while frontier:
            nid, dist = frontier.pop(0)
            # Forward edges
            for edge in graph.out_edges(nid):
                if edge.locked and edge.key_id and edge.key_id not in held_keys:
                    continue
                if edge.target not in visited:
                    if edge.target == goal:
                        return dist + 1
                    visited.add(edge.target)
                    frontier.append((edge.target, dist + 1))
            # Reverse edges (non-one-way)
            for edge in graph.in_edges(nid):
                if edge.one_way:
                    continue
                if edge.locked and edge.key_id and edge.key_id not in held_keys:
                    continue
                if edge.source not in visited:
                    if edge.source == goal:
                        return dist + 1
                    visited.add(edge.source)
                    frontier.append((edge.source, dist + 1))
        return 999


class CautiousAgent(AgentStrategy):
    """Prefers edges with low patrol density and high cover.

    Models a careful stealth player who avoids danger.
    """

    name = "cautious"

    def choose_edge(
        self,
        graph: LevelGraph,
        current: str,
        available_edges: list[Edge],
        state: AgentState,
    ) -> Edge:
        def safety_score(e: Edge) -> float:
            return (1 - e.patrol_density) * 0.6 + e.cover_availability * 0.4

        # Check if EXIT is reachable with current keys
        exit_id = graph.find_exit().id
        exit_reachable = ShortestPathAgent._lock_aware_distance(
            graph, current, exit_id, state.held_keys
        ) < 999

        if exit_reachable:
            # Normal cautious behavior: prefer safe, unvisited edges
            non_backtrack = [
                e for e in available_edges
                if e.target not in state.visited_nodes[-3:]
            ]
            candidates = non_backtrack if non_backtrack else available_edges
            return max(candidates, key=safety_score)
        else:
            # Key-seeking mode: head toward needed KEY_ROOM via safest path
            needed = ShortestPathAgent._find_needed_keys(graph, state.held_keys)
            key_rooms = [
                nid for nid, n in graph.nodes.items()
                if n.node_type == NodeType.KEY_ROOM
                and n.provides in needed
            ]
            if key_rooms:
                # Primary: closest to key room. Secondary: safety as tiebreaker.
                best_edge = available_edges[0]
                best_dist = 999
                best_safety = -1.0
                for edge in available_edges:
                    for kr in key_rooms:
                        d = ShortestPathAgent._lock_aware_distance(
                            graph, edge.target, kr, state.held_keys
                        )
                        if d < best_dist or (d == best_dist and safety_score(edge) > best_safety):
                            best_dist = d
                            best_safety = safety_score(edge)
                            best_edge = edge
                if best_dist < 999:
                    return best_edge

            # Fallback: avoid recent, pick safest
            non_backtrack = [
                e for e in available_edges
                if e.target not in state.visited_nodes[-8:]
            ]
            candidates = non_backtrack if non_backtrack else available_edges
            return max(candidates, key=safety_score)


class ExplorerAgent(AgentStrategy):
    """Prefers unvisited nodes and side objectives.

    Models a player who explores every corner before heading to the exit.
    """

    name = "explorer"

    def choose_edge(
        self,
        graph: LevelGraph,
        current: str,
        available_edges: list[Edge],
        state: AgentState,
    ) -> Edge:
        visited_set = set(state.visited_nodes)

        # Prefer unvisited targets
        unvisited = [e for e in available_edges if e.target not in visited_set]
        if unvisited:
            # Prefer side objectives
            side_obj = [
                e for e in unvisited
                if graph.get_node(e.target).node_type == NodeType.SIDE_OBJECTIVE
            ]
            if side_obj:
                return side_obj[0]
            return random.choice(unvisited)

        # All visited — pick the one closest to exit to make progress
        return ShortestPathAgent().choose_edge(
            graph, current, available_edges, state
        )


class LevelSimulator:
    """Runs an agent through a level graph and records the tension trace.

    This is the main interface used by the fitness evaluator.
    """

    def __init__(
        self,
        strategy: AgentStrategy | None = None,
        tension_weights: TensionWeights | None = None,
        max_steps: int = 400,
    ) -> None:
        self.strategy = strategy or ShortestPathAgent()
        self.calculator = TensionCalculator(tension_weights)
        self.max_steps = max_steps

    def simulate(self, graph: LevelGraph) -> SimulationResult:
        """Run one simulation from ENTRY to EXIT.

        Returns a :class:`SimulationResult` with the tension trace.
        """
        entry = graph.find_entry()
        exit_node = graph.find_exit()

        state = AgentState(current_node=entry.id)
        result = SimulationResult(path=[], tension_trace=[])

        # Record tension at ENTRY (no incoming edge)
        node = graph.get_node(entry.id)
        t0 = self.calculator.compute(graph, node, None, state)
        state.visited_nodes.append(entry.id)
        result.path.append(entry.id)
        result.tension_trace.append(t0)

        # Pick up key if entry is a key room (unlikely but handle it)
        if node.provides:
            state.held_keys.add(node.provides)

        for step in range(self.max_steps):
            current_id = state.current_node

            # Check if we reached the exit
            if current_id == exit_node.id:
                result.reached_exit = True
                break

            # Get available edges (respect locks with current keys)
            available = self._get_available_edges(graph, current_id, state)
            if not available:
                break  # stuck

            # Agent chooses an edge
            chosen_edge = self.strategy.choose_edge(
                graph, current_id, available, state
            )

            # Move to the target node
            next_id = chosen_edge.target
            next_node = graph.get_node(next_id)

            # Pick up key if this is a KEY_ROOM
            if next_node.provides:
                state.held_keys.add(next_node.provides)
                if next_node.provides not in result.keys_collected:
                    result.keys_collected.append(next_node.provides)

            # Compute tension
            tension = self.calculator.compute(
                graph, next_node, chosen_edge, state
            )

            # Update state
            state.current_node = next_id
            state.visited_nodes.append(next_id)
            state.tension_trace.append(tension)

            result.path.append(next_id)
            result.tension_trace.append(tension)

        result.total_steps = len(result.path)
        return result

    def simulate_multi(
        self,
        graph: LevelGraph,
        strategies: list[AgentStrategy] | None = None,
    ) -> list[SimulationResult]:
        """Run multiple agents and return all results.

        If no strategies provided, runs all three built-in agents.
        Useful for evaluating a level's robustness across player types.
        """
        if strategies is None:
            strategies = [ShortestPathAgent(), CautiousAgent(), ExplorerAgent()]

        results = []
        for strat in strategies:
            self.strategy = strat
            results.append(self.simulate(graph))
        return results

    @staticmethod
    def _get_available_edges(
        graph: LevelGraph,
        node_id: str,
        state: AgentState,
    ) -> list[Edge]:
        """Get traversable edges from the current node.

        Includes outgoing edges (forward) and, when no forward edges
        are passable, incoming non-one-way edges (backtrack).
        For backtracking edges, source and target are swapped so
        ``edge.target`` always points to the destination.
        """
        forward = []
        for edge in graph.out_edges(node_id):
            if edge.locked:
                if edge.key_id and edge.key_id not in state.held_keys:
                    continue
            forward.append(edge)

        if forward:
            return forward

        # Dead end — try backtracking through incoming edges
        from dataclasses import replace
        backward = []
        for edge in graph.in_edges(node_id):
            if edge.one_way:
                continue
            if edge.locked:
                if edge.key_id and edge.key_id not in state.held_keys:
                    continue
            # Create a reversed view so edge.target = where the agent goes
            rev = Edge(
                id=edge.id + "_rev",
                source=edge.target,
                target=edge.source,
                locked=edge.locked,
                traversal_type=edge.traversal_type,
                visibility=edge.visibility,
                one_way=False,
                attrs=dict(edge.attrs),
            )
            backward.append(rev)
        return backward
