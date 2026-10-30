"""L2 — 거친 격자 위의 배치 탐색 (파이프라인 제3단계).

관선 재편에 따라 이 모듈에서 proximity 관련 기계장치가 전부 빠졌다.
공유벽은 더 이상 만족시켜야 할 제약이 아니라 **배치 결과에서 읽어내는
기하적 사실**이며, 그 일은 제4단계(grammar/adjacency)가 맡는다.

따라서 여기서의 목표 함수는 세 가지뿐이다.

  1. 겹치지 않게 놓는다
  2. 조밀하게, 지나치게 길쭉하지 않게
  3. exposure_length 가 바라는 간격을 되도록 맞춘다

여기에 하나의 **경성 제약**이 붙는다. mandatory 엣지와 임계 경로 엣지는
반드시 문 또는 복도로 실현되어야 한다. 이것이 깨지면 Godot 에서 통과
불가능한 레벨이 나오므로, 배치·배선 어느 단계에서도 희생 대상이 아니다.

통행 방식이 통풍구·등반인 엣지는 지상 격자를 점유하지 않는다. S4 가
만드는 엣지가 전부 여기에 해당하므로, 그것을 걷어낸 지상 부분 그래프는
사실상 평면 그래프가 되어 배치 실패가 거의 발생하지 않는다.
"""
from __future__ import annotations

import heapq
import random
from collections import deque
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Sequence, Set, Tuple

from .config import Cell, LayoutConfig, LayoutEdge, LayoutInput
from .footprints import Footprint, cells_of, footprint_domain

DIRS: Dict[str, Tuple[int, int]] = {
    "east": (1, 0), "west": (-1, 0), "south": (0, 1), "north": (0, -1),
}
OPPOSITE = {"east": "west", "west": "east", "north": "south", "south": "north"}


def desired_gap_cells(exposure_length: int, gap_max: int) -> int:
    e = max(1, min(5, int(exposure_length)))
    return min(gap_max, {1: 0, 2: 1, 3: 1, 4: 2, 5: 2}[e])


@dataclass
class RoomPlacement:
    node_id: str
    origin: Cell
    footprint: Footprint
    cells: Set[Cell]
    anchor_dir: Optional[str] = None
    anchor_id: Optional[str] = None

    def bbox(self) -> Tuple[int, int, int, int]:
        x, y = self.origin
        w, h = self.footprint
        return x, y, x + w - 1, y + h - 1


@dataclass
class CorridorLane:
    edge_id: str
    cells: List[Cell]          # 비어 있으면 문 (두 방이 맞닿음)
    routed: bool = True
    from_node: str = ""
    to_node: str = ""


@dataclass
class CoarseLayout:
    rooms: Dict[str, RoomPlacement] = field(default_factory=dict)
    lanes: Dict[str, CorridorLane] = field(default_factory=dict)
    overlay_edges: List[str] = field(default_factory=list)
    unrouted_edges: List[str] = field(default_factory=list)
    essential_unrouted: List[str] = field(default_factory=list)
    stats: Dict[str, float] = field(default_factory=dict)


class _State:
    def __init__(self) -> None:
        self.occ: Dict[Cell, str] = {}
        self.rooms: Dict[str, RoomPlacement] = {}
        self.lanes: Dict[str, CorridorLane] = {}

    def free(self, cells) -> bool:
        return all(c not in self.occ for c in cells)

    def bbox_wh(self) -> Tuple[int, int]:
        if not self.occ:
            return 0, 0
        xs = [c[0] for c in self.occ]; ys = [c[1] for c in self.occ]
        return max(xs) - min(xs) + 1, max(ys) - min(ys) + 1

    def bbox_with(self, cells) -> Tuple[int, int]:
        pts = list(self.occ) + list(cells)
        xs = [c[0] for c in pts]; ys = [c[1] for c in pts]
        return max(xs) - min(xs) + 1, max(ys) - min(ys) + 1

    def add_room(self, rp: RoomPlacement) -> None:
        for c in rp.cells:
            self.occ[c] = f"room:{rp.node_id}"
        self.rooms[rp.node_id] = rp

    def drop_room(self, node_id: str) -> Optional[RoomPlacement]:
        rp = self.rooms.pop(node_id, None)
        if rp is not None:
            for c in rp.cells:
                self.occ.pop(c, None)
        return rp

    def occupy_lane(self, lane: CorridorLane) -> None:
        for c in lane.cells:
            self.occ[c] = f"corr:{lane.edge_id}"
        self.lanes[lane.edge_id] = lane


class LayoutSolver:
    def __init__(self, data: LayoutInput, config: Optional[LayoutConfig] = None) -> None:
        self.data = data
        self.cfg = config or LayoutConfig()
        self.rng = random.Random(self.cfg.seed)
        self.adj = data.neighbors_ground()
        self.degree = {n: len(self.adj[n]) for n in data.nodes}
        self.cp_index = {n: i for i, n in enumerate(data.critical_path)}

        cp_seq = list(data.critical_path)
        self._cp_pairs = {frozenset((cp_seq[i], cp_seq[i + 1]))
                          for i in range(len(cp_seq) - 1)}
        self.essential_adj: Dict[str, List[str]] = {n: [] for n in data.nodes}
        for e in data.ground_edges():
            if self.is_essential(e):
                self.essential_adj[e.source].append(e.target)
                self.essential_adj[e.target].append(e.source)

        self._budget = self.cfg.node_budget

    def is_essential(self, e: LayoutEdge) -> bool:
        """끊기면 레벨이 물리적으로 성립하지 않는 엣지."""
        return e.mandatory or frozenset((e.source, e.target)) in self._cp_pairs

    # ------------------------------------------------------------------ order
    def _placement_order(self) -> List[Tuple[str, Optional[str]]]:
        start = next((n for n, nd in self.data.nodes.items()
                      if str(nd.type).lower() == "entry"), None)
        if start is None:
            start = (self.data.critical_path[0] if self.data.critical_path
                     else next(iter(self.data.nodes)))

        cp = set(self.data.critical_path)
        order: List[Tuple[str, Optional[str]]] = [(start, None)]
        placed = {start}

        def branch(root: str, parent: str) -> None:
            q = deque([(root, parent)])
            while q:
                v, par = q.popleft()
                if v in placed:
                    continue
                order.append((v, par))
                placed.add(v)
                # 필수 이웃을 먼저 따라간다 — 나중에 놓을수록 자리가 없다
                for u in self.essential_adj.get(v, ()):
                    if u not in placed and u not in cp:
                        q.appendleft((u, v))
                for u, _e in self.adj[v]:
                    if u not in placed and u not in cp:
                        q.append((u, v))

        for v in self.data.critical_path or [start]:
            if v not in placed:
                anchor = next((u for u, _ in self.adj[v] if u in placed), None)
                if anchor is None:
                    continue
                order.append((v, anchor))
                placed.add(v)
            for u, _e in self.adj[v]:
                if u not in placed and u not in cp:
                    branch(u, v)

        changed = True
        while changed:
            changed = False
            for v in self.data.nodes:
                if v in placed:
                    continue
                anchor = next((u for u, _ in self.adj[v] if u in placed), None)
                if anchor is not None:
                    order.append((v, anchor))
                    placed.add(v)
                    changed = True
        for v in self.data.nodes:
            if v not in placed:
                order.append((v, None))
                placed.add(v)
        return order

    # ------------------------------------------------------------- candidates
    def _candidates(self, state: _State, v: str, anchor: str
                    ) -> List[Tuple[float, RoomPlacement]]:
        cfg = self.cfg
        ap = state.rooms[anchor]
        ax0, ay0, ax1, ay1 = ap.bbox()
        edge = self._edge_between(anchor, v)
        if edge is None:
            return []
        want = 0 if edge.is_door_only else desired_gap_cells(
            edge.exposure_length, cfg.gap_max_cells)
        gaps = sorted({0, want, min(cfg.gap_max_cells, want + 1)})

        out: List[Tuple[float, RoomPlacement]] = []
        for fp in footprint_domain(self.data.nodes[v].type, self.degree[v]):
            vw, vh = fp
            for dname, (dx, dy) in DIRS.items():
                for gap in gaps:
                    if dx != 0:
                        ox = ax1 + 1 + gap if dx > 0 else ax0 - gap - vw
                        coords = [(ox, oy) for oy in range(ay0 - vh + 1, ay1 + 1)]
                    else:
                        oy = ay1 + 1 + gap if dy > 0 else ay0 - gap - vh
                        coords = [(ox, oy) for ox in range(ax0 - vw + 1, ax1 + 1)]
                    for origin in coords:
                        cells = set(cells_of(origin[0], origin[1], fp))
                        if not state.free(cells):
                            continue
                        if not self._essential_ok(state, v, cells):
                            continue
                        cost = self._cost(state, v, cells, gap, want, dname, ap)
                        out.append((cost, RoomPlacement(v, origin, fp, cells,
                                                        dname, anchor)))
        out.sort(key=lambda t: t[0])
        return out[: cfg.candidates_per_node]

    def _cost(self, state: _State, v: str, cells: Set[Cell], gap: int,
              want: int, dname: str, ap: RoomPlacement) -> float:
        cfg = self.cfg
        cost = cfg.w_gap * abs(gap - want)
        if gap == 0:
            cost -= cfg.w_door_bonus

        # 둘레 여유 — 아직 놓이지 않은 이웃이 붙을 자리를 남겨 둔다
        free_sides = sum(1 for c in _ring(cells) if c not in state.occ)
        pending = sum(1 for u, _ in self.adj[v] if u not in state.rooms)
        if free_sides < pending * 2:
            cost += cfg.w_crowding * (pending * 2 - free_sides)

        for u, _e in self.adj[v]:
            rp = state.rooms.get(u)
            if rp is None or rp.node_id == ap.node_id:
                continue
            cost += cfg.w_edge_stretch * max(
                0, _cell_dist(cells, rp.cells) - cfg.gap_max_cells - 1)

        nw, nh = state.bbox_with(cells)
        ow, oh = state.bbox_wh()
        cost += cfg.w_compact * ((nw * nh - ow * oh) / 4.0
                                 + 2.0 * (max(nw, nh) - max(ow, oh)))
        if v in self.cp_index and ap.anchor_dir == OPPOSITE[dname]:
            cost += cfg.w_reversal
        return cost + self.rng.random() * 0.03

    def _edge_between(self, a: str, b: str) -> Optional[LayoutEdge]:
        for u, e in self.adj[a]:
            if u == b:
                return e
        return None

    # ------------------------------------------------- essential-edge guard
    def _essential_ok(self, state: _State, nid: str, cells: Set[Cell],
                      extra_occ: Optional[Set[Cell]] = None) -> bool:
        """필수 이웃과 실제로 이어질 수 있는가 — 거리가 아니라 경로로 본다.

        거리만 재면 사이에 제3의 방이 끼어 있는 경우를 놓치고, 배선 단계에
        가서야 실패한다.
        """
        limit = self.cfg.max_essential_cells
        for u in self.essential_adj.get(nid, ()):
            rp = state.rooms.get(u)
            if rp is None:
                continue
            if _touching(cells, rp.cells):
                continue
            if not self._free_path_within(state, cells, rp.cells, limit,
                                          cells, extra_occ):
                return False
        return True

    def _free_path_within(self, state: _State, src: Set[Cell], dst: Set[Cell],
                          limit: int, own: Set[Cell],
                          extra_occ: Optional[Set[Cell]]) -> bool:
        def blocked(c: Cell) -> bool:
            return ((c in state.occ and c not in own)
                    or (extra_occ is not None and c in extra_occ))

        frontier = [c for c in _ring(src) if not blocked(c) and c not in own]
        seen = set(frontier)
        for _ in range(limit):
            if not frontier:
                return False
            nxt: List[Cell] = []
            for c in frontier:
                for dx, dy in DIRS.values():
                    n = (c[0] + dx, c[1] + dy)
                    if n in dst:
                        return True
                    if n in seen or blocked(n) or n in own:
                        continue
                    seen.add(n)
                    nxt.append(n)
            frontier = nxt
        return False

    def _neighbors_still_ok(self, state: _State, cells: Set[Cell],
                            skip: Optional[str] = None) -> bool:
        """새 방이 남의 필수 통로를 막지는 않는가."""
        touched = set()
        for c in cells:
            for dx, dy in DIRS.values():
                owner = state.occ.get((c[0] + dx, c[1] + dy), "")
                if owner.startswith("room:"):
                    touched.add(owner[5:])
        for nid in touched:
            if nid == skip:
                continue
            rp = state.rooms.get(nid)
            if rp is not None and not self._essential_ok(
                    state, nid, rp.cells, extra_occ=cells):
                return False
        return True

    # ---------------------------------------------------------------- solve
    def solve(self) -> CoarseLayout:
        order = self._placement_order()
        state = _State()
        first, _ = order[0]
        fp0 = footprint_domain(self.data.nodes[first].type, self.degree[first])[0]
        state.add_room(RoomPlacement(first, (0, 0), fp0, set(cells_of(0, 0, fp0))))

        self._budget = self.cfg.node_budget
        ok = self._place(state, order, 1)

        layout = CoarseLayout()
        layout.overlay_edges = [e.id for e in self.data.edges.values() if e.is_overlay]
        layout.stats["solved"] = 1.0 if ok else 0.0

        self._place_orphans(state)
        self._route_all(state, layout)

        layout.rooms = dict(state.rooms)
        layout.lanes = dict(state.lanes)
        self._score(layout)
        return layout

    def _place(self, state: _State, order, i: int) -> bool:
        if i >= len(order):
            return True
        if self._budget <= 0:
            return False
        v, anchor = order[i]
        if anchor is None or anchor not in state.rooms:
            anchor = next((u for u, _ in self.adj[v] if u in state.rooms), None)
            if anchor is None:
                return self._place(state, order, i + 1)

        for _cost, rp in self._candidates(state, v, anchor):
            self._budget -= 1
            if self._budget <= 0:
                return False
            if not self._neighbors_still_ok(state, rp.cells):
                continue
            state.add_room(rp)
            if self._place(state, order, i + 1):
                return True
            state.drop_room(v)
        return False

    def _place_orphans(self, state: _State) -> None:
        """지상 엣지가 없는 노드(ALT_PATH 등)도 좌표는 필요하다."""
        overlay_adj: Dict[str, List[str]] = {}
        for e in self.data.edges.values():
            if e.is_overlay:
                overlay_adj.setdefault(e.source, []).append(e.target)
                overlay_adj.setdefault(e.target, []).append(e.source)
        for nid in self.data.nodes:
            if nid in state.rooms:
                continue
            anchors = [state.rooms[u] for u in overlay_adj.get(nid, [])
                       if u in state.rooms]
            if anchors:
                cx = sum((r.bbox()[0] + r.bbox()[2]) / 2 for r in anchors) / len(anchors)
                cy = sum((r.bbox()[1] + r.bbox()[3]) / 2 for r in anchors) / len(anchors)
            else:
                cx = cy = 0
            spot = self._nearest_free(state, (round(cx), round(cy)))
            state.add_room(RoomPlacement(nid, spot, (1, 1), {spot}))

    def _nearest_free(self, state: _State, seed: Cell) -> Cell:
        if seed not in state.occ:
            return seed
        for r in range(1, 60):
            for dx in range(-r, r + 1):
                for dy in (-r, r):
                    for c in ((seed[0] + dx, seed[1] + dy),
                              (seed[0] + dy, seed[1] + dx)):
                        if c not in state.occ:
                            return c
        return (0, 0)

    # -------------------------------------------------------------- routing
    def _route_all(self, state: _State, layout: CoarseLayout) -> None:
        ground = self.data.ground_edges()
        essential = [e for e in ground if self.is_essential(e)]
        optional = [e for e in ground if not self.is_essential(e)]
        essential.sort(key=lambda e: self.cp_index.get(e.source, 10 ** 6))

        # 필수 엣지를 먼저, 빈 공간을 독점한 상태에서 배선한다
        failed = self._route_group(state, essential, cap=True)
        failed = self._route_group(state, failed, cap=False)
        for e in failed:
            if self._force_connect(state, e):
                state.lanes[e.id] = CorridorLane(e.id, [], True, e.source, e.target)
            else:
                layout.unrouted_edges.append(e.id)
                layout.essential_unrouted.append(e.id)
                state.lanes[e.id] = CorridorLane(e.id, [], False, e.source, e.target)

        rest = self._route_group(state, optional, cap=True)
        rest = self._route_group(state, rest, cap=False)
        for e in rest:
            layout.unrouted_edges.append(e.id)
            state.lanes[e.id] = CorridorLane(e.id, [], False, e.source, e.target)

    def _route_group(self, state: _State, edges: Sequence[LayoutEdge],
                     cap: bool) -> List[LayoutEdge]:
        failed: List[LayoutEdge] = []
        for e in edges:
            if e.id in state.lanes:
                continue
            ra, rb = state.rooms.get(e.source), state.rooms.get(e.target)
            if ra is None or rb is None:
                failed.append(e)
                continue
            if _touching(ra.cells, rb.cells):
                state.lanes[e.id] = CorridorLane(e.id, [], True, e.source, e.target)
                continue
            path = self._astar(state, ra, rb)
            if path is None:
                failed.append(e)
                continue
            if cap and len(path) > 4 * max(2, _cell_dist(ra.cells, rb.cells)) + 6:
                failed.append(e)
                continue
            state.occupy_lane(CorridorLane(e.id, path, True, e.source, e.target))
        return failed

    def _force_connect(self, state: _State, e: LayoutEdge) -> bool:
        for mover, other in ((e.source, e.target), (e.target, e.source)):
            if mover in state.rooms and other in state.rooms:
                if self._relocate_beside(state, mover, other):
                    return True
        return False

    def _relocate_beside(self, state: _State, mover: str, target: str) -> bool:
        old = state.drop_room(mover)
        if old is None:
            return False
        tcells = state.rooms[target].cells
        tx0 = min(c[0] for c in tcells); tx1 = max(c[0] for c in tcells)
        ty0 = min(c[1] for c in tcells); ty1 = max(c[1] for c in tcells)
        ground = [state.rooms[u] for u, _ in self.adj[mover] if u in state.rooms]
        best = None
        for fp in footprint_domain(self.data.nodes[mover].type, self.degree[mover]):
            w, h = fp
            spots: List[Cell] = []
            for oy in range(ty0 - h + 1, ty1 + 1):
                spots += [(tx1 + 1, oy), (tx0 - w, oy)]
            for ox in range(tx0 - w + 1, tx1 + 1):
                spots += [(ox, ty1 + 1), (ox, ty0 - h)]
            for ox, oy in spots:
                cells = set(cells_of(ox, oy, fp))
                if not state.free(cells) or not _touching(cells, tcells):
                    continue
                dists = [_cell_dist(cells, r.cells) for r in ground]
                key = (sum(dists), len(cells))
                if best is None or key < best[0]:
                    best = (key, RoomPlacement(mover, (ox, oy), fp, cells,
                                               old.anchor_dir, old.anchor_id))
        if best is None:
            state.add_room(old)
            return False
        state.add_room(best[1])
        return True

    def _astar(self, state: _State, ra: RoomPlacement, rb: RoomPlacement
               ) -> Optional[List[Cell]]:
        starts = [c for c in _ring(ra.cells) if c not in state.occ]
        if not starts or not any(c not in state.occ for c in _ring(rb.cells)):
            return None
        gx0, gy0, gx1, gy1 = _bounds(rb.cells)

        def h(c: Cell) -> int:
            return (max(0, gx0 - c[0], c[0] - gx1)
                    + max(0, gy0 - c[1], c[1] - gy1))

        openq: List[Tuple[int, int, Cell]] = []
        came: Dict[Cell, Optional[Cell]] = {}
        gsc: Dict[Cell, int] = {}
        for s in starts:
            gsc[s] = 0
            came[s] = None
            heapq.heappush(openq, (h(s), 0, s))

        limit = 8000
        while openq and limit > 0:
            limit -= 1
            _f, g, cur = heapq.heappop(openq)
            if any(abs(cur[0] - c[0]) + abs(cur[1] - c[1]) == 1 for c in rb.cells):
                path: List[Cell] = []
                node: Optional[Cell] = cur
                while node is not None:
                    path.append(node)
                    node = came[node]
                path.reverse()
                return path
            for dx, dy in DIRS.values():
                nxt = (cur[0] + dx, cur[1] + dy)
                if nxt in state.occ:
                    continue
                ng = g + 1
                if ng < gsc.get(nxt, 10 ** 9):
                    gsc[nxt] = ng
                    came[nxt] = cur
                    heapq.heappush(openq, (ng + h(nxt), ng, nxt))
        return None

    # ---------------------------------------------------------------- score
    def _score(self, layout: CoarseLayout) -> None:
        doors = sum(1 for l in layout.lanes.values() if l.routed and not l.cells)
        corridors = sum(1 for l in layout.lanes.values() if l.routed and l.cells)
        layout.stats.update({
            "rooms": float(len(layout.rooms)),
            "doors": float(doors),
            "corridors_routed": float(corridors),
            "unrouted": float(len(layout.unrouted_edges)),
            "essential_unrouted": float(len(layout.essential_unrouted)),
        })


# ------------------------------------------------------------------ helpers
def _ring(cells: Set[Cell]) -> List[Cell]:
    out: Set[Cell] = set()
    for x, y in cells:
        for dx, dy in DIRS.values():
            c = (x + dx, y + dy)
            if c not in cells:
                out.add(c)
    return list(out)


def _touching(a: Set[Cell], b: Set[Cell]) -> bool:
    """두 셀 집합이 한 변을 공유하는가."""
    if len(b) < len(a):
        a, b = b, a
    for x, y in a:
        for dx, dy in DIRS.values():
            if (x + dx, y + dy) in b:
                return True
    return False


def shared_boundary(a: Set[Cell], b: Set[Cell]) -> List[Tuple[Cell, Cell]]:
    """맞닿은 격자 변의 목록. 제4단계가 공유벽을 읽어낼 때 쓴다."""
    out: List[Tuple[Cell, Cell]] = []
    for x, y in a:
        for dx, dy in DIRS.values():
            c = (x + dx, y + dy)
            if c in b:
                out.append(((x, y), c))
    return out


def _bounds(cells) -> Tuple[int, int, int, int]:
    xs = [c[0] for c in cells]; ys = [c[1] for c in cells]
    return min(xs), min(ys), max(xs), max(ys)


def _cell_dist(a: Set[Cell], b: Set[Cell]) -> int:
    """최근접 맨해튼 거리 (맞닿으면 1). L2 의 방은 전부 직사각형이므로
    경계 상자만으로 정확히 구해진다."""
    ax0, ay0, ax1, ay1 = _bounds(a)
    bx0, by0, bx1, by1 = _bounds(b)
    return max(0, bx0 - ax1, ax0 - bx1) + max(0, by0 - ay1, ay0 - by1)
