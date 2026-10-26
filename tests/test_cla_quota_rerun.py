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


def run(run_id, head, *, number=1, attempt=1, pr_head=None, name="CLA", updated="2026-10-26T04:00:00Z",
        conclusion="failure"):
    return {"id": run_id, "name": name, "head_sha": head, "run_attempt": attempt, "updated_at": updated,
            "status": "completed", "conclusion": conclusion,
            "pull_requests": [{"number": number, "head": {"sha": pr_head or head}}]}


class FakeGitHub:
    def __init__(self, assistant, guard, logs, remaining=9000):
        self.assistant, self.guard, self.logs, self.remaining = assistant, guard, logs, remaining
        self.calls, self.posts = [], []
        self.repo = "o/r"

    def request(self, method, path, raw=False):
        self.calls.append((method, path))
        if path == "/rate_limit":
            return {"resources": {"core": {"limit": 15000, "remaining": self.remaining}}}
        if method == "POST":
            self.posts.append(path)
            return {}
        if "/workflows/cla.yml/runs" in path:
            return {"workflow_runs": self.assistant}
        if "/workflows/cla-policy-guard.yml/runs" in path:
            return {"workflow_runs": self.guard}
        if path.endswith("/jobs?filter=latest&per_page=10"):
            run_id = int(path.split("/runs/")[1].split("/")[0])
            return {"jobs": [{"id": run_id * 10, "conclusion": "failure"}]}
        if path.endswith("/logs"):
            job_id = int(path.split("/jobs/")[1].split("/")[0])
            return self.logs.get(job_id // 10, "")
        raise AssertionError(path)


class Tests(unittest.TestCase):
    def sweep(self, fake, dry=False):
        env = {"GITHUB_REPOSITORY": "o/r", "GH_TOKEN": "app", "RATE_TOKEN": "workflow"}
        out = io.StringIO()
        with mock.patch.object(rerun, "GitHub", lambda token, repo: fake), mock.patch.dict("os.environ", env), \
                redirect_stdout(out):
            self.assertEqual(rerun.main(["--dry-run"] if dry else [], now=NOW), 0)
        return out.getvalue()

    def test_a_spent_budget_stops_after_the_free_read(self):
        fake = FakeGitHub([run(1, "a" * 40)], [], {1: LIMITED_LOG}, remaining=100)
        self.assertIn("budget is low", self.sweep(fake))
        self.assertEqual(fake.calls, [("GET", "/rate_limit")])

    def test_rate_limited_assistant_and_a_failed_guard_are_rerun(self):
        head = "a" * 40
        fake = FakeGitHub([run(1, head)], [run(2, head, attempt=7, name="CLA policy guard")], {1: LIMITED_LOG})
        self.sweep(fake)
        self.assertEqual(sorted(fake.posts), ["/repos/o/r/actions/runs/1/rerun-failed-jobs",
                                              "/repos/o/r/actions/runs/2/rerun-failed-jobs"])

    def test_other_failures_superseded_heads_old_runs_and_spent_attempts_are_left_alone(self):
        fake = FakeGitHub(
            [run(1, "a" * 40), run(3, "c" * 40, pr_head="d" * 40), run(4, "e" * 40, updated="2026-10-24T00:00:00Z"),
             run(5, "f" * 40, attempt=rerun.MAX_ATTEMPT)],
            [run(2, "a" * 40, attempt=rerun.MAX_GUARD_ATTEMPT, name="CLA policy guard")],
            {1: "##[error]Committers of this pull request have not signed the CLA", 3: LIMITED_LOG, 4: LIMITED_LOG,
             5: LIMITED_LOG})
        self.sweep(fake)
        self.assertEqual(fake.posts, [])

    def test_a_head_rerun_since_is_not_replayed(self):
        head = "a" * 40
        fake = FakeGitHub([run(1, head), run(6, head, conclusion="success")],
                          [run(2, head, name="CLA policy guard"), run(7, head, name="CLA policy guard", conclusion=None)],
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
            env = {"GITHUB_REPOSITORY": "o/r", "GH_TOKEN": "app", "RATE_TOKEN": "workflow"}
            with mock.patch.object(rerun, "GitHub", lambda token, repo: fake), mock.patch.dict("os.environ", env), \
                    redirect_stdout(io.StringIO()):
                rerun.main([], now=NOW + dt.timedelta(minutes=10 * slot))
            reached.update(fake.posts)
        self.assertIn("/repos/o/r/actions/runs/99/rerun-failed-jobs", reached)

    def test_a_guard_failure_alone_is_rerun(self):
        fake = FakeGitHub([], [run(2, "b" * 40, attempt=1, name="CLA policy guard")], {})
        self.sweep(fake)
        self.assertEqual(fake.posts, ["/repos/o/r/actions/runs/2/rerun-failed-jobs"])

    def test_dry_run_writes_nothing(self):
        fake = FakeGitHub([run(1, "a" * 40)], [], {1: LIMITED_LOG})
        self.assertIn("would re-run", self.sweep(fake, dry=True))
        self.assertEqual(fake.posts, [])


if __name__ == "__main__":
    unittest.main()
