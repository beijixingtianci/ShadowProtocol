"""파이프라인 제4단계 — 인접 관계 도출.

관선 재편의 핵심이 이 모듈이다.

구버전은 제3단계에서 위상 거리 2~3홉인 노드 쌍 중 일부를 무작위로 뽑아
"이 두 방은 붙어 있다"고 **선언**했다. 그런데 그 시점에는 기하가 아직
존재하지 않았으므로, 뒤에 오는 배치 단계는 임의로 지정된 제약 다발을
만족시켜야 했고 충족률이라는 지표가 생겨났다. 만족시키지 못한 링크는
소리는 전달되는데 벽은 없는 모순된 상태로 남았다.

지금은 순서가 반대다. 배치가 먼저 끝나고, 어떤 두 방이 벽을 맞대고 있는지는
**기하적 사실**이므로 그냥 읽어내면 된다. 충족률이라는 개념 자체가 사라진다.

읽어낸 뒤에 하는 일은 각 면에 재질·두께·창문을 지정하는 것뿐이다.
``leak_rate`` 는 "맞닿은 면 중 실제로 소리가 새도록 만들 비율"이며,
새지 않는 면은 두꺼운 콘크리트로 처리된다 — 구버전에서 "링크가 없다"에
해당하던 상태가 이제는 "차음이 잘 되는 벽이 있다"로 바뀐 것이다.
"""
from __future__ import annotations

import random
from dataclasses import dataclass
from typing import Dict, List, Optional, Tuple

from stealth_pcg.core.graph import LevelGraph, SharedWall
from stealth_pcg.core.types import (DEFAULT_THREAT, NodeType, ThreatLevel,
                                    WallMaterial, window_capacity)
from stealth_pcg.layout.solver import CoarseLayout, shared_boundary

Cell = Tuple[int, int]


@dataclass
class AdjacencyConfig:
    seed: int = 42
    #: 맞닿은 면 중 실제로 소리가 새도록 만들 비율 (나머지는 두꺼운 콘크리트)
    leak_rate: float = 0.35
    #: 누설 벽 / 무관계 인접면의 기본 이격 (타일)
    separation_bonded: int = 0
    separation_neutral: int = 3
    #: length_tiles 환산에 쓰는 격자 한 칸의 공칭 크기 (타일)
    nominal_cell_tiles: float = 10.0
    #: 창문을 낼 확률 (용량이 1 이상인 면에 한해)
    window_prob: float = 0.30


#: 재질 후보. 양쪽 방의 위협도에 따라 가중이 달라진다.
_MATERIALS_SECURE = [WallMaterial.CONCRETE, WallMaterial.METAL,
                     WallMaterial.CONCRETE]
_MATERIALS_CIVIL = [WallMaterial.DRYWALL, WallMaterial.GLASS,
                    WallMaterial.DRYWALL, WallMaterial.MESH]

#: 창문을 두지 않는 방 유형. 키 보관실과 고경계 구역은 외부 시선을 차단한다.
_NO_WINDOW = {NodeType.KEY_ROOM, NodeType.HIGH_SECURITY}


def derive_shared_walls(graph: LevelGraph, coarse: CoarseLayout,
                        config: Optional[AdjacencyConfig] = None) -> int:
    """배치 결과에서 공유벽을 읽어 그래프에 등록한다. 등록한 면의 수를 돌려준다.

    후보 = 격자에서 실제로 변을 맞대고 있으면서, 두 방 사이에 통행 엣지가
    없는 모든 쌍. 통행 엣지가 있으면 그것은 문이므로 공유벽이 아니다.
    """
    cfg = config or AdjacencyConfig()
    rng = random.Random(cfg.seed * 31 + 7)

    # 기존 공유벽을 비운다 (재실행 대비)
    for pid in list(graph.proximity_links):
        graph.remove_proximity(pid)

    connected = {frozenset((e.source, e.target)) for e in graph.edges.values()}
    rooms = coarse.rooms
    ids = sorted(rooms)
    count = 0

    for i, a in enumerate(ids):
        for b in ids[i + 1:]:
            if frozenset((a, b)) in connected:
                continue                      # 통행 엣지가 있으면 문이다
            boundary = shared_boundary(rooms[a].cells, rooms[b].cells)
            if not boundary:
                continue

            length = len(boundary) * cfg.nominal_cell_tiles
            leaky = rng.random() < cfg.leak_rate
            material, thickness = _pick_material(graph, a, b, leaky, rng)
            separation = (cfg.separation_bonded if leaky
                          else cfg.separation_neutral)

            windows = 0
            cap = window_capacity(length, material)
            if cap > 0 and rng.random() < cfg.window_prob:
                if not _blocks_windows(graph, a, b):
                    windows = rng.randint(1, cap)

            graph.add_proximity(
                a, b,
                material=material, thickness=thickness,
                separation=separation, window_count=windows,
                length_tiles=length,
                between=(boundary[len(boundary) // 2][0],
                         boundary[len(boundary) // 2][1]),
            )
            count += 1
    return count


def _pick_material(graph: LevelGraph, a: str, b: str, leaky: bool,
                   rng: random.Random) -> Tuple[WallMaterial, float]:
    """재질과 두께. 재질은 제6단계 교정에서 바뀌지 않는다 — 미술 자산이
    재질 단위로 준비되기 때문이다."""
    ta = DEFAULT_THREAT.get(graph.get_node(a).node_type, ThreatLevel.LOW)
    tb = DEFAULT_THREAT.get(graph.get_node(b).node_type, ThreatLevel.LOW)
    secure = ThreatLevel.HIGH in (ta, tb)

    if not leaky:
        # 새지 않는 면은 두꺼운 구조체. 구버전의 '링크 없음'에 해당한다.
        return WallMaterial.CONCRETE, rng.uniform(0.75, 1.0)
    pool = _MATERIALS_SECURE if secure else _MATERIALS_CIVIL
    material = rng.choice(pool)
    thickness = (rng.uniform(0.5, 0.9) if secure else rng.uniform(0.15, 0.5))
    return material, thickness


def _blocks_windows(graph: LevelGraph, a: str, b: str) -> bool:
    return (graph.get_node(a).node_type in _NO_WINDOW
            or graph.get_node(b).node_type in _NO_WINDOW)


def adjacency_summary(graph: LevelGraph) -> Dict[str, float]:
    walls = list(graph.proximity_links.values())
    if not walls:
        return {"walls": 0.0}
    leaky = [w for w in walls if w.sound_leak >= 0.15]
    windowed = [w for w in walls if w.window_count > 0]
    return {
        "walls": float(len(walls)),
        "leaky": float(len(leaky)),
        "windowed": float(len(windowed)),
        "windows_total": float(sum(w.window_count for w in walls)),
        "mean_sound_leak": sum(w.sound_leak for w in walls) / len(walls),
        "mean_visual_leak": sum(w.visual_leak for w in walls) / len(walls),
    }
