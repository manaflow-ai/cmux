#!/usr/bin/env python3
"""cla_quota_rerun.py re-runs only CLA checks the spent GITHUB_TOKEN budget failed (no network)."""

from __future__ import annotations

import datetime as dt
import io
import sys
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

import cla_quota_rerun as rerun  # noqa: E402

NOW = dt.datetime(2026, 10, 26, 4, 30, tzinfo=dt.timezone.utc)
LIMITED_LOG = "##[error]Could not complete the CLA check: ... API rate limit exceeded for installation."
# The guard hides every PolicyError, a failed API read included, behind this one line.
GUARD_LOG = ("Run set -euo pipefail\n  BASE_SHA: c0a00581d66f425cdb55bf1a4a9c349aca554668\n"
             "  PR_NUMBER: 25403\nPASS: test merge regression matrix (15 cases)\n"
             "##[error]CLA policy validation rejected the proposed policy\n")
GUARD_403_LOG = ("gh: API rate limit exceeded for installation ID 1 (HTTP 403)\n"
                 "##[error]CLA policy validation rejected the proposed policy\n")
GUARD = "CLA policy guard"


def run(run_id, head, *, number=1, attempt=1, name="CLA", updated="2026-10-26T04:00:00Z", conclusion="failure"):
    return {"id": run_id, "name": name, "head_sha": head, "run_attempt": attempt, "updated_at": updated,
            "status": "completed", "conclusion": conclusion, "number_hint": number,
            "pull_requests": [{"number": number, "head": {"sha": head}}]}


def pull(number, head, base="main"):
    return {"number": number, "head": {"sha": head}, "base": {"ref": base}}


class FakeGitHub:
    def __init__(self, assistant, guard, logs, *, pulls=None, finished=None, remaining=9000):
        self.assistant, self.guard, self.logs, self.remaining = assistant, guard, logs, remaining
        # By default every run's head is an open pull request into main.
        self.pulls = pulls if pulls is not None else [pull(r["number_hint"], r["head_sha"]) for r in assistant + guard]
        self.finished = finished or {}
        self.calls, self.posts = [], []
        self.repo = "o/r"

    def request(self, method, path, raw=False):
        self.calls.append((method, path))
        if path == "/rate_limit":
            return {"resources": {"core": {"limit": 15000, "remaining": self.remaining, "reset": 1793000000}}}
        if method == "POST":
            self.posts.append(path)
            return {}
        if path.startswith("/repos/o/r/pulls?state=open"):
            return self.pulls if "page=1" in path else []
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
    def sweep(self, fake, dry=False, now=NOW):
        env = {"GITHUB_REPOSITORY": "o/r", "GH_TOKEN": "app", "RATE_TOKEN": "workflow"}
        out = io.StringIO()
        with mock.patch.object(rerun, "GitHub", lambda token, repo: fake), mock.patch.dict("os.environ", env), \
                redirect_stdout(out):
            self.assertEqual(rerun.main(["--dry-run"] if dry else [], now=now), 0)
        return out.getvalue()

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
        fake = FakeGitHub([run(5, other_head, updated="2026-10-26T03:00:00Z")], [run(2, guard_head, name=GUARD)],
                          {2: GUARD_LOG, 5: LIMITED_LOG}, pulls=[pull(1, guard_head), pull(9, other_head)],
                          finished={2: "2026-10-26T04:00:00Z", 5: "2026-10-26T03:00:00Z"})
        self.sweep(fake)
        self.assertEqual(fake.posts, [rerun_path(5)])

    def test_other_failures_closed_or_superseded_heads_old_runs_and_spent_attempts_are_left_alone(self):
        fake = FakeGitHub(
            [run(1, "a" * 40), run(3, "c" * 40), run(4, "e" * 40, updated="2026-10-24T00:00:00Z"),
             run(5, "f" * 40, attempt=rerun.MAX_ATTEMPT)],
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

    def test_dry_run_writes_nothing(self):
        fake = FakeGitHub([run(1, "a" * 40)], [], {1: LIMITED_LOG})
        self.assertIn("would re-run", self.sweep(fake, dry=True))
        self.assertEqual(fake.posts, [])


if __name__ == "__main__":
    unittest.main()
