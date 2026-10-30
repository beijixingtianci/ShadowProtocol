"""파이프라인 제6단계 — 공간 배치 계층 (Layout Solver).

전형적인 사용:

    from stealth_pcg.layout import solve_layout, layout_to_json
    from stealth_pcg.layout.render_html import write_report

    tl, coarse = solve_layout(graph, LayoutConfig(seed=cfg.seed))
    level_json["layout"] = layout_to_json(tl, coarse.stats)
    write_report(tl, from_level_graph(graph), "layout.html")
"""
from __future__ import annotations

from typing import Any, Optional, Sequence, Tuple

from .adapter import from_level_graph, layout_to_json
from .config import (LayoutConfig, LayoutEdge, LayoutInput, LayoutNode,
                     LayoutProximity)
from .refine import TileLayout, refine
from .solver import CoarseLayout, LayoutSolver

__all__ = [
    "solve_layout", "LayoutConfig", "LayoutInput", "LayoutNode", "LayoutEdge",
    "LayoutProximity", "TileLayout", "CoarseLayout",
    "from_level_graph", "layout_to_json",
]


def solve_layout(graph_or_input: Any,
                 config: Optional[LayoutConfig] = None,
                 critical_path: Optional[Sequence[str]] = None
                 ) -> Tuple[TileLayout, CoarseLayout]:
    cfg = config or LayoutConfig()
    data = (graph_or_input if isinstance(graph_or_input, LayoutInput)
            else from_level_graph(graph_or_input, critical_path))

    # L2 탐색은 그래프 하나당 수십 밀리초 수준이므로, 동률 분산만 바꿔
    # 여러 번 돌린 뒤 최량해를 취한다. proximity 충족률이 재시작에 따라
    # 0.3~0.7 사이에서 흔들리기 때문에 이 한 줄이 실제로 가장 크게 기여한다.
    import dataclasses
    best = None
    best_key = None
    for k in range(max(1, cfg.restarts)):
        trial = dataclasses.replace(cfg, seed=cfg.seed * 1000003 + k)
        c = LayoutSolver(data, trial).solve()
        w, h = _extent_wh(c)
        aspect = max(w, h) / max(1, min(w, h))
        # 공유벽 제약이 사라졌으므로 기준은 두 가지뿐이다.
        # 필수 엣지가 끊긴 해를 먼저 걸러내고, 나머지는 조밀하고
        # 지나치게 길쭉하지 않은 배치를 고른다.
        key = (-c.stats.get("essential_unrouted", 0.0),
               -c.stats.get("unrouted", 0.0),
               c.stats.get("solved", 0.0),
               -round(aspect, 2), -w * h)
        if best_key is None or key > best_key:
            best, best_key = c, key

    tile = refine(data, best, cfg)          # L3 는 항상 cfg.seed 로 재현 가능
    return tile, best


def _extent_wh(coarse: CoarseLayout):
    cells = [c for rp in coarse.rooms.values() for c in rp.cells]
    if not cells:
        return 1, 1
    xs = [c[0] for c in cells]; ys = [c[1] for c in cells]
    return max(xs) - min(xs) + 1, max(ys) - min(ys) + 1
