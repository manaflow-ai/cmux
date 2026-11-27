#!/usr/bin/env python3
"""nightly-next unsigned resume (scripts/ci/nightly_next_unsigned_resume.py).

main's feed watch resumes a failed nightly-next run's signing and publication
from its saved unsigned app, at most --max-resumes times per run, one resume
at a time, and only for a build newer than the feed.
"""
from __future__ import annotations

import importlib.util
from pathlib import Path
import sys
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/ci/nightly_next_unsigned_resume.py"
spec = importlib.util.spec_from_file_location("unsigned_resume", SCRIPT)
resume = importlib.util.module_from_spec(spec)
sys.modules["unsigned_resume"] = resume
spec.loader.exec_module(resume)

FEED = 4073801205901  # run 40738012059, attempt 1
NEWER, OLDER = 40740000000, 40735210057


def push(run_id, conclusion="failure", status="completed"):
    return {"id": run_id, "event": "push", "head_branch": "nightly-next", "status": status, "conclusion": conclusion,
            "display_title": "Nightly macOS build", "html_url": f"https://github.com/o/r/actions/runs/{run_id}"}


def resumed(source, attempt, run_id, status="completed"):
    return {"id": run_id, "event": "workflow_dispatch", "head_branch": "nightly-next", "status": status,
            "conclusion": "failure" if status == "completed" else None,
            "display_title": f"Resume nightly-next run {source} attempt {attempt}",
            "html_url": f"https://github.com/o/r/actions/runs/{run_id}"}


def jobs(app="success", helper="success", app_attempt=1, helper_attempt=1):
    return [{"name": "decide", "conclusion": "success", "run_attempt": 2},
            {"name": "build-nightly-app", "conclusion": app, "run_attempt": app_attempt},
            {"name": "build-nightly-ghostty-cli-helper", "conclusion": helper, "run_attempt": helper_attempt},
            {"name": "signer-dmg", "conclusion": "failure", "run_attempt": 2}]


KEPT = [{"name": name, "expired": False} for name in resume.UNSIGNED_ARTIFACTS]


class FakeGitHub:
    def __init__(self, jobs_by_run=None, artifacts_by_run=None):
        self.jobs_by_run = jobs_by_run or {}
        self.artifacts_by_run = artifacts_by_run or {}
        self.dispatches = []
        self.reads = []

    def call(self, method, path, body=None):
        run_id = int(path.split("/")[3])
        if "/jobs?" in path:
            self.reads.append(("jobs", run_id))
            return {"jobs": self.jobs_by_run.get(run_id, jobs())}
        self.reads.append((method, path))
        return {"artifacts": self.artifacts_by_run.get(run_id, KEPT)}

    def dispatch(self, workflow, ref, inputs=None):
        self.dispatches.append((workflow, ref, inputs))


def decide(gh, runs, max_resumes=2, names=True):
    return resume.decide(gh, FEED, runs, max_resumes, lambda: names)


class DecideTests(unittest.TestCase):
    def test_resumes_the_newest_failed_run_from_its_producer_attempt(self):
        gh = FakeGitHub({NEWER: jobs(app_attempt=1, helper_attempt=1)})
        message = decide(gh, [push(NEWER), push(OLDER)])
        self.assertEqual(gh.dispatches, [("nightly.yml", "nightly-next",
                                          {"nightly_next_unsigned_run": str(NEWER), "nightly_next_unsigned_attempt": "1"})])
        self.assertIn("resume 1 of 2", message)

    def test_a_superseded_build_is_never_resumed(self):
        # publish-nightly refuses it anyway: "build 4073521005701 is not above 4073801205901".
        gh = FakeGitHub()
        self.assertIn("nothing to resume", decide(gh, [push(OLDER)]))
        self.assertEqual(gh.dispatches, [])
        self.assertEqual(gh.reads, [], "a run older than the feed's build costs no reads")

    def test_a_failed_compile_is_left_to_the_next_build(self):
        gh = FakeGitHub({NEWER: jobs(app="failure")})
        self.assertIn("build-nightly-app did not succeed", decide(gh, [push(NEWER)]))
        self.assertEqual(gh.dispatches, [])

    def test_the_producer_attempt_is_the_one_that_succeeded_not_the_newest(self):
        # Attempt 1 compiled; attempt 2 re-ran the picker and its dependents, and the compile failed there.
        rerun = jobs() + [{"name": "build-nightly-app", "conclusion": "failure", "run_attempt": 2},
                          {"name": "build-nightly-ghostty-cli-helper", "conclusion": "success", "run_attempt": 2}]
        gh = FakeGitHub({NEWER: rerun})
        decide(gh, [push(NEWER)])
        self.assertEqual(gh.dispatches[0][2]["nightly_next_unsigned_attempt"], "1")

    def test_producers_from_different_attempts_are_not_resumed(self):
        gh = FakeGitHub({NEWER: jobs(app_attempt=2, helper_attempt=1)})
        self.assertIn("different attempts", decide(gh, [push(NEWER)]))
        self.assertEqual(gh.dispatches, [])

    def test_a_rerun_producer_attempt_names_its_own_build(self):
        # A run whose compile was re-run in attempt 2: build NEWER*100+2.
        gh = FakeGitHub({NEWER: jobs(app_attempt=2, helper_attempt=2)})
        decide(gh, [push(NEWER)])
        self.assertEqual(gh.dispatches[0][2]["nightly_next_unsigned_attempt"], "2")

    def test_cancelled_and_successful_runs_are_not_resumed(self):
        gh = FakeGitHub()
        decide(gh, [push(NEWER, "cancelled"), push(NEWER + 1, "success"), push(NEWER + 2, None, "in_progress"),
                    push(NEWER + 3, "timed_out")])  # the validator refuses a timed_out source
        self.assertEqual(gh.dispatches, [])

    def test_one_resume_at_a_time(self):
        gh = FakeGitHub()
        message = decide(gh, [resumed(OLDER, 1, NEWER + 5, status="in_progress"), push(NEWER)])
        self.assertIn("still running", message)
        self.assertEqual(gh.dispatches, [])

    def test_capped_resumes_per_run_then_an_older_run_is_tried(self):
        older_but_newer_than_feed = NEWER - 1
        gh = FakeGitHub()
        runs = [resumed(NEWER, 1, NEWER + 7), resumed(NEWER, 1, NEWER + 6), push(NEWER), push(older_but_newer_than_feed)]
        message = decide(gh, runs)
        self.assertIn(f"run {NEWER}: resumed 2 times already", message)
        self.assertEqual(gh.dispatches[0][2]["nightly_next_unsigned_run"], str(older_but_newer_than_feed))

    def test_a_resume_of_another_attempt_does_not_count(self):
        gh = FakeGitHub()
        decide(gh, [resumed(NEWER, 2, NEWER + 7), resumed(NEWER, 2, NEWER + 6), push(NEWER)])
        self.assertEqual(len(gh.dispatches), 1)

    def test_expired_unsigned_app_is_not_resumed(self):
        artifacts = [dict(item, expired=item["name"] == "cmux-nightly-unsigned-app") for item in KEPT]
        gh = FakeGitHub(artifacts_by_run={NEWER: artifacts})
        self.assertIn("cmux-nightly-unsigned-app expired", decide(gh, [push(NEWER)]))
        self.assertEqual(gh.dispatches, [])

    def test_a_pending_notarization_is_left_to_the_continuation(self):
        artifacts = KEPT + [{"name": "cmux-nightly-notarization-recovery-abc", "expired": False}]
        gh = FakeGitHub(artifacts_by_run={NEWER: artifacts})
        self.assertIn("recovery artifact", decide(gh, [push(NEWER)]))
        self.assertEqual(gh.dispatches, [])

    def test_nothing_dispatches_until_the_ref_titles_resumes(self):
        gh = FakeGitHub()
        self.assertIn("does not title resume runs yet", decide(gh, [push(NEWER)], names=False))
        self.assertEqual(gh.dispatches, [])

    def test_zero_turns_it_off(self):
        gh = FakeGitHub()
        self.assertIn("off", decide(gh, [push(NEWER)], max_resumes=0))
        self.assertEqual((gh.dispatches, gh.reads), ([], []))

    def test_a_valid_run_behind_newer_failed_compiles_is_still_found(self):
        gh = FakeGitHub({NEWER - i: jobs(app="failure") for i in range(3)})
        decide(gh, [push(NEWER - i) for i in range(4)])
        self.assertEqual(gh.dispatches[0][2]["nightly_next_unsigned_run"], str(NEWER - 3))

    def test_reads_are_bounded(self):
        many = resume.CANDIDATES_READ + 10
        gh = FakeGitHub({NEWER - i: jobs(app="failure") for i in range(many)})
        decide(gh, [push(NEWER - i) for i in range(many)])
        self.assertEqual(len([read for read in gh.reads if read[0] == "jobs"]), resume.CANDIDATES_READ)


class ListingTests(unittest.TestCase):
    def test_resumes_are_counted_over_the_whole_unsigned_app_lifetime(self):
        import datetime as dt
        calls = []

        class Lister:
            def call(self, method, path, body=None):
                calls.append(path)
                return {"workflow_runs": []}

        resume.runs_to_judge(Lister(), dt.datetime(2026, 10, 28, 22, 0, tzinfo=dt.timezone.utc))
        dispatch = [c for c in calls if "event=workflow_dispatch" in c]
        self.assertEqual(len(dispatch), 1)
        self.assertIn("created=%3E%3D2026-10-27T20%3A00%3A00Z", dispatch[0])
        self.assertTrue(any("event=push" in c for c in calls))


class StarvationTests(unittest.TestCase):
    def test_a_running_resume_never_holds_back_a_build_of_the_newer_tip(self):
        watch = sys.modules["nightly_next_feed_watch"]
        tip = "a" * 40
        running = resumed(OLDER, 1, NEWER, status="in_progress")
        running.update(head_sha=tip, created_at="2026-10-28T20:00:00Z")
        self.assertFalse(watch.carries_tip(running, tip, None))
        self.assertTrue(watch.carries_tip(dict(push(NEWER), head_sha=tip), tip, None))

    def test_a_running_resume_never_carries_the_next_tip(self):
        # cmux NEXT judges by head_sha; a resume runs on nightly-next's head, which may hold the tip.
        watch = sys.modules["nightly_next_feed_watch"]
        tip = "a" * 40
        running = resumed(OLDER, 1, NEWER, status="in_progress")
        running.update(head_sha=tip)
        self.assertFalse(watch.next_carries_tip(None, running, tip))
        self.assertTrue(watch.next_carries_tip(None, dict(push(NEWER), head_sha=tip), tip))


class FeedTests(unittest.TestCase):
    def test_feed_newest_build_reads_the_nightly_ring(self):
        item = ("<item><sparkle:channel>cmux-next</sparkle:channel><sparkle:version>{}</sparkle:version>"
                "<pubDate>Wed, 28 Oct 2026 19:00:00 +0000</pubDate></item>")
        xml = "<rss><channel>" + item.format(4073521005701) + item.format(FEED) + "</channel></rss>"
        self.assertEqual(resume.feed_newest_build(xml), FEED)
        self.assertIsNone(resume.feed_newest_build("<rss></rss>"))


class WorkflowTests(unittest.TestCase):
    def test_the_feed_watch_runs_it_without_failing_the_watch(self):
        workflow = (Path(__file__).resolve().parents[1] / ".github/workflows/nightly-next-feed-watch.yml").read_text()
        step = workflow.split("- name: Resume a failed nightly-next signing from its saved unsigned app", 1)[1].split("- name:", 1)[0]
        self.assertIn("continue-on-error: true", step)
        self.assertIn("scripts/ci/nightly_next_unsigned_resume.py", step)
        self.assertNotIn("cancel", step.split("run:", 1)[1])

if __name__ == "__main__":
    unittest.main()
