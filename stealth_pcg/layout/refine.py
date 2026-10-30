"""L3 — 타일 좌표계로의 정제. 실패하지 않는 후처리이며 위상을 바꾸지 않는다.

격자감을 지우는 네 가지 수단이 여기 모두 들어 있다.
  1) 비균일 격자선 : 열/행마다 간격을 따로 뽑는다. 인접 관계는 그대로 보존된다.
  2) 방별 변 여백  : footprint 은 '예산 박스'일 뿐, 실제 방은 그 안에서 변마다
                     다른 여백만큼 물러난다. 인접 방의 벽면이 일직선에서 풀린다.
  3) L자 절단      : 4셀 이상 방에서 문이 걸리지 않은 모서리 셀을 제거한다.
  4) 복도 우회     : exposure_length 목표 길이에 못 미치면 Z자로 돌아간다.
"""
from __future__ import annotations

import random
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Sequence, Set, Tuple

from .config import Cell, LayoutConfig, LayoutInput
from .solver import CoarseLayout, DIRS

Pt = Tuple[float, float]
Rect = Tuple[float, float, float, float]   # x0, y0, x1, y1 (tile)


@dataclass
class RoomGeom:
    node_id: str
    node_type: str
    cells: List[Cell]
    rects: List[Rect] = field(default_factory=list)          # 채움용 (셀별 트림 사각형)
    outline: List[Tuple[Pt, Pt]] = field(default_factory=list)  # 외곽선 선분
    bbox: Rect = (0, 0, 0, 0)
    center: Pt = (0, 0)
    l_cut: bool = False


@dataclass
class CorridorGeom:
    edge_id: str
    source: str
    target: str
    points: List[Pt] = field(default_factory=list)
    width: int = 4
    length_tiles: float = 0.0
    desired_tiles: float = 0.0
    layer: str = "ground"       # ground | overlay
    routed: bool = True
    traversal_type: str = "normal"
    locked: bool = False
    visibility: str = "obvious"
    key_id: Optional[str] = None


@dataclass
class WallGeom:
    prox_id: str
    a: str
    b: str
    p0: Pt
    p1: Pt
    wall_type: str
    sound_leak: float
    satisfied: bool


@dataclass
class TileLayout:
    rooms: Dict[str, RoomGeom]
    corridors: Dict[str, CorridorGeom]
    walls: List[WallGeom]
    col_widths: List[int]
    row_heights: List[int]
    tile_size: int
    extent: Rect
    stats: Dict[str, float] = field(default_factory=dict)


# --------------------------------------------------------------------------- #
def refine(data: LayoutInput, coarse: CoarseLayout,
           cfg: Optional[LayoutConfig] = None,
           walls: Optional[Dict[frozenset, dict]] = None) -> TileLayout:
    """L2 격자를 타일 좌표로 정제한다 (파이프라인 제7단계).

    관선 재편 이후 이 단계는 제6단계(벽 교정) **뒤**에 온다. separation 이
    교정 단계에서 결정되는 값이고, 여기서 그것을 실제 여백으로 옮겨야 하기
    때문이다.

    여백은 더 이상 방마다 무작위가 아니라 **그 변의 맞은편이 무엇인가**로
    정해진다. 구버전은 네 변에 독립적으로 1~4 타일을 뽑았기 때문에,
    sound_leak 0.6 으로 선언된 한 쌍이 양쪽에서 4 타일씩 물러나 8 타일짜리
    무인지대를 사이에 두는 일이 생겼다. 도면에는 공유벽이 그려져 있는데
    실제로는 붙어 있지 않은 것이다.

    walls: frozenset({a, b}) -> {"separation": int} 형태. 제6단계 결과.
    """
    cfg = cfg or LayoutConfig()
    rng = random.Random(cfg.seed * 7919 + 13)

    occupied: Set[Cell] = set()
    for rp in coarse.rooms.values():
        occupied |= rp.cells
    for lane in coarse.lanes.values():
        occupied |= set(lane.cells)
    if not occupied:
        raise ValueError("빈 배치 결과")

    minx = min(c[0] for c in occupied)
    miny = min(c[1] for c in occupied)
    maxx = max(c[0] for c in occupied)
    maxy = max(c[1] for c in occupied)
    ncol, nrow = maxx - minx + 1, maxy - miny + 1

    # 1) 비균일 격자선
    col_w = [rng.randint(cfg.cell_tiles_min, cfg.cell_tiles_max) for _ in range(ncol)]
    row_h = [rng.randint(cfg.cell_tiles_min, cfg.cell_tiles_max) for _ in range(nrow)]
    X = [0]
    for w in col_w:
        X.append(X[-1] + w)
    Y = [0]
    for h in row_h:
        Y.append(Y[-1] + h)

    def cell_rect(c: Cell) -> Rect:
        cx, cy = c[0] - minx, c[1] - miny
        return (X[cx], Y[cy], X[cx + 1], Y[cy + 1])

    # 연결부에 걸린 셀 (L자 절단 금지 대상)
    critical: Dict[str, Set[Cell]] = {n: set() for n in coarse.rooms}
    for lane in coarse.lanes.values():
        touch = set(lane.cells)
        for nid in (lane.from_node, lane.to_node):
            rp = coarse.rooms.get(nid)
            if rp is None:
                continue
            other = coarse.rooms.get(lane.to_node if nid == lane.from_node
                                     else lane.from_node)
            probe = touch if touch else (other.cells if other else set())
            for c in rp.cells:
                for dx, dy in DIRS.values():
                    if (c[0] + dx, c[1] + dy) in probe:
                        critical[nid].add(c)

    # 2) + 3) 방 기하
    rooms: Dict[str, RoomGeom] = {}
    for nid, rp in coarse.rooms.items():
        cells = set(rp.cells)
        l_cut = False
        if len(cells) >= 4 and rng.random() < cfg.l_cut_prob:
            cand = [c for c in cells
                    if c not in critical[nid] and _is_corner(c, cells)]
            rng.shuffle(cand)
            for c in cand:
                trial = cells - {c}
                if _connected(trial):
                    cells = trial
                    l_cut = True
                    break

        margin_for = _margin_resolver(nid, cells, coarse, walls, cfg, rng)
        rects: List[Rect] = []
        outline: List[Tuple[Pt, Pt]] = []
        for c in cells:
            x0, y0, x1, y1 = cell_rect(c)
            if (c[0], c[1] - 1) not in cells:
                y0 += margin_for(c, "north")
            if (c[0], c[1] + 1) not in cells:
                y1 -= margin_for(c, "south")
            if (c[0] - 1, c[1]) not in cells:
                x0 += margin_for(c, "west")
            if (c[0] + 1, c[1]) not in cells:
                x1 -= margin_for(c, "east")
            x1 = max(x1, x0 + cfg.min_room_tiles)
            y1 = max(y1, y0 + cfg.min_room_tiles)
            rects.append((x0, y0, x1, y1))
            if (c[0], c[1] - 1) not in cells:
                outline.append(((x0, y0), (x1, y0)))
            if (c[0], c[1] + 1) not in cells:
                outline.append(((x0, y1), (x1, y1)))
            if (c[0] - 1, c[1]) not in cells:
                outline.append(((x0, y0), (x0, y1)))
            if (c[0] + 1, c[1]) not in cells:
                outline.append(((x1, y0), (x1, y1)))

        bx0 = min(r[0] for r in rects); by0 = min(r[1] for r in rects)
        bx1 = max(r[2] for r in rects); by1 = max(r[3] for r in rects)
        rooms[nid] = RoomGeom(
            node_id=nid, node_type=str(data.nodes[nid].type).lower(),
            cells=sorted(cells), rects=rects, outline=outline,
            bbox=(bx0, by0, bx1, by1),
            center=((bx0 + bx1) / 2, (by0 + by1) / 2), l_cut=l_cut,
        )

    # 4) 복도
    corridors: Dict[str, CorridorGeom] = {}
    for eid, lane in coarse.lanes.items():
        e = data.edges[eid]
        ra, rb = rooms.get(lane.from_node), rooms.get(lane.to_node)
        if ra is None or rb is None:
            continue
        pts = _corridor_points(ra, rb, lane.cells, cell_rect)
        desired = e.exposure_length * cfg.tiles_per_exposure_unit
        pts = _extend_to_length(pts, desired, cfg, rng)
        corridors[eid] = CorridorGeom(
            edge_id=eid, source=lane.from_node, target=lane.to_node,
            points=pts, width=cfg.corridor_width,
            length_tiles=_polyline_len(pts), desired_tiles=float(desired),
            layer="ground" if lane.routed else "overlay", routed=lane.routed,
            traversal_type=e.traversal_type, locked=e.locked,
            visibility=e.visibility, key_id=e.key_id,
        )

    for eid in coarse.overlay_edges:
        e = data.edges[eid]
        ra, rb = rooms.get(e.source), rooms.get(e.target)
        if ra is None or rb is None:
            continue
        corridors[eid] = CorridorGeom(
            edge_id=eid, source=e.source, target=e.target,
            points=[ra.center, rb.center], width=2,
            length_tiles=_polyline_len([ra.center, rb.center]),
            desired_tiles=float(e.exposure_length * cfg.tiles_per_exposure_unit),
            layer="overlay", routed=True, traversal_type=e.traversal_type,
            locked=e.locked, visibility=e.visibility, key_id=e.key_id,
        )

    # proximity 공유벽
    # 공유벽은 제4단계가 기하에서 읽어낸 사실이므로 '충족 여부'가 없다.
    # 여기서는 선분 위치만 계산한다.
    wall_geoms: List[WallGeom] = []
    for pid, p in data.proximity.items():
        ra, rb = rooms.get(p.a), rooms.get(p.b)
        if ra is None or rb is None:
            continue
        seg = _shared_wall(ra.bbox, rb.bbox, cfg) or _fallback_wall(ra.bbox, rb.bbox)
        wall_geoms.append(WallGeom(pid, p.a, p.b, seg[0], seg[1],
                                   p.wall_type, p.sound_leak, True))
    walls_out = wall_geoms

    ex0 = min(r.bbox[0] for r in rooms.values())
    ey0 = min(r.bbox[1] for r in rooms.values())
    ex1 = max(r.bbox[2] for r in rooms.values())
    ey1 = max(r.bbox[3] for r in rooms.values())

    tl = TileLayout(rooms=rooms, corridors=corridors, walls=walls_out,
                    col_widths=col_w, row_heights=row_h,
                    tile_size=cfg.tile_size, extent=(ex0, ey0, ex1, ey1))
    tl.stats = {
        "rooms": float(len(rooms)),
        "corridors": float(len(corridors)),
        "l_cut_rooms": float(sum(1 for r in rooms.values() if r.l_cut)),
        "walls": float(len(walls_out)),
        "unrouted": coarse.stats.get("unrouted", 0.0),
        "essential_unrouted": coarse.stats.get("essential_unrouted", 0.0),
        "local_moves": coarse.stats.get("local_moves", 0.0),
        "solved": coarse.stats.get("solved", 0.0),
        "grid_cols": float(len(col_w)),
        "grid_rows": float(len(row_h)),
        "extent_tiles_w": ex1 - ex0,
        "extent_tiles_h": ey1 - ey0,
    }
    return tl


_SIDE_DELTA = {"north": (0, -1), "south": (0, 1), "west": (-1, 0), "east": (1, 0)}


def _margin_resolver(nid, cells, coarse, walls, cfg, rng):
    """격자 변의 맞은편이 무엇이냐에 따라 여백을 정한다.

      공유벽      separation / 2 — 정말로 한 장의 칸막이를 공유한다
      문(통행 엣지) 작게 — 문은 공유면 위에 뚫려야 한다
      복도 레인    보통 — 그 공간은 본래 복도 몫이다
      무관계 인접  크게 — 서로 각자의 칸 안에서 최대한 물러난다
      바깥 공지    중간 무작위
    """
    owner_of: Dict[Cell, str] = {}
    for other, rp in coarse.rooms.items():
        if other == nid:
            continue
        for c in rp.cells:
            owner_of[c] = other
    lane_cells = {c for lane in coarse.lanes.values() for c in lane.cells}
    doors = {frozenset((l.from_node, l.to_node))
             for l in coarse.lanes.values() if l.routed and not l.cells}
    cache: Dict[Tuple[Cell, str], int] = {}

    def resolve(cell, side):
        key = (cell, side)
        if key in cache:
            return cache[key]
        dx, dy = _SIDE_DELTA[side]
        probe = (cell[0] + dx, cell[1] + dy)
        other = owner_of.get(probe)
        if other is not None:
            pair = frozenset((nid, other))
            if walls and pair in walls:
                m = max(0, int(walls[pair].get("separation", 0)) // 2)
            elif pair in doors:
                m = cfg.margin_min
            else:
                m = cfg.separation_neutral
        elif probe in lane_cells:
            m = rng.randint(cfg.margin_min, cfg.margin_max)
        else:
            m = rng.randint(cfg.margin_min, cfg.margin_max)
        cache[key] = m
        return m

    return resolve


# ------------------------------------------------------------------ geometry
def _is_corner(c: Cell, cells: Set[Cell]) -> bool:
    n = sum(1 for dx, dy in DIRS.values() if (c[0] + dx, c[1] + dy) in cells)
    return n <= 2


def _connected(cells: Set[Cell]) -> bool:
    if not cells:
        return False
    start = next(iter(cells))
    seen = {start}
    stack = [start]
    while stack:
        x, y = stack.pop()
        for dx, dy in DIRS.values():
            c = (x + dx, y + dy)
            if c in cells and c not in seen:
                seen.add(c)
                stack.append(c)
    return len(seen) == len(cells)


def _port_toward(room: RoomGeom, target: Pt) -> Pt:
    """방 외곽 위에서 target 방향으로 가장 가까운 문 위치."""
    x0, y0, x1, y1 = room.bbox
    tx, ty = target
    cx, cy = room.center
    if abs(tx - cx) >= abs(ty - cy):
        x = x1 if tx > cx else x0
        y = min(max(ty, y0 + 2), y1 - 2) if y1 - y0 > 4 else cy
        return (x, y)
    y = y1 if ty > cy else y0
    x = min(max(tx, x0 + 2), x1 - 2) if x1 - x0 > 4 else cx
    return (x, y)


def _corridor_points(ra: RoomGeom, rb: RoomGeom, lane_cells: Sequence[Cell],
                     cell_rect) -> List[Pt]:
    mids: List[Pt] = []
    for c in lane_cells:
        x0, y0, x1, y1 = cell_rect(c)
        mids.append(((x0 + x1) / 2, (y0 + y1) / 2))
    first_target = mids[0] if mids else rb.center
    last_target = mids[-1] if mids else ra.center
    pa = _port_toward(ra, first_target)
    pb = _port_toward(rb, last_target)
    return _orthogonalize([pa] + mids + [pb])


def _orthogonalize(pts: Sequence[Pt]) -> List[Pt]:
    out: List[Pt] = [pts[0]]
    for nxt in pts[1:]:
        cur = out[-1]
        if abs(cur[0] - nxt[0]) > 1e-6 and abs(cur[1] - nxt[1]) > 1e-6:
            out.append((nxt[0], cur[1]))
        if (abs(out[-1][0] - nxt[0]) > 1e-6) or (abs(out[-1][1] - nxt[1]) > 1e-6):
            out.append(nxt)
    return out


def _polyline_len(pts: Sequence[Pt]) -> float:
    return sum(abs(pts[i + 1][0] - pts[i][0]) + abs(pts[i + 1][1] - pts[i][1])
               for i in range(len(pts) - 1))


def _extend_to_length(pts: List[Pt], desired: float, cfg: LayoutConfig,
                      rng: random.Random) -> List[Pt]:
    """exposure_length 를 채우기 위해 가장 긴 구간에 Z자 우회를 넣는다."""
    cur = _polyline_len(pts)
    if cur >= desired - 1 or len(pts) < 2:
        return pts
    need = desired - cur
    lat = min(need / 2.0, cfg.cell_tiles_min / 2.0 - cfg.corridor_width / 2.0)
    if lat < 1.5:
        return pts
    best_i, best_len = 0, -1.0
    for i in range(len(pts) - 1):
        d = abs(pts[i + 1][0] - pts[i][0]) + abs(pts[i + 1][1] - pts[i][1])
        if d > best_len:
            best_i, best_len = i, d
    if best_len < 4:
        return pts
    p, q = pts[best_i], pts[best_i + 1]
    horizontal = abs(p[1] - q[1]) < 1e-6
    sign = 1 if rng.random() < 0.5 else -1
    mid1 = (p[0] + (q[0] - p[0]) * 0.35, p[1])
    mid2 = (p[0] + (q[0] - p[0]) * 0.65, q[1])
    if horizontal:
        a = (mid1[0], p[1]); b = (mid1[0], p[1] + sign * lat)
        c = (mid2[0], p[1] + sign * lat); d = (mid2[0], q[1])
    else:
        a = (p[0], p[1] + (q[1] - p[1]) * 0.35)
        b = (p[0] + sign * lat, a[1])
        c = (p[0] + sign * lat, p[1] + (q[1] - p[1]) * 0.65)
        d = (q[0], c[1])
    return pts[: best_i + 1] + [a, b, c, d] + pts[best_i + 1:]


def _fallback_wall(ra: Rect, rb: Rect) -> Tuple[Pt, Pt]:
    """L2 에서는 맞닿는데 여백 때문에 기하 판정이 어긋난 경우의 보수적 선분."""
    ax0, ay0, ax1, ay1 = ra
    bx0, by0, bx1, by1 = rb
    ov_y0, ov_y1 = max(ay0, by0), min(ay1, by1)
    ov_x0, ov_x1 = max(ax0, bx0), min(ax1, bx1)
    if (ov_y1 - ov_y0) >= (ov_x1 - ov_x0):
        x = (ax1 + bx0) / 2 if bx0 >= ax1 else (bx1 + ax0) / 2
        return ((x, ov_y0), (x, max(ov_y1, ov_y0 + 3)))
    y = (ay1 + by0) / 2 if by0 >= ay1 else (by1 + ay0) / 2
    return ((ov_x0, y), (max(ov_x1, ov_x0 + 3), y))


def _shared_wall(ra: Rect, rb: Rect, cfg: LayoutConfig
                 ) -> Optional[Tuple[Pt, Pt]]:
    """공유벽 선분의 위치. 존재 여부는 이미 제4단계가 기하로 확정했으므로
    여기서는 '어느 축에서 마주보는가'만 판정한다."""
    ax0, ay0, ax1, ay1 = ra
    bx0, by0, bx1, by1 = rb
    ov_y0, ov_y1 = max(ay0, by0), min(ay1, by1)
    ov_x0, ov_x1 = max(ax0, bx0), min(ax1, bx1)

    if (ov_y1 - ov_y0) >= (ov_x1 - ov_x0) and ov_y1 > ov_y0:
        x = (ax1 + bx0) / 2 if bx0 >= ax1 else (bx1 + ax0) / 2
        return ((x, ov_y0), (x, ov_y1))
    if ov_x1 > ov_x0:
        y = (ay1 + by0) / 2 if by0 >= ay1 else (by1 + ay0) / 2
        return ((ov_x0, y), (ov_x1, y))
    return None
