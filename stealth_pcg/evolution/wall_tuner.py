"""파이프라인 제6단계 — 벽 교정 (Wall Tuner).

구버전의 Proximity Tuner 는 인접 링크를 **추가·삭제**할 수 있었다. 그래서
아무 관계도 없는 두 방 사이에 링크를 만들어낼 수 있었고, 그런 링크는 뒤에
오는 배치 단계에서 실현 불가능했다.

관선 재편 이후 벽의 집합은 기하가 정한 고정값이다. 이 단계는 이미 존재하는
면의 성질만 조정한다. 조정 가능한 축은 셋이다.

  thickness    연속. 차음량만 바꾼다.
  separation   정수(타일). 두 방을 각자의 격자 칸 안에서 서로 멀리 밀어낸다.
               눈에 보이지 않는 연속적 지렛대이며, 재질 계단 사이를 메운다.
  window_count 정수. 청각과 시각을 **따로** 밀 수 있는 유일한 축이다.
               소리는 개구 면적에 선형으로 누적되고 시각은 포화하므로,
               창을 하나 더 내면 소음 압박이 실질적으로 늘어난다.

material 은 잠근다. 미술 자산이 재질 단위로 준비되고, 재질은 제4단계가
양쪽 방의 성격에 따라 이미 결정했기 때문이다.

능력이 줄어든 것처럼 보이지만 실제로는 반대다. 구버전은 전체 노드 쌍의
15% 안에서만 손댈 수 있었으나, 지금은 관선이 내놓는 14~23 면 전부가
조작 대상이고 **모든 조작이 반드시 실현된다**.
"""
from __future__ import annotations

import random
from dataclasses import dataclass, field
from typing import Dict, List, Optional

from stealth_pcg.core.graph import LevelGraph, SharedWall
from stealth_pcg.core.types import DEFAULT_THREAT, ThreatLevel
from stealth_pcg.curves.dtw_wrapper import normalised_dtw
from stealth_pcg.curves.templates import TensionCurve
from stealth_pcg.simulation.agent import LevelSimulator, ShortestPathAgent
from stealth_pcg.simulation.tension import TensionWeights


@dataclass
class TunerConfig:
    max_iterations: int = 10
    deviation_threshold: float = 0.15
    max_changes_per_iter: int = 3
    #: 1회 조정 폭
    thickness_step: float = 0.20
    separation_step: int = 1
    separation_range: tuple[int, int] = (0, 8)
    seed: Optional[int] = None


@dataclass
class TunerResult:
    graph: LevelGraph
    initial_fitness: float
    final_fitness: float
    iterations_used: int
    walls_changed: int
    windows_added: int
    windows_removed: int
    per_room_corrections: List[dict] = field(default_factory=list)

    # 구버전 필드 호환 (링크 추가·삭제는 더 이상 일어나지 않는다)
    @property
    def links_added(self) -> int:
        return 0

    @property
    def links_removed(self) -> int:
        return 0


class WallTuner:
    """진화 수렴 후, 잔여 편차가 큰 방의 공유벽 성질을 국소 조정한다."""

    def __init__(self, target_curve: TensionCurve, *,
                 config: Optional[TunerConfig] = None,
                 tension_weights: Optional[TensionWeights] = None) -> None:
        self.target = target_curve
        self.config = config or TunerConfig()
        self.tw = tension_weights or TensionWeights()
        self._rng = random.Random(self.config.seed)

    # ------------------------------------------------------------------ #
    def tune(self, graph: LevelGraph) -> TunerResult:
        cfg = self.config
        initial = self._evaluate(graph)
        current = initial
        changed = win_add = win_rm = 0
        log: List[dict] = []
        iteration = 0
        deviations: List[dict] = []

        for iteration in range(cfg.max_iterations):
            deviations = self._find_deviations(graph)
            if not deviations:
                break
            deviations.sort(key=lambda d: abs(d["deviation"]), reverse=True)

            done = 0
            for dev in deviations:
                if abs(dev["deviation"]) < cfg.deviation_threshold:
                    break
                if done >= cfg.max_changes_per_iter:
                    break
                action = self._adjust(graph, dev["node_id"], dev["deviation"])
                if action is None:
                    continue
                log.append(action)
                changed += 1
                done += 1
                if action["axis"] == "window_count":
                    if action["to"] > action["from"]:
                        win_add += action["to"] - action["from"]
                    else:
                        win_rm += action["from"] - action["to"]

            new = self._evaluate(graph)
            if new >= current and iteration > 0:
                break
            current = new

        return TunerResult(
            graph=graph, initial_fitness=initial, final_fitness=current,
            iterations_used=iteration + 1 if deviations else 0,
            walls_changed=changed, windows_added=win_add,
            windows_removed=win_rm, per_room_corrections=log,
        )

    # ------------------------------------------------------------------ #
    def _adjust(self, graph: LevelGraph, node_id: str,
                deviation: float) -> Optional[dict]:
        """이 방의 긴장도를 올리거나(deviation<0) 내린다(>0).

        고위협 이웃과 맞댄 면부터 손댄다 — 그쪽이 지렛대가 크다.
        축은 창문 → 이격 → 두께 순으로 시도한다. 창문이 먼저인 것은 그것이
        청각과 시각을 분리해 밀 수 있는 유일한 수단이기 때문이다.
        """
        walls = self._ranked_walls(graph, node_id)
        if not walls:
            return None
        raise_tension = deviation < 0

        for wall in walls:
            for axis in ("window_count", "separation", "thickness"):
                action = self._try_axis(wall, axis, raise_tension)
                if action is not None:
                    action.update(node_id=node_id, wall_id=wall.id,
                                  direction="up" if raise_tension else "down")
                    return action
        return None

    def _try_axis(self, wall: SharedWall, axis: str,
                  raise_tension: bool) -> Optional[dict]:
        cfg = self.config
        if axis == "window_count":
            cap = wall.capacity
            if cap == 0:
                return None
            new = wall.window_count + (1 if raise_tension else -1)
            if not (0 <= new <= cap) or new == wall.window_count:
                return None
            old, wall.window_count = wall.window_count, new
            return {"axis": axis, "from": old, "to": new}

        if axis == "separation":
            lo, hi = cfg.separation_range
            # 긴장을 올리려면 붙이고(이격↓), 내리려면 떼어놓는다(이격↑)
            new = wall.separation + (-cfg.separation_step if raise_tension
                                     else cfg.separation_step)
            new = max(lo, min(hi, new))
            if new == wall.separation:
                return None
            old, wall.separation = wall.separation, new
            return {"axis": axis, "from": old, "to": new}

        # thickness — 올리려면 얇게, 내리려면 두껍게
        new = wall.thickness + (-cfg.thickness_step if raise_tension
                                else cfg.thickness_step)
        new = max(0.1, min(1.0, new))
        if abs(new - wall.thickness) < 1e-6:
            return None
        old, wall.thickness = wall.thickness, new
        return {"axis": "thickness", "from": round(old, 3), "to": round(new, 3)}

    def _ranked_walls(self, graph: LevelGraph, node_id: str) -> List[SharedWall]:
        scored = []
        for neighbor, wall in graph.proximity_neighbors(node_id):
            threat = DEFAULT_THREAT.get(neighbor.node_type, ThreatLevel.LOW)
            tv = {"low": 0.1, "medium": 0.4, "high": 0.8,
                  "variable": 0.5}.get(threat.value, 0.3)
            scored.append((tv, wall))
        scored.sort(key=lambda t: -t[0])
        return [w for _tv, w in scored]

    # ------------------------------------------------------------------ #
    def _evaluate(self, graph: LevelGraph) -> float:
        sim = LevelSimulator(strategy=ShortestPathAgent(), tension_weights=self.tw)
        result = sim.simulate(graph)
        if not result.reached_exit:
            return 10.0
        return normalised_dtw(result.tension_trace,
                              self.target.sample(len(result.tension_trace)))

    def _find_deviations(self, graph: LevelGraph) -> List[dict]:
        sim = LevelSimulator(strategy=ShortestPathAgent(), tension_weights=self.tw)
        result = sim.simulate(graph)
        if not result.reached_exit or len(result.tension_trace) < 2:
            return []
        target = self.target.sample(len(result.tension_trace))
        out: List[dict] = []
        for i, (actual, want) in enumerate(zip(result.tension_trace, target)):
            if i < len(result.path):
                out.append({"node_id": result.path[i], "index": i,
                            "actual": actual, "target": want,
                            "deviation": actual - want})
        return out


#: 구버전 이름 호환
ProximityTuner = WallTuner
