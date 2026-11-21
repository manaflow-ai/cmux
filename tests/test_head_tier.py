"""scripts/ci/head_tier.py and its use in the pr router: a draft head runs the cheap tier only."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

import head_tier  # noqa: E402
import pr_router  # noqa: E402


def event(draft: bool, labels: tuple[str, ...] = (), action: str = "synchronize") -> dict:
    return {"action": action, "pull_request": {"draft": draft, "labels": [{"name": n} for n in labels]}}


class TierTests(unittest.TestCase):
    def test_draft_is_cheap(self) -> None:
        self.assertEqual(head_tier.tier("pull_request", event(True))[0], "cheap")

    def test_ready_is_full(self) -> None:
        self.assertEqual(head_tier.tier("pull_request", event(False))[0], "full")

    def test_full_ci_label_makes_a_draft_full(self) -> None:
        self.assertEqual(head_tier.tier("pull_request", event(True, ("full-ci",)))[0], "full")

    def test_switch_off_makes_a_draft_full(self) -> None:
        self.assertEqual(head_tier.tier("pull_request", event(True), "0")[0], "full")

    def test_other_events_and_unreadable_payloads_are_full(self) -> None:
        self.assertEqual(head_tier.tier("push", event(True))[0], "full")
        self.assertEqual(head_tier.tier("pull_request", {})[0], "full")


class RouterTests(unittest.TestCase):
    CALLEES = {
        "heavy.yml": {"types": ["opened", "synchronize", "ready_for_review"]},
        "cheap.yml": {"types": ["opened", "synchronize", "ready_for_review"], "draft": True},
    }

    def test_a_draft_starts_only_draft_callees(self) -> None:
        start, why = pr_router.route(event(True), self.CALLEES, ["a.py"])
        self.assertEqual(start, ["cheap.yml"])
        self.assertIn("ready for review", why["heavy.yml"])

    def test_marking_ready_starts_everything(self) -> None:
        start, _ = pr_router.route(event(False, action="ready_for_review"), self.CALLEES, ["a.py"])
        self.assertEqual(start, ["cheap.yml", "heavy.yml"])

    def test_full_ci_and_the_switch_start_everything_on_a_draft(self) -> None:
        self.assertEqual(pr_router.route(event(True, ("full-ci",)), self.CALLEES, ["a.py"])[0],
                         ["cheap.yml", "heavy.yml"])
        self.assertEqual(pr_router.route(event(True), self.CALLEES, ["a.py"], "0")[0], ["cheap.yml", "heavy.yml"])

    def test_every_real_callee_that_skips_drafts_listens_to_ready_for_review(self) -> None:
        for name, config in pr_router.load_manifest().items():
            if not config.get("draft"):
                self.assertIn("ready_for_review", config["types"], name)


if __name__ == "__main__":
    unittest.main()
