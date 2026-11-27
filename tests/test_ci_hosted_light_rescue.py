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
import urllib.parse
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
            (directory / "report.yml").write_text("on:\n  workflow_call:\n")
            (directory / "caller.yml").write_text("on: [pull_request]\njobs:\n  report:\n    uses: ./.github/workflows/report.yml\n")
            self.assertEqual(rescue.with_callers(["report.yml"], directory), ["caller.yml"])

    def test_callers_drops_only_workflows_proven_to_be_reusable_only(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            (directory / "reusable.yml").write_text("on:\n  workflow_call:\n")
            (directory / "caller.yml").write_text(
                "on:\n  workflow_call:\n  pull_request:\n\njobs:\n  call:\n    uses: ./.github/workflows/reusable.yml\n")
            self.assertEqual(rescue.with_callers(["reusable.yml"], directory), ["caller.yml"])

    def test_reusable_only_callers_with_nested_inputs_are_filtered_but_dual_trigger_is_kept(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            (directory / "reusable.yml").write_text(
                "on:\n  workflow_call:\n    inputs:\n      mode:\n        required: false\n    outputs:\n      result:\n        value: x\n")
            (directory / "dual.yml").write_text(
                "on:\n  workflow_call:\n    inputs:\n      mode:\n        required: false\n  pull_request:\n")
            (directory / "caller.yml").write_text(
                "on: [pull_request]\njobs:\n  call:\n    uses: ./.github/workflows/reusable.yml\n")
            self.assertEqual(rescue.with_callers(["reusable.yml", "dual.yml"], directory),
                             ["caller.yml", "dual.yml"])

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

    def test_forbidden_diagnostics_are_bounded_and_quota_refusal_is_cooled_down(self):
        client = rescue.GitHub("workflow-token", "o/r")
        body = json.dumps({"message": "API rate limit exceeded; " + "secret-token " * 200,
                           "resource": "core"}).encode()
        error = urllib.error.HTTPError("url", 403, "forbidden", {
            "X-RateLimit-Remaining": "0", "X-RateLimit-Limit": "5000", "X-RateLimit-Reset": "123",
            "X-RateLimit-Resource": "core", "Retry-After": "9", "X-Secret": "do-not-print"},
            __import__("io").BytesIO(body))
        with mock.patch.object(rescue.urllib.request, "urlopen", side_effect=error) as opened:
            with self.assertRaises(rescue.GitHubHTTPError) as raised:
                client.run(7)
            with self.assertRaises(rescue.GitHubHTTPError) as raised_again:
                client.run(8)
        self.assertEqual(opened.call_count, 1)
        self.assertEqual(raised.exception.status, 403)
        self.assertEqual(raised_again.exception.status, 403)
        rendered = str(raised.exception)
        self.assertTrue(rendered.endswith("HTTP 403"), rendered)
        self.assertIn("quota", rendered)
        self.assertIn("remaining=0", rendered)
        self.assertIn("resource=core", rendered)
        self.assertNotIn("secret-token", rendered)
        self.assertNotIn("X-Secret", rendered)


class Sweep(unittest.TestCase):
    def test_discovery_query_retains_fresh_runs_for_local_stall_filtering(self):
        client = rescue.GitHub("workflow-token", "o/r")
        with mock.patch.object(client, "request", return_value={"workflow_runs": []}) as request:
            client.runs("pr-checks.yml", "queued", NOW - rescue.WINDOW,
                        NOW - dt.timedelta(seconds=rescue.STALL_SECONDS))
        query = rescue.urllib.parse.parse_qs(rescue.urllib.parse.urlsplit(request.call_args.args[1]).query)
        self.assertEqual(query["created"], [f">={rescue.iso(NOW - rescue.WINDOW)}"])
        self.assertEqual(query["event"], ["pull_request"])

    def test_fresh_run_becomes_eligible_while_discovery_page_is_cached(self):
        fresh = {**run(7), "created_at": ago(150)}
        fake = Fake({"pr-checks.yml": [fresh]}, {7: [job("PR size", waited=150)]})
        cursor = rescue.ScanState()
        rescue.sweep(fake, ["pr-checks.yml"], now=NOW, dry_run=False, scan_state=cursor,
                     clock=lambda: 0, sleep=lambda _: None)
        self.assertEqual(fake.job_reads, {})
        self.assertEqual(mutations(fake), [])
        fake.calls.clear()
        rescue.sweep(fake, ["pr-checks.yml"], now=NOW + dt.timedelta(seconds=31), dry_run=False,
                     scan_state=cursor, clock=lambda: 31, sleep=lambda _: None, log=lambda _: None)
        self.assertEqual(sum(call[0] == "runs" for call in fake.calls), 0)
        self.assertEqual(mutations(fake), [("cancel", 7), ("rerun", 7)])

    def test_discovery_page_cache_reuses_a_page_within_its_short_ttl(self):
        fake = Fake({"pr-checks.yml": [run(7)]}, {7: [job("PR size")]})
        cursor = rescue.ScanState()
        rescue.sweep(fake, ["pr-checks.yml"], now=NOW, dry_run=True, scan_state=cursor,
                     clock=lambda: 0, sleep=lambda _: None)
        first = sum(call[0] == "runs" for call in fake.calls)
        fake.calls.clear()
        rescue.sweep(fake, ["pr-checks.yml"], now=NOW + dt.timedelta(seconds=60), dry_run=True, scan_state=cursor,
                     clock=lambda: 60, sleep=lambda _: None)
        self.assertEqual(first, 2)
        self.assertEqual(sum(call[0] == "runs" for call in fake.calls), 0)

    def test_non_stalled_job_verdict_is_cached_but_stalled_verdict_is_read_again(self):
        fake = Fake({"pr-checks.yml": [run(7)]}, {7: [job("build", status="in_progress", runner_id=7)]})
        cursor = rescue.ScanState()
        rescue.sweep(fake, ["pr-checks.yml"], now=NOW, dry_run=True, scan_state=cursor,
                     clock=lambda: 0, sleep=lambda _: None)
        first_reads = fake.job_reads[7]
        rescue.sweep(fake, ["pr-checks.yml"], now=NOW + dt.timedelta(seconds=30), dry_run=True, scan_state=cursor,
                     clock=lambda: 30, sleep=lambda _: None)
        self.assertEqual(fake.job_reads[7], first_reads)

    def test_same_sequence_reduces_discovery_and_non_stalled_job_reads(self):
        rows = [run(index) for index in range(1, 41)]
        fake = Fake({"pr-checks.yml": rows}, {
            item["id"]: [job("build", status="in_progress", runner_id=7)] for item in rows})
        cursor = rescue.ScanState()
        rescue.sweep(fake, ["pr-checks.yml"], now=NOW, dry_run=True, scan_state=cursor,
                     clock=lambda: 0, sleep=lambda _: None)
        first_discovery = sum(call[0] == "runs" for call in fake.calls)
        first_jobs = sum(fake.job_reads.values())
        fake.calls.clear()
        rescue.sweep(fake, ["pr-checks.yml"], now=NOW + dt.timedelta(seconds=60), dry_run=True, scan_state=cursor,
                     clock=lambda: 60, sleep=lambda _: None)
        self.assertEqual((first_discovery, first_jobs), (2, 40))
        self.assertEqual(sum(call[0] == "runs" for call in fake.calls), 0)
        self.assertEqual(sum(fake.job_reads.values()), 40)

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
        history.rescue_jobs.assert_called_once_with(
            NOW - rescue.WINDOW, events=("schedule", "workflow_dispatch"), titles=("owned-pool-sweeper",))

    def test_unrelated_history_cap_does_not_hide_newest_owned_settlement(self):
        import owned_pool_rescue
        client = rescue.GitHub("workflow-token", "o/r")
        history = owned_pool_rescue.GitHub("workflow-token", "o/r")
        client.history = history
        listing_reads = []
        rows = [
            {"id": 10, "event": "schedule", "display_title": "owned-pool-sweeper", "status": "completed",
             "conclusion": "cancelled", "run_attempt": 1, "created_at": ago(600),
             "run_started_at": ago(600), "updated_at": ago(400)},
            {"id": 20, "event": "workflow_dispatch", "display_title": "owned-pool-sweeper", "status": "completed",
             "conclusion": "success", "run_attempt": 1, "created_at": ago(300),
             "run_started_at": ago(300), "updated_at": ago(200)}]
        def request(method, path, **_):
            if path.startswith("/actions/workflows/"):
                listing_reads.append(path)
                query = rescue.urllib.parse.parse_qs(rescue.urllib.parse.urlsplit(path).query)
                if "event" not in query:
                    return {"total_count": 2501, "workflow_runs": []}
                selected = [row for row in rows if row["event"] == query["event"][0]]
                return {"total_count": len(selected), "workflow_runs": selected if query["page"] == ["1"] else []}
            run_id = int(path.split("/runs/")[1].split("/")[0])
            return {"jobs": [{"id": run_id, "status": "completed", "conclusion": "success"}]}
        history.request = request
        marks = {
            20: [f"{rescue.LIGHT_CANCEL_SETTLED} run 7 attempt 1"],
            10: [f"{rescue.LIGHT_CANCEL_SENT} run 7 attempt 1", f"{rescue.LIGHT_CANCEL_SENT} run 9 attempt 1"]}
        history.job_marks = lambda job_id: owned_pool_rescue.cancel_marks(marks[job_id])
        self.assertEqual(client.pending_cancellations(NOW), {9})
        self.assertEqual(len(listing_reads), 4)
        with self.assertRaises(owned_pool_rescue.RescueHistoryCapped):
            history.rescue_jobs(NOW - rescue.WINDOW)

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

    def test_a_quota_refusal_on_both_tokens_pauses_reads_without_another_request(self):
        client = self.client()
        def refused():
            return urllib.error.HTTPError("url", 403, "rate limited", {"X-RateLimit-Remaining": "0"}, None)
        with mock.patch.object(rescue.urllib.request, "urlopen", side_effect=[refused(), refused()]) as opened:
            with self.assertRaises(rescue.GitHubHTTPError):
                client.runs(None, "queued", NOW - rescue.WINDOW, NOW)
            with self.assertRaises(rescue.GitHubHTTPError) as again:
                client.runs(None, "in_progress", NOW - rescue.WINDOW, NOW)
        self.assertEqual(self.sent(opened), ["Bearer bot-token", "Bearer workflow-token"])
        self.assertIn("quota", str(again.exception))

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

class BacklogFake:
    """GitHub for the backlog pass: listings, runs, pulls, jobs and earlier passes' logs, by request path. Every call,
    read or write, counts in `reads`."""

    repo = "manaflow-ai/cmux"

    def __init__(self, runs: list[dict], jobs: dict[int, list[dict]], pulls: dict[int, dict] | None = None,
                 branch_pulls: dict[str, list[dict]] | None = None, *, settles: bool = True,
                 remaining: int = 12_500) -> None:
        self.runs, self.jobs_by_run = {r["id"]: r for r in runs}, jobs
        self.pulls, self.branch_pulls = pulls or {}, branch_pulls or {}
        self.settles, self.remaining_core = settles, remaining
        self.calls: list[tuple] = []
        self.listings: list[str] = []
        self.started_meanwhile: set[int] = set()
        self.reads = 0
        # Earlier backlog passes, oldest first: (pass run id, its log lines).
        self.passes: list[tuple[int, list[str]]] = []

    def record_pass(self, lines: list[str], *, minutes_ago: float = 10) -> None:
        self.passes.append((10 ** 15 + len(self.passes), [f"{ago(minutes_ago * 60)} {line}" for line in lines]))

    def settle(self) -> None:
        for run_id, run_ in self.runs.items():
            if run_.get("status") == "cancelling":
                self.runs[run_id] = {**run_, "status": "completed"}

    def rate_limit(self):
        self.reads += 1
        return self.remaining_core, NOW.timestamp() + 1800

    def request(self, method, path):
        self.reads += 1
        assert method == "GET", path
        parsed = urllib.parse.urlparse(path)
        query = dict(urllib.parse.parse_qsl(parsed.query))
        if parsed.path == f"/actions/workflows/{rescue.BACKLOG_WORKFLOW}/runs":
            return {"workflow_runs": [{"id": pass_id, "created_at": ago(600)}
                                      for pass_id, _ in reversed(self.passes)][:int(query["per_page"])]}
        if parsed.path == "/actions/runs" and "head_sha" in query:
            return {"workflow_runs": [r for r in self.runs.values() if r["head_sha"] == query["head_sha"]]}
        if parsed.path == "/actions/runs":
            self.listings.append(path)
            low, high = (rescue.parse_time(part) for part in query["created"].split(".."))
            rows = [r for r in self.runs.values()
                    if query["status"] in (r["status"], r.get("conclusion")) and r["event"] == query["event"]
                    and low <= rescue.parse_time(r["created_at"]) <= high]
            rows.sort(key=lambda r: (r["created_at"], r["id"]), reverse=True)
            page = int(query.get("page", 1))
            return {"total_count": len(rows), "workflow_runs": rows[(page - 1) * 100:page * 100]}
        if parsed.path.startswith("/actions/runs/"):
            found = dict(self.runs[int(parsed.path.rsplit("/", 1)[1])])
            return {**found, "status": "in_progress"} if found["status"] == "cancelling" else found
        if parsed.path.startswith("/pulls/"):
            return self.pulls[int(parsed.path.rsplit("/", 1)[1])]
        if parsed.path == "/pulls":
            return self.branch_pulls.get(query["head"].split(":", 1)[1], [])
        raise AssertionError(path)

    def jobs(self, run_id):
        self.reads += 1
        if run_id >= 10 ** 15:
            return [{"id": run_id + 1, "name": "backlog"}]
        if run_id in self.started_meanwhile and any(c == ("jobs", run_id) for c in self.calls):
            return [job("x", status="in_progress", runner_id=7)]
        self.calls.append(("jobs", run_id))
        return self.jobs_by_run.get(run_id, [])

    def job_log(self, job_id):
        self.reads += 1
        return dict(self.passes)[job_id - 1]

    def cancel(self, run_id):
        self.reads += 1
        self.calls.append(("cancel", run_id))
        self.runs[run_id] = {**self.runs[run_id], "status": "completed" if self.settles else "cancelling",
                             "conclusion": "cancelled"}

    def force_cancel(self, run_id):
        self.reads += 1
        self.calls.append(("force-cancel", run_id))

    def rerun_failed(self, run_id):
        self.reads += 1
        self.calls.append(("rerun", run_id))
        self.runs[run_id] = {**self.runs[run_id], "run_attempt": 2, "status": "queued", "conclusion": None}


def backlog_run(run_id: int, *, age_min: float = 200, event: str = "pull_request", status: str = "queued",
                attempt: int = 1, workflow: str = "web-validation.yml", head: str = HEAD, pr: int | None = None,
                pr_head: str = HEAD, repo: str = "manaflow-ai/cmux") -> dict:
    return {"id": run_id, "event": event, "run_attempt": attempt, "status": status, "head_sha": head,
            "head_branch": f"lane/{run_id}", "created_at": ago(age_min * 60),
            "path": f".github/workflows/{workflow}",
            "head_repository": {"full_name": repo, "owner": {"login": repo.split("/")[0]}},
            "pull_requests": [] if pr is None else [{"number": pr, "head": {"sha": pr_head}}]}


def backlog(fake: BacklogFake, *, dry_run=False, declared=("pr-checks.yml",), actions=rescue.BACKLOG_ACTIONS,
            now=NOW, since=None, routes=None):
    """One pass. Like the workflow, it starts from the earlier passes' logs and leaves its own for the next."""
    if not fake.passes:
        fake.record_pass(rescue.journal_lines({}), minutes_ago=20)
    lines, counts = rescue.backlog_sweep(fake, now=now, dry_run=dry_run, declared=declared, actions=actions,
                                         since=since, sleep=lambda _s: None, clock=lambda: 0.0, routes=routes)
    fake.record_pass(lines)
    return lines, counts


def two_passes(fake: BacklogFake, **kwargs):
    """A pass, then the next one ten minutes later; the counts of each."""
    _, first = backlog(fake, **kwargs)
    fake.settle()
    _, second = backlog(fake, now=NOW + dt.timedelta(minutes=10), **kwargs)
    return first, second


def own_heads(runs: list[dict]) -> dict[int, dict]:
    """Give each run its own pull request at its own head (one head's newer run would stand in for the older one's
    re-run); the open pull requests by number."""
    pulls = {}
    for run_ in runs:
        head = f"{run_['id']:040x}"
        run_.update(head_sha=head, pull_requests=[{"number": run_["id"], "head": {"sha": head}}])
        pulls[run_["id"]] = {"state": "open", "head": {"sha": head}}
    return pulls


def backlog_mutations(fake: BacklogFake) -> list[tuple]:
    return [call for call in fake.calls if call[0] in ("cancel", "rerun", "force-cancel")]


OPEN_AT_HEAD = {"state": "open", "head": {"sha": HEAD}}


class Backlog(unittest.TestCase):
    """--backlog: pull request runs whose every unfinished job sat 30+ min on hosted Ubuntu, at any age under 24 h."""

    def test_a_three_hour_old_run_at_its_head_is_cancelled_and_re_run_by_the_next_pass(self):
        fake = BacklogFake([backlog_run(1, pr=11)], {1: [job("changes", waited=3 * 3600), job("plan", waited=3 * 3600)]},
                           pulls={11: OPEN_AT_HEAD})
        lines, counts = backlog(fake)
        self.assertEqual(backlog_mutations(fake), [("cancel", 1)])
        self.assertEqual((counts["cancelled"], counts["journalled"], counts["superseded"]), (1, 1, 0))
        self.assertIn("1 cancelled (0 superseded), 0 earlier cancels re-run, 1 wait for their re-run", lines[-3])
        self.assertTrue(lines[-2].startswith("hosted-backlog journal: run 1 cancelled "))
        lines, counts = backlog(fake, now=NOW + dt.timedelta(minutes=10))
        self.assertEqual(backlog_mutations(fake), [("cancel", 1), ("rerun", 1)])
        self.assertEqual((counts["recovered"], counts["pending"]), (1, 0))
        self.assertEqual(lines[-1], "hosted-backlog journal end: 0 cancelled runs wait for their re-run")

    def test_cancels_that_never_settle_in_their_pass_are_all_re_run_by_the_next(self):
        # cmux#45886 polled 120 s for each cancel to settle and re-ran only those that did: on 2026-11-18 almost none
        # did, and every pass left about 20 pull request heads cancelled with no checks and no later re-run.
        runs = [backlog_run(700 + i, age_min=100 + i, pr=1) for i in range(rescue.BACKLOG_PENDING_MAX)]
        fake = BacklogFake(runs, {r["id"]: [job("x", waited=6000)] for r in runs}, pulls=own_heads(runs),
                           settles=False)
        first, second = two_passes(fake)
        cancelled = sorted(c[1] for c in backlog_mutations(fake) if c[0] == "cancel")
        reran = sorted(c[1] for c in backlog_mutations(fake) if c[0] == "rerun")
        self.assertEqual(len(cancelled), rescue.BACKLOG_PENDING_MAX)
        self.assertEqual((first["recovered"], first["pending"]), (0, rescue.BACKLOG_PENDING_MAX))
        self.assertEqual(reran, cancelled)
        self.assertEqual((second["recovered"], second["pending"], second["cancelled"]),
                         (rescue.BACKLOG_PENDING_MAX, 0, 0))

    def test_a_cancel_still_unsettled_is_force_cancelled_once_and_kept(self):
        fake = BacklogFake([backlog_run(710, pr=1)], {710: [job("x", waited=6000)]}, pulls={1: OPEN_AT_HEAD},
                           settles=False)
        backlog(fake)
        for minutes in (10, 20):
            _, counts = backlog(fake, now=NOW + dt.timedelta(minutes=minutes))
            self.assertEqual(counts["pending"], 1)
        self.assertEqual(backlog_mutations(fake), [("cancel", 710), ("force-cancel", 710)])
        fake.settle()
        _, counts = backlog(fake, now=NOW + dt.timedelta(minutes=30))
        self.assertEqual(backlog_mutations(fake)[-1], ("rerun", 710))

    def test_a_cancel_never_re_run_in_the_recovery_window_is_reported_and_dropped(self):
        fake = BacklogFake([backlog_run(711, pr=1)], {711: [job("x", waited=6000)]}, pulls={1: OPEN_AT_HEAD},
                           settles=False)
        backlog(fake)
        lines, counts = backlog(fake, now=NOW + rescue.BACKLOG_RECOVER_WINDOW + dt.timedelta(minutes=1))
        self.assertEqual((counts["expired"], counts["pending"]), (1, 0))
        self.assertTrue(any(line.startswith("::warning") and "run 711" in line for line in lines))

    def test_current_head_cancels_wait_while_the_journal_is_full(self):
        runs = [backlog_run(720 + i, age_min=100 + i, pr=1) for i in range(rescue.BACKLOG_PENDING_MAX + 5)]
        fake = BacklogFake(runs, {r["id"]: [job("x", waited=6000)] for r in runs}, pulls={1: OPEN_AT_HEAD},
                           settles=False)
        _, first = backlog(fake, actions=rescue.BACKLOG_ACTIONS_MAX)
        self.assertEqual(first["cancelled"], rescue.BACKLOG_PENDING_MAX)
        _, second = backlog(fake, now=NOW + dt.timedelta(minutes=5), actions=rescue.BACKLOG_ACTIONS_MAX)
        self.assertEqual(second["cancelled"], 0)   # none settled: nothing more is cancelled at a current head

    def test_no_journal_means_no_current_head_cancel(self):
        fake = BacklogFake([backlog_run(730, pr=1)], {730: [job("x", waited=6000)]}, pulls={1: OPEN_AT_HEAD})
        fake.request = mock.Mock(side_effect=RuntimeError("HTTP 502"))
        lines, counts = rescue.backlog_sweep(fake, now=NOW, dry_run=False, declared=())
        self.assertEqual(backlog_mutations(fake), [])
        self.assertTrue(any("no earlier pass's journal could be read" in line for line in lines))
        self.assertFalse(any(rescue.JOURNAL_END in line for line in lines))

    def test_a_pass_never_makes_more_calls_than_its_bound(self):
        # Listings, jobs, pull requests, re-reads, journal reads, recovery and every cancel and re-run, counted
        # together: cmux#45886 counted only first job reads, and its settle loop made up to 500 more calls a pass.
        runs = [backlog_run(400 + i, age_min=100 + i, pr=1) for i in range(300)]
        stranded_runs = [{**backlog_run(500_000 + i, pr=1), "status": "completed", "conclusion": "cancelled"}
                         for i in range(40)]
        pulls = own_heads(runs + stranded_runs)
        superseded = [backlog_run(800 + i, age_min=100 + i, pr=2) for i in range(60)]
        pulls[2] = {"state": "open", "head": {"sha": "f" * 40}}
        fake = BacklogFake(runs + superseded + stranded_runs, {r["id"]: [job("x", waited=6000)] for r in runs + superseded},
                           pulls=pulls, settles=False)
        stranded = {r["id"]: rescue.Journalled(NOW - dt.timedelta(minutes=30)) for r in stranded_runs}
        fake.record_pass(rescue.journal_lines(stranded))
        for minutes in (0, 10, 20, 30):
            before = fake.reads
            lines, counts = backlog(fake, now=NOW + dt.timedelta(minutes=minutes), actions=rescue.BACKLOG_ACTIONS_MAX)
            self.assertLessEqual(fake.reads - before, rescue.BACKLOG_READS)
            self.assertEqual(counts["requests"], fake.reads - before)
            self.assertIn(f"of {rescue.BACKLOG_READS} API calls", lines[-2 - counts["pending"]])
            self.assertLessEqual(counts["pending"], max(rescue.BACKLOG_PENDING_MAX, 40))
            fake.settle()
        self.assertEqual(sum(1 for c in fake.calls if c[0] == "rerun" and c[1] >= 500_000), 40)

    def test_a_pass_with_a_spent_budget_cancels_nothing_and_exits_0(self):
        fake = BacklogFake([backlog_run(740, pr=1)], {740: [job("x", waited=6000)]}, pulls={1: OPEN_AT_HEAD},
                           remaining=rescue.BACKLOG_READS + rescue.POOL_RESERVE - 1)
        with tempfile.TemporaryDirectory() as tmp, mock.patch("builtins.print") as printed:
            summary = Path(tmp) / "summary.md"
            code = rescue.main(["--backlog"], {"GITHUB_STEP_SUMMARY": str(summary)}, client=fake, now=NOW)
            text = summary.read_text()
        self.assertEqual(code, 0)
        self.assertEqual(backlog_mutations(fake), [])
        self.assertEqual(fake.reads, 1)   # the rate limit, nothing else
        self.assertIn("skipped: the token has 649 core API calls left", text)
        self.assertFalse(any(rescue.JOURNAL_END in str(call) for call in printed.call_args_list))

    def test_an_unreadable_rate_limit_skips_the_pass(self):
        fake = BacklogFake([backlog_run(741, pr=1)], {741: [job("x", waited=6000)]}, pulls={1: OPEN_AT_HEAD})
        fake.rate_limit = mock.Mock(side_effect=RuntimeError("HTTP 500"))
        lines, _ = rescue.backlog_sweep(fake, now=NOW, dry_run=False, declared=())
        self.assertEqual(backlog_mutations(fake), [])
        self.assertIn("rate limit could not be read", lines[0])

    def test_the_journal_survives_a_skipped_pass(self):
        fake = BacklogFake([backlog_run(742, pr=1)], {742: [job("x", waited=6000)]}, pulls={1: OPEN_AT_HEAD},
                           settles=False)
        backlog(fake)
        fake.remaining_core = 10
        backlog(fake, now=NOW + dt.timedelta(minutes=10))   # skipped: its log has no journal
        fake.remaining_core = 12_500
        fake.settle()
        _, counts = backlog(fake, now=NOW + dt.timedelta(minutes=20))
        self.assertEqual(counts["recovered"], 1)

    def test_runs_the_first_backlog_passes_left_stranded_are_re_run(self):
        # cmux#45886's passes logged "...; cancelled, but the cancel did not settle in 120 s; re-run it by hand" and
        # never journalled. The first pass with a journal reads those logs back to the newest journal (none yet), or
        # every log back to --recover-since.
        for since in (None, NOW - dt.timedelta(hours=2)):
            with self.subTest(since=since):
                stranded = [{**backlog_run(600 + i, pr=1), "status": "completed", "conclusion": "cancelled"}
                            for i in range(3)]
                moved = {**backlog_run(603, pr=2), "status": "completed", "conclusion": "cancelled"}
                pulls = own_heads(stranded)
                pulls[2] = {"state": "closed", "head": {"sha": HEAD}}
                fake = BacklogFake(stranded + [moved], {}, pulls=pulls)
                for run_ in stranded[:2] + [moved]:
                    fake.record_pass([f"run {run_['id']} (web-validation.yml, pull_request, lane/x): 2 jobs queued on "
                                      "hosted Ubuntu, the oldest 300 min; cancelled, but the cancel did not settle in "
                                      "120 s; re-run it by hand", "20 candidate runs, 20 read, 20 stalled, 20 cancelled "
                                      "(0 superseded), 0 re-run"], minutes_ago=60)
                fake.record_pass(["run 602 (pr-checks.yml, pull_request, lane/y): x; cancelled, re-run refused (HTTP "
                                  "500); re-run it by hand"], minutes_ago=50)
                lines, counts = backlog(fake, since=since)
                self.assertEqual(sorted(c[1] for c in backlog_mutations(fake)), [600, 601, 602])
                self.assertEqual(counts["recovered"], 3)
                self.assertIn("3 earlier cancels re-run", lines[-2])

    def test_a_pass_stopped_before_its_journal_still_has_its_cancels_re_run(self):
        runs = [backlog_run(760, pr=1)]
        fake = BacklogFake(runs, {760: [job("x", waited=6000)]}, pulls=own_heads(runs), settles=False)
        fake.record_pass(rescue.journal_lines({}), minutes_ago=20)
        printed: list[str] = []
        rescue.backlog_sweep(fake, now=NOW, dry_run=False, declared=(), echo=printed.append)
        fake.record_pass([line for line in printed if "the next pass re-runs it" in line])   # killed before the end
        fake.settle()
        _, counts = backlog(fake, now=NOW + dt.timedelta(minutes=10))
        self.assertEqual(backlog_mutations(fake), [("cancel", 760), ("rerun", 760)])
        self.assertEqual(counts["recovered"], 1)

    def test_another_pull_requests_target_run_at_the_same_base_does_not_stand_in_for_the_re_run(self):
        # A pull_request_target run's head_sha is the base commit, shared by every pull request on that base.
        mine = {**backlog_run(770, event="pull_request_target", head="b" * 40, pr=1, pr_head=HEAD),
                "status": "completed", "conclusion": "cancelled"}
        theirs = {**backlog_run(771, event="pull_request_target", head="b" * 40, pr=2, pr_head="e" * 40),
                  "status": "completed", "conclusion": "success"}
        fake = BacklogFake([mine, theirs], {}, pulls={1: OPEN_AT_HEAD, 2: {"state": "open", "head": {"sha": "e" * 40}}})
        fake.record_pass(rescue.journal_lines({770: rescue.Journalled(NOW - dt.timedelta(minutes=20))}))
        backlog(fake)
        self.assertEqual(backlog_mutations(fake), [("rerun", 770)])

    def test_an_unread_newer_log_keeps_its_cancels_for_a_later_pass(self):
        # The newest pass's log fails to read twice: falling back to an older whole journal would drop that pass's
        # cancels. This pass holds current-head cancels and writes a partial journal; the next reads past it.
        runs = [{**backlog_run(780, pr=1), "status": "completed", "conclusion": "cancelled"}, backlog_run(781, pr=1)]
        pulls = own_heads(runs)
        fake = BacklogFake(runs, {781: [job("x", waited=6000)]}, pulls=pulls)
        fake.record_pass(rescue.journal_lines({}), minutes_ago=30)
        fake.record_pass(rescue.journal_lines({780: rescue.Journalled(NOW - dt.timedelta(minutes=15))}))
        newest_job = fake.passes[-1][0] + 1
        real_log, failures = fake.job_log, [0]

        def flaky(job_id):
            if job_id == newest_job and failures[0] < 2:
                failures[0] += 1
                raise RuntimeError("HTTP 502")
            return real_log(job_id)
        fake.job_log = flaky
        lines, counts = backlog(fake)
        self.assertEqual(backlog_mutations(fake), [])
        self.assertTrue(lines[-1].startswith(rescue.JOURNAL_PARTIAL))
        backlog(fake, now=NOW + dt.timedelta(minutes=10))
        self.assertEqual(backlog_mutations(fake), [("rerun", 780), ("cancel", 781)])

    def test_a_cancel_whose_answer_was_lost_is_journalled(self):
        runs = [backlog_run(790, pr=1)]
        fake = BacklogFake(runs, {790: [job("x", waited=6000)]}, pulls=own_heads(runs))
        real_cancel = fake.cancel

        def timed_out(run_id):
            real_cancel(run_id)
            raise RuntimeError("POST /actions/runs/790/cancel: timed out")
        fake.cancel = timed_out
        _, counts = backlog(fake)
        self.assertEqual((counts["journalled"], counts["pending"]), (1, 1))
        _, counts = backlog(fake, now=NOW + dt.timedelta(minutes=10))
        self.assertEqual(backlog_mutations(fake)[-1], ("rerun", 790))

    def test_dispatched_run_ids_are_the_only_runs_read_under_the_same_rules(self):
        # The cancel guard refuses an agent's cancel of an open pull request's head run and points at this dispatch.
        stalled, moved, fresh = backlog_run(44238822296, pr=1), backlog_run(44238822326, pr=2), backlog_run(3, pr=1)
        running = backlog_run(4, pr=1)
        push, nightly, rerun = (backlog_run(5, event="push"), backlog_run(6, workflow="nightly.yml", pr=1),
                                backlog_run(7, attempt=2, pr=1))
        runs = [stalled, moved, fresh, running, push, nightly, rerun]
        pulls = own_heads([stalled])
        pulls[2] = {"state": "open", "head": {"sha": "c" * 40}}
        jobs = {r["id"]: [job("x", waited=6 * 3600)] for r in runs}
        jobs[4] = [job("x", waited=6000), job("build", status="in_progress", runner_id=3)]
        fake = BacklogFake(runs + [backlog_run(8, pr=1)], {**jobs, 8: [job("x", waited=6000)]}, pulls=pulls)
        fake.record_pass(rescue.journal_lines({}))
        with tempfile.TemporaryDirectory() as tmp, mock.patch("builtins.print") as printed:
            code = rescue.main(["--backlog"], {"BACKLOG_RUN_IDS": "44238822296, 44238822326,4,5,6,7"}, client=fake,
                               now=NOW)
        text = "\n".join(str(call.args[0]) for call in printed.call_args_list if call.args)
        self.assertEqual(code, 0)
        self.assertEqual(backlog_mutations(fake), [("cancel", 44238822296), ("cancel", 44238822326)])
        self.assertEqual(fake.listings, [])   # the queue is not listed
        self.assertIn("hosted-backlog journal: run 44238822296 cancelled", text)
        self.assertNotIn("journal: run 44238822326", text)   # superseded: cancel only
        self.assertIn("run 5: a push run, not a pull request's; left alone", text)
        self.assertIn("run 6: workflow nightly.yml is never touched", text)
        self.assertIn("run 7: attempt 2, not 1", text)
        self.assertIn("left alone", text.split("run 4 ")[1])
        fake.record_pass(text.splitlines())
        _, counts = backlog(fake, now=NOW + dt.timedelta(minutes=10), actions=0)
        self.assertEqual(backlog_mutations(fake)[-1], ("rerun", 44238822296))

    def test_dispatched_run_ids_count_against_the_bound_and_the_budget_check(self):
        runs = [backlog_run(900 + i, pr=1) for i in range(200)]
        fake = BacklogFake(runs, {r["id"]: [job("x", waited=6000)] for r in runs}, pulls=own_heads(runs))
        fake.record_pass(rescue.journal_lines({}))
        before = fake.reads
        _, counts = rescue.backlog_sweep(fake, now=NOW, dry_run=False, declared=(), actions=rescue.BACKLOG_ACTIONS_MAX,
                                         run_ids=[r["id"] for r in runs])
        self.assertLessEqual(fake.reads - before, rescue.BACKLOG_READS)
        spent = BacklogFake(runs, {}, pulls={}, remaining=10)
        rescue.backlog_sweep(spent, now=NOW, dry_run=False, declared=(), run_ids=[900])
        self.assertEqual((spent.reads, backlog_mutations(spent)), (1, []))

    def test_a_journal_entry_someone_re_ran_or_superseded_is_dropped(self):
        rerun_meanwhile = {**backlog_run(750, pr=1), "run_attempt": 2, "status": "completed", "conclusion": "success"}
        moved = {**backlog_run(751, pr=2), "status": "completed", "conclusion": "cancelled"}
        newer_head = {**backlog_run(752, pr=1), "status": "completed", "conclusion": "cancelled"}
        newer = {**backlog_run(753, age_min=40, pr=1), "status": "completed", "conclusion": "success",
                 "head_branch": "lane/752"}
        fake = BacklogFake([rerun_meanwhile, moved, newer_head, newer], {},
                           pulls={1: OPEN_AT_HEAD, 2: {"state": "open", "head": {"sha": "e" * 40}}})
        fake.record_pass(rescue.journal_lines({i: rescue.Journalled(NOW - dt.timedelta(minutes=20))
                                               for i in (750, 751, 752)}))
        _, counts = backlog(fake)
        self.assertEqual(backlog_mutations(fake), [])
        self.assertEqual(counts["pending"], 0)

    def test_a_pull_request_target_run_is_covered(self):
        target = backlog_run(2, event="pull_request_target", head="b" * 40, pr=12, pr_head=HEAD)
        fake = BacklogFake([target], {2: [job("guard", waited=7200)]}, pulls={12: OPEN_AT_HEAD})
        two_passes(fake)
        self.assertEqual(backlog_mutations(fake), [("cancel", 2), ("rerun", 2)])

    def test_a_superseded_head_is_cancelled_but_not_re_run(self):
        moved = {"state": "open", "head": {"sha": "c" * 40}}
        fake = BacklogFake([backlog_run(3, pr=13)], {3: [job("check", waited=7200)]}, pulls={13: moved})
        first, second = two_passes(fake)
        self.assertEqual(backlog_mutations(fake), [("cancel", 3)])
        self.assertEqual((first["superseded"], first["pending"]), (1, 0))

    def test_a_closed_pull_request_found_by_branch_is_cancelled_but_not_re_run(self):
        fake = BacklogFake([backlog_run(4)], {4: [job("check", waited=7200)]},
                           branch_pulls={"lane/4": [{"state": "closed", "head": {"sha": HEAD}}]})
        two_passes(fake)
        self.assertEqual(backlog_mutations(fake), [("cancel", 4)])

    def test_a_run_whose_pull_request_cannot_be_told_is_left_alone(self):
        fake = BacklogFake([backlog_run(5)], {5: [job("check", waited=7200)]})
        lines, _ = backlog(fake)
        self.assertEqual(backlog_mutations(fake), [])
        self.assertTrue(any("could not be told" in line for line in lines))

    def test_a_job_queued_under_30_minutes_is_not_touched(self):
        fake = BacklogFake([backlog_run(6, pr=16)], {6: [job("check", waited=29 * 60)]}, pulls={16: OPEN_AT_HEAD})
        backlog(fake)
        self.assertEqual(backlog_mutations(fake), [])

    def test_a_run_with_a_job_running_or_on_another_label_is_left_alone(self):
        running = [job("check", waited=7200), job("build", status="in_progress", runner_id=3)]
        blacksmith = [job("check", waited=7200), job("build", labels=("blacksmith-4vcpu-ubuntu-2404",), waited=7200)]
        fake = BacklogFake([backlog_run(7, pr=17), backlog_run(8, pr=18)], {7: running, 8: blacksmith},
                           pulls={17: OPEN_AT_HEAD, 18: OPEN_AT_HEAD})
        backlog(fake)
        self.assertEqual(backlog_mutations(fake), [])

    def test_push_schedule_dispatch_nightly_later_attempts_and_forks_are_never_touched(self):
        runs = [backlog_run(20, event="push"), backlog_run(21, event="schedule"),
                backlog_run(22, event="workflow_dispatch"), backlog_run(23, workflow="nightly.yml", pr=1),
                backlog_run(24, attempt=2, pr=1), backlog_run(25, repo="someone/cmux", pr=1)]
        fake = BacklogFake(runs, {r["id"]: [job("x", waited=7200)] for r in runs}, pulls={1: OPEN_AT_HEAD})
        _, counts = backlog(fake)
        self.assertEqual(backlog_mutations(fake), [])
        self.assertEqual(counts["candidates"], 0)
        self.assertTrue(all("event=pull_request" in path for path in fake.listings))

    def test_the_minute_pass_keeps_its_declared_runs_under_90_minutes(self):
        runs = [backlog_run(30, age_min=60, workflow="pr-checks.yml", pr=1),
                backlog_run(31, age_min=60, workflow="web-validation.yml", pr=1),
                backlog_run(32, age_min=120, workflow="pr-checks.yml", pr=1)]
        fake = BacklogFake(runs, {r["id"]: [job("x", waited=50 * 60)] for r in runs}, pulls={1: OPEN_AT_HEAD})
        backlog(fake)
        self.assertEqual(sorted(c[1] for c in backlog_mutations(fake) if c[0] == "cancel"), [31, 32])
        unread = BacklogFake([dict(r) for r in runs], {r["id"]: [job("x", waited=50 * 60)] for r in runs},
                             pulls={1: OPEN_AT_HEAD})
        backlog(unread, declared=None)
        self.assertEqual([c[1] for c in backlog_mutations(unread) if c[0] == "cancel"], [32])

    def test_runs_older_than_a_day_are_not_listed(self):
        fake = BacklogFake([backlog_run(40, age_min=25 * 60, pr=1)], {40: [job("x", waited=7200)]},
                           pulls={1: OPEN_AT_HEAD})
        _, counts = backlog(fake)
        self.assertEqual(counts["candidates"], 0)

    def test_a_job_that_started_after_the_read_is_not_cancelled(self):
        fake = BacklogFake([backlog_run(41, pr=1)], {41: [job("x", waited=7200)]}, pulls={1: OPEN_AT_HEAD})
        fake.started_meanwhile.add(41)
        backlog(fake)
        self.assertEqual(backlog_mutations(fake), [])

    def test_a_dry_run_mutates_nothing(self):
        fake = BacklogFake([backlog_run(42, pr=1)], {42: [job("x", waited=7200)]}, pulls={1: OPEN_AT_HEAD})
        lines, _ = backlog(fake, dry_run=True)
        self.assertEqual(backlog_mutations(fake), [])
        self.assertTrue(any("would cancel, and re-run next pass" in line for line in lines))

    def test_recovery_in_a_dry_run_mutates_nothing_and_keeps_the_journal(self):
        settled = {**backlog_run(67, pr=1), "status": "completed", "conclusion": "cancelled"}
        fake = BacklogFake([settled], {}, pulls={1: OPEN_AT_HEAD})
        fake.record_pass(rescue.journal_lines({67: rescue.Journalled(NOW - dt.timedelta(minutes=20))}))
        lines, counts = backlog(fake, dry_run=True)
        self.assertEqual(backlog_mutations(fake), [])
        self.assertTrue(any("would re-run (dry run)" in line for line in lines))
        self.assertEqual(counts["pending"], 1)

    def test_cancels_are_bounded_oldest_queued_first(self):
        runs = [backlog_run(100 + i, age_min=100 + i, pr=1) for i in range(30)]
        runs.append(backlog_run(99, age_min=500, status="in_progress", pr=1))
        fake = BacklogFake(runs, {r["id"]: [job("x", waited=6000)] for r in runs}, pulls={1: OPEN_AT_HEAD})
        backlog(fake, actions=5)
        cancelled = [c[1] for c in backlog_mutations(fake) if c[0] == "cancel"]
        self.assertEqual(cancelled, [129, 128, 127, 126, 125])

    def test_superseded_cancels_count_against_the_bound(self):
        moved = {"state": "open", "head": {"sha": "c" * 40}}
        runs = [backlog_run(200 + i, age_min=100 + i, pr=1) for i in range(10)]
        fake = BacklogFake(runs, {r["id"]: [job("x", waited=6000)] for r in runs}, pulls={1: moved})
        _, counts = backlog(fake, actions=3)
        self.assertEqual((counts["cancelled"], counts["superseded"]), (3, 3))

    def test_old_runs_that_started_a_job_spend_a_bounded_share_of_reads(self):
        runs = [backlog_run(300 + i, age_min=100 + i, status="in_progress", pr=1) for i in range(50)]
        busy = [job("build", status="in_progress", runner_id=9)]
        fake = BacklogFake(runs, {r["id"]: busy for r in runs}, pulls={1: OPEN_AT_HEAD})
        _, counts = backlog(fake)
        self.assertEqual(counts["read"], rescue.BACKLOG_IN_PROGRESS_READS)
        self.assertEqual(backlog_mutations(fake), [])

    def test_a_deep_queue_is_walked_from_its_oldest_slice(self):
        runs = [backlog_run(1000 + i, age_min=40 + i * 1.2, pr=1) for i in range(1100)]
        fake = BacklogFake(runs, {r["id"]: [job("x", waited=40 * 60)] for r in runs}, pulls={1: OPEN_AT_HEAD})
        _, counts = backlog(fake, actions=3)
        cancelled = [c[1] for c in backlog_mutations(fake) if c[0] == "cancel"]
        self.assertEqual(cancelled, [2099, 2098, 2097])
        self.assertLessEqual(counts["requests"], rescue.BACKLOG_READS)

    def test_a_pending_run_whose_job_waits_on_hosted_ubuntu_is_cancelled_and_re_run(self):
        # 2026-11-19: cmux#47559's required React Doctor run 44604684959 sat `pending` (held behind its concurrency
        # group) with its one job queued on ubuntu-24.04 for 8 h. The pass listed queued and in_progress runs only.
        fake = BacklogFake([backlog_run(44604684959, status="pending", pr=47559,
                                        workflow="cmux-next-react-doctor.yml")],
                           {44604684959: [job("React Doctor (changed React projects)", waited=8 * 3600)]},
                           pulls={47559: OPEN_AT_HEAD})
        first, second = two_passes(fake)
        self.assertEqual(backlog_mutations(fake), [("cancel", 44604684959), ("rerun", 44604684959)])
        self.assertEqual((first["cancelled"], second["recovered"]), (1, 1))

    def test_a_run_waiting_on_an_environment_is_never_listed(self):
        fake = BacklogFake([backlog_run(61, status="waiting", pr=1)], {61: [job("x", waited=7200)]},
                           pulls={1: OPEN_AT_HEAD})
        backlog(fake)
        self.assertEqual(backlog_mutations(fake), [])
        self.assertNotIn(("jobs", 61), fake.calls)

    def test_a_stalled_run_behind_many_old_runs_on_blacksmith_is_reached_within_a_few_passes(self):
        # 2026-11-20: 489 candidates a pass, the same 116 oldest read every time (all queued on Blacksmith, none
        # stalled), so the hosted-bound runs created after them were never read.
        old = [backlog_run(5000 + i, age_min=600 + i, pr=1) for i in range(400)]
        stuck = backlog_run(9000, age_min=300, pr=2)
        fake = BacklogFake(old + [stuck],
                           {**{r["id"]: [job("x", labels=("blacksmith-4vcpu-ubuntu-2404",), waited=36000)]
                               for r in old}, 9000: [job("x", waited=300 * 60)]},
                           pulls={1: OPEN_AT_HEAD, 2: OPEN_AT_HEAD})
        passes = 0
        for passes in range(1, 9):
            _, counts = backlog(fake, now=NOW + dt.timedelta(minutes=10 * (passes - 1)))
            self.assertLessEqual(counts["requests"], rescue.BACKLOG_READS)
            if ("cancel", 9000) in backlog_mutations(fake):
                break
        self.assertIn(("cancel", 9000), backlog_mutations(fake))
        self.assertLessEqual(passes, 8)

    def test_the_rotation_keeps_the_oldest_waiting_runs_first(self):
        waiting = [{"id": i} for i in range(rescue.BACKLOG_OLDEST_FIRST + 100)]
        for minutes in (0, 10, 20, 30):
            rotated = rescue.backlog_rotate(waiting, NOW + dt.timedelta(minutes=minutes))
            self.assertEqual(rotated[:rescue.BACKLOG_OLDEST_FIRST], waiting[:rescue.BACKLOG_OLDEST_FIRST])
            self.assertEqual(sorted(r["id"] for r in rotated), list(range(len(waiting))))
        self.assertEqual(rescue.backlog_rotate(waiting[:5], NOW), waiting[:5])

    def test_main_reads_tokens_and_the_action_bound_from_the_environment(self):
        fake = BacklogFake([backlog_run(50, pr=1), backlog_run(51, age_min=210, pr=1)],
                           {50: [job("x", waited=7200)], 51: [job("x", waited=7200)]}, pulls={1: OPEN_AT_HEAD})
        fake.record_pass(rescue.journal_lines({}))
        with tempfile.TemporaryDirectory() as tmp, mock.patch("sys.stdout"):
            summary = Path(tmp) / "summary.md"
            rescue.main(["--backlog"], {"BACKLOG_ACTIONS": "1", "GITHUB_STEP_SUMMARY": str(summary)},
                        client=fake, now=NOW, sleep=lambda _s: None)
            self.assertIn("Hosted backlog rescue", summary.read_text())
        self.assertEqual(backlog_mutations(fake), [("cancel", 51)])

    def test_main_reads_the_recovery_start_from_the_environment(self):
        with mock.patch.object(rescue, "backlog_sweep", return_value=([], {})) as swept, mock.patch("sys.stdout"):
            rescue.main(["--backlog"], {"BACKLOG_RECOVER_SINCE": "2026-11-18T08:50:00Z"}, client=object(), now=NOW)
        self.assertEqual(swept.call_args.kwargs["since"], dt.datetime(2026, 11, 18, 8, 50, tzinfo=dt.timezone.utc))

    def test_the_bot_token_reads_and_writes_and_the_workflow_token_only_reads(self):
        client = None
        with mock.patch.object(rescue, "backlog_sweep", return_value=([], {})) as swept, mock.patch("sys.stdout"):
            rescue.main(["--backlog"], {"HOSTED_LIGHT_TOKEN": "bot", "GH_TOKEN": "workflow", "GH_REPO": "o/r"},
                        now=NOW)
            client = swept.call_args.args[0]
        self.assertEqual((client.token, client.write_token, client.fallback), ("bot", "bot", "workflow"))

    def test_the_workflow_is_scheduled_dispatchable_and_bounded(self):
        import yaml
        path = ROOT / ".github/workflows/ci-hosted-backlog-rescue.yml"
        workflow = yaml.safe_load(path.read_text())
        events = workflow.get("on", workflow.get(True))
        self.assertIn("schedule", events)
        self.assertEqual(set(events["workflow_dispatch"]["inputs"]), {"dry_run", "actions", "recover_since", "run_ids"})
        self.assertFalse(workflow["concurrency"]["cancel-in-progress"])
        job_ = workflow["jobs"]["backlog"]
        self.assertIn("CI_HOSTED_LIGHT_RESCUE_DISABLED", job_["if"])
        self.assertEqual(job_["permissions"], {"actions": "write", "contents": "read", "pull-requests": "read"})
        self.assertNotIn("ubuntu-24.04\",", job_["runs-on"])  # never queues behind the hosted backlog it drains
        [checkout] = [s for s in job_["steps"] if s.get("with", {}).get("ref") == "refs/heads/main"]
        self.assertFalse(checkout["with"]["persist-credentials"])
        [step] = [s for s in job_["steps"] if "hosted_light_rescue.py" in str(s.get("run", ""))]
        self.assertIn("--backlog", step["run"])
        self.assertEqual(step["env"]["GH_TOKEN"], "${{ github.token }}")
        self.assertIn("inputs.recover_since", step["env"]["BACKLOG_RECOVER_SINCE"])
        self.assertIn("inputs.run_ids", step["env"]["BACKLOG_RUN_IDS"])
        self.assertIn(rescue.BACKLOG_WORKFLOW, str(path))


PR_CONTROL_JIT = "cmux-gcp-pr-control-jit-x64"
GATE_JIT = "cmux-gcp-gate-jit-x64"


class BacklogMovedJit(unittest.TestCase):
    """--backlog also moves jobs left queued on a one-job JIT label after their route moved off it (cmux#49216)."""

    def test_a_cmux_next_run_at_its_head_on_the_pr_control_label_is_cancelled_then_re_run(self):
        # cmux-next.yml names the label on attempt 1 only, so the re-run (attempt 2) takes RUNNER_POOLS instead.
        fake = BacklogFake([backlog_run(1, pr=11, workflow="cmux-next.yml")],
                           {1: [job("cmux-next push head preflight", labels=(PR_CONTROL_JIT,), waited=3 * 3600)]},
                           pulls={11: OPEN_AT_HEAD})
        first, second = two_passes(fake, declared=())
        self.assertEqual(backlog_mutations(fake), [("cancel", 1), ("rerun", 1)])
        self.assertEqual((first["cancelled"], first["journalled"], second["recovered"]), (1, 1, 1))

    def test_a_superseded_run_on_either_label_is_only_cancelled_whatever_its_workflow(self):
        runs = [backlog_run(2, pr=12, workflow="pr-status.yml"), backlog_run(3, pr=13, workflow="backend-migrations.yml")]
        moved = {"state": "open", "head": {"sha": "b" * 40}}
        fake = BacklogFake(runs, {2: [job("status", labels=(PR_CONTROL_JIT,), waited=6000)],
                                  3: [job("migrate", labels=(GATE_JIT,), waited=6000)]}, pulls={12: moved, 13: moved})
        first, second = two_passes(fake, declared=())
        self.assertEqual(sorted(backlog_mutations(fake)), [("cancel", 2), ("cancel", 3)])
        self.assertEqual((first["cancelled"], first["superseded"], second["recovered"]), (2, 2, 0))

    def test_a_run_at_its_head_whose_re_run_takes_the_same_label_stays_queued(self):
        # pr-status.yml and backend-migrations.yml name their JIT label on every attempt: a re-run only loses its place.
        runs = [backlog_run(4, pr=14, workflow="pr-status.yml"), backlog_run(5, pr=15, workflow="backend-migrations.yml"),
                backlog_run(6, pr=16, workflow="cmux-next.yml")]
        fake = BacklogFake(runs, {4: [job("status", labels=(PR_CONTROL_JIT,), waited=6000)],
                                  5: [job("migrate", labels=(GATE_JIT,), waited=6000)],
                                  6: [job("compile", labels=(GATE_JIT,), waited=6000)]},
                           pulls={14: OPEN_AT_HEAD, 15: OPEN_AT_HEAD, 16: OPEN_AT_HEAD})
        lines, counts = backlog(fake, declared=())
        self.assertEqual(backlog_mutations(fake), [])
        self.assertEqual((counts["stalled"], counts["stays"], counts["cancelled"]), (3, 3, 0))
        self.assertTrue(any("run 4 " in line and f"would queue on {PR_CONTROL_JIT} again" in line for line in lines))

    def test_a_jit_job_beside_another_label_or_under_thirty_minutes_is_not_stalled(self):
        self.assertFalse(rescue.backlog_stalled(job("x", labels=(PR_CONTROL_JIT, "cmux-has-docker"), waited=6000), NOW))
        self.assertFalse(rescue.backlog_stalled(job("x", labels=(PR_CONTROL_JIT,), waited=600), NOW))
        self.assertFalse(rescue.backlog_stalled(job("x", labels=("cmux-gcp-nightly-jit-x64",), waited=6000), NOW))
        self.assertTrue(rescue.backlog_stalled(job("x", labels=(GATE_JIT,), waited=6000), NOW))

    def test_push_and_nightly_runs_on_the_label_are_never_touched(self):
        runs = [backlog_run(7, event="push", pr=17, workflow="cmux-next.yml"),
                backlog_run(8, pr=18, workflow="nightly.yml")]
        fake = BacklogFake(runs, {r["id"]: [job("x", labels=(PR_CONTROL_JIT,), waited=6000)] for r in runs},
                           pulls={17: OPEN_AT_HEAD, 18: {"state": "open", "head": {"sha": "b" * 40}}})
        _, counts = backlog(fake, declared=())
        self.assertEqual((backlog_mutations(fake), counts["read"]), ([], 0))


if __name__ == "__main__":
    unittest.main()


# A feat-cmux-next-style workflow: two jobs re-read LINUX_RUNNER on a re-run, one is pinned to Blacksmith.
ROUTED_WORKFLOW = """name: lane checks
on:
  pull_request:
jobs:
  build:
    name: build (${{ matrix.part }})
    runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name != github.repository && 'blacksmith-4vcpu-ubuntu-2404' || vars.LINUX_RUNNER || 'blacksmith-4vcpu-ubuntu-2404' }}
    steps:
      - run: true
  lint:
    runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || !startsWith(vars.LINUX_RUNNER, 'blacksmith-') && vars.LINUX_RUNNER || 'blacksmith-16vcpu-ubuntu-2404' }} # owned first
    steps:
      - run: true
  pinned:
    name: "pinned guard"
    runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || vars.CI_CLOUD_OVERFLOW_SAVED && 'blacksmith-16vcpu-ubuntu-2404' || 'blacksmith-4vcpu-ubuntu-2404' }}
    steps:
      - run: true
  main-style:
    runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || contains(fromJSON('["blacksmith-4vcpu-ubuntu-2404"]'), vars.LINUX_RUNNER) && vars.LINUX_RUNNER || 'blacksmith-4vcpu-ubuntu-2404' }}
    steps:
      - run: true
"""


class BacklogBlacksmith(unittest.TestCase):
    """--backlog also moves a job queued on Blacksmith Ubuntu, but only when its re-run takes the owned LINUX_RUNNER."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dir = Path(self.tmp.name)
        (self.dir / "lane-checks.yml").write_text(ROUTED_WORKFLOW, encoding="utf-8")

    def routes(self, linux_runner="cmux-linux"):
        return rescue.RerunRoutes({"feat-cmux-next": self.dir}, linux_runner)

    def based(self, run_id, *, base="feat-cmux-next", pr=None):
        found = backlog_run(run_id, workflow="lane-checks.yml", pr=pr or run_id + 10)
        for pull in found["pull_requests"]:
            pull["base"] = {"ref": base}
        return found

    def blacksmith(self, name, label="blacksmith-4vcpu-ubuntu-2404", waited=3 * 3600):
        return job(name, labels=(label,), waited=waited)

    def test_the_label_pattern_takes_every_blacksmith_ubuntu_form_the_workflows_use(self):
        for label in ("blacksmith-2vcpu-ubuntu-2404", "blacksmith-4vcpu-ubuntu-2404", "blacksmith-16vcpu-ubuntu-2404",
                      "blacksmith-32vcpu-ubuntu-2404", "blacksmith-4vcpu-ubuntu-2404-arm"):
            self.assertTrue(rescue.BLACKSMITH_LINUX_LABEL.match(label), label)
        for label in ("blacksmith-6vcpu-macos-26", "blacksmith-4vcpu-windows-2025", "ubuntu-24.04", "cmux-linux"):
            self.assertFalse(rescue.BLACKSMITH_LINUX_LABEL.match(label), label)

    def test_a_blacksmith_job_whose_re_run_takes_the_owned_route_is_cancelled_and_re_run(self):
        fake = BacklogFake([self.based(1)], {1: [self.blacksmith("build (a)"),
                                                 self.blacksmith("lint", "blacksmith-16vcpu-ubuntu-2404")]},
                           pulls={11: OPEN_AT_HEAD})
        lines, counts = backlog(fake, routes=self.routes())
        self.assertEqual(backlog_mutations(fake), [("cancel", 1)])
        self.assertTrue(any("2 on Blacksmith Ubuntu, re-run on cmux-linux" in line for line in lines), lines)
        backlog(fake, now=NOW + dt.timedelta(minutes=10), routes=self.routes())
        self.assertEqual(backlog_mutations(fake), [("cancel", 1), ("rerun", 1)])

    def test_mixed_hosted_and_movable_blacksmith_jobs_move_together(self):
        fake = BacklogFake([self.based(1)], {1: [job("report", waited=3 * 3600), self.blacksmith("build (a)")]},
                           pulls={11: OPEN_AT_HEAD})
        backlog(fake, routes=self.routes())
        self.assertEqual(backlog_mutations(fake), [("cancel", 1)])

    def test_a_job_pinned_to_blacksmith_holds_its_run_as_today(self):
        # Its re-run would take a Blacksmith label again (the queue's tail), so the run, hosted job and all, stays.
        for jobs in ([self.blacksmith("pinned guard")], [job("report", waited=3 * 3600), self.blacksmith("pinned guard")],
                     [self.blacksmith("main-style")], [self.blacksmith("build (a)"), self.blacksmith("pinned guard")]):
            fake = BacklogFake([self.based(1)], {1: jobs}, pulls={11: OPEN_AT_HEAD})
            backlog(fake, routes=self.routes())
            self.assertEqual(backlog_mutations(fake), [], jobs)

    def test_no_owned_linux_route_means_no_blacksmith_move(self):
        # vars.LINUX_RUNNER unset, Blacksmith or hosted: the re-run would not land on an owned label.
        for linux_runner in (None, "", "blacksmith-8vcpu-ubuntu-2404", "ubuntu-24.04"):
            fake = BacklogFake([self.based(1)], {1: [self.blacksmith("build (a)")]}, pulls={11: OPEN_AT_HEAD})
            backlog(fake, routes=self.routes(linux_runner))
            self.assertEqual(backlog_mutations(fake), [], linux_runner)

    def test_an_unknown_base_job_or_workflow_is_left_alone(self):
        cases = [(self.based(1, base="lane/stack"), [self.blacksmith("build (a)")]),
                 (self.based(1), [self.blacksmith("not in the workflow")]),
                 (backlog_run(1, workflow="lane-checks.yml", pr=11), [self.blacksmith("build (a)")])]
        for run_, jobs in cases:
            fake = BacklogFake([run_], {1: jobs}, pulls={11: OPEN_AT_HEAD})
            backlog(fake, routes=self.routes())
            self.assertEqual(backlog_mutations(fake), [], (run_, jobs))

    def test_without_routes_blacksmith_jobs_stay_as_before(self):
        fake = BacklogFake([self.based(1)], {1: [self.blacksmith("build (a)")]}, pulls={11: OPEN_AT_HEAD})
        backlog(fake)
        self.assertEqual(backlog_mutations(fake), [])

    def test_a_fresh_or_assigned_blacksmith_job_is_not_touched(self):
        for jobs in ([self.blacksmith("build (a)", waited=29 * 60)],
                     [job("build (a)", labels=("blacksmith-4vcpu-ubuntu-2404",), runner_id=9, waited=3 * 3600)]):
            fake = BacklogFake([self.based(1)], {1: jobs}, pulls={11: OPEN_AT_HEAD})
            backlog(fake, routes=self.routes())
            self.assertEqual(backlog_mutations(fake), [])

    def test_the_minute_pass_still_never_moves_a_blacksmith_job(self):
        self.assertFalse(rescue.stalled(self.blacksmith("build (a)"), NOW))

    def test_the_rerun_route_is_read_from_the_job_runs_on(self):
        self.assertTrue(rescue.rerun_reads_linux_runner(
            "${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || vars.LINUX_RUNNER || 'blacksmith-4vcpu-ubuntu-2404' }}"))
        self.assertFalse(rescue.rerun_reads_linux_runner("blacksmith-4vcpu-ubuntu-2404"))
        self.assertFalse(rescue.rerun_reads_linux_runner(
            "${{ github.run_attempt == 1 && 'blacksmith-4vcpu-ubuntu-2404' || vars.LINUX_RUNNER || 'x' }}"))

    def test_the_workflow_passes_the_route_and_both_bases(self):
        text = (ROOT / ".github" / "workflows" / "ci-hosted-backlog-rescue.yml").read_text(encoding="utf-8")
        self.assertIn("BACKLOG_LINUX_RUNNER: ${{ vars.LINUX_RUNNER }}", text)
        self.assertIn("--route-workflows main=.github/workflows", text)
        self.assertIn("--route-workflows feat-cmux-next=.rescue-workflows/.github/workflows", text)

    def test_main_reads_the_route_workflows_and_the_variable(self):
        seen = {}

        def fake_sweep(client, **kwargs):
            seen.update(kwargs)
            return [], {}
        with mock.patch.object(rescue, "backlog_sweep", fake_sweep):
            rescue.main(["--backlog", "--route-workflows", f"feat-cmux-next={self.dir}"],
                        {"BACKLOG_LINUX_RUNNER": "cmux-linux", "GH_REPO": "manaflow-ai/cmux"}, client=object(), now=NOW)
        self.assertEqual(seen["routes"].workflows, {"feat-cmux-next": self.dir})
        self.assertEqual(seen["routes"].linux_runner, "cmux-linux")
