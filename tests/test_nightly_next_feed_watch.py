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
        original = watch.GitHub.call, watch.read_feed
        watch.GitHub.call, watch.read_feed = boom, lambda url: NEWEST
        try:
            with unittest.mock.patch.dict("os.environ", {"GH_TOKEN": "t"}):
                self.assertEqual(watch.main(["--repo", "o/r", "--dry-run"]), 0)
        finally:
            watch.GitHub.call, watch.read_feed = original


class FeedTests(unittest.TestCase):
    def test_watches_the_cmux_next_feed(self):
        # nightly-next ships as cmux NEXT with its own feed (cx-x7hwx); the old
        # cmux NIGHTLY-identity feed is no longer written.
        self.assertEqual(watch.FEED_URL, "https://files-next.cmux.com/nightly-next/next/appcast-arm64.xml")


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


if __name__ == "__main__":
    unittest.main(verbosity=2)
