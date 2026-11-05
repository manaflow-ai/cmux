#!/usr/bin/env python3
"""scripts/ci/hosted_light_rescue.py: a declared hosted light job that GitHub-hosted Ubuntu never assigns is failed
over to its re-run route (attempt 2) after about 3 minutes, bounded to pull request runs at attempt 1."""

from __future__ import annotations

import datetime as dt
import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
import hosted_light_rescue as rescue  # noqa: E402

NOW = dt.datetime(2026, 11, 2, 8, 30, tzinfo=dt.timezone.utc)
HEAD = "a" * 40


def ago(seconds: float) -> str:
    return rescue.iso(NOW - dt.timedelta(seconds=seconds))


def run(run_id: int, *, event: str = "pull_request", attempt: int = 1, head: str = HEAD, pr_head: str | None = HEAD,
        status: str = "in_progress", workflow: str = "pr-checks.yml") -> dict:
    return {"id": run_id, "event": event, "run_attempt": attempt, "status": status, "head_sha": head,
            "head_branch": f"lane/{run_id}", "created_at": ago(600), "path": f".github/workflows/{workflow}",
            "pull_requests": [] if pr_head is None else [{"number": run_id, "head": {"sha": pr_head}}]}


def job(name: str, *, status: str = "queued", labels=("ubuntu-24.04",), runner_id=0, waited: float = 400) -> dict:
    return {"name": name, "status": status, "labels": list(labels), "runner_id": runner_id,
            "runner_name": f"GitHub Actions {runner_id}" if runner_id else "", "created_at": ago(waited)}


class Fake:
    def __init__(self, runs_by_workflow: dict[str, list[dict]], jobs: dict[int, list[dict]], *,
                 settles_after: int = 1, cancel_error: Exception | None = None) -> None:
        self.runs_by_workflow, self.jobs_by_run = runs_by_workflow, jobs
        self.settles_after, self.cancel_error = settles_after, cancel_error
        self.calls: list[tuple] = []
        self.reads: dict[int, int] = {}
        self.heads: dict[int, str | None] = {}
        self.second_jobs: dict[int, list[dict]] = {}
        self.job_reads: dict[int, int] = {}
        self.cancelled: dict[int, int | None] = {}
        self.fresh: dict[int, dict] = {}
        self.pull_error: Exception | None = None

    def runs(self, workflow, status, start, end):
        self.calls.append(("runs", workflow, status))
        return [r for r in self.runs_by_workflow.get(workflow, []) if r["status"] == status]

    def jobs(self, run_id):
        self.job_reads[run_id] = self.job_reads.get(run_id, 0) + 1
        if self.job_reads[run_id] == 1:
            self.calls.append(("jobs", run_id))
        elif run_id in self.second_jobs:
            return self.second_jobs[run_id]
        return self.jobs_by_run.get(run_id, [])

    def pull_head(self, number):
        if self.pull_error:
            raise self.pull_error
        return self.heads.get(number, HEAD)

    def run(self, run_id):
        self.reads[run_id] = self.reads.get(run_id, 0) + 1
        listed = next((r for runs in self.runs_by_workflow.values() for r in runs if r["id"] == run_id), {})
        if self.cancelled.get(run_id) is None:
            return {**listed, **self.fresh.get(run_id, {})}
        done = self.reads[run_id] - self.cancelled[run_id] >= self.settles_after
        return {**listed, "status": "completed" if done else "in_progress", "run_attempt": 1}

    def cancel(self, run_id):
        self.calls.append(("cancel", run_id))
        self.cancelled[run_id] = self.reads.get(run_id, 0)
        if self.cancel_error:
            raise self.cancel_error

    def rerun_failed(self, run_id):
        self.calls.append(("rerun", run_id))


def mutations(fake: Fake) -> list[tuple]:
    return [call for call in fake.calls if call[0] in ("cancel", "rerun")]


def sweep(fake: Fake, *, dry_run: bool = False, workflows=("pr-checks.yml",)) -> list[str]:
    clock = iter(range(0, 10_000)).__next__
    return rescue.sweep(fake, list(workflows), now=NOW, dry_run=dry_run, sleep=lambda _s: None,
                        clock=lambda: float(clock()))


class Scope(unittest.TestCase):
    def test_declared_workflows_come_from_both_key_forms_and_skip_the_nightly(self):
        runners = {"hosted_light_jobs": {"$comment": ["x"], "pr-checks.yml#size": {}, "pr-checks.yml#ui-review": {},
                                         "ci.yml#changes": {}, "fast-checks.yml:admit": {}, "nightly.yml#decide": {}}}
        self.assertEqual(rescue.declared_workflows(runners), ["ci.yml", "fast-checks.yml", "pr-checks.yml"])
        self.assertEqual(rescue.declared_workflows({}), [])

    def test_the_repository_declaration_scopes_real_workflow_files(self):
        runners = json.loads((ROOT / ".github" / "runners.json").read_text())
        for name in rescue.declared_workflows(runners):
            self.assertTrue((ROOT / ".github" / "workflows" / name).is_file(), name)

    def test_reusable_declarations_bring_their_callers(self):
        runners = json.loads((ROOT / ".github" / "runners.json").read_text())
        names = rescue.with_callers(rescue.declared_workflows(runners), ROOT / ".github" / "workflows")
        for caller in ("cmux-next.yml", "cmux-next-guards.yml", "ci.yml", "pr-checks.yml"):
            self.assertIn(caller, names)
        self.assertNotIn("nightly.yml", names)

    def test_callers_without_a_directory_are_just_the_declaration(self):
        self.assertEqual(rescue.with_callers(["b.yml", "a.yml"], None), ["a.yml", "b.yml"])

    def test_only_a_job_with_no_runner_on_hosted_ubuntu_past_the_bound_is_stalled(self):
        self.assertTrue(rescue.stalled(job("PR size", waited=181), NOW))
        self.assertFalse(rescue.stalled(job("PR size", waited=60), NOW))
        self.assertFalse(rescue.stalled(job("PR size", runner_id=1000291949), NOW))
        self.assertFalse(rescue.stalled(job("PR size", status="in_progress"), NOW))
        self.assertFalse(rescue.stalled(job("PR size", status="waiting"), NOW))
        self.assertFalse(rescue.stalled(job("build", labels=("blacksmith-4vcpu-ubuntu-2404",)), NOW))
        self.assertFalse(rescue.stalled(job("mixed", labels=("ubuntu-24.04", "self-hosted")), NOW))
        self.assertFalse(rescue.stalled(job("macos", labels=("macos-15",)), NOW))

    def test_only_pull_request_runs_at_attempt_one_and_their_current_head_are_candidates(self):
        self.assertTrue(rescue.candidate(run(1)))
        self.assertFalse(rescue.candidate(run(1, attempt=2)))
        self.assertFalse(rescue.candidate(run(1, event="push")))
        self.assertFalse(rescue.candidate(run(1, event="workflow_dispatch")))
        self.assertFalse(rescue.candidate(run(1, event="schedule")))
        self.assertFalse(rescue.candidate(run(1, pr_head="b" * 40)))
        self.assertFalse(rescue.candidate(run(1, pr_head=None)))
        self.assertFalse(rescue.candidate(run(1, status="completed")))


class Sweep(unittest.TestCase):
    def test_a_stalled_report_job_is_cancelled_and_its_failed_jobs_re_run(self):
        jobs = [job("Changes", status="completed", runner_id=1, waited=900), job("PR size"), job("UI review advisory")]
        fake = Fake({"pr-checks.yml": [run(7)]}, {7: jobs}, settles_after=3)
        lines = sweep(fake)
        self.assertEqual(mutations(fake), [("cancel", 7), ("rerun", 7)])
        self.assertIn("1 failed over", lines[-1])

    def test_a_run_with_other_unfinished_jobs_is_left_alone(self):
        jobs = [job("PR size"), job("build", status="in_progress", labels=("blacksmith-4vcpu-ubuntu-2404",),
                                    runner_id=5)]
        fake = Fake({"pr-checks.yml": [run(7)]}, {7: jobs})
        lines = sweep(fake)
        self.assertEqual(mutations(fake), [])
        self.assertTrue(any("left alone" in line for line in lines))

    def test_a_fresh_or_assigned_hosted_job_is_not_touched(self):
        fake = Fake({"pr-checks.yml": [run(7), run(8)]},
                    {7: [job("PR size", waited=30)], 8: [job("PR size", runner_id=1000292032)]})
        sweep(fake)
        self.assertEqual(mutations(fake), [])

    def test_a_cancel_that_never_settles_is_not_re_run(self):
        fake = Fake({"pr-checks.yml": [run(7)]}, {7: [job("PR size")]}, settles_after=10**9)
        lines = sweep(fake)
        self.assertEqual(mutations(fake), [("cancel", 7)])
        self.assertTrue(any("did not settle" in line for line in lines))

    def test_a_refused_cancel_is_reported_and_not_re_run(self):
        fake = Fake({"pr-checks.yml": [run(7)]}, {7: [job("PR size")]}, cancel_error=RuntimeError("HTTP 409"))
        lines = sweep(fake)
        self.assertEqual(mutations(fake), [("cancel", 7)])
        self.assertTrue(any("cancel refused" in line for line in lines))

    def test_a_pull_request_that_moved_on_is_not_cancelled(self):
        fake = Fake({"pr-checks.yml": [run(7)]}, {7: [job("PR size")]})
        fake.heads[7] = "d" * 40
        lines = sweep(fake)
        self.assertEqual(mutations(fake), [])
        self.assertTrue(any("moved on" in line for line in lines))

    def test_a_run_re_run_meanwhile_is_not_cancelled(self):
        fake = Fake({"pr-checks.yml": [run(7)]}, {7: [job("PR size")]})
        fake.fresh[7] = {"run_attempt": 2}
        lines = sweep(fake)
        self.assertEqual(mutations(fake), [])
        self.assertTrue(any("moved on" in line for line in lines))

    def test_a_token_that_may_not_read_pull_requests_falls_back_to_the_fresh_run(self):
        fake = Fake({"pr-checks.yml": [run(7)]}, {7: [job("PR size")]})
        fake.pull_error = RuntimeError("GET /pulls/7: HTTP 403")
        sweep(fake)
        self.assertEqual(mutations(fake), [("cancel", 7), ("rerun", 7)])
        fake = Fake({"pr-checks.yml": [run(8)]}, {8: [job("PR size")]})
        fake.pull_error = RuntimeError("GET /pulls/8: HTTP 403")
        fake.fresh[8] = {"pull_requests": [{"number": 8, "head": {"sha": "e" * 40}}]}
        sweep(fake)
        self.assertEqual(mutations(fake), [])

    def test_a_pull_request_read_that_fails_otherwise_leaves_the_run(self):
        fake = Fake({"pr-checks.yml": [run(7)]}, {7: [job("PR size")]})
        fake.pull_error = RuntimeError("GET /pulls/7: HTTP 502")
        lines = sweep(fake)
        self.assertEqual(mutations(fake), [])
        self.assertTrue(any("could not re-read" in line for line in lines))

    def test_a_job_a_runner_took_after_the_read_is_not_cancelled(self):
        fake = Fake({"pr-checks.yml": [run(7)]}, {7: [job("PR size")]})
        fake.second_jobs[7] = [job("PR size", status="in_progress", runner_id=1000292999)]
        lines = sweep(fake)
        self.assertEqual(mutations(fake), [])
        self.assertTrue(any("since the read" in line for line in lines))

    def test_no_cancel_once_the_settle_time_is_spent(self):
        fake = Fake({"pr-checks.yml": [run(7), run(8)]}, {7: [job("PR size")], 8: [job("PR size")]},
                    settles_after=10**9)
        lines = sweep(fake)
        self.assertEqual(mutations(fake), [("cancel", 7)])
        self.assertTrue(any("settle time is spent" in line for line in lines))

    def test_a_run_with_a_second_page_of_jobs_is_gated(self):
        jobs = [job("PR size"), {"name": "(jobs past the first page)", "status": "unknown"}]
        self.assertEqual(rescue.verdict(jobs, NOW)[0], "gated")

    def test_jobs_past_the_first_page_stand_in_as_unfinished(self):
        client = rescue.GitHub("t", "o/r")
        client.request = lambda method, path: {"total_count": 120, "jobs": [job("PR size")]}
        self.assertEqual(rescue.verdict(client.jobs(7), NOW)[0], "gated")

    def test_a_dry_run_mutates_nothing(self):
        fake = Fake({"pr-checks.yml": [run(7)]}, {7: [job("PR size")]})
        lines = sweep(fake, dry_run=True)
        self.assertEqual(mutations(fake), [])
        self.assertTrue(any("dry run" in line for line in lines))

    def test_re_runs_and_job_reads_are_bounded(self):
        many = [run(100 + index) for index in range(rescue.MAX_RUNS + 5)]
        fake = Fake({"pr-checks.yml": many}, {r["id"]: [job("PR size")] for r in many})
        sweep(fake)
        self.assertEqual(len([c for c in fake.calls if c[0] == "jobs"]), rescue.MAX_RUNS)
        self.assertEqual(len([c for c in fake.calls if c[0] == "rerun"]), rescue.MAX_RESCUES)

    def test_non_candidate_runs_are_never_read(self):
        fake = Fake({"pr-checks.yml": [run(7, attempt=2), run(8, event="push"), run(9, pr_head="c" * 40)]},
                    {7: [job("PR size")], 8: [job("PR size")], 9: [job("PR size")]})
        sweep(fake)
        self.assertEqual([c for c in fake.calls if c[0] != "runs"], [])

    def test_main_reads_the_declaration_and_writes_the_summary(self):
        with tempfile.TemporaryDirectory() as tmp:
            runners = Path(tmp) / "runners.json"
            runners.write_text(json.dumps({"hosted_light_jobs": {"pr-checks.yml#size": {}}}))
            summary = Path(tmp) / "summary.md"
            fake = Fake({"pr-checks.yml": [run(7)]}, {7: [job("PR size")]})
            code = rescue.main(["--runners", str(runners)], {"GITHUB_STEP_SUMMARY": str(summary)}, client=fake,
                               now=NOW, sleep=lambda _s: None)
            self.assertEqual(code, 0)
            self.assertEqual(mutations(fake), [("cancel", 7), ("rerun", 7)])
            self.assertIn("Hosted light rescue", summary.read_text())

    def test_main_with_no_token_does_nothing_and_passes(self):
        with tempfile.TemporaryDirectory() as tmp:
            runners = Path(tmp) / "runners.json"
            runners.write_text(json.dumps({"hosted_light_jobs": {"pr-checks.yml#size": {}}}))
            self.assertEqual(rescue.main(["--runners", str(runners)], {}), 0)


if __name__ == "__main__":
    unittest.main()
