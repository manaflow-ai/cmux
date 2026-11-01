import datetime as dt
import base64
import unittest
from unittest import mock

from scripts.ci import cloud_probe_rescue as r


NOW = dt.datetime(2026, 11, 1, tzinfo=dt.timezone.utc)


def run(attempt=1):
    return {"id": 9, "path": r.WORKFLOW_PATH, "run_attempt": attempt,
            "status": "in_progress", "head_sha": "a" * 40,
            "head_branch": "main", "head_repository": {"full_name": r.TRUSTED_REPOSITORY},
            "created_at": (NOW - dt.timedelta(minutes=10)).isoformat()}


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

    def test_rerun_without_current_attempt_time_fails_closed(self):
        rerun = {**run(2), "created_at": (NOW - dt.timedelta(hours=1)).isoformat(),
                 "run_started_at": (NOW - dt.timedelta(seconds=60)).isoformat()}
        job = {"name": r.WATCH_JOB, "status": "queued", "runner_name": None}
        self.assertEqual(r.decide(rerun, [job], now=NOW).action, "noop")

        old_rerun = {**rerun, "run_started_at": (NOW - dt.timedelta(seconds=181)).isoformat()}
        self.assertEqual(r.decide(old_rerun, [job], now=NOW).action, "rescue")

    def test_untrusted_head_is_never_rescued(self):
        fork = {**run(), "head_repository": {"full_name": "someone/fork"}}
        self.assertEqual(r.decide(fork, [watch()], now=NOW).action, "noop")


class RescueTests(unittest.TestCase):
    @staticmethod
    def mark(api):
        source = ("jobs:\n  watch:\n    runs-on: ${{ github.run_attempt == 1 && '" + r.WATCH_LABELS[0]
                  + "' || github.run_attempt == 2 && '" + r.WATCH_LABELS[1]
                  + "' || '" + r.WATCH_LABELS[2] + "' }}")
        api.request.return_value = {"content": base64.b64encode(source.encode()).decode()}

    def test_candidate_scan_filters_to_inflight_cloud_probe_runs(self):
        api = mock.Mock()
        self.mark(api)
        api.request.return_value = {"workflow_runs": [
            {"id": 1, "path": r.WORKFLOW_PATH, "status": "queued", "head_branch": "main",
             "head_repository": {"full_name": r.TRUSTED_REPOSITORY}},
            {"id": 2, "path": ".github/workflows/nightly.yml", "status": "queued", "head_branch": "main",
             "head_repository": {"full_name": r.TRUSTED_REPOSITORY}},
            {"id": 3, "path": r.WORKFLOW_PATH, "status": "completed", "head_branch": "main",
             "head_repository": {"full_name": r.TRUSTED_REPOSITORY}},
        ]}
        self.assertEqual([run["id"] for run in r.candidate_runs(api)], [1])

    def test_legacy_marker_in_comment_does_not_enable_reroute(self):
        api = mock.Mock()
        source = "# github.run_attempt " + " ".join(r.WATCH_LABELS)
        api.request.return_value = {"content": base64.b64encode(source.encode()).decode()}
        self.assertFalse(r.workflow_supports_reroute(api, run()))

    def test_cancel_settle_reruns_and_returns_next_label(self):
        api = mock.Mock()
        self.mark(api)
        api.jobs.side_effect = [[watch()], [watch()]]
        api.run.side_effect = [run(), run(), {"status": "cancelled", "run_attempt": 1, "path": r.WORKFLOW_PATH}]
        decision = r.rescue_control(api, run(), now=lambda: NOW, sleep=lambda _: None)
        self.assertEqual(decision.next_label, r.WATCH_LABELS[1])
        api.cancel.assert_called_once_with(9)
        api.rerun.assert_called_once_with(9, 2)
        api.force_cancel.assert_not_called()

    def test_stale_event_cannot_cancel_a_new_attempt(self):
        api = mock.Mock()
        self.mark(api)
        api.run.return_value = {**run(2), "status": "in_progress"}
        result = r.rescue_control(api, run(1), now=lambda: NOW, sleep=lambda _: None)
        self.assertEqual(result.action, "noop")
        api.cancel.assert_not_called()

    def test_assignment_race_is_rechecked_before_cancel(self):
        api = mock.Mock()
        self.mark(api)
        api.run.return_value = run(1)
        api.jobs.return_value = [watch(runner="runner-1")]
        result = r.rescue_control(api, run(1), now=lambda: NOW, sleep=lambda _: None)
        self.assertEqual(result.action, "noop")
        api.cancel.assert_not_called()

    def test_cancel_timeout_does_not_rerun(self):
        api = mock.Mock()
        self.mark(api)
        api.jobs.return_value = [watch()]
        api.run.return_value = {"status": "in_progress", "run_attempt": 1,
                                "path": r.WORKFLOW_PATH, "head_sha": "a" * 40,
                                "head_branch": "main",
                                "head_repository": {"full_name": r.TRUSTED_REPOSITORY}}
        clock = iter([NOW, NOW, NOW, NOW + dt.timedelta(seconds=r.CANCEL_WAIT_SECONDS),
                      NOW + dt.timedelta(seconds=r.CANCEL_WAIT_SECONDS)])
        result = r.rescue_control(api, run(), now=lambda: next(clock), sleep=lambda _: None)
        self.assertEqual(result.action, "noop")
        api.rerun.assert_not_called()

    def test_a_new_attempt_appearing_while_cancel_settles_is_not_touched(self):
        api = mock.Mock()
        self.mark(api)
        api.jobs.return_value = [watch()]
        api.run.side_effect = [
            {"status": "in_progress", "run_attempt": 1, "path": r.WORKFLOW_PATH,
             "head_sha": "a" * 40, "head_branch": "main",
             "head_repository": {"full_name": r.TRUSTED_REPOSITORY}},
            {"status": "in_progress", "run_attempt": 1, "path": r.WORKFLOW_PATH,
             "head_sha": "a" * 40, "head_branch": "main",
             "head_repository": {"full_name": r.TRUSTED_REPOSITORY}},
            {"status": "in_progress", "run_attempt": 2, "path": r.WORKFLOW_PATH,
             "head_sha": "a" * 40, "head_branch": "main",
             "head_repository": {"full_name": r.TRUSTED_REPOSITORY}},
        ]
        result = r.rescue_control(api, run(), now=lambda: NOW, sleep=lambda _: None)
        self.assertEqual(result.action, "noop")
        self.assertIn("changed while cancelling", result.reason)
        api.force_cancel.assert_not_called()
        api.rerun.assert_not_called()

    def test_cli_waits_once_and_scans_once(self):
        api = mock.Mock()
        api.request.return_value = {"workflow_runs": [{**run(), "status": "queued"}]}
        with mock.patch.object(r, "_client", return_value=api) as client, \
                mock.patch.object(r, "run_once", return_value=r.Decision("noop", "idle")), \
                mock.patch.object(r.time, "sleep") as sleep, \
                mock.patch.dict("os.environ", {"GH_TOKEN": "test-token", "GITHUB_REPOSITORY": r.TRUSTED_REPOSITORY}, clear=False):
            self.assertEqual(r.main(["--source-root", "/trusted", "--wait-seconds", "300"]), 0)
        client.assert_called_once()
        sleep.assert_called_once_with(300)
        api.request.assert_called_once()

    def test_requested_event_follows_one_fresh_rerun_attempt(self):
        api = mock.Mock()
        api.run.return_value = run(2)
        rescue = r.Decision("rescue", "queued", r.WATCH_LABELS[1])
        done = r.Decision("noop", "started")
        with mock.patch.object(r, "run_once", side_effect=[rescue, done]) as run_once, \
                mock.patch.object(r.time, "sleep") as sleep:
            decisions = r.rescue_sequence(api, run(), wait_seconds=180,
                                          follow_retries=True, sleep=sleep)
        self.assertEqual(decisions, [rescue, done])
        self.assertEqual(sleep.call_args_list, [mock.call(180), mock.call(r.NO_START_SECONDS)])
        api.run.assert_called_once_with(9)
        self.assertEqual(run_once.call_count, 2)


if __name__ == "__main__":
    unittest.main()
