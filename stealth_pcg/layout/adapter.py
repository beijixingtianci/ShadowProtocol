"""기존 파이프라인(v8)과의 접속부.

v8 의 LevelGraph 구현 세부를 모르므로 속성 접근을 전부 관대하게 처리한다.
객체 속성 / 딕셔너리 / Enum(.value) 어느 쪽이든 받는다.
"""
from __future__ import annotations

from typing import Any, Dict, Iterable, List, Optional, Sequence, Tuple

from .config import LayoutEdge, LayoutInput, LayoutNode, LayoutProximity


def _get(obj: Any, *names: str, default: Any = None) -> Any:
    for n in names:
        if isinstance(obj, dict) and n in obj:
            return obj[n]
        if hasattr(obj, n):
            return getattr(obj, n)
    return default


def _enum_str(v: Any, default: str = "") -> str:
    if v is None:
        return default
    v = getattr(v, "value", v)
    return str(v).lower()


def _items(container: Any) -> Iterable:
    """dict(id->obj) / list / .values() 를 모두 (id, obj) 로 정규화."""
    if container is None:
        return []
    if isinstance(container, dict):
        return list(container.items())
    out = []
    for i, o in enumerate(container):
        out.append((_get(o, "id", "edge_id", "node_id", default=f"auto_{i}"), o))
    return out


def from_level_graph(graph: Any,
                     critical_path: Optional[Sequence[str]] = None) -> LayoutInput:
    nodes: Dict[str, LayoutNode] = {}
    for nid, n in _items(_get(graph, "nodes", "node_map", default={})):
        nodes[str(nid)] = LayoutNode(
            id=str(nid),
            type=_enum_str(_get(n, "type", "node_type"), "transit"),
        )

    edges: Dict[str, LayoutEdge] = {}
    for eid, e in _items(_get(graph, "edges", "edge_map", default={})):
        src = str(_get(e, "source", "src", "from_node", "u", default=""))
        dst = str(_get(e, "target", "dst", "to_node", "v", default=""))
        if src not in nodes or dst not in nodes:
            continue
        edges[str(eid)] = LayoutEdge(
            id=str(eid), source=src, target=dst,
            traversal_type=_enum_str(_get(e, "traversal_type", "traversal"), "normal"),
            exposure_length=int(_get(e, "exposure_length", "exposure", default=2) or 2),
            locked=bool(_get(e, "locked", default=False)),
            visibility=_enum_str(_get(e, "visibility"), "obvious"),
            key_id=(_get(e, "key_id") or None),
            mandatory=bool(_get(e, "mandatory", default=True)),
        )

    prox: Dict[str, LayoutProximity] = {}
    raw_p = _get(graph, "proximity_links", "proximity", "prox_links", default={})
    for pid, p in _items(raw_p):
        a = str(_get(p, "a", "node_a", "source", "u", default=""))
        b = str(_get(p, "b", "node_b", "target", "v", default=""))
        if a not in nodes or b not in nodes:
            continue
        prox[str(pid)] = LayoutProximity(
            id=str(pid), a=a, b=b,
            material=_enum_str(_get(p, "material", "wall_type"), "drywall"),
            thickness=float(_get(p, "thickness", default=0.5) or 0.5),
            separation=int(_get(p, "separation", default=0) or 0),
            window_count=int(_get(p, "window_count", default=0) or 0),
            length_tiles=float(_get(p, "length_tiles", default=8.0) or 8.0),
            sound_leak=float(_get(p, "sound_leak", default=0.0) or 0.0),
            visual_leak=float(_get(p, "visual_leak", default=0.0) or 0.0),
        )

    cp = critical_path
    if cp is None:
        cp = _get(graph, "critical_path", default=None)
        if callable(cp):
            try:
                cp = cp()
            except TypeError:
                cp = None
    cp = [str(x) for x in (cp or []) if str(x) in nodes]

    return LayoutInput(nodes=nodes, edges=edges, proximity=prox, critical_path=cp)


# --------------------------------------------------------------- JSON v2 블록
def layout_to_json(coarse, graph=None, *, refine_seed: int = 42,
                   cell_tiles: Tuple[int, int] = (7, 13),
                   tile_size: int = 32) -> Dict[str, Any]:
    """JSON 스키마 v2 의 "layout" 필드.

    L2(격자 점유)만 내보낸다. 타일 단위 정제 — 격자선 간격, 방별 여백,
    L자 절단, 복도 우회 — 는 refine_seed 에서 결정적으로 재생되므로
    클라이언트가 자기 에셋 치수에 맞춰 다시 만드는 편이 낫다. 재생할 수
    없는 것은 배치 탐색의 해, 즉 어느 방이 어느 칸을 차지하는가뿐이다.
    """
    # 격자 좌표를 원점 기준으로 정규화한다 (음수 없이 내보내기 위해)
    all_cells = [c for rp in coarse.rooms.values() for c in rp.cells]
    all_cells += [c for l in coarse.lanes.values() for c in l.cells]
    ox = min(c[0] for c in all_cells) if all_cells else 0
    oy = min(c[1] for c in all_cells) if all_cells else 0

    def shift(c):
        return [c[0] - ox, c[1] - oy]

    rooms = {nid: {"cells": [shift(c) for c in sorted(rp.cells)]}
             for nid, rp in coarse.rooms.items()}

    links: Dict[str, Any] = {}
    for eid, lane in coarse.lanes.items():
        if not lane.routed:
            links[eid] = {"kind": "overlay"}
        elif lane.cells:
            links[eid] = {"kind": "corridor",
                          "cells": [shift(c) for c in lane.cells]}
        else:
            links[eid] = {"kind": "door"}
    for eid in coarse.overlay_edges:
        links.setdefault(eid, {"kind": "overlay"})

    walls: List[Dict[str, Any]] = []
    if graph is not None:
        for pid, w in graph.proximity_links.items():
            walls.append({
                "id": pid, "a": w.node_a, "b": w.node_b,
                "between": [shift(w.between[0]), shift(w.between[1])]
                           if w.between else None,
                "material": getattr(w.material, "value", w.material),
                "thickness": round(float(w.thickness), 3),
                "separation": int(w.separation),
                "window_count": int(w.window_count),
                "window_capacity": int(w.capacity),
                "length_tiles": round(float(w.length_tiles), 1),
                "sound_leak": round(w.sound_leak, 3),
                "visual_leak": round(w.visual_leak, 3),
            })

    return {
        "unit": "cell",
        "refine_seed": refine_seed,
        "hints": {"cell_tiles": list(cell_tiles), "tile_size": tile_size},
        "rooms": rooms,
        "links": links,
        "walls": walls,
        "stats": {k: (round(v, 4) if isinstance(v, float) else v)
                  for k, v in coarse.stats.items()},
    }
