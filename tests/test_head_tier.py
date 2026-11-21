"""scripts/ci/head_tier.py and its use in the pr router: a draft head runs the cheap tier only."""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
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


DAY = 24 * 3600


class IdleTests(unittest.TestCase):
    """A real repository: a branch with its own commit, then two base merges on top."""

    def git(self, *args: str, when: int | None = None) -> str:
        env = dict(os.environ)
        if when is not None:
            env.update(GIT_AUTHOR_DATE=f"{when} +0000", GIT_COMMITTER_DATE=f"{when} +0000")
        return subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false",
                               *args], cwd=self.dir, env=env, check=True, capture_output=True,
                              text=True).stdout.strip()

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = self.tmp.name
        self.now = 1_800_000_000
        self.git("init", "-q", "-b", "feat-cmux-next")
        self.git("commit", "-q", "--allow-empty", "-m", "base", when=self.now - 10 * DAY)
        self.git("checkout", "-q", "-b", "lane/x")
        self.git("commit", "-q", "--allow-empty", "-m", "own work", when=self.now - 3 * DAY)
        self.own = self.git("rev-parse", "HEAD")
        self.git("checkout", "-q", "feat-cmux-next")
        self.git("commit", "-q", "--allow-empty", "-m", "base moves", when=self.now - 2 * DAY)
        self.git("checkout", "-q", "lane/x")
        self.git("merge", "-q", "--no-ff", "-m", "Merge branch 'feat-cmux-next' into lane/x", "feat-cmux-next",
                 when=self.now - 2 * DAY)
        self.git("checkout", "-q", "feat-cmux-next")
        self.git("commit", "-q", "--allow-empty", "-m", "base moves again", when=self.now - 60)
        self.git("checkout", "-q", "lane/x")
        self.git("merge", "-q", "--no-ff", "-m", "Merge remote-tracking branch 'origin/feat-cmux-next' into lane/x",
                 "feat-cmux-next", when=self.now - 30)
        self.head = self.git("rev-parse", "HEAD")
        self.cwd = os.getcwd()
        os.chdir(self.dir)

    def tearDown(self) -> None:
        os.chdir(self.cwd)
        self.tmp.cleanup()

    @staticmethod
    def event(sha: str, action: str = "synchronize", labels: tuple[str, ...] = ()) -> dict:
        return {"action": action, "pull_request": {"draft": False, "head": {"sha": sha},
                                                   "base": {"ref": "feat-cmux-next"},
                                                   "labels": [{"name": n} for n in labels]}}

    def test_two_base_merges_on_a_branch_idle_three_days_run_nothing(self) -> None:
        facts = head_tier.head_facts(self.event(self.head))
        self.assertEqual(facts, {"base_merge_only": True, "own_last": self.now - 3 * DAY})
        self.assertEqual(head_tier.tier("pull_request", self.event(self.head), facts=facts, now=self.now)[0], "none")

    def test_a_recent_own_commit_is_not_idle(self) -> None:
        facts = head_tier.head_facts(self.event(self.head))
        self.assertEqual(head_tier.tier("pull_request", self.event(self.head), facts=facts,
                                        now=self.now - 2 * DAY - 60)[0], "full")

    def test_an_own_commit_head_is_full(self) -> None:
        facts = head_tier.head_facts(self.event(self.own))
        self.assertEqual(facts, {"base_merge_only": False, "own_last": None})
        self.assertEqual(head_tier.tier("pull_request", self.event(self.own), facts=facts, now=self.now)[0], "full")

    def test_full_ci_the_switch_and_other_actions_override(self) -> None:
        facts = head_tier.head_facts(self.event(self.head))
        tier = head_tier.tier
        self.assertEqual(tier("pull_request", self.event(self.head, labels=("full-ci",)), facts=facts,
                              now=self.now)[0], "full")
        self.assertEqual(tier("pull_request", self.event(self.head), facts=facts, now=self.now, idle_switch="0")[0],
                         "full")
        self.assertEqual(tier("pull_request", self.event(self.head, "ready_for_review"), facts=facts,
                              now=self.now)[0], "full")
        self.assertIsNone(head_tier.head_facts(self.event(self.head, "opened")))

    def test_an_unreadable_head_is_full(self) -> None:
        facts = head_tier.head_facts(self.event("0" * 40))
        self.assertIsNone(facts)
        self.assertEqual(head_tier.tier("pull_request", self.event("0" * 40), facts=facts, now=self.now)[0], "full")

    def test_the_router_starts_nothing_for_an_idle_base_merge(self) -> None:
        decided = head_tier.tier("pull_request", self.event(self.head),
                                 facts=head_tier.head_facts(self.event(self.head)), now=self.now)
        start, why = pr_router.route(self.event(self.head), RouterTests.CALLEES, ["a.py"], decided=decided)
        self.assertEqual(start, [])
        self.assertIn("only merges the base", why["cheap.yml"])


if __name__ == "__main__":
    unittest.main()
