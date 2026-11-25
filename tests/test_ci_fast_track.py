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


if __name__ == "__main__":
    unittest.main()
