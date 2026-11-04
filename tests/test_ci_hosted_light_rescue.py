#!/usr/bin/env python3
"""scripts/ci/hosted_light_rescue.py: a declared hosted light job that GitHub-hosted Ubuntu never assigns is failed
over to its re-run route (attempt 2) after about 3 minutes, bounded to pull request runs at attempt 1."""

from __future__ import annotations

import datetime as dt
import json
import sys
import tempfile
import unittest
from unittest import mock
import urllib.error
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
        return {**listed, "status": "completed" if done else "in_progress", "run_attempt": 1,
                "conclusion": "cancelled" if done else None}

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
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            (directory / "caller.yml").write_text("jobs:\n  report:\n    uses: ./.github/workflows/report.yml\n")
            self.assertEqual(rescue.with_callers(["report.yml"], directory), ["caller.yml", "report.yml"])

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


class Periodic(unittest.TestCase):
    def test_a_job_is_rescued_at_180_seconds_on_the_existing_minute_cadence(self):
        clock = [0.0]
        seen, rescue_at = [], []
        def tick():
            seen.append(clock[0])
            if rescue.stalled(job("PR size", waited=clock[0]), NOW):
                rescue_at.append(clock[0])
        def wait(seconds):
            clock[0] += seconds
            return False
        rescue.follow(tick, stopped=wait, seconds=241, clock=lambda: clock[0])
        self.assertEqual(seen[:4], [0, 60, 120, 180])
        self.assertEqual(rescue_at[0], 180)

    def test_a_failed_pass_does_not_end_the_next_minute(self):
        clock, calls, lines = [0.0], [], []
        def tick():
            calls.append(clock[0])
            raise RuntimeError("read refused")
        def wait(seconds):
            clock[0] += seconds
            return False
        rescue.follow(tick, stopped=wait, seconds=121, clock=lambda: clock[0], log=lines.append)
        self.assertEqual(calls, [0, 60, 120])
        self.assertEqual(len(lines), 3)

    def test_handover_stops_before_another_pass(self):
        calls = []
        rescue.follow(lambda: calls.append(1), stopped=lambda seconds: True, seconds=300)
        self.assertEqual(calls, [1])


class WorkflowToken(unittest.TestCase):
    def test_independent_recovery_dispatches_the_single_sweeper_instead_of_mutating_runs(self):
        with mock.patch.object(rescue, "GitHub") as github:
            client = github.return_value
            result = rescue.main(["--wake-sweeper"], env={"GH_TOKEN": "workflow-token", "GH_REPO": "o/r"})
        self.assertEqual(result, 0)
        github.assert_called_once_with("workflow-token", "o/r", "workflow-token")
        self.assertEqual(client.method_calls, [mock.call.wake_sweeper()])

    def test_dry_run_recovery_does_not_dispatch_a_sweeper(self):
        client = mock.Mock()
        result = rescue.main(["--wake-sweeper", "--dry-run"], env={}, client=client)
        self.assertEqual(result, 0)
        self.assertEqual(client.method_calls, [])

    def test_the_sweeper_wake_uses_its_existing_main_concurrency_owner(self):
        client = rescue.GitHub("workflow-token", "o/r")
        with mock.patch("urllib.request.urlopen") as send:
            response = send.return_value.__enter__.return_value
            response.read.return_value = b""
            response.headers = {}
            client.wake_sweeper()
        request = send.call_args.args[0]
        self.assertEqual(request.method, "POST")
        self.assertEqual(request.full_url,
                         "https://api.github.com/repos/o/r/actions/workflows/ci-owned-pool-rescue.yml/dispatches")
        self.assertEqual(json.loads(request.data), {"ref": "main"})

    def test_the_minute_pass_uses_only_its_workflow_token(self):
        with tempfile.TemporaryDirectory() as tmp:
            policy = Path(tmp)
            (policy / "runners.json").write_text(json.dumps({"hosted_light_jobs": {"pr-checks.yml#size": {}}}))
            (policy / "workflows").mkdir()
            env = {"HOSTED_LIGHT_TOKEN": "workflow-token", "READ_TOKEN": "routing-app-token",
                   "GH_TOKEN": "bot-token", "HOSTED_LIGHT_POLICY": str(policy)}
            with mock.patch.object(rescue, "GitHub") as client, mock.patch.object(rescue, "sweep", return_value=[]):
                client.return_value.pending_cancellations.return_value = set()
                callback = rescue.from_env(env, "o/r", now=lambda: NOW, log=lambda text: None)
                callback()
            client.assert_called_once_with("workflow-token", "o/r")
            self.assertIsNone(rescue.from_env(dict(env, HOSTED_LIGHT_DISABLED="1"), "o/r",
                                             now=lambda: NOW, log=lambda text: None))

    def test_unchanged_job_reads_use_authenticated_conditional_requests(self):
        client = rescue.GitHub("workflow-token", "o/r")
        answer = mock.MagicMock()
        answer.__enter__.return_value = answer
        answer.read.return_value = b'{"jobs": []}'
        answer.headers = {"ETag": '"v1"'}
        not_modified = urllib.error.HTTPError("url", 304, "not modified", {}, None)
        with mock.patch.object(rescue.urllib.request, "urlopen", side_effect=[answer, not_modified]) as opened:
            self.assertEqual(client.jobs(7), [])
            self.assertEqual(client.jobs(7), [])
        request = opened.call_args_list[1].args[0]
        self.assertEqual(request.get_header("If-none-match"), '"v1"')
        self.assertEqual(request.get_header("Authorization"), "Bearer workflow-token")


class Sweep(unittest.TestCase):
    def test_a_stalled_report_job_is_cancelled_and_its_failed_jobs_re_run(self):
        jobs = [job("Changes", status="completed", runner_id=1, waited=900), job("PR size"), job("UI review advisory")]
        fake = Fake({"pr-checks.yml": [run(7)]}, {7: jobs}, settles_after=3)
        lines = sweep(fake)
        self.assertEqual(mutations(fake), [("cancel", 7), ("rerun", 7)])
        self.assertIn("1 failed over", lines[-1])

    def test_legacy_blacksmith_web_validation_is_never_cancelled_back_onto_its_fixed_label(self):
        fake = Fake({"web-validation.yml": [run(7, workflow="web-validation.yml")]},
                    {7: [job("web-validation", labels=("blacksmith-4vcpu-ubuntu-2404",), waited=2520)]})
        sweep(fake, workflows=["web-validation.yml"])
        self.assertEqual(mutations(fake), [])

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

    def test_a_token_that_may_not_read_pull_requests_never_cancels(self):
        fake = Fake({"pr-checks.yml": [run(7)]}, {7: [job("PR size")]})
        fake.pull_error = RuntimeError("GET /pulls/7: HTTP 403")
        sweep(fake)
        self.assertEqual(mutations(fake), [])
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


class RecoverCancelled(unittest.TestCase):
    """A confirmed rescue cancellation survives transient rerun failures and a handover."""

    def fake(self, failures=1, *, accepted=False):
        fake = Fake({"pr-checks.yml": [run(7)]}, {7: [job("PR size")]})
        original = fake.run
        def current(run_id):
            state = original(run_id)
            if state.get("status") == "completed":
                state["conclusion"] = "cancelled"
            if accepted and any(call[0] == "rerun" for call in fake.calls):
                state.update(run_attempt=2, status="queued", conclusion=None)
            return state
        fake.run = current
        def rerun(run_id):
            fake.calls.append(("rerun", run_id))
            if sum(call[0] == "rerun" for call in fake.calls) <= failures:
                raise RuntimeError("POST rerun: HTTP 502")
        fake.rerun_failed = rerun
        return fake

    def test_a_transient_rerun_error_recovers_without_another_cancel(self):
        fake = self.fake()
        lines = sweep(fake)
        self.assertEqual(mutations(fake), [("cancel", 7), ("rerun", 7), ("rerun", 7)])
        self.assertIn("1 failed over", lines[-1])

    def test_a_rerun_accepted_before_a_transport_error_is_not_sent_again(self):
        fake = self.fake(accepted=True)
        sweep(fake)
        self.assertEqual(mutations(fake), [("cancel", 7), ("rerun", 7)])

    def test_exhausted_retries_leave_an_owned_journal_entry_for_the_next_pass(self):
        fake = self.fake(failures=100)
        pending, journal = set(), []
        rescue.sweep(fake, ["pr-checks.yml"], now=NOW, dry_run=False, pending=pending,
                     log=journal.append, sleep=lambda _: None, clock=lambda: 0)
        self.assertEqual(pending, {7})
        self.assertTrue(any("cancel sent, re-run to follow: run 7 attempt 1" in line for line in journal))
        fake.rerun_failed = lambda run_id: fake.calls.append(("rerun", run_id))
        rescue.sweep(fake, ["pr-checks.yml"], now=NOW, dry_run=False, pending=pending,
                     log=journal.append, sleep=lambda _: None, clock=lambda: 0)
        self.assertEqual(pending, set())
        self.assertEqual(sum(call[0] == "cancel" for call in fake.calls), 1)
        self.assertTrue(any("cancel settled: run 7 attempt 1" in line for line in journal))

    def test_restored_owned_cancellation_is_retried_but_an_unmarked_one_is_not(self):
        fake = self.fake(failures=0)
        fake.cancelled[7] = -1
        pending = {7}
        rescue.sweep(fake, ["pr-checks.yml"], now=NOW, dry_run=False, pending=pending,
                     log=lambda _: None, sleep=lambda _: None, clock=lambda: 0)
        self.assertEqual(mutations(fake), [("rerun", 7)])
        self.assertEqual(pending, set())
        fake = self.fake(failures=0)
        fake.cancelled[7] = -1
        sweep(fake)
        self.assertEqual(mutations(fake), [])

    def test_closed_or_advanced_pending_runs_are_not_retried(self):
        for closed in (False, True):
            fake = self.fake(failures=0)
            fake.cancelled[7] = -1
            if closed:
                fake.heads[7] = None
            else:
                previous = fake.run
                fake.run = lambda run_id: dict(previous(run_id), run_attempt=2)
            pending = {7}
            rescue.sweep(fake, ["pr-checks.yml"], now=NOW, dry_run=False, pending=pending,
                         log=lambda _: None, sleep=lambda _: None, clock=lambda: 0)
            self.assertEqual(mutations(fake), [])
            self.assertEqual(pending, set())

    def test_a_successor_reads_only_hosted_light_intents_and_newest_settlements(self):
        import owned_pool_rescue
        client = rescue.GitHub("workflow-token", "o/r")
        history = mock.Mock()
        client.history = history
        history.rescue_jobs.return_value = [100, 99]
        history.job_marks.side_effect = [
            owned_pool_rescue.cancel_marks([
                f"{rescue.LIGHT_CANCEL_SETTLED} run 7 attempt 1",
                f"{owned_pool_rescue.CANCEL_SENT} run 8 attempt 1"]),
            owned_pool_rescue.cancel_marks([
                f"{rescue.LIGHT_CANCEL_SENT} run 7 attempt 1",
                f"{rescue.LIGHT_CANCEL_SENT} run 9 attempt 1"])]
        self.assertEqual(client.pending_cancellations(NOW), {9})

    def test_an_incomplete_journal_cannot_authorize_a_recovery(self):
        client = rescue.GitHub("workflow-token", "o/r")
        client.history = mock.Mock()
        client.history.rescue_jobs.return_value = [100]
        client.history.job_marks.return_value = None
        with self.assertRaisesRegex(RuntimeError, "could not be read whole"):
            client.pending_cancellations(NOW)

    def test_an_unavailable_pr_read_keeps_the_owned_intent_without_a_rerun(self):
        fake = self.fake(failures=0)
        fake.cancelled[7] = -1
        fake.pull_error = RuntimeError("GET /pulls/7: HTTP 403")
        pending = {7}
        rescue.sweep(fake, ["pr-checks.yml"], now=NOW, dry_run=False, pending=pending,
                     log=lambda _: None, sleep=lambda _: None, clock=lambda: 0)
        self.assertEqual(mutations(fake), [])
        self.assertEqual(pending, {7})


if __name__ == "__main__":
    unittest.main()
