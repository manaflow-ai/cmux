#!/usr/bin/env python3
"""nightly-next feed watch (scripts/ci/nightly_next_feed_watch.py, cx-npz7g).

feat-cmux-next work must reach the nightly-next feed. The nightly.yml alarm
runs only inside nightly-next push runs, so a promotion stall (red Release
compile, unpublished cmux-tui tree) never raised it. The watch runs from main
every 30 minutes and measures how long feat-cmux-next pushes have waited.
"""
from __future__ import annotations

import datetime as dt
import http.client
import importlib.util
from pathlib import Path
import sys
import urllib.error
import urllib.parse
import unittest.mock
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/ci/nightly_next_feed_watch.py"
spec = importlib.util.spec_from_file_location("feed_watch", SCRIPT)
watch = importlib.util.module_from_spec(spec)
sys.modules["feed_watch"] = watch
spec.loader.exec_module(watch)

NOW = dt.datetime(2026, 10, 12, 12, 0, tzinfo=dt.timezone.utc)
NEWEST = NOW - dt.timedelta(hours=30)
NEWEST_FEED = f"<rss><channel><item><pubDate>{NEWEST.strftime('%a, %d %b %Y %H:%M:%S +0000')}</pubDate></item></channel></rss>"


def at(hours_ago: float) -> str:
    return (NOW - dt.timedelta(hours=hours_ago)).strftime("%Y-%m-%dT%H:%M:%SZ")


def run(run_id: int, hours_ago: float, status="completed", conclusion="success"):
    return {"id": run_id, "created_at": at(hours_ago), "status": status, "conclusion": conclusion,
            "head_sha": f"{run_id:040d}", "html_url": f"https://github.com/o/r/actions/runs/{run_id}"}


JOBS = {
    7: [{"name": "decide", "conclusion": "success", "steps": []},
        {"name": "build-nightly-ghostty-cli-helper", "conclusion": "failure",
         "steps": [{"name": "libghostty-vt Zig packages are covered by the notices", "conclusion": "failure"}]}],
    8: [{"name": "build / build x86_64-apple-darwin", "conclusion": "failure",
         "steps": [{"name": "Build the macOS binaries on Linux (no Apple SDK)", "conclusion": "failure"}]}],
    9: [{"name": "cmux-next Release compile (Xcode 26)", "conclusion": "failure", "steps": []}],
    10: [{"name": "cmux-next Release compile (Xcode 26)", "conclusion": "cancelled", "steps": []}],
    11: [{"name": "cmux-next Release compile (Xcode 26)", "conclusion": "success", "steps": []}],
}


def assess(pushes, nightly=(), artifacts=(), compiles=()):
    return watch.assess(NOW, NEWEST, list(pushes), list(nightly), lambda r: JOBS.get(r["id"], []),
                        list(artifacts), list(compiles), 4.0)


class AssessTests(unittest.TestCase):
    def test_quiet_spell_is_not_stale(self):
        self.assertFalse(assess([]).stale)
        self.assertFalse(assess([run(1, 0.5)]).stale)  # a first push after 30h of quiet

    def test_promotion_stall_alarms_and_names_the_stage(self):
        stage = assess([run(1, 5), run(2, 1)], artifacts=[run(8, 1, conclusion="failure")], compiles=[run(9, 1)])
        self.assertTrue(stage.stale)
        self.assertAlmostEqual(stage.waited_hours, 5.0)
        self.assertIn("Nothing was promoted", stage.reason)
        self.assertIn("build / build x86_64-apple-darwin (step: Build the macOS binaries on Linux (no Apple SDK))", stage.reason)
        self.assertIn("cmux-next Release compile (Xcode 26) is failure", stage.reason)

    def test_failed_nightly_names_its_job_and_step(self):
        stage = assess([run(1, 6)], nightly=[run(7, 2, conclusion="failure")])
        self.assertTrue(stage.stale)
        self.assertIn("runs/7", stage.reason)
        self.assertIn("build-nightly-ghostty-cli-helper (step: libghostty-vt Zig packages are covered by the notices)", stage.reason)

    def test_newer_build_supersedes_an_older_failure(self):
        stage = assess([run(1, 6)], nightly=[run(6, 0.5, status="in_progress", conclusion=None), run(7, 2, conclusion="failure")])
        self.assertIn("runs/6", stage.reason)
        self.assertIn("still building", stage.reason)

    def test_a_green_nightly_that_did_not_publish_is_named(self):
        stage = assess([run(1, 6)], nightly=[run(6, 1), run(7, 2, conclusion="failure")])
        self.assertIn("runs/6", stage.reason)
        self.assertIn("did not publish", stage.reason)

    def test_promotion_stall_quotes_the_tick_refusal(self):
        # 2026-10-21: every tick refused 120 commits for want of daemon-tested
        # trees while the issue said only "Nothing was promoted".
        tally = "120 refused: 87x the daemon tests have not passed for tree <sha> yet"
        stage = watch.assess(NOW, NEWEST, [run(1, 5)], [], lambda r: [], [], [], 3.0, tick_refusal=lambda: tally)
        self.assertIn("refused every newer commit: " + tally, stage.detail)
        self.assertIn(stage.detail, watch.issue_body(stage, NEWEST, NOW, "", 3.0, "url"))
        # The tally changes every tick; the issue comments only when the stage itself changes.
        gh = FakeGitHub([{"number": 7, "body": watch.issue_body(stage, NEWEST, NOW, "", 3.0, "url")}])
        watch.sync_issue(gh, watch.Stage(True, 5.5, stage.since, stage.reason, "121 refused: other"), "body", 3.0, "url")
        self.assertEqual(gh.calls, [("PATCH", "/issues/7", None)])
        read = []
        stage = watch.assess(NOW, NEWEST, [run(1, 5)], [run(7, 2, conclusion="failure")], lambda r: JOBS.get(r["id"], []),
                             [], [], 3.0, tick_refusal=lambda: read.append(1) or tally)
        self.assertNotIn(tally, stage.reason)
        self.assertEqual(read, [])  # a promoted build's stage needs no tick lookup

    def test_release_compile_is_read_from_the_newest_decided_run(self):
        # Superseded pushes cancel their compile; that is not the stuck stage.
        stage = assess([run(1, 5)], compiles=[run(10, 1), run(9, 2)])
        self.assertIn("is failure: https://github.com/o/r/actions/runs/9", stage.reason)
        stage = assess([run(1, 5)], compiles=[run(10, 1), run(11, 2), run(9, 3)])
        self.assertNotIn("Release compile", stage.reason)


class PagedGitHub(watch.GitHub):
    """Runs come newest first, 100 a page; the oldest push is on the last page."""

    def __init__(self, pushes, published=None):
        super().__init__("o/r", "t", dry_run=True)
        self.pushes = pushes
        self.published = published
        self.queries = []

    def call(self, method, path, body=None):
        self.queries.append(path)
        query = dict(urllib.parse.parse_qsl(urllib.parse.urlsplit(path).query))
        if "head_sha" in query:
            runs = [self.published] if self.published and self.published["head_sha"] == query["head_sha"] else []
            return {"total_count": len(runs), "workflow_runs": runs}
        bound = query["created"]
        after = watch.parse_time(bound.lstrip(">="))
        runs = [r for r in self.pushes if (watch.parse_time(r["created_at"]) > after if not bound.startswith(">=") else watch.parse_time(r["created_at"]) >= after)]
        per_page, page = int(query.get("per_page", 30)), int(query.get("page", 1))
        return {"total_count": len(runs), "workflow_runs": runs[(page - 1) * per_page:page * per_page]}


class WindowTests(unittest.TestCase):
    def test_the_oldest_waiting_push_is_found_past_the_first_page(self):
        pushes = [run(1000 + i, i * 0.05) for i in range(250)]  # 250 pushes over 12.5h
        oldest = watch.oldest_waiting_push(PagedGitHub(pushes), "", NEWEST)
        self.assertEqual(oldest["id"], 1249)

    def test_a_push_during_the_published_build_still_waits(self):
        # X was promoted and pushed 6h ago, Y landed while X built; X then published 5h ago.
        x, y = run(1, 6), run(2, 5.5)
        gh = PagedGitHub([y, x], published=x)
        self.assertEqual(watch.oldest_waiting_push(gh, x["head_sha"], NOW - dt.timedelta(hours=5))["id"], 2)
        self.assertIsNone(watch.oldest_waiting_push(PagedGitHub([x], published=x), x["head_sha"], NOW - dt.timedelta(hours=5)))


class MainTests(unittest.TestCase):
    def test_a_github_error_warns_instead_of_failing_the_schedule(self):
        def boom(*_args, **_kwargs):
            raise urllib.error.HTTPError("u", 502, "Bad Gateway", {}, None)
        original = watch.GitHub.call, watch.fetch_feed
        watch.GitHub.call, watch.fetch_feed = boom, lambda url: NEWEST_FEED
        try:
            with unittest.mock.patch.dict("os.environ", {"GH_TOKEN": "t"}):
                self.assertEqual(watch.main(["--repo", "o/r", "--dry-run"]), 0)
        finally:
            watch.GitHub.call, watch.fetch_feed = original


class TickRefusalTests(unittest.TestCase):
    class Tick(watch.GitHub):
        def __init__(self, notes):
            super().__init__("o/r", "t", dry_run=True)
            self.notes = notes

        def call(self, method, path, body=None):
            if "/workflows/nightly-next-tick.yml/runs" in path:
                return {"workflow_runs": [{"id": 5, "html_url": "https://github.com/o/r/actions/runs/5"}]}
            if path.startswith("/actions/runs/5/jobs"):
                return {"jobs": [{"id": 50, "name": "request"}]}
            if path.startswith("/check-runs/50/annotations"):
                return self.notes
            raise AssertionError(path)

    def test_reads_the_tick_annotation_by_title(self):
        notes = [{"title": "other", "message": "x"}, {"title": watch.TICK_ANNOTATION, "message": "87x daemon tests\n"}]
        self.assertEqual(self.Tick(notes).tick_refusal(), "87x daemon tests (https://github.com/o/r/actions/runs/5)")
        self.assertEqual(self.Tick([]).tick_refusal(), "")

    def test_the_tick_writes_the_annotation_the_watch_reads(self):
        tick = (Path(__file__).resolve().parents[1] / ".github/workflows/nightly-next-tick.yml").read_text()
        self.assertIn(f"::warning title={watch.TICK_ANNOTATION}::", tick)


class StaleExitTests(unittest.TestCase):
    """A stale feed fails the scheduled run: a green run hid a 4-hour stall on 2026-10-21."""

    def main_with(self, stale, legacy_stale=False):
        stage = watch.Stage(stale, 5.0 if stale else 0.5, NOW - dt.timedelta(hours=5), "Nothing was promoted.")
        with unittest.mock.patch.object(watch, "fetch_feed", lambda url: NEWEST_FEED), \
                unittest.mock.patch.object(watch, "legacy_lag", lambda *a: (4023540480101 if legacy_stale else None, "legacy")), \
                unittest.mock.patch.object(watch, "legacy_rerun", lambda *a: "re-ran"), \
                unittest.mock.patch.object(watch, "published_commit", lambda gh: ""), \
                unittest.mock.patch.object(watch, "published_commit_for_release", lambda gh, tag: ""), \
                unittest.mock.patch.object(watch, "oldest_waiting_push", lambda gh, sha, newest: None), \
                unittest.mock.patch.object(watch, "assess", lambda *a, **k: stage), \
                unittest.mock.patch.object(watch.GitHub, "runs", lambda self, *a, **k: []), \
                unittest.mock.patch.object(watch.GitHub, "queued_runs", lambda self, *a, **k: []), \
                unittest.mock.patch.object(watch, "sync_issue", lambda *a: "synced"), \
                unittest.mock.patch.object(watch, "starvation_dispatch", lambda *a, **k: "stubbed"), \
                unittest.mock.patch.dict("os.environ", {"GH_TOKEN": "t"}):
            return watch.main(["--repo", "o/r", "--dry-run"])

    def test_stale_fails_and_current_passes(self):
        self.assertEqual(self.main_with(True), 1)
        self.assertEqual(self.main_with(False), 0)
        self.assertEqual(self.main_with(False, legacy_stale=True), 1, "cmux NIGHTLY's feed behind fails the run too")

    def test_the_limit_is_thirty_minutes(self):
        # Leo, 2026-10-24: "it is unacceptable to have nightlies >30min out of date".
        workflow = (Path(__file__).resolve().parents[1] / ".github/workflows/nightly-next-feed-watch.yml").read_text()
        self.assertIn("vars.NIGHTLY_NEXT_MAX_FEED_LAG_HOURS || '0.5'", workflow)
        self.assertIn("default=0.5", SCRIPT.read_text())
        self.assertNotIn("NIGHTLY_NEXT_MAX_FEED_LAG_HOURS || '3'", workflow)


def queued_job(name, minutes_ago, labels, status="queued"):
    # The Actions jobs payload: created_at is the queue time; a queued job has no runner start yet.
    return {"name": name, "status": status, "labels": labels, "started_at": None,
            "created_at": (NOW - dt.timedelta(minutes=minutes_ago)).strftime("%Y-%m-%dT%H:%M:%SZ")}


class QueuedGateTests(unittest.TestCase):
    """A gate job with no runner is named with its label (2026-10-26: daemon tests queued on side-std)."""

    DAEMON = "cmux_next_ daemon tests (macOS)"

    def gates(self, jobs_by_run, runs_by_workflow, minutes=watch.GATE_QUEUED_MINUTES):
        return watch.queued_gates(NOW, runs_by_workflow, lambda r: jobs_by_run.get(r["id"], []), minutes)

    def test_names_a_long_queued_gate_job_with_its_label_and_run(self):
        out = self.gates({21: [queued_job("build", 30, ["x"], status="completed"),
                               queued_job(self.DAEMON, 45, ["glaeda-side-std-xcode-26.6"])]},
                         [("cmux-tui-artifacts.yml", [run(21, 1, status="queued", conclusion=None)])])
        self.assertIn(f'cmux-tui-artifacts.yml job "{self.DAEMON}" queued 45 min on glaeda-side-std-xcode-26.6', out)
        self.assertIn("runs/21", out)
        self.assertNotIn('"build"', out)

    def test_a_job_that_just_queued_is_not_a_stall(self):
        self.assertEqual(self.gates({21: [queued_job(self.DAEMON, 3, ["l"])]},
                                    [("cmux-tui-artifacts.yml", [run(21, 1, status="queued", conclusion=None)])]), "")

    def test_reads_at_most_a_few_runs_per_workflow(self):
        read = []
        runs = [run(30 + i, 1, status="queued", conclusion=None) for i in range(10)]
        watch.queued_gates(NOW, [("nightly.yml", runs)], lambda r: read.append(r["id"]) or [])
        self.assertEqual(len(read), watch.GATE_RUNS_READ)

    def test_queue_age_is_from_created_at_not_started_at(self):
        job = queued_job(self.DAEMON, 45, ["l"])
        job["started_at"] = (NOW - dt.timedelta(minutes=2)).strftime("%Y-%m-%dT%H:%M:%SZ")
        out = self.gates({21: [job]}, [("cmux-tui-artifacts.yml", [run(21, 1, status="in_progress", conclusion=None)])])
        self.assertIn("queued 45 min", out)

    def test_reads_in_progress_runs_whose_gate_job_still_waits(self):
        class Listing(watch.GitHub):
            def __init__(self):
                super().__init__("o/r", "t", dry_run=True)
                self.paths = []

            def call(self, method, path, body=None):
                self.paths.append(path)
                status = dict(urllib.parse.parse_qsl(urllib.parse.urlsplit(path).query))["status"]
                runs = {"queued": [run(1, 0.2, status="queued", conclusion=None)],
                        "in_progress": [run(2, 1, status="in_progress", conclusion=None),
                                        run(1, 0.2, status="queued", conclusion=None)]}[status]
                return {"workflow_runs": runs}

        gh = Listing()
        runs = gh.queued_runs("cmux-tui-artifacts.yml", "feat-cmux-next")
        self.assertEqual([r["id"] for r in runs], [1, 2], "deduplicated, newest first")
        self.assertTrue(any("status=in_progress" in p for p in gh.paths))
        self.assertTrue(any("status=queued" in p for p in gh.paths))

    def test_watches_the_promotion_gate_and_the_publish_gate(self):
        self.assertIn(("cmux-tui-artifacts.yml", "feat-cmux-next"), watch.GATE_RUNS)
        self.assertIn(("nightly.yml", "nightly-next"), watch.GATE_RUNS)

    def test_a_stale_feed_names_the_queued_gate_in_the_alarm(self):
        stage = watch.Stage(True, 1.0, NOW - dt.timedelta(hours=1), "Nothing was promoted.")
        jobs = {21: [queued_job(self.DAEMON, 45, ["glaeda-side-std-xcode-26.6"])]}
        printed = []
        with unittest.mock.patch.object(watch, "fetch_feed", lambda url: NEWEST_FEED), \
                unittest.mock.patch.object(watch, "legacy_lag", lambda *a: (None, "legacy")), \
                unittest.mock.patch.object(watch, "published_commit", lambda gh: ""), \
                unittest.mock.patch.object(watch, "published_commit_for_release", lambda gh, tag: ""), \
                unittest.mock.patch.object(watch, "oldest_waiting_push", lambda gh, sha, newest: None), \
                unittest.mock.patch.object(watch, "assess", lambda *a, **k: stage), \
                unittest.mock.patch.object(watch.GitHub, "runs", lambda self, *a, **k: []), \
                unittest.mock.patch.object(watch.GitHub, "queued_runs", lambda self, workflow, branch: [run(21, 1, status="queued", conclusion=None)] if workflow == "cmux-tui-artifacts.yml" else []), \
                unittest.mock.patch.object(watch.GitHub, "jobs", lambda self, r: jobs.get(r["id"], [])), \
                unittest.mock.patch.object(watch, "sync_issue", lambda *a: printed.append(a[2]) or "synced"), \
                unittest.mock.patch.object(watch, "starvation_dispatch", lambda *a, **k: "stubbed"), \
                unittest.mock.patch.dict("os.environ", {"GH_TOKEN": "t"}):
            self.assertEqual(watch.main(["--repo", "o/r", "--dry-run"]), 1)
        self.assertIn("glaeda-side-std-xcode-26.6", printed[0])
        self.assertIn(self.DAEMON, printed[0])

    def test_an_unreadable_gate_list_never_hides_the_alarm(self):
        def boom(self, *a):
            raise urllib.error.HTTPError("u", 403, "rate limited", {}, None)
        stage = watch.Stage(True, 1.0, NOW - dt.timedelta(hours=1), "Nothing was promoted.")
        with unittest.mock.patch.object(watch, "fetch_feed", lambda url: NEWEST_FEED), \
                unittest.mock.patch.object(watch, "legacy_lag", lambda *a: (None, "legacy")), \
                unittest.mock.patch.object(watch, "published_commit", lambda gh: ""), \
                unittest.mock.patch.object(watch, "published_commit_for_release", lambda gh, tag: ""), \
                unittest.mock.patch.object(watch, "oldest_waiting_push", lambda gh, sha, newest: None), \
                unittest.mock.patch.object(watch, "assess", lambda *a, **k: stage), \
                unittest.mock.patch.object(watch.GitHub, "runs", lambda self, *a, **k: []), \
                unittest.mock.patch.object(watch.GitHub, "queued_runs", boom), \
                unittest.mock.patch.object(watch, "sync_issue", lambda *a: "synced"), \
                unittest.mock.patch.object(watch, "starvation_dispatch", lambda *a, **k: "stubbed"), \
                unittest.mock.patch.dict("os.environ", {"GH_TOKEN": "t"}):
            self.assertEqual(watch.main(["--repo", "o/r", "--dry-run"]), 1)


class FeedTests(unittest.TestCase):
    def test_watches_the_cmux_next_feed(self):
        # nightly-next ships as cmux NEXT with its own feed (cx-x7hwx); the old
        # feed is cmux NIGHTLY's (com.cmuxterm.app.nightly reads it), written
        # only by publish-nightly-identity-legacy, and watched too.
        self.assertEqual(watch.FEED_URL, "https://files-next.cmux.com/nightly-next/next/appcast-arm64.xml")
        self.assertEqual(watch.LEGACY_FEED_URL, "https://files-next.cmux.com/nightly-next/appcast-arm64.xml")


def feed(*items):
    """items: (build, minutes ago, channel or None)."""
    body = "".join(
        f"<item><sparkle:version>{build}</sparkle:version>"
        + (f"<sparkle:channel>{channel}</sparkle:channel>" if channel else "")
        + f"<pubDate>{(NOW - dt.timedelta(minutes=minutes)).strftime('%a, %d %b %Y %H:%M:%S +0000')}</pubDate></item>"
        for build, minutes, channel in items)
    return f"<rss><channel>{body}</channel></rss>"


class LegacyGitHub:
    def __init__(self, run, jobs, fail=None):
        self.run, self.job_list, self.posts, self.fail = run, jobs, [], fail

    def call(self, method, path, body=None):
        if self.fail == method:
            raise urllib.error.HTTPError("u", 403, "API rate limit exceeded for installation", {}, None)
        if method == "GET":
            return self.run
        self.posts.append(path)
        return {}

    def jobs(self, run):
        return self.job_list


class LegacyFeedTests(unittest.TestCase):
    """cmux NIGHTLY's feed fell 7 hours behind cmux NEXT's on 2026-10-25: every legacy job
    403'd on the Actions token's rate limit, and only cmux NEXT's feed was watched."""

    NEXT = feed((4023540480101, 40, "cmux-next"), (4020374816001, 450, "cmux-next"))
    OLD = feed((4020374816001, 450, "cmux-next"))
    RUN = {"id": 40235404801, "path": ".github/workflows/nightly.yml", "head_branch": "nightly-next",
           "status": "completed", "run_attempt": 1, "html_url": "run-url"}
    FAILED = [{"id": 11, "name": "verify-nightly-identity-legacy", "conclusion": "failure"},
              {"id": 12, "name": "publish-nightly-identity-legacy", "conclusion": "failure"},
              {"id": 13, "name": "sign-nightly-identity-legacy", "conclusion": "success"},
              {"id": 14, "name": "publish-nightly", "conclusion": "failure"}]

    def lag(self, next_xml=NEXT, old_xml=OLD):
        return watch.legacy_lag(NOW, next_xml, old_xml)

    def rerun(self, run=None, jobs=None, fail=None):
        gh = LegacyGitHub(dict(self.RUN, **(run or {})), self.FAILED if jobs is None else jobs, fail)
        return watch.legacy_rerun(gh, 4023540480101), gh.posts

    def test_a_feed_behind_names_the_waiting_build(self):
        build, message = self.lag()
        self.assertEqual(build, 4023540480101)
        self.assertIn("4020374816001", message)

    def test_current_or_fresh_is_not_behind(self):
        self.assertIsNone(self.lag(old_xml=feed((4023540480101, 30, "cmux-next")))[0])
        self.assertIsNone(self.lag(next_xml=feed((4023540480101, 5, "cmux-next"), (4020374816001, 450, "cmux-next")))[0])

    def test_a_newer_publication_never_restarts_the_wait(self):
        # 40 minutes waiting for one build, and a second one published 5 minutes ago: still behind,
        # and the newest is the one to publish.
        build, _ = self.lag(next_xml=feed((4024000000101, 5, "cmux-next"), (4023540480101, 40, "cmux-next"),
                                          (4020374816001, 450, "cmux-next")))
        self.assertEqual(build, 4024000000101)

    def test_a_feed_that_dropped_its_earlier_items_never_restarts_the_wait(self):
        # A skipped republish leaves cmux NEXT's feed with only its newest item (cx-urd.67).
        build, _ = self.lag(next_xml=feed((4024000000101, 5, "cmux-next")))
        self.assertEqual(build, 4024000000101)
        # With cmux NIGHTLY's build still listed, the oldest missing build's own date counts.
        self.assertIsNone(self.lag(next_xml=feed((4024000000101, 5, "cmux-next"), (4020374816001, 450, "cmux-next")))[0])

    def test_only_items_tagged_cmux_next_count(self):
        # nightly_next_ring.py select keeps only explicit cmux-next tags.
        self.assertIsNone(self.lag(next_xml=feed((4023540480101, 40, "cmux-next-dev"), (4020374816001, 450, "cmux-next")))[0])
        self.assertIsNone(self.lag(next_xml=feed((4023540480101, 40, None), (4020374816001, 450, "cmux-next")))[0])

    def test_reruns_only_the_earliest_failed_legacy_job_of_the_run_that_built_it(self):
        message, posts = self.rerun()
        self.assertEqual(posts, ["/actions/jobs/11/rerun"], "publish follows verify; publish-nightly is not touched")
        self.assertIn("verify-nightly-identity-legacy", message)

    def test_reruns_a_failed_target_or_a_timed_out_job(self):
        # A failed legacy-identity-target leaves the later legacy jobs skipped; a timeout is a failure.
        for jobs, posted in (([{"id": 10, "name": "legacy-identity-target", "conclusion": "failure"},
                               {"id": 13, "name": "sign-nightly-identity-legacy", "conclusion": "skipped"}], 10),
                             ([{"id": 13, "name": "sign-nightly-identity-legacy", "conclusion": "timed_out"}], 13)):
            _, posts = self.rerun(jobs=jobs)
            self.assertEqual(posts, [f"/actions/jobs/{posted}/rerun"], jobs)

    def test_no_rerun_when_running_exhausted_not_failed_or_foreign(self):
        for run, jobs in (({"status": "in_progress"}, None), ({"run_attempt": 3}, None),
                          (None, [{"id": 12, "name": "publish-nightly-identity-legacy", "conclusion": "skipped"}]),
                          ({"head_branch": "main"}, None)):
            _, posts = self.rerun(run=run, jobs=jobs)
            self.assertEqual(posts, [], (run, jobs))

    def run_main(self, fail, *extra):
        def call(gh, method, path, body=None):
            raise urllib.error.HTTPError("u", 403, "API rate limit exceeded for installation", {}, None)
        feeds = {watch.FEED_URL: self.NEXT, watch.LEGACY_FEED_URL: self.OLD}
        with unittest.mock.patch.object(watch, "fetch_feed", lambda url: feeds.get(url, self.NEXT)), \
                unittest.mock.patch.object(watch.dt, "datetime", wraps=dt.datetime) as clock, \
                unittest.mock.patch.object(watch.GitHub, "call", call), \
                unittest.mock.patch.dict("os.environ", {"GH_TOKEN": "t"}):
            clock.now.return_value = NOW
            return watch.main(["--repo", "o/r", "--dry-run", *extra])

    def test_an_api_error_never_turns_a_stale_feed_green(self):
        self.assertEqual(self.run_main(fail=True), 1)

    def test_a_stale_legacy_feed_fails_after_both_guards_ran(self):
        # The merged order (#25350): the starvation guards run first, then this check, and a 403
        # everywhere still ends red while cmux NIGHTLY's feed is behind.
        seen = []
        with unittest.mock.patch.object(watch, "starvation_dispatch",
                                        lambda *a, **k: seen.append(k.get("branch")) or "stubbed"):
            self.assertEqual(self.run_main(fail=True), 1)
        self.assertEqual(seen, ["feat-cmux-next", "main"])

    def test_a_zoneless_or_malformed_date_never_hides_the_lag(self):
        stamp = (NOW - dt.timedelta(minutes=40)).strftime("%a, %d %b %Y %H:%M:%S")
        odd = ("<rss><channel>"
               f"<item><sparkle:version>4023540480101</sparkle:version><sparkle:channel>cmux-next</sparkle:channel><pubDate>{stamp} -0000</pubDate></item>"
               "<item><sparkle:version>4023540480102</sparkle:version><sparkle:channel>cmux-next</sparkle:channel><pubDate>not a date</pubDate></item>"
               "</channel></rss>")
        build, _ = watch.legacy_lag(NOW, odd, self.OLD)
        self.assertEqual(build, 4023540480101)

    def test_the_off_switch_stops_the_watch(self):
        # NIGHTLY_NEXT_LEGACY_IDENTITY=off stops every legacy job; nothing can catch the feed up.
        self.assertEqual(self.run_main(True, "--legacy-identity", "off"), 0)
        workflow = (Path(__file__).resolve().parents[1] / ".github/workflows/nightly-next-feed-watch.yml").read_text()
        self.assertIn("LEGACY_IDENTITY: ${{ vars.NIGHTLY_NEXT_LEGACY_IDENTITY == 'off' && 'off' || 'on' }}", workflow)
        self.assertIn('--legacy-identity "$LEGACY_IDENTITY"', workflow)

    def test_behind_means_more_than_the_limit(self):
        self.assertIsNone(self.lag(next_xml=feed((4023540480101, 15, "cmux-next"), (4020374816001, 450, "cmux-next")))[0])
        self.assertIsNotNone(self.lag(next_xml=feed((4023540480101, 16, "cmux-next"), (4020374816001, 450, "cmux-next")))[0])

    def test_the_watch_may_rerun_jobs(self):
        workflow = (Path(__file__).resolve().parents[1] / ".github/workflows/nightly-next-feed-watch.yml").read_text()
        self.assertIn("actions: write", workflow)

    def test_watches_both_next_appcast_paths(self):
        """The shipped app polls the bare path; `/next/` is the channel path."""
        self.assertEqual(set(watch.NEXT_FEED_URLS), {
            "https://files-next.cmux.com/nightly-next/appcast-arm64.xml",
            "https://files-next.cmux.com/nightly-next/next/appcast-arm64.xml",
        })

    def test_freshness_is_the_older_of_the_two_feeds(self):
        """On 2026-10-26 the bare feed was two hours ahead of `/next/`; a build
        that reaches one path and not the other still leaves users behind."""
        ahead, behind = NOW - dt.timedelta(minutes=5), NOW - dt.timedelta(hours=2)
        with unittest.mock.patch.object(watch, "read_feed", {"a": ahead, "b": behind}.get):
            self.assertEqual(watch.read_feeds(["a", "b"]), (behind, []))
            self.assertEqual(watch.read_feeds(["b", "a"]), (behind, []))

    def test_a_zoneless_feed_date_is_read_as_utc(self):
        """A pubDate with no zone used to blow up `now - feed` as naive vs aware."""
        feed = "<rss><pubDate>Mon, 26 Oct 2026 01:16:50 -0000</pubDate>" \
               "<pubDate>Sun, 25 Oct 2026 23:14:49 +0000</pubDate></rss>"
        # RFC 2822 "-0000" means "zone unknown", and Python returns it naive.
        newest = watch.newest_item(feed)
        self.assertEqual(newest.tzinfo, dt.timezone.utc)
        self.assertEqual(newest.isoformat(), "2026-10-26T01:16:50+00:00")
        self.assertIsInstance((NOW - newest).total_seconds(), float)  # no naive/aware TypeError
        self.assertEqual(watch.as_utc(dt.datetime(2026, 10, 26, 1, 0)).tzinfo, dt.timezone.utc)

    def test_one_malformed_item_never_hides_the_rest_of_a_feed(self):
        feed = "<rss><pubDate>not a date</pubDate><pubDate>Sun, 25 Oct 2026 23:14:49 +0000</pubDate></rss>"
        self.assertEqual(watch.newest_item(feed).isoformat(), "2026-10-25T23:14:49+00:00")
        self.assertIsNone(watch.newest_item("<rss><pubDate>not a date</pubDate></rss>"))

    def test_a_feed_whose_dates_are_malformed_is_a_feed_fault_not_a_crash(self):
        def read(url):
            raise ValueError("unparseable pubDate")
        with unittest.mock.patch.object(watch, "read_feed", read):
            newest, missing = watch.read_feeds(["bad"])
        self.assertIsNone(newest)
        self.assertEqual(missing, ["bad: unparseable pubDate"])

    def test_an_unreadable_feed_is_named_and_never_hides_the_others(self):
        def read(url):
            if url == "gone":
                raise urllib.error.HTTPError(url, 404, "Not Found", {}, None)
            return None if url == "empty" else NEWEST
        with unittest.mock.patch.object(watch, "read_feed", read):
            newest, missing = watch.read_feeds(["gone", "empty", "ok"])
        self.assertEqual(newest, NEWEST)
        self.assertEqual(len(missing), 2)
        self.assertTrue(missing[0].startswith("gone: "), missing)
        self.assertEqual(missing[1], "empty: no dated item")
        self.assertEqual(watch.read_feeds([]), (None, []))


class StarvationGuardTests(unittest.TestCase):
    """Past 25 minutes without a publication the guard builds the current tip.

    It never cancels anything: a newer tip builds alongside a running build.
    An active run holds it back only when that run could already be carrying
    the tip, so a build stuck on an old commit no longer freezes the feed
    (2026-10-26: nightly-next runs created 03:27Z, 04:18Z and 04:23Z kept the
    guard quiet while the tip ran four hours ahead of the feed).
    """

    TIP = "f" * 40
    LANDED = NOW - dt.timedelta(minutes=10)

    class Gh(watch.GitHub):
        def __init__(self, outer, runs, tip=None, landed=...):
            super().__init__("o/r", "t", dry_run=False)
            self._runs, self.dispatched = runs, []
            self._tip = outer.TIP if tip is None else tip
            self._landed = outer.LANDED if landed is ... else landed

        def ref_commit(self, branch):
            return self._tip, self._landed

        def ref_sha(self, branch):
            return self._tip

        def recent_runs(self, workflow, branch=None, now=None):
            return list(self._runs)

        def dispatch(self, workflow, ref, inputs=None):
            self.dispatched.append((workflow, ref, inputs))

    def guard(self, gh, feed_age_minutes=90.0, published_sha=""):
        return watch.starvation_dispatch(
            gh, NOW, feed=NOW - dt.timedelta(minutes=feed_age_minutes),
            published_sha=published_sha, branch="feat-cmux-next",
            workflow="nightly-next-tick.yml", ref="main")

    def active(self, run_id, created_hours_ago, head_sha=None):
        return {"id": run_id, "status": "in_progress", "created_at": at(created_hours_ago),
                "head_sha": head_sha or f"{run_id:040d}",
                "html_url": f"https://github.com/o/r/actions/runs/{run_id}"}

    def test_an_unreadable_feed_is_unknown_not_fresh(self):
        """Saying "fresh" is how a 404 on the appcast stood the guard down."""
        gh = self.Gh(self, [])
        self.assertEqual(
            watch.starvation_dispatch(gh, NOW, feed=None, published_sha="", branch="main",
                                      workflow="nightly.yml", ref="main"),
            "feed unknown, nothing dispatched")
        self.assertEqual(gh.dispatched, [])

    def test_a_fresh_feed_dispatches_nothing(self):
        gh = self.Gh(self, [])
        self.assertEqual(self.guard(gh, feed_age_minutes=24.0), "fresh")
        self.assertEqual(gh.dispatched, [])

    def test_a_quiet_branch_dispatches_nothing(self):
        gh = self.Gh(self, [])
        self.assertTrue(self.guard(gh, published_sha=self.TIP).startswith("unchanged"))
        self.assertEqual(gh.dispatched, [])

    def test_a_published_tip_reports_its_feed_age_without_diagnosing_it(self):
        """A build cannot fix this case: the promotion ignores a request that
        does not move the branch forward, and the alarm does not raise it,
        because no push is waiting. So the run names it instead of reporting a
        bare "unchanged" -- but it reports the age, it does not call the feed
        behind. On a branch quiet for two hours an old newest item is exactly
        what a correct feed looks like, and this check cannot tell that from a
        publication that never reached a path.
        """
        gh = self.Gh(self, [])
        feed = NOW - dt.timedelta(minutes=90)
        self.assertEqual(self.guard(gh, published_sha=self.TIP),
                         f"unchanged: the tip is published, feed newest {feed.isoformat()}")
        # A feed published ten minutes after the tip landed is current, and a
        # quiet hour later it must not be described any differently.
        current = watch.starvation_dispatch(
            self.Gh(self, []), NOW, feed=NOW - dt.timedelta(minutes=26), published_sha=self.TIP,
            branch="feat-cmux-next", workflow="nightly-next-tick.yml", ref="main")
        self.assertEqual(current,
                         f"unchanged: the tip is published, "
                         f"feed newest {(NOW - dt.timedelta(minutes=26)).isoformat()}")
        self.assertNotIn("behind", current)
        unreadable = watch.starvation_dispatch(
            self.Gh(self, []), NOW, feed=None, published_sha=self.TIP, branch="feat-cmux-next",
            workflow="nightly-next-tick.yml", ref="main", feed_unknown=True)
        self.assertEqual(unreadable, "unchanged: the tip is published and its feed could not be read")
        self.assertEqual(gh.dispatched, [])

    def test_a_stale_feed_with_no_active_run_builds_the_tip(self):
        gh = self.Gh(self, [])
        self.assertEqual(self.guard(gh), f"dispatched nightly-next-tick.yml for {self.TIP}")
        self.assertEqual(gh.dispatched, [("nightly-next-tick.yml", "main", None)])

    def test_a_run_that_started_before_the_tip_landed_never_blocks_it(self):
        """The 2026-10-26 outage: three runs stuck on a commit hours behind."""
        gh = self.Gh(self, [self.active(1, 2.0), self.active(2, 1.5), self.active(3, 1.0)])
        self.assertEqual(self.guard(gh), f"dispatched nightly-next-tick.yml for {self.TIP}")
        self.assertEqual(len(gh.dispatched), 1)

    def test_a_run_that_started_after_the_tip_landed_blocks(self):
        gh = self.Gh(self, [self.active(4, 0.05)])
        self.assertEqual(self.guard(gh), "running https://github.com/o/r/actions/runs/4")
        self.assertEqual(gh.dispatched, [])

    def test_the_tips_own_run_blocks_however_old_it_looks(self):
        gh = self.Gh(self, [self.active(5, 9.0, head_sha=self.TIP.upper())])
        self.assertEqual(self.guard(gh), "running https://github.com/o/r/actions/runs/5")
        self.assertEqual(gh.dispatched, [])

    def test_an_unreadable_tip_time_never_doubles_a_build(self):
        gh = self.Gh(self, [self.active(6, 9.0)], landed=None)
        self.assertEqual(self.guard(gh), "running https://github.com/o/r/actions/runs/6")
        self.assertEqual(gh.dispatched, [])

    def test_every_active_status_still_blocks(self):
        """One unfiltered page keeps ACTIVE's `pending` and `requested`, which a
        status-filtered read would have dropped."""
        for status in sorted(watch.ACTIVE):
            with self.subTest(status=status):
                live = dict(self.active(8, 0.05), status=status)
                self.assertEqual(self.guard(self.Gh(self, [live])),
                                 "running https://github.com/o/r/actions/runs/8")

    def test_a_completed_run_never_blocks(self):
        done = dict(self.active(7, 0.05), status="completed")
        gh = self.Gh(self, [done])
        self.assertEqual(self.guard(gh), f"dispatched nightly-next-tick.yml for {self.TIP}")

    def test_the_dispatched_commit_is_the_one_judged_stale(self):
        gh = self.Gh(self, [])
        watch.starvation_dispatch(
            gh, NOW, feed=NOW - dt.timedelta(minutes=90), published_sha="",
            branch="feat-cmux-next", workflow="nightly-next-tick.yml", ref="main",
            tip_input="sha")
        self.assertEqual(gh.dispatched, [("nightly-next-tick.yml", "main", {"sha": self.TIP})])

    def test_a_fresh_feed_costs_no_api_call(self):
        """The guard must stay affordable when the REST budget is nearly spent."""
        class NoCalls(watch.GitHub):
            def call(self, *_a, **_k):
                raise AssertionError("a fresh feed must not call the API")
        self.assertEqual(self.guard(NoCalls("o/r", "t", False), feed_age_minutes=24.0), "fresh")

    def test_a_feed_path_we_could_not_read_is_not_evidence_of_freshness(self):
        """Usually a path the publish step never wrote, which a build does fix."""
        gh = self.Gh(self, [])
        self.assertEqual(
            watch.starvation_dispatch(gh, NOW, feed=NOW, published_sha="", branch="feat-cmux-next",
                                      workflow="nightly-next-tick.yml", ref="main", feed_unknown=True),
            f"dispatched nightly-next-tick.yml for {self.TIP}")
        # Still bounded: a branch that has not moved past the published commit
        # dispatches nothing, however unreadable its feed is.
        quiet = self.Gh(self, [])
        self.assertEqual(
            watch.starvation_dispatch(quiet, NOW, feed=None, published_sha=self.TIP,
                                      branch="feat-cmux-next", workflow="nightly-next-tick.yml",
                                      ref="main", feed_unknown=True),
            "unchanged: the tip is published and its feed could not be read")
        self.assertEqual(quiet.dispatched, [])

    def test_the_guard_never_cancels_a_run(self):
        """Leo, 2026-10-24: a newer tip builds alongside, it never evicts."""
        self.assertNotIn("/cancel", SCRIPT.read_text())

    def test_the_trigger_is_twenty_five_minutes(self):
        """25 minutes to act, so the 30-minute ceiling is never breached."""
        import inspect
        self.assertEqual(inspect.signature(watch.starvation_dispatch).parameters["minutes"].default, 25.0)


class ActiveRunReadTests(unittest.TestCase):
    """A stuck run must be found even when newer runs have buried it.

    One page of 100 would have missed a run displaced by newer completed ones,
    which is exactly the run that holds the feed back.
    """

    class Paged(watch.GitHub):
        def __init__(self, pages):
            super().__init__("o/r", "t", dry_run=True)
            self.pages, self.asked = pages, []

        def call(self, method, path, body=None):
            page = int(urllib.parse.parse_qs(path.split("?", 1)[1])["page"][0])
            self.asked.append(page)
            return {"workflow_runs": self.pages[page - 1] if page <= len(self.pages) else []}

    def page_of(self, count, hours_ago):
        return [{"id": i, "created_at": at(hours_ago), "status": "completed"} for i in range(count)]

    def test_it_pages_past_a_full_page_of_recent_runs(self):
        stuck = {"id": 999, "created_at": at(2.0), "status": "queued"}
        gh = self.Paged([self.page_of(100, 0.5), [stuck] + self.page_of(99, 3.0)])
        runs = gh.recent_runs("nightly.yml", "nightly-next", NOW)
        self.assertIn(stuck, runs)
        # Page 2 is still inside the lookback, so it asks once more and the
        # empty page three ends the walk.
        self.assertEqual(gh.asked, [1, 2, 3])

    def test_it_stops_once_a_page_is_older_than_anything_can_still_be_running(self):
        gh = self.Paged([self.page_of(100, 9.0), self.page_of(100, 20.0)])
        gh.recent_runs("nightly.yml", "nightly-next", NOW)
        self.assertEqual(gh.asked, [1], "a page older than the lookback ends the walk")

    def test_a_short_page_ends_the_walk(self):
        gh = self.Paged([self.page_of(3, 0.5)])
        self.assertEqual(len(gh.recent_runs("nightly.yml", "nightly-next", NOW)), 3)
        self.assertEqual(gh.asked, [1])


class HealBeforeAlarmTests(unittest.TestCase):
    """Every scheduled run from 01:35Z to 04:52Z on 2026-10-26 hit a 403 in the
    alarm path and returned before the guards ran, so the feed sat four hours
    stale while the schedule stayed green. The guards now run first, and each
    inside its own boundary."""

    def run_main(self, gh_call):
        seen = []
        with unittest.mock.patch.object(watch, "read_feed", lambda url: NEWEST), \
                unittest.mock.patch.object(watch, "fetch_feed", lambda url: ""), \
                unittest.mock.patch.object(watch.GitHub, "call", gh_call), \
                unittest.mock.patch.object(
                    watch, "starvation_dispatch",
                    lambda *a, **k: seen.append(k.get("branch")) or f"dispatched for {k.get('branch')}"), \
                unittest.mock.patch.dict("os.environ", {"GH_TOKEN": "t"}):
            return watch.main(["--repo", "o/r", "--dry-run"]), seen

    def test_a_rate_limited_alarm_still_runs_both_guards(self):
        def forbidden(self, method, path, body=None):
            raise urllib.error.HTTPError("u", 403, "rate limit exceeded", {}, None)
        code, seen = self.run_main(forbidden)
        self.assertEqual(code, 0)
        self.assertEqual(seen, ["feat-cmux-next", "main"])

    def test_one_failing_guard_never_skips_the_other(self):
        calls = []

        def guard(*_args, **kwargs):
            calls.append(kwargs.get("branch"))
            if kwargs.get("branch") == "feat-cmux-next":
                raise urllib.error.HTTPError("u", 403, "Forbidden", {}, None)
            return "dispatched"

        def forbidden(self, method, path, body=None):
            raise urllib.error.HTTPError("u", 403, "Forbidden", {}, None)
        with unittest.mock.patch.object(watch, "read_feed", lambda url: NEWEST), \
                unittest.mock.patch.object(watch, "fetch_feed", lambda url: ""), \
                unittest.mock.patch.object(watch.GitHub, "call", forbidden), \
                unittest.mock.patch.object(watch, "starvation_dispatch", guard), \
                unittest.mock.patch.dict("os.environ", {"GH_TOKEN": "t"}):
            self.assertEqual(watch.main(["--repo", "o/r", "--dry-run"]), 0)
        self.assertEqual(calls, ["feat-cmux-next", "main"])

    def test_a_release_read_that_is_not_an_oserror_still_leaves_a_guard_running(self):
        """`published_commit*` swallow OSError, so a 403 was survivable, but the
        read sat outside every boundary: the live `IncompleteRead` seen on
        2026-10-26 is not an OSError and would have taken both guards with it."""
        seen = []
        with unittest.mock.patch.object(watch, "read_feed", lambda url: NEWEST), \
                unittest.mock.patch.object(watch, "fetch_feed", lambda url: ""), \
                unittest.mock.patch.object(
                    watch, "published_commit",
                    lambda gh: (_ for _ in ()).throw(http.client.IncompleteRead(b"half"))), \
                unittest.mock.patch.object(watch, "published_commit_for_release", lambda gh, tag: ""), \
                unittest.mock.patch.object(
                    watch, "starvation_dispatch",
                    lambda *a, **k: seen.append(k.get("branch")) or "dispatched"), \
                unittest.mock.patch.dict("os.environ", {"GH_TOKEN": "t"}):
            self.assertEqual(watch.main(["--repo", "o/r", "--dry-run"]), 0)
        # The NEXT guard cannot run without its marker, but classic still does.
        self.assertEqual(seen, ["main"])

    def test_each_release_marker_is_read_once(self):
        """The guards and the alarm share one read apiece, not three."""
        reads = []
        with unittest.mock.patch.object(watch, "read_feed", lambda url: NEWEST), \
                unittest.mock.patch.object(watch, "fetch_feed", lambda url: ""), \
                unittest.mock.patch.object(
                    watch, "published_commit", lambda gh: reads.append("next") or ""), \
                unittest.mock.patch.object(
                    watch, "published_commit_for_release", lambda gh, tag: reads.append(tag) or ""), \
                unittest.mock.patch.object(watch, "starvation_dispatch", lambda *a, **k: "stubbed"), \
                unittest.mock.patch.object(watch, "oldest_waiting_push", lambda gh, sha, newest: None), \
                unittest.mock.patch.object(watch.GitHub, "runs", lambda self, *a, **k: []), \
                unittest.mock.patch.object(watch, "sync_issue", lambda *a: "synced"), \
                unittest.mock.patch.dict("os.environ", {"GH_TOKEN": "t"}):
            watch.main(["--repo", "o/r", "--dry-run"])
        self.assertEqual(reads, ["next", "nightly"])

    def test_the_classic_guard_runs_when_the_next_feeds_are_unreadable(self):
        """Different feeds fail differently; one must not take the other down."""
        seen = []

        def read(url):
            if url == watch.CLASSIC_FEED_URL:
                return NEWEST
            raise urllib.error.HTTPError(url, 404, "Not Found", {}, None)

        def forbidden(self, method, path, body=None):
            raise urllib.error.HTTPError("u", 403, "Forbidden", {}, None)
        with unittest.mock.patch.object(watch, "read_feed", read), \
                unittest.mock.patch.object(watch, "fetch_feed", lambda url: ""), \
                unittest.mock.patch.object(watch.GitHub, "call", forbidden), \
                unittest.mock.patch.object(
                    watch, "starvation_dispatch",
                    lambda *a, **k: seen.append(k.get("branch")) or "ok"), \
                unittest.mock.patch.dict("os.environ", {"GH_TOKEN": "t"}):
            self.assertEqual(watch.main(["--repo", "o/r", "--dry-run"]), 0)
        self.assertEqual(seen, ["feat-cmux-next", "main"])

    def test_heal_reports_any_failure_without_raising(self):
        """A guard runs before the alarm, so nothing it raises may stop the check."""
        for error in (urllib.error.HTTPError("u", 403, "Forbidden", {}, None),
                      KeyError("workflow_runs"), ValueError("not json"), TypeError("none")):
            with self.subTest(error=type(error).__name__):
                def boom(err=error):
                    raise err
                watch.heal("next", boom)  # must not raise
        self.assertIsNone(watch.heal("next", lambda: "dispatched"))


class FakeGitHub:
    def __init__(self, issues):
        self.issues = issues
        self.calls = []

    def call(self, method, path, body=None):
        if method == "GET":
            return self.issues
        self.calls.append((method, path, (body or {}).get("state")))
        return {}


class IssueTests(unittest.TestCase):
    def stale(self):
        return assess([run(1, 5)], nightly=[run(7, 2, conclusion="failure")])

    def test_opens_one_issue(self):
        gh = FakeGitHub([])
        watch.sync_issue(gh, self.stale(), "body", 4.0, "url")
        self.assertEqual(gh.calls, [("POST", "/issues", None)])

    def test_keeps_the_oldest_and_comments_only_on_a_new_reason(self):
        stage = self.stale()
        gh = FakeGitHub([{"number": 9, "body": ""}, {"number": 7, "body": f"x\n\n{stage.reason}"}])
        watch.sync_issue(gh, stage, "body", 4.0, "url")
        self.assertEqual(gh.calls, [("PATCH", "/issues/7", None), ("POST", "/issues/9/comments", None), ("PATCH", "/issues/9", "closed")])
        gh = FakeGitHub([{"number": 7, "body": "an older reason"}])
        watch.sync_issue(gh, stage, "body", 4.0, "url")
        self.assertEqual(gh.calls, [("PATCH", "/issues/7", None), ("POST", "/issues/7/comments", None)])

    def test_closes_when_the_feed_catches_up(self):
        gh = FakeGitHub([{"number": 7, "body": ""}])
        watch.sync_issue(gh, assess([]), "body", 4.0, "url")
        self.assertEqual(gh.calls, [("POST", "/issues/7/comments", None), ("PATCH", "/issues/7", "closed")])

    def test_body_names_the_last_published_commit(self):
        stage = self.stale()
        body = watch.issue_body(stage, NEWEST, NOW, "a" * 40, 4.0, "url")
        self.assertIn("a" * 40, body)
        self.assertIn(stage.reason, body)
        self.assertIn("30.0 hours old", body)
        self.assertEqual(watch.PUBLISHED_MARKER.search("<!-- cmux-published-sha: " + "b" * 40 + " -->").group(1), "b" * 40)


class ContinuationTests(unittest.TestCase):
    """The schedule also publishes a build Apple accepted after its run stopped
    waiting. Without it, an accepted build waited for the next green
    feat-cmux-next compile, so a quiet branch held the feed."""

    ROOT = Path(__file__).resolve().parents[1]

    def test_the_schedule_requests_a_continuation(self):
        workflow = (self.ROOT / ".github/workflows/nightly-next-feed-watch.yml").read_text()
        self.assertIn("actions: write", workflow)
        call = 'run: scripts/cmux-next/continue-nightly-next.sh --repo "$REPOSITORY"'
        self.assertIn(call, workflow)
        step = workflow[:workflow.index(call)].rsplit("- name:", 1)[1]
        self.assertIn("continue-on-error: true", step)

    def test_the_continuation_script_passes_its_own_test(self):
        import subprocess
        test = self.ROOT / "scripts/cmux-next/tests/continue-nightly-next.test.sh"
        self.assertTrue(test.is_file(), test)
        result = subprocess.run(["bash", str(test)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


class TrainModeTests(unittest.TestCase):
    """Train run 40428446287 spent an hour on a dry run (145 cars of car
    guards) that publishes nothing, and every landing dispatched another. A
    train is started, and counts as delivering, only when NIGHTLY_NEXT_TRAIN
    is on, the switch the train itself reads."""

    WORKFLOWS = SCRIPT.parents[2] / ".github/workflows"

    def test_only_a_train_that_is_on_holds_back_the_starvation_dispatch(self):
        train = ("nightly-next-train.yml", "feat-cmux-next")
        for mode in ("on", "ON", "On"):
            self.assertIn(train, watch.next_delivery_workflows(mode), mode)
        for mode in ("", "dry-run", "off", "plan"):
            flows = watch.next_delivery_workflows(mode)
            self.assertNotIn(train, flows, mode)
            self.assertIn(("nightly.yml", "nightly-next"), flows)
            self.assertIn(("nightly-next-tick.yml", "main"), flows)

    def test_the_watch_passes_the_train_switch(self):
        workflow = (self.WORKFLOWS / "nightly-next-feed-watch.yml").read_text(encoding="utf-8")
        self.assertIn("TRAIN: ${{ vars.NIGHTLY_NEXT_TRAIN == 'on' && 'on' || 'off' }}", workflow)
        self.assertIn('--train "$TRAIN"', workflow)
        seen = []
        with unittest.mock.patch.object(watch, "read_feed", lambda url: NEWEST), \
                unittest.mock.patch.object(watch, "fetch_feed", lambda url: ""), \
                unittest.mock.patch.object(watch, "published_commit", lambda gh: ""), \
                unittest.mock.patch.object(watch, "published_commit_for_release", lambda gh, tag: ""), \
                unittest.mock.patch.object(
                    watch, "starvation_dispatch",
                    lambda *a, **k: (k.get("branch") == "feat-cmux-next" and seen.append(k["active_workflows"])) or "dispatched"), \
                unittest.mock.patch.dict("os.environ", {"GH_TOKEN": "t"}):
            watch.main(["--repo", "o/r", "--dry-run"])
            watch.main(["--repo", "o/r", "--dry-run", "--train", "on"])
        self.assertEqual(seen, [watch.next_delivery_workflows(""), watch.next_delivery_workflows("on")])

    def test_the_tick_starts_the_train_only_when_it_is_on(self):
        tick = (self.WORKFLOWS / "nightly-next-tick.yml").read_text(encoding="utf-8")
        step = tick[tick.index("- name: Start the nightly-next train"):]
        step = step[:step.index("\n      - name:")]
        self.assertIn("if: vars.NIGHTLY_NEXT_TRAIN == 'on'", step)
        self.assertIn("MODE: drive", step)
        self.assertIn("gh workflow run nightly-next-train.yml", step)
        self.assertNotIn("plan", step.split("run:", 1)[1])
        # Train off: the plain promotion still goes ahead.
        self.assertIn("if: vars.NIGHTLY_NEXT_TRAIN != 'on'", tick)


if __name__ == "__main__":
    unittest.main(verbosity=2)
