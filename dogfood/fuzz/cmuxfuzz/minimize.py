"""Delta minimization of a failing action sequence.

`reproduces(steps)` replays `steps` against a fresh app and returns True when
the same failure signature comes back. Replays are expensive (an app launch
each), so the search is bounded by `max_replays` and `deadline`.
"""

from __future__ import annotations

import time
from dataclasses import dataclass, field
from typing import Callable, Sequence, TypeVar

T = TypeVar("T")


@dataclass
class MinimizeResult:
    steps: list
    replays: int
    exhausted: bool
    log: list[str] = field(default_factory=list)


def _split(items: Sequence[T], n: int) -> list[list[T]]:
    size, extra = divmod(len(items), n)
    chunks, start = [], 0
    for i in range(n):
        end = start + size + (1 if i < extra else 0)
        chunks.append(list(items[start:end]))
        start = end
    return [c for c in chunks if c]


def ddmin(
    steps: Sequence[T],
    reproduces: Callable[[list[T]], bool],
    *,
    max_replays: int = 60,
    deadline: float | None = None,
    stop: Callable[[], bool] | None = None,
) -> MinimizeResult:
    """Zeller's ddmin, with a replay budget.

    The input is assumed to fail. Every candidate keeps the original order, and
    actions address panes, tabs and workspaces by relative position, so any
    subsequence stays executable.
    """
    current = list(steps)
    replays = 0
    log: list[str] = []

    def attempt(candidate: list[T], why: str) -> bool:
        nonlocal replays
        if (replays >= max_replays or (deadline is not None and time.monotonic() > deadline)
                or (stop is not None and stop())):
            raise _Budget()
        replays += 1
        ok = reproduces(candidate)
        log.append(f"{why}: {len(candidate)} steps -> {'reproduces' if ok else 'passes'}")
        return ok

    n = 2
    try:
        while len(current) >= 2:
            chunks = _split(current, n)
            reduced = False
            for i, chunk in enumerate(chunks):
                if attempt(chunk, f"subset {i + 1}/{len(chunks)}"):
                    current, n, reduced = chunk, 2, True
                    break
            if not reduced and n > 2:
                for i in range(len(chunks)):
                    complement = [s for j, c in enumerate(chunks) if j != i for s in c]
                    if attempt(complement, f"complement {i + 1}/{len(chunks)}"):
                        current, n, reduced = complement, max(n - 1, 2), True
                        break
            if not reduced:
                if n >= len(current):
                    break
                n = min(len(current), n * 2)
        # One-at-a-time removal catches single steps ddmin's chunking kept.
        i = 0
        while i < len(current) and len(current) > 1:
            candidate = current[:i] + current[i + 1 :]
            if attempt(candidate, f"drop step {i + 1}"):
                current = candidate
            else:
                i += 1
    except _Budget:
        return MinimizeResult(current, replays, True, log)
    return MinimizeResult(current, replays, False, log)


class _Budget(Exception):
    pass
