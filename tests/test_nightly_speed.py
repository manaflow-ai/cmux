#!/usr/bin/env python3
"""scripts/ci/nightly_speed.py: the per-nightly timing record, the budget and slow-stage check, the bisect over the
recorded runs, and the one cmuxterm-hq issue. No network: gh is a fake, git runs in a temporary repository.

The fixtures in tests/fixtures/nightly-speed are trimmed REST payloads of build 4318547490101 (push run 43185474901,
sign run 43189297315, 2026-11-12): 85.97 min merge to feed, cmux15's "Set up runner" hook held a job 12.5 min.
Run: python3 -I tests/test_nightly_speed.py (also runs in nightly-speed.yml)."""
from __future__ import annotations

import base64
import contextlib
import copy
import importlib.util
import io
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
# The fixture's failed and cancelled sign runs: read once each (a failed run may still have published), no feed step.
FAILED_SIGN_JOBS = {"runs/43198322667/attempts/1/jobs": {"jobs": []}, "runs/43194746628/attempts/1/jobs": {"jobs": []}}


def fixture_record():
    rec, why = ns.build_record(BY_ID[43189297315], BY_ID[43185474901], SIGN_JOBS, PUSH_JOBS, LANDED)
    assert rec, why
    return rec


def synthetic(n, mtf, stages, sha=None, hosts=None):
    """Record n with the given merge_to_feed and stages, fed n hours after a fixed start."""
    return {"build": f"b{n}", "sha": sha or f"{n:040x}", "sign_run": 1000 + n, "feed_at": f"2026-11-12T{n:02d}:00:00Z"
            if n < 24 else f"2026-11-13T{n - 24:02d}:00:00Z", "sign_created": f"2026-11-12T{n % 24:02d}:00:00Z",
            "merge_to_feed": mtf, "stages": dict(stages), "runners": {"build": "ultra1"}, "hosts": hosts or {}, "jobs": []}



def fixture_attribution(records, git_dir, base_ref=ns.BASE_REF, *, confirm_feeds=True, **kwargs):
    """Legacy graph fixtures now explicitly supply synthetic provider and publication receipts.
    Provider rejection and differing clocks are tested separately with independent payloads below.
    """
    now = kwargs.get("now", ns.time.time())
    since = now - kwargs.get("window_days", ns.PR_WINDOW_DAYS) * 86400
    candidates = ns.first_parent_pr_merges(git_dir, base_ref, since, kwargs.get("run", subprocess.run))
    provider = {}
    for r in candidates:
        if r["pr"] is not None and r["github"]:
            provider[r["pr"]] = {k: r[k] for k in ("pr", "sha", "merged_at")}
    def verified(f):
        return {"confirmed": True, "confirmed_identity": True, "sha_source": "signed_notes", **f}
    if confirm_feeds:
        records = [verified(f) for f in records]
        if "feeds" in kwargs:
            kwargs["feeds"] = [verified(f) for f in kwargs["feeds"]]
    return ns.pr_attribution(records, git_dir, base_ref, **kwargs,
                             provider_merges={"rows": list(provider.values()), "complete": True})

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
        gh = FakeGh(api={"workflows/nightly.yml/runs": {"workflow_runs": RUNS}, **FAILED_SIGN_JOBS,
                         "runs/43189297315/attempts/1/jobs": {"jobs": SIGN_JOBS},
                         "runs/43185474901/attempts/1/jobs": {"jobs": PUSH_JOBS}})
        st = ns.record("o/r", "o/hq", 8, ".", "origin/feat-cmux-next", "t", "h", run=gh)
        self.assertEqual(st["new"], ["4318547490101"])
        self.assertEqual(sorted(st["new_unpublished"]), [43194746628, 43198322667], "the in-progress sign run waits")
        apis = [c[0][2] for c in gh.calls if c[0][:2] == ["gh", "api"] and "/pulls?" not in c[0][2]]
        self.assertEqual(len(apis), 5, "one list, two job lists for the build, one for each failed sign run")
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
        self.assertEqual(len([c for c in gh2.calls if c[0][:2] == ["gh", "api"] and "/pulls?" not in c[0][2]]), 1)
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


class PrAttribution(unittest.TestCase):
    class Git:
        def __init__(self):
            self.log = "\n".join([
                "m4\tp1 p2\t1794873600\tMerge pull request #104 from x/missing",
                "m3\tp1 p2\t1794787200\tnightly merge without a PR",
                "m2\tp1\t1794700800\tfeature: slow path (#102)",
                "m1\tp1 p2\t1794614400\tMerge pull request #101 from x/fast",
            ]) + "\n"

        def __call__(self, cmd, **kw):
            if "rev-list" in cmd:
                return subprocess.CompletedProcess(cmd, 128, "", "no rev-list in this fake")
            if "log" in cmd:
                return subprocess.CompletedProcess(cmd, 0, self.log, "")
            if "merge-base" in cmd:
                commit, head = cmd[-2:]
                return subprocess.CompletedProcess(cmd, 0 if (commit, head) in {
                    ("m1", "a1a1a1a"), ("m1", "a2a2a2a"), ("m2", "a2a2a2a")
                } else 1, "", "")
            raise AssertionError(cmd)

    def test_merges_map_to_the_first_later_feed_and_keep_missing_rows(self):
        feeds = [
            {"build": "n0", "sha": "a0a0a0a", "feed_at": "2026-11-13T12:00:00Z"},
            {"build": "n1", "sha": "a1a1a1a", "feed_at": "2026-11-14T01:00:00Z"},
            {"build": "n2", "sha": "a2a2a2a", "feed_at": "2026-11-16T00:00:00Z"},
        ]
        result = fixture_attribution(feeds, ".", "origin/feat-cmux-next", run=self.Git(),
                                   now=ns.ts("2026-11-20T00:00:00Z"))
        self.assertEqual(result["count"], 4)
        self.assertEqual(result["attributed"], 2)
        rows = {row["pr"]: row for row in result["rows"]}
        self.assertEqual((rows[101]["build"], rows[101]["merge_to_nightly"]), ("n1", 60.0))
        self.assertEqual((rows[102]["build"], rows[102]["merge_to_nightly"]), ("n2", 1440.0))
        self.assertEqual(rows[None]["reason"], "no PR number in merge metadata")
        self.assertEqual(rows[104]["reason"], "no later published nightly contains merge")
        self.assertEqual((result["p50"], result["p90"]), (750.0, 1302.0))

    def test_history_and_markdown_carry_the_attribution_summary(self):
        data = {"window_days": 7, "count": 1, "attributed": 0, "p50": None, "p90": None,
                "rows": [{"pr": 7, "status": "unattributed", "reason": "no later published nightly contains merge",
                          "merged_at": "2026-11-14T00:00:00Z", "sha": "m", "subject": "x",
                          "feed_at": None, "build": None, "merge_to_nightly": None}]}
        body = ns.history_comment([], [], pr_data=data)
        doc = ns.history_json(body)
        self.assertEqual(doc["schema"], 2)
        self.assertEqual(doc["pr_attribution"]["count"], 1)
        self.assertEqual(ns.parse_history(body)["pr_attribution"]["p90"], None)
        text = ns.render_verdict({"build": "n1", "sha": "a1a1a1a", "merge_to_feed": 20.0,
                                  "verdict": "in budget", "budget_min": 30.0, "window": 1, "over": False,
                                  "p50": 20.0, "p95": 20.0, "feed_at": "2026-11-14T01:00:00Z",
                                  "slow": {}, "diff": None, "bisect": [],
                                  "pr_attribution": data})
        self.assertIn("PR merge to NIGHTLY", text)
        self.assertIn("no later published nightly contains merge", text)

    def test_the_pr_number_is_the_trailing_one_then_merge_pull_request_then_none(self):
        cases = {
            "PR 1 of 3: split the sidebar (#43168)": 43168,
            "after #40 landed, retry the feed (#43170)  ": 43170,
            "Merge pull request #101 from x/fast": 101,
            "Merge pull request #101 from x/after-#99": 101,
            "Revert \"fix (#5)\" for PR 7": None,
            "fix: see #12 and PR 13": None,
            "Merge origin/feat-cmux-next (a584889f871f) into feat-cmux-next": None,
        }
        for subject, want in cases.items():
            self.assertEqual(ns.pr_number(subject), want, subject)

    def test_a_merge_before_the_oldest_observed_feed_is_unattributed_and_out_of_the_quantiles(self):
        class Git:
            def __call__(self, cmd, **kw):
                if "rev-list" in cmd:
                    return subprocess.CompletedProcess(cmd, 0, "m1\nm2\nm3\n", "")
                if "log" in cmd:
                    return subprocess.CompletedProcess(cmd, 0, "\n".join([
                        "m3\tp1\t1794787200\tlate (#3)",      # 2026-11-16T00:00Z
                        "m2\tp1\t1794700800\tmiddle (#2)",    # 2026-11-15T00:00Z
                        "m1\tp1\t1794614400\tearly (#1)",     # 2026-11-14T00:00Z
                    ]) + "\n", "")
                if "merge-base" in cmd:
                    return subprocess.CompletedProcess(cmd, 0, "", "")  # every feed holds every merge
                raise AssertionError(cmd)

        feeds = [{"build": "n1", "sha": "a1a1a1a", "feed_at": "2026-11-14T12:00:00Z"},
                 {"build": "n2", "sha": "a2a2a2a", "feed_at": "2026-11-16T01:00:00Z"}]
        result = fixture_attribution(feeds, ".", run=Git(), now=ns.ts("2026-11-20T00:00:00Z"))
        rows = {row["pr"]: row for row in result["rows"]}
        self.assertEqual((rows[1]["status"], rows[1]["reason"], rows[1]["build"]),
                         ("unattributed", ns.BEFORE_FEEDS, None))
        self.assertEqual((rows[2]["build"], rows[3]["build"]), ("n2", "n2"))
        self.assertEqual(result["attributed"], 2)
        self.assertEqual(result["reasons"], {ns.BEFORE_FEEDS: 1})
        self.assertEqual((result["p50"], result["p90"]), (ns.quantile([1500.0, 60.0], 0.5), ns.quantile([1500.0, 60.0], 0.9)))
        text = ns.render_verdict({
            "build": "n2", "sha": "a2a2a2a", "merge_to_feed": 20.0, "verdict": "in budget", "budget_min": 30.0, "window": 1,
            "over": False, "p50": 20.0, "p95": 20.0, "feed_at": "2026-11-16T01:00:00Z", "slow": {}, "diff": None,
            "bisect": [], "pr_attribution": result})
        self.assertIn(f"{ns.BEFORE_FEEDS}: 1", text)
        self.assertIn("## PR merge to NIGHTLY (partial: observed window)", text)
        self.assertNotIn("newest 7 days", text, "never labelled a full window")
        self.assertIn("Observed window: 2026-11-14T12:00:00Z to 2026-11-20T00:00:00Z; "
                      "1 merges before it unattributed (no feed observed). Coverage is partial", text)

    def test_a_sync_merge_brings_its_second_parent_landings_and_an_old_date_does_not_stop_the_walk(self):
        """c3d5d5742ca0 on 2026-11-21: a local branch merged origin/feat-cmux-next and was pushed, so the first-parent
        line ran down the local branch and #48675 sat only on the second parent. And one commit with an old committer
        date in the middle of the line must not end the walk (git log --since stops there)."""
        with tempfile.TemporaryDirectory() as repo:
            git_fixture_env.init_repo(repo, "-b", "main")
            env = git_fixture_env.fixture_env()
            env.update(GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@e", GIT_COMMITTER_NAME="GitHub",
                       GIT_COMMITTER_EMAIL=ns.GITHUB_COMMITTER)

            def g(*args, when=None):
                e = dict(env, **({"GIT_COMMITTER_DATE": when, "GIT_AUTHOR_DATE": when} if when else {}))
                return subprocess.run(["git", "-C", repo, *args], env=e, check=True, capture_output=True,
                                      text=True).stdout.strip()

            g("commit", "--allow-empty", "-qm", "start", when="2026-11-10T00:00:00Z")
            g("commit", "--allow-empty", "-qm", "first landing (#100)", when="2026-11-18T00:00:00Z")
            g("commit", "--allow-empty", "-qm", "old-dated landing (#101)", when="2026-11-01T00:00:00Z")
            g("commit", "--allow-empty", "-qm", "behind the old date (#102)", when="2026-11-18T02:00:00Z")
            fork = g("rev-parse", "HEAD")
            g("commit", "--allow-empty", "-qm", "cmux-next: pin (#48675)", when="2026-11-19T01:10:00Z")
            remote = g("rev-parse", "HEAD")
            g("checkout", "-q", "-b", "local", fork)
            g("commit", "--allow-empty", "-qm", "local work, pushed directly", when="2026-11-19T01:00:00Z")
            g("merge", "-q", "--no-ff", "-m", "Merge origin/feat-cmux-next into feat-cmux-next", remote,
              when="2026-11-19T01:11:00Z")
            merges = ns.first_parent_pr_merges(repo, "local", ns.ts("2026-11-15T00:00:00Z"))
            head = g("rev-parse", "HEAD")
            data = fixture_attribution([{"build": "n0", "sha": fork, "feed_at": "2026-11-18T03:00:00Z"},
                                      {"build": "n1", "sha": head, "feed_at": "2026-11-19T02:00:00Z"}],
                                     repo, "local", now=ns.ts("2026-11-20T00:00:00Z"), window_days=5)
        self.assertEqual([m["pr"] for m in merges], [None, 48675, None, 102, 100])
        self.assertEqual(merges[1]["merged_at"], "2026-11-19T01:10:00Z")
        rows = {r["pr"]: r for r in data["rows"]}
        self.assertEqual((rows[48675]["build"], rows[48675]["merge_to_nightly"]), ("n1", 50.0))
        self.assertEqual(rows[102]["reason"], ns.BEFORE_FEEDS)

    def test_a_week_of_merges_leaves_every_record_in_the_body(self):
        """The readback of 2026-11-21: ~2,500 first-parent merges in the window made a 279 KB body even with every
        record dropped. The body and the history carry the summary; the 40 records and 40 unpublished lines stay."""
        recs = Issue.records(ns.HISTORY_KEEP)
        unp = [ns.unpublished_line({**one_job_run(100 + i), "conclusion": "cancelled",
                                    "created_at": f"2026-11-11T{i % 24:02d}:{i % 60:02d}:00Z"})
               for i in range(ns.UNPUBLISHED_KEEP)]
        rnd = random.Random(11)
        start, end = ns.ts("2026-11-09T00:00:00Z"), ns.ts("2026-11-12T00:00:00Z")
        lines = []
        for i in range(2500):
            stamp = int(start + (end - start) * i / 2500)
            subject = (f"area-{i % 37}: a realistic subject line of some length, step {rnd.getrandbits(32):x} "
                       + (f"(#{40000 + i})" if i % 50 else "with no number"))
            lines.append(f"{rnd.getrandbits(160):040x}\tp{i} q{i}\t{stamp}\t{subject}")
        log = "\n".join(reversed(lines)) + "\n"
        feed_of = {r["sha"]: ns.ts(r["feed_at"]) for r in recs}

        def git(cmd, **kw):
            if "log" in cmd:
                return subprocess.CompletedProcess(cmd, 0, log if "^" not in cmd[-1] else "", "")
            if "rev-list" in cmd:  # a head holds the merges before its feed, a few late ones excepted
                held = [ln.split("\t")[0] for ln in lines
                        if int(ln.split("\t")[2]) < feed_of[cmd[-1]] - 3600 * rnd.random()]
                return subprocess.CompletedProcess(cmd, 0, "\n".join(held) + "\n", "")
            raise AssertionError(cmd)

        data = fixture_attribution(recs, ".", run=git, now=end, window_days=4)
        self.assertEqual(data["count"], 2500)
        self.assertGreater(data["reasons"][ns.BEFORE_FEEDS], 0)
        body = ns.issue_body(recs, unp, ".", run=FakeGh(), pr_data=data)
        self.assertLess(len(body), ns.BODY_LIMIT)
        back = ns.parse_history(body)
        self.assertEqual((len(back["records"]), len(back["unpublished"])), (ns.HISTORY_KEEP, ns.UNPUBLISHED_KEEP))
        self.assertEqual(back["pr_attribution"]["count"], 2500)
        self.assertNotIn("rows", back["pr_attribution"], "the history stores no per-merge rows")
        table = [ln for ln in body.splitlines() if ln.startswith("| 2026-11-")
                 and ln.rstrip().endswith(("attributed |", "contains merge |", "metadata |", "feed |"))]
        self.assertLessEqual(len(table), ns.PR_SUMMARY_ROWS)

    @staticmethod
    def busy_week(n=60):
        """n nightlies over the 7 days before 2026-11-20 (a busy week: more than HISTORY_KEEP), the predecessor feed
        just before the window first, and a git fake whose head holds every merge committed before its feed."""
        end = ns.ts("2026-11-20T00:00:00Z")
        feeds = [{"sha": "%040x" % (0xf00 + i), "build": f"b{i}", "sign_run": 1 + i,
                  "confirmed": True, "sha_source": "signed_notes", "confirmed_identity": True,
                  "feed_at": ns.iso(end - 7 * 86400 + i * (7 * 86400 / n) - (3600 if i == 0 else -60))}
                 for i in range(n)]
        merges = [("%040x" % (0xa00 + i), int(ns.ts(f["feed_at"]) - 600)) for i, f in enumerate(feeds) if i]
        log = "".join(f"{sha}\tp1\t{stamp}\tlanding {k} (#{1000 + k})\n"
                      for k, (sha, stamp) in reversed(list(enumerate(merges))))
        when = {f["sha"]: ns.ts(f["feed_at"]) for f in feeds}

        def git(cmd, **kw):
            if "log" in cmd:
                return subprocess.CompletedProcess(cmd, 0, log, "")
            if "rev-list" in cmd:
                return subprocess.CompletedProcess(cmd, 0, "".join(f"{m}\n" for m, t in merges if t < when[cmd[-1]]), "")
            raise AssertionError(cmd)

        return end, feeds, git

    def test_a_busy_week_attributes_merges_older_than_the_40th_record_and_proves_its_window(self):
        end, feeds, git = self.busy_week()
        records = [{**f, "landed_at": None} for f in feeds[-ns.HISTORY_KEEP:]]
        old_merge = 1000 + 5  # merged 10 min before feed 6, far older than the oldest of the 40 records
        only_records = fixture_attribution(records, ".", run=git, now=end)
        self.assertEqual({r["pr"]: r for r in only_records["rows"]}[old_merge]["reason"], ns.BEFORE_FEEDS)
        self.assertTrue(only_records["partial"])
        kept = ns.feed_list(feeds, records, end)
        self.assertEqual(len(kept), len(feeds), "every feed of the 7 days and the one before them")
        # A predecessor alone proves nothing: no run classification, the label stays.
        unproven = fixture_attribution(records, ".", run=git, now=end, feeds=kept)
        self.assertTrue(unproven["partial"])
        span = {"from": ns.iso(end - 8 * 86400), "to": ns.iso(end)}
        data = fixture_attribution(records, ".", run=git, now=end, feeds=kept, classified=span)
        row = {r["pr"]: r for r in data["rows"]}[old_merge]
        self.assertEqual((row["build"], row["feed_sha"], row["merge_to_nightly"]), ("b6", feeds[6]["sha"], 10.0))
        self.assertEqual((data["attributed"], data["count"], data["partial"]), (len(feeds) - 1, len(feeds) - 1, False))
        verdict = {"build": "b59", "sha": feeds[-1]["sha"], "merge_to_feed": 20.0, "verdict": "in budget",
                   "budget_min": 30.0, "window": 1, "over": False, "p50": 20.0, "p95": 20.0,
                   "feed_at": feeds[-1]["feed_at"], "slow": {}, "diff": None, "bisect": []}
        full = ns.render_verdict({**verdict, "pr_attribution": data})
        self.assertIn("## PR merge to NIGHTLY (newest 7 days)", full)
        self.assertNotIn("partial", full)
        self.assertIn(f"Observed window: {data['since']} to {data['until']}; 0 merges before it", full)
        # Without the predecessor the window is not proven: the label stays.
        short = fixture_attribution(records, ".", run=git, now=end, feeds=kept[1:], classified=span)
        self.assertTrue(short["partial"])
        self.assertIn("(partial: observed window)", ns.render_verdict({**verdict, "pr_attribution": short}))

    def test_the_feed_list_outlives_the_records_and_bad_entries_are_dropped(self):
        end, feeds, _ = self.busy_week()
        stale = {"sha": "%040x" % 0xbad, "build": "old", "sign_run": 999, "feed_at": "2026-11-01T00:00:00Z"}
        kept = ns.feed_list([stale] + feeds, [], end)
        self.assertEqual([e["build"] for e in kept], [f["build"] for f in feeds], "older than the predecessor goes")
        recs = Issue.records(ns.HISTORY_KEEP)
        body = ns.issue_body(recs, [], ".", run=FakeGh(), pr_data={"count": 0}, feeds=kept)
        self.assertLess(len(body), ns.BODY_LIMIT)
        back = ns.parse_history(body)
        self.assertEqual((len(back["records"]), back["feeds"]), (ns.HISTORY_KEEP, kept))
        bad = [{"sha": "zz; rm -rf", "build": "x", "feed_at": "2026-11-19T00:00:00Z"},
               {"sha": "abcdef1", "build": "x"}, {"sha": "abcdef1", "build": "x", "feed_at": "not a time"},
               {"sha": "abcdef1", "build": "", "feed_at": "2026-11-19T00:00:00Z"},
               {"sha": "abcdef1", "build": "x", "feed_at": "2026-11-19T00:00:00Z", "sign_run": -1},
               "text", 7, None, ["abcdef1"]]
        good = {"sha": "abcdef1", "build": "ok", "sign_run": 3, "feed_at": "2026-11-19T00:00:00Z"}
        doc = {"records": [], "unpublished": [], "feeds": bad + [good]}
        self.assertEqual(ns.parse_history(Issue.packed(doc))["feeds"], [good])
        self.assertNotIn("feeds", ns.parse_history(Issue.packed({"records": [], "feeds": {"a": 1}})))

    def test_the_pr_json_holds_no_host_runner_or_diff(self):
        end, feeds, git = self.busy_week()
        span = {"from": ns.iso(end - 8 * 86400), "to": ns.iso(end)}
        data = fixture_attribution(feeds[-3:], ".", run=git, now=end, feeds=feeds, classified=span)
        rec = fixture_record()
        self.assertTrue(rec.get("hosts") and rec.get("jobs"), "the fixture carries hosts and jobs")
        with tempfile.TemporaryDirectory() as tmp:
            state, out, full = (os.path.join(tmp, n) for n in ("state.json", "pr.json", "check.json"))
            with open(state, "w", encoding="utf-8") as f:
                json.dump({"records": [rec], "pr_attribution": data}, f)
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(ns.main(["check", "--state", state, "--pr-json", out, "--json", full,
                                          "--git-dir", tmp]), 0)
            with open(out, encoding="utf-8") as f:
                doc = json.load(f)
            with open(full, encoding="utf-8") as f:
                self.assertIn("build_runner", f.read(), "the full check JSON names runners; the PR JSON must not")

        def keys(v):
            if isinstance(v, dict):
                for k, x in v.items():
                    yield k
                    yield from keys(x)
            elif isinstance(v, list):
                for x in v:
                    yield from keys(x)

        found = set(keys(doc))
        for banned in ("build_runner", "hosts", "host", "runners", "runner", "jobs", "diff", "bisect", "stages", "subject", "slow"):
            self.assertNotIn(banned, found)
        self.assertEqual(set(doc["rows"][0]), {"pr", "sha", "merged_at", "feed_sha", "feed_at", "merge_to_nightly",
                                               "reason", "pr_number", "merge_sha", "feed_source_sha",
                                               "feed_uploaded_at", "pr_merge_to_feed_min"})
        self.assertEqual((doc["partial"], doc["count"], len(doc["rows"])), (False, len(feeds) - 1, len(feeds) - 1))
        self.assertEqual(doc["observed_window"], {"from": data["oldest_feed"], "to": data["until"]})


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
        gh = FakeGh(api={"workflows/nightly.yml/runs": {"workflow_runs": [one_job_run()] + RUNS}, **FAILED_SIGN_JOBS,
                         "runs/43300000001/attempts/1/jobs": {"jobs": one_job_jobs()},
                         "runs/43189297315/attempts/1/jobs": {"jobs": SIGN_JOBS},
                         "runs/43185474901/attempts/1/jobs": {"jobs": PUSH_JOBS}})
        st = ns.record("o/r", "o/hq", 8, ".", "origin/feat-cmux-next", "t", "h", run=gh)
        self.assertEqual(st["new"], ["4318547490101", "4330000000101"], "the two-run build and the one-job build")
        apis = [c[0][2] for c in gh.calls if c[0][:2] == ["gh", "api"] and "/pulls?" not in c[0][2]]
        self.assertEqual(len(apis), 6, "one list, two job lists for the two-run build, one for the one-job build, "
                                       "one for each failed sign run")
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
        self.assertEqual(len([c for c in gh2.calls if c[0][:2] == ["gh", "api"] and "/pulls?" not in c[0][2]]), 1)

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
        self.assertEqual(len([c for c in gh2.calls if c[0][:2] == ["gh", "api"] and "/pulls?" not in c[0][2]]), 1, "its jobs are not read again")

    def test_a_push_run_listed_before_its_sign_run_is_forgotten_once_the_sign_run_is_listed(self):
        push = next(r for r in RUNS if r["id"] == 43185474901)
        gh = FakeGh(api={"workflows/nightly.yml/runs": {"workflow_runs": [push]},
                         "runs/43185474901/attempts/1/jobs": {"jobs": PUSH_JOBS}})
        st = ns.record("o/r", "o/hq", 8, ".", "origin/feat-cmux-next", "t", "h", run=gh)
        self.assertEqual(st["new_unpublished"], [43185474901])
        body = ns.issue_body(st["records"], st["unpublished"], ".", run=gh)
        gh2 = FakeGh(issues=[{"number": 9, "title": ns.ISSUE_TITLE, "body": body}],
                     api={"workflows/nightly.yml/runs": {"workflow_runs": RUNS}, **FAILED_SIGN_JOBS,
                          "runs/43189297315/attempts/1/jobs": {"jobs": SIGN_JOBS},
                          "runs/43185474901/attempts/1/jobs": {"jobs": PUSH_JOBS}})
        st2 = ns.record("o/r", "o/hq", 8, ".", "origin/feat-cmux-next", "t", "h", run=gh2)
        self.assertEqual(st2["new"], ["4318547490101"])
        self.assertNotIn(43185474901, [u["sign_run"] for u in st2["unpublished"]])

    def test_a_rerun_of_an_unpublished_sign_run_that_publishes_is_recorded(self):
        failed = [{**r, "conclusion": "failure"} if r["id"] == 43189297315 else r for r in RUNS]
        gh = FakeGh(api={"workflows/nightly.yml/runs": {"workflow_runs": failed}, **FAILED_SIGN_JOBS,
                         "runs/43189297315/attempts/1/jobs": {"jobs": SIGN_JOBS}})
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
        gh = FakeGh(api=api(failed, **{"runs/43300000001/attempts/1/jobs": {"jobs": one_job_jobs()}}, **FAILED_SIGN_JOBS,
                            **{"runs/43189297315/attempts/1/jobs": {"jobs": SIGN_JOBS}}))
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
        self.assertEqual(len([c for c in gh3.calls if c[0][:2] == ["gh", "api"] and "/pulls?" not in c[0][2]]), 1)

    def test_a_rerun_that_publishes_nothing_again_is_read_once_per_attempt(self):
        def record(attempt, body=None):
            runs = [{**one_job_run(), "run_attempt": attempt}]
            gh = FakeGh(issues=[{"number": 9, "title": ns.ISSUE_TITLE, "body": body}] if body else [],
                        api={"workflows/nightly.yml/runs": {"workflow_runs": runs},
                             f"runs/43300000001/attempts/{attempt}/jobs": {"jobs": one_job_jobs(feed=False)}})
            st = ns.record("o/r", "o/hq", 8, ".", "origin/feat-cmux-next", "t", "h", run=gh)
            reads = len([c for c in gh.calls if c[0][:2] == ["gh", "api"] and "/pulls?" not in c[0][2]])
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
            self.assertEqual(len([c for c in gh.calls if c[0][:2] == ["gh", "api"] and "/pulls?" not in c[0][2]]), reads, f"attempt {attempt}")

    def test_a_completed_run_is_read_whatever_its_conclusion_or_event(self):
        # A job after the publisher can fail a run that published (run 44087850352), and a dispatch publishes too
        # (run 44904268153): failed, cancelled and dispatched runs are read once each; one in progress is not.
        runs = [one_job_run(1, "failure"), one_job_run(2, "cancelled"), one_job_run(3, None, "in_progress"),
                {**one_job_run(4), "event": "workflow_dispatch"}]
        gh = FakeGh(api={"workflows/nightly.yml/runs": {"workflow_runs": runs},
                         **{f"runs/{i}/attempts/1/jobs": {"jobs": one_job_jobs(feed=False)} for i in (1, 2, 4)}})
        st = ns.record("o/r", "o/hq", 8, ".", "origin/feat-cmux-next", "t", "h", run=gh)
        self.assertEqual((st["new"], sorted(st["new_unpublished"]), st["why"]), ([], [1, 2, 4], None))
        self.assertEqual(sorted(u["conclusion"] for u in st["unpublished"]),
                         ["cancelled", "failure", "success, no feed upload"])
        self.assertEqual(len([c for c in gh.calls if c[0][:2] == ["gh", "api"] and "/pulls?" not in c[0][2]]), 4)

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
        # The feed list is seeded from the records (verified publications), and past the 7 days keeps only the one
        # feed before the window.
        self.assertEqual([e["build"] for e in ns.parse_history(body)["feeds"]], ["4318547490101"])
        self.assertEqual([e["build"] for e in ns.parse_history(gh2.written)["feeds"]], ["b30"])

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
                    api={"workflows/nightly.yml/runs": {"workflow_runs": RUNS}, **FAILED_SIGN_JOBS,
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


class PublicationReceipt(unittest.TestCase):
    """A record is a publication only when the write-gated read-back after the upload passed: write_feed exits zero
    without writing on a refused (superseded) write and on an already-live replay."""

    @staticmethod
    def jobs(readback):
        jobs = copy.deepcopy(one_job_jobs())
        if readback:
            jobs[1]["steps"].append({"name": ns.READBACK_STEP, "conclusion": readback, "started_at": "2026-11-13T01:20:40Z",
                                     "completed_at": "2026-11-13T01:20:42Z" if readback != "skipped" else None})
        return jobs

    def test_an_upload_whose_read_back_was_skipped_wrote_nothing_and_is_unpublished(self):
        rec, why = ns.build_record(one_job_run(), one_job_run(), [], self.jobs("skipped"), None)
        self.assertEqual((rec, why), (None, ns.NO_FRESH_WRITE))
        gh = FakeGh(api={"workflows/nightly.yml/runs": {"workflow_runs": [one_job_run()]},
                         "runs/43300000001/attempts/1/jobs": {"jobs": self.jobs("skipped")}})
        st = ns.record("o/r", "o/hq", 8, ".", "origin/feat-cmux-next", "t", "h", run=gh)
        self.assertEqual((st["new"], st["new_unpublished"]), ([], [43300000001]))
        self.assertEqual(st["unpublished"][0]["conclusion"], "success, no fresh write")
        self.assertEqual(st["feeds"], [], "no feed entry either")
        rec, why = ns.build_record(one_job_run(), one_job_run(), [], self.jobs("failure"), None)
        self.assertEqual((rec, why), (None, "read-back failed"))

    def test_an_upload_and_its_read_back_publish_at_the_upload_time(self):
        rec, why = ns.build_record(one_job_run(), one_job_run(), [], self.jobs("success"), None)
        self.assertIsNone(why)
        self.assertEqual((rec["feed_at"], rec["confirmed"]), ("2026-11-13T01:20:40Z", True), "the upload's completed_at")
        self.assertTrue(ns.sound_record(rec))
        self.assertEqual(ns.feed_list([], [rec], ns.ts("2026-11-14T00:00:00Z"))[0]["confirmed"], True)
        # A pipeline without the read-back step keeps its record, unconfirmed.
        rec, _ = ns.build_record(one_job_run(), one_job_run(), [], self.jobs(None), None)
        self.assertIs(rec["confirmed"], False)

    def test_a_failed_run_that_published_is_recorded(self):
        # cmux run 44087850352: nightly-next-one uploaded the feed at 13:20:56Z and read it back at 13:20:58Z; a later
        # job (attest-nightly-remote-daemon) failed the run. It was missing from the history.
        doc = load("run-44087850352-1.json")
        run, jobs = doc["run"], doc["jobs"]
        self.assertEqual((run["conclusion"], next(j for j in jobs if j["name"] == "nightly-next-one")["conclusion"]),
                         ("failure", "success"))
        gh = FakeGh(api={"workflows/nightly.yml/runs": {"workflow_runs": [run]},
                         "runs/44087850352/attempts/1/jobs": {"jobs": jobs}})
        st = ns.record("o/r", "o/hq", 8, ".", "origin/feat-cmux-next", "t", "h", run=gh)
        self.assertEqual((st["new"], st["new_unpublished"]), (["4408785035201"], []))
        r = st["records"][0]
        self.assertEqual((r["feed_at"], r["confirmed"], r["sha"]),
                         ("2026-11-17T13:20:56Z", True, "99b627ab8ac5011f3e2732936f63178bf614baea"))
        self.assertEqual(st["feeds"][0]["feed_at"], "2026-11-17T13:20:56Z")
        # Its read-back skipped (nothing written): a failed run is unpublished, with its own conclusion.
        unread = copy.deepcopy(jobs)
        for j in unread:
            for step in j["steps"]:
                if step["name"] == ns.READBACK_STEP:
                    step["conclusion"] = "skipped"
        gh = FakeGh(api={"workflows/nightly.yml/runs": {"workflow_runs": [run]},
                         "runs/44087850352/attempts/1/jobs": {"jobs": unread}})
        st = ns.record("o/r", "o/hq", 8, ".", "origin/feat-cmux-next", "t", "h", run=gh)
        self.assertEqual((st["new"], st["new_unpublished"]), ([], [44087850352]))
        self.assertEqual(st["unpublished"][0]["conclusion"], "failure")

    def test_a_retry_dispatch_that_wrote_the_feed_is_recorded(self):
        # cmux run 44904268153, "Retry nightly-next (1 of 2)": a workflow_dispatch, neither a push nor a sign run.
        doc = load("run-44904268153-1.json")
        run, jobs = doc["run"], doc["jobs"]
        self.assertEqual((run["event"], run["display_title"]), ("workflow_dispatch", "Retry nightly-next (1 of 2)"))
        gh = FakeGh(api={"workflows/nightly.yml/runs": {"workflow_runs": [run]},
                         "runs/44904268153/attempts/1/jobs": {"jobs": jobs}})
        st = ns.record("o/r", "o/hq", 8, ".", "origin/feat-cmux-next", "t", "h", run=gh)
        self.assertEqual((st["new"], st["why"]), (["4490426815301"], None))
        r = st["records"][0]
        self.assertEqual((r["feed_at"], r["confirmed"], r["sha"]),
                         ("2026-11-21T12:59:48Z", True, "a9aa7a318206e006b1758ea8f9f47effc4e9d825"))
        self.assertEqual(len([c for c in gh.calls if c[0][:2] == ["gh", "api"] and "/pulls?" not in c[0][2]]), 2, "one list, one job list")
        # A tail-only dispatch (the publisher skipped, no write) is no publication.
        tail = [j for j in jobs if j["name"] != "nightly-next-one"]
        gh = FakeGh(api={"workflows/nightly.yml/runs": {"workflow_runs": [run]},
                         "runs/44904268153/attempts/1/jobs": {"jobs": tail}})
        st = ns.record("o/r", "o/hq", 8, ".", "origin/feat-cmux-next", "t", "h", run=gh)
        self.assertEqual((st["new"], st["new_unpublished"], st["feeds"]), ([], [44904268153], []))

    def test_an_earlier_attempt_that_published_joins_the_feed_list(self):
        rerun = {**one_job_run(), "run_attempt": 3, "conclusion": "failure"}
        gh = FakeGh(api={"workflows/nightly.yml/runs": {"workflow_runs": [rerun]},
                         "runs/43300000001/attempts/3/jobs": {"jobs": one_job_jobs(feed=False)},
                         "runs/43300000001/attempts/2/jobs": {"jobs": one_job_jobs(feed=False)},
                         "runs/43300000001/attempts/1/jobs": {"jobs": self.jobs("success")}})
        st = ns.record("o/r", "o/hq", 8, ".", "origin/feat-cmux-next", "t", "h", run=gh)
        self.assertEqual((st["new"], st["new_unpublished"]), ([], [43300000001]))
        self.assertEqual([(e["build"], e["confirmed"]) for e in st["feeds"]], [("4330000000101", True)])
        self.assertEqual(len([c for c in gh.calls if c[0][:2] == ["gh", "api"] and "/pulls?" not in c[0][2]]), 4, "the list and three attempts")
        # A rerun of a recorded run is read at its new attempt; the older record's attempt is not read again.
        rec, _ = ns.build_record(one_job_run(), one_job_run(), [], self.jobs("success"), None)
        body = ns.issue_body([rec], [], ".", run=gh)
        gh2 = FakeGh(issues=[{"number": 9, "title": ns.ISSUE_TITLE, "body": body}],
                     api={"workflows/nightly.yml/runs": {"workflow_runs": [{**one_job_run(), "run_attempt": 2}]},
                          "runs/43300000001/attempts/2/jobs": {"jobs": one_job_jobs(feed=False)}})
        st2 = ns.record("o/r", "o/hq", 8, ".", "origin/feat-cmux-next", "t", "h", run=gh2)
        self.assertEqual((st2["new"], st2["new_unpublished"], [r["build"] for r in st2["records"]]),
                         ([], [43300000001], ["4330000000101"]))
        self.assertEqual(len([c for c in gh2.calls if c[0][:2] == ["gh", "api"] and "/pulls?" not in c[0][2]]), 2)
        self.assertEqual([(u["sign_run"], u["attempt"]) for u in st2["unpublished"]], [(43300000001, 2)],
                         "the later attempt's line stays beside the record: it is how that attempt is known")

    def test_seeded_unconfirmed_feeds_keep_the_partial_label(self):
        end, feeds, git = PrAttribution.busy_week()
        span = {"from": ns.iso(end - 8 * 86400), "to": ns.iso(end)}
        seeded = [{k: v for k, v in f.items() if k != "confirmed"} for f in feeds]  # records from before receipts
        data = fixture_attribution([], ".", run=git, now=end, feeds=seeded, classified=span, confirm_feeds=False)
        self.assertEqual((data["attributed"], data["unconfirmed"], data["feeds"]), (0, len(feeds), len(feeds)),
                         "unconfirmed publications do not enter percentiles")
        self.assertTrue(data["partial"])
        verdict = {"build": "b59", "sha": feeds[-1]["sha"], "merge_to_feed": 20.0, "verdict": "in budget",
                   "budget_min": 30.0, "window": 1, "over": False, "p50": 20.0, "p95": 20.0,
                   "feed_at": feeds[-1]["feed_at"], "slow": {}, "diff": None, "bisect": []}
        text = ns.render_verdict({**verdict, "pr_attribution": data})
        self.assertIn("(partial: observed window)", text)
        self.assertIn(f"{len(feeds)} of {len(feeds)} feeds are unconfirmed (no read-back receipt).", text)
        # One unconfirmed feed among confirmed ones is enough to keep it.
        mixed = feeds[:30] + seeded[30:31] + feeds[31:]
        self.assertTrue(fixture_attribution([], ".", run=git, now=end, feeds=mixed, classified=span, confirm_feeds=False)["partial"])
        self.assertFalse(fixture_attribution([], ".", run=git, now=end, feeds=feeds, classified=span)["partial"])
        # A stored confirmed entry is not downgraded by its unconfirmed record.
        self.assertTrue(ns.feed_list(feeds[-1:], seeded[-1:], end)[0]["confirmed"])

    def test_a_run_head_sha_keeps_the_partial_label(self):
        # The ledger's job and time pairs are proven, its sha is the run head: nightly.yml may publish a recovered
        # or republished build, so an entry with no published build_sha never proves the window.
        doc = load("feeds-ledger-excerpt.json")
        ledger = [dict(zip(doc["fields"], r)) for r in doc["records"]]
        kept = ns.feed_list([{**e, "confirmed": True} for e in ledger], [], ns.ts("2026-11-21T13:00:00Z"), 7)
        self.assertEqual([(e["build"], e["confirmed"], e["sha_source"], e["confirmed_identity"]) for e in kept],
                         [(e["build"], True, "run_head", False) for e in ledger])
        end, feeds, git = PrAttribution.busy_week()
        span = {"from": ns.iso(end - 8 * 86400), "to": ns.iso(end)}
        head = [{k: v for k, v in f.items() if k not in ("sha_source", "confirmed_identity")} for f in feeds]
        claimed = [{**f, "confirmed_identity": True} for f in head]  # identity claimed with no build_sha source
        for fs in (head, claimed, feeds[:30] + head[30:31] + feeds[31:]):
            data = fixture_attribution([], ".", run=git, now=end, feeds=fs, classified=span, confirm_feeds=False)
            self.assertTrue(data["partial"])
            self.assertEqual(data["attributed"], 0 if fs is head or fs is claimed else len(feeds) - 1,
                             "only verified publications enter percentiles")
        data = fixture_attribution([], ".", run=git, now=end, feeds=head, classified=span, confirm_feeds=False)
        self.assertEqual((data["unconfirmed"], data["unidentified"]), (0, len(feeds)))
        verdict = {"build": "b59", "sha": feeds[-1]["sha"], "merge_to_feed": 20.0, "verdict": "in budget",
                   "budget_min": 30.0, "window": 1, "over": False, "p50": 20.0, "p95": 20.0,
                   "feed_at": feeds[-1]["feed_at"], "slow": {}, "diff": None, "bisect": []}
        text = ns.render_verdict({**verdict, "pr_attribution": data})
        self.assertIn(f"{len(feeds)} of {len(feeds)} feeds name the run's head commit, not the published build_sha "
                      "(identity unconfirmed).", text)
        # A record names its run head, so its entry is never identity-confirmed and never upgrades a stored one.
        self.assertFalse(ns.feed_entry({**feeds[-1], "sha_source": None})["confirmed_identity"])
        self.assertTrue(ns.feed_list(feeds[-1:], head[-1:], end)[0]["confirmed_identity"])

    def test_signed_notes_confirm_a_feeds_identity(self):
        # The publisher's notes of build 4490426815301 as the public feed serves them, verified with its content key.
        with open(os.path.join(FIX, "notes-4490426815301.json"), "rb") as f:
            body = f.read()
        with open(os.path.join(FIX, "notes-4490426815301.json.sig"), "rb") as f:
            sig = f.read()
        urls = []

        def fetch(url, files={".json": body, ".json.sig": sig}):
            urls.append(url)
            for ext, data in sorted(files.items(), key=lambda kv: -len(kv[0])):
                if url.endswith(ext):
                    return data
            raise OSError("404")

        head = "a9aa7a318206e006b1758ea8f9f47effc4e9d825"
        self.assertEqual(ns.signed_head("4490426815301", fetch), head)
        self.assertEqual(urls, [ns.NOTES_FEED + "4490426815301.json", ns.NOTES_FEED + "4490426815301.json.sig"])
        self.assertIsNone(ns.signed_head("4490426815302", fetch), "notes of another build")
        tampered = body.replace(head.encode(), b"0" * 40)
        self.assertIsNone(ns.signed_head("4490426815301", lambda u: tampered if u.endswith(".json") else sig))
        self.assertIsNone(ns.signed_head("4490426815301", lambda u: (_ for _ in ()).throw(OSError("down"))))
        self.assertIsNone(ns.signed_head("../x", fetch), "a build reaches a URL only as digits")
        # Through record(): the retry run's feed is identity-confirmed by its notes; with no notes reader it is not.
        doc = load("run-44904268153-1.json")
        api = {"workflows/nightly.yml/runs": {"workflow_runs": [doc["run"]]},
               "runs/44904268153/attempts/1/jobs": {"jobs": doc["jobs"]}}
        st = ns.record("o/r", "o/hq", 8, ".", "origin/feat-cmux-next", "t", "h", run=FakeGh(api=api),
                       notes=lambda b: ns.signed_head(b, fetch))
        self.assertEqual([(e["sha"], e["sha_source"], e["confirmed"], e["confirmed_identity"]) for e in st["feeds"]],
                         [(head, "signed_notes", True, True)])
        st = ns.record("o/r", "o/hq", 8, ".", "origin/feat-cmux-next", "t", "h", run=FakeGh(api=api))
        self.assertEqual([(e["sha_source"], e["confirmed_identity"]) for e in st["feeds"]], [("run_head", False)])

    def test_signed_notes_replace_a_run_head_and_are_bounded(self):
        end, feeds, git = PrAttribution.busy_week()
        head = [{k: v for k, v in f.items() if k not in ("sha_source", "confirmed_identity")} for f in feeds]
        asked = []
        other = "f" * 40

        def notes(build):
            asked.append(build)
            return other if build == head[-1]["build"] else None

        out = ns.identify(ns.feed_list(head, [], end), notes)
        self.assertEqual(asked, [f["build"] for f in head[::-1][:ns.NOTES_PER_PASS]], "newest first, bounded")
        self.assertEqual((out[-1]["sha"], out[-1]["sha_source"], out[-1]["confirmed_identity"]),
                         (other, "signed_notes", True), "the notes' head is the published build's, not the run's")
        self.assertEqual(sum(e["confirmed_identity"] for e in out), 1)
        asked.clear()
        ns.identify(ns.feed_list(feeds, [], end), notes)
        self.assertEqual(asked, [], "identified entries are not read again")

    def test_coverage_needs_every_run_classified(self):
        end, feeds, git = PrAttribution.busy_week()
        since = end - 7 * 86400
        # Classified only from inside the window, or only up to before the newest attributed feed: partial.
        for span in ({"from": ns.iso(since + 3600), "to": ns.iso(end)},
                     {"from": ns.iso(end - 8 * 86400), "to": feeds[-2]["feed_at"]}):
            data = fixture_attribution([], ".", run=git, now=end, feeds=feeds, classified=span)
            self.assertTrue(data["partial"], span)
            verdict = {"build": "b59", "sha": feeds[-1]["sha"], "merge_to_feed": 20.0, "verdict": "in budget",
                       "budget_min": 30.0, "window": 1, "over": False, "p50": 20.0, "p95": 20.0,
                       "feed_at": feeds[-1]["feed_at"], "slow": {}, "diff": None, "bisect": []}
            self.assertIn(f"runs are classified from {span['from']} to {span['to']}",
                          ns.render_verdict({**verdict, "pr_attribution": data}))

    def test_the_classified_span_grows_only_over_a_contiguous_run_list(self):
        def run(i, start, status="completed"):
            return {"id": i, "event": "push", "status": status, "conclusion": "success", "run_attempt": 1,
                    "display_title": "x", "created_at": start, "run_started_at": start}
        state = {"records": [{"sign_run": 1}], "unpublished": [{"sign_run": 2, "attempt": 1}]}
        runs = [run(1, "2026-11-20T01:00:00Z"), run(2, "2026-11-20T02:00:00Z")]
        now = "2026-11-20T03:00:00Z"
        self.assertEqual(ns.classified_span(None, runs, set(), state, "", now), {"from": "", "to": now},
                         "a list shorter than a page holds every run")
        prev = {"from": "2026-11-10T00:00:00Z", "to": "2026-11-19T00:00:00Z"}
        self.assertEqual(ns.classified_span(prev, runs, set(), state, "", now)["from"], prev["from"])
        full = runs + [run(100 + i, "2026-11-19T12:00:00Z") for i in range(ns.LIST_PAGE)]
        state["unpublished"] += [{"sign_run": 100 + i, "attempt": 1} for i in range(ns.LIST_PAGE)]
        self.assertEqual(ns.classified_span(prev, full, set(), state, "", now)["from"], "2026-11-19T12:00:00Z",
                         "a full page that does not reach back to the stored span starts a new one")
        waiting = runs + [run(3, "2026-11-20T02:30:00Z", "in_progress")]
        self.assertEqual(ns.classified_span(prev, waiting, set(), state, "", now)["to"], "2026-11-20T02:30:00Z",
                         "the span ends where a run is not classified yet")

    def test_a_span_that_ends_before_the_report_is_partial(self):
        # A confirmed predecessor, a last feed at 10:00, runs classified to 10:00, a merge at 11:00 with no feed yet,
        # and a report until 12:00: the runs after 10:00 are unread, so a feed holding that merge may exist.
        end, feeds, git = PrAttribution.busy_week()
        last = ns.ts(feeds[-1]["feed_at"])
        span = {"from": ns.iso(end - 8 * 86400), "to": feeds[-1]["feed_at"]}
        rows = [{"status": "unattributed", "feed_at": None}]
        pairs = [(ns.ts(f["feed_at"]), {**f, "confirmed": True, "confirmed_identity": True}) for f in feeds]
        self.assertFalse(ns.covered(rows, pairs, end - 7 * 86400, last + 7200, span))
        self.assertTrue(ns.covered(rows, pairs, end - 7 * 86400, last, span), "a span to the report's end covers it")
        self.assertTrue(ns.covered(rows, pairs, end - 7 * 86400, last + 0.75, span),
                        "the span is stored to the second: 14:03:13Z covers a report until 14:03:13.750")
        data = fixture_attribution([], ".", run=git, now=last + 7200,
                                 feeds=[{**f, "confirmed": True, "confirmed_identity": True} for f in feeds],
                                 classified=span)
        self.assertTrue(data["partial"])

    def test_a_rerun_with_unread_earlier_attempts_stays_unclassified(self):
        def run(i, start, attempt):
            return {"id": i, "event": "push", "status": "completed", "conclusion": "success", "run_attempt": attempt,
                    "display_title": "x", "created_at": start, "run_started_at": start}
        now = "2026-11-20T03:00:00Z"
        runs = [run(1, "2026-11-20T01:00:00Z", 1), run(2, "2026-11-20T02:00:00Z", 4)]
        state = {"records": [{"sign_run": 1}, {"sign_run": 2, "sign_attempt": 4}], "unpublished": []}
        self.assertEqual(ns.classified_span(None, runs, set(), state, "", now)["to"], "2026-11-20T02:00:00Z",
                         "only attempt 4 is known: attempts 1 to 3 may have published")
        span = ns.classified_span(None, runs, set(), state, "", now, {(2, 4)})
        self.assertEqual((span["to"], span["complete"]), (now, [[2, 4]]), "every earlier attempt read")
        self.assertEqual(ns.classified_span(span, runs, set(), state, "", now)["to"], now, "kept with the span")
        body = ns.history_comment([], [], classified=span)
        self.assertEqual(ns.parse_history(body)["classified"]["complete"], [[2, 4]])
        # record() reads EARLIER_ATTEMPTS earlier attempts; a run at attempt 4 has three, so it is not complete.
        r4 = {**one_job_run(), "run_attempt": 4}
        api = {"workflows/nightly.yml/runs": {"workflow_runs": [r4]}}
        for k in (4, 3, 2, 1):
            api[f"runs/43300000001/attempts/{k}/jobs"] = {"jobs": one_job_jobs(feed=False)}
        st = ns.record("o/r", "o/hq", 8, ".", "origin/feat-cmux-next", "t", "h", run=FakeGh(api=api))
        self.assertEqual(st["classified"]["to"], ns.started(r4))
        self.assertNotIn("complete", st["classified"])
        r3 = {**r4, "run_attempt": 3}
        api["workflows/nightly.yml/runs"] = {"workflow_runs": [r3]}
        st = ns.record("o/r", "o/hq", 8, ".", "origin/feat-cmux-next", "t", "h", run=FakeGh(api=api))
        self.assertEqual(st["classified"]["complete"], [[43300000001, 3]])
        self.assertGreaterEqual(st["classified"]["to"], ns.started(r3))

    def test_each_pr_is_counted_once_at_its_github_merge(self):
        """The readback at 96b7b447: #37003 counted twice, at its GitHub merge b6fff4f6f10 (1,838.5 min) and at the
        direct follow-up 68216e37903 naming the same number (205.6 min); 77484148ba, a direct pin commit, claimed
        #46990, which GitHub merged before the window."""
        with tempfile.TemporaryDirectory() as repo:
            git_fixture_env.init_repo(repo, "-b", "main")
            env = git_fixture_env.fixture_env()

            def g(*args, when=None, direct=False):
                e = dict(env, GIT_AUTHOR_NAME="a", GIT_AUTHOR_EMAIL="a@e",
                         GIT_COMMITTER_NAME="a" if direct else "GitHub",
                         GIT_COMMITTER_EMAIL="a@e" if direct else ns.GITHUB_COMMITTER)
                if when:
                    e.update(GIT_COMMITTER_DATE=when, GIT_AUTHOR_DATE=when)
                return subprocess.run(["git", "-C", repo, *args], env=e, check=True, capture_output=True,
                                      text=True).stdout.strip()

            g("commit", "--allow-empty", "-qm", "start", when="2026-11-17T00:00:00Z")
            start = g("rev-parse", "HEAD")
            g("commit", "--allow-empty", "-qm", "cmux Computer Use: a from-scratch engine (#37003)",
              when="2026-11-18T00:00:00Z")
            merge = g("rev-parse", "HEAD")
            g("commit", "--allow-empty", "-qm", "Cloud image computer use: failing tests and probe (#37003)",
              when="2026-11-19T00:00:00Z", direct=True)
            follow = g("rev-parse", "HEAD")
            g("commit", "--allow-empty", "-qm", "cmux-next: pin CCmuxAppFFI (#46990)", when="2026-11-19T01:00:00Z",
              direct=True)
            head = g("rev-parse", "HEAD")
            data = fixture_attribution([{"build": "n0", "sha": start, "feed_at": "2026-11-17T01:00:00Z"},
                                      {"build": "n1", "sha": head, "feed_at": "2026-11-19T02:00:00Z"}], repo, "main",
                                     now=ns.ts("2026-11-20T00:00:00Z"), window_days=3)
        rows = {r["sha"]: r for r in data["rows"]}
        self.assertEqual((rows[merge]["status"], rows[merge]["merge_to_nightly"]), ("attributed", 1560.0))
        self.assertEqual((rows[follow]["reason"], rows[follow]["canonical_sha"]), (ns.DUPLICATE_PR, merge))
        self.assertEqual([r["reason"] for r in data["rows"] if r["pr"] == 46990], [ns.DIRECT_PR])
        self.assertEqual((data["attributed"], data["p50"]), (1, 1560.0), "one PR, one time")
        self.assertEqual(data["reasons"], {ns.DUPLICATE_PR: 1, ns.DIRECT_PR: 1, "no PR number in merge metadata": 1})


class VerifiedPrAttribution(unittest.TestCase):
    def test_provider_clock_identity_and_first_verified_feed(self):
        graph = PrAttribution.Git()
        graph.log += "m5\tp1\t1794700800\tspoofed merge (#101)\0noreply@github.com\n"
        feeds = [
            {"build": "old", "sha": "a0a0a0a", "feed_at": "2026-11-13T12:00:00Z"},
            {"build": "unverified", "sha": "a1a1a1a", "feed_at": "2026-11-14T00:30:00Z", "confirmed": False},
            {"build": "first", "sha": "a1a1a1a", "feed_at": "2026-11-14T01:00:00Z"},
            {"build": "retry", "sha": "a1a1a1a", "feed_at": "2026-11-14T02:00:00Z"},
        ]
        feeds = [{"confirmed": True, "confirmed_identity": True, "sha_source": "signed_notes", **f} for f in feeds]
        provider = {"complete": True, "rows": [{"pr": 101, "sha": "m1", "merged_at": "2026-11-14T00:02:00Z"}]}
        result = ns.pr_attribution(feeds, ".", run=graph, now=ns.ts("2026-11-20T00:00:00Z"),
                                   provider_merges=provider)
        doc = ns.pr_stream(result)
        row = next(r for r in doc["rows"] if r["sha"] == "m1")
        self.assertEqual((row["pr_number"], row["merge_sha"], row["feed_source_sha"],
                          row["feed_uploaded_at"], row["pr_merge_to_feed_min"]),
                         (101, "m1", "a1a1a1a", "2026-11-14T01:00:00Z", 58.0))
        self.assertEqual((doc["matched_prs"], doc["excluded_commits"], doc["unverified_feeds"]), (1, 4, 1))
        self.assertTrue(doc["coverage_partial"])
        self.assertEqual((doc["p50"], doc["p90"]), (58.0, 58.0))
        replay = ns.pr_attribution(list(reversed(feeds)), ".", run=graph,
                                   now=ns.ts("2026-11-20T00:00:00Z"), provider_merges=provider)
        self.assertEqual(ns.pr_stream(replay), doc)

    def test_missing_provider_never_falls_back_to_committer_metadata(self):
        result = ns.pr_attribution([], ".", run=PrAttribution.Git(), now=ns.ts("2026-11-20T00:00:00Z"))
        self.assertEqual((result["matched_prs"], result["p50"], result["p90"]), (0, None, None))
        self.assertFalse(result["provider_complete"])
        self.assertTrue(result["partial"])
        self.assertTrue(all(row["merged_at"] is None for row in result["rows"]))

    def test_provider_merge_without_message_marker_or_matching_commit_clock(self):
        def graph(cmd, **kw):
            if "log" in cmd:
                return subprocess.CompletedProcess(cmd, 0, "", "")
            if "rev-list" in cmd:
                self.assertFalse(any(x.startswith("--since") for x in cmd))
                return subprocess.CompletedProcess(cmd, 0, "m1" if cmd[-1] == "aaaaaaa" else "", "")
            return subprocess.CompletedProcess(cmd, 0, "", "")
        provider = {"complete": True, "rows": [{"pr": 7, "sha": "m1", "merged_at": "2026-11-14T01:00:00Z"}]}
        feeds = [{"build": "old", "sha": "bbbbbbb", "feed_at": "2026-11-13T01:00:00Z"},
                 {"build": "first", "sha": "aaaaaaa", "feed_at": "2026-11-14T01:00:00Z"}]
        feeds = [{**f, "confirmed": True, "confirmed_identity": True, "sha_source": "signed_notes"} for f in feeds]
        result = ns.pr_attribution(feeds, ".", run=graph, now=ns.ts("2026-11-20T00:00:00Z"), provider_merges=provider)
        self.assertEqual((result["matched_prs"], result["p50"]), (1, 0.0))
        provider["rows"][0]["merged_at"] = "2026-11-14T01:00:01Z"
        result = ns.pr_attribution(feeds, ".", run=graph, now=ns.ts("2026-11-20T00:00:00Z"), provider_merges=provider)
        self.assertEqual((result["unmatched_prs"], result["p50"]), (1, None))

    def test_provider_pages_validate_base_and_merge_not_subject(self):
        entry = {"number": 7, "merge_commit_sha": "a" * 40, "merged_at": "2026-11-14T01:00:00Z",
                 "updated_at": "2026-11-14T02:00:00Z", "base": {"ref": "feat-cmux-next"}}
        gh = FakeGh(api={"&page=1": [entry] * 100, "&page=2": [
            {**entry, "number": 8, "merged_at": None},
            {**entry, "number": 9, "base": {"ref": "main"}}]})
        result = ns.provider_pr_merges("o/r", "origin/feat-cmux-next", ns.ts("2026-11-13T00:00:00Z"), "t", gh)
        self.assertTrue(result["complete"])
        self.assertEqual(result["rows"], [{"pr": 7, "sha": "a" * 40, "merged_at": "2026-11-14T01:00:00Z"}])
        self.assertEqual(len(gh.calls), 2)
        limited = ns.provider_pr_merges("o/r", "origin/feat-cmux-next", ns.ts("2026-11-13T00:00:00Z"), "t", gh, max_pages=1)
        self.assertFalse(limited["complete"])
        self.assertEqual(limited["rows"], result["rows"])
        failed = ns.provider_pr_merges("o/r", "origin/feat-cmux-next", 0, "t", FakeGh())
        self.assertFalse(failed["complete"])
        self.assertIn("HTTP 404", failed["reason"])


if __name__ == "__main__":
    unittest.main()
