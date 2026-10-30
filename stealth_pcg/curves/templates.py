"""
stealth_pcg.curves.templates
=============================
Designer tension curves: presets, custom builder, and interpolation.

A tension curve is defined by **control points** on a normalised
[0, 1] × [0, 1] plane.  The x-axis is normalised level progress
(0 = ENTRY, 1 = EXIT), the y-axis is target tension (0 = calm, 1 = peak).

Control points are interpolated to match any actual path length via
cubic or linear interpolation.  This decouples the designer's intent
from the generated level's size.

Usage (presets)::

    curve = TensionCurve.escalating()
    values = curve.sample(n=15)  # tension at each of 15 rooms

Usage (custom)::

    curve = TensionCurve.from_points([(0, 0.1), (0.3, 0.8), (0.7, 0.2), (1, 0.9)])

Usage (interactive builder)::

    builder = CurveBuilder()
    builder.add(0.0, 0.1)
    builder.add(0.5, 0.9)
    builder.add(1.0, 0.6)
    curve = builder.build()
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field
from typing import Sequence


@dataclass(frozen=True)
class ControlPoint:
    """A single point on the tension curve."""
    x: float  # 0..1 (progress)
    y: float  # 0..1 (tension)

    def __post_init__(self) -> None:
        if not (0.0 <= self.x <= 1.0):
            raise ValueError(f"x must be in [0,1], got {self.x}")
        if not (0.0 <= self.y <= 1.0):
            raise ValueError(f"y must be in [0,1], got {self.y}")


class TensionCurve:
    """A designer-defined target tension curve.

    Internally stored as sorted control points.  Supports linear and
    cosine interpolation to produce tension values at arbitrary resolution.
    """

    def __init__(
        self,
        points: Sequence[ControlPoint],
        *,
        name: str = "custom",
        interpolation: str = "cosine",  # "linear" or "cosine"
    ) -> None:
        if len(points) < 2:
            raise ValueError("Need at least 2 control points")
        self.points = sorted(points, key=lambda p: p.x)
        self.name = name
        self.interpolation = interpolation

        # Validate endpoints
        if self.points[0].x != 0.0:
            raise ValueError("First control point must have x=0.0")
        if self.points[-1].x != 1.0:
            raise ValueError("Last control point must have x=1.0")

    def evaluate(self, t: float) -> float:
        """Evaluate tension at normalised progress *t* ∈ [0, 1]."""
        t = max(0.0, min(1.0, t))

        # Find surrounding control points
        for i in range(len(self.points) - 1):
            p0 = self.points[i]
            p1 = self.points[i + 1]
            if p0.x <= t <= p1.x:
                if p1.x == p0.x:
                    return p0.y
                local_t = (t - p0.x) / (p1.x - p0.x)
                if self.interpolation == "cosine":
                    # Cosine interpolation — smoother than linear
                    local_t = (1 - math.cos(local_t * math.pi)) / 2
                return p0.y + (p1.y - p0.y) * local_t

        return self.points[-1].y

    def sample(self, n: int) -> list[float]:
        """Sample *n* evenly-spaced tension values along the curve.

        This is the primary interface for the fitness evaluator:
        given a level with *n* rooms on the critical path, produce the
        target tension sequence of length *n*.
        """
        if n < 2:
            return [self.evaluate(0.5)]
        return [self.evaluate(i / (n - 1)) for i in range(n)]

    def to_dict(self) -> dict:
        """Serialize for JSON export / UI storage."""
        return {
            "name": self.name,
            "interpolation": self.interpolation,
            "points": [{"x": p.x, "y": p.y} for p in self.points],
        }

    @classmethod
    def from_dict(cls, data: dict) -> TensionCurve:
        """Deserialize."""
        points = [ControlPoint(p["x"], p["y"]) for p in data["points"]]
        return cls(
            points,
            name=data.get("name", "custom"),
            interpolation=data.get("interpolation", "cosine"),
        )

    @classmethod
    def from_points(
        cls,
        xy_pairs: list[tuple[float, float]],
        *,
        name: str = "custom",
        interpolation: str = "cosine",
    ) -> TensionCurve:
        """Convenience: create from a list of (x, y) tuples."""
        points = [ControlPoint(x, y) for x, y in xy_pairs]
        return cls(points, name=name, interpolation=interpolation)

    # ──────────────────────────────────────────
    # Preset templates (Sonancia 2016 set + stealth variants)
    # ──────────────────────────────────────────

    @classmethod
    def escalating(cls) -> TensionCurve:
        """Steady climb from calm to peak.  Classic difficulty ramp."""
        return cls.from_points(
            [(0, 0.1), (0.5, 0.5), (1, 0.95)],
            name="escalating",
        )

    @classmethod
    def v_shape(cls) -> TensionCurve:
        """Start tense, relax in the middle, tense again at the end."""
        return cls.from_points(
            [(0, 0.7), (0.2, 0.4), (0.5, 0.15), (0.8, 0.5), (1, 0.9)],
            name="v_shape",
        )

    @classmethod
    def inverted_v(cls) -> TensionCurve:
        """Calm start, peak in the middle, calm ending.  Good for
        "one big heist in the center" design."""
        return cls.from_points(
            [(0, 0.1), (0.3, 0.4), (0.5, 0.95), (0.7, 0.4), (1, 0.15)],
            name="inverted_v",
        )

    @classmethod
    def double_peak(cls) -> TensionCurve:
        """Two tension peaks with a valley between.
        "Get the keycard, breathe, then the final push." """
        return cls.from_points(
            [(0, 0.1), (0.25, 0.8), (0.45, 0.2), (0.75, 0.9), (1, 0.7)],
            name="double_peak",
        )

    @classmethod
    def late_climax(cls) -> TensionCurve:
        """Long calm exploration, sudden spike at the end.
        The "Invisible Inc. alarm clock" pattern."""
        return cls.from_points(
            [(0, 0.1), (0.6, 0.2), (0.8, 0.5), (0.95, 0.95), (1, 0.85)],
            name="late_climax",
        )

    @classmethod
    def roller_coaster(cls) -> TensionCurve:
        """Rapid oscillation between tense and calm.
        Alternating high-security and safe zones."""
        return cls.from_points(
            [(0, 0.1), (0.15, 0.7), (0.3, 0.2), (0.45, 0.8),
             (0.6, 0.15), (0.75, 0.85), (0.9, 0.3), (1, 0.9)],
            name="roller_coaster",
        )

    @classmethod
    def flat_high(cls) -> TensionCurve:
        """Sustained high tension throughout.  Hardcore mode."""
        return cls.from_points(
            [(0, 0.7), (0.5, 0.8), (1, 0.85)],
            name="flat_high",
        )

    @classmethod
    def all_presets(cls) -> dict[str, TensionCurve]:
        """Return all preset curves keyed by name."""
        return {
            "escalating": cls.escalating(),
            "v_shape": cls.v_shape(),
            "inverted_v": cls.inverted_v(),
            "double_peak": cls.double_peak(),
            "late_climax": cls.late_climax(),
            "roller_coaster": cls.roller_coaster(),
            "flat_high": cls.flat_high(),
        }

    def __repr__(self) -> str:
        return f"TensionCurve({self.name!r}, {len(self.points)} points)"


class CurveBuilder:
    """Interactive builder for custom tension curves.

    Designed for a game UI where the player drags control points::

        builder = CurveBuilder()
        builder.add(0.0, 0.1)   # start calm
        builder.add(0.5, 0.9)   # peak in the middle
        builder.add(1.0, 0.6)   # moderate ending
        curve = builder.build()
    """

    def __init__(self) -> None:
        self._points: list[ControlPoint] = []

    def add(self, x: float, y: float) -> CurveBuilder:
        """Add a control point.  Returns self for chaining."""
        self._points.append(ControlPoint(x, y))
        return self

    def remove_nearest(self, x: float) -> CurveBuilder:
        """Remove the control point closest to *x*.
        Won't remove if fewer than 2 points would remain."""
        if len(self._points) <= 2:
            return self
        nearest_idx = min(range(len(self._points)),
                         key=lambda i: abs(self._points[i].x - x))
        self._points.pop(nearest_idx)
        return self

    def move(self, index: int, x: float, y: float) -> CurveBuilder:
        """Move control point at *index* to new position."""
        x = max(0.0, min(1.0, x))
        y = max(0.0, min(1.0, y))
        self._points[index] = ControlPoint(x, y)
        return self

    def clear(self) -> CurveBuilder:
        """Remove all control points."""
        self._points.clear()
        return self

    @property
    def points(self) -> list[ControlPoint]:
        return sorted(self._points, key=lambda p: p.x)

    def build(
        self,
        *,
        name: str = "custom",
        interpolation: str = "cosine",
        auto_endpoints: bool = True,
    ) -> TensionCurve:
        """Build the curve.

        If *auto_endpoints* is True, automatically add x=0 and x=1
        endpoints if missing (using the nearest existing point's y value).
        """
        pts = sorted(self._points, key=lambda p: p.x)

        if auto_endpoints:
            if not pts or pts[0].x != 0.0:
                y0 = pts[0].y if pts else 0.1
                pts.insert(0, ControlPoint(0.0, y0))
            if pts[-1].x != 1.0:
                pts.append(ControlPoint(1.0, pts[-1].y))

        return TensionCurve(pts, name=name, interpolation=interpolation)
