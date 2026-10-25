#!/usr/bin/env python3
"""nightly-next feed watch (scripts/ci/nightly_next_feed_watch.py, cx-npz7g).

feat-cmux-next work must reach the nightly-next feed. The nightly.yml alarm
runs only inside nightly-next push runs, so a promotion stall (red Release
compile, unpublished cmux-tui tree) never raised it. The watch runs from main
every 30 minutes and measures how long feat-cmux-next pushes have waited.
"""
from __future__ import annotations

import datetime as dt
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
                unittest.mock.patch.object(watch, "oldest_waiting_push", lambda gh, sha, newest: None), \
                unittest.mock.patch.object(watch, "assess", lambda *a, **k: stage), \
                unittest.mock.patch.object(watch.GitHub, "runs", lambda self, *a, **k: []), \
                unittest.mock.patch.object(watch, "sync_issue", lambda *a: "synced"), \
                unittest.mock.patch.dict("os.environ", {"GH_TOKEN": "t"}):
            return watch.main(["--repo", "o/r", "--dry-run"])

    def test_stale_fails_and_current_passes(self):
        self.assertEqual(self.main_with(True), 1)
        self.assertEqual(self.main_with(False), 0)
        self.assertEqual(self.main_with(False, legacy_stale=True), 1, "cmux NIGHTLY's feed behind fails the run too")

    def test_the_limit_is_three_hours(self):
        workflow = (Path(__file__).resolve().parents[1] / ".github/workflows/nightly-next-feed-watch.yml").read_text()
        self.assertIn("vars.NIGHTLY_NEXT_MAX_FEED_LAG_HOURS || '3'", workflow)
        self.assertIn("default=3.0", SCRIPT.read_text())


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

    def run_main(self, fail):
        def call(gh, method, path, body=None):
            raise urllib.error.HTTPError("u", 403, "API rate limit exceeded for installation", {}, None)
        feeds = {watch.FEED_URL: self.NEXT, watch.LEGACY_FEED_URL: self.OLD}
        with unittest.mock.patch.object(watch, "fetch_feed", lambda url: feeds.get(url, self.NEXT)), \
                unittest.mock.patch.object(watch.dt, "datetime", wraps=dt.datetime) as clock, \
                unittest.mock.patch.object(watch.GitHub, "call", call), \
                unittest.mock.patch.dict("os.environ", {"GH_TOKEN": "t"}):
            clock.now.return_value = NOW
            return watch.main(["--repo", "o/r", "--dry-run"])

    def test_an_api_error_never_turns_a_stale_feed_green(self):
        self.assertEqual(self.run_main(fail=True), 1)

    def test_the_watch_may_rerun_jobs(self):
        workflow = (Path(__file__).resolve().parents[1] / ".github/workflows/nightly-next-feed-watch.yml").read_text()
        self.assertIn("actions: write", workflow)


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


if __name__ == "__main__":
    unittest.main(verbosity=2)
