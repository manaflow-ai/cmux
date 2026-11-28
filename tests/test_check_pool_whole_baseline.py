#!/usr/bin/env python3
"""A pool command that reads the whole tree runs on every pull request: no new one joins without a line here.

scripts/ci/check-pool-whole.txt lists the whole-tree commands of scripts/ci/cmux-next-slow-checks.txt today. A new
command must name its inputs or declare them (`# guard-inputs:` in its source, scripts/ci/guard_step_inputs.py), so
`--affected` can skip it on a change it cannot reach; one that stops reading the whole tree leaves the list.
"""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
import check_pool_affected as pool  # noqa: E402
import guard_step_inputs as graph  # noqa: E402

POOL = ROOT / "scripts" / "ci" / "cmux-next-slow-checks.txt"


def baseline() -> set[str]:
    return {line for line in pool.WHOLE_BASELINE.read_text().splitlines() if line and not line.startswith("#")}


class WholeBaselineTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.now = pool.whole(graph.Tree(ROOT), POOL.read_text().splitlines())

    def test_no_new_whole_tree_command(self):
        now = self.now
        new = [f"{command}  ({why})" for command, why in now if command not in baseline()]
        self.assertEqual(new, [], "a pool command reads the whole tree, so it would run on every pull request: name "
                                  "its inputs or declare them with `# guard-inputs:` in its source "
                                  "(scripts/ci/guard_step_inputs.py DECLARED), then check with "
                                  "check_pool_affected.py --verify --match TEXT")

    def test_the_baseline_shrinks(self):
        now = {command for command, _why in self.now}
        stale = sorted(baseline() - now)
        self.assertEqual(stale, [], f"no longer whole-tree (or gone from the pool): drop from {pool.WHOLE_BASELINE.name}")

    def test_a_new_undeclared_walk_is_flagged(self):
        lines = ["[x]", "python3 scripts/ci/check_pool_affected.py --whole"]
        self.assertEqual([c for c, _ in pool.whole(graph.Tree(ROOT), lines)], [lines[1]])


if __name__ == "__main__":
    unittest.main()
