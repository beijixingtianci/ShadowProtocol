"""
stealth_pcg.core.types
======================
All enumeration types and shared constants for the stealth-escape PCG system.

Design note: Every enum uses ``auto()`` and derives from ``str`` so values
serialize cleanly to JSON and print readably in logs.
"""

from __future__ import annotations

import math
from enum import Enum, auto


# ──────────────────────────────────────────────
# Node types (v2 §2.1)
# ──────────────────────────────────────────────

class NodeType(str, Enum):
    """Functional type of a spatial unit in the level graph."""

    ENTRY = "entry"
    EXIT = "exit"
    OBJECTIVE = "objective"
    SIDE_OBJECTIVE = "side_objective"
    TRANSIT = "transit"
    OBSERVATION = "observation"
    HIGH_SECURITY = "high_security"
    CHOKE = "choke"
    ALT_PATH = "alt_path"
    KEY_ROOM = "key_room"


# ──────────────────────────────────────────────
# Edge required attributes (v2 §2.2.1)
# ──────────────────────────────────────────────

class TraversalType(str, Enum):
    """How the player traverses this edge."""

    NORMAL = "normal"
    STEALTH_REQUIRED = "stealth_required"
    VENT = "vent"
    CLIMB = "climb"
    HACK = "hack"
    TAKEDOWN_REQUIRED = "takedown_required"


class Visibility(str, Enum):
    """Whether the edge is visible to the player."""

    OBVIOUS = "obvious"
    HIDDEN = "hidden"
    CONDITIONAL = "conditional"


class NoiseLevel(str, Enum):
    """Noise produced when traversing the edge."""

    SILENT = "silent"
    LOW = "low"
    MEDIUM = "medium"
    HIGH = "high"


# ──────────────────────────────────────────────
# Threat level (convenience enum for node defaults)
# ──────────────────────────────────────────────

class ThreatLevel(str, Enum):
    """Coarse threat category for quick node characterization."""

    LOW = "low"
    MEDIUM = "medium"
    HIGH = "high"
    VARIABLE = "variable"


# ──────────────────────────────────────────────
# Approach style tags (v2 §2.2.2 approach_tags)
# ──────────────────────────────────────────────

class ApproachTag(str, Enum):
    """Play-style tags an edge supports."""

    STEALTH = "stealth"
    COMBAT = "combat"       # i.e. takedown / assassination
    HACK = "hack"
    SOCIAL = "social"       # disguise-based


# ──────────────────────────────────────────────
# Alert state FSM (Leonard / Smith model)
# ──────────────────────────────────────────────

class AlertState(str, Enum):
    """Enemy alert state (used by simulation agent)."""

    UNAWARE = "unaware"
    SUSPICIOUS = "suspicious"
    INVESTIGATING = "investigating"
    ALERT = "alert"


# ──────────────────────────────────────────────
# Shared wall model (proximity layer)
# ──────────────────────────────────────────────
#
# 구버전의 WallType 은 두께와 재질을 한 축에 섞어 두어 '두꺼운 유리'나
# '얇은 철판' 같은 조합을 표현할 수 없었고, 청각 전달과 시각 전달이 같은
# 값에서 파생되어 유리(소리는 막고 시야는 통함)를 제대로 다룰 수 없었다.
# 재질 · 두께 · 이격 · 창문 수 네 축으로 분리한다.

class WallMaterial(str, Enum):
    """공유벽의 재질. 차음 계수와 투명도를 결정한다."""

    CONCRETE = "concrete"   # 콘크리트·조적 — 두께 효과가 가장 크다
    DRYWALL = "drywall"     # 석고보드 칸막이 — 소리가 샌다
    GLASS = "glass"         # 유리 — 차음은 준수, 시야는 그대로 통한다
    METAL = "metal"         # 철판 — 차음 중간, 파괴 가능하되 시끄럽다
    MESH = "mesh"           # 철망·격자 — 소리도 시야도 거의 통과


#: 재질별 기본 음향 투과율 (두께 1.0 기준)
MATERIAL_TRANSMISSION: dict[WallMaterial, float] = {
    WallMaterial.CONCRETE: 0.05,
    WallMaterial.DRYWALL:  0.45,
    WallMaterial.GLASS:    0.15,
    WallMaterial.METAL:    0.20,
    WallMaterial.MESH:     0.80,
}

#: 재질별 투명도. 청각과 독립이다.
MATERIAL_TRANSPARENCY: dict[WallMaterial, float] = {
    WallMaterial.CONCRETE: 0.0,
    WallMaterial.DRYWALL:  0.0,
    WallMaterial.GLASS:    0.95,
    WallMaterial.METAL:    0.0,
    WallMaterial.MESH:     0.70,
}

#: 창문 한 짝이 차지하는 벽 길이 (타일)
WINDOW_WIDTH_TILES = 3
#: 창문 사이 및 양 끝에 필요한 여유 (타일)
WINDOW_MARGIN_TILES = 2
#: 창문 수 상한. 이보다 많으면 벽이 아니라 개구부다.
WINDOW_MAX = 3

SOUND_THICKNESS_K = 0.45        # 두께 감쇠 상수
SOUND_SEPARATION_LAMBDA = 3.0   # 이격 감쇠 상수 (타일)
WINDOW_SOUND_GAIN = 0.55        # 창문 개구 면적당 음향 우회량
WINDOW_VISUAL_DECAY = 0.35      # 창문 추가분의 시각 포화 계수
SEPARATION_VISUAL_CUT = 0.45    # 이격 2타일 이상일 때 시야 감쇠


def window_capacity(length_tiles: float, material: WallMaterial) -> int:
    """벽 길이에서 나오는 창문 수 상한.

    기하가 정하는 값이며 자유 파라미터가 아니다. 짧은 벽에는 창을 낼 수
    없고 긴 벽일수록 조절 폭이 커진다 — '연결이 많은 방은 실제로 크다'와
    같은 부류의, 공간에서 자동으로 따라 나오는 합리성이다.

    유리벽은 면 전체가 이미 개구이므로 창문 개념이 성립하지 않는다.
    """
    if material is WallMaterial.GLASS:
        return 0
    usable = length_tiles - WINDOW_MARGIN_TILES
    if usable <= 0:
        return 0
    return max(0, min(WINDOW_MAX, int(usable // (WINDOW_WIDTH_TILES + 1))))


def compute_sound_leak(material: WallMaterial, thickness: float,
                       separation: float, window_count: int,
                       length_tiles: float) -> float:
    """청각 전달률.

    창문은 두께를 **우회**한다. 콘크리트 벽에 창을 하나 내면 두께가 아무리
    두꺼워도 그 개구를 통해 소리가 그대로 넘어온다. 개구 면적에 선형으로
    누적된다 — 창 두 짝은 한 짝의 두 배로 샌다.
    """
    base = MATERIAL_TRANSMISSION[material]
    body = base * math.exp(-max(0.0, thickness) / SOUND_THICKNESS_K)
    body *= math.exp(-max(0.0, separation) / SOUND_SEPARATION_LAMBDA)
    ratio = 0.0
    if window_count > 0 and length_tiles > 0:
        ratio = min(1.0, window_count * WINDOW_WIDTH_TILES / length_tiles)
    return max(0.0, min(1.0, body + WINDOW_SOUND_GAIN * ratio))


def compute_visual_leak(material: WallMaterial, separation: float,
                        window_count: int) -> float:
    """시각 전달률.

    청각과 달리 **포화**한다. 창 한 짝이면 이미 옆방이 보이고, 두 번째
    창은 시야각을 넓힐 뿐이다. 두께와는 무관하다.
    """
    base = MATERIAL_TRANSPARENCY[material]
    if window_count > 0:
        base = base + (1.0 - base) * (1.0 - WINDOW_VISUAL_DECAY ** window_count)
    if separation >= 2:
        base *= SEPARATION_VISUAL_CUT
    return max(0.0, min(1.0, base))


# ──────────────────────────────────────────────
# Default attribute mappings
# ──────────────────────────────────────────────

#: Default threat level by node type (v2 §2.1 table, rightmost column).
DEFAULT_THREAT: dict[NodeType, ThreatLevel] = {
    NodeType.ENTRY:          ThreatLevel.LOW,
    NodeType.EXIT:           ThreatLevel.VARIABLE,
    NodeType.OBJECTIVE:      ThreatLevel.HIGH,
    NodeType.SIDE_OBJECTIVE: ThreatLevel.MEDIUM,
    NodeType.TRANSIT:        ThreatLevel.LOW,
    NodeType.OBSERVATION:    ThreatLevel.LOW,
    NodeType.HIGH_SECURITY:  ThreatLevel.HIGH,
    NodeType.CHOKE:          ThreatLevel.HIGH,
    NodeType.ALT_PATH:       ThreatLevel.LOW,
    NodeType.KEY_ROOM:       ThreatLevel.MEDIUM,
}

#: Traversal-type → default noise (rule A5)
DEFAULT_NOISE: dict[TraversalType, NoiseLevel] = {
    TraversalType.NORMAL:            NoiseLevel.LOW,
    TraversalType.STEALTH_REQUIRED:  NoiseLevel.SILENT,
    TraversalType.VENT:              NoiseLevel.SILENT,
    TraversalType.CLIMB:             NoiseLevel.LOW,
    TraversalType.HACK:              NoiseLevel.SILENT,
    TraversalType.TAKEDOWN_REQUIRED: NoiseLevel.MEDIUM,
}

#: Traversal-type → implied approach tags (rule A3/A6 helper)
TRAVERSAL_TO_TAGS: dict[TraversalType, set[ApproachTag]] = {
    TraversalType.NORMAL:            {ApproachTag.STEALTH},
    TraversalType.STEALTH_REQUIRED:  {ApproachTag.STEALTH},
    TraversalType.VENT:              {ApproachTag.STEALTH},
    TraversalType.CLIMB:             {ApproachTag.STEALTH},
    TraversalType.HACK:              {ApproachTag.HACK},
    TraversalType.TAKEDOWN_REQUIRED: {ApproachTag.COMBAT},
}
