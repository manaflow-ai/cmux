import datetime as dt
import importlib.util
import pathlib
import unittest
from unittest import mock


SCRIPT = pathlib.Path(__file__).parents[1] / "scripts/ci/cleanup-stale-runs.py"
SPEC = importlib.util.spec_from_file_location("cleanup_stale_runs", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class ClassifyRunTests(unittest.TestCase):
    now = dt.datetime(2026, 9, 19, tzinfo=dt.timezone.utc)
    run_data = {"created_at": "2026-09-18T00:00:00Z", "status": "queued", "event": "pull_request"}

    def test_non_pr_runs_are_preserved_at_a_merged_commit(self):
        prs = [{"state": "closed", "merged_at": "2026-09-18T12:00:00Z"}]
        for event in ("push", "schedule", "workflow_dispatch", "merge_group", "pull_request_target", None):
            with self.subTest(event=event):
                run = dict(self.run_data, event=event)
                self.assertIsNone(MODULE.classify_run(run, prs, now=self.now, min_age_seconds=3600))

    def test_completed_pr_run_is_preserved(self):
        prs = [{"state": "closed", "merged_at": "2026-09-18T12:00:00Z"}]
        run = dict(self.run_data, status="completed")
        self.assertIsNone(MODULE.classify_run(run, prs, now=self.now, min_age_seconds=3600))

    def test_merged_pr_is_eligible(self):
        prs = [{"state": "closed", "merged_at": "2026-09-18T12:00:00Z"}]
        self.assertEqual(MODULE.classify_run(self.run_data, prs, now=self.now, min_age_seconds=3600), "merged PR")

    def test_closed_pr_is_eligible(self):
        prs = [{"state": "closed", "merged_at": None}]
        self.assertEqual(MODULE.classify_run(self.run_data, prs, now=self.now, min_age_seconds=3600), "closed PR")

    def test_open_pr_is_preserved_even_when_old(self):
        prs = [{"state": "open", "merged_at": None}]
        self.assertIsNone(MODULE.classify_run(self.run_data, prs, now=self.now, min_age_seconds=3600))

    def test_no_pr_is_preserved(self):
        self.assertIsNone(MODULE.classify_run(self.run_data, [], now=self.now, min_age_seconds=3600))

    def test_recent_terminal_run_is_preserved(self):
        recent = {"created_at": "2026-09-19T00:00:00Z", "status": "queued", "event": "pull_request"}
        prs = [{"state": "closed", "merged_at": None}]
        self.assertIsNone(MODULE.classify_run(recent, prs, now=self.now, min_age_seconds=3600))


class CleanupRevalidationTests(unittest.TestCase):
    def test_cleanup_uses_refreshed_run_status(self):
        original = dict(ClassifyRunTests.run_data, id=123, head_sha="old-head")
        closed = [{"state": "closed", "merged_at": "2026-09-18T12:00:00Z"}]
        for status, method, suffix in [("queued", "DELETE", ""), ("in_progress", "POST", "/cancel")]:
            with self.subTest(status=status):
                api = mock.Mock()
                api.runs.side_effect = [[original], []]
                api.pull_requests_for_commit.return_value = closed
                api.request.side_effect = [dict(original, status=status), {}]
                environment = {"GH_TOKEN": "test-token", "GH_REPO": "test/repo",
                               "CLEANUP": "true", "GITHUB_EVENT_NAME": "workflow_dispatch"}
                with mock.patch.dict(MODULE.os.environ, environment, clear=True), mock.patch.object(MODULE, "GitHub", return_value=api):
                    self.assertEqual(MODULE.main(), 0)
                self.assertEqual(api.request.call_args_list, [
                    mock.call("GET", "/repos/test/repo/actions/runs/123"),
                    mock.call(method, "/repos/test/repo/actions/runs/123" + suffix),
                ])

    def test_changed_run_or_reopened_pr_is_preserved(self):
        original = dict(ClassifyRunTests.run_data, id=123, head_sha="old-head")
        closed = [{"state": "closed", "merged_at": "2026-09-18T12:00:00Z"}]
        scenarios = [
            (dict(original, status="completed"), closed),
            (dict(original, event="push"), closed),
            (original, [{"state": "open"}]),
            (original, [{}]),
        ]
        for current, current_prs in scenarios:
            with self.subTest(current=current, current_prs=current_prs):
                api = mock.Mock()
                api.runs.side_effect = [[original], []]
                api.pull_requests_for_commit.side_effect = [closed, current_prs]
                api.request.return_value = current
                environment = {"GH_TOKEN": "test-token", "GH_REPO": "test/repo",
                               "CLEANUP": "true", "GITHUB_EVENT_NAME": "workflow_dispatch"}
                with mock.patch.dict(MODULE.os.environ, environment, clear=True), mock.patch.object(MODULE, "GitHub", return_value=api):
                    self.assertEqual(MODULE.main(), 0)
                api.request.assert_called_once_with("GET", "/repos/test/repo/actions/runs/123")


if __name__ == "__main__":
    unittest.main()
