"""gh-merge-green excuses a red check only when the base branch's latest completed run has the same failures."""
import copy
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
import unittest.mock
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("base_red_excuse", ROOT / "scripts/ci/base_red_excuse.py")
excuse = importlib.util.module_from_spec(spec)
spec.loader.exec_module(excuse)

REPO = "manaflow-ai/cmux"
HEAD = "a" * 40
BASE_SHA = "b" * 40
SWIFT = "cmux-next swift test"
SCHEME = "cmux app scheme compile (Debug)"
TEST_STEP = "Run package tests"
ISSUE = ("✘ Test writesTheRequestAfterTheReadyMarkerAndReturnsTheReply() recorded an issue at "
         "DiffSidecarProcessTests.swift:41:9: Expectation failed")
OTHER = "✘ Test palettePagesReleaseTheRegistry() recorded an issue at PaletteNavigationTests.swift:88:3: Expectation failed"


def log(job, step, *lines):
    return "\n".join(f"{job}\t{step}\t2026-10-07T02:10:37.8032610Z {line}" for line in lines)


def failed_job(job_id, run_id, sha, name=SWIFT, step=TEST_STEP):
    return {"id": job_id, "run_id": run_id, "head_sha": sha, "name": name, "status": "completed",
            "conclusion": "failure", "steps": [
                {"name": "Set up runner", "status": "completed", "conclusion": "success"},
                {"name": "Build package and tests", "status": "completed", "conclusion": "success"},
                {"name": step, "status": "completed", "conclusion": "failure"}]}


class FakeGitHub:
    """The head run 10 (workflow 7) and feat-cmux-next's latest completed run 20 of the same workflow."""

    def __init__(self):
        self.jobs = {1: failed_job(1, 10, HEAD), 2: failed_job(2, 20, BASE_SHA)}
        self.logs = {1: log(SWIFT, TEST_STEP, ISSUE, "##[error]1 red tests: writesTheRequest()"),
                     2: log(SWIFT, TEST_STEP, ISSUE, OTHER, "##[error]2 red tests: writesTheRequest(), palette()")}
        self.base_runs = [{"id": 21, "event": "push", "head_branch": "feat-cmux-next", "status": "completed",
                           "conclusion": "cancelled"},
                          {"id": 20, "event": "push", "head_branch": "feat-cmux-next", "status": "completed",
                           "conclusion": "failure", "head_sha": BASE_SHA}]
        self.routes: list[str] = []
        # Base commits, newest first, by ref; check runs per commit; sibling pull request runs.
        self.history: dict[str, list[str]] = {}
        self.merge_base: str | None = None
        self.commit_checks: dict[str, list[dict]] = {}
        self.pr_runs: list[dict] = []
        self.pr_commits: dict[int, list[str]] = {}
        # Runs of workflows other than 7, by workflow; the workflow of each run that is not 7.
        self.other_runs: dict[int, list[dict]] = {}
        self.run_workflows: dict[int, int] = {}
        # Base commits that predate the merge-base (a compare from it says "behind"), and the
        # runs of workflow 7 at the base tip.
        self.stale: set[str] = set()
        self.tip_runs: list[dict] = []
        # Completed workflow_dispatch runs of workflow 7 on the base (the tip Swift suite).
        self.dispatch_runs: list[dict] = []

    def json(self, route, *, paginate=False):
        self.routes.append(route)
        if "/commits?sha=" in route:
            ref = route.split("?sha=", 1)[1].split("&", 1)[0]
            limit = int(route.rsplit("per_page=", 1)[1])
            return [{"sha": sha} for sha in self.history.get(ref, [])[:limit]]
        if "/compare/" in route:
            ancestor, sha = route.split("/compare/", 1)[1].split("?", 1)[0].split("...")
            if sha != HEAD:
                assert ancestor == self.merge_base, route
                return {"status": "behind" if sha in self.stale else ("identical" if sha == ancestor else "ahead")}
            return {"merge_base_commit": {"sha": self.merge_base}} if self.merge_base else {}
        if "/commits/" in route and "/check-runs" in route:
            sha = route.split("/commits/", 1)[1].split("/", 1)[0]
            return [{"check_runs": copy.deepcopy(self.commit_checks.get(sha, []))}]
        if "/actions/jobs/" in route:
            return copy.deepcopy(self.jobs[int(route.rsplit("/", 1)[1])])
        if "/pulls/" in route and "/commits" in route:
            number = int(route.split("/pulls/", 1)[1].split("/", 1)[0])
            return [[{"sha": sha} for sha in self.pr_commits.get(number, [])]]
        if "/actions/workflows/7/runs?" in route and "event=pull_request" in route:
            return {"workflow_runs": copy.deepcopy(self.pr_runs)}
        if "/actions/workflows/7/runs?" in route and "head_sha=" in route:
            return {"workflow_runs": copy.deepcopy(self.tip_runs)}
        if "/actions/workflows/7/runs?" in route and "event=workflow_dispatch" in route:
            assert "branch=feat-cmux-next" in route and "status=completed" in route, route
            return {"workflow_runs": copy.deepcopy(self.dispatch_runs)}
        if "/actions/runs/" in route and route.endswith("/jobs?filter=latest&per_page=100"):
            run = int(route.split("/actions/runs/", 1)[1].split("/", 1)[0])
            return [{"jobs": [copy.deepcopy(job) for job in self.jobs.values() if job["run_id"] == run]}]
        if "/actions/workflows/" in route and "/actions/workflows/7/" not in route:
            assert "branch=feat-cmux-next" in route and "status=completed" in route, route
            workflow = int(route.split("/actions/workflows/", 1)[1].split("/", 1)[0])
            return {"workflow_runs": copy.deepcopy(self.other_runs.get(workflow, []))}
        if "/actions/workflows/7/runs?" in route:
            assert "branch=feat-cmux-next" in route and "status=completed" in route, route
            return {"workflow_runs": copy.deepcopy(self.base_runs)}
        if "/actions/runs/" in route:
            run = int(route.rsplit("/", 1)[1])
            return {"id": run, "workflow_id": self.run_workflows.get(run, 7), "path": ".github/workflows/ci.yml"}
        raise AssertionError(route)

    def log(self, repo, job):
        return self.logs[job["id"]]


class Excusing(unittest.TestCase):
    def setUp(self):
        self.gh = FakeGitHub()

    def judge(self, runs=(10,)):
        return excuse.judge(REPO, "feat-cmux-next", HEAD, list(runs), self.gh)

    def test_a_test_failing_on_the_base_too_is_excused_with_the_base_run_named(self):
        lines = self.judge()
        text = "\n".join(lines)
        self.assertIn(SWIFT, text)
        self.assertIn("run 20", text)
        self.assertIn("writesTheRequestAfterTheReadyMarkerAndReturnsTheReply()", text)
        # The cancelled run 21 has no verdict; the newest run with one decides.
        self.assertNotIn("run 21", text)

    def test_a_job_pushes_skip_is_judged_by_the_newest_dispatched_base_run(self):
        # cmux-next swift test is skipped on feat-cmux-next pushes; its base verdict comes from the
        # scheduled tip Swift suite dispatch, older than the newest twenty push runs.
        self.gh.base_runs = [{"id": 21, "event": "push", "head_branch": "feat-cmux-next", "status": "completed",
                              "conclusion": "success", "created_at": "2026-10-21T20:00:00Z"}]
        self.gh.dispatch_runs = [{"id": 20, "event": "workflow_dispatch", "head_branch": "feat-cmux-next",
                                  "status": "completed", "conclusion": "failure", "head_sha": BASE_SHA,
                                  "created_at": "2026-10-21T17:00:00Z"}]
        self.assertIn("run 20", "\n".join(self.judge()))

    def test_counts_do_not_matter_only_names(self):
        # The base fails one more test than the head; the head's are all on the base.
        self.assertTrue(self.judge())

    def test_a_failure_not_on_the_base_blocks(self):
        self.gh.logs[1] = log(SWIFT, TEST_STEP, ISSUE, OTHER.replace("palettePages", "somethingNew"))
        with self.assertRaisesRegex(excuse.Refused, "somethingNew"):
            self.judge()

    def test_a_different_failed_step_blocks(self):
        self.gh.jobs[1]["steps"][1]["conclusion"] = "failure"
        with self.assertRaisesRegex(excuse.Refused, "Build package and tests"):
            self.judge()

    def test_a_compile_error_not_on_the_base_blocks(self):
        self.gh.jobs[1] = failed_job(1, 10, HEAD, name=SCHEME, step="Compile the cmux scheme")
        self.gh.jobs[2] = failed_job(2, 20, BASE_SHA, name=SCHEME, step="Compile the cmux scheme")
        self.gh.logs[1] = log(SCHEME, "Compile the cmux scheme",
                              "Sources/App/New.swift:12:5: error: cannot find 'x' in scope")
        self.gh.logs[2] = log(SCHEME, "Compile the cmux scheme",
                              "Sources/App/Onboarding.swift:30:7: error: type 'ActionSurfaces' has no member 'cli'")
        with self.assertRaisesRegex(excuse.Refused, "cannot find 'x' in scope"):
            self.judge()

    def test_the_same_compile_error_at_a_moved_line_is_excused(self):
        self.gh.jobs[1] = failed_job(1, 10, HEAD, name=SCHEME, step="Compile the cmux scheme")
        self.gh.jobs[2] = failed_job(2, 20, BASE_SHA, name=SCHEME, step="Compile the cmux scheme")
        self.gh.logs[1] = log(SCHEME, "Compile the cmux scheme",
                              "Sources/App/Onboarding.swift:31:7: error: type 'ActionSurfaces' has no member 'cli'")
        self.gh.logs[2] = log(SCHEME, "Compile the cmux scheme",
                              "Sources/App/Onboarding.swift:30:7: error: type 'ActionSurfaces' has no member 'cli'")
        self.assertIn(SCHEME, "\n".join(self.judge()))

    def test_warning_lines_that_differ_between_runs_do_not_block(self):
        # #18147 at 6b8ec44652f against base run 37564446089: the same red test,
        # refused over SwiftPM cache warnings only the head printed.
        self.gh.logs[1] = log(SWIFT, TEST_STEP, ISSUE,
                              "warning: 'swift-collections': skipping cache due to an error: "
                              "The file \u201cmaintenance.lock\u201d doesn\u2019t exist.",
                              "##[warning]'swift-system': skipping cache due to an error: lock")
        self.assertIn(SWIFT, "\n".join(self.judge()))

    def test_failing_tests_decide_and_error_lines_beside_them_are_not_compared(self):
        self.gh.logs[1] = log(SWIFT, TEST_STEP, ISSUE, "##[error]error: the swift test run exited with code 1")
        self.assertIn(SWIFT, "\n".join(self.judge()))

    def test_a_compile_error_with_a_warning_only_the_head_printed_is_excused(self):
        self.gh.jobs[1] = failed_job(1, 10, HEAD, name=SCHEME, step="Compile the cmux scheme")
        self.gh.jobs[2] = failed_job(2, 20, BASE_SHA, name=SCHEME, step="Compile the cmux scheme")
        error = "Sources/App/Onboarding.swift:30:7: error: type 'ActionSurfaces' has no member 'cli'"
        self.gh.logs[1] = log(SCHEME, "Compile the cmux scheme", error,
                              "Sources/App/Other.swift:9:1: warning: an error: in a warning is noise")
        self.gh.logs[2] = log(SCHEME, "Compile the cmux scheme", error)
        self.assertIn(SCHEME, "\n".join(self.judge()))

    def test_a_job_green_on_the_base_blocks(self):
        self.gh.jobs[2]["conclusion"] = "success"
        with self.assertRaisesRegex(excuse.Refused, "not red on feat-cmux-next"):
            self.judge()

    def test_a_job_the_base_did_not_run_blocks(self):
        del self.gh.jobs[2]
        with self.assertRaisesRegex(excuse.Refused, "no completed feat-cmux-next run"):
            self.judge()

    def test_the_newest_base_run_with_a_verdict_for_the_job_decides(self):
        # 2026-10-07: the newest base push run's swift test was cancelled by the next push.
        self.gh.base_runs.insert(0, {"id": 22, "event": "push", "head_branch": "feat-cmux-next",
                                     "status": "completed", "conclusion": "failure"})
        self.gh.jobs[4] = dict(failed_job(4, 22, BASE_SHA), conclusion="cancelled")
        self.gh.jobs[5] = dict(failed_job(5, 22, BASE_SHA, name=SCHEME))
        self.gh.jobs[5]["steps"] = [{"name": "Set up runner", "status": "completed", "conclusion": "failure"}]
        text = "\n".join(self.judge())
        self.assertIn("run 20", text)
        self.assertNotIn("run 22", text)

    def test_no_completed_base_run_blocks(self):
        self.gh.base_runs = []
        with self.assertRaisesRegex(excuse.Refused, "no completed"):
            self.judge()

    def test_a_setup_refusal_is_never_excused(self):
        self.gh.jobs[1]["steps"] = [{"name": "Set up job", "status": "completed", "conclusion": "success"},
                                    {"name": "Set up runner", "status": "completed", "conclusion": "failure"}]
        self.gh.logs[1] = log(SWIFT, "Set up runner",
                              "##[error]glaeda-cmux-runner-hook: refused: a fleet build is waiting for the host (pid 1)")
        self.gh.jobs[2]["steps"] = copy.deepcopy(self.gh.jobs[1]["steps"])
        self.gh.logs[2] = self.gh.logs[1]
        with self.assertRaisesRegex(excuse.Refused, "refused at setup"):
            self.judge()

    def test_a_job_with_no_steps_is_never_excused(self):
        self.gh.jobs[1]["steps"] = []
        with self.assertRaisesRegex(excuse.Refused, "refused at setup"):
            self.judge()

    def test_a_cancelled_or_timed_out_job_is_never_excused(self):
        for conclusion in ("cancelled", "timed_out"):
            self.gh.jobs[1]["conclusion"] = conclusion
            with self.assertRaisesRegex(excuse.Refused, conclusion):
                self.judge()

    def test_a_failure_with_nothing_to_compare_blocks(self):
        # No test names and no error lines: the same step name alone proves nothing.
        self.gh.logs[1] = log(SWIFT, TEST_STEP, "##[error]Process completed with exit code 1.")
        with self.assertRaisesRegex(excuse.Refused, "nothing to compare"):
            self.judge()

    def test_a_red_run_with_no_failed_job_listed_blocks(self):
        self.gh.jobs[1]["conclusion"] = "success"
        with self.assertRaisesRegex(excuse.Refused, "no failed job"):
            self.judge()

    def test_check_names_resolve_to_their_head_jobs(self):
        self.gh.check_runs = [{"check_runs": [
            {"id": 1, "name": SWIFT, "status": "completed", "conclusion": "failure", "app": {"slug": "github-actions"},
             "details_url": f"https://github.com/{REPO}/actions/runs/10/job/1"}]}]
        original = self.gh.json

        def json_with_checks(route, *, paginate=False):
            if route.endswith(f"commits/{HEAD}/check-runs?per_page=100"):
                return copy.deepcopy(self.gh.check_runs)
            if route.endswith("/actions/jobs/1"):
                return copy.deepcopy(self.gh.jobs[1])
            return original(route, paginate=paginate)

        self.gh.json = json_with_checks
        lines = excuse.judge(REPO, "feat-cmux-next", HEAD, [], self.gh, checks=[SWIFT])
        self.assertIn("run 20", "\n".join(lines))

    def with_checks(self, checks):
        self.gh.check_runs = [{"check_runs": checks}]
        original = self.gh.json

        def json_with_checks(route, *, paginate=False):
            if route.endswith(f"commits/{HEAD}/check-runs?per_page=100"):
                return copy.deepcopy(self.gh.check_runs)
            if "/actions/jobs/" in route:
                return copy.deepcopy(self.gh.jobs[int(route.rsplit("/", 1)[1])])
            return original(route, paginate=paginate)

        self.gh.json = json_with_checks

    def test_a_red_ci_status_is_judged_by_the_failed_jobs_of_its_run(self):
        self.gh.jobs[3] = {"id": 3, "run_id": 10, "head_sha": HEAD, "name": "ci-status", "status": "completed",
                           "conclusion": "failure", "steps": [{"name": "Report", "conclusion": "failure"}]}
        self.with_checks([{"id": 3, "name": "ci-status", "status": "completed", "conclusion": "failure",
                           "app": {"slug": "github-actions"},
                           "details_url": f"https://github.com/{REPO}/actions/runs/10/job/3"}])
        lines = excuse.judge(REPO, "feat-cmux-next", HEAD, [], self.gh, checks=["ci-status"])
        self.assertIn(SWIFT, "\n".join(lines))
        self.assertNotIn("'ci-status'", "\n".join(lines))

    def test_a_red_ci_status_with_no_other_failed_job_blocks(self):
        self.gh.jobs[1]["conclusion"] = "success"
        self.gh.jobs[3] = {"id": 3, "run_id": 10, "head_sha": HEAD, "name": "ci-status", "status": "completed",
                           "conclusion": "failure", "steps": [{"name": "Report", "conclusion": "failure"}]}
        self.with_checks([{"id": 3, "name": "ci-status", "status": "completed", "conclusion": "failure",
                           "app": {"slug": "github-actions"},
                           "details_url": f"https://github.com/{REPO}/actions/runs/10/job/3"}])
        with self.assertRaisesRegex(excuse.Refused, "no failed job"):
            excuse.judge(REPO, "feat-cmux-next", HEAD, [], self.gh, checks=["ci-status"])


def crashed(job, signal, unfinished, frames, *extra):
    """A swift test log whose test helper died on `signal` with `unfinished` tests in flight."""
    return log(job, TEST_STEP, *extra,
               f"error: Process '/x/swiftpm-testing-helper --test-bundle-path /x/CmuxNextPackageTests' "
               f"exited with unexpected signal code {signal}",
               f"##[error]no \"Test run with\" summary line (crash, kill or truncation); {len(unfinished)} tests "
               f"started and never finished: {'; '.join(unfinished)}",
               f"##[error]the test helper died on signal {signal}; crashed thread: {frames}")


class CrashIsNeverABaseRed(unittest.TestCase):
    """A test helper crash is the head's own red whatever the base shows (scripts/ci/test_reds.py; cmux#26346
    landed with its own signal 6 because its swift test job was red on the base too)."""

    def setUp(self):
        self.gh = FakeGitHub()
        self.gh.logs[2] = crashed(SWIFT, 5, ["a()", "b()"], "swift_task_checkIsolatedSwift <- KeyWindowObserver.windowWillClose(_:)")

    def judge(self):
        return excuse.judge(REPO, "feat-cmux-next", HEAD, [10], self.gh)

    def test_a_crash_with_the_signal_the_base_crashed_on_still_blocks(self):
        self.gh.logs[1] = crashed(SWIFT, 5, ["c()", "d()", "e()"], "swift_task_checkIsolatedSwift <- ???")
        with self.assertRaisesRegex(excuse.Refused, r"crashed \(signal 5\).*never a base red"):
            self.judge()

    def test_a_crash_the_base_did_not_have_blocks(self):
        self.gh.logs[1] = crashed(SWIFT, 5, ["c()"], "f")
        self.gh.logs[2] = log(SWIFT, TEST_STEP, ISSUE)
        with self.assertRaisesRegex(excuse.Refused, "signal 5"):
            self.judge()

    def test_a_non_test_job_that_died_on_a_signal_the_base_did_not_blocks(self):
        self.gh.logs[1] = log(SWIFT, TEST_STEP, "error: cannot find 'x' in scope", "the test helper died on signal 11")
        self.gh.logs[2] = log(SWIFT, TEST_STEP, "error: cannot find 'x' in scope")
        for job in self.gh.jobs.values():
            job["name"] = "cmux app scheme compile (Debug)"
        with self.assertRaisesRegex(excuse.Refused, "signal 11"):
            self.judge()

    def test_a_web_test_shard_that_timed_out_on_both_sides_still_blocks(self):
        web = "web / react-apps-check (1)"
        for job in self.gh.jobs.values():
            job["name"] = web
        self.gh.logs[1] = self.gh.logs[2] = log(web, TEST_STEP, "START src/a.test.ts (hard limit 300s)",
                                                "TIMEOUT src/a.test.ts (limit 300s)")
        with self.assertRaisesRegex(excuse.Refused, "src/a.test.ts timed out"):
            self.judge()

    def test_a_red_test_the_base_does_not_fail_blocks(self):
        self.gh.logs[1] = log(SWIFT, TEST_STEP, ISSUE, OTHER)
        self.gh.logs[2] = log(SWIFT, TEST_STEP, ISSUE)
        with self.assertRaisesRegex(excuse.Refused, "palettePagesReleaseTheRegistry"):
            self.judge()


OLD_BASE = "e" * 40
NEW_TIP = "f" * 40

class StaleBase(unittest.TestCase):
    """2026-10-20: feat-cmux-next's CI workflow runs only when dispatched. Its newest run, from
    02:29Z, predated every red that landed after it, so each read as "not excused"."""

    def setUp(self):
        self.gh = FakeGitHub()
        # The PR branched from BASE_SHA; the base has moved on to NEW_TIP since. No commit has check runs
        # for the job, so the base workflow's runs decide.
        self.gh.history = {"feat-cmux-next": [NEW_TIP, BASE_SHA, OLD_BASE]}
        self.gh.merge_base = BASE_SHA

    def judge(self):
        return excuse.judge(REPO, "feat-cmux-next", HEAD, [10], self.gh)

    def test_a_base_run_older_than_the_merge_base_is_not_compared(self):
        # Run 20 ran on a commit before the merge-base: it is green there, as the base was then.
        self.gh.jobs[2].update(head_sha=OLD_BASE, conclusion="success")
        self.gh.base_runs[1]["head_sha"] = OLD_BASE
        self.gh.stale = {OLD_BASE}
        with self.assertRaises(excuse.Refused) as caught:
            self.judge()
        text = str(caught.exception)
        self.assertNotIn("not red on", text)
        self.assertIn("run 20", text)
        self.assertIn(BASE_SHA[:10], text)
        self.assertIn(NEW_TIP[:10], text)
        self.assertIn("gh workflow run ci.yml --repo manaflow-ai/cmux --ref feat-cmux-next", text)

    def test_a_running_base_run_at_the_tip_is_named_instead_of_a_dispatch(self):
        self.gh.base_runs[1]["head_sha"] = OLD_BASE
        self.gh.jobs[2]["head_sha"] = OLD_BASE
        self.gh.stale = {OLD_BASE}
        self.gh.jobs[2]["conclusion"] = "success"
        self.gh.tip_runs = [{"id": 39386215666, "status": "in_progress", "head_sha": NEW_TIP}]
        with self.assertRaisesRegex(excuse.Refused, f"run 39386215666 of ci.yml at the base tip {NEW_TIP[:10]} is in_progress"):
            self.judge()

    def test_an_unreadable_tip_run_list_still_names_the_dispatch(self):
        self.gh.base_runs[1]["head_sha"] = OLD_BASE
        self.gh.jobs[2].update(head_sha=OLD_BASE, conclusion="success")
        self.gh.stale = {OLD_BASE}
        original = self.gh.json

        def failing(route, *, paginate=False):
            if "head_sha=" in route:
                raise excuse.Refused("GitHub evidence request failed: HTTP 502")
            return original(route, paginate=paginate)
        self.gh.json = failing
        with self.assertRaises(excuse.Refused) as caught:
            self.judge()
        self.assertIn("gh workflow run ci.yml", str(caught.exception))
        self.assertIn("run 20", str(caught.exception))

    def test_base_runs_are_read_newest_first_whatever_order_github_lists_them(self):
        # Run 20 (a stale green) is listed before run 23, the newer run at the tip that is red the same way.
        self.gh.base_runs[1].update(head_sha=OLD_BASE, created_at="2026-10-20T02:29:05Z")
        self.gh.jobs[2].update(head_sha=OLD_BASE, conclusion="success")
        self.gh.stale = {OLD_BASE}
        self.gh.base_runs.append({"id": 23, "event": "workflow_dispatch", "status": "completed", "conclusion": "failure",
                                  "head_sha": NEW_TIP, "created_at": "2026-10-20T07:40:00Z"})
        self.gh.jobs[3] = failed_job(3, 23, NEW_TIP)
        self.gh.logs[3] = self.gh.logs[1]
        self.assertIn("run 23", "\n".join(self.judge()))

    def test_a_stale_base_run_red_the_same_way_still_excuses(self):
        # The head inherits a red its merge-base's ancestors already had.
        self.gh.base_runs[1]["head_sha"] = OLD_BASE
        self.gh.jobs[2]["head_sha"] = OLD_BASE
        self.gh.stale = {OLD_BASE}
        self.assertIn("run 20", "\n".join(self.judge()))

    def test_a_base_run_with_no_commit_is_stale(self):
        self.gh.jobs[2]["conclusion"] = "success"
        del self.gh.base_runs[1]["head_sha"]
        with self.assertRaisesRegex(excuse.Refused, "run 20 at \\? .*predates the merge-base"):
            self.judge()

    def test_a_green_commit_before_the_merge_base_is_not_a_verdict(self):
        # merge-base's own check runs say nothing; tip~2 (older than the merge-base) is green.
        check = {"id": 9, "name": SWIFT, "status": "completed", "conclusion": "success", "app": {"slug": "github-actions"},
                 "details_url": f"https://github.com/{REPO}/actions/runs/30/job/9"}
        self.gh.commit_checks = {OLD_BASE: [check]}
        self.gh.jobs[9] = dict(failed_job(9, 30, OLD_BASE), conclusion="success")
        self.gh.base_runs = []
        with self.assertRaises(excuse.Refused) as caught:
            self.judge()
        text = str(caught.exception)
        self.assertIn("predates the merge-base", text)
        self.assertIn("gh workflow run ci.yml", text)

    def test_a_base_run_at_the_tip_after_the_merge_base_decides(self):
        # The newest run contains the merge-base: the red there is the base's.
        self.gh.base_runs[1]["head_sha"] = NEW_TIP
        self.gh.jobs[2]["head_sha"] = NEW_TIP
        text = "\n".join(self.judge())
        self.assertIn("run 20", text)
        self.assertIn("writesTheRequestAfterTheReadyMarkerAndReturnsTheReply()", text)


DEFAULTS = "defaults-snapshot"
FRESH = "The defaults snapshot matches the exports"


class StepOutput(unittest.TestCase):
    """2026-10-20: defaults-snapshot was red on feat-cmux-next too, but its step prints no test
    name and no `error:` line, so it was refused with "no failing test or error line to match"."""

    def setUp(self):
        self.gh = FakeGitHub()
        self.gh.jobs = {1: failed_job(1, 10, HEAD, name=DEFAULTS, step=FRESH),
                        2: failed_job(2, 20, BASE_SHA, name=DEFAULTS, step=FRESH)}
        stale = ("schemas/defaults/cmux-next.json is stale: the settings export changed "
                 "(source stamp 3f9a2c1d0b != 81be44a7c2)")
        self.gh.logs = {1: log(DEFAULTS, FRESH, "##[group]Run python3 scripts/ci/defaults_guard.py check-fresh",
                               "##[endgroup]", stale, "##[error]Process completed with exit code 1."),
                        2: log(DEFAULTS, FRESH, "##[group]Run python3 scripts/ci/defaults_guard.py check-fresh",
                               "##[endgroup]", stale.replace("3f9a2c1d0b", "77aa01bc9e"),
                               "##[error]Process completed with exit code 1.")}

    def judge(self):
        return excuse.judge(REPO, "feat-cmux-next", HEAD, [10], self.gh)

    def test_a_red_step_printing_what_the_base_printed_is_excused(self):
        text = "\n".join(self.judge())
        self.assertIn(DEFAULTS, text)
        self.assertIn("schemas/defaults/cmux-next.json is stale", text)

    def test_a_red_step_printing_only_part_of_the_base_output_blocks(self):
        # Review: a head that fails earlier, silently, prints a prefix of the base's output.
        check = "##[group]Run python3 scripts/ci/defaults_guard.py check-fresh"
        self.gh.logs[2] = log(DEFAULTS, FRESH, check, "##[endgroup]", "Checking settings export",
                              "Checking keymap export", "keymap.json is stale",
                              "##[error]Process completed with exit code 1.")
        self.gh.logs[1] = log(DEFAULTS, FRESH, check, "##[endgroup]", "Checking settings export",
                              "##[error]Process completed with exit code 1.")
        with self.assertRaisesRegex(excuse.Refused, "head did not print.*keymap.json is stale"):
            self.judge()

    def test_a_red_step_printing_something_the_base_did_not_blocks(self):
        self.gh.logs[1] = self.gh.logs[1].replace("is stale", "is missing key sidebar.width")
        with self.assertRaisesRegex(excuse.Refused, "output not on feat-cmux-next run 20.*sidebar.width"):
            self.judge()


class RateLimit(unittest.TestCase):
    def test_a_rate_limited_read_exits_3_with_the_reset_time(self):
        fake = Path(tempfile.mkdtemp()) / "gh"
        fake.write_text("#!/bin/sh\n"
                        "if [ \"$1 $2\" = 'api rate_limit' ]; then printf '%s' '{\"resources\":{\"core\":"
                        "{\"limit\":5000,\"remaining\":0,\"reset\":4102444800},\"graphql\":{\"limit\":5000,"
                        "\"remaining\":0,\"reset\":4102444800}}}'; exit 0; fi\n"
                        "echo 'gh: API rate limit exceeded for user ID 13091533. (HTTP 403)' >&2; exit 1\n")
        fake.chmod(0o755)
        env = {**os.environ, "PATH": f"{fake.parent}{os.pathsep}{os.environ['PATH']}"}
        result = subprocess.run([sys.executable, str(ROOT / "scripts/ci/base_red_excuse.py"), "--repo", REPO,
                                 "--base", "feat-cmux-next", "--sha", HEAD, "--run", "10"],
                                env=env, capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 3, result.stderr)
        self.assertIn("rate-limited", result.stderr)
        self.assertIn("core 0 of 5000 left, resets 00:00:00Z", result.stderr)


CHECKS = "cmux-next checks (god files, concurrency, crash safety, l10n)"
L10N = "String tables (21 languages)"
XCSTRINGS = "Packages/macOS/CmuxNext/Sources/CmuxNextSidebar/Resources/Localizable.xcstrings"


def l10n_log(wait_ms, *findings):
    """The step echoes its script and environment in a group, then prints its findings."""
    return log(CHECKS, L10N, "##[group]Run set -o pipefail",
               "\x1b[36;1mscripts/cmux-next/check-l10n.sh \"$GITHUB_WORKSPACE\"\x1b[0m",
               f"  BLACKSMITH_RUNNER_MESSAGE_WAIT_MS: {wait_ms}", "##[endgroup]",
               *findings, f"107 tables, 6180 keys, 21 languages: {len(findings)} errors",
               "##[error]Process completed with exit code 1.")


class LintFindings(unittest.TestCase):
    """A red god-file, l10n or concurrency check is the base's only when every finding is."""

    def setUp(self):
        self.gh = FakeGitHub()
        self.gh.jobs = {1: failed_job(1, 10, HEAD, name=CHECKS, step=L10N),
                        2: failed_job(2, 20, BASE_SHA, name=CHECKS, step=L10N)}
        self.gh.logs = {1: l10n_log(103765, f"{XCSTRINGS}:sidebar.doc.move: missing uk"),
                        2: l10n_log(611, f"{XCSTRINGS}:sidebar.doc.move: missing uk",
                                    f"{XCSTRINGS}:sidebar.doc.move: missing vi")}

    def judge(self):
        return excuse.judge(REPO, "feat-cmux-next", HEAD, [10], self.gh)

    def test_findings_all_on_the_base_are_excused(self):
        text = "\n".join(self.judge())
        self.assertIn(CHECKS, text)
        self.assertIn("sidebar.doc.move: missing uk", text)

    def test_temp_names_and_hashes_that_differ_between_runs_do_not_block(self):
        self.gh.logs[1] = self.gh.logs[1].replace(
            "##[error]Process", "stripping release binary: /tmp/tmp.QIOv8hOe3B/cmux\nSubmodule path 'g': "
            "checked out '738f29bd11cc'\n##[error]Process")
        self.gh.logs[2] = self.gh.logs[2].replace(
            "##[error]Process", "stripping release binary: /tmp/tmp.Zk2pWq9xYa/cmux\nSubmodule path 'g': "
            "checked out 'fcdb3662c651'\n##[error]Process")
        self.gh.logs = {job: "\n".join(line if "\t" in line else f"{CHECKS}\t{L10N}\t{line}"
                                       for line in text.splitlines()) for job, text in self.gh.logs.items()}
        self.assertTrue(self.judge())

    def test_a_finding_the_base_does_not_have_blocks(self):
        # One more missing translation prints no error line; it is still the head's own.
        self.gh.logs[1] = l10n_log(103765, f"{XCSTRINGS}:sidebar.doc.move: missing uk",
                                   f"{XCSTRINGS}:sidebar.doc.rename: missing uk")
        with self.assertRaisesRegex(excuse.Refused, "findings not on feat-cmux-next.*sidebar.doc.rename"):
            self.judge()

    def test_digits_inside_a_name_are_not_masked(self):
        self.gh.logs[1] = l10n_log(103765, f"{XCSTRINGS}:onboarding.step2.title: missing uk")
        self.gh.logs[2] = l10n_log(611, f"{XCSTRINGS}:onboarding.step1.title: missing uk")
        with self.assertRaisesRegex(excuse.Refused, "onboarding.step2.title"):
            self.judge()
        # Every digit after a letter, not just the first: item11 is not the base's item10.
        self.gh.logs[1] = l10n_log(103765, f"{XCSTRINGS}:foo.item11: missing uk")
        self.gh.logs[2] = l10n_log(611, f"{XCSTRINGS}:foo.item10: missing uk")
        with self.assertRaisesRegex(excuse.Refused, "foo.item11"):
            self.judge()

    def test_one_more_copy_of_a_base_finding_blocks(self):
        # A second blocking call in the same file prints the same line once more.
        call = "concurrency: Sources/Home/HomeHostView.swift:159: synchronous NSWorkspace open"
        self.gh.logs[1] = l10n_log(1, call, call.replace("159", "201"))
        self.gh.logs[2] = l10n_log(1, call)
        with self.assertRaisesRegex(excuse.Refused, "HomeHostView"):
            self.judge()

    def test_output_cut_short_blocks(self):
        # check-l10n.sh prints 200 errors and then "... N more": what it hid can't be compared.
        self.gh.logs[1] = l10n_log(1, f"{XCSTRINGS}:sidebar.doc.move: missing uk", "... 12 more")
        self.gh.logs[2] = l10n_log(1, f"{XCSTRINGS}:sidebar.doc.move: missing uk", "... 40 more")
        with self.assertRaisesRegex(excuse.Refused, "cut short"):
            self.judge()

    def test_a_red_step_that_printed_no_finding_blocks(self):
        self.gh.logs[1] = log(CHECKS, L10N, "##[group]Run x", "##[endgroup]",
                              "##[error]Process completed with exit code 1.")
        with self.assertRaisesRegex(excuse.Refused, "printed nothing"):
            self.judge()

    def test_a_head_log_without_step_names_compares_only_its_red_steps(self):
        # GitHub served the head's log with every line under UNKNOWN STEP (#22200, 2026-10-20):
        # the runner banner, a green step and the post-job cleanup are no step's findings.
        unnamed = "\n".join(
            [f"{CHECKS}\tUNKNOWN STEP\t2026-10-07T02:10:37.8032610Z {line}" for line in (
                "Runner name: 'blacksmith-4vcpu-ubuntu-2404-2dlrqe74lxhfk4or'",
                "##[group]Run actions/checkout@de0fac2e", "##[endgroup]",
                " * [new tag]             xcframework-ios-v5 -> xcframework-ios-v5",
                "##[group]Run python3 scripts/cmux-next/check-god-files.py", "##[endgroup]",
                "check-god-files: ok")]
            + [line.replace(f"\t{L10N}\t", "\tUNKNOWN STEP\t") for line in self.gh.logs[1].splitlines()]
            + [f"{CHECKS}\tUNKNOWN STEP\t2026-10-07T02:10:37.8032610Z {line}" for line in (
                "Post job cleanup.", "[command]/usr/local/bin/git version")])
        self.gh.jobs[1]["steps"] = [
            {"name": name, "status": "completed", "conclusion": conclusion} for name, conclusion in (
                ("Set up job", "success"), ("Run actions/checkout@de0fac2e", "success"),
                ("God files and types (Swift)", "success"), (L10N, "failure"),
                ("Post Run actions/checkout@de0fac2e", "success"), ("Complete job", "success"))]
        self.gh.logs[1] = unnamed
        text = "\n".join(self.judge())
        self.assertIn("sidebar.doc.move: missing uk", text)
        # Its own finding still blocks.
        self.gh.logs[1] = unnamed.replace("missing uk", "missing uk\n" + (
            f"{CHECKS}\tUNKNOWN STEP\t2026-10-07T02:10:37.8032610Z {XCSTRINGS}:sidebar.doc.rename: missing uk"), 1)
        with self.assertRaisesRegex(excuse.Refused, "sidebar.doc.rename"):
            self.judge()
        # A nested `Run` group (a composite action's step) could split a red step's findings from
        # its error: the blocks no longer match the steps, so it refuses rather than guess.
        self.gh.logs[1] = unnamed.replace("##[group]Run python3 scripts/cmux-next/check-god-files.py",
                                          "##[group]Run python3 scripts/cmux-next/check-god-files.py\n" + (
            f"{CHECKS}\tUNKNOWN STEP\t2026-10-07T02:10:37.8032610Z ##[group]Run inner"), 1)
        with self.assertRaisesRegex(excuse.Refused, "cannot be told apart"):
            self.judge()

    def test_a_lint_check_green_on_the_base_blocks(self):
        self.gh.jobs[2]["conclusion"] = "success"
        with self.assertRaisesRegex(excuse.Refused, "not red on feat-cmux-next"):
            self.judge()


LINTS = ("God files and types (Swift)", "Main-thread concurrency", "Type scale", "Web bundle key inputs")
AGGREGATE_STEP = "Fail on any red check"
TIP, TIP_1, TIP_2 = "1" * 40, "2" * 40, "3" * 40
MERGE_BASE = "4" * 40


def lint_job(job_id, run_id, sha, red=("Main-thread concurrency", "Type scale"), name=CHECKS):
    """The cmux-next checks job: each lint is a continue-on-error step; only the last step fails."""
    steps = [{"name": "Set up runner", "status": "completed", "conclusion": "success"}]
    steps += [{"name": lint, "status": "completed", "conclusion": "success"} for lint in LINTS]
    steps.append({"name": AGGREGATE_STEP, "status": "completed", "conclusion": "failure"})
    return {"id": job_id, "run_id": run_id, "head_sha": sha, "name": name, "status": "completed",
            "conclusion": "failure", "html_url": f"https://github.com/{REPO}/actions/runs/{run_id}/job/{job_id}",
            "steps": steps}


def lint_log(red=("Main-thread concurrency", "Type scale"), extra=()):
    lines = [f"{CHECKS}\t{lint}\t2026-10-19T19:31:23.4759936Z ##[error]Process completed with exit code 1."
             for lint in red]
    lines += [f"{CHECKS}\t{lint}\t2026-10-19T19:31:23.4759936Z {line}" for lint, line in extra]
    lines += [f"{CHECKS}\t{AGGREGATE_STEP}\t2026-10-19T19:35:08.4265507Z - {lint} (failure)" for lint in red]
    lines.append(f"{CHECKS}\t{AGGREGATE_STEP}\t2026-10-19T19:35:08.4268790Z ##[error]Process completed with exit code 1.")
    return "\n".join(lines)


def check_run(job, name=None):
    return {"id": job["id"], "name": name or job["name"], "status": "completed", "conclusion": job["conclusion"],
            "app": {"slug": "github-actions"},
            "details_url": f"https://github.com/{REPO}/actions/runs/{job['run_id']}/job/{job['id']}"}


class BaseCommitEvidence(unittest.TestCase):
    """2026-10-19: #21729 and #21807 were refused over "no base verdict" for reds feat-cmux-next had too.
    The base tip, the merge-base and a few commits before each are read before giving up, and a
    missing verdict names everything that was compared."""

    def setUp(self):
        self.gh = FakeGitHub()
        self.gh.jobs = {1: lint_job(1, 10, HEAD)}
        self.gh.logs = {1: lint_log()}
        self.gh.base_runs = []
        self.gh.history = {"feat-cmux-next": [TIP, TIP_1, TIP_2], MERGE_BASE: [MERGE_BASE]}

    def judge(self, **kwargs):
        return excuse.judge(REPO, "feat-cmux-next", HEAD, [10], self.gh, **kwargs)

    def base_lint(self, job_id, commit, run_id=40, **kwargs):
        job = lint_job(job_id, run_id, commit, **kwargs)
        self.gh.jobs[job_id] = job
        self.gh.logs[job_id] = lint_log(**{k: v for k, v in kwargs.items() if k == "red"})
        self.gh.commit_checks.setdefault(commit, []).append(check_run(job))
        return job

    def test_a_lint_red_on_the_base_tip_is_excused_naming_the_tip(self):
        self.base_lint(2, TIP, red=("Main-thread concurrency", "Type scale", "Web bundle key inputs"))
        text = "\n".join(self.judge())
        self.assertIn(f"excused '{CHECKS}'", text)
        self.assertIn(f"base tip {TIP[:10]}", text)
        self.assertIn("/job/2", text)

    def test_a_new_red_lint_step_the_base_does_not_have_is_refused(self):
        self.gh.logs[1] = lint_log(red=("Main-thread concurrency", "God files and types (Swift)"))
        self.base_lint(2, TIP)
        with self.assertRaisesRegex(excuse.Refused, r"God files and types \(Swift\)") as caught:
            self.judge()
        self.assertIn(HEAD[:10], str(caught.exception))
        self.assertIn(TIP[:10], str(caught.exception))

    def test_a_missing_tip_verdict_looks_back_a_few_base_commits(self):
        self.base_lint(2, TIP_2)
        text = "\n".join(self.judge())
        self.assertIn(f"base tip~2 {TIP_2[:10]}", text)

    def test_the_lookback_is_bounded(self):
        self.gh.history["feat-cmux-next"] = [TIP] + [f"{i:040d}" for i in range(1, 9)]
        self.base_lint(2, f"{7:040d}")
        with self.assertRaisesRegex(excuse.Refused, "no feat-cmux-next verdict"):
            self.judge(lookback=3)

    def test_a_red_at_the_merge_base_is_excused_when_the_tip_has_no_verdict(self):
        self.gh.merge_base = MERGE_BASE
        self.base_lint(2, MERGE_BASE)
        text = "\n".join(self.judge())
        self.assertIn(f"merge-base {MERGE_BASE[:10]}", text)

    def test_a_green_tip_and_no_red_elsewhere_refuses_naming_the_green_job(self):
        job = lint_job(2, 40, TIP)
        job["conclusion"] = "success"
        job["steps"][-1]["conclusion"] = "success"
        self.gh.jobs[2] = job
        self.gh.logs[2] = ""
        self.gh.commit_checks[TIP] = [check_run(job)]
        with self.assertRaisesRegex(excuse.Refused, f"green on base tip {TIP[:10]}"):
            self.judge()

    def test_a_matrix_suffix_difference_still_matches(self):
        # #21807: `web / react-apps-check (1)` on the pull request; the base push runs one leg unsuffixed.
        self.gh.jobs[1] = dict(failed_job(1, 10, HEAD), name="web / react-apps-check (1)")
        base = dict(failed_job(2, 40, TIP), name="web / react-apps-check")
        self.gh.jobs[2] = base
        self.gh.commit_checks[TIP] = [check_run(base)]
        self.gh.logs[1] = log("web / react-apps-check (1)", TEST_STEP, ISSUE)
        self.gh.logs[2] = log("web / react-apps-check", TEST_STEP, ISSUE)
        text = "\n".join(self.judge())
        self.assertIn("matched without its matrix suffix", text)

    def test_a_caller_prefix_difference_still_matches(self):
        self.gh.jobs[1] = dict(failed_job(1, 10, HEAD), name="web / react-apps-check")
        base = dict(failed_job(2, 40, TIP), name="react-apps-check")
        self.gh.jobs[2] = base
        self.gh.commit_checks[TIP] = [check_run(base)]
        self.gh.logs[1] = log("web / react-apps-check", TEST_STEP, ISSUE)
        self.gh.logs[2] = log("react-apps-check", TEST_STEP, ISSUE)
        text = "\n".join(self.judge())
        self.assertIn("matched without its caller prefix", text)

    def test_no_base_verdict_names_the_job_the_sha_and_everything_compared(self):
        # #21729: the checks job never runs on feat-cmux-next pushes, so no base run has it.
        self.gh.merge_base = MERGE_BASE
        with self.assertRaises(excuse.Refused) as caught:
            self.judge()
        message = str(caught.exception)
        for expected in (CHECKS, HEAD[:10], "no feat-cmux-next verdict", f"base tip ({TIP[:10]}",
                         f"merge-base ({MERGE_BASE[:10]}", "no completed feat-cmux-next run of its workflow",
                         "gh workflow run"):
            self.assertIn(expected, message)


RAC = "web / react-apps-check"
SHARD_STEP = "Run webview tests"
TABLE = "(fail) markdown table keys > Cmd-A selects the cell's text, then the whole table [18.20ms]"
LAYERS = "(fail) check-layers > this checkout passes with its baseline [537.18ms]"


def shard_job(job_id, run_id, sha, shard, conclusion="failure"):
    job = dict(failed_job(job_id, run_id, sha, name=f"{RAC} ({shard})", step=SHARD_STEP),
               html_url=f"https://github.com/{REPO}/actions/runs/{run_id}/job/{job_id}")
    if conclusion != "failure":
        job["conclusion"] = conclusion
        job["steps"][-1]["conclusion"] = conclusion
    return job


def status_job(job_id, run_id, sha, name, *reported):
    """A status job: its one failed step prints `<job id>: failure` for each red job it needs."""
    job = {"id": job_id, "run_id": run_id, "head_sha": sha, "name": name, "status": "completed",
           "conclusion": "failure", "html_url": f"https://github.com/{REPO}/actions/runs/{run_id}/job/{job_id}",
           "steps": [{"name": "Set up job", "status": "completed", "conclusion": "success"},
                     {"name": "Check routed web jobs", "status": "completed", "conclusion": "failure"}]}
    lines = ["##[group]Run python3 - <<'PY'", "import json", "##[endgroup]"]
    lines += [f"{reported_job}: failure" for reported_job in reported]
    lines.append("##[error]Process completed with exit code 1.")
    return job, log(name, "Check routed web jobs", *lines)


class ShardsAndStatusJobs(unittest.TestCase):
    """2026-10-20: #22097 was refused for reds feat-cmux-next had too. The web jobs run in
    ci.yml on a pull request and in cmux-next web on a push, react-apps-check only when the
    push touches webviews (so the base tip's is skipped), its twelve shards place a test
    differently each run, and `web / Web status` prints nothing but `<job>: failure`."""

    def setUp(self):
        self.gh = FakeGitHub()
        self.gh.jobs = {1: shard_job(1, 10, HEAD, 1)}
        self.gh.logs = {1: log(f"{RAC} (1)", SHARD_STEP, TABLE, "##[error]Process completed with exit code 1.")}
        self.gh.base_runs = []
        self.gh.history = {"feat-cmux-next": [TIP, TIP_1, TIP_2]}

    def judge(self, runs=(10,), **kwargs):
        return excuse.judge(REPO, "feat-cmux-next", HEAD, list(runs), self.gh, **kwargs)

    def base_shards(self, run_id, sha, red_shard=4, lines=(TABLE,), shards=4, checks=True):
        """A base run of every shard; only `red_shard` fails, printing `lines`."""
        for shard in range(1, shards + 1):
            job_id = run_id * 100 + shard
            red = shard == red_shard
            self.gh.jobs[job_id] = shard_job(job_id, run_id, sha, shard, "failure" if red else "success")
            self.gh.logs[job_id] = log(f"{RAC} ({shard})", SHARD_STEP, *(lines if red else ("12 pass",)))
            if checks:
                self.gh.commit_checks.setdefault(sha, []).append(check_run(self.gh.jobs[job_id]))

    def test_bun_test_failures_are_failing_test_names_without_their_duration(self):
        job = shard_job(9, 1, HEAD, 1)
        _, tests, _ = excuse.signature(job, log(f"{RAC} (1)", SHARD_STEP, TABLE, LAYERS))
        self.assertEqual(tests, {"markdown table keys > Cmd-A selects the cell's text, then the whole table",
                                 "check-layers > this checkout passes with its baseline"})

    def test_a_red_test_in_another_shard_on_the_base_is_excused(self):
        self.base_shards(40, TIP, red_shard=4, lines=(TABLE.replace("18.20ms", "25.71ms"),))
        text = "\n".join(self.judge())
        self.assertIn(f"excused '{RAC} (1)'", text)
        self.assertIn("every shard", text)
        self.assertIn(f"base tip {TIP[:10]}", text)

    def test_red_tests_spread_over_several_base_shards_are_pooled(self):
        self.gh.logs[1] = log(f"{RAC} (1)", SHARD_STEP, TABLE, LAYERS)
        self.base_shards(40, TIP, red_shard=2, lines=(LAYERS,))
        self.gh.jobs[4003] = shard_job(4003, 40, TIP, 3)
        self.gh.logs[4003] = log(f"{RAC} (3)", SHARD_STEP, TABLE)
        self.gh.commit_checks[TIP] = [check for check in self.gh.commit_checks[TIP] if check["id"] != 4003]
        self.gh.commit_checks[TIP].append(check_run(self.gh.jobs[4003]))
        text = "\n".join(self.judge())
        self.assertIn("2 failed shards", text)

    def test_a_red_test_no_base_shard_has_is_refused(self):
        self.base_shards(40, TIP, red_shard=4, lines=(LAYERS,))
        with self.assertRaisesRegex(excuse.Refused, "markdown table keys"):
            self.judge()

    def test_every_base_shard_green_is_refused(self):
        self.base_shards(40, TIP, red_shard=0)
        with self.assertRaisesRegex(excuse.Refused, f"green on base tip {TIP[:10]}"):
            self.judge()

    def skipped_on_the_tip(self, run_id=50, workflow=9):
        """The base tip's push ran the web jobs in workflow 9 and skipped react-apps-check."""
        for job_id, name in ((5001, f"{RAC} (${{{{ matrix.shard }}}})"), (5002, RAC)):
            self.gh.jobs[job_id] = {"id": job_id, "run_id": run_id, "head_sha": TIP, "name": name,
                                    "status": "completed", "conclusion": "skipped", "steps": []}
            self.gh.commit_checks.setdefault(TIP, []).append(check_run(self.gh.jobs[job_id]))
        self.gh.run_workflows[run_id] = workflow

    def test_the_newest_base_run_that_ran_a_path_filtered_job_decides(self):
        self.skipped_on_the_tip()
        # Run 51 (the tip's push) skipped it; run 52, an older push that touched webviews, ran it.
        self.gh.other_runs[9] = [{"id": 51, "event": "push", "conclusion": "success"},
                                 {"id": 52, "event": "push", "conclusion": "failure"}]
        self.gh.jobs[5101] = dict(self.gh.jobs[5001], id=5101, run_id=51)
        self.base_shards(52, "9" * 40, red_shard=3, checks=False)
        text = "\n".join(self.judge())
        self.assertIn(f"excused '{RAC} (1)'", text)
        self.assertIn("feat-cmux-next run 52", text)

    def test_a_path_filtered_job_green_on_the_newest_base_run_that_ran_it_is_refused(self):
        self.skipped_on_the_tip()
        self.gh.other_runs[9] = [{"id": 52, "event": "push", "conclusion": "success"},
                                 {"id": 53, "event": "push", "conclusion": "failure"}]
        self.base_shards(52, "9" * 40, red_shard=0, checks=False)
        self.base_shards(53, "8" * 40, red_shard=3, checks=False)
        with self.assertRaisesRegex(excuse.Refused, "is not red on feat-cmux-next run 52"):
            self.judge()

    def test_without_the_base_tip_naming_its_workflow_there_is_no_verdict(self):
        self.gh.other_runs[9] = [{"id": 52, "event": "push", "conclusion": "failure"}]
        self.base_shards(52, "9" * 40, red_shard=3, checks=False)
        with self.assertRaisesRegex(excuse.Refused, "no feat-cmux-next verdict"):
            self.judge()

    def add_status_jobs(self):
        aggregate, aggregate_log = status_job(2, 10, HEAD, RAC, "react-apps-check-shard")
        status, status_log = status_job(3, 10, HEAD, "web / Web status", "react-apps-check")
        self.gh.jobs.update({2: aggregate, 3: status})
        self.gh.logs.update({2: aggregate_log, 3: status_log})

    def test_status_jobs_are_excused_when_the_jobs_under_them_are(self):
        self.add_status_jobs()
        self.base_shards(40, TIP)
        text = "\n".join(self.judge())
        self.assertIn(f"excused '{RAC} (1)'", text)
        self.assertIn("excused 'web / Web status': it only reports react-apps-check red", text)
        self.assertIn(f"excused '{RAC}': it only reports react-apps-check-shard red", text)

    def test_a_red_status_check_brings_in_the_failed_jobs_of_its_run(self):
        self.add_status_jobs()
        self.base_shards(40, TIP)
        self.gh.commit_checks[HEAD] = [check_run(self.gh.jobs[3])]
        text = "\n".join(self.judge(runs=(), checks=["web / Web status"]))
        self.assertIn(f"excused '{RAC} (1)'", text)
        self.gh.logs[1] = log(f"{RAC} (1)", SHARD_STEP, LAYERS)
        with self.assertRaisesRegex(excuse.Refused, "check-layers"):
            self.judge(runs=(), checks=["web / Web status"])

    def test_a_status_job_with_no_failed_job_under_it_is_refused(self):
        self.add_status_jobs()
        del self.gh.jobs[1]
        with self.assertRaisesRegex(excuse.Refused, "prints react-apps-check-shard: failure, which names no failed job"):
            self.judge()
        # Two status jobs naming only each other.
        self.gh.jobs[2], self.gh.logs[2] = status_job(2, 10, HEAD, RAC, "web-status")
        with self.assertRaisesRegex(excuse.Refused, "every failed job of its run is a status job"):
            self.judge()
        del self.gh.jobs[3]
        with self.assertRaisesRegex(excuse.Refused, "has no failed job under web / to compare"):
            self.judge()

    def test_status_lines_name_failed_jobs_of_the_run(self):
        _, status_log = status_job(2, 10, HEAD, RAC, "react-apps-check-shard")
        self.assertEqual(excuse.reported_red(status_log), ["react-apps-check-shard"])
        # Inside the echo of its script, or a cancelled job, is not a report of a red job.
        echoed = log(RAC, "Check routed web jobs", "##[group]Run x", "web-tests: failure", "##[endgroup]",
                     "react-apps-check-shard: cancelled")
        self.assertEqual(excuse.reported_red(echoed), [])
        under = [shard_job(1, 10, HEAD, 1), dict(shard_job(4, 10, HEAD, 1), name="web / Web tests (2/4)")]
        unnamed = lambda reported, jobs, prefixed=True: [  # noqa: E731
            job_id for job_id, found in excuse.report_matches(reported, jobs, prefixed).items() if not found]
        self.assertEqual(unnamed(["react-apps-check-shard", "web-tests", "react-apps-check"], under), [])
        self.assertEqual(unnamed(["migrations", "web-tests-e2e", "web"], under), ["migrations", "web-tests-e2e", "web"])
        # Only a status job without a caller prefix names a caller's jobs by the caller.
        self.assertEqual(unnamed(["web"], under, prefixed=False), [])

    def test_gh_run_view_filing_every_line_under_unknown_step_still_finds_a_status_job(self):
        # #22097's `web / react-apps-check` job 118426578476: the runner banner and the step's
        # output all came back under UNKNOWN STEP.
        self.add_status_jobs()
        self.gh.logs[2] = log(RAC, "UNKNOWN STEP", "Current runner version: '2.329.0'",
                              "Runner name: 'blacksmith-4vcpu-ubuntu-2404-3l7m7a67dykrgcxk'",
                              "##[group]Run python3 - <<'PY'", '    "result": "failure",', "##[endgroup]",
                              "react-apps-check-shard: failure", "##[error]Process completed with exit code 1.",
                              "Cleaning up orphan processes")
        self.base_shards(40, TIP)
        self.assertIn(f"excused '{RAC}': it only reports react-apps-check-shard red", "\n".join(self.judge()))

    def test_a_job_summing_up_its_own_failure_is_compared_not_excused_as_a_status_job(self):
        # Review of #22140: a migrations job ending in `migrations: failure` beside a base-red shard.
        self.gh.jobs[2] = dict(failed_job(2, 10, HEAD, name="web / web-db-migrations"),
                               html_url=f"https://github.com/{REPO}/actions/runs/10/job/2")
        self.gh.logs[2] = log("web / web-db-migrations", TEST_STEP, "##[group]Run migrate", "##[endgroup]",
                              'ERROR relation "x" already exists', "migrations: failure")
        self.base_shards(40, TIP)
        with self.assertRaisesRegex(excuse.Refused, "prints migrations: failure, which names no failed job"):
            self.judge()

    def test_a_bun_test_file_that_died_loading_is_a_failure_of_its_own(self):
        # Review of #22140: an unhandled error prints no `(fail)` line beside a base-red test.
        self.gh.logs[1] = log(f"{RAC} (1)", SHARD_STEP, "FAIL test/markdown-table-keys.test.ts", TABLE,
                              "FAIL test/new-thing.test.ts", "# Unhandled error between tests",
                              "error: Cannot find module './NewThing'")
        self.base_shards(40, TIP, lines=("FAIL test/markdown-table-keys.test.ts", TABLE))
        with self.assertRaisesRegex(excuse.Refused, "test/new-thing.test.ts"):
            self.judge()
        self.gh.logs[1] = log(f"{RAC} (1)", SHARD_STEP, "FAIL test/markdown-table-keys.test.ts (limit 120s)", TABLE)
        self.assertTrue(self.judge())

    def test_two_legs_each_ending_in_a_status_line_naming_the_other_are_refused(self):
        # Re-review of #22140: `web / migrations (pg15)` and `(pg16)` each print `migrations: failure`.
        self.base_shards(40, TIP)
        for job_id, leg in ((2, "pg15"), (3, "pg16")):
            name = f"web / migrations ({leg})"
            self.gh.jobs[job_id] = dict(failed_job(job_id, 10, HEAD, name=name),
                                        html_url=f"https://github.com/{REPO}/actions/runs/10/job/{job_id}")
            self.gh.logs[job_id] = log(name, TEST_STEP, 'ERROR relation "x" already exists', "migrations: failure")
        with self.assertRaisesRegex(excuse.Refused, "every failed job of its run is a status job"):
            self.judge()

    def test_bun_s_error_outside_any_test_is_a_failure_of_its_own(self):
        # Re-review of #22140: a file the base fails a test in dies loading on the head.
        self.gh.logs[1] = log(f"{RAC} (1)", SHARD_STEP, "FAIL test/markdown-table-keys.test.ts",
                              "# Unhandled error between tests", "SyntaxError: Unexpected token")
        self.base_shards(40, TIP, lines=("FAIL test/markdown-table-keys.test.ts", TABLE))
        with self.assertRaisesRegex(excuse.Refused, "Unhandled error between tests"):
            self.judge()

    def test_a_green_merge_base_does_not_stop_the_search_for_the_tip_s_skipped_job(self):
        # Re-review of #22140: only the base tip line's verdict outranks the base-run search.
        self.gh.merge_base = MERGE_BASE
        self.gh.history[MERGE_BASE] = [MERGE_BASE]
        self.base_shards(45, MERGE_BASE, red_shard=0)
        self.skipped_on_the_tip()
        self.gh.other_runs[9] = [{"id": 52, "event": "push", "conclusion": "failure"}]
        self.base_shards(52, "9" * 40, red_shard=3, checks=False)
        self.assertIn("feat-cmux-next run 52", "\n".join(self.judge()))

    def test_a_green_base_tip_is_not_overruled_by_an_older_red_base_run(self):
        # Review of #22140: a dispatched base run stays the newest run long after the base is fixed.
        self.base_shards(40, TIP, red_shard=0)
        self.gh.base_runs = [{"id": 20, "event": "workflow_dispatch", "conclusion": "failure"}]
        self.base_shards(20, "7" * 40, red_shard=2, checks=False)
        with self.assertRaisesRegex(excuse.Refused, f"green on base tip {TIP[:10]}") as caught:
            self.judge()
        self.assertNotIn("run 20", str(caught.exception))


class SkippedRunsOnABaseCommit(unittest.TestCase):
    """2026-10-24: base commit e8697614 ran the checks job twice: push run 40146316318 failed it and
    a later workflow_dispatch DEV run skipped it. The newer, skipped check hid the red."""

    def setUp(self):
        self.gh = FakeGitHub()
        self.gh.jobs = {1: lint_job(1, 10, HEAD)}
        self.gh.logs = {1: lint_log()}
        self.gh.base_runs = []
        self.gh.history = {"feat-cmux-next": [TIP, TIP_1]}

    def test_a_newer_skipped_run_of_the_job_does_not_hide_the_red(self):
        red = lint_job(2, 40, TIP)
        skipped = dict(lint_job(3, 41, TIP), conclusion="skipped")
        self.gh.jobs.update({2: red, 3: skipped})
        self.gh.logs[2] = lint_log()
        self.gh.commit_checks[TIP] = [check_run(red), check_run(skipped)]
        text = "\n".join(excuse.judge(REPO, "feat-cmux-next", HEAD, [10], self.gh))
        self.assertIn(f"base tip {TIP[:10]}", text)
        self.assertIn("/job/2", text)

    def test_the_newest_verdict_still_wins_over_an_older_one(self):
        red = lint_job(2, 40, TIP)
        green = dict(lint_job(3, 41, TIP), conclusion="success")
        green["steps"] = [dict(step, conclusion="success") for step in green["steps"]]
        self.gh.jobs.update({2: red, 3: green})
        self.gh.logs.update({2: lint_log(), 3: ""})
        self.gh.commit_checks[TIP] = [check_run(red), check_run(green)]
        with self.assertRaisesRegex(excuse.Refused, f"green on base tip {TIP[:10]}"):
            excuse.judge(REPO, "feat-cmux-next", HEAD, [10], self.gh)


class AssertionNoise(unittest.TestCase):
    """2026-10-24: the checks job's script tests print a mkdtemp folder and a Python set of every
    package folder; both differ run to run, and refused #24997 for a red the base had."""

    def test_a_temporary_folder_name_and_a_string_set_are_masked(self):
        job = failed_job(1, 10, HEAD, name=CHECKS, step=L10N)
        head = excuse.printed(job, l10n_log(1, "grep: /tmp/cmux-prepush-foe40iki/head/x: No such file",
                                            "AssertionError: 'Tests/A' not found in {'Sources/B', 'Sources/C'}"))
        base = excuse.printed(job, l10n_log(1, "grep: /tmp/cmux-prepush-1awnk_q2/head/x: No such file",
                                            "AssertionError: 'Tests/A' not found in {'Sources/D', 'Sources/B'}"))
        self.assertEqual(head, base)
        # What the assertion says is missing is still compared.
        other = excuse.printed(job, l10n_log(1, "AssertionError: 'Tests/E' not found in {'Sources/B'}"))
        self.assertNotIn("AssertionError: 'Tests/A' not found in {…}", other)
        # Only the set an assertion says something is missing from: a lint finding's set is compared.
        self.assertNotEqual(excuse.printed(job, l10n_log(1, "violations: {'new.swift'}")),
                            excuse.printed(job, l10n_log(1, "violations: {'old.swift'}")))


class LogOfARunStillGoing(unittest.TestCase):
    """gh serves no run log until the whole run completes; a finished job's own log is read instead."""

    class Recorder(excuse._evidence.GitHub):
        def __init__(self, failures):
            self.calls, self.failures = [], failures

        def run(self, args):
            self.calls.append(args)
            for marker, message in self.failures:
                if marker in args:
                    raise excuse.Refused("GitHub evidence request failed: " + message)
            return "2026-10-24T00:00:00.0000000Z hello\n"

    JOB = {"id": 5, "run_id": 9, "name": "job"}

    def test_a_job_whose_run_is_still_going_is_read_from_its_raw_log(self):
        gh = self.Recorder([("--log", "run 9 is still in progress; logs will be available when it is complete")])
        self.assertIn("job\tUNKNOWN STEP\t2026-10-24T00:00:00.0000000Z hello", gh.log(REPO, self.JOB))
        self.assertEqual(gh.calls[-1], ["api", f"repos/{REPO}/actions/jobs/5/logs", "--allow-escape-sequences"])

    def test_an_older_gh_without_the_escape_flag_is_asked_without_it(self):
        gh = self.Recorder([("--log", "run 9 is still in progress"),
                            ("--allow-escape-sequences", "unknown flag: --allow-escape-sequences")])
        self.assertIn("hello", gh.log(REPO, self.JOB))
        self.assertEqual(gh.calls[-1], ["api", f"repos/{REPO}/actions/jobs/5/logs"])

    def test_any_other_failure_still_refuses(self):
        gh = self.Recorder([("--log", "HTTP 404: Not Found")])
        with self.assertRaisesRegex(excuse.Refused, "404"):
            gh.log(REPO, self.JOB)


class LargeEvidenceOutput(unittest.TestCase):
    """Swift test logs can exceed the old 32 MiB evidence cap."""

    def test_swift_sized_log_is_retained_for_classification(self):
        payload = "x" * (40 * 1024 * 1024)

        class Process:
            returncode = 0

            def __init__(self, stdout, stderr):
                stdout.write(payload.encode())
                stderr.write(b"")

            def wait(self, timeout=None):
                return 0

        class Popen:
            def __new__(cls, args, stdout, stderr):
                return Process(stdout, stderr)

        with unittest.mock.patch.object(excuse._evidence.subprocess, "Popen", Popen):
            output = excuse._evidence.GitHub().run(["api", "evidence"])
        self.assertEqual(len(output), len(payload))


WEB = "cmux-next web bundles (source-keyed cache)"
WEB_STEP = "Build web bundles"
CSS_ERROR = ("error: the agent pane imports webviews/src/summary/WorkflowCard.css but build-agent-pane-web.ts "
             "does not add it to the page's styles")
PR_NUMBER = 24997


class OutsideTheDiff(unittest.TestCase):
    """A red whose failed steps name only files the pull request does not change, on a job the base had
    red, is not the pull request's even when the base prints it differently or has fixed it since."""

    def setUp(self):
        self.gh = FakeGitHub()
        self.gh.base_runs = []
        self.gh.history = {"feat-cmux-next": [TIP]}
        self.gh.jobs = {1: failed_job(1, 10, HEAD, name=WEB, step=WEB_STEP),
                        2: failed_job(2, 40, TIP, name=WEB, step=WEB_STEP)}
        self.gh.logs = {1: self.web_log(CSS_ERROR),
                        2: self.web_log("error: the agent pane imports webviews/src/Other.css but nothing adds it")}
        self.gh.commit_checks[TIP] = [check_run(self.gh.jobs[2])]
        self.files = [{"filename": "Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/AgentPaneView+Transport.swift"}]
        original = self.gh.json

        def json(route, *, paginate=False):
            if route.endswith(f"/pulls/{PR_NUMBER}/files?per_page=100"):
                self.gh.routes.append(route)
                return [copy.deepcopy(self.files)]
            return original(route, paginate=paginate)

        self.gh.json = json

    @staticmethod
    def web_log(*lines):
        return log(WEB, WEB_STEP, "##[group]Run bash scripts/cmux-next/build-web-bundles.sh", "##[endgroup]",
                   *lines, "##[error]Process completed with exit code 1.")

    def judge(self, pr=PR_NUMBER):
        return excuse.judge(REPO, "feat-cmux-next", HEAD, [10], self.gh, pr=pr)

    def test_a_red_naming_only_files_the_pr_does_not_change_is_excused(self):
        text = "\n".join(self.judge())
        self.assertIn(f"only files #{PR_NUMBER} does not change", text)
        self.assertIn("WorkflowCard.css", text)
        self.assertIn(f"base tip {TIP[:10]}", text)
        # The file list is read once, only when the base comparison did not excuse.
        self.assertEqual(sum("/pulls/" in route for route in self.gh.routes), 1)

    def test_without_the_pull_request_the_base_comparison_alone_decides(self):
        with self.assertRaisesRegex(excuse.Refused, "errors not on base tip"):
            self.judge(pr=None)

    def test_a_named_file_a_bare_name_or_a_renamed_file_the_pr_changes_blocks(self):
        for changed in ({"filename": "webviews/src/summary/WorkflowCard.css"},
                        {"filename": "webviews/agent-pane/build-agent-pane-web.ts"},
                        {"filename": "webviews/src/summary/Card.css",
                         "previous_filename": "webviews/src/summary/WorkflowCard.css"}):
            self.files = [changed]
            with self.assertRaisesRegex(excuse.Refused, "which this pull request changes"):
                self.judge()

    def test_a_failing_test_is_never_pinned_to_files(self):
        for line in ("AssertionError: 'x' not found in Sources/A.swift", " FAIL  webviews/src/a.test.ts > renders",
                     "(fail) markdown table keys > webviews/src/table.ts [18.20ms]", ISSUE):
            self.gh.logs[1] = self.web_log(line)
            with self.assertRaisesRegex(excuse.Refused, "says a test failed"):
                self.judge()

    def test_an_error_or_a_red_step_naming_no_file_blocks(self):
        self.gh.logs[1] = self.web_log(CSS_ERROR, "##[error]error: the bundle key is stale")
        with self.assertRaisesRegex(excuse.Refused, "error naming no file"):
            self.judge()
        self.gh.logs[1] = self.web_log("3 findings")
        with self.assertRaisesRegex(excuse.Refused, "naming no file"):
            self.judge()

    def test_a_pr_changing_check_code_workflows_or_a_baseline_blocks(self):
        for path in ("scripts/cmux-next/no-swiftui-allowlist.txt", ".github/workflows/cmux-next.yml",
                     "Packages/macOS/CmuxNext/godfile-baseline.tsv"):
            self.files = [{"filename": path}]
            with self.assertRaisesRegex(excuse.Refused, "check code, a baseline or a build input"):
                self.judge()

    def test_a_job_no_base_commit_had_red_blocks(self):
        self.gh.jobs[2]["conclusion"] = "success"
        self.gh.commit_checks[TIP] = [check_run(self.gh.jobs[2])]
        with self.assertRaisesRegex(excuse.Refused, "no feat-cmux-next commit or run read has it red"):
            self.judge()

    def test_a_file_list_github_cut_short_blocks(self):
        self.files = [{"filename": f"f{index}.txt"} for index in range(excuse.MAX_PR_FILES)]
        with self.assertRaisesRegex(excuse.Refused, "which it changes is unknown"):
            self.judge()

    # Review of #25036 (Codex, gpt-6-astra): each of these excused a red the PR may have caused.
    def test_a_test_failure_inside_a_nested_group_still_blocks(self):
        self.gh.logs[1] = self.web_log(CSS_ERROR, "##[group]bun test webviews/src/a.test.ts: exit 1",
                                       "FAIL test/foo", "##[endgroup]")
        with self.assertRaisesRegex(excuse.Refused, "says a test failed"):
            self.judge()

    def test_error_and_test_lines_are_recognised_in_any_case(self):
        for lines in (("ERROR: compilation failed", "info: src/base.ts"),
                      ("Fatal: the bundle is stale", "info: src/base.ts"),
                      ("error: test Foo failed: src/base.ts",)):
            self.gh.logs[1] = self.web_log(*lines)
            with self.assertRaises(excuse.Refused):
                self.judge()

    def test_a_path_is_read_whole_and_a_host_name_is_no_file(self):
        self.assertEqual(excuse.file_paths("missing assets/Foo@2x.png in the bundle"), {"assets/Foo@2x.png"})
        self.assertEqual(excuse.file_paths("see docs.example.com or https://example.com/x"), set())
        self.assertEqual(excuse.file_paths("Sources/A.swift:12:5: error: x; build.sh"), {"Sources/A.swift", "build.sh"})
        self.gh.logs[1] = self.web_log("error: assets/Foo@2x.png is not in the asset catalog")
        self.files = [{"filename": "webviews/assets/Foo@2x.png"}]
        with self.assertRaisesRegex(excuse.Refused, "which this pull request changes"):
            self.judge()

    # Second review round of #25036.
    def test_plural_failures_and_errors_still_block(self):
        for line in ("2 test failures in webviews/src/old.css", "3 errors"):
            self.gh.logs[1] = self.web_log(line)
            with self.assertRaises(excuse.Refused):
                self.judge()

    def test_a_compile_error_saying_expected_is_still_pinned_to_its_file(self):
        self.gh.logs[1] = self.web_log("error: expected expression in webviews/src/Foo.ts")
        self.assertIn("Foo.ts", "\n".join(self.judge()))

    def test_a_quoted_name_with_a_space_is_matched_to_the_changed_file(self):
        self.gh.logs[1] = self.web_log("error: 'webviews/src/My File.ts' imports a missing module")
        self.files = [{"filename": "webviews/src/My File.ts"}]
        with self.assertRaisesRegex(excuse.Refused, "which this pull request changes"):
            self.judge()

    def test_paths_only_in_warnings_or_the_script_do_not_pin_a_red(self):
        self.gh.logs[1] = self.web_log("warning: webviews/src/Old.ts is deprecated", "3 findings")
        with self.assertRaisesRegex(excuse.Refused, "naming no file"):
            self.judge()

    def test_a_new_finding_inside_a_nested_group_is_compared_with_the_base(self):
        job = failed_job(1, 10, HEAD, name=CHECKS, step=L10N)
        nested = l10n_log(1, "##[group]check-x: 1 finding", f"{XCSTRINGS}:new.key: missing uk", "##[endgroup]")
        self.assertIn(f"{XCSTRINGS}:new.key: missing uk", excuse.printed(job, nested))

    # Third review round of #25036.
    def test_a_url_is_no_file(self):
        self.assertEqual(excuse.file_paths("fetching https://cdn.example.com/assets/Old.ts failed? no: "
                                           "'http://x.dev/a.css' www.example.com/b.js"), set())
        self.gh.logs[1] = self.web_log("error: could not load https://cdn.example.com/assets/Old.ts")
        with self.assertRaisesRegex(excuse.Refused, "error naming no file"):
            self.judge()

    def test_a_status_job_reporting_a_red_inside_a_nested_group_judges_it(self):
        text = log("web / Web status", "Check", "##[group]Run python3 - <<'PY'", "##[endgroup]",
                   "##[group]react-apps-check: failure", "details", "##[endgroup]", "web-lint: failure")
        self.assertEqual(excuse.reported_red(text), ["react-apps-check", "web-lint"])

    def test_only_source_files_outside_dot_folders_may_be_excused_by_files(self):
        for path in (".xcode-version", "biome.json", "web/.oxlintrc.json", "Makefile", "webviews/a.yaml",
                     "cmux-tui/rust-toolchain"):
            self.assertTrue(excuse.guarded(path), path)
        for path in ("webviews/src/A.tsx", "Packages/macOS/CmuxNext/Sources/A/B.swift", "cmux-tui/src/lib.rs"):
            self.assertFalse(excuse.guarded(path), path)

    # Fourth review round of #25036.
    def test_a_later_run_group_in_a_step_is_output(self):
        self.gh.logs[1] = self.web_log(CSS_ERROR, "##[group]Run inner/action@v1", "FAIL webviews/src/a.test.ts",
                                       "##[endgroup]")
        with self.assertRaisesRegex(excuse.Refused, "says a test failed"):
            self.judge()
        job = failed_job(1, 10, HEAD, name=CHECKS, step=L10N)
        nested = l10n_log(1, "##[group]Run inner/action@v1", f"{XCSTRINGS}:new.key: missing uk", "##[endgroup]")
        self.assertIn(f"{XCSTRINGS}:new.key: missing uk", excuse.printed(job, nested))

    def test_a_url_without_a_scheme_is_no_file(self):
        self.assertEqual(excuse.file_paths("docs.example.com/assets/Changed.ts //cdn.x.io/a.css "
                                           "WWW.Example.COM/b.js"), set())
        self.gh.logs[1] = self.web_log("error: cannot fetch docs.example.com/assets/Changed.ts")
        with self.assertRaisesRegex(excuse.Refused, "error naming no file"):
            self.judge()

    def test_an_uppercase_warning_never_pins_a_red(self):
        self.gh.logs[1] = self.web_log("WARNING: webviews/src/Old.ts is deprecated", "3 findings")
        with self.assertRaisesRegex(excuse.Refused, "naming no file"):
            self.judge()

    def test_a_go_or_rust_panic_is_a_test_failure(self):
        for line in ("panic: webviews/src/Old.ts", "thread 'main' panicked at src/lib.rs:3:5"):
            self.gh.logs[1] = self.web_log(line)
            with self.assertRaisesRegex(excuse.Refused, "says a test failed"):
                self.judge()

    # Fifth review round of #25036.
    def test_a_scheme_without_a_slash_and_a_host_port_are_no_file(self):
        self.assertEqual(excuse.file_paths("file:Old.ts localhost:3000/assets/Old.ts 127.0.0.1:8080/a.css"), set())
        # A file name with a line number is still a file.
        self.assertEqual(excuse.file_paths("build.sh:42: x; Sources/A.swift:12:5: y"), {"build.sh", "Sources/A.swift"})

    def test_a_file_named_like_test_language_is_not_a_test_failure(self):
        self.gh.logs[1] = self.web_log("error: cannot load webviews/src/panic.ts or webviews/src/assertions.ts")
        self.assertIn("panic.ts", "\n".join(self.judge()))

    def test_other_failed_test_wording_blocks(self):
        for line in ("Tests did not pass: webviews/src/Old.ts", "test run unsuccessful in webviews/src/Old.ts"):
            self.gh.logs[1] = self.web_log(line)
            with self.assertRaisesRegex(excuse.Refused, "says a test failed"):
                self.judge()

    # Sixth review round of #25036.
    def test_a_pr_changing_any_test_blocks(self):
        for path in ("cmuxTests/AppTests.swift", "cmuxUITests/LaunchTests.swift", "tests_v2/test_x.py",
                     "webviews/test/status.test.ts", "webviews/src/a.spec.tsx",
                     "Packages/macOS/CmuxNext/Tests/ATests/ATests.swift", "webviews/src/__mocks__/x.ts"):
            self.assertTrue(excuse.guarded(path), path)
            self.files = [{"filename": path}]
            with self.assertRaisesRegex(excuse.Refused, "a build input"):
                self.judge()

    def test_a_windows_path_is_matched_to_the_changed_file(self):
        self.assertEqual(excuse.file_paths(r"error: src\foo.rs:3:5: x"), {"src/foo.rs"})
        self.gh.logs[1] = self.web_log(r"error[E0425]: cannot find value in src\foo.rs:3:5")
        self.files = [{"filename": "cmux-tui/src/foo.rs"}]
        with self.assertRaisesRegex(excuse.Refused, "which this pull request changes"):
            self.judge()

    # Seventh review round of #25036.
    def test_build_scripts_and_cmake_descriptions_are_guarded(self):
        for path in ("cmux-tui/bindings/cpp/CMakeLists.txt", "cmux-tui/crates/cmux-tui-core/build.rs",
                     "cmux-tui/build-support/embed.rs"):
            self.assertTrue(excuse.guarded(path), path)

    def test_an_absolute_windows_path_is_a_file(self):
        self.assertEqual(excuse.file_paths(r"error: C:\a\cmux\src\foo.rs:3:5: x"), {"/a/cmux/src/foo.rs"})
        self.assertIsNotNone(excuse.touched("/a/cmux/src/foo.rs", {"src/foo.rs"}))

    def test_a_pr_changing_a_build_input_blocks(self):
        for path in ("web/vercel.json", "Dockerfile", "cmux-tui/scripts/requirements-windows-conpty.txt",
                     "webviews/package.json", "webviews/bun.lock", "Packages/macOS/CmuxNext/Package.swift",
                     "webviews/vite.config.ts", "webviews/tsconfig.app.json", "cmux-tui/Cargo.toml"):
            self.files = [{"filename": path}]
            with self.assertRaisesRegex(excuse.Refused, "a build input"):
                self.judge()

    def test_a_log_served_without_step_names_is_judged_by_its_red_blocks(self):
        # GitHub served the head's log under UNKNOWN STEP; the API's failed step (the summary) is no block.
        self.gh.jobs[1]["steps"] = [{"name": name, "status": "completed", "conclusion": conclusion}
                                    for name, conclusion in (("Set up job", "success"), ("No new SwiftUI", "success"),
                                                             (AGGREGATE_STEP, "failure"), ("Complete job", "success"))]
        self.gh.logs[1] = log(WEB, "UNKNOWN STEP", "##[group]Run scripts/cmux-next/check-no-swiftui.sh", "##[endgroup]",
                              "NO-SWIFTUI: Packages/macOS/CmuxNext/Sources/A/View.swift: imports SwiftUI",
                              "##[error]Process completed with exit code 1.",
                              "##[group]Run failed=()", "##[endgroup]", "##[error]red check: No new SwiftUI",
                              "##[error]Process completed with exit code 1.")
        self.assertIn("View.swift", "\n".join(self.judge()))

    def test_the_checks_jobs_summary_step_is_not_a_finding(self):
        self.gh.logs[1] = "\n".join([self.web_log(CSS_ERROR), log(
            WEB, AGGREGATE_STEP, "##[group]Run failed=()", "##[endgroup]",
            "##[error]red check: Web bundle key inputs", "- Web bundle key inputs (failure)",
            "##[error]Process completed with exit code 1.")])
        self.assertTrue(self.judge())


class Script(unittest.TestCase):
    def test_gh_merge_green_names_the_pull_request_to_the_base_comparison(self):
        text = (ROOT / "scripts/gh-merge-green").read_text()
        self.assertEqual(text.count('base_red_excuse.py" --repo "$repo" --base "$base" --sha "$sha" --pull "$num"'), 2)

    def test_gh_merge_green_asks_the_base_before_refusing_a_red_lane(self):
        text = (ROOT / "scripts/gh-merge-green").read_text()
        self.assertIn("base_red_excuse.py", text)
        # A red lint check the base has too is asked about; risk evidence is never waived.
        self.assertIn("--override cannot bypass risk evidence", text)
        self.assertIn('"${lint_reds[@]+"${lint_reds[@]}"}"', text)


if __name__ == "__main__":
    unittest.main()
