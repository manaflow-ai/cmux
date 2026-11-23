#!/usr/bin/env python3
"""Policy tests for scripts/ci/shed_superseded_runs.py over fixture runs (no network)."""

from __future__ import annotations

import datetime as dt
import sys
import unittest
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/shed_superseded_runs.py"
WORKFLOW = ROOT / ".github/workflows/ci-shed-superseded-runs.yml"
if str(SCRIPT.parent) not in sys.path:
    sys.path.insert(0, str(SCRIPT.parent))
import shed_superseded_runs as shed  # noqa: E402

REPO = "manaflow-ai/cmux"
TIPS = {"feature": "tip", "feat-cmux-next": "base", "release/1.2": "rel"}
_ids = iter(range(1000, 100000))


def run(**over):
    base = {
        "id": next(_ids), "status": "queued", "run_attempt": 1, "event": "pull_request",
        "head_branch": "feature", "head_sha": "old", "name": "CI", "path": ".github/workflows/ci.yml",
        "created_at": "2026-11-19T20:00:00Z", "head_repository": {"full_name": REPO},
    }
    base.update(over)
    return base


def why(r):
    return shed.verdict(r, REPO, TIPS)


class VerdictTests(unittest.TestCase):
    def test_superseded_queued_run_is_shed(self):
        self.assertEqual(why(run()), "superseded")
        self.assertEqual(why(run(event="push")), "superseded")

    def test_gone_branch_is_shed(self):
        self.assertEqual(why(run(head_branch="deleted")), "branch-gone")

    def test_current_head_is_kept(self):
        self.assertEqual(why(run(head_sha="tip")), "keep:current-pull_request")
        self.assertEqual(why(run(event="push", head_sha="tip")), "keep:current-push")

    def test_in_progress_and_retries_are_kept(self):
        self.assertEqual(why(run(status="in_progress")), "keep:status-in_progress")
        self.assertEqual(why(run(run_attempt=2)), "keep:attempt")

    def test_other_events_and_forks_are_kept(self):
        for event in ("schedule", "workflow_dispatch", "merge_group", "issue_comment"):
            self.assertTrue(why(run(event=event)).startswith("keep:event-"), event)
        self.assertEqual(why(run(head_repository={"full_name": "someone/cmux"})), "keep:fork")
        self.assertEqual(why(run(head_repository=None)), "keep:fork")

    def test_protected_branches_are_kept(self):
        for branch in ("master", "release/1.2", "nightly-next", "gh-pages", ""):
            for event in ("push", "pull_request", "workflow_run"):
                self.assertEqual(why(run(head_branch=branch, event=event)), "keep:protected-branch", branch)

    def test_lane_workflow_run_of_a_replaced_head_is_shed(self):
        self.assertEqual(why(run(event="workflow_run")), "superseded")
        self.assertEqual(why(run(event="workflow_run", head_sha="tip")), "keep:current-workflow_run")
        self.assertEqual(why(run(event="workflow_run", head_branch="deleted")), "branch-gone")

    def test_base_push_runs_are_shed_only_when_a_newer_push_replaced_them(self):
        base = dict(head_branch="feat-cmux-next", event="push")
        self.assertEqual(why(run(**base)), "superseded-base")
        # The tip's own run is never touched: the newest head is always tested.
        self.assertEqual(why(run(**base, head_sha="base")), "keep:current-push")
        # Only push runs: any other base event answers one event, not one commit.
        for event in ("pull_request", "workflow_run", "schedule", "workflow_dispatch", "issue_comment"):
            self.assertEqual(why(run(head_branch="feat-cmux-next", event=event)), f"keep:event-{event}", event)
        # A base branch missing from the tips read is unread, never "gone".
        self.assertEqual(why(run(head_branch="main", event="push")), "keep:base-unread")
        self.assertEqual(why(run(**base, run_attempt=2)), "keep:attempt")
        self.assertEqual(why(run(**base, head_repository={"full_name": "someone/cmux"})), "keep:fork")

    def test_base_publishing_workflows_keep_every_push(self):
        base = dict(head_branch="feat-cmux-next", event="push")
        for path in shed.BASE_KEEP_PATHS:
            self.assertEqual(why(run(**base, path=path)), "keep:publishes-per-commit", path)
            # On a lane branch the same workflow is shed like any other.
            self.assertEqual(why(run(event="push", path=path)), "superseded", path)
        for name in ("Nightly NEXT", "Dev build", "Promote", "Release", "Publish"):
            self.assertEqual(why(run(**base, name=name)), "keep:protected-workflow", name)


def job(status="queued", **over):
    return {"status": status, "runner_id": None, "runner_name": None, "steps": [], **over}


class UnstartedTests(unittest.TestCase):
    def test_only_a_run_with_nothing_running_or_claimed_is_unstarted(self):
        self.assertTrue(shed.unstarted([job("completed"), job()]))
        self.assertTrue(shed.unstarted([job(), job()]))
        self.assertFalse(shed.unstarted([]))  # nothing read: not known to be unstarted
        self.assertFalse(shed.unstarted([job("completed")]))  # nothing left to stop
        self.assertFalse(shed.unstarted([job(), job("in_progress")]))
        self.assertFalse(shed.unstarted([job(runner_id=7)]))
        self.assertFalse(shed.unstarted([job(runner_name="r")]))
        self.assertFalse(shed.unstarted([job(steps=[{"name": "Set up job"}])]))
        self.assertFalse(shed.unstarted([job("waiting")]))

    def test_in_progress_run_is_shed_only_with_its_jobs_read_and_unstarted(self):
        r = run(status="in_progress")
        self.assertEqual(shed.verdict(r, REPO, TIPS), "keep:status-in_progress")
        self.assertEqual(shed.verdict(r, REPO, TIPS, {}), "keep:status-in_progress")
        self.assertEqual(shed.verdict(r, REPO, TIPS, {r["id"]: [job("completed"), job()]}), "superseded")
        self.assertEqual(shed.verdict(r, REPO, TIPS, {r["id"]: [job(), job("in_progress")]}), "keep:running")
        tip = run(status="in_progress", head_sha="tip")
        self.assertEqual(shed.verdict(tip, REPO, TIPS, {tip["id"]: [job()]}), "keep:current-pull_request")
        for status in ("completed", "waiting", "requested", "pending"):
            self.assertEqual(why(run(status=status)), f"keep:status-{status}", status)

    def test_needs_jobs_reads_only_in_progress_runs_it_would_shed_oldest_first_under_the_cap(self):
        a = run(status="in_progress", created_at="2026-11-19T20:03:00Z")
        b = run(status="in_progress", created_at="2026-11-19T20:01:00Z")
        c = run(status="in_progress", created_at="2026-11-19T20:02:00Z", head_branch="feat-cmux-next", event="push")
        kept = [run(status="in_progress", head_sha="tip"), run(), run(status="in_progress", name="Nightly NEXT"),
                run(status="in_progress", head_branch="feat-cmux-next", event="workflow_run")]
        got = shed.needs_jobs([a, b, c, a, *kept], REPO, TIPS, 300)
        self.assertEqual([r["id"] for r in got], [b["id"], c["id"], a["id"]])
        self.assertEqual([r["id"] for r in shed.needs_jobs([a, b, c], REPO, TIPS, 2)], [b["id"], c["id"]])
        self.assertEqual(shed.needs_jobs([a, b], REPO, TIPS, 0), [])
        self.assertEqual(shed.needs_jobs([a, b], REPO, TIPS, -1), [])

    def test_protected_workflows_are_kept(self):
        for name in ("Nightly NEXT", "Dev build", "Promote", "Release", "TestFlight", "App Store upload",
                     "Deploy web", "Publish", "Sign and notarize"):
            self.assertEqual(why(run(name=name)), "keep:protected-workflow", name)
        self.assertEqual(why(run(path=".github/workflows/nightly-next-tick.yml")), "keep:protected-workflow")
        self.assertEqual(why(run(name="Web validation")), "superseded")


class PlanTests(unittest.TestCase):
    def test_plan_caps_dedupes_and_orders_oldest_first(self):
        a = run(created_at="2026-11-19T20:03:00Z")
        b = run(created_at="2026-11-19T20:01:00Z")
        c = run(created_at="2026-11-19T20:02:00Z")
        keep = run(head_sha="tip")
        picks, counts = shed.plan([a, b, c, a, keep], REPO, TIPS, 2)
        self.assertEqual([r["id"] for r, _ in picks], [b["id"], c["id"]])
        self.assertEqual(counts, {"superseded": 3, "keep:current-pull_request": 1})

    def test_zero_cap_cancels_nothing(self):
        self.assertEqual(shed.plan([run()], REPO, TIPS, 0)[0], [])

    def test_plan_sheds_base_and_unstarted_runs_with_their_own_verdicts(self):
        base = run(head_branch="feat-cmux-next", event="push", created_at="2026-11-19T20:01:00Z")
        idle = run(status="in_progress", created_at="2026-11-19T20:02:00Z")
        busy = run(status="in_progress", created_at="2026-11-19T20:03:00Z")
        unread = run(status="in_progress", created_at="2026-11-19T20:04:00Z")
        jobs = {idle["id"]: [job()], busy["id"]: [job("in_progress")]}
        picks, counts = shed.plan([base, idle, busy, unread], REPO, TIPS, 10, jobs)
        self.assertEqual([(r["id"], w) for r, w in picks], [(base["id"], "superseded-base"), (idle["id"], "superseded")])
        self.assertEqual(counts, {"superseded-base": 1, "superseded": 1, "keep:running": 1,
                                  "keep:status-in_progress": 1})


class WindowTests(unittest.TestCase):
    def test_windows_split_until_under_cap_and_cover_range(self):
        start = dt.datetime(2026, 11, 19, tzinfo=dt.timezone.utc)
        end = start + dt.timedelta(hours=24)
        # 5,000 runs spread evenly over the day.
        density = 5000 / (end - start).total_seconds()

        def total(lo, hi):
            return int(((hi - lo).total_seconds() + 1) * density)

        parts = sorted(shed.windows(start, end, total))
        self.assertGreater(len(parts), 5)
        self.assertTrue(all(total(lo, hi) <= shed.LIST_CAP for lo, hi in parts))
        self.assertEqual(parts[0][0], start)
        self.assertEqual(parts[-1][1], end)
        for (_, hi), (lo, _) in zip(parts, parts[1:]):
            self.assertEqual(lo - hi, dt.timedelta(seconds=1))

    def test_small_range_is_one_window(self):
        start = dt.datetime(2026, 11, 19, tzinfo=dt.timezone.utc)
        self.assertEqual(shed.windows(start, start + dt.timedelta(hours=1), lambda lo, hi: 10),
                         [(start, start + dt.timedelta(hours=1))])

    def test_ls_remote_parse(self):
        text = "abc\trefs/heads/feature\ndef\trefs/heads/a/b\n123\trefs/tags/v1\n"
        self.assertEqual(shed.parse_ls_remote(text), {"feature": "abc", "a/b": "def"})


class WorkflowTests(unittest.TestCase):
    def setUp(self):
        self.doc = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
        self.job = self.doc["jobs"]["shed"]

    def test_scheduled_every_ten_minutes_and_dispatchable(self):
        on = self.doc.get("on", self.doc.get(True))
        self.assertEqual(on["schedule"], [{"cron": "*/10 * * * *"}])
        self.assertIn("workflow_dispatch", on)

    def test_runs_on_owned_label_never_blacksmith_or_hosted(self):
        runs_on = self.job["runs-on"]
        self.assertEqual(runs_on, "${{ vars.CI_CONTROL_RUNNER || 'cmux-gcp-nightly-x64' }}")
        for bad in ("blacksmith", "ubuntu-", "RUNNER_POOLS", "LINUX_RUNNER", "cmux-fleet-linux"):
            self.assertNotIn(bad, runs_on)

    def test_token_scope_and_serialized_sweeps(self):
        self.assertEqual(self.doc["permissions"], {})
        self.assertEqual(self.job["permissions"], {"actions": "write", "contents": "read"})
        self.assertEqual(self.doc["concurrency"]["cancel-in-progress"], False)


if __name__ == "__main__":
    unittest.main()
