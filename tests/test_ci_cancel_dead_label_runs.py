#!/usr/bin/env python3
"""Policy tests for scripts/ci/cancel_dead_label_runs.py over fixture JSON (no network)."""

from __future__ import annotations

import datetime as dt
import re
import sys
import unittest
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/cancel_dead_label_runs.py"
WORKFLOW = ROOT / ".github/workflows/ci-cancel-dead-label-runs.yml"
# Imported by name, never loaded by path: one module object per file (tests/test_script_module_loads.py).
if str(SCRIPT.parent) not in sys.path:
    sys.path.insert(0, str(SCRIPT.parent))
import cancel_dead_label_runs as cdl  # noqa: E402

NOW = dt.datetime(2026, 11, 20, 3, 0, tzinfo=dt.timezone.utc)
DEAD = re.compile(cdl.DEFAULT_DEAD_LABELS)
NO_BASE = {"main": set(), "feat-cmux-next": set()}


def iso(minutes_ago: float) -> str:
    return (NOW - dt.timedelta(minutes=minutes_ago)).strftime("%Y-%m-%dT%H:%M:%SZ")


def run(*, name="CI", path=".github/workflows/ci.yml", branch="feature", sha="aaa", event="pull_request",
        status="queued", age=120):
    return {"id": 1, "name": name, "path": path, "head_branch": branch, "head_sha": sha, "event": event,
            "status": status, "created_at": iso(age), "display_title": "t"}


def job(label="ubuntu-latest", status="queued", age=90):
    return {"status": status, "labels": [label], "created_at": iso(age)}


class DecideTests(unittest.TestCase):
    def verdict(self, r, jobs, base=NO_BASE):
        return cdl.decide(r, jobs, base, NOW, DEAD, 61)[0]

    def test_dead_label_patterns(self):
        for label in ("ubuntu-latest", "ubuntu-24.04", "blacksmith-8vcpu-ubuntu-2404",
                      "blacksmith-16vcpu-ubuntu-2204", "blacksmith-32vcpu-ubuntu-2404-arm"):
            self.assertTrue(DEAD.match(label), label)
        for label in ("blacksmith-2vcpu-ubuntu-2404", "blacksmith-4vcpu-ubuntu-2404", "cmux-gcp-lane-build-x64",
                      "self-hosted", "macos-15", "blacksmith-6vcpu-macos-15"):
            self.assertFalse(DEAD.match(label), label)

    def test_old_dead_queued_job_is_cancelled_with_detail(self):
        why, detail = cdl.decide(run(), [job(age=90), job("blacksmith-4vcpu-ubuntu-2404", age=200)],
                                 NO_BASE, NOW, DEAD, 61)
        self.assertEqual(why, "cancel")
        self.assertEqual(detail["labels"], ["ubuntu-latest"])
        self.assertEqual(detail["queued_minutes"], 90)

    def test_young_dead_job_is_kept(self):
        self.assertEqual(self.verdict(run(), [job(age=60)]), "keep:too-young")

    def test_live_labels_only_are_kept(self):
        self.assertEqual(self.verdict(run(), [job("blacksmith-4vcpu-ubuntu-2404", age=300)]),
                         "keep:no-dead-queued-job")

    def test_any_in_progress_job_keeps_the_run(self):
        self.assertEqual(self.verdict(run(), [job(age=300), job("cmux-gcp-lane-build-x64", "in_progress")]),
                         "keep:job-in-progress")

    def test_delivery_runs_are_kept(self):
        for r in (run(name="cmux NEXT nightly", path=".github/workflows/nightly-next.yml", event="schedule"),
                  run(name="Promote", path=".github/workflows/promote.yml", event="workflow_dispatch"),
                  run(name="Release", path=".github/workflows/release.yml", event="push"),
                  run(name="Sign and notarize", path=".github/workflows/x.yml"),
                  run(name="Publish docs", path=".github/workflows/docs.yml"),
                  run(name="cmux NEXT DEV daily · x", path=".github/workflows/cmux-next-dev-daily.yml",
                      event="schedule")):
            self.assertTrue(self.verdict(r, [job(age=300)]).startswith("keep:"), r["name"])

    def test_newest_base_head_is_kept_and_older_base_head_is_not(self):
        runs = [run(branch="main", sha="old", age=500), run(branch="main", sha="new", age=100)]
        base = cdl.newest_base_heads(runs, {"main": "tip", "feat-cmux-next": ""})
        self.assertEqual(base["main"], {"tip", "new"})
        self.assertEqual(self.verdict(run(branch="main", sha="new"), [job(age=300)], base),
                         "keep:newest-base-head")
        self.assertEqual(self.verdict(run(branch="main", sha="tip"), [job(age=300)], base),
                         "keep:newest-base-head")
        self.assertEqual(self.verdict(run(branch="main", sha="old"), [job(age=300)], base), "cancel")

    def test_non_queued_run_is_kept(self):
        self.assertEqual(self.verdict(run(status="in_progress"), [job(age=300)]), "keep:status-in_progress")


class WindowTests(unittest.TestCase):
    def test_windows_split_until_each_fits_the_cap(self):
        start = NOW - dt.timedelta(hours=8)
        created = [start + dt.timedelta(seconds=7 * i) for i in range(3500)]

        def total(lo, hi):
            return sum(lo <= c <= hi for c in created)

        out = cdl.windows(start, NOW, total)
        self.assertTrue(all(total(lo, hi) <= cdl.LIST_CAP for lo, hi in out))
        self.assertEqual(sum(total(lo, hi) for lo, hi in out), len(created))


class WorkflowTests(unittest.TestCase):
    def test_workflow_shape(self):
        doc = yaml.safe_load(WORKFLOW.read_text())
        on = doc.get("on", doc.get(True))
        self.assertEqual(on["schedule"], [{"cron": "*/15 * * * *"}])
        inputs = on["workflow_dispatch"]["inputs"]
        self.assertEqual(str(inputs["dry_run"]["default"]).lower(), "false")
        self.assertEqual(str(inputs["max_cancels"]["default"]), "3000")
        self.assertFalse(doc["concurrency"]["cancel-in-progress"])
        (only,) = doc["jobs"].values()
        self.assertEqual(only["permissions"], {"actions": "write", "contents": "read"})
        runs_on = str(only["runs-on"])
        self.assertNotIn("blacksmith", runs_on)
        self.assertNotIn("ubuntu-", runs_on)
        self.assertNotIn("macos", runs_on)


if __name__ == "__main__":
    unittest.main()
