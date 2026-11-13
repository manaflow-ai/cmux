#!/usr/bin/env python3
"""scripts/ci/nightly_speed.py: the per-nightly timing record, the budget and slow-stage check, the bisect over the
recorded runs, and the one cmuxterm-hq issue. No network: gh is a fake, git runs in a temporary repository.

The fixtures in tests/fixtures/nightly-speed are trimmed REST payloads of build 4318547490101 (push run 43185474901,
sign run 43189297315, 2026-11-12): 85.97 min merge to feed, cmux15's "Set up runner" hook held a job 12.5 min.
Run: python3 -I tests/test_nightly_speed.py (also runs in nightly-speed.yml)."""
from __future__ import annotations

import base64
import copy
import importlib.util
import json
import os
import random
import subprocess
import tempfile
import unittest
import zlib

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
FIX = os.path.join(ROOT, "tests", "fixtures", "nightly-speed")
spec = importlib.util.spec_from_file_location("nightly_speed", os.path.join(ROOT, "scripts", "ci", "nightly_speed.py"))
ns = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ns)
# tests/git_fixture_env.py, loaded by path: `python3 -I` puts no script folder on sys.path.
_gspec = importlib.util.spec_from_file_location("git_fixture_env", os.path.join(ROOT, "tests", "git_fixture_env.py"))
git_fixture_env = importlib.util.module_from_spec(_gspec)
_gspec.loader.exec_module(git_fixture_env)

LANDED = 1794472936.0  # 9dc6d10f0's committer time on feat-cmux-next


def load(name):
    with open(os.path.join(FIX, name), encoding="utf-8") as f:
        return json.load(f)


RUNS = load("runs.json")["workflow_runs"]
BY_ID = {r["id"]: r for r in RUNS}
SIGN_JOBS = load("jobs-43189297315-1.json")["jobs"]
PUSH_JOBS = load("jobs-43185474901-1.json")["jobs"]


def fixture_record():
    rec, why = ns.build_record(BY_ID[43189297315], BY_ID[43185474901], SIGN_JOBS, PUSH_JOBS, LANDED)
    assert rec, why
    return rec


def synthetic(n, mtf, stages, sha=None, hosts=None):
    """Record n with the given merge_to_feed and stages, fed n hours after a fixed start."""
    return {"build": f"b{n}", "sha": sha or f"{n:040x}", "sign_run": 1000 + n, "feed_at": f"2026-11-12T{n:02d}:00:00Z"
            if n < 24 else f"2026-11-13T{n - 24:02d}:00:00Z", "sign_created": f"2026-11-12T{n % 24:02d}:00:00Z",
            "merge_to_feed": mtf, "stages": dict(stages), "runners": {"build": "ultra1"}, "hosts": hosts or {}, "jobs": []}


class FakeGh:
    """gh issue list/edit/create and gh api, by argv; records every call."""

    def __init__(self, issues=None, api=None, fail_list=False):
        self.issues, self.api, self.fail_list, self.calls = issues or [], api or {}, fail_list, []

    def __call__(self, cmd, **kw):
        self.calls.append((cmd, kw))
        if cmd[:3] == ["gh", "issue", "list"]:
            if self.fail_list:
                return subprocess.CompletedProcess(cmd, 1, "", "HTTP 403")
            return subprocess.CompletedProcess(cmd, 0, json.dumps(self.issues), "")
        if cmd[:3] in (["gh", "issue", "edit"], ["gh", "issue", "create"]):
            self.written = kw.get("input")
            return subprocess.CompletedProcess(cmd, 0, "https://github.com/o/hq/issues/9\n", "")
        if cmd[:2] == ["gh", "api"]:
            path = cmd[2]
            for key, doc in self.api.items():
                if key in path:
                    return subprocess.CompletedProcess(cmd, 0, json.dumps(doc), "")
            return subprocess.CompletedProcess(cmd, 1, "", f"HTTP 404 {path}")
        if cmd[0] == "git":
            return subprocess.CompletedProcess(cmd, 1, "", "no git here")
        raise AssertionError(cmd)


class Record(unittest.TestCase):
    def test_fixture_stages_match_the_measurement(self):
        r = fixture_record()
        self.assertEqual(r["build"], "4318547490101")
        self.assertEqual(r["merge_to_feed"], 85.97)
        self.assertEqual(r["feed_at"], "2026-11-12T10:08:14Z")
        want = {"promote": 2.55, "a_push_wait": 0.27, "b_pre_build": 9.7, "c_build": 15.65, "c1_compile": 9.32,
                "d_build_tail": 1.37, "e_sign_wait": 7.52, "f_pre_sign": 9.38, "g_sign": 19.82, "g1_notarize": 8.18,
                "h_verify": 12.48, "i_publish": 7.23}
        self.assertEqual({k: r["stages"][k] for k in want}, want)
        self.assertEqual(r["runners"], {"build": "ultra1", "sign": "cmux15", "publish": "cmux15"})

    def test_queue_and_hook_by_host(self):
        r = fixture_record()
        jobs, queue, hook, longest = r["hosts"]["cmux15"]
        self.assertEqual(longest, 12.5, "the 12.5 min Set up runner wait of build nightly inputs")
        self.assertGreater(hook, 50)
        self.assertIn(["build nightly inputs", "cmux15", 0.03, 12.48], r["jobs"])

    def test_every_job_that_ran_is_a_stage_whatever_the_graph(self):
        r = fixture_record()
        self.assertIn("job:build-nightly-app", r["stages"])
        self.assertNotIn("job:promote-nightly-next", r["stages"], "a skipped job is no stage")
        # One job doing build, sign and publish: the named stages it lacks are left out, the feed is still found.
        one = copy.deepcopy([j for j in SIGN_JOBS if j["name"] == "publish-nightly"])
        one[0]["name"] = "ship-nightly"
        rec, why = ns.build_record(BY_ID[43189297315], BY_ID[43185474901], one, [], LANDED)
        self.assertIsNone(why)
        self.assertEqual(rec["feed_at"], "2026-11-12T10:08:14Z")
        self.assertIn("job:ship-nightly", rec["stages"])
        self.assertNotIn("c_build", rec["stages"])

    def test_no_feed_upload_is_not_a_record(self):
        rec, why = ns.build_record(BY_ID[43189297315], BY_ID[43185474901], [], PUSH_JOBS, LANDED)
        self.assertIsNone(rec)
        self.assertEqual(why, "no feed upload")

    def test_record_reads_one_list_and_two_jobs_per_new_build(self):
        gh = FakeGh(api={"workflows/nightly.yml/runs": {"workflow_runs": RUNS},
                         "runs/43189297315/attempts/1/jobs": {"jobs": SIGN_JOBS},
                         "runs/43185474901/attempts/1/jobs": {"jobs": PUSH_JOBS}})
        st = ns.record("o/r", "o/hq", 8, ".", "origin/feat-cmux-next", "t", "h", run=gh)
        self.assertEqual(st["new"], ["4318547490101"])
        self.assertEqual(sorted(st["new_unpublished"]), [43194746628, 43198322667], "the in-progress sign run waits")
        apis = [c[0][2] for c in gh.calls if c[0][:2] == ["gh", "api"]]
        self.assertEqual(len(apis), 3)
        cancelled = next(u for u in st["unpublished"] if u["sign_run"] == 43194746628)
        self.assertEqual((cancelled["conclusion"], cancelled["held_min"]), ("cancelled", 24.13))
        # No landing time from git (the fake has none): recorded, merge_to_feed unknown.
        self.assertIsNone(st["records"][0]["merge_to_feed"])
        # Again with that history in the issue: one list read, nothing new.
        body = ns.issue_body(st["records"], st["unpublished"], ".", run=gh)
        gh2 = FakeGh(issues=[{"number": 9, "title": ns.ISSUE_TITLE, "body": body}],
                     api={"workflows/nightly.yml/runs": {"workflow_runs": RUNS}})
        st2 = ns.record("o/r", "o/hq", 8, ".", "origin/feat-cmux-next", "t", "h", run=gh2)
        self.assertEqual((st2["new"], st2["new_unpublished"]), ([], []))
        self.assertEqual(len([c for c in gh2.calls if c[0][:2] == ["gh", "api"]]), 1)
        self.assertEqual(len(st2["records"]), 1)

    def test_a_job_of_one_name_in_both_runs_keeps_both_walls(self):
        r = fixture_record()
        self.assertEqual(r["stages"]["job:build-nightly-app"], 15.65, "the push run's keeps the plain key")
        self.assertEqual(r["stages"]["job:build-nightly-app (sign run)"], 4.7)
        self.assertEqual(r["stages"]["job:decide (sign run)"], 0.53)
        self.assertNotIn("job:find-nightly-next-recovery (sign run)", r["stages"], "a name only the sign run has")
        self.assertIn("job:find-nightly-next-recovery", r["stages"])
        # The diff table shows the sign run's copy when it moved.
        then = synthetic(1, 20.0, {"job:build-nightly-app (sign run)": 4.7})
        now = synthetic(2, 40.0, {"job:build-nightly-app (sign run)": 9.7})
        text = ns.render_verdict(ns.check([then, now], ".", run=FakeGh()))
        self.assertIn("| job:build-nightly-app (sign run) | 9.7 | 4.7 | +5.0 |", text)

    def test_a_name_repeated_in_one_run_is_numbered_by_start(self):
        def job(start, end):
            return {"name": "verify", "conclusion": "success", "created_at": f"2026-11-12T09:{start}Z",
                    "started_at": f"2026-11-12T09:{start}Z", "completed_at": f"2026-11-12T09:{end}Z"}
        sign = SIGN_JOBS + [job("50:00", "53:00"), job("49:00", "50:00"),
                            {**job("49:30", "59:00"), "conclusion": "skipped"}]
        rec, why = ns.build_record(BY_ID[43189297315], BY_ID[43185474901], sign, PUSH_JOBS, LANDED)
        self.assertIsNone(why)
        self.assertEqual((rec["stages"]["job:verify"], rec["stages"]["job:verify #2"]), (1.0, 3.0))
        self.assertNotIn("job:verify #3", rec["stages"], "a skipped job is no stage")

    def test_unreadable_history_and_list_say_why(self):
        st = ns.record("o/r", "o/hq", 8, ".", "x", None, None, run=FakeGh())
        self.assertIn("no cmuxterm-hq token", st["history_why"])
        self.assertIn("no run list", st["why"])
        self.assertEqual(st["records"], [])


def one_job_run(run_id=43300000001, conclusion="success", status="completed"):
    return {"id": run_id, "event": "push", "status": status, "conclusion": conclusion, "run_attempt": 1,
            "display_title": "chat: a landing", "head_branch": "nightly-next", "head_sha": "c" * 40,
            "created_at": "2026-11-13T01:00:00Z", "updated_at": "2026-11-13T01:25:00Z"}


def one_job_jobs(feed=True):
    """decide (20 s), then one job on one Mac: hook 6 s, compile 8 min, sign 30 s, notarize 9 min, upload 1 min."""
    def step(name, start, end):
        return {"name": name, "conclusion": "success", "started_at": f"2026-11-13T01:{start}Z",
                "completed_at": f"2026-11-13T01:{end}Z"}
    steps = [step(ns.HOOK_STEP, "02:00", "02:06"), step(ns.BUILD_STEP, "02:06", "10:06"),
             step("Sign the app", "10:06", "10:36"), step(ns.NOTARIZE_STEP, "10:36", "19:36"),
             step("Write the build number", "19:36", "19:40")]
    if feed:
        steps.append(step(ns.FEED_STEP, "19:40", "20:40"))
    return [{"name": "decide", "conclusion": "success", "runner_name": "cmux15-glaeda-nightly-only-3",
             "created_at": "2026-11-13T01:00:30Z", "started_at": "2026-11-13T01:00:40Z",
             "completed_at": "2026-11-13T01:01:00Z", "steps": []},
            {"name": "nightly", "conclusion": "success", "runner_name": "cmux15-glaeda",
             "created_at": "2026-11-13T01:01:00Z", "started_at": "2026-11-13T01:02:00Z",
             "completed_at": "2026-11-13T01:21:00Z", "steps": steps}]


class OneJob(unittest.TestCase):
    """Build, sign and publish in one job of the push run: no sign run names it, and it uploads the feed itself."""

    def test_a_one_job_nightly_is_recorded_from_its_push_run(self):
        gh = FakeGh(api={"workflows/nightly.yml/runs": {"workflow_runs": [one_job_run()] + RUNS},
                         "runs/43300000001/attempts/1/jobs": {"jobs": one_job_jobs()},
                         "runs/43189297315/attempts/1/jobs": {"jobs": SIGN_JOBS},
                         "runs/43185474901/attempts/1/jobs": {"jobs": PUSH_JOBS}})
        st = ns.record("o/r", "o/hq", 8, ".", "origin/feat-cmux-next", "t", "h", run=gh)
        self.assertEqual(st["new"], ["4318547490101", "4330000000101"], "the two-run build and the one-job build")
        apis = [c[0][2] for c in gh.calls if c[0][:2] == ["gh", "api"]]
        self.assertEqual(len(apis), 4, "one list, two job lists for the two-run build, one for the one-job build")
        self.assertEqual(sum("runs/43185474901/" in a for a in apis), 1,
                         "a push run its sign run names is not read as a one-job nightly as well")
        r = st["records"][-1]
        self.assertEqual((r["push_run"], r["sign_run"], r["feed_at"]), (43300000001, 43300000001, "2026-11-13T01:20:40Z"))
        self.assertEqual(r["push_to_feed"], 20.67)
        self.assertEqual(r["stages"], {"a_push_wait": 0.5, "b_pre_build": 1.5, "j_one_job": 18.67, "c1_compile": 8.0,
                                       "g1_notarize": 9.0, "step:Sign the app": 0.5,
                                       f"step:{ns.FEED_STEP}": 1.0, "job:decide": 0.33, "job:nightly": 19.0})
        self.assertEqual(r["runners"], {"build": "cmux15", "publish": "cmux15"})
        self.assertEqual(r["hosts"]["cmux15"][:3], [2, 1.17, 0.1])
        # Judged like any record: the budget, and its stages against their own trailing medians.
        self.assertIn("j_one_job", ns.TOP_STAGES)
        # Again with that history in the issue: one list read, nothing new.
        body = ns.issue_body(st["records"], st["unpublished"], ".", run=gh)
        gh2 = FakeGh(issues=[{"number": 9, "title": ns.ISSUE_TITLE, "body": body}],
                     api={"workflows/nightly.yml/runs": {"workflow_runs": [one_job_run()] + RUNS}})
        st2 = ns.record("o/r", "o/hq", 8, ".", "origin/feat-cmux-next", "t", "h", run=gh2)
        self.assertEqual((st2["new"], st2["new_unpublished"]), ([], []))
        self.assertEqual(len([c for c in gh2.calls if c[0][:2] == ["gh", "api"]]), 1)

    def test_a_push_run_that_published_nothing_is_read_once(self):
        runs = [one_job_run()]
        gh = FakeGh(api={"workflows/nightly.yml/runs": {"workflow_runs": runs},
                         "runs/43300000001/attempts/1/jobs": {"jobs": one_job_jobs(feed=False)}})
        st = ns.record("o/r", "o/hq", 8, ".", "origin/feat-cmux-next", "t", "h", run=gh)
        self.assertEqual((st["new"], st["new_unpublished"]), ([], [43300000001]))
        self.assertEqual(st["unpublished"][0]["conclusion"], "success, no feed upload")
        self.assertEqual(st["unpublished"][0]["push_run"], 43300000001)
        body = ns.issue_body(st["records"], st["unpublished"], ".", run=gh)
        gh2 = FakeGh(issues=[{"number": 9, "title": ns.ISSUE_TITLE, "body": body}],
                     api={"workflows/nightly.yml/runs": {"workflow_runs": runs}})
        ns.record("o/r", "o/hq", 8, ".", "origin/feat-cmux-next", "t", "h", run=gh2)
        self.assertEqual(len([c for c in gh2.calls if c[0][:2] == ["gh", "api"]]), 1, "its jobs are not read again")

    def test_a_push_run_listed_before_its_sign_run_is_forgotten_once_the_sign_run_is_listed(self):
        push = next(r for r in RUNS if r["id"] == 43185474901)
        gh = FakeGh(api={"workflows/nightly.yml/runs": {"workflow_runs": [push]},
                         "runs/43185474901/attempts/1/jobs": {"jobs": PUSH_JOBS}})
        st = ns.record("o/r", "o/hq", 8, ".", "origin/feat-cmux-next", "t", "h", run=gh)
        self.assertEqual(st["new_unpublished"], [43185474901])
        body = ns.issue_body(st["records"], st["unpublished"], ".", run=gh)
        gh2 = FakeGh(issues=[{"number": 9, "title": ns.ISSUE_TITLE, "body": body}],
                     api={"workflows/nightly.yml/runs": {"workflow_runs": RUNS},
                          "runs/43189297315/attempts/1/jobs": {"jobs": SIGN_JOBS},
                          "runs/43185474901/attempts/1/jobs": {"jobs": PUSH_JOBS}})
        st2 = ns.record("o/r", "o/hq", 8, ".", "origin/feat-cmux-next", "t", "h", run=gh2)
        self.assertEqual(st2["new"], ["4318547490101"])
        self.assertNotIn(43185474901, [u["sign_run"] for u in st2["unpublished"]])

    def test_a_rerun_of_an_unpublished_sign_run_that_publishes_is_recorded(self):
        failed = [{**r, "conclusion": "failure"} if r["id"] == 43189297315 else r for r in RUNS]
        gh = FakeGh(api={"workflows/nightly.yml/runs": {"workflow_runs": failed}})
        st = ns.record("o/r", "o/hq", 8, ".", "origin/feat-cmux-next", "t", "h", run=gh)
        line = next(u for u in st["unpublished"] if u["sign_run"] == 43189297315)
        self.assertEqual((line["conclusion"], line["attempt"]), ("failure", 1))
        body = ns.issue_body(st["records"], st["unpublished"], ".", run=gh)
        rerun = [{**r, "run_attempt": 2} if r["id"] == 43189297315 else r for r in RUNS]
        gh2 = FakeGh(issues=[{"number": 9, "title": ns.ISSUE_TITLE, "body": body}],
                     api={"workflows/nightly.yml/runs": {"workflow_runs": rerun},
                          "runs/43189297315/attempts/2/jobs": {"jobs": SIGN_JOBS},
                          "runs/43185474901/attempts/1/jobs": {"jobs": PUSH_JOBS}})
        st2 = ns.record("o/r", "o/hq", 8, ".", "origin/feat-cmux-next", "t", "h", run=gh2)
        self.assertEqual(st2["new"], ["4318547490101"])
        self.assertEqual(st2["records"][0]["sign_attempt"], 2)
        self.assertNotIn(43189297315, [u["sign_run"] for u in st2["unpublished"]])
        # Written over the issue that still has the failed line: the line is gone there too.
        ns.write_issue(st2, "o/hq", "t", ".", run=gh2)
        self.assertNotIn(43189297315, [u["sign_run"] for u in ns.parse_history(gh2.written)["unpublished"]])

    def test_a_rerun_of_a_run_older_than_the_oldest_record_is_read(self):
        # The only record (the one-job build of 11-13) is newer than the sign run that failed on 11-12. A rerun keeps
        # that run's created_at; its run_started_at is the rerun's.
        def api(runs, **more):
            return {"workflows/nightly.yml/runs": {"workflow_runs": [one_job_run()] + runs}, **more}
        failed = [{**r, "conclusion": "failure"} if r["id"] == 43189297315 else r for r in RUNS]
        gh = FakeGh(api=api(failed, **{"runs/43300000001/attempts/1/jobs": {"jobs": one_job_jobs()}}))
        st = ns.record("o/r", "o/hq", 8, ".", "origin/feat-cmux-next", "t", "h", run=gh)
        self.assertEqual(st["new"], ["4330000000101"])
        self.assertIn(43189297315, [u["sign_run"] for u in st["unpublished"]])
        body = ns.issue_body(st["records"], st["unpublished"], ".", run=gh)
        rerun = [{**r, "run_attempt": 2, "run_started_at": "2026-11-13T02:00:00Z"} if r["id"] == 43189297315 else r
                 for r in RUNS]
        gh2 = FakeGh(issues=[{"number": 9, "title": ns.ISSUE_TITLE, "body": body}],
                     api=api(rerun, **{"runs/43189297315/attempts/2/jobs": {"jobs": SIGN_JOBS},
                                       "runs/43185474901/attempts/1/jobs": {"jobs": PUSH_JOBS}}))
        st2 = ns.record("o/r", "o/hq", 8, ".", "origin/feat-cmux-next", "t", "h", run=gh2)
        self.assertEqual(st2["new"], ["4318547490101"], "the rerun is read though its run was created before the history")
        rec = next(r for r in st2["records"] if r["sign_run"] == 43189297315)
        self.assertEqual((rec["sign_attempt"], rec["sign_started"]), (2, "2026-11-13T02:00:00Z"))
        # The rerun's record does not move the history's start back to its run's created_at: nothing older is re-read.
        body = ns.issue_body(st2["records"], st2["unpublished"], ".", run=gh2)
        gh3 = FakeGh(issues=[{"number": 9, "title": ns.ISSUE_TITLE, "body": body}], api=api(rerun))
        st3 = ns.record("o/r", "o/hq", 8, ".", "origin/feat-cmux-next", "t", "h", run=gh3)
        self.assertEqual((st3["new"], st3["new_unpublished"]), ([], []))
        self.assertEqual(len([c for c in gh3.calls if c[0][:2] == ["gh", "api"]]), 1)

    def test_a_rerun_that_publishes_nothing_again_is_read_once_per_attempt(self):
        def record(attempt, body=None):
            runs = [{**one_job_run(), "run_attempt": attempt}]
            gh = FakeGh(issues=[{"number": 9, "title": ns.ISSUE_TITLE, "body": body}] if body else [],
                        api={"workflows/nightly.yml/runs": {"workflow_runs": runs},
                             f"runs/43300000001/attempts/{attempt}/jobs": {"jobs": one_job_jobs(feed=False)}})
            st = ns.record("o/r", "o/hq", 8, ".", "origin/feat-cmux-next", "t", "h", run=gh)
            reads = len([c for c in gh.calls if c[0][:2] == ["gh", "api"]])
            return st, reads, ns.issue_body(st["records"], st["unpublished"], ".", run=gh)

        st, reads, body = record(1)
        self.assertEqual((st["new_unpublished"], reads), ([43300000001], 2))
        st, reads, body = record(2, body)
        self.assertEqual((st["new_unpublished"], reads), ([43300000001], 2), "the rerun's jobs are read")
        self.assertEqual([(u["sign_run"], u["attempt"]) for u in st["unpublished"]], [(43300000001, 2)])
        st, reads, _ = record(2, body)
        self.assertEqual((st["new_unpublished"], reads), ([], 1), "the same attempt is not read again")

    def test_an_unpublished_line_without_an_attempt_is_attempt_one(self):
        line = ns.unpublished_line(one_job_run(), "success, no feed upload")
        line.pop("attempt", None)
        body = ns.issue_body([], [line], ".", run=FakeGh())
        for attempt, reads in ((1, 1), (2, 2)):
            runs = [{**one_job_run(), "run_attempt": attempt}]
            gh = FakeGh(issues=[{"number": 9, "title": ns.ISSUE_TITLE, "body": body}],
                        api={"workflows/nightly.yml/runs": {"workflow_runs": runs},
                             f"runs/43300000001/attempts/{attempt}/jobs": {"jobs": one_job_jobs(feed=False)}})
            ns.record("o/r", "o/hq", 8, ".", "origin/feat-cmux-next", "t", "h", run=gh)
            self.assertEqual(len([c for c in gh.calls if c[0][:2] == ["gh", "api"]]), reads, f"attempt {attempt}")

    def test_only_a_push_run_that_succeeded_is_read(self):
        runs = [one_job_run(1, "failure"), one_job_run(2, "cancelled"), one_job_run(3, None, "in_progress"),
                {**one_job_run(4), "event": "workflow_dispatch"}]
        gh = FakeGh(api={"workflows/nightly.yml/runs": {"workflow_runs": runs}})
        st = ns.record("o/r", "o/hq", 8, ".", "origin/feat-cmux-next", "t", "h", run=gh)
        self.assertEqual((st["new"], st["new_unpublished"], st["why"]), ([], [], None))
        self.assertEqual(len([c for c in gh.calls if c[0][:2] == ["gh", "api"]]), 1)

    def test_a_step_is_shown_in_the_diff_only_when_it_moved(self):
        then = synthetic(1, 20.0, {"j_one_job": 18.0, "step:Sign the app": 0.5, "step:Make the DMG": 2.0})
        now = synthetic(2, 40.0, {"j_one_job": 38.0, "step:Sign the app": 0.6, "step:Make the DMG": 21.0})
        text = ns.render_verdict(ns.check([then, now], ".", run=FakeGh()))
        self.assertIn("| step:Make the DMG | 21.0 | 2.0 | +19.0 |", text)
        self.assertNotIn("step:Sign the app", text)


BASE = {"promote": 2.0, "c_build": 15.0, "g_sign": 20.0, "tiny": 0.07}


class Check(unittest.TestCase):
    def history(self, n=8, mtf=25.0):
        return [synthetic(i, mtf, BASE) for i in range(n)]

    def test_in_budget_says_so(self):
        c = ns.check(self.history(), ".", run=FakeGh())
        self.assertEqual(c["verdict"], "in budget")
        self.assertIn("In budget, no slow stage.", ns.render_verdict(c))

    def test_over_budget_and_slow_stage_name_the_diff_from_the_last_fast_run(self):
        recs = self.history()
        recs.append(synthetic(8, 45.0, {**BASE, "c_build": 30.0}))
        c = ns.check(recs, ".", run=FakeGh())
        self.assertEqual(c["verdict"], "over budget")
        self.assertEqual(c["slow"], {"c_build": [30.0, 15.0]})
        self.assertEqual(c["diff"]["ref_build"], "b7")
        row = next(s for s in c["diff"]["stages"] if s["stage"] == "c_build")
        self.assertEqual(row["delta"], 15.0)
        md = ns.render_verdict(c)
        self.assertIn("Diff from the last fast run: build b7", md)
        self.assertIn("c build job **slow**", md)

    def test_the_one_minute_floor(self):
        recs = self.history()
        recs.append(synthetic(8, 25.0, {**BASE, "tiny": 0.12, "promote": 2.9}))
        c = ns.check(recs, ".", run=FakeGh())
        self.assertEqual(c["slow"], {}, "0.07 -> 0.12 is 1.7x but 3 s; 2.0 -> 2.9 is under 1.5x")
        self.assertEqual(c["verdict"], "in budget")

    def test_too_little_history_judges_only_the_budget(self):
        recs = [synthetic(0, 20.0, BASE), synthetic(1, 20.0, {**BASE, "c_build": 90.0})]
        c = ns.check(recs, ".", run=FakeGh())
        self.assertEqual((c["slow"], c["verdict"]), ({}, "in budget"))

    def test_host_and_wait_deltas(self):
        recs = self.history()
        recs[-1]["hosts"] = {"cmux15": [10, 1.0, 2.0, 0.5]}
        recs.append(synthetic(8, 50.0, BASE, hosts={"cmux15": [10, 1.0, 26.0, 23.5]}))
        recs[-1]["runners"] = {"build": "ultra2"}
        c = ns.check(recs, ".", run=FakeGh())
        self.assertEqual(c["diff"]["runner_changes"], [["build", "ultra1", "ultra2"]])
        self.assertEqual(c["diff"]["waits"][0], {"host": "cmux15", "jobs": [10, 10], "queue": [1.0, 1.0], "hook": [2.0, 26.0],
                                                 "hook_max": [0.5, 23.5], "delta": 24.0})
        self.assertIn("| cmux15 | 10/10 |", ns.render_verdict(c))


class Bisect(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        repo = self.tmp.name
        git_fixture_env.init_repo(repo, "-b", "main")
        env = git_fixture_env.fixture_env()
        env.update(GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@e", GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@e")

        def commit(path, msg):
            full = os.path.join(repo, path)
            os.makedirs(os.path.dirname(full), exist_ok=True)
            with open(full, "a", encoding="utf-8") as f:
                f.write(msg + "\n")
            subprocess.run(["git", "-C", repo, "add", "-A"], env=env, check=True, capture_output=True)
            subprocess.run(["git", "-C", repo, "commit", "-qm", msg], env=env, check=True, capture_output=True)
            return subprocess.run(["git", "-C", repo, "rev-parse", "HEAD"], env=env, check=True, capture_output=True,
                                  text=True).stdout.strip()

        self.shas = [commit("README", "start")]
        self.shas.append(commit("App/A.swift", "app: a"))
        self.shas.append(commit(".github/workflows/nightly.yml", "ci(nightly): build twice"))
        self.shas.append(commit("cmux-tui/src/x.rs", "tui: x"))
        self.shas.append(commit("App/B.swift", "app: b"))
        self.repo = repo

    def tearDown(self):
        self.tmp.cleanup()

    def test_three_slow_in_a_row_finds_the_change_point_and_its_pipeline_commits(self):
        s = self.shas
        recs = [synthetic(i, 25.0, BASE, sha=s[0]) for i in range(6)]
        recs.append(synthetic(6, 25.0, BASE, sha=s[1]))
        recs += [synthetic(7 + i, 40.0, {**BASE, "c_build": 31.0}, sha=sha) for i, sha in enumerate(s[3:])]
        c = ns.check(recs, self.repo)
        self.assertEqual(c["bisect"], [], "two slow records are not yet a recurring regression")
        recs.append(synthetic(9, 40.0, {**BASE, "c_build": 31.0}, sha=s[4]))
        c = ns.check(recs, self.repo)
        b = c["bisect"][0]
        self.assertEqual((b["stage"], b["streak"], b["last_ok"]["build"], b["first_slow"]["build"]), ("c_build", 3, "b6", "b7"))
        self.assertEqual([subj for _, subj in b["pipeline_commits"]], ["ci(nightly): build twice"])
        self.assertEqual(b["code_files"], {"cmux-tui": 1})
        md = ns.render_verdict(c)
        self.assertIn("### Bisect: `c build job` slow in 3 consecutive nightlies", md)
        self.assertIn("ci(nightly): build twice", md)
        self.assertEqual(c["diff"]["commits"]["count"], 3, "the last fast run b6 at a: three commits to b")

    def test_landing_times_read_first_parent(self):
        t = ns.landing_times(self.repo, "main")
        self.assertEqual(set(t), set(self.shas))


class Issue(unittest.TestCase):
    def test_creates_once_then_edits_and_keeps_history(self):
        rec = fixture_record()
        gh = FakeGh()
        st = {"records": [rec], "unpublished": [], "new": [rec["build"]], "new_unpublished": []}
        self.assertEqual(ns.write_issue(st, "o/hq", "t", ".", run=gh), "https://github.com/o/hq/issues/9")
        body = gh.written
        self.assertTrue(body.startswith(ns.ISSUE_MARK))
        self.assertIn("4318547490101", body)
        self.assertEqual(ns.parse_history(body)["records"][0]["merge_to_feed"], 85.97)
        # An empty state (record's history read failed) never drops what the issue holds.
        gh2 = FakeGh(issues=[{"number": 9, "title": ns.ISSUE_TITLE, "body": body}])
        nxt = synthetic(30, 20.0, BASE)
        ns.write_issue({"records": [nxt], "unpublished": [], "new": ["b30"]}, "o/hq", "t", ".", run=gh2)
        self.assertEqual(gh2.calls[-1][0][:4], ["gh", "issue", "edit", "9"])
        self.assertEqual([r["build"] for r in ns.parse_history(gh2.written)["records"]], ["4318547490101", "b30"])

    def test_nothing_new_writes_nothing(self):
        gh = FakeGh(issues=[{"number": 9, "title": ns.ISSUE_TITLE, "body": ns.ISSUE_MARK}])
        self.assertIn("nothing new", ns.write_issue({"records": [], "new": []}, "o/hq", "t", ".", run=gh))
        self.assertFalse(any(c[0][:3] == ["gh", "issue", "edit"] for c in gh.calls))

    @staticmethod
    def records(n, pad=0):
        """n copies of the fixture record, each wall and wait varied as real nightlies are (and `pad` characters of
        noise per record), so the compressed history is not n identical records."""
        rnd, rec, out = random.Random(7), fixture_record(), []
        for i in range(n):
            r = copy.deepcopy(rec)
            r.update(sign_run=1 + i, build=f"b{i}", feed_at=f"2026-11-{10 + i // 24:02d}T{i % 24:02d}:00:00Z",
                     sha="%040x" % rnd.getrandbits(160), merge_to_feed=round(rnd.uniform(20, 150), 2))
            r["stages"] = {k: round(v * rnd.uniform(0.7, 1.4), 2) for k, v in r["stages"].items()}
            r["jobs"] = [[name, host, round((q or 0) * rnd.uniform(0.5, 2), 2),
                          round((h or 0) * rnd.uniform(0.5, 2), 2)] for name, host, q, h in r["jobs"]]
            if pad:
                r["noise"] = "%x" % rnd.getrandbits(4 * pad)
            out.append(r)
        return out

    def test_body_keeps_every_record_and_the_comment_cannot_close_early(self):
        recs = self.records(ns.HISTORY_KEEP)
        for r in recs:
            r["jobs"][0][0] = "a --> b"
        body = ns.issue_body(recs, [], ".", run=FakeGh())
        self.assertLessEqual(len(body), ns.BODY_LIMIT)
        self.assertEqual(body.count("-->"), body.count("<!--"))
        back = ns.parse_history(body)["records"]
        self.assertEqual(len(back), ns.HISTORY_KEEP, "the whole history fits")
        self.assertEqual([("jobs" in r) for r in back], [False] * (ns.HISTORY_KEEP - 6) + [True] * 6)
        self.assertEqual(back[-1]["jobs"][0][0], "a --> b")
        self.assertEqual(back, ns.parse_history(body)["records"])
        self.assertEqual(back[-1]["stages"], recs[-1]["stages"])

    def test_a_body_in_the_plain_form_still_parses(self):
        recs = self.records(3)
        body = ns.issue_body(recs, [], ".", run=FakeGh())
        self.assertNotIn("<!-- nightly-speed-history: {", body, "written compressed")
        plain = f"{ns.ISSUE_MARK}\nreport\n<!-- nightly-speed-history: {json.dumps({'records': recs})} -->\n"
        self.assertEqual([r["build"] for r in ns.parse_history(plain)["records"]], ["b0", "b1", "b2"])

    def test_a_corrupt_compressed_history_is_an_empty_history(self):
        plain = f"<!-- nightly-speed-history: {json.dumps({'records': self.records(1)})} -->"
        bomb = base64.b64encode(zlib.compress(b" " * (ns.INFLATE_CAP + 10), 9)).decode()
        cut = ns.history_comment(self.records(2), [])[:-30] + " -->"
        for z in ("not base64!", "AAAA", base64.b64encode(b"not zlib").decode(), bomb,
                  base64.b64encode(zlib.compress(b"[1, 2]")).decode()):
            body = f"{ns.ISSUE_MARK}\n<!-- nightly-speed-history-z: {z} -->\n{plain}\n"
            self.assertEqual(ns.parse_history(body), {"records": [], "unpublished": []}, z[:20])
        self.assertEqual(ns.parse_history(cut), {"records": [], "unpublished": []})

    @staticmethod
    def packed(doc):
        z = base64.b64encode(zlib.compress(json.dumps(doc).encode("utf-8"), 9)).decode("ascii")
        return f"{ns.ISSUE_MARK}\n<!-- nightly-speed-history-z: {z} -->\n"

    def test_valid_json_of_another_shape_is_no_history(self):
        empty = {"records": [], "unpublished": []}
        for doc in ({"records": 1}, {"records": "abc"}, {"records": {"a": 1}}, {"records": [1, "a", None, [2]]},
                    {"unpublished": 7}, {"records": None, "unpublished": {"sign_run": 1}}, 5, "text", None):
            self.assertEqual(ns.parse_history(self.packed(doc)), empty, doc)
        deep = base64.b64encode(zlib.compress(b"[" * 200000, 9)).decode("ascii")
        self.assertEqual(ns.parse_history(f"<!-- nightly-speed-history-z: {deep} -->"), empty, "nested past the parser")
        # record goes on with an empty history instead of raising.
        gh = FakeGh(issues=[{"number": 9, "title": ns.ISSUE_TITLE, "body": self.packed({"records": 1})}],
                    api={"workflows/nightly.yml/runs": {"workflow_runs": RUNS},
                         "runs/43189297315/attempts/1/jobs": {"jobs": SIGN_JOBS},
                         "runs/43185474901/attempts/1/jobs": {"jobs": PUSH_JOBS}})
        st = ns.record("o/r", "o/hq", 8, ".", "origin/feat-cmux-next", "t", "h", run=gh)
        self.assertEqual(st["new"], ["4318547490101"])

    def test_a_stored_record_of_another_shape_is_no_record(self):
        good = fixture_record()
        self.assertTrue(ns.sound_record(json.loads(json.dumps(good))), "what build_record writes is sound")
        changes = ({"stages": 1}, {"stages": {"c_build": "9"}}, {"merge_to_feed": "85"}, {"merge_to_feed": 10 ** 400},
                   {"merge_to_feed": float("nan")}, {"merge_to_feed": True}, {"sha": "--output=/tmp/x"}, {"sha": 5},
                   {"feed_at": 7}, {"build": None}, {"hosts": {"cmux15": [1, 2]}}, {"hosts": {"cmux15": [1, 2, "3", 4]}},
                   {"jobs": [["a"]]}, {"jobs": {"a": 1}}, {"runners": []}, {"sign_created": 3}, {"sign_run": "1"},
                   {"sign_run": True}, {"sign_run": 0})
        bad = [{**good, "sign_run": 2 + i, **change} for i, change in enumerate(changes)]
        unp = [{"sign_run": 5, "held_min": "x"}, {"sign_run": 6, "created_at": 3}, {"sign_run": 7, "attempt": "2"},
               {"sign_run": [8]}, {"sign_run": 9}]
        hist = ns.parse_history(self.packed({"records": bad + [good], "unpublished": unp}))
        self.assertEqual([r["sign_run"] for r in hist["records"]], [good["sign_run"]])
        self.assertEqual([u["sign_run"] for u in hist["unpublished"]], [9])
        # What is left is judged and written without raising.
        self.assertLessEqual(len(ns.issue_body(hist["records"], hist["unpublished"], ".", run=FakeGh())), ns.BODY_LIMIT)

    def test_trimming_records_keeps_the_unpublished_lines(self):
        unp = [ns.unpublished_line({**one_job_run(100 + i), "conclusion": "cancelled", "run_attempt": 2})
               for i in range(ns.UNPUBLISHED_KEEP)]
        body = ns.issue_body(self.records(ns.HISTORY_KEEP, pad=3000), unp, ".", run=FakeGh())
        self.assertLessEqual(len(body), ns.BODY_LIMIT)
        hist = ns.parse_history(body)
        self.assertTrue(0 < len(hist["records"]) < ns.HISTORY_KEEP, len(hist["records"]))
        self.assertEqual(hist["unpublished"], unp, "a dropped record takes no unpublished line with it")
        # Lines alone too large for the body: the oldest go, the newest stay.
        rnd = random.Random(3)
        huge = [{**u, "conclusion": "%x" % rnd.getrandbits(8000)} for u in unp]
        body = ns.issue_body([], huge, ".", run=FakeGh())
        self.assertLessEqual(len(body), ns.BODY_LIMIT)
        kept = ns.parse_history(body)["unpublished"]
        self.assertTrue(0 < len(kept) < len(huge), len(kept))
        self.assertEqual(kept[-1], huge[-1])

    def test_records_too_large_for_the_floor_still_fit(self):
        recs = self.records(ns.HISTORY_KEEP, pad=3000)
        body = ns.issue_body(recs, [], ".", run=FakeGh())
        self.assertLessEqual(len(body), ns.BODY_LIMIT)
        back = ns.parse_history(body)["records"]
        self.assertTrue(0 < len(back) < ns.TRAILING + ns.BISECT_AFTER, len(back))
        self.assertFalse(any("jobs" in r for r in back), "per-job detail goes before records below the floor")
        self.assertEqual(back[-1]["build"], recs[-1]["build"], "the newest are kept")

    def test_unreadable_issue_list_is_an_error(self):
        with self.assertRaises(ns.SourceError):
            ns.write_issue({"records": []}, "o/hq", "t", ".", run=FakeGh(fail_list=True))


if __name__ == "__main__":
    unittest.main()
