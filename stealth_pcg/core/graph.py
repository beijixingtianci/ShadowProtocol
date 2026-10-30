"""
stealth_pcg.core.graph
======================
Attributed single-layer spatial graph — the canonical level representation.

Design decisions (v2 §1.2):
* Single layer with rich edge attributes encodes both spatial connectivity
  and mission dependencies (key-lock ordering, traversal conditions).
* Nodes carry a *type* and an open attribute dict for extensibility.
* Edges carry four *required* attributes (locked, traversal_type, visibility,
  one_way) plus an open attribute dict for optional attributes.
* The graph supports efficient neighbor queries, path search, and deep copy.
"""

from __future__ import annotations

import copy
import itertools
from collections import defaultdict
from dataclasses import dataclass, field
from typing import Any, Iterator

from stealth_pcg.core.types import (
    ApproachTag,
    NoiseLevel,
    NodeType,
    ThreatLevel,
    TraversalType,
    Visibility,
    WallMaterial,
    window_capacity,
    compute_sound_leak,
    compute_visual_leak,
    DEFAULT_NOISE,
    DEFAULT_THREAT,
    TRAVERSAL_TO_TAGS,


)


# ──────────────────────────────────────────────
# ID generation
# ──────────────────────────────────────────────

class _IDGen:
    """Thread-unsafe but deterministic ID generator.  Resettable for tests."""

    def __init__(self) -> None:
        self._counters: dict[str, int] = defaultdict(int)

    def next(self, prefix: str = "n") -> str:
        self._counters[prefix] += 1
        return f"{prefix}_{self._counters[prefix]:04d}"

    def reset(self) -> None:
        self._counters.clear()


_id_gen = _IDGen()


def reset_id_generator() -> None:
    """Reset the global ID generator (call at the start of each generation run)."""
    _id_gen.reset()


# ──────────────────────────────────────────────
# Node
# ──────────────────────────────────────────────

@dataclass
class Node:
    """A spatial unit in the level graph.

    Attributes:
        id:         Unique identifier (auto-generated if not supplied).
        node_type:  Functional type from :class:`NodeType`.
        attrs:      Open dictionary for additional attributes.
                    Common keys: ``provides`` (key_id this room provides),
                    ``threat_level``, ``reachable_styles``.
    """

    id: str
    node_type: NodeType
    attrs: dict[str, Any] = field(default_factory=dict)

    # Convenience shortcuts ------------------------------------------------

    @property
    def provides(self) -> str | None:
        """Key ID this node provides (KEY_ROOM only)."""
        return self.attrs.get("provides")

    @provides.setter
    def provides(self, value: str | None) -> None:
        if value is None:
            self.attrs.pop("provides", None)
        else:
            self.attrs["provides"] = value

    def __repr__(self) -> str:
        extra = ""
        if self.provides:
            extra = f", provides={self.provides!r}"
        return f"Node({self.id!r}, {self.node_type.value}{extra})"


# ──────────────────────────────────────────────
# Edge
# ──────────────────────────────────────────────

@dataclass
class Edge:
    """A directed connection between two nodes with rich attributes.

    Required attributes (v2 §2.2.1) are explicit fields.
    Optional attributes live in ``attrs`` (v2 §2.2.2).
    """

    id: str
    source: str          # node ID
    target: str          # node ID

    # ── Required attributes (always present) ──
    locked: bool = False
    traversal_type: TraversalType = TraversalType.NORMAL
    visibility: Visibility = Visibility.OBVIOUS
    one_way: bool = False

    # ── Optional attributes (open dict) ──
    attrs: dict[str, Any] = field(default_factory=dict)

    # Convenience properties for frequently accessed optional attrs --------

    @property
    def key_id(self) -> str | None:
        return self.attrs.get("key_id")

    @key_id.setter
    def key_id(self, value: str | None) -> None:
        if value is None:
            self.attrs.pop("key_id", None)
        else:
            self.attrs["key_id"] = value

    @property
    def requires(self) -> list[str]:
        return self.attrs.get("requires", [])

    @requires.setter
    def requires(self, value: list[str]) -> None:
        self.attrs["requires"] = value

    @property
    def mandatory(self) -> bool:
        return self.attrs.get("mandatory", True)

    @mandatory.setter
    def mandatory(self, value: bool) -> None:
        self.attrs["mandatory"] = value

    @property
    def alternative_to(self) -> str | None:
        return self.attrs.get("alternative_to")

    @alternative_to.setter
    def alternative_to(self, value: str | None) -> None:
        if value is None:
            self.attrs.pop("alternative_to", None)
        else:
            self.attrs["alternative_to"] = value

    @property
    def rule_origin(self) -> str | None:
        return self.attrs.get("rule_origin")

    @rule_origin.setter
    def rule_origin(self, value: str | None) -> None:
        if value is None:
            self.attrs.pop("rule_origin", None)
        else:
            self.attrs["rule_origin"] = value

    @property
    def patrol_density(self) -> float:
        return self.attrs.get("patrol_density", 0.3)

    @patrol_density.setter
    def patrol_density(self, value: float) -> None:
        self.attrs["patrol_density"] = max(0.0, min(1.0, value))

    @property
    def cover_availability(self) -> float:
        return self.attrs.get("cover_availability", 0.5)

    @cover_availability.setter
    def cover_availability(self, value: float) -> None:
        self.attrs["cover_availability"] = max(0.0, min(1.0, value))

    @property
    def exposure_length(self) -> int:
        return self.attrs.get("exposure_length", 1)

    @exposure_length.setter
    def exposure_length(self, value: int) -> None:
        self.attrs["exposure_length"] = max(1, value)

    @property
    def noise_level(self) -> NoiseLevel:
        return self.attrs.get("noise_level", DEFAULT_NOISE.get(self.traversal_type, NoiseLevel.LOW))

    @noise_level.setter
    def noise_level(self, value: NoiseLevel) -> None:
        self.attrs["noise_level"] = value

    @property
    def approach_tags(self) -> set[ApproachTag]:
        stored = self.attrs.get("approach_tags")
        if stored is not None:
            return stored
        return TRAVERSAL_TO_TAGS.get(self.traversal_type, {ApproachTag.STEALTH})

    @approach_tags.setter
    def approach_tags(self, value: set[ApproachTag]) -> None:
        self.attrs["approach_tags"] = value

    def __repr__(self) -> str:
        lock_str = " [LOCKED]" if self.locked else ""
        return (
            f"Edge({self.id!r}, {self.source}->{self.target}, "
            f"{self.traversal_type.value}{lock_str})"
        )


# ──────────────────────────────────────────────
# ProximityLink
# ──────────────────────────────────────────────

@dataclass
class SharedWall:
    """두 방이 공유하는 비통행 경계면.

    통행 엣지가 '지나갈 수 있는 연결'이라면 이쪽은 '지나갈 수는 없지만
    소리와 시야가 새는 면'이다. 네 축이 서로 독립이다.

      material    재질 — 차음 계수와 투명도
      thickness   두께 0.1~1.0 — 차음량만
      separation  이격(타일) — 제6단계 교정의 주 지렛대, 눈에 보이지 않는다
      window_count 창문 수 — 청각과 시각을 따로 밀 수 있는 유일한 축

    sound_leak / visual_leak 는 저장값이 아니라 네 축에서 파생된다.
    창문은 통행 불가이다. 창을 넘어갈 수 있게 하려면 그것은 문법 단계가
    만드는 traversal_type=climb 엣지여야 하며, 여기서 다룰 일이 아니다.
    """

    id: str
    node_a: str
    node_b: str
    material: WallMaterial = WallMaterial.DRYWALL
    thickness: float = 0.5
    separation: int = 0
    window_count: int = 0
    length_tiles: float = 8.0
    between: tuple[tuple[int, int], tuple[int, int]] | None = None  # 격자 셀 쌍

    def __post_init__(self) -> None:
        self.thickness = max(0.1, min(1.0, float(self.thickness)))
        self.separation = max(0, int(self.separation))
        self.window_count = max(0, min(self.capacity, int(self.window_count)))

    @property
    def capacity(self) -> int:
        return window_capacity(self.length_tiles, self.material)

    @property
    def sound_leak(self) -> float:
        return compute_sound_leak(self.material, self.thickness,
                                  self.separation, self.window_count,
                                  self.length_tiles)

    @property
    def visual_leak(self) -> float:
        return compute_visual_leak(self.material, self.separation,
                                   self.window_count)

    def __repr__(self) -> str:
        return (f"SharedWall({self.id!r}, {self.node_a}~{self.node_b}, "
                f"{self.material.value} t={self.thickness:.1f} "
                f"sep={self.separation} win={self.window_count}, "
                f"snd={self.sound_leak:.2f}, vis={self.visual_leak:.2f})")


#: 구버전 이름 호환
ProximityLink = SharedWall


# ──────────────────────────────────────────────
# LevelGraph
# ──────────────────────────────────────────────

class LevelGraph:
    """Attributed directed graph representing a single level.

    Provides O(1) node/edge lookup, O(degree) neighbor queries,
    and convenience methods for path analysis and rule application.

    Includes a *proximity layer*: non-traversable spatial adjacency
    links that model sound/visual leakage between rooms sharing a wall.
    """

    def __init__(self) -> None:
        self._nodes: dict[str, Node] = {}
        self._edges: dict[str, Edge] = {}
        self._proximity: dict[str, SharedWall] = {}
        # Adjacency: node_id -> list of edge_ids
        self._out_edges: dict[str, list[str]] = defaultdict(list)
        self._in_edges: dict[str, list[str]] = defaultdict(list)
        # Proximity adjacency: node_id -> list of proximity_ids
        self._prox_adj: dict[str, list[str]] = defaultdict(list)

    # ── Factory ───────────────────────────────

    @classmethod
    def make_initial(cls) -> LevelGraph:
        """Create the seed graph: ``ENTRY --e0--> EXIT``.

        This is Stage 0 of the grammar expansion (v2 §4).
        """
        g = cls()
        entry = g.add_node(NodeType.ENTRY, safe_zone=True)
        exit_ = g.add_node(NodeType.EXIT)
        g.add_edge(entry.id, exit_.id, rule_origin="seed")
        return g

    # ── Node operations ───────────────────────

    def add_node(
        self,
        node_type: NodeType,
        node_id: str | None = None,
        **attrs: Any,
    ) -> Node:
        """Add a node and return it."""
        if node_id is None:
            node_id = _id_gen.next("n")
        if node_id in self._nodes:
            raise ValueError(f"Duplicate node id: {node_id!r}")
        node = Node(id=node_id, node_type=node_type, attrs=dict(attrs))
        self._nodes[node_id] = node
        return node

    def get_node(self, node_id: str) -> Node:
        return self._nodes[node_id]

    def has_node(self, node_id: str) -> bool:
        return node_id in self._nodes

    def remove_node(self, node_id: str) -> None:
        """Remove a node and all its incident edges."""
        for eid in list(self._out_edges.get(node_id, [])):
            self._remove_edge_internal(eid)
        for eid in list(self._in_edges.get(node_id, [])):
            self._remove_edge_internal(eid)
        self._out_edges.pop(node_id, None)
        self._in_edges.pop(node_id, None)
        del self._nodes[node_id]

    @property
    def nodes(self) -> dict[str, Node]:
        return self._nodes

    def nodes_of_type(self, ntype: NodeType) -> list[Node]:
        return [n for n in self._nodes.values() if n.node_type == ntype]

    # ── Edge operations ───────────────────────

    def add_edge(
        self,
        source: str,
        target: str,
        edge_id: str | None = None,
        *,
        locked: bool = False,
        traversal_type: TraversalType = TraversalType.NORMAL,
        visibility: Visibility = Visibility.OBVIOUS,
        one_way: bool = False,
        rule_origin: str | None = None,
        **attrs: Any,
    ) -> Edge:
        """Add an edge with required + optional attributes and return it."""
        if source not in self._nodes:
            raise ValueError(f"Source node not found: {source!r}")
        if target not in self._nodes:
            raise ValueError(f"Target node not found: {target!r}")
        if edge_id is None:
            edge_id = _id_gen.next("e")
        if edge_id in self._edges:
            raise ValueError(f"Duplicate edge id: {edge_id!r}")
        if rule_origin is not None:
            attrs["rule_origin"] = rule_origin
        edge = Edge(
            id=edge_id,
            source=source,
            target=target,
            locked=locked,
            traversal_type=traversal_type,
            visibility=visibility,
            one_way=one_way,
            attrs=dict(attrs),
        )
        self._edges[edge_id] = edge
        self._out_edges[source].append(edge_id)
        self._in_edges[target].append(edge_id)
        return edge

    def get_edge(self, edge_id: str) -> Edge:
        return self._edges[edge_id]

    def has_edge(self, edge_id: str) -> bool:
        return edge_id in self._edges

    def remove_edge(self, edge_id: str) -> None:
        self._remove_edge_internal(edge_id)

    def _remove_edge_internal(self, edge_id: str) -> None:
        edge = self._edges.pop(edge_id, None)
        if edge is None:
            return
        try:
            self._out_edges[edge.source].remove(edge_id)
        except ValueError:
            pass
        try:
            self._in_edges[edge.target].remove(edge_id)
        except ValueError:
            pass

    @property
    def edges(self) -> dict[str, Edge]:
        return self._edges

    # ── Adjacency queries ─────────────────────

    def out_edges(self, node_id: str) -> list[Edge]:
        """Edges originating from *node_id*."""
        return [self._edges[eid] for eid in self._out_edges.get(node_id, [])]

    def in_edges(self, node_id: str) -> list[Edge]:
        """Edges arriving at *node_id*."""
        return [self._edges[eid] for eid in self._in_edges.get(node_id, [])]

    def successors(self, node_id: str) -> list[Node]:
        """Nodes reachable in one hop from *node_id* (respecting direction)."""
        return [self._nodes[e.target] for e in self.out_edges(node_id)]

    def predecessors(self, node_id: str) -> list[Node]:
        return [self._nodes[e.source] for e in self.in_edges(node_id)]

    def neighbors(self, node_id: str) -> list[Node]:
        """All adjacent nodes (ignoring direction)."""
        seen: set[str] = set()
        result: list[Node] = []
        for e in self.out_edges(node_id):
            if e.target not in seen:
                seen.add(e.target)
                result.append(self._nodes[e.target])
        for e in self.in_edges(node_id):
            if e.source not in seen:
                seen.add(e.source)
                result.append(self._nodes[e.source])
        return result

    def edges_between(self, a: str, b: str) -> list[Edge]:
        """All edges from *a* to *b*."""
        return [e for e in self.out_edges(a) if e.target == b]

    # ── Proximity operations ──────────────────

    def add_proximity(
        self,
        node_a: str,
        node_b: str,
        *,
        prox_id: str | None = None,
        material: WallMaterial = WallMaterial.DRYWALL,
        thickness: float = 0.5,
        separation: int = 0,
        window_count: int = 0,
        length_tiles: float = 8.0,
        between: tuple[tuple[int, int], tuple[int, int]] | None = None,
    ) -> SharedWall:
        """공유벽을 등록한다.

        제4단계(인접 도출)가 배치 결과의 기하에서 호출한다. 무작위 지정이
        아니라 기하적 사실의 기록이므로, '지정했지만 구현하지 못한 링크'가
        원리적으로 발생하지 않는다.
        """
        if node_a not in self._nodes:
            raise ValueError(f"Node not found: {node_a!r}")
        if node_b not in self._nodes:
            raise ValueError(f"Node not found: {node_b!r}")
        if prox_id is None:
            prox_id = _id_gen.next("p")
        link = SharedWall(
            id=prox_id, node_a=node_a, node_b=node_b,
            material=material, thickness=thickness, separation=separation,
            window_count=window_count, length_tiles=length_tiles,
            between=between,
        )
        self._proximity[prox_id] = link
        self._prox_adj[node_a].append(prox_id)
        self._prox_adj[node_b].append(prox_id)
        return link

    def remove_proximity(self, prox_id: str) -> None:
        link = self._proximity.pop(prox_id, None)
        if link is None:
            return
        self._prox_adj[link.node_a] = [
            p for p in self._prox_adj[link.node_a] if p != prox_id
        ]
        self._prox_adj[link.node_b] = [
            p for p in self._prox_adj[link.node_b] if p != prox_id
        ]

    def get_proximity(self, prox_id: str) -> SharedWall:
        return self._proximity[prox_id]

    @property
    def proximity_links(self) -> dict[str, SharedWall]:
        return self._proximity

    @property
    def proximity_count(self) -> int:
        return len(self._proximity)

    def proximity_of(self, node_id: str) -> list[SharedWall]:
        """All proximity links involving *node_id*."""
        return [self._proximity[pid] for pid in self._prox_adj.get(node_id, [])]

    def proximity_neighbors(self, node_id: str) -> list[tuple[Node, SharedWall]]:
        """Nodes spatially adjacent (not traversable) with their link info."""
        result = []
        for link in self.proximity_of(node_id):
            other_id = link.node_b if link.node_a == node_id else link.node_a
            result.append((self._nodes[other_id], link))
        return result

    def has_proximity_between(self, a: str, b: str) -> bool:
        """Check if a proximity link exists between *a* and *b*."""
        for link in self.proximity_of(a):
            if link.node_a == b or link.node_b == b:
                return True
        return False

    _THREAT_VAL = {"low": 0.1, "medium": 0.4, "high": 0.8, "variable": 0.5}

    def ambient_threat(self, node_id: str) -> tuple[float, float]:
        """공유벽 너머에서 오는 환경 위협을 청각·시각으로 나누어 돌려준다.

        재질·두께·이격·창문 네 축으로 분리한 뒤로 두 경로는 더 이상 같은
        값에서 파생되지 않는다. 유리벽은 시각만, 석고보드는 청각만 높다.
        따라서 하나의 스칼라로 합치면 그 구분이 도로 사라진다.

        Returns:
            (청각 환경 위협, 시각 환경 위협) 각각 [0, 1]
        """
        max_audio = 0.0
        max_visual = 0.0
        for neighbor, wall in self.proximity_neighbors(node_id):
            threat = DEFAULT_THREAT.get(neighbor.node_type, ThreatLevel.LOW)
            tv = self._THREAT_VAL.get(threat.value, 0.3)
            max_audio = max(max_audio, wall.sound_leak * tv)
            max_visual = max(max_visual, wall.visual_leak * tv)
        return max_audio, max_visual

    # ── Path queries ──────────────────────────

    def find_entry(self) -> Node:
        entries = self.nodes_of_type(NodeType.ENTRY)
        if not entries:
            raise ValueError("No ENTRY node in graph")
        return entries[0]

    def find_exit(self) -> Node:
        exits = self.nodes_of_type(NodeType.EXIT)
        if not exits:
            raise ValueError("No EXIT node in graph")
        return exits[0]

    def reachable_from(
        self,
        start: str,
        *,
        respect_locks: bool = False,
        held_keys: set[str] | None = None,
    ) -> set[str]:
        """BFS reachability from *start* with iterative key expansion.

        If *respect_locks* is True, locked edges are only traversable when
        the required ``key_id`` is in *held_keys*.  Keys picked up during
        traversal (from KEY_ROOM nodes) are accumulated.  When a new key
        is found the entire BFS restarts with the expanded key set, so
        previously blocked edges become traversable.  Converges in at most
        O(K+1) full passes where K is the number of distinct keys.
        """
        if held_keys is None:
            held_keys = set()
        else:
            held_keys = set(held_keys)

        prev_size = -1
        visited: set[str] = set()

        # Keep restarting until visited set stops growing
        while len(visited) != prev_size:
            prev_size = len(visited)
            visited = set()
            frontier: list[str] = [start]

            while frontier:
                nid = frontier.pop(0)
                if nid in visited:
                    continue
                visited.add(nid)

                # Pick up key if this is a KEY_ROOM
                node = self._nodes[nid]
                if node.provides:
                    held_keys.add(node.provides)

                # Outgoing edges
                for edge in self.out_edges(nid):
                    if respect_locks and edge.locked:
                        if edge.key_id and edge.key_id not in held_keys:
                            continue
                    if edge.target not in visited:
                        frontier.append(edge.target)

                # Incoming edges (for bidirectional traversal)
                for edge in self.in_edges(nid):
                    if edge.one_way:
                        continue
                    if respect_locks and edge.locked:
                        if edge.key_id and edge.key_id not in held_keys:
                            continue
                    if edge.source not in visited:
                        frontier.append(edge.source)

        return visited

    def is_solvable(self) -> bool:
        """Check whether EXIT is reachable from ENTRY respecting locks/keys."""
        entry = self.find_entry()
        exit_ = self.find_exit()
        reachable = self.reachable_from(entry.id, respect_locks=True)
        return exit_.id in reachable

    def critical_path(self) -> list[str] | None:
        """BFS shortest path (by node count) from ENTRY to EXIT, ignoring locks.

        Returns list of node IDs, or None if no path exists.
        """
        entry = self.find_entry()
        exit_ = self.find_exit()
        parent: dict[str, str | None] = {entry.id: None}
        queue: list[str] = [entry.id]

        while queue:
            nid = queue.pop(0)
            if nid == exit_.id:
                # Reconstruct
                path = []
                cur: str | None = exit_.id
                while cur is not None:
                    path.append(cur)
                    cur = parent[cur]
                return list(reversed(path))
            for edge in self.out_edges(nid):
                if edge.target not in parent:
                    parent[edge.target] = nid
                    queue.append(edge.target)
        return None

    # ── Structural info ───────────────────────

    @property
    def node_count(self) -> int:
        return len(self._nodes)

    @property
    def edge_count(self) -> int:
        return len(self._edges)

    def mandatory_edges(self) -> list[Edge]:
        """Edges on the mandatory path (mandatory=True or default)."""
        return [e for e in self._edges.values() if e.mandatory]

    # ── Copy ──────────────────────────────────

    def deep_copy(self) -> LevelGraph:
        """Return an independent deep copy of the graph."""
        return copy.deepcopy(self)

    # ── Serialization ─────────────────────────

    def to_dict(self) -> dict[str, Any]:
        """Serialize to a JSON-compatible dictionary."""
        return {
            "nodes": {
                nid: {
                    "type": n.node_type.value,
                    "attrs": n.attrs,
                }
                for nid, n in self._nodes.items()
            },
            "edges": {
                eid: {
                    "source": e.source,
                    "target": e.target,
                    "locked": e.locked,
                    "traversal_type": e.traversal_type.value,
                    "visibility": e.visibility.value,
                    "one_way": e.one_way,
                    "attrs": {
                        k: (v.value if isinstance(v, str) and hasattr(v, 'value') else
                            list(v) if isinstance(v, set) else v)
                        for k, v in e.attrs.items()
                    },
                }
                for eid, e in self._edges.items()
            },
            "proximity": {
                pid: {
                    "node_a": p.node_a,
                    "node_b": p.node_b,
                    "wall_type": p.wall_type.value,
                    "sound_leak": p.sound_leak,
                    "visual_leak": p.visual_leak,
                }
                for pid, p in self._proximity.items()
            },
        }

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> LevelGraph:
        """Deserialize from a dictionary (inverse of ``to_dict``)."""
        g = cls()
        for nid, ndata in data["nodes"].items():
            g.add_node(
                NodeType(ndata["type"]),
                node_id=nid,
                **ndata.get("attrs", {}),
            )
        for eid, edata in data["edges"].items():
            attrs = dict(edata.get("attrs", {}))
            g.add_edge(
                edata["source"],
                edata["target"],
                edge_id=eid,
                locked=edata.get("locked", False),
                traversal_type=TraversalType(edata.get("traversal_type", "normal")),
                visibility=Visibility(edata.get("visibility", "obvious")),
                one_way=edata.get("one_way", False),
                **attrs,
            )
        for pid, pdata in data.get("proximity", {}).items():
            g.add_proximity(
                pdata["node_a"],
                pdata["node_b"],
                prox_id=pid,
                material=WallMaterial(pdata.get("material", "drywall")),
                thickness=pdata.get("thickness", 0.5),
                separation=pdata.get("separation", 0),
                window_count=pdata.get("window_count", 0),
                length_tiles=pdata.get("length_tiles", 8.0),
            )
        return g

    # ── Display ───────────────────────────────

    def summary(self) -> str:
        """Human-readable one-line summary."""
        return (
            f"LevelGraph({self.node_count} nodes, {self.edge_count} edges, "
            f"{self.proximity_count} proximity, solvable={self.is_solvable()})"
        )

    def __repr__(self) -> str:
        lines = [self.summary()]
        for n in self._nodes.values():
            lines.append(f"  {n}")
        for e in self._edges.values():
            lines.append(f"  {e}")
        for p in self._proximity.values():
            lines.append(f"  {p}")
        return "\n".join(lines)
