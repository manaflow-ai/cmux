#!/usr/bin/env python3
"""Print the repository paths the action exports are made from, one git pathspec per line.

The exports (plans/cmux-next/action-surfaces.json and the generated block of
plans/cmux-next/actions.md) are written by one test, ActionSurfaceParityTests in
the CmuxNextActionsTests target (scripts/cmux-next/regenerate-action-contracts.sh).
So they are a function of that target's sources, the targets it depends on, the
local packages those use, the files its sources read (the graph's "reads"), and
the manifest inputs every package test has. The target graph
(Packages/macOS/CmuxNext/ci-target-graph.json, made from `swift package
dump-package` by scripts/cmux-next/ci-target-graph.py, the same graph
scripts/ci/cmux_next_route.py routes test targets by) names all of them.

judge-action-exports.sh reads this to tell whether a change moved the exports'
inputs, and to key the base's fresh exports. Before it, every change under
Packages counted: 214 keys a day on feat-cmux-next (2026-11-16..17), against
63 for these paths.

Reads the graph JSON on stdin (`git show REV:Packages/macOS/CmuxNext/ci-target-graph.json`).
Exits 1 when the graph lacks the target, so the caller falls back to its broad inputs.
A read with `*` (a pattern) is widened to the folder before its first `*`.
"""

from __future__ import annotations

import json
import sys

PACKAGE = "Packages/macOS/CmuxNext/"
TEST_TARGET = "CmuxNextActionsTests"
ALWAYS = (
    PACKAGE + "Package.swift",
    PACKAGE + "Package.resolved",
    PACKAGE + "app-ffi-pin.json",
    PACKAGE + "ci-target-graph.json",
    "scripts/cmux-next/regenerate-action-contracts.sh",
)


def inputs(graph: dict) -> list[str]:
    targets = graph["targets"]
    if TEST_TARGET not in targets:
        raise KeyError(TEST_TARGET)
    seen: set[str] = set()
    pending = [TEST_TARGET]
    found = set(ALWAYS)
    while pending:
        name = pending.pop()
        if name in seen:
            continue
        seen.add(name)
        target = targets[name]
        if target.get("path"):
            found.add(target["path"].rstrip("/") + "/")
        for package in target.get("packages") or []:
            found.add(graph["packages"][package].rstrip("/") + "/")
        pending.extend(target.get("targets") or [])
    for read in targets[TEST_TARGET].get("reads") or []:
        if "*" in read:
            read = read[: read.index("*")]
            read = read[: read.rindex("/") + 1] if "/" in read else ""
        if read:
            found.add(read)
        else:
            raise ValueError("a read pattern at the repository root")
    return sorted(found)


def main() -> int:
    try:
        paths = inputs(json.load(sys.stdin))
    except (ValueError, KeyError, TypeError, AttributeError) as error:
        print(f"action_export_inputs: {error!r}", file=sys.stderr)
        return 1
    print("\n".join(paths))
    return 0


if __name__ == "__main__":
    sys.exit(main())
