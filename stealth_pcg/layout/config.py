"""공간 배치 계층 설정 (파이프라인 제6단계).

L1 위상 그래프 -> L2 거친 격자(coarse cell) -> L3 타일 좌표(tile) -> L4 Godot.
CSP 탐색은 L2 에서만 수행하고, L3 는 실패하지 않는 후처리이다.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Dict, List, Optional, Sequence, Tuple

Cell = Tuple[int, int]

# 지상층을 점유하지 않는 통행 방식. S4(ALT_PATH)가 생성하는 엣지가 여기에 해당하며,
# 이 엣지들을 제외한 지상 부분 그래프는 사실상 평면 그래프가 되어 격자 배치가 거의 항상 성공한다.
OVERLAY_TRAVERSALS = frozenset({"vent", "climb"})

# 문으로 처리되어 복도 셀을 점유하지 않는 통행 방식.
DOOR_TRAVERSALS = frozenset({"hack"})


@dataclass
class LayoutConfig:
    seed: int = 42

    # --- L2 탐색 ---
    gap_max_cells: int = 2           # 두 방 사이 복도가 점유할 수 있는 최대 셀 수
    candidates_per_node: int = 36    # 노드당 유지할 후보 배치 수 (충족 수 → 비용 순)
    node_budget: int = 120_000       # 백트래킹 탐색 노드 예산
    restarts: int = 8                # L2 재시작 횟수. 최량해를 고른다
    w_gap: float = 1.0               # exposure_length 목표 간격과의 편차
    w_door_bonus: float = 0.5        # 간격 0(문) 배치 우대. proximity 압력이
                                     # 사라졌으므로 구버전보다 크게 낮춘다
    w_compact: float = 0.22          # 전체 바운딩 박스 팽창 억제
    w_crowding: float = 1.2          # 아직 안 놓인 이웃을 위한 둘레 여유 확보
    w_edge_stretch: float = 2.0      # 통행 이웃과 배선 불가 거리로 벌어지는 것 억제
    w_enclose: float = 12.0          # 이웃 방을 완전히 가두는 배치 (복도 출구 소멸)
    w_reversal: float = 1.40         # 임계 경로가 왔던 방향으로 되꺾이는 것을 억제
    max_essential_cells: int = 3     # 필수 엣지가 떨어질 수 있는 최대 셀 거리

    # --- L3 정제 ---
    cell_tiles_min: int = 7          # 격자선 간격(타일). 열/행마다 독립 추첨 -> 격자감 제거
    cell_tiles_max: int = 13
    margin_min: int = 1              # 예산 박스 대비 방 외곽 여백(타일). 변마다 독립 추첨
    margin_max: int = 4
    corridor_width: int = 3
    l_cut_prob: float = 0.35         # 4셀 이상 방을 L자로 깎을 확률
    tile_size: int = 32              # Godot 픽셀 환산용. 배치 계산에는 쓰이지 않음

    # --- 공유벽 (제4단계가 기하에서 읽어낸다) ---
    leak_rate: float = 0.35          # 맞닿은 면 중 실제로 소리가 새는 비율
    separation_bonded: int = 0       # 누설 벽의 기본 이격 (타일)
    separation_neutral: int = 3      # 무관계 인접면의 기본 이격
    min_room_tiles: int = 4          # 이격을 키워도 방 한 변이 이보다 작아질 수 없다

    # --- 복도 길이 ---
    tiles_per_exposure_unit: int = 9  # exposure_length 1단위당 목표 복도 길이(타일)


@dataclass
class LayoutNode:
    id: str
    type: str


@dataclass
class LayoutEdge:
    id: str
    source: str
    target: str
    traversal_type: str = "normal"
    exposure_length: int = 2
    locked: bool = False
    visibility: str = "obvious"
    key_id: Optional[str] = None
    mandatory: bool = True   # 없으면 필수 엣지 보호가 조용히 무력화된다
    mandatory: bool = True     # False = S4/S5 가 만든 선택 경로

    @property
    def is_overlay(self) -> bool:
        return self.traversal_type in OVERLAY_TRAVERSALS

    @property
    def is_door_only(self) -> bool:
        return self.traversal_type in DOOR_TRAVERSALS


@dataclass
class LayoutProximity:
    id: str
    a: str
    b: str
    material: str = "drywall"
    thickness: float = 0.5
    separation: int = 0
    window_count: int = 0
    length_tiles: float = 8.0
    sound_leak: float = 0.0
    visual_leak: float = 0.0

    @property
    def wall_type(self) -> str:      # 렌더러 호환
        return self.material


@dataclass
class LayoutInput:
    nodes: Dict[str, LayoutNode]
    edges: Dict[str, LayoutEdge]
    proximity: Dict[str, LayoutProximity] = field(default_factory=dict)
    critical_path: Sequence[str] = ()

    def ground_edges(self) -> List[LayoutEdge]:
        return [e for e in self.edges.values() if not e.is_overlay]

    def neighbors_ground(self) -> Dict[str, List[Tuple[str, LayoutEdge]]]:
        adj: Dict[str, List[Tuple[str, LayoutEdge]]] = {n: [] for n in self.nodes}
        for e in self.ground_edges():
            if e.source in adj and e.target in adj:
                adj[e.source].append((e.target, e))
                adj[e.target].append((e.source, e))
        return adj
