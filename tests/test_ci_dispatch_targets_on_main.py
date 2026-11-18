#!/usr/bin/env python3
"""Every workflow a main workflow dispatches by file name resolves on main.

GitHub resolves `actions/workflows/<file>.yml` (list runs, dispatch) only for a
workflow it has registered: one whose file is on the default branch, or one that
some event on another branch has already run. A feat-cmux-next workflow with only
a `workflow_dispatch` trigger is never registered, so a dispatcher on main that
starts it 404s on every run. cu-driver-eval-dispatch.yml did from the day it
landed (#36154) until main got an inert registration copy of cu-driver-eval.yml,
as it already had for first-user-journey-web.yml, screen-stream-eval.yml and
cmux-next-perf-bench.yml.

A dispatch target must be a file in main's .github/workflows, or be named in
REGISTERED_ELSEWHERE with the reason GitHub already knows it.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"

# Not on main, but registered: GitHub answers GET actions/workflows/<file> with 200.
REGISTERED_ELSEWHERE = {
    # feat-cmux-next's own push and pull_request triggers run it there.
    "ios-review-gate.yml": "push trigger on feat-cmux-next",
    # Registered 2026-10-22 by an earlier run on feat-cmux-next.
    "cmux-next-perf-budgets.yml": "registered by a feat-cmux-next run on 2026-10-22",
}

# The ways a workflow names the workflow it starts: github-script's
# `workflow_id: 'x.yml'` or `const workflow = 'x.yml'`, the REST path
# `actions/workflows/x.yml/dispatches`, and `gh workflow run x.yml`.
TARGET = re.compile(
    r"""(?:workflow_id:\s*|const\s+workflow\s*=\s*)['"]([\w.-]+\.ya?ml)['"]"""
    r"""|actions/workflows/([\w.-]+\.ya?ml)/dispatches"""
    r"""|gh\s+workflow\s+run\s+['"]?([\w.-]+\.ya?ml)"""
)


def dispatch_targets() -> dict[str, set[str]]:
    found: dict[str, set[str]] = {}
    for path in sorted(WORKFLOWS.glob("*.y*ml")):
        for match in TARGET.finditer(path.read_text()):
            name = next(group for group in match.groups() if group)
            found.setdefault(name, set()).add(path.name)
    return found


class DispatchTargets(unittest.TestCase):
    def test_the_pattern_finds_each_way_of_naming_a_target(self) -> None:
        text = "\n".join(
            [
                "workflow_id: 'a.yml',",
                "const workflow = 'b.yml';",
                'gh api -X POST "repos/$R/actions/workflows/c.yml/dispatches"',
                "gh workflow run d.yml --ref feat-cmux-next",
            ]
        )
        names = {next(g for g in m.groups() if g) for m in TARGET.finditer(text)}
        self.assertEqual(names, {"a.yml", "b.yml", "c.yml", "d.yml"})

    def test_the_cu_driver_eval_dispatcher_is_seen(self) -> None:
        self.assertIn("cu-driver-eval.yml", dispatch_targets())

    def test_every_dispatch_target_resolves_on_main(self) -> None:
        on_main = {path.name for path in WORKFLOWS.glob("*.y*ml")}
        missing = {
            name: sorted(callers)
            for name, callers in dispatch_targets().items()
            if name not in on_main and name not in REGISTERED_ELSEWHERE
        }
        self.assertEqual(
            missing,
            {},
            "these workflows are dispatched by file name but are not on main, so GitHub "
            "answers 404 unless something registered them: add an inert registration copy "
            "(see first-user-journey-web.yml) or name them in REGISTERED_ELSEWHERE with the reason",
        )


if __name__ == "__main__":
    unittest.main()
