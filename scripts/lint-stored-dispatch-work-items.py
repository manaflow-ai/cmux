#!/usr/bin/env python3
"""Reject stored DispatchWorkItem declarations in Sources/ outside audited one-shot uses."""

from __future__ import annotations

import collections
import re
import sys
from dataclasses import dataclass
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent
SOURCES_ROOT = REPO_ROOT / "Sources"
DECLARATION = re.compile(
    r"\bvar\s+(?P<name>[A-Za-z_][A-Za-z0-9_]*)\s*:\s*(?P<type>[^=\n]+DispatchWorkItem[^=\n]*)"
)
INFERRED_DECLARATION = re.compile(
    r"\bvar\s+(?P<name>[A-Za-z_][A-Za-z0-9_]*)\s*=\s*"
    r"(?P<type>DispatchWorkItem\b|\[[^\]\n]*DispatchWorkItem[^\]\n]*\]\s*\()"
)


@dataclass(frozen=True)
class Allowance:
    path: str
    name: str
    type_text: str
    count: int
    reason: str


# These declarations never replace queued work. Keep the list exact so adding
# another declaration with the same spelling still fails the guard.
ALLOWANCES = (
    Allowance(
        "Sources/AppDelegate.swift",
        "timeoutWorkItem",
        "DispatchWorkItem?",
        2,
        "function-local, single-shot debug/UI-test deadlines",
    ),
    Allowance(
        "Sources/Panels/MarkdownRemoteImageLoader.swift",
        "timeoutWorkItem",
        "DispatchWorkItem?",
        1,
        "single-shot network timeout protected by finish()",
    ),
    Allowance(
        "Sources/TabManager.swift",
        "timeoutWork",
        "DispatchWorkItem?",
        1,
        "function-local, single-shot UI-test deadline",
    ),
    Allowance(
        "Sources/Update/UpdateTitlebarAccessory.swift",
        "startupScanWorkItems",
        "[DispatchWorkItem]",
        1,
        "fixed-size append-only startup scan fanout",
    ),
)


def normalized_type(value: str) -> str:
    return "".join(value.split())


def declarations() -> collections.Counter[tuple[str, str, str]]:
    found: collections.Counter[tuple[str, str, str]] = collections.Counter()
    for path in sorted(SOURCES_ROOT.rglob("*.swift")):
        relative = path.relative_to(REPO_ROOT).as_posix()
        for line in path.read_text(encoding="utf-8").splitlines():
            match = DECLARATION.search(line)
            if match is None:
                match = INFERRED_DECLARATION.search(line)
            if match is None:
                continue
            found[(relative, match.group("name"), normalized_type(match.group("type")))] += 1
    return found


def main() -> int:
    actual = declarations()
    allowed = collections.Counter(
        (item.path, item.name, normalized_type(item.type_text))
        for item in ALLOWANCES
        for _ in range(item.count)
    )

    unexpected = actual - allowed
    stale = allowed - actual
    if not unexpected and not stale:
        print(
            "lint-stored-dispatch-work-items: ok "
            f"({sum(actual.values())} audited non-replacement declarations)"
        )
        return 0

    print(
        "Stored DispatchWorkItem declarations can rebuild recursive release chains. "
        "Use MainActorDeferredActionScheduler for replace-on-reschedule work.",
        file=sys.stderr,
    )
    for (path, name, type_text), count in sorted(unexpected.items()):
        print(
            f"unexpected: {path}: {name}: {type_text} (count={count})",
            file=sys.stderr,
        )
    for (path, name, type_text), count in sorted(stale.items()):
        print(
            f"stale allowance: {path}: {name}: {type_text} (count={count})",
            file=sys.stderr,
        )
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
