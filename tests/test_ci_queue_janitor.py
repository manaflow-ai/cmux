#!/usr/bin/env python3
"""Policy tests for scripts/ci/queue_janitor.py over fixture JSON (no network)."""

from __future__ import annotations

import datetime as dt
import email.message
import http.client
import importlib.util
import io
import json
import re
import sys
import tempfile
import unittest
import urllib.error
import urllib.parse
import zipfile
from pathlib import Path
from unittest import mock

import yaml


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/queue_janitor.py"
WORKFLOW = ROOT / ".github/workflows/ci-queue-janitor.yml"
SPEC = importlib.util.spec_from_file_location("queue_janitor", SCRIPT)
janitor = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules["queue_janitor"] = janitor
SPEC.loader.exec_module(janitor)

NOW = dt.datetime(2026, 9, 22, 17, 0, tzinfo=dt.timezone.utc)
MAC = "blacksmith-6vcpu-macos-15"
LINUX = "blacksmith-4vcpu-ubuntu-2404"
_ids = iter(range(1000, 100000))


def iso(minutes_ago: float) -> str:
    return (NOW - dt.timedelta(minutes=minutes_ago)).strftime("%Y-%m-%dT%H:%M:%SZ")


def make_run(*, event="pull_request", branch="feature", path=".github/workflows/ci.yml", name="CI",
             status="in_progress", sha="aaa", age=30, owner="manaflow-ai", prs=(), attempt=1):
    run_id = next(_ids)
    return {
        "id": run_id, "event": event, "head_branch": branch, "path": path, "name": name,
        "status": status, "head_sha": sha, "created_at": iso(age), "run_attempt": attempt,
        "html_url": f"https://github.com/manaflow-ai/cmux/actions/runs/{run_id}",
        "head_repository": {"full_name": f"{owner}/cmux", "owner": {"login": owner}},
        "pull_requests": [{"number": n} for n in prs],
    }


def mac_jobs(queued=0, running=0, age=20, running_name="macos / app-host shard", label=MAC):
    jobs = [{"status": "queued", "name": "macos / shard", "labels": [label], "created_at": iso(age)}
            for _ in range(queued)]
    jobs += [{"status": "in_progress", "name": running_name, "labels": [label], "created_at": iso(age)}
             for _ in range(running)]
    jobs.append({"status": "completed", "name": "changes", "labels": [LINUX], "created_at": iso(age)})
    return jobs


def doomed_jobs(*, queued=2, running=1, conclusion="failure", failed_age=30, name=None,
                completed_at=True):
    """macOS jobs for a run whose app-host shard has already concluded."""
    jobs = mac_jobs(queued=queued, running=running, running_name="macos / app-host unit tests (4/6)")
    jobs.append({
        "status": "completed", "labels": [MAC], "created_at": iso(60),
        "name": name or "macos / app-host unit tests (3/6)",
        "conclusion": conclusion,
        "completed_at": iso(failed_age) if completed_at else None,
    })
    return jobs


def make_pr(number=1, *, state="OPEN", draft=False, head="aaa", labels=(), owner="manaflow-ai", timeline=(),
            files=("web/app/page.tsx",), files_truncated=False, labels_truncated=False):
    return {
        "number": number, "state": state, "isDraft": draft, "headRefOid": head,
        "headRepositoryOwner": {"login": owner},
        "files": None if files is None else {
            "pageInfo": {"hasNextPage": files_truncated},
            "nodes": [{"path": path} for path in files],
        },
        "labels": {"pageInfo": {"hasNextPage": labels_truncated}, "nodes": [{"name": name} for name in labels]},
        "timelineItems": {"nodes": [
            {"__typename": kind, "createdAt": iso(age), "label": {"name": label}}
            for kind, label, age in timeline
        ]},
    }


def plan(runs, jobs, prs=None, *, threshold=6, max_cancels=10, policy="compile-only"):
    return janitor.build_plan(
        runs, jobs, prs or {}, threshold=threshold, max_cancels=max_cancels, pull_request_policy=policy,
        now=NOW,
    )


def busy_main_push(queued=7):
    """A protected run that fills the queue so the threshold is exceeded."""
    run = make_run(event="push", branch="main", name="CI")
    return run, mac_jobs(queued=queued)


class ProtectionTests(unittest.TestCase):
    def test_never_touched_runs(self):
        cases = [
            make_run(event="merge_group", branch="gh-readonly-queue/main/pr-1-abc"),
            make_run(event="push", branch="main"),
            make_run(event="push", branch="rc/0.64"),
            make_run(event="schedule", branch="main", name="Nightly macOS build", path=".github/workflows/nightly.yml"),
            make_run(event="workflow_dispatch", branch="main"),
            make_run(event="schedule", branch="main", name="Some check"),
            make_run(event="push", branch="v0.64.0", name="Release", path=".github/workflows/release.yml"),
            make_run(event="push", branch="cmux-tui-v0.13.1", name="cmux-tui publish pypi"),
            make_run(event="release", branch="v0.64.0"),
            make_run(event="pull_request", name="iOS TestFlight (cmux.app)", path=".github/workflows/ios-testflight.yml"),
            make_run(event="pull_request", name="iOS App Store", path=".github/workflows/ios-app-store.yml"),
            make_run(event="push", branch="exp/nightly-probe", name="Nightly macOS build", path=".github/workflows/nightly.yml"),
        ]
        for run in cases:
            with self.subTest(event=run["event"], branch=run["head_branch"], name=run["name"]):
                self.assertIsNotNone(janitor.protected_reason(run))
                pr = make_pr(state="CLOSED", draft=True, head="zzz")
                self.assertIsNone(janitor.classify(
                    run, janitor.macos_usage(mac_jobs(queued=3)), pr,
                    newer_ci_run_waiting=True, pull_request_policy="compile-only", now=NOW,
                ))

    def test_protected_runs_count_toward_the_queue_but_are_never_planned(self):
        main_run, main_jobs = busy_main_push(queued=20)
        merge = make_run(event="merge_group", branch="gh-readonly-queue/main/pr-9-abc")
        result = plan([main_run, merge], {main_run["id"]: main_jobs, merge["id"]: mac_jobs(queued=5)})
        self.assertEqual(result.queued_macos_jobs, 25)
        self.assertEqual(result.decisions, [])

    def test_ordinary_pr_and_exp_push_are_not_protected(self):
        self.assertIsNone(janitor.protected_reason(make_run()))
        self.assertIsNone(janitor.protected_reason(make_run(
            event="push", branch="exp/incremental-generation-canary-v2",
            name="Xcode incremental generation canary", path=".github/workflows/incremental-state-canary.yml")))


class CategoryTests(unittest.TestCase):
    def classify(self, run, pr=None, *, jobs=None, newer=False, policy="compile-only"):
        usage = janitor.macos_usage(jobs if jobs is not None else mac_jobs(queued=2))
        return janitor.classify(run, usage, pr, newer_ci_run_waiting=newer, pull_request_policy=policy, now=NOW)

    def test_experiment_push(self):
        run = make_run(event="push", branch="exp/incremental-foo", name="Xcode incremental generation canary")
        self.assertEqual(self.classify(run)[0], "experiment")
        self.assertIsNone(self.classify(make_run(event="push", branch="feature/foo")))

    def test_closed_merged_and_superseded_prs(self):
        run = make_run(sha="aaa")
        self.assertEqual(self.classify(run, make_pr(state="MERGED"))[0], "stale-pr")
        self.assertEqual(self.classify(run, make_pr(state="CLOSED"))[0], "stale-pr")
        verdict = self.classify(run, make_pr(head="bbb"))
        self.assertEqual(verdict[0], "stale-pr")
        self.assertIn("superseded", verdict[1])

    def test_current_open_pr_is_kept(self):
        self.assertIsNone(self.classify(make_run(), make_pr()))

    def test_unresolved_pr_is_kept(self):
        self.assertIsNone(self.classify(make_run(), None))

    def test_run_without_macos_jobs_is_never_a_candidate(self):
        run = make_run(event="push", branch="exp/x")
        self.assertIsNone(self.classify(run, jobs=[{"status": "queued", "labels": [LINUX], "name": "lint"}]))

    def test_current_draft_pr_is_kept(self):
        # Drafts can be active integration branches; being a draft is not waste.
        self.assertIsNone(self.classify(make_run(), make_pr(draft=True)))

    def dropped_label_pr(self, **overrides):
        # full-ci added 60m ago (before the run), removed 5m ago.
        values = dict(timeline=[("LabeledEvent", "full-ci", 60), ("UnlabeledEvent", "full-ci", 5)])
        values.update(overrides)
        return make_pr(**values)

    def test_label_dropped_full_suite(self):
        run = make_run(age=30)
        self.assertEqual(self.classify(run, self.dropped_label_pr(), newer=True)[0], "label-dropped")

    def test_label_dropped_needs_a_waiting_replacement(self):
        self.assertIsNone(self.classify(make_run(age=30), self.dropped_label_pr(), newer=False))

    def test_label_dropped_keeps_a_compile_in_flight(self):
        # ci.yml keeps this compile alive so the queued run can reuse its product.
        jobs = mac_jobs(queued=0, running=1, running_name="macos / macOS compile admission")
        self.assertIsNone(self.classify(make_run(age=30), self.dropped_label_pr(), jobs=jobs, newer=True))

    def test_label_dropped_only_under_compile_only_policy(self):
        self.assertIsNone(self.classify(make_run(age=30), self.dropped_label_pr(), newer=True, policy=""))

    def test_label_still_present_or_never_present(self):
        run = make_run(age=30)
        present = make_pr(labels=["full-ci"], timeline=[("LabeledEvent", "full-ci", 60)])
        self.assertIsNone(self.classify(run, present, newer=True))
        never = make_pr()
        self.assertIsNone(self.classify(run, never, newer=True))

    def test_run_created_after_label_removal_was_compile_only(self):
        # The run started after the unlabel: it never had the full suite.
        run = make_run(age=2)
        self.assertIsNone(self.classify(run, self.dropped_label_pr(), newer=True))

    def test_label_dropped_only_for_ci_workflow(self):
        run = make_run(age=30, path=".github/workflows/terminal-hang-diagnostics.yml", name="Terminal hang")
        self.assertIsNone(self.classify(run, self.dropped_label_pr(), newer=True))

    def test_stale_draft_is_still_stale(self):
        verdict = self.classify(make_run(), make_pr(draft=True, state="CLOSED"))
        self.assertEqual(verdict[0], "stale-pr")


class DoomedCategoryTests(unittest.TestCase):
    """An `app-host unit tests` shard failure decides ci-status by construction.

    ci-status accepts only `success` or `skipped` from the `macos`
    reusable-workflow call, so one failed shard fails the required check and no
    later job takes it back. Across the 299 CI runs created between
    2026-09-22T06:05Z and 17:00Z, 21 runs had such a failure and ci-status
    concluded `failure` in all 21.
    """

    def classify(self, *, jobs=None, pr=None, run=None):
        return janitor.classify(
            run or make_run(), janitor.macos_usage(jobs if jobs is not None else doomed_jobs()),
            pr if pr is not None else make_pr(),
            newer_ci_run_waiting=False, pull_request_policy="compile-only", now=NOW,
        )

    def test_failed_shard_with_macos_jobs_still_held_is_doomed(self):
        verdict = self.classify()
        self.assertEqual(verdict[0], "doomed")
        self.assertIn("app-host unit tests (3/6)", verdict[1])
        self.assertIn("3 macOS job(s) still held", verdict[1])
        self.assertIn("PR #1 (feature)", verdict[1])

    def test_earliest_failed_shard_is_the_one_reported(self):
        jobs = doomed_jobs(failed_age=30)
        jobs.append({"status": "completed", "labels": [MAC], "created_at": iso(60),
                     "name": "macos / app-host unit tests (5/6)", "conclusion": "failure",
                     "completed_at": iso(40)})
        self.assertIn("(5/6)", self.classify(jobs=jobs)[1])

    def test_no_macos_job_left_to_reclaim_is_kept(self):
        # usage.held == 0 short-circuits every category: cancelling would free
        # nothing and only destroy the Linux results.
        self.assertIsNone(self.classify(jobs=doomed_jobs(queued=0, running=0)))

    def test_macos_jobs_held_without_a_shard_failure_are_kept(self):
        for conclusion in ("success", "skipped", "cancelled"):
            with self.subTest(conclusion=conclusion):
                self.assertIsNone(self.classify(jobs=doomed_jobs(conclusion=conclusion)))

    def test_continue_on_error_step_failure_is_kept(self):
        # The jobs API does not report continue-on-error and does not need to:
        # a job whose only failed steps tolerate failure concludes `success`,
        # and ci-status reads the job, not the step.
        jobs = doomed_jobs(conclusion="success")
        jobs[-1]["steps"] = [{"name": "Upload xcresults", "conclusion": "failure"}]
        self.assertIsNone(self.classify(jobs=jobs))

    def test_app_host_job_has_no_job_level_continue_on_error(self):
        # Job-level continue-on-error is not absorbed by the job conclusion the
        # test above relies on, so reading a `failure` conclusion as decisive
        # would stop being sound.
        macos = (ROOT / ".github/workflows/ci-macos.yml").read_text(encoding="utf-8")
        # The job ends at the next line indented exactly two spaces. Splitting
        # on "\n  " alone stopped after the job's first key, so a job-level
        # continue-on-error anywhere below it went unseen.
        block = re.split(r"\n  (?=\S)", macos.split("\n  app-host-unit-tests:\n", 1)[1], maxsplit=1)[0]
        self.assertIn("\n    steps:", "\n" + block)
        self.assertNotIn("\n    continue-on-error", "\n" + block)

    def test_a_run_fixing_the_failing_job_is_kept(self):
        """The run repairing app-host is the one that most needs its shards.

        Each path is a real diff from a run this rule flagged in the census
        window: PR #13643 (fix/app-host-green and siblings), #13579, #13427,
        #13414 and #13615 were all repairing the app-host lane when a shard of
        their own run failed. Run 35738641571 on `ci-6134-isolate-ssh-fish-hang`
        was cancelled by hand for exactly this and had to be restarted.
        """
        repairs = {
            "PR #13643 app-host test sources": "cmuxTests/AgentSessionAutoResumeSettingsTests.swift",
            "PR #13408 the failing regression itself": "cmuxTests/WorkspaceSSHFishShellTests.swift",
            "PR #13579 shard splitter": "scripts/ci/cmux_unit_test_shard.py",
            "PR #13579 shard workload": "scripts/ci/workloads/macos-app-host-test-shard.sh",
            "PR #13427 job definition": ".github/workflows/ci-macos.yml",
            "PR #13414 test product build": "scripts/ci/compile-app-host-test-product.sh",
            "quarantine list": "scripts/ci/app-host-known-failures.json",
        }
        for name, path in repairs.items():
            with self.subTest(name=name):
                pr = make_pr(files=("Sources/AppDelegate.swift", path))
                self.assertIsNone(self.classify(pr=pr))

    def test_failed_compile_admission_with_macos_jobs_still_held_is_doomed(self):
        # 2026-09-24: main stopped compiling (36c30506) and every PR run built
        # on it failed `macOS compile admission`, while its other macOS jobs
        # stayed queued on Blacksmith macos-26 for over an hour. A failed
        # admission fails the `macos` call just as a failed shard does.
        jobs = doomed_jobs(name="macos / macOS compile admission")
        verdict = self.classify(jobs=jobs)
        self.assertEqual(verdict[0], "doomed")
        self.assertIn("macOS compile admission", verdict[1])

    def test_compile_admission_that_did_not_fail_is_kept(self):
        for conclusion in ("success", "skipped", "cancelled"):
            with self.subTest(conclusion=conclusion):
                jobs = doomed_jobs(name="macos / macOS compile admission", conclusion=conclusion)
                self.assertIsNone(self.classify(jobs=jobs))

    def test_an_unrelated_diff_is_still_doomed(self):
        # PR #13218 changed nothing the shard consumes, so its remaining macOS
        # jobs are only holding pool capacity.
        pr = make_pr(files=("Sources/JSONC.swift", "web/app/page.tsx", "tests/test_jsonc.py"))
        self.assertEqual(self.classify(pr=pr)[0], "doomed")

    def test_unreadable_diff_is_kept(self):
        # A diff past the page size, or one GraphQL did not return, cannot show
        # that a path is absent.
        self.assertIsNone(self.classify(pr=make_pr(files_truncated=True)))
        self.assertIsNone(self.classify(pr=make_pr(files=None)))

    def test_opt_out_label_is_honoured(self):
        # The escape hatch for a fix that lives entirely in product code, which
        # no path list can distinguish from an ordinary change.
        self.assertIsNone(self.classify(pr=make_pr(labels=["full-ci", "no-janitor"])))

    def test_recent_failure_waits_out_the_grace_window(self):
        self.assertIsNone(self.classify(jobs=doomed_jobs(failed_age=5)))

    def test_undated_failure_fails_closed(self):
        self.assertIsNone(self.classify(jobs=doomed_jobs(completed_at=False)))

    def test_rerun_is_kept(self):
        self.assertIsNone(self.classify(run=make_run(attempt=2)))

    def test_missing_attempt_fails_closed(self):
        run = make_run()
        del run["run_attempt"]
        self.assertIsNone(self.classify(run=run))

    def test_only_the_ci_workflow(self):
        run = make_run(path=".github/workflows/ci-macos.yml", name="CI macOS")
        self.assertIsNone(self.classify(run=run))

    def test_closed_or_superseded_pr_stays_stale_pr(self):
        # The earlier categories win: they need no diff read and no grace wait.
        self.assertEqual(self.classify(pr=make_pr(state="MERGED"))[0], "stale-pr")
        self.assertEqual(self.classify(pr=make_pr(head="bbb"))[0], "stale-pr")

    def test_doomed_is_spent_last_and_under_the_shared_cap(self):
        main_run, main_jobs = busy_main_push(queued=9)
        exp = make_run(event="push", branch="exp/a", name="canary")
        doomed = make_run(branch="feature", sha="aaa")
        runs = [main_run, exp, doomed]
        jobs = {main_run["id"]: main_jobs, exp["id"]: mac_jobs(queued=2), doomed["id"]: doomed_jobs()}
        result = plan(runs, jobs, {"feature": [make_pr()]}, max_cancels=1)
        self.assertEqual([c.category for c in result.to_cancel()], ["experiment"])
        skipped = [d for d in result.decisions if d.action == "skip"]
        self.assertEqual([d.candidate.category for d in skipped], ["doomed"])
        self.assertIn("per-sweep cap", skipped[0].note)

    def test_doomed_does_not_fire_below_the_queue_threshold(self):
        # A doomed run is only worth cancelling when its slots are contended.
        doomed = make_run(branch="feature", sha="aaa")
        result = plan([doomed], {doomed["id"]: doomed_jobs()}, {"feature": [make_pr()]})
        self.assertEqual(result.to_cancel(), [])
        self.assertTrue(all(d.action == "skip" for d in result.decisions))
        self.assertIn("not over", result.decisions[0].note)


class ResolvePullRequestTests(unittest.TestCase):
    def test_prefers_run_pull_request_number(self):
        run = make_run(prs=[2])
        prs = [make_pr(1, state="CLOSED"), make_pr(2)]
        self.assertEqual(janitor.resolve_pull_request(run, prs)["number"], 2)

    def test_matches_head_sha_then_single_open_pr(self):
        run = make_run(sha="old")
        closed_old = make_pr(1, state="CLOSED", head="old")
        open_new = make_pr(2, head="new")
        self.assertEqual(janitor.resolve_pull_request(run, [open_new, closed_old])["number"], 1)
        self.assertEqual(janitor.resolve_pull_request(make_run(sha="other"), [open_new, closed_old])["number"], 2)

    def test_fork_with_same_branch_name_is_not_confused(self):
        run = make_run(owner="someone")
        self.assertIsNone(janitor.resolve_pull_request(run, [make_pr(1, state="CLOSED")]))
        fork_pr = make_pr(3, state="CLOSED", owner="someone")
        self.assertEqual(janitor.resolve_pull_request(run, [make_pr(1), fork_pr])["number"], 3)

    def test_ambiguous_open_prs_are_left_alone(self):
        run = make_run(sha="zzz")
        self.assertIsNone(janitor.resolve_pull_request(run, [make_pr(1, head="a"), make_pr(2, head="b")]))


class PlanTests(unittest.TestCase):
    def test_threshold_gates_all_cancellation(self):
        exp = make_run(event="push", branch="exp/incremental-a")
        result = plan([exp], {exp["id"]: mac_jobs(queued=6)}, threshold=6)
        self.assertFalse(result.over_threshold)
        self.assertEqual(result.to_cancel(), [])
        self.assertEqual([d.action for d in result.decisions], ["skip"])

    def test_priority_order_and_stop_when_projected_under_threshold(self):
        main_run, main_jobs = busy_main_push(queued=6)
        draft_run = make_run(branch="draft-branch", age=300)
        merged_run = make_run(branch="merged-branch", age=200)
        closed_run = make_run(branch="closed-branch", age=10)
        exp_run = make_run(event="push", branch="exp/incremental-b", age=5)
        runs = [main_run, draft_run, closed_run, merged_run, exp_run]
        jobs = {
            main_run["id"]: main_jobs,
            draft_run["id"]: mac_jobs(queued=4),
            merged_run["id"]: mac_jobs(queued=1),
            closed_run["id"]: mac_jobs(queued=1),
            exp_run["id"]: mac_jobs(queued=1, running=1),
        }
        prs = {
            "draft-branch": [make_pr(1, draft=True)],
            "merged-branch": [make_pr(2, state="MERGED")],
            "closed-branch": [make_pr(3, state="CLOSED")],
        }
        result = plan(runs, jobs, prs, threshold=6)
        self.assertEqual(result.queued_macos_jobs, 13)
        # The open draft is never planned, even with the queue far over threshold.
        self.assertEqual([d.candidate.run["id"] for d in result.decisions],
                         [exp_run["id"], merged_run["id"], closed_run["id"]])
        self.assertEqual([d.action for d in result.decisions], ["cancel", "cancel", "cancel"])

        # 13 queued: experiment frees 2 -> 11, merged frees 1 -> 10. The pool
        # is no longer over 10, but a stale PR run is cancelled regardless.
        result = plan(runs, jobs, prs, threshold=10)
        self.assertEqual([d.action for d in result.decisions], ["cancel", "cancel", "cancel"])

        # Other categories stop once the projected queue is back under.
        main_run, main_jobs = busy_main_push(queued=10)
        exps = [make_run(event="push", branch=f"exp/stop-{i}", age=10 - i) for i in range(3)]
        jobs = {main_run["id"]: main_jobs, **{r["id"]: mac_jobs(queued=1) for r in exps}}
        # 13 queued: two experiments bring it to 11, which is not over 11.
        result = plan([main_run, *exps], jobs, threshold=11)
        self.assertEqual([d.action for d in result.decisions], ["cancel", "cancel", "skip"])

    def test_stale_pr_runs_are_cancelled_below_the_threshold(self):
        # No pool is backed up, yet runs for merged, closed and superseded PRs
        # produce results nobody reads, so they go whatever the queue.
        merged_run = make_run(branch="merged-branch", age=50)
        closed_run = make_run(branch="closed-branch", age=40)
        superseded_run = make_run(branch="moved-branch", sha="old", age=30)
        current_run = make_run(branch="current-branch", age=20)
        exp_run = make_run(event="push", branch="exp/idle", age=10)
        runs = [merged_run, closed_run, superseded_run, current_run, exp_run]
        jobs = {run["id"]: mac_jobs(running=1, label="macos-26") for run in runs}
        prs = {
            "merged-branch": [make_pr(1, state="MERGED")],
            "closed-branch": [make_pr(2, state="CLOSED")],
            "moved-branch": [make_pr(3, head="new")],
            "current-branch": [make_pr(4)],
        }
        result = plan(runs, jobs, prs, threshold=6)
        self.assertFalse(result.over_threshold)
        self.assertEqual(
            [(d.candidate.run["id"], d.action) for d in result.decisions],
            [(exp_run["id"], "skip"), (merged_run["id"], "cancel"), (closed_run["id"], "cancel"),
             (superseded_run["id"], "cancel")])
        summary = janitor.render_summary(result, dry_run=True, now=NOW)
        self.assertNotIn("nothing is cancelled", summary)

    def test_stale_pr_runs_still_respect_the_cancel_cap(self):
        runs = [make_run(branch=f"merged-{i}", age=10 + i) for i in range(3)]
        jobs = {run["id"]: mac_jobs(running=1) for run in runs}
        prs = {f"merged-{i}": [make_pr(i + 1, state="MERGED")] for i in range(3)}
        result = plan(runs, jobs, prs, max_cancels=2)
        self.assertEqual([d.action for d in result.decisions], ["cancel", "cancel", "skip"])

    def test_stale_runs_on_idle_pools_do_not_take_the_cap_from_a_backed_up_pool(self):
        # A stale run on an idle pool frees nothing anyone waits for, so it is
        # cancelled only after the runs that relieve the backed-up pool.
        main_run, main_jobs = busy_main_push(queued=9)
        idle_merged = make_run(branch="merged-branch", age=50)
        doomed = make_run(branch="feature", sha="aaa", age=10)
        runs = [main_run, idle_merged, doomed]
        jobs = {main_run["id"]: main_jobs, idle_merged["id"]: mac_jobs(running=1, label="macos-26"),
                doomed["id"]: doomed_jobs()}
        prs = {"merged-branch": [make_pr(1, state="MERGED")], "feature": [make_pr(2)]}
        result = plan(runs, jobs, prs, max_cancels=1)
        self.assertEqual([c.category for c in result.to_cancel()], ["doomed"])

    def test_a_rerun_or_opted_out_stale_run_waits_for_a_backed_up_pool(self):
        # Someone re-ran it, or labelled the PR no-janitor, on purpose: keep it
        # unless its pool is contended.
        rerun = make_run(branch="moved-branch", sha="old", attempt=2, age=30)
        opted_out = make_run(branch="kept-branch", sha="old", age=20)
        prs = {"moved-branch": [make_pr(1, head="new")],
               "kept-branch": [make_pr(2, head="new", labels=(janitor.JANITOR_OPT_OUT_LABEL,))]}
        idle_jobs = {rerun["id"]: mac_jobs(running=1), opted_out["id"]: mac_jobs(running=1)}
        idle = plan([rerun, opted_out], idle_jobs, prs)
        self.assertEqual(idle.to_cancel(), [])
        self.assertTrue(all("not over" in d.note for d in idle.decisions))

        main_run, main_jobs = busy_main_push(queued=9)
        busy = plan([main_run, rerun, opted_out], {main_run["id"]: main_jobs, **idle_jobs}, prs)
        self.assertEqual([c.run["id"] for c in busy.to_cancel()], [rerun["id"], opted_out["id"]])

    def test_a_stale_run_with_an_unread_label_page_waits_for_a_backed_up_pool(self):
        # no-janitor may be on the page that was not fetched.
        run = make_run(branch="moved-branch", sha="old")
        prs = {"moved-branch": [make_pr(1, head="new", labels_truncated=True)]}
        result = plan([run], {run["id"]: mac_jobs(running=1)}, prs)
        self.assertEqual(result.to_cancel(), [])

    def test_cancel_cap(self):
        main_run, main_jobs = busy_main_push(queued=30)
        exps = [make_run(event="push", branch=f"exp/incremental-{i}") for i in range(4)]
        jobs = {main_run["id"]: main_jobs, **{r["id"]: mac_jobs(queued=1) for r in exps}}
        result = plan([main_run, *exps], jobs, max_cancels=2)
        self.assertEqual([d.action for d in result.decisions], ["cancel", "cancel", "skip", "skip"])

    def test_threshold_is_per_pool(self):
        # Four pools of five queued jobs each: 20 queued in total, but no pool
        # is backed up, so cancelling anything frees nothing anyone waits for.
        pools = ["blacksmith-6vcpu-macos-15", "blacksmith-6vcpu-macos-26", "macos-15", "macos-26"]
        main_runs = [make_run(event="push", branch="main") for _ in pools]
        exp = make_run(event="push", branch="exp/idle-pools")
        jobs = {run["id"]: mac_jobs(queued=5, label=pool) for run, pool in zip(main_runs, pools)}
        jobs[exp["id"]] = mac_jobs(queued=1, label="macos-15")
        result = plan([*main_runs, exp], jobs, threshold=6)
        self.assertEqual(result.queued_macos_jobs, 21)
        self.assertFalse(result.over_threshold)
        self.assertEqual(result.to_cancel(), [])

    def test_only_runs_holding_a_backed_up_pool_are_cancelled(self):
        # Blacksmith macOS 26 is backed up; the hosted macOS 15 pool is not.
        main_run = make_run(event="push", branch="main")
        idle_exp = make_run(event="push", branch="exp/hosted-15", age=30)
        stuck_exp = make_run(event="push", branch="exp/blacksmith-26", age=5)
        jobs = {
            main_run["id"]: mac_jobs(queued=8, label="blacksmith-6vcpu-macos-26"),
            idle_exp["id"]: mac_jobs(queued=2, label="macos-15"),
            stuck_exp["id"]: mac_jobs(queued=1, label="blacksmith-6vcpu-macos-26"),
        }
        result = plan([main_run, idle_exp, stuck_exp], jobs, threshold=6)
        self.assertTrue(result.over_threshold)
        # Runs holding the backed-up pool are decided first.
        self.assertEqual([(d.candidate.run["id"], d.action) for d in result.decisions],
                         [(stuck_exp["id"], "cancel"), (idle_exp["id"], "skip")])
        self.assertIn("not backed up", result.decisions[1].note)

    def test_label_dropped_uses_waiting_replacement_in_inventory(self):
        main_run, main_jobs = busy_main_push(queued=10)
        old = make_run(branch="feat", age=30, status="in_progress")
        new = make_run(branch="feat", age=5, status="pending")
        pr = make_pr(1, timeline=[("LabeledEvent", "full-ci", 60), ("UnlabeledEvent", "full-ci", 5)])
        jobs = {main_run["id"]: main_jobs, old["id"]: mac_jobs(queued=3, running=2), new["id"]: []}
        result = plan([main_run, old, new], jobs, {"feat": [pr]})
        self.assertEqual([(d.candidate.run["id"], d.candidate.category, d.action) for d in result.decisions],
                         [(old["id"], "label-dropped", "cancel")])

    def test_branches_to_resolve_skips_runs_without_macos_jobs(self):
        with_mac = make_run(branch="a")
        without = make_run(branch="b")
        protected = make_run(branch="c", name="iOS TestFlight")
        jobs = {with_mac["id"]: mac_jobs(queued=1), without["id"]: [], protected["id"]: mac_jobs(queued=1)}
        self.assertEqual(janitor.branches_to_resolve([with_mac, without, protected], jobs), ["a"])


class FetchSelectionTests(unittest.TestCase):
    def test_linux_only_workflows_and_ghosts_skip_job_listing(self):
        linux_only = frozenset({".github/workflows/cla.yml"})
        self.assertFalse(janitor.needs_jobs(make_run(path=".github/workflows/cla.yml"), linux_only, NOW))
        self.assertFalse(janitor.needs_jobs(make_run(status="queued", age=60 * 48), linux_only, NOW))
        self.assertFalse(janitor.needs_jobs(make_run(event="deployment_status"), linux_only, NOW))
        self.assertTrue(janitor.needs_jobs(make_run(status="queued", age=180), linux_only, NOW))
        # Workflows that only exist on an experiment branch are unknown: look.
        self.assertTrue(janitor.needs_jobs(
            make_run(event="push", branch="exp/x", path=".github/workflows/incremental-x.yml"), linux_only, NOW))

    def test_linux_only_scan(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            (directory / "linux.yml").write_text("jobs:\n  a:\n    runs-on: ubuntu\n")
            (directory / "mac.yml").write_text("jobs:\n  a:\n    runs-on: ${{ vars.MACOS_RUNNER_15 }}\n")
            (directory / "caller.yml").write_text("jobs:\n  a:\n    uses: ./.github/workflows/mac.yml\n")
            self.assertEqual(janitor.linux_only_workflow_paths(directory),
                             frozenset({".github/workflows/linux.yml"}))

    def test_macos_usage_counts_only_macos_labels(self):
        jobs = mac_jobs(queued=2, running=1, age=90) + [
            {"status": "queued", "name": "lint", "labels": [LINUX], "created_at": iso(500)},
            {"status": "completed", "name": "old", "labels": [MAC], "created_at": iso(500)},
        ]
        usage = janitor.macos_usage(jobs)
        self.assertEqual((usage.queued, usage.running), (2, 1))
        self.assertEqual(janitor.format_age(NOW - usage.oldest_queued_at), "1h30m")


class GraphQLTests(unittest.TestCase):
    def test_single_query_for_all_branches(self):
        query, variables = janitor.graphql_query("manaflow-ai", "cmux", ["a", "exp/b"])
        self.assertIn("b0: pullRequests(headRefName: $b0", query)
        self.assertIn("b1: pullRequests(headRefName: $b1", query)
        self.assertNotIn("isDraft", query)
        self.assertIn("LABELED_EVENT", query)
        self.assertEqual(variables, {"owner": "manaflow-ai", "name": "cmux", "b0": "a", "b1": "exp/b"})
        response = {"data": {"repository": {"b0": {"nodes": [make_pr(1)]}, "b1": {"nodes": []}}}}
        self.assertEqual(sorted(janitor.parse_graphql_prs(response, ["a", "exp/b"])), ["a", "exp/b"])


class SummaryTests(unittest.TestCase):
    def test_summary_logs_url_reason_and_age(self):
        main_run, main_jobs = busy_main_push(queued=8)
        exp = make_run(event="push", branch="exp/incremental-a", name="Xcode incremental generation canary")
        result = plan([main_run, exp], {main_run["id"]: main_jobs, exp["id"]: mac_jobs(queued=3, age=171)})
        text = janitor.render_summary(result, dry_run=True, now=NOW)
        self.assertIn("dry run", text)
        self.assertIn(exp["html_url"], text)
        self.assertIn("would cancel", text)
        self.assertIn("push-triggered experiment on exp/incremental-a", text)
        self.assertIn("2h51m", text)
        live = janitor.render_summary(result, dry_run=False, now=NOW, results={exp["id"]: "cancelled"})
        self.assertIn("| cancelled |", live)


class OwnedMarkerRunTests(unittest.TestCase):
    def run_of(self, **overrides):
        run = {"event": "pull_request", "path": ".github/workflows/ci.yml", "run_attempt": 1,
               "head_repository": {"id": 1}, "repository": {"id": 1}}
        run.update(overrides)
        return run

    def test_ci_pull_requests_and_e2e_dispatches_may_hold_an_owned_pool(self):
        self.assertTrue(janitor.may_hold_owned_pool(self.run_of(), []))
        # Attempt 2 is placed like attempt 1, whoever started it (pr_runner_pool.LAST_OWNED_ATTEMPT).
        bot = {"login": "github-actions[bot]"}
        self.assertTrue(janitor.may_hold_owned_pool(self.run_of(run_attempt=2, triggering_actor=bot), []))
        # A person's re-run follows a code failure and may pick the fleet again.
        self.assertTrue(janitor.may_hold_owned_pool(self.run_of(run_attempt=3), []))
        self.assertTrue(janitor.may_hold_owned_pool(
            self.run_of(event="workflow_dispatch", path=".github/workflows/test-e2e.yml"), []))
        for why, run in {
            "ci.yml dispatch": self.run_of(event="workflow_dispatch"),
            "e2e as a pull request": self.run_of(path=".github/workflows/test-e2e.yml"),
            "the bot's third attempt": self.run_of(run_attempt=3, triggering_actor={"login": "github-actions[bot]"}),
            "fork": self.run_of(head_repository={"id": 2}),
            "other workflow": self.run_of(event="workflow_dispatch", path=".github/workflows/nightly.yml"),
        }.items():
            with self.subTest(why=why):
                self.assertFalse(janitor.may_hold_owned_pool(run, []))

    def test_a_first_attempt_still_in_the_queue_has_no_marker_to_list(self):
        queued = [{"status": "queued", "name": "changes", "labels": [LINUX]},
                  {"status": "waiting", "name": "deploy", "labels": [LINUX]}]
        self.assertFalse(janitor.marker_may_exist(self.run_of(), queued))
        self.assertFalse(janitor.marker_may_exist(self.run_of(), []))
        started = [{"status": "in_progress", "name": "changes", "labels": [LINUX]}] + queued
        self.assertTrue(janitor.marker_may_exist(self.run_of(), started))
        done = [{"status": "completed", "name": "changes", "labels": [LINUX]}] + queued
        self.assertTrue(janitor.marker_may_exist(self.run_of(), done))
        # A re-run may hold the marker an earlier attempt uploaded.
        self.assertTrue(janitor.marker_may_exist(self.run_of(run_attempt=2), queued))
        # A listing cut at MAX_JOB_PAGES may hide the started job.
        many = [{"status": "queued", "name": "x", "labels": [LINUX]}] * (janitor.MAX_JOB_PAGES * 100)
        self.assertTrue(janitor.marker_may_exist(self.run_of(), many))


class WorkflowShapeTests(unittest.TestCase):
    def setUp(self):
        self.text = WORKFLOW.read_text(encoding="utf-8")

    def test_a_requested_ci_run_refreshes_a_stale_snapshot(self):
        # The cron drifts (55 minutes apart on 2026-09-25), so CI being
        # requested also sweeps, unless the newest snapshot is fresh.
        workflow = yaml.safe_load(self.text)
        triggers = workflow[True] if True in workflow else workflow["on"]
        self.assertEqual(triggers["workflow_run"], {"workflows": ["CI"], "types": ["requested"]})
        steps = workflow["jobs"]["sweep"]["steps"]
        # Only the glaeda-route App mint comes first (it spends the App's budget, not
        # GITHUB_TOKEN's), so the freshness probe's one read is on the App's budget too.
        self.assertEqual(steps[0]["id"], "glaeda-token")
        self.assertEqual(steps[0]["with"]["private-key"], "${{ secrets.GLAEDA_ROUTE_APP_KEY }}")
        self.assertEqual(steps[1]["id"], "fresh")
        self.assertEqual(steps[1]["env"]["GH_TOKEN"], "${{ steps.glaeda-token.outputs.token || github.token }}")
        for step in steps[2:]:
            self.assertIn("steps.fresh.outputs.skip != 'true'", step["if"], step["name"])

    def test_a_feat_cmux_next_ci_run_starts_no_sweep(self):
        # feat-cmux-next's ci.yml never sends its pull requests to macOS; the cron still sweeps.
        workflow = yaml.safe_load(self.text)
        self.assertEqual(
            workflow["jobs"]["sweep"]["if"],
            "${{ !(github.event_name == 'workflow_run' && "
            "github.event.workflow_run.pull_requests[0].base.ref == 'feat-cmux-next') }}")

    def test_requested_runs_only_stand_in_for_a_late_cron(self):
        # 2026-10-06: CI was requested hundreds of times an hour, a 240 s skip
        # let those requests sweep about every 5 minutes on top of the cron, and
        # the shared GITHUB_TOKEN budget ran out. A requested run now sweeps only
        # once a cron interval has passed without a snapshot, and a cron skips
        # when a requested run has just swept for it. A manual dispatch always
        # sweeps.
        workflow = yaml.safe_load(self.text)
        fresh = workflow["jobs"]["sweep"]["steps"][1]
        self.assertEqual(fresh["if"], "github.event_name != 'workflow_dispatch'")
        self.assertEqual(fresh["env"]["FRESH_SECONDS"],
                         "${{ github.event_name == 'workflow_run' && '600' || '300' }}")
        # The cron skip must stay below one interval less a sweep, so an on-time
        # cron always sweeps after the previous on-time cron.
        self.assertIn('- cron: "*/10 * * * *"', self.text)

    def test_triggers_permissions_and_runner(self):
        text = self.text
        self.assertIn('- cron: "*/10 * * * *"', text)
        self.assertIn("workflow_dispatch:", text)
        self.assertIn("dry_run:", text)
        self.assertNotIn("pull_request", text.split("jobs:")[0].replace("pull-requests: read", ""))
        self.assertIn("\npermissions: {}\n", text)
        self.assertIn("  sweep:\n    permissions:\n      actions: write\n      pull-requests: read\n      contents: read\n", text)
        self.assertIn("runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || vars.LINUX_RUNNER || 'blacksmith-4vcpu-ubuntu-2404' }}", text)
        self.assertIn("concurrency:\n  group: ci-queue-janitor\n  cancel-in-progress: false\n", text)
        self.assertIn("vars.CI_JANITOR_QUEUE_THRESHOLD", text)
        self.assertIn("ORPHAN_MINUTES: ${{ vars.CI_JANITOR_ORPHAN_MINUTES }}", text)
        self.assertIn("run: python3 scripts/ci/queue_janitor.py", text)
        self.assertIn("persist-credentials: false", text)

    def test_manual_dispatch_defaults_to_dry_run(self):
        block = self.text.split("dry_run:", 1)[1].split("permissions:", 1)[0]
        self.assertIn("default: true", block)
        self.assertIn("inputs.dry_run && 'true'", self.text)
        self.assertIn("vars.CI_JANITOR_DRY_RUN == 'true'", self.text)


# ---------------------------------------------------------------------------
# Orphaned runs: a job GitHub/Blacksmith never assigned a runner.
# ---------------------------------------------------------------------------


def linux_job(*, status="completed", age=30, runner=True, name="lint", label=LINUX):
    job = {"status": status, "name": name, "labels": [label], "created_at": iso(age),
           "runner_name": f"{label}-Runner-abc" if runner else None}
    if status == "completed":
        job["conclusion"] = "success"
    return job


def orphan_job(*, age=240, name="ci-status", label=LINUX, status="queued"):
    """A job that never got a runner: runner_name is empty."""
    return {"status": status, "name": name, "labels": [label], "created_at": iso(age), "runner_name": None}


def served_job(*, age=30, label=LINUX, status="completed"):
    """A job on the same pool that did get a runner."""
    return linux_job(status=status, age=age, runner=True, label=label)


def find(runs, jobs, *, minutes=120):
    return janitor.find_orphans(runs, jobs, min_age=dt.timedelta(minutes=minutes), now=NOW)


def orphan_plan(orphans, prs=None, *, max_cancels=5, exclude=()):
    return janitor.build_orphan_plan(orphans, prs or {}, max_cancels=max_cancels, exclude_ids=set(exclude), now=NOW)


class OrphanDetectionTests(unittest.TestCase):
    def test_lost_assignment_is_an_orphan(self):
        # PR #13988: macOS jobs cancelled, the Linux ci-status job queued for
        # hours while newer Linux jobs on the same pool got runners.
        stuck = make_run(status="queued", age=340, branch="ci/macos26-app-host-repair", prs=(13988,))
        other = make_run(status="in_progress", age=20, branch="other")
        jobs = {
            stuck["id"]: [linux_job(age=330), orphan_job(age=220)],
            other["id"]: [served_job(age=15), orphan_job(age=10, name="young")],
        }
        orphans = find([stuck, other], jobs)
        self.assertEqual([o.run["id"] for o in orphans], [stuck["id"]])
        self.assertEqual(orphans[0].job_name, "ci-status")
        self.assertIn("newer", orphans[0].evidence)
        self.assertIn(LINUX, orphans[0].evidence)

    def test_backlogged_pool_is_not_an_orphan(self):
        # A saturated pool: every job behind this one is also still queued and
        # the ones with runners were queued earlier. That is a backlog.
        waiting = make_run(age=300)
        behind = make_run(age=100)
        ahead = make_run(age=400)
        jobs = {
            waiting["id"]: [orphan_job(age=250, label=MAC, name="macos / shard")],
            behind["id"]: [orphan_job(age=90, label=MAC, name="macos / shard") for _ in range(8)],
            ahead["id"]: [served_job(age=390, label=MAC, status="in_progress")],
        }
        self.assertEqual(find([waiting, behind, ahead], jobs), [])

    def test_a_newer_job_on_another_pool_is_not_evidence(self):
        waiting = make_run(age=300)
        other = make_run(age=30)
        jobs = {
            waiting["id"]: [orphan_job(age=250, label=MAC)],
            other["id"]: [served_job(age=20, label=LINUX), served_job(age=20, label="blacksmith-6vcpu-macos-26")],
        }
        self.assertEqual(find([waiting, other], jobs), [])

    def test_threshold_is_respected(self):
        waiting = make_run(age=100)
        other = make_run(age=30)
        jobs = {waiting["id"]: [orphan_job(age=90)], other["id"]: [served_job(age=20)]}
        self.assertEqual(find([waiting, other], jobs), [])
        self.assertEqual(len(find([waiting, other], jobs, minutes=60)), 1)

    def test_a_day_without_a_runner_is_an_orphan_without_evidence(self):
        waiting = make_run(status="in_progress", age=60 * 26)
        jobs = {waiting["id"]: [linux_job(age=60 * 26), orphan_job(age=60 * 25, label="some-dead-label")]}
        orphans = find([waiting], jobs)
        self.assertEqual(len(orphans), 1)
        self.assertIn("no runner", orphans[0].evidence)

    def test_jobs_that_are_not_queued_or_have_a_runner_are_not_orphans(self):
        waiting = make_run(age=300)
        other = make_run(age=30)
        jobs = {
            waiting["id"]: [
                orphan_job(age=250, status="waiting"),  # environment approval
                orphan_job(age=250, status="pending"),  # concurrency
                dict(orphan_job(age=250), runner_name="blacksmith-runner-1"),
            ],
            other["id"]: [served_job(age=20)],
        }
        self.assertEqual(find([waiting, other], jobs), [])

    def test_sep13_style_queued_run_without_jobs_is_an_orphan(self):
        ghost = make_run(status="queued", age=60 * 24 * 11, name="CLA Assistant",
                         path=".github/workflows/cla.yml", event="pull_request_target")
        # The sweep deliberately does not list a ghost's jobs.
        self.assertFalse(janitor.needs_jobs(ghost, frozenset(), NOW))
        orphans = find([ghost], {})
        self.assertEqual([o.run["id"] for o in orphans], [ghost["id"]])
        self.assertIsNone(orphans[0].job_name)
        self.assertIn("queued", orphans[0].evidence)

    def test_recent_queued_run_without_jobs_is_not_an_orphan(self):
        run = make_run(status="queued", age=180)
        self.assertEqual(find([run], {}), [])
        self.assertEqual(find([run], {run["id"]: []}), [])

    def test_completed_runs_are_ignored(self):
        run = make_run(status="completed", age=60 * 48)
        self.assertEqual(find([run], {run["id"]: [orphan_job(age=60 * 30)]}), [])

    def test_sweep_lists_queued_runs_regardless_of_age(self):
        ghost = make_run(status="queued", age=60 * 24 * 11, name="Legacy workflow",
                         path=".github/workflows/legacy-workflow.yml")
        fake = FakeGitHub({ghost["id"]: ghost})
        runs = fake.in_flight_runs()
        self.assertIn(ghost["id"], [r["id"] for r in runs])
        self.assertTrue(any("status=queued" in path for method, path in fake.log if method == "GET"))
        self.assertEqual([o.run["id"] for o in find(runs, {})], [ghost["id"]])


class OrphanPlanTests(unittest.TestCase):
    def orphans(self, count, *, kind="job", **run_kwargs):
        result = []
        for index in range(count):
            if kind == "job":
                run = make_run(age=300 + index, **run_kwargs)
                other = make_run(age=10)
                jobs = {run["id"]: [orphan_job(age=250 + index)], other["id"]: [served_job(age=5)]}
                result += find([run, other], jobs)
            else:
                run = make_run(status="queued", age=60 * 48 + index, **run_kwargs)
                result += find([run], {})
        return result

    def test_orphans_are_cancelled_without_a_backed_up_pool(self):
        decisions = orphan_plan(self.orphans(1))
        self.assertEqual([d.action for d in decisions], ["cancel"])

    def test_separate_cap_prefers_lost_assignments_over_ghost_runs(self):
        jobs = self.orphans(2)
        ghosts = self.orphans(3, kind="ghost")
        decisions = orphan_plan(ghosts + jobs, max_cancels=3)
        cancelled = [d.orphan.run["id"] for d in decisions if d.action == "cancel"]
        self.assertEqual(len(cancelled), 3)
        self.assertTrue({o.run["id"] for o in jobs} <= set(cancelled))
        capped = [d for d in decisions if d.action == "skip"]
        self.assertEqual(len(capped), 2)
        self.assertTrue(all("orphan cap of 3" in d.note for d in capped))

    def test_ghost_past_give_up_age_is_left_to_github(self):
        # The 2026-09-13 runs answer 409 to cancel and force-cancel alike;
        # retrying them every sweep only spends the shared API budget.
        old = [o for o in (find([make_run(status="queued", age=60 * 24 * 11 + i)], {}) for i in range(3))
               for o in o]
        young = self.orphans(1, kind="ghost")
        decisions = orphan_plan(old + young, max_cancels=1)
        by_id = {d.orphan.run["id"]: d.action for d in decisions}
        self.assertEqual([by_id[o.run["id"]] for o in old], ["github-side"] * 3)
        self.assertEqual(by_id[young[0].run["id"]], "cancel")
        summary = janitor.render_orphan_summary(decisions, dry_run=False, now=NOW, min_age=dt.timedelta(hours=2))
        self.assertIn("3 run(s) still queued after", summary)
        self.assertNotIn(old[0].run["html_url"], summary)

    def test_ghost_left_to_github_skips_the_label_lookup(self):
        old = find([make_run(status="queued", age=60 * 24 * 11, branch="sep13", event="pull_request_target")], {})
        young = find([make_run(status="queued", age=60 * 48, branch="young", event="pull_request_target")], {})
        self.assertEqual(janitor.orphan_branches(old + young, NOW), ["young"])

    def test_protected_ghost_past_give_up_age_keeps_its_row(self):
        run = make_run(status="queued", age=60 * 24 * 11, name="Release", path=".github/workflows/release.yml")
        decisions = orphan_plan(find([run], {}))
        self.assertEqual([d.action for d in decisions], ["skip"])
        summary = janitor.render_orphan_summary(decisions, dry_run=False, now=NOW, min_age=dt.timedelta(hours=2))
        self.assertIn(run["html_url"], summary)
        self.assertIn("left for a human", summary)

    def test_summary_with_only_ghosts_left_to_github_has_no_table(self):
        old = find([make_run(status="queued", age=60 * 24 * 11)], {})
        summary = janitor.render_orphan_summary(orphan_plan(old), dry_run=False, now=NOW,
                                                min_age=dt.timedelta(hours=2))
        self.assertIn("1 run(s) still queued after", summary)
        self.assertNotIn("| Decision |", summary)
        self.assertNotIn("No orphaned runs found.", summary)

    def test_ghost_order_rotates_between_sweeps(self):
        # Runs GitHub refuses to cancel must not hold the cap forever.
        ghosts = self.orphans(4, kind="ghost")
        first = set()
        for minutes in range(0, 60, 10):
            decisions = janitor.build_orphan_plan(
                ghosts, {}, max_cancels=1, exclude_ids=set(), now=NOW + dt.timedelta(minutes=minutes))
            first.update(d.orphan.run["id"] for d in decisions if d.action == "cancel")
        self.assertEqual(first, {o.run["id"] for o in ghosts})

    def test_run_with_siblings_still_running_waits_for_them(self):
        # PR #13055: one app-host shard lost while its siblings ran. Their
        # output is still wanted; the run goes once they finish.
        run = make_run(age=300)
        other = make_run(age=10)
        jobs = {run["id"]: [orphan_job(age=250, label=MAC), served_job(age=250, label=MAC, status="in_progress")],
                other["id"]: [served_job(age=5, label=MAC)]}
        decisions = orphan_plan(find([run, other], jobs))
        self.assertEqual([d.action for d in decisions], ["skip"])
        self.assertIn("still running", decisions[0].note)

    def test_zero_cap_cancels_nothing(self):
        self.assertEqual({d.action for d in orphan_plan(self.orphans(2), max_cancels=0)}, {"skip"})

    def test_backlog_cancels_are_not_repeated(self):
        orphans = self.orphans(1)
        decisions = orphan_plan(orphans, exclude=[orphans[0].run["id"]])
        self.assertEqual(decisions, [])

    def test_main_schedule_nightly_and_testflight_orphans_are_cancelled(self):
        for kwargs in (
            dict(event="schedule", branch="main", name="iOS TestFlight (cmux.app)",
                 path=".github/workflows/ios-appstore-upload.yml"),
            dict(event="push", branch="main", name="Nightly macOS build", path=".github/workflows/nightly.yml"),
            dict(event="issue_comment", branch="main", name="Claude Code", path=".github/workflows/claude.yml"),
        ):
            with self.subTest(**kwargs):
                decisions = orphan_plan(self.orphans(1, **kwargs))
                self.assertEqual([d.action for d in decisions], ["cancel"])

    def test_release_merge_queue_and_tag_orphans_are_only_reported(self):
        for kwargs in (
            dict(event="release", branch="v0.64.0"),
            dict(event="push", branch="v0.64.0", name="Release", path=".github/workflows/release.yml"),
            dict(event="merge_group", branch="gh-readonly-queue/main/pr-1-abc"),
            dict(event="workflow_dispatch", branch="main", name="cmux-tui release cut",
                 path=".github/workflows/cmux-tui-release-cut.yml"),
        ):
            with self.subTest(**kwargs):
                decisions = orphan_plan(self.orphans(1, **kwargs))
                self.assertEqual([d.action for d in decisions], ["skip"])
                self.assertIn("human", decisions[0].note)

    def test_no_janitor_label_is_honoured(self):
        orphans = self.orphans(1, branch="keep-me", prs=(7,))
        prs = {"keep-me": [make_pr(7, labels=("no-janitor",))]}
        decisions = orphan_plan(orphans, prs)
        self.assertEqual([d.action for d in decisions], ["skip"])
        self.assertIn("no-janitor", decisions[0].note)
        self.assertEqual([d.action for d in orphan_plan(orphans, {"keep-me": [make_pr(7)]})], ["cancel"])

    def test_orphan_pr_branches_are_resolved(self):
        orphans = self.orphans(1, branch="pr-branch") + self.orphans(1, kind="ghost", event="push", branch="exp/x")
        self.assertEqual(janitor.orphan_branches(orphans, NOW), ["pr-branch"])


class FakeGitHub(janitor.GitHub):
    """Routes janitor API calls to in-memory runs; records every call."""

    def __init__(self, runs, jobs=None, *, refuse_cancel=(), ignore_cancel=(), refuse_force=(),
                 unreadable_branches=()):
        super().__init__("token", "manaflow-ai/cmux")
        self.runs = runs
        self.job_map = jobs or {}
        self.refuse_cancel = set(refuse_cancel)
        self.ignore_cancel = set(ignore_cancel)
        self.refuse_force = set(refuse_force)
        self.log = []
        # Earlier sweeps' macos-pool-load snapshots, oldest first.
        self.snapshots = []
        # Completed runs per workflow file, for the lost-assignment evidence listing.
        self.completed = {}
        self.refuse_rerun = set()
        self.app_only_posts = []
        self.refuse_dispatch = False
        # (method, path, body) of every POST.
        self.bodies = []
        # Branch -> pull requests the GraphQL lookup answers with.
        self.prs = {}
        # Branch -> head sha (GET /branches/<branch>); a branch missing here answers 404.
        self.branches = {}
        # Run ids, and runs of these branches, whose job listing fails as a 502 would after its retries.
        self.unreadable_jobs = set()
        self.unreadable_branches = set(unreadable_branches)

    def request(self, method, path, body=None, *, app_only=False):
        self.calls += 1
        self.log.append((method, path))
        if app_only:
            self.app_only_posts.append(path)
        if method == "POST":
            self.bodies.append((method, path, body))
        path = path.replace("/repos/manaflow-ai/cmux", "", 1)
        if method == "POST" and path == "/graphql":
            variables = (body or {}).get("variables") or {}
            return {"data": {"repository": {
                key: {"nodes": self.prs.get(branch, [])} for key, branch in variables.items()
                if re.fullmatch(r"b[0-9]+", key)}}}
        if method == "GET" and path.startswith("/branches/"):
            branch = urllib.parse.unquote(path.split("/", 2)[2])
            if branch not in self.branches:
                raise RuntimeError(f"GET /branches/{branch} failed (404)")
            return {"name": branch, "commit": {"sha": self.branches[branch]}}
        if method == "GET" and path.startswith("/actions/runs?"):
            query = urllib.parse.parse_qs(path.split("?", 1)[1])
            status, page = query["status"][0], int(query["page"][0])
            batch = [r for r in self.runs.values() if r["status"] == status] if page == 1 else []
            return {"workflow_runs": batch}
        if method == "GET" and path.startswith("/actions/artifacts?"):
            return {"artifacts": [
                {"id": index + 1, "name": "macos-pool-load", "expired": False,
                 "created_at": iso(10 * (len(self.snapshots) - index)),
                 "archive_download_url": f"https://example.invalid/{index}",
                 "workflow_run": {"head_branch": "main", "repository_id": 1, "head_repository_id": 1}}
                for index in range(len(self.snapshots))]}
        if method == "POST" and path.startswith("/actions/workflows/") and path.endswith("/dispatches"):
            if self.refuse_dispatch:
                raise RuntimeError(f"POST {path} failed (422)")
            return {}
        if method == "GET" and path.startswith("/actions/workflows/"):
            name = path.split("?", 1)[0].split("/")[3]
            query = urllib.parse.parse_qs(path.split("?", 1)[1])
            if "head_sha" in query:
                # The runs of one workflow at one branch, event and head (newer_run_at_head()).
                return {"workflow_runs": [dict(r) for r in self.runs.values()
                                          if r["path"].endswith("/" + name)
                                          and r["head_branch"] == query["branch"][0]
                                          and r["event"] == query["event"][0]
                                          and r["head_sha"] == query["head_sha"][0]]}
            return {"workflow_runs": [dict(r) for r in self.completed.get(name, [])]}
        parts = path.split("?", 1)[0].split("/")
        run_id = int(parts[3])
        if method == "GET" and parts[-1] == "jobs":
            if run_id in self.unreadable_jobs or self.runs.get(run_id, {}).get("head_branch") in self.unreadable_branches:
                raise RuntimeError(f"GET /actions/runs/{run_id}/jobs failed (502)")
            return {"jobs": self.job_map.get(run_id, [])}
        if method == "POST" and parts[-1] == "rerun-failed-jobs":
            if run_id in self.refuse_rerun:
                raise RuntimeError(f"POST /actions/runs/{run_id}/rerun-failed-jobs failed (403)")
            run = self.runs[run_id]
            actor = "cmux-bot[bot]" if app_only else "github-actions[bot]"
            run.update(status="queued", conclusion=None, run_attempt=run["run_attempt"] + 1,
                       triggering_actor={"login": actor})
            return {}
        if method == "GET" and parts[-1] == "artifacts":
            return {"artifacts": []}
        if method == "GET":
            return dict(self.runs[run_id])
        if parts[-1] == "cancel":
            if run_id in self.refuse_cancel:
                raise RuntimeError(f"POST /actions/runs/{run_id}/cancel failed (409)")
            if run_id not in self.ignore_cancel:
                self.runs[run_id]["status"] = "completed"
            return {}
        if parts[-1] == "force-cancel":
            if run_id in self.refuse_force:
                raise RuntimeError(f"POST /actions/runs/{run_id}/force-cancel failed (409)")
            self.runs[run_id]["status"] = "completed"
            return {}
        raise AssertionError(f"unexpected {method} {path}")

    def download(self, artifact):
        self.calls += 1
        self.log.append(("DOWNLOAD", artifact["archive_download_url"]))
        index = int(artifact["archive_download_url"].rsplit("/", 1)[1])
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, "w") as archive:
            archive.writestr("macos-pool-load.json", json.dumps(self.snapshots[index]))
        return buffer.getvalue()

    def posts(self):
        return [path.rsplit("/", 2)[-2:] for method, path in self.log if method == "POST" and "graphql" not in path]


class OrphanExecutionTests(unittest.TestCase):
    def run_one(self, **fake_kwargs):
        ghost = make_run(status="queued", age=60 * 48)
        sets = {key: ({ghost["id"]} if value else ()) for key, value in fake_kwargs.items()}
        fake = FakeGitHub({ghost["id"]: dict(ghost)}, **sets)
        decisions = orphan_plan(find([ghost], {}))
        slept = []
        results, failures = janitor.cancel_orphans(fake, decisions, sleep=slept.append)
        return ghost["id"], fake, results, failures, slept

    def test_cancel_that_takes_effect_needs_no_force(self):
        run_id, fake, results, failures, slept = self.run_one()
        self.assertEqual(results[run_id], "cancelled")
        self.assertEqual(fake.posts(), [[str(run_id), "cancel"]])
        self.assertEqual(failures, 0)
        self.assertEqual(len(slept), 1)

    def test_cancel_that_leaves_the_run_stuck_is_forced(self):
        run_id, fake, results, failures, _ = self.run_one(ignore_cancel=True)
        self.assertEqual(fake.posts(), [[str(run_id), "cancel"], [str(run_id), "force-cancel"]])
        self.assertIn("force-cancelled", results[run_id])
        self.assertEqual(failures, 0)

    def test_refused_cancel_goes_straight_to_force(self):
        run_id, fake, results, failures, _ = self.run_one(refuse_cancel=True)
        self.assertEqual(fake.posts(), [[str(run_id), "cancel"], [str(run_id), "force-cancel"]])
        self.assertIn("force-cancelled", results[run_id])
        self.assertEqual(failures, 0)

    def test_a_run_github_will_not_cancel_is_reported_not_failed(self):
        # ios-testflight.yml documents runs where GitHub rejects cancel and
        # force-cancel alike; that must not turn every sweep red.
        run_id, fake, results, failures, _ = self.run_one(refuse_cancel=True, refuse_force=True)
        self.assertIn("refused", results[run_id])
        self.assertEqual(failures, 0)

    def test_a_run_that_finished_meanwhile_is_left_alone(self):
        ghost = make_run(status="queued", age=60 * 48)
        fake = FakeGitHub({ghost["id"]: dict(ghost, status="completed")})
        results, _ = janitor.cancel_orphans(fake, orphan_plan(find([ghost], {})), sleep=lambda _: None)
        self.assertIn("skipped", results[ghost["id"]])
        self.assertEqual(fake.posts(), [])


class PlannedCancellationTests(unittest.TestCase):
    def candidate(self):
        run = make_run(status="queued")
        usage = janitor.macos_usage(mac_jobs(queued=1))
        return janitor.Candidate(run, "stale-pr", "PR is merged", usage), run

    def test_refused_cancel_is_force_cancelled_without_failing(self):
        candidate, run = self.candidate()
        fake = FakeGitHub({run["id"]: dict(run)}, refuse_cancel=[run["id"]])

        results, failures = janitor.cancel_plan(fake, [candidate])

        self.assertIn("force-cancelled", results[run["id"]])
        self.assertEqual(failures, 0)
        self.assertEqual(fake.posts(), [[str(run["id"]), "cancel"], [str(run["id"]), "force-cancel"]])

    def test_run_github_will_not_cancel_is_reported_without_failing(self):
        candidate, run = self.candidate()
        fake = FakeGitHub({run["id"]: dict(run)}, refuse_cancel=[run["id"]], refuse_force=[run["id"]])

        results, failures = janitor.cancel_plan(fake, [candidate])

        self.assertIn("stuck", results[run["id"]])
        self.assertEqual(failures, 0)

    def test_a_run_re_run_since_the_inventory_is_left_alone(self):
        candidate, run = self.candidate()
        fake = FakeGitHub({run["id"]: dict(run, run_attempt=2)})

        results, failures = janitor.cancel_plan(fake, [candidate])

        self.assertEqual(results[run["id"]], "skipped (now attempt 2)")
        self.assertEqual(failures, 0)
        self.assertEqual(fake.posts(), [])


class OrphanSweepTests(unittest.TestCase):
    def sweep(self, *args, **fake_kwargs):
        stuck = make_run(status="queued", age=340, branch="ci/macos26-app-host-repair")
        busy = make_run(status="in_progress", age=20, branch="busy")
        ghost = make_run(status="queued", age=60 * 48, name="CLA Assistant", path=".github/workflows/cla.yml",
                         event="pull_request_target", branch="old")
        sep13 = make_run(status="queued", age=60 * 24 * 11, name="CLA policy guard",
                         path=".github/workflows/cla-policy-guard.yml", event="pull_request_target", branch="older")
        runs = {r["id"]: dict(r) for r in (stuck, busy, ghost, sep13)}
        jobs = {stuck["id"]: [linux_job(age=330), orphan_job(age=220)], busy["id"]: [served_job(age=15)]}
        fake = FakeGitHub(runs, jobs, **fake_kwargs)
        with tempfile.TemporaryDirectory() as temp:
            summary = Path(temp) / "summary.md"
            argv = ["--repo", "manaflow-ai/cmux", "--summary", str(summary),
                    "--workflows-dir", str(Path(temp) / "none"), *args]
            with mock.patch.object(janitor, "GitHub", lambda token, repo, fallback_token="": fake), \
                    mock.patch.dict("os.environ", {"GH_TOKEN": "t"}), \
                    mock.patch.object(janitor.time, "sleep", lambda _: None), \
                    mock.patch.object(janitor, "utc_now", lambda: NOW), \
                    mock.patch("builtins.print"):
                code = janitor.main(argv)
            return code, fake, summary.read_text(), (stuck, ghost)

    def test_dry_run_cancels_nothing_and_reports_orphans(self):
        code, fake, text, (stuck, ghost) = self.sweep("--dry-run")
        self.assertEqual(code, 0)
        self.assertEqual(fake.posts(), [])
        self.assertIn("Orphaned runs", text)
        self.assertIn(stuck["html_url"], text)
        self.assertIn(ghost["html_url"], text)
        self.assertIn("would cancel", text)
        self.assertIn("1 run(s) still queued after", text)

    def test_live_sweep_cancels_orphans_under_their_own_cap(self):
        code, fake, text, (stuck, ghost) = self.sweep("--max-orphan-cancels", "1", "--max-cancels", "0")
        self.assertEqual(code, 0)
        # The lost assignment goes first; the ghost waits for the next sweep.
        self.assertEqual(fake.posts(), [[str(stuck["id"]), "cancel"]])
        self.assertIn("orphan cap of 1", text)

    def test_an_unreadable_run_writes_the_snapshot_and_cancels_nothing(self):
        # A full sweep cancels the ghost (test_orphan_minutes_comes_from_the_environment()); with one run's
        # job listing failing it writes the snapshot and decides nothing.
        for unreadable, posts in (((), True), (("ci/macos26-app-host-repair",), False)):
            with self.subTest(unreadable=unreadable), tempfile.TemporaryDirectory() as out:
                load = Path(out) / "load.json"
                code, fake, text, _ = self.sweep("--pool-load", str(load), unreadable_branches=unreadable)
                self.assertEqual(code, 0)
                self.assertEqual(bool(fake.posts()), posts)
                snapshot = json.loads(load.read_text())
                self.assertEqual(len(snapshot.get(janitor.UNREAD_RUNS_KEY, [])), 0 if posts else 1)
                if not posts:
                    self.assertIn("this sweep decided nothing", text)

    def test_orphan_minutes_comes_from_the_environment(self):
        with mock.patch.dict("os.environ", {"ORPHAN_MINUTES": "600"}):
            code, fake, text, (stuck, ghost) = self.sweep()
        self.assertEqual(code, 0)
        self.assertEqual(fake.posts(), [[str(ghost["id"]), "cancel"]])


class StarvedLabelSnapshotTests(unittest.TestCase):
    """The starved-label alert reads jobs main's linux-only filter skips when the run uses another branch's copy."""

    FLEET = "glaeda-side-light-xcode-26.6"
    NEXT = "feat-cmux-" + "next"

    def snapshot(self, runs, jobs, *, fail_jobs=(), completed=None, code=0):
        fake = FakeGitHub({r["id"]: dict(r) for r in runs}, jobs)
        fake.completed = dict(completed or {})
        listing_runs = fake.completed_runs

        def created_since(workflow, since):
            # GitHub applies `created>=since` to the listing; the shared fake does not.
            return [run for run in listing_runs(workflow, since)
                    if janitor.parse_time(run["created_at"]) >= janitor.parse_time(since)]

        fake.completed_runs = created_since
        if fail_jobs:
            listing = fake.jobs

            def jobs_or_fail(run_id):
                if run_id in fail_jobs:
                    raise RuntimeError(f"GET /actions/runs/{run_id}/jobs failed (503)")
                return listing(run_id)

            fake.jobs = jobs_or_fail
        with tempfile.TemporaryDirectory() as temp:
            workflows = Path(temp) / "workflows"
            workflows.mkdir()
            # Main's inert registration: no macOS text, so main reads it as linux-only.
            (workflows / "cmux-next.yml").write_text("name: cmux-next\non:\n  workflow_dispatch:\n")
            out = Path(temp) / "pool.json"
            argv = ["--repo", "manaflow-ai/cmux", "--summary", str(Path(temp) / "summary.md"), "--dry-run",
                    "--workflows-dir", str(workflows), "--pool-load", str(out)]
            with mock.patch.object(janitor, "GitHub", lambda token, repo, fallback_token="": fake), \
                    mock.patch.dict("os.environ", {"GH_TOKEN": "t"}), \
                    mock.patch.object(janitor.time, "sleep", lambda _: None), \
                    mock.patch.object(janitor, "utc_now", lambda: NOW), \
                    mock.patch("builtins.print"):
                self.assertEqual(janitor.main(argv), code)
            return (json.loads(out.read_text()) if out.exists() else None), fake

    def compile_job(self):
        return {"status": "queued", "name": "cmux-next app compile (build fleet)", "labels": [self.FLEET],
                "created_at": iso(40), "runner_name": None, "html_url": "https://example.invalid/job"}

    @staticmethod
    def listed(fake, run):
        return any(f"/runs/{run['id']}/jobs" in path for _, path in fake.log)

    def test_a_branch_run_of_a_main_linux_only_workflow_is_read_for_starved_labels(self):
        run = make_run(path=".github/workflows/cmux-next.yml", name="cmux-next", branch="lane/x")
        run["pull_requests"] = [{"number": 7, "base": {"ref": self.NEXT}}]
        pushed = make_run(event="push", path=".github/workflows/cmux-next.yml", name="cmux-next", branch=self.NEXT)
        snapshot, fake = self.snapshot([run, pushed], {run["id"]: [self.compile_job()], pushed["id"]: []})
        self.assertEqual([entry["label"] for entry in snapshot["starved"]], [self.FLEET])
        self.assertEqual(snapshot["unserved"], [self.FLEET])
        self.assertTrue(self.listed(fake, pushed))

    def test_a_dispatch_on_a_branch_follows_that_branch_copy(self):
        run = make_run(event="workflow_dispatch", path=".github/workflows/cmux-next.yml", name="cmux-next",
                       branch=self.NEXT)
        snapshot, _ = self.snapshot([run], {run["id"]: [self.compile_job()]})
        self.assertEqual([entry["label"] for entry in snapshot["starved"]], [self.FLEET])

    def test_a_failed_listing_skips_its_run_and_marks_the_snapshot_partial(self):
        # One run's listing failing (after its retries) skips that run, as any run's does: the snapshot is
        # still written, so the cascade reading it is never left without one, and it names the unread run.
        # 2026-10-26 08:08Z: one 502 ended the sweep and the snapshot went stale.
        run = make_run(path=".github/workflows/cmux-next.yml", name="cmux-next", branch="lane/x")
        run["pull_requests"] = [{"number": 7, "base": {"ref": self.NEXT}}]
        snapshot, _ = self.snapshot([run], {run["id"]: [self.compile_job()]}, fail_jobs={run["id"]})
        self.assertIs(snapshot["starved_incomplete"], True)
        self.assertEqual(snapshot[janitor.UNREAD_RUNS_KEY], [run["id"]])
        self.assertEqual(snapshot["starved"], [])

    def test_a_complete_listing_is_not_marked_incomplete(self):
        run = make_run(path=".github/workflows/cmux-next.yml", name="cmux-next", branch="lane/x")
        run["pull_requests"] = [{"number": 7, "base": {"ref": self.NEXT}}]
        snapshot, _ = self.snapshot([run], {run["id"]: [self.compile_job()]})
        self.assertNotIn("starved_incomplete", snapshot)

    def test_a_recent_start_in_a_completed_run_of_its_workflow_serves_the_label(self):
        run = make_run(path=".github/workflows/cmux-next.yml", name="cmux-next", branch="lane/x")
        run["pull_requests"] = [{"number": 7, "base": {"ref": self.NEXT}}]
        done = make_run(path=".github/workflows/cmux-next.yml", name="cmux-next", branch="lane/y",
                        status="completed", age=20)
        done.update(conclusion="success", updated_at=iso(1))
        started = {"status": "completed", "conclusion": "success", "name": "cmux-next app compile (build fleet)",
                   "labels": [self.FLEET], "created_at": iso(20), "started_at": iso(5), "completed_at": iso(1),
                   "runner_name": "mini-3"}
        snapshot, fake = self.snapshot([run], {run["id"]: [self.compile_job()], done["id"]: [started]},
                                       completed={"cmux-next.yml": [done]})
        self.assertEqual(snapshot["starved"], [])
        self.assertEqual(snapshot["unserved"], [])

    def test_an_older_completed_run_that_started_the_label_recently_serves_it(self, conclusion="success"):
        run = make_run(path=".github/workflows/cmux-next.yml", name="cmux-next", branch="lane/x")
        run["pull_requests"] = [{"number": 7, "base": {"ref": self.NEXT}}]
        done = make_run(path=".github/workflows/cmux-next.yml", name="cmux-next", branch="lane/y",
                        status="completed", age=90)
        done.update(conclusion=conclusion, updated_at=iso(1))
        started = {"status": "completed", "conclusion": conclusion, "name": "cmux-next app compile (build fleet)",
                   "labels": [self.FLEET], "created_at": iso(90), "started_at": iso(5), "completed_at": iso(1),
                   "runner_name": "mini-3"}
        snapshot, _ = self.snapshot([run], {run["id"]: [self.compile_job()], done["id"]: [started]},
                                    completed={"cmux-next.yml": [done]})
        self.assertEqual(snapshot["starved"], [])

    def test_a_cancelled_run_that_started_the_label_recently_serves_it(self):
        # A run cancelled after its fleet job started still proves a listener took the job.
        self.test_an_older_completed_run_that_started_the_label_recently_serves_it(conclusion="cancelled")

    def test_a_main_run_of_a_linux_only_workflow_is_still_not_listed(self):
        into_main = make_run(path=".github/workflows/cmux-next.yml", name="cmux-next", branch="lane/x")
        into_main["pull_requests"] = [{"number": 7, "base": {"ref": "main"}}]
        on_main = make_run(event="push", path=".github/workflows/cmux-next.yml", name="cmux-next", branch="main")
        fork = make_run(path=".github/workflows/cmux-next.yml", name="cmux-next", branch="fork-branch")
        runs = (into_main, on_main, fork)
        snapshot, fake = self.snapshot(runs, {run["id"]: [self.compile_job()] for run in runs})
        self.assertEqual(snapshot["starved"], [])
        self.assertFalse(any(self.listed(fake, run) for run in runs))


class OwnedMarkerListingSweepTests(unittest.TestCase):
    def test_only_runs_that_can_hold_a_marker_have_their_artifacts_listed(self):
        waiting = make_run(status="queued", branch="waiting")
        started = make_run(branch="started")
        rerun = make_run(status="queued", branch="rerun", attempt=2)
        runs = {r["id"]: dict(r) for r in (waiting, started, rerun)}
        queued_only = [{"status": "queued", "name": "changes", "labels": [LINUX], "created_at": iso(5)}]
        jobs = {waiting["id"]: queued_only, started["id"]: mac_jobs(queued=1), rerun["id"]: queued_only}
        fake = FakeGitHub(runs, jobs)
        with tempfile.TemporaryDirectory() as temp:
            argv = ["--repo", "manaflow-ai/cmux", "--dry-run", "--pool-load", str(Path(temp) / "load.json"),
                    "--summary", str(Path(temp) / "summary.md"), "--workflows-dir", str(Path(temp) / "none")]
            with mock.patch.object(janitor, "GitHub", lambda token, repo, fallback_token="": fake), \
                    mock.patch.dict("os.environ", {"GH_TOKEN": "t", "PR_POOL_OWNED": "1"}), \
                    mock.patch.object(janitor, "utc_now", lambda: NOW), \
                    mock.patch("builtins.print"):
                self.assertEqual(janitor.main(argv), 0)
        # Per-run listings only; the repository-wide one by name reads the previous snapshot.
        listed = {int(path.split("/")[-2]) for method, path in fake.log
                  if path.split("?")[0].endswith("/artifacts") and "/runs/" in path}
        self.assertEqual(listed, {started["id"], rerun["id"]})


class TransientFailureTests(unittest.TestCase):
    """2026-10-26 08:08Z: one 502 on a run's job listing ended the sweep before the pool snapshot was
    written, so the cascade read no snapshot and sent no job to Blacksmith."""

    def urlopen(self, failures):
        import email.message

        class Response(io.BytesIO):
            headers = email.message.Message()

        sent = []

        def urlopen(request, timeout=30):
            sent.append(request.get_method())
            if failures:
                raise failures.pop(0)
            return Response(b'{"ok": true}')
        return urlopen, sent

    def bad_gateway(self):
        import email.message
        return urllib.error.HTTPError("https://api.github.com/x", 502, "Bad Gateway", email.message.Message(), None)

    def test_a_read_is_made_again_after_a_5xx_or_a_dropped_connection(self):
        github = janitor.GitHub("t", "manaflow-ai/cmux")
        failures = [self.bad_gateway(), urllib.error.URLError("Connection reset by peer")]
        urlopen, sent = self.urlopen(failures)
        delays = []
        with mock.patch.object(janitor.urllib.request, "urlopen", urlopen), \
                mock.patch.object(janitor.time, "sleep", delays.append), mock.patch("builtins.print"):
            self.assertEqual(github.request("GET", "/repos/manaflow-ai/cmux/actions/runs/1/jobs"), {"ok": True})
        self.assertEqual(sent, ["GET"] * 3)
        self.assertEqual(delays, list(janitor.RETRY_DELAYS))

    def test_retries_are_bounded_and_writes_are_not_made_again(self):
        github = janitor.GitHub("t", "manaflow-ai/cmux")
        urlopen, sent = self.urlopen([self.bad_gateway() for _ in range(5)])
        with mock.patch.object(janitor.urllib.request, "urlopen", urlopen), \
                mock.patch.object(janitor.time, "sleep", lambda _: None), mock.patch("builtins.print"):
            with self.assertRaisesRegex(RuntimeError, r"failed \(502\)"):
                github.request("GET", "/repos/manaflow-ai/cmux/actions/runs/1/jobs")
            self.assertEqual(len(sent), len(janitor.RETRY_DELAYS) + 1)
            sent.clear()
            with self.assertRaisesRegex(RuntimeError, r"failed \(502\)"):
                github.request("POST", "/repos/manaflow-ai/cmux/actions/runs/1/rerun-failed-jobs")
            self.assertEqual(sent, ["POST"])
            # A GraphQL query only reads.
            urlopen, sent = self.urlopen([self.bad_gateway()])
            with mock.patch.object(janitor.urllib.request, "urlopen", urlopen):
                github.request("POST", "/graphql", {"query": "{ viewer { login } }"})
            self.assertEqual(sent, ["POST", "POST"])

    def test_one_unreadable_run_still_writes_the_snapshot_and_the_sweep_decides_nothing(self):
        unreadable = make_run(status="queued", branch="unreadable")
        started = make_run(branch="started")
        # A queued run so old a full sweep cancels it as an orphan.
        stuck = make_run(status="queued", age=340, branch="ci/stuck")
        runs = {r["id"]: dict(r) for r in (unreadable, started, stuck)}
        fake = FakeGitHub(runs, {unreadable["id"]: mac_jobs(queued=1), started["id"]: mac_jobs(queued=1),
                                 stuck["id"]: [linux_job(age=330), orphan_job(age=220)]})
        pending = [{"run_id": 99, "attempt": 1, "cancelled_at": iso(5)}]
        fake.snapshots = [{"generated_at": iso(10), janitor.LOST_RERUNS_KEY: pending}]
        for unreadable_ids, decides in (({unreadable["id"]}, False),):
            fake.unreadable_jobs = unreadable_ids
            fake.log.clear()
            with self.subTest(unreadable=unreadable_ids), tempfile.TemporaryDirectory() as temp:
                load = Path(temp) / "load.json"
                argv = ["--repo", "manaflow-ai/cmux", "--pool-load", str(load),
                        "--summary", str(Path(temp) / "summary.md"), "--workflows-dir", str(Path(temp) / "none")]
                with mock.patch.object(janitor, "GitHub", lambda token, repo, fallback_token="": fake), \
                        mock.patch.object(janitor, "previous_lost_reruns", lambda github: list(pending)), \
                        mock.patch.dict("os.environ", {"GH_TOKEN": "t"}), \
                        mock.patch.object(janitor.time, "sleep", lambda _: None), \
                        mock.patch.object(janitor, "utc_now", lambda: NOW), \
                        mock.patch("builtins.print"):
                    janitor.main(argv)
                snapshot = json.loads(load.read_text())
                self.assertIn("generated_at", snapshot)
                if decides:
                    self.assertNotIn(janitor.UNREAD_RUNS_KEY, snapshot)
                    self.assertTrue(any(method == "POST" for method, _ in fake.log))
                    continue
                self.assertEqual(snapshot[janitor.UNREAD_RUNS_KEY], [unreadable["id"]])
                # No cancel, re-run or orphan cancel on a partial inventory; the pending re-run waits.
                self.assertEqual([path for method, path in fake.log if method == "POST" and path != "/graphql"], [])
                self.assertEqual(snapshot[janitor.LOST_RERUNS_KEY], pending)

    def test_a_dropped_or_truncated_response_is_made_again(self):
        import http.client
        github = janitor.GitHub("t", "manaflow-ai/cmux")
        for error in (http.client.IncompleteRead(b"{"), http.client.BadStatusLine(""),
                      http.client.RemoteDisconnected("closed"), TimeoutError("timed out")):
            urlopen, sent = self.urlopen([error])
            with self.subTest(error=type(error).__name__), \
                    mock.patch.object(janitor.urllib.request, "urlopen", urlopen), \
                    mock.patch.object(janitor.time, "sleep", lambda _: None), mock.patch("builtins.print"):
                self.assertEqual(github.request("GET", "/repos/manaflow-ai/cmux/actions/runs/1/jobs"), {"ok": True})
                self.assertEqual(len(sent), 2)
        # Truncated while reading the body, not while opening it.
        import email.message

        class Truncated(io.BytesIO):
            headers = email.message.Message()

            def read(self, *args):
                raise http.client.IncompleteRead(b"{")

        calls = []

        def urlopen(request, timeout=30):
            calls.append(1)
            return Truncated(b"") if len(calls) == 1 else self.urlopen([])[0](request)
        with mock.patch.object(janitor.urllib.request, "urlopen", urlopen), \
                mock.patch.object(janitor.time, "sleep", lambda _: None), mock.patch("builtins.print"):
            self.assertEqual(github.request("GET", "/repos/manaflow-ai/cmux/actions/runs/1/jobs"), {"ok": True})
        self.assertEqual(len(calls), 2)

    def test_a_partial_inventory_asserts_no_starved_label(self):
        # The unreadable run holds the only running job on a fleet label; another run's job queued there
        # would read as starved. Nothing is asserted from a partial inventory, and nothing is closed.
        label = "glaeda-side-std-xcode-26.6"
        running = make_run(branch="running")
        waiting = make_run(status="queued", age=120, branch="waiting")
        runs = {r["id"]: dict(r) for r in (running, waiting)}
        jobs = {running["id"]: [{"status": "in_progress", "name": "compile", "labels": [label], "created_at": iso(90),
                                 "started_at": iso(1), "runner_name": "mini-1"}],
                waiting["id"]: [{"status": "queued", "name": "compile", "labels": [label], "created_at": iso(100)}]}
        fake = FakeGitHub(runs, jobs)
        fake.unreadable_jobs = {running["id"]}
        fake.completed_runs = lambda workflow, since: []
        with tempfile.TemporaryDirectory() as temp:
            load = Path(temp) / "load.json"
            argv = ["--repo", "manaflow-ai/cmux", "--dry-run", "--pool-load", str(load),
                    "--summary", str(Path(temp) / "summary.md"), "--workflows-dir", str(Path(temp) / "none")]
            with mock.patch.object(janitor, "GitHub", lambda token, repo, fallback_token="": fake), \
                    mock.patch.dict("os.environ", {"GH_TOKEN": "t"}), \
                    mock.patch.object(janitor.time, "sleep", lambda _: None), \
                    mock.patch.object(janitor, "utc_now", lambda: NOW), \
                    mock.patch("builtins.print"):
                janitor.main(argv)
            snapshot = json.loads(load.read_text())
        self.assertEqual(snapshot["starved"], [])
        self.assertIs(snapshot["starved_incomplete"], True)
        plan = janitor.starved_labels.plan_issues(snapshot["starved"], [
            {"number": 5, "title": janitor.starved_labels.issue_title(label), "updated_at": iso(60)}],
            incomplete=True)
        self.assertEqual((plan.open, plan.update, plan.close), ([], [], []))

    def test_a_rate_limit_still_ends_the_sweep(self):
        run = make_run(status="queued", branch="limited")

        class Limited(FakeGitHub):
            def jobs(self, run_id):
                raise janitor.RateLimited("GET /jobs failed (403: rate limit)")

        fake = Limited({run["id"]: dict(run)}, {})
        with self.assertRaises(janitor.RateLimited):
            janitor.read_run_jobs(fake, [run], frozenset(), NOW)
        # Nor is it swallowed as missing evidence: the starved-label evidence listing re-raises it.
        evidence = Limited({run["id"]: dict(run)}, {})
        evidence.completed_runs = lambda workflow, since: (_ for _ in ()).throw(
            janitor.RateLimited("GET /runs failed (403: rate limit)"))
        fleet = make_run(status="queued", branch="fleet")
        jobs = {fleet["id"]: [{"status": "queued", "name": "compile", "labels": ["glaeda-side-std-xcode-26.6"],
                               "created_at": iso(100)}]}
        with self.assertRaises(janitor.RateLimited):
            janitor.starved_result(evidence, [fleet], jobs, {}, now=NOW)


class RateLimitTests(unittest.TestCase):
    HEADERS = {"X-RateLimit-Limit": "15000", "X-RateLimit-Remaining": "4211", "X-RateLimit-Used": "10789",
               "X-RateLimit-Reset": "1791323880", "X-RateLimit-Resource": "core"}

    def test_headers_are_read_per_resource(self):
        self.assertEqual(janitor.read_rate_limit(self.HEADERS), ("core", {
            "limit": 15000, "remaining": 4211, "used": 10789, "reset": 1791323880}))
        self.assertEqual(janitor.read_rate_limit({"X-RateLimit-Remaining": "7"}), ("core", {"remaining": 7}))
        self.assertIsNone(janitor.read_rate_limit({}))
        self.assertIsNone(janitor.read_rate_limit(None))
        self.assertIsNone(janitor.read_rate_limit({"X-RateLimit-Remaining": "lots"}))

    def test_budget_line(self):
        line = janitor.render_rate_limits({"core": janitor.read_rate_limit(self.HEADERS)[1],
                                           "graphql": {"remaining": 4990, "limit": 5000}})
        self.assertIn("core 4211 of 15000 left, 10789 used, resets ", line)
        self.assertIn("graphql 4990 of 5000 left", line)
        self.assertIn("no rate limit headers", janitor.render_rate_limits({}))

    def response(self, headers):
        response = mock.MagicMock()
        response.headers = headers
        response.read.return_value = b"{}"
        response.__enter__.return_value = response
        return response

    def test_requests_record_the_budget_even_when_they_fail(self):
        import email.message
        import urllib.error
        github = janitor.GitHub("t", "manaflow-ai/cmux")
        with mock.patch.object(janitor.urllib.request, "urlopen", return_value=self.response(self.HEADERS)):
            github.request("GET", "/repos/manaflow-ai/cmux/actions/runs")
        self.assertEqual(github.rate_limits["core"]["remaining"], 4211)
        headers = email.message.Message()
        for key, value in dict(self.HEADERS, **{"X-RateLimit-Remaining": "0"}).items():
            headers[key] = value
        error = urllib.error.HTTPError("https://api.github.com/x", 403, "rate limited", headers, None)
        with mock.patch.object(janitor.urllib.request, "urlopen", side_effect=error):
            with self.assertRaises(RuntimeError):
                github.request("GET", "/repos/manaflow-ai/cmux/actions/runs")
        self.assertEqual(github.rate_limits["core"]["remaining"], 0)

    def test_a_refused_app_token_hands_the_sweep_to_the_workflow_token(self):
        github = janitor.GitHub("app", "manaflow-ai/cmux", fallback_token="workflow")
        sent = []

        class Response(io.BytesIO):
            headers = email.message.Message()

        def urlopen(request, timeout=30):
            sent.append(request.get_header("Authorization"))
            if request.get_header("Authorization") == "Bearer app":
                raise urllib.error.HTTPError(request.full_url, 403, "rate limited", email.message.Message(), None)
            return Response(b"{}")

        with mock.patch.object(janitor.urllib.request, "urlopen", urlopen), mock.patch("builtins.print"):
            github.request("GET", "/repos/manaflow-ai/cmux/actions/runs")
            github.request("POST", "/repos/manaflow-ai/cmux/actions/runs/1/cancel")
        self.assertEqual(sent, ["Bearer app", "Bearer workflow", "Bearer workflow"])
        # The snapshot download (previous_lost_reruns()) follows the handover too.
        with mock.patch.object(janitor, "PoolClient") as pool_client:
            github.download({"archive_download_url": "https://example.invalid/0"})
        self.assertEqual(pool_client.call_args.args[0], "workflow")
        # Without a fallback the refusal is still an error.
        github = janitor.GitHub("app", "manaflow-ai/cmux")
        with mock.patch.object(janitor.urllib.request, "urlopen", urlopen), self.assertRaises(RuntimeError):
            github.request("GET", "/repos/manaflow-ai/cmux/actions/runs")

    def test_an_app_out_of_budget_stops_the_sweep_instead_of_spending_the_workflow_token(self):
        import email.message
        import urllib.error
        github = janitor.GitHub("app", "manaflow-ai/cmux", fallback_token="workflow")
        sent = []
        limited = email.message.Message()
        limited["X-RateLimit-Remaining"] = "0"

        def urlopen(request, timeout=30):
            sent.append(request.get_header("Authorization"))
            raise urllib.error.HTTPError(request.full_url, 403, "rate limited", limited, None)

        with mock.patch.object(janitor.urllib.request, "urlopen", urlopen), self.assertRaises(RuntimeError):
            github.request("GET", "/repos/manaflow-ai/cmux/actions/runs")
        self.assertEqual(sent, ["Bearer app"])
        # A secondary limit says so in its body.
        body = io.BytesIO(b'{"message": "You have exceeded a secondary rate limit."}')
        sent.clear()

        def secondary(request, timeout=30):
            sent.append(request.get_header("Authorization"))
            raise urllib.error.HTTPError(request.full_url, 403, "Forbidden", email.message.Message(), body)

        with mock.patch.object(janitor.urllib.request, "urlopen", secondary), self.assertRaises(RuntimeError):
            github.request("GET", "/repos/manaflow-ai/cmux/actions/runs")
        self.assertEqual(sent, ["Bearer app"])

    def test_sweep_summary_reports_the_budget(self):
        fake = FakeGitHub({})
        fake.rate_limits["core"] = {"remaining": 900, "limit": 15000, "used": 14100}
        with tempfile.TemporaryDirectory() as temp:
            summary = Path(temp) / "summary.md"
            argv = ["--repo", "manaflow-ai/cmux", "--dry-run", "--summary", str(summary),
                    "--workflows-dir", str(Path(temp) / "none")]
            with mock.patch.object(janitor, "GitHub", lambda token, repo, fallback_token="": fake), \
                    mock.patch.dict("os.environ", {"GH_TOKEN": "t"}), \
                    mock.patch.object(janitor, "utc_now", lambda: NOW), \
                    mock.patch("builtins.print"):
                self.assertEqual(janitor.main(argv), 0)
            self.assertIn("core 900 of 15000 left, 14100 used", summary.read_text())


# ---------------------------------------------------------------------------
# Category e: lost runner assignments (a queued job its pool skipped).
# ---------------------------------------------------------------------------

SIDE = "glaeda-side-std-xcode-26.6"
PIN_BRANCH = "cmux-tui-pin-c59ca5471ad6"


def unassigned_job(*, age=40, label=SIDE, runner_id=None, runner_name=None, name="macos / side lane"):
    """A job GitHub shows queued with no runner (runner_id null or 0)."""
    return {"status": "queued", "name": name, "labels": [label] if isinstance(label, str) else list(label),
            "created_at": iso(age), "started_at": iso(age), "runner_id": runner_id, "runner_name": runner_name}


def started_job(*, age=20, label=SIDE, status="in_progress", runner_id=77, conclusion="success"):
    """A job the pool's runners took: running, or finished after running."""
    job = {"status": status, "name": "macos / side lane", "labels": [label] if isinstance(label, str) else list(label),
           "created_at": iso(age), "started_at": iso(age - 1), "runner_id": runner_id,
           "runner_name": f"mini-{runner_id}-side"}
    if status == "completed":
        job.update(conclusion=conclusion, completed_at=iso(max(0, age - 3)))
    return job


def lost_world(*, age=40, event="push", branch=PIN_BRANCH, sha="aaa", evidence=True, evidence_age=None,
               evidence_label=SIDE, attempt=1, actor="leo", lost=None, siblings=()):
    """A run with one lost job, and another run whose newer same-label job started."""
    stuck = make_run(event=event, branch=branch, sha=sha, status="queued", age=age + 1, attempt=attempt,
                     name="cmux-tui", path=".github/workflows/cmux-tui.yml")
    stuck["triggering_actor"] = {"login": actor}
    other = make_run(event="push", branch="other-pin", status="in_progress", age=age, name="cmux-tui",
                     path=".github/workflows/cmux-tui.yml")
    jobs = {stuck["id"]: [lost or unassigned_job(age=age), *siblings], other["id"]: []}
    if evidence:
        jobs[other["id"]].append(started_job(age=evidence_age if evidence_age is not None else age - 5,
                                             label=evidence_label))
    return stuck, other, jobs


def decision_for(result, run):
    found = [d for d in result.decisions if d.candidate.run["id"] == run["id"]]
    return found[0] if found else None


class LostJobDetectionTests(unittest.TestCase):
    def test_runner_id_zero_and_null_both_count_but_an_assigned_runner_does_not(self):
        for runner_id in (None, 0):
            with self.subTest(runner_id=runner_id):
                self.assertTrue(janitor.unassigned(unassigned_job(runner_id=runner_id)))
        self.assertFalse(janitor.unassigned(unassigned_job(runner_name="mini-3-side")))
        self.assertFalse(janitor.unassigned(unassigned_job(runner_id=12)))
        self.assertFalse(janitor.unassigned(dict(unassigned_job(), status="waiting")))
        self.assertFalse(janitor.unassigned(dict(unassigned_job(), labels=[])))

    def test_started_means_a_runner_took_it(self):
        self.assertTrue(janitor.took_runner(started_job()))
        self.assertTrue(janitor.took_runner(started_job(status="completed")))
        # A job cancelled while still queued keeps a started_at but never had a runner.
        cancelled = dict(started_job(status="completed", conclusion="cancelled"), runner_id=0, runner_name=None)
        self.assertFalse(janitor.took_runner(cancelled))
        self.assertFalse(janitor.took_runner(unassigned_job()))

    def test_evidence_is_a_later_job_on_the_identical_label_set_that_started(self):
        job = unassigned_job(age=40)
        since = janitor.parse_time(job["created_at"])
        self.assertEqual(janitor.skipped_by_pool(job, since, [started_job(age=35)]), 1)
        # Created earlier: the pool served its queue in order.
        self.assertEqual(janitor.skipped_by_pool(job, since, [started_job(age=45)]), 0)
        # Another label set, a superset or a subset is another pool.
        self.assertEqual(janitor.skipped_by_pool(job, since, [started_job(age=35, label=MAC)]), 0)
        self.assertEqual(janitor.skipped_by_pool(job, since, [started_job(age=35, label=[SIDE, "glaeda-ios-sim"])]), 0)
        # Label case does not make another pool.
        self.assertEqual(janitor.skipped_by_pool(job, since, [started_job(age=35, label=SIDE.upper())]), 1)
        # Still queued is no evidence.
        self.assertEqual(janitor.skipped_by_pool(job, since, [unassigned_job(age=35)]), 0)

    def test_wait_starts_when_the_runs_last_other_job_finished(self):
        # A job record can exist before its needs finished; the wait starts when it could run.
        job = unassigned_job(age=60)
        gate = started_job(age=60, status="completed", label=LINUX)
        gate["completed_at"] = iso(20)
        self.assertEqual(janitor.lost_wait_start(job, [job, gate]), janitor.parse_time(iso(20)))
        self.assertEqual(janitor.lost_wait_start(job, [job]), janitor.parse_time(iso(60)))

    def test_a_gated_job_is_not_lost_before_it_could_run_for_thirty_minutes(self):
        gate = started_job(age=60, status="completed", label=LINUX)
        gate["completed_at"] = iso(20)
        stuck, other, jobs = lost_world(age=60, evidence_age=15, siblings=[gate])
        self.assertEqual(janitor.find_lost([stuck, other], jobs, now=NOW), {})


class LostAssignmentPlanTests(unittest.TestCase):
    def test_lost_job_on_a_pin_push_branch_without_a_pr_is_cancelled(self):
        # Run 39631559018: job 119450713364 on glaeda-side-std-xcode-26.6 sat queued 80+ minutes.
        stuck, other, jobs = lost_world(age=85)
        result = plan([stuck, other], jobs, {PIN_BRANCH: [], "other-pin": []})
        decision = decision_for(result, stuck)
        self.assertEqual((decision.action, decision.candidate.category), ("cancel", "lost"))
        self.assertFalse(decision.candidate.rerun)
        self.assertIn("no open pull request", decision.candidate.reason)
        self.assertIsNone(decision_for(result, other))
        # Not gated on a backed-up pool: one queued job is far under the threshold.
        self.assertFalse(result.over_threshold)

    def test_pr_23694_swift_test_on_the_gui_pool_is_lost_at_the_open_pr_head(self):
        # Run 39667716636 attempt 1 (PR #23694, head f4090b079d), the same pattern as job 119450713364:
        # job 119458409272 `cmux-next swift test` on exactly glaeda-gui-std-xcode-26.6, created 20:11:17Z,
        # never assigned, while newer gui-std jobs started (22:51Z, 23:07Z). Its wait starts when the
        # run's last other job finished (Release compile, 22:33:32Z), so it is lost from 23:03:32Z.
        gui = "glaeda-gui-std-xcode-26.6"
        sha = "f4090b079dafb116fcd800023aef9ca1e1007f9d"
        now = dt.datetime(2026, 10, 21, 23, 10, tzinfo=dt.timezone.utc)

        def job(name, label, created, started=None, completed=None, conclusion=None, runner=None):
            status = "completed" if completed else ("in_progress" if runner else "queued")
            return {"name": name, "labels": [label], "status": status, "conclusion": conclusion,
                    "created_at": created, "started_at": started or created, "completed_at": completed,
                    "runner_id": runner or 0, "runner_name": f"runner-{runner}" if runner else None}

        def world(sibling_conclusion):
            run = {"id": 39667716636, "event": "pull_request", "status": "queued", "run_attempt": 1,
                   "head_branch": "launch-frame/restore-first-frame", "head_sha": sha,
                   "path": ".github/workflows/cmux-next.yml", "name": "cmux-next",
                   "created_at": "2026-10-21T20:08:33Z", "triggering_actor": {"login": "teamleaderleo"},
                   "head_repository": {"full_name": "manaflow-ai/cmux", "owner": {"login": "manaflow-ai"}},
                   "pull_requests": [{"number": 23694}]}
            jobs = [
                job("cmux-next checks (god files, concurrency, crash safety, l10n)", LINUX, "2026-10-21T20:08:34Z",
                    "2026-10-21T20:08:44Z", "2026-10-21T20:11:58Z", sibling_conclusion, 3258772),
                job("cmux-next web bundles (source-keyed cache)", LINUX, "2026-10-21T20:09:06Z",
                    "2026-10-21T20:09:10Z", "2026-10-21T20:11:17Z", "success", 3258992),
                job("cmux-next Release compile (Xcode 26)", SIDE, "2026-10-21T20:09:22Z",
                    "2026-10-21T22:23:49Z", "2026-10-21T22:33:32Z", "success", 1249742),
                job("cmux-next generated files", "glaeda-session-std-xcode-26.6", "2026-10-21T20:11:17Z",
                    "2026-10-21T20:13:06Z", "2026-10-21T20:13:18Z", sibling_conclusion, 2782319),
                job("cmux-next swift test", gui, "2026-10-21T20:11:17Z"),
            ]
            other = make_run(branch="another-pr", sha="ccc", path=".github/workflows/cmux-next.yml",
                             name="cmux-next")
            served = [job("cmux-next swift test", gui, "2026-10-21T22:20:00Z", "2026-10-21T22:26:00Z",
                          "2026-10-21T22:40:00Z", "success", 11),
                      job("cmux-next swift test", gui, "2026-10-21T22:46:00Z", "2026-10-21T22:51:00Z",
                          "2026-10-21T23:05:00Z", "success", 12),
                      job("cmux-next swift test", gui, "2026-10-21T23:01:00Z", "2026-10-21T23:07:00Z", runner=13)]
            return run, other, {run["id"]: jobs, other["id"]: served}

        pr = make_pr(23694, head=sha)
        for sibling_conclusion, rerun in (("failure", False), ("success", True)):
            with self.subTest(sibling_conclusion=sibling_conclusion):
                run, other, jobs = world(sibling_conclusion)
                lost = janitor.find_lost([run, other], jobs, now=now)
                self.assertEqual(lost[run["id"]].job_name, "cmux-next swift test")
                self.assertEqual(lost[run["id"]].labels, gui)
                # 22:26Z was created before the wait began; 22:51Z and 23:07Z are the evidence.
                self.assertEqual(lost[run["id"]].skipped, 2)
                result = janitor.build_plan([run, other], jobs, {run["head_branch"]: [pr], "another-pr": []},
                                            threshold=6, max_cancels=10, pull_request_policy="compile-only",
                                            now=now)
                decision = decision_for(result, run)
                self.assertEqual((decision.action, decision.candidate.category), ("cancel", "lost"))
                self.assertIn("PR #23694", decision.candidate.reason)
                # As it happened, two other jobs had already failed, so it is cancelled but not re-run;
                # a run with no failure is re-run once.
                self.assertEqual(decision.candidate.rerun, rerun)
        # Before 23:03:32Z it had not waited 30 minutes since it could run.
        run, other, jobs = world("success")
        self.assertEqual(janitor.find_lost([run, other], jobs, now=now - dt.timedelta(minutes=7)), {})

    def test_a_job_younger_than_thirty_minutes_is_left_alone(self):
        stuck, other, jobs = lost_world(age=25, evidence_age=20)
        self.assertEqual(plan([stuck, other], jobs, {PIN_BRANCH: []}).decisions, [])

    def test_a_backed_up_pool_is_not_a_lost_assignment(self):
        # Queued two hours, but every newer job on its labels still queues too,
        # and the one that started was created before it.
        stuck, other, jobs = lost_world(age=120, evidence=False)
        jobs[other["id"]] = [unassigned_job(age=100), unassigned_job(age=60), started_job(age=130)]
        result = plan([stuck, other], jobs, {PIN_BRANCH: [], "other-pin": []})
        self.assertIsNone(decision_for(result, stuck))

    def test_a_later_job_on_other_labels_is_not_evidence(self):
        stuck, other, jobs = lost_world(age=85, evidence_label=MAC)
        self.assertIsNone(decision_for(plan([stuck, other], jobs, {PIN_BRANCH: []}), stuck))

    def test_an_assigned_runner_is_not_lost(self):
        stuck, other, jobs = lost_world(age=85, lost=unassigned_job(age=85, runner_name="mini-3-side"))
        self.assertIsNone(decision_for(plan([stuck, other], jobs, {PIN_BRANCH: []}), stuck))
        for runner_id in (None, 0):
            with self.subTest(runner_id=runner_id):
                stuck, other, jobs = lost_world(age=85, lost=unassigned_job(age=85, runner_id=runner_id))
                self.assertEqual(decision_for(plan([stuck, other], jobs, {PIN_BRANCH: []}), stuck).action,
                                 "cancel")

    def test_evidence_from_a_completed_run_the_sweep_fetched_for_it(self):
        stuck, other, jobs = lost_world(age=85, evidence=False)
        evidence = {999: [started_job(age=50, status="completed")]}
        result = janitor.build_plan([stuck], {stuck["id"]: jobs[stuck["id"]]}, {PIN_BRANCH: []},
                                    threshold=6, max_cancels=10, pull_request_policy="compile-only", now=NOW,
                                    evidence_jobs=evidence)
        self.assertEqual(decision_for(result, stuck).action, "cancel")

    def test_an_unlooked_up_branch_is_left_alone(self):
        stuck, other, jobs = lost_world(age=85)
        self.assertIsNone(decision_for(plan([stuck, other], jobs, {}), stuck))

    def test_superseded_or_closed_pr_run_is_cancelled_without_a_rerun(self):
        for pr in (make_pr(5, head="bbb"), make_pr(5, state="CLOSED"), make_pr(5, state="MERGED")):
            with self.subTest(state=pr["state"], head=pr["headRefOid"]):
                stuck, other, jobs = lost_world(age=85, event="pull_request", branch="feature", sha="aaa")
                decision = decision_for(plan([stuck, other], jobs, {"feature": [pr]}), stuck)
                self.assertEqual((decision.action, decision.candidate.category), ("cancel", "lost"))
                self.assertFalse(decision.candidate.rerun)

    def test_push_run_whose_branch_pr_moved_on_is_cancelled_without_a_rerun(self):
        stuck, other, jobs = lost_world(age=85, branch="feature", sha="aaa")
        decision = decision_for(plan([stuck, other], jobs, {"feature": [make_pr(5, head="bbb")]}), stuck)
        self.assertEqual(decision.action, "cancel")
        self.assertFalse(decision.candidate.rerun)

    def test_current_head_of_an_open_pr_is_cancelled_for_a_rerun(self):
        for event in ("pull_request", "push"):
            with self.subTest(event=event):
                stuck, other, jobs = lost_world(age=85, event=event, branch="feature", sha="aaa")
                decision = decision_for(plan([stuck, other], jobs, {"feature": [make_pr(5)]}), stuck)
                self.assertEqual((decision.action, decision.candidate.category), ("cancel", "lost"))
                self.assertTrue(decision.candidate.rerun)
                self.assertIn("PR #5", decision.candidate.reason)

    def test_a_job_behind_an_unfinished_sibling_is_not_lost_at_any_head(self):
        # The job may be queued behind a gate that is still building, waiting, or itself queued in a
        # backed-up pool (no evidence on its labels): its wait has not begun, stale run or not.
        backed_up_gate = unassigned_job(age=90, label=MAC, name="macos / gate")
        gates = {"building": started_job(age=90, label=LINUX), "backed-up": backed_up_gate,
                 "waiting": dict(unassigned_job(age=90, label=LINUX), status="waiting"),
                 "pending": dict(unassigned_job(age=90, label=LINUX), status="pending")}
        for name, gate in gates.items():
            for event, branch, prs in (("push", PIN_BRANCH, []), ("pull_request", "feature", [make_pr(5)]),
                                       ("pull_request", "feature", [make_pr(5, head="bbb")])):
                with self.subTest(gate=name, event=event, head=prs and prs[0]["headRefOid"]):
                    stuck, other, jobs = lost_world(age=85, event=event, branch=branch, siblings=[gate])
                    self.assertEqual(janitor.find_lost([stuck, other], jobs, now=NOW), {})
                    # A superseded run may still go as stale-pr (b), on its own terms; never as lost.
                    decision = decision_for(plan([stuck, other], jobs, {branch: prs}), stuck)
                    self.assertTrue(decision is None or decision.candidate.category != "lost")
        # A sibling that is still running needs no evidence listing either.
        stuck, other, jobs = lost_world(age=85, evidence=False, siblings=[started_job(age=90, label=LINUX)])
        self.assertEqual(janitor.evidence_queries([stuck, other], jobs, now=NOW), [])

    def test_two_lost_jobs_do_not_mask_each_other(self):
        # A sibling that is itself unassigned, overdue and skipped by its own pool is no gate.
        stuck, other, jobs = lost_world(age=85, siblings=[unassigned_job(age=80, label=MAC, name="macos / other")])
        jobs[other["id"]].append(started_job(age=50, label=MAC))
        lost = janitor.find_lost([stuck, other], jobs, now=NOW)
        self.assertEqual(lost[stuck["id"]].job_name, "macos / side lane")
        self.assertEqual(decision_for(plan([stuck, other], jobs, {PIN_BRANCH: []}), stuck).action, "cancel")

    def test_a_run_that_already_failed_is_cancelled_without_a_rerun(self):
        failed = started_job(age=90, status="completed", label=LINUX, conclusion="failure")
        failed["completed_at"] = iso(87)
        stuck, other, jobs = lost_world(age=85, event="pull_request", branch="feature", siblings=[failed])
        decision = decision_for(plan([stuck, other], jobs, {"feature": [make_pr(5)]}), stuck)
        self.assertEqual(decision.action, "cancel")
        self.assertFalse(decision.candidate.rerun)

    def test_a_bot_re_run_at_the_pr_head_is_left_to_the_rescue_and_the_orphan_pass(self):
        for actor in ("github-actions[bot]", "cmux-bot[bot]"):
            with self.subTest(actor=actor):
                stuck, other, jobs = lost_world(age=85, event="pull_request", branch="feature", attempt=2,
                                                actor=actor)
                decision = decision_for(plan([stuck, other], jobs, {"feature": [make_pr(5)]}), stuck)
                self.assertEqual(decision.action, "skip")
                self.assertIn("bot", decision.note)
                # Nobody reads a superseded bot re-run, so that one still goes.
                stuck, other, jobs = lost_world(age=85, event="pull_request", branch="feature", attempt=2,
                                                actor=actor)
                decision = decision_for(plan([stuck, other], jobs, {"feature": [make_pr(5, head="bbb")]}), stuck)
                self.assertEqual(decision.action, "cancel")
                self.assertFalse(decision.candidate.rerun)
        # A person's re-run is theirs to ask for again.
        stuck, other, jobs = lost_world(age=85, event="pull_request", branch="feature", attempt=2, actor="leo")
        self.assertTrue(decision_for(plan([stuck, other], jobs, {"feature": [make_pr(5)]}), stuck)
                        .candidate.rerun)

    def test_a_newer_run_at_the_same_head_takes_over_so_the_cancel_asks_for_no_rerun(self):
        # A `labeled` run queued behind the lost run in ci.yml's concurrency group: re-running the
        # old one would replay `synchronize` with cancel-in-progress and kill the newer one.
        for newer_path in (".github/workflows/ci.yml", ".github/workflows/cmux-tui.yml"):
            with self.subTest(newer_path=newer_path):
                stuck, other, jobs = lost_world(age=85, event="pull_request", branch="feature")
                stuck.update(path=newer_path, name="CI" if newer_path.endswith("ci.yml") else "cmux-tui")
                newer = make_run(event="pull_request", branch="feature", sha="aaa", status="pending", age=20,
                                 path=newer_path)
                decision = decision_for(plan([stuck, other, newer], jobs, {"feature": [make_pr(5)]}), stuck)
                self.assertEqual((decision.action, decision.candidate.category), ("cancel", "lost"))
                self.assertFalse(decision.candidate.rerun)
                self.assertIn(str(newer["id"]), decision.candidate.reason)

    def test_without_re_run_state_the_current_head_is_left_alone(self):
        stuck, other, jobs = lost_world(age=85, event="pull_request", branch="feature")
        result = janitor.build_plan([stuck, other], jobs, {"feature": [make_pr(5)]}, threshold=6, max_cancels=10,
                                    pull_request_policy="compile-only", now=NOW, rerun_state=False)
        decision = decision_for(result, stuck)
        self.assertEqual(decision.action, "skip")
        self.assertIn("re-run", decision.note)

    def test_never_candidates_are_never_touched(self):
        for event, branch, name, path in (
                ("push", "main", "CI", ".github/workflows/ci.yml"),
                ("push", "feat-cmux-next", "CI", ".github/workflows/ci.yml"),
                ("merge_group", "gh-readonly-queue/main/pr-1-abc", "CI", ".github/workflows/ci.yml"),
                ("schedule", "main", "Some check", ".github/workflows/check.yml"),
                ("workflow_dispatch", "main", "CI", ".github/workflows/ci.yml"),
                ("push", "v0.64.0", "Release", ".github/workflows/release.yml"),
                ("push", "nightly-next", "Nightly macOS build", ".github/workflows/nightly.yml")):
            with self.subTest(event=event, branch=branch):
                stuck, other, jobs = lost_world(age=85, event=event, branch=branch)
                stuck.update(name=name, path=path)
                result = plan([stuck, other], jobs, {branch: []})
                self.assertIsNone(decision_for(result, stuck))

    def test_no_janitor_label_is_honoured_like_an_orphan(self):
        for pr in (make_pr(5, labels=("no-janitor",)), make_pr(5, labels_truncated=True),
                   make_pr(5, head="bbb", labels=("no-janitor",))):
            with self.subTest(labels=pr["labels"]):
                stuck, other, jobs = lost_world(age=85, event="pull_request", branch="feature")
                decision = decision_for(plan([stuck, other], jobs, {"feature": [pr]}), stuck)
                self.assertEqual(decision.action, "skip")

    def test_the_shared_cancel_cap_is_respected(self):
        runs, jobs, prs = [], {}, {}
        for index in range(3):
            stuck, other, world = lost_world(age=85 + index, branch=f"pin-{index}")
            runs += [stuck, other]
            jobs.update(world)
            prs[f"pin-{index}"] = []
        merged = make_run(branch="merged-branch", age=10)
        runs.append(merged)
        jobs[merged["id"]] = mac_jobs(running=1)
        prs["merged-branch"] = [make_pr(9, state="MERGED")]
        result = plan(runs, jobs, prs, max_cancels=2)
        actions = [d.action for d in result.decisions]
        self.assertEqual(actions.count("cancel"), 2)
        self.assertEqual(actions.count("skip"), 2)
        self.assertTrue(all("cap of 2" in d.note for d in result.decisions if d.action == "skip"))

    def test_lost_wins_over_stale_pr_so_a_re_run_never_waits_for_pressure(self):
        stuck, other, jobs = lost_world(age=85, event="pull_request", branch="feature", attempt=2, actor="leo")
        decision = decision_for(plan([stuck, other], jobs, {"feature": [make_pr(5, head="bbb")]}), stuck)
        self.assertEqual((decision.action, decision.candidate.category), ("cancel", "lost"))

    def test_lost_branches_join_the_pull_request_lookup(self):
        stuck, other, jobs = lost_world(age=85)
        lost = janitor.find_lost([stuck, other], jobs, now=NOW)
        self.assertEqual(sorted(lost), [stuck["id"]])
        self.assertEqual(janitor.lost_branches([stuck, other], lost, []), [PIN_BRANCH])
        self.assertEqual(janitor.lost_branches([], {}, [{"branch": "feature"}]), ["feature"])


class LostEvidenceFetchTests(unittest.TestCase):
    def test_suspects_without_evidence_name_their_workflow_and_wait_start(self):
        stuck, other, jobs = lost_world(age=85, evidence=False)
        self.assertEqual(janitor.evidence_queries([stuck, other], jobs, now=NOW), [("cmux-tui.yml", iso(85))])
        # Evidence already in the inventory needs no extra listing.
        stuck, other, jobs = lost_world(age=85)
        self.assertEqual(janitor.evidence_queries([stuck, other], jobs, now=NOW), [])
        # Too young, or protected, needs none either.
        stuck, other, jobs = lost_world(age=20, evidence=False)
        self.assertEqual(janitor.evidence_queries([stuck, other], jobs, now=NOW), [])
        stuck, other, jobs = lost_world(age=85, evidence=False, branch="main")
        self.assertEqual(janitor.evidence_queries([stuck, other], jobs, now=NOW), [])

    def test_evidence_runs_are_capped_and_skip_known_or_unstarted_runs(self):
        listed = [dict(make_run(status="completed"), conclusion=conclusion)
                  for conclusion in ("success", "cancelled", "failure", "success", "skipped")]
        chosen = janitor.evidence_runs(listed, known={listed[0]["id"]}, cap=2)
        self.assertEqual([run["id"] for run in chosen], [listed[2]["id"], listed[3]["id"]])

    def test_a_sweep_lists_completed_runs_for_evidence_within_its_cap(self):
        stuck, other, jobs = lost_world(age=85, evidence=False)
        done = [dict(make_run(status="completed", age=60 - index), conclusion="success") for index in range(4)]
        fake = FakeGitHub({stuck["id"]: dict(stuck)}, {stuck["id"]: jobs[stuck["id"]],
                                                      done[0]["id"]: [started_job(age=60, status="completed")]})
        fake.completed["cmux-tui.yml"] = done
        fake.prs[PIN_BRANCH] = []
        with tempfile.TemporaryDirectory() as temp:
            argv = ["--repo", "manaflow-ai/cmux", "--summary", str(Path(temp) / "s.md"),
                    "--workflows-dir", str(Path(temp) / "none")]
            with mock.patch.object(janitor, "GitHub", lambda token, repo, fallback_token="": fake), \
                    mock.patch.dict("os.environ", {"GH_TOKEN": "t"}), \
                    mock.patch.object(janitor.time, "sleep", lambda _: None), \
                    mock.patch.object(janitor, "utc_now", lambda: NOW), \
                    mock.patch("builtins.print"):
                self.assertEqual(janitor.main(argv), 0)
        listed_jobs = [path for method, path in fake.log if path.split("?")[0].endswith("/jobs")]
        self.assertEqual(len(listed_jobs), 1 + janitor.LOST_EVIDENCE_RUNS_PER_WORKFLOW)
        self.assertEqual(fake.posts(), [[str(stuck["id"]), "cancel"]])


def pending_entry(run, *, attempt=1, age=10):
    return {"run_id": run["id"], "attempt": attempt, "head_sha": run["head_sha"], "branch": run["head_branch"],
            "cancelled_at": iso(age)}


class LostRerunPlanTests(unittest.TestCase):
    def cancelled(self, *, event="pull_request", attempt=1, conclusion="cancelled", status="completed"):
        run = make_run(event=event, branch="feature", sha="aaa", status=status, attempt=attempt)
        run["conclusion"] = conclusion
        return run

    def test_cancelled_run_still_at_the_open_pr_head_is_re_run(self):
        run = self.cancelled()
        decisions = janitor.plan_lost_reruns([pending_entry(run)], {run["id"]: run}, {"feature": [make_pr(5)]},
                                             now=NOW, head_runs={run["id"]: []})
        self.assertEqual([d.action for d in decisions], ["rerun"])

    def test_a_cancel_that_has_not_settled_is_kept_for_the_next_sweep(self):
        run = self.cancelled(status="in_progress", conclusion=None)
        decisions = janitor.plan_lost_reruns([pending_entry(run)], {run["id"]: run}, {"feature": [make_pr(5)]},
                                             now=NOW, head_runs={run["id"]: []})
        self.assertEqual([d.action for d in decisions], ["keep"])

    def test_a_moved_closed_or_opted_out_pr_is_never_re_run(self):
        for pr in (make_pr(5, head="bbb"), make_pr(5, state="CLOSED"), make_pr(5, labels=("no-janitor",))):
            with self.subTest(pr=pr["state"]):
                run = self.cancelled()
                decisions = janitor.plan_lost_reruns([pending_entry(run)], {run["id"]: run}, {"feature": [pr]},
                                                     now=NOW, head_runs={run["id"]: []})
                self.assertEqual([d.action for d in decisions], ["drop"])

    def test_someone_elses_re_run_or_another_conclusion_drops_it(self):
        rerun = self.cancelled(attempt=2, status="in_progress", conclusion=None)
        finished = self.cancelled(conclusion="success")
        decisions = janitor.plan_lost_reruns(
            [pending_entry(rerun), pending_entry(finished)], {rerun["id"]: rerun, finished["id"]: finished},
            {"feature": [make_pr(5)]}, now=NOW, head_runs={rerun["id"]: [], finished["id"]: []})
        self.assertEqual([d.action for d in decisions], ["drop", "drop"])

    def test_an_unreadable_run_is_kept_and_an_old_entry_expires(self):
        run = self.cancelled()
        decisions = janitor.plan_lost_reruns([pending_entry(run), pending_entry(run, age=60 * 7)], {},
                                             {"feature": [make_pr(5)]}, now=NOW, head_runs={})
        self.assertEqual([d.action for d in decisions], ["keep", "drop"])

    def test_a_newer_run_at_the_head_drops_the_re_run(self):
        run = self.cancelled()
        newer = make_run(branch="feature", sha="aaa", status="completed")
        newer["conclusion"] = "success"
        decisions = janitor.plan_lost_reruns([pending_entry(run)], {run["id"]: run}, {"feature": [make_pr(5)]},
                                             now=NOW, head_runs={run["id"]: [run, newer]})
        self.assertEqual([d.action for d in decisions], ["drop"])
        self.assertIn(str(newer["id"]), decisions[0].note)
        # A newer run that was cancelled took nothing over; another branch, head, workflow or event is
        # not this run's.
        cancelled = dict(newer, conclusion="cancelled")
        unrelated = [make_run(branch="other", sha="aaa", status="queued"),
                     make_run(branch="feature", sha="bbb", status="queued"),
                     make_run(branch="feature", sha="aaa", path=".github/workflows/other.yml", status="queued"),
                     make_run(event="push", branch="feature", sha="aaa", status="queued")]
        decisions = janitor.plan_lost_reruns([pending_entry(run)], {run["id"]: run}, {"feature": [make_pr(5)]},
                                             now=NOW, head_runs={run["id"]: [cancelled, *unrelated]})
        self.assertEqual([d.action for d in decisions], ["rerun"])
        # Not listed this sweep: unknown, so kept.
        decisions = janitor.plan_lost_reruns([pending_entry(run)], {run["id"]: run}, {"feature": [make_pr(5)]},
                                             now=NOW, head_runs={})
        self.assertEqual([d.action for d in decisions], ["keep"])

    def test_new_pending_entries_come_only_from_cancels_that_took(self):
        runs = [make_run(branch=f"b{index}") for index in range(4)]
        usage = janitor.macos_usage([])
        candidates = [janitor.Candidate(runs[0], "lost", "r", usage, rerun=True),
                      janitor.Candidate(runs[1], "lost", "r", usage, rerun=True),
                      janitor.Candidate(runs[2], "lost", "r", usage, rerun=False),
                      janitor.Candidate(runs[3], "lost", "r", usage, rerun=True)]
        results = {runs[0]["id"]: "cancelled", runs[1]["id"]: "skipped (head changed)",
                   runs[2]["id"]: "cancelled", runs[3]["id"]: "force-cancelled (cancel refused: x)"}
        entries = janitor.new_lost_reruns(candidates, results, now=NOW)
        self.assertEqual([entry["run_id"] for entry in entries], [runs[0]["id"], runs[3]["id"]])
        self.assertEqual(entries[0]["attempt"], 1)


class LostAssignmentSweepTests(unittest.TestCase):
    """Sweeps of main() carrying the re-run through the pool snapshot: cancel, re-run once, never again."""

    def sweep(self, fake, temp, *args):
        load = Path(temp) / "load.json"
        summary = Path(temp) / "s.md"
        summary.write_text("")
        argv = ["--repo", "manaflow-ai/cmux", "--pool-load", str(load), "--summary", str(summary),
                "--workflows-dir", str(Path(temp) / "none"), *args]
        with mock.patch.object(janitor, "GitHub", lambda token, repo, fallback_token="": fake), \
                mock.patch.dict("os.environ", {"GH_TOKEN": "t"}), \
                mock.patch.object(janitor.time, "sleep", lambda _: None), \
                mock.patch.object(janitor, "utc_now", lambda: NOW), \
                mock.patch("builtins.print"):
            code = janitor.main(argv)
        fake.snapshots.append(json.loads(load.read_text()))
        return code, summary.read_text()

    def test_cancel_then_re_run_failed_jobs_once(self):
        stuck, other, jobs = lost_world(age=85, event="pull_request", branch="feature")
        fake = FakeGitHub({stuck["id"]: dict(stuck), other["id"]: dict(other)}, jobs)
        fake.prs["feature"] = [make_pr(5)]
        with tempfile.TemporaryDirectory() as temp:
            code, text = self.sweep(fake, temp)
            self.assertEqual(code, 0)
            self.assertEqual(fake.posts(), [[str(stuck["id"]), "cancel"]])
            self.assertEqual([entry["run_id"] for entry in fake.snapshots[-1]["lost_reruns"]], [stuck["id"]])
            fake.runs[stuck["id"]]["conclusion"] = "cancelled"

            # Sweep 2: the run finished cancelled at the PR head -> re-run its failed jobs.
            fake.log.clear()
            code, text = self.sweep(fake, temp)
            self.assertEqual(code, 0)
            self.assertEqual(fake.posts(), [[str(stuck["id"]), "rerun-failed-jobs"]])
            self.assertEqual(fake.snapshots[-1]["lost_reruns"], [])
            self.assertIn("re-ran", text)
            self.assertEqual(fake.runs[stuck["id"]]["run_attempt"], 2)

            # Sweep 3: the janitor's re-run lost its runner again -> left to the rescue and the
            # orphan pass, never re-run a second time.
            fake.log.clear()
            code, text = self.sweep(fake, temp)
            self.assertEqual(fake.posts(), [])
            self.assertEqual(fake.snapshots[-1]["lost_reruns"], [])

    def test_a_newer_run_at_the_head_before_the_re_run_gets_none(self):
        stuck, other, jobs = lost_world(age=85, event="pull_request", branch="feature")
        newer = make_run(event="pull_request", branch="feature", sha="aaa", status="completed", age=20,
                         path=stuck["path"])
        newer["conclusion"] = "success"
        fake = FakeGitHub({stuck["id"]: dict(stuck, status="completed", conclusion="cancelled"),
                           newer["id"]: newer}, {})
        fake.prs["feature"] = [make_pr(5)]
        fake.snapshots.append({"generated_at": iso(10), "pools": {}, "lost_reruns": [pending_entry(stuck)]})
        with tempfile.TemporaryDirectory() as temp:
            self.sweep(fake, temp)
        self.assertEqual(fake.posts(), [])
        self.assertEqual(fake.snapshots[-1]["lost_reruns"], [])

    def test_a_ci_re_run_dispatches_ui_tests_for_the_new_attempt(self):
        for refuse in (False, True):
            with self.subTest(refuse_dispatch=refuse):
                stuck, other, jobs = lost_world(age=85, event="pull_request", branch="feature")
                stuck.update(path=".github/workflows/ci.yml", name="CI")
                fake = FakeGitHub({stuck["id"]: dict(stuck, status="completed", conclusion="cancelled")}, {})
                fake.refuse_dispatch = refuse
                fake.prs["feature"] = [make_pr(5)]
                fake.snapshots.append({"generated_at": iso(10), "pools": {}, "lost_reruns": [pending_entry(stuck)]})
                with tempfile.TemporaryDirectory() as temp:
                    code, text = self.sweep(fake, temp)
                # A dispatch GitHub refused is a warning: the re-run itself took.
                self.assertEqual(code, 0)
                self.assertEqual(fake.posts(), [[str(stuck["id"]), "rerun-failed-jobs"],
                                                ["ci-ui-tests.yml", "dispatches"]])
                self.assertEqual(fake.bodies[-1][2], {"ref": "main", "inputs": {"run_id": str(stuck["id"]),
                                                                               "run_attempt": "2"}})
                self.assertEqual(fake.snapshots[-1]["lost_reruns"], [])

    def test_a_pr_head_that_moved_before_the_re_run_gets_none(self):
        stuck, other, jobs = lost_world(age=85, event="pull_request", branch="feature")
        fake = FakeGitHub({stuck["id"]: dict(stuck, status="completed", conclusion="cancelled")}, {})
        fake.prs["feature"] = [make_pr(5, head="bbb")]
        fake.snapshots.append({"generated_at": iso(10), "pools": {}, "lost_reruns": [pending_entry(stuck)]})
        with tempfile.TemporaryDirectory() as temp:
            self.sweep(fake, temp)
        self.assertEqual(fake.posts(), [])
        self.assertEqual(fake.snapshots[-1]["lost_reruns"], [])

    def test_dry_run_carries_pending_re_runs_without_acting(self):
        stuck, other, jobs = lost_world(age=85, event="pull_request", branch="feature")
        fake = FakeGitHub({stuck["id"]: dict(stuck, status="completed", conclusion="cancelled")}, {})
        fake.prs["feature"] = [make_pr(5)]
        expired = make_run(status="completed")
        fake.snapshots.append({"generated_at": iso(10), "pools": {},
                               "lost_reruns": [pending_entry(stuck), pending_entry(expired, age=60 * 7)]})
        with tempfile.TemporaryDirectory() as temp:
            self.sweep(fake, temp, "--dry-run")
        self.assertEqual(fake.posts(), [])
        # An entry past LOST_RERUN_TTL is dropped in a dry run too; the rest is carried as it was.
        self.assertEqual(fake.snapshots[-1]["lost_reruns"], [pending_entry(stuck)])

    def pending_and_fresh(self):
        """A pending re-run of an earlier cancel, and a fresh lost run at another PR's head."""
        stuck, other, jobs = lost_world(age=85, event="pull_request", branch="fresh", sha="ccc")
        earlier = make_run(event="pull_request", branch="feature", sha="aaa", status="completed")
        earlier["conclusion"] = "cancelled"
        fake = FakeGitHub({stuck["id"]: dict(stuck), other["id"]: dict(other), earlier["id"]: earlier}, jobs)
        fake.prs.update({"fresh": [make_pr(6, head="ccc")], "feature": [make_pr(5)]})
        fake.snapshots.append({"generated_at": iso(10), "pools": {}, "lost_reruns": [pending_entry(earlier)]})
        return stuck, earlier, fake

    def test_one_error_after_the_cancels_never_drops_the_sweeps_entries(self):
        def failing_run(fake, run_id, original):
            if run_id == earlier["id"]:
                raise http.client.IncompleteRead(b"")
            return original(run_id)

        cases = {
            "run": (lambda fake: setattr(fake, "run", lambda run_id, o=fake.run: failing_run(fake, run_id, o)),
                    0, "both"),
            "runs_at_head": (lambda fake: setattr(fake, "runs_at_head", mock.Mock(side_effect=ValueError("bad"))),
                             0, "both"),
            "rerun_failed": (lambda fake: setattr(fake, "rerun_failed",
                                                  mock.Mock(side_effect=http.client.IncompleteRead(b""))), 1, "both"),
            "ui_tests": (lambda fake: None, 0, "fresh"),
        }
        for name, (break_it, expected_code, kept) in cases.items():
            with self.subTest(failing=name):
                stuck, earlier, fake = self.pending_and_fresh()
                break_it(fake)
                with tempfile.TemporaryDirectory() as temp, \
                        mock.patch.object(janitor.ui_tests_dispatch, "rerun_dispatch",
                                          side_effect=KeyError("inputs")):
                    code, _ = self.sweep(fake, temp)
                self.assertEqual(code, expected_code)
                self.assertIn([str(stuck["id"]), "cancel"], fake.posts())
                ids = {entry["run_id"] for entry in fake.snapshots[-1]["lost_reruns"]}
                self.assertEqual(ids, {stuck["id"], earlier["id"]} if kept == "both" else {stuck["id"]})

    def test_the_sweeps_cancels_are_saved_before_the_re_run_phase(self):
        stuck, earlier, fake = self.pending_and_fresh()
        with tempfile.TemporaryDirectory() as temp, \
                mock.patch.object(janitor, "plan_lost_reruns", side_effect=RecursionError("boom")):
            with self.assertRaises(RecursionError):
                self.sweep(fake, temp)
            saved = json.loads((Path(temp) / "load.json").read_text())
        self.assertEqual({entry["run_id"] for entry in saved["lost_reruns"]}, {stuck["id"], earlier["id"]})

    def test_a_snapshot_without_state_falls_back_to_an_older_one(self):
        stuck, other, jobs = lost_world(age=85, event="pull_request", branch="feature")
        fake = FakeGitHub({stuck["id"]: dict(stuck, status="completed", conclusion="cancelled")}, {})
        fake.prs["feature"] = [make_pr(5)]
        fake.snapshots += [{"generated_at": iso(20), "pools": {}, "lost_reruns": [pending_entry(stuck)]},
                           {"generated_at": iso(10), "pools": {}}]
        with tempfile.TemporaryDirectory() as temp:
            self.sweep(fake, temp)
        self.assertEqual(fake.posts(), [[str(stuck["id"]), "rerun-failed-jobs"]])

    def test_an_unreadable_previous_state_leaves_the_current_head_alone(self):
        for error in (RuntimeError("boom"), http.client.IncompleteRead(b""), KeyError("archive_download_url")):
            with self.subTest(error=type(error).__name__):
                stuck, other, jobs = lost_world(age=85, event="pull_request", branch="feature")
                fake = FakeGitHub({stuck["id"]: dict(stuck), other["id"]: dict(other)}, jobs)
                fake.prs["feature"] = [make_pr(5)]
                with tempfile.TemporaryDirectory() as temp, \
                        mock.patch.object(janitor, "previous_lost_reruns", side_effect=error):
                    code, _ = self.sweep(fake, temp)
                self.assertEqual(code, 0)
                self.assertEqual(fake.posts(), [])
                self.assertNotIn("lost_reruns", fake.snapshots[-1])



# ---------------------------------------------------------------------------
# Unclaimed legs: a leg on an owned label no runner claimed within a bounded
# wait, at a live head, whatever the evidence.
# ---------------------------------------------------------------------------

DISPATCH_BRANCH = "acpmux-policy-everywhere"
DISPATCH_SHA = "d9d0e2ca"
TUI = ".github/workflows/cmux-tui.yml"


def unclaimed_world(*, age=50, event="workflow_dispatch", branch=DISPATCH_BRANCH, sha=DISPATCH_SHA, path=TUI,
                    attempt=1, actor="leo", label=SIDE, siblings=(), name="macOS lint and tests"):
    """Run 39652497071: a dispatch of cmux-tui.yml whose macOS leg no runner ever claimed, and no other run."""
    run = make_run(event=event, branch=branch, sha=sha, status="queued", age=age + 2, attempt=attempt,
                   name="cmux-tui", path=path)
    run["triggering_actor"] = {"login": actor}
    return run, {run["id"]: [unassigned_job(age=age, label=label, name=name), *siblings]}


def waited_job(*, waited, label=SIDE, age=None):
    """A job a runner took after waiting `waited` minutes, `age` minutes ago (default: just now)."""
    started = 1 if age is None else age
    job = {"status": "in_progress", "name": "macos / side lane", "labels": [label],
           "created_at": iso(started + waited), "started_at": iso(started), "runner_id": 7,
           "runner_name": "mini-7-side"}
    return job


def unclaimed_plan(runs, jobs, prs=None, *, heads=None, rerun_state=True):
    return janitor.build_plan(runs, jobs, prs or {}, threshold=6, max_cancels=10,
                              pull_request_policy="compile-only", now=NOW, rerun_state=rerun_state,
                              branch_heads=heads if heads is not None else {DISPATCH_BRANCH: DISPATCH_SHA})


class UnclaimedLegDetectionTests(unittest.TestCase):
    def test_pool_p90_wait_comes_from_the_jobs_runners_took(self):
        jobs = [waited_job(waited=minutes) for minutes in (1, 2, 3, 4, 5, 6, 7, 8, 9, 70)]
        jobs += [waited_job(waited=90, label=MAC), unassigned_job(age=200)]
        p90 = janitor.pool_wait_p90({1: jobs})
        # Nearest rank over ten samples: the ninth. Blacksmith labels are not owned pools.
        self.assertEqual(p90, {SIDE: 9 * 60})

    def test_a_pool_with_fewer_than_five_samples_has_no_p90(self):
        jobs = [waited_job(waited=minutes) for minutes in (60, 70, 80, 90)]
        self.assertEqual(janitor.pool_wait_p90({1: jobs}), {})
        self.assertEqual(janitor.pool_wait_p90({1: jobs + [waited_job(waited=100)]}), {SIDE: 100 * 60})

    def test_a_sample_waits_from_when_its_run_let_it_run(self):
        # Created 60 minutes ago behind a gate that finished 30 minutes ago, taken 20 minutes ago: it waited
        # 10 minutes for a runner, not 40. A sibling that finished after it started gated nothing.
        jobs = {}
        for index in range(5):
            gate = started_job(age=60, status="completed", label=LINUX)
            gate["completed_at"] = iso(30)
            late = started_job(age=15, status="completed", label=LINUX)
            late["completed_at"] = iso(5)
            jobs[index] = [waited_job(waited=40, age=20), gate, late]
        self.assertEqual(janitor.pool_wait_p90(jobs), {SIDE: 10 * 60})

    def test_bound_is_45_minutes_or_the_pools_p90_when_higher(self):
        self.assertEqual(janitor.unclaimed_bound(SIDE, {}), 45 * 60)
        self.assertEqual(janitor.unclaimed_bound(SIDE, {SIDE: 20 * 60}), 45 * 60)
        self.assertEqual(janitor.unclaimed_bound(SIDE, {SIDE: 70 * 60}), 70 * 60)

    def test_run_39652497071_dispatch_leg_is_unclaimed_after_45_minutes(self):
        run, jobs = unclaimed_world(age=46)
        found = janitor.find_unclaimed([run], jobs, now=NOW)
        self.assertEqual(sorted(found), [run["id"]])
        self.assertEqual(found[run["id"]].pool, SIDE)
        self.assertEqual(found[run["id"]].bound_seconds, 45 * 60)
        run, jobs = unclaimed_world(age=44)
        self.assertEqual(janitor.find_unclaimed([run], jobs, now=NOW), {})

    def test_a_slow_pool_waits_for_its_own_p90(self):
        run, jobs = unclaimed_world(age=60)
        other = make_run(event="push", branch="other", status="in_progress", path=TUI)
        jobs[other["id"]] = [waited_job(waited=75) for _ in range(5)]
        self.assertEqual(janitor.find_unclaimed([run, other], jobs, now=NOW), {})
        run, jobs2 = unclaimed_world(age=80)
        jobs2[other["id"]] = jobs[other["id"]]
        self.assertEqual(sorted(janitor.find_unclaimed([run, other], jobs2, now=NOW)), [run["id"]])

    def test_only_owned_legs_in_scope_runs_count(self):
        # A Blacksmith leg re-run would only rejoin the same label.
        run, jobs = unclaimed_world(age=90, label=MAC)
        self.assertEqual(janitor.find_unclaimed([run], jobs, now=NOW), {})
        # Protected runs (a dispatch on main) and events with no head (schedule) are out of scope.
        for event, branch in (("workflow_dispatch", "main"), ("schedule", DISPATCH_BRANCH)):
            with self.subTest(event=event, branch=branch):
                run, jobs = unclaimed_world(age=90, event=event, branch=branch)
                self.assertEqual(janitor.find_unclaimed([run], jobs, now=NOW), {})

    def test_an_unfinished_sibling_gates_the_leg(self):
        running = started_job(age=100, label=LINUX)
        run, jobs = unclaimed_world(age=90, siblings=[running])
        self.assertEqual(janitor.find_unclaimed([run], jobs, now=NOW), {})

    def test_a_run_category_e_already_holds_is_not_counted_twice(self):
        stuck, other, jobs = lost_world(age=85)
        lost = janitor.find_lost([stuck, other], jobs, now=NOW)
        self.assertEqual(sorted(lost), [stuck["id"]])
        self.assertEqual(janitor.find_unclaimed([stuck, other], jobs, now=NOW, lost=lost), {})


class UnclaimedLegPlanTests(unittest.TestCase):
    def test_run_39652497071_is_cancelled_for_a_blacksmith_re_run_at_the_live_branch_head(self):
        run, jobs = unclaimed_world(age=50)
        decision = decision_for(unclaimed_plan([run], jobs, {DISPATCH_BRANCH: []}), run)
        self.assertEqual((decision.action, decision.candidate.category), ("cancel", "unclaimed"))
        self.assertTrue(decision.candidate.rerun)
        self.assertIn("live branch", decision.candidate.reason)
        self.assertIn(SIDE, decision.candidate.reason)

    def test_an_open_pr_at_the_head_makes_a_push_or_dispatch_live_too(self):
        for event in ("push", "workflow_dispatch", "pull_request"):
            with self.subTest(event=event):
                run, jobs = unclaimed_world(age=50, event=event, branch="feature", sha="aaa")
                decision = decision_for(unclaimed_plan([run], jobs, {"feature": [make_pr(5)]}, heads={}), run)
                self.assertEqual((decision.action, decision.candidate.category), ("cancel", "unclaimed"))
                self.assertTrue(decision.candidate.rerun)

    def test_a_moved_deleted_or_unread_branch_is_left_alone(self):
        for heads in ({DISPATCH_BRANCH: "eeeeeee"}, {DISPATCH_BRANCH: ""}, {}):
            with self.subTest(heads=heads):
                run, jobs = unclaimed_world(age=50)
                # Not live: left to category b and the orphan pass, not even listed.
                self.assertIsNone(decision_for(unclaimed_plan([run], jobs, {DISPATCH_BRANCH: []}, heads=heads), run))

    def test_a_superseded_or_closed_pull_request_run_is_left_to_category_b(self):
        run, jobs = unclaimed_world(age=50, event="pull_request", branch="feature", sha="aaa")
        decision = decision_for(unclaimed_plan([run], jobs, {"feature": [make_pr(5, head="bbb")]}, heads={}), run)
        self.assertEqual(decision.candidate.category, "stale-pr")

    def test_a_re_run_that_would_stay_on_the_owned_label_is_left_to_the_rescue(self):
        run, jobs = unclaimed_world(age=50, path=".github/workflows/cmux-next.yml")
        decision = decision_for(unclaimed_plan([run], jobs, {DISPATCH_BRANCH: []}), run)
        self.assertEqual(decision.action, "skip")
        self.assertIn("owned", decision.note)

    def test_bot_re_runs_failed_runs_and_newer_runs_are_never_re_run(self):
        run, jobs = unclaimed_world(age=50, attempt=2, actor="github-actions[bot]")
        self.assertEqual(decision_for(unclaimed_plan([run], jobs, {DISPATCH_BRANCH: []}), run).action, "skip")
        failed = dict(started_job(age=100, label=LINUX, status="completed", conclusion="failure"))
        run, jobs = unclaimed_world(age=50, siblings=[failed])
        self.assertEqual(decision_for(unclaimed_plan([run], jobs, {DISPATCH_BRANCH: []}), run).action, "skip")
        run, jobs = unclaimed_world(age=50, event="pull_request", branch="feature", sha="aaa")
        newer = make_run(event="pull_request", branch="feature", sha="aaa", status="in_progress", path=TUI, age=10)
        decision = decision_for(unclaimed_plan([run, newer], jobs, {"feature": [make_pr(5)]}, heads={}), run)
        self.assertEqual(decision.action, "skip")
        self.assertIn(str(newer["id"]), decision.note)

    def test_two_dispatches_at_the_same_head_do_not_block_the_rescue(self):
        # cmux-tui.yml runs each dispatch in its own group (cmux-tui-${{ inputs.request_id }}, never cancelled
        # in progress): a second dispatch at the head is another request, not a takeover.
        run, jobs = unclaimed_world(age=50)
        second = make_run(event="workflow_dispatch", branch=DISPATCH_BRANCH, sha=DISPATCH_SHA,
                          status="in_progress", path=TUI, age=10)
        decision = decision_for(unclaimed_plan([run, second], jobs, {DISPATCH_BRANCH: []}), run)
        self.assertEqual((decision.action, decision.candidate.category), ("cancel", "unclaimed"))
        self.assertIsNone(janitor.newer_run_at_head(run, [run, second]))

    def test_no_re_run_state_or_no_janitor_leaves_it_alone(self):
        run, jobs = unclaimed_world(age=50)
        decision = decision_for(unclaimed_plan([run], jobs, {DISPATCH_BRANCH: []}, rerun_state=False), run)
        self.assertEqual(decision.action, "skip")
        run, jobs = unclaimed_world(age=50, event="pull_request", branch="feature", sha="aaa")
        decision = decision_for(unclaimed_plan([run], jobs, {"feature": [make_pr(5, labels=("no-janitor",))]},
                                               heads={}), run)
        self.assertEqual(decision.action, "skip")

    def test_category_e_push_at_a_live_branch_head_is_now_re_run(self):
        # Run 39631559018's pin push had no pull request; once the branch head is read and still the run's,
        # the branch is live and the cancel carries a re-run (without the read: cancelled only, as before).
        stuck, other, jobs = lost_world(age=85)
        decision = decision_for(unclaimed_plan([stuck, other], jobs, {PIN_BRANCH: [], "other-pin": []},
                                               heads={PIN_BRANCH: "aaa"}), stuck)
        self.assertEqual((decision.action, decision.candidate.category), ("cancel", "lost"))
        self.assertTrue(decision.candidate.rerun)

    def test_unclaimed_cancels_need_no_backed_up_pool_and_share_the_cap(self):
        worlds = [unclaimed_world(age=50, branch=f"b{index}", sha=f"s{index}") for index in range(3)]
        runs = [run for run, _ in worlds]
        jobs = {key: value for _, world in worlds for key, value in world.items()}
        result = janitor.build_plan(runs, jobs, {f"b{index}": [] for index in range(3)}, threshold=6,
                                    max_cancels=2, pull_request_policy="compile-only", now=NOW,
                                    branch_heads={f"b{index}": f"s{index}" for index in range(3)})
        self.assertEqual([d.action for d in result.decisions].count("cancel"), 2)
        self.assertFalse(result.over_threshold)


class UnclaimedLegRerunTests(unittest.TestCase):
    def test_a_dispatch_entry_is_re_run_while_its_branch_is_live(self):
        run = make_run(event="workflow_dispatch", branch=DISPATCH_BRANCH, sha=DISPATCH_SHA, status="completed",
                       path=TUI)
        run["conclusion"] = "cancelled"
        cases = (({DISPATCH_BRANCH: DISPATCH_SHA}, "rerun"), ({DISPATCH_BRANCH: "eeee"}, "drop"),
                 ({DISPATCH_BRANCH: ""}, "drop"), ({}, "keep"))
        for heads, action in cases:
            with self.subTest(heads=heads):
                decisions = janitor.plan_lost_reruns([pending_entry(run)], {run["id"]: run}, {DISPATCH_BRANCH: []},
                                                     now=NOW, head_runs={run["id"]: []}, branch_heads=heads)
                self.assertEqual([d.action for d in decisions], [action])

    def test_a_second_dispatch_at_the_head_never_drops_the_pending_re_run(self):
        run = make_run(event="workflow_dispatch", branch=DISPATCH_BRANCH, sha=DISPATCH_SHA, status="completed",
                       path=TUI)
        run["conclusion"] = "cancelled"
        second = make_run(event="workflow_dispatch", branch=DISPATCH_BRANCH, sha=DISPATCH_SHA, status="queued",
                          path=TUI)
        decisions = janitor.plan_lost_reruns([pending_entry(run)], {run["id"]: run}, {DISPATCH_BRANCH: []},
                                             now=NOW, head_runs={run["id"]: [run, second]},
                                             branch_heads={DISPATCH_BRANCH: DISPATCH_SHA})
        self.assertEqual([d.action for d in decisions], ["rerun"])

    def test_head_lookups_are_capped_and_only_for_branches_a_push_or_dispatch_needs(self):
        runs = [make_run(event="workflow_dispatch", branch=f"b{index}") for index in range(20)]
        runs.append(make_run(event="pull_request", branch="pr-branch"))
        wanted = janitor.branch_head_lookups(runs, {run["id"] for run in runs})
        self.assertEqual(len(wanted), janitor.CANDIDATE_HEAD_LOOKUPS)
        self.assertNotIn("pr-branch", wanted)

    def test_candidates_that_could_not_be_re_run_spend_no_head_read(self):
        runs, jobs = [], {}
        for index, (path, actor, attempt) in enumerate(((TUI, "leo", 1), (".github/workflows/cmux-next.yml", "leo", 1),
                                                        (TUI, "github-actions[bot]", 2))):
            run, world = unclaimed_world(age=50, branch=f"b{index}", path=path, actor=actor, attempt=attempt)
            runs.append(run)
            jobs.update(world)
        failed, world = unclaimed_world(age=50, branch="failed",
                                        siblings=[started_job(age=90, label=LINUX, status="completed",
                                                              conclusion="failure")])
        opted, world2 = unclaimed_world(age=50, branch="opted")
        runs += [failed, opted]
        jobs.update(world)
        jobs.update(world2)
        prs = {"opted": [make_pr(9, head="other", labels=("no-janitor",))]}
        wanted = janitor.branch_head_lookups(runs, {run["id"] for run in runs}, prs_by_branch=prs,
                                             jobs_by_run=jobs, unclaimed={run["id"] for run in runs})
        self.assertEqual(wanted, ["b0"])


class UnclaimedLegSweepTests(unittest.TestCase):
    sweep = LostAssignmentSweepTests.sweep

    def test_run_39652497071_is_cancelled_then_re_run_once_on_blacksmith(self):
        run, jobs = unclaimed_world(age=50)
        fake = FakeGitHub({run["id"]: dict(run)}, jobs)
        fake.prs[DISPATCH_BRANCH] = []
        fake.branches[DISPATCH_BRANCH] = DISPATCH_SHA
        with tempfile.TemporaryDirectory() as temp:
            code, text = self.sweep(fake, temp)
            self.assertEqual(code, 0)
            self.assertEqual(fake.posts(), [[str(run["id"]), "cancel"]])
            self.assertIn("unclaimed", text)
            self.assertEqual([entry["run_id"] for entry in fake.snapshots[-1]["lost_reruns"]], [run["id"]])
            # One branch read for the liveness check.
            self.assertEqual(len([path for _, path in fake.log if "/branches/" in path]), 1)
            fake.runs[run["id"]]["conclusion"] = "cancelled"

            fake.log.clear()
            code, text = self.sweep(fake, temp)
            self.assertEqual(fake.posts(), [[str(run["id"]), "rerun-failed-jobs"]])
            self.assertEqual(fake.runs[run["id"]]["run_attempt"], 2)
            self.assertEqual(fake.snapshots[-1]["lost_reruns"], [])

            # Attempt 2 is the bot's: never re-run again here.
            fake.runs[run["id"]].update(status="queued")
            fake.log.clear()
            self.sweep(fake, temp)
            self.assertEqual(fake.posts(), [])

    def test_settled_cancels_get_head_reads_however_many_candidates_spend_theirs(self):
        runs, jobs = {}, {}
        for index in range(janitor.CANDIDATE_HEAD_LOOKUPS + 4):
            run, world = unclaimed_world(age=50, branch=f"c{index}", sha=f"s{index}")
            runs[run["id"]] = dict(run)
            jobs.update(world)
        settled = make_run(event="workflow_dispatch", branch=DISPATCH_BRANCH, sha=DISPATCH_SHA, status="completed",
                           path=TUI, age=120)
        settled["conclusion"] = "cancelled"
        runs[settled["id"]] = settled
        fake = FakeGitHub(runs, jobs)
        fake.branches[DISPATCH_BRANCH] = DISPATCH_SHA
        fake.snapshots.append({"generated_at": iso(10), "pools": {}, "lost_reruns": [pending_entry(settled)]})
        with tempfile.TemporaryDirectory() as temp:
            self.sweep(fake, temp)
        self.assertIn([str(settled["id"]), "rerun-failed-jobs"], fake.posts())
        reads = [path for _, path in fake.log if "/branches/" in path]
        self.assertEqual(len(reads), janitor.CANDIDATE_HEAD_LOOKUPS + 1)

    def test_the_snapshot_carries_each_owned_pools_p90_wait(self):
        run, jobs = unclaimed_world(age=10)
        other = make_run(event="push", branch="other", status="in_progress", path=TUI)
        jobs[other["id"]] = [waited_job(waited=12) for _ in range(5)]
        fake = FakeGitHub({run["id"]: dict(run), other["id"]: dict(other)}, jobs)
        with tempfile.TemporaryDirectory() as temp:
            self.sweep(fake, temp)
        self.assertEqual(fake.snapshots[-1]["wait_p90_seconds"], {SIDE: 12 * 60})
        self.assertEqual(fake.posts(), [])


NEXT_PATH = ".github/workflows/cmux-next.yml"
NEXT_BRANCH = "feat-cmux-" + "next"
LARGE_MAC = "blacksmith-12vcpu-macos-26"


def next_pr_run(*, branch="steer-default-2/new-chat-default-mode", sha="5353d57a", prs=True, age=95,
                attempt=1, actor="leo", status="queued"):
    """Run 40259152940: a cmux-next pull request run into feat-cmux-next, from this repository."""
    run = make_run(path=NEXT_PATH, name="cmux-next", branch=branch, sha=sha, age=age, attempt=attempt,
                   status=status)
    run["pull_requests"] = [{"number": 24021, "base": {"ref": NEXT_BRANCH}}] if prs else []
    run["head_repository"]["id"] = 1
    run["repository"] = {"id": 1, "full_name": "manaflow-ai/cmux"}
    run["triggering_actor"] = {"login": actor}
    return run


def fast_tier_leg(*, age=90, label=LARGE_MAC):
    return unassigned_job(age=age, label=label, name="cmux-next fast tier")


def finished_sibling(*, conclusion="success"):
    job = started_job(age=100, label=LINUX, status="completed", conclusion=conclusion)
    job["completed_at"] = iso(95)
    return job


class BranchCopyListingTests(unittest.TestCase):
    """main's cmux-next.yml is an inert registration; feat-cmux-next's runs put Mac jobs on Blacksmith macOS."""

    LINUX_ONLY = frozenset({NEXT_PATH})

    def test_runs_that_follow_feat_cmux_next_are_listed(self):
        into_next = next_pr_run()
        push = make_run(event="push", path=NEXT_PATH, branch=NEXT_BRANCH)
        landed = next_pr_run(prs=False)
        for run in (into_next, push, landed):
            with self.subTest(run=run["event"], prs=run["pull_requests"]):
                self.assertTrue(janitor.needs_jobs(run, self.LINUX_ONLY, NOW))

    def test_runs_that_follow_main_or_a_fork_stay_unlisted(self):
        into_main = next_pr_run()
        into_main["pull_requests"] = [{"number": 7, "base": {"ref": "main"}}]
        fork = next_pr_run(prs=False)
        fork["head_repository"]["id"] = 2
        unknown = make_run(path=NEXT_PATH)  # no repository ids: nothing says it is this repository's
        for run in (into_main, fork, unknown):
            with self.subTest(run=run["pull_requests"], head=run["head_repository"]):
                self.assertFalse(janitor.needs_jobs(run, self.LINUX_ONLY, NOW))

    def sweep(self, runs, jobs, prs=None):
        fake = FakeGitHub({run["id"]: dict(run) for run in runs}, jobs)
        fake.prs = dict(prs or {})
        with tempfile.TemporaryDirectory() as temp:
            workflows = Path(temp) / "workflows"
            workflows.mkdir()
            (workflows / "cmux-next.yml").write_text("name: cmux-next\non:\n  workflow_dispatch:\n")
            out, summary = Path(temp) / "pool.json", Path(temp) / "summary.md"
            argv = ["--repo", "manaflow-ai/cmux", "--summary", str(summary), "--workflows-dir", str(workflows),
                    "--pool-load", str(out)]
            with mock.patch.object(janitor, "GitHub", lambda token, repo, fallback_token="": fake), \
                    mock.patch.dict("os.environ", {"GH_TOKEN": "t"}), \
                    mock.patch.object(janitor.time, "sleep", lambda _: None), \
                    mock.patch.object(janitor, "utc_now", lambda: NOW), \
                    mock.patch("builtins.print"):
                self.assertEqual(janitor.main(argv), 0)
            return json.loads(out.read_text()), fake

    def test_run_40259152940_the_snapshot_counts_cmux_next_blacksmith_queue(self):
        # At 02:32Z the cascade counted 2 queued on the 12 vCPU label; cmux-next's own jobs there were missing.
        runs, jobs = [], {}
        for index in range(10):
            run = next_pr_run(branch=f"lane/{index}", sha=f"s{index}", age=30 + index)
            runs.append(run)
            jobs[run["id"]] = [fast_tier_leg(age=20 + index)]
        prs = {run["head_branch"]: [make_pr(100 + index, head=run["head_sha"])] for index, run in enumerate(runs)}
        snapshot, _ = self.sweep(runs, jobs, prs)
        self.assertEqual(snapshot["pools"][LARGE_MAC]["queued"], 10)
        self.assertEqual(snapshot["pools"][LARGE_MAC]["oldest_queued_minutes"], 29)

    def test_run_40259152940_is_cancelled_once_its_pull_request_landed(self):
        run = next_pr_run(prs=False)
        jobs = {run["id"]: [fast_tier_leg(), finished_sibling(conclusion="failure")]}
        _, fake = self.sweep([run], jobs, {run["head_branch"]: [make_pr(24021, state="MERGED", head=run["head_sha"])]})
        self.assertEqual(fake.posts(), [[str(run["id"]), "cancel"]])


class BlacksmithLegTests(unittest.TestCase):
    """Category f moves a cmux-next leg off a Blacksmith macOS label no runner serves, by an App's re-run."""

    def world(self, *, age=30, label=LARGE_MAC, attempt=1, actor="leo", path=NEXT_PATH, siblings=None):
        run = next_pr_run(attempt=attempt, actor=actor, age=age + 10)
        run["path"] = path
        jobs = {run["id"]: [fast_tier_leg(age=age, label=label), *(siblings or [finished_sibling()])]}
        # The sibling finished 95 minutes ago; the leg could run from its own creation.
        return run, jobs

    def plan(self, run, jobs, *, app_rerun=True):
        prs = {run["head_branch"]: [make_pr(24021, head=run["head_sha"])]}
        unclaimed = janitor.find_unclaimed([run], jobs, now=NOW, blacksmith_legs=True)
        return janitor.build_plan([run], jobs, prs, threshold=6, max_cancels=10, pull_request_policy="compile-only",
                                  now=NOW, unclaimed=unclaimed, branch_heads={}, app_rerun=app_rerun)

    def test_a_leg_waiting_past_the_cascades_stall_wait_is_unclaimed(self):
        run, jobs = self.world(age=26)
        found = janitor.find_unclaimed([run], jobs, now=NOW, blacksmith_legs=True)
        self.assertEqual(found[run["id"]].pool, LARGE_MAC)
        self.assertTrue(found[run["id"]].blacksmith)
        self.assertEqual(found[run["id"]].bound_seconds, 25 * 60)
        run, jobs = self.world(age=24)
        self.assertEqual(janitor.find_unclaimed([run], jobs, now=NOW, blacksmith_legs=True), {})

    def test_only_cmux_next_legs_with_owned_pools_on_count(self):
        run, jobs = self.world(age=60)
        self.assertEqual(janitor.find_unclaimed([run], jobs, now=NOW), {})
        run, jobs = self.world(age=60, path=TUI)
        self.assertEqual(janitor.find_unclaimed([run], jobs, now=NOW, blacksmith_legs=True), {})
        run, jobs = self.world(age=60, label="macos-26")
        self.assertEqual(janitor.find_unclaimed([run], jobs, now=NOW, blacksmith_legs=True), {})

    def test_it_is_cancelled_for_an_apps_re_run(self):
        run, jobs = self.world(age=40)
        decision = decision_for(self.plan(run, jobs), run)
        self.assertEqual((decision.action, decision.candidate.category), ("cancel", "unclaimed"))
        self.assertTrue(decision.candidate.rerun)
        self.assertTrue(decision.candidate.app_actor)
        entries = janitor.new_lost_reruns([decision.candidate], {run["id"]: "cancelled"}, now=NOW)
        self.assertEqual([entry.get("app_actor") for entry in entries], [True])

    def test_a_rescue_attempt_counts_but_not_past_its_ladder(self):
        run, jobs = self.world(age=40, attempt=2, actor="github-actions[bot]")
        self.assertEqual(decision_for(self.plan(run, jobs), run).action, "cancel")
        run, jobs = self.world(age=40, attempt=janitor.rescue.REFUSAL_RESCUE_ATTEMPT + 1, actor="github-actions[bot]")
        decision = decision_for(self.plan(run, jobs), run)
        self.assertEqual(decision.action, "skip")
        self.assertIn("ladder", decision.note)

    def test_without_an_app_token_it_is_left_alone(self):
        run, jobs = self.world(age=40)
        decision = decision_for(self.plan(run, jobs, app_rerun=False), run)
        self.assertEqual(decision.action, "skip")
        self.assertIn("App", decision.note)

    def test_a_failed_run_is_still_never_re_run(self):
        run, jobs = self.world(age=40, siblings=[finished_sibling(conclusion="failure")])
        self.assertEqual(decision_for(self.plan(run, jobs), run).action, "skip")

    def test_an_app_entry_waits_for_an_app_token(self):
        run = next_pr_run(status="completed")
        run["conclusion"] = "cancelled"
        entry = {**pending_entry(run), "app_actor": True}
        prs = {run["head_branch"]: [make_pr(24021, head=run["head_sha"])]}
        for app_token, action in ((False, "keep"), (True, "rerun")):
            with self.subTest(app_token=app_token):
                decisions = janitor.plan_lost_reruns([entry], {run["id"]: run}, prs, now=NOW,
                                                     head_runs={run["id"]: []}, app_token=app_token)
                self.assertEqual([d.action for d in decisions], [action])

    def test_an_app_only_re_run_never_falls_back_to_the_workflow_token(self):
        github = janitor.GitHub("app", "manaflow-ai/cmux", fallback_token="workflow")
        self.assertTrue(github.app_token)
        refused = urllib.error.HTTPError("https://api.github.com/x", 403, "Forbidden", email.message.Message(),
                                         io.BytesIO(b"{}"))
        with mock.patch.object(janitor.urllib.request, "urlopen", side_effect=refused), \
                mock.patch("builtins.print"):
            with self.assertRaises(RuntimeError):
                github.rerun_failed(1, app_only=True)
        self.assertTrue(github.app_token)
        self.assertEqual(github.headers["Authorization"], "Bearer app")
        workflow_only = janitor.GitHub("workflow", "manaflow-ai/cmux", fallback_token="workflow")
        self.assertFalse(workflow_only.app_token)
        with self.assertRaises(RuntimeError):
            workflow_only.rerun_failed(1, app_only=True)

    def test_sweeps_cancel_then_re_run_it_once_as_an_app(self):
        run, jobs = self.world(age=40)
        fake = FakeGitHub({run["id"]: dict(run)}, jobs)
        fake.app_token = True
        fake.prs[run["head_branch"]] = [make_pr(24021, head=run["head_sha"])]
        with tempfile.TemporaryDirectory() as temp, mock.patch.dict("os.environ", {"PR_POOL_OWNED": "1"}):
            code, text = LostAssignmentSweepTests.sweep(self, fake, temp)
            self.assertEqual(code, 0)
            self.assertEqual(fake.posts(), [[str(run["id"]), "cancel"]])
            self.assertEqual([entry.get("app_actor") for entry in fake.snapshots[-1]["lost_reruns"]], [True])
            fake.runs[run["id"]].update(status="completed", conclusion="cancelled")
            fake.log.clear()
            LostAssignmentSweepTests.sweep(self, fake, temp)
            self.assertEqual(fake.posts(), [[str(run["id"]), "rerun-failed-jobs"]])
            self.assertEqual(len(fake.app_only_posts), 1)
            self.assertEqual(fake.runs[run["id"]]["triggering_actor"], {"login": "cmux-bot[bot]"})
            self.assertEqual(fake.snapshots[-1]["lost_reruns"], [])

    def test_a_bots_attempt_category_e_leaves_is_moved_by_category_f(self):
        run, jobs = self.world(age=40, attempt=2, actor="github-actions[bot]")
        other = make_run(path=NEXT_PATH, name="cmux-next", branch="lane/other", status="in_progress", age=20)
        jobs[other["id"]] = [started_job(age=10, label=LARGE_MAC)]
        lost = janitor.find_lost([run, other], jobs, now=NOW)
        unclaimed = janitor.find_unclaimed([run, other], jobs, now=NOW, lost=lost, blacksmith_legs=True)
        self.assertEqual((sorted(lost), sorted(unclaimed)), ([run["id"]], [run["id"]]))
        prs = {run["head_branch"]: [make_pr(24021, head=run["head_sha"])], "lane/other": [make_pr(9)]}
        result = janitor.build_plan([run, other], jobs, prs, threshold=6, max_cancels=10,
                                    pull_request_policy="compile-only", now=NOW, lost=lost, unclaimed=unclaimed,
                                    branch_heads={}, app_rerun=True)
        decision = decision_for(result, run)
        self.assertEqual((decision.action, decision.candidate.category), ("cancel", "unclaimed"))
        self.assertTrue(decision.candidate.app_actor)

    def test_a_lost_gui_job_on_blacksmith_also_needs_an_app(self):
        run, jobs = self.world(age=40)
        jobs[run["id"]][0]["name"] = "cmux-next swift test"
        jobs[run["id"]][0]["labels"] = ["blacksmith-6vcpu-macos-26"]
        other = make_run(path=NEXT_PATH, name="cmux-next", branch="lane/other", status="in_progress", age=20)
        jobs[other["id"]] = [started_job(age=10, label="blacksmith-6vcpu-macos-26")]
        lost = janitor.find_lost([run, other], jobs, now=NOW)
        prs = {run["head_branch"]: [make_pr(24021, head=run["head_sha"])], "lane/other": [make_pr(9)]}
        result = janitor.build_plan([run, other], jobs, prs, threshold=6, max_cancels=10,
                                    pull_request_policy="compile-only", now=NOW, lost=lost, unclaimed={},
                                    branch_heads={}, app_rerun=False)
        self.assertEqual(decision_for(result, run).action, "skip")

    def test_a_feat_cmux_next_push_is_never_an_orphan_to_cancel(self):
        push = make_run(event="push", path=NEXT_PATH, name="cmux-next", branch=NEXT_BRANCH)
        self.assertIn("push to", janitor.orphan_protected_reason(push))
        main_push = make_run(event="push", path=".github/workflows/ci.yml", branch="main")
        self.assertIsNone(janitor.orphan_protected_reason(main_push))

    def test_only_same_repository_pull_request_cascade_jobs_count(self):
        run, jobs = self.world(age=60)
        self.assertIsNotNone(janitor.blacksmith_leg(run, jobs[run["id"]][0]))
        fork, jobs = self.world(age=60)
        fork["head_repository"]["id"] = 2
        self.assertEqual(janitor.find_unclaimed([fork], jobs, now=NOW, blacksmith_legs=True), {})
        dispatch, jobs = self.world(age=60)
        dispatch["event"] = "workflow_dispatch"
        self.assertEqual(janitor.find_unclaimed([dispatch], jobs, now=NOW, blacksmith_legs=True), {})
        run, jobs = self.world(age=60)
        jobs[run["id"]][0]["name"] = "cmux-next swift test"
        self.assertEqual(janitor.find_unclaimed([run], jobs, now=NOW, blacksmith_legs=True), {})

    def test_a_lost_blacksmith_leg_is_re_run_only_by_an_app(self):
        # Category e can hold the run first (a newer job on the same label started): its re-run needs an App too.
        run, jobs = self.world(age=40)
        other = make_run(path=NEXT_PATH, name="cmux-next", branch="lane/other", status="in_progress", age=20)
        newer = started_job(age=10, label=LARGE_MAC)
        jobs[other["id"]] = [newer]
        lost = janitor.find_lost([run, other], jobs, now=NOW)
        self.assertEqual(sorted(lost), [run["id"]])
        prs = {run["head_branch"]: [make_pr(24021, head=run["head_sha"])], "lane/other": [make_pr(9)]}
        for app_rerun, action in ((False, "skip"), (True, "cancel")):
            with self.subTest(app_rerun=app_rerun):
                result = janitor.build_plan([run, other], jobs, prs, threshold=6, max_cancels=10,
                                            pull_request_policy="compile-only", now=NOW, lost=lost, unclaimed={},
                                            branch_heads={}, app_rerun=app_rerun)
                decision = decision_for(result, run)
                self.assertEqual((decision.action, decision.candidate.category), (action, "lost"))
                self.assertTrue(decision.candidate.app_actor or action == "skip")


class InFlightRunListingTests(unittest.TestCase):
    """A status-filtered runs page can come back short before the last one (2026-10-26: 99, then 85, of 182)."""

    def listing(self, pages, *, total=True):
        github = janitor.GitHub("token", "manaflow-ai/cmux")
        asked = []

        def request(method, path, body=None):
            query = urllib.parse.parse_qs(path.split("?", 1)[1])
            status, page = query["status"][0], int(query["page"][0])
            asked.append((status, page))
            batch = pages.get(status, {}).get(page, [])
            count = sum(len(rows) for rows in pages.get(status, {}).values())
            return {"workflow_runs": batch, **({"total_count": count} if total else {})}

        github.request = request
        return {run["id"] for run in github.in_flight_runs()}, asked

    def test_a_short_first_page_does_not_hide_the_older_queued_runs(self):
        queued = {1: [{"id": index} for index in range(99)], 2: [{"id": 1000 + index} for index in range(85)]}
        ids, asked = self.listing({"queued": queued})
        self.assertEqual(len(ids), 184)
        self.assertIn(1084, ids)
        self.assertIn(("queued", 3), asked)

    def test_only_an_empty_page_or_the_page_cap_ends_a_status(self):
        # A page repeating rows reaches total_count by row count while run 3 is still unread.
        ids, asked = self.listing({"queued": {1: [{"id": 1}, {"id": 2}], 2: [{"id": 2}, {"id": 3}]}})
        self.assertEqual(ids, {1, 2, 3})
        self.assertEqual([page for status, page in asked if status == "queued"], [1, 2, 3])
        ids, asked = self.listing({"queued": {1: [{"id": 1}], 3: [{"id": 3}]}}, total=False)
        self.assertEqual(ids, {1})
        self.assertEqual([page for status, page in asked if status == "queued"], [1, 2])
        pages = {page: [{"id": page * 1000 + index} for index in range(100)] for page in range(1, 5)}
        ids, asked = self.listing({"queued": pages})
        self.assertEqual(len(ids), 100 * janitor.MAX_RUN_PAGES)


if __name__ == "__main__":
    unittest.main()
