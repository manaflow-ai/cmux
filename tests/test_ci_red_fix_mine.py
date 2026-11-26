#!/usr/bin/env python3
"""red_fix_mine (scripts/ci/red_fix_mine.py): a PR's red commit and its next commit form a pair; the fix is
classified by its files (formatter-only, generated, test registry, workflow, language) or, unread, by the red's
failing checks and the fix's subject. No network.

Run: python3 -I tests/test_ci_red_fix_mine.py"""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts" / "ci"))
import red_fix_mine as m  # noqa: E402


def commit(oid, at, state, failed=(), subject="", parents=1):
    nodes = [{"name": n, "conclusion": "FAILURE"} for n in failed]
    return {"commit": {"oid": oid, "committedDate": at, "messageHeadline": subject, "additions": 1, "deletions": 1,
                       "parents": {"totalCount": parents},
                       "statusCheckRollup": {"state": state, "contexts": {"nodes": nodes}}}}


class ClassifyTests(unittest.TestCase):
    def test_files(self):
        self.assertEqual(m.classify_files([{"filename": "a.swift", "patch": "-  x = 1\n+x = 1"}]), "formatter")
        self.assertEqual(m.classify_files([{"filename": "plans/cmux-next/actions.json", "patch": "-a\n+b"},
                                           {"filename": "webviews/bun.lock", "patch": "-a\n+b"}]), "generated")
        self.assertEqual(m.classify_files([{"filename": "tests/test-execution.toml", "patch": "+x"}]),
                         "test-registry")
        self.assertEqual(m.classify_files([{"filename": ".github/workflows/ci.yml", "patch": "-a\n+b"}]),
                         "workflow-lint")
        self.assertEqual(m.classify_files([{"filename": "crates/x/src/lib.rs", "patch": "-a\n+b"}]), "rust-compile")
        self.assertEqual(m.classify_files([{"filename": "web/a.tsx", "patch": "-a\n+b"},
                                           {"filename": "x.rs", "patch": "-a\n+b"}]), "other")

    def test_hints(self):
        self.assertEqual(m.classify_hint([], "Merge branch 'main' into lane/x", False), "base-merge")
        self.assertEqual(m.classify_hint([], "anything", True), "base-merge")
        self.assertEqual(m.classify_hint(["cmux-next / cmux-next generated files"], "fix", False), "generated")
        self.assertEqual(m.classify_hint(["webviews / typecheck"], "address review", False), "ts-typecheck")
        self.assertEqual(m.classify_hint([], "Fix TS2339 in App.tsx", False), "ts-typecheck")


class PairTests(unittest.TestCase):
    def test_red_then_next_is_a_pair_and_bot_reds_are_not(self):
        pr = {"number": 7, "commits": {"nodes": [
            commit("a", "2026-11-25T07:00:00Z", "FAILURE", ["CI / typecheck"]),
            commit("b", "2026-11-25T07:12:00Z", "FAILURE", ["CLA Assistant / CLA Assistant"], "fix types"),
            commit("c", "2026-11-25T07:30:00Z", "SUCCESS")]}}
        pairs = m.pairs_of(pr)
        self.assertEqual([(p["red"], p["fix"]) for p in pairs], [("a", "b")])
        self.assertEqual(pairs[0]["wait_min"], 12.0)


if __name__ == "__main__":
    unittest.main()
