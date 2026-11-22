import datetime as dt
import base64
from pathlib import Path
import unittest
import sys
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

    def test_unmodified_legacy_workflow_requires_separate_activation(self):
        api = mock.Mock()
        source = (Path(__file__).resolve().parents[1] / r.WORKFLOW_PATH).read_text()
        api.request.return_value = {"content": base64.b64encode(source.encode()).decode()}
        self.assertFalse(r.workflow_supports_reroute(api, run()))

    def test_missing_yaml_dependency_fails_loudly_before_mutation(self):
        api = mock.Mock()
        with mock.patch.dict(sys.modules, {"yaml": None}):
            with self.assertRaisesRegex(RuntimeError, "python-with-yaml.sh"):
                r.workflow_supports_reroute(api, run())
        api.request.assert_not_called()
        api.cancel.assert_not_called()

    def test_unconditional_prefix_cannot_hide_the_route(self):
        api = mock.Mock()
        self.mark(api)
        source = base64.b64decode(api.request.return_value["content"]).decode()
        source = source.replace("${{", "${{ true ||")
        api.request.return_value = {"content": base64.b64encode(source.encode()).decode()}
        self.assertFalse(r.workflow_supports_reroute(api, run()))

    def test_legacy_marker_in_comment_does_not_enable_reroute(self):
        api = mock.Mock()
        source = "# github.run_attempt " + " ".join(r.WATCH_LABELS)
        api.request.return_value = {"content": base64.b64encode(source.encode()).decode()}
        self.assertFalse(r.workflow_supports_reroute(api, run()))

    def test_unreachable_labels_do_not_enable_reroute(self):
        api = mock.Mock()
        source = ("jobs:\n  watch:\n    runs-on: ${{ github.run_attempt == 1 && '" + r.WATCH_LABELS[0]
                  + "' || '" + r.WATCH_LABELS[1] + "' || '" + r.WATCH_LABELS[2] + "' }}")
        api.request.return_value = {"content": base64.b64encode(source.encode()).decode()}
        self.assertFalse(r.workflow_supports_reroute(api, run()))

    def test_cancel_settle_reruns_and_returns_next_label(self):
        api = mock.Mock()
        self.mark(api)
        api.jobs.side_effect = [[watch()], [watch()]]
        api.run.side_effect = [run(), run(), {"status": "cancelled", "run_attempt": 1, "path": r.WORKFLOW_PATH}]
        decision = r.rescue_control(api, run(), now=lambda: NOW, sleep=lambda _: None)
        self.assertEqual(decision.next_label, r.WATCH_LABELS[1])
        api.cancel.assert_called_once_with(9, before_send=mock.ANY)
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
        api.request.return_value = {"workflow_runs": [{**run(), "status": "queued"},
                                                      {**run(), "id": 10, "status": "queued"}]}
        with mock.patch.object(r, "_client", return_value=api) as client, \
                mock.patch.object(r, "run_once", return_value=r.Decision("noop", "idle")), \
                mock.patch.object(r.time, "sleep") as sleep, \
                mock.patch.dict("os.environ", {"GH_TOKEN": "test-token", "GITHUB_REPOSITORY": r.TRUSTED_REPOSITORY}, clear=False):
            calls = []
            sleep.side_effect = lambda _: calls.append("wait")
            api.request.side_effect = lambda *_: (calls.append("scan") or api.request.return_value)
            self.assertEqual(r.main(["--source-root", "/trusted", "--wait-seconds", "300"]), 0)
            self.assertEqual(calls, ["wait", "scan"])
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


class RetryingTransport:
    """Main's before_send contract: validate again after a refused POST waits."""

    def __init__(self):
        self.current = run()
        self.watcher = watch()
        self.seconds = 0
        self.read_seconds = 0
        self.sent = []
        self.reruns = []
        self.retry_path = "cancel"
        self.on_retry = lambda: None
        self.hold_cancel = False
        self.on_jobs = lambda: None

    def run(self, run_id):
        return dict(self.current)

    def jobs(self, run_id, attempt):
        self.seconds += self.read_seconds
        result = [dict(self.watcher)]
        self.on_jobs()
        return result

    def request(self, method, path, *, before_send=None):
        if method == "GET":
            api = mock.Mock()
            RescueTests.mark(api)
            return api.request.return_value
        action = path.rsplit("/", 1)[-1]
        before_send()
        if action == self.retry_path:
            # The first POST received 429 and did nothing. A watcher may have
            # started while main's transport waited for its retry budget.
            self.on_retry()
            before_send()
        self.sent.append(action)
        if action == "force-cancel" or not self.hold_cancel:
            self.current["status"] = "completed"

    def cancel(self, run_id, *, before_send):
        self.request("POST", f"/actions/runs/{run_id}/cancel", before_send=before_send)

    def rerun(self, run_id, attempt):
        self.reruns.append((run_id, attempt))

    def sleep(self, seconds):
        self.seconds += seconds

    def rescue(self):
        return r.rescue_control(self, run(), now=lambda: NOW + dt.timedelta(seconds=self.seconds),
                                monotonic=lambda: self.seconds, sleep=self.sleep)


class SendGuardTests(unittest.TestCase):
    def test_queued_watcher_can_cancel_and_rerun_after_transport_retry(self):
        api = RetryingTransport()
        self.assertEqual(api.rescue().action, "rescue")
        self.assertEqual(api.sent, ["cancel"])
        self.assertEqual(api.reruns, [(9, 2)])

    def test_cancel_retry_stops_when_watcher_starts_or_run_changes(self):
        changes = (
            lambda api: api.watcher.update(status="in_progress", runner_name="runner"),
            lambda api: api.current.update(run_attempt=2),
            lambda api: api.current.update(head_repository={"full_name": "other/repo"}),
            lambda api: api.current.update(head_sha="b" * 40),
        )
        for change in changes:
            with self.subTest(change=change):
                api = RetryingTransport()
                api.on_retry = lambda: change(api)
                self.assertEqual(api.rescue().action, "noop")
                self.assertEqual(api.sent, [])
                self.assertEqual(api.reruns, [])

    def test_force_cancel_retry_stops_when_watcher_starts_or_attempt_changes(self):
        for change in (
            lambda api: api.watcher.update(status="in_progress", runner_name="runner"),
            lambda api: api.current.update(run_attempt=2),
        ):
            with self.subTest(change=change):
                api = RetryingTransport()
                api.hold_cancel = True
                api.retry_path = "force-cancel"
                api.on_retry = lambda: change(api)
                self.assertEqual(api.rescue().action, "noop")
                self.assertEqual(api.sent, ["cancel"])
                self.assertEqual(api.reruns, [])

    def test_force_cancel_still_finishes_an_unassigned_watcher(self):
        api = RetryingTransport()
        api.hold_cancel = True
        api.retry_path = "force-cancel"
        self.assertEqual(api.rescue().action, "rescue")
        self.assertEqual(api.sent, ["cancel", "force-cancel"])
        self.assertEqual(api.reruns, [(9, 2)])

    def test_nested_read_wait_aborts_instead_of_sending_stale_validation(self):
        api = RetryingTransport()
        api.read_seconds = r.SEND_CHECK_MAX_SECONDS + 1
        result = api.rescue()
        self.assertIn("freshness budget", result.reason)
        self.assertEqual(api.sent, [])
        self.assertEqual(api.reruns, [])

    def test_attempt_change_during_guard_jobs_read_aborts(self):
        api = RetryingTransport()
        api.on_retry = lambda: setattr(api, "on_jobs", lambda: api.current.update(run_attempt=2))
        self.assertEqual(api.rescue().action, "noop")
        self.assertEqual(api.sent, [])
        self.assertEqual(api.reruns, [])


if __name__ == "__main__":
    unittest.main()
