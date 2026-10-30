"""공간 배치 계층(파이프라인 제6단계) 단위 테스트."""
from __future__ import annotations

import json

from stealth_pcg.export.serializer import LevelSerializer
from stealth_pcg.core.graph import reset_id_generator
from stealth_pcg.grammar.generator import GenerationConfig, LevelGenerator
from stealth_pcg.layout import (LayoutConfig, from_level_graph, layout_to_json,
                                solve_layout)
from stealth_pcg.core.types import (WallMaterial, compute_sound_leak,
                                    compute_visual_leak)
from stealth_pcg.grammar.adjacency import AdjacencyConfig, derive_shared_walls
from stealth_pcg.layout.config import OVERLAY_TRAVERSALS
from stealth_pcg.layout.solver import shared_boundary
from stealth_pcg.layout.render_html import render_layout_svg


def _graph(seed: int = 42):
    # 전역 ID 생성기를 초기화해야 시드만으로 재현된다.
    reset_id_generator()
    return LevelGenerator(GenerationConfig(seed=seed)).generate()


def test_adapter_reads_level_graph():
    g = _graph()
    d = from_level_graph(g)
    assert len(d.nodes) == g.node_count
    assert len(d.edges) == g.edge_count
    assert len(d.proximity) == g.proximity_count
    assert d.critical_path and d.critical_path[0] == g.find_entry().id


def test_every_node_is_placed():
    for seed in (0, 1, 42):
        g = _graph(seed)
        tile, _ = solve_layout(g, LayoutConfig(seed=seed))
        assert set(tile.rooms) == set(g.nodes), f"seed {seed}"


def test_rooms_do_not_overlap_in_coarse_cells():
    g = _graph(7)
    _, coarse = solve_layout(g, LayoutConfig(seed=7))
    seen = set()
    for rp in coarse.rooms.values():
        assert not (seen & rp.cells), f"{rp.node_id} overlaps an existing room"
        seen |= rp.cells


def test_corridor_cells_never_collide_with_rooms():
    g = _graph(3)
    _, coarse = solve_layout(g, LayoutConfig(seed=3))
    room_cells = {c for rp in coarse.rooms.values() for c in rp.cells}
    for lane in coarse.lanes.values():
        assert not (set(lane.cells) & room_cells), lane.edge_id


def test_overlay_edges_do_not_occupy_the_ground_grid():
    """S4 가 만든 vent/climb 엣지는 지상 격자를 점유하지 않아야 한다."""
    g = _graph(1)
    tile, coarse = solve_layout(g, LayoutConfig(seed=1))
    for eid, e in g.edges.items():
        if e.traversal_type.value in OVERLAY_TRAVERSALS:
            assert eid not in coarse.lanes
            assert tile.corridors[eid].layer == "overlay"


def test_refine_is_deterministic_for_a_fixed_seed():
    g = _graph(5)
    a, _ = solve_layout(g, LayoutConfig(seed=5))
    b, _ = solve_layout(g, LayoutConfig(seed=5))
    assert a.col_widths == b.col_widths and a.row_heights == b.row_heights
    assert {k: v.bbox for k, v in a.rooms.items()} == \
           {k: v.bbox for k, v in b.rooms.items()}


def test_shared_walls_are_derived_from_geometry_not_declared():
    """공유벽은 배치 결과에서 읽어낸 기하적 사실이어야 한다.

    구버전은 위상 거리 2~3홉인 노드 쌍을 무작위로 뽑아 인접을 '선언'했고,
    그 시점에는 기하가 없었으므로 실현하지 못하는 링크가 남았다. 지금은
    격자에서 실제로 변을 맞댄 쌍만 등록되므로 미실현 링크가 존재할 수 없다.
    """
    for seed in (0, 3, 7):
        g = _graph(seed)
        assert g.proximity_count == 0, "문법 단계는 더 이상 공유벽을 만들지 않는다"

        _tile, coarse = solve_layout(g, LayoutConfig(seed=seed))
        derive_shared_walls(g, coarse, AdjacencyConfig(seed=seed))
        assert g.proximity_count > 0

        connected = {frozenset((e.source, e.target)) for e in g.edges.values()}
        for w in g.proximity_links.values():
            assert shared_boundary(coarse.rooms[w.node_a].cells,
                                   coarse.rooms[w.node_b].cells), \
                f"{w.id}: 실제로 맞닿지 않은 면"
            assert frozenset((w.node_a, w.node_b)) not in connected, \
                f"{w.id}: 통행 엣지가 있는 쌍은 문이지 공유벽이 아니다"


def test_sound_and_visual_leak_are_independent_axes():
    """재질·두께·이격·창문으로 분리한 결과, 두 전달 경로가 갈라져야 한다."""
    m = WallMaterial
    # 유리 — 시야는 통하고 소리는 막는다
    assert compute_visual_leak(m.GLASS, 0, 0) > 0.9
    assert compute_sound_leak(m.GLASS, 0.5, 0, 0, 8) < 0.12
    # 석고보드 — 소리는 새고 시야는 막힌다
    assert compute_visual_leak(m.DRYWALL, 0, 0) == 0.0
    assert compute_sound_leak(m.DRYWALL, 0.2, 0, 0, 8) > 0.2
    # 창문은 두께를 우회한다: 두꺼운 콘크리트라도 개구로 소리가 넘어온다
    solid = compute_sound_leak(m.CONCRETE, 0.9, 0, 0, 12)
    windowed = compute_sound_leak(m.CONCRETE, 0.9, 0, 1, 12)
    assert windowed > solid + 0.1
    # 소리는 개구 면적에 선형 누적, 시야는 포화
    s1 = compute_sound_leak(m.CONCRETE, 0.9, 0, 1, 12)
    s2 = compute_sound_leak(m.CONCRETE, 0.9, 0, 2, 12)
    v1 = compute_visual_leak(m.CONCRETE, 0, 1)
    v2 = compute_visual_leak(m.CONCRETE, 0, 2)
    assert (s2 - s1) > 0.9 * (s1 - solid)      # 선형에 가깝다
    assert (v2 - v1) < 0.5 * v1                # 포화한다


def test_separation_never_changes_which_rooms_are_adjacent():
    """제6단계의 이격 조정은 격자 점유를 건드리지 않는다.

    이 성질 덕분에 제4단계가 확정한 인접 관계를 뒤 단계가 뒤엎을 수 없다.
    """
    g = _graph(5)
    _tile, coarse = solve_layout(g, LayoutConfig(seed=5))
    derive_shared_walls(g, coarse, AdjacencyConfig(seed=5))
    before = {frozenset((w.node_a, w.node_b)) for w in g.proximity_links.values()}
    for w in g.proximity_links.values():
        w.separation = 8
    after = {frozenset((w.node_a, w.node_b)) for w in g.proximity_links.values()}
    assert before == after


def test_json_v2_carries_cell_level_layout_only():
    """JSON 은 재생 불가능한 것만 싣는다.

    타일 단위 정제(격자선 간격·여백·L자 절단·복도 우회)는 refine_seed 에서
    결정적으로 재생되므로 클라이언트가 자기 에셋 치수에 맞춰 다시 만든다.
    재생할 수 없는 것은 배치 탐색의 해, 즉 방의 격자 점유뿐이다.
    """
    g = _graph(42)
    _tile, coarse = solve_layout(g, LayoutConfig(seed=42))
    derive_shared_walls(g, coarse, AdjacencyConfig(seed=42))
    doc = LevelSerializer(g).to_dict(
        meta={"seed": 42}, layout=layout_to_json(coarse, g, refine_seed=42))

    assert doc["version"] == 2
    assert set(doc["layout"]) == {"unit", "refine_seed", "hints",
                                  "rooms", "links", "walls", "stats"}
    assert set(doc["layout"]["rooms"]) == set(doc["nodes"])
    assert doc["layout"]["unit"] == "cell"
    # 격자 좌표는 원점 기준으로 정규화되어 음수가 없어야 한다
    for room in doc["layout"]["rooms"].values():
        for cx, cy in room["cells"]:
            assert cx >= 0 and cy >= 0
    json.dumps(doc)


def test_svg_renders_without_error():
    g = _graph(0)
    tile, _ = solve_layout(g, LayoutConfig(seed=0))
    svg = render_layout_svg(tile, from_level_graph(g))
    assert svg.startswith("<svg") and svg.endswith("</svg>")
    assert svg.count("<rect") >= len(tile.rooms)


def test_essential_edges_are_never_left_unconnected():
    """mandatory 엣지와 임계 경로 엣지는 반드시 문 또는 복도로 실현된다.

    이것이 깨지면 Godot 에서 통과 불가능한 레벨이 만들어지므로,
    proximity 충족률보다 우선하는 경성 제약이다.
    """
    for seed in (0, 3, 7, 11):
        g = _graph(seed)
        _tile, coarse = solve_layout(g, LayoutConfig(seed=seed))
        assert not coarse.essential_unrouted, (
            f"seed {seed}: essential edges unrouted {coarse.essential_unrouted}")

        cp = g.critical_path() or []
        pairs = {frozenset((cp[i], cp[i + 1])) for i in range(len(cp) - 1)}
        for eid in coarse.unrouted_edges:
            e = g.edges[eid]
            assert frozenset((e.source, e.target)) not in pairs
            assert not e.mandatory


