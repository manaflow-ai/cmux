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


class Script(unittest.TestCase):
    def test_gh_merge_green_asks_the_base_before_refusing_a_red_lane(self):
        text = (ROOT / "scripts/gh-merge-green").read_text()
        self.assertIn("base_red_excuse.py", text)
        # A red lint check the base has too is asked about; risk evidence is never waived.
        self.assertIn("--override cannot bypass risk evidence", text)
        self.assertIn('"${lint_reds[@]+"${lint_reds[@]}"}"', text)


if __name__ == "__main__":
    unittest.main()
