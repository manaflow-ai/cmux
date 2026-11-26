"""scripts/ci/fast_track.py and its use in the pr router: docs, plans, skills, copy and tests-only changes run the cheap tier."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

import fast_track  # noqa: E402
import pr_router  # noqa: E402

EVENT = {"action": "synchronize", "pull_request": {"draft": False, "labels": []}}
CALLEES = {
    "full.yml": {"types": ["synchronize"]},
    "cheap.yml": {"types": ["synchronize"], "draft": True},
}


class FastTrackTests(unittest.TestCase):
    def test_docs_and_tests_are_fast(self):
        self.assertTrue(fast_track.classify(["docs/ci/x.md", "tests/test_x.py"])[0])

    def test_product_code_or_workflow_is_not(self):
        for path in (".github/workflows/ci.yml", "scripts/ci/pr_router.py", "Cargo.lock"):
            self.assertFalse(fast_track.classify(["docs/a.md", path])[0], path)

    def test_empty_is_not(self):
        self.assertFalse(fast_track.classify([])[0])

    def test_kill_switch(self):
        self.assertTrue(fast_track.enabled({}))
        self.assertFalse(fast_track.enabled({"CMUX_FAST_TRACK": "0"}))

    def _route(self, files, decided=("full", "x"), labels=()):
        event = {"action": "synchronize", "pull_request": {"draft": False, "labels": [{"name": n} for n in labels]}}
        return pr_router.route(event, CALLEES, files, decided=decided)[0]

    def test_router_runs_only_cheap_callees(self):
        self.assertEqual(self._route(["docs/a.md"]), ["cheap.yml"])

    def test_router_full_for_code(self):
        self.assertEqual(self._route(["scripts/ci/pr_router.py"]), ["cheap.yml", "full.yml"])

    def test_full_ci_label_wins(self):
        self.assertEqual(self._route(["docs/a.md"], labels=("full-ci",)), ["cheap.yml", "full.yml"])

    def test_full_ci_keeps_path_filters(self):
        # Before, full-ci started every callee whatever its path filter: swift-linux-packages.yml ran on 511 branches
        # in 24 h (42.8k runner-min). full-ci lifts the tier gates only; a callee the change cannot reach stays off.
        callees = {**CALLEES, "swift.yml": {"types": ["synchronize"], "paths": ["Packages/**"]}}
        event = {"action": "synchronize", "pull_request": {"draft": False, "labels": [{"name": "full-ci"}]}}
        start, why = pr_router.route(event, callees, ["docs/a.md"], decided=("full", "x"))
        self.assertEqual(start, ["cheap.yml", "full.yml"])
        self.assertEqual(why["swift.yml"], "its path filter admits no changed file")
        # Adding full-ci is the land handoff: it routes as ready_for_review, still through the path filters.
        added = {"action": "labeled", "label": {"name": "full-ci"}, "pull_request": event["pull_request"]}
        callees = {name: {**c, "types": ["ready_for_review"]} for name, c in callees.items()}
        self.assertNotIn("swift.yml", pr_router.route(added, callees, ["docs/a.md"], decided=("full", "x"))[0])
        self.assertIn("swift.yml", pr_router.route(added, callees, ["Packages/x.swift"], decided=("full", "x"))[0])


if __name__ == "__main__":
    unittest.main()
