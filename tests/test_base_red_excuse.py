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
        # Base commits, newest first, by ref; check runs per commit; sibling pull request runs.
        self.history: dict[str, list[str]] = {}
        self.merge_base: str | None = None
        self.commit_checks: dict[str, list[dict]] = {}
        self.pr_runs: list[dict] = []
        self.pr_commits: dict[int, list[str]] = {}
        # Runs of workflows other than 7, by workflow; the workflow of each run that is not 7.
        self.other_runs: dict[int, list[dict]] = {}
        self.run_workflows: dict[int, int] = {}

    def json(self, route, *, paginate=False):
        self.routes.append(route)
        if "/commits?sha=" in route:
            ref = route.split("?sha=", 1)[1].split("&", 1)[0]
            limit = int(route.rsplit("per_page=", 1)[1])
            return [{"sha": sha} for sha in self.history.get(ref, [])[:limit]]
        if "/compare/" in route:
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
            return {"id": run, "workflow_id": self.run_workflows.get(run, 7)}
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
        self.gh.logs[1] = log(SWIFT, TEST_STEP, ISSUE, "##[error]error: the swift test run exited with signal 6")
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


class BaseOwnedCrash(unittest.TestCase):
    """A test helper crash on the base is the base's: the head's crash with the same signal is excused,
    though the tests in flight and the crashed thread differ run to run."""

    def setUp(self):
        self.gh = FakeGitHub()
        self.gh.logs[2] = crashed(SWIFT, 5, ["a()", "b()"], "swift_task_checkIsolatedSwift <- KeyWindowObserver.windowWillClose(_:)")

    def judge(self):
        return excuse.judge(REPO, "feat-cmux-next", HEAD, [10], self.gh)

    def test_a_crash_with_the_signal_the_base_crashed_on_is_excused(self):
        self.gh.logs[1] = crashed(SWIFT, 5, ["c()", "d()", "e()"], "swift_task_checkIsolatedSwift <- ???")
        text = "\n".join(self.judge())
        self.assertIn("run 20", text)
        self.assertIn("signal 5", text)

    def test_a_crash_the_base_did_not_have_blocks(self):
        self.gh.logs[1] = crashed(SWIFT, 5, ["c()"], "f")
        self.gh.logs[2] = log(SWIFT, TEST_STEP, ISSUE)
        with self.assertRaisesRegex(excuse.Refused, "signal"):
            self.judge()

    def test_a_crash_on_another_signal_blocks(self):
        self.gh.logs[1] = crashed(SWIFT, 11, ["c()"], "f")
        with self.assertRaisesRegex(excuse.Refused, "signal"):
            self.judge()

    def test_a_red_test_before_the_crash_must_still_be_on_the_base(self):
        self.gh.logs[1] = crashed(SWIFT, 5, ["c()"], "f", OTHER)
        with self.assertRaisesRegex(excuse.Refused, "palettePagesReleaseTheRegistry"):
            self.judge()
        self.gh.logs[2] = crashed(SWIFT, 5, ["a()"], "g", OTHER)
        self.assertTrue(self.judge())

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
        with self.assertRaisesRegex(excuse.Refused, "every failed job of its run is a status job"):
            self.judge()
        del self.gh.jobs[3]
        with self.assertRaisesRegex(excuse.Refused, "has no failed job under web / to compare"):
            self.judge()

    def test_a_status_line_beside_other_output_is_not_a_status_job(self):
        job, status_log = status_job(2, 10, HEAD, RAC, "react-apps-check-shard")
        self.assertEqual(excuse.aggregated(job, status_log), ["react-apps-check-shard"])
        self.assertIsNone(excuse.aggregated(job, status_log + "\n" + log(RAC, "Check routed web jobs", "boom")))
        cancelled = log(RAC, "Check routed web jobs", "react-apps-check-shard: cancelled")
        self.assertIsNone(excuse.aggregated(job, cancelled))


class Script(unittest.TestCase):
    def test_gh_merge_green_asks_the_base_before_refusing_a_red_lane(self):
        text = (ROOT / "scripts/gh-merge-green").read_text()
        self.assertIn("base_red_excuse.py", text)
        # A red lint check the base has too is asked about; risk evidence is never waived.
        self.assertIn("--override cannot bypass risk evidence", text)
        self.assertIn('"${lint_reds[@]+"${lint_reds[@]}"}"', text)


if __name__ == "__main__":
    unittest.main()
