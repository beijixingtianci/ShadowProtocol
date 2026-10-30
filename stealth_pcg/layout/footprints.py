"""노드 타입별 footprint(가로x세로 셀 수) 정의역.

방을 정사각형으로 고정하지 않기 위해 footprint 자체를 CSP 변수의 일부로 둔다.
변수는 (위치, footprint 변형)의 쌍이 되며, 90도 회전 변형은 자동 생성된다.
"""
from __future__ import annotations

from typing import Dict, List, Tuple

Footprint = Tuple[int, int]  # (w, h) in cells

_BASE: Dict[str, List[Footprint]] = {
    "entry":          [(1, 2), (2, 2)],
    "exit":           [(1, 2), (2, 2)],
    "objective":      [(2, 2), (2, 3)],
    "side_objective": [(1, 2), (2, 2)],
    "transit":        [(1, 1), (1, 2)],
    "observation":    [(1, 1), (1, 2)],
    "high_security":  [(2, 2), (2, 3)],
    "choke":          [(1, 2)],          # 병목은 항상 좁다 (의미론적 강제)
    "alt_path":       [(1, 1)],
    "key_room":       [(1, 1), (1, 2)],
}

_DEFAULT: List[Footprint] = [(1, 1), (1, 2)]


def _with_rotations(fps: List[Footprint]) -> List[Footprint]:
    out: List[Footprint] = []
    for w, h in fps:
        for cand in ((w, h), (h, w)):
            if cand not in out:
                out.append(cand)
    return out


def footprint_domain(node_type: str, degree: int) -> List[Footprint]:
    """degree 제약: 둘레 셀 수 >= 연결 차수.

    연결이 많은 방이 1x1 이면 문이 한 자리에 몰려 물리적으로 성립하지 않는다.
    이 제약에 의해 '그래프상 연결이 많은 방은 게임 안에서도 실제로 크다'가
    별도 규칙 없이 성립한다.
    """
    base = _BASE.get(str(node_type).lower(), _DEFAULT)
    cands = _with_rotations(base)

    def perimeter_cells(fp: Footprint) -> int:
        w, h = fp
        return 2 * (w + h) if (w > 1 or h > 1) else 4

    ok = [fp for fp in cands if perimeter_cells(fp) >= max(1, degree)]
    if ok:
        return ok
    # 정의역 전체가 막히면 정사각으로 승급시켜 확장한다.
    size = 2
    while True:
        fp = (size, size)
        if 2 * (size + size) >= degree or size >= 5:
            return [fp]
        size += 1


def cells_of(origin_x: int, origin_y: int, fp: Footprint) -> List[Tuple[int, int]]:
    w, h = fp
    return [(origin_x + dx, origin_y + dy) for dx in range(w) for dy in range(h)]
