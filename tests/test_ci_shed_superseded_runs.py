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
        for event in ("schedule", "workflow_dispatch", "merge_group", "workflow_run"):
            self.assertTrue(why(run(event=event)).startswith("keep:event-"), event)
        self.assertEqual(why(run(head_repository={"full_name": "someone/cmux"})), "keep:fork")
        self.assertEqual(why(run(head_repository=None)), "keep:fork")

    def test_protected_branches_are_kept(self):
        for branch in ("main", "master", "feat-cmux-next", "release/1.2", "nightly-next", "gh-pages", ""):
            self.assertEqual(why(run(head_branch=branch)), "keep:protected-branch", branch)

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
