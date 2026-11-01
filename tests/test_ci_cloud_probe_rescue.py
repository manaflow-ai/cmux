import datetime as dt
import unittest
from unittest import mock

from scripts.ci import cloud_probe_rescue as r


NOW = dt.datetime(2026, 11, 1, tzinfo=dt.timezone.utc)


def run(attempt=1):
    return {"id": 9, "path": r.WORKFLOW_PATH, "run_attempt": attempt,
            "status": "in_progress", "created_at": (NOW - dt.timedelta(minutes=10)).isoformat()}


def watch(status="queued", age=180, runner=None):
    return {"name": r.WATCH_JOB, "status": status,
            "created_at": (NOW - dt.timedelta(seconds=age)).isoformat(),
            "runner_name": runner}


class DecisionTests(unittest.TestCase):
    def test_exact_queued_unassigned_watch_selects_next_label(self):
        self.assertEqual(r.decide(run(), [watch()], now=NOW).next_label, r.WATCH_LABELS[1])

    def test_started_or_other_workflow_is_never_rescued(self):
        for item in (watch("in_progress"), watch(runner="runner-1")):
            self.assertEqual(r.decide(run(), [item], now=NOW).action, "noop")
        other = {**run(), "path": ".github/workflows/nightly.yml"}
        self.assertEqual(r.decide(other, [watch()], now=NOW).action, "noop")

    def test_attempt_three_and_short_queue_are_left_alone(self):
        self.assertEqual(r.decide(run(3), [watch()], now=NOW).action, "noop")
        self.assertEqual(r.decide(run(), [watch(age=179)], now=NOW).action, "noop")


class RescueTests(unittest.TestCase):
    def test_cancel_settle_reruns_and_returns_next_label(self):
        api = mock.Mock()
        api.jobs.side_effect = [[watch()], [watch()]]
        api.run.side_effect = [run(), run(), {"status": "cancelled", "run_attempt": 1, "path": r.WORKFLOW_PATH}]
        decision = r.rescue_control(api, run(), now=lambda: NOW, sleep=lambda _: None)
        self.assertEqual(decision.next_label, r.WATCH_LABELS[1])
        api.cancel.assert_called_once_with(9)
        api.rerun.assert_called_once_with(9, 2)
        api.force_cancel.assert_not_called()

    def test_stale_event_cannot_cancel_a_new_attempt(self):
        api = mock.Mock()
        api.run.return_value = {**run(2), "status": "in_progress"}
        result = r.rescue_control(api, run(1), now=lambda: NOW, sleep=lambda _: None)
        self.assertEqual(result.action, "noop")
        api.cancel.assert_not_called()

    def test_assignment_race_is_rechecked_before_cancel(self):
        api = mock.Mock()
        api.run.return_value = run(1)
        api.jobs.return_value = [watch(runner="runner-1")]
        result = r.rescue_control(api, run(1), now=lambda: NOW, sleep=lambda _: None)
        self.assertEqual(result.action, "noop")
        api.cancel.assert_not_called()

    def test_cancel_timeout_does_not_rerun(self):
        api = mock.Mock()
        api.jobs.return_value = [watch()]
        api.run.return_value = {"status": "in_progress", "run_attempt": 1, "path": r.WORKFLOW_PATH}
        clock = iter([NOW, NOW, NOW, NOW + dt.timedelta(seconds=r.CANCEL_WAIT_SECONDS),
                      NOW + dt.timedelta(seconds=r.CANCEL_WAIT_SECONDS)])
        result = r.rescue_control(api, run(), now=lambda: next(clock), sleep=lambda _: None)
        self.assertEqual(result.action, "noop")
        api.rerun.assert_not_called()

    def test_a_new_attempt_appearing_while_cancel_settles_is_not_touched(self):
        api = mock.Mock()
        api.jobs.return_value = [watch()]
        api.run.side_effect = [
            {"status": "in_progress", "run_attempt": 1, "path": r.WORKFLOW_PATH},
            {"status": "in_progress", "run_attempt": 1, "path": r.WORKFLOW_PATH},
            {"status": "in_progress", "run_attempt": 2, "path": r.WORKFLOW_PATH},
        ]
        result = r.rescue_control(api, run(), now=lambda: NOW, sleep=lambda _: None)
        self.assertEqual(result.action, "noop")
        self.assertIn("changed while cancelling", result.reason)
        api.force_cancel.assert_not_called()
        api.rerun.assert_not_called()


if __name__ == "__main__":
    unittest.main()
