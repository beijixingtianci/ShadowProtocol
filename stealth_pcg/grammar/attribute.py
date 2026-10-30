"""
stealth_pcg.grammar.attribute
=============================
Attribute rules that modify edge/node attributes without changing
graph topology.  After v2 revision: A2, A4, A5, A6.
(A1 and A3 were removed — see change log.)
"""

from __future__ import annotations

from stealth_pcg.core.graph import LevelGraph
from stealth_pcg.core.types import (
    ApproachTag,
    NoiseLevel,
    NodeType,
    TraversalType,
    Visibility,
    DEFAULT_NOISE,
    DEFAULT_THREAT,
    TRAVERSAL_TO_TAGS,
)
from stealth_pcg.grammar.rule_base import Rule, Match


class A2_ThreatDerivation(Rule):
    """A2: Derive edge threat attributes from adjacent node types.

    Edges adjacent to HIGH_SECURITY or CHOKE nodes get elevated
    patrol_density, reduced cover_availability, and increased exposure.
    """

    name = "A2"

    HIGH_THREAT_TYPES = {NodeType.HIGH_SECURITY, NodeType.CHOKE, NodeType.OBJECTIVE}

    def find_matches(self, graph: LevelGraph) -> list[Match]:
        matches = []
        for eid, edge in graph.edges.items():
            src = graph.get_node(edge.source)
            tgt = graph.get_node(edge.target)
            if (src.node_type in self.HIGH_THREAT_TYPES
                    or tgt.node_type in self.HIGH_THREAT_TYPES):
                if "patrol_density" not in edge.attrs:
                    matches.append(Match(edges=[eid]))
        return matches

    def apply(self, graph: LevelGraph, match: Match) -> None:
        for eid in match.edges:
            edge = graph.get_edge(eid)
            src = graph.get_node(edge.source)
            tgt = graph.get_node(edge.target)

            is_src_high = src.node_type in self.HIGH_THREAT_TYPES
            is_tgt_high = tgt.node_type in self.HIGH_THREAT_TYPES

            if is_src_high and is_tgt_high:
                edge.patrol_density = 0.9
                edge.cover_availability = 0.1
                edge.exposure_length = 3
            elif is_src_high or is_tgt_high:
                edge.patrol_density = 0.6
                edge.cover_availability = 0.3
                edge.exposure_length = 2


class A4_KeyLockValidation(Rule):
    """A4: Verify key-lock pair existence.

    Checks two things:
    1. Every locked edge has a key_id or requires.
    2. A KEY_ROOM providing that key_id exists in the graph.

    Reachability (can the player actually reach the KEY_ROOM in the
    correct order?) is verified separately by ``LevelGraph.is_solvable()``,
    which uses iterative key-expansion BFS.  A4 and is_solvable() are
    complementary: A4 checks *existence*, is_solvable() checks *reachability*.
    """

    name = "A4"

    def find_matches(self, graph: LevelGraph) -> list[Match]:
        violations = []
        for eid, edge in graph.edges.items():
            if not edge.locked:
                continue
            key_id = edge.key_id
            if key_id is None and not edge.requires:
                violations.append(Match(
                    edges=[eid],
                    data={"reason": "locked edge has no key_id or requires"},
                ))
                continue
            if key_id is not None:
                providers = [
                    n for n in graph.nodes.values()
                    if n.node_type == NodeType.KEY_ROOM and n.provides == key_id
                ]
                if not providers:
                    violations.append(Match(
                        edges=[eid],
                        data={"reason": f"no KEY_ROOM provides {key_id}"},
                    ))
        return violations

    def apply(self, graph: LevelGraph, match: Match) -> None:
        reason = match.data.get("reason", "unknown")
        edge_id = match.edges[0]
        raise ValueError(
            f"Key-lock validation failed on edge {edge_id}: {reason}"
        )

    def validate(self, graph: LevelGraph) -> list[str]:
        """Return a list of violation descriptions (empty = valid)."""
        violations = self.find_matches(graph)
        return [m.data.get("reason", "unknown") for m in violations]


class A5_NoiseConsistency(Rule):
    """A5: Ensure traversal type and noise level are consistent."""

    name = "A5"

    def find_matches(self, graph: LevelGraph) -> list[Match]:
        matches = []
        for eid, edge in graph.edges.items():
            if "noise_level" not in edge.attrs:
                matches.append(Match(edges=[eid]))
        return matches

    def apply(self, graph: LevelGraph, match: Match) -> None:
        for eid in match.edges:
            edge = graph.get_edge(eid)
            edge.noise_level = DEFAULT_NOISE.get(edge.traversal_type, NoiseLevel.LOW)


class A6_StyleTagPropagation(Rule):
    """A6: Compute reachable approach styles for each node.

    Measures *structural* style diversity — the set of play styles
    that the graph topology theoretically supports, ignoring locks.
    This is intentional: A6 measures what the graph *could* support,
    not what a specific key-acquisition order guarantees.
    """

    name = "A6"

    def find_matches(self, graph: LevelGraph) -> list[Match]:
        return [Match(nodes=list(graph.nodes.keys()))]

    def apply(self, graph: LevelGraph, match: Match) -> None:
        entry = graph.find_entry()

        styles: dict[str, set[ApproachTag]] = {
            entry.id: {ApproachTag.STEALTH}
        }

        changed = True
        while changed:
            changed = False
            for nid in list(graph.nodes.keys()):
                if nid not in styles:
                    continue
                for edge in graph.out_edges(nid):
                    edge_styles = edge.approach_tags
                    new_styles = styles[nid] | edge_styles

                    if edge.target not in styles:
                        styles[edge.target] = new_styles
                        changed = True
                    elif not new_styles.issubset(styles[edge.target]):
                        styles[edge.target] = styles[edge.target] | new_styles
                        changed = True

        for nid, node in graph.nodes.items():
            node.attrs["reachable_styles"] = styles.get(nid, set())

    def check_diversity(self, graph: LevelGraph, min_styles: int = 2) -> bool:
        exit_node = graph.find_exit()
        styles = exit_node.attrs.get("reachable_styles", set())
        return len(styles) >= min_styles
