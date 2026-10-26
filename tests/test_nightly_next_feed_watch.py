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
        original = watch.GitHub.call, watch.read_feed
        watch.GitHub.call, watch.read_feed = boom, lambda url: NEWEST
        try:
            with unittest.mock.patch.dict("os.environ", {"GH_TOKEN": "t"}):
                self.assertEqual(watch.main(["--repo", "o/r", "--dry-run"]), 0)
        finally:
            watch.GitHub.call, watch.read_feed = original


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

    def main_with(self, stale):
        stage = watch.Stage(stale, 5.0 if stale else 0.5, NOW - dt.timedelta(hours=5), "Nothing was promoted.")
        with unittest.mock.patch.object(watch, "read_feed", lambda url: NEWEST), \
                unittest.mock.patch.object(watch, "published_commit", lambda gh: ""), \
                unittest.mock.patch.object(watch, "oldest_waiting_push", lambda gh, sha, newest: None), \
                unittest.mock.patch.object(watch, "assess", lambda *a, **k: stage), \
                unittest.mock.patch.object(watch.GitHub, "runs", lambda self, *a, **k: []), \
                unittest.mock.patch.object(watch, "sync_issue", lambda *a: "synced"), \
                unittest.mock.patch.object(watch, "starvation_dispatch", lambda *a, **k: "stubbed"), \
                unittest.mock.patch.dict("os.environ", {"GH_TOKEN": "t"}):
            return watch.main(["--repo", "o/r", "--dry-run"])

    def test_stale_fails_and_current_passes(self):
        self.assertEqual(self.main_with(True), 1)
        self.assertEqual(self.main_with(False), 0)

    def test_the_limit_is_three_hours(self):
        workflow = (Path(__file__).resolve().parents[1] / ".github/workflows/nightly-next-feed-watch.yml").read_text()
        self.assertIn("vars.NIGHTLY_NEXT_MAX_FEED_LAG_HOURS || '3'", workflow)
        self.assertIn("default=3.0", SCRIPT.read_text())


class FeedTests(unittest.TestCase):
    def test_watches_the_cmux_next_feed(self):
        # nightly-next ships as cmux NEXT with its own feed (cx-x7hwx); the old
        # cmux NIGHTLY-identity feed is no longer written.
        self.assertEqual(watch.FEED_URL, "https://files-next.cmux.com/nightly-next/next/appcast-arm64.xml")

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

        def recent_runs(self, workflow, branch=None):
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

    def test_a_fresh_feed_dispatches_nothing(self):
        gh = self.Gh(self, [])
        self.assertEqual(self.guard(gh, feed_age_minutes=24.0), "fresh")
        self.assertEqual(gh.dispatched, [])

    def test_a_quiet_branch_dispatches_nothing(self):
        gh = self.Gh(self, [])
        self.assertEqual(self.guard(gh, published_sha=self.TIP), "unchanged")
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

    def test_the_guard_never_cancels_a_run(self):
        """Leo, 2026-10-24: a newer tip builds alongside, it never evicts."""
        self.assertNotIn("/cancel", SCRIPT.read_text())

    def test_the_trigger_is_twenty_five_minutes(self):
        """25 minutes to act, so the 30-minute ceiling is never breached."""
        import inspect
        self.assertEqual(inspect.signature(watch.starvation_dispatch).parameters["minutes"].default, 25.0)


class HealBeforeAlarmTests(unittest.TestCase):
    """Every scheduled run from 01:35Z to 04:52Z on 2026-10-26 hit a 403 in the
    alarm path and returned before the guards ran, so the feed sat four hours
    stale while the schedule stayed green. The guards now run first, and each
    inside its own boundary."""

    def run_main(self, gh_call):
        seen = []
        with unittest.mock.patch.object(watch, "read_feed", lambda url: NEWEST), \
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
                unittest.mock.patch.object(watch.GitHub, "call", forbidden), \
                unittest.mock.patch.object(watch, "starvation_dispatch", guard), \
                unittest.mock.patch.dict("os.environ", {"GH_TOKEN": "t"}):
            self.assertEqual(watch.main(["--repo", "o/r", "--dry-run"]), 0)
        self.assertEqual(calls, ["feat-cmux-next", "main"])

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


if __name__ == "__main__":
    unittest.main(verbosity=2)
