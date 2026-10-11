#!/usr/bin/env python3
"""Retry policy for failed cmux-tui artifacts runs.

A run cannot rerun itself while it is in progress (GitHub answers 403 "This
workflow is already running"), so a separate workflow_run workflow reruns the
failed jobs of a completed run. It never retries an immutable R2 conflict: a
rebuild is not byte-identical, so a retry cannot succeed and only hides the
real failure.
"""
from __future__ import annotations

import importlib.util
from pathlib import Path
import sys
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/ci/cmux_tui_artifacts_retry.py"
spec = importlib.util.spec_from_file_location("retry", SCRIPT)
retry = importlib.util.module_from_spec(spec)
sys.modules["retry"] = retry  # dataclasses resolve their module through sys.modules
spec.loader.exec_module(retry)


def run(**overrides):
    value = {"id": 1, "status": "completed", "conclusion": "failure", "run_attempt": 1}
    value.update(overrides)
    return value


def job(job_id, conclusion):
    return {"id": job_id, "name": f"job {job_id}", "conclusion": conclusion}


class RetryPolicyTests(unittest.TestCase):
    def test_failed_run_reruns_failed_jobs(self):
        decision = retry.decide(run(), [job(1, "success"), job(2, "failure")], {2: []})
        self.assertEqual(decision.action, "rerun-failed-jobs")

    def test_immutable_conflict_is_never_retried(self):
        annotations = {2: [{"title": "immutable-r2-conflict", "message": "manifest.json differs"}]}
        decision = retry.decide(run(), [job(2, "failure"), job(3, "failure")], {**annotations, 3: []})
        self.assertEqual(decision.action, "refuse")
        self.assertIn("immutable", decision.reason)
        self.assertIn("job 2", decision.reason)

    def test_attempt_cap(self):
        self.assertEqual(retry.decide(run(run_attempt=3), [job(2, "failure")], {2: []}).action, "skip")

    def test_only_completed_failures(self):
        for overrides in ({"conclusion": "success"}, {"conclusion": "cancelled"}, {"status": "in_progress", "conclusion": None}):
            with self.subTest(overrides=overrides):
                self.assertEqual(retry.decide(run(**overrides), [job(2, "failure")], {2: []}).action, "skip")

    def test_failure_without_a_failed_job_is_not_retried(self):
        self.assertEqual(retry.decide(run(), [job(1, "success")], {}).action, "skip")


if __name__ == "__main__":
    unittest.main(verbosity=2)
