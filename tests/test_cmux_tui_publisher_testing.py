#!/usr/bin/env python3
"""A feat-cmux-next push waits for its tree's publisher to test it only while
that publisher's daemon-test job is on its way.

On 2026-10-21 nightly-next sat still from 01:44Z: tree 671c0a45's publisher
(run 39551025809) had its "cmux_next_ daemon tests (macOS)" job queued on the
pull request side label, and every later push of the key deferred to it, so
no tree got daemon-tests.json and no commit was promotable. Moving
CI_NEXT_DAEMON_POOL did not help: a queued job keeps its label.
"""

from __future__ import annotations

import datetime as dt
import importlib.util
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/cmux_tui_publisher_testing.py"
spec = importlib.util.spec_from_file_location("publisher_testing", SCRIPT)
publisher = importlib.util.module_from_spec(spec)
sys.modules["publisher_testing"] = publisher
spec.loader.exec_module(publisher)

NOW = dt.datetime(2026, 10, 21, 6, 30, tzinfo=dt.timezone.utc)
POOL = "glaeda-side-light-xcode-26.6"
GATE_RUNS_ON = "${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || 'blacksmith-32vcpu-ubuntu-2404' }}"


def job(status, conclusion=None, minutes_ago=1.0, labels=(POOL,), name=publisher.JOB_NAME):
    created = (NOW - dt.timedelta(minutes=minutes_ago)).strftime("%Y-%m-%dT%H:%M:%SZ")
    return {"name": name, "status": status, "conclusion": conclusion, "created_at": created, "labels": list(labels)}


def testing(jobs, pool=POOL, limit=20.0):
    return publisher.verdict(jobs, pool, limit, NOW)[0]


class VerdictTests(unittest.TestCase):
    def test_the_2026_10_21_stall_does_not_defer(self):
        # Queued since 05:43Z on the old side label.
        stale = job("queued", minutes_ago=47, labels=("glaeda-side-std-xcode-26.6",))
        self.assertFalse(testing([stale]))
        self.assertFalse(testing([job("queued", minutes_ago=2, labels=("glaeda-side-std-xcode-26.6",))]))

    def test_a_long_queue_on_the_current_pool_does_not_defer(self):
        self.assertFalse(testing([job("queued", minutes_ago=25)]))
        self.assertTrue(testing([job("queued", minutes_ago=5)]))

    def test_a_running_or_passed_job_defers(self):
        self.assertTrue(testing([job("in_progress", minutes_ago=90, labels=("other",))]))
        self.assertTrue(testing([job("completed", "success")]))

    def test_an_ended_job_without_success_does_not_defer(self):
        for conclusion in ("skipped", "cancelled", "failure", "timed_out"):
            with self.subTest(conclusion=conclusion):
                self.assertFalse(testing([job("completed", conclusion)]))

    def test_no_job_yet_defers(self):
        self.assertTrue(testing([job("in_progress", name="build / select binary targets")]))

    def test_no_pool_checks_only_the_wait(self):
        self.assertTrue(testing([job("queued", minutes_ago=5, labels=("anything",))], pool=""))

    def test_an_api_failure_tests_here(self):
        publisher_jobs = publisher.jobs
        publisher.jobs = lambda run_id: (_ for _ in ()).throw(OSError("down"))
        try:
            self.assertEqual(publisher.main(["--run-id", "1", "--pool", POOL]), 1)
        finally:
            publisher.jobs = publisher_jobs


class WiringTests(unittest.TestCase):
    WORKFLOW = (ROOT / ".github/workflows/cmux-tui-artifacts.yml").read_text()

    def test_both_deferrals_ask_the_script(self):
        self.assertIn('cmux_tui_publisher_testing.py --run-id "$source_run" --pool "${DAEMON_POOL:-}"', self.WORKFLOW)
        self.assertIn('cmux_tui_publisher_testing.py --run-id "$OWNER_RUN_ID" --pool "${DAEMON_POOL:-}"', self.WORKFLOW)
        self.assertEqual(self.WORKFLOW.count(f"DAEMON_POOL: {GATE_RUNS_ON}"), 2)

    def test_the_owner_wait_sparse_checkout_has_the_script(self):
        owner_wait = self.WORKFLOW[self.WORKFLOW.index("sparse-checkout: |\n            scripts/ci/cmux-tui-tree-claim.sh"):]
        self.assertIn("scripts/ci/cmux_tui_publisher_testing.py", owner_wait.split("- name:", 1)[0])

    def test_the_job_name_matches_the_daemon_test_job(self):
        # A renamed job reads as "not created yet", which defers forever.
        job = self.WORKFLOW[self.WORKFLOW.index("\n  cmux-next-daemon-tests:\n"):]
        job = job[:job.index("\n    runs-on:")]
        name = job[job.index("\n    name: ") + len("\n    name: "):].split("\n", 1)[0]
        self.assertEqual(name, publisher.JOB_NAME)
        self.assertTrue(publisher.is_daemon_job(name))

    def test_older_runs_suffixed_jobs_still_count_and_the_shadow_does_not(self):
        # Runs from before the runner suffix was dropped are still read.
        for suffix in ("macOS", "Linux"):
            self.assertTrue(publisher.is_daemon_job(f"cmux_next_ daemon tests ({suffix})"))
        self.assertTrue(testing([job("completed", "success", name="cmux_next_ daemon tests (macOS)")]))
        self.assertFalse(publisher.is_daemon_job("cmux_next_ macOS-only daemon tests (shadow)"))
        self.assertFalse(publisher.is_daemon_job(None))

    def test_the_pool_matches_the_daemon_test_job(self):
        # DAEMON_POOL names the gate job's own runs-on label.
        job = self.WORKFLOW[self.WORKFLOW.index("\n  cmux-next-daemon-tests:\n"):]
        runs_on = job[job.index("\n    runs-on: ") + len("\n    runs-on: "):].split("\n", 1)[0]
        self.assertEqual(runs_on, GATE_RUNS_ON)

if __name__ == "__main__":
    unittest.main(verbosity=2)
