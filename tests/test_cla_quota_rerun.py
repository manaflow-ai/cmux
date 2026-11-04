#!/usr/bin/env python3
"""cla_quota_rerun.py re-runs only CLA checks the spent GITHUB_TOKEN budget failed (no network)."""

from __future__ import annotations

import datetime as dt
import io
import re
import sys
import unittest
import urllib.error
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

import cla_quota_rerun as rerun  # noqa: E402
import yaml  # noqa: E402

API = "https://api.github.com"
NOW = dt.datetime(2026, 10, 26, 4, 30, tzinfo=dt.timezone.utc)
LIMITED_LOG = "##[error]Could not complete the CLA check: ... API rate limit exceeded for installation."
# The guard hides every PolicyError, a failed API read included, behind this one line.
GUARD_LOG = ("Run set -euo pipefail\n  BASE_SHA: c0a00581d66f425cdb55bf1a4a9c349aca554668\n"
             "  PR_NUMBER: 25403\nPASS: test merge regression matrix (15 cases)\n"
             "##[error]CLA policy validation rejected the proposed policy\n")
GUARD_403_LOG = ("gh: API rate limit exceeded for installation ID 1 (HTTP 403)\n"
                 "##[error]CLA policy validation rejected the proposed policy\n")
GUARD = "CLA policy guard"
POLICY_CHANGE = [{"filename": ".github/workflows/cla.yml"}]
NO_POLICY = [{"filename": "Sources/App.swift"}, {"filename": "tests/test_app.py"}]


def run(run_id, head, *, number=1, attempt=1, name="CLA", updated="2026-10-26T04:00:00Z", conclusion="failure"):
    return {"id": run_id, "name": name, "head_sha": head, "run_attempt": attempt, "updated_at": updated,
            "status": "completed", "conclusion": conclusion, "number_hint": number,
            "pull_requests": [{"number": number, "head": {"sha": head}, "base": {"ref": "main"}}]}


def pull(number, head, base="main"):
    return {"number": number, "head": {"sha": head}, "base": {"ref": base}}


class FakeGitHub:
    def __init__(self, assistant, guard, logs, *, pulls=None, finished=None, remaining=9000, reset=None, files=None):
        # `remaining` may be a list: one value per rate_limit read, the last one repeating.
        # `files`: pull request number -> its changed files (default: one that changes CLA policy).
        self.assistant, self.guard, self.logs = assistant, guard, logs
        self.files = files or {}
        self.remaining = remaining if isinstance(remaining, list) else [remaining]
        self.reset = reset or NOW + dt.timedelta(hours=1)
        # By default every run's head is an open pull request into main.
        self.pulls = pulls if pulls is not None else [pull(r["number_hint"], r["head_sha"]) for r in assistant + guard]
        self.finished = finished or {}
        self.calls, self.posts = [], []
        self.repo = "o/r"
        self.errors = {}  # (method, path) -> HTTPErrors raised in turn, one per call

    def fail(self, method, path, code, **headers):
        headers = {key.replace("_", "-"): value for key, value in headers.items()}
        self.errors.setdefault((method, path), []).append(urllib.error.HTTPError(API + path, code, "x", headers, None))

    def request(self, method, path, raw=False):
        self.calls.append((method, path))
        pending = self.errors.get((method, path))
        if pending:
            # What GitHub.request raises for it.
            error = pending.pop(0)
            spent = rerun.spent_budget(error, path)
            raise spent if spent is not None else error
        if path == "/rate_limit":
            left = self.remaining.pop(0) if len(self.remaining) > 1 else self.remaining[0]
            return {"resources": {"core": {"limit": 15000, "remaining": left, "reset": int(self.reset.timestamp())}}}
        if method == "POST":
            self.posts.append(path)
            return {}
        if "/files?" in path:
            number = int(path.split("/pulls/")[1].split("/")[0])
            page = int(path.rsplit("page=", 1)[1])
            changed = self.files.get(number, POLICY_CHANGE)
            return changed[(page - 1) * 100:page * 100]
        if path.startswith("/repos/o/r/pulls?state=open"):
            base = path.split("base=")[1].split("&")[0]
            return [p for p in self.pulls if p["base"]["ref"] == base] if path.endswith("page=1") else []
        if "/workflows/cla.yml/runs" in path:
            return {"workflow_runs": self.assistant}
        if "/workflows/cla-policy-guard.yml/runs" in path:
            return {"workflow_runs": self.guard}
        if path.endswith("/jobs?filter=latest&per_page=10"):
            run_id = int(path.split("/runs/")[1].split("/")[0])
            return {"jobs": [{"id": run_id * 10, "conclusion": "failure",
                              "completed_at": self.finished.get(run_id, "2026-10-26T04:00:00Z")}]}
        if path.endswith("/logs"):
            job_id = int(path.split("/jobs/")[1].split("/")[0])
            return self.logs.get(job_id // 10, "")
        raise AssertionError(path)


def rerun_path(run_id):
    return f"/repos/o/r/actions/runs/{run_id}/rerun-failed-jobs"


class Tests(unittest.TestCase):
    def sweep(self, fake, dry=False, now=NOW, slept=None, code=0):
        env = {"GITHUB_REPOSITORY": "o/r", "GH_TOKEN": "app", "RATE_TOKEN": "workflow"}
        out = io.StringIO()
        slept = [] if slept is None else slept
        with mock.patch.object(rerun, "GitHub", lambda token, repo: fake), mock.patch.dict("os.environ", env), \
                redirect_stdout(out):
            self.assertEqual(rerun.main(["--dry-run"] if dry else [], now=now, sleep=slept.append), code)
        return out.getvalue()

    def test_a_reset_within_the_window_gets_one_pass_just_after_it(self):
        fake = FakeGitHub([run(1, "a" * 40)], [], {1: LIMITED_LOG}, remaining=[0, 15000],
                          reset=NOW + dt.timedelta(minutes=6))
        slept = []
        self.assertIn("just after the reset", self.sweep(fake, slept=slept))
        self.assertEqual(slept, [6 * 60 + 20])
        self.assertEqual([c for c in fake.calls if c[1] == "/rate_limit"], [("GET", "/rate_limit")] * 2)
        self.assertEqual(fake.posts, [rerun_path(1)])

    def test_a_reset_that_leaves_the_budget_low_stops_after_one_more_read(self):
        fake = FakeGitHub([run(1, "a" * 40)], [], {1: LIMITED_LOG}, remaining=[0, 100],
                          reset=NOW + dt.timedelta(minutes=6))
        slept = []
        self.assertIn("a re-run would fail the same way", self.sweep(fake, slept=slept))
        self.assertEqual(len(slept), 1)
        self.assertEqual(fake.calls, [("GET", "/rate_limit")] * 2)

    def test_a_far_reset_is_not_waited_for(self):
        reset = NOW + dt.timedelta(minutes=50)
        fake = FakeGitHub([run(1, "a" * 40)], [], {1: LIMITED_LOG}, remaining=0, reset=reset)
        slept = []
        # Spent until past the deadline: red, with the time, for the next tick.
        self.assertIn(f"spent until {reset + rerun.RESET_GRACE:%H:%M:%SZ}", self.sweep(fake, slept=slept, code=1))
        self.assertEqual(slept, [])
        self.assertEqual(fake.calls, [("GET", "/rate_limit")])

    def test_a_far_reset_under_the_floor_but_not_spent_stays_green(self):
        fake = FakeGitHub([run(1, "a" * 40)], [], {1: LIMITED_LOG}, remaining=100, reset=NOW + dt.timedelta(minutes=50))
        self.assertIn("a re-run would fail the same way", self.sweep(fake))
        self.assertEqual(fake.posts, [])

    def test_re_runs_are_capped_to_keep_the_floor(self):
        floor = int(15000 * rerun.FLOOR_SHARE)
        assistants = [run(i, f"{i:040x}", number=i) for i in range(1, 6)]
        guards = [run(i, f"{i:040x}", number=i, name=GUARD) for i in range(20, 25)]
        fake = FakeGitHub(assistants, guards, {i: LIMITED_LOG for i in range(1, 6)} | {i: GUARD_LOG for i in range(20, 25)},
                          remaining=floor + 4 * rerun.RERUN_COST)
        self.sweep(fake)
        self.assertEqual(len(fake.posts), 4)
        self.assertEqual(len([p for p in fake.posts if int(p.split("/")[-2]) >= 20]), 2)

    def test_a_spent_budget_stops_after_the_free_read(self):
        fake = FakeGitHub([run(1, "a" * 40)], [], {1: LIMITED_LOG}, remaining=100)
        out = self.sweep(fake)
        self.assertIn("budget is low", out)
        self.assertIn("resets", out)
        self.assertEqual(fake.calls, [("GET", "/rate_limit")])

    def test_rate_limited_assistant_and_its_guard_are_rerun(self):
        head = "a" * 40
        fake = FakeGitHub([run(1, head)], [run(2, head, attempt=7, name=GUARD)], {1: LIMITED_LOG, 2: GUARD_LOG})
        self.sweep(fake)
        self.assertEqual(sorted(fake.posts), [rerun_path(1), rerun_path(2)])

    def test_pull_requests_into_main_and_feat_cmux_next_count_and_other_bases_do_not(self):
        heads = ["a" * 40, "b" * 40, "c" * 40]
        fake = FakeGitHub([run(1, heads[0], number=11), run(2, heads[1], number=12), run(3, heads[2], number=13)], [],
                          {1: LIMITED_LOG, 2: LIMITED_LOG, 3: LIMITED_LOG},
                          pulls=[pull(11, heads[0], "main"), pull(12, heads[1], "feat-cmux-next"),
                                 pull(13, heads[2], "release/1")])
        self.sweep(fake)
        self.assertEqual(sorted(fake.posts), [rerun_path(1), rerun_path(2)])

    def test_a_run_whose_own_pull_request_is_into_another_base_is_left_alone(self):
        head = "a" * 40
        other = run(1, head, number=13)
        other["pull_requests"][0]["base"]["ref"] = "release/1"
        fake = FakeGitHub([other], [], {1: LIMITED_LOG}, pulls=[pull(12, head)])
        self.sweep(fake)
        self.assertEqual(fake.posts, [])

    def test_a_run_from_before_a_force_push_is_stale_even_when_another_pull_request_has_its_sha(self):
        old = "a" * 40
        stale = run(1, old, number=12)
        stale["pull_requests"][0]["head"]["sha"] = "b" * 40  # #12 was force-pushed since
        fake = FakeGitHub([stale], [], {1: LIMITED_LOG}, pulls=[pull(12, "b" * 40), pull(13, old)])
        self.sweep(fake)
        self.assertEqual(fake.posts, [])

    def test_a_closed_pull_requests_run_is_left_alone_when_an_open_one_shares_its_sha(self):
        head = "a" * 40
        fake = FakeGitHub([run(1, head, number=12)], [], {1: LIMITED_LOG}, pulls=[pull(13, head)])
        self.sweep(fake)
        self.assertEqual(fake.posts, [])

    def test_assistant_failures_cannot_take_the_guards_slots(self):
        limited = [run(i, f"{i:040x}", number=i, updated="2026-10-26T04:00:00Z") for i in range(1, 11)]
        guard = run(50, "e" * 40, number=50, name=GUARD)
        fake = FakeGitHub(limited, [guard], {i: LIMITED_LOG for i in range(1, 11)} | {50: GUARD_LOG})
        self.sweep(fake)
        self.assertIn(rerun_path(50), fake.posts)
        self.assertEqual(len(fake.posts), rerun.MAX_RERUNS - rerun.MAX_RERUNS // 2 + 1)

    def test_pull_requests_are_read_per_base(self):
        fake = FakeGitHub([], [], {})
        self.sweep(fake)
        reads = [path for _, path in fake.calls if "/pulls?" in path]
        self.assertEqual(reads, [
            "/repos/o/r/pulls?state=open&base=main&per_page=100&sort=updated&direction=desc&page=1",
            "/repos/o/r/pulls?state=open&base=feat-cmux-next&per_page=100&sort=updated&direction=desc&page=1"])

    def test_a_secondary_rate_limit_elsewhere_is_not_evidence_for_a_guard(self):
        guard_head, other_head = "b" * 40, "c" * 40
        fake = FakeGitHub([run(5, other_head, number=9, updated="2026-10-26T04:02:00Z")],
                          [run(2, guard_head, name=GUARD)], {2: GUARD_LOG, 5: "You have exceeded a secondary rate limit"},
                          pulls=[pull(1, guard_head), pull(9, other_head)],
                          finished={2: "2026-10-26T04:00:00Z", 5: "2026-10-26T04:02:00Z"})
        self.sweep(fake)
        self.assertEqual(fake.posts, [rerun_path(5)])

    def test_a_fork_pull_request_is_matched_by_its_head(self):
        head = "f" * 40
        fork = run(1, head, number=25411)
        fork["pull_requests"] = []  # GitHub lists no pull request on a fork's run
        fake = FakeGitHub([fork], [], {1: LIMITED_LOG}, pulls=[pull(25411, head)])
        self.assertIn("for #25411", self.sweep(fake))
        self.assertEqual(fake.posts, [rerun_path(1)])

    def test_a_guard_reject_with_its_own_api_failure_is_rerun(self):
        fake = FakeGitHub([], [run(2, "b" * 40, name=GUARD)], {2: GUARD_403_LOG})
        self.sweep(fake)
        self.assertEqual(fake.posts, [rerun_path(2)])

    def test_an_api_failure_after_the_reject_is_not_evidence(self):
        log = GUARD_LOG + "post step: HTTP 403\n"
        fake = FakeGitHub([], [run(2, "b" * 40, name=GUARD)], {2: log})
        self.assertIn("possibly a real policy rejection", self.sweep(fake))
        self.assertEqual(fake.posts, [])

    def test_a_guard_reject_with_no_api_failure_is_never_rerun(self):
        # "403" inside a PR number or a SHA is not an API failure.
        fake = FakeGitHub([], [run(2, "b" * 40, name=GUARD)], {2: GUARD_LOG})
        out = self.sweep(fake)
        self.assertIn("::warning title=CLA policy guard reject left alone::run 2", out)
        self.assertEqual(fake.posts, [])

    def test_a_rate_limited_assistant_on_another_pull_request_inside_the_window_is_evidence(self):
        # The budget is the repository's: a CLA Assistant that hit it two minutes from the
        # guard's reject, on any pull request, even one already re-run green, explains it.
        guard_head, other_head = "b" * 40, "c" * 40
        fake = FakeGitHub([run(5, other_head, number=9, updated="2026-10-26T04:02:00Z")],
                          [run(2, guard_head, name=GUARD)], {2: GUARD_LOG, 5: LIMITED_LOG},
                          pulls=[pull(1, guard_head)], finished={2: "2026-10-26T04:00:00Z", 5: "2026-10-26T04:02:00Z"})
        self.sweep(fake)
        self.assertEqual(fake.posts, [rerun_path(2)])

    def test_a_rate_limited_assistant_outside_the_window_is_not_evidence(self):
        guard_head, other_head = "b" * 40, "c" * 40
        fake = FakeGitHub([run(5, other_head, number=9, updated="2026-10-26T03:00:00Z")], [run(2, guard_head, name=GUARD)],
                          {2: GUARD_LOG, 5: LIMITED_LOG}, pulls=[pull(1, guard_head), pull(9, other_head)],
                          finished={2: "2026-10-26T04:00:00Z", 5: "2026-10-26T03:00:00Z"})
        self.sweep(fake)
        self.assertEqual(fake.posts, [rerun_path(5)])

    def test_other_failures_closed_or_superseded_heads_old_runs_and_spent_attempts_are_left_alone(self):
        fake = FakeGitHub(
            [run(1, "a" * 40), run(3, "c" * 40, number=3), run(4, "e" * 40, number=4, updated="2026-10-24T00:00:00Z"),
             run(5, "f" * 40, number=5, attempt=rerun.MAX_ATTEMPT)],
            [run(2, "a" * 40, attempt=rerun.MAX_GUARD_ATTEMPT, name=GUARD)],
            {1: "##[error]Committers of this pull request have not signed the CLA", 3: LIMITED_LOG, 4: LIMITED_LOG,
             5: LIMITED_LOG},
            pulls=[pull(1, "a" * 40), pull(3, "d" * 40), pull(4, "e" * 40), pull(5, "f" * 40)])
        self.sweep(fake)
        self.assertEqual(fake.posts, [])

    def test_a_head_rerun_since_is_not_replayed(self):
        head = "a" * 40
        fake = FakeGitHub([run(1, head), run(6, head, conclusion="success")],
                          [run(2, head, name=GUARD), run(7, head, name=GUARD, conclusion=None)],
                          {1: LIMITED_LOG})
        fake.guard[1]["status"] = "in_progress"
        self.sweep(fake)
        self.assertEqual(fake.posts, [])

    def test_genuine_failures_cannot_hold_the_read_budget(self):
        genuine = [run(100 + i, f"{i:040x}") for i in range(rerun.MAX_LOG_READS)]
        limited = run(99, "f" * 40)
        logs = {r["id"]: "not signed" for r in genuine} | {99: LIMITED_LOG}
        reached = set()
        for slot in range(len(genuine) + 1):
            fake = FakeGitHub(genuine + [limited], [], logs)
            self.sweep(fake, now=NOW + dt.timedelta(minutes=10 * slot))
            reached.update(fake.posts)
        self.assertIn(rerun_path(99), reached)

    def test_a_guard_reject_on_a_pull_request_that_proposes_no_policy_is_rerun(self):
        # No x-ratelimit header, no 403 wording and no CLA Assistant failure needed: a pull
        # request that changes no policy path passes the guard unless a GitHub read fails.
        fake = FakeGitHub([], [run(2, "b" * 40, number=7, name=GUARD)], {2: GUARD_LOG}, files={7: NO_POLICY})
        self.sweep(fake)
        self.assertEqual(fake.posts, [rerun_path(2)])
        self.assertIn(("GET", "/repos/o/r/pulls/7/files?per_page=100&page=1"), fake.calls)

    def test_no_policy_evidence_stops_after_early_attempts(self):
        fake = FakeGitHub([], [run(2, "b" * 40, number=7, attempt=rerun.NO_POLICY_MAX_ATTEMPT, name=GUARD)],
                          {2: GUARD_LOG}, files={7: NO_POLICY})
        self.assertIn("possibly a real policy rejection", self.sweep(fake))
        self.assertEqual(fake.posts, [])

    def test_a_pull_request_that_touches_any_policy_path_is_not_evidence(self):
        for changed in ([{"filename": path} for path in sorted(rerun.POLICY_PATHS)]
                        + [{"filename": "docs/cla.md", "previous_filename": "CLA.md"}]):
            fake = FakeGitHub([], [run(2, "b" * 40, number=7, name=GUARD)], {2: GUARD_LOG},
                              files={7: NO_POLICY + [changed]})
            self.sweep(fake)
            self.assertEqual(fake.posts, [], changed)

    def test_a_pull_request_too_large_to_list_is_not_evidence(self):
        many = [{"filename": f"f{i}.txt"} for i in range(100 * rerun.MAX_FILE_PAGES)]
        fake = FakeGitHub([], [run(2, "b" * 40, number=7, name=GUARD)], {2: GUARD_LOG}, files={7: many})
        self.sweep(fake)
        self.assertEqual(fake.posts, [])

    def test_policy_paths_match_the_guard(self):
        # The guard's CLA_POLICY_PATHS and GUARD_PATHS, read from its source.
        source = (ROOT / "scripts" / "ci" / "validate-cla-policy.rb").read_text(encoding="utf-8")
        constants = dict(re.findall(r'^([A-Z0-9_]+_PATH) = "([^"]+)"\.freeze$', source, re.MULTILINE))
        listed = re.search(r"^CLA_POLICY_PATHS = \[(.*?)\]", source, re.MULTILINE | re.DOTALL).group(1)
        guard = re.search(r"^GUARD_PATHS = \[(.*?)\]", source, re.MULTILINE | re.DOTALL).group(1)
        names = re.findall(r"[A-Z0-9_]+_PATH\b", listed + guard)
        self.assertEqual(len(names), 6)
        self.assertEqual({constants[name] for name in names}, set(rerun.POLICY_PATHS))

    def test_the_workflow_runs_after_each_cla_failure_and_each_rerun(self):
        workflow = yaml.safe_load((ROOT / ".github" / "workflows" / "ci-cla-quota-rerun.yml").read_text())
        on = workflow.get("on", workflow.get(True))
        self.assertEqual(sorted(on["workflow_run"]["workflows"]), ["CLA Assistant", "CLA policy guard"])
        self.assertEqual(on["workflow_run"]["types"], ["completed"])
        self.assertIn("schedule", on)
        job = workflow["jobs"]["cla-quota-rerun"]
        for term in ("github.event.workflow_run.event == 'pull_request_target'",
                     "github.event.workflow_run.conclusion == 'failure'", "github.event.workflow_run.run_attempt > 1"):
            self.assertIn(term, job["if"])
        # Job level: CLA runs that start no job must never displace a pending pass.
        self.assertNotIn("concurrency", workflow)
        self.assertEqual(job["concurrency"], {"group": "ci-cla-quota-rerun", "cancel-in-progress": False})
        # The pass may wait WAIT_FOR_RESET, and the job outlives it.
        wait = rerun.WAIT_FOR_RESET.total_seconds() / 60
        step = next(s for s in job["steps"] if "cla_quota_rerun.py" in str(s.get("run", "")))
        self.assertGreater(step["timeout-minutes"], wait)
        self.assertGreater(job["timeout-minutes"], step["timeout-minutes"])
        self.assertNotIn("pull_request_target", on)
        self.assertEqual(workflow["permissions"], {})

    def test_a_403_waits_for_the_reset_and_reruns(self):
        # 2026-10-26: a pass logged only "HTTP Error 403: Forbidden" and ended green, CLA red.
        fake = FakeGitHub([run(1, "a" * 40)], [], {1: LIMITED_LOG})
        reset = NOW + dt.timedelta(minutes=6)
        fake.fail("POST", rerun_path(1), 403, X_RateLimit_Remaining="0", X_RateLimit_Reset=str(int(reset.timestamp())))
        slept = []
        out = self.sweep(fake, slept=slept)
        self.assertIn("HTTP 403", out)
        self.assertEqual(slept, [6 * 60 + 20])
        self.assertEqual(fake.posts, [rerun_path(1)])

    def test_a_spent_app_budget_is_named_waited_out_and_its_guard_rejects_rerun(self):
        # 2026-10-28 06:44Z: the glaeda-route App budget, which the guard reads on, ran out and
        # the guard rejected every pull request into main until the reset, policy changes included.
        reset = NOW + dt.timedelta(minutes=6)
        inside, before = "b" * 40, "c" * 40
        fake = FakeGitHub([], [run(2, inside, number=2, name=GUARD), run(3, before, number=3, name=GUARD)],
                          {2: GUARD_LOG, 3: GUARD_LOG},
                          finished={2: "2026-10-26T04:25:00Z", 3: "2026-10-26T03:30:00Z"})
        fake.fail("GET", "/repos/o/r/pulls?state=open&base=main&per_page=100&sort=updated&direction=desc&page=1", 403,
                  X_RateLimit_Remaining="0", X_RateLimit_Reset=str(int(reset.timestamp())))
        slept = []
        out = self.sweep(fake, slept=slept)
        self.assertIn("::warning title=glaeda-route App budget spent::the glaeda-route App budget is spent until "
                      f"{reset + rerun.RESET_GRACE:%H:%M:%SZ}", out)
        self.assertIn("the glaeda-route App budget is spent; the pass runs again in 380 s", out)
        self.assertEqual(slept, [6 * 60 + 20])
        # Both change CLA policy; only the reject inside the App's spent hour is re-run.
        self.assertEqual(fake.posts, [rerun_path(2)])
        self.assertIn("reject left alone::run 3", out)

    def test_only_a_guard_reject_inside_the_app_hour_is_evidence(self):
        # A guard run that failed for another reason (runner, checkout) in that hour is not re-run.
        reset = NOW + dt.timedelta(minutes=6)
        fake = FakeGitHub([], [run(2, "b" * 40, number=2, name=GUARD)], {2: "##[error]The runner has lost communication\n"},
                          finished={2: "2026-10-26T04:25:00Z"})
        fake.fail("GET", "/repos/o/r/pulls?state=open&base=main&per_page=100&sort=updated&direction=desc&page=1", 403,
                  X_RateLimit_Remaining="0", X_RateLimit_Reset=str(int(reset.timestamp())))
        self.sweep(fake)
        self.assertEqual(fake.posts, [])

    def test_a_refusal_without_a_reset_opens_no_app_hour(self):
        # Retry-After or the 60 s fallback says nothing about when the App hour began.
        fake = FakeGitHub([], [run(2, "b" * 40, number=2, name=GUARD)], {2: GUARD_LOG},
                          finished={2: "2026-10-26T04:29:30Z"})
        fake.fail("GET", "/repos/o/r/pulls?state=open&base=main&per_page=100&sort=updated&direction=desc&page=1", 429,
                  Retry_After="30")
        out = self.sweep(fake)
        self.assertNotIn("glaeda-route App budget spent", out)
        self.assertIn("is not a spent hourly budget", out)
        self.assertEqual(fake.posts, [])

    def test_a_secondary_limit_with_budget_left_opens_no_app_hour(self):
        # A 429 with X-RateLimit-Remaining above 0 is a secondary limit, even with a reset header.
        reset = NOW + dt.timedelta(minutes=6)
        fake = FakeGitHub([], [run(2, "b" * 40, number=2, name=GUARD)], {2: GUARD_LOG},
                          finished={2: "2026-10-26T04:25:00Z"})
        fake.fail("GET", "/repos/o/r/pulls?state=open&base=main&per_page=100&sort=updated&direction=desc&page=1", 429,
                  X_RateLimit_Remaining="9000", Retry_After="30", X_RateLimit_Reset=str(int(reset.timestamp())))
        out = self.sweep(fake)
        self.assertNotIn("glaeda-route App budget spent", out)
        self.assertEqual(fake.posts, [])

    def test_a_permission_refusal_opens_no_app_hour(self):
        # A 403 with budget left (a missing permission, say) is no evidence that the App hour ran out.
        reset = NOW + dt.timedelta(minutes=6)
        fake = FakeGitHub([], [run(2, "b" * 40, number=2, name=GUARD)], {2: GUARD_LOG},
                          finished={2: "2026-10-26T04:25:00Z"})
        fake.fail("GET", "/repos/o/r/pulls?state=open&base=main&per_page=100&sort=updated&direction=desc&page=1", 403,
                  X_RateLimit_Remaining="4000", X_RateLimit_Reset=str(int(reset.timestamp())))
        out = self.sweep(fake)
        self.assertNotIn("glaeda-route App budget spent", out)
        self.assertEqual(fake.posts, [])

    def test_a_spent_workflow_token_budget_is_not_called_the_apps(self):
        fake = FakeGitHub([run(1, "a" * 40)], [], {1: LIMITED_LOG}, remaining=0, reset=NOW + dt.timedelta(minutes=50))
        out = self.sweep(fake, code=1)
        self.assertIn("the budget is spent until", out)
        self.assertNotIn("glaeda-route App", out)

    def test_a_429_waits_for_retry_after(self):
        fake = FakeGitHub([run(1, "a" * 40)], [], {1: LIMITED_LOG})
        fake.fail("GET", "/repos/o/r/actions/workflows/cla.yml/runs?event=pull_request_target&per_page=100", 429,
                  Retry_After="30", X_RateLimit_Reset=str(int((NOW + dt.timedelta(minutes=30)).timestamp())))
        slept = []
        self.sweep(fake, slept=slept)
        self.assertEqual(slept, [30.0])
        self.assertEqual(fake.posts, [rerun_path(1)])

    def test_remaining_zero_on_another_status_is_a_spent_budget(self):
        error = urllib.error.HTTPError(API, 404, "x", {"X-RateLimit-Remaining": "0"}, None)
        self.assertIsNotNone(rerun.spent_budget(error, "/x"))
        self.assertIsNone(rerun.spent_budget(urllib.error.HTTPError(API, 500, "x", {}, None), "/x"))

    def test_a_reset_past_the_deadline_exits_non_zero_with_its_time(self):
        fake = FakeGitHub([run(1, "a" * 40)], [], {1: LIMITED_LOG})
        reset = NOW + rerun.PASS_DEADLINE + dt.timedelta(minutes=1)
        fake.fail("POST", rerun_path(1), 403, X_RateLimit_Reset=str(int(reset.timestamp())))
        slept = []
        out = self.sweep(fake, slept=slept, code=1)
        self.assertEqual(slept, [])
        self.assertIn(f"spent until {reset + rerun.RESET_GRACE:%H:%M:%SZ}", out)
        self.assertEqual(fake.posts, [])

    def test_a_budget_that_stays_spent_stops_after_the_retries(self):
        fake = FakeGitHub([run(1, "a" * 40)], [], {1: LIMITED_LOG})
        for _ in range(rerun.SPENT_RETRIES + 1):
            fake.fail("POST", rerun_path(1), 403)
        slept = []
        self.sweep(fake, slept=slept, code=1)
        self.assertEqual(slept, [rerun.SPENT_FALLBACK.total_seconds()] * rerun.SPENT_RETRIES)

    def test_other_http_errors_stay_warnings(self):
        fake = FakeGitHub([run(1, "a" * 40)], [], {1: LIMITED_LOG})
        fake.fail("POST", rerun_path(1), 500)
        self.assertIn("::warning", self.sweep(fake))

    def test_the_pass_ends_inside_the_step_and_a_red_pass_shows_red(self):
        workflow = yaml.safe_load((ROOT / ".github" / "workflows" / "ci-cla-quota-rerun.yml").read_text())
        job = workflow["jobs"]["cla-quota-rerun"]
        step = next(s for s in job["steps"] if "cla_quota_rerun.py" in str(s.get("run", "")))
        self.assertGreater(step["timeout-minutes"], rerun.PASS_DEADLINE.total_seconds() / 60)
        self.assertGreater(rerun.PASS_DEADLINE, rerun.WAIT_FOR_RESET)
        self.assertNotIn("continue-on-error", job)
        self.assertNotIn("continue-on-error", step)

    def test_a_retried_pass_never_reruns_a_run_twice(self):
        fake = FakeGitHub([run(1, "a" * 40, number=1), run(2, "b" * 40, number=2)], [], {1: LIMITED_LOG, 2: LIMITED_LOG})
        fake.fail("POST", rerun_path(2), 403)  # run 1, accepted first, still lists as failed
        self.sweep(fake)
        self.assertEqual(sorted(fake.posts), [rerun_path(1), rerun_path(2)])

    def test_a_budget_still_spent_after_the_reset_ends_red(self):
        fake = FakeGitHub([run(1, "a" * 40)], [], {1: LIMITED_LOG}, remaining=[0, 0],
                          reset=NOW + dt.timedelta(minutes=6))
        slept = []
        self.sweep(fake, slept=slept, code=1)
        self.assertEqual(slept[0], 6 * 60 + 20)
        self.assertEqual(fake.posts, [])

    def test_a_retry_spends_no_slot_on_a_run_already_rerun(self):
        head_a, head_g = "a" * 40, "b" * 40
        fake = FakeGitHub([run(1, head_a, number=1)], [run(2, head_g, number=2, name=GUARD)],
                          {1: LIMITED_LOG, 2: GUARD_403_LOG}, remaining=[15000, rerun.FLOOR_MIN * 3 + rerun.RERUN_COST])
        fake.fail("POST", rerun_path(2), 403)
        self.sweep(fake)
        self.assertEqual(fake.posts, [rerun_path(1), rerun_path(2)])

    def test_a_pass_out_of_time_exits_non_zero(self):
        fake = FakeGitHub([run(1, "a" * 40)], [], {1: LIMITED_LOG})
        fake.request = mock.Mock(side_effect=rerun.PastDeadline("no time left for GET /rate_limit"))
        self.assertIn("deadline", self.sweep(fake, code=1))

    def test_dry_run_writes_nothing(self):
        fake = FakeGitHub([run(1, "a" * 40)], [], {1: LIMITED_LOG})
        self.assertIn("would re-run", self.sweep(fake, dry=True))
        self.assertEqual(fake.posts, [])


class Response(io.BytesIO):
    def __init__(self, body=b"{}", status=200, headers=None):
        super().__init__(body)
        self.status, self.headers = status, headers or {}


class RealRequestTests(unittest.TestCase):
    """GitHub.request itself, with urlopen mocked."""

    def test_a_403_becomes_a_spent_budget_with_its_reset(self):
        error = urllib.error.HTTPError(API + "/x", 403, "Forbidden", {"X-RateLimit-Reset": "1793124441"}, None)
        with mock.patch.object(rerun.urllib.request, "urlopen", side_effect=error):
            with self.assertRaises(rerun.SpentBudget) as caught:
                rerun.GitHub("t", "o/r").request("POST", "/x")
        self.assertEqual(caught.exception.reset, dt.datetime.fromtimestamp(1793124441, dt.timezone.utc))
        error.close()

    def test_a_successful_response_with_none_left_stops_the_next_call(self):
        gh = rerun.GitHub("t", "o/r")
        headers = {"X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1793124441"}
        with mock.patch.object(rerun.urllib.request, "urlopen", return_value=Response(headers=headers)) as opened:
            self.assertEqual(gh.request("GET", "/repos/o/r/pulls"), {})
            with self.assertRaises(rerun.SpentBudget):
                gh.request("GET", "/repos/o/r/pulls")
        self.assertEqual(opened.call_count, 1)

    def test_the_free_rate_limit_read_is_judged_by_its_body(self):
        gh = rerun.GitHub("t", "o/r")
        with mock.patch.object(rerun.urllib.request, "urlopen",
                               side_effect=lambda *a, **k: Response(headers={"X-RateLimit-Remaining": "0"})) as opened:
            gh.request("GET", "/rate_limit")
            gh.request("GET", "/rate_limit")
        self.assertEqual(opened.call_count, 2)

    def test_a_call_cut_short_by_the_deadline_is_out_of_time(self):
        gh = rerun.GitHub("t", "o/r")
        gh.deadline = dt.datetime.now(dt.timezone.utc) + dt.timedelta(seconds=1.5)

        def slow(*args, **kwargs):
            gh.deadline = dt.datetime.now(dt.timezone.utc)  # the timeout ran out
            raise TimeoutError("timed out")

        with mock.patch.object(rerun.urllib.request, "urlopen", side_effect=slow), self.assertRaises(rerun.PastDeadline):
            gh.request("GET", "/x")

    def test_no_call_starts_past_the_deadline(self):
        gh = rerun.GitHub("t", "o/r")
        gh.deadline = dt.datetime.now(dt.timezone.utc)
        with mock.patch.object(rerun.urllib.request, "urlopen") as opened, self.assertRaises(rerun.PastDeadline):
            gh.request("GET", "/x")
        opened.assert_not_called()


if __name__ == "__main__":
    unittest.main()
