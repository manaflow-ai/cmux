# SPDX-License-Identifier: MIT
"""Small statistics helpers (stdlib only)."""

from __future__ import annotations

import math
import statistics


def wilson(successes: int, n: int, z: float = 1.959964) -> tuple[float, float]:
    """The Wilson score interval for a binomial proportion (95% by default)."""
    if n == 0:
        return (0.0, 1.0)
    p = successes / n
    denom = 1 + z * z / n
    center = (p + z * z / (2 * n)) / denom
    half = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / denom
    return (max(0.0, center - half), min(1.0, center + half))


def median(values: list[float]) -> float | None:
    values = [v for v in values if v is not None]
    return statistics.median(values) if values else None


def newcombe_diff(s1: int, n1: int, s2: int, n2: int) -> tuple[float, float, float]:
    """Difference of two proportions p1 - p2 with Newcombe's hybrid score interval."""
    if n1 == 0 or n2 == 0:
        return (0.0, -1.0, 1.0)
    p1, p2 = s1 / n1, s2 / n2
    l1, u1 = wilson(s1, n1)
    l2, u2 = wilson(s2, n2)
    d = p1 - p2
    lo = d - math.sqrt((p1 - l1) ** 2 + (u2 - p2) ** 2)
    hi = d + math.sqrt((u1 - p1) ** 2 + (p2 - l2) ** 2)
    return (d, max(-1.0, lo), min(1.0, hi))
