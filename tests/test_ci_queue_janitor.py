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
        # Doomed only ever judges a run at its open PR's head: listed, never cancelled.
        self.assertEqual(skipped[0].note, janitor.OPEN_HEAD_RULE)

    def test_doomed_does_not_fire_below_the_queue_threshold(self):
        # A doomed run is only worth cancelling when its slots are contended.
        doomed = make_run(branch="feature", sha="aaa")
        result = plan([doomed], {doomed["id"]: doomed_jobs()}, {"feature": [make_pr()]})
        self.assertEqual(result.to_cancel(), [])
        self.assertTrue(all(d.action == "skip" for d in result.decisions))


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
        exp = make_run(event="push", branch="exp/a", name="canary", age=10)
        runs = [main_run, idle_merged, exp]
        jobs = {main_run["id"]: main_jobs, idle_merged["id"]: mac_jobs(running=1, label="macos-26"),
                exp["id"]: mac_jobs(queued=2)}
        prs = {"merged-branch": [make_pr(1, state="MERGED")]}
        result = plan(runs, jobs, prs, max_cancels=1)
        self.assertEqual([c.category for c in result.to_cancel()], ["experiment"])

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
        # Label-dropped only ever judges a run at its open PR's head, so it is listed, never cancelled.
        self.assertEqual([(d.candidate.run["id"], d.candidate.category, d.action, d.note) for d in result.decisions],
                         [(old["id"], "label-dropped", "skip", janitor.OPEN_HEAD_RULE)])

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

    def test_an_open_pr_older_than_the_five_newest_is_still_seen(self):
        query, _ = janitor.graphql_query("manaflow-ai", "cmux", ["a"])
        self.assertIn("o0: pullRequests(headRefName: $b0, states: [OPEN], first: 20)", query)
        newest = [make_pr(n, state="CLOSED", head="zzz") for n in range(10, 15)]
        response = {"data": {"repository": {"b0": {"nodes": newest},
                                            "o0": {"nodes": [make_pr(3, head="aaa"), make_pr(12, head="zzz")]}}}}
        prs = janitor.parse_graphql_prs(response, ["a"])["a"]
        self.assertEqual([pr["number"] for pr in prs], [10, 11, 12, 13, 14, 3])
        run = make_run(event="push", branch="a", sha="aaa")
        self.assertEqual(janitor.open_pr_at_head(run, prs)["number"], 3)

    def test_a_branch_with_more_open_prs_than_were_read_fails_closed(self):
        query, _ = janitor.graphql_query("manaflow-ai", "cmux", ["a"])
        self.assertIn("pageInfo { hasNextPage }", query.split("o0:")[1])
        response = {"data": {"repository": {
            "b0": {"nodes": [make_pr(9, state="MERGED", head="aaa")]},
            "o0": {"pageInfo": {"hasNextPage": True}, "nodes": [make_pr(n, head="zzz") for n in range(20)]}}}}
        prs = janitor.parse_graphql_prs(response, ["a"])["a"]
        for event in ("pull_request", "push"):
            with self.subTest(event=event):
                run = make_run(event=event, branch="a", sha="aaa", prs=(9,))
                self.assertTrue(janitor.open_pr_at_head(run, prs).get(janitor.OPEN_PRS_UNREAD))
                # Even the merged PR's run, which category b would cancel, is left alone on that branch.
                result = plan([run], {run["id"]: mac_jobs(running=1)}, {"a": prs})
                self.assertEqual([d.action for d in result.decisions], ["skip"] if event == "pull_request" else [])
        # The marker is invisible to the other readers.
        self.assertIsNone(janitor.resolve_pull_request(make_run(branch="a", sha="aaa", prs=(1,)), prs[-1:]))
        self.assertEqual(janitor.lost_pr_state(make_run(event="push", branch="a", sha="aaa"), prs[-1:])[0], "stale")


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

    def test_kit_markers_cover_same_repo_pr_push_and_dispatch(self):
        for kind in ("pull_request", "push", "workflow_dispatch"):
            with self.subTest(event=kind):
                run = self.run_of(event=kind, path=".github/workflows/cmux-next-ios-kit.yml")
                self.assertTrue(janitor.may_hold_owned_pool(run, []))
                self.assertFalse(janitor.may_hold_owned_pool(
                    {**run, "head_repository": {"id": 2}}, []))

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

    def test_a_run_that_starts_no_sweep_never_evicts_a_waiting_sweep(self):
        # The concurrency group keeps one run going and one waiting, and each new arrival cancels the
        # waiting one. The CI runs of pull requests into feat-cmux-next start no sweep (the job's `if`),
        # but with the whole workflow in the group they still arrived there and cancelled the real sweep
        # that was waiting: on 2026-10-30 they were 238 of the janitor's last 400 runs, crons were
        # cancelled within seconds of being queued, and after 17:57Z no snapshot was written until the
        # 18:14 cron (the pool snapshot was 50 minutes old). Such a run gets a group of its own now.
        workflow = yaml.safe_load(self.text)
        no_sweep = ("github.event_name == 'workflow_run' && "
                    "github.event.workflow_run.pull_requests[0].base.ref == 'feat-cmux-next'")
        self.assertEqual(workflow["jobs"]["sweep"]["if"], "${{ !(" + no_sweep + ") }}")
        self.assertEqual(workflow["concurrency"], {
            "group": "${{ (" + no_sweep + ") && format('ci-queue-janitor-noop-{0}', github.run_id) "
                     "|| 'ci-queue-janitor' }}",
            "cancel-in-progress": False,
        })

    def test_a_long_sweep_still_publishes_its_snapshot(self):
        # The snapshot is uploaded by the last step, which a job timeout skips. Sweeps listing the whole
        # queue took up to 13 minutes on 2026-10-30, and two in a row hit the 10-minute timeout at
        # 17:46Z and 17:58Z, so neither published. The job gets room for the longest sweep seen.
        workflow = yaml.safe_load(self.text)
        self.assertGreaterEqual(workflow["jobs"]["sweep"]["timeout-minutes"], 15)

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
        # No pull_request trigger (the concurrency group reads workflow_run.pull_requests, which is no trigger).
        self.assertNotIn("pull_request", text.split("jobs:")[0].replace("pull-requests: read", "")
                         .replace("workflow_run.pull_requests[0]", ""))
        self.assertIn("\npermissions: {}\n", text)
        self.assertIn("  sweep:\n    permissions:\n      actions: write\n      pull-requests: read\n      contents: read\n", text)
        # It mints GLAEDA_ROUTE_APP_KEY and CMUX_BOT_APP_KEY: RUNNER_POOLS and LINUX_RUNNER move it only
        # among the Blacksmith Linux sizes the expression names (tests/test_ci_fork_runner_routing.py).
        self.assertIn("runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || contains(fromJSON('[\"blacksmith-4vcpu-ubuntu-2404\",\"blacksmith-8vcpu-ubuntu-2404\",\"blacksmith-16vcpu-ubuntu-2404\",\"blacksmith-32vcpu-ubuntu-2404\"]'), fromJSON(vars.RUNNER_POOLS || '{}').linux) && fromJSON(vars.RUNNER_POOLS || '{}').linux || contains(fromJSON('[\"blacksmith-4vcpu-ubuntu-2404\",\"blacksmith-8vcpu-ubuntu-2404\",\"blacksmith-16vcpu-ubuntu-2404\",\"blacksmith-32vcpu-ubuntu-2404\"]'), vars.LINUX_RUNNER) && vars.LINUX_RUNNER || 'blacksmith-4vcpu-ubuntu-2404' }}", text)
        self.assertIn("concurrency:\n  group: ${{ (github.event_name == 'workflow_run'", text)
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


class SweepRunnerTests(unittest.TestCase):
    """The sweep follows the mirrored Linux pool member, even when LINUX_RUNNER is stale.

    On 2026-11-01 LINUX_RUNNER stayed on blacksmith-32vcpu-ubuntu-2404 while that size stalled;
    the janitor's route must follow RUNNER_POOLS.linux after the mirror moves to a live member.
    Every sweep from 05:43Z queued on 32 vCPU, so none ran, and job 124762739841 (web-subarea-scope,
    run 41275619982) waited 50 minutes with no janitor to fail it over.
    """

    def runner(self, variables: dict[str, str]) -> str:
        """The label the sweep's runs-on yields in manaflow-ai with these repository variables."""
        spec = importlib.util.spec_from_file_location("fork_routing", ROOT / "tests" / "test_ci_fork_runner_routing.py")
        routing = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(routing)
        expression = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]["sweep"]["runs-on"]
        tree = routing.parse_expression(re.fullmatch(r"\$\{\{(.*)\}\}", expression.strip(), re.DOTALL).group(1))
        context = {"github.repository_owner": "manaflow-ai",
                   **{f"vars.{name}": value for name, value in variables.items()}}

        def value(node: tuple) -> object:
            kind = node[0]
            if kind == "or":
                result: object = None
                for child in node[1]:
                    result = value(child)
                    if result:
                        return result
                return result
            if kind == "and":
                result = None
                for child in node[1]:
                    result = value(child)
                    if not result:
                        return result
                return result
            if kind == "literal":
                return node[1][1:-1]
            if kind == "ref":
                return context.get(node[1], "")
            if kind == "cmp":
                return (str(value(node[2])).lower() == str(value(node[3])).lower()) == (node[1] == "==")
            if kind == "call" and node[1] == "fromJSON":
                parsed = json.loads(str(value(node[2][0])))
                for key in (node[3].lstrip(".").split(".") if len(node) > 3 and node[3] else ()):
                    parsed = parsed.get(key, "") if isinstance(parsed, dict) else ""
                return parsed
            if kind == "call" and node[1] == "contains":
                haystack, needle = (value(arg) for arg in node[2])
                return any(str(item).lower() == str(needle).lower() for item in haystack)
            raise AssertionError(f"unexpected node {node!r}")

        return str(value(tree))

    def test_a_stalled_linux_runner_size_does_not_hold_the_sweep(self):
        # The pool moved to 16 vCPU while the legacy mirror stayed stale at 32 vCPU.
        frozen = {"LINUX_RUNNER": "blacksmith-32vcpu-ubuntu-2404",
                  "RUNNER_POOLS": json.dumps({"linux": "blacksmith-16vcpu-ubuntu-2404",
                                              "_dead": {"blacksmith-32vcpu-ubuntu-2404": "2026-11-01T05:30:00Z"}})}
        self.assertEqual(self.runner(frozen), "blacksmith-16vcpu-ubuntu-2404")

    def test_eight_vcpu_pool_member_wins_over_stale_linux_runner(self):
        frozen = {"LINUX_RUNNER": "blacksmith-32vcpu-ubuntu-2404",
                  "RUNNER_POOLS": json.dumps({"linux": "blacksmith-8vcpu-ubuntu-2404"})}
        self.assertEqual(self.runner(frozen), "blacksmith-8vcpu-ubuntu-2404")

    def test_falls_back_to_linux_runner_then_four_vcpu(self):
        self.assertEqual(self.runner({"LINUX_RUNNER": "blacksmith-32vcpu-ubuntu-2404"}), "blacksmith-32vcpu-ubuntu-2404")
        self.assertEqual(self.runner({"RUNNER_POOLS": json.dumps({"linux": "blacksmith-8vcpu-ubuntu-2404"}),
                                      "LINUX_RUNNER": "cmux-lawrence"}), "blacksmith-4vcpu-ubuntu-2404")
        self.assertEqual(self.runner({}), "blacksmith-4vcpu-ubuntu-2404")


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

    def test_main_schedule_and_testflight_orphans_are_cancelled(self):
        for kwargs in (
            dict(event="schedule", branch="main", name="iOS TestFlight (cmux.app)",
                 path=".github/workflows/ios-appstore-upload.yml"),
            dict(event="issue_comment", branch="main", name="Claude Code", path=".github/workflows/claude.yml"),
            # ci.yml's run-name carries routing metadata such as release=arm64.
            # Run 40039647633 held main's CI concurrency group for two days
            # because that word made the orphan pass read it as a release.
            dict(event="workflow_dispatch", branch="main",
                 name="v1;sha=b42fd54913fa92017bc08195148f70755fb93288;ref=main;cache=r2;release=arm64;coverage=full",
                 path=".github/workflows/ci.yml"),
        ):
            with self.subTest(**kwargs):
                decisions = orphan_plan(self.orphans(1, **kwargs))
                self.assertEqual([d.action for d in decisions], ["cancel"])

    def test_nightly_dev_and_promote_orphans_are_only_reported(self):
        # Run 40428578701 (cmux NEXT DEV daily, a publish) was cancelled as an orphan on 2026-10-27:
        # its verify job had waited 126 minutes for a runner. Waiting is not "stuck past its timeout".
        for kwargs in (
            dict(event="workflow_dispatch", branch="feat-cmux-next", name="cmux NEXT DEV daily · sign 1",
                 path=".github/workflows/cmux-next-dev-daily.yml"),
            # The DEV source build: cmux-next.yml dispatched with dev_daily=true (run 40426912368, the
            # same sweep, `cmux NEXT DEV Release compile` queued 2h16m).
            dict(event="workflow_dispatch", branch="feat-cmux-next",
                 name="cmux NEXT DEV daily · bf4461675b1c6321a8c93ff5310ed46d42a51998",
                 path=".github/workflows/cmux-next.yml"),
            dict(event="schedule", branch="main", name="cmux NEXT DEV daily dispatch",
                 path=".github/workflows/cmux-next-dev-daily-dispatch.yml"),
            dict(event="push", branch="main", name="Nightly macOS build", path=".github/workflows/nightly.yml"),
            dict(event="push", branch="nightly-next", name="Nightly macOS build",
                 path=".github/workflows/nightly.yml"),
            dict(event="workflow_run", branch="main", name="Nightly sign", path=".github/workflows/nightly-sign.yml"),
            dict(event="schedule", branch="main", name="nightly-next train",
                 path=".github/workflows/nightly-next-train.yml"),
            dict(event="workflow_dispatch", branch="feat-cmux-next", name="cmux-tui nightly",
                 path=".github/workflows/cmux-tui-nightly.yml"),
        ):
            with self.subTest(**kwargs):
                decisions = orphan_plan(self.orphans(1, **kwargs))
                self.assertEqual([d.action for d in decisions], ["skip"])
                self.assertIn("delivery workflow", decisions[0].note)
        # Any other cmux-next.yml dispatch is still an ordinary orphan.
        tip_suite = dict(event="workflow_dispatch", branch="feat-cmux-next", path=".github/workflows/cmux-next.yml",
                         name="cmux-next tip Swift suite · bf4461675b1c6321a8c93ff5310ed46d42a51998")
        self.assertEqual([d.action for d in orphan_plan(self.orphans(1, **tip_suite))], ["cancel"])
        # A generic `name` with the DEV title only in `display_title` is still a DEV run.
        titled = self.orphans(1, event="workflow_dispatch", branch="feat-cmux-next", name="cmux-next",
                              path=".github/workflows/cmux-next.yml")
        titled[0].run["display_title"] = "cmux NEXT DEV daily · bf4461675b1c6321a8c93ff5310ed46d42a51998"
        self.assertEqual([d.action for d in orphan_plan(titled)], ["skip"])
        for kwargs in (dict(event="workflow_dispatch", branch="feat-cmux-next", name="Cloud VM image promote",
                            path=".github/workflows/cloud-vm-image-promote.yml"),):
            self.assertEqual([d.action for d in orphan_plan(self.orphans(1, **kwargs))], ["skip"])

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
        # Superseded: nobody reads it, so it goes.
        self.assertEqual([d.action for d in orphan_plan(orphans, {"keep-me": [make_pr(7, head="bbb")]})], ["cancel"])

    def test_an_orphan_at_an_open_pr_head_is_never_cancelled(self):
        for event in ("pull_request", "push", "workflow_dispatch", "pull_request_review", "workflow_run"):
            with self.subTest(event=event):
                orphans = self.orphans(1, event=event, branch="keep-me", prs=(7,))
                decisions = orphan_plan(orphans, {"keep-me": [make_pr(7)]})
                self.assertEqual([d.action for d in decisions], ["skip"])
                self.assertIn(janitor.OPEN_HEAD_RULE, decisions[0].note)

    def test_orphan_pr_branches_are_resolved(self):
        orphans = self.orphans(1, branch="pr-branch") + self.orphans(1, kind="ghost", event="push", branch="exp/x")
        # Any event's branch too: an open pull request at its head keeps it (open_pr_at_head()).
        orphans += self.orphans(1, event="pull_request_review", branch="reviewed")
        self.assertEqual(janitor.orphan_branches(orphans, NOW), ["exp/x", "pr-branch", "reviewed"])
        protected = self.orphans(1, event="push", branch="feat-cmux-next", path=".github/workflows/cmux-next.yml")
        self.assertEqual(janitor.orphan_branches(protected, NOW), [])


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
            # b<i>: the branch's newest pull requests; o<i>: its open ones (a dict entry may be shared, as GitHub's are).
            repository = {key: {"nodes": self.prs.get(branch, [])} for key, branch in variables.items()
                          if re.fullmatch(r"b[0-9]+", key)}
            repository.update({"o" + key[1:]: {"nodes": [pr for pr in self.prs.get(branch, [])
                                                         if pr.get("state") == "OPEN"]}
                               for key, branch in variables.items() if re.fullmatch(r"b[0-9]+", key)})
            return {"data": {"repository": repository}}
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
        if method == "POST" and parts[2] == "jobs" and parts[-1] == "rerun":
            return {}
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


def nightly_run(sha, age, *, status="queued", branch="nightly-next"):
    run = make_run(event="push", branch=branch, path=".github/workflows/nightly.yml", name="Nightly macOS build",
                   status=status, sha=sha, age=age)
    run["workflow_id"] = 234270400
    return run


def gate_jobs(age, *, build=None):
    """Run 40505473184's shape: light control jobs done in minutes, `build-nightly-app` queued for a Mac."""
    jobs = [{"name": "decide", "status": "completed", "conclusion": "success", "labels": [LINUX],
             "runner_name": "r1", "started_at": iso(age), "completed_at": iso(age - 1)},
            {"name": "resolve-nightly-cmux-tui-client", "status": "completed", "conclusion": "success", "labels": [LINUX],
             "runner_name": "r2", "started_at": iso(age - 1), "completed_at": iso(age - 4)},
            {"name": "promote-nightly-next", "status": "completed", "conclusion": "skipped", "labels": [LINUX],
             "started_at": iso(age), "completed_at": iso(age)},
            # GitHub sets a queued job's started_at when it is queued.
            {"name": "build-nightly-app", "status": "queued", "conclusion": None, "labels": [MAC],
             "runner_name": None, "started_at": iso(age - 2), "completed_at": None}]
    if build:
        jobs[-1].update(build)
    return jobs


def building_jobs(age):
    """A newer run with its app build running on a Mac."""
    return gate_jobs(age, build={"status": "in_progress", "runner_name": "mini-1"})


TIP = "ccb74c4d"  # the nightly-next tip in the superseded-run tests


class SupersededDeliveryTests(unittest.TestCase):
    """Leo, 2026-10-26: "When nightly runs for older commits are stuck waiting (queued for a runner or a gate),
    skip them and build from the tip: cancel the stale runs and move the nightly branch to the tip". sr2,
    2026-10-28: a run is stale only when every job but the light control and decide ones is still queued, it has
    waited at least 20 min, and a newer tip run is already building."""

    def judge(self, old, old_jobs, runs, newer_jobs=None, tip="ccb74c4d"):
        # Every newer run is building the same jobs unless told otherwise; the branch tip is ccb74c4d.
        return janitor.superseded_unstarted(old, old_jobs, runs,
                                            lambda other: (newer_jobs or {}).get(other["id"], building_jobs(10)),
                                            tip_sha=tip, now=NOW)

    def test_unstarted_on_a_superseded_head_is_skipped(self):
        old, new = nightly_run("864dceb6", 60), nightly_run("ccb74c4d", 20)
        ok, why = self.judge(old, gate_jobs(60), [old, new])
        self.assertTrue(ok, why)
        self.assertIn(str(new["id"]), why)

    def test_a_started_build_on_an_old_head_is_kept(self):
        old, new = nightly_run("864dceb6", 60), nightly_run("ccb74c4d", 20)
        for build in ({"status": "in_progress", "runner_name": "mini-1"},          # running
                      {"runner_name": "mini-1"},                                    # queued, but has a runner
                      {"status": "completed", "conclusion": "success", "runner_name": "mini-1",
                       "completed_at": iso(5)}):                                    # ran on a Mac
            with self.subTest(build=build):
                ok, why = self.judge(old, gate_jobs(60, build=build), [old, new])
                self.assertFalse(ok)
                self.assertIn("started", why)
        # Any job past the light control and decide ones that ran, on Linux too, has started the run.
        for job in ({"name": "publish-nightly", "labels": [LINUX]},
                    {"name": "build nightly inputs", "labels": [LINUX]}):
            with self.subTest(job=job):
                jobs = gate_jobs(60)
                jobs[1] = {**jobs[1], **job}
                self.assertFalse(self.judge(old, jobs, [old, new])[0])

    def test_unstarted_with_no_newer_head_run_is_kept(self):
        old = nightly_run("864dceb6", 60)
        same_head = nightly_run("864dceb6", 30)
        cancelled = {**nightly_run("ccb74c4d", 20), "status": "completed", "conclusion": "cancelled"}
        failed = {**nightly_run("ccb74c4d", 20), "status": "completed", "conclusion": "failure"}
        fork = nightly_run("ccb74c4d", 20)
        fork["head_repository"] = {"full_name": "someone/cmux", "owner": {"login": "someone"}}
        dispatched = {**nightly_run("ccb74c4d", 20), "event": "workflow_dispatch"}
        ordinary = {**nightly_run("ccb74c4d", 20), "path": ".github/workflows/cmux-next.yml", "workflow_id": 9,
                    "name": "cmux-next", "display_title": "cmux-next tip Swift suite"}
        other_branch = nightly_run("ccb74c4d", 20, branch="main")
        other_workflow = {**nightly_run("ccb74c4d", 20), "workflow_id": 1, "path": ".github/workflows/ci.yml"}
        older = nightly_run("0ldhead0", 90)
        no_status = {**nightly_run("ccb74c4d", 20), "status": None}
        rerun = {**nightly_run("ccb74c4d", 20), "run_attempt": 2}
        for others in ([no_status], [rerun], [], [same_head], [cancelled], [failed], [fork], [dispatched], [other_branch], [other_workflow],
                       [older]):
            with self.subTest(others=others):
                ok, why = self.judge(old, gate_jobs(60), [old, *others])
                self.assertFalse(ok)
                self.assertIn("no newer head", why)
        self.assertFalse(self.judge(old, None, [old, nightly_run("ccb74c4d", 20)])[0])
        # Without a way to read the newer run's jobs, nothing is skipped.
        self.assertFalse(janitor.superseded_unstarted(old, gate_jobs(60), [old, nightly_run("ccb74c4d", 20)], tip_sha=TIP, now=NOW)[0])
        # A shared workflow's DEV delivery run is not superseded by an ordinary run of that workflow.
        dev = {**nightly_run("864dceb6", 60), "path": ".github/workflows/cmux-next.yml", "workflow_id": 9,
               "name": "cmux-next", "display_title": "cmux NEXT DEV daily · 864dceb6"}
        self.assertFalse(self.judge(dev, gate_jobs(60), [dev, {**ordinary, "event": "push"}])[0])
        self.assertTrue(self.judge(
            dev, gate_jobs(60), [dev, {**ordinary, "display_title": "cmux NEXT DEV daily · ccb74c4d"}])[0])

    def test_a_newer_run_that_does_not_do_the_build_does_not_supersede(self):
        # A cache-only warmup or a throttled push at a newer head skips the app build; one still deciding has not
        # listed it; an unreadable one proves nothing.
        old, new = nightly_run("864dceb6", 60), nightly_run("ccb74c4d", 20)
        skipped = gate_jobs(20, build={"status": "completed", "conclusion": "skipped", "runner_name": None})
        deciding = gate_jobs(20)[:1]
        unknown = gate_jobs(20, build={"status": None})
        for newer_jobs in (skipped, deciding, unknown, None):
            with self.subTest(newer_jobs=newer_jobs):
                ok, why = janitor.superseded_unstarted(old, gate_jobs(60), [old, new], lambda other: newer_jobs, tip_sha=TIP, now=NOW)
                self.assertFalse(ok)
                self.assertIn("building in its place", why)
        # An old run still at its gates (only `decide` queued) is not matched to anything: a cache-only run's
        # `decide` succeeds too.
        at_gates = [{"name": "decide", "status": "queued", "labels": [LINUX], "runner_name": None, "started_at": iso(60)}]
        ok, why = janitor.superseded_unstarted(old, at_gates, [old, new], lambda other: skipped, tip_sha=TIP, now=NOW)
        self.assertFalse(ok)
        self.assertIn("condition 3 fails", why)
        # A newer run that skipped a gate the old one ran (a different path) is not the same build either.
        other_path = gate_jobs(20)
        other_path[1] = {**other_path[1], "status": "completed", "conclusion": "skipped"}
        self.assertFalse(janitor.superseded_unstarted(old, gate_jobs(60), [old, new], lambda other: other_path, tip_sha=TIP, now=NOW)[0])
        # Two newer runs: the tip's is cache-only, an older head's is building. The tip itself must be building.
        building = nightly_run("e3ca669f", 30)
        ok, why = self.judge(old, gate_jobs(60), [old, building, new], {new["id"]: skipped})
        self.assertFalse(ok, why)
        self.assertTrue(self.judge(old, gate_jobs(60), [old, building, new], {new["id"]: skipped}, tip="e3ca669f")[0])
        # An unread tip is never stale.
        self.assertIn("could not be read", self.judge(old, gate_jobs(60), [old, new], tip="")[1])

    def test_a_rerun_is_kept(self):
        # Only the latest attempt's jobs are read; an earlier attempt may have built.
        old, new = {**nightly_run("864dceb6", 60), "run_attempt": 2}, nightly_run("ccb74c4d", 20)
        ok, why = self.judge(old, gate_jobs(60), [old, new])
        self.assertFalse(ok)
        self.assertIn("attempt 2", why)
        for broken in ({"run_attempt": None}, {"status": None}, {"status": "completed"}, {"status": "weird"}):
            with self.subTest(broken=broken):
                self.assertFalse(self.judge({**old, "run_attempt": 1, **broken}, gate_jobs(60), [old, new])[0])

    def test_a_queued_rerun_after_an_attempt_that_built_is_a_candidate(self):
        # A re-run of a build that ran is a new build; its attempt's own jobs say whether it started.
        old = {**nightly_run("864dceb6", 60), "run_attempt": 2}
        built = {"name": "build-nightly-app", "status": "completed", "conclusion": "failure", "labels": [MAC],
                 "runner_name": "mini-1", "started_at": iso(90), "completed_at": iso(80), "run_attempt": 1}
        jobs = [built, *({**job, "run_attempt": 2} for job in gate_jobs(60))]
        self.assertEqual(janitor.superseded_candidates([old], {old["id"]: jobs}), [old])
        self.assertEqual(janitor.superseded_candidates([old], {old["id"]: gate_jobs(60)}), [])  # attempts unread

    def sweep(self, runs, jobs, *, completed=(), dry_run=False, prs=None, rejob=None, extra_runs=(), tip=TIP):
        fake = FakeGitHub({r["id"]: dict(r) for r in [*runs, *extra_runs]}, jobs)
        fake.branches = {"nightly-next": tip}
        fake.completed["nightly.yml"] = list(completed)
        fake.prs = prs or {}
        if rejob:  # what the re-read right before the cancel sees
            fake.job_map = {**jobs, **rejob}
        candidates = janitor.superseded_candidates(runs, jobs)
        decisions, failures = janitor.skip_superseded_delivery(fake, candidates, runs, jobs, fake.prs,
                                                               dry_run=dry_run, now=NOW)
        return fake, {d.run["id"]: d for d in decisions}, failures

    def test_the_sweep_cancels_every_superseded_unstarted_run_and_keeps_the_tip(self):
        a, b, tip = nightly_run("864dceb6", 70), nightly_run("5cec7c8d", 50), nightly_run("ccb74c4d", 20)
        started = nightly_run("e3ca669f", 40)
        jobs = {a["id"]: gate_jobs(70), b["id"]: gate_jobs(50), tip["id"]: building_jobs(20),
                started["id"]: gate_jobs(40, build={"status": "in_progress", "runner_name": "mini-1"})}
        fake, decided, failures = self.sweep([a, b, started, tip], jobs)
        self.assertEqual(failures, 0)
        self.assertEqual({k for k, d in decided.items() if d.action == "cancel"}, {a["id"], b["id"]})
        self.assertNotIn(started["id"], decided)  # a started build is never a candidate
        self.assertNotIn(tip["id"], decided)  # the tip is building, so never a candidate
        self.assertEqual(sorted(fake.posts()), sorted([[str(a["id"]), "cancel"], [str(b["id"]), "cancel"]]))

    def test_an_unread_or_moved_tip_keeps_the_run(self):
        old, tip = nightly_run("864dceb6", 70), nightly_run("ccb74c4d", 20)
        jobs = {old["id"]: gate_jobs(70), tip["id"]: building_jobs(20)}
        for head in ("", "ffffffff"):  # gone (404) or moved past every run the sweep knows
            with self.subTest(head=head):
                fake, decided, _ = self.sweep([old, tip], jobs, tip=head)
                self.assertEqual(decided[old["id"]].action, "keep")
                self.assertIn("condition 3", decided[old["id"]].note)
                self.assertEqual(fake.posts(), [])

    def test_the_20_minute_wait_on_a_fixed_clock(self):
        old, new = nightly_run("864dceb6", 60), nightly_run("ccb74c4d", 20)
        # gate_jobs(age): the last job movement is `age - 4` minutes ago.
        self.assertTrue(self.judge(old, gate_jobs(24), [old, new])[0])
        ok, why = self.judge(old, gate_jobs(23), [old, new])
        self.assertFalse(ok)
        self.assertIn("condition 2 fails: it has waited 19 min", why)

    def test_a_dry_run_cancels_nothing(self):
        old, tip = nightly_run("864dceb6", 70), nightly_run("ccb74c4d", 20)
        fake, decided, _ = self.sweep([old, tip], {old["id"]: gate_jobs(70), tip["id"]: building_jobs(20)},
                                      dry_run=True)
        self.assertEqual(decided[old["id"]].action, "cancel")
        self.assertEqual(fake.posts(), [])

    def test_a_build_that_starts_before_the_cancel_is_kept(self):
        old, tip = nightly_run("864dceb6", 70), nightly_run("ccb74c4d", 20)
        jobs = {old["id"]: gate_jobs(70), tip["id"]: building_jobs(20)}
        rejob = {old["id"]: gate_jobs(70, build={"status": "in_progress", "runner_name": "mini-1"})}
        fake, decided, _ = self.sweep([old, tip], jobs, rejob=rejob)
        self.assertEqual(decided[old["id"]].action, "keep")
        self.assertIn("on re-read", decided[old["id"]].note)
        self.assertEqual(fake.posts(), [])

    def test_a_replacement_that_fails_before_the_cancel_keeps_the_old_run(self):
        old, tip = nightly_run("864dceb6", 70), nightly_run("ccb74c4d", 20)
        jobs = {old["id"]: gate_jobs(70), tip["id"]: building_jobs(20)}
        fake = FakeGitHub({r["id"]: dict(r) for r in (old, tip)}, jobs)
        fake.branches = {"nightly-next": tip["head_sha"]}
        fake.runs[tip["id"]].update(status="completed", conclusion="cancelled")  # what the re-read sees
        candidates = janitor.superseded_candidates([old, tip], jobs)
        decisions, _ = janitor.skip_superseded_delivery(fake, candidates, [old, tip], jobs, {}, dry_run=False, now=NOW)
        self.assertEqual({d.run["id"]: d.action for d in decisions}[old["id"]], "keep")
        self.assertEqual(fake.posts(), [])

    def test_a_pr_opened_at_the_head_during_the_sweep_keeps_the_run(self):
        old, tip = nightly_run("864dceb6", 70), nightly_run("ccb74c4d", 20)
        jobs = {old["id"]: gate_jobs(70), tip["id"]: building_jobs(20)}
        fake = FakeGitHub({r["id"]: dict(r) for r in (old, tip)}, jobs)
        fake.branches = {"nightly-next": tip["head_sha"]}
        fake.prs = {"nightly-next": [make_pr(9, head="864dceb6")]}  # what the re-read sees; the snapshot had none
        candidates = janitor.superseded_candidates([old, tip], jobs)
        decisions, _ = janitor.skip_superseded_delivery(fake, candidates, [old, tip], jobs, {}, dry_run=False, now=NOW)
        self.assertIn("open PR #9", {d.run["id"]: d.note for d in decisions}[old["id"]])
        self.assertEqual(fake.posts(), [])

    def test_a_gate_with_no_conclusion_is_unread(self):
        old, new = nightly_run("864dceb6", 60), nightly_run("ccb74c4d", 20)
        jobs = gate_jobs(60)
        jobs[1] = {**jobs[1], "conclusion": None}
        ok, why = self.judge(old, jobs, [old, new])
        self.assertFalse(ok)
        self.assertIn("unknown conclusion", why)

    def test_a_newer_run_that_skips_the_build_sends_the_sweep_to_the_branch_listing(self):
        old, cache_only = nightly_run("864dceb6", 70), nightly_run("e3ca669f", 40)
        done = {**nightly_run("ccb74c4d", 20, status="completed"), "conclusion": "success"}
        skipped = gate_jobs(40, build={"status": "completed", "conclusion": "skipped", "runner_name": None})
        built = gate_jobs(20, build={"status": "completed", "conclusion": "success", "runner_name": "mini-1"})
        fake, decided, _ = self.sweep([old, cache_only], {old["id"]: gate_jobs(70), cache_only["id"]: skipped},
                                      completed=[done], rejob={done["id"]: built}, extra_runs=[done])
        self.assertEqual(decided[old["id"]].action, "cancel", decided[old["id"]].note)

    def test_a_full_jobs_listing_is_unread(self):
        old = nightly_run("864dceb6", 60)
        full = gate_jobs(60) + [dict(gate_jobs(60)[0]) for _ in range(100 * janitor.MAX_JOB_PAGES)]
        self.assertEqual(janitor.superseded_candidates([old], {old["id"]: full}), [])
        self.assertIsNone(janitor.complete_jobs(full))

    def test_matrix_legs_need_a_leg_each(self):
        old, new = nightly_run("864dceb6", 60), nightly_run("ccb74c4d", 20)
        two = gate_jobs(60) + [dict(gate_jobs(60)[-1])]  # two `build-nightly-app` legs
        one = building_jobs(20)
        self.assertFalse(janitor.superseded_unstarted(old, two, [old, new], lambda other: one, tip_sha=TIP, now=NOW)[0])
        self.assertTrue(janitor.superseded_unstarted(old, two, [old, new], lambda other: one + [dict(one[-1])], tip_sha=TIP, now=NOW)[0])

    def test_a_finished_newer_run_is_found_by_one_branch_listing(self):
        old = nightly_run("864dceb6", 70)
        done = {**nightly_run("ccb74c4d", 20, status="completed"), "conclusion": "success"}
        built = gate_jobs(20, build={"status": "completed", "conclusion": "success", "runner_name": "mini-1"})
        fake, decided, _ = self.sweep([old], {old["id"]: gate_jobs(70)}, completed=[done], rejob={done["id"]: built},
                                      extra_runs=[done])
        self.assertEqual(decided[old["id"]].action, "cancel")
        self.assertEqual([p for m, p in fake.log if "/actions/workflows/" in p],
                         ["/repos/manaflow-ai/cmux/actions/workflows/nightly.yml/runs?branch=nightly-next&per_page=20"])

    def test_a_run_at_an_open_prs_head_is_kept(self):
        old, tip = nightly_run("864dceb6", 70), nightly_run("ccb74c4d", 20)
        prs = {"nightly-next": [make_pr(7, head="864dceb6")]}
        fake, decided, _ = self.sweep([old, tip], {old["id"]: gate_jobs(70), tip["id"]: building_jobs(20)}, prs=prs)
        self.assertEqual(decided[old["id"]].action, "keep")
        self.assertEqual(fake.posts(), [])

    def test_ordinary_runs_are_never_candidates(self):
        ci = make_run(status="queued", sha="old")
        self.assertEqual(janitor.superseded_candidates([ci], {ci["id"]: gate_jobs(60)}), [])


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


class RestLineTests(unittest.TestCase):
    """The summary says what a sweep spent, by endpoint, so a change in REST use shows in its log."""

    def test_requests_are_counted_by_kind_and_printed_most_first(self):
        self.assertEqual(janitor.request_kind("GET", "/repos/o/r/actions/runs/12/jobs?page=1", "o/r"),
                         "GET /actions/runs/{id}/jobs")
        self.assertEqual(janitor.request_kind("POST", "/graphql", "o/r"), "POST /graphql")
        self.assertEqual(janitor.rest_line({"GET /a": 1, "GET /b": 3}), "REST by kind: GET /b 3, GET /a 1")
        self.assertEqual(janitor.rest_line({}), "REST by kind: none")
        github = janitor.GitHub("t", "manaflow-ai/cmux")

        class Response(io.BytesIO):
            headers = email.message.Message()

        with mock.patch.object(janitor.urllib.request, "urlopen", lambda request, timeout=30: Response(b"{}")):
            github.request("GET", "/repos/manaflow-ai/cmux/actions/runs/1/jobs?page=1")
            github.request("GET", "/repos/manaflow-ai/cmux/actions/runs/2/jobs?page=1")
            github.request("GET", "/repos/manaflow-ai/cmux/actions/runs?status=queued")
        self.assertEqual(github.kinds, {"GET /actions/runs/{id}/jobs": 2, "GET /actions/runs": 1})


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

    def test_requests_in_flight_when_the_app_token_is_refused_all_move_to_the_workflow_token(self):
        # The job listings run on several threads: every request sent with the App token before one of them
        # switched to the workflow token is made again with it, not failed for want of a fallback.
        import threading
        github = janitor.GitHub("app", "manaflow-ai/cmux", fallback_token="workflow")
        both_sent = threading.Barrier(4, timeout=5)
        sent = []

        class Response(io.BytesIO):
            headers = email.message.Message()

        def urlopen(request, timeout=30):
            token = request.get_header("Authorization")
            sent.append(token)
            if token == "Bearer app":
                both_sent.wait()  # all four are in flight with the App token before any is refused
                raise urllib.error.HTTPError(request.full_url, 401, "bad credentials", email.message.Message(), None)
            return Response(b'{"jobs": []}')

        runs = [make_run(status="queued", age=age, branch=f"b{age}") for age in range(1, 5)]
        with mock.patch.object(janitor.urllib.request, "urlopen", urlopen), mock.patch("builtins.print"), \
                mock.patch.object(janitor.time, "sleep", lambda _: None):
            jobs, unread, _ = janitor.read_run_jobs(github, runs, frozenset(), NOW, workers=4)
        self.assertEqual(unread, set())
        self.assertEqual(set(jobs), {run["id"] for run in runs})
        self.assertEqual(sorted(sent), ["Bearer app"] * 4 + ["Bearer workflow"] * 4)
        # A refusal of the workflow token itself is still an error, not a loop.
        refused = janitor.GitHub("app", "manaflow-ai/cmux", fallback_token="workflow")

        def always(request, timeout=30):
            raise urllib.error.HTTPError(request.full_url, 401, "bad credentials", email.message.Message(), None)
        with mock.patch.object(janitor.urllib.request, "urlopen", always), mock.patch("builtins.print"), \
                self.assertRaises(RuntimeError):
            refused.request("GET", "/repos/manaflow-ai/cmux/actions/runs/1/jobs")

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


RealGitHub = janitor.GitHub  # the client itself, for tests that patch janitor.GitHub with a factory


def rate_limited_http_error(request):
    headers = email.message.Message()
    headers["X-RateLimit-Remaining"] = "0"
    headers["X-RateLimit-Limit"] = "12500"
    headers["X-RateLimit-Resource"] = "core"
    return urllib.error.HTTPError(request.full_url, 403, "rate limited", headers, io.BytesIO(b"{}"))


class OutOfBudgetSweepTests(unittest.TestCase):
    """2026-10-31: the cmux-bot installation ran out at about 00:50Z and every sweep until the reset failed red.
    Running out of budget says nothing about the queue, so the sweep stops early and ends as an infra skip."""

    def sweep(self, github, temp, env=None):
        argv = ["--repo", "manaflow-ai/cmux", "--pool-load", str(Path(temp) / "load.json"),
                "--summary", str(Path(temp) / "summary.md"), "--workflows-dir", str(Path(temp) / "none")]
        printed = []
        with mock.patch.object(janitor, "GitHub", lambda token, repo, fallback_token="": github), \
                mock.patch.dict("os.environ", {"GH_TOKEN": "t", **(env or {})}), \
                mock.patch.object(janitor.time, "sleep", lambda _: None), \
                mock.patch.object(janitor, "utc_now", lambda: NOW), \
                mock.patch("builtins.print", lambda *args, **kwargs: printed.append(" ".join(map(str, args)))):
            code = janitor.main(argv)
        return code, printed

    def test_a_sweep_refused_for_its_rate_limit_ends_green_with_a_warning(self):
        github = janitor.GitHub("app", "manaflow-ai/cmux", fallback_token="workflow")
        sent = []

        def urlopen(request, timeout=30):
            sent.append(request.get_header("Authorization"))
            raise rate_limited_http_error(request)

        with tempfile.TemporaryDirectory() as temp, \
                mock.patch.object(janitor.urllib.request, "urlopen", urlopen):
            code, printed = self.sweep(github, temp)
            self.assertFalse((Path(temp) / "load.json").exists())
        self.assertEqual(code, 0)
        warnings = [line for line in printed if line.startswith("::warning title=queue janitor out of API budget::")]
        self.assertEqual(len(warnings), 1, printed)
        self.assertIn("rate limit", warnings[0])
        self.assertIn("core 0 of 12500 left", warnings[0])
        # Still never moved onto the workflow token (GitHub.request()).
        self.assertEqual(sent, ["Bearer app"])

    def test_a_rate_limit_in_the_job_listings_ends_green_too(self):
        run = make_run(status="queued", branch="limited")

        class Limited(FakeGitHub):
            def jobs(self, run_id):
                raise janitor.RateLimited("GET /actions/runs/1/jobs failed (403: rate limit)")

        with tempfile.TemporaryDirectory() as temp:
            code, printed = self.sweep(Limited({run["id"]: dict(run)}, {}), temp)
        self.assertEqual(code, 0)
        self.assertTrue(any(line.startswith("::warning title=queue janitor out of API budget::") for line in printed))

    def test_a_rate_limit_while_cancelling_ends_green_too(self):
        stale = make_run(status="queued", branch="gone", prs=(7,))
        jobs = {stale["id"]: mac_jobs(queued=1)}

        class Limited(FakeGitHub):
            # The cancel goes through the real client, which GitHub refuses for its rate limit.
            def cancel(self, run_id):
                self.log.append(("POST", f"/actions/runs/{run_id}/cancel"))
                RealGitHub._request(self, "POST", f"/repos/manaflow-ai/cmux/actions/runs/{run_id}/cancel")

        fake = Limited({stale["id"]: dict(stale)}, jobs)
        fake.prs = {"gone": [make_pr(7, state="MERGED")]}
        with tempfile.TemporaryDirectory() as temp, \
                mock.patch.object(janitor.urllib.request, "urlopen",
                                  lambda request, timeout=30: (_ for _ in ()).throw(rate_limited_http_error(request))):
            code, printed = self.sweep(fake, temp)
        self.assertIn(("POST", f"/actions/runs/{stale['id']}/cancel"), fake.log)
        self.assertEqual(code, 0, printed)
        self.assertTrue(any(line.startswith("::warning title=queue janitor out of API budget::") for line in printed))

    def test_other_failures_still_fail_the_sweep(self):
        class Broken(FakeGitHub):
            def in_flight_runs(self):
                raise RuntimeError("GET /actions/runs failed (404)")

        with tempfile.TemporaryDirectory() as temp:
            code, printed = self.sweep(Broken({}), temp)
        self.assertEqual(code, 1)
        self.assertFalse(any("out of API budget" in line for line in printed))


class BranchWorkflowCopyTests(unittest.TestCase):
    """A run follows its own branch's workflow copy. feat-cmux-next's linux-only runs were listed on every sweep
    because only main's copy was read: 573 of the 1,324 runs listed on 2026-10-31, one cmux-bot request each."""

    MAC_WORKFLOW = "jobs:\n  build:\n    runs-on: blacksmith-6vcpu-macos-15\n"
    LINUX_WORKFLOW = "jobs:\n  lint:\n    runs-on: blacksmith-4vcpu-ubuntu-2404\n"

    def workflows(self, root, branch, files):
        directory = Path(root) / branch / ".github/workflows"
        directory.mkdir(parents=True)
        for name, text in files.items():
            (directory / name).write_text(text)
        return directory

    def next_run(self, path, *, event="pull_request", prs=(5,)):
        run = make_run(event=event, branch="topic", path=path, status="queued", prs=prs)
        if event == "pull_request":
            run["pull_requests"] = [{"number": n, "base": {"ref": "feat-cmux-next"}} for n in prs]
        else:
            run["head_branch"] = "feat-cmux-next"
        return run

    def test_a_branch_run_is_listed_by_its_own_branch_copy(self):
        with tempfile.TemporaryDirectory() as temp:
            main_dir = self.workflows(temp, "main", {"guards.yml": self.MAC_WORKFLOW, "next.yml": self.LINUX_WORKFLOW})
            next_dir = self.workflows(temp, "next", {"guards.yml": self.LINUX_WORKFLOW, "next.yml": self.MAC_WORKFLOW})
            main_only = janitor.linux_only_workflow_paths(main_dir)
            branches = janitor.branch_linux_only_paths([f"feat-cmux-next={next_dir}"])
        self.assertEqual(branches, {"feat-cmux-next": frozenset({".github/workflows/guards.yml"})})
        guards = self.next_run(".github/workflows/guards.yml")
        nxt = self.next_run(".github/workflows/next.yml")
        push = self.next_run(".github/workflows/guards.yml", event="push", prs=())
        # Linux-only on feat-cmux-next: not listed, whatever main's copy says.
        self.assertFalse(janitor.needs_jobs(guards, main_only, NOW, branch_linux_only=branches))
        self.assertFalse(janitor.needs_jobs(push, main_only, NOW, branch_linux_only=branches))
        # Main's copy is inert but feat-cmux-next's schedules Macs (cmux-next.yml): still listed.
        self.assertTrue(janitor.needs_jobs(nxt, main_only, NOW, branch_linux_only=branches))
        # Without that branch's files every one of its runs is listed, as before.
        self.assertTrue(janitor.needs_jobs(guards, main_only, NOW))
        self.assertTrue(janitor.needs_jobs(guards, main_only, NOW, branch_linux_only={}))
        # A branch with no copy read (a stacked base) is listed; main's runs still follow main's copy.
        other = make_run(branch="topic", path=".github/workflows/guards.yml", status="queued")
        other["pull_requests"] = [{"number": 6, "base": {"ref": "stacked-base"}}]
        self.assertTrue(janitor.needs_jobs(other, main_only, NOW, branch_linux_only=branches))
        on_main = make_run(branch="topic", path=".github/workflows/next.yml", status="queued")
        on_main["pull_requests"] = [{"number": 8, "base": {"ref": "main"}}]
        self.assertFalse(janitor.needs_jobs(on_main, main_only, NOW, branch_linux_only=branches))
        on_main_mac = dict(on_main, path=".github/workflows/guards.yml")
        self.assertTrue(janitor.needs_jobs(on_main_mac, main_only, NOW, branch_linux_only=branches))

    def test_a_missing_or_empty_branch_copy_names_no_branch(self):
        with tempfile.TemporaryDirectory() as temp:
            empty = Path(temp) / "empty"
            empty.mkdir()
            main_dir = self.workflows(temp, "main", {"a.yml": self.LINUX_WORKFLOW})
            with mock.patch("builtins.print"):
                found = janitor.branch_linux_only_paths([
                    f"feat-cmux-next={Path(temp) / 'missing'}", f"other={empty}", f"main={main_dir}", "bad", "=x"])
        self.assertEqual(found, {})

    def test_the_sweep_lists_only_what_the_branch_copy_can_put_on_a_mac(self):
        guards = self.next_run(".github/workflows/guards.yml")
        nxt = self.next_run(".github/workflows/next.yml")
        runs = {run["id"]: dict(run) for run in (guards, nxt)}
        fake = FakeGitHub(runs, {nxt["id"]: mac_jobs(queued=1)})
        with tempfile.TemporaryDirectory() as temp:
            next_dir = self.workflows(temp, "next", {"guards.yml": self.LINUX_WORKFLOW, "next.yml": self.MAC_WORKFLOW})
            summary = Path(temp) / "summary.md"
            argv = ["--repo", "manaflow-ai/cmux", "--dry-run", "--summary", str(summary),
                    "--workflows-dir", str(Path(temp) / "none")]
            with mock.patch.object(janitor, "GitHub", lambda token, repo, fallback_token="": fake), \
                    mock.patch.dict("os.environ", {"GH_TOKEN": "t", "BRANCH_WORKFLOWS": f"feat-cmux-next={next_dir}"}), \
                    mock.patch.object(janitor, "utc_now", lambda: NOW), \
                    mock.patch("builtins.print"):
                self.assertEqual(janitor.main(argv), 0)
            text = summary.read_text()
        listed = {int(path.split("/")[-2]) for _, path in fake.log if path.split("?")[0].endswith("/jobs")}
        self.assertEqual(listed, {nxt["id"]})
        self.assertIn("1 job listings (1 more runs not listed: linux-only on their branch)", text)

    def test_the_workflow_checks_out_feat_cmux_nexts_workflows_for_the_janitor(self):
        workflow = yaml.safe_load(WORKFLOW.read_text())
        steps = workflow["jobs"]["sweep"]["steps"]
        checkout = next(step for step in steps if step.get("name") == "Check out feat-cmux-next's workflow files")
        self.assertEqual(checkout["uses"].split("@")[0], "actions/checkout")
        self.assertEqual(checkout["with"]["ref"], "feat-cmux-next")
        self.assertEqual(checkout["with"]["sparse-checkout"], ".github/workflows")
        self.assertIs(checkout["with"]["persist-credentials"], False)
        # A failed fetch only means that branch's runs are all listed, as before.
        self.assertIs(checkout["continue-on-error"], True)
        self.assertNotIn("token", checkout["with"])
        sweep = next(step for step in steps if step.get("name") == "Cancel wasted macOS runs")
        self.assertLess(steps.index(checkout), steps.index(sweep))
        self.assertEqual(sweep["env"]["BRANCH_WORKFLOWS"],
                         f"feat-cmux-next={checkout['with']['path']}/.github/workflows")


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


def live_plan(runs, jobs, branch="feature", sha="aaa", *, prs=None, rerun_state=True):
    """A plan where `branch` is live at `sha` and has no open pull request at that head."""
    return janitor.build_plan(runs, jobs, {branch: list(prs or ()), "other-pin": []}, threshold=6, max_cancels=10,
                              pull_request_policy="compile-only", now=NOW, rerun_state=rerun_state,
                              branch_heads={branch: sha})


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

    def test_wait_starts_when_the_last_job_it_may_need_finished(self):
        # A sibling created before the job may be one of its needs; the wait starts when it could run.
        job = unassigned_job(age=60)
        gate = started_job(age=61, status="completed", label=LINUX)
        gate["completed_at"] = iso(20)
        self.assertEqual(janitor.lost_wait_start(job, [job, gate]), janitor.parse_time(iso(20)))
        self.assertEqual(janitor.lost_wait_start(job, [job]), janitor.parse_time(iso(60)))
        # A sibling with no created_at may be a need too.
        undated = dict(gate, created_at=None)
        self.assertEqual(janitor.lost_wait_start(job, [job, undated]), janitor.parse_time(iso(20)))
        # GitHub creates a job only once its needs finished: a sibling created with it or later is no need.
        for age in (60, 50):
            with self.subTest(sibling_created_minutes_ago=age):
                sibling = started_job(age=age, status="completed", label=LINUX)
                sibling["completed_at"] = iso(20)
                self.assertFalse(janitor.may_need(job, sibling))
                self.assertEqual(janitor.lost_wait_start(job, [job, sibling]), janitor.parse_time(iso(60)))

    def test_a_gated_job_is_not_lost_before_it_could_run_for_thirty_minutes(self):
        gate = started_job(age=61, status="completed", label=LINUX)
        gate["completed_at"] = iso(20)
        stuck, other, jobs = lost_world(age=60, evidence_age=15, siblings=[gate])
        self.assertEqual(janitor.find_lost([stuck, other], jobs, now=NOW), {})


def recorded_jobs(history, at):
    """Job records as the jobs API showed them at `at`, from (id, name, label, created, started, completed, runner).

    A job appears once created; a runner shows from its start; `completed` None means it was still unfinished at
    the end of the record. A job with no label is one that was skipped when it was created.
    """
    when = janitor.parse_time(at)
    jobs = []
    for job_id, name, label, created, started, completed, runner in history:
        if janitor.parse_time(created) > when:
            continue
        job = {"id": job_id, "name": name, "labels": [label] if label else [], "created_at": created,
               "started_at": started or created, "completed_at": None, "conclusion": None, "runner_id": 0,
               "runner_name": None, "status": "queued"}
        if not label:
            job.update(status="completed", conclusion="skipped", completed_at=created)
        elif completed and janitor.parse_time(completed) <= when:
            job.update(status="completed", conclusion="success", completed_at=completed, runner_id=runner,
                       runner_name=f"runner-{runner}")
        elif runner and started and janitor.parse_time(started) <= when:
            job.update(status="in_progress", runner_id=runner, runner_name=f"runner-{runner}")
        jobs.append(job)
    return jobs


# Run 41158893861 attempt 1, as the jobs API recorded it: (id, name, label, created, started, completed, runner).
GHOSTTYKIT_LABEL = "blacksmith-4vcpu-ubuntu-2404"
LINUX_32 = "blacksmith-32vcpu-ubuntu-2404"
GHOSTTYKIT_RUN_HISTORY = (
    (124411760843, "changes", GHOSTTYKIT_LABEL, "2026-10-31T02:12:02Z", "2026-10-31T02:18:00Z", "2026-10-31T02:18:12Z", 5323721),
    (124411761827, "Fast static checks", None, "2026-10-31T02:12:02Z", None, None, None),
    (124411798261, "CI fast guards", None, "2026-10-31T02:12:11Z", None, None, None),
    (124413283263, "GhosttyKit release check", GHOSTTYKIT_LABEL, "2026-10-31T02:18:12Z", None, None, None),
    (124413283312, "web / web-subarea-scope", GHOSTTYKIT_LABEL, "2026-10-31T02:18:12Z", "2026-10-31T02:29:57Z",
     "2026-10-31T02:30:24Z", 5327146),
    (124413283459, "web / runners / Resolve runner capabilities", GHOSTTYKIT_LABEL, "2026-10-31T02:18:12Z",
     "2026-10-31T02:43:45Z", "2026-10-31T02:43:49Z", 5331201),
    *((job_id, name, None, "2026-10-31T02:18:12Z", None, None, None) for job_id, name in (
        (124413284096, "macos"), (124413284415, "guards"), (124413284463, "Dogfood build"),
        (124413284512, "remote-daemon"), (124413284665, "browser"))),
    (124416184629, "web / react-apps-check (4)", LINUX_32, "2026-10-31T02:30:24Z", "2026-10-31T02:30:27Z",
     "2026-10-31T02:57:37Z", 5327215),
    (124416184651, "web / react-apps-check (1)", LINUX_32, "2026-10-31T02:30:24Z", "2026-10-31T02:30:27Z",
     "2026-10-31T02:54:30Z", 5327221),
    (124416184652, "web / react-apps-check (3)", LINUX_32, "2026-10-31T02:30:24Z", "2026-10-31T02:30:27Z",
     "2026-10-31T02:42:57Z", 5327228),
    (124416184731, "web / react-apps-check (2)", LINUX_32, "2026-10-31T02:30:24Z", "2026-10-31T02:30:37Z",
     "2026-10-31T02:43:21Z", 5327226),
    *((job_id, name, None, "2026-10-31T02:30:24Z", None, None, None) for job_id, name in (
        (124416185471, "web / web-production-build"), (124416185700, "web / web-typecheck"),
        (124416185767, "web / web-instant-navigation"), (124416185799, "web / Web tests"),
        (124416185996, "web / web-db-migrations"), (124416186228, "web / diff-sidecar-check"))),
    (124419203091, "web / react-doctor", "blacksmith-16vcpu-ubuntu-2404", "2026-10-31T02:43:49Z",
     "2026-10-31T02:43:51Z", "2026-10-31T02:54:20Z", 5330616),
    (124422166158, "web / webviews-test-durations", GHOSTTYKIT_LABEL, "2026-10-31T02:57:37Z", "2026-10-31T03:13:00Z",
     "2026-10-31T03:13:04Z", 5339621),
    *((job_id, f"web / react-apps-base-check ({shard})", LINUX_32, "2026-10-31T02:57:37Z", "2026-10-31T02:57:41Z",
       done, runner) for job_id, shard, done, runner in (
        (124422166175, 1, "2026-10-31T03:05:29Z", 5335039), (124422166177, 2, "2026-10-31T02:59:03Z", 5335090),
        (124422166204, 4, "2026-10-31T02:59:29Z", 5334949), (124422166224, 3, "2026-10-31T02:58:59Z", 5335187))),
    (124422167396, "web / webviews-test-history", None, "2026-10-31T02:57:37Z", None, None, None),
)


class LostBesideLaterSiblingsTests(unittest.TestCase):
    """Run 41158893861 (PR #28749, CI, 2026-10-31): a lost job beside siblings created after it.

    `GhosttyKit release check` (job 124413283263, blacksmith-4vcpu-ubuntu-2404, needs `changes`) was created at
    02:18:12Z and queued with runner_id 0 until 02:59:09Z, while a newer job on its label started (the janitor's
    own sweep job 124415812116: created 02:28:45Z, started 02:42:40Z). The jobs created after it at 02:30:24Z,
    02:43:49Z and 02:57:37Z cannot be its needs (GitHub creates a job once its needs finished), but each of
    them unfinished gated it (_gated()), and each completion moved its wait start (lost_wait_start()), so it
    was never found lost. The history below is the jobs API's record of attempt 1.
    """

    LABEL = GHOSTTYKIT_LABEL
    SHA = "7f1a501dcb390a02ca61e8485c445bd1dcc45a8a"
    HISTORY = GHOSTTYKIT_RUN_HISTORY

    def world(self, at):
        run = {"id": 41158893861, "event": "pull_request", "status": "queued", "run_attempt": 1,
               "head_branch": "lane/orch-lane-report-ui", "head_sha": self.SHA, "path": ".github/workflows/ci.yml",
               "name": "CI", "created_at": "2026-10-31T02:12:01Z", "triggering_actor": {"login": "teamleaderleo"},
               "head_repository": {"full_name": "manaflow-ai/cmux", "owner": {"login": "manaflow-ai"}},
               "pull_requests": [{"number": 28749}]}
        sweep = make_run(event="schedule", branch="main", sha="ddd", path=".github/workflows/ci-queue-janitor.yml",
                         name="CI queue janitor")
        evidence = recorded_jobs([(124415812116, "Sweep wasted macOS demand", self.LABEL, "2026-10-31T02:28:45Z",
                                   "2026-10-31T02:42:40Z", "2026-10-31T02:45:58Z", 5330856)], at)
        return run, sweep, {run["id"]: recorded_jobs(self.HISTORY, at), sweep["id"]: evidence}

    def stuck(self, jobs, run):
        return next(job for job in jobs[run["id"]] if job["id"] == 124413283263)

    def test_its_wait_starts_when_it_was_created_not_when_a_later_sibling_finished(self):
        for at in ("2026-10-31T02:48:30Z", "2026-10-31T02:57:39Z"):
            with self.subTest(at=at):
                run, _, jobs = self.world(at)
                stuck = self.stuck(jobs, run)
                self.assertEqual(stuck["status"], "queued")
                # Before the fix: 02:43:49Z (`web / runners`) at 02:48:30Z, and 02:57:37Z at 02:57:39Z.
                self.assertEqual(janitor.lost_wait_start(stuck, jobs[run["id"]]),
                                 janitor.parse_time("2026-10-31T02:18:12Z"))

    def test_it_is_lost_from_02_48_and_fails_over_at_the_open_head(self):
        # 30 minutes after 02:18:12Z, react-apps-check (1) and (4) and react-doctor were running (created 02:30Z
        # and 02:43Z) and `web / runners` had just finished (02:43:49Z); at 02:57:39Z the react-apps-base-check
        # shards had been created and were queued. None of them can be its need, and the run cannot finish
        # without it, so it is lost at both: the cancel's re-run of failed (cancelled) jobs brings them back too.
        for at in ("2026-10-31T02:48:30Z", "2026-10-31T02:57:39Z"):
            with self.subTest(at=at):
                self.assert_fails_over(at)
        # Not before its 30 minutes.
        run, sweep, jobs = self.world("2026-10-31T02:48:00Z")
        self.assertEqual(janitor.find_lost([run, sweep], jobs, now=janitor.parse_time("2026-10-31T02:48:00Z")), {})

    def assert_fails_over(self, at):
        now = janitor.parse_time(at)
        run, sweep, jobs = self.world(at)
        lost = janitor.find_lost([run, sweep], jobs, now=now)
        self.assertEqual(lost[run["id"]].job_name, "GhosttyKit release check")
        self.assertEqual(lost[run["id"]].labels, self.LABEL)
        self.assertEqual(lost[run["id"]].job_id, 124413283263)
        # `web / runners`, created the same second, is no newer job; the sweep job is.
        self.assertEqual(lost[run["id"]].skipped, 1)
        pr = make_pr(28749, head=self.SHA)
        result = janitor.build_plan([run, sweep], jobs, {run["head_branch"]: [pr], "main": []}, threshold=6,
                                    max_cancels=10, pull_request_policy="compile-only", now=now, rerun_state=True,
                                    cmux_bot_rerun=True)
        decision = decision_for(result, run)
        self.assertEqual((decision.action, decision.candidate.category), ("cancel", "lost"))
        self.assertTrue(decision.candidate.rerun and decision.candidate.open_head)
        # Nothing failed: the run's failed (cancelled) jobs are re-run, the later siblings with it.
        self.assertIsNone(decision.candidate.rerun_job)
        self.assertIn("PR #28749", decision.candidate.reason)

    def test_a_sibling_created_before_it_still_gates_it(self):
        # One that may be its need, still running, or queued in a backed-up pool (no newer job on its label
        # started): the job may be waiting on it.
        now = janitor.parse_time("2026-10-31T02:57:39Z")
        for status, runner in (("in_progress", 11), ("queued", 0)):
            with self.subTest(status=status):
                run, sweep, jobs = self.world("2026-10-31T02:57:39Z")
                gate = dict(self.stuck(jobs, run), id=1, name="earlier gate", status=status, runner_id=runner,
                            runner_name=f"runner-{runner}" if runner else None,
                            labels=["blacksmith-8vcpu-ubuntu-2404"], created_at="2026-10-31T02:15:00Z")
                jobs[run["id"]].append(gate)
                self.assertEqual(janitor.find_lost([run, sweep], jobs, now=now), {})


class LostInAFailedRunTests(unittest.TestCase):
    """Run 41150189497 (PR #28544, cmux-next, 2026-10-31): a lost job in a run that had already failed.

    `cmux-next fast tier` (job 124387425580, glaeda-side-std-xcode-26.6) was created at 00:36:11Z and queued
    with runner_id 0 until a person cancelled the run at 03:11:49Z and re-ran it by hand, while newer jobs on
    its label ran. Every sweep found it lost ("queued 48m with no runner while 1 newer job(s) on
    `glaeda-side-std-xcode-26.6` started", 02:28Z) and kept it: `cmux-next swift test` had failed at 01:35:23Z,
    and open_head_lost() refused any run that already failed, because a re-run of its failed jobs would repeat
    that red. It was the run's only unfinished job, so cancelling the run kills nothing else, and re-running
    that one job (POST /actions/jobs/{id}/rerun) keeps the red as it is.
    """

    SIDE_LABEL = "glaeda-side-std-xcode-26.6"
    SHA = "f36beccbd8df0bdf692914d81d2eee6873df8928"
    AT = "2026-10-31T02:28:30Z"

    def world(self):
        history = [
            (124384817073, "cmux-next push head preflight", LINUX, "2026-10-31T00:27:20Z", "2026-10-31T00:30:44Z",
             "2026-10-31T00:30:47Z", 5292677),
            (124384817218, "cmux-next path routing", LINUX, "2026-10-31T00:27:20Z", "2026-10-31T00:30:43Z",
             "2026-10-31T00:31:01Z", 5292676),
            (124385904142, "cmux-next fleet Release compile", LINUX, "2026-10-31T00:31:01Z", "2026-10-31T00:31:02Z",
             "2026-10-31T01:01:00Z", 5292739),
            (124385904145, "cmux-next macOS placement", LINUX, "2026-10-31T00:31:01Z", "2026-10-31T00:35:59Z",
             "2026-10-31T00:36:11Z", 5294236),
            (124387425580, "cmux-next fast tier", self.SIDE_LABEL, "2026-10-31T00:36:11Z", None, None, None),
            (124387425614, "cmux-next app compile (build fleet)", "glaeda-gateway-xcode-26.6",
             "2026-10-31T00:36:11Z", "2026-10-31T00:36:14Z", "2026-10-31T00:41:27Z", 5143970),
            (124387425690, "cmux-next swift test", "glaeda-gui-std-xcode-26.6", "2026-10-31T00:36:11Z",
             "2026-10-31T01:30:30Z", "2026-10-31T01:35:23Z", 2782327),
            (124387427841, "cmux-next Swift canary", None, "2026-10-31T00:36:11Z", None, None, None),
            (124403018305, "cmux-next generated files (shared build)", "blacksmith-2vcpu-ubuntu-2404",
             "2026-10-31T01:35:24Z", "2026-10-31T01:35:26Z", "2026-10-31T01:35:31Z", 5311369),
        ]
        jobs = recorded_jobs(history, self.AT)
        for job in jobs:
            if job["name"] in ("cmux-next swift test", "cmux-next generated files (shared build)"):
                job["conclusion"] = "failure"
        run = {"id": 41150189497, "event": "pull_request", "status": "queued", "run_attempt": 1,
               "head_branch": "lane/ux-chat-link-right-pane", "head_sha": self.SHA,
               "path": ".github/workflows/cmux-next.yml", "name": "cmux-next · 669c45fc6f2e6d3287cd22a9fd08a0c23a94b15a",
               "created_at": "2026-10-31T00:26:39Z", "triggering_actor": {"login": "teamleaderleo"},
               "head_repository": {"full_name": "manaflow-ai/cmux", "owner": {"login": "manaflow-ai"}},
               "pull_requests": [{"number": 28544}]}
        other = make_run(event="pull_request", branch="another-pr", sha="ccc", path=".github/workflows/cmux-next.yml",
                         name="cmux-next · ccc", status="in_progress")
        served = recorded_jobs([(1, "cmux-next fast tier", self.SIDE_LABEL, "2026-10-31T01:50:00Z",
                                 "2026-10-31T01:52:00Z", None, 77)], self.AT)
        return run, other, {run["id"]: jobs, other["id"]: served}, {run["head_branch"]: [make_pr(28544, head=self.SHA)],
                                                                    "another-pr": []}

    def plan(self, runs, jobs, prs):
        return janitor.build_plan(runs, jobs, prs, threshold=6, max_cancels=10, pull_request_policy="compile-only",
                                  now=janitor.parse_time(self.AT), rerun_state=True, branch_heads={},
                                  app_rerun=True, cmux_bot_rerun=True)

    def test_the_lost_job_alone_is_cancelled_and_re_run(self):
        run, other, jobs, prs = self.world()
        lost = janitor.find_lost([run, other], jobs, now=janitor.parse_time(self.AT))
        self.assertEqual((lost[run["id"]].job_name, lost[run["id"]].job_id), ("cmux-next fast tier", 124387425580))
        decision = decision_for(self.plan([run, other], jobs, prs), run)
        self.assertEqual((decision.action, decision.candidate.category), ("cancel", "lost"))
        self.assertTrue(decision.candidate.rerun and decision.candidate.open_head)
        self.assertEqual(decision.candidate.rerun_job, 124387425580)
        self.assertIn("only the lost job is re-run", decision.candidate.reason)
        entry, = janitor.new_lost_reruns([decision.candidate], {run["id"]: "cancelled"}, now=janitor.parse_time(self.AT))
        self.assertEqual((entry["job_id"], entry["open_head"]), (124387425580, True))

    def test_another_unfinished_job_keeps_the_red_rule(self):
        # A cancel would kill it, and a one-job re-run would not bring it back.
        run, other, jobs, prs = self.world()
        jobs[run["id"]].append(dict(jobs[run["id"]][-1], id=2, name="still running", status="in_progress",
                                    conclusion=None, completed_at=None, created_at="2026-10-31T00:20:00Z"))
        decision = decision_for(self.plan([run, other], jobs, prs), run)
        self.assertTrue(decision is None or decision.action == "skip")
        # And a lost job whose id the listing did not give keeps it too.
        run, other, jobs, prs = self.world()
        for job in jobs[run["id"]]:
            if job["name"] == "cmux-next fast tier":
                del job["id"]
        decision = decision_for(self.plan([run, other], jobs, prs), run)
        self.assertEqual((decision.action, decision.note), ("skip", janitor.OPEN_HEAD_RULE))
        self.assertIn("already failed", decision.candidate.reason)

    def test_the_cancel_goes_through_when_the_failure_predates_the_inventory(self):
        # 2026-10-31, after #28852: cancel_plan()'s re-read refused every such run as "a job failed since the
        # inventory", though `cmux-next swift test` had failed in the inventory too (sweeps 41176910685 to
        # 41179594210 skipped ten each, filling the per-sweep cap).
        run, other, jobs, prs = self.world()
        candidate = decision_for(self.plan([run, other], jobs, prs), run).candidate
        self.assertEqual(candidate.rerun_job, 124387425580)
        fake = FakeGitHub({run["id"]: dict(run)}, {run["id"]: [dict(job) for job in jobs[run["id"]]]})
        results, failures = janitor.cancel_plan(fake, [candidate], jobs)
        self.assertEqual((results[run["id"]], failures), ("cancelled", 0))

    def test_the_cancel_is_refused_when_a_job_failed_or_appeared_since(self):
        run, other, jobs, prs = self.world()
        candidate = decision_for(self.plan([run, other], jobs, prs), run).candidate
        last = jobs[run["id"]][-1]
        cases = {
            "a job failed since the inventory": dict(last, id=3, name="late failure", status="completed",
                                                     conclusion="failure"),
            "is unfinished beside the lost job": dict(last, id=4, name="new sibling", status="queued",
                                                      conclusion=None, completed_at=None, runner_id=None),
        }
        for case, extra in cases.items():
            with self.subTest(case=case):
                now_jobs = [dict(job) for job in jobs[run["id"]]] + [extra]
                fake = FakeGitHub({run["id"]: dict(run)}, {run["id"]: now_jobs})
                results, failures = janitor.cancel_plan(fake, [candidate], jobs)
                self.assertIn(case, results[run["id"]])
                self.assertEqual((failures, fake.posts()), (0, []))

    def test_the_re_run_posts_the_job_not_the_runs_failed_jobs(self):
        fake = FakeGitHub({})
        fake.app_token = True
        entry = {"run_id": 41150189497, "attempt": 1, "head_sha": self.SHA, "branch": "lane/ux-chat-link-right-pane",
                 "cancelled_at": self.AT, "open_head": True, "job_id": 124387425580}
        pending, results, failures = janitor.rerun_lost(fake, [janitor.LostRerun(entry, "rerun", "", None)])
        self.assertEqual((pending, failures), ([], 0))
        self.assertEqual(results, {41150189497: "re-ran job 124387425580"})
        self.assertEqual(fake.app_only_posts, ["/repos/manaflow-ai/cmux/actions/jobs/124387425580/rerun"])
        # Never on the workflow's token: cmux-bot's re-run or none, as for the run's failed jobs.
        workflow_only = FakeGitHub({})
        pending, results, failures = janitor.rerun_lost(workflow_only, [janitor.LostRerun(entry, "rerun", "", None)])
        self.assertEqual((len(pending), failures), (1, 1))
        self.assertEqual(workflow_only.app_only_posts, [])


class EveryUnfinishedJobLostInAFailedRunTests(unittest.TestCase):
    """Run 41192867338 (PR #28562, cmux-next, 2026-10-31): two lost jobs in a run that had already failed.

    `cmux-next fast tier` (job 124513333014, glaeda-std-xcode-26.6, created 10:29:36Z) and `cmux-next swift test`
    (job 124514288372, glaeda-gui-std-xcode-26.6, created 10:34:19Z) queued with runner_id 0 while newer jobs on
    both labels ran; `cmux-next daemon tests` had failed at 10:47:40Z. The 12:49Z sweep found the run lost and
    kept it ("the run already failed, and a re-run of its failed jobs would repeat that red"): the job-only
    re-run of #28852 needs the lost job to be the only unfinished one, and a one-job re-run would have left the
    other lost job cancelled. With every unfinished job lost, the cancel kills nothing that runs, and the run's
    failed jobs are re-run: both lost jobs come back, and so does the red.
    """

    AT = "2026-10-31T12:49:00Z"
    SHA = "988b88bdfb018a63be088399dd673bc290680c6a"
    STD = "glaeda-std-xcode-26.6"

    def world(self):
        history = [
            (124513134997, "cmux-next push head preflight", LINUX, "2026-10-31T10:28:34Z", "2026-10-31T10:28:35Z",
             "2026-10-31T10:28:37Z", 5465530),
            (124513135153, "cmux-next path routing", LINUX, "2026-10-31T10:28:34Z", "2026-10-31T10:28:35Z",
             "2026-10-31T10:29:24Z", 5465560),
            (124513296470, "cmux-next macOS placement", LINUX, "2026-10-31T10:29:24Z", "2026-10-31T10:29:25Z",
             "2026-10-31T10:29:35Z", 5465807),
            (124513334013, "cmux-next Swift canary", None, "2026-10-31T10:29:36Z", None, None, None),
            (124513333014, "cmux-next fast tier", self.STD, "2026-10-31T10:29:36Z", None, None, None),
            (124513333051, "cmux-next app compile (build fleet)", "glaeda-gateway-xcode-26.6",
             "2026-10-31T10:29:36Z", "2026-10-31T10:29:37Z", "2026-10-31T10:32:28Z", 5143840),
            (124514288372, "cmux-next swift test", GUI, "2026-10-31T10:34:19Z", None, None, None),
            (124514288426, "cmux-next daemon tests", "glaeda-session-std-xcode-26.6", "2026-10-31T10:34:19Z",
             "2026-10-31T10:43:10Z", "2026-10-31T10:47:40Z", 2782218),
        ]
        jobs = recorded_jobs(history, self.AT)
        for job in jobs:
            if job["name"] == "cmux-next daemon tests":
                job["conclusion"] = "failure"
        run = {"id": 41192867338, "event": "pull_request", "status": "queued", "run_attempt": 1,
               "head_branch": "dep-fleet--shared-spm-scratch", "head_sha": self.SHA,
               "path": ".github/workflows/cmux-next.yml", "name": "cmux-next · c4d92e19a749c79c3fd74a547e598c9f081fbfac",
               "created_at": "2026-10-31T10:28:09Z", "triggering_actor": {"login": "teamleaderleo"},
               "head_repository": {"full_name": "manaflow-ai/cmux", "owner": {"login": "manaflow-ai"}},
               "pull_requests": [{"number": 28562}]}
        other = make_run(event="pull_request", branch="another-pr", sha="ccc", path=".github/workflows/cmux-next.yml",
                         name="cmux-next · ccc", status="in_progress")
        served = recorded_jobs([(1, "cmux app scheme compile (Debug)", self.STD, "2026-10-31T12:39:11Z",
                                 "2026-10-31T12:40:00Z", None, 77),
                                (2, "cmux-next swift test", GUI, "2026-10-31T12:20:00Z", "2026-10-31T12:30:01Z",
                                 None, 78)], self.AT)
        return run, other, {run["id"]: jobs, other["id"]: served}, {run["head_branch"]: [make_pr(28562, head=self.SHA)],
                                                                    "another-pr": []}

    def plan(self, runs, jobs, prs):
        return janitor.build_plan(runs, jobs, prs, threshold=6, max_cancels=10, pull_request_policy="compile-only",
                                  now=janitor.parse_time(self.AT), rerun_state=True, branch_heads={},
                                  app_rerun=True, cmux_bot_rerun=True)

    def test_both_lost_jobs_are_found(self):
        run, other, jobs, _ = self.world()
        lost = janitor.find_lost([run, other], jobs, now=janitor.parse_time(self.AT))
        self.assertEqual(lost[run["id"]].job_name, "cmux-next fast tier")
        self.assertEqual(sorted(lost[run["id"]].job_ids), [124513333014, 124514288372])

    def test_the_run_is_cancelled_and_its_failed_jobs_re_run(self):
        run, other, jobs, prs = self.world()
        decision = decision_for(self.plan([run, other], jobs, prs), run)
        self.assertEqual((decision.action, decision.candidate.category), ("cancel", "lost"))
        self.assertTrue(decision.candidate.rerun and decision.candidate.open_head)
        # Not one job: both lost jobs come back with the run's failed jobs.
        self.assertIsNone(decision.candidate.rerun_job)
        self.assertIn("every unfinished job is lost", decision.candidate.reason)
        entry, = janitor.new_lost_reruns([decision.candidate], {run["id"]: "cancelled"}, now=janitor.parse_time(self.AT))
        self.assertTrue(entry["open_head"])
        self.assertNotIn("job_id", entry)
        fake = FakeGitHub({run["id"]: dict(run)}, {run["id"]: [dict(job) for job in jobs[run["id"]]]})
        results, failures = janitor.cancel_plan(fake, [decision.candidate], jobs)
        self.assertEqual((results[run["id"]], failures), ("cancelled", 0))

    def test_the_cancel_is_refused_when_a_sibling_appeared_or_started_since(self):
        # #29405: between the plan and the cancel, a job created or started since the inventory is not lost.
        run, other, jobs, prs = self.world()
        candidate = decision_for(self.plan([run, other], jobs, prs), run).candidate
        self.assertIsNone(candidate.rerun_job)
        last = jobs[run["id"]][-1]
        cases = {
            "new sibling": dict(last, id=5, name="new sibling", status="in_progress", conclusion=None,
                                completed_at=None, runner_id=9, runner_name="runner-9"),
            "queued sibling": dict(last, id=6, name="queued sibling", status="queued", conclusion=None,
                                   completed_at=None, runner_id=0, runner_name=None),
        }
        for case, extra in cases.items():
            with self.subTest(case=case):
                now_jobs = [dict(job) for job in jobs[run["id"]]] + [extra]
                fake = FakeGitHub({run["id"]: dict(run)}, {run["id"]: now_jobs})
                results, failures = janitor.cancel_plan(fake, [candidate], jobs)
                self.assertIn("unfinished beside the lost jobs", results[run["id"]])
                self.assertEqual((failures, fake.posts()), (0, []))

    def test_an_unfinished_job_that_is_not_lost_keeps_the_red_rule(self):
        # A third unfinished job, running, would be killed by the cancel.
        run, other, jobs, prs = self.world()
        jobs[run["id"]].append(dict(jobs[run["id"]][-1], id=3, name="still running", status="in_progress",
                                    conclusion=None, completed_at=None, runner_id=9, runner_name="runner-9",
                                    created_at="2026-10-31T10:40:00Z"))
        decision = decision_for(self.plan([run, other], jobs, prs), run)
        self.assertTrue(decision is None or decision.action == "skip")
        # And one lost job whose id the listing did not give leaves the set unknown.
        run, other, jobs, prs = self.world()
        for job in jobs[run["id"]]:
            if job["name"] == "cmux-next swift test":
                del job["id"]
        decision = decision_for(self.plan([run, other], jobs, prs), run)
        self.assertEqual((decision.action, decision.note), ("skip", janitor.OPEN_HEAD_RULE))
        self.assertIn("already failed", decision.candidate.reason)


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
        for sibling_conclusion in ("failure", "success"):
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
                # Lost, but at the head of open PR #23694: never cancelled, failed sibling or not.
                self.assertEqual((decision.action, decision.candidate.category), ("skip", "lost"))
                self.assertIn("PR #23694", decision.candidate.reason)
                self.assertEqual(decision.note, janitor.OPEN_HEAD_RULE)
                self.assertFalse(decision.candidate.rerun)
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

    def test_current_head_of_an_open_pr_is_never_cancelled(self):
        for event in ("pull_request", "push"):
            with self.subTest(event=event):
                stuck, other, jobs = lost_world(age=85, event=event, branch="feature", sha="aaa")
                decision = decision_for(plan([stuck, other], jobs, {"feature": [make_pr(5)]}), stuck)
                self.assertEqual((decision.action, decision.candidate.category), ("skip", "lost"))
                self.assertEqual(decision.note, janitor.OPEN_HEAD_RULE)
                self.assertIn("PR #5", decision.candidate.reason)

    def test_a_live_branch_head_with_no_open_pr_is_cancelled_for_a_rerun(self):
        stuck, other, jobs = lost_world(age=85, event="push", branch="feature", sha="aaa")
        decision = decision_for(live_plan([stuck, other], jobs), stuck)
        self.assertEqual((decision.action, decision.candidate.category), ("cancel", "lost"))
        self.assertTrue(decision.candidate.rerun)
        self.assertIn("live branch", decision.candidate.reason)

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
        stuck, other, jobs = lost_world(age=85, event="push", branch="feature", siblings=[failed])
        decision = decision_for(live_plan([stuck, other], jobs), stuck)
        self.assertEqual(decision.action, "cancel")
        self.assertFalse(decision.candidate.rerun)

    def test_a_bot_re_run_at_a_live_head_is_left_to_the_rescue_and_the_orphan_pass(self):
        for actor in ("github-actions[bot]", "cmux-bot[bot]"):
            with self.subTest(actor=actor):
                stuck, other, jobs = lost_world(age=85, event="push", branch="feature", attempt=2, actor=actor)
                decision = decision_for(live_plan([stuck, other], jobs), stuck)
                self.assertEqual(decision.action, "skip")
                self.assertIn("bot", decision.note)
                # Nobody reads a superseded bot re-run, so that one still goes.
                stuck, other, jobs = lost_world(age=85, event="pull_request", branch="feature", attempt=2,
                                                actor=actor)
                decision = decision_for(plan([stuck, other], jobs, {"feature": [make_pr(5, head="bbb")]}), stuck)
                self.assertEqual(decision.action, "cancel")
                self.assertFalse(decision.candidate.rerun)
        # A person's re-run is theirs to ask for again.
        stuck, other, jobs = lost_world(age=85, event="push", branch="feature", attempt=2, actor="leo")
        self.assertTrue(decision_for(live_plan([stuck, other], jobs), stuck).candidate.rerun)

    def test_a_newer_run_at_the_same_head_takes_over_so_the_cancel_asks_for_no_rerun(self):
        # A `labeled` run queued behind the lost run in ci.yml's concurrency group: re-running the
        # old one would replay `synchronize` with cancel-in-progress and kill the newer one.
        for newer_path in (".github/workflows/ci.yml", ".github/workflows/cmux-tui.yml"):
            with self.subTest(newer_path=newer_path):
                stuck, other, jobs = lost_world(age=85, event="push", branch="feature")
                stuck.update(path=newer_path, name="CI" if newer_path.endswith("ci.yml") else "cmux-tui")
                newer = make_run(event="push", branch="feature", sha="aaa", status="pending", age=20,
                                 path=newer_path)
                decision = decision_for(live_plan([stuck, other, newer], jobs), stuck)
                self.assertEqual((decision.action, decision.candidate.category), ("cancel", "lost"))
                self.assertFalse(decision.candidate.rerun)
                self.assertIn(str(newer["id"]), decision.candidate.reason)

    def test_without_re_run_state_the_current_head_is_left_alone(self):
        stuck, other, jobs = lost_world(age=85, event="push", branch="feature")
        decision = decision_for(live_plan([stuck, other], jobs, rerun_state=False), stuck)
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
        # A push at its live branch head with no open pull request there.
        stuck, other, jobs = lost_world(age=85, event="push", branch="feature")
        fake = FakeGitHub({stuck["id"]: dict(stuck), other["id"]: dict(other)}, jobs)
        fake.prs["feature"] = []
        fake.branches["feature"] = "aaa"
        with tempfile.TemporaryDirectory() as temp:
            code, text = self.sweep(fake, temp)
            self.assertEqual(code, 0)
            self.assertEqual(fake.posts(), [[str(stuck["id"]), "cancel"]])
            self.assertEqual([entry["run_id"] for entry in fake.snapshots[-1]["lost_reruns"]], [stuck["id"]])
            fake.runs[stuck["id"]]["conclusion"] = "cancelled"

            # Sweep 2: the run finished cancelled at the live head -> re-run its failed jobs.
            fake.log.clear()
            code, text = self.sweep(fake, temp)
            self.assertEqual(code, 0)
            self.assertEqual(fake.posts(), [[str(stuck["id"]), "rerun-failed-jobs"]])
            self.assertEqual(fake.snapshots[-1]["lost_reruns"], [])
            self.assertIn("re-ran", text)
            self.assertEqual(fake.runs[stuck["id"]]["run_attempt"], 2)

            # Sweep 3: the janitor's re-run lost its runner again -> never re-run a second time. (A bot's
            # attempt gets no branch-head read, so a push with no open pull request is judged stale, as before.)
            fake.log.clear()
            code, text = self.sweep(fake, temp)
            self.assertNotIn([str(stuck["id"]), "rerun-failed-jobs"], fake.posts())
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
        """A pending re-run of an earlier cancel, and a fresh lost push run at another live branch's head."""
        stuck, other, jobs = lost_world(age=85, event="push", branch="fresh", sha="ccc")
        earlier = make_run(event="pull_request", branch="feature", sha="aaa", status="completed")
        earlier["conclusion"] = "cancelled"
        fake = FakeGitHub({stuck["id"]: dict(stuck), other["id"]: dict(other), earlier["id"]: earlier}, jobs)
        fake.prs.update({"fresh": [], "feature": [make_pr(5)]})
        fake.branches["fresh"] = "ccc"
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

    def test_an_open_pr_at_the_head_is_never_cancelled_whatever_the_event(self):
        for event in ("push", "workflow_dispatch", "pull_request"):
            for heads in ({}, {"feature": "aaa"}):
                with self.subTest(event=event, heads=heads):
                    run, jobs = unclaimed_world(age=50, event=event, branch="feature", sha="aaa")
                    decision = decision_for(unclaimed_plan([run], jobs, {"feature": [make_pr(5)]}, heads=heads), run)
                    self.assertEqual((decision.action, decision.candidate.category), ("skip", "unclaimed"))
                    self.assertEqual(decision.note, janitor.OPEN_HEAD_RULE)

    def test_an_unread_branch_is_left_alone(self):
        run, jobs = unclaimed_world(age=50)
        # Unknown: left to category b and the orphan pass, not even listed.
        self.assertIsNone(decision_for(unclaimed_plan([run], jobs, {DISPATCH_BRANCH: []}, heads={}), run))

    def test_a_moved_or_deleted_short_lived_branch_is_cancelled_and_not_re_run(self):
        # 2026-10-30: dispatches at moved or deleted lane heads held glaeda-side-std-xcode-26.6 places for two to
        # three and a half hours (runs 41066827744 and 41080779296) while 49 jobs queued behind them.
        cases = (({DISPATCH_BRANCH: "eeeeeee"}, "moved on"), ({DISPATCH_BRANCH: ""}, "gone"))
        for heads, why in cases:
            for path, actor, attempt in ((TUI, "leo", 1), (".github/workflows/cmux-next.yml", "leo", 1),
                                         (TUI, "github-actions[bot]", 2)):
                with self.subTest(heads=heads, path=path, attempt=attempt):
                    run, jobs = unclaimed_world(age=50, path=path, actor=actor, attempt=attempt)
                    decision = decision_for(unclaimed_plan([run], jobs, {DISPATCH_BRANCH: []}, heads=heads), run)
                    self.assertEqual((decision.action, decision.candidate.category), ("cancel", "unclaimed"))
                    self.assertFalse(decision.candidate.rerun)
                    self.assertIn(why, decision.candidate.reason)

    def test_a_stale_head_on_a_long_lived_branch_or_a_delivery_run_is_left_alone(self):
        for branch in ("main", "feat-cmux-next", "nightly-next", "rc/1.2"):
            with self.subTest(branch=branch):
                run, jobs = unclaimed_world(age=50, branch=branch)
                self.assertIsNone(decision_for(unclaimed_plan([run], jobs, {branch: []}, heads={branch: "eeee"}), run))
        # A DEV build is a delivery run (delivery_workflows.delivers()), whatever its branch.
        run, jobs = unclaimed_world(age=50, path=".github/workflows/cmux-next.yml")
        run["name"] = run["display_title"] = "cmux NEXT DEV daily · d9d0e2ca"
        self.assertIsNone(decision_for(unclaimed_plan([run], jobs, {DISPATCH_BRANCH: []},
                                                      heads={DISPATCH_BRANCH: "eeee"}), run))
        run, jobs = unclaimed_world(age=50, path=".github/workflows/nightly-next-launch-smoke.yml")
        self.assertIsNone(decision_for(unclaimed_plan([run], jobs, {DISPATCH_BRANCH: []},
                                                      heads={DISPATCH_BRANCH: "eeee"}), run))

    def test_a_stale_head_whose_open_pull_request_opted_out_is_skipped(self):
        run, jobs = unclaimed_world(age=50)
        prs = {DISPATCH_BRANCH: [make_pr(5, head="eeee", labels=("no-janitor",))]}
        decision = decision_for(unclaimed_plan([run], jobs, prs, heads={DISPATCH_BRANCH: "eeee"}), run)
        self.assertEqual(decision.action, "skip")

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
        run, jobs = unclaimed_world(age=50, event="push", branch="feature", sha="aaa")
        newer = make_run(event="push", branch="feature", sha="aaa", status="in_progress", path=TUI, age=10)
        decision = decision_for(unclaimed_plan([run, newer], jobs, {"feature": []}, heads={"feature": "aaa"}), run)
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
        # On rc/* (as on main, feat-cmux-next and nightly-next) a stale head cancels nothing
        # (stale_head_cancellable()), so a read is spent only where a re-run can follow.
        runs, jobs = [], {}
        for index, (path, actor, attempt) in enumerate(((TUI, "leo", 1), (".github/workflows/cmux-next.yml", "leo", 1),
                                                        (TUI, "github-actions[bot]", 2))):
            run, world = unclaimed_world(age=50, branch=f"rc/b{index}", path=path, actor=actor, attempt=attempt)
            runs.append(run)
            jobs.update(world)
        failed, world = unclaimed_world(age=50, branch="rc/failed",
                                        siblings=[started_job(age=90, label=LINUX, status="completed",
                                                              conclusion="failure")])
        opted, world2 = unclaimed_world(age=50, branch="rc/opted")
        runs += [failed, opted]
        jobs.update(world)
        jobs.update(world2)
        prs = {"rc/opted": [make_pr(9, head="other", labels=("no-janitor",))]}
        wanted = janitor.branch_head_lookups(runs, {run["id"] for run in runs}, prs_by_branch=prs,
                                             jobs_by_run=jobs, unclaimed={run["id"] for run in runs})
        self.assertEqual(wanted, ["rc/b0"])

    def test_a_short_lived_branch_gets_a_read_whatever_its_re_run_would_do(self):
        # A stale head there cancels the run outright (stale_head_cancellable()), so the read is never wasted;
        # an opted-out pull request still spends none.
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
        self.assertEqual(wanted, ["b0", "b1", "b2", "failed"])
        # Outside category f (a lost run of category e) nothing changes: no read where no re-run can follow.
        wanted = janitor.branch_head_lookups(runs, {run["id"] for run in runs}, prs_by_branch=prs,
                                             jobs_by_run=jobs, unclaimed=set())
        self.assertEqual(wanted, ["b0", "b1"])


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

    def test_a_dispatch_at_a_moved_branch_head_is_cancelled_and_never_re_run(self):
        run, jobs = unclaimed_world(age=50)
        fake = FakeGitHub({run["id"]: dict(run)}, jobs)
        fake.prs[DISPATCH_BRANCH] = []
        fake.branches[DISPATCH_BRANCH] = "eeeeeee"
        with tempfile.TemporaryDirectory() as temp:
            code, text = self.sweep(fake, temp)
            self.assertEqual(code, 0)
            self.assertEqual(fake.posts(), [[str(run["id"]), "cancel"]])
            self.assertIn("stale head", text)
            self.assertEqual(fake.snapshots[-1]["lost_reruns"], [])
            fake.runs[run["id"]].update(status="completed", conclusion="cancelled")

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


def gates_reading(**row):
    """A CI_FLEET_GATES reading as the fleet dashboard writes it (cmuxterm-hq build-fleet/ci-dash fleet_gates)."""
    std = {"listening": 0, "busy": 10, "held_offline": {"total": 1, "units": 1, "cpu": 0, "livelock": 0, "other": 0},
           "down": 0, "unreported": 0, "queued": 16, "oldest_queued_s": 3960, "as_of": "2026-09-22T16:58:00Z"}
    side = {"listening": 1, "busy": 5, "held_offline": {"total": 40, "units": 12, "cpu": 26, "livelock": 2, "other": 0},
            "down": 0, "unreported": 0, "queued": 44, "oldest_queued_s": 2580}
    std.update(row)
    return {"version": 1, "as_of": "2026-09-22T16:58:00Z", "published": {"variable": "CI_FLEET_GATES"},
            "labels": {"glaeda-std-xcode-26.6": std, "glaeda-side-std-xcode-26.6": side}}


class FleetGatesTests(unittest.TestCase):
    """GitHub lists a runner whose gate holds its listener off as offline, like a dead one (2026-10-30 11:19Z: std
    showed 10 of 11 online busy with 16 queued). The snapshot carries the gates' own state as `gates`."""

    sweep = OrphanSweepTests.sweep

    def test_a_reading_keeps_the_documented_fields_per_label(self):
        gates, why = janitor.fleet_gates(json.dumps(gates_reading()))
        self.assertIsNone(why)
        self.assertEqual((gates["version"], gates["as_of"]), (1, "2026-09-22T16:58:00Z"))
        self.assertNotIn("published", gates)
        self.assertEqual(gates["labels"]["glaeda-std-xcode-26.6"], {
            "listening": 0, "busy": 10,
            "held_offline": {"total": 1, "units": 1, "cpu": 0, "livelock": 0, "other": 0},
            "down": 0, "unreported": 0, "queued": 16, "oldest_queued_s": 3960, "as_of": "2026-09-22T16:58:00Z"})
        side = gates["labels"]["glaeda-side-std-xcode-26.6"]
        self.assertEqual(side["held_offline"], {"total": 40, "units": 12, "cpu": 26, "livelock": 2, "other": 0})
        self.assertEqual(side["as_of"], "2026-09-22T16:58:00Z")  # the reading's own, when a label has none
        self.assertEqual(janitor.FLEET_GATES_STALE_S, 300)

    def test_a_reading_out_of_shape_is_refused_whole(self):
        bad = {
            "": "no CI_FLEET_GATES reading",
            "not json": "not JSON",
            json.dumps(dict(gates_reading(), version=2)): "not version 1",
            json.dumps(dict(gates_reading(), as_of="yesterday")): "no as_of",
            json.dumps(dict(gates_reading(), as_of="2026-09-22T16:58:00")): "no as_of",
            json.dumps(gates_reading(busy=-1)): "out of shape",
            json.dumps(gates_reading(busy=True)): "out of shape",
            json.dumps(gates_reading(queued="16")): "out of shape",
            json.dumps(gates_reading(held_offline={"total": 1, "units": 1})): "out of shape",
            json.dumps(dict(gates_reading(), labels={"blacksmith-6vcpu-macos-26": gates_reading()["labels"][
                "glaeda-std-xcode-26.6"]})): "out of shape",
        }
        for raw, want in bad.items():
            gates, why = janitor.fleet_gates(raw)
            self.assertIsNone(gates, raw)
            self.assertIn(want, why, raw)
        self.assertEqual(janitor.fleet_gates(None), (None, "no CI_FLEET_GATES reading"))

    def test_the_sweep_writes_the_reading_into_the_pool_snapshot(self):
        with tempfile.TemporaryDirectory() as out:
            load = Path(out) / "load.json"
            with mock.patch.dict("os.environ", {"FLEET_GATES": json.dumps(gates_reading())}):
                code, *_ = self.sweep("--pool-load", str(load))
            self.assertEqual(code, 0)
            snapshot = json.loads(load.read_text())
            self.assertEqual(snapshot["gates"], janitor.fleet_gates(json.dumps(gates_reading()))[0])
            self.assertNotIn("gates_error", snapshot)

    def test_the_sweep_says_why_a_snapshot_has_no_reading(self):
        with tempfile.TemporaryDirectory() as out:
            load = Path(out) / "load.json"
            with mock.patch.dict("os.environ", {"FLEET_GATES": ""}):
                code, *_ = self.sweep("--pool-load", str(load))
            self.assertEqual(code, 0)
            snapshot = json.loads(load.read_text())
            self.assertNotIn("gates", snapshot)
            self.assertEqual(snapshot["gates_error"], "no CI_FLEET_GATES reading")

    def test_the_workflow_passes_the_variable_through_env_only(self):
        text = WORKFLOW.read_text(encoding="utf-8")
        steps = yaml.safe_load(text)["jobs"]["sweep"]["steps"]
        step = next(s for s in steps if s.get("name") == "Cancel wasted macOS runs")
        self.assertEqual(step["env"]["FLEET_GATES"], "${{ vars.CI_FLEET_GATES }}")
        self.assertEqual(text.count("vars.CI_FLEET_GATES"), 1)  # never expanded into a script


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

    def test_at_the_open_pr_head_it_is_listed_but_never_cancelled(self):
        # A Blacksmith leg is only ever a same-repository pull request run's, so at its open head it waits for the
        # controller's fall-through, whatever the attempt or token.
        for attempt, actor in ((1, "leo"), (2, "github-actions[bot]"),
                               (janitor.rescue.REFUSAL_RESCUE_ATTEMPT + 1, "github-actions[bot]")):
            for app_rerun in (True, False):
                with self.subTest(attempt=attempt, app_rerun=app_rerun):
                    run, jobs = self.world(age=40, attempt=attempt, actor=actor)
                    decision = decision_for(self.plan(run, jobs, app_rerun=app_rerun), run)
                    self.assertEqual((decision.action, decision.candidate.category), ("skip", "unclaimed"))
                    self.assertEqual(decision.note, janitor.OPEN_HEAD_RULE)

    def test_pr_25446_attempt_2_on_blacksmith_is_never_cancelled(self):
        # Run 40398277457 (cmux-next, PR #25446 at 8be738c84d8): attempt 2, started by github-actions[bot] (the
        # owned-pool rescue's re-run), held the head's only Release compile while `cmux-next fast tier` sat 50m
        # with no runner on blacksmith-6vcpu-macos-26. Sweep 40410764677 cancelled it at 22:18:32Z for an App's
        # re-run that never came (a later sweep had to carry it, and the concurrency group evicted those).
        sha = "8be738c84d8"
        run = next_pr_run(branch="pr-25446", sha=sha, attempt=2, actor="github-actions[bot]", age=60)
        run["pull_requests"] = [{"number": 25446, "base": {"ref": NEXT_BRANCH}}]
        compile_job = started_job(age=55, label="glaeda-side-std-xcode-26.6", status="completed")
        compile_job.update(name="cmux-next Release compile (Xcode 26)", completed_at=iso(52))
        jobs = {run["id"]: [fast_tier_leg(age=50, label="blacksmith-6vcpu-macos-26"), compile_job]}
        fake = FakeGitHub({run["id"]: dict(run)}, jobs)
        fake.app_token = True
        fake.prs["pr-25446"] = [make_pr(25446, head=sha)]
        with tempfile.TemporaryDirectory() as temp, mock.patch.dict("os.environ", {"PR_POOL_OWNED": "1"}):
            code, text = LostAssignmentSweepTests.sweep(self, fake, temp)
        self.assertEqual(code, 0)
        self.assertEqual(fake.posts(), [])
        self.assertEqual(fake.snapshots[-1]["lost_reruns"], [])
        self.assertIn("PR #25446", text)
        self.assertIn("never cancelled", text)

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

    def test_an_earlier_sweeps_app_entry_is_still_re_run_once_as_an_app(self):
        # A cancel an older janitor made (or a person's) is still worth its re-run: that restores the run.
        run, _ = self.world(age=40)
        run.update(status="completed", conclusion="cancelled")
        fake = FakeGitHub({run["id"]: dict(run)}, {})
        fake.app_token = True
        fake.prs[run["head_branch"]] = [make_pr(24021, head=run["head_sha"])]
        fake.snapshots.append({"generated_at": iso(10), "pools": {},
                               "lost_reruns": [{**pending_entry(run), "app_actor": True}]})
        with tempfile.TemporaryDirectory() as temp, mock.patch.dict("os.environ", {"PR_POOL_OWNED": "1"}):
            LostAssignmentSweepTests.sweep(self, fake, temp)
        self.assertEqual(fake.posts(), [[str(run["id"]), "rerun-failed-jobs"]])
        self.assertEqual(len(fake.app_only_posts), 1)
        self.assertEqual(fake.runs[run["id"]]["triggering_actor"], {"login": "cmux-bot[bot]"})
        self.assertEqual(fake.snapshots[-1]["lost_reruns"], [])

    def test_a_bots_attempt_category_e_leaves_is_judged_by_category_f(self):
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
        # Category f holds it, and at the open PR's head it waits.
        self.assertEqual((decision.action, decision.candidate.category), ("skip", "unclaimed"))
        self.assertEqual(decision.note, janitor.OPEN_HEAD_RULE)

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

    def test_at_a_live_push_head_a_lost_blacksmith_leg_is_re_run_only_by_an_app(self):
        # The App gating still holds where cancels remain: a cmux-next push at its live branch head, no open PR.
        run, jobs = self.world(age=40)
        run.update(event="push", head_branch="lane/next-push", pull_requests=[])
        jobs[run["id"]][0]["labels"] = ["blacksmith-6vcpu-macos-26"]
        other = make_run(path=NEXT_PATH, name="cmux-next", branch="lane/other", status="in_progress", age=20)
        jobs[other["id"]] = [started_job(age=10, label="blacksmith-6vcpu-macos-26")]
        lost = janitor.find_lost([run, other], jobs, now=NOW)
        self.assertEqual(sorted(lost), [run["id"]])
        # The PR lookup covers a push's branch too, so an open PR at its head would be seen.
        self.assertEqual(janitor.lost_branches([run, other], lost, []), ["lane/next-push"])
        prs = {"lane/next-push": [], "lane/other": [make_pr(9)]}
        for app_rerun, action in ((False, "skip"), (True, "cancel")):
            with self.subTest(app_rerun=app_rerun):
                result = janitor.build_plan([run, other], jobs, prs, threshold=6, max_cancels=10,
                                            pull_request_policy="compile-only", now=NOW, lost=lost, unclaimed={},
                                            branch_heads={"lane/next-push": run["head_sha"]}, app_rerun=app_rerun)
                decision = decision_for(result, run)
                self.assertEqual((decision.action, decision.candidate.category), (action, "lost"))
                if action == "skip":
                    self.assertIn("App", decision.note)
                    continue
                self.assertTrue(decision.candidate.rerun and decision.candidate.app_actor)
                entries = janitor.new_lost_reruns([decision.candidate], {run["id"]: "cancelled"}, now=NOW)
                self.assertEqual([entry.get("app_actor") for entry in entries], [True])
        # An open PR at that head turns the same run into a skip.
        prs["lane/next-push"] = [make_pr(31, head=run["head_sha"])]
        result = janitor.build_plan([run, other], jobs, prs, threshold=6, max_cancels=10,
                                    pull_request_policy="compile-only", now=NOW, lost=lost, unclaimed={},
                                    branch_heads={"lane/next-push": run["head_sha"]}, app_rerun=True)
        self.assertEqual((decision_for(result, run).action, decision_for(result, run).note),
                         ("skip", janitor.OPEN_HEAD_RULE))

    def test_a_lost_blacksmith_leg_at_the_open_pr_head_is_never_cancelled(self):
        # Category e can hold the run first (a newer job on the same label started): at the open head it waits.
        run, jobs = self.world(age=40)
        other = make_run(path=NEXT_PATH, name="cmux-next", branch="lane/other", status="in_progress", age=20)
        newer = started_job(age=10, label=LARGE_MAC)
        jobs[other["id"]] = [newer]
        lost = janitor.find_lost([run, other], jobs, now=NOW)
        self.assertEqual(sorted(lost), [run["id"]])
        prs = {run["head_branch"]: [make_pr(24021, head=run["head_sha"])], "lane/other": [make_pr(9)]}
        for app_rerun in (False, True):
            with self.subTest(app_rerun=app_rerun):
                result = janitor.build_plan([run, other], jobs, prs, threshold=6, max_cancels=10,
                                            pull_request_policy="compile-only", now=NOW, lost=lost, unclaimed={},
                                            branch_heads={}, app_rerun=app_rerun)
                decision = decision_for(result, run)
                self.assertEqual((decision.action, decision.candidate.category), ("skip", "lost"))
                self.assertEqual(decision.note, janitor.OPEN_HEAD_RULE)


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
        self.assertEqual(len(ids), 400)  # four full pages, then the empty fifth: no cap at three


def github_listing(runs, *, result_pages=10):
    """A janitor client whose run listing answers like GitHub: newest first, 100 a page, `status` and
    `created<=` filters, and nothing past `result_pages` pages (its 1,000-result cap). Returns (client, asked)."""
    github = janitor.GitHub("token", "manaflow-ai/cmux")
    asked = []
    ordered = sorted(runs, key=lambda run: (run["created_at"], run["id"]), reverse=True)

    def request(method, path, body=None):
        query = urllib.parse.parse_qs(path.split("?", 1)[1])
        status, page = query["status"][0], int(query["page"][0])
        created = query.get("created", [""])[0]
        asked.append((status, page, created))
        rows = [run for run in ordered if run["status"] == status
                and (not created or run["created_at"] <= created.removeprefix("<="))]
        batch = rows[(page - 1) * 100:page * 100] if page <= result_pages else []
        return {"workflow_runs": batch, "total_count": len(rows)}

    github.request = request
    return github, asked


def queued_runs(count, *, status="queued"):
    """`count` runs a second apart, newest first in time."""
    start = dt.datetime(2026, 10, 30, 14, 0, tzinfo=dt.timezone.utc)
    return [{"id": 10_000 + index, "status": status,
             "created_at": (start - dt.timedelta(seconds=index)).strftime("%Y-%m-%dT%H:%M:%SZ")}
            for index in range(count)]


class FullQueueListingTests(unittest.TestCase):
    """2026-10-30: 1,138 runs queued, and the sweep listed 300 of them (three pages a status)."""

    def test_every_queued_run_of_a_1138_run_queue_is_listed(self):
        runs = queued_runs(1138)
        github, asked = github_listing(runs)
        ids = {run["id"] for run in github.in_flight_runs()}
        self.assertEqual(ids, {run["id"] for run in runs})
        state = janitor.listing_state(github, set())
        self.assertEqual((state["truncated"], state["listed"], state["total"]), (False, 1138, 1138))
        self.assertEqual(state["statuses"]["queued"]["listed"], 1138)
        # Past GitHub's ten pages the listing goes on from the oldest run seen, not from page eleven.
        self.assertNotIn(("queued", 11, ""), asked)
        self.assertTrue(any(created.startswith("<=") for status, _, created in asked if status == "queued"))

    def test_a_listing_past_its_ceiling_says_truncated_with_counts(self):
        runs = queued_runs(500)
        github, asked = github_listing(runs)
        with mock.patch.object(janitor, "MAX_RUN_PAGES", 2):
            ids = github.in_flight_runs()
        self.assertEqual(len(ids), 200)
        self.assertEqual(len([entry for entry in asked if entry[0] == "queued"]), 2)
        state = janitor.listing_state(github, set())
        self.assertIs(state["truncated"], True)
        self.assertEqual((state["listed"], state["total"]), (200, 500))
        self.assertIs(state["statuses"]["queued"]["truncated"], True)

    def test_runs_left_past_the_job_listing_cap_truncate_the_listing(self):
        runs = [make_run(status="queued", age=age, branch=f"b{age}") for age in (5, 10, 15)]
        fake = FakeGitHub({run["id"]: dict(run) for run in runs}, {run["id"]: mac_jobs(queued=1) for run in runs})
        jobs, unread, unlisted = janitor.read_run_jobs(fake, runs, frozenset(), NOW, cap=2)
        # The newest two are listed; the oldest is left, and the snapshot says so.
        self.assertEqual(set(jobs), {runs[0]["id"], runs[1]["id"]})
        self.assertEqual((unread, unlisted), (set(), {runs[2]["id"]}))
        state = janitor.listing_state(fake, unlisted)
        self.assertIs(state["truncated"], True)
        self.assertEqual(state["jobs_unlisted"], 1)

    def test_parallel_job_listings_match_one_at_a_time(self):
        runs = [make_run(status="queued", age=age, branch=f"b{age}") for age in range(1, 40)]
        job_map = {run["id"]: mac_jobs(queued=run["id"] % 3 + 1) for run in runs}
        fake = FakeGitHub({run["id"]: dict(run) for run in runs}, job_map)
        fake.unreadable_jobs = {runs[7]["id"]}
        with mock.patch.object(janitor.time, "sleep", lambda _: None), mock.patch("builtins.print"):
            parallel = janitor.read_run_jobs(fake, runs, frozenset(), NOW, workers=6)
            serial = janitor.read_run_jobs(fake, runs, frozenset(), NOW, workers=1)
        self.assertEqual(parallel, serial)
        self.assertEqual(list(parallel[0]), [run["id"] for run in runs if run["id"] != runs[7]["id"]])
        self.assertEqual(parallel[1], {runs[7]["id"]})

    def test_a_rate_limit_in_a_parallel_listing_ends_the_sweep(self):
        runs = [make_run(status="queued", age=age, branch=f"b{age}") for age in range(1, 10)]

        class Limited(FakeGitHub):
            def jobs(self, run_id):
                if run_id == runs[4]["id"]:
                    raise janitor.RateLimited("GET /jobs failed (403: rate limit)")
                return []

        with self.assertRaises(janitor.RateLimited):
            janitor.read_run_jobs(Limited({}, {}), runs, frozenset(), NOW, workers=4)


class TruncatedSweepTests(unittest.TestCase):
    """A sweep that saw part of the queue says so in the snapshot and decides nothing."""

    def sweep(self, **patches):
        stuck = make_run(status="queued", age=340, branch="ci/macos26-app-host-repair")
        busy = make_run(status="in_progress", age=20, branch="busy")
        runs = {r["id"]: dict(r) for r in (stuck, busy)}
        jobs = {stuck["id"]: [linux_job(age=330), orphan_job(age=220)], busy["id"]: [served_job(age=15)]}
        fake = FakeGitHub(runs, jobs)
        with tempfile.TemporaryDirectory() as temp:
            load, summary = Path(temp) / "load.json", Path(temp) / "summary.md"
            argv = ["--repo", "manaflow-ai/cmux", "--summary", str(summary), "--pool-load", str(load),
                    "--workflows-dir", str(Path(temp) / "none")]
            with mock.patch.object(janitor, "GitHub", lambda token, repo, fallback_token="": fake), \
                    mock.patch.dict("os.environ", {"GH_TOKEN": "t"}), \
                    mock.patch.object(janitor.time, "sleep", lambda _: None), \
                    mock.patch.object(janitor, "utc_now", lambda: NOW), \
                    mock.patch.multiple(janitor, MAX_JOB_LISTINGS=patches.get("MAX_JOB_LISTINGS", janitor.MAX_JOB_LISTINGS)), \
                    mock.patch("builtins.print"):
                code = janitor.main(argv)
            return code, fake, json.loads(load.read_text()), summary.read_text()

    def test_a_complete_sweep_says_so_and_acts(self):
        code, fake, snapshot, text = self.sweep()
        self.assertEqual(code, 0)
        self.assertIs(snapshot["truncated"], False)
        self.assertEqual(snapshot["listed"], 2)
        self.assertIn("queued", snapshot["listing"]["statuses"])
        self.assertNotIn("starved_incomplete", snapshot)
        self.assertTrue(fake.posts())  # the orphan is cancelled
        self.assertIn("Listed 2 of", text)

    def test_a_truncated_sweep_marks_the_snapshot_and_cancels_nothing(self):
        code, fake, snapshot, text = self.sweep(MAX_JOB_LISTINGS=1)
        self.assertEqual(code, 0)
        self.assertIs(snapshot["truncated"], True)
        self.assertEqual(snapshot["listing"]["jobs_unlisted"], 1)
        self.assertIs(snapshot["starved_incomplete"], True)
        self.assertEqual(fake.posts(), [])
        self.assertIn("this sweep decided nothing", text)


class OpenHeadNeverCancelledTests(unittest.TestCase):
    """Every category and the orphan pass, given a run at an open pull request's head, cancel nothing."""

    def world(self):
        """One run per category, each at the head of its own open pull request, on a backed-up pool."""
        runs, jobs, prs, expected = [], {}, {}, {}

        def add(run, run_jobs, pr, category):
            runs.append(run)
            jobs[run["id"]] = run_jobs
            prs.setdefault(run["head_branch"], []).append(pr)
            expected[run["id"]] = category

        main_run, main_jobs = busy_main_push(queued=10)
        runs.append(main_run)
        jobs[main_run["id"]] = main_jobs
        add(make_run(event="push", branch="exp/open", name="canary", sha="e1"), mac_jobs(queued=2),
            make_pr(1, head="e1"), "experiment")
        # Its own PR #2 is closed, but open PR #3 from the same branch is at the run's head.
        add(make_run(branch="reopened", sha="r1", prs=(2,)), mac_jobs(running=1), make_pr(2, state="CLOSED", head="r1"),
            "stale-pr")
        prs["reopened"].append(make_pr(3, head="r1"))
        old = make_run(branch="dropped", sha="d1", age=30)
        add(old, mac_jobs(queued=3, running=2),
            make_pr(4, head="d1", timeline=[("LabeledEvent", "full-ci", 60), ("UnlabeledEvent", "full-ci", 5)]),
            "label-dropped")
        newer = make_run(branch="dropped", sha="d1", age=5, status="pending")
        runs.append(newer)
        jobs[newer["id"]] = []
        add(make_run(branch="doomed", sha="m1"), doomed_jobs(), make_pr(5, head="m1"), "doomed")
        for event, branch in (("pull_request", "lost-pr"), ("push", "lost-push")):
            stuck, other, world = lost_world(age=85, event=event, branch=branch, sha=f"{branch}-sha")
            add(stuck, world[stuck["id"]], make_pr(6, head=f"{branch}-sha"), "lost")
            runs.append(other)
            jobs[other["id"]] = world[other["id"]]
            prs.setdefault("other-pin", [])
        for event in ("workflow_dispatch", "push"):
            run, world = unclaimed_world(age=50, event=event, branch=f"f-{event}", sha=f"f-{event}")
            add(run, world[run["id"]], make_pr(7, head=f"f-{event}"), "unclaimed")
        return runs, jobs, prs, expected

    def test_no_category_cancels_a_run_at_an_open_pr_head(self):
        runs, jobs, prs, expected = self.world()
        heads = {branch: pr_list[-1]["headRefOid"] for branch, pr_list in prs.items() if pr_list}
        for app_rerun in (False, True):
            with self.subTest(app_rerun=app_rerun):
                result = janitor.build_plan(runs, jobs, prs, threshold=6, max_cancels=25,
                                            pull_request_policy="compile-only", now=NOW, branch_heads=heads,
                                            app_rerun=app_rerun)
                cancelled = {c.run["id"] for c in result.to_cancel()}
                self.assertEqual(cancelled & set(expected), set())
                seen = {d.candidate.run["id"]: d for d in result.decisions}
                for run_id, category in expected.items():
                    with self.subTest(category=category, run=run_id):
                        if category == "stale-pr":
                            # Category b judges it by its closed PR #2, but open PR #3 has its head.
                            self.assertEqual(seen[run_id].action, "skip")
                            continue
                        self.assertEqual((seen[run_id].candidate.category, seen[run_id].action), (category, "skip"))
                        self.assertEqual(seen[run_id].note, janitor.OPEN_HEAD_RULE)

    def test_the_orphan_pass_cancels_none_of_them(self):
        runs, jobs, prs, expected = self.world()
        later = NOW + dt.timedelta(hours=30)
        orphans = janitor.find_orphans(runs, jobs, min_age=dt.timedelta(minutes=120), now=later)
        self.assertTrue({o.run["id"] for o in orphans} & set(expected))
        decisions = janitor.build_orphan_plan(orphans, prs, max_cancels=25, exclude_ids=set(), now=later)
        cancelled = {d.orphan.run["id"] for d in decisions if d.action == "cancel"}
        self.assertEqual(cancelled & set(expected), set())

    def test_a_sweep_posts_no_cancel(self):
        runs, jobs, prs, expected = self.world()
        fake = FakeGitHub({run["id"]: dict(run) for run in runs}, jobs)
        fake.prs.update(prs)
        fake.branches.update({branch: pr_list[-1]["headRefOid"] for branch, pr_list in prs.items() if pr_list})
        fake.app_token = True
        with tempfile.TemporaryDirectory() as temp, mock.patch.dict("os.environ", {"PR_POOL_OWNED": "1"}):
            code, _ = LostAssignmentSweepTests.sweep(self, fake, temp)
        self.assertEqual(code, 0)
        posted = {int(run_id) for run_id, verb in fake.posts() if verb in ("cancel", "force-cancel")}
        self.assertEqual(posted & set(expected), set())


class DeliveryRunScopeTests(unittest.TestCase):
    """dep-fleet's ruling (#27521) protects delivery runs (any event but a pull request's), never a pull request's
    test run of a nightly-named workflow: that run gets the normal open-head treatment and reserves no label."""

    CANARY = ".github/workflows/nightly-next-canary.yml"
    SMOKE = ".github/workflows/nightly-next-launch-smoke.yml"
    CHECKS = ((CANARY, "nightly-next canary"), (SMOKE, "nightly-next launch smoke"))
    LABEL = "blacksmith-6vcpu-macos-26"

    def classify(self, run, pr):
        return janitor.classify(run, janitor.macos_usage(mac_jobs(queued=2)), pr, newer_ci_run_waiting=False,
                                pull_request_policy="compile-only", now=NOW)

    def reserved(self, run):
        job = {"labels": [self.LABEL], "status": "queued", "created_at": iso(5), "name": "smoke"}
        return janitor.pool_load_snapshot([run], {run["id"]: [job]}, now=NOW)["pools"][self.LABEL]["reserved_queued"]

    def test_a_pull_request_run_of_a_post_publish_check_is_swept_like_any_other(self):
        for path, name in self.CHECKS:
            with self.subTest(path=path):
                run = make_run(path=path, name=name)
                self.assertIsNone(janitor.protected_reason(run))
                self.assertIsNone(janitor.orphan_protected_reason(run))
                self.assertEqual(self.classify(run, make_pr(state="CLOSED"))[0], "stale-pr")
                self.assertIsNone(self.classify(run, make_pr()), "its open head keeps it")
                self.assertEqual(self.reserved(run), 0)

    def test_delivery_runs_stay_protected_and_reserved(self):
        for path, name in self.CHECKS:
            for event, branch in (("schedule", "main"), ("workflow_dispatch", "feat-cmux-next"),
                                  ("workflow_dispatch", "nightly-next")):
                with self.subTest(path=path, event=event, branch=branch):
                    run = make_run(event=event, branch=branch, path=path, name=name)
                    self.assertIsNotNone(janitor.protected_reason(run))
                    self.assertIsNotNone(janitor.orphan_protected_reason(run))
                    self.assertIsNone(self.classify(run, make_pr(state="CLOSED")))
                    self.assertEqual(self.reserved(run), 1)
        build = make_run(event="push", branch="nightly-next", path=".github/workflows/nightly.yml",
                         name="Nightly macOS build")
        self.assertIsNotNone(janitor.protected_reason(build))
        self.assertIsNotNone(janitor.orphan_protected_reason(build))
        self.assertEqual(self.reserved(build), 1)

    def test_shared_cmux_next_dev_dispatch_is_delivery_protected(self):
        # DEV daily dispatches use the shared cmux-next.yml path and title;
        # they must receive the same orphan/lost-assignment protection as the
        # dedicated nightly workflow.
        run = make_run(event="workflow_dispatch", branch="feat-cmux-next", path=".github/workflows/cmux-next.yml",
                       name="cmux NEXT DEV daily · aaa")
        self.assertIsNotNone(janitor.protected_reason(run))
        self.assertIsNotNone(janitor.orphan_protected_reason(run))


class ReservedPoolWorkflowTests(unittest.TestCase):
    """Which runs' queued macOS jobs count as `reserved_queued`, the freshness work PR overflow stays off."""

    LABEL = "blacksmith-6vcpu-macos-26"
    # A workflow named or filed as nightly, release, promote or notarization work that is no freshness work, and
    # why. Any other such workflow with a Blacksmith macOS job must reserve its label.
    NOT_FRESHNESS = {
        "iroh-release-gate.yml": "a manual test gate run before an Iroh release; it builds and ships nothing",
        "tmux-corpus.yml": "a manual terminal-corpus test titled \"terminal nightly\"; it builds and ships nothing",
    }
    MARKED = re.compile(r"nightly|release|promot|notari", re.IGNORECASE)
    BLACKSMITH_MACOS = re.compile(r"blacksmith-[\w.-]*macos|MACOS_RUNNER", re.IGNORECASE)
    PR_WORKFLOWS = ("ci.yml", "cmux-next.yml", "ci-macos.yml")

    def reserved(self, path: str, name: str = "x") -> int:
        run = {"id": 1, "name": name, "path": path, "status": "in_progress"}
        job = {"labels": [self.LABEL], "status": "queued", "created_at": iso(5), "name": "wait-and-staple"}
        snap = janitor.pool_load_snapshot([run], {1: [job]}, now=NOW)
        return snap["pools"][self.LABEL]["reserved_queued"]

    def test_continue_nightly_notarization_reserves_its_label(self):
        # 2026-10-30 12:43Z: its three wait-and-staple jobs queued on blacksmith-6vcpu-macos-26 behind 22 PR
        # overflow jobs, because the snapshot did not count them as reserved.
        self.assertEqual(self.reserved(".github/workflows/auto-resume-nightly-notarization.yml",
                                       "Continue nightly notarization"), 1)
        self.assertEqual(self.reserved(".github/workflows/resume-nightly-notarization.yml"), 1)

    def test_every_freshness_workflow_with_a_blacksmith_macos_job_reserves(self):
        workflows = sorted((ROOT / ".github/workflows").glob("*.yml"))
        self.assertTrue(workflows)
        checked = []
        for path in workflows:
            doc = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
            jobs = doc.get("jobs") or {}
            macos = [job_id for job_id, job in jobs.items()
                     if isinstance(job, dict) and self.BLACKSMITH_MACOS.search(str(job.get("runs-on", "")))]
            marked = self.MARKED.search(path.name) or self.MARKED.search(str(doc.get("name") or ""))
            if not macos or not marked:
                continue
            reserved = self.reserved(f".github/workflows/{path.name}", str(doc.get("name") or ""))
            with self.subTest(workflow=path.name, jobs=macos):
                if path.name in self.NOT_FRESHNESS:
                    self.assertEqual(reserved, 0, f"{path.name} is exempt: {self.NOT_FRESHNESS[path.name]}")
                else:
                    self.assertEqual(reserved, 1, f"{path.name} runs {macos} on Blacksmith macOS but its "
                                                  "queued jobs do not reserve the label (queue_janitor.reserves_pool)")
                    checked.append(path.name)
        for name in ("release.yml", "nightly.yml", "auto-resume-nightly-notarization.yml",
                     "resume-nightly-notarization.yml"):
            self.assertIn(name, checked)
        for name in self.NOT_FRESHNESS:
            self.assertTrue((ROOT / ".github/workflows" / name).exists(), f"stale exemption {name}")

    def test_pull_request_workflows_do_not_reserve(self):
        for name in self.PR_WORKFLOWS:
            self.assertTrue((ROOT / ".github/workflows" / name).exists(), name)
            with self.subTest(workflow=name):
                self.assertEqual(self.reserved(f".github/workflows/{name}", "v1;release=arm64"), 0)



# ---------------------------------------------------------------------------
# The stall-aware failover at an open pull request's head (open_head_lost(), rerun_open_head()):
# a job GitHub never assigned is cancelled and re-run as cmux-bot at the same head, in the same sweep.
# Coordinator-approved 2026-10-30, after 23 runs waited 1.5 to 10 hours at open heads.
# ---------------------------------------------------------------------------

GUI = "glaeda-gui-std-xcode-26.6"


def open_head_world(*, age=85, label=SIDE, siblings=(), attempt=1, actor="leo", path=".github/workflows/cmux-next.yml",
                    name="cmux-next · aaa", event="pull_request", branch="feature", lost=None, evidence_age=None):
    """A run at open PR #5's head with one lost job, and another run whose newer same-label job started."""
    stuck, other, jobs = lost_world(age=age, event=event, branch=branch, sha="aaa", evidence_label=label,
                                    attempt=attempt, actor=actor, siblings=siblings, evidence_age=evidence_age,
                                    lost=lost or unassigned_job(age=age, label=label, name="cmux-next fast tier"))
    stuck.update(path=path, name=name)
    return stuck, other, jobs, {branch: [make_pr(5, head="aaa")], "other-pin": []}


def open_head_plan(runs, jobs, prs, *, cmux_bot=True, rerun_state=True):
    return janitor.build_plan(runs, jobs, prs, threshold=6, max_cancels=10, pull_request_policy="compile-only",
                              now=NOW, rerun_state=rerun_state, branch_heads={}, app_rerun=True,
                              cmux_bot_rerun=cmux_bot)


class OpenHeadFailoverScopeTests(unittest.TestCase):
    def test_a_never_assigned_job_queued_thirty_minutes_after_newer_starts_fails_over(self):
        for label in (SIDE, GUI):
            for runner_id in (None, 0):
                with self.subTest(label=label, runner_id=runner_id):
                    stuck, other, jobs, prs = open_head_world(
                        label=label, lost=unassigned_job(age=85, label=label, runner_id=runner_id))
                    decision = decision_for(open_head_plan([stuck, other], jobs, prs), stuck)
                    self.assertEqual((decision.action, decision.candidate.category), ("cancel", "lost"))
                    self.assertTrue(decision.candidate.rerun and decision.candidate.open_head)
                    self.assertIn("PR #5", decision.candidate.reason)
                    entries = janitor.new_lost_reruns([decision.candidate], {stuck["id"]: "cancelled"}, now=NOW)
                    self.assertEqual([entry.get("open_head") for entry in entries], [True])

    def test_an_assigned_job_is_never_failed_over(self):
        stuck, other, jobs, prs = open_head_world(lost=unassigned_job(age=85, runner_id=12))
        self.assertIsNone(decision_for(open_head_plan([stuck, other], jobs, prs), stuck))
        stuck, other, jobs, prs = open_head_world(lost=unassigned_job(age=85, runner_name="mini-3-side"))
        self.assertIsNone(decision_for(open_head_plan([stuck, other], jobs, prs), stuck))

    def test_under_thirty_minutes_is_left_alone(self):
        stuck, other, jobs, prs = open_head_world(age=25, evidence_age=20)
        self.assertIsNone(decision_for(open_head_plan([stuck, other], jobs, prs), stuck))

    def test_without_a_newer_start_on_exactly_its_labels_it_is_only_waiting(self):
        # Backed up: the newer same-label job still queues; a newer job on another label set started.
        stuck, other, jobs, prs = open_head_world()
        jobs[other["id"]] = [unassigned_job(age=60), started_job(age=50, label=[SIDE, "glaeda-ios-sim"]),
                             started_job(age=50, label=GUI)]
        self.assertEqual(janitor.find_lost([stuck, other], jobs, now=NOW), {})
        # Category f may list it (an unclaimed leg), but at the open head it keeps OPEN_HEAD_RULE.
        decision = decision_for(open_head_plan([stuck, other], jobs, prs), stuck)
        self.assertTrue(decision is None or (decision.action, decision.note) == ("skip", janitor.OPEN_HEAD_RULE))

    def test_a_nightly_dev_or_promote_run_never_fails_over(self):
        cases = {
            # A pull request's run of a delivery workflow (the launch smoke): category e may see it, the failover never.
            "launch smoke PR run": dict(path=".github/workflows/nightly-next-launch-smoke.yml",
                                        name="nightly-next launch smoke"),
            "DEV daily title": dict(name="cmux NEXT DEV daily · aaa"),
        }
        for case, overrides in cases.items():
            with self.subTest(case=case):
                stuck, other, jobs, prs = open_head_world(**overrides)
                decision = decision_for(open_head_plan([stuck, other], jobs, prs), stuck)
                self.assertTrue(decision is None or decision.action == "skip", case)
                if decision is not None:
                    self.assertEqual(decision.note, janitor.OPEN_HEAD_RULE)
        # A feat-cmux-next push (the promote gate) and a nightly push are out of category e's scope altogether.
        for branch, path in (("feat-cmux-next", ".github/workflows/cmux-next.yml"),
                             ("nightly-next", ".github/workflows/nightly.yml")):
            with self.subTest(branch=branch):
                stuck, other, jobs, prs = open_head_world(event="push", branch=branch, path=path,
                                                          name="Nightly macOS build")
                self.assertEqual(janitor.find_lost([stuck, other], jobs, now=NOW), {})
                self.assertIsNone(decision_for(open_head_plan([stuck, other], jobs, prs), stuck))
        # open_head_lost() refuses one on its own too, whatever reaches it.
        run = make_run(event="pull_request", path=".github/workflows/nightly.yml", name="Nightly macOS build")
        verdict = janitor.open_head_lost(run, [], "lost", make_pr(5), rerun_state=True, newer=None, cmux_bot=True)
        self.assertEqual((verdict.action, verdict.note), ("skip", janitor.OPEN_HEAD_RULE))

    def test_a_bots_re_run_lost_again_fails_over_once_more_then_keeps_the_rule(self):
        # 2026-10-31 12:49Z: 28 of the 30 lost runs kept at open heads were a bot's attempt 2 (the janitor's own
        # failover), lost again on the label it came back to, PR #29228's `cmux-next fast tier` 2h46m among them.
        # The same sweep re-runs what it cancels now, so attempt 2 fails over again; from
        # LOST_FAILOVER_MAX_ATTEMPT on, a bot's attempt keeps OPEN_HEAD_RULE (run 40398277457's rule), so the
        # loop is finite.
        self.assertEqual(janitor.LOST_FAILOVER_MAX_ATTEMPT, 3)
        for actor in ("github-actions[bot]", "cmux-bot[bot]"):
            with self.subTest(actor=actor, attempt=2):
                stuck, other, jobs, prs = open_head_world(attempt=2, actor=actor)
                decision = decision_for(open_head_plan([stuck, other], jobs, prs), stuck)
                self.assertEqual((decision.action, decision.candidate.category), ("cancel", "lost"))
                self.assertTrue(decision.candidate.rerun and decision.candidate.open_head)
                entry, = janitor.new_lost_reruns([decision.candidate], {stuck["id"]: "cancelled"}, now=NOW)
                self.assertEqual((entry["attempt"], entry["open_head"]), (2, True))
            for attempt in (3, 4):
                with self.subTest(actor=actor, attempt=attempt):
                    stuck, other, jobs, prs = open_head_world(attempt=attempt, actor=actor)
                    decision = decision_for(open_head_plan([stuck, other], jobs, prs), stuck)
                    self.assertEqual((decision.action, decision.note), ("skip", janitor.OPEN_HEAD_RULE))
                    self.assertIn("bot's re-run", decision.candidate.reason)
        # A person's re-run is any other run, whatever its attempt.
        for attempt in (2, 3):
            stuck, other, jobs, prs = open_head_world(attempt=attempt, actor="leo")
            self.assertEqual(decision_for(open_head_plan([stuck, other], jobs, prs), stuck).action, "cancel")

    def test_a_run_that_already_failed_keeps_its_red(self):
        failed = started_job(age=90, status="completed", label=LINUX, conclusion="failure")
        failed["completed_at"] = iso(87)
        stuck, other, jobs, prs = open_head_world(siblings=[failed])
        decision = decision_for(open_head_plan([stuck, other], jobs, prs), stuck)
        self.assertEqual((decision.action, decision.note), ("skip", janitor.OPEN_HEAD_RULE))
        self.assertIn("already failed", decision.candidate.reason)

    def test_a_newer_run_at_the_head_reports_for_it(self):
        stuck, other, jobs, prs = open_head_world()
        newer = make_run(event="pull_request", branch="feature", sha="aaa", status="in_progress", age=10,
                         path=stuck["path"], name=stuck["name"])
        jobs[newer["id"]] = [started_job(age=5, label=LINUX)]
        decision = decision_for(open_head_plan([stuck, other, newer], jobs, prs), stuck)
        self.assertEqual((decision.action, decision.note), ("skip", janitor.OPEN_HEAD_RULE))
        self.assertIn(f"newer run {newer['id']}", decision.candidate.reason)

    def test_without_cmux_bot_or_re_run_state_nothing_is_cancelled(self):
        for cmux_bot, rerun_state in ((False, True), (True, False)):
            with self.subTest(cmux_bot=cmux_bot, rerun_state=rerun_state):
                stuck, other, jobs, prs = open_head_world()
                decision = decision_for(open_head_plan([stuck, other], jobs, prs, cmux_bot=cmux_bot,
                                                       rerun_state=rerun_state), stuck)
                self.assertEqual((decision.action, decision.note), ("skip", janitor.OPEN_HEAD_RULE))

    def test_an_unread_page_of_open_pull_requests_fails_closed(self):
        stuck, other, jobs, prs = open_head_world()
        prs["feature"] = [{janitor.OPEN_PRS_UNREAD: True, "number": None}, *prs["feature"]]
        decision = decision_for(open_head_plan([stuck, other], jobs, prs), stuck)
        self.assertTrue(decision is None or decision.action == "skip")

    def test_other_categories_still_never_cancel_at_an_open_head(self):
        runs, jobs, prs, expected = OpenHeadNeverCancelledTests.world(OpenHeadNeverCancelledTests())
        heads = {branch: pr_list[-1]["headRefOid"] for branch, pr_list in prs.items() if pr_list}
        result = janitor.build_plan(runs, jobs, prs, threshold=6, max_cancels=25, pull_request_policy="compile-only",
                                    now=NOW, branch_heads=heads, app_rerun=True, cmux_bot_rerun=True)
        cancelled = {c.run["id"]: c for c in result.to_cancel()}
        for run_id, category in expected.items():
            with self.subTest(category=category, run=run_id):
                if category == "lost" and run_id in cancelled:
                    self.assertTrue(cancelled[run_id].open_head)
                else:
                    self.assertNotIn(run_id, cancelled)


class SettlingFakeGitHub(FakeGitHub):
    """A FakeGitHub whose cancel finishes the run as `cancelled`, as GitHub's does for a run with only queued jobs."""

    on_cancel = None  # called with the run once its cancel is posted: what changes while it settles

    def request(self, method, path, body=None, *, app_only=False):
        result = super().request(method, path, body, app_only=app_only)
        tail = path.rsplit("/", 1)[-1]
        if method == "POST" and tail in ("cancel", "force-cancel"):
            run = self.runs[int(path.rsplit("/", 2)[-2])]
            if run["status"] == "completed":
                run["conclusion"] = "cancelled"
            if self.on_cancel:
                self.on_cancel(run)
        return result


class OpenHeadFailoverSweepTests(unittest.TestCase):
    """main() at an open head: cancel, a bounded wait for the cancel, re-run as cmux-bot, in one sweep."""

    def world(self, **kwargs):
        stuck, other, jobs, prs = open_head_world(**kwargs)
        fake = SettlingFakeGitHub({stuck["id"]: dict(stuck), other["id"]: dict(other)}, jobs)
        fake.app_token = True
        fake.prs.update(prs)
        return stuck, fake

    def sweep(self, fake, temp, *args, cmux_bot=True):
        env = {"CMUX_BOT_TOKEN": "t" if cmux_bot else ""}
        with mock.patch.dict("os.environ", env):
            return LostAssignmentSweepTests.sweep(self, fake, temp, *args)

    def test_one_sweep_cancels_and_re_runs_as_cmux_bot(self):
        stuck, fake = self.world()
        with tempfile.TemporaryDirectory() as temp:
            code, text = self.sweep(fake, temp)
        self.assertEqual(code, 0)
        self.assertEqual(fake.posts(), [[str(stuck["id"]), "cancel"], [str(stuck["id"]), "rerun-failed-jobs"]])
        # app_only: never retried on the workflow's token, whose re-run would be github-actions[bot]'s.
        self.assertEqual(fake.app_only_posts, [f"/repos/manaflow-ai/cmux/actions/runs/{stuck['id']}/rerun-failed-jobs"])
        self.assertEqual(fake.runs[stuck["id"]]["run_attempt"], 2)
        self.assertEqual(fake.runs[stuck["id"]]["head_sha"], "aaa")
        self.assertEqual(fake.runs[stuck["id"]]["triggering_actor"], {"login": "cmux-bot[bot]"})
        self.assertEqual(fake.snapshots[-1]["lost_reruns"], [])
        self.assertIn("open-head failover freed 1 lost job run(s) this sweep", text)

        # Its attempt 2 lost its runner again: a bot's attempt below LOST_FAILOVER_MAX_ATTEMPT fails over again.
        fake.runs[stuck["id"]].update(status="queued", conclusion=None)
        fake.log.clear()
        with tempfile.TemporaryDirectory() as temp:
            self.sweep(fake, temp)
        self.assertEqual(fake.posts(), [[str(stuck["id"]), "cancel"], [str(stuck["id"]), "rerun-failed-jobs"]])
        self.assertEqual(fake.runs[stuck["id"]]["run_attempt"], 3)

        # Attempt 3 lost too: from LOST_FAILOVER_MAX_ATTEMPT on, a bot's re-run is never cancelled at the open head.
        fake.runs[stuck["id"]].update(status="queued", conclusion=None)
        fake.log.clear()
        with tempfile.TemporaryDirectory() as temp:
            self.sweep(fake, temp)
        self.assertEqual(fake.posts(), [])

    def test_a_sweep_whose_token_is_not_cmux_bots_leaves_the_open_head_alone(self):
        stuck, fake = self.world()
        with tempfile.TemporaryDirectory() as temp:
            code, text = self.sweep(fake, temp, cmux_bot=False)
        self.assertEqual(code, 0)
        self.assertEqual(fake.posts(), [])
        self.assertNotIn("open-head failover freed", text)

    def test_run_40398277457_a_cancel_the_sweep_cannot_re_run_is_never_left_cancelled(self):
        # Run 40398277457 was cancelled at its open head and stayed cancelled: its re-run waited on a later sweep
        # that never made it. Here every way the in-sweep re-run can miss keeps the entry for the next sweep.
        cases = ("cancel not settled", "re-run refused", "next sweep has no cmux-bot", "cancel read fails")
        for case in cases:
            with self.subTest(case=case):
                stuck, fake = self.world()
                if case == "cancel not settled":
                    fake.ignore_cancel.add(stuck["id"])
                if case in ("re-run refused", "next sweep has no cmux-bot"):
                    fake.refuse_rerun.add(stuck["id"])
                if case == "cancel read fails":
                    original = fake.run
                    reads = []

                    def flaky(run_id, original=original, reads=reads, stuck=stuck):
                        # The cancel's two guard reads in cancel_plan() work; every read after the cancel fails.
                        reads.append(run_id)
                        if run_id == stuck["id"] and len([r for r in reads if r == run_id]) > 2:
                            raise http.client.IncompleteRead(b"")
                        return original(run_id)
                    fake.run = flaky
                with tempfile.TemporaryDirectory() as temp:
                    self.sweep(fake, temp)
                self.assertIn([str(stuck["id"]), "cancel"], fake.posts())
                self.assertEqual(fake.runs[stuck["id"]]["run_attempt"], 1)
                entries = fake.snapshots[-1]["lost_reruns"]
                self.assertEqual([(e["run_id"], e.get("open_head")) for e in entries], [(stuck["id"], True)])

                # The cancel settles; GitHub takes re-runs again; the read works again.
                fake.runs[stuck["id"]].update(status="completed", conclusion="cancelled")
                fake.refuse_rerun.clear()
                if case == "cancel read fails":
                    fake.run = original
                if case == "next sweep has no cmux-bot":
                    fake.log.clear()
                    with tempfile.TemporaryDirectory() as temp:
                        self.sweep(fake, temp, cmux_bot=False)
                    self.assertEqual(fake.posts(), [])
                    self.assertEqual([e["run_id"] for e in fake.snapshots[-1]["lost_reruns"]], [stuck["id"]])
                fake.log.clear()
                with tempfile.TemporaryDirectory() as temp:
                    self.sweep(fake, temp)
                self.assertEqual(fake.posts(), [[str(stuck["id"]), "rerun-failed-jobs"]])
                self.assertEqual(fake.runs[stuck["id"]]["triggering_actor"], {"login": "cmux-bot[bot]"})
                self.assertEqual(fake.snapshots[-1]["lost_reruns"], [])

    def test_the_entry_is_saved_before_the_first_read_after_the_cancel(self):
        stuck, fake = self.world()
        with tempfile.TemporaryDirectory() as temp, \
                mock.patch.object(janitor, "rerun_open_head", side_effect=RecursionError("boom")):
            with self.assertRaises(RecursionError):
                self.sweep(fake, temp)
            saved = json.loads((Path(temp) / "load.json").read_text())
        self.assertEqual([(e["run_id"], e.get("open_head")) for e in saved["lost_reruns"]], [(stuck["id"], True)])

    def test_the_wait_is_bounded(self):
        stuck, fake = self.world()
        fake.ignore_cancel.add(stuck["id"])
        sleeps = []
        with tempfile.TemporaryDirectory() as temp:
            load = Path(temp) / "load.json"
            summary = Path(temp) / "s.md"
            summary.write_text("")
            argv = ["--repo", "manaflow-ai/cmux", "--pool-load", str(load), "--summary", str(summary),
                    "--workflows-dir", str(Path(temp) / "none")]
            with mock.patch.object(janitor, "GitHub", lambda token, repo, fallback_token="": fake), \
                    mock.patch.dict("os.environ", {"GH_TOKEN": "t", "CMUX_BOT_TOKEN": "t"}), \
                    mock.patch.object(janitor.time, "sleep", sleeps.append), \
                    mock.patch.object(janitor, "utc_now", lambda: NOW), \
                    mock.patch("builtins.print"):
                janitor.main(argv)
        settle = [s for s in sleeps if s == janitor.LOST_SETTLE_INTERVAL_S]
        self.assertEqual(len(settle), janitor.LOST_SETTLE_READS - 1)
        self.assertLessEqual(janitor.LOST_SETTLE_READS * janitor.LOST_SETTLE_INTERVAL_S, 120)
        reads = [path for method, path in fake.log if method == "GET" and path.endswith(f"/runs/{stuck['id']}")]
        # The cancel's two guard reads (before and after its jobs are read again), then LOST_SETTLE_READS reads.
        self.assertEqual(len(reads), 2 + janitor.LOST_SETTLE_READS)

    def test_a_push_to_the_pr_while_the_cancel_settles_means_no_re_run_of_the_old_head(self):
        # The re-run would replay the old head's event and, through ci.yml's concurrency group, cancel the new
        # head's CI: the PR is read again after the cancel settles.
        stuck, fake = self.world()
        fake.on_cancel = lambda run: fake.prs["feature"][0].update(headRefOid="bbb")
        with tempfile.TemporaryDirectory() as temp:
            code, text = self.sweep(fake, temp)
        self.assertEqual(code, 0)
        self.assertEqual(fake.posts(), [[str(stuck["id"]), "cancel"]])
        self.assertEqual(fake.runs[stuck["id"]]["run_attempt"], 1)
        self.assertEqual(fake.snapshots[-1]["lost_reruns"], [])
        self.assertIn("open-head failover freed 0 lost job run(s) this sweep", text)
        self.assertIn("superseded", text)

    def test_a_newer_run_at_its_head_even_a_green_one_means_no_re_run(self):
        for conclusion in ("success", None):
            with self.subTest(conclusion=conclusion):
                stuck, fake = self.world()

                def newer(run, fake=fake, stuck=stuck, conclusion=conclusion):
                    fake.runs[stuck["id"] + 1000] = dict(
                        stuck, id=stuck["id"] + 1000, status="completed" if conclusion else "queued",
                        conclusion=conclusion, run_attempt=1)
                fake.on_cancel = newer
                with tempfile.TemporaryDirectory() as temp:
                    self.sweep(fake, temp)
                self.assertEqual(fake.posts(), [[str(stuck["id"]), "cancel"]])
                self.assertEqual(fake.snapshots[-1]["lost_reruns"], [])

    def test_an_unread_pull_request_after_the_cancel_keeps_the_entry(self):
        stuck, fake = self.world()
        calls = []
        original = fake.pull_requests

        def pull_requests(branches, original=original):
            calls.append(list(branches))
            if len(calls) > 1:  # the sweep's own read works; the one after the cancel fails
                raise RuntimeError("POST /graphql failed (502)")
            return original(branches)
        fake.pull_requests = pull_requests
        with tempfile.TemporaryDirectory() as temp:
            self.sweep(fake, temp)
        self.assertEqual(fake.posts(), [[str(stuck["id"]), "cancel"]])
        self.assertEqual([(e["run_id"], e.get("open_head")) for e in fake.snapshots[-1]["lost_reruns"]],
                         [(stuck["id"], True)])

    def test_slow_reads_never_run_the_wait_past_its_budget(self):
        # Each read takes 40 s (a timeout and its retries): the wait still ends inside LOST_SETTLE_BUDGET_S, keeps
        # the entry, and posts nothing after it.
        stuck, fake = self.world()
        fake.ignore_cancel.add(stuck["id"])
        clock = [1000.0]
        started = []
        original = fake.request

        def slow(method, path, body=None, *, app_only=False):
            started.append(clock[0])
            clock[0] += 40.0
            return original(method, path, body, app_only=app_only)
        fake.request = slow
        candidate = mock.Mock(run=dict(stuck, status="completed", conclusion=None), category="lost", rerun=True,
                              open_head=True, app_actor=False, pr=make_pr(5), reason="lost")
        entries = janitor.new_lost_reruns([candidate], {stuck["id"]: "cancelled"}, now=NOW)
        self.assertTrue(entries and entries[0].get("open_head"))
        with mock.patch.object(janitor.time, "monotonic", lambda: clock[0]), \
                mock.patch.object(janitor.time, "sleep", lambda s: clock.__setitem__(0, clock[0] + s)), \
                mock.patch("builtins.print"):
            decisions, pending, results, failures = janitor.rerun_open_head(fake, entries, now=NOW)
        self.assertTrue(started)
        self.assertTrue(all(at < 1000.0 + janitor.LOST_SETTLE_BUDGET_S for at in started), started)
        self.assertLessEqual(clock[0], 1000.0 + janitor.LOST_SETTLE_BUDGET_S + 40.0)
        self.assertEqual([d.action for d in decisions], ["keep"])
        self.assertEqual([e["run_id"] for e in pending], [stuck["id"]])
        self.assertEqual(fake.posts(), [])
        self.assertIsNone(fake.deadline)

    def test_the_client_never_retries_or_waits_past_its_deadline(self):
        github = janitor.GitHub("token", "manaflow-ai/cmux")
        sleeps = []
        with mock.patch.object(janitor.time, "sleep", sleeps.append), \
                mock.patch.object(github, "_request", side_effect=janitor._Transient("502")), \
                mock.patch("builtins.print"):
            github.deadline = janitor.time.monotonic() + 1.0
            with self.assertRaises(RuntimeError):
                github.request("GET", "/repos/manaflow-ai/cmux/actions/runs/1")
        self.assertEqual(sleeps, [])  # the first retry's 2 s would end past the deadline
        timeouts = []

        class Response:
            headers = {}

            def __enter__(self):
                return self

            def __exit__(self, *exc):
                return False

            def read(self):
                return b"{}"

        def urlopen(request, timeout):
            timeouts.append(timeout)
            return Response()
        with mock.patch.object(janitor.urllib.request, "urlopen", urlopen):
            github.deadline = janitor.time.monotonic() + 5.0
            github.request("GET", "/repos/manaflow-ai/cmux/actions/runs/1")
            self.assertLessEqual(timeouts[-1], 5.0)
            github.deadline = janitor.time.monotonic() - 1.0
            with self.assertRaises(RuntimeError):
                github.request("POST", "/repos/manaflow-ai/cmux/actions/runs/1/rerun-failed-jobs")
        self.assertEqual(len(timeouts), 1)

    def test_a_sweep_past_its_cutoff_leaves_the_re_run_to_the_next_sweep(self):
        stuck, fake = self.world()
        with tempfile.TemporaryDirectory() as temp, mock.patch.object(janitor, "LOST_FAILOVER_CUTOFF_S", -1.0):
            self.sweep(fake, temp)
        self.assertEqual(fake.posts(), [[str(stuck["id"]), "cancel"]])
        self.assertEqual([(e["run_id"], e.get("open_head")) for e in fake.snapshots[-1]["lost_reruns"]],
                         [(stuck["id"], True)])
        fake.log.clear()
        with tempfile.TemporaryDirectory() as temp:
            self.sweep(fake, temp)
        self.assertEqual(fake.posts(), [[str(stuck["id"]), "rerun-failed-jobs"]])
        self.assertEqual(fake.runs[stuck["id"]]["triggering_actor"], {"login": "cmux-bot[bot]"})

    def test_a_lost_job_that_took_a_runner_since_the_inventory_is_never_cancelled(self):
        # The plan judged the sweep's job inventory; the job took a runner before the cancel. Cancelling now would
        # interrupt valid work at the PR's head, so the jobs are read again first.
        stuck, other, jobs, prs = open_head_world()
        candidate = decision_for(open_head_plan([stuck, other], jobs, prs), stuck).candidate
        self.assertTrue(candidate.open_head)
        cases = {
            "took a runner": [started_job(age=1)],
            "no job is still unassigned": [],
            "a job failed": [unassigned_job(age=85), started_job(age=2, status="completed", conclusion="failure")],
        }
        for case, now_jobs in cases.items():
            with self.subTest(case=case):
                if case == "took a runner":
                    now_jobs[0]["name"] = jobs[stuck["id"]][0]["name"]
                    now_jobs[0]["created_at"] = jobs[stuck["id"]][0]["created_at"]
                fake = FakeGitHub({stuck["id"]: dict(stuck)}, {stuck["id"]: now_jobs})
                results, failures = janitor.cancel_plan(fake, [candidate], jobs)
                self.assertTrue(results[stuck["id"]].startswith("skipped ("), results)
                self.assertIn(case, results[stuck["id"]])
                self.assertEqual((failures, fake.posts()), (0, []))
                self.assertEqual(janitor.new_lost_reruns([candidate], results, now=NOW), [])
        with self.subTest(case="jobs not readable"):
            fake = FakeGitHub({stuck["id"]: dict(stuck)}, jobs)
            fake.unreadable_jobs.add(stuck["id"])
            results, failures = janitor.cancel_plan(fake, [candidate], jobs)
            self.assertIn("could not be read again", results[stuck["id"]])
            self.assertEqual(fake.posts(), [])
        with self.subTest(case="re-run between the run read and the jobs read"):
            # The jobs listing is the latest attempt's: a re-run started in between lists jobs whose ids match
            # nothing in the inventory, which would read as "nothing moved".
            fake = FakeGitHub({stuck["id"]: dict(stuck)}, {stuck["id"]: [dict(unassigned_job(age=1), run_attempt=2)]})
            results, failures = janitor.cancel_plan(fake, [candidate], jobs)
            self.assertEqual(results[stuck["id"]], "skipped (now attempt 2)")
            self.assertEqual(fake.posts(), [])
            fake = FakeGitHub({stuck["id"]: dict(stuck)}, jobs)
            original = fake.jobs

            def jobs_then_rerun(run_id, fake=fake, original=original):
                listed = original(run_id)
                fake.runs[run_id]["run_attempt"] += 1
                return listed
            fake.jobs = jobs_then_rerun
            results, failures = janitor.cancel_plan(fake, [candidate], jobs)
            self.assertEqual(results[stuck["id"]], "skipped (now attempt 2)")
            self.assertEqual(fake.posts(), [])
        with self.subTest(case="still lost"):
            fake = FakeGitHub({stuck["id"]: dict(stuck)}, jobs)
            results, failures = janitor.cancel_plan(fake, [candidate], jobs)
            self.assertEqual(results[stuck["id"]], "cancelled")
            self.assertEqual(fake.posts(), [[str(stuck["id"]), "cancel"]])

    def test_one_cancel_that_never_settles_does_not_cost_the_settled_ones_their_re_run(self):
        settled, fake = self.world()
        stuck, other, jobs, prs = open_head_world(branch="feature-b")
        fake.runs[stuck["id"]] = dict(stuck)
        fake.prs.update(prs)
        fake.runs[settled["id"]].update(status="completed", conclusion="cancelled")
        clock = [1000.0]
        original = fake.request

        def timed(method, path, body=None, *, app_only=False):
            clock[0] += 1.0
            return original(method, path, body, app_only=app_only)
        fake.request = timed

        def entry(run, branch):
            candidate = mock.Mock(run=dict(run, status="completed", conclusion=None), category="lost", rerun=True,
                                  open_head=True, app_actor=False, pr=make_pr(5), reason="lost")
            return janitor.new_lost_reruns([candidate], {run["id"]: "cancelled"}, now=NOW)[0]
        entries = [entry(settled, "feature"), entry(stuck, "feature-b")]
        with mock.patch.object(janitor.time, "monotonic", lambda: clock[0]), \
                mock.patch.object(janitor.time, "sleep", lambda s: clock.__setitem__(0, clock[0] + s)), \
                mock.patch("builtins.print"):
            decisions, pending, results, failures = janitor.rerun_open_head(fake, entries, now=NOW)
        self.assertEqual([(d.entry["run_id"], d.action) for d in decisions],
                         [(settled["id"], "rerun"), (stuck["id"], "keep")])
        self.assertEqual(fake.posts(), [[str(settled["id"]), "rerun-failed-jobs"]])
        self.assertEqual([e["run_id"] for e in pending], [stuck["id"]])
        self.assertLessEqual(clock[0], 1000.0 + janitor.LOST_SETTLE_BUDGET_S + 1.0)

    def test_the_failover_and_the_pending_entries_share_one_re_run_cap(self):
        # A sweep re-runs at most LOST_RERUN_MAX runs, whether this sweep cancelled them or an earlier one did.
        earlier, fake = self.world()
        with tempfile.TemporaryDirectory() as temp, mock.patch.object(janitor, "LOST_FAILOVER_CUTOFF_S", -1.0):
            self.sweep(fake, temp)
        self.assertEqual([e["run_id"] for e in fake.snapshots[-1]["lost_reruns"]], [earlier["id"]])
        fake.runs[earlier["id"]].update(status="completed", conclusion="cancelled")
        stuck, other, jobs, prs = open_head_world(branch="feature-b")
        fake.runs.update({stuck["id"]: dict(stuck), other["id"]: dict(other)})
        fake.job_map.update(jobs)
        fake.prs.update(prs)
        fake.log.clear()
        with tempfile.TemporaryDirectory() as temp, mock.patch.object(janitor, "LOST_RERUN_MAX", 1):
            self.sweep(fake, temp)
        reruns = [post for post in fake.posts() if post[1] == "rerun-failed-jobs"]
        self.assertEqual(reruns, [[str(stuck["id"]), "rerun-failed-jobs"]])
        self.assertEqual([e["run_id"] for e in fake.snapshots[-1]["lost_reruns"]], [earlier["id"]])

    def test_a_cancel_github_took_but_whose_response_was_lost_is_still_re_run(self):
        # The POST failed on a dropped connection after GitHub took it: the run ends cancelled at the open head,
        # and only the kept entry brings it back.
        stuck, fake = self.world()
        original = fake.request

        def dropped(method, path, body=None, *, app_only=False):
            result = original(method, path, body, app_only=app_only)
            if method == "POST" and path.endswith(f"/runs/{stuck['id']}/cancel"):
                raise RuntimeError(f"POST /repos/manaflow-ai/cmux/actions/runs/{stuck['id']}/cancel failed "
                                   "(RemoteDisconnected)")
            return result
        fake.request = dropped
        with tempfile.TemporaryDirectory() as temp:
            code, text = self.sweep(fake, temp)
        self.assertEqual(fake.posts(), [[str(stuck["id"]), "cancel"]])
        self.assertEqual(fake.runs[stuck["id"]]["conclusion"], "cancelled")
        entries = fake.snapshots[-1]["lost_reruns"]
        self.assertEqual([(e["run_id"], e.get("open_head"), e.get("cancel_unconfirmed")) for e in entries],
                         [(stuck["id"], True, True)])
        fake.request = original
        fake.log.clear()
        with tempfile.TemporaryDirectory() as temp:
            self.sweep(fake, temp)
        self.assertEqual(fake.posts(), [[str(stuck["id"]), "rerun-failed-jobs"]])
        self.assertEqual(fake.runs[stuck["id"]]["triggering_actor"], {"login": "cmux-bot[bot]"})
        self.assertEqual(fake.snapshots[-1]["lost_reruns"], [])

    def test_a_cancel_that_did_not_take_drops_its_entry_once_the_run_finishes(self):
        stuck, fake = self.world()
        original = fake.request

        def failed(method, path, body=None, *, app_only=False):
            if method == "POST" and path.endswith(f"/runs/{stuck['id']}/cancel"):
                fake.log.append((method, path))
                raise RuntimeError(f"POST /repos/manaflow-ai/cmux/actions/runs/{stuck['id']}/cancel failed (500)")
            return original(method, path, body, app_only=app_only)
        fake.request = failed
        with tempfile.TemporaryDirectory() as temp:
            self.sweep(fake, temp)
        self.assertEqual([e["run_id"] for e in fake.snapshots[-1]["lost_reruns"]], [stuck["id"]])
        fake.request = original
        fake.runs[stuck["id"]].update(status="completed", conclusion="success")
        fake.log.clear()
        with tempfile.TemporaryDirectory() as temp:
            self.sweep(fake, temp)
        self.assertEqual(fake.posts(), [])
        self.assertEqual(fake.snapshots[-1]["lost_reruns"], [])

    def test_the_workflow_hands_the_janitor_cmux_bots_token_twice(self):
        workflow = yaml.safe_load(WORKFLOW.read_text())
        step = next(step for step in workflow["jobs"]["sweep"]["steps"] if step.get("name") == "Cancel wasted macOS runs")
        self.assertEqual(step["env"]["CMUX_BOT_TOKEN"], "${{ steps.cmux-bot-token.outputs.token }}")
        self.assertTrue(step["env"]["GH_TOKEN"].startswith("${{ steps.cmux-bot-token.outputs.token ||"))


class DevPublishStub:
    """The janitor client calls skip_superseded_dev_publish() makes, in memory."""

    def __init__(self, runs, jobs, heads, compare="ahead"):
        self.runs, self.job_map, self.heads, self.compare = runs, jobs, heads, compare
        self.cancelled, self.calls = [], []

    def dev_publish_runs(self):
        self.calls.append("list")
        return [r for r in self.runs.values() if r["status"] == "completed" and r["conclusion"] == "success"]

    def jobs(self, run_id):
        self.calls.append(("jobs", run_id))
        return self.job_map[run_id]

    def run(self, run_id):
        self.calls.append(("run", run_id))
        return self.runs.get(run_id) or {"id": run_id, "head_sha": self.heads[run_id]}

    def compare_status(self, base, head):
        self.calls.append(("compare", base, head))
        return self.compare

    def cancel(self, run_id):
        self.cancelled.append(run_id)


def dev_publish(source, ident, *, status="queued", conclusion=None):
    title = f"cmux NEXT DEV daily · publish {source}"
    return {"id": ident, "path": ".github/workflows/cmux-next-dev-daily.yml", "name": title, "display_title": title,
            "status": status, "conclusion": conclusion, "head_sha": "m" * 40, "head_branch": "main",
            "event": "workflow_dispatch", "run_attempt": 1, "created_at": iso(600)}


def dev_jobs(*, published=False, mac_status="queued"):
    def j(name, status="completed", conclusion="success", label="blacksmith-4vcpu-ubuntu-2404", runner="r"):
        return {"name": name, "status": status, "conclusion": conclusion if status == "completed" else None,
                "labels": [label], "runner_name": runner if status != "queued" else None,
                "started_at": iso(590), "completed_at": iso(589) if status == "completed" else None}
    jobs = [j("Build the signer"), j("Sign cmux NEXT DEV"), j("runner")]
    if published:
        return [*jobs, j("Verify signed cmux NEXT DEV", label="glaeda-std-xcode-26.6"), j("Publish cmux NEXT DEV")]
    return [*jobs, j("Verify signed cmux NEXT DEV", mac_status, label="blacksmith-12vcpu-macos-26"),
            j("Build the unsigned cmux NEXT DEV tip DMG", "queued", label="blacksmith-12vcpu-macos-26")]


class SupersededDevPublishTests(unittest.TestCase):
    def setUp(self):
        self.runs = {1: dev_publish(100, 1), 2: dev_publish(110, 2),
                     3: dev_publish(200, 3, status="completed", conclusion="success"), 4: dev_publish(300, 4)}
        self.jobs = {1: dev_jobs(), 2: dev_jobs(mac_status="in_progress"), 3: dev_jobs(published=True), 4: dev_jobs()}
        self.heads = {100: "a" * 40, 110: "b" * 40, 200: "c" * 40, 300: "d" * 40}

    def sweep(self, stub, dry_run=False, **kw):
        inflight = [r for r in stub.runs.values() if r["status"] != "completed"]
        return janitor.skip_superseded_dev_publish(stub, inflight, {}, dry_run=dry_run, now=NOW, **kw)

    def test_cancels_only_the_older_waiting_run_and_keeps_started_and_newer_ones(self):
        stub = DevPublishStub(self.runs, self.jobs, self.heads)
        decisions, failures = self.sweep(stub)
        self.assertEqual(failures, 0)
        self.assertEqual(stub.cancelled, [1])
        notes = {d.run["id"]: d.note for d in decisions}
        self.assertIn("running", notes[2])
        self.assertIn("no older than", notes[4])

    def test_dry_run_cancels_nothing(self):
        stub = DevPublishStub(self.runs, self.jobs, self.heads)
        decisions, _ = self.sweep(stub, dry_run=True)
        self.assertEqual(stub.cancelled, [])
        self.assertEqual([d.run["id"] for d in decisions if d.action == "cancel"], [1])

    def test_a_source_the_winner_does_not_contain_is_kept(self):
        stub = DevPublishStub(self.runs, self.jobs, self.heads, compare="diverged")
        self.sweep(stub)
        self.assertEqual(stub.cancelled, [])

    def test_no_published_run_keeps_everything(self):
        self.runs[3]["conclusion"] = "failure"
        stub = DevPublishStub(self.runs, self.jobs, self.heads)
        decisions, _ = self.sweep(stub)
        self.assertEqual(stub.cancelled, [])
        self.assertTrue(all(d.action == "keep" for d in decisions))

    def test_a_mac_job_that_started_between_the_reads_is_kept(self):
        stub = DevPublishStub(self.runs, self.jobs, self.heads)
        reads = {"n": 0}
        original = stub.jobs

        def jobs(run_id):
            if run_id == 1:
                reads["n"] += 1
                if reads["n"] == 2:
                    return dev_jobs(mac_status="in_progress")
            return original(run_id)
        stub.jobs = jobs
        decisions, _ = self.sweep(stub)
        self.assertEqual(stub.cancelled, [])
        self.assertIn("on re-read", {d.run["id"]: d.note for d in decisions}[1])

    def test_the_cap_and_read_budget_bound_a_sweep(self):
        for ident in range(10, 16):
            self.runs[ident] = dev_publish(50 + ident, ident)
            self.jobs[ident] = dev_jobs()
            self.heads[50 + ident] = f"{ident:x}".ljust(40, "e")
        stub = DevPublishStub(self.runs, self.jobs, self.heads)
        self.sweep(stub, max_cancels=2)
        self.assertEqual(len(stub.cancelled), 2)
        stub = DevPublishStub(self.runs, self.jobs, self.heads)
        self.sweep(stub, max_reads=3)
        self.assertEqual(len(stub.cancelled), 3)

    def test_the_sweep_runs_the_pass(self):
        self.assertIn("skip_superseded_dev_publish(github, runs, delivery_jobs", SCRIPT.read_text())



BASE_TIER_SHA = "07088897" + "0" * 32
BLACKSMITH_MAC26 = "blacksmith-6vcpu-macos-26"
GLAEDA_STD = "glaeda-std-xcode-26.6"


def base_tier_dispatch(*, sha=BASE_TIER_SHA, kind="cmux-next base tier", age=135.25, attempt=1, status="in_progress"):
    run = make_run(event="workflow_dispatch", branch="feat-cmux-next", path=".github/workflows/cmux-next.yml",
                   name=f"{kind} · {sha}", status=status, sha=sha, age=age, attempt=attempt)
    run["display_title"] = run["name"]
    return run


def real_41190186270_jobs():
    """Run 41190186270's jobs at 12:03:47Z on 2026-10-31, when the orphan pass cancelled it (ages in minutes).

    `cmux-next daemon tests` queued 09:49:03Z on blacksmith-6vcpu-macos-26 and never got a runner; its sibling
    `cmux app scheme compile (Debug)`, created with it, waited 78 minutes for one and finished at 11:16:07Z."""
    def job(name, label, created, started=None, completed=None, conclusion=None, runner=None):
        return {"id": next(_ids), "name": name, "labels": [label], "created_at": iso(created),
                "started_at": iso(started if started is not None else created),
                "status": "completed" if completed is not None else "queued",
                "conclusion": conclusion, "completed_at": iso(completed) if completed is not None else None,
                "runner_id": 7 if runner else None, "runner_name": runner}
    return [
        job("cmux-next macOS placement", LINUX, 135.2, 134.9, 134.7, "success", "blacksmith-4vcpu-ubuntu-2404-by3y"),
        job("cmux-next daemon tests", BLACKSMITH_MAC26, 134.7),
        job("cmux app scheme compile (Debug)", BLACKSMITH_MAC26, 134.7, 56.7, 47.7, "success",
            "blacksmith-6vcpu-macos-26-6x5m"),
        job("cmux-next crash ends the app", LINUX, 47.65, 47.6, 47.6, "success", "blacksmith-2vcpu-ubuntu-2404-srrh"),
    ]


def served_mac26(age=40):
    """A newer blacksmith-6vcpu-macos-26 job a runner took: the orphan pass's evidence."""
    run = make_run(event="pull_request", branch="other", status="in_progress", age=age + 1)
    return run, [{"id": next(_ids), "name": "cmux-next generated files", "labels": [BLACKSMITH_MAC26],
                  "created_at": iso(age), "started_at": iso(age - 1), "status": "in_progress",
                  "runner_id": 9, "runner_name": "blacksmith-6vcpu-macos-26-2bct"}]


def daemon_job(*, started, conclusion="success", status="completed"):
    return {"id": next(_ids), "name": "cmux-next daemon tests", "labels": [GLAEDA_STD], "created_at": iso(30),
            "started_at": iso(20) if started else iso(30), "status": status,
            "conclusion": conclusion if status == "completed" else None,
            "runner_id": 3 if started else None, "runner_name": "cmux10s-mac-mini-glaeda-10" if started else None}


class OrphanedDispatchRerunTests(unittest.TestCase):
    """An orphaned dispatch on a long-lived branch comes back (orphan_reruns()): base's daemon-tests verdict."""

    def test_scope_is_a_long_lived_branch_dispatch_below_the_attempt_bound(self):
        def scoped(run, job_name="cmux-next daemon tests"):
            return janitor.orphan_rerun_scope(janitor.Orphan(run, "e", job_name, NOW, 0, 1))
        self.assertIsNotNone(scoped(base_tier_dispatch()))
        self.assertIsNotNone(scoped(base_tier_dispatch(attempt=2)))
        self.assertIsNone(scoped(base_tier_dispatch(attempt=janitor.LOST_FAILOVER_MAX_ATTEMPT)))
        self.assertIsNone(scoped(base_tier_dispatch(), job_name=None))
        lane = dict(base_tier_dispatch(), head_branch="lane/odd-27327-spaces")
        push = dict(base_tier_dispatch(), event="push")
        dev = dict(base_tier_dispatch(), display_title="cmux NEXT DEV daily · " + BASE_TIER_SHA,
                   name="cmux NEXT DEV daily · " + BASE_TIER_SHA)
        for run in (lane, push, dev):
            with self.subTest(run=run["display_title"], branch=run["head_branch"], event=run["event"]):
                self.assertIsNone(scoped(run))

    def test_dispatch_kind_drops_the_trailing_sha(self):
        self.assertEqual(janitor.dispatch_kind(base_tier_dispatch()), "cmux-next base tier")
        self.assertEqual(janitor.dispatch_kind({"display_title": "app-host test rerun @ e872d40b"}),
                         "app-host test rerun @ e872d40b")

    def sweep(self, fake, temp):
        return LostAssignmentSweepTests.sweep(self, fake, temp)

    def world(self):
        run = base_tier_dispatch()
        jobs = real_41190186270_jobs()
        other, other_jobs = served_mac26()
        fake = FakeGitHub({run["id"]: dict(run), other["id"]: dict(other)},
                          {run["id"]: jobs, other["id"]: other_jobs})
        fake.prs["feat-cmux-next"] = []
        fake.prs["other"] = []
        fake.branches["feat-cmux-next"] = "f" * 40  # the branch moved on, as it does every few minutes
        fake.completed["cmux-next.yml"] = []
        return run, jobs, fake

    def test_run_41190186270_is_cancelled_then_re_run_at_the_same_head(self):
        run, jobs, fake = self.world()
        with tempfile.TemporaryDirectory() as temp:
            code, text = self.sweep(fake, temp)
            self.assertEqual(code, 0)
            self.assertEqual(fake.posts(), [[str(run["id"]), "cancel"]])
            entries = fake.snapshots[-1]["lost_reruns"]
            self.assertEqual([entry["run_id"] for entry in entries], [run["id"]])
            self.assertEqual(entries[0]["dispatch"], {"kind": "cmux-next base tier", "title": run["display_title"],
                                                      "job": "cmux-next daemon tests"})
            self.assertNotIn("job_id", entries[0])
            self.assertIn("Re-run by the next sweep", text)
            fake.runs[run["id"]]["conclusion"] = "cancelled"

            # The next sweep: no newer base tier dispatch took the daemon tests, so it is re-run at its head.
            fake.log.clear()
            code, text = self.sweep(fake, temp)
            self.assertEqual(code, 0)
            self.assertEqual(fake.posts(), [[str(run["id"]), "rerun-failed-jobs"]])
            self.assertEqual(fake.snapshots[-1]["lost_reruns"], [])
            self.assertEqual(fake.runs[run["id"]]["run_attempt"], 2)
            self.assertEqual(fake.runs[run["id"]]["head_sha"], BASE_TIER_SHA)
            self.assertIn("orphaned dispatch", text)

    def test_the_attempt_bounds_the_loop(self):
        run, jobs, fake = self.world()
        posts = []
        with tempfile.TemporaryDirectory() as temp:
            for _ in range(8):
                fake.log.clear()
                self.sweep(fake, temp)
                posts += fake.posts()
                current = fake.runs[run["id"]]
                if current["status"] == "completed":
                    current["conclusion"] = "cancelled"
        reruns = [post for post in posts if post == [str(run["id"]), "rerun-failed-jobs"]]
        cancels = [post for post in posts if post == [str(run["id"]), "cancel"]]
        # Attempts 1 and 2 are cancelled and re-run; attempt 3 (LOST_FAILOVER_MAX_ATTEMPT) is cancelled with none.
        self.assertEqual(len(reruns), janitor.LOST_FAILOVER_MAX_ATTEMPT - 1)
        self.assertEqual(len(cancels), janitor.LOST_FAILOVER_MAX_ATTEMPT)
        self.assertEqual(fake.runs[run["id"]]["run_attempt"], janitor.LOST_FAILOVER_MAX_ATTEMPT)
        self.assertEqual(fake.snapshots[-1]["lost_reruns"], [])

    def pending(self, run, *, job="cmux-next daemon tests", title=None):
        entry = pending_entry(run)
        entry["dispatch"] = {"kind": janitor.dispatch_kind(run), "title": title or run["display_title"], "job": job}
        return entry

    def judge(self, run, listed, jobs):
        cancelled = dict(run, status="completed", conclusion="cancelled")
        return janitor.plan_lost_reruns([self.pending(cancelled)], {run["id"]: cancelled}, {}, now=NOW,
                                        head_runs={}, branch_heads={}, dispatch_runs={run["id"]: listed},
                                        dispatch_jobs=jobs)

    def test_only_a_newer_dispatch_that_took_the_job_drops_it(self):
        run = base_tier_dispatch()
        newer = dict(base_tier_dispatch(sha="8710f236" + "0" * 32, age=60, status="completed"), conclusion="success")
        cases = (
            ("ran it", [daemon_job(started=True)], "drop"),
            ("ran it red", [daemon_job(started=True, conclusion="failure")], "drop"),
            ("still running it", [daemon_job(started=True, status="in_progress")], "drop"),
            # The kick's own base tier run skips the daemon tests its same-tree run carries (41199046903).
            ("skipped it", [dict(daemon_job(started=False), conclusion="skipped")], "rerun"),
            ("lost it too", [dict(daemon_job(started=False), conclusion="cancelled")], "rerun"),
            ("still queued", [daemon_job(started=False, status="queued")], "rerun"),
            ("unread", None, "rerun"),
        )
        for label, jobs, action in cases:
            with self.subTest(label):
                decisions = self.judge(run, [newer], {} if jobs is None else {newer["id"]: jobs})
                self.assertEqual([d.action for d in decisions], [action])
                if action == "drop":
                    self.assertIn(str(newer["id"]), decisions[0].note)
        # An older dispatch, another workflow or kind, a push or another branch never covers it.
        older = dict(newer, id=run["id"] - 1)
        unrelated = [older, dict(newer, id=newer["id"] + 1, path=".github/workflows/other.yml"),
                     dict(newer, id=newer["id"] + 2, display_title="cmux-next tip Swift suite · " + "1" * 40),
                     dict(newer, id=newer["id"] + 3, event="push"),
                     dict(newer, id=newer["id"] + 4, head_branch="main")]
        ran = {other["id"]: [daemon_job(started=True)] for other in unrelated}
        self.assertEqual([d.action for d in self.judge(run, unrelated, ran)], ["rerun"])
        # Not listed this sweep: kept.
        cancelled = dict(run, status="completed", conclusion="cancelled")
        decisions = janitor.plan_lost_reruns([self.pending(cancelled)], {run["id"]: cancelled}, {}, now=NOW,
                                             head_runs={}, dispatch_runs={}, dispatch_jobs={})
        self.assertEqual([d.action for d in decisions], ["keep"])

    def test_a_same_tree_dispatch_is_covered_only_by_one_for_its_own_commit(self):
        # Run 41193804308: `cmux-next · bcec3ce..`, a same-tree dispatch whose scheme compile lost its runner.
        sha = "bcec3ce4" + "0" * 32
        run = base_tier_dispatch(sha=sha, kind="cmux-next")
        other_commit = base_tier_dispatch(sha="625b1ca0" + "0" * 32, kind="cmux-next", age=20)
        same_commit = base_tier_dispatch(sha=sha, kind="cmux-next", age=20)
        scheme = dict(daemon_job(started=True), name="cmux app scheme compile (Debug)")
        cancelled = dict(run, status="completed", conclusion="cancelled")
        for newer, action in ((other_commit, "rerun"), (same_commit, "drop")):
            with self.subTest(newer=newer["display_title"]):
                decisions = janitor.plan_lost_reruns(
                    [self.pending(cancelled, job="cmux app scheme compile (Debug)")], {run["id"]: cancelled}, {},
                    now=NOW, head_runs={}, dispatch_runs={run["id"]: [newer]}, dispatch_jobs={newer["id"]: [scheme]})
                self.assertEqual([d.action for d in decisions], [action])

    def test_a_run_that_already_failed_re_runs_only_its_lost_job(self):
        run = base_tier_dispatch()
        jobs = real_41190186270_jobs()
        jobs[2] = dict(jobs[2], conclusion="failure")
        orphans = find([run], {run["id"]: jobs, 1: served_mac26()[1]})
        decisions = orphan_plan(orphans)
        self.assertEqual([d.action for d in decisions], ["cancel"])
        entries = janitor.orphan_reruns(decisions, {run["id"]: "cancelled"}, {run["id"]: jobs}, now=NOW)
        self.assertEqual(entries[0]["job_id"], jobs[1]["id"])
        # A cancel that did not take, or GitHub would not end, carries nothing.
        for result in ("stuck: GitHub refused cancel and force-cancel (x)", "failed: boom", "skipped (now completed)"):
            self.assertEqual(janitor.orphan_reruns(decisions, {run["id"]: result}, {run["id"]: jobs}, now=NOW), [])

    def test_a_dry_run_carries_no_orphan_re_run(self):
        run, jobs, fake = self.world()
        with tempfile.TemporaryDirectory() as temp:
            LostAssignmentSweepTests.sweep(self, fake, temp, "--dry-run")
        self.assertEqual(fake.posts(), [])
        self.assertEqual(fake.snapshots[-1]["lost_reruns"], [])


if __name__ == "__main__":
    unittest.main()
