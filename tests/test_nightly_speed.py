#!/usr/bin/env python3
"""scripts/ci/nightly_speed.py: the per-nightly timing record, the budget and slow-stage check, the bisect over the
recorded runs, and the one cmuxterm-hq issue. No network: gh is a fake, git runs in a temporary repository.

The fixtures in tests/fixtures/nightly-speed are trimmed REST payloads of build 4318547490101 (push run 43185474901,
sign run 43189297315, 2026-11-12): 85.97 min merge to feed, cmux15's "Set up runner" hook held a job 12.5 min.
Run: python3 -I tests/test_nightly_speed.py (also runs in nightly-speed.yml)."""
from __future__ import annotations

import copy
import importlib.util
import json
import os
import subprocess
import tempfile
import unittest

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

    def test_unreadable_history_and_list_say_why(self):
        st = ns.record("o/r", "o/hq", 8, ".", "x", None, None, run=FakeGh())
        self.assertIn("no cmuxterm-hq token", st["history_why"])
        self.assertIn("no run list", st["why"])
        self.assertEqual(st["records"], [])


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

    def test_body_stays_under_the_limit_and_the_comment_cannot_close_early(self):
        rec = fixture_record()
        recs = []
        for i in range(ns.HISTORY_KEEP):
            r = copy.deepcopy(rec)
            r.update(sign_run=i, build=f"b{i}", feed_at=f"2026-11-{10 + i // 24:02d}T{i % 24:02d}:00:00Z")
            r["jobs"][0][0] = "a --> b"
            recs.append(r)
        body = ns.issue_body(recs, [], ".", run=FakeGh())
        self.assertLessEqual(len(body), ns.BODY_LIMIT)
        self.assertEqual(body.count("-->"), body.count("<!--"))
        back = ns.parse_history(body)["records"]
        self.assertEqual(back[-1]["jobs"][0][0], "a --> b")
        self.assertNotIn("jobs", back[0], "only the newest records keep per-job detail")

    def test_unreadable_issue_list_is_an_error(self):
        with self.assertRaises(ns.SourceError):
            ns.write_issue({"records": []}, "o/hq", "t", ".", run=FakeGh(fail_list=True))


if __name__ == "__main__":
    unittest.main()
