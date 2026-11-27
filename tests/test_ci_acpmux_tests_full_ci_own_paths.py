#!/usr/bin/env python3
"""A full-ci pull request runs acpmux tests only when it touches acpmux's own paths.

full-ci lifts acpmux-tests' feat-cmux-next skip (the post-merge batch runs it), but not the acpmux-own gate: a
full-ci pull request that reached acpmux only through a path dependency ran the whole ~24 min suite on every head
(25T17-26T17Z 2026-11: 1,162 pull request runs, 28.2k job-minutes, 18 of 27 sampled touching no acpmux path). The
post-merge batch and feat-cmux-next pushes still run it on every reach.

Run: python3 tests/test_ci_acpmux_tests_full_ci_own_paths.py
"""

from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "cmux-tui-spec.yml"


def load() -> dict:
    return yaml.safe_load(WORKFLOW.read_text())


def own_regex(doc: dict) -> re.Pattern:
    step = next(s for s in doc["jobs"]["changes"]["steps"] if s.get("id") == "acpmux-own")
    return re.compile(re.search(r"grep -Eq '([^']+)'", step["run"]).group(1))


def own_gate(doc: dict) -> str:
    cond = doc["jobs"]["acpmux-tests"]["if"]
    m = re.search(r"\(github\.event_name != 'pull_request' \|\| needs\.changes\.outputs\.acpmux_own != 'false'[^)]*\)",
                  cond)
    assert m, "acpmux-tests' if lost its acpmux_own clause"
    return m.group(0)


def gate_runs(gate: str, own_changed: bool, labels: list[str]) -> bool:
    """The acpmux_own clause on a pull_request event, evaluated for the clause's two known forms."""
    if "full-ci" in gate and "full-ci" in labels:
        return True
    return own_changed


class FullCiOwnPaths(unittest.TestCase):
    def setUp(self):
        self.doc = load()
        self.own = own_regex(self.doc)
        self.gate = own_gate(self.doc)

    def test_full_ci_does_not_lift_the_own_paths_gate(self):
        self.assertNotIn("full-ci", self.gate, self.gate)

    def test_an_acpmux_change_runs_under_full_ci(self):
        changed = bool(self.own.search("cmux-tui/crates/acpmux/src/lib.rs"))
        self.assertTrue(changed)
        self.assertTrue(gate_runs(self.gate, changed, ["full-ci"]))
        self.assertTrue(self.own.search("cmux-tui/crates/acpmux-core/src/x.rs"))
        self.assertTrue(self.own.search("cmux-tui/Cargo.lock"))

    def test_an_unrelated_change_skips_under_full_ci(self):
        for path in ("cmux-tui/crates/cmux-tui/src/main.rs", "webviews/src/app.tsx", "scripts/ci/head_tier.py"):
            with self.subTest(path=path):
                changed = bool(self.own.search(path))
                self.assertFalse(changed)
                self.assertFalse(gate_runs(self.gate, changed, ["full-ci", "ready-to-land"]))


if __name__ == "__main__":
    sys.exit(unittest.main())
