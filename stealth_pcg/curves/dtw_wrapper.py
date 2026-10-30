"""
stealth_pcg.curves.dtw_wrapper
===============================
DTW-based curve similarity with Sakoe-Chiba banding and length penalty.

Uses ``dtaidistance`` for fast C-optimised DTW when available,
falls back to a pure-Python implementation otherwise.  Both paths compute the
same quantity (sum of |a - b| along the warping path, Sakoe-Chiba band), so the
result does not depend on which one is installed.

Per the research report:
- Always use Sakoe-Chiba band of 10-15% of sequence length
- Always normalise y-axis to [0, 1]
- Always include a length-deviation penalty
"""

from __future__ import annotations

import math
from typing import Sequence

try:
    from dtaidistance import dtw as _dtw_lib
    _HAS_DTAIDISTANCE = True
except ImportError:
    _HAS_DTAIDISTANCE = False


def dtw_distance(
    seq_a: Sequence[float],
    seq_b: Sequence[float],
    *,
    window_fraction: float = 0.12,
) -> float:
    """Compute DTW distance between two 1-D sequences.

    Uses Sakoe-Chiba band constraint with radius = ``window_fraction``
    × max(len(a), len(b)).

    Parameters
    ----------
    seq_a, seq_b : sequence of float
        The two tension traces to compare.
    window_fraction : float
        Band width as a fraction of the longer sequence (default 12%).

    Returns
    -------
    float
        The DTW distance (lower = more similar).
    """
    if not seq_a or not seq_b:
        return float("inf")

    window = max(1, math.ceil(window_fraction * max(len(seq_a), len(seq_b))))

    # The C path must return exactly what the pure-Python path returns, otherwise
    # the same seed evolves a different level depending on whether dtaidistance
    # is installed.  Two library defaults differ from our definition:
    #   - inner distance: default is squared differences + final sqrt (Euclidean);
    #     inner_dist='euclidean' on 1-D values is |a - b|, summed — same as ours.
    #   - band: the library keeps |i - j| < window, ours keeps |i - j| <= window.
    # The library also widens the band when lengths differ, so it is only used
    # for equal lengths (every fitness call compares a trace with the target
    # sampled to the same length).
    if _HAS_DTAIDISTANCE and len(seq_a) == len(seq_b):
        import array
        a_arr = array.array('d', seq_a)
        b_arr = array.array('d', seq_b)
        try:
            return _dtw_lib.distance_fast(
                a_arr, b_arr,
                window=window + 1,
                use_pruning=True,
                inner_dist='euclidean',
            )
        except Exception:
            pass  # C extension unavailable — fall through to pure Python
    return _dtw_pure_python(list(seq_a), list(seq_b), window)


def _dtw_pure_python(
    a: list[float],
    b: list[float],
    window: int,
) -> float:
    """Pure-Python DTW with Sakoe-Chiba band.  O(n·w) time/space."""
    n, m = len(a), len(b)
    INF = float("inf")

    # Cost matrix (only need current and previous row for memory efficiency)
    prev = [INF] * (m + 1)
    curr = [INF] * (m + 1)
    prev[0] = 0.0

    for i in range(1, n + 1):
        curr[0] = INF
        j_start = max(1, i - window)
        j_end = min(m, i + window)
        for j in range(1, m + 1):
            if j < j_start or j > j_end:
                curr[j] = INF
            else:
                cost = abs(a[i - 1] - b[j - 1])
                curr[j] = cost + min(prev[j], curr[j - 1], prev[j - 1])
        prev, curr = curr, prev

    result = prev[m]
    return result if result != INF else float("inf")


def normalised_dtw(
    seq_a: Sequence[float],
    seq_b: Sequence[float],
    *,
    window_fraction: float = 0.12,
) -> float:
    """DTW distance normalised by alignment length.

    Divides raw DTW distance by (len(a) + len(b)) so the metric
    is comparable across sequences of different lengths.
    """
    raw = dtw_distance(seq_a, seq_b, window_fraction=window_fraction)
    total_len = len(seq_a) + len(seq_b)
    if total_len == 0:
        return 0.0
    return raw / total_len


def curve_fitness(
    actual: Sequence[float],
    target: Sequence[float],
    *,
    window_fraction: float = 0.12,
    length_penalty_weight: float = 0.1,
    desired_length: int | None = None,
) -> float:
    """Combined fitness score for evolutionary evaluation.

    Combines normalised DTW distance with an optional length penalty.
    **Lower is better** (0 = perfect match).

    Parameters
    ----------
    actual : sequence of float
        Tension trace from simulation.
    target : sequence of float
        Target tension trace (sampled from designer curve at len(actual) points).
    window_fraction : float
        Sakoe-Chiba band width.
    length_penalty_weight : float
        Weight for the length deviation penalty (β in the formula).
    desired_length : int, optional
        If provided, adds penalty for |len(actual) - desired_length|.

    Returns
    -------
    float
        Fitness value (lower = better).
    """
    dtw_score = normalised_dtw(actual, target, window_fraction=window_fraction)

    # Length penalty
    length_penalty = 0.0
    if desired_length is not None and desired_length > 0:
        length_penalty = abs(len(actual) - desired_length) / desired_length

    return dtw_score + length_penalty_weight * length_penalty
