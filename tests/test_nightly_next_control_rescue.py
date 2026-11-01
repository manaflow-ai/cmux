from __future__ import annotations

import sys
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from scripts.ci import nightly_next_control_rescue as rescue


def event(*, path: str, event: str = "schedule", attempt: int = 1) -> dict:
    return {"workflow_run": {"id": 42, "path": path, "event": event, "run_attempt": attempt,
                              "head_repository": {"full_name": "manaflow-ai/cmux"}}}


class ControlRescueTests(unittest.TestCase):
    def test_control_target_accepts_only_own_first_attempt(self):
        self.assertIsNotNone(rescue.control_target(event(path=next(iter(rescue.CONTROL_PATHS))), "manaflow-ai/cmux"))
        self.assertIsNone(rescue.control_target(event(path=".github/workflows/ci.yml"), "manaflow-ai/cmux"))
        self.assertIsNone(rescue.control_target(event(path=next(iter(rescue.CONTROL_PATHS)), attempt=2), "manaflow-ai/cmux"))
        self.assertIsNone(rescue.control_target(event(path=next(iter(rescue.CONTROL_PATHS))), "someone/cmux"))

    def test_started_control_is_never_rescued(self):
        jobs = [{"name": "admit", "status": "in_progress", "runner_name": "fleet-1"}]
        self.assertTrue(rescue.control_started(jobs))
        api = mock.Mock()
        api.jobs.return_value = jobs
        self.assertEqual(rescue.rescue_control(api, event(path=next(iter(rescue.CONTROL_PATHS)))['workflow_run'],
                                               sleep=lambda _: None, clock=lambda: 0.0), "started")
        api.cancel.assert_not_called()

    def test_queued_runner_id_zero_is_not_execution_proof(self):
        self.assertFalse(rescue.control_started([
            {"name": "request", "status": "queued", "runner_id": 0, "runner_name": None},
        ]))
        self.assertTrue(rescue.control_started([
            {"name": "request", "status": "completed", "conclusion": "success", "runner_id": 0,
             "started_at": "2026-11-01T00:00:00Z"},
        ]))

    def test_unstarted_control_is_cancelled_and_retried_after_settlement(self):
        api = mock.Mock()
        api.jobs.return_value = []
        api.request.side_effect = [
            {"path": next(iter(rescue.CONTROL_PATHS)), "run_attempt": 1, "status": "in_progress"},
            {"status": "completed"},
        ]
        with mock.patch.object(rescue, "WAIT_SECONDS", 0):
            result = rescue.rescue_control(api, event(path=next(iter(rescue.CONTROL_PATHS)))['workflow_run'],
                                           sleep=lambda _: None, clock=lambda: 0.0)
        self.assertEqual(result, "rerun")
        api.cancel.assert_called_once_with(42)
        api.rerun.assert_called_once_with(42)

    def test_changed_attempt_is_not_cancelled(self):
        api = mock.Mock()
        api.jobs.return_value = []
        api.request.return_value = {"path": next(iter(rescue.CONTROL_PATHS)), "run_attempt": 2,
                                    "status": "in_progress"}
        with mock.patch.object(rescue, "WAIT_SECONDS", 0):
            result = rescue.rescue_control(api, event(path=next(iter(rescue.CONTROL_PATHS)))['workflow_run'],
                                           sleep=lambda _: None, clock=lambda: 0.0)
        self.assertEqual(result, "changed")
        api.cancel.assert_not_called()

    def test_unreadable_final_jobs_are_left_for_the_next_rescue(self):
        api = mock.Mock()
        api.jobs.side_effect = RuntimeError("temporary API outage")
        with mock.patch.object(rescue, "WAIT_SECONDS", 0):
            result = rescue.rescue_control(api, event(path=next(iter(rescue.CONTROL_PATHS)))['workflow_run'],
                                           sleep=lambda _: None, clock=lambda: 0.0)
        self.assertEqual(result, "unreadable")
        api.cancel.assert_not_called()


if __name__ == "__main__":
    unittest.main()
