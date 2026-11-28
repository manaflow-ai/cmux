#!/usr/bin/env python3
"""scripts/ci/palette_coverage_gate.py: a gap the pull request adds fails; one the base already has is a note."""
from __future__ import annotations

import importlib.util
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("palette_coverage_gate", ROOT / "scripts/ci/palette_coverage_gate.py")
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


def report(*gaps: str, problems: tuple[str, ...] = ()) -> dict:
    entries = [{"surface": g.split(" ", 1)[0], "name": g.split(" ", 1)[1], "what": "x"} for g in gaps]
    return {"missing": len(entries), "kept": 1, "entries": entries, "problems": list(problems)}


class Judge(unittest.TestCase):
    def test_new_gap_fails(self):
        added, old = gate.judge(report("cli foo bar"), report())
        self.assertEqual(added, ["missing: cli foo bar"])
        self.assertEqual(old, [])

    def test_gap_on_base_is_a_note(self):
        added, old = gate.judge(report("cli foo bar", "action x.y"), report("cli foo bar"))
        self.assertEqual(added, ["missing: action x.y"])
        self.assertEqual(old, ["missing: cli foo bar"])

    def test_new_problem_fails_and_unreadable_base_counts_nothing_as_old(self):
        added, _ = gate.judge(report(problems=("cli a: maps to b, which is no registry action",)), None)
        self.assertEqual(added, ["problem: cli a: maps to b, which is no registry action"])


class OnThisTree(unittest.TestCase):
    def test_runs_on_the_checkout_against_head(self):
        head = subprocess.run(["git", "-C", str(ROOT), "rev-parse", "HEAD"], capture_output=True, text=True)
        if head.returncode != 0:
            self.skipTest("no git checkout")
        got = subprocess.run([sys.executable, "-I", str(ROOT / "scripts/ci/palette_coverage_gate.py"),
                              "--base", head.stdout.strip(), "--repo", str(ROOT)], capture_output=True, text=True)
        # Against itself nothing is added, so it passes whatever the count is.
        self.assertEqual(got.returncode, 0, got.stdout + got.stderr)


if __name__ == "__main__":
    unittest.main()
