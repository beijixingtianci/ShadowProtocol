"""
stealth_pcg.grammar.structural
===============================
Structural rules S1–S6 that modify graph topology (v2 §3.1).

Each rule is a subclass of :class:`Rule` with specific match/apply logic.
"""

from __future__ import annotations

import random
from typing import Any

from stealth_pcg.core.graph import LevelGraph, Node, Edge
from stealth_pcg.core.types import (
    NodeType, TraversalType, Visibility, NoiseLevel,
)
from stealth_pcg.grammar.rule_base import Rule, Match


class S1_BasicMissionExpand(Rule):
    """S1: ENTRY → EXIT  ⇒  ENTRY → TRANSIT → OBJECTIVE → TRANSIT → EXIT

    The most basic mission structure.  Only fires on a direct ENTRY→EXIT edge
    to prevent double application.
    """

    name = "S1"

    def find_matches(self, graph: LevelGraph) -> list[Match]:
        matches = []
        for eid, edge in graph.edges.items():
            src = graph.get_node(edge.source)
            tgt = graph.get_node(edge.target)
            if src.node_type == NodeType.ENTRY and tgt.node_type == NodeType.EXIT:
                matches.append(Match(
                    nodes=[src.id, tgt.id],
                    edges=[eid],
                ))
        return matches

    def apply(self, graph: LevelGraph, match: Match) -> None:
        entry_id, exit_id = match.nodes
        edge_id = match.edges[0]

        # Remove original edge
        graph.remove_edge(edge_id)

        # Insert: ENTRY → TRANSIT → OBJECTIVE → TRANSIT → EXIT
        t1 = graph.add_node(NodeType.TRANSIT)
        obj = graph.add_node(NodeType.OBJECTIVE)
        t2 = graph.add_node(NodeType.TRANSIT)

        graph.add_edge(entry_id, t1.id, rule_origin=self.name)
        graph.add_edge(t1.id, obj.id, rule_origin=self.name)
        graph.add_edge(obj.id, t2.id, rule_origin=self.name)
        graph.add_edge(t2.id, exit_id, rule_origin=self.name)


class S2_KeyLock(Rule):
    """S2: A --[unlocked]--> B  ⇒  A branches to KEY_ROOM, A --[locked]--> B

    Selects an unlocked, non-locked edge and converts it into a key-lock
    pattern.  A new KEY_ROOM is branched off the source, and the original
    edge becomes locked.

    A global key counter ensures unique key IDs.
    """

    name = "S2"

    _key_counter: int = 0

    @classmethod
    def reset_counter(cls) -> None:
        cls._key_counter = 0

    #: Node types that are valid lock targets (functional rooms, not corridors)
    LOCK_TARGET_TYPES = {
        NodeType.OBJECTIVE, NodeType.HIGH_SECURITY, NodeType.CHOKE,
        NodeType.EXIT, NodeType.KEY_ROOM,
    }

    def find_matches(self, graph: LevelGraph) -> list[Match]:
        matches = []
        for eid, edge in graph.edges.items():
            if edge.locked:
                continue
            if edge.source == edge.target:
                continue
            src = graph.get_node(edge.source)
            tgt = graph.get_node(edge.target)
            if src.node_type == NodeType.ENTRY and tgt.node_type == NodeType.EXIT:
                continue
            if edge.rule_origin == "S2_branch":
                continue
            # Only lock edges whose target is a functional node type
            if tgt.node_type not in self.LOCK_TARGET_TYPES:
                continue
            matches.append(Match(
                nodes=[edge.source, edge.target],
                edges=[eid],
            ))
        return matches

    def apply(self, graph: LevelGraph, match: Match) -> None:
        src_id = match.nodes[0]
        edge_id = match.edges[0]
        edge = graph.get_edge(edge_id)

        # Generate unique key ID
        S2_KeyLock._key_counter += 1
        key_id = f"K{S2_KeyLock._key_counter}"

        # Lock the edge
        edge.locked = True
        edge.key_id = key_id

        # Create KEY_ROOM branching from source
        key_room = graph.add_node(NodeType.KEY_ROOM, provides=key_id)
        graph.add_edge(src_id, key_room.id, rule_origin="S2_branch")
        # Return edge (player goes back to source after getting key)
        graph.add_edge(key_room.id, src_id, rule_origin="S2_branch")


class S3_RhythmControl(Rule):
    """S3: HIGH_SECURITY → HIGH_SECURITY  ⇒  insert OBSERVATION between.

    Stealth-genre specific: prevents two consecutive high-threat zones
    by injecting a breathing point.
    """

    name = "S3"

    #: Node types considered "high-threat" for rhythm purposes
    HIGH_THREAT_TYPES = {NodeType.HIGH_SECURITY, NodeType.CHOKE, NodeType.OBJECTIVE}

    def find_matches(self, graph: LevelGraph) -> list[Match]:
        matches = []
        for eid, edge in graph.edges.items():
            src = graph.get_node(edge.source)
            tgt = graph.get_node(edge.target)
            if (src.node_type in self.HIGH_THREAT_TYPES
                    and tgt.node_type in self.HIGH_THREAT_TYPES):
                # Don't insert if there's already an OBSERVATION between
                matches.append(Match(
                    nodes=[src.id, tgt.id],
                    edges=[eid],
                ))
        return matches

    def apply(self, graph: LevelGraph, match: Match) -> None:
        src_id, tgt_id = match.nodes
        edge_id = match.edges[0]
        old_edge = graph.get_edge(edge_id)

        # Preserve the old edge's lock state
        was_locked = old_edge.locked
        old_key_id = old_edge.key_id

        graph.remove_edge(edge_id)

        obs = graph.add_node(NodeType.OBSERVATION, safe_zone=True)

        # src → OBSERVATION (low threat)
        graph.add_edge(
            src_id, obs.id,
            rule_origin=self.name,
            patrol_density=0.1,
            cover_availability=0.8,
        )
        # OBSERVATION → target (transfer lock if any)
        e2 = graph.add_edge(
            obs.id, tgt_id,
            locked=was_locked,
            rule_origin=self.name,
            patrol_density=0.1,
            cover_availability=0.8,
        )
        if old_key_id:
            e2.key_id = old_key_id


class S4_PathDiversification(Rule):
    """S4: A → B  ⇒  keep A → B, add A → ALT_PATH → B.

    The alternative path gets a different traversal type (vent/climb/hack)
    and hidden visibility by default.
    """

    name = "S4"

    #: Traversal types for alternative paths
    ALT_TRAVERSALS = [TraversalType.VENT, TraversalType.CLIMB, TraversalType.HACK]

    def __init__(self, *, apply_probability: float = 0.4) -> None:
        self.apply_probability = apply_probability

    def find_matches(self, graph: LevelGraph) -> list[Match]:
        matches = []
        for eid, edge in graph.edges.items():
            # Only normal traversal edges, not already alternatives
            if edge.traversal_type != TraversalType.NORMAL:
                continue
            if edge.alternative_to is not None:
                continue
            # Don't bypass locked edges (preserve key-lock structure)
            if edge.locked:
                continue
            # Don't diversify edges into/out of ENTRY/EXIT directly
            src = graph.get_node(edge.source)
            tgt = graph.get_node(edge.target)
            if src.node_type == NodeType.ENTRY or tgt.node_type == NodeType.EXIT:
                continue
            # Don't create alt if one already exists between these nodes
            existing_alts = [
                e for e in graph.edges_between(edge.source, edge.target)
                if e.id != eid
            ]
            if existing_alts:
                continue
            matches.append(Match(
                nodes=[edge.source, edge.target],
                edges=[eid],
            ))
        return matches

    def apply(self, graph: LevelGraph, match: Match) -> None:
        src_id, tgt_id = match.nodes
        main_edge_id = match.edges[0]

        # Create ALT_PATH node
        alt_node = graph.add_node(NodeType.ALT_PATH)

        # Choose a random alternative traversal type
        alt_traversal = random.choice(self.ALT_TRAVERSALS)

        # src → ALT_PATH
        graph.add_edge(
            src_id, alt_node.id,
            traversal_type=alt_traversal,
            visibility=Visibility.HIDDEN,
            rule_origin=self.name,
            alternative_to=main_edge_id,
            mandatory=False,
            noise_level=NoiseLevel.SILENT,
        )
        # ALT_PATH → target
        graph.add_edge(
            alt_node.id, tgt_id,
            traversal_type=alt_traversal,
            visibility=Visibility.HIDDEN,
            rule_origin=self.name,
            alternative_to=main_edge_id,
            mandatory=False,
            noise_level=NoiseLevel.SILENT,
        )


class S5_SideObjective(Rule):
    """S5: TRANSIT  ⇒  branch to SIDE_OBJECTIVE.

    Adds optional exploration value to transit areas.
    """

    name = "S5"

    def find_matches(self, graph: LevelGraph) -> list[Match]:
        matches = []
        for nid, node in graph.nodes.items():
            if node.node_type != NodeType.TRANSIT:
                continue
            # Don't add if this transit already has a side objective
            has_side = any(
                graph.get_node(e.target).node_type == NodeType.SIDE_OBJECTIVE
                for e in graph.out_edges(nid)
            )
            if has_side:
                continue
            matches.append(Match(nodes=[nid]))
        return matches

    def apply(self, graph: LevelGraph, match: Match) -> None:
        transit_id = match.nodes[0]

        side = graph.add_node(NodeType.SIDE_OBJECTIVE, safe_zone=True)
        graph.add_edge(
            transit_id, side.id,
            rule_origin=self.name,
            mandatory=False,
        )
        # Return edge
        graph.add_edge(
            side.id, transit_id,
            rule_origin=self.name,
            mandatory=False,
        )


class S6_ChokePoint(Rule):
    """S6: Insert CHOKE node on the main path.

    Picks an edge on the mandatory path and inserts a CHOKE node,
    setting high patrol density on the surrounding edges.
    """

    name = "S6"

    def find_matches(self, graph: LevelGraph) -> list[Match]:
        crit_path = graph.critical_path()
        if crit_path is None or len(crit_path) < 3:
            return []

        matches = []
        # Consider edges along the critical path (skip first and last segments)
        for i in range(1, len(crit_path) - 1):
            a, b = crit_path[i], crit_path[i + 1] if i + 1 < len(crit_path) else None
            if b is None:
                continue
            node_a = graph.get_node(a)
            node_b = graph.get_node(b)
            # Don't insert choke adjacent to ENTRY/EXIT or existing CHOKE
            if node_a.node_type in {NodeType.ENTRY, NodeType.EXIT, NodeType.CHOKE}:
                continue
            if node_b.node_type in {NodeType.ENTRY, NodeType.EXIT, NodeType.CHOKE}:
                continue
            edges = graph.edges_between(a, b)
            if edges:
                matches.append(Match(
                    nodes=[a, b],
                    edges=[edges[0].id],
                ))
        return matches

    def apply(self, graph: LevelGraph, match: Match) -> None:
        src_id, tgt_id = match.nodes
        edge_id = match.edges[0]
        old_edge = graph.get_edge(edge_id)

        # Preserve lock state
        was_locked = old_edge.locked
        old_key_id = old_edge.key_id

        graph.remove_edge(edge_id)

        choke = graph.add_node(NodeType.CHOKE)

        graph.add_edge(
            src_id, choke.id,
            rule_origin=self.name,
            patrol_density=0.8,
            cover_availability=0.2,
        )
        e2 = graph.add_edge(
            choke.id, tgt_id,
            locked=was_locked,
            rule_origin=self.name,
            patrol_density=0.8,
            cover_availability=0.2,
        )
        if old_key_id:
            e2.key_id = old_key_id


class S7_CorridorExpansion(Rule):
    """S7: Expand a TRANSIT into a corridor of 2+ nodes.

    Makes the level physically larger without adding mechanical complexity.
    Randomly upgrades one new node to HIGH_SECURITY for variety.
    """

    name = "S7"

    def __init__(self, *, expansion_length: int = 2) -> None:
        self.expansion_length = expansion_length

    def find_matches(self, graph: LevelGraph) -> list[Match]:
        matches = []
        for nid, node in graph.nodes.items():
            if node.node_type != NodeType.TRANSIT:
                continue
            if node.attrs.get("expanded"):
                continue
            mandatory_out = [e for e in graph.out_edges(nid) if e.mandatory]
            if not mandatory_out:
                continue
            matches.append(Match(nodes=[nid]))
        return matches

    def apply(self, graph: LevelGraph, match: Match) -> None:
        original_id = match.nodes[0]
        original = graph.get_node(original_id)
        original.attrs["expanded"] = True

        mandatory_out = [e for e in graph.out_edges(original_id) if e.mandatory]
        if not mandatory_out:
            return
        edge_to_stretch = mandatory_out[0]
        target_id = edge_to_stretch.target
        was_locked = edge_to_stretch.locked
        old_key_id = edge_to_stretch.key_id

        graph.remove_edge(edge_to_stretch.id)

        prev_id = original_id
        for i in range(self.expansion_length):
            if i == self.expansion_length - 1 and random.random() < 0.3:
                new_type = NodeType.HIGH_SECURITY
            else:
                new_type = NodeType.TRANSIT
            new_node = graph.add_node(new_type)
            new_node.attrs["expanded"] = True
            graph.add_edge(prev_id, new_node.id, rule_origin=self.name)
            prev_id = new_node.id

        e_final = graph.add_edge(
            prev_id, target_id, locked=was_locked, rule_origin=self.name,
        )
        if old_key_id:
            e_final.key_id = old_key_id


class S8_MultiObjective(Rule):
    """S8: Insert an additional OBJECTIVE segment on the critical path.

    Inserts TRANSIT → OBJECTIVE → TRANSIT between two existing nodes.
    Each new OBJECTIVE can later be targeted by S2/S6 for cascade expansion.
    """

    name = "S8"

    def find_matches(self, graph: LevelGraph) -> list[Match]:
        crit_path = graph.critical_path()
        if crit_path is None or len(crit_path) < 3:
            return []

        matches = []
        for i in range(len(crit_path) - 1):
            a, b = crit_path[i], crit_path[i + 1]
            na = graph.get_node(a)
            nb = graph.get_node(b)
            if na.node_type in {NodeType.ENTRY, NodeType.OBJECTIVE}:
                continue
            if nb.node_type in {NodeType.EXIT, NodeType.OBJECTIVE}:
                continue
            edges = graph.edges_between(a, b)
            if edges:
                matches.append(Match(nodes=[a, b], edges=[edges[0].id]))
        return matches

    def apply(self, graph: LevelGraph, match: Match) -> None:
        src_id, tgt_id = match.nodes
        edge_id = match.edges[0]
        old_edge = graph.get_edge(edge_id)
        was_locked = old_edge.locked
        old_key_id = old_edge.key_id

        graph.remove_edge(edge_id)

        t1 = graph.add_node(NodeType.TRANSIT)
        obj = graph.add_node(NodeType.OBJECTIVE)
        t2 = graph.add_node(NodeType.TRANSIT)

        graph.add_edge(src_id, t1.id, rule_origin=self.name)
        graph.add_edge(t1.id, obj.id, rule_origin=self.name)
        graph.add_edge(obj.id, t2.id, rule_origin=self.name)
        e_final = graph.add_edge(
            t2.id, tgt_id, locked=was_locked, rule_origin=self.name,
        )
        if old_key_id:
            e_final.key_id = old_key_id


class S9_FunctionalNodeBuffer(Rule):
    """S9: Insert TRANSIT between directly connected functional nodes.

    Functional nodes (ENTRY, EXIT, OBJECTIVE, SIDE_OBJECTIVE, HIGH_SECURITY,
    CHOKE, KEY_ROOM) should not be directly adjacent without a corridor
    buffer.  S9 inserts a TRANSIT where both endpoints are functional.

    Must run AFTER S3 so OBSERVATION insertions are already in place.
    """

    name = "S9"

    FUNCTIONAL_TYPES = {
        NodeType.ENTRY, NodeType.EXIT,
        NodeType.OBJECTIVE, NodeType.SIDE_OBJECTIVE,
        NodeType.HIGH_SECURITY, NodeType.CHOKE, NodeType.KEY_ROOM,
    }

    def find_matches(self, graph: LevelGraph) -> list[Match]:
        matches = []
        for eid, edge in graph.edges.items():
            src = graph.get_node(edge.source)
            tgt = graph.get_node(edge.target)
            if (src.node_type in self.FUNCTIONAL_TYPES
                    and tgt.node_type in self.FUNCTIONAL_TYPES):
                matches.append(Match(
                    nodes=[edge.source, edge.target],
                    edges=[eid],
                ))
        return matches

    def apply(self, graph: LevelGraph, match: Match) -> None:
        src_id, tgt_id = match.nodes
        edge_id = match.edges[0]
        old_edge = graph.get_edge(edge_id)

        was_locked = old_edge.locked
        old_key_id = old_edge.key_id

        graph.remove_edge(edge_id)

        buf = graph.add_node(NodeType.TRANSIT)

        graph.add_edge(src_id, buf.id, rule_origin=self.name)
        e2 = graph.add_edge(
            buf.id, tgt_id, locked=was_locked, rule_origin=self.name,
        )
        if old_key_id:
            e2.key_id = old_key_id
