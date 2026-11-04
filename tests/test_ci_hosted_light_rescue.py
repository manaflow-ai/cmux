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

    def runs(self, workflow, status, start, end, *, page=1):
        self.calls.append(("runs", workflow, status, page))
        source = (self.runs_by_workflow.get(workflow, []) if workflow is not None
                  else [r for rows in self.runs_by_workflow.values() for r in rows])
        rows = [r for r in source if r["status"] == status]
        rows.sort(key=lambda item: (item["created_at"], item["id"]), reverse=True)
        return rows[(page - 1) * 100:page * 100]

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


def sweep(fake: Fake, *, dry_run: bool = False, workflows=("pr-checks.yml",), cursor=None) -> list[str]:
    clock = iter(range(0, 10_000)).__next__
    return rescue.sweep(fake, list(workflows), now=NOW, dry_run=dry_run, sleep=lambda _s: None,
                        clock=lambda: float(clock()), scan_state=cursor)


class Scope(unittest.TestCase):
    def test_declared_workflows_come_from_both_key_forms_and_skip_the_nightly(self):
        runners = {"hosted_light_jobs": {"$comment": ["x"], "pr-checks.yml#size": {}, "pr-checks.yml#ui-review": {},
                                         "ci.yml#changes": {}, "fast-checks.yml:admit": {}, "nightly.yml#decide": {}}}
        self.assertEqual(rescue.declared_workflows(runners), ["ci.yml", "pr-checks.yml"])
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
            with mock.patch.object(rescue, "GitHub") as client, mock.patch.object(rescue, "sweep", return_value=[]):
                client.return_value.pending_cancellations.return_value = set()
                rescue.from_env(dict(env, HOSTED_LIGHT_TOKEN="bot-token", HOSTED_LIGHT_FALLBACK_TOKEN="workflow-token"),
                                "o/r", now=lambda: NOW, log=lambda text: None)()
            client.assert_called_once_with("bot-token", "o/r", fallback="workflow-token", mint=None)
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
    def test_an_overflow_listing_page_finds_a_candidate_past_the_first_100_runs(self):
        gated = [run(100 + index) for index in range(101)]
        overflow = run(999)
        overflow["created_at"] = ago(800)
        fixture_runs = {"pr-checks.yml": gated + [overflow]}
        fixture_jobs = {
            item["id"]: [
                job("PR size"),
                job("build", status="in_progress", labels=("blacksmith-4vcpu-ubuntu-2404",), runner_id=7),
            ]
            for item in gated
        }
        fixture_jobs[overflow["id"]] = [job("PR size")]
        fake = Fake(fixture_runs, fixture_jobs)

        cursor = rescue.ScanState()
        sweep(fake, cursor=cursor)

        self.assertIn(("runs", None, "in_progress", 2), fake.calls)
        self.assertEqual(mutations(fake), [("cancel", overflow["id"]), ("rerun", overflow["id"])])
        self.assertIsNotNone(cursor.cursor)

    def test_a_fair_cursor_reaches_a_newer_eligible_run_behind_40_gated_runs(self):
        """Persistent gated runs must not consume every bounded minute-pass forever."""
        gated = [run(100 + index) for index in range(101)]
        eligible = run(999)
        fixture_runs = {"pr-checks.yml": gated + [eligible]}
        fixture_jobs = {
            item["id"]: [
                job("PR size"),
                job("build", status="in_progress", labels=("blacksmith-4vcpu-ubuntu-2404",), runner_id=7),
            ]
            for item in gated
        }
        fixture_jobs[eligible["id"]] = [job("PR size")]

        def passes_until_rescue(fake, cursor=None, limit=3):
            for count in range(1, limit + 1):
                sweep(fake, cursor=cursor)
                if ("rerun", eligible["id"]) in mutations(fake):
                    return count
            return None

        before = passes_until_rescue(Fake(fixture_runs, fixture_jobs), limit=3)
        cursor = rescue.ScanState()
        after = passes_until_rescue(Fake(fixture_runs, fixture_jobs), cursor=cursor, limit=3)
        self.assertIsNone(before)
        self.assertEqual(after, 3)

    def test_rotating_overflow_pages_do_not_drop_an_eligible_run_before_it_is_read(self):
        """A run outside each page's first 40 still receives bounded eventual service."""
        rows = [run(index) for index in range(1, 902)]
        eligible_id = 400
        jobs = {item["id"]: [job("PR size"), job("build", status="in_progress", runner_id=7)]
                for item in rows}
        jobs[eligible_id] = [job("PR size")]
        fake = Fake({"pr-checks.yml": rows}, jobs)
        cursor = rescue.ScanState()

        for _ in range(35):
            sweep(fake, cursor=cursor)
            if ("rerun", eligible_id) in mutations(fake):
                break

        self.assertIn(("rerun", eligible_id), mutations(fake))

    def test_cached_candidates_expire_when_they_leave_the_rescue_window(self):
        fake = Fake({"pr-checks.yml": [run(7)]}, {7: [job("build", status="in_progress", runner_id=7)]})
        cursor = rescue.ScanState()
        sweep(fake, cursor=cursor)
        fake.runs_by_workflow.clear()
        fake.calls.clear()

        rescue.sweep(fake, ["pr-checks.yml"], now=NOW + rescue.WINDOW, dry_run=True, scan_state=cursor)

        self.assertEqual(fake.job_reads[7], 1)
        self.assertEqual(mutations(fake), [])

    def test_fresh_runs_spend_no_job_reads_and_become_eligible_after_aging(self):
        fresh = [{**run(index), "created_at": ago(60)} for index in range(1, 41)]
        eligible = run(999)
        for source in ("listed", "retained"):
            with self.subTest(source=source):
                rows = fresh + [eligible] if source == "listed" else [eligible]
                fake = Fake({"pr-checks.yml": rows}, {999: [job("PR size")]})
                cursor = rescue.ScanState()
                if source == "retained":
                    cursor.candidates = {item["id"]: {**item, "_workflow": "pr-checks.yml"} for item in fresh}

                sweep(fake, dry_run=True, cursor=cursor)

                self.assertEqual(fake.job_reads, {999: 1})
                self.assertEqual(set(cursor.candidates), {999})
                aged = Fake({"pr-checks.yml": [fresh[0]]}, {1: [job("PR size", waited=60)]})
                rescue.sweep(aged, ["pr-checks.yml"], now=NOW + dt.timedelta(seconds=180), dry_run=False,
                             scan_state=cursor, log=lambda _: None, sleep=lambda _: None, clock=lambda: 0)
                self.assertEqual(mutations(aged), [("cancel", 1), ("rerun", 1)])

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

    def test_unreadable_owned_cancellations_do_not_starve_newer_recovery_or_fresh_work(self):
        fake = Fake({"pr-checks.yml": [run(12)]}, {12: [job("PR size")]})
        previous = fake.run
        def current(run_id):
            if run_id <= 10:
                raise RuntimeError(f"GET /actions/runs/{run_id}: HTTP 403")
            if run_id == 11:
                return {**run(11), "status": "completed", "conclusion": "cancelled"}
            return previous(run_id)
        fake.run = current
        pending, cursor = set(range(1, 12)), rescue.ScanState()
        serviced = {}
        for count in range(1, 4):
            before = len(mutations(fake))
            rescue.sweep(fake, ["pr-checks.yml"], now=NOW, dry_run=False, pending=pending,
                         scan_state=cursor, log=lambda _: None, sleep=lambda _: None, clock=lambda: 0)
            for run_id in (11, 12):
                if ("rerun", run_id) in mutations(fake):
                    serviced.setdefault(run_id, count)
            self.assertLessEqual(len(mutations(fake)) - before, rescue.MAX_RESCUES * 2)

        self.assertEqual(serviced, {12: 1, 11: 3})
        self.assertEqual(pending, set(range(1, 11)))

    def test_slow_unreadable_receipts_leave_settle_time_for_fresh_work(self):
        fake = Fake({"pr-checks.yml": [run(12)]}, {12: [job("PR size")]})
        elapsed = [0.0]
        previous = fake.run
        def current(run_id):
            if run_id <= 10:
                elapsed[0] += 20
                raise RuntimeError(f"GET /actions/runs/{run_id}: HTTP 403")
            return previous(run_id)
        fake.run = current
        pending = set(range(1, 11))

        rescue.sweep(fake, ["pr-checks.yml"], now=NOW, dry_run=False, pending=pending,
                     scan_state=rescue.ScanState(), log=lambda _: None, sleep=lambda _: None,
                     clock=lambda: elapsed[0])

        self.assertEqual(mutations(fake), [("cancel", 12), ("rerun", 12)])
        self.assertEqual(pending, set(range(1, 11)))

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


class Quota(unittest.TestCase):
    """The pass shares the repository's one GITHUB_TOKEN pool (1,000 requests an hour) with every workflow."""

    def test_no_overflow_page_is_read_when_the_newest_page_is_not_full(self):
        fake = Fake({"pr-checks.yml": [run(7)]}, {7: [job("build", status="in_progress", runner_id=7)]})
        sweep(fake, dry_run=True, cursor=rescue.ScanState())
        listings = [call for call in fake.calls if call[0] == "runs"]
        self.assertEqual(listings, [("runs", None, "queued", 1), ("runs", None, "in_progress", 1)])

    def test_one_repository_listing_per_status_covers_every_declared_workflow(self):
        """Two listings a pass however many workflows are declared; an undeclared workflow's run is never read."""
        declared = ["ci.yml", "pr-checks.yml", "web-validation.yml", "cmux-next.yml"]
        fake = Fake({"ci.yml": [run(1, workflow="ci.yml")], "web-validation.yml": [run(2, workflow="web-validation.yml")],
                     "other.yml": [run(3, workflow="other.yml")]},
                    {1: [job("PR size")], 2: [job("PR size")], 3: [job("PR size")]})
        sweep(fake, dry_run=True, workflows=declared, cursor=rescue.ScanState())
        listings = [call for call in fake.calls if call[0] == "runs"]
        self.assertEqual(listings, [("runs", None, "queued", 1), ("runs", None, "in_progress", 1)])
        self.assertEqual(set(fake.job_reads), {1, 2})

    def test_a_declared_run_behind_two_pages_of_undeclared_runs_is_found_by_the_rotation(self):
        """Pages 1 and 2 are read every pass; the third page onward rotates, so a buried declared run is reached."""
        noise = [run(1000 + index, workflow="other.yml") for index in range(200)]
        buried = run(7)
        buried["created_at"] = ago(1200)
        fake = Fake({"other.yml": noise, "pr-checks.yml": [buried]}, {7: [job("PR size")]})
        cursor = rescue.ScanState()
        sweep(fake, dry_run=True, cursor=cursor)
        listings = [call for call in fake.calls if call[0] == "runs"]
        self.assertIn(("runs", None, "in_progress", 1), listings)
        self.assertIn(("runs", None, "in_progress", 2), listings)
        self.assertIn(("runs", None, "in_progress", 3), listings)
        self.assertEqual(set(fake.job_reads), {7})

    def test_the_repository_listing_reads_the_runs_endpoint(self):
        client = rescue.GitHub("workflow-token", "o/r")
        with mock.patch.object(client, "request", return_value={"workflow_runs": []}) as request:
            client.runs(None, "queued", NOW - rescue.WINDOW, NOW, page=1)
            client.runs("ci.yml", "queued", NOW - rescue.WINDOW, NOW, page=1)
        self.assertTrue(request.call_args_list[0].args[1].startswith("/actions/runs?"))
        self.assertTrue(request.call_args_list[1].args[1].startswith("/actions/workflows/ci.yml/runs?"))

    def test_workflow_file_names_a_listed_run(self):
        self.assertEqual(rescue.workflow_file({"path": ".github/workflows/ci.yml"}), "ci.yml")
        self.assertEqual(rescue.workflow_file({"path": ".github/workflows/ci.yml@refs/heads/main"}), "ci.yml")
        self.assertIsNone(rescue.workflow_file({"path": "dynamic/copilot"}))
        self.assertIsNone(rescue.workflow_file("not a run"))

    def test_a_pool_at_its_reserve_makes_no_listing_or_job_read(self):
        fake = Fake({"pr-checks.yml": [run(7)]}, {7: [job("PR size")]})
        fake.remaining, fake.reset = rescue.POOL_RESERVE, NOW.timestamp() + 600
        fake.spare = lambda now: now.timestamp() >= fake.reset or fake.remaining > rescue.POOL_RESERVE
        lines = sweep(fake)
        self.assertEqual(fake.calls, [])
        self.assertIn("reserve", lines[-1])

    def test_job_reads_stop_once_the_pool_reaches_its_reserve(self):
        rows = [run(index) for index in range(1, 11)]
        fake = Fake({"pr-checks.yml": rows}, {item["id"]: [job("build", status="in_progress", runner_id=7)]
                                              for item in rows})
        fake.remaining, fake.reset = rescue.POOL_RESERVE + 3, NOW.timestamp() + 600
        reads = fake.jobs

        def jobs(run_id):
            fake.remaining -= 1
            return reads(run_id)

        fake.jobs = jobs
        fake.spare = lambda now: fake.remaining > rescue.POOL_RESERVE
        lines = sweep(fake, dry_run=True, cursor=rescue.ScanState())
        self.assertEqual(len(fake.job_reads), 3)
        self.assertTrue(any("7 job reads left to a later pass" in line for line in lines), lines)

    def test_the_client_reads_the_pool_from_every_response_and_spares_it_after_the_reset(self):
        client = rescue.GitHub("workflow-token", "o/r")
        answer = mock.MagicMock()
        answer.__enter__.return_value = answer
        answer.read.return_value = b'{"jobs": []}'
        answer.headers = {"ETag": '"v1"', "X-RateLimit-Remaining": "900", "X-RateLimit-Reset": str(int(NOW.timestamp()) + 60)}
        refused = urllib.error.HTTPError("url", 403, "rate limited",
                                         {"X-RateLimit-Remaining": "0", "X-RateLimit-Reset": str(int(NOW.timestamp()) + 60)},
                                         None)
        self.assertTrue(client.spare(NOW))
        with mock.patch.object(rescue.urllib.request, "urlopen", side_effect=[answer, refused]):
            client.jobs(7)
            self.assertEqual(client.remaining, 900)
            self.assertTrue(client.spare(NOW))
            with self.assertRaises(RuntimeError):
                client.run(8)
        self.assertEqual(client.remaining, 0)
        self.assertFalse(client.spare(NOW))
        self.assertTrue(client.spare(NOW + dt.timedelta(seconds=60)))

    def test_an_unreadable_journal_is_read_again_only_after_the_retry_interval(self):
        with tempfile.TemporaryDirectory() as tmp:
            policy = Path(tmp)
            (policy / "runners.json").write_text(json.dumps({"hosted_light_jobs": {"pr-checks.yml#size": {}}}))
            (policy / "workflows").mkdir()
            env = {"HOSTED_LIGHT_TOKEN": "workflow-token", "HOSTED_LIGHT_POLICY": str(policy)}
            clock = [NOW]
            with mock.patch.object(rescue, "GitHub") as client, mock.patch.object(rescue, "sweep", return_value=[]):
                journal = client.return_value.pending_cancellations
                journal.side_effect = RuntimeError("2500 rescue runs in the window, more than 10 pages")
                callback = rescue.from_env(env, "o/r", now=lambda: clock[0], log=lambda text: None)
                callback()
                clock[0] = NOW + dt.timedelta(minutes=14)
                callback()
                self.assertEqual(journal.call_count, 1)
                clock[0] = NOW + rescue.JOURNAL_RETRY
                journal.side_effect, journal.return_value = None, set()
                callback()
                callback()
                self.assertEqual(journal.call_count, 2)



class BotTokenFirst(unittest.TestCase):
    """Reads go out as cmux-bot; the shared workflow token answers only while cmux-bot is low or refused."""

    def answer(self, remaining: int, body: bytes = b'{"workflow_runs": []}'):
        response = mock.MagicMock()
        response.__enter__.return_value = response
        response.read.return_value = body
        response.headers = {"X-RateLimit-Remaining": str(remaining), "X-RateLimit-Reset": str(NOW.timestamp() + 900)}
        return response

    def sent(self, opened) -> list[str]:
        return [call.args[0].get_header("Authorization") for call in opened.call_args_list]

    def client(self, **kwargs):
        return rescue.GitHub("bot-token", "o/r", fallback="workflow-token", clock=lambda: NOW.timestamp(), **kwargs)

    def test_reads_use_the_bot_and_writes_the_workflow_token(self):
        client = self.client()
        with mock.patch.object(rescue.urllib.request, "urlopen",
                               side_effect=[self.answer(4000), self.answer(4000, b"")]) as opened:
            client.runs(None, "queued", NOW - rescue.WINDOW, NOW)
            client.cancel(7)
        self.assertEqual(self.sent(opened), ["Bearer bot-token", "Bearer workflow-token"])

    def test_a_low_bot_pool_moves_reads_to_the_workflow_token_until_its_reset(self):
        client = self.client()
        with mock.patch.object(rescue.urllib.request, "urlopen",
                               side_effect=[self.answer(rescue.POOL_RESERVE), self.answer(900)]) as opened:
            client.runs(None, "queued", NOW - rescue.WINDOW, NOW)
            client.runs(None, "in_progress", NOW - rescue.WINDOW, NOW)
        self.assertEqual(self.sent(opened), ["Bearer bot-token", "Bearer workflow-token"])
        self.assertTrue(client.spare(NOW))
        self.assertEqual(client.remaining, 900)

    def test_a_refused_bot_read_is_asked_again_with_the_workflow_token(self):
        client = self.client()
        refused = urllib.error.HTTPError("url", 403, "rate limited", {"X-RateLimit-Remaining": "0"}, None)
        with mock.patch.object(rescue.urllib.request, "urlopen", side_effect=[refused, self.answer(900)]) as opened:
            client.runs(None, "queued", NOW - rescue.WINDOW, NOW)
        self.assertEqual(self.sent(opened), ["Bearer bot-token", "Bearer workflow-token"])
        self.assertEqual(client.read_pool(), "fallback")

    def test_both_pools_low_stop_the_pass(self):
        client = self.client()
        client.pools["primary"].remaining = client.pools["fallback"].remaining = rescue.POOL_RESERVE
        client.pools["primary"].reset = client.pools["fallback"].reset = NOW.timestamp() + 600
        self.assertFalse(client.spare(NOW))

    def test_the_bot_token_is_minted_again_before_its_hour_is_up(self):
        clock = [NOW.timestamp()]
        client = rescue.GitHub("bot-token", "o/r", fallback="workflow-token", mint=lambda: "bot-token-2",
                               clock=lambda: clock[0])
        clock[0] += rescue.APP_TOKEN_SECONDS
        with mock.patch.object(rescue.urllib.request, "urlopen", side_effect=[self.answer(4000)]) as opened:
            client.runs(None, "queued", NOW - rescue.WINDOW, NOW)
        self.assertEqual(self.sent(opened), ["Bearer bot-token-2"])

    def test_the_workflow_mints_the_bot_token_for_the_pass(self):
        text = (ROOT / ".github/workflows/ci-owned-pool-rescue.yml").read_text()
        self.assertIn("HOSTED_LIGHT_TOKEN: ${{ steps.cmux-bot-token.outputs.token || github.token }}", text)
        self.assertIn("HOSTED_LIGHT_FALLBACK_TOKEN: ${{ github.token }}", text)

if __name__ == "__main__":
    unittest.main()
