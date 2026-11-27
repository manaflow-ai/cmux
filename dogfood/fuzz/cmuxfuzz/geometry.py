"""Pure layout checks over pane rectangles; no app or socket needed."""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class Rect:
    x: float
    y: float
    w: float
    h: float

    @property
    def area(self) -> float:
        return max(self.w, 0.0) * max(self.h, 0.0)

    def intersection(self, other: "Rect") -> float:
        w = min(self.x + self.w, other.x + other.w) - max(self.x, other.x)
        h = min(self.y + self.h, other.y + other.h) - max(self.y, other.y)
        return w * h if w > 0 and h > 0 else 0.0

    def contains(self, other: "Rect", slack: float) -> bool:
        return (
            other.x >= self.x - slack
            and other.y >= self.y - slack
            and other.x + other.w <= self.x + self.w + slack
            and other.y + other.h <= self.y + self.h + slack
        )


def tiling_problems(
    container: Rect,
    panes: dict[str, Rect],
    *,
    divider_slack: float = 12.0,
    min_coverage: float = 0.9,
    min_side: float = 1.0,
) -> list[tuple[str, str]]:
    """Returns (invariant, detail) pairs; empty when the panes tile the container.

    Dividers and borders leave gaps between panes, so coverage only has to
    reach `min_coverage` of the container, and containment allows
    `divider_slack` points.
    """
    problems: list[tuple[str, str]] = []
    for pid, rect in panes.items():
        if rect.w < min_side or rect.h < min_side:
            problems.append(("pane-degenerate-size", f"{pid} is {rect.w:g}x{rect.h:g}"))
        elif not container.contains(rect, divider_slack):
            problems.append(("pane-outside-window", f"{pid} at {rect} outside {container}"))
    ids = sorted(panes)
    for i, a in enumerate(ids):
        for b in ids[i + 1 :]:
            overlap = panes[a].intersection(panes[b])
            # A shared 1-point border is not an overlap.
            if overlap > max(4.0, 0.01 * min(panes[a].area, panes[b].area)):
                problems.append(("panes-overlap", f"{a} and {b} overlap by {overlap:.0f} pt^2"))
    if container.area > 0 and panes:
        covered = sum(r.area for r in panes.values())
        ratio = covered / container.area
        if ratio < min_coverage:
            problems.append(("panes-leave-gap", f"panes cover {ratio:.0%} of the content area"))
    return problems
