#!/usr/bin/env python3
"""Policy tests for scripts/ci/queue_janitor.py over fixture JSON (no network)."""

from __future__ import annotations

import datetime as dt
import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path


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
            files=("web/app/page.tsx",), files_truncated=False):
    return {
        "number": number, "state": state, "isDraft": draft, "headRefOid": head,
        "headRepositoryOwner": {"login": owner},
        "files": None if files is None else {
            "pageInfo": {"hasNextPage": files_truncated},
            "nodes": [{"path": path} for path in files],
        },
        "labels": {"nodes": [{"name": name} for name in labels]},
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
        block = macos.split("\n  app-host-unit-tests:\n", 1)[1].split("\n  ", 1)[0]
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

        # 13 queued: experiment frees 2 -> 11, merged frees 1 -> 10; stop at 10.
        result = plan(runs, jobs, prs, threshold=10)
        self.assertEqual([d.action for d in result.decisions], ["cancel", "cancel", "skip"])

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
        self.assertEqual([(d.candidate.run["id"], d.action) for d in result.decisions],
                         [(idle_exp["id"], "skip"), (stuck_exp["id"], "cancel")])
        self.assertIn("not backed up", result.decisions[0].note)

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


class WorkflowShapeTests(unittest.TestCase):
    def setUp(self):
        self.text = WORKFLOW.read_text(encoding="utf-8")

    def test_triggers_permissions_and_runner(self):
        text = self.text
        self.assertIn('- cron: "*/10 * * * *"', text)
        self.assertIn("workflow_dispatch:", text)
        self.assertIn("dry_run:", text)
        self.assertNotIn("pull_request", text.split("jobs:")[0].replace("pull-requests: read", ""))
        self.assertIn("permissions:\n  actions: write\n  pull-requests: read\n  contents: read\n", text)
        self.assertIn("runs-on: ${{ vars.LINUX_RUNNER || 'blacksmith-4vcpu-ubuntu-2404' }}", text)
        self.assertIn("concurrency:\n  group: ci-queue-janitor\n  cancel-in-progress: false\n", text)
        self.assertIn("vars.CI_JANITOR_QUEUE_THRESHOLD", text)
        self.assertIn("run: python3 scripts/ci/queue_janitor.py", text)
        self.assertIn("persist-credentials: false", text)

    def test_manual_dispatch_defaults_to_dry_run(self):
        block = self.text.split("dry_run:", 1)[1].split("permissions:", 1)[0]
        self.assertIn("default: true", block)
        self.assertIn("inputs.dry_run && 'true'", self.text)
        self.assertIn("vars.CI_JANITOR_DRY_RUN == 'true'", self.text)


if __name__ == "__main__":
    unittest.main()
