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
        # One read per commit in the inventory (runs 1 and 2 share "a"); the cleanup path reads again before acting.
        self.assertEqual(api.pull_requests_for_commit.call_args_list, [mock.call("a"), mock.call("e")])
        lines = [" ".join(str(arg) for arg in call.args) for call in printed.call_args_list]
        self.assertIn("stale-run-janitor: DRY-RUN; eligible=2; limit=25", lines)
        self.assertIn("would process run 1 (queued, merged PR)", lines)
        self.assertIn("would process run 2 (in_progress, merged PR)", lines)

    def test_the_inventory_reads_each_commits_pull_requests_once(self):
        # 2026-11-22 02:35Z: the report-only schedule read commits/{sha}/pulls for 227 old runs of 19 commits, twice
        # an hour, from the GITHUB_TOKEN hour the production promote gates read their staging runs from.
        old = dict(ClassifyRunTests.run_data, created_at="2026-01-01T00:00:00Z")
        runs = [dict(old, id=n, head_sha="abc"[n % 3]) for n in range(30)]
        api = mock.Mock()
        api.runs.side_effect = [runs[:20], runs[20:]]
        api.pull_requests_for_commit.side_effect = lambda sha: [{"state": "closed", "merged_at": None}]
        with mock.patch.dict(MODULE.os.environ, self.environment, clear=True), \
                mock.patch.object(MODULE, "GitHub", return_value=api), \
                mock.patch("builtins.print") as printed:
            self.assertEqual(MODULE.main(), 0)
        self.assertEqual(sorted(c.args[0] for c in api.pull_requests_for_commit.call_args_list), ["a", "b", "c"])
        lines = [" ".join(str(arg) for arg in call.args) for call in printed.call_args_list]
        self.assertIn("stale-run-janitor: DRY-RUN; eligible=30; limit=25", lines)

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


class SupersededTests(unittest.TestCase):
    now = ClassifyRunTests.now
    run_data = {"id": 7, "created_at": "2026-09-18T00:00:00Z", "status": "queued", "event": "pull_request",
                "head_sha": "old", "path": ".github/workflows/ci.yml", "name": "CI", "pull_requests": [{"number": 5}]}
    heads = {5: "new", 6: "other"}

    def test_queued_run_of_an_open_pr_at_a_newer_head_is_superseded(self):
        self.assertEqual(MODULE.classify_superseded(self.run_data, self.heads, now=self.now), "superseded head")

    def test_runs_that_must_be_kept(self):
        protected = [".github/workflows/nightly.yml", ".github/workflows/promote-stable.yml",
                     ".github/workflows/release.yml", ".github/workflows/cmux-dev.yml"]
        cases = {
            "live head": dict(self.run_data, head_sha="new"),
            "head of another open PR": dict(self.run_data, head_sha="other"),
            "started": dict(self.run_data, status="in_progress"),
            "push": dict(self.run_data, event="push"),
            "schedule": dict(self.run_data, event="schedule"),
            "dispatch": dict(self.run_data, event="workflow_dispatch"),
            "no pull request": dict(self.run_data, pull_requests=[]),
            "closed pull request": dict(self.run_data, pull_requests=[{"number": 9}]),
            "one PR still at this head": dict(self.run_data, pull_requests=[{"number": 5}, {"number": 9}]),
            "young": dict(self.run_data, created_at="2026-09-18T23:55:00Z"),
            "no sha": dict(self.run_data, head_sha=""),
            "dev by name": dict(self.run_data, name="Dev build"),
            **{path: dict(self.run_data, path=path) for path in protected},
        }
        for label, run in cases.items():
            with self.subTest(label):
                self.assertIsNone(MODULE.classify_superseded(run, self.heads, now=self.now))

    def test_devtools_style_names_are_not_mistaken_for_dev(self):
        run = dict(self.run_data, path=".github/workflows/devtools-check.yml", name="Devtools")
        self.assertEqual(MODULE.classify_superseded(run, self.heads, now=self.now), "superseded head")

    def run_main(self, api, cleanup="true"):
        environment = {"GH_TOKEN": "t", "GH_REPO": "test/repo", "CLEANUP": cleanup, "SUPERSEDED": "true",
                       "MAX_SUPERSEDED": "200", "GITHUB_EVENT_NAME": "workflow_dispatch"}
        with mock.patch.dict(MODULE.os.environ, environment, clear=True), \
                mock.patch.object(MODULE, "GitHub", return_value=api):
            return MODULE.main()

    def test_cancel_rereads_the_run_and_its_pr(self):
        api = mock.Mock()
        api.open_heads.return_value = dict(self.heads)
        api.queued_pull_request_runs.return_value = [self.run_data]
        api.request.side_effect = [dict(self.run_data), {"state": "open", "head": {"sha": "new"}}, {}]
        api.pull_requests_for_commit.return_value = [{"number": 5, "state": "open", "head": {"sha": "new"}}]
        self.assertEqual(self.run_main(api), 0)
        self.assertEqual(api.request.call_args_list, [
            mock.call("GET", "/repos/test/repo/actions/runs/7"),
            mock.call("GET", "/repos/test/repo/pulls/5"),
            mock.call("POST", "/repos/test/repo/actions/runs/7/cancel"),
        ])

    def test_started_run_or_pr_back_at_this_head_is_kept(self):
        for current, pr in [(dict(self.run_data, status="in_progress"), {"state": "open", "head": {"sha": "new"}}),
                            (self.run_data, {"state": "open", "head": {"sha": "old"}}),
                            (self.run_data, {"state": "closed", "head": {"sha": "new"}})]:
            with self.subTest(current=current, pr=pr):
                api = mock.Mock()
                api.open_heads.return_value = dict(self.heads)
                api.queued_pull_request_runs.return_value = [self.run_data]
                api.request.side_effect = [current, pr]
                api.pull_requests_for_commit.return_value = []
                self.assertEqual(self.run_main(api), 0)
                self.assertNotIn("POST", [call.args[0] for call in api.request.call_args_list])

    def test_another_pr_pushed_back_to_this_head_is_kept(self):
        # The inventory saw PR 6 at "other"; by the recheck it was pushed back to this run's commit.
        api = mock.Mock()
        api.open_heads.return_value = dict(self.heads)
        api.queued_pull_request_runs.return_value = [self.run_data]
        api.request.side_effect = [dict(self.run_data), {"state": "open", "head": {"sha": "new"}}]
        api.pull_requests_for_commit.return_value = [{"number": 6, "state": "open", "head": {"sha": "old"}}]
        self.assertEqual(self.run_main(api), 0)
        api.pull_requests_for_commit.assert_called_once_with("old")
        self.assertNotIn("POST", [call.args[0] for call in api.request.call_args_list])

    def test_malformed_created_at_is_kept_without_a_traceback(self):
        for created_at in ("not-a-time", "2026-13-45T00:00:00Z", 12345):
            with self.subTest(created_at=created_at):
                run = dict(self.run_data, created_at=created_at)
                self.assertIsNone(MODULE.classify_superseded(run, self.heads, now=self.now))
        api = mock.Mock()
        api.open_heads.return_value = dict(self.heads)
        api.queued_pull_request_runs.return_value = [dict(self.run_data, id=8, created_at="garbage"), self.run_data]
        self.assertEqual(self.run_main(api, cleanup="false"), 0)

    def test_dry_run_and_schedule_never_cancel(self):
        api = mock.Mock()
        api.open_heads.return_value = dict(self.heads)
        api.queued_pull_request_runs.return_value = [self.run_data]
        self.assertEqual(self.run_main(api, cleanup="false"), 0)
        api.request.assert_not_called()
        environment = {"GH_TOKEN": "t", "GH_REPO": "test/repo", "CLEANUP": "true", "SUPERSEDED": "true",
                       "GITHUB_EVENT_NAME": "schedule"}
        api = mock.Mock()
        api.queued_pull_request_runs.return_value = []
        api.runs.return_value = []
        with mock.patch.dict(MODULE.os.environ, environment, clear=True), \
                mock.patch.object(MODULE, "GitHub", return_value=api):
            self.assertEqual(MODULE.main(), 0)
        api.open_heads.assert_not_called()

    def test_limit_is_bounded(self):
        for value in ("0", "501", "x"):
            environment = {"GH_TOKEN": "t", "GH_REPO": "test/repo", "SUPERSEDED": "true",
                           "MAX_SUPERSEDED": value, "GITHUB_EVENT_NAME": "workflow_dispatch"}
            with self.subTest(value=value), mock.patch.dict(MODULE.os.environ, environment, clear=True), \
                    mock.patch.object(MODULE, "GitHub"):
                self.assertEqual(MODULE.main(), 2)

    def test_open_heads_pages_until_empty(self):
        client = MODULE.GitHub("t", "test/repo")
        pages = [[{"number": n, "head": {"sha": f"s{n}"}} for n in range(100)], [{"number": 100, "head": {"sha": "x"}}], []]
        with mock.patch.object(client, "request", side_effect=pages) as request:
            heads = client.open_heads()
        self.assertEqual(len(heads), 101)
        self.assertEqual(request.call_count, 3)


class QueuedListingTests(unittest.TestCase):
    def test_a_short_page_does_not_end_the_listing(self):
        client = MODULE.GitHub("test-token", "test/repo")
        pages = [{"workflow_runs": [{"id": i} for i in range(98)]}, {"workflow_runs": [{"id": 98}]}, {"workflow_runs": []}]
        with mock.patch.object(client, "request", side_effect=pages):
            self.assertEqual(len(client.runs("queued")), 99)

    def test_a_window_that_fills_the_listing_cap_is_split(self):
        # 2026-11-19: over 2,500 queued runs, but one query lists at most 1,000.
        client = MODULE.GitHub("test-token", "test/repo")
        now = dt.datetime(2026, 11, 19, 19, 0, tzinfo=dt.timezone.utc)
        calls = []

        def runs(status, pages=10, *, created=None):
            calls.append(created)
            if len(calls) == 1:
                return [{"id": i} for i in range(MODULE.LIST_CAP)], False
            return [{"id": f"{created}-{i}"} for i in range(3)] + [{"id": "shared"}], True

        with mock.patch.object(client, "listing", side_effect=runs):
            found = client.queued_pull_request_runs(now=now, hours=2)
        self.assertEqual(calls[0], "2026-11-19T17:00:00Z..2026-11-19T19:00:00Z")
        self.assertEqual(sorted(calls[1:]), ["2026-11-19T17:00:00Z..2026-11-19T18:00:00Z",
                                             "2026-11-19T18:00:00Z..2026-11-19T19:00:00Z"])
        self.assertEqual(len(found), 7)

    def test_a_capped_listing_of_short_pages_is_split(self):
        # Review of #47775, F3: 98 visible runs a page over 10 pages is 980, under LIST_CAP, but the listing never
        # reached an empty page, so the window holds more than it returned.
        client = MODULE.GitHub("test-token", "test/repo")
        now = dt.datetime(2026, 11, 19, 19, 0, tzinfo=dt.timezone.utc)
        windows = []

        def request(method, path, **_):
            query = dict(item.split("=", 1) for item in path.split("?", 1)[1].split("&"))
            if query["page"] == "1":
                windows.append(query["created"])
            if len(windows) == 1:
                return {"workflow_runs": [{"id": f"{query['page']}-{i}"} for i in range(98)]}
            if query["page"] == "1":
                return {"workflow_runs": [{"id": f"{query['created']}-{i}"} for i in range(2)]}
            return {"workflow_runs": []}

        with mock.patch.object(client, "request", side_effect=request):
            found = client.queued_pull_request_runs(now=now, hours=2)
        self.assertEqual(len(windows), 3)
        self.assertEqual(len(found), 4)


class DeadQueuedTests(unittest.TestCase):
    now = dt.datetime(2026, 9, 19, tzinfo=dt.timezone.utc)
    run_data = {"id": 7, "created_at": "2026-09-18T00:00:00Z", "status": "queued", "event": "pull_request",
                "head_sha": "old", "head_branch": "feat", "path": ".github/workflows/ci.yml", "name": "CI",
                "workflow_id": 1, "run_attempt": 1, "pull_requests": [{"number": 5}]}

    def pr(self, sha="old", draft=False, labels=()):
        return {"sha": sha, "draft": draft, "labels": tuple(labels)}

    def kind(self, run, prs, runs=None):
        keepers = MODULE.duplicate_keepers(runs or [run], self.now)
        return MODULE.classify_dead(run, prs, keepers, now=self.now)

    def test_superseded_and_closed(self):
        self.assertEqual(self.kind(self.run_data, {5: self.pr("new")}), "superseded head")
        self.assertEqual(self.kind(self.run_data, {6: self.pr("other")}), "closed PR")

    def test_draft_head_unstarted_a_day_is_stale_but_a_young_one_or_ready_pr_is_kept(self):
        self.assertEqual(self.kind(self.run_data, {5: self.pr(draft=True)}), "stale draft")
        young = dict(self.run_data, created_at="2026-09-18T12:00:00Z")
        self.assertIsNone(self.kind(young, {5: self.pr(draft=True)}))
        self.assertIsNone(self.kind(self.run_data, {5: self.pr()}))
        self.assertIsNone(self.kind(self.run_data, {5: self.pr(draft=True), 6: self.pr()}))

    def test_older_duplicate_goes_once_the_newest_has_waited(self):
        newer = dict(self.run_data, id=8, created_at="2026-09-18T01:00:00Z")
        self.assertEqual(self.kind(self.run_data, {5: self.pr()}, [self.run_data, newer]), "duplicate")
        self.assertIsNone(self.kind(newer, {5: self.pr()}, [self.run_data, newer]))
        fresh = dict(newer, created_at="2026-09-18T23:55:00Z")
        self.assertIsNone(self.kind(self.run_data, {5: self.pr()}, [self.run_data, fresh]))
        for other in (dict(newer, head_sha="x"), dict(newer, workflow_id=2), dict(newer, pull_requests=[{"number": 6}])):
            with self.subTest(other=other):
                self.assertIsNone(self.kind(self.run_data, {5: self.pr()}, [self.run_data, other]))
        rerun = dict(self.run_data, run_attempt=2)
        self.assertIsNone(self.kind(rerun, {5: self.pr()}, [rerun, newer]))

    def test_runs_that_must_be_kept(self):
        cases = {
            "started": dict(self.run_data, status="in_progress"),
            "push": dict(self.run_data, event="push"),
            "dispatch": dict(self.run_data, event="workflow_dispatch"),
            "no pull request": dict(self.run_data, pull_requests=[]),
            "young": dict(self.run_data, created_at="2026-09-18T23:55:00Z"),
            "nightly": dict(self.run_data, path=".github/workflows/nightly.yml"),
            "release": dict(self.run_data, name="Release"),
            "rerun": dict(self.run_data, run_attempt=2),
        }
        for label, run in cases.items():
            with self.subTest(label):
                self.assertIsNone(self.kind(run, {6: self.pr("other")}))
        self.assertIsNone(self.kind(self.run_data, {5: self.pr("new", labels=["no-janitor"])}))
        self.assertIsNone(self.kind(self.run_data, {5: self.pr(draft=True, labels=["no-janitor"])}))
        # Review of #47775, F1: a fresh rerun of an old draft is someone asking for it again.
        rerun = dict(self.run_data, run_attempt=2)
        self.assertIsNone(self.kind(rerun, {5: self.pr(draft=True)}))
        self.assertIsNone(self.kind(rerun, {5: self.pr("new")}))

    def run_main(self, api, cleanup="true"):
        environment = {"GH_TOKEN": "t", "GH_REPO": "test/repo", "CLEANUP": cleanup, "DEAD_QUEUED": "true",
                       "MAX_SUPERSEDED": "200", "GITHUB_EVENT_NAME": "workflow_dispatch"}
        with mock.patch.dict(MODULE.os.environ, environment, clear=True), \
                mock.patch.object(MODULE, "GitHub", return_value=api):
            return MODULE.main()

    def test_cancel_rereads_the_run_its_pr_and_the_kept_run(self):
        newer = dict(self.run_data, id=8, created_at="2026-09-18T01:00:00Z")
        open_pr = {"number": 5, "state": "open", "draft": False, "labels": [], "head": {"sha": "old"}}
        for kept_status, cancels in (("queued", 1), ("in_progress", 0)):
            with self.subTest(kept_status=kept_status):
                api = mock.Mock()
                api.open_prs.return_value = {5: self.pr()}
                api.queued_pull_request_runs.return_value = [self.run_data, newer]
                api.request.side_effect = [dict(self.run_data), open_pr, dict(newer, status=kept_status), {}]
                api.pull_requests_for_commit.return_value = []
                self.assertEqual(self.run_main(api), 0)
                posts = [c for c in api.request.call_args_list if c.args[0] == "POST"]
                self.assertEqual(len(posts), cancels)
                self.assertEqual(api.request.call_args_list[:3], [
                    mock.call("GET", "/repos/test/repo/actions/runs/7"),
                    mock.call("GET", "/repos/test/repo/pulls/5", missing_is_empty=True),
                    mock.call("GET", "/repos/test/repo/actions/runs/8")])

    def test_a_reopened_pr_keeps_a_closed_pr_run(self):
        api = mock.Mock()
        api.open_prs.return_value = {}
        api.queued_pull_request_runs.return_value = [self.run_data]
        api.request.side_effect = [dict(self.run_data),
                                   {"number": 5, "state": "open", "draft": False, "labels": [], "head": {"sha": "old"}}]
        api.pull_requests_for_commit.return_value = []
        self.assertEqual(self.run_main(api), 0)
        self.assertNotIn("POST", [c.args[0] for c in api.request.call_args_list])

    def test_a_closed_pr_labelled_no_janitor_keeps_its_run(self):
        # Review of #47775, F2: the inventory sees only open PRs' labels; the reread sees the closed one's.
        api = mock.Mock()
        api.open_prs.return_value = {}
        api.queued_pull_request_runs.return_value = [self.run_data]
        api.request.side_effect = [dict(self.run_data), {"number": 5, "state": "closed", "draft": False,
                                                         "labels": [{"name": "no-janitor"}], "head": {"sha": "old"}}]
        api.pull_requests_for_commit.return_value = []
        self.assertEqual(self.run_main(api), 0)
        self.assertNotIn("POST", [c.args[0] for c in api.request.call_args_list])

    def test_dry_run_counts_each_kind_and_cancels_nothing(self):
        api = mock.Mock()
        api.open_prs.return_value = {5: self.pr("new")}
        api.queued_pull_request_runs.return_value = [self.run_data, dict(self.run_data, id=9, pull_requests=[{"number": 4}])]
        with mock.patch("builtins.print") as printed:
            self.assertEqual(self.run_main(api, cleanup="false"), 0)
        api.request.assert_not_called()
        text = " ".join(str(c.args[0]) for c in printed.call_args_list)
        self.assertIn('would_cancel=2 {"closed PR": 1, "superseded head": 1}', text)


class WorkflowSafetyTests(unittest.TestCase):
    def test_scheduled_and_manual_janitors_are_serialized(self):
        workflow = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("concurrency:\n  group: ci-stale-run-janitor\n  cancel-in-progress: false", workflow)

    def test_dead_queued_is_a_dispatch_input(self):
        workflow = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("      dead_queued:\n", workflow)
        self.assertIn("DEAD_QUEUED: ${{ inputs.dead_queued || 'false' }}", workflow)


if __name__ == "__main__":
    unittest.main()
