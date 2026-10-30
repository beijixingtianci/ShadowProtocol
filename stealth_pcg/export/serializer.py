"""stealth_pcg.export.serializer
================================
생성 파이프라인의 전체 출력을 Godot 클라이언트용 JSON 으로 직렬화한다.

스키마 v2 = v1(7개 최상위 필드) + ``layout`` (파이프라인 제6단계 산출물).
클라이언트는 알 수 없는 필드를 무시하므로 v1 만 읽는 클라이언트와도 호환된다.
"""
from __future__ import annotations

import json
from typing import Any, Mapping, Optional, Sequence

from stealth_pcg.core.graph import LevelGraph
from stealth_pcg.core.types import DEFAULT_THREAT, NodeType

SCHEMA_VERSION = 2

#: footprint 셀 수 → 클라이언트가 참고할 방 규모 힌트
_SIZE_BY_CELLS = {1: "small", 2: "medium"}

_SIZE_BY_TYPE = {
    NodeType.OBJECTIVE: "large", NodeType.HIGH_SECURITY: "large",
    NodeType.ENTRY: "medium", NodeType.EXIT: "medium",
    NodeType.SIDE_OBJECTIVE: "medium", NodeType.CHOKE: "small",
    NodeType.KEY_ROOM: "small", NodeType.ALT_PATH: "small",
    NodeType.TRANSIT: "small", NodeType.OBSERVATION: "small",
}


def _v(x: Any) -> Any:
    return getattr(x, "value", x)


class LevelSerializer:
    """LevelGraph(+옵션: 배치·시뮬레이션 결과) → JSON 사전."""

    def __init__(self, graph: LevelGraph) -> None:
        self.graph = graph

    # ------------------------------------------------------------------ #
    def to_dict(self,
                meta: Optional[Mapping[str, Any]] = None,
                layout: Optional[Mapping[str, Any]] = None,
                simulation_results: Optional[Mapping[str, Any]] = None
                ) -> dict[str, Any]:
        g = self.graph
        crit = g.critical_path() or []

        doc: dict[str, Any] = {
            "version": SCHEMA_VERSION,
            "meta": dict(meta or {}),
            "nodes": self._nodes(layout),
            "edges": self._edges(),
            "proximity": self._proximity(),
            "critical_path": crit,
            "clear_conditions": self._clear_conditions(),
        }
        if layout is not None:
            doc["layout"] = dict(layout)
        if simulation_results is not None:
            doc["simulation_results"] = dict(simulation_results)
        return doc

    def write(self, path: str, **kwargs: Any) -> str:
        with open(path, "w", encoding="utf-8") as f:
            json.dump(self.to_dict(**kwargs), f, ensure_ascii=False, indent=2)
        return path

    # ------------------------------------------------------------------ #
    def _nodes(self, layout: Optional[Mapping[str, Any]]) -> dict[str, Any]:
        rooms = (layout or {}).get("rooms", {}) or {}
        out: dict[str, Any] = {}
        for nid, n in self.graph.nodes.items():
            cells = len(rooms.get(nid, {}).get("cells", []) or [])
            size = (_SIZE_BY_CELLS.get(cells, "large") if cells
                    else _SIZE_BY_TYPE.get(n.node_type, "small"))
            out[nid] = {
                "type": _v(n.node_type),
                "threat_level": _v(DEFAULT_THREAT.get(n.node_type)),
                "safe_zone": bool(n.attrs.get("safe_zone", False)),
                "provides": n.provides,
                "size_hint": size,
                "reachable_styles": sorted(
                    _v(t) for t in n.attrs.get("reachable_styles", set())),
            }
        return out

    def _edges(self) -> dict[str, Any]:
        out: dict[str, Any] = {}
        for eid, e in self.graph.edges.items():
            out[eid] = {
                "source": e.source, "target": e.target,
                "locked": bool(e.locked),
                "key_id": e.key_id,
                "traversal_type": _v(e.traversal_type),
                "visibility": _v(e.visibility),
                "one_way": bool(e.one_way),
                "mandatory": bool(e.mandatory),
                "patrol_density": round(float(e.patrol_density), 4),
                "cover_availability": round(float(e.cover_availability), 4),
                "exposure_length": int(e.exposure_length),
                "noise_level": _v(e.noise_level),
                "approach_tags": sorted(_v(t) for t in e.approach_tags),
                "rule_origin": e.rule_origin,
            }
        return out

    def _proximity(self) -> dict[str, Any]:
        """공유벽. 재질·두께·이격·창문 네 축이 서로 독립이며,
        sound_leak / visual_leak 은 그 넷에서 파생된 값이다."""
        return {
            pid: {
                "node_a": w.node_a, "node_b": w.node_b,
                "material": _v(w.material),
                "thickness": round(float(w.thickness), 3),
                "separation": int(w.separation),
                "window_count": int(w.window_count),
                "window_capacity": int(w.capacity),
                "length_tiles": round(float(w.length_tiles), 1),
                "sound_leak": round(w.sound_leak, 3),
                "visual_leak": round(w.visual_leak, 3),
            }
            for pid, w in self.graph.proximity_links.items()
        }

    def _clear_conditions(self) -> dict[str, Any]:
        g = self.graph
        keys = sorted({e.key_id for e in g.edges.values()
                       if e.locked and e.key_id})
        return {
            "entry_node": g.find_entry().id,
            "exit_node": g.find_exit().id,
            "required_keys": keys,
            "objective_nodes": [n.id for n in g.nodes_of_type(NodeType.OBJECTIVE)],
            "optional_objectives": [n.id for n in
                                    g.nodes_of_type(NodeType.SIDE_OBJECTIVE)],
        }


# ---------------------------------------------------------------------- #
def simulation_block(results: Sequence[Any], names: Sequence[str]
                     ) -> dict[str, Any]:
    """SimulationResult 목록을 simulation_results 필드로 변환한다."""
    out: dict[str, Any] = {}
    for r, name in zip(results, names):
        key = name.lower().replace(" ", "_")
        out[key] = {
            "agent_type": name,
            "path": list(getattr(r, "path", []) or []),
            "tension_trace": [round(float(t), 4)
                              for t in (getattr(r, "tension_trace", []) or [])],
            "reached_exit": bool(getattr(r, "reached_exit", False)),
            "total_steps": int(getattr(r, "total_steps", 0)),
            "keys_collected": sorted(getattr(r, "keys_collected", []) or []),
        }
    return out
