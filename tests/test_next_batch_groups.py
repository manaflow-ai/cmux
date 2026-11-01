#!/usr/bin/env python3
"""Labeled PR groups in the batch queue: assembly, check union, bisect and landing."""
from __future__ import annotations

import datetime as dt
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
               pr(4), pr(5, labels=["batch:ui", "batch:infra"]),
               pr(6, labels=["batch:", "batch:ui"])]
        found = groups.assemble(prs)
        self.assertEqual({name: [item.number for item in members] for name, members in found.items()},
                         {"ui": [1, 2], "infra": [3]})
        self.assertEqual(groups.conflicting_groups(prs[4].labels), ["batch:infra", "batch:ui"])
        self.assertEqual(groups.conflicting_groups(prs[5].labels), ["batch:", "batch:ui"])

    def test_stack_order_wins_then_label_order_then_number(self):
        a, b, c, d = pr(10), pr(11), pr(12), pr(13)
        # 13 is stacked on 10 (its head contains 10's); 12 got the label first.
        ancestors = {(a.sha, d.sha)}
        labeled = {10: "2026-10-19T03:00:00Z", 11: "2026-10-19T02:00:00Z", 12: "2026-10-19T01:00:00Z",
                   13: "2026-10-19T00:00:00Z"}
        ordered = groups.order([a, b, c, d], labeled, lambda x, y: (x, y) in ancestors)
        self.assertEqual([item.number for item in ordered], [12, 11, 10, 13])
        self.assertEqual([item.number for item in groups.order([b, a], {}, lambda x, y: False)], [10, 11])

    def test_a_members_review_is_the_batch_queues_own_gate(self):
        item = controller()
        with mock.patch.object(nb, "reviewed", side_effect=lambda target, gh: target.number == 1) as gate:
            self.assertEqual(item.group_reviews([pr(1), pr(2)]), {1: True, 2: False})
        self.assertEqual(gate.call_count, 2)

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
        # A failed tour job (the base app's build, setup) blames nobody unless the recorder failed.
        self.assertTrue(item.judge_tour({"conclusion": "failure"}, None, "failure").startswith("did not run"))
        self.assertTrue(item.judge_tour({"conclusion": "failure"}, {"status": "recorder-failed"}, "failure")
                        .startswith("failed"))


class GroupWeb(unittest.TestCase):
    def test_web_is_compared_with_the_web_run_at_the_stacks_base(self):
        item = controller()
        item.gh.runs.return_value = [{"id": 2, "head_branch": nb.BASE, "status": "completed", "head_sha": "b" * 40}]
        item.failed_jobs = lambda run_id, detail=False: {1: ["web / react-apps-check: step Check"],
                                                       2: ["web / react-apps-check: step Check"]}[run_id]
        self.assertEqual(item.judge_web({"id": 1, "conclusion": "failure"}, "b" * 40), "passed")
        self.assertIn("head_sha=" + "b" * 40, item.gh.runs.call_args.args[1])
        item.failed_jobs = lambda run_id, detail=False: []
        self.assertTrue(item.judge_web({"id": 1, "conclusion": "startup_failure"}, "b" * 40).startswith("did not run"))


class GroupBisectAndLand(unittest.TestCase):
    def run_group(self, members, red_member, reviewed=True, base_moved=False, dry_run=False, frozen=(), refusal=None):
        item = controller()
        item.args.dry_run = dry_run
        item.frozen = lambda target: "frozen by #1" if target.number in frozen else ""
        unproven = getattr(self, "unproven", set())
        item.risk_evidence = lambda target: ("risk evidence has not passed on this head"
                                             if target.number in unproven else "")
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
        fresh = getattr(self, "fresh", None)
        item.fresh_members = lambda prs: fresh or {target.number: target for target in prs}
        item.member_files = lambda target, base: list(target.files)
        refusals = list(getattr(self, "refusals", []))

        def merge_one(target, validation):
            merges.append((target.number, target.sha))
            return refusals.pop(0) if refusals else "landed"

        item.merge_one = merge_one
        with mock.patch.object(nb, "now", return_value=NOW), \
                mock.patch.object(nb, "landing_refusal", return_value=refusal):
            outcome = item.run_group("ui", members)
        return outcome, comments, merges

    def test_a_green_reviewed_group_merges_in_order_at_the_validated_heads(self):
        outcome, comments, merges = self.run_group([pr(1), pr(2), pr(3)], red_member=None)
        # merge_one (Landing in test_next_batch) squash-merges each through GitHub's merge API at that head.
        self.assertEqual(merges, [(number, pr(number).sha) for number in (1, 2, 3)])
        self.assertEqual([text for _, text in outcome], ["landed", "landed", "landed"])

    def test_a_red_group_bisects_names_the_culprit_and_lands_the_rest(self):
        outcome, comments, merges = self.run_group([pr(1), pr(2), pr(3), pr(4)], red_member=3)
        self.assertIn((3, "culprit"), comments)
        self.assertEqual([number for number, _ in merges], [1, 2, 4])
        self.assertEqual(dict((target.number, text) for target, text in outcome)[3], "culprit")

    def test_an_unreviewed_group_validates_nothing_and_merges_nothing(self):
        outcome, comments, merges = self.run_group([pr(1), pr(2)], red_member=None, reviewed=False)
        self.assertEqual(merges, [])
        self.assertTrue(all(text.startswith("waiting: no review pass") for _, text in outcome))

    def test_a_base_change_to_the_groups_files_lands_nothing(self):
        outcome, comments, merges = self.run_group([pr(1), pr(2)], red_member=None, base_moved=True)
        self.assertEqual(merges, [])
        self.assertTrue(all("revalidate" in text for _, text in outcome))

    def test_a_member_without_passing_risk_evidence_holds_the_whole_group(self):
        """merge_one refuses a head whose risk evidence hasn't passed; checked for every
        member first, so the members before it never land alone."""
        self.unproven = {2}
        outcome, comments, merges = self.run_group([pr(1), pr(2)], red_member=None)
        self.assertEqual(merges, [])
        self.assertTrue(all("#2 risk evidence has not passed" in text for _, text in outcome))

    def test_a_frozen_member_holds_the_whole_group(self):
        outcome, comments, merges = self.run_group([pr(1), pr(2)], red_member=None, frozen={2})
        self.assertEqual(merges, [])
        self.assertTrue(all("frozen" in text for _, text in outcome))

    def test_a_host_that_must_not_land_merges_nothing(self):
        outcome, comments, merges = self.run_group([pr(1)], red_member=None, refusal="no exclude list")
        self.assertEqual(merges, [])
        self.assertIn("no exclude list", outcome[0][1])

    def test_a_base_branch_modified_refusal_is_retried(self):
        self.refusals = ["not landed: GitHub was unreachable or busy (HTTP 405: Base branch was modified)"]
        with mock.patch.object(nb.time, "sleep"):
            outcome, comments, merges = self.run_group([pr(1), pr(2)], red_member=None)
        self.assertEqual([text for _, text in outcome], ["landed", "landed"])
        self.assertEqual([number for number, _ in merges], [1, 1, 2])

    def test_a_member_github_refuses_stops_the_rest(self):
        self.refusals = ["not landed: GitHub refused to merge o/r#1: HTTP 409: Head branch was modified"]
        outcome, comments, merges = self.run_group([pr(1), pr(2)], red_member=None)
        self.assertEqual([number for number, _ in merges], [1])
        self.assertTrue(outcome[0][1].startswith("not landed: GitHub refused"))
        self.assertEqual(outcome[1][1], "not landed: #1 did not land")

    def test_a_check_that_turned_red_during_validation_lands_nothing(self):
        item_prs = [pr(1), pr(2)]
        self.fresh = {1: pr(1), 2: pr(2, checks=[("ci-status", "completed", "failure")])}
        outcome, comments, merges = self.run_group(item_prs, red_member=None)
        self.assertEqual(merges, [])
        self.assertTrue(all("#2 red check ci-status" in text for _, text in outcome))

    def test_a_dry_run_merges_nothing(self):
        outcome, comments, merges = self.run_group([pr(1), pr(2)], red_member=None, dry_run=True)
        self.assertEqual(merges, [])
        self.assertTrue(all(text == "validated; landing disabled for this run" for _, text in outcome))

class GroupCycle(unittest.TestCase):
    def setUp(self):
        nb.GROUP_TRIED.clear()

    def test_after_a_group_lands_the_cycle_stops_and_starts_fresh(self):
        item = controller()
        item.reported = lambda target, kinds: ""
        item.fetch = lambda prs: "b" * 40
        item.group_meta = lambda prs: {target.number: {"labeled": {}} for target in prs}
        item.is_ancestor = lambda a, b: False
        ran = []
        item.run_group = lambda name, members: ran.append(name) or [(members[0], "landed")]
        prs = [pr(1, labels=["batch:a"]), pr(2, labels=["batch:b"])]
        with mock.patch.object(nb, "now", return_value=NOW):
            outcome = item.run_groups(prs, None, {})
        self.assertEqual(ran, ["a"])  # b validates next cycle, on the base a landed on
        self.assertEqual([text for _, text in outcome], ["landed"])

    def test_the_same_heads_are_not_validated_again_within_the_hour(self):
        item = controller()
        item.reported = lambda target, kinds: ""
        item.fetch = lambda prs: "b" * 40
        item.group_meta = lambda prs: {target.number: {"labeled": {}} for target in prs}
        item.is_ancestor = lambda a, b: False
        ran = []
        item.run_group = lambda name, members: ran.append(name) or [(members[0], "not landed: lane did not run")]
        nb.GROUP_TRIED.clear()
        prs = [pr(1, labels=["batch:a"])]
        skipped = {}
        with mock.patch.object(nb, "now", return_value=NOW):
            item.run_groups(prs, None, {})
            item.run_groups(prs, None, skipped)
        self.assertEqual(ran, ["a"])
        self.assertIn("tried at these heads", skipped[1])

    def cycle(self, group_result, base_now):
        item = controller()
        item.base_sha = ""
        item.base_probe_result = {"branch": "next-batch/local-1-base", "run": 9}
        item.base_probe = mock.Mock(is_alive=lambda: True)
        item.reported = lambda target, kinds: ""
        item.current_base = lambda: base_now
        item.after_landing = lambda: None
        posted, deleted = [], []
        item.post_sticky = posted.append
        item.delete_branch = deleted.append

        def run_groups(prs, only, skipped):
            item.base_sha = "b" * 40
            item.validations.append(nb.Validation(name="group a", stack=nb.Stack(base="b" * 40, head="c" * 40),
                                                  branch="next-batch/local-1-1"))
            return [(pr(1), group_result)]

        item.run_groups = run_groups
        with mock.patch.object(nb, "open_prs", return_value=[]), \
                mock.patch.object(nb, "select", return_value=([pr(7)], {})), \
                mock.patch.object(nb, "admit_reviewed", return_value=([], {7: "waiting: no review"})), \
                mock.patch.object(nb, "write_summary"):
            item.run()
        return item, posted, deleted

    def test_a_cycle_with_nothing_reviewed_still_cleans_up_and_reports_the_groups(self):
        item, posted, deleted = self.cycle("not landed: lane did not run", "b" * 40)
        self.assertEqual(sorted(deleted), ["next-batch/local-1-1", "next-batch/local-1-base"])
        self.assertIn(("run", "cancel", "9"), [call.args[:3] for call in item.gh.gh.call_args_list])
        self.assertTrue(posted and "#1: not landed: lane did not run" in posted[0])

    def test_the_ordinary_batch_does_not_reuse_a_base_that_moved_during_the_groups(self):
        item, posted, deleted = self.cycle("not landed: lane did not run", "d" * 40)
        self.assertEqual(item.base_sha, "")
        self.assertIn("next-batch/local-1-base", deleted)

    def test_a_reset_keeps_the_old_probe_out_of_the_new_bases_result(self):
        item = controller()
        item.base_sha = "a" * 40
        item.base_tree_waited = True
        item.push = lambda sha, ref: None
        item.delete_branch = lambda ref: None
        item.find_run = lambda workflow, branch, match, since: {"id": 5, "html_url": "https://probe"}
        item.failed_jobs = lambda run_id, detail=False: ["cmux-next swift test: test cancelled()"]

        def wait_run(run_id, timeout):
            item.reset_base()  # feat-cmux-next moved while the old base's probe ran
            return {"status": "completed", "conclusion": "failure"}

        item.wait_run = wait_run
        with mock.patch.object(nb.time, "sleep"):
            item.start_base_probe()
            for thread in threading.enumerate():
                if thread.name == "base-probe":
                    thread.join(timeout=10)
        self.assertNotIn("failed", item.base_probe_result)
        self.assertFalse(item.base_tree_waited)

    def test_a_base_change_does_not_hold_the_group_for_the_hour(self):
        item = controller()
        item.reported = lambda target, kinds: ""
        item.fetch = lambda prs: "b" * 40
        item.group_meta = lambda prs: {target.number: {"labeled": {}} for target in prs}
        item.is_ancestor = lambda a, b: False
        ran = []
        moved = f"not landed: {nb.BASE} changed the group's files since validation; revalidate next cycle"
        item.run_group = lambda name, members: ran.append(name) or [(members[0], moved)]
        nb.GROUP_TRIED.clear()
        prs = [pr(1, labels=["batch:a"])]
        with mock.patch.object(nb, "now", return_value=NOW):
            item.run_groups(prs, None, {})
            item.run_groups(prs, None, {})
        self.assertEqual(ran, ["a", "a"])

    def test_a_member_with_its_own_red_check_holds_the_group(self):
        """A member red at landing would strand the members before it, so any red holds the group."""
        item = controller()
        item.reported = lambda target, kinds: ""
        ran = []
        item.run_group = lambda name, members: ran.append(name) or []
        prs = [pr(1, labels=["batch:a"]), pr(2, labels=["batch:a"], checks=[("ci-status", "completed", "failure")])]
        skipped = {}
        with mock.patch.object(nb, "now", return_value=NOW):
            item.run_groups(prs, None, skipped)
        self.assertEqual(ran, [])
        self.assertIn("#2 red check ci-status", skipped[1])
        # A red heavy job too: the group's bar is stricter than a single PR's.
        prs = [pr(1, labels=["batch:a"], checks=[("cmux-next swift test", "completed", "failure")]),
               pr(2, labels=["batch:a"])]
        skipped = {}
        with mock.patch.object(nb, "now", return_value=NOW):
            item.run_groups(prs, None, skipped)
        self.assertEqual(ran, [])
        self.assertIn("#1 red check cmux-next swift test", skipped[2])
        # A trusted `queue: known base red` doesn't let a member in either.
        trusted = pr(2, labels=["batch:a", nb.OVERRIDE_BASE_RED], checks=[("ci-status", "completed", "failure")],
                     label_actors={nb.OVERRIDE_BASE_RED: "lawrencecchen"})
        skipped = {}
        with mock.patch.object(nb, "now", return_value=NOW):
            item.run_groups([pr(1, labels=["batch:a"]), trusted], None, skipped)
        self.assertEqual(ran, [])
        self.assertIn("#2 red check ci-status", skipped[1])

    def test_a_failed_run_a_later_run_of_the_same_check_passed_does_not_hold_the_group(self):
        """The hold reads each check's newest run: a rerun that passed, or a cancelled
        run another run of the same check on the head passed, holds nothing."""
        def run(name, status, conclusion, started, completed=""):
            return {"__typename": "CheckRun", "name": name, "status": status, "conclusion": conclusion,
                    "startedAt": started, "completedAt": completed or started}

        rollup = [
            run("ci-status", "COMPLETED", "FAILURE", "2026-10-06T01:00:00Z"),
            run("ci-status", "COMPLETED", "SUCCESS", "2026-10-06T02:00:00Z"),  # the rerun passed
            run("build / release-compile", "COMPLETED", "SUCCESS", "2026-10-06T01:00:00Z", "2026-10-06T01:30:00Z"),
            # A newer run of the same check, cancelled after the pass started (a superseded run).
            run("build / release-compile", "COMPLETED", "CANCELLED", "2026-10-06T01:10:00Z", "2026-10-06T01:31:00Z"),
            run("lint", "COMPLETED", "SUCCESS", "2026-10-06T01:00:00Z"),
            run("lint", "COMPLETED", "FAILURE", "2026-10-06T03:00:00Z"),  # the newest run failed: still red
            run("docs", "COMPLETED", "CANCELLED", "2026-10-06T01:00:00Z"),  # cancelled with no pass: still red
        ]
        checks = nb.newest_checks(nb.parse_contexts(rollup))
        self.assertEqual(sorted(checks), [("build / release-compile", "completed", "success"),
                                          ("ci-status", "completed", "success"),
                                          ("docs", "completed", "cancelled"),
                                          ("lint", "completed", "failure")])
        self.assertEqual(nb.group_hold(pr(1, checks=checks)), "red check docs, lint")
        clean = [item for item in rollup if item["name"] in {"ci-status", "build / release-compile"}]
        self.assertIsNone(nb.group_hold(pr(1, checks=nb.newest_checks(nb.parse_contexts(clean)))))

    def test_newest_run_edge_cases(self):
        def run(name, conclusion, started, workflow="ci", status="COMPLETED"):
            return {"__typename": "CheckRun", "name": name, "status": status, "conclusion": conclusion,
                    "startedAt": started, "checkSuite": {"workflowRun": {"workflow": {"name": workflow}}}}

        # A cancelled newest run gives way to the newest run that finished, not to an older pass.
        between = [run("lint", "SUCCESS", "2026-10-06T01:00:00Z"), run("lint", "FAILURE", "2026-10-06T02:00:00Z"),
                   run("lint", "CANCELLED", "2026-10-06T03:00:00Z")]
        self.assertEqual(nb.newest_checks(nb.parse_contexts(between)), [("lint", "completed", "failure")])
        # Same job name in two workflows: two checks, so one's pass never hides the other's red.
        twins = [run("build", "FAILURE", "2026-10-06T01:00:00Z", workflow="a"),
                 run("build", "SUCCESS", "2026-10-06T02:00:00Z", workflow="b")]
        self.assertEqual(sorted(nb.newest_checks(nb.parse_contexts(twins))),
                         [("build", "completed", "failure"), ("build", "completed", "success")])
        # A skipped newest run (a label event the workflow skips, cmux#29747) gives way to the red before it.
        relabeled = [run("check", "FAILURE", "2026-10-06T01:00:00Z", workflow="cmux VM"),
                     run("check", "SKIPPED", "2026-10-06T02:00:00Z", workflow="cmux VM")]
        checks = nb.newest_checks(nb.parse_contexts(relabeled))
        self.assertEqual(checks, [("check", "completed", "failure")])
        self.assertEqual(nb.red_fast_checks(pr(1, checks=checks)), ["check"])
        # Skipped with no other run: the skip stands.
        self.assertEqual(nb.newest_checks(nb.parse_contexts(relabeled[1:])), [("check", "completed", "skipped")])
        # A queued rerun (no start time yet) is the newest run.
        queued = [run("lint", "FAILURE", "2026-10-06T01:00:00Z"), run("lint", None, None, status="QUEUED")]
        self.assertEqual(nb.newest_checks(nb.parse_contexts(queued)), [("lint", "queued", "")])

    def test_open_prs_keep_only_each_checks_newest_run(self):
        """End to end through the details query: a superseded red never reaches a PR's checks."""
        def run(conclusion, started):
            return {"__typename": "CheckRun", "name": "ci-status", "status": "COMPLETED", "conclusion": conclusion,
                    "startedAt": started, "completedAt": started}

        gh = mock.Mock()
        gh.graphql.return_value = {"p0": {"commits": {"nodes": [{"commit": {"statusCheckRollup": {"contexts": {
            "pageInfo": {"hasNextPage": False},
            "nodes": [run("SUCCESS", "2026-10-06T02:00:00Z"), run("CANCELLED", "2026-10-06T01:00:00Z")]}}}}]}}}
        found = nb.fetch_details(gh, [("PR_1", False, True)])
        self.assertEqual(found["PR_1"][1], [("ci-status", "completed", "success")])
        self.assertIn("startedAt", gh.graphql.call_args.args[0])

    def test_lanes_use_each_members_full_diff(self):
        item = controller()
        item.git = mock.Mock(return_value="\n".join(f"webviews/src/f{index}.ts" for index in range(150)))
        self.assertEqual(len(item.member_files(pr(1), "b" * 40)), 150)
        self.assertIn("b" * 40 + "..." + pr(1).sha, item.git.call_args.args)


if __name__ == "__main__":
    unittest.main()
