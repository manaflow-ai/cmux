#!/usr/bin/env python3
"""Labeled PR groups in the batch queue: assembly, check union, bisect and landing."""
from __future__ import annotations

import datetime as dt
import subprocess
import sys
import threading
import unittest
from argparse import Namespace
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/ci"))
import next_batch as nb  # noqa: E402
import next_batch_groups as groups  # noqa: E402

NEW_TAB = "Packages/macOS/CmuxNext/Sources/CmuxNextApp/NewTab/NewTabPageView.swift"
AGENT_PANE = "Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/AgentPaneView.swift"
WEBVIEW = "webviews/src/pages/markdown/links.ts"
DOCS = "docs/ci/cmux-next-batch.md"
NOW = dt.datetime(2026, 10, 6, 5, 0, tzinfo=dt.timezone.utc)


def pr(number: int, **fields) -> nb.PullRequest:
    defaults = dict(sha=f"{number:040x}", title=f"PR {number}", author="teamleaderleo",
                    committed_at="2026-10-06T04:00:00Z", head_ref=f"lane-{number}")
    defaults.update(fields)
    return nb.PullRequest(number=number, **defaults)


class Assembly(unittest.TestCase):
    def test_members_share_one_batch_label(self):
        prs = [pr(1, labels=["batch:ui"]), pr(2, labels=["batch:ui", "dev-build"]), pr(3, labels=["batch:infra"]),
               pr(4), pr(5, labels=["batch:ui", "batch:infra"])]
        found = groups.assemble(prs)
        self.assertEqual({name: [item.number for item in members] for name, members in found.items()},
                         {"ui": [1, 2], "infra": [3]})
        self.assertEqual(groups.conflicting_groups(prs[4].labels), ["batch:infra", "batch:ui"])

    def test_stack_order_wins_then_label_order_then_number(self):
        a, b, c, d = pr(10), pr(11), pr(12), pr(13)
        # 13 is stacked on 10 (its head contains 10's); 12 got the label first.
        ancestors = {(a.sha, d.sha)}
        labeled = {10: "2026-10-19T03:00:00Z", 11: "2026-10-19T02:00:00Z", 12: "2026-10-19T01:00:00Z",
                   13: "2026-10-19T00:00:00Z"}
        ordered = groups.order([a, b, c, d], labeled, lambda x, y: (x, y) in ancestors)
        self.assertEqual([item.number for item in ordered], [12, 11, 10, 13])
        self.assertEqual([item.number for item in groups.order([b, a], {}, lambda x, y: False)], [10, 11])

    def test_a_review_pass_is_for_the_current_head(self):
        sha = "a" * 40
        self.assertTrue(groups.reviewed(sha, [{"state": "APPROVED", "commit": {"oid": sha}}], []))
        self.assertFalse(groups.reviewed(sha, [{"state": "APPROVED", "commit": {"oid": "b" * 40}}], []))
        self.assertTrue(groups.reviewed(sha, [], ["Looks right.\nreview-pass: aaaaaaaaaaaa\n"]))
        self.assertFalse(groups.reviewed(sha, [], ["review-pass: bbbbbbbbbbbb"]))
        self.assertFalse(groups.reviewed(sha, [{"state": "COMMENTED", "commit": {"oid": sha}}], ["no marker"]))

    def test_a_members_own_red_check_does_not_keep_it_out(self):
        member = pr(1, labels=["batch:ui"], checks=[("ci-status", "completed", "failure")],
                    files=[WEBVIEW])
        self.assertIsNotNone(nb.ineligible_reason(member, NOW))
        self.assertIsNone(nb.ineligible_reason(member, NOW, own_checks=False))
        self.assertEqual(nb.ineligible_reason(pr(2, labels=["batch:ui"], draft=True), NOW, own_checks=False),
                         "draft")

    def test_group_members_stay_out_of_the_ordinary_batch(self):
        eligible, skipped = nb.select([pr(1, labels=["batch:ui"]), pr(2)], NOW)
        self.assertEqual([item.number for item in eligible], [2])
        self.assertIn("group batch:ui", skipped[1])


class CheckUnion(unittest.TestCase):
    def test_each_ui_members_tour_is_in_the_combined_run(self):
        plan = groups.check_plan(ROOT, {1: [NEW_TAB], 2: [AGENT_PANE]})
        self.assertEqual(plan.tours, ["new-tab", "agent-pane"])
        self.assertEqual(plan.members[1]["tours"], ["new-tab"])
        self.assertEqual(plan.members[2]["tours"], ["agent-pane"])
        self.assertIn("swift", plan.cmux_tiers)
        self.assertIn("tour", plan.lanes())

    def test_a_web_member_adds_the_web_lane_and_docs_add_nothing(self):
        plan = groups.check_plan(ROOT, {1: [WEBVIEW], 2: [DOCS]})
        self.assertIn("react_apps", plan.web)
        self.assertEqual(plan.members[2]["web"], [])
        self.assertEqual(plan.members[2]["tours"], [])
        self.assertIn("web", plan.lanes())
        self.assertEqual(groups.check_plan(ROOT, {2: [DOCS]}).lanes(), [])


def controller() -> nb.Controller:
    item = nb.Controller.__new__(nb.Controller)
    item.args = Namespace(repo="o/r", dry_run=False, no_land=False, land=True, keep_branches=False, prs="")
    item.gh = mock.Mock()
    item.writer = item.gh
    item.run_url = "https://example.test/run/1"
    item.batch_id = "local-1"
    item.validations = []
    item.base_sha = "b" * 40
    item.base_failures = None
    item.base_probe = None
    item.base_probe_result = {}
    item.base_probe_stop = threading.Event()
    item.local = True
    item.worktree = Path("/nonexistent")
    item.started = 0
    return item


class GroupLanes(unittest.TestCase):
    def validation(self, prs) -> nb.Validation:
        return nb.Validation(name="group ui", stack=nb.Stack(base="b" * 40, head="c" * 40, included=list(prs)),
                             build={"ok": True})

    def test_a_failed_tour_or_web_run_makes_the_group_red(self):
        item = controller()
        validation = self.validation([pr(1)])
        validation.lanes = {"web": "passed", "tour": "failed: recorder-failed"}
        self.assertFalse(validation.green)
        self.assertTrue(validation.lane_failed)
        validation.lanes = {"web": "passed", "tour": "did not run: no owned gui runner"}
        self.assertFalse(validation.green)
        self.assertFalse(validation.lane_failed)  # infrastructure: nobody is blamed
        validation.lanes = {"web": "passed", "tour": "passed"}
        self.assertTrue(validation.green)
        del item

    def test_a_tour_is_judged_by_its_capture_receipt(self):
        item = controller()
        self.assertEqual(item.judge_tour({"conclusion": "success"}, {"status": "ok"}, "success"), "passed")
        self.assertEqual(item.judge_tour({"conclusion": "success"}, {"status": "no-ui-paths"}, "success"), "passed")
        self.assertTrue(item.judge_tour({"conclusion": "success"}, {"status": "recorder-failed"}, "success")
                        .startswith("failed"))
        self.assertTrue(item.judge_tour({"conclusion": "success"}, None, "success").startswith("failed"))
        self.assertTrue(item.judge_tour({"conclusion": "success"}, None, "skipped").startswith("did not run"))
        self.assertTrue(item.judge_tour({"conclusion": "failure"}, {"status": "ok"}, "failure").startswith("failed"))


class GroupBisectAndLand(unittest.TestCase):
    def run_group(self, members, red_member, reviewed=True, base_moved=False, dry_run=False):
        item = controller()
        item.args.dry_run = dry_run
        comments, merges = [], []
        item.comment_once = lambda target, kind, body: comments.append((target.number, kind))
        item.report_drop = lambda target, blocking: None
        item.group_reviews = lambda prs: {target.number: reviewed for target in prs}
        item.cleanup = lambda: None

        def validate(prs, name, group=None):
            validation = nb.Validation(name=name, stack=nb.Stack(base=item.base_sha, head="c" * 40, included=list(prs)),
                                       build={"ok": True}, branch=f"next-batch/local-1-{len(item.validations) + 1}")
            if any(target.number == red_member for target in prs):
                validation.heavy_failed = ["cmux-next swift test: test broken()"]
            item.validations.append(validation)
            return validation

        item.validate = validate
        item.current_base = lambda: ("d" * 40 if base_moved else item.base_sha)
        item.base_moved_onto = lambda old, new, files: base_moved
        item.fresh_members = lambda prs: {target.number: target for target in prs}

        def fake_run(command, **_):
            merges.append(command)
            return subprocess.CompletedProcess(command, 0, "", "")

        with mock.patch.object(nb.subprocess, "run", fake_run):
            outcome = item.run_group("ui", members)
        return outcome, comments, merges

    def test_a_green_reviewed_group_merges_in_order_without_its_own_ci(self):
        outcome, comments, merges = self.run_group([pr(1), pr(2), pr(3)], red_member=None)
        self.assertEqual([command[3] for command in merges], ["1", "2", "3"])
        for command in merges:
            self.assertEqual(command[:3], ["gh", "pr", "merge"])
            self.assertIn("--squash", command)
            self.assertIn("--match-head-commit", command)
            self.assertNotIn("--admin", command)
        self.assertEqual([text for _, text in outcome], ["landed", "landed", "landed"])

    def test_a_red_group_bisects_names_the_culprit_and_lands_the_rest(self):
        outcome, comments, merges = self.run_group([pr(1), pr(2), pr(3), pr(4)], red_member=3)
        self.assertIn((3, "culprit"), comments)
        self.assertEqual([command[3] for command in merges], ["1", "2", "4"])
        self.assertEqual(dict((target.number, text) for target, text in outcome)[3], "culprit")

    def test_an_unreviewed_group_validates_nothing_and_merges_nothing(self):
        outcome, comments, merges = self.run_group([pr(1), pr(2)], red_member=None, reviewed=False)
        self.assertEqual(merges, [])
        self.assertTrue(all(text.startswith("waiting: no review pass") for _, text in outcome))

    def test_a_base_change_to_the_groups_files_lands_nothing(self):
        outcome, comments, merges = self.run_group([pr(1), pr(2)], red_member=None, base_moved=True)
        self.assertEqual(merges, [])
        self.assertTrue(all("revalidate" in text for _, text in outcome))

    def test_a_dry_run_merges_nothing(self):
        outcome, comments, merges = self.run_group([pr(1), pr(2)], red_member=None, dry_run=True)
        self.assertEqual(merges, [])
        self.assertTrue(all(text == "validated; landing disabled for this run" for _, text in outcome))

if __name__ == "__main__":
    unittest.main()
