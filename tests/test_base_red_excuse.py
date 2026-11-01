"""gh-merge-green excuses a red check only when the base branch's latest completed run has the same failures."""
import copy
import importlib.util
import json
import os
import subprocess
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

    def json(self, route, *, paginate=False):
        self.routes.append(route)
        if "/actions/runs/" in route and route.endswith("/jobs?filter=latest&per_page=100"):
            run = int(route.split("/actions/runs/", 1)[1].split("/", 1)[0])
            return [{"jobs": [copy.deepcopy(job) for job in self.jobs.values() if job["run_id"] == run]}]
        if "/actions/workflows/7/runs?" in route:
            # The dispatch fallback lists every status (deferred_first_runs); the window only completed runs.
            assert "branch=feat-cmux-next" in route and ("status=completed" in route
                                                         or "event=workflow_dispatch" in route), route
            return {"workflow_runs": copy.deepcopy(self.base_runs)}
        if "/actions/runs/" in route:
            return {"id": int(route.rsplit("/", 1)[1]), "workflow_id": 7}
        raise AssertionError(route)

    def log(self, repo, job):
        return self.logs[job["id"]]


class InProgressJobLogGitHub(FakeGitHub):
    """An in-progress run whose failed job has already finished.

    The Actions run-log endpoint serves this job immediately; the run-level
    ``gh run view --log`` command waits for every other job in the run.
    """

    def __init__(self):
        super().__init__()
        self.jobs[3] = dict(failed_job(3, 10, HEAD, name="Mac compile"),
                            status="queued", conclusion=None, steps=[])
        self.log_requests: list[list[str]] = []

    def json(self, route, *, paginate=False):
        result = super().json(route, paginate=paginate)
        if route == f"repos/{REPO}/actions/runs/10":
            result.update(status="in_progress", conclusion=None)
        return result

    def log(self, repo, job):
        return excuse.GitHub.log(self, repo, job)

    def run(self, args):
        self.log_requests.append(args)
        if args[:2] == ["run", "view"]:
            raise excuse.Refused("logs will be available when it is complete")
        for job_id, text in self.logs.items():
            if args in (["api", "--allow-escape-sequences", f"repos/{REPO}/actions/jobs/{job_id}/logs"],
                        ["api", f"repos/{REPO}/actions/jobs/{job_id}/logs"]):
                # Raw endpoint output has timestamps but no job/step prefix.
                return "\n".join(line.split("\t", 2)[-1] for line in text.splitlines())
        raise AssertionError(args)


class LargeJobListGitHub(excuse.GitHub):
    """The real client and pager over FakeGitHub's data, through `gh api` calls only.

    GitHub answers a run's job listing with HTTP 502 when a page holds more than 30 jobs' steps:
    seen on 2026-10-30 for the 34-job web run 41098664586, where per_page=100 and 50 failed every
    time and per_page=30 answered, so no red in that run could be judged.
    """

    def __init__(self):
        self.data = FakeGitHub()
        self.calls: list[str] = []

    def run(self, args):
        assert args[0] == "api", args
        route = args[-1]
        self.calls.append(route)
        path, _, query = route.partition("?")
        params = dict(part.split("=", 1) for part in query.split("&") if part)
        if path.endswith("/jobs"):
            per_page, page = int(params["per_page"]), int(params["page"])
            if per_page > 30:
                raise excuse.Refused("GitHub evidence request failed: gh: Server Error (HTTP 502)")
            jobs = self.data.json(f"{path}?filter=latest&per_page=100", paginate=True)[0]["jobs"]
            return json.dumps({"total_count": len(jobs), "jobs": jobs[(page - 1) * per_page:page * per_page]})
        if path.endswith("/logs"):
            return self.data.logs[int(path.rsplit("/", 2)[-2])]
        return json.dumps(self.data.json(route))


class JobListPages(unittest.TestCase):
    def test_a_run_with_many_jobs_is_still_judged(self):
        github = LargeJobListGitHub()
        lines = excuse.judge(REPO, "feat-cmux-next", HEAD, [10], github)
        self.assertIn("run 20", "\n".join(lines))

    def test_job_lists_are_read_in_pages_of_30(self):
        github = LargeJobListGitHub()
        excuse.judge(REPO, "feat-cmux-next", HEAD, [10], github)
        job_reads = [route for route in github.calls if "/jobs?" in route]
        self.assertTrue(job_reads)
        self.assertTrue(all("per_page=30&" in route for route in job_reads), job_reads)


class JobLogEndpoint(unittest.TestCase):
    def test_finished_red_job_is_classified_while_its_run_is_in_progress(self):
        github = InProgressJobLogGitHub()
        lines = excuse.judge(REPO, "feat-cmux-next", HEAD, [10], github)
        self.assertIn("run 20", "\n".join(lines))
        self.assertEqual(github.json(f"repos/{REPO}/actions/runs/10")["status"], "in_progress")
        self.assertEqual(github.log_requests,
                         [["api", "--allow-escape-sequences", f"repos/{REPO}/actions/jobs/{job_id}/logs"]
                          for job_id in (1, 2)])

    def test_job_logs_are_read_even_with_terminal_colours(self):
        # ANSI colours are stripped by the Python parser after the flag-capable request.
        github = InProgressJobLogGitHub()
        excuse.judge(REPO, "feat-cmux-next", HEAD, [10], github)
        self.assertTrue(all("--allow-escape-sequences" in r for r in github.log_requests))

    def test_new_failure_in_finished_job_still_blocks(self):
        github = InProgressJobLogGitHub()
        github.logs[1] = log(SWIFT, TEST_STEP, OTHER)
        github.logs[2] = log(SWIFT, TEST_STEP, ISSUE)
        with self.assertRaisesRegex(excuse.Refused, "palettePagesReleaseTheRegistry"):
            excuse.judge(REPO, "feat-cmux-next", HEAD, [10], github)

    def test_raw_log_tabs_do_not_hide_a_new_error(self):
        github = InProgressJobLogGitHub()
        for job_id in (1, 2):
            github.jobs[job_id]["name"] = SCHEME
            github.logs[job_id] = log(SCHEME, TEST_STEP, "Source.swift:10:1: error: existing failure")
        github.logs[1] += "\n" + log(SCHEME, TEST_STEP, "##[error]\tnew compile failure")
        with self.assertRaisesRegex(excuse.Refused, "new compile failure"):
            excuse.judge(REPO, "feat-cmux-next", HEAD, [10], github)

    def test_raw_log_tabs_do_not_hide_no_verdict_annotation(self):
        text = f"2026-10-30T12:00:00.000Z ##[error]No build-fleet verdict for `\t{HEAD}`"
        self.assertIsNotNone(excuse.no_verdict(text))

    def test_raw_log_tabs_preserve_the_entire_error(self):
        text = "2026-10-30T12:00:00.000Z ##[error]\tnew\tcompile failure"
        self.assertEqual(excuse.lines_of(text), ["##[error]\tnew\tcompile failure"])


class StepFailureOutput(unittest.TestCase):
    """Checks with no test names still compare the failed step's diagnostic output."""

    def test_a_step_without_test_names_compares_its_failure_summary(self):
        github = FakeGitHub()
        defaults = "defaults-snapshot"
        step = "The defaults snapshot matches the exports"
        github.jobs = {
            1: failed_job(1, 10, HEAD, name=defaults, step=step),
            2: failed_job(2, 20, BASE_SHA, name=defaults, step=step),
        }
        stale = ("schemas/defaults/cmux-next.json is stale: the settings export changed "
                 f"(source stamp {'a' * 40} != {'b' * 40})")
        github.logs = {
            1: log(defaults, step, stale, "##[error]Process completed with exit code 1."),
            2: log(defaults, step, stale.replace("a" * 40, "c" * 40), "##[error]Process completed with exit code 1."),
        }
        text = "\n".join(excuse.judge(REPO, "feat-cmux-next", HEAD, [10], github))
        self.assertIn(defaults, text)
        self.assertIn("settings export changed", text)

    def test_a_different_step_summary_still_blocks(self):
        github = FakeGitHub()
        defaults = "defaults-snapshot"
        step = "The defaults snapshot matches the exports"
        github.jobs = {
            1: failed_job(1, 10, HEAD, name=defaults, step=step),
            2: failed_job(2, 20, BASE_SHA, name=defaults, step=step),
        }
        github.logs = {
            1: log(defaults, step, "schemas/defaults/cmux-next.json is missing its source stamp",
                   "##[error]Process completed with exit code 1."),
            2: log(defaults, step, "schemas/defaults/cmux-next.json is stale: the settings export changed",
                   "##[error]Process completed with exit code 1."),
        }
        with self.assertRaisesRegex(excuse.Refused, "errors not on feat-cmux-next run 20"):
            excuse.judge(REPO, "feat-cmux-next", HEAD, [10], github)

    def test_defaults_checker_fail_line_is_compared(self):
        github = FakeGitHub()
        defaults = "defaults-snapshot"
        step = "The defaults snapshot matches the exports"
        failure = "check-group-menus: FAIL tab: tabGroup.create is not a top-level row"
        github.jobs = {
            1: failed_job(1, 10, HEAD, name=defaults, step=step),
            2: failed_job(2, 20, BASE_SHA, name=defaults, step=step),
        }
        github.logs = {
            1: log(defaults, step, failure, "##[error]Process completed with exit code 1."),
            2: log(defaults, step, failure, "##[error]Process completed with exit code 1."),
        }
        self.assertIn(defaults, "\n".join(excuse.judge(REPO, "feat-cmux-next", HEAD, [10], github)))

    def test_defaults_snapshot_source_mismatch_is_compared(self):
        github = FakeGitHub()
        defaults = "defaults-snapshot"
        step = "The defaults snapshot matches the exports"
        failure = "DEFAULTS snapshot: schemas/defaults/cmux-next.json does not match the sources"
        github.jobs = {1: failed_job(1, 10, HEAD, name=defaults, step=step),
                       2: failed_job(2, 20, BASE_SHA, name=defaults, step=step)}
        github.logs = {1: log(defaults, step, failure, "##[error]Process completed with exit code 1."),
                       2: log(defaults, step, failure, "##[error]Process completed with exit code 1.")}
        self.assertIn(defaults, "\n".join(excuse.judge(REPO, "feat-cmux-next", HEAD, [10], github)))

    def test_defaults_checker_summary_cannot_excuse_a_crash(self):
        github = FakeGitHub()
        defaults = "defaults-snapshot"
        step = "The defaults snapshot matches the exports"
        failure = "schemas/defaults/cmux-next.json is stale: the settings export changed"
        github.jobs = {
            1: failed_job(1, 10, HEAD, name=defaults, step=step),
            2: failed_job(2, 20, BASE_SHA, name=defaults, step=step),
        }
        github.logs = {
            1: log(defaults, step, failure, "Segmentation fault (core dumped)",
                   "##[error]Process completed with exit code 139."),
            2: log(defaults, step, failure, "##[error]Process completed with exit code 1."),
        }
        with self.assertRaisesRegex(excuse.Refused, "crash"):
            excuse.judge(REPO, "feat-cmux-next", HEAD, [10], github)


# A `gh` on PATH: it records its argv; FAKE_GH=http and FAKE_GH=other-flag refuse every call.
# Otherwise it prints a coloured log, which the Python parser strips.
FAKE_GH = """#!/usr/bin/env python3
import os, sys
args = sys.argv[1:]
with open(os.environ["FAKE_GH_CALLS"], "a") as calls:
    calls.write(" ".join(args) + "\\n")
mode = os.environ.get("FAKE_GH", "")
if mode == "old" and "--allow-escape-sequences" in args:
    sys.stderr.write("unknown flag: --allow-escape-sequences\\n\\nUsage: gh api <endpoint> [flags]\\n")
    sys.exit(1)
if mode == "http":
    sys.stderr.write("gh: Not Found (HTTP 404)\\n")
    sys.exit(1)
if mode == "other-flag":
    sys.stderr.write("unknown flag: --hostname-x\\nunknown flag: --allow-escape-sequences\\n")
    sys.exit(1)
print("2026-10-30T12:00:00.000Z \\x1b[31mred\\x1b[0m log")
"""


class PortableGhLog(unittest.TestCase):

    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        gh = Path(self.dir.name) / "gh"
        gh.write_text(FAKE_GH)
        gh.chmod(0o755)
        self.calls = Path(self.dir.name) / "calls"
        self.calls.write_text("")
        env = {"PATH": f"{self.dir.name}{os.pathsep}{os.environ.get('PATH', '')}", "FAKE_GH_CALLS": str(self.calls)}
        patch = unittest.mock.patch.dict(os.environ, env)
        patch.start()
        self.addCleanup(patch.stop)

    def read(self, mode):
        os.environ["FAKE_GH"] = mode
        return excuse.GitHub().log(REPO, {"id": 7, "run_id": 10})

    def asked(self):
        return self.calls.read_text().splitlines()

    def test_logs_use_the_flag_and_strip_ansi_in_python(self):
        raw = self.read("")
        self.assertIn("\x1b[31mred", raw)
        route = f"repos/{REPO}/actions/jobs/7/logs"
        self.assertEqual(self.asked(), [f"api --allow-escape-sequences {route}"])
        self.assertEqual(excuse.lines_of(raw), ["red log"])

    def test_old_gh_falls_back_without_the_flag(self):
        self.assertIn("red", self.read("old"))
        route = f"repos/{REPO}/actions/jobs/7/logs"
        self.assertEqual(self.asked(), [f"api --allow-escape-sequences {route}", f"api {route}"])

    def test_any_other_failure_still_refuses_with_no_retry(self):
        for mode in ("http", "other-flag"):
            with self.subTest(mode=mode):
                self.calls.write_text("")
                with self.assertRaises(excuse.Refused):
                    self.read(mode)
                self.assertEqual(len(self.asked()), 1)

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

    def test_chromium_currency_same_failed_step_is_excused_without_log_error(self):
        """Blacksmith exposes only a generic exit annotation for this deterministic check."""
        github = FakeGitHub()
        for job in github.jobs.values():
            job["name"] = excuse.CHROMIUM_CURRENCY_JOB
            job["steps"] = [
                {"name": "Set up runner", "status": "completed", "conclusion": "success"},
                {"name": excuse.CHROMIUM_CURRENCY_STEP, "status": "completed", "conclusion": "failure"},
            ]
        github.logs[1] = github.logs[2] = ""
        lines = excuse.judge(REPO, "feat-cmux-next", HEAD, [10], github)
        self.assertIn("run 20", "\n".join(lines))

    def test_chromium_currency_diagnostic_still_compares_errors(self):
        github = FakeGitHub()
        for job in github.jobs.values():
            job["name"] = excuse.CHROMIUM_CURRENCY_JOB
            job["steps"] = [
                {"name": "Set up runner", "status": "completed", "conclusion": "success"},
                {"name": excuse.CHROMIUM_CURRENCY_STEP, "status": "completed", "conclusion": "failure"},
            ]
        github.logs[1] = log(excuse.CHROMIUM_CURRENCY_JOB, excuse.CHROMIUM_CURRENCY_STEP,
                              "##[error]Chromium currency check raised ValueError")
        github.logs[2] = log(excuse.CHROMIUM_CURRENCY_JOB, excuse.CHROMIUM_CURRENCY_STEP,
                              "##[error]Chromium currency check failed: three milestones behind")
        with self.assertRaisesRegex(excuse.Refused, "ValueError"):
            excuse.judge(REPO, "feat-cmux-next", HEAD, [10], github)

    def test_chromium_currency_missing_head_diagnostics_do_not_hide_base_diagnostics(self):
        github = FakeGitHub()
        for job in github.jobs.values():
            job["name"] = excuse.CHROMIUM_CURRENCY_JOB
            job["steps"] = [
                {"name": "Set up runner", "status": "completed", "conclusion": "success"},
                {"name": excuse.CHROMIUM_CURRENCY_STEP, "status": "completed", "conclusion": "failure"},
            ]
        github.logs[1] = ""
        github.logs[2] = log(excuse.CHROMIUM_CURRENCY_JOB, excuse.CHROMIUM_CURRENCY_STEP,
                              "##[error]Chromium currency check failed: three milestones behind")
        with self.assertRaisesRegex(excuse.Refused, "no failing test or error line"):
            excuse.judge(REPO, "feat-cmux-next", HEAD, [10], github)

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

    def tip_daemon_setup(self, *, verdict="failure"):
        # 2026-10-30 (#27692): a feat-cmux-next push never runs daemon-test, base pushes land every
        # minute or two, and the base's only daemon-test verdict is main's tip daemon suite run.
        daemon = "cmux-next daemon tests"
        self.gh.jobs = {1: failed_job(1, 10, HEAD, name=daemon, step="Run the live-daemon suites")}
        self.gh.logs[1] = log(daemon, "Run the live-daemon suites", ISSUE)
        pushes = []
        for offset in range(excuse.BASE_JOB_READS + 5):
            run_id = 3000 + offset
            self.gh.jobs[run_id] = dict(failed_job(run_id, run_id, BASE_SHA, name=daemon), conclusion="skipped",
                                        steps=[])
            pushes.append({"id": run_id, "event": "push", "head_branch": "feat-cmux-next",
                           "status": "completed", "conclusion": "success"})
        self.gh.base_runs = pushes
        suite = {"id": 40, "event": "workflow_dispatch", "head_branch": "feat-cmux-next", "status": "completed",
                 "conclusion": verdict, "display_title": "cmux-next tip daemon suite · " + BASE_SHA,
                 "html_url": "https://github.com/manaflow-ai/cmux/actions/runs/40"}
        other = {"id": 41, "event": "workflow_dispatch", "head_branch": "feat-cmux-next", "status": "completed",
                 "conclusion": "success", "display_title": "cmux NEXT DEV daily · " + BASE_SHA}
        self.gh.jobs[4] = dict(failed_job(4, 40, BASE_SHA, name=daemon, step="Run the live-daemon suites"),
                               conclusion=verdict)
        self.gh.logs[4] = log(daemon, "Run the live-daemon suites", ISSUE, OTHER)
        plain = self.gh.json

        def json(route, *, paginate=False):
            if "/actions/workflows/7/runs?" in route and "event=workflow_dispatch" in route:
                self.gh.routes.append(route)
                return {"workflow_runs": [copy.deepcopy(other), copy.deepcopy(suite)]}
            return plain(route, paginate=paginate)

        self.gh.json = json

    def test_the_tip_daemon_suite_past_a_burst_of_base_pushes_is_the_base_verdict(self):
        self.tip_daemon_setup()
        text = "\n".join(self.judge())
        self.assertIn("excused 'cmux-next daemon tests'", text)
        self.assertIn("run 40", text)
        lookup = [route for route in self.gh.routes if "event=workflow_dispatch" in route]
        self.assertEqual(len(lookup), 1)
        self.assertIn("branch=feat-cmux-next", lookup[0])
        # Only the tip suite run's jobs are read past the window, never the DEV daily's.
        self.assertNotIn(f"repos/{REPO}/actions/runs/41/jobs?filter=latest&per_page=100", self.gh.routes)

    def test_a_newer_green_dispatch_stands_over_an_older_red_tip_suite(self):
        # Review of #28283: a newer ordinary dispatch that ran daemon-test green must not be skipped for
        # an older red tip suite run, or a regression since would be excused.
        self.tip_daemon_setup()
        daemon = "cmux-next daemon tests"
        newer = {"id": 42, "event": "workflow_dispatch", "head_branch": "feat-cmux-next", "status": "completed",
                 "conclusion": "success", "display_title": "cmux-next · " + "c" * 40}
        self.gh.jobs[5] = dict(failed_job(5, 42, BASE_SHA, name=daemon), conclusion="success")
        listed = self.gh.json

        def json(route, *, paginate=False):
            answer = listed(route, paginate=paginate)
            if "event=workflow_dispatch" in route:
                answer["workflow_runs"].insert(0, copy.deepcopy(newer))
            return answer

        self.gh.json = json
        with self.assertRaisesRegex(excuse.Refused, "not red on feat-cmux-next run 42"):
            self.judge()

    def test_a_tip_daemon_suite_green_on_the_base_still_blocks(self):
        self.tip_daemon_setup(verdict="success")
        with self.assertRaisesRegex(excuse.Refused, "not red on feat-cmux-next run 40"):
            self.judge()

    def test_a_job_with_no_tip_suite_gets_no_extra_lookup(self):
        self.gh.base_runs = []
        self.gh.jobs[1]["name"] = "cmux-next Release compile (Xcode 26)"
        with self.assertRaisesRegex(excuse.Refused, "no completed"):
            self.judge()
        self.assertFalse([route for route in self.gh.routes if "event=workflow_dispatch" in route])

    def base_tier_setup(self, name, *, verdict="failure", in_window=False):
        # cmuxterm-hq#5424: a feat-cmux-next push no longer runs the base Mac tier (daemon tests, generated
        # files, the Debug scheme compile); a `cmux-next base tier · <sha>` dispatch runs it at most once
        # every 15 minutes on the tip, so most base runs, pushes and DEV daily runs, have no verdict for it.
        self.gh.jobs = {1: failed_job(1, 10, HEAD, name=name, step="Run the suites")}
        self.gh.logs[1] = log(name, "Run the suites", ISSUE)
        noise = []
        for offset in range(excuse.BASE_JOB_READS + 5):
            run_id = 3000 + offset
            self.gh.jobs[run_id] = dict(failed_job(run_id, run_id, BASE_SHA, name=name), conclusion="skipped",
                                        steps=[])
            noise.append({"id": run_id, "event": "workflow_dispatch", "head_branch": "feat-cmux-next",
                          "status": "completed", "conclusion": "success",
                          "display_title": "cmux NEXT DEV daily · " + BASE_SHA})
        tested = "e" * 40
        tier = {"id": 40, "event": "workflow_dispatch", "head_branch": "feat-cmux-next", "head_sha": "f" * 40,
                "status": "completed", "conclusion": verdict, "display_title": "cmux-next base tier · " + tested,
                "created_at": "2026-10-30T12:00:00Z", "html_url": "https://github.com/manaflow-ai/cmux/actions/runs/40"}
        self.gh.jobs[4] = dict(failed_job(4, 40, tested, name=name, step="Run the suites"), conclusion=verdict)
        self.gh.logs[4] = log(name, "Run the suites", ISSUE, OTHER)
        self.gh.base_runs = noise + ([copy.deepcopy(tier)] if in_window else [])
        plain = self.gh.json

        def json(route, *, paginate=False):
            if "/actions/workflows/7/runs?" in route and "event=workflow_dispatch" in route:
                self.gh.routes.append(route)
                return {"workflow_runs": [copy.deepcopy(noise[0]), copy.deepcopy(tier)]}
            return plain(route, paginate=paginate)

        self.gh.json = json

    def test_the_base_tier_run_is_the_base_verdict_for_its_jobs(self):
        for name in ("cmux-next daemon tests", "cmux-next generated files", SCHEME):
            with self.subTest(job=name):
                self.setUp()
                self.base_tier_setup(name)
                text = "\n".join(self.judge())
                self.assertIn(f"excused '{name}'", text)
                # It says which commit and when the verdict is from: one base tier run covers the landings
                # of up to 15 minutes, so it is often not the base tip's.
                self.assertIn("run 40 at eeeeeeeeee (the newest feat-cmux-next verdict for it, 2026-10-30T12:00:00Z)",
                              text)
                self.assertNotIn(f"repos/{REPO}/actions/runs/3000/jobs?filter=latest&per_page=100", self.gh.routes)

    def test_suites_that_never_run_the_job_are_skipped_unread_in_the_window(self):
        # 45 DEV daily runs ahead of the base tier run in the window: none is read, so the job-list budget
        # still reaches the base tier run and the dispatch fallback is not needed.
        self.base_tier_setup(SCHEME, in_window=True)
        text = "\n".join(self.judge())
        self.assertIn(f"excused '{SCHEME}'", text)
        self.assertFalse([route for route in self.gh.routes if "/runs/30" in route and "/jobs?" in route])
        self.assertFalse([route for route in self.gh.routes if "event=workflow_dispatch" in route])

    def test_a_suite_runs_verdict_for_a_shared_job_still_counts(self):
        # Review of this change: tip suite runs also run checks and web bundles. A newer green verdict in a
        # tip daemon suite run must stand over an older red push run, or a regression would be excused.
        name = "cmux-next checks (god files, concurrency, crash safety, l10n)"
        self.gh.jobs = {1: failed_job(1, 10, HEAD, name=name, step="Run the suites")}
        self.gh.logs[1] = log(name, "Run the suites", ISSUE)
        suite = {"id": 21, "event": "workflow_dispatch", "head_branch": "feat-cmux-next", "status": "completed",
                 "conclusion": "success", "display_title": "cmux-next tip daemon suite · " + BASE_SHA}
        push = {"id": 20, "event": "push", "head_branch": "feat-cmux-next", "status": "completed",
                "conclusion": "failure", "display_title": "cmux-next · " + BASE_SHA}
        self.gh.jobs[5] = dict(failed_job(5, 21, BASE_SHA, name=name), conclusion="success")
        self.gh.jobs[6] = failed_job(6, 20, BASE_SHA, name=name, step="Run the suites")
        self.gh.logs[6] = log(name, "Run the suites", ISSUE)
        self.gh.base_runs = [suite, push]
        with self.assertRaisesRegex(excuse.Refused, "not red on feat-cmux-next run 21"):
            self.judge()

    def deferred_first_runs_setup(self, name):
        # 2026-10-31: a base tier dispatch whose cmux-tui tree had not published skipped its tree jobs and
        # left them to the same-tree run its publish dispatched, under the same name, which then queued for
        # the Mac pool. The six newest completed dispatches were all such first runs, so the job-list reads
        # ran out before the tip daemon suite run that had the verdict.
        self.base_tier_setup(name)
        listed = []
        for offset in range(excuse.TIP_SUITE_JOB_READS + 2):
            tested = f"{offset:x}" * 40
            title = "cmux-next base tier · " + tested[:40]
            listed.append({"id": 6000 + offset, "event": "workflow_dispatch", "head_branch": "feat-cmux-next",
                           "status": "queued", "conclusion": None, "display_title": title})
            first = 5000 + offset
            listed.append({"id": first, "event": "workflow_dispatch", "head_branch": "feat-cmux-next",
                           "status": "completed", "conclusion": "success", "display_title": title})
            self.gh.jobs[first] = dict(failed_job(first, first, tested[:40], name=name, step="Run the suites"),
                                       conclusion="skipped")
        # The newest same-tree run that finished: base_tier_setup's run 40, the only run of its name.
        suite = {"id": 40, "event": "workflow_dispatch", "head_branch": "feat-cmux-next", "status": "completed",
                 "conclusion": "failure", "display_title": "cmux-next base tier · " + "e" * 40,
                 "created_at": "2026-10-31T09:48:29Z"}
        self.gh.base_runs = []
        plain = self.gh.json

        def json(route, *, paginate=False):
            if "/actions/workflows/7/runs?" in route and "event=workflow_dispatch" in route:
                self.gh.routes.append(route)
                self.assertNotIn("status=", route)
                return {"workflow_runs": copy.deepcopy(listed) + [copy.deepcopy(suite)]}
            return plain(route, paginate=paginate)

        self.gh.json = json

    def test_first_runs_that_left_their_tree_jobs_to_a_same_tree_run_are_skipped_unread(self):
        for name in ("cmux-next daemon tests", SCHEME):
            with self.subTest(job=name):
                self.setUp()
                self.deferred_first_runs_setup(name)
                text = "\n".join(self.judge())
                self.assertIn(f"excused '{name}'", text)
                self.assertIn("run 40", text)
                self.assertFalse([route for route in self.gh.routes if "/runs/50" in route and "/jobs?" in route])

    def test_cancelled_base_tier_runs_are_skipped_unread(self):
        # The base tier kick cancels superseded base tier runs before a Mac job starts
        # (cmux_next_base_tier.py cancel_superseded). Ahead of the run with the verdict, more of them than the
        # lookup reads must not hide it.
        self.base_tier_setup(SCHEME)
        cancelled = [{"id": 7000 + offset, "event": "workflow_dispatch", "head_branch": "feat-cmux-next",
                      "status": "completed", "conclusion": "cancelled",
                      "display_title": "cmux-next base tier · " + f"{offset:x}" * 40}
                     for offset in range(excuse.TIP_SUITE_JOB_READS + 2)]
        suite = {"id": 40, "event": "workflow_dispatch", "head_branch": "feat-cmux-next", "status": "completed",
                 "conclusion": "failure", "display_title": "cmux-next base tier · " + "e" * 40,
                 "created_at": "2026-10-31T09:48:29Z"}
        self.gh.base_runs = copy.deepcopy(cancelled)
        plain = self.gh.json

        def json(route, *, paginate=False):
            if "/actions/workflows/7/runs?" in route and "event=workflow_dispatch" in route:
                self.gh.routes.append(route)
                return {"workflow_runs": copy.deepcopy(cancelled) + [copy.deepcopy(suite)]}
            return plain(route, paginate=paginate)

        self.gh.json = json
        text = "\n".join(self.judge())
        self.assertIn(f"excused '{SCHEME}'", text)
        self.assertFalse([route for route in self.gh.routes if "/runs/70" in route and "/jobs?" in route])

    def test_tree_jobs_are_jobs_of_the_suites_that_defer_them(self):
        # Only a tip daemon suite or base tier run defers its tree jobs; a name outside them skips nothing.
        self.assertLessEqual(excuse.TREE_JOBS, excuse.SUITES["cmux-next base tier · "])
        self.assertLessEqual(excuse.SUITES["cmux-next tip daemon suite · "], excuse.TREE_JOBS)

    def test_a_first_run_still_counts_for_the_jobs_it_runs_itself(self):
        # Generated files run in the first run itself (path routing's generated_host), never in its
        # same-tree run, so the newest first run's verdict decides: here green, so the red is the head's.
        name = "cmux-next generated files"
        self.deferred_first_runs_setup(name)
        self.gh.jobs[5000]["conclusion"] = "success"
        with self.assertRaisesRegex(excuse.Refused, "not red on feat-cmux-next run 5000"):
            self.judge()

    def test_a_green_base_tier_run_still_blocks(self):
        self.base_tier_setup("cmux-next daemon tests", verdict="success")
        with self.assertRaisesRegex(excuse.Refused, "not red on feat-cmux-next run 40"):
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

    def test_generated_shared_build_no_verdict_reruns_its_prerequisite(self):
        """A cancelled-before-start Swift host leaves the dependent check without evidence.

        The workflow intentionally keeps generated-verdict fail-closed.  Its diagnostic is a request to
        rerun the host and dependent together, not a test or compile failure that can be compared with base.
        The shell source echoes the same error branch, so the classifier must read the live annotation only.
        """
        name = excuse.GENERATED_VERDICT_JOB
        step = "Read the generated files verdict of the shared build"
        no_verdict = "swift-test (cancelled) gave no generated files verdict: its package build failed or it stopped before the checks. Fix or re-run swift-test."
        self.gh.jobs[1] = failed_job(1, 10, HEAD, name=name, step=step)
        self.gh.jobs[2] = failed_job(2, 20, BASE_SHA, name=name, step=step)
        echoed = [
            '##[group]Run case "$VERDICT" in',
            'echo "::error::swift-test ($HOST_RESULT) gave no generated files verdict: its package build failed or it stopped before the checks. Fix or re-run $HOST."',
            "shell: /usr/bin/bash -e {0}",
            "##[endgroup]",
        ]
        self.gh.logs[1] = log(name, step, *echoed, "##[error]" + no_verdict, "##[error]Process completed with exit code 1.")
        self.gh.logs[2] = log(name, step, "##[error]" + no_verdict, "##[error]Process completed with exit code 1.")
        with self.assertRaisesRegex(excuse.Refused, r"no generated files verdict.*re-run its prerequisite and this dependent"):
            self.judge()

    def test_generated_shared_build_real_stale_error_is_still_compared(self):
        name = excuse.GENERATED_VERDICT_JOB
        step = "Read the generated files verdict of the shared build"
        stale = "Generated cmux-next files are stale. swift-test's step summary says how to regenerate them; its cmux-next-generated-patch artifact holds the regenerated files."
        self.gh.jobs[1] = failed_job(1, 10, HEAD, name=name, step=step)
        self.gh.jobs[2] = failed_job(2, 20, BASE_SHA, name=name, step=step)
        self.gh.logs[1] = log(name, step, "##[error]" + stale, "##[error]Process completed with exit code 1.")
        self.gh.logs[2] = log(name, step, "##[error]" + stale, "##[error]Process completed with exit code 1.")
        self.assertTrue(self.judge())

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

    def red_ci_status(self):
        self.gh.jobs[3] = {"id": 3, "run_id": 10, "head_sha": HEAD, "name": "ci-status", "status": "completed",
                           "conclusion": "failure", "steps": [{"name": "Report", "conclusion": "failure"}]}
        self.with_checks([{"id": 3, "name": "ci-status", "status": "completed", "conclusion": "failure",
                           "app": {"slug": "github-actions"},
                           "details_url": f"https://github.com/{REPO}/actions/runs/10/job/3"}])

    def test_a_red_ci_status_is_judged_by_the_failed_jobs_of_its_run(self):
        # ci.yml's ci-status needs `macos`, a called workflow: its jobs are 'macos / <job>'.
        for job_id in (1, 2):
            self.gh.jobs[job_id]["name"] = f"macos / {SWIFT}"
        self.red_ci_status()
        lines = excuse.judge(REPO, "feat-cmux-next", HEAD, [], self.gh, checks=["ci-status"])
        self.assertIn(f"macos / {SWIFT}", "\n".join(lines))
        self.assertNotIn("'ci-status'", "\n".join(lines))

    def test_a_red_ci_status_whose_failed_jobs_are_all_outside_its_needs_blocks(self):
        # The run's only red job is not under ci-status's needs (ci.yml's pr-red-checks, say), so it did not turn
        # ci-status red: its own verdict did. A base-red job outside it must not carry it.
        self.red_ci_status()
        with self.assertRaisesRegex(excuse.Refused, "no failed job under its needs"):
            excuse.judge(REPO, "feat-cmux-next", HEAD, [], self.gh, checks=["ci-status"])
        with self.assertRaisesRegex(excuse.Refused, "no failed job under its needs"):
            excuse.judge(REPO, "feat-cmux-next", HEAD, [10], self.gh)

    def test_a_red_ci_status_with_no_other_failed_job_blocks(self):
        self.gh.jobs[1]["conclusion"] = "success"
        self.gh.jobs[3] = {"id": 3, "run_id": 10, "head_sha": HEAD, "name": "ci-status", "status": "completed",
                           "conclusion": "failure", "steps": [{"name": "Report", "conclusion": "failure"}]}
        self.with_checks([{"id": 3, "name": "ci-status", "status": "completed", "conclusion": "failure",
                           "app": {"slug": "github-actions"},
                           "details_url": f"https://github.com/{REPO}/actions/runs/10/job/3"}])
        with self.assertRaisesRegex(excuse.Refused, "no failed job"):
            excuse.judge(REPO, "feat-cmux-next", HEAD, [], self.gh, checks=["ci-status"])

    def test_a_guard_status_is_judged_by_its_routed_child(self):
        name = "nightly-guards / Guard status"
        head = failed_job(3, 10, HEAD, name=name, step="Check routed guard jobs")
        base = failed_job(4, 20, BASE_SHA, name=name, step="Check routed guard jobs")
        base["steps"].append({"name": "Report routed guard jobs", "conclusion": "failure"})
        self.gh.jobs = {3: head, 4: base}
        self.gh.logs = {
            3: log(name, "Check routed guard jobs", "workflow-guard-tests: failure (route linux_guard_tests=true)"),
            4: log(name, "Check routed guard jobs", "workflow-guard-tests: failure (route linux_guard_tests=true)", "Report routed guard jobs"),
        }
        self.with_checks([{"id": 3, "name": name, "status": "completed", "conclusion": "failure",
                           "app": {"slug": "github-actions"},
                           "details_url": f"https://github.com/{REPO}/actions/runs/10/job/3"}])
        child_name = "nightly-guards / workflow-guard-tests / release-notary"
        step = "Test What's New highlights and release notes"
        self.gh.jobs[5] = failed_job(5, 10, HEAD, name=child_name, step=step)
        self.gh.jobs[6] = failed_job(6, 20, BASE_SHA, name=child_name, step=step)
        self.gh.logs[5] = log(child_name, step, "error: missing release note")
        self.gh.logs[6] = log(child_name, step, "error: missing release note")
        lines = excuse.judge(REPO, "feat-cmux-next", HEAD, [], self.gh, checks=[name])
        self.assertIn("release-notary", "\n".join(lines))

    def test_a_failed_guard_check_must_still_have_a_failed_aggregate_job(self):
        # The check-run metadata can remain failed after its Actions job is
        # replaced or retried.  Do not rescan the run and excuse its children
        # when the exact aggregate job endpoint is now green.
        self.test_a_guard_status_is_judged_by_its_routed_child()
        self.gh.jobs[3]["conclusion"] = "success"
        with self.assertRaisesRegex(excuse.Refused, "aggregate job"):
            excuse.judge(REPO, "feat-cmux-next", HEAD, [], self.gh,
                         checks=["nightly-guards / Guard status"])

    def runner_preamble(self, name):
        """The lines the runner writes before a called workflow's job starts (cmux#28099's Guard status log)."""
        return log(name, "Set up job", "##[group]GITHUB_TOKEN Permissions", "Contents: read", "##[endgroup]",
                   "Uses: manaflow-ai/cmux/.github/workflows/ci-guards.yml@refs/pull/28099/merge", "##[group] Inputs",
                   "  linux_guard_tests: true", '  linux_guard_test_groups: ["release-notary"]',
                   "  linux_guard_history: false", "  linux_guard_cli: false", "  linux_guard_source: false",
                   "##[endgroup]", f"Complete job name: {name}") + "\n"

    def test_a_called_workflows_echoed_inputs_are_not_route_reports(self):
        # cmux#28099 at 0080692 (run 41072552965): the echoed `linux_guard_tests: true` input was read as a route
        # report and refused the Guard status, whose only failed child is release-notary, red the same way on the base.
        self.test_a_guard_status_is_judged_by_its_routed_child()
        name = "nightly-guards / Guard status"
        for job_id in (3, 4):
            self.gh.logs[job_id] = self.runner_preamble(name) + self.gh.logs[job_id]
        self.assertIn("release-notary", "\n".join(self.judge_guard()))

    def test_a_route_report_after_the_preamble_is_still_judged(self):
        self.test_a_called_workflows_echoed_inputs_are_not_route_reports()
        self.gh.logs[3] += "\n" + log("nightly-guards / Guard status", "Check routed guard jobs",
                                      "workflow-guard-source-lints: skipped (route linux_guard_source=true)")
        with self.assertRaisesRegex(excuse.Refused, "skipped"):
            self.judge_guard()

    def judge_guard(self):
        return excuse.judge(REPO, "feat-cmux-next", HEAD, [], self.gh, checks=["nightly-guards / Guard status"])

    def test_guard_route_job_must_match_the_reported_route_input(self):
        # ci-guards.yml maps linux_guard_tests -> workflow-guard-tests and
        # linux_guard_source -> workflow-guard-source-lints.  A mismatched
        # suffix must not let a base-red child hide a routing failure.
        self.test_a_guard_status_is_judged_by_its_routed_child()
        name = "nightly-guards / Guard status"
        self.gh.logs[3] = log(name, "Check routed guard jobs",
                              "workflow-guard-tests: failure (route linux_guard_source=true)")
        with self.assertRaisesRegex(excuse.Refused, "does not map"):
            excuse.judge(REPO, "feat-cmux-next", HEAD, [], self.gh, checks=[name])

    def test_guard_invalid_route_with_base_red_child_is_not_excused(self):
        self.test_a_guard_status_is_judged_by_its_routed_child()
        self.gh.logs[3] += "\n" + log("nightly-guards / Guard status", "Check routed guard jobs",
                                      "linux_guard_source: invalid route linux_guard_source='bogus'")
        with self.assertRaisesRegex(excuse.Refused, "invalid route"):
            self.judge()

    def test_guard_required_skipped_route_with_base_red_child_is_not_excused(self):
        self.test_a_guard_status_is_judged_by_its_routed_child()
        self.gh.logs[3] += "\n" + log("nightly-guards / Guard status", "Check routed guard jobs",
                                      "workflow-guard-source-lints: skipped (route linux_guard_source=true)")
        with self.assertRaisesRegex(excuse.Refused, "skipped"):
            self.judge()

    def test_guard_unexplained_failed_route_with_base_red_child_is_not_excused(self):
        self.test_a_guard_status_is_judged_by_its_routed_child()
        self.gh.logs[3] += "\n" + log("nightly-guards / Guard status", "Check routed guard jobs",
                                      "workflow-guard-source-lints: failure (route linux_guard_source=true)")
        with self.assertRaisesRegex(excuse.Refused, "no failed child"):
            self.judge()

    def test_guard_runtime_error_with_base_red_child_is_not_excused(self):
        self.test_a_guard_status_is_judged_by_its_routed_child()
        self.gh.logs[3] += "\n" + log("nightly-guards / Guard status", "Check routed guard jobs",
                                      "##[error]guard routing failed to parse")
        with self.assertRaisesRegex(excuse.Refused, "routing failed"):
            self.judge()

    def test_guard_missing_route_report_with_base_red_child_is_not_excused(self):
        self.test_a_guard_status_is_judged_by_its_routed_child()
        self.gh.logs[3] = log("nightly-guards / Guard status", "Check routed guard jobs",
                              "##[error]Process completed with exit code 1.")
        with self.assertRaisesRegex(excuse.Refused, "no routed failure"):
            self.judge()

    def test_guard_child_new_step_is_not_excused(self):
        self.test_a_guard_status_is_judged_by_its_routed_child()
        self.gh.jobs[5]["steps"][-1]["name"] = "New source lint"
        with self.assertRaisesRegex(excuse.Refused, "New source lint"):
            self.judge()

    def test_guard_child_new_error_is_not_excused(self):
        self.test_a_guard_status_is_judged_by_its_routed_child()
        self.gh.logs[5] = "error: new source lint violation"
        with self.assertRaisesRegex(excuse.Refused, "new source lint violation"):
            self.judge()

    def test_guard_child_new_job_is_not_excused(self):
        self.test_a_guard_status_is_judged_by_its_routed_child()
        self.gh.jobs[5]["name"] = "nightly-guards / workflow-guard-source-lints / lint"
        with self.assertRaisesRegex(excuse.Refused, "no failed child"):
            self.judge()

    def test_newest_red_base_job_wins_over_older_green(self):
        self.test_a_guard_status_is_judged_by_its_routed_child()
        older = copy.deepcopy(self.gh.jobs[6])
        older.update(id=7, run_id=19, conclusion="success")
        older["steps"][-1]["conclusion"] = "success"
        self.gh.jobs[7] = older
        self.gh.base_runs.append({"id": 19, "event": "push", "conclusion": "success"})
        self.assertIn("run 20", "\n".join(self.judge()))

    def contract_with(self, edit):
        contract = copy.deepcopy(excuse.rollups())
        edit(contract["routed"]["Guard status"]["routes"])
        patch = unittest.mock.patch.object(excuse, "_ROLLUPS", contract)
        patch.start()
        self.addCleanup(patch.stop)

    def test_a_route_the_workflow_adds_is_judged_from_the_contract(self):
        # A needed job the workflow adds (here workflow-guard-new on linux_guard_new) is read from the contract,
        # with no list in this script to update.
        self.test_a_guard_status_is_judged_by_its_routed_child()
        self.contract_with(lambda routes: routes.update(
            {"workflow-guard-new": {"route": "linux_guard_new", "exact": [], "prefixes": ["workflow-guard-new / "]}}))
        name = "nightly-guards / Guard status"
        for job_id, child in ((5, 3), (6, 4)):
            self.gh.jobs[job_id]["name"] = "nightly-guards / workflow-guard-new / lint"
            self.gh.logs[child] = log(name, "Check routed guard jobs", "workflow-guard-new: failure (route linux_guard_new=true)")
        self.assertIn("workflow-guard-new / lint", "\n".join(self.judge_guard()))

    def test_a_route_job_the_contract_does_not_name_is_refused(self):
        self.test_a_guard_status_is_judged_by_its_routed_child()
        self.contract_with(lambda routes: routes.pop("workflow-guard-tests"))
        with self.assertRaisesRegex(excuse.Refused, "unknown routed job workflow-guard-tests"):
            self.judge_guard()

    def test_an_unconditional_job_reported_with_a_route_is_refused(self):
        # workflow-guard-submodule-forward-only has no `if:`: its report never names a route.
        self.test_a_guard_status_is_judged_by_its_routed_child()
        name = "nightly-guards / Guard status"
        self.gh.jobs[5]["name"] = self.gh.jobs[6]["name"] = "nightly-guards / workflow-guard-submodule-forward-only"
        self.gh.logs[3] = log(name, "Check routed guard jobs",
                              "workflow-guard-submodule-forward-only: failure (route linux_guard_tests=true)")
        with self.assertRaisesRegex(excuse.Refused, "does not map"):
            self.judge_guard()

    def test_a_guard_status_does_not_match_an_unrelated_routed_job(self):
        name = "nightly-guards / Guard status"
        head = failed_job(3, 10, HEAD, name=name, step="Check routed guard jobs")
        base = failed_job(4, 20, BASE_SHA, name=name, step="Check routed guard jobs")
        self.gh.jobs = {3: head, 4: base}
        self.gh.logs = {
            3: log(name, "Check routed guard jobs", "workflow-guard-source-lints: failure (route linux_guard_source=true)"),
            4: log(name, "Check routed guard jobs", "workflow-guard-tests: failure (route linux_guard_tests=true)"),
        }
        self.with_checks([{"id": 3, "name": name, "status": "completed", "conclusion": "failure",
                           "app": {"slug": "github-actions"},
                           "details_url": f"https://github.com/{REPO}/actions/runs/10/job/3"}])
        with self.assertRaisesRegex(excuse.Refused, "no failed job"):
            excuse.judge(REPO, "feat-cmux-next", HEAD, [], self.gh, checks=[name])


def crashed(job, signal, unfinished, frames, *extra):
    """A swift test log whose test helper died on `signal` with `unfinished` tests in flight."""
    return log(job, TEST_STEP, *extra,
               f"error: Process '/x/swiftpm-testing-helper --test-bundle-path /x/CmuxNextPackageTests' "
               f"exited with unexpected signal code {signal}",
               f"##[error]no \"Test run with\" summary line (crash, kill or truncation); {len(unfinished)} tests "
               f"started and never finished: {'; '.join(unfinished)}",
               f"##[error]the test helper died on signal {signal}; crashed thread: {frames}")


CI_YML = """
on: {pull_request: {}}
jobs:
  changes: {runs-on: x, steps: []}
  web: {needs: [changes], uses: ./.github/workflows/ci-web.yml}
  fast-guards: {name: CI fast guards, runs-on: x, steps: []}
  outside: {needs: [web], runs-on: x, steps: []}
  ci-status: {needs: [web, fast-guards], runs-on: x, steps: []}
"""
GUARDS_YML = """
on:
  workflow_call:
    inputs:
      linux_guard_tests: {type: string}
jobs:
  workflow-guard-submodule-forward-only: {name: workflow-guard-submodule-forward-only, runs-on: x, steps: []}
  workflow-guard-tests:
    if: ${{ inputs.linux_guard_tests == 'true' }}
    name: workflow-guard-tests / ${{ matrix.group }}
    strategy: {matrix: {group: [a]}}
    runs-on: x
    steps: []
  guard-status:
    name: Guard status
    needs: [workflow-guard-submodule-forward-only, workflow-guard-tests]
    runs-on: x
    steps: []
"""


class RollupsFromNeeds(unittest.TestCase):
    """The rollups (ci-status, Guard status) and the jobs under them come from the workflows' `needs:`."""

    def derive(self, ci=CI_YML, guards=GUARDS_YML):
        with tempfile.TemporaryDirectory() as root:
            for file, text in (("ci.yml", ci), ("ci-guards.yml", guards)):
                if text is not None:
                    (Path(root) / file).write_text(text)
            return excuse.derive_rollups(Path(root))

    def test_the_committed_contract_is_the_workflows(self):
        import yaml  # noqa: F401,PLC0415 - deriving reads YAML; a host without it must not pass this silently
        self.assertEqual(json.loads(excuse.ROLLUPS_FILE.read_text()), excuse.derive_rollups(),
                         "run: python3 scripts/ci/base_red_excuse.py --write-rollups")

    def test_needs_are_followed_and_named_as_actions_names_them(self):
        got = self.derive()
        self.assertEqual(got["run"]["ci-status"]["under"], {
            "changes": {"exact": ["changes"], "prefixes": []},
            "fast-guards": {"exact": ["CI fast guards"], "prefixes": []},
            "web": {"exact": [], "prefixes": ["web / "]}})
        self.assertEqual(got["routed"]["Guard status"]["routes"], {
            "workflow-guard-submodule-forward-only": {
                "route": None, "exact": ["workflow-guard-submodule-forward-only"], "prefixes": []},
            "workflow-guard-tests": {"route": "linux_guard_tests", "exact": [], "prefixes": ["workflow-guard-tests / "]}})

    def test_any_shape_it_does_not_know_is_refused(self):
        tests_if = "if: ${{ inputs.linux_guard_tests == 'true' }}"
        cases = {
            "a missing workflow": (dict(ci=None), "unreadable"),
            "a missing rollup job": (dict(ci=CI_YML.replace("ci-status:", "ci-verdict:")), "no job ci-status"),
            "an unknown need": (dict(ci=CI_YML.replace("needs: [web, fast-guards]", "needs: [web, nope]")),
                                "not jobs of its workflow"),
            "needs that are not a list": (dict(ci=CI_YML.replace("needs: [web, fast-guards]", "needs: {web: 1}")),
                                          "not jobs of its workflow"),
            "a rollup with no needs": (dict(ci=CI_YML.replace("needs: [web, fast-guards], ", "")), "needs no job"),
            "a name with an expression inside": (dict(
                ci=CI_YML.replace("name: CI fast guards", 'name: "CI ${{ matrix.x }} guards"')), "not a fixed name"),
            "an expression before the last part": (dict(guards=GUARDS_YML.replace(
                "workflow-guard-tests / ${{ matrix.group }}", '"workflow-guard-tests / ${{ matrix.group }} / x"')),
                "not a fixed name"),
            "a route if of another shape": (dict(guards=GUARDS_YML.replace(
                tests_if, "if: ${{ inputs.linux_guard_tests == 'true' || github.event_name == 'push' }}")),
                "not one route input"),
            "a route input not declared": (dict(guards=GUARDS_YML.replace(
                tests_if, "if: ${{ inputs.linux_guard_other == 'true' }}")), "not one route input"),
            "a routed workflow with another trigger": (dict(
                guards=GUARDS_YML.replace("on:\n", "on:\n  push: {}\n")), "called only"),
            "unparseable YAML": (dict(guards=GUARDS_YML + "\n  : [\n"), "unreadable"),
        }
        for why, (files, said) in cases.items():
            with self.subTest(why), self.assertRaisesRegex(excuse.Refused, said):
                self.derive(**files)

    def test_a_missing_or_malformed_contract_refuses_every_rollup(self):
        for text in (None, "{", "[]", '{"run": {}, "routed": {}}',
                     '{"run": {"ci-status": {"under": {"x": {"exact": "x", "prefixes": []}}}}, "routed": {}}'):
            with self.subTest(text=text), tempfile.TemporaryDirectory() as root:
                path = Path(root) / "rollups.json"
                if text is not None:
                    path.write_text(text)
                with unittest.mock.patch.object(excuse, "ROLLUPS_FILE", path), \
                        unittest.mock.patch.object(excuse, "_ROLLUPS", None), \
                        self.assertRaisesRegex(excuse.Refused, "no rollup red is excused"):
                    excuse.is_aggregate("ci-status")


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


class EchoedStepScriptIsNoEvidence(unittest.TestCase):
    """The runner echoes each step's script before it runs, so the script's own text (an `echo "::error::..."`
    branch, a grep for test names) is in every run's log. 2026-10-30: cmux#28145's kit job at c39d28ef failed two
    iOS simulator tests that base run 41138142557 passed, and was excused because both logs echo the same
    `::error::` lines of the xcodebuild step's script."""

    KIT = "CmuxMobileKit tests (macOS swift test, iOS simulator)"
    STEP = "xcodebuild test (iOS simulator)"
    FIXTURES = ROOT / "tests/fixtures/test_reds"

    def setUp(self):
        self.gh = FakeGitHub()
        self.gh.jobs = {1: failed_job(1, 10, HEAD, self.KIT, self.STEP),
                        2: failed_job(2, 20, BASE_SHA, self.KIT, self.STEP)}
        self.gh.logs = {1: (self.FIXTURES / "ios-kit-head-run-41079430021.log").read_text(),
                        2: (self.FIXTURES / "ios-kit-base-run-41138142557.log").read_text()}

    def test_the_28145_kit_red_is_not_excused_by_the_echoed_script(self):
        with self.assertRaisesRegex(excuse.Refused, "HomeRetryTests.failedHomeLoadRetriesTheFeedOnTheExistingLink"):
            excuse.judge(REPO, "feat-cmux-next", HEAD, [10], self.gh)

    def test_echoed_script_lines_are_not_error_lines(self):
        _, tests, errors = excuse.signature(self.gh.jobs[2], self.gh.logs[2])
        self.assertEqual(tests, {"TerminalSurfaceFramePacingTests.busyOutputDrawsAtMostOneFramePerDisplayRefresh()"})
        self.assertEqual(errors, set(), "every `::error::` in this log is the step script's echo")

    def test_an_error_only_the_echo_names_cannot_excuse_a_head_error(self):
        echo = ["##[group]Run make", 'echo "::error::Python is required"', "shell: /bin/bash -e {0}", "##[endgroup]"]
        name = "cmux-next fast tier"
        self.gh.jobs = {1: failed_job(1, 10, HEAD, name, "Install"), 2: failed_job(2, 20, BASE_SHA, name, "Install")}
        self.gh.logs[1] = log(name, "Install", *echo, "##[error]Python is required")
        self.gh.logs[2] = log(name, "Install", *echo, "##[error]Could not find a version for foo")
        with self.assertRaisesRegex(excuse.Refused, "errors not on feat-cmux-next run 20: Python is required"):
            excuse.judge(REPO, "feat-cmux-next", HEAD, [10], self.gh)

    def test_successful_ok_diagnostic_wrapper_is_not_an_error(self):
        successful = "ok: cmux Computer Use.app validation (error: expected nested helper diagnostic)"
        self.gh.logs[2] = log(self.KIT, self.STEP, successful)
        _, tests, errors = excuse.signature(self.gh.jobs[2], self.gh.logs[2])
        self.assertEqual(tests, set())
        self.assertEqual(errors, set())

    def test_error_outside_ok_wrapper_remains_evidence(self):
        self.gh.logs[2] = log(self.KIT, self.STEP,
                              "error: cmux Computer Use.app validation failed")
        _, tests, errors = excuse.signature(self.gh.jobs[2], self.gh.logs[2])
        self.assertEqual(tests, set())
        self.assertEqual(errors, {"error: cmux Computer Use.app validation failed"})


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


CLIPPY = "clippy (changed cmux-tui packages)"
RATCHET_STEP = "Rust panic ratchet on changed cmux-tui packages"


def ratchet_log(scope, *rows, other=()):
    """A panic ratchet step's log, shaped like run 41176610742's (cmux#26849): each ROWS entry is
    (crate, lint, count, where) with two hit locations under it; OTHER lines are the ratchet's other failures."""
    lines = [f"cmux-tui-clippy-changed: panic ratchet on {scope}",
             "##[warning]acpmux: clippy::arithmetic_side_effects 1496 > baseline 1430",
             "rust-panic-ratchet: 50 crates checked, 17 at deny", "rust-panic-ratchet: RED"]
    for crate, lint, count, where in rows:
        lines += [f"  {crate}: clippy::{lint} {count} > {where}",
                  f"      crates/{crate}/src/lib.rs:{count}:9", f"      crates/{crate}/src/main.rs:{count + 1}:13"]
    lines += [f"  {line}" for line in other]
    lines += ["Fix the hit (a typed error handled at a boundary), or put a reviewed",
              '#[allow(clippy::<lint>, reason = "...")] on the smallest item. Never raise the baseline.',
              f"##[error]the panic ratchet is red for {scope}; its log above names each new hit "
              "(plans/cmux-next/rust-panic-free.md)",
              "##[error]Process completed with exit code 1."]
    return log(CLIPPY, RATCHET_STEP, *lines)


HEAD_ROWS = (("acpmux", "indexing_slicing", 692, "baseline 686"), ("cmux-tui", "indexing_slicing", 836, "baseline 831"))
RD_LINK = ("cmux-rd-link", "indexing_slicing", 7, "new crate (must be 0)")
CHANGED = "cmux-remote, cmux-terminal-client, cmux-tui, cmux-tui-core"
WHOLE = "the whole cmux-tui workspace"


class PanicRatchet(unittest.TestCase):
    """The ratchet's error line names the packages a run checked, and a base run can check the whole workspace
    while a PR's checks only its changed packages: its red is compared by its per-lint rows instead (cmux#26849's
    run 41176610742 was refused against base run 41176544319, which failed on the same two rows and one more)."""

    def setUp(self):
        self.gh = FakeGitHub()
        self.gh.jobs = {1: failed_job(1, 10, HEAD, CLIPPY, RATCHET_STEP),
                        2: failed_job(2, 20, BASE_SHA, CLIPPY, RATCHET_STEP)}
        self.gh.logs[1] = ratchet_log(CHANGED, *HEAD_ROWS)
        self.gh.logs[2] = ratchet_log(WHOLE, HEAD_ROWS[0], RD_LINK, HEAD_ROWS[1])

    def judge(self):
        return "\n".join(excuse.judge(REPO, "feat-cmux-next", HEAD, [10], self.gh))

    def test_rows_all_on_a_whole_workspace_base_run_are_excused(self):
        text = self.judge()
        self.assertIn(f"excused '{CLIPPY}'", text)
        self.assertIn("acpmux: clippy::indexing_slicing 692 > baseline 686", text)

    def test_a_base_count_above_the_heads_still_covers_it(self):
        self.gh.logs[1] = ratchet_log(CHANGED, ("acpmux", "indexing_slicing", 690, "baseline 686"), HEAD_ROWS[1])
        self.assertIn(f"excused '{CLIPPY}'", self.judge())

    def test_a_head_count_above_the_bases_blocks(self):
        self.gh.logs[1] = ratchet_log(CHANGED, ("acpmux", "indexing_slicing", 693, "baseline 686"), HEAD_ROWS[1])
        with self.assertRaisesRegex(excuse.Refused, "acpmux: clippy::indexing_slicing 693 > baseline 686"):
            self.judge()

    def test_a_head_count_above_the_bases_blocks_with_the_same_scope_too(self):
        self.gh.logs[1] = ratchet_log(WHOLE, ("acpmux", "indexing_slicing", 693, "baseline 686"), RD_LINK, HEAD_ROWS[1])
        with self.assertRaisesRegex(excuse.Refused, "693 > baseline 686"):
            self.judge()

    def test_a_row_not_on_the_base_blocks(self):
        self.gh.logs[1] = ratchet_log(CHANGED, *HEAD_ROWS, ("cmux-wg", "indexing_slicing", 3, "baseline 1"))
        with self.assertRaisesRegex(excuse.Refused, "cmux-wg: clippy::indexing_slicing 3 > baseline 1"):
            self.judge()

    def test_a_row_of_another_lint_blocks(self):
        self.gh.logs[1] = ratchet_log(CHANGED, HEAD_ROWS[0], ("cmux-tui", "unwrap_used", 836, "baseline 831"))
        with self.assertRaisesRegex(excuse.Refused, "unwrap_used"):
            self.judge()

    def test_a_different_baseline_blocks(self):
        # The PR raised (or set) the row's baseline: base's row is not the same red.
        self.gh.logs[1] = ratchet_log(CHANGED, ("acpmux", "indexing_slicing", 692, "baseline 680"), HEAD_ROWS[1])
        with self.assertRaisesRegex(excuse.Refused, "692 > baseline 680"):
            self.judge()

    def test_another_ratchet_failure_not_on_the_base_blocks(self):
        reason = 'crates/acpmux/src/lib.rs:12: allow(indexing_slicing) needs reason = "..."'
        self.gh.logs[1] = ratchet_log(CHANGED, *HEAD_ROWS, other=[reason])
        with self.assertRaisesRegex(excuse.Refused, "needs reason"):
            self.judge()
        self.gh.logs[2] = ratchet_log(WHOLE, HEAD_ROWS[0], RD_LINK, HEAD_ROWS[1], other=[reason])
        self.assertIn(f"excused '{CLIPPY}'", self.judge())

    def test_a_ratchet_red_with_no_rows_blocks(self):
        # The ratchet refuses a clippy run that did not finish: nothing in it can be compared.
        self.gh.logs[1] = log(CLIPPY, RATCHET_STEP,
                              "rust-panic-ratchet: the clippy run did not finish successfully (no build-finished "
                              "success line); counts from a partial build prove nothing",
                              f"##[error]the panic ratchet is red for {WHOLE}; its log above names each new hit "
                              "(plans/cmux-next/rust-panic-free.md)")
        self.gh.logs[2] = self.gh.logs[1]
        with self.assertRaisesRegex(excuse.Refused, "no per-lint row"):
            self.judge()

    def test_another_error_beside_the_ratchet_is_still_compared(self):
        self.gh.logs[1] += "\n" + log(CLIPPY, RATCHET_STEP, "error: could not compile `acpmux`")
        with self.assertRaisesRegex(excuse.Refused, "could not compile"):
            self.judge()


GUARD = "nightly-guards / workflow-guard-tests / release-notary"
GUARD_STEP = "Validate the car guards"
MERGE_BASE = "c" * 40
CAR_TEST = "test_cmux_next_follows_the_committed_target_graph"


def guard_log(*tests, file="tests/test_car_guards.py", exit_line=True):
    """A unittest step's log: its echo, one FAIL block per test with its traceback, the summary and exit."""
    lines = [f"##[group]Run python3 {file}", f"python3 {file}", "shell: /usr/bin/bash -e {0}", "##[endgroup]"]
    for test in tests:
        lines += ["=" * 70, f"FAIL: {test} (__main__.FocusedTests.{test})", "-" * 70,
                  "Traceback (most recent call last):",
                  f'  File "/home/runner/work/cmux/cmux/{file}", line 160, in {test}',
                  "    self.assertEqual(", "AssertionError: Lists differ"]
    lines += ["-" * 70, "Ran 40 tests in 1.204s", "", f"FAILED (failures={len(tests)})"]
    if exit_line:
        lines.append("##[error]Process completed with exit code 1.")
    return log(GUARD, GUARD_STEP, *lines)


class FixedOnBaseGitHub(FakeGitHub):
    """The head's guard job red; the newest base run (20, at BASE_SHA, after the merge-base) passes it."""

    def __init__(self, changed=("Sources/App/Feature.swift",), status="ahead"):
        super().__init__()
        self.jobs = {1: failed_job(1, 10, HEAD, name=GUARD, step=GUARD_STEP),
                     2: dict(failed_job(2, 20, BASE_SHA, name=GUARD, step=GUARD_STEP), conclusion="success")}
        self.logs = {1: guard_log(CAR_TEST), 2: ""}
        self.changed = list(changed)
        self.status = status

    def json(self, route, *, paginate=False):
        if f"/compare/feat-cmux-next...{HEAD}" in route:
            self.routes.append(route)
            return {"merge_base_commit": {"sha": MERGE_BASE}, "files": [{"filename": f} for f in self.changed]}
        if f"/compare/{MERGE_BASE}...{BASE_SHA}" in route:
            self.routes.append(route)
            return {"status": self.status}
        return super().json(route, paginate=paginate)


class FixedOnBase(unittest.TestCase):
    """A guard test red on a head whose merge-base predates the base fix (#27584, #27918, #27905, #27775)."""

    def judge(self, github):
        return "\n".join(excuse.judge(REPO, "feat-cmux-next", HEAD, [10], github))

    def test_a_guard_test_that_passes_on_the_newest_base_is_excused_as_fixed_on_base(self):
        text = self.judge(FixedOnBaseGitHub())
        self.assertIn(f"excused '{GUARD}': fixed on base (passes at {BASE_SHA[:12]}", text)
        self.assertIn("PR does not touch tests/test_car_guards.py, .github/, scripts/, tests/", text)
        self.assertIn(CAR_TEST, text)

    def test_a_pr_that_touches_the_test_file_is_not_excused(self):
        with self.assertRaisesRegex(excuse.Refused, "not fixed on base: .*tests/test_car_guards.py"):
            self.judge(FixedOnBaseGitHub(changed=("tests/test_car_guards.py",)))

    def test_a_pr_that_touches_the_default_guard_paths_is_not_excused(self):
        for path in (".github/workflows/ci.yml", "scripts/ci/car_guards.py", "tests/other.py", "package.json",
                     "release-notes/next/kill-switches.json", "homebrew-cmux/cmux.rb"):
            with self.subTest(path=path), self.assertRaisesRegex(excuse.Refused, "reads paths the PR changes"):
                self.judge(FixedOnBaseGitHub(changed=(path,)))

    def test_a_pr_that_touches_a_declared_read_path_is_not_excused(self):
        # test_car_guards reads the CmuxNext target graph; the default set alone would miss it.
        with self.assertRaisesRegex(excuse.Refused, "Packages/macOS/CmuxNext/Package.swift"):
            self.judge(FixedOnBaseGitHub(changed=("Packages/macOS/CmuxNext/Package.swift",)))

    def test_an_undeclared_guard_test_is_never_fixed_on_base(self):
        # tests/test_docs_deploy_auth_guard.py reads web/vercel.docs-channel.json: an undeclared test may read anything.
        github = FixedOnBaseGitHub(changed=("web/vercel.docs-channel.json",))
        github.logs[1] = guard_log("test_docs_channel", file="tests/test_docs_deploy_auth_guard.py")
        with self.assertRaisesRegex(excuse.Refused, "test_docs_deploy_auth_guard.py declares no read paths"):
            self.judge(github)

    def test_a_base_pass_not_after_the_merge_base_is_not_excused(self):
        for status in ("identical", "behind", "diverged"):
            with self.subTest(status=status), self.assertRaisesRegex(excuse.Refused, "not after the merge-base"):
                self.judge(FixedOnBaseGitHub(status=status))

    def test_a_crash_is_never_fixed_on_base(self):
        github = FixedOnBaseGitHub()
        github.logs[1] = guard_log(CAR_TEST, exit_line=False) + "\n" + log(
            GUARD, GUARD_STEP, "##[error]Process completed with exit code 134.")
        with self.assertRaisesRegex(excuse.Refused, "crash"):
            self.judge(github)

    def test_a_cut_short_run_is_never_fixed_on_base(self):
        github = FixedOnBaseGitHub()
        github.logs[1] = log(GUARD, GUARD_STEP, "##[group]Run python3 tests/test_car_guards.py",
                             "python3 tests/test_car_guards.py", "shell: /usr/bin/bash -e {0}", "##[endgroup]",
                             f"FAIL: {CAR_TEST} (__main__.FocusedTests.{CAR_TEST})",
                             f'  File "/w/tests/test_car_guards.py", line 160, in {CAR_TEST}',
                             f"{CAR_TEST} (__main__.FocusedTests.{CAR_TEST}) ... ok",
                             "##[error]Process completed with exit code 1.")
        with self.assertRaisesRegex(excuse.Refused, "never a base red"):
            self.judge(github)
        self.assertFalse([route for route in github.routes if "/compare/" in route])

    def test_a_failed_step_with_no_guard_test_is_not_excused(self):
        github = FixedOnBaseGitHub()
        github.logs[1] += "\n" + log(GUARD, "Validate create-dmg", "##[group]Run ./tests/test_ci_create_dmg_pinned.sh",
                                     "./tests/test_ci_create_dmg_pinned.sh", "shell: /usr/bin/bash -e {0}",
                                     "##[endgroup]", "create-dmg is not pinned",
                                     "##[error]Process completed with exit code 1.")
        with self.assertRaisesRegex(excuse.Refused, "names no failing test"):
            self.judge(github)

    def test_a_non_guard_test_job_is_never_fixed_on_base(self):
        # A Swift test reads product code: a pass on the base proves only that the head broke it.
        github = FakeGitHub()
        github.jobs[2]["conclusion"] = "success"
        with self.assertRaisesRegex(excuse.Refused, "not a declared guard job"):
            excuse.judge(REPO, "feat-cmux-next", HEAD, [10], github)
        self.assertFalse([route for route in github.routes if "/compare/" in route])

    def test_a_guard_test_line_printed_by_another_job_is_never_fixed_on_base(self):
        github = FixedOnBaseGitHub()
        for job in github.jobs.values():
            job["name"] = SWIFT
        github.logs[1] = github.logs[1].replace(GUARD, SWIFT)
        with self.assertRaisesRegex(excuse.Refused, "not a declared guard job"):
            self.judge(github)

    def test_a_step_that_does_not_run_the_test_file_is_not_excused(self):
        github = FixedOnBaseGitHub()
        github.logs[1] = github.logs[1].replace("python3 tests/test_car_guards.py", "./build.sh")
        with self.assertRaisesRegex(excuse.Refused, "script does not run tests/test_car_guards.py"):
            self.judge(github)

    def test_a_pytest_line_with_no_test_run_is_not_excused(self):
        github = FixedOnBaseGitHub()
        github.logs[1] = log(GUARD, GUARD_STEP, "##[group]Run python3 tests/test_car_guards.py",
                             "python3 tests/test_car_guards.py", "shell: /usr/bin/bash -e {0}", "##[endgroup]",
                             f"FAILED tests/test_car_guards.py::FocusedTests::{CAR_TEST}",
                             "##[error]Process completed with exit code 1.")
        with self.assertRaisesRegex(excuse.Refused, "printed no test-run summary"):
            self.judge(github)

    def test_the_checks_job_is_a_guard_job(self):
        self.assertTrue(excuse.guard_job("cmux-next checks (god files, concurrency, crash safety, l10n)"))
        self.assertTrue(excuse.guard_job("nightly-guards / workflow-guard-tests / release-notary"))
        self.assertFalse(excuse.guard_job("nightly-guards / workflow-guard-tests / ci"))

    def test_a_too_long_diff_is_not_excused(self):
        github = FixedOnBaseGitHub(changed=[f"Sources/App/F{n}.swift" for n in range(excuse.COMPARE_FILES_CAP)])
        with self.assertRaisesRegex(excuse.Refused, "too many"):
            self.judge(github)

    def test_the_checks_job_rollup_step_is_read_as_its_guard_tests(self):
        github = FixedOnBaseGitHub(changed=("Sources/App/Feature.swift",))
        github.logs[1] = guard_log("test_every_part_of_bun_run_check_runs_in_the_warn_branch",
                                   file="tests/test_cmux_next_checks_workflow.py") + "\n" + log(
            GUARD, "Fail on any red check", "##[group]Run failed=()", "failed=()", "shell: /usr/bin/bash -e {0}",
            "##[endgroup]", "##[error]red check: Checks job structure", "##[error]Process completed with exit code 1.")
        self.assertIn("fixed on base", self.judge(github))
        for path in ("webviews/package.json", "cmux-tui/Cargo.toml", "Native/OptChat/chief/Cargo.toml"):
            github.changed = [path]
            with self.subTest(path=path), self.assertRaisesRegex(excuse.Refused, path):
                self.judge(github)

    def test_a_rollup_naming_more_reds_than_guard_tests_is_not_excused(self):
        github = FixedOnBaseGitHub()
        github.logs[1] += "\n" + log(
            GUARD, "Fail on any red check", "##[group]Run failed=()", "failed=()", "shell: /usr/bin/bash -e {0}",
            "##[endgroup]", "##[error]red check: Checks job structure", "##[error]red check: God files",
            "##[error]Process completed with exit code 1.")
        with self.assertRaisesRegex(excuse.Refused, "rollup names 2 red checks"):
            self.judge(github)

    def test_a_pytest_id_names_its_file(self):
        self.assertEqual(excuse.guard_test_file("tests/test_x.py::Case::test_y", []), "tests/test_x.py")
        self.assertIsNone(excuse.guard_test_file("web/test_x.py::test_y", []))


class Script(unittest.TestCase):
    def test_gh_merge_green_asks_the_base_before_refusing_a_red_lane(self):
        text = (ROOT / "scripts/gh-merge-green").read_text()
        self.assertIn("base_red_excuse.py", text)
        # Lint stays unwaivable, and --override still skips the base comparison.
        self.assertIn("--override cannot bypass god-file, l10n or concurrency lint", text)


if __name__ == "__main__":
    unittest.main()
