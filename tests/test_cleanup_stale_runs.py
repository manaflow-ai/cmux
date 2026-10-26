import datetime as dt
import importlib.util
import pathlib
import unittest
from unittest import mock


SCRIPT = pathlib.Path(__file__).parents[1] / "scripts/ci/cleanup-stale-runs.py"
WORKFLOW = pathlib.Path(__file__).parents[1] / ".github/workflows/ci-stale-run-janitor.yml"
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


class InventoryBudgetTests(unittest.TestCase):
    environment = {"GH_TOKEN": "test-token", "GH_REPO": "test/repo"}

    def test_pull_requests_are_read_only_for_old_pull_request_runs(self):
        old = dict(ClassifyRunTests.run_data, created_at="2026-01-01T00:00:00Z")
        runs = [
            dict(old, id=1, head_sha="a"),
            dict(old, id=2, head_sha="a", status="in_progress"),
            dict(old, id=3, head_sha="b", event="push"),
            dict(old, id=4, head_sha="c", created_at="2999-01-01T00:00:00Z"),
            dict(old, id=5, head_sha="d", created_at=None),
            dict(old, id=6, head_sha="e"),
        ]
        api = mock.Mock()
        api.runs.side_effect = [runs[:1] + runs[2:], runs[1:2]]
        api.pull_requests_for_commit.side_effect = lambda sha: {
            "a": [{"state": "closed", "merged_at": "2026-01-02T00:00:00Z"}], "e": [{"state": "open"}]}[sha]
        with mock.patch.dict(MODULE.os.environ, self.environment, clear=True), \
                mock.patch.object(MODULE, "GitHub", return_value=api), \
                mock.patch("builtins.print") as printed:
            self.assertEqual(MODULE.main(), 0)
        self.assertEqual(api.pull_requests_for_commit.call_args_list, [mock.call("a"), mock.call("e"), mock.call("a")])
        lines = [" ".join(str(arg) for arg in call.args) for call in printed.call_args_list]
        self.assertIn("stale-run-janitor: DRY-RUN; eligible=2; limit=25", lines)
        self.assertIn("would process run 1 (queued, merged PR)", lines)
        self.assertIn("would process run 2 (in_progress, merged PR)", lines)

    def test_listing_asks_only_for_pull_request_runs(self):
        client = MODULE.GitHub("test-token", "test/repo")
        with mock.patch.object(client, "request", return_value={"workflow_runs": []}) as request:
            self.assertEqual(client.runs("queued"), [])
        request.assert_called_once_with(
            "GET", "/repos/test/repo/actions/runs?status=queued&event=pull_request&per_page=100&page=1")

    def test_prefilter_matches_classify_run_for_a_closed_pr(self):
        prs = [{"state": "closed", "merged_at": None}]
        now = ClassifyRunTests.now
        for event in ("pull_request", "push", None):
            for status in ("queued", "in_progress", "completed"):
                for created_at in ("2026-09-18T00:00:00Z", "2026-09-18T23:30:00Z", None):
                    run = {"event": event, "status": status, "created_at": created_at}
                    with self.subTest(run=run):
                        self.assertEqual(MODULE.may_be_eligible(run, now=now, min_age_seconds=3600),
                                         MODULE.classify_run(run, prs, now=now, min_age_seconds=3600) is not None)


class WorkflowSafetyTests(unittest.TestCase):
    def test_scheduled_and_manual_janitors_are_serialized(self):
        workflow = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("concurrency:\n  group: ci-stale-run-janitor\n  cancel-in-progress: false", workflow)


if __name__ == "__main__":
    unittest.main()
