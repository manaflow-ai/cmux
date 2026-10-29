"""gh-merge-green excuses a red check only when the base branch's latest completed run has the same failures."""
import copy
import importlib.util
import json
import os
import subprocess
import tempfile
import unittest
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

    def json(self, route, *, paginate=False):
        self.routes.append(route)
        if "/actions/runs/" in route and route.endswith("/jobs?filter=latest&per_page=100"):
            run = int(route.split("/actions/runs/", 1)[1].split("/", 1)[0])
            return [{"jobs": [copy.deepcopy(job) for job in self.jobs.values() if job["run_id"] == run]}]
        if "/actions/workflows/7/runs?" in route:
            assert "branch=feat-cmux-next" in route and "status=completed" in route, route
            return {"workflow_runs": copy.deepcopy(self.base_runs)}
        if "/actions/runs/" in route:
            return {"id": int(route.rsplit("/", 1)[1]), "workflow_id": 7}
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

    def dev_daily_runs(self, count, first_id=1000):
        # A DEV daily dispatch of the same workflow: its swift-test job is skipped, so no verdict.
        for offset in range(count):
            run_id = first_id + offset
            self.gh.jobs[run_id] = dict(failed_job(run_id, run_id, BASE_SHA), conclusion="skipped", steps=[])
        return [{"id": first_id + offset, "event": "workflow_dispatch", "head_branch": "feat-cmux-next",
                 "status": "completed", "conclusion": "success"} for offset in range(count)]

    def test_the_tip_swift_suite_behind_a_burst_of_dev_daily_runs_is_the_base_verdict(self):
        # 2026-10-28: 16 of the base's 20 newest completed runs were DEV daily dispatches, the tip
        # suite run fell out of a 20-run window, and no Swift red on any PR could be compared.
        self.gh.base_runs = self.dev_daily_runs(30) + self.gh.base_runs
        text = "\n".join(self.judge())
        self.assertIn("run 20", text)
        lookup = next(route for route in self.gh.routes if "/actions/workflows/7/runs?" in route)
        self.assertIn(f"per_page={excuse.BASE_RUNS_PAGE}", lookup)

    def test_the_base_lookup_reaches_past_the_tip_suites_cadence(self):
        # The tip suite runs about once an hour (at most once per 25 minutes, tip_swift_suite_plan.js
        # MIN_GAP_MS), and DEV daily runs land about every 3 minutes between them: 20 runs an hour.
        # The job reads have to reach past more than one tip suite run, so one with no verdict (a
        # lost runner) still leaves the one before it.
        self.assertGreaterEqual(excuse.BASE_RUNS_PAGE, 100)
        self.assertGreaterEqual(excuse.BASE_JOB_READS, 2 * 20)

    def test_base_job_reads_are_bounded(self):
        self.gh.base_runs = self.dev_daily_runs(excuse.BASE_JOB_READS + 5) + self.gh.base_runs
        with self.assertRaisesRegex(excuse.Refused, "no completed"):
            self.judge()
        reads = [route for route in self.gh.routes if route.endswith("/jobs?filter=latest&per_page=100")
                 and "/runs/10/" not in route]
        self.assertEqual(len(reads), excuse.BASE_JOB_READS)

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

    def test_a_cut_short_run_blocks_with_no_crash(self):
        self.gh.logs[1] = log(SWIFT, TEST_STEP, ISSUE, "##[error]the summaries count 2 tests in total but 3 "
                              "started and 1 of those never finished; swift test exited 1")
        with self.assertRaisesRegex(excuse.Refused, "never finished"):
            self.judge()

    def test_a_non_test_job_that_died_on_a_signal_the_base_did_not_blocks(self):
        scheme = "cmux app scheme compile (Debug)"
        self.gh.jobs = {1: failed_job(1, 10, HEAD, scheme, "Build"), 2: failed_job(2, 20, BASE_SHA, scheme, "Build")}
        self.gh.logs[1] = log(scheme, "Build", "error: cannot find 'x' in scope", "the test helper died on signal 11")
        self.gh.logs[2] = log(scheme, "Build", "error: cannot find 'x' in scope")
        with self.assertRaisesRegex(excuse.Refused, "signal 11"):
            self.judge()

    def test_a_tools_error_in_a_non_test_job_is_still_excused_when_the_base_has_it(self):
        fast = "cmux-next fast tier"
        self.gh.jobs = {1: failed_job(1, 10, HEAD, fast, "Install"), 2: failed_job(2, 20, BASE_SHA, fast, "Install")}
        self.gh.logs[1] = self.gh.logs[2] = log(fast, "Install", "##[error]error: Could not find a version for foo")
        self.assertIn(fast, "\n".join(self.judge()))

    def test_a_red_test_the_base_does_not_fail_blocks(self):
        self.gh.logs[1] = log(SWIFT, TEST_STEP, ISSUE, OTHER)
        self.gh.logs[2] = log(SWIFT, TEST_STEP, ISSUE)
        with self.assertRaisesRegex(excuse.Refused, "palettePagesReleaseTheRegistry"):
            self.judge()


class NoVerdictCompileIsNeverABaseRed(unittest.TestCase):
    """A compile check with no verdict (the build-fleet controller unreachable or timed out) compiled
    nothing, so it is never a base red, even when the base shows the same "no result" with only its own
    sha differing (2026-10-28, cmux#26798's run against base run 40656801765). It is set aside only when
    another job at that same head compiled it and passed. A real red that differs only by the commit
    sha it names is still excused."""

    FLEET = "cmux-next fleet Release compile"
    STEP = "Wait for the fleet Release compile and publish cmux-next/compile"
    RELEASE = "cmux-next Release compile (Xcode 26)"

    class GitHub(FakeGitHub):
        def __init__(self):
            super().__init__()
            self.check_runs: list[dict] = []
            self.actions_jobs: dict[int, dict] = {}
            self.statuses: list[dict] = []

        def json(self, route, *, paginate=False):
            if f"/commits/{HEAD}/check-runs" in route:
                return [{"check_runs": copy.deepcopy(self.check_runs)}]
            if route.endswith(f"/commits/{HEAD}/status"):
                return {"statuses": copy.deepcopy(self.statuses)}
            if "/actions/jobs/" in route:
                return copy.deepcopy(self.actions_jobs[int(route.rsplit("/", 1)[1])])
            return super().json(route, paginate=paginate)

    def setUp(self):
        self.gh = self.GitHub()
        self.gh.jobs = {1: failed_job(1, 10, HEAD, self.FLEET, self.STEP),
                        2: failed_job(2, 20, BASE_SHA, self.FLEET, self.STEP)}
        self.gh.logs[1] = self.no_result(self.FLEET, self.STEP, "df40f81342c8bb1eb135ced40728a4e7a090ed49")
        self.gh.logs[2] = self.no_result(self.FLEET, self.STEP, "7ea21d1ce82ffaecc58599ae3f6bbf95afd92c51")

    @staticmethod
    def no_result(job, step, sha):
        return log(job, step, f"##[warning]no result for {sha} from the controller (attempt 1)",
                   f"##[error]cmux-next/compile is not a pass for {sha} (no result)",
                   "##[error]Process completed with exit code 1.")

    def release_run(self, check_id, conclusion="success", *, steps=None, sha=HEAD, check_sha=HEAD):
        """A `cmux-next Release compile (Xcode 26)` check run and its job. steps: the Mac compile's by default."""
        steps = steps if steps is not None else [("Checkout", "success"), ("Release compile", conclusion)]
        # A check run id is not its job id: the job comes from the details link.
        job_id = 1000 + check_id
        self.gh.check_runs.append({"id": check_id, "name": self.RELEASE, "status": "completed",
                                   "conclusion": conclusion, "head_sha": check_sha,
                                   "details_url": f"https://github.com/{REPO}/actions/runs/30/job/{job_id}",
                                   "app": {"slug": "github-actions"}})
        self.gh.actions_jobs[job_id] = {"id": job_id, "run_id": 30, "name": self.RELEASE, "head_sha": sha,
                                        "status": "completed", "conclusion": conclusion,
                                        "steps": [{"name": name, "conclusion": state} for name, state in steps]}

    def judge(self):
        return excuse.judge(REPO, "feat-cmux-next", HEAD, [10], self.gh)

    def test_no_verdict_with_nothing_else_compiling_the_head_is_refused_even_when_the_base_has_it(self):
        with self.assertRaisesRegex(excuse.Refused, r"no compile verdict.*never a base red"):
            self.judge()

    def test_the_app_compile_with_no_build_fleet_verdict_is_refused_too(self):
        app = "cmux-next app compile (build fleet)"
        step = "Compile-check the app at the pull request's head on the build fleet"
        self.gh.jobs = {1: failed_job(1, 10, HEAD, app, step), 2: failed_job(2, 20, BASE_SHA, app, step)}
        line = ("##[error]No build-fleet verdict for `{}` (controller unreachable or timed out: cmux-ci exit 69), "
                "so nothing has compiled this head here.")
        self.gh.logs[1] = log(app, step, line.format(HEAD))
        self.gh.logs[2] = log(app, step, line.format(BASE_SHA))
        with self.assertRaisesRegex(excuse.Refused, "never a base red"):
            self.judge()

    def test_no_verdict_is_ignored_when_the_mac_release_compile_passed_at_the_head(self):
        self.release_run(6)
        text = "\n".join(self.judge())
        self.assertIn(f"ignored '{self.FLEET}'", text)
        self.assertIn(self.RELEASE, text)

    def test_a_reused_pass_for_the_same_inputs_counts(self):
        self.release_run(6, steps=[("Reuse that pass", "success"), ("Release compile", "skipped")])
        self.assertIn(f"ignored '{self.FLEET}'", "\n".join(self.judge()))

    def test_the_admission_job_of_the_same_name_is_not_a_compile(self):
        self.release_run(6, steps=[("Record the Release compile admission", "success")])
        with self.assertRaisesRegex(excuse.Refused, "never a base red"):
            self.judge()

    def test_an_older_pass_does_not_count_when_a_newer_attempt_failed(self):
        self.release_run(6)
        self.release_run(9, "failure")
        with self.assertRaisesRegex(excuse.Refused, "never a base red"):
            self.judge()

    def test_a_skipped_foreign_or_unknown_sha_release_compile_is_not_a_pass(self):
        self.release_run(5, "skipped", steps=[])
        self.release_run(6, check_sha=None)
        self.release_run(7, sha=BASE_SHA)
        self.gh.check_runs.append({"id": 8, "name": self.RELEASE, "status": "completed", "conclusion": "success",
                                   "head_sha": HEAD, "app": {"slug": "someone-else"}})
        with self.assertRaises(excuse.Refused):
            self.judge()

    def test_no_verdict_is_ignored_when_cmux_next_compile_succeeded_at_the_head(self):
        self.gh.statuses = [{"context": "cmux-next/compile", "state": "success"}]
        self.assertIn("cmux-next/compile status", "\n".join(self.judge()))

    def test_another_job_printing_the_marker_is_never_set_aside(self):
        """Only the compile jobs that can end without a verdict are set aside by a compile pass; any other
        job with the same line is compared with the base like every red."""
        other = "cmux-next swift test"
        self.gh.jobs = {1: failed_job(1, 10, HEAD, other, TEST_STEP), 2: failed_job(2, 20, BASE_SHA, other, TEST_STEP)}
        self.gh.logs[1] = log(other, TEST_STEP, f"##[error]cmux-next/compile is not a pass for {HEAD} (no result)", OTHER)
        self.gh.logs[2] = log(other, TEST_STEP, ISSUE)
        self.release_run(6)
        with self.assertRaisesRegex(excuse.Refused, "palettePagesReleaseTheRegistry"):
            self.judge()

    def test_a_release_compile_without_a_job_link_or_from_another_run_is_not_a_pass(self):
        self.release_run(6)
        self.gh.check_runs[-1]["details_url"] = "https://example.com/job/1006"
        self.release_run(7)
        self.gh.actions_jobs[1007]["run_id"] = 31
        with self.assertRaises(excuse.Refused):
            self.judge()

    def test_a_failed_cmux_next_compile_status_is_not_a_pass(self):
        """The newest status per context decides: an older success behind it is stale."""
        self.gh.statuses = [{"context": "cmux-next/compile", "state": "failure"},
                            {"context": "cmux-next/compile", "state": "success"}]
        with self.assertRaises(excuse.Refused):
            self.judge()

    def test_a_real_fleet_red_whose_log_echoes_the_script_is_not_set_aside(self):
        """The log echoes the step's script, no-verdict words included; only the job's own ::error decides."""
        app = "cmux-next app compile (build fleet)"
        step = "Compile-check the app at the pull request's head on the build fleet"
        self.gh.jobs = {1: failed_job(1, 10, HEAD, app, step), 2: failed_job(2, 20, BASE_SHA, app, step)}
        script = '    local summary="No build-fleet verdict for \\`$REF\\` ($1), so nothing has compiled this head here."'
        self.gh.logs[1] = log(app, step, script, "##[error]The cmux-next app did not compile on the build fleet at "
                              f"`{HEAD}`; the errors are in this job's log above.")
        self.gh.logs[2] = log(app, step, script, "##[error]something else broke")
        self.release_run(6)
        with self.assertRaisesRegex(excuse.Refused, "did not compile"):
            self.judge()

    def test_a_real_red_differing_only_by_its_embedded_sha_is_excused(self):
        scheme = "cmux app scheme compile (Debug)"
        self.gh.jobs = {1: failed_job(1, 10, HEAD, scheme, "Build"), 2: failed_job(2, 20, BASE_SHA, scheme, "Build")}
        line = "error: cmux-tui for this checkout's tree {} is not published after 0 min."
        self.gh.logs[1] = log(scheme, "Build", line.format("5948da759b33dbe312f3108fab7dc39956c3dc56"))
        self.gh.logs[2] = log(scheme, "Build", line.format("8f0c2e1"))
        self.assertIn(f"excused '{scheme}'", "\n".join(self.judge()))

    def test_a_different_error_is_not_excused(self):
        scheme = "cmux app scheme compile (Debug)"
        self.gh.jobs = {1: failed_job(1, 10, HEAD, scheme, "Build"), 2: failed_job(2, 20, BASE_SHA, scheme, "Build")}
        self.gh.logs[1] = log(scheme, "Build", "error: cmux-tui for this checkout's tree 5948da759b3 is not published.")
        self.gh.logs[2] = log(scheme, "Build", "error: cmux-tui for this checkout's tree 8f0c2e1aa is corrupt.")
        with self.assertRaisesRegex(excuse.Refused, "not published"):
            self.judge()

    def test_other_hex_ids_are_compared_as_they_are(self):
        scheme = "cmux app scheme compile (Debug)"
        self.gh.jobs = {1: failed_job(1, 10, HEAD, scheme, "Build"), 2: failed_job(2, 20, BASE_SHA, scheme, "Build")}
        self.gh.logs[1] = log(scheme, "Build", "error: artifact deadbeef1 missing")
        self.gh.logs[2] = log(scheme, "Build", "error: artifact abcdef12 missing")
        with self.assertRaisesRegex(excuse.Refused, "artifact"):
            self.judge()

    def test_only_commit_shas_are_masked(self):
        self.assertEqual(excuse.mask_shas(f"defaced 1234567 accede deadbeef1 {HEAD} at 8f0c2e1 tree `5948da7` "
                                          "commit 1234567 for abcdef12"),
                         "defaced 1234567 accede deadbeef1 <sha> at 8f0c2e1 tree `<sha>` commit <sha> for abcdef12")

    def test_hex_ids_after_a_generic_word_are_compared_as_they_are(self):
        scheme = "cmux app scheme compile (Debug)"
        self.gh.jobs = {1: failed_job(1, 10, HEAD, scheme, "Build"), 2: failed_job(2, 20, BASE_SHA, scheme, "Build")}
        self.gh.logs[1] = log(scheme, "Build", "error: no artifact for deadbeef1")
        self.gh.logs[2] = log(scheme, "Build", "error: no artifact for abcdef12")
        with self.assertRaisesRegex(excuse.Refused, "artifact"):
            self.judge()

    def test_every_compile_status_state_but_fail_is_no_verdict(self):
        """Fail closed: compile-status's own lines are a real red only for "(fail)"."""
        for line in ("cmux-next/compile is not a pass for {} (pending)", "cmux-next/compile is not a pass for {} (pass)",
                     "cmux-next/compile is not a pass for {} (last: queued)",
                     "cmux-next/compile is not a pass for {} (unavailable)", "could not post the pending status",
                     "bad head sha '{}'"):
            with self.subTest(line=line):
                self.gh.logs[1] = log(self.FLEET, self.STEP, "##[error]" + line.format(HEAD))
                self.gh.logs[2] = log(self.FLEET, self.STEP, "##[error]" + line.format(BASE_SHA))
                with self.assertRaisesRegex(excuse.Refused, "never a base red"):
                    self.judge()

    def test_a_real_fleet_compile_failure_is_compared_with_the_base(self):
        line = "##[error]cmux-next/compile is not a pass for {} (fail)"
        self.gh.logs[1] = log(self.FLEET, self.STEP, line.format(HEAD))
        self.gh.logs[2] = log(self.FLEET, self.STEP, line.format(BASE_SHA))
        self.assertIn(f"excused '{self.FLEET}'", "\n".join(self.judge()))


class Script(unittest.TestCase):
    def test_gh_merge_green_asks_the_base_before_refusing_a_red_lane(self):
        text = (ROOT / "scripts/gh-merge-green").read_text()
        self.assertIn("base_red_excuse.py", text)
        # Lint stays unwaivable, and --override still skips the base comparison.
        self.assertIn("--override cannot bypass god-file, l10n or concurrency lint", text)


if __name__ == "__main__":
    unittest.main()
