"""gh-merge-green excuses a red check only when the base branch's latest completed run has the same failures."""
import ast
import contextlib
import copy
import re
import io
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import tomllib
import unittest
import urllib.error
import urllib.parse
import unittest.mock
from collections import Counter
import zipfile
from pathlib import Path
# tests/git_fixture_env.py, loaded by path: `python3 -I` puts no script folder on sys.path.
import importlib.util as _git_fixture_importlib  # noqa: E402
from os import path as _git_fixture_path  # noqa: E402
_git_fixture_spec = _git_fixture_importlib.spec_from_file_location(
    "git_fixture_env", _git_fixture_path.join(_git_fixture_path.dirname(_git_fixture_path.abspath(__file__)), "git_fixture_env.py"))
git_fixture_env = _git_fixture_importlib.module_from_spec(_git_fixture_spec)
_git_fixture_spec.loader.exec_module(git_fixture_env)

ROOT = Path(__file__).resolve().parents[1]
# Imported by name, never loaded by path: one module object per file, so a test that patches it
# patches what every other test reads (tests/test_script_module_loads.py).
import sys  # noqa: E402
if str(ROOT / "scripts/ci") not in sys.path:
    sys.path.insert(0, str(ROOT / "scripts/ci"))
# A host's own glaeda-gh keeps real job logs: every test reads its fakes only, unless it names a fake glaeda-gh
# (GlaedaKeptLog).
os.environ["CMUX_GLAEDA_GH"] = ""
import base_red_excuse as excuse  # noqa: E402
# Another repo's files are read with git first (excuse.git_text, a network fetch), then GraphQL. Tests read them from
# their fakes only; SourceReads runs the real git reader against a local repository.
REAL_GIT_TEXT = getattr(excuse, "git_text", None)
# The fleet's compile receipt is a network read too: tests see no receipt unless they fake one; CompileReceiptRead and
# FfiPinCompileReceipt run the real reader against a faked urlopen.
REAL_COMPILE_RECEIPT = excuse.compile_receipt
# StaleFfiPinOfAStepARustChange's setUp patches excuse.ffi_release_file; the release-file tests call the real one.
REAL_FFI_RELEASE_FILE = excuse.ffi_release_file
# HEAD below is a placeholder ("a" * 40) that the fakes answer for; the CLI refuses one unless told a fixture does.
os.environ["BASE_RED_EXCUSE_FIXTURE_SHA"] = "1"


def setUpModule():
    patch = unittest.mock.patch.object(excuse, "git_text", lambda repo, ref, path: None, create=True)
    patch.start()
    unittest.addModuleCleanup(patch.stop)
    receipt = unittest.mock.patch.object(excuse, "compile_receipt", lambda repo, sha: None)
    receipt.start()
    unittest.addModuleCleanup(receipt.stop)
    # The fakes reuse run ids with other jobs from test to test: no base job list is kept on disk unless a test asks.
    env = unittest.mock.patch.dict(os.environ, {"BASE_RED_EXCUSE_JOBS_CACHE": "off"})
    env.start()
    unittest.addModuleCleanup(env.stop)

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


def status_answer(route, statuses):
    """A commit's statuses as GitHub answers ROUTE: the statuses list (newest first, each naming who posted it; the
    one compile status poster unless a status names another) or the combined status (no creator)."""
    statuses = copy.deepcopy(statuses)
    if "/statuses" in route:
        if not route.endswith("&page=1"):  # one page here: every later page is empty
            return []
        return [{"creator": dict(excuse.COMPILE_STATUS_POSTER), **status} for status in statuses]
    return {"statuses": [{key: value for key, value in status.items() if key != "creator"} for status in statuses]}


def failed_job(job_id, run_id, sha, name=SWIFT, step=TEST_STEP):
    return {"id": job_id, "run_id": run_id, "head_sha": sha, "name": name, "status": "completed",
            "conclusion": "failure", "steps": [
                {"name": "Set up runner", "status": "completed", "conclusion": "success"},
                {"name": "Build package and tests", "status": "completed", "conclusion": "success"},
                {"name": step, "status": "completed", "conclusion": "failure"}]}


class CrashClassRuleSignature(unittest.TestCase):
    OBJC = ("objc-selectors: Sources/A.swift:12: super.viewDidMove (NSView call:viewDidMove/0): probe needed; "
            "run scripts/cmux-next/check-objc-selectors.py --probe --write on a Mac and commit t.json")

    def test_an_objc_selectors_line_is_a_named_failure_not_an_unmatchable_job(self):
        job = failed_job(1, 10, HEAD, "crash-class selectors", "Run the selector check")
        _, tests, _ = placed_signature(job, log(1, "Run the selector check", self.OBJC))
        _, other, _ = placed_signature(job, log(1, "Run the selector check", self.OBJC.replace(":12:", ":13:")))
        self.assertEqual(tests, {"objc-selectors Sources/A.swift:12 super.viewDidMove (NSView call:viewDidMove/0)"})
        self.assertNotEqual(tests, other)


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
        if f"/compare/feat-cmux-next...{HEAD}" in route:
            # The base runs here test the merge-base itself unless a test says otherwise (before_merge_base).
            return {"merge_base_commit": {"sha": BASE_SHA}, "files": []}
        if f"/compare/{BASE_SHA}..." in route:
            # Any other base commit a test names is newer than that merge-base.
            return {"status": "ahead"}
        if "/actions/runs/" in route and route.endswith(("/jobs?filter=latest&per_page=100",
                                                         "/jobs?filter=all&per_page=100")):
            # One attempt per run here: every attempt (filter=all) is the latest one.
            run = int(route.split("/actions/runs/", 1)[1].split("/", 1)[0])
            return [{"jobs": [copy.deepcopy(job) for job in self.jobs.values() if job["run_id"] == run]}]
        if "/actions/workflows/7/runs?" in route:
            # Both list every status: the dispatch fallback for deferred_first_runs, the window because a finished
            # job in a running base run is already a verdict.
            assert "branch=feat-cmux-next" in route and "status=" not in route, route
            runs = copy.deepcopy(self.base_runs)
            if "&event=" in route:
                # GitHub filters by event, as the tip suite's dispatch read asks it to.
                event = route.split("&event=", 1)[1].split("&", 1)[0]
                runs = [run for run in runs if run.get("event") == event]
            return {"workflow_runs": runs}
        if route.endswith(f"commits/{HEAD}/check-runs?filter=all&per_page=100"):
            # A cancelled head job asks whether a newer run of its name superseded it (superseding_check).
            return [{"check_runs": [{"id": job["id"], "name": job["name"], "status": job["status"],
                                     "conclusion": job["conclusion"], "app": {"slug": "github-actions"},
                                     "details_url": f"https://github.com/{REPO}/actions/runs/{job['run_id']}"
                                                    f"/job/{job['id']}"}
                                    for job in self.jobs.values() if job["head_sha"] == HEAD]}]
        if "/actions/jobs/" in route:
            return copy.deepcopy(self.jobs[int(route.rsplit("/", 1)[1])])
        if route.endswith("/annotations?per_page=100"):
            # A job's check-run annotations (fixed_on_base_by_step's rollup reds): one per `##[error]` line, as the
            # runner makes them.
            text = self.logs.get(int(route.split("/check-runs/", 1)[1].split("/", 1)[0])) or ""
            notes = [{"annotation_level": "failure", "message": line.removeprefix("##[error]")}
                     for line in excuse.lines_of(text) if line.startswith("##[error]")]
            return [notes] if paginate else notes
        if "/actions/runs?head_sha=" in route:
            # The head's run list (head_runs): each run's workflow, no workflow file or time, so none supersedes
            # another by run (superseding_run) unless a test lists them (SupersededRunGitHub).
            sha = route.split("head_sha=", 1)[1].split("&", 1)[0]
            runs = [{"id": run, "workflow_id": self.workflows.get(run, 7), "head_sha": sha}
                    for run in sorted({job["run_id"] for job in self.jobs.values() if job["head_sha"] == sha})]
            return [{"total_count": len(runs), "workflow_runs": runs}]
        if "/actions/runs/" in route:
            run = int(route.rsplit("/", 1)[1])
            return {"id": run, "workflow_id": self.workflows.get(run, 7)}
        raise AssertionError(route)

    workflows: dict[int, int] = {}

    def log(self, repo, job):
        return frame_legacy(job, self.logs[job["id"]])


def frame_legacy(job, text):
    """TEXT as the job-log endpoint serves it for JOB, for a fixture written before lines were placed by step order:
    its steps have no times, and its log no STEP_START lines. Then the whole log was kept as the failed steps' (no
    line could be placed), so the fake serves it as that: every line printed by the job's first failed step (its last
    step when none failed), each other step opening with its own `Run` line, "Complete job" last, the times set on
    JOB's steps in place (judge reads JOB after its log). When the text opens with the owner's own `Run` line (and has
    no other), that line is the owner's header. A fixture with step times is served as written."""
    steps = [step for step in job.get("steps") or [] if step.get("conclusion") != "skipped"]
    if not steps or any(step.get("started_at") for step in steps) or text is None:
        return text
    steps.append({"name": "Complete job", "status": "completed", "conclusion": "success"})
    job["steps"] = steps
    owner = next((n for n, step in enumerate(steps) if step.get("conclusion") not in ("success", None)),
                 len(steps) - 2)
    out, own = [], [line for line in excuse.lines_of(text) if line]
    opened = (len(own) > 0 and excuse.STEP_START.match(own[0]) is not None
              and sum(1 for line in own if excuse.STEP_START.match(line)) == 1)
    for n, step in enumerate(steps):
        step.update(number=n + 1, started_at=f"2026-10-07T02:{10 + n:02d}:00Z",
                    completed_at=f"2026-10-07T02:{10 + n:02d}:30Z")
        stamp = f"2026-10-07T02:{10 + n:02d}:10.0000000Z "
        if n == len(steps) - 1:
            break
        name = str(step.get("name") or "")
        header = (name if name.startswith("Run ") else "Post job cleanup." if name.startswith("Post ")
                  else f"Run fixture-step-{n}")
        if n == owner and opened:
            out += [stamp + line for line in own]
            continue
        out.append(stamp + (f"##[group]{header}" if n else "fixture: set up job"))
        if n == owner:
            out += [stamp + line for line in own]
    return "\n".join(out)


# What a fixture with no workflow to read passes for step_owners' required STEP_NAMES.
UNKNOWN = {"step_names": excuse.STEP_NAMES_UNKNOWN}


def placed_signature(job, text, base=False):
    """excuse.signature of a fixture written before lines were placed by step order, framed as the job-log endpoint
    serves it (frame_legacy) so step_owners places it: a log it does not place has no signature (excuse.UNPLACED)."""
    job = copy.deepcopy(job)
    return excuse.signature(excuse.failed_view(job, frame_legacy(job, text), base=base, **UNKNOWN))


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
        return frame_legacy(job, excuse.GitHub.log(self, repo, job))

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
        route = next(arg for arg in args[1:] if not arg.startswith("-"))  # a projected read appends --jq FILTER
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

    def log(self, repo, job):
        return frame_legacy(job, super().log(repo, job))


class JobListPages(unittest.TestCase):
    def test_a_run_with_many_jobs_is_still_judged(self):
        github = LargeJobListGitHub()
        lines = excuse.judge(REPO, "feat-cmux-next", HEAD, [10], github)
        self.assertIn("run 20", "\n".join(lines))


QUOTA_TEXT = ("API rate limit exceeded for installation ID 1. If you reach out to GitHub Support for help, please "
              "include the request ID ABCD and timestamp 2026-11-10 06:00:00 UTC. " + "x" * 300)


class StrBaseRunsGitHub(FakeGitHub):
    """FakeGitHub whose list of a workflow's base runs comes back as a str, as it did while the REST quota was spent."""

    def json(self, route, *, paginate=False):
        if "/actions/workflows/7/runs?" in route:
            self.routes.append(route)
            return QUOTA_TEXT
        return super().json(route, paginate=paginate)


class UnreadShape(unittest.TestCase):
    """2026-11-10: merge_hold refused cmux#39676 at 9be3f014 with a traceback, not a reason: list_base_runs read a
    workflow's base runs while the REST quota was spent, the answer was a str, and `listed.get("workflow_runs")` raised
    AttributeError. Every json read that is not a JSON object or list is now Refused as unread, naming what came back."""

    def assert_unread(self, error, route):
        said = str(error.exception)
        self.assertIn(f"GitHub's answer to {route}", said)
        self.assertIn("could not be read: " + QUOTA_TEXT[:excuse.SHAPE_CHARS], said)
        self.assertNotIn(QUOTA_TEXT[:excuse.SHAPE_CHARS + 1], said)  # the first 200 characters only

    def test_a_str_base_run_list_refuses_the_judge_with_a_reason(self):
        github = StrBaseRunsGitHub()
        with self.assertRaises(excuse.Refused) as error:
            excuse.judge(REPO, "feat-cmux-next", HEAD, [10], github)
        self.assertIn("could not be read: API rate limit exceeded", str(error.exception))

    def test_main_reports_a_str_answer_as_not_excused(self):
        err = io.StringIO()
        with unittest.mock.patch.object(excuse, "GitHub", StrBaseRunsGitHub), \
                unittest.mock.patch.object(excuse.test_reds, "load_flake_state", lambda *a, **k: None), \
                contextlib.redirect_stderr(err):
            code = excuse.main(["--repo", REPO, "--base", "feat-cmux-next", "--sha", HEAD, "--run", "10"])
        self.assertEqual(code, 1)
        self.assertIn("not excused: ", err.getvalue())
        self.assertIn("could not be read: API rate limit exceeded", err.getvalue())
        self.assertNotIn("Traceback", err.getvalue())

    def test_every_json_read_through_the_judges_reader_is_checked(self):
        class Answers:
            def __init__(self, found):
                self.found = found

            def json(self, route, *, paginate=False):
                return self.found
        route = f"repos/{REPO}/actions/workflows/7/runs?branch=feat-cmux-next&per_page=100"
        for found, paginate in ((QUOTA_TEXT, False), (QUOTA_TEXT, True), ([{"check_runs": []}, QUOTA_TEXT], True)):
            with self.subTest(found=str(found)[:20], paginate=paginate), self.assertRaises(excuse.Refused) as error:
                excuse.rate_limit_aware(Answers(found)).json(route, paginate=paginate)
            self.assert_unread(error, route)
        # An object, a list, and a fake's None (nothing) still read as they did.
        for found in ({"workflow_runs": []}, [], None, [{"check_runs": []}]):
            self.assertEqual(excuse.rate_limit_aware(Answers(found)).json(route, paginate=True), found)

    def test_list_base_runs_reads_a_str_as_unread(self):
        route = f"repos/{REPO}/actions/workflows/7/runs?branch=feat-cmux-next&per_page={excuse.BASE_RUNS_PAGE}"
        with self.assertRaises(excuse.Refused) as error:
            excuse.list_base_runs(REPO, "feat-cmux-next", 7, excuse.rate_limit_aware(StrBaseRunsGitHub()), {})
        self.assert_unread(error, route)

    def reader(self, answers):
        github = excuse.GitHub()
        github.run = lambda args: answers.pop(0)
        return github

    def test_the_real_client_refuses_a_json_str_or_text_that_is_not_json(self):
        route = f"repos/{REPO}/actions/workflows/7/runs?branch=feat-cmux-next&per_page=100"
        for said in (json.dumps(QUOTA_TEXT), QUOTA_TEXT, "null", "3"):
            with self.subTest(said=said[:20]), self.assertRaises(excuse.Refused) as error:
                self.reader([said]).json(route)
            self.assertIn(f"GitHub's answer to {route} could not be read: ", str(error.exception))
            if said.startswith(("\"", "A")):
                self.assert_unread(error, route)
        self.assertEqual(self.reader(['{"workflow_runs": []}']).json(route), {"workflow_runs": []})

    def test_the_real_client_checks_each_page_before_the_pager_reads_it(self):
        # A projected read (a run's jobs) and a whole one (a commit's check runs), paginated: a str page is unread,
        # never the pager's TypeError.
        for route in (f"repos/{REPO}/actions/runs/42/jobs?filter=all&per_page=100",
                      f"repos/{REPO}/commits/{HEAD}/check-runs?filter=all&per_page=100"):
            with self.subTest(route=route), self.assertRaises(excuse.Refused) as error:
                self.reader([json.dumps(QUOTA_TEXT)]).json(route, paginate=True)
            self.assertIn("could not be read: " + QUOTA_TEXT[:excuse.SHAPE_CHARS], str(error.exception))


class LastRealAttemptGitHub(FakeGitHub):
    """Head run 10 of cmux#35906 at e1d1894a (run 41931705470): attempt 1 ran and failed, then each later attempt
    in ATTEMPTS ran the jobs it lists, [] for one that ended in startup_failure with no jobs. GitHub's latest-attempt
    views (jobs?filter=latest, check-runs with no filter) show only the newest attempt, so after two startup_failure
    reruns they show no job and no check run at all; every attempt (filter=all) still shows attempt 1's red."""

    def __init__(self, *later: list[dict]):
        super().__init__()
        red = dict(self.jobs.pop(1), run_attempt=1)
        self.attempts = [[red], *([dict(job, run_attempt=number) for job in jobs]
                                  for number, jobs in enumerate(later, 2))]
        for jobs in self.attempts:
            self.jobs.update((job["id"], job) for job in jobs)

    def check(self, job: dict) -> dict:
        return {"id": job["id"], "name": job["name"], "status": job["status"], "conclusion": job["conclusion"],
                "app": {"slug": "github-actions"},
                "details_url": f"https://github.com/{REPO}/actions/runs/10/job/{job['id']}"}

    def json(self, route, *, paginate=False):
        if route.endswith("/actions/runs/10/jobs?filter=latest&per_page=100"):
            self.routes.append(route)
            return [{"jobs": copy.deepcopy(self.attempts[-1])}]
        if route.endswith("/actions/runs/10/jobs?filter=all&per_page=100"):
            self.routes.append(route)
            return [{"jobs": copy.deepcopy([job for jobs in self.attempts for job in jobs])}]
        if f"/commits/{HEAD}/check-runs" in route:
            self.routes.append(route)
            shown = [job for jobs in self.attempts for job in jobs] if "filter=all" in route else self.attempts[-1]
            return [{"check_runs": [self.check(job) for job in shown]}]
        if f"/commits/{HEAD}/status" in route:
            self.routes.append(route)
            return status_answer(route, [])
        if f"actions/runs?head_sha={HEAD}" in route:
            self.routes.append(route)
            return {"workflow_runs": []}
        if "/actions/jobs/" in route:
            self.routes.append(route)
            return copy.deepcopy(self.jobs[int(route.rsplit("/", 1)[1])])
        return super().json(route, paginate=paginate)


class LastRealAttempt(unittest.TestCase):
    """A check reads as its last real attempt left it. An attempt that ended in startup_failure, or ran no jobs, is
    no result: it never hides the red before it. cmux#35906 merged as 633d5e38 pinned at e1d1894a with its
    'publish tree-addressed cmux-tui' red in run 41931705470 (attempt 1) unexcused: two reruns ended in
    startup_failure with no jobs, and the red check run dropped out of the head's latest-attempt view."""

    def green(self, job_id=5):
        job = failed_job(job_id, 10, HEAD)
        job["conclusion"] = "success"
        job["steps"][-1]["conclusion"] = "success"
        return job

    def test_red_then_two_startup_failures_is_still_judged_as_red_by_check(self):
        github = LastRealAttemptGitHub([], [])
        lines = excuse.judge(REPO, "feat-cmux-next", HEAD, [], github, checks=[SWIFT])
        self.assertIn("run 20", "\n".join(lines))
        self.assertTrue(any("check-runs?filter=all" in route for route in github.routes), github.routes)

    def test_red_hidden_by_startup_failures_stays_not_excused_when_the_base_lacks_it(self):
        for checks, runs in (([SWIFT], []), ([], [10])):
            with self.subTest(checks=checks, runs=runs):
                github = LastRealAttemptGitHub([], [])
                github.jobs[2]["conclusion"] = "success"
                github.jobs[2]["steps"][-1]["conclusion"] = "success"
                with self.assertRaises(excuse.Refused) as refused:
                    excuse.judge(REPO, "feat-cmux-next", HEAD, runs, github, checks=checks)
                # Judged against the base and refused as the head's own red, not lost as "no job".
                self.assertIn("is not red on feat-cmux-next", str(refused.exception))

    def test_red_then_a_real_green_rerun_reads_green(self):
        # Green on its own, and green with a startup_failure rerun after it: the green is the last real attempt.
        for later in (([self.green()],), ([self.green()], [])):
            with self.subTest(attempts=len(later) + 1):
                with self.assertRaisesRegex(excuse.Refused, "is success"):
                    excuse.judge(REPO, "feat-cmux-next", HEAD, [], LastRealAttemptGitHub(*later), checks=[SWIFT])
                with self.assertRaisesRegex(excuse.Refused, "no failed job found"):
                    excuse.judge(REPO, "feat-cmux-next", HEAD, [10], LastRealAttemptGitHub(*later))

    def test_startup_failure_alone_is_no_result_not_green(self):
        github = LastRealAttemptGitHub()
        github.attempts = [[]]
        with self.assertRaisesRegex(excuse.Refused, "has not run on exact head"):
            excuse.judge(REPO, "feat-cmux-next", HEAD, [], github, checks=[SWIFT])
        self.assertEqual(excuse.last_real_jobs(REPO, 10, github), [])


class NoFailureExitsZero(unittest.TestCase):
    """2026-11-05: asked about a head with no red (no --run, no --check), the classifier exited 1 with "no failed job
    found on the head to compare with the base" (cmuxterm-hq#7234 at ce69ab6d, 16/16 green), so a merge check that
    ran it on every head refused every green PR. No failure is exit 0; a red run or check that was named and shows
    no failed job is still refused (LastRealAttempt)."""

    def test_no_run_or_check_named_is_no_failure(self):
        github = FakeGitHub()
        self.assertEqual(excuse.judge(REPO, "feat-cmux-next", HEAD, [], github),
                         [f"no red run or check named on {HEAD}: no failure to excuse"])
        self.assertEqual(github.routes, [])  # nothing to read

    def test_main_exits_0_on_no_failure(self):
        out = io.StringIO()
        with unittest.mock.patch.object(excuse, "GitHub", FakeGitHub), \
                unittest.mock.patch.object(excuse.test_reds, "load_flake_state", lambda *a, **k: None), \
                contextlib.redirect_stdout(out):
            code = excuse.main(["--repo", REPO, "--base", "feat-cmux-next", "--sha", HEAD])
        self.assertEqual(code, 0)
        self.assertIn("no failure to excuse", out.getvalue())

    # 2026-11-05: a gh-merge-green test's classifier, --sha aaaa... against a fake gh whose list never ended, outlived
    # its test and ran three days on gcp-agent-lane-2 at 27.6 GB.
    def test_main_refuses_a_placeholder_sha_before_reading_anything(self):
        def unread(*a, **k):
            raise AssertionError("nothing is read for a placeholder sha")
        for sha in ("a" * 40, "0" * 40, "F" * 40):
            err = io.StringIO()
            with unittest.mock.patch.dict(os.environ, {"BASE_RED_EXCUSE_FIXTURE_SHA": ""}), \
                    unittest.mock.patch.object(excuse, "judge", unread), \
                    unittest.mock.patch.object(excuse, "GitHub", unread), contextlib.redirect_stderr(err):
                code = excuse.main(["--repo", REPO, "--base", "feat-cmux-next", "--sha", sha, "--check", "x"])
            with self.subTest(sha=sha):
                self.assertEqual(code, 1)
                self.assertIn("is a placeholder, not a commit", err.getvalue())

    def test_main_stops_at_its_deadline_even_inside_a_loop_that_takes_every_refusal(self):
        # The alarm is the clock: a fake one records what main arms, and the loop below fires the handler main
        # installed, as the real alarm does once the deadline passes. No real time passes.
        armed = []
        caller_handler = excuse.signal.getsignal(excuse.signal.SIGALRM)

        def endless(*a, **k):  # as a window read that catches Refused and reads on, with a list that never ends
            for _ in range(3):
                try:
                    excuse.signal.getsignal(excuse.signal.SIGALRM)(excuse.signal.SIGALRM, None)  # the deadline
                except Exception:  # noqa: BLE001
                    pass
            raise AssertionError("the deadline did not end a loop that takes every Exception")
        err = io.StringIO()
        with unittest.mock.patch.dict(os.environ, {"BASE_RED_EXCUSE_DEADLINE_SECONDS": "1"}), \
                unittest.mock.patch.object(excuse.signal, "alarm", lambda seconds: armed.append(seconds) or 0), \
                unittest.mock.patch.object(excuse, "judge", endless), \
                unittest.mock.patch.object(excuse, "GitHub", FakeGitHub), \
                unittest.mock.patch.object(excuse.test_reds, "load_flake_state", lambda *a, **k: None), \
                contextlib.redirect_stderr(err):
            code = excuse.main(["--repo", REPO, "--base", "feat-cmux-next", "--sha", "1" * 39 + "2", "--check", "x"])
        self.assertEqual(code, 1)
        self.assertIn("ran past its 1 s deadline", err.getvalue())
        self.assertEqual(armed, [1, 0])  # armed for the 1 s deadline, then no alarm left armed for the caller
        self.assertIs(excuse.signal.getsignal(excuse.signal.SIGALRM), caller_handler)  # the caller's handler is back


class JobLogEndpoint(unittest.TestCase):
    def test_finished_red_job_is_classified_while_its_run_is_in_progress(self):
        github = InProgressJobLogGitHub()
        lines = excuse.judge(REPO, "feat-cmux-next", HEAD, [10], github)
        self.assertIn("run 20", "\n".join(lines))
        self.assertEqual(github.json(f"repos/{REPO}/actions/runs/10")["status"], "in_progress")
        self.assertEqual(github.log_requests,
                         [["api", "--allow-escape-sequences", f"repos/{REPO}/actions/jobs/{job_id}/logs"]
                          for job_id in (1, 2)])

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

    def test_a_rule_line_shared_with_base_does_not_hide_a_new_error_line_of_another_step(self):
        # The crash-class job: the selector step is red on both sides with the same line, the concurrency step
        # prints only error lines, and the head adds one.
        github = InProgressJobLogGitHub()
        objc = CrashClassRuleSignature.OBJC
        for job_id in (1, 2):
            github.jobs[job_id]["name"] = SCHEME
            github.logs[job_id] = log(SCHEME, TEST_STEP, objc, "##[error]concurrency: Sources/Old.swift:3: old rule")
        github.logs[1] += "\n" + log(SCHEME, TEST_STEP, "##[error]concurrency: Sources/New.swift:9: new rule")
        with self.assertRaisesRegex(excuse.Refused, "new rule"):
            excuse.judge(REPO, "feat-cmux-next", HEAD, [10], github)

    def test_raw_log_tabs_do_not_hide_no_verdict_annotation(self):
        text = f"2026-10-30T12:00:00.000Z ##[error]No build-fleet verdict for `\t{HEAD}`"
        self.assertIsNotNone(excuse.no_verdict(text))

    def test_a_byte_order_mark_never_hides_a_line(self):
        # GitHub's job log can start a section with U+FEFF, which str.strip() keeps: a ws-check run's
        # WS_CHECK_RESULT line came back as "\ufeffWS_CHECK_RESULT=..." and the base red read as unreported
        # (cmuxterm-hq run 42391652834, 2026-11-07).
        raw = "2026-11-07T16:38:25.8020289Z ok\n\ufeff2026-11-07T16:38:25.8257495Z WS_CHECK_RESULT={}"
        self.assertEqual(excuse.lines_of(raw), ["ok", "WS_CHECK_RESULT={}"])
        cli = "checks\tUNKNOWN STEP\t\ufeff2026-11-07T16:38:25.8257495Z WS_CHECK_RESULT={}"
        self.assertEqual(excuse.lines_of(cli), ["WS_CHECK_RESULT={}"])

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
if mode == "shim-old" and "--allow-escape-sequences" in args:
    # An agent host's gh wrappers note a wait before the real gh answers.
    sys.stderr.write("glaeda-gh: this caller read the same thing moments ago and the cache cannot answer it; "
                     "waiting 23 s before spending a request on it again (CMUX_GH_MIN_REPEAT_SECONDS)\\n"
                     "unknown flag: --allow-escape-sequences\\n\\nUsage: gh api <endpoint> [flags]\\n")
    sys.exit(1)
if mode == "http":
    sys.stderr.write("gh: Not Found (HTTP 404)\\n")
    sys.exit(1)
if mode == "other-flag":
    sys.stderr.write("unknown flag: --hostname-x\\nunknown flag: --allow-escape-sequences\\n")
    sys.exit(1)
if mode == "big":
    line = "2026-10-30T12:00:00.000Z " + "x" * 1000 + "\\n"
    sys.stdout.write(line * (41 * 1024 * 1024 // len(line)) + "2026-10-30T12:00:00.000Z tail\\n")
    sys.exit(0)
if mode == "bom":
    print("2026-10-30T12:00:00.000Z ok\\n\\ufeff2026-10-30T12:00:01.000Z WS_CHECK_RESULT={}")
    sys.exit(0)
print("2026-10-30T12:00:00.000Z \\x1b[31mred\\x1b[0m log")
"""


class ListReadsNameTheirFields(unittest.TestCase):
    """cmux#38416: a run's jobs, a combined status and a commit history are read with a --jq naming the fields this
    script uses, so an agent host's gh shim can answer them over GraphQL while REST is under its floor."""

    JOBS = f"repos/{REPO}/actions/runs/42476982159/jobs?filter=all&per_page=100"
    REST_JOB = {"id": 128722545294, "run_id": 42476982159, "run_attempt": 1, "name": "GhosttyKit release check",
                "head_sha": "7d54364414a39fbe9270455427ae66de087c9449", "head_branch": "lane/x", "status": "completed",
                "conclusion": "failure", "started_at": "2026-11-08T10:50:00Z", "completed_at": "2026-11-08T10:51:00Z",
                "html_url": "https://github.com/x/job/1", "url": "https://api.github.com/x", "check_run_url": "c",
                "workflow_name": "ci", "runner_name": "mini-3", "labels": ["macos"], "node_id": "N",
                "steps": [{"name": "Verify published GhosttyKit release and checksum", "status": "completed",
                           "conclusion": "failure", "number": 4, "started_at": "s", "completed_at": "e"}]}

    def reader(self, answers):
        github, asked = excuse.GitHub(), []

        def run(args):
            asked.append(args)
            return answers.pop(0)
        github.run = run
        return github, asked

    def test_a_runs_jobs_pages_are_read_with_the_projection(self):
        page = json.dumps({"total_count": 1, "jobs": [{"id": 1, "name": "a", "run_id": None, "run_attempt": 1}]})
        github, asked = self.reader([page])
        jobs = excuse.last_real_jobs(REPO, 42476982159, github)
        self.assertEqual(len(asked), 1)
        self.assertEqual(asked[0][:2], ["api", f"repos/{REPO}/actions/runs/42476982159/jobs?filter=all&per_page=30&page=1"])
        self.assertEqual(asked[0][2:], ["--jq", excuse.projection(self.JOBS)])
        self.assertEqual(jobs[0]["run_id"], 42476982159)  # a projected null run_id is the run read, as a missing one

    def test_status_and_history_are_projected_and_other_reads_stay_whole(self):
        for route in (f"repos/{REPO}/commits/abc/status", f"repos/{REPO}/commits/abc/status?per_page=100",
                      f"repos/{REPO}/commits?sha=feat-cmux-next&per_page=10",
                      f"repos/{REPO}/actions/runs/5/attempts/2/jobs?per_page=30&page=1"):
            self.assertIsNotNone(excuse.projection(route), route)
        for route in (f"repos/{REPO}/actions/jobs/5", f"repos/{REPO}/actions/runs/5",
                      f"repos/{REPO}/compare/a...b?per_page=1", f"repos/{REPO}/commits/abc/check-runs?per_page=100",
                      f"repos/{REPO}/actions/runs/5/artifacts?per_page=100"):
            self.assertIsNone(excuse.projection(route), route)
        github, asked = self.reader(['{"workflow_id": 7}'])
        self.assertEqual(github.json(f"repos/{REPO}/actions/runs/5"), {"workflow_id": 7})
        self.assertEqual(asked, [["api", f"repos/{REPO}/actions/runs/5"]])

    def test_the_jobs_projection_keeps_every_field_this_script_reads(self):
        import shutil
        if shutil.which("jq") is None:
            self.skipTest("jq is not on PATH")
        doc = {"total_count": 1, "jobs": [self.REST_JOB]}
        out = subprocess.run(["jq", "-c", excuse.projection(self.JOBS)], input=json.dumps(doc), text=True,
                             capture_output=True, check=True).stdout
        job = json.loads(out)["jobs"][0]
        dropped = {"runner_name", "labels", "node_id"}
        self.assertEqual(job, {k: v for k, v in self.REST_JOB.items() if k not in dropped})


    def test_a_status_projection_keeps_updated_at_for_the_verdict_window(self):
        import shutil
        if shutil.which("jq") is None:
            self.skipTest("jq is not on PATH")
        status = {"context": "ws-check", "state": "success", "description": "d", "target_url": "u",
                  "created_at": "2026-11-08T10:00:00Z", "updated_at": "2026-11-08T11:00:00Z", "id": 9, "creator": {}}
        doc = {"state": "success", "sha": "abc", "total_count": 1, "statuses": [status], "repository": {}}
        out = subprocess.run(["jq", "-c", excuse.projection(f"repos/{REPO}/commits/abc/status")],
                             input=json.dumps(doc), text=True, capture_output=True, check=True).stdout
        self.assertEqual(json.loads(out)["statuses"][0]["updated_at"], "2026-11-08T11:00:00Z")

    def test_a_base_runs_projected_jobs_are_cached_with_their_run_id(self):
        page = json.dumps({"total_count": 1, "jobs": [{"id": 1, "name": "a", "run_id": None, "run_attempt": 1}]})
        run = {"id": 77, "status": "completed", "run_attempt": 1, "updated_at": "2026-11-08T11:00:00Z"}
        with tempfile.TemporaryDirectory() as cache, \
                unittest.mock.patch.dict(os.environ, {excuse.JOBS_CACHE_ENV: cache}):
            github, asked = self.reader([page])
            self.assertEqual(excuse.base_run_jobs(REPO, run, github)[0]["run_id"], 77)
            github, asked = self.reader([])
            self.assertEqual(excuse.base_run_jobs(REPO, run, github)[0]["run_id"], 77)  # from the cache, no read
            self.assertEqual(asked, [])


FAKE_GLAEDA_GH = """#!/usr/bin/env python3
import os, sys
with open(os.environ["FAKE_GLAEDA_CALLS"], "a") as calls:
    calls.write(" ".join(sys.argv[1:]) + "\\n")
mode = os.environ.get("FAKE_GLAEDA", "")
if mode == "miss":
    sys.stderr.write("glaeda-gh: no kept log for o/r job 7; --fetch reads it once\\n")
    sys.exit(7)
if mode == "old":
    sys.stderr.write("glaeda-gh: error: argument command: invalid choice: 'log'\\n")
    sys.exit(2)
sys.stdout.write("\\ufeff2026-10-30T12:00:00.000Z kept \\x1b[31mred\\x1b[0m log\\n")
"""


class GlaedaKeptLog(unittest.TestCase):
    """A failed job's log this host's glaeda-gh kept is read there, with no gh call; anything else reads GitHub."""

    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        for name, text in (("gh", FAKE_GH), ("glaeda-gh", FAKE_GLAEDA_GH)):
            path = Path(self.dir.name) / name
            path.write_text(text)
            path.chmod(0o755)
        self.gh_calls = Path(self.dir.name) / "gh-calls"
        self.glaeda_calls = Path(self.dir.name) / "glaeda-calls"
        self.gh_calls.write_text("")
        self.glaeda_calls.write_text("")
        env = git_fixture_env.fixture_env({"PATH": f"{self.dir.name}{os.pathsep}{os.environ.get('PATH', '')}",
                                           "FAKE_GH_CALLS": str(self.gh_calls),
                                           "FAKE_GLAEDA_CALLS": str(self.glaeda_calls),
                                           "CMUX_GLAEDA_GH": str(Path(self.dir.name) / "glaeda-gh")})
        patch = unittest.mock.patch.dict(os.environ, env)
        patch.start()
        self.addCleanup(patch.stop)

    def read(self, mode):
        os.environ["FAKE_GLAEDA"] = mode
        return excuse.GitHub().log(REPO, {"id": 7, "run_id": 10})

    def test_a_kept_log_is_read_with_no_api_call(self):
        raw = self.read("")
        self.assertEqual(self.gh_calls.read_text(), "")
        self.assertEqual(self.glaeda_calls.read_text().splitlines(), [f"log job {REPO} 7"])
        self.assertNotIn("\ufeff", raw)
        self.assertEqual(excuse.lines_of(raw), ["kept red log"])

    def test_a_log_glaeda_gh_does_not_keep_is_read_from_github(self):
        for mode in ("miss", "old"):
            self.gh_calls.write_text("")
            self.assertIn("red", self.read(mode))
            self.assertEqual(self.gh_calls.read_text().splitlines(),
                             [f"api --allow-escape-sequences repos/{REPO}/actions/jobs/7/logs"], mode)

    def test_no_glaeda_gh_on_the_host_reads_github(self):
        for named in ("", str(Path(self.dir.name) / "absent")):
            os.environ["CMUX_GLAEDA_GH"] = named
            self.gh_calls.write_text("")
            self.assertIn("red", self.read(""))
            self.assertEqual(len(self.gh_calls.read_text().splitlines()), 1, named)
        self.assertEqual(self.glaeda_calls.read_text(), "")

    # Readers of GET .../actions/jobs/ID/logs that do not ask glaeda-gh, and why. A new reader asks it first (or
    # says here why it cannot): a replay or classifier that reads a log the host's mirror kept spends a read for
    # nothing (cmux#41244's replay: about 150 reads, stopped at 51 runs).
    UNCACHED_LOG_READERS = {
        "base_red_checks.py": "runs in the push workflow with the Actions token (urllib), where no glaeda-gh is",
        "cmux_next_tree_notify.py": "not switched yet: follow-up to the glaeda job-log cache",
        "cmux_tui_tree_handoff.py": "not switched yet: follow-up to the glaeda job-log cache",
        "nightly_ghostty_helper_reuse.py": "not switched yet: follow-up to the glaeda job-log cache",
        "package_bisect.py": "not switched yet: follow-up to the glaeda job-log cache",
        "web_test_failure_census.py": "not switched yet: follow-up to the glaeda job-log cache",
    }

    def test_every_job_log_reader_asks_glaeda_gh_first(self):
        route = re.compile(r"actions/jobs/\{[^}]*\}/logs")
        readers = {path.name for path in (ROOT / "scripts/ci").glob("*.py") if route.search(path.read_text())}
        uncached = {name for name in readers
                    if "glaeda_log.cached_job_log(" not in (ROOT / "scripts/ci" / name).read_text()}
        self.assertEqual(uncached - set(self.UNCACHED_LOG_READERS), set(),
                         "a new job log reader: ask glaeda_log.cached_job_log first, or name why not")
        self.assertEqual(set(self.UNCACHED_LOG_READERS) - uncached, set(), "this reader asks glaeda-gh now: drop it")
        self.assertGreaterEqual(readers - uncached, {"base_red_excuse.py", "classify_failures.py", "guard_attribution.py",
                                                      "main_compile_attribution.py", "next_batch.py",
                                                      "affected_tests_replay.py"})


class PortableGhLog(unittest.TestCase):

    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        gh = Path(self.dir.name) / "gh"
        gh.write_text(FAKE_GH)
        gh.chmod(0o755)
        self.calls = Path(self.dir.name) / "calls"
        self.calls.write_text("")
        env = git_fixture_env.fixture_env({"PATH": f"{self.dir.name}{os.pathsep}{os.environ.get('PATH', '')}", "FAKE_GH_CALLS": str(self.calls)})
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
        # The reader strips the colour gh served, once, so no parser sees it (#41329's review F2).
        self.assertEqual(raw, "2026-10-30T12:00:00.000Z red log\n")
        route = f"repos/{REPO}/actions/jobs/7/logs"
        self.assertEqual(self.asked(), [f"api --allow-escape-sequences {route}"])
        self.assertEqual(excuse.lines_of(raw), ["red log"])

    def test_a_byte_order_mark_in_a_job_log_is_dropped_on_read(self):
        raw = self.read("bom")
        self.assertNotIn("\ufeff", raw)
        self.assertEqual(excuse.lines_of(raw), ["ok", "WS_CHECK_RESULT={}"])

    def test_old_gh_falls_back_without_the_flag(self):
        self.assertIn("red", self.read("old"))
        route = f"repos/{REPO}/actions/jobs/7/logs"
        self.assertEqual(self.asked(), [f"api --allow-escape-sequences {route}", f"api {route}"])

    def test_old_gh_behind_a_wrapper_notice_falls_back_without_the_flag(self):
        self.assertIn("red", self.read("shim-old"))
        route = f"repos/{REPO}/actions/jobs/7/logs"
        self.assertEqual(self.asked(), [f"api --allow-escape-sequences {route}", f"api {route}"])

    def test_any_other_failure_still_refuses_with_no_retry(self):
        for mode in ("http", "other-flag"):
            with self.subTest(mode=mode):
                self.calls.write_text("")
                with self.assertRaises(excuse.Refused):
                    self.read(mode)
                self.assertEqual(len(self.asked()), 1)

    def test_a_job_log_over_32_mib_is_read_whole(self):
        # 2026-11-01: #28391's cmux-next swift test log was about 40 MB, past the old 32 MiB cap.
        text = self.read("big")
        self.assertGreater(len(text), 40 * 1024 * 1024)
        self.assertTrue(text.endswith("tail\n"))


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

    def test_a_pull_request_target_run_is_never_base_evidence(self):
        # Like a pull_request run, it ran in a PR's context: its red is not the base's.
        self.gh.base_runs[1]["event"] = "pull_request_target"
        with self.assertRaisesRegex(excuse.Refused, "no feat-cmux-next run of its workflow has a verdict"):
            self.judge()

    def test_the_newest_base_run_decides_whatever_order_github_lists_them(self):
        # Run 22 is newer and green; listed after the older red run 20, it still decides: not red on the base.
        self.gh.jobs[3] = dict(failed_job(3, 22, "c" * 40), conclusion="success",
                               steps=[{"name": TEST_STEP, "status": "completed", "conclusion": "success"}])
        self.gh.base_runs[1]["created_at"] = "2026-11-04T10:00:00Z"
        self.gh.base_runs.append({"id": 22, "event": "push", "head_branch": "feat-cmux-next", "status": "completed",
                                  "conclusion": "success", "head_sha": "c" * 40, "created_at": "2026-11-04T11:00:00Z"})
        with self.assertRaisesRegex(excuse.Refused, "not red on feat-cmux-next run 22"):
            self.judge()

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
        with self.assertRaisesRegex(excuse.Refused, "no feat-cmux-next run of its workflow"):
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
        with self.assertRaisesRegex(excuse.Refused, "no feat-cmux-next run of its workflow"):
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
        with self.assertRaisesRegex(excuse.Refused, "no feat-cmux-next run of its workflow"):
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

    def coalesced_setup(self, newest_green: bool, yielded: bool = False):
        # cmux-next-web.yml runs its web checks at most once every 30 minutes (web_coalesce.py): a push whose
        # pending coalesce job a newer push replaced ends cancelled, its coalesce job cancelled and its web job
        # skipped. Such runs sit ahead of the run that covered them.
        name = "web / Web tests (1/4)"
        self.gh.jobs = {1: failed_job(1, 10, HEAD, name=name)}
        self.gh.logs[1] = log(name, TEST_STEP, ISSUE)
        runs = []
        for n in range(9):
            rid = 3000 + n
            runs.append({"id": rid, "event": "push", "head_branch": "feat-cmux-next", "status": "completed",
                         "conclusion": "success" if yielded else "cancelled",
                         "path": ".github/workflows/cmux-next-web.yml", "head_sha": f"{n}" * 40})
            self.gh.jobs[100 + n] = dict(failed_job(100 + n, rid, f"{n}" * 40, name="coalesce"),
                                         conclusion="success" if yielded else "cancelled")
            self.gh.jobs[200 + n] = dict(failed_job(200 + n, rid, f"{n}" * 40, name="web"), conclusion="skipped")
        if newest_green:
            # Cancelled by hand after its web tests passed: that green is the newest verdict.
            self.gh.jobs[300] = dict(failed_job(300, 3000, "0" * 40, name=name), conclusion="success")
        covering = {"id": 20, "event": "push", "head_branch": "feat-cmux-next", "status": "completed",
                    "conclusion": "failure", "path": ".github/workflows/cmux-next-web.yml", "head_sha": BASE_SHA}
        self.gh.jobs[2] = failed_job(2, 20, BASE_SHA, name=name)
        self.gh.logs[2] = log(name, TEST_STEP, ISSUE, OTHER)
        self.gh.base_runs = runs + [covering]
        return name

    def test_coalesced_web_push_runs_leave_the_verdict_to_the_run_that_covered_them(self):
        name = self.coalesced_setup(newest_green=False)
        self.assertIn(f"excused '{name}': feat-cmux-next run 20", "\n".join(self.judge()))

    def test_yielded_web_push_runs_leave_the_verdict_to_the_run_that_covered_them(self):
        # web_coalesce.py (#33872): a coalesce job that slept yields to a newer push; its run ends success with its
        # web job skipped, which is no verdict.
        name = self.coalesced_setup(newest_green=False, yielded=True)
        self.assertIn(f"excused '{name}': feat-cmux-next run 20", "\n".join(self.judge()))

    def test_a_cancelled_web_run_whose_job_passed_is_the_newest_verdict(self):
        # A cancelled run is not proof that nothing ran: its green must not be passed over for an older red.
        self.coalesced_setup(newest_green=True)
        with self.assertRaises(excuse.Refused):
            self.judge()

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

    def cancelled_tier_setup(self, name, *, cancelled_without_verdict=0):
        # cmux_next_base_tier.py cancel_superseded (2026-11-09) cancels a superseded base tier run whose daemon tests
        # (or generated files) finished and whose scheme compile still queued: such a cancelled run has a verdict.
        self.gh.jobs = {1: failed_job(1, 10, HEAD, name=name, step="Run the suites")}
        self.gh.logs[1] = log(name, "Run the suites", ISSUE)
        title = "cmux-next base tier · "
        older = {"id": 40, "event": "workflow_dispatch", "head_branch": "feat-cmux-next", "status": "in_progress",
                 "conclusion": None, "display_title": title + "e" * 40, "created_at": "2026-11-09T12:00:00Z",
                 "check_suite_node_id": "CS_40"}
        self.gh.jobs[4] = failed_job(4, 40, "e" * 40, name=name, step="Run the suites")
        self.gh.logs[4] = log(name, "Run the suites", ISSUE, OTHER)
        runs = [older]
        for offset in range(cancelled_without_verdict):
            run_id = 7000 + offset
            runs.append({"id": run_id, "event": "workflow_dispatch", "head_branch": "feat-cmux-next",
                         "status": "completed", "conclusion": "cancelled",
                         "display_title": title + f"{offset % 16:x}" * 39 + "0",
                         "created_at": f"2026-11-09T13:{offset:02d}:00Z", "check_suite_node_id": f"CS_{run_id}"})
            self.gh.jobs[run_id] = dict(failed_job(run_id, run_id, "0" * 40, name=name), conclusion="cancelled",
                                        steps=[])
        self.gh.base_runs = sorted(runs, key=lambda run: run["created_at"], reverse=True)

        def run(args):
            # The check suites of the listed runs: every check run of the asked name in each, as GraphQL answers.
            query = next(arg for arg in args if arg.startswith("query="))
            asked = next(arg for arg in args if arg.startswith("name="))[len("name="):]
            return json.dumps({"data": {"nodes": [
                {"id": f"CS_{suite}", "checkRuns": {"pageInfo": {"hasNextPage": False}, "nodes": [
                    {"conclusion": (job["conclusion"] or "").upper() or None}
                    for job in self.gh.jobs.values() if job["run_id"] == int(suite) and job["name"] == asked]}}
                for suite in re.findall(r'"CS_(\d+)"', query)]}})

        self.gh.run = run

    def test_a_cancelled_base_tier_runs_newer_green_stands_over_an_older_red(self):
        # The kick cancelled run 41 after its daemon tests (or generated files) passed; run 40, older, is red. The
        # newest verdict is run 41's green: the head's red is its own, never excused by run 40.
        for name in ("cmux-next daemon tests", "cmux-next generated files"):
            with self.subTest(job=name):
                self.setUp()
                self.cancelled_tier_setup(name)
                self.gh.base_runs.insert(0, {
                    "id": 41, "event": "workflow_dispatch", "head_branch": "feat-cmux-next", "status": "completed",
                    "conclusion": "cancelled", "display_title": "cmux-next base tier · " + "d" * 40,
                    "created_at": "2026-11-09T12:15:00Z", "check_suite_node_id": "CS_41"})
                self.gh.jobs[5] = dict(failed_job(5, 41, "d" * 40, name=name, step="Run the suites"),
                                       conclusion="success")
                self.gh.jobs[5]["steps"][-1]["conclusion"] = "success"
                with self.assertRaisesRegex(excuse.Refused, "not red on feat-cmux-next run 41"):
                    self.judge()

    def test_cancelled_base_tier_runs_with_no_verdict_spend_no_job_reads(self):
        # More cancelled base tier runs with no verdict for the job than either lookup reads sit ahead of run 40:
        # their check suites say so, so none is read or counted, and run 40's red still decides.
        for name in ("cmux-next daemon tests", "cmux-next generated files"):
            with self.subTest(job=name):
                self.setUp()
                self.cancelled_tier_setup(name, cancelled_without_verdict=excuse.BASE_JOB_READS + 2)
                text = "\n".join(self.judge())
                self.assertIn(f"excused '{name}': feat-cmux-next run 40", text)
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

    def test_a_summary_with_no_verdict_is_refused_with_rerun(self):
        """A summary gate (scripts/ci/needs_verdict.py) whose dependency was abandoned judged nothing.

        It ends red so no merger reads it as green; its `no verdict: ` annotation must make this refuse with
        "re-run it", never excuse it as the base's red. The runner's echo of the step script does not count.
        """
        name, step = "rust workspaces", "Every planned workspace passed"
        no_verdict = "no verdict: rust workspaces: plan abandoned, workspace skipped; nothing it summarizes was judged: re-run the run"
        self.gh.jobs[1] = failed_job(1, 10, HEAD, name=name, step=step)
        self.gh.jobs[2] = failed_job(2, 20, BASE_SHA, name=name, step=step)
        echoed = [
            "##[group]Run needs_verdict() {",
            'echo "::error::no verdict: $what:${unjudged%,}; nothing it summarizes was judged: re-run the run"; return 3',
            "shell: /usr/bin/bash -e {0}",
            "##[endgroup]",
        ]
        self.gh.logs[1] = log(name, step, *echoed, "##[error]" + no_verdict, "##[error]Process completed with exit code 3.")
        self.gh.logs[2] = log(name, step, "##[error]" + no_verdict, "##[error]Process completed with exit code 3.")
        with self.assertRaisesRegex(excuse.Refused, r"gave no verdict.*re-run it"):
            self.judge()

    def test_a_summary_echoing_the_rule_is_judged_by_its_live_lines_only(self):
        # The runner's echo of the step script spells both markers; only a live annotation is a summary's verdict.
        name, step = "rust workspaces", "Every planned workspace passed"
        echoed = [
            "##[group]Run needs_verdict() {",
            'if [[ -n "$failed" ]]; then echo "::error::summary red: $what:${failed%;}"; return 1; fi',
            'echo "::error::no verdict: $what:${unjudged%,}; nothing it summarizes was judged: re-run the run"; return 3',
            "shell: /usr/bin/bash -e {0}",
            "##[endgroup]",
        ]
        self.assertIsNone(excuse.summary_red(log(name, step, *echoed)))
        self.assertIsNone(excuse.summary_no_verdict(log(name, step, *echoed)))
        self.assertIsNotNone(excuse.summary_red(log(name, step, *echoed, "##[error]summary red: rust workspaces: workspace: failure")))

    def rule_step(self, workflow, job, step_name, env):
        """Run a workflow step that carries needs_verdict.py's rule, for real: its printed lines, each `::error::` the
        way the runner logs it, and the runner's exit line."""
        import yaml
        doc = yaml.safe_load((ROOT / ".github/workflows" / workflow).read_text(encoding="utf-8"))
        body = next(s for s in doc["jobs"][job]["steps"] if s["name"] == step_name)["run"]
        with tempfile.TemporaryDirectory() as tmp:
            done = subprocess.run(["bash", "-e", "-c", body], capture_output=True, text=True, stdin=subprocess.DEVNULL,
                                  env={**os.environ, "GITHUB_STEP_SUMMARY": str(Path(tmp) / "summary"), **env})
        return [line.replace("::error::", "##[error]", 1) if line.startswith("::error::") else line
                for line in (done.stdout + done.stderr).splitlines()] + [
            f"##[error]Process completed with exit code {done.returncode}."]

    def test_rust_workspaces_failing_different_crates_on_head_and_base_is_refused(self):
        # cmux#39857 review (gpt-6.1-sol, b7b3ad7f): the rule's red line is the same words whichever crate failed, so a
        # head failing crate-a matched a base failing crate-b and was excused with no child compared.
        name, step = "rust workspaces", "Every planned workspace passed"
        printed = self.rule_step("rust-workspaces.yml", "summary", step, {"PLAN": "success", "WORKSPACES": "failure"})
        self.assertIn("##[error]summary red: rust workspaces: workspace: failure", printed)
        self.gh.jobs = {1: failed_job(1, 10, HEAD, name=name, step=step), 2: failed_job(2, 20, BASE_SHA, name=name, step=step),
                        7: failed_job(7, 10, HEAD, name="workspace (crate-a)", step="cargo test"),
                        8: failed_job(8, 20, BASE_SHA, name="workspace (crate-b)", step="cargo test")}
        self.gh.logs = {1: log(name, step, *printed), 2: log(name, step, *printed),
                        7: log("workspace (crate-a)", "cargo test", "test a::t ... FAILED"),
                        8: log("workspace (crate-b)", "cargo test", "test b::t ... FAILED")}
        self.with_checks([{"id": 1, "name": name, "status": "completed", "conclusion": "failure",
                           "app": {"slug": "github-actions"},
                           "details_url": f"https://github.com/{REPO}/actions/runs/10/job/1"}])
        with self.assertRaisesRegex(excuse.Refused, "rust workspaces' is a summary red.*compare its failed children"):
            excuse.judge(REPO, "feat-cmux-next", HEAD, [], self.gh, checks=[name])

    def test_every_rule_summary_red_is_refused_unless_its_children_are_compared(self):
        """Every workflow job on needs_verdict.py's rule, head and base red with different children or the same child:
        never excused on its own red line. Only a job registered for child-level comparison (a routed rollup, judged by
        validate_guard_routes against its failed children; Guard status) gets past it, and the Guard status tests above
        feed its real step output through that path."""
        import yaml
        sys.path.insert(0, str(ROOT / "scripts/ci"))
        import needs_verdict as nv
        whats = []
        for path in sorted((ROOT / ".github/workflows").glob("*.yml")):
            doc = yaml.safe_load(path.read_text(encoding="utf-8"))
            for job_id, job in (doc.get("jobs") or {}).items():
                for st in job.get("steps") or []:
                    body = st.get("run") or ""
                    if nv.SHELL_RULE.splitlines()[0] in body:
                        found = re.findall(r'needs_verdict\s+(?:"([^"$]+)"|([\w-]+))', body.replace(nv.SHELL_RULE, ""))
                        kind = "shell"
                    elif nv.PYTHON_RULE.splitlines()[0] in body:
                        import ast
                        script = re.search(r"<<'PY'\n(.*?)\nPY\b", body, re.S).group(1)
                        found = [(call.args[1].value, "") for call in ast.walk(ast.parse(script))
                                 if isinstance(call, ast.Call) and getattr(call.func, "id", "") == "exit_with_verdict"
                                 and len(call.args) > 1 and isinstance(call.args[1], ast.Constant)]
                        kind = "python"
                    else:
                        continue
                    check = job.get("name", job_id)
                    for what in {a or b for a, b in found}:
                        whats.append((path.name, job_id, check, st["name"], what, kind))
        self.assertGreaterEqual(len({w[:2] for w in whats}), 8, whats)
        self.assertIn(("ci-web.yml", "web-status", "Web status"), {(w[0], w[1], w[4]) for w in whats})

        def red_line(kind, what, child):
            if kind == "shell":
                code = ["bash", "-c", nv.SHELL_RULE + f'needs_verdict "{what}" "{child}=failure"']
            else:
                code = [sys.executable, "-c", "import sys\n" + nv.PYTHON_RULE + f"exit_with_verdict({{{child!r}: 'failure'}}, {what!r})"]
            out = subprocess.run(code, capture_output=True, text=True, stdin=subprocess.DEVNULL).stdout
            return [line.replace("::error::", "##[error]", 1) for line in out.splitlines() if line.startswith("::error::")]

        registered = set()
        for workflow, job_id, check, step, what, kind in whats:
            if excuse.routed_rollup(check) is not None:
                registered.add(check)
                continue
            for head_child, base_child in (("child-a", "child-b"), ("child-a", "child-a")):
                with self.subTest(workflow=workflow, job=job_id, what=what, head=head_child, base=base_child):
                    self.gh.jobs = {1: failed_job(1, 10, HEAD, name=check, step=step),
                                    2: failed_job(2, 20, BASE_SHA, name=check, step=step)}
                    self.gh.logs = {
                        1: log(check, step, *red_line(kind, what, head_child), "##[error]Process completed with exit code 1."),
                        2: log(check, step, *red_line(kind, what, base_child), "##[error]Process completed with exit code 1.")}
                    with self.assertRaisesRegex(excuse.Refused, "summary red.*compare its failed children"):
                        self.judge()
        self.assertEqual(registered, {"Guard status"})

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

    def with_checks(self, checks):
        self.gh.check_runs = [{"check_runs": checks}]
        original = self.gh.json

        def json_with_checks(route, *, paginate=False):
            if route.endswith(f"commits/{HEAD}/check-runs?filter=all&per_page=100"):
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

    def test_a_red_ci_status_check_whose_job_was_retried_green_blocks(self):
        # The check-run can stay failed while its exact job was re-run green: never rescan the run and excuse
        # its child reds then, as for a routed rollup (the Guard status).
        for job_id in (1, 2):
            self.gh.jobs[job_id]["name"] = f"macos / {SWIFT}"
        self.red_ci_status()
        self.gh.jobs[3]["conclusion"] = "success"
        with self.assertRaisesRegex(excuse.Refused, "exact aggregate job is success, not failure"):
            excuse.judge(REPO, "feat-cmux-next", HEAD, [], self.gh, checks=["ci-status"])

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

    def test_a_guard_status_whose_log_is_not_placed_is_refused(self):
        # validate_guard_routes reads the guard's failed steps and errors through signature(): a log that does not map
        # one to one onto its steps (two `Run` headers in the routing step) proves no step's lines, so its routes
        # excuse nothing (#40542's Codex F1 at 76dc160c, every signature() caller).
        self.test_a_guard_status_is_judged_by_its_routed_child()
        name = "nightly-guards / Guard status"
        self.gh.logs[3] = log(name, "Check routed guard jobs", "##[group]Run scripts/ci/needs_verdict.py",
                              "##[group]Run inner/action@v1",
                              "workflow-guard-tests: failure (route linux_guard_tests=true)")
        with self.assertRaisesRegex(excuse.Refused, "does not map one to one onto its steps"):
            excuse.judge(REPO, "feat-cmux-next", HEAD, [], self.gh, checks=[name])

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

    def guard_step_output(self, tests_result):
        """What ci-guards.yml's `Check routed guard jobs` step prints, run for real, as its log lines: stdout and
        stderr, each `::error::` annotation the way the runner logs it (`##[error]`), then the runner's exit line."""
        import yaml
        doc = yaml.safe_load((ROOT / ".github/workflows/ci-guards.yml").read_text(encoding="utf-8"))
        body = next(s for s in doc["jobs"]["guard-status"]["steps"] if s["name"] == "Check routed guard jobs")["run"]
        inputs = {"submodule_forward_only": "false", "linux_guard_tests": "true",
                  "linux_guard_test_groups": '["release-notary"]', "linux_guard_history": "false",
                  "linux_guard_cli": "false", "linux_guard_source": "false"}
        needs = {job: {"result": "skipped"} for job in (
            "workflow-guard-submodule-forward-only", "workflow-guard-history", "workflow-guard-cli-scripts",
            "workflow-guard-source-lints")}
        needs["workflow-guard-submodule-forward-only"] = {"result": "success"}
        needs["workflow-guard-tests"] = {"result": tests_result}
        done = subprocess.run(["bash", "-e", "-c", body], capture_output=True, text=True, stdin=subprocess.DEVNULL,
                              env={**os.environ, "GUARD_INPUTS": json.dumps(inputs), "GUARD_NEEDS": json.dumps(needs)})
        printed = [line.replace("::error::", "##[error]", 1) if line.startswith("::error::") else line
                   for line in (done.stdout + done.stderr).splitlines()]
        return printed + [f"##[error]Process completed with exit code {done.returncode}."], done.returncode

    def guard_from_its_step(self, tests_result):
        self.test_a_guard_status_is_judged_by_its_routed_child()
        name = "nightly-guards / Guard status"
        printed, code = self.guard_step_output(tests_result)
        for job_id in (3, 4):
            self.gh.logs[job_id] = log(name, "Check routed guard jobs", *printed)
        return printed, code

    def test_guard_status_rule_output_with_an_inherited_failure_is_excused(self):
        # ci-guards.yml judges its needs with scripts/ci/needs_verdict.py's rule, whose red adds the line
        # `##[error]Guard status: workflow-guard-tests: failure (route linux_guard_tests=true)` (cmux#39857 F1).
        printed, code = self.guard_from_its_step("failure")
        self.assertEqual(code, 1, printed)
        self.assertIn("##[error]summary red: Guard status: workflow-guard-tests: failure (route linux_guard_tests=true)", printed)
        self.assertIn("release-notary", "\n".join(self.judge_guard()))

    def test_guard_status_rule_output_with_its_own_failure_is_refused(self):
        self.guard_from_its_step("failure")
        self.gh.logs[6] = log("nightly-guards / workflow-guard-tests / release-notary",
                              "Test What's New highlights and release notes", "ok")
        self.gh.jobs[6]["conclusion"] = "success"
        self.gh.jobs[6]["steps"][-1]["conclusion"] = "success"
        with self.assertRaisesRegex(excuse.Refused, "release-notary' is not red on feat-cmux-next"):
            self.judge_guard()

    def test_guard_status_rule_output_with_no_verdict_is_rerun(self):
        printed, code = self.guard_from_its_step("abandoned")
        self.assertEqual(code, 3, printed)
        with self.assertRaisesRegex(excuse.Refused, r"gave no verdict.*re-run it"):
            self.judge_guard()

    def test_guard_status_rule_line_is_never_evidence(self):
        # Its red line names jobs in words any summary shares (SUMMARY_RED): the route reports, each checked against a
        # failed child, are the evidence. A line naming another job neither excuses nor refuses by itself.
        self.guard_from_its_step("failure")
        self.gh.logs[3] += "\n" + log("nightly-guards / Guard status", "Check routed guard jobs",
                                      "##[error]summary red: Guard status: workflow-guard-source-lints: failure")
        self.assertIn("release-notary", "\n".join(self.judge_guard()))

    def test_guard_status_other_annotation_is_still_a_routing_error(self):
        self.guard_from_its_step("failure")
        self.gh.logs[3] += "\n" + log("nightly-guards / Guard status", "Check routed guard jobs",
                                      "##[error]Guard status: could not read GUARD_INPUTS")
        with self.assertRaisesRegex(excuse.Refused, "routing error"):
            self.judge_guard()

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

    def test_guard_child_new_error_is_not_excused(self):
        self.test_a_guard_status_is_judged_by_its_routed_child()
        self.gh.logs[5] = "error: new source lint violation"
        with self.assertRaisesRegex(excuse.Refused, "new source lint violation"):
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



class SupersededCancelledRun(unittest.TestCase):
    """cmux#36965 at 004465b3: run 42179149655's 'risk evidence' was cancelled by concurrency while the newer run
    42179187468 of the same workflow passed it. The newest completed run of a check name is its verdict."""

    def setUp(self):
        self.gh = FakeGitHub()
        self.gh.workflows = {}

    def judge(self, runs=(10,)):
        return excuse.judge(REPO, "feat-cmux-next", HEAD, list(runs), self.gh)

    def newer(self, conclusion, run=11):
        self.gh.jobs[5] = dict(failed_job(5, run, HEAD), conclusion=conclusion)
        self.gh.logs[5] = self.gh.logs[1]

    def test_recency_is_the_linked_job_id_not_the_check_run_id(self):
        # A check run's own id need not be its job's: the newer run's check run here has the lower id.
        self.gh.jobs[1]["conclusion"] = "cancelled"
        self.gh.jobs[5] = dict(failed_job(5, 11, HEAD), conclusion="success")
        checks = [{"id": 900, "name": SWIFT, "status": "completed", "conclusion": "cancelled",
                   "app": {"slug": "github-actions"},
                   "details_url": f"https://github.com/{REPO}/actions/runs/10/job/1"},
                  {"id": 3, "name": SWIFT, "status": "completed", "conclusion": "success",
                   "app": {"slug": "github-actions"},
                   "details_url": f"https://github.com/{REPO}/actions/runs/11/job/5"}]
        original = self.gh.json

        def json(route, *, paginate=False):
            if route.endswith(f"commits/{HEAD}/check-runs?filter=all&per_page=100"):
                return [{"check_runs": copy.deepcopy(checks)}]
            return original(route, paginate=paginate)

        self.gh.json = json
        lines = self.judge()
        self.assertTrue(lines[0].startswith(f"ignored '{SWIFT}': its cancelled job in run 10 is superseded by job 5 "),
                        lines)
        # The other way round, the newer check run's job is older than the cancelled one: it supersedes nothing.
        checks[1]["details_url"] = f"https://github.com/{REPO}/actions/runs/11/job/0"
        with self.assertRaisesRegex(excuse.Refused, "cancelled"):
            self.judge()

    def check(self, name=SWIFT):
        return excuse.judge(REPO, "feat-cmux-next", HEAD, [], self.gh, checks=[name])

    def test_a_check_named_whose_newest_run_passed_a_cancelled_one_is_not_a_red(self):
        # gh-merge-green names a red required check by --check: GitHub's latest of the name is the green one.
        self.gh.jobs[1]["conclusion"] = "cancelled"
        self.newer("success")
        lines = self.check()
        self.assertEqual(len(lines), 1, lines)
        self.assertTrue(lines[0].startswith(f"ignored '{SWIFT}': its newest job 5 on {HEAD} is success, superseding 1 "
                                            "cancelled run(s)"), lines)

    def test_a_check_named_whose_cancelled_run_is_another_workflows_stays_a_red(self):
        self.gh.jobs[1]["conclusion"] = "cancelled"
        self.newer("success")
        self.gh.workflows = {11: 8}
        with self.assertRaisesRegex(excuse.Refused, "success"):
            self.check()

    def test_a_newer_run_of_another_workflow_supersedes_nothing(self):
        self.gh.jobs[1]["conclusion"] = "cancelled"
        self.newer("success")
        self.gh.workflows = {11: 8}
        with self.assertRaisesRegex(excuse.Refused, "cancelled"):
            self.judge()

    def test_a_newer_run_still_running_supersedes_nothing(self):
        self.gh.jobs[1]["conclusion"] = "cancelled"
        self.newer(None)
        self.gh.jobs[5]["status"] = "in_progress"
        with self.assertRaisesRegex(excuse.Refused, "cancelled"):
            self.judge()

    def test_a_cancelled_run_with_a_newer_failure_is_judged_by_that_failure(self):
        self.gh.jobs[1]["conclusion"] = "cancelled"
        self.newer("failure")
        lines = "\n".join(self.judge())
        self.assertIn(f"excused '{SWIFT}'", lines)
        self.assertNotIn("ignored", lines)

    def test_a_newer_failure_after_an_older_success_is_still_a_red(self):
        self.gh.jobs[1]["conclusion"] = "success"
        self.newer("failure")
        lines = "\n".join(self.judge(runs=(11,)))
        self.assertIn(f"excused '{SWIFT}'", lines)
        self.assertNotIn("ignored", lines)
        self.gh.logs[2] = log(SWIFT, TEST_STEP, OTHER, "##[error]1 red test: palette()")
        with self.assertRaises(excuse.Refused):
            self.judge(runs=(11,))

    def test_a_failure_with_a_newer_green_run_stays_a_red(self):
        # A failure is a verdict: a later run's green never launders it (merge_hold's _superseded_cancels).
        self.newer("success")
        lines = "\n".join(self.judge())
        self.assertIn(f"excused '{SWIFT}'", lines)
        self.assertNotIn("ignored", lines)


class SlimRunRecordGitHub(FakeGitHub):
    """A lane VM's gh chain: `actions/runs/ID` answers glaeda's 12-field run summary (no workflow_id or path), and a
    run's job list names no run_id; `actions/runs?head_sha=SHA` is REST's list (LISTED, or every run in workflow 7)."""

    SLIM = ("id", "name", "display_title", "status", "conclusion", "html_url", "head_sha", "head_branch", "event",
            "run_attempt", "created_at", "updated_at")

    def __init__(self):
        super().__init__()
        self.listed: list[dict] | None = None
        self.logged: list[int] = []

    def json(self, route, *, paginate=False):
        if "/actions/runs?head_sha=" in route:
            self.routes.append(route)
            sha = route.split("head_sha=", 1)[1].split("&", 1)[0]
            runs = self.listed if self.listed is not None else [
                {"id": run, "workflow_id": self.workflows.get(run, 7), "head_sha": sha, "event": "pull_request"}
                for run in sorted({job["run_id"] for job in self.jobs.values() if job["head_sha"] == sha})]
            return [{"total_count": len(runs), "workflow_runs": copy.deepcopy(runs)}]
        found = super().json(route, paginate=paginate)
        if route.endswith(("/jobs?filter=latest&per_page=100", "/jobs?filter=all&per_page=100")):
            return [{"jobs": [{k: v for k, v in job.items() if k != "run_id"} for page in found
                              for job in page["jobs"]]}]
        if "/actions/runs/" in route and "/jobs" not in route:
            run = int(route.rsplit("/", 1)[1])
            sha = next((job["head_sha"] for job in self.jobs.values() if job["run_id"] == run), HEAD)
            return {key: {"id": run, "name": "risk tier", "head_sha": sha, "event": "pull_request",
                          "status": "completed"}.get(key) for key in self.SLIM}
        return found

    def log(self, repo, job):
        self.logged.append(job["id"])
        return super().log(repo, job)


class SlimRunRecord(unittest.TestCase):
    """cmux#36971 at b265fe8c: on a lane VM, `actions/runs/ID` came back as glaeda's summary with no workflow_id, so a
    cancelled run that newer greens of its workflow superseded (risk-tier's 42191711726) stayed red, and cmux#37033
    asked `actions/workflows/None/runs`. The summary is completed from the head's run list (rest_run)."""

    def setUp(self):
        self.gh = SlimRunRecordGitHub()
        self.gh.workflows = {}

    def judge(self):
        return excuse.judge(REPO, "feat-cmux-next", HEAD, [10], self.gh)

    def test_a_cancel_a_newer_green_superseded_is_ignored_unlogged(self):
        self.gh.jobs[1]["conclusion"] = "cancelled"
        self.gh.jobs[5] = dict(failed_job(5, 11, HEAD), conclusion="success")
        lines = self.judge()
        self.assertEqual(len(lines), 1, lines)
        self.assertTrue(lines[0].startswith(f"ignored '{SWIFT}': its cancelled job in run 10 is superseded by job 5"),
                        lines)
        self.assertEqual(self.gh.logged, [])  # the superseded cancel's log is never read
        self.assertEqual(len([r for r in self.gh.routes if "runs?head_sha=" in r]), 1)  # one list for the head

    def test_another_workflows_green_of_the_name_supersedes_nothing(self):
        self.gh.jobs[1]["conclusion"] = "cancelled"
        self.gh.jobs[5] = dict(failed_job(5, 11, HEAD), conclusion="success")
        self.gh.workflows = {11: 8}
        with self.assertRaisesRegex(excuse.Refused, "cancelled"):
            self.judge()

    def test_a_list_that_does_not_name_the_run_keeps_the_red(self):
        self.gh.jobs[1]["conclusion"] = "cancelled"
        self.gh.jobs[5] = dict(failed_job(5, 11, HEAD), conclusion="success")
        self.gh.listed = [{"id": 11, "workflow_id": 7, "head_sha": HEAD, "event": "pull_request"}]
        with self.assertRaisesRegex(excuse.Refused, "cancelled"):
            self.judge()

    def test_a_failure_is_compared_with_its_workflows_base_runs(self):
        lines = "\n".join(self.judge())
        self.assertIn(f"excused '{SWIFT}'", lines)
        self.assertFalse([r for r in self.gh.routes if "/workflows/None/" in r], self.gh.routes)

    def test_a_failure_whose_workflow_stays_unread_is_refused_not_asked_of_none(self):
        self.gh.listed = []
        with self.assertRaisesRegex(excuse.Refused, "without its workflow_id"):
            self.judge()
        self.assertFalse([r for r in self.gh.routes if "/workflows/None/" in r], self.gh.routes)


class SupersededRunGitHub(FakeGitHub):
    """The head's run list (`actions/runs?head_sha=SHA`, LISTED): cmux#40850 at 4dd65e96, where backend-migrations runs
    42921917680 and 42921920329 were cancelled with no job while run 42921946667 of the same workflow file passed."""

    def __init__(self):
        super().__init__()
        self.listed: list[dict] = []

    def json(self, route, *, paginate=False):
        if "/actions/runs?head_sha=" in route:
            self.routes.append(route)
            return [{"total_count": len(self.listed), "workflow_runs": copy.deepcopy(self.listed)}]
        return super().json(route, paginate=paginate)


def head_run(run_id, conclusion, created, *, path=".github/workflows/backend-migrations.yml", event="pull_request",
             sha=HEAD, name="backend-migrations", **extra):
    return {"id": run_id, "name": name, "path": path, "workflow_id": 70, "event": event, "head_sha": sha,
            "status": "completed", "conclusion": conclusion, "created_at": f"2026-11-11T00:{created:02d}:00Z", **extra}


class CancelledRunSupersededByLaterGreen(unittest.TestCase):
    """dep-fleet-6: "A cancelled run counts as superseded, not red, only when all of these hold": a later run of the
    same workflow file, at the same head SHA, from the same event (for workflow_dispatch, the same inputs), created
    after the cancelled one, concluded success. Anything less stays red."""

    def setUp(self):
        self.gh = SupersededRunGitHub()
        self.gh.jobs = {}  # run 30 ran no job, as 42921917680 did
        self.gh.listed = [head_run(30, "cancelled", 1)]

    def judge(self, runs=(30,)):
        return excuse.judge(REPO, "feat-cmux-next", HEAD, list(runs), self.gh)

    def test_a_jobless_cancelled_run_a_later_green_of_its_workflow_file_superseded_is_ignored(self):
        self.gh.listed.append(head_run(31, "success", 5))
        lines = self.judge()
        self.assertEqual(len(lines), 1, lines)
        self.assertTrue(lines[0].startswith("ignored 'backend-migrations': its cancelled run 30 is superseded by run 31"),
                        lines)

    def test_every_cancelled_run_of_a_head_shares_one_run_list_read(self):
        self.gh.listed += [head_run(32, "cancelled", 2), head_run(31, "success", 5)]
        lines = self.judge(runs=(30, 32))
        self.assertEqual(len(lines), 2, lines)
        self.assertEqual(len([r for r in self.gh.routes if "runs?head_sha=" in r]), 1, self.gh.routes)

    def superseded_then(self, **later):
        """The cancelled run 30 with a later green run 31 is ignored; with LATER changed in run 31, it refuses: each
        refusal below is that one part of the rule failing, never an unread or unlisted run."""
        self.gh.listed[1:] = [head_run(31, "success", 5)]
        self.assertTrue(self.judge()[0].startswith("ignored 'backend-migrations': its cancelled run 30"))
        self.gh.listed[1:] = [head_run(31, later.pop("conclusion", "success"), later.pop("created", 5), **later)]
        with self.assertRaisesRegex(excuse.Refused, "no failed job found"):
            self.judge()

    def test_a_cancelled_run_with_no_later_run_refuses(self):
        self.gh.listed[1:] = [head_run(31, "success", 5)]
        self.assertTrue(self.judge()[0].startswith("ignored 'backend-migrations': its cancelled run 30"))
        del self.gh.listed[1:]
        with self.assertRaisesRegex(excuse.Refused, "no failed job found"):
            self.judge()

    def test_a_later_green_at_another_sha_refuses(self):
        self.superseded_then(sha="c" * 40)

    def test_a_later_green_of_another_workflow_file_with_the_same_name_refuses(self):
        self.superseded_then(path=".github/workflows/backend-migrations-2.yml")

    def test_a_later_run_that_skipped_refuses(self):
        for conclusion in ("skipped", "neutral", "cancelled"):
            with self.subTest(conclusion=conclusion):
                self.superseded_then(conclusion=conclusion)

    def test_a_green_created_before_the_cancelled_run_refuses(self):
        self.superseded_then(created=0)

    def test_a_later_green_from_another_event_refuses(self):
        self.superseded_then(event="push")

    def test_a_workflow_dispatch_with_other_inputs_refuses(self):
        self.gh.listed = [head_run(30, "cancelled", 1, event="workflow_dispatch", inputs={"lane": "a"}),
                          head_run(31, "success", 5, event="workflow_dispatch", inputs={"lane": "a"})]
        self.assertTrue(self.judge()[0].startswith("ignored 'backend-migrations': its cancelled run 30"))
        self.gh.listed[1]["inputs"] = {"lane": "b"}
        with self.assertRaisesRegex(excuse.Refused, "no failed job found"):
            self.judge()
        # Inputs GitHub's run record does not carry are unknown, never the same.
        for run in self.gh.listed:
            del run["inputs"]
        with self.assertRaisesRegex(excuse.Refused, "no failed job found"):
            self.judge()

    def test_a_superseded_run_names_each_cancelled_job_and_still_judges_a_failure(self):
        self.gh.listed.append(head_run(31, "success", 5))
        self.gh.jobs = {3: dict(failed_job(3, 30, HEAD, name="migrate"), conclusion="cancelled")}
        lines = self.judge()
        self.assertTrue(any(line.startswith("ignored 'migrate': its cancelled job 3 in run 30 is superseded by run 31")
                            for line in lines), lines)
        # A failure is a verdict: a later green never launders it (merge_hold's _superseded_cancels).
        self.gh.jobs = {1: failed_job(1, 30, HEAD), 2: failed_job(2, 20, BASE_SHA)}
        self.assertIn(f"excused '{SWIFT}'", "\n".join(self.judge()))
        self.gh.logs[2] = log(SWIFT, TEST_STEP, OTHER, "##[error]1 red test: palette()")
        with self.assertRaises(excuse.Refused):
            self.judge()


class CancelledRunWithPassedJobsSuperseded(unittest.TestCase):
    """#40963 review F1 at 1f697b4c: a cancelled run whose jobs all passed, skipped or were neutral never asked
    superseding_run, so it still read "no failed job found" though a later green run of its workflow file passed. Every
    cancelled run with no failed or timed-out job is asked; a failure or a time-out is still a verdict."""

    def setUp(self):
        self.gh = SupersededRunGitHub()
        self.gh.listed = [head_run(30, "cancelled", 1), head_run(31, "success", 5)]

    def judge(self):
        return excuse.judge(REPO, "feat-cmux-next", HEAD, [30], self.gh)

    def jobs(self, *conclusions):
        self.gh.jobs = {job_id: dict(failed_job(job_id, 30, HEAD, name=f"job {job_id}"), conclusion=conclusion)
                        for job_id, conclusion in enumerate(conclusions, start=3)}

    def test_an_all_success_cancelled_run_with_a_later_green_run_is_ignored(self):
        self.jobs("success", "success")
        lines = self.judge()
        self.assertEqual(lines[0].split(":", 1)[0], "ignored 'backend-migrations'", lines)
        self.assertIn("its cancelled run 30 is superseded by run 31", lines[0])

    def test_an_all_skipped_cancelled_run_with_a_later_green_run_is_ignored(self):
        self.jobs("skipped", "neutral")
        lines = self.judge()
        self.assertTrue(lines[0].startswith("ignored 'backend-migrations': its cancelled run 30 is superseded by run 31"),
                        lines)

    def test_a_passed_job_run_with_no_later_green_still_refuses(self):
        self.jobs("success", "skipped")
        del self.gh.listed[1:]
        with self.assertRaisesRegex(excuse.Refused, "no failed job found"):
            self.judge()

    def test_a_failed_or_timed_out_job_in_a_superseded_run_is_still_judged(self):
        self.gh.jobs = {1: failed_job(1, 30, HEAD), 2: failed_job(2, 20, BASE_SHA),
                        3: dict(failed_job(3, 30, HEAD, name="job 3"), conclusion="success")}
        self.assertIn(f"excused '{SWIFT}'", "\n".join(self.judge()))  # judged against the base, as before
        self.gh.logs[2] = log(SWIFT, TEST_STEP, OTHER, "##[error]1 red test: palette()")
        with self.assertRaises(excuse.Refused):
            self.judge()
        self.gh.jobs = {1: dict(failed_job(1, 30, HEAD), conclusion="timed_out"),
                        3: dict(failed_job(3, 30, HEAD, name="job 3"), conclusion="success")}
        with self.assertRaisesRegex(excuse.Refused, "timed_out"):
            self.judge()


class StatusOnlyChecks(unittest.TestCase):
    """A same-tree run posts 'cmux-next daemon tests (same-tree)' as a commit status, not a check run (cmux#30294):
    it is judged by the job behind it, in the run its target_url links."""

    DAEMON = "cmux-next daemon tests"
    CONTEXT = DAEMON + " (same-tree)"
    STEP = "Run the daemon tests"

    def setUp(self):
        self.gh = FakeGitHub()
        self.gh.jobs = {1: failed_job(1, 10, HEAD, name=self.DAEMON, step=self.STEP),
                        2: failed_job(2, 20, BASE_SHA, name=self.DAEMON, step=self.STEP)}
        self.gh.logs = {1: log(self.DAEMON, self.STEP, ISSUE), 2: log(self.DAEMON, self.STEP, ISSUE, OTHER)}
        self.status = {"context": self.CONTEXT, "state": "failure",
                       "target_url": f"https://github.com/{REPO}/actions/runs/10",
                       "description": "same-tree cmux-tui run: failure"}
        self.head_run = {"id": 10, "workflow_id": 7, "head_sha": HEAD, "event": "workflow_dispatch",
                         "display_title": "cmux-next · " + HEAD}
        self.listed = []
        original = self.gh.json

        def json(route, *, paginate=False):
            if route.endswith(f"commits/{HEAD}/check-runs?filter=all&per_page=100"):
                self.gh.routes.append(route)
                return [{"check_runs": []}]
            if route.endswith(f"commits/{HEAD}/status?per_page=100"):
                self.gh.routes.append(route)
                return {"statuses": [copy.deepcopy(self.status)] if self.status else []}
            if route.endswith(f"actions/runs?head_sha={HEAD}&per_page=100"):
                self.gh.routes.append(route)
                return {"workflow_runs": copy.deepcopy(self.listed)}
            if route.endswith("/actions/runs/10"):
                self.gh.routes.append(route)
                return copy.deepcopy(self.head_run)
            return original(route, paginate=paginate)

        self.gh.json = json

    def judge(self):
        return excuse.judge(REPO, "feat-cmux-next", HEAD, [], self.gh, checks=[self.CONTEXT])

    def test_a_status_red_the_base_shares_is_judged_by_its_target_runs_job_and_excused(self):
        text = "\n".join(self.judge())
        self.assertIn(self.DAEMON, text)
        self.assertIn("run 20", text)

    def test_an_excused_status_red_is_named_by_its_status_context(self):
        # merge_hold covers a red only by an audit line that starts with its own name (cmux#37038 at 1f4963c0 was
        # refused: "never named 'cmux-next daemon tests (same-tree)'" while its job's line was excused).
        lines = self.judge()
        self.assertTrue(any(line.startswith(f"excused '{self.CONTEXT}'") for line in lines), lines)
        self.assertTrue(any(line.startswith(f"excused '{self.DAEMON}'") for line in lines), lines)

    def test_every_status_judged_by_one_job_is_named(self):
        # Two contexts whose verdict is the same job: a later one must not drop the earlier one's name.
        other = dict(self.status, context=self.DAEMON)
        original = self.gh.json

        def json(route, *, paginate=False):
            found = original(route, paginate=paginate)
            if route.endswith(f"commits/{HEAD}/status?per_page=100"):
                found["statuses"].append(copy.deepcopy(other))
            return found

        self.gh.json = json
        lines = excuse.judge(REPO, "feat-cmux-next", HEAD, [], self.gh, checks=[self.CONTEXT, self.DAEMON])
        for context in (self.CONTEXT, self.DAEMON):
            self.assertTrue(any(line.startswith(f"excused '{context}': its status") for line in lines),
                            (context, lines))

    def test_a_status_red_not_on_the_base_blocks_per_test(self):
        self.gh.logs[1] = log(self.DAEMON, self.STEP, OTHER.replace("palettePages", "somethingNew"))
        with self.assertRaisesRegex(excuse.Refused, "somethingNew"):
            self.judge()

    def test_with_no_target_url_the_run_that_tested_the_head_is_used(self):
        self.status["target_url"] = ""
        self.listed = [{"id": 11, "head_sha": HEAD, "display_title": "cmux-next · " + "c" * 40},
                       self.head_run]
        self.assertIn("run 20", "\n".join(self.judge()))

    def test_a_target_run_for_another_commit_is_refused(self):
        self.head_run["display_title"] = "cmux-next tip daemon suite · " + "c" * 40
        with self.assertRaisesRegex(excuse.Refused, "which tested cccccccccccc"):
            self.judge()

    def test_a_fast_gates_red_is_the_prs_own_and_never_compared_by_the_dispatch_head(self):
        """2026-11-09, cmux#38640: a dispatched cmux-next-fast-gates.yml run tests the PR head merged into the
        feat-cmux-next tip, so its head_sha is the tip. The refusal read "its status links run 42644887804, which
        tested 144fbacf8328, not 6115...", as if the run tested another commit. A fast-gates red is never a base red:
        it is refused as the PR's own, naming the base it ran on and the run, before any head_sha comparison."""
        self.status = {"context": excuse.FAST_GATES_STATUS, "state": "failure",
                       "target_url": f"https://github.com/{REPO}/actions/runs/10", "description": f"base {BASE_SHA}"}
        self.head_run = {"id": 10, "workflow_id": 7, "head_sha": BASE_SHA, "event": "workflow_dispatch",
                         "display_title": "cmux-next fast gates"}
        with self.assertRaises(excuse.Refused) as refused:
            excuse.judge(REPO, "feat-cmux-next", HEAD, [], self.gh, checks=[excuse.FAST_GATES_STATUS])
        why = str(refused.exception)
        self.assertIn("the pull request's own", why)
        self.assertIn(f"base {BASE_SHA[:12]}", why)
        self.assertIn("run 10", why)
        self.assertNotIn("which tested", why)
        self.assertFalse([r for r in self.gh.routes if r.endswith("/actions/runs/10")])  # the status decides

    def test_a_status_whose_run_has_no_such_job_is_refused_with_its_description(self):
        # same-tree-cmux-tui posts a failure when the tree is unavailable: no daemon tests ran.
        self.gh.jobs.pop(1)
        self.status["description"] = "same-tree cmux-tui unavailable"
        with self.assertRaisesRegex(excuse.Refused, "no job 'cmux-next daemon tests' in run 10.*unavailable|"
                                                    "unavailable.*no job 'cmux-next daemon tests' in run 10"):
            self.judge()

    def test_a_pending_status_is_refused(self):
        self.status["state"] = "pending"
        with self.assertRaisesRegex(excuse.Refused, "still pending"):
            self.judge()

    def test_a_status_whose_job_passed_is_refused(self):
        self.gh.jobs[1]["conclusion"] = "success"
        with self.assertRaisesRegex(excuse.Refused, "is success"):
            self.judge()


def pr_graphql(case, calls, paths, *, number, changed=None, page=100, base_oids=()):
    """A fake GitHub.run for pr_paths' read: HEAD's PRs (another PR into feat-cmux-next with another head beside the
    one into it with HEAD), with that PR's files PAGE at a time, the cursor being the next file's index. CHANGED: the
    PR's changedFiles, when it is not how many files are listed; BASE_OIDS: its base commit on each page in turn. Each
    call's argv goes to CALLS."""

    def run(args):
        calls.append(args)
        case.assertEqual(args[:4], ["api", "graphql", "-f", f"query={excuse.PR_FILES_QUERY}"])
        case.assertIn(f"oid={HEAD}", args)
        after = args[-1].removeprefix("after=")
        start = 0 if after == "null" else int(after)
        more = start + page < len(paths)
        base_oid = base_oids[len(calls) - 1] if base_oids else "b" * 40
        pr = {"number": number, "baseRefName": "feat-cmux-next", "baseRefOid": base_oid, "headRefOid": HEAD,
              "changedFiles": len(paths) if changed is None else changed,
              "files": {"nodes": [{"path": path} for path in paths[start:start + page]],
                        "pageInfo": {"hasNextPage": more, "endCursor": str(start + page) if more else None}}}
        other = dict(pr, number=number + 1, headRefOid="0" * 40, files={"nodes": [], "pageInfo": {}})
        return json.dumps({"data": {"repository": {"object": {"associatedPullRequests": {"nodes": [other, pr]}}}}})

    return run


class JoblessStatusChecks(unittest.TestCase):
    """Vercel posts a commit status no Actions job gave (cmuxterm-hq#7039, 2026-11-04: "Deployment rate limited —
    retry in 24 hours." on the head and on main's tip alike). It is excused only when the newest base commit with
    that context has the same state and description."""

    CONTEXT = "Vercel"
    LIMITED = "Deployment rate limited — retry in 24 hours."
    TIP, OLDER = "c" * 40, "d" * 40

    def setUp(self):
        self.gh = FakeGitHub()
        self.head = {"context": self.CONTEXT, "state": "failure", "description": self.LIMITED,
                     "target_url": "https://vercel.com/manaflow?upgradeToPro=build-rate-limit"}
        self.base = {self.TIP: [dict(self.head)], self.OLDER: [dict(self.head, state="success",
                                                                    description="Deployment has completed")]}
        original = self.gh.json

        def json(route, *, paginate=False):
            self.gh.routes.append(route)
            if route.endswith(f"commits/{HEAD}/check-runs?filter=all&per_page=100"):
                return [{"check_runs": []}]
            if route.endswith(f"commits/{HEAD}/status?per_page=100"):
                return {"statuses": [copy.deepcopy(self.head)]}
            if route.endswith(f"actions/runs?head_sha={HEAD}&per_page=100"):
                return {"workflow_runs": []}
            if route.endswith("/actions/runs/10"):
                return {"id": 10, "workflow_id": 7, "head_sha": HEAD, "event": "workflow_dispatch",
                        "display_title": "cmux-next · " + HEAD}
            if route.endswith(f"commits?sha=feat-cmux-next&per_page={excuse.BASE_STATUS_COMMITS}"):
                return [{"sha": self.TIP}, {"sha": self.OLDER}]
            for sha, statuses in self.base.items():
                if route.endswith(f"commits/{sha}/status?per_page=100"):
                    return {"statuses": copy.deepcopy(statuses)}
            return original(route, paginate=paginate)

        self.gh.json = json

    def judge(self):
        return excuse.judge(REPO, "feat-cmux-next", HEAD, [], self.gh, checks=[self.CONTEXT])

    def test_the_newest_base_commit_with_the_context_decides(self):
        self.base[self.TIP] = []  # the tip has no Vercel status yet
        with self.assertRaisesRegex(excuse.Refused, f"{self.OLDER} has it success: Deployment has completed"):
            self.judge()
        self.base[self.OLDER] = [dict(self.head)]
        self.assertEqual(self.judge(), [f"excused 'Vercel': base {self.OLDER} status failure \"{self.LIMITED}\""])

    def test_another_description_on_the_base_is_refused(self):
        self.base[self.TIP] = [dict(self.head, description="Deployment failed")]
        with self.assertRaisesRegex(excuse.Refused, "has it failure: Deployment failed"):
            self.judge()

    def test_another_state_on_the_base_is_refused(self):
        self.base[self.TIP] = [dict(self.head, state="error")]
        with self.assertRaisesRegex(excuse.Refused, "has it error"):
            self.judge()

    def test_a_status_the_base_does_not_have_is_refused(self):
        self.base = {self.TIP: [], self.OLDER: [dict(self.head, context="Vercel – other-project")]}
        with self.assertRaisesRegex(excuse.Refused, "none of the 10 newest feat-cmux-next commits has a status"):
            self.judge()

    def test_a_status_with_no_description_is_refused(self):
        self.head["description"] = ""
        self.base[self.TIP] = [dict(self.head)]
        with self.assertRaisesRegex(excuse.Refused, "no description and no job"):
            self.judge()

    def test_a_status_linking_an_actions_run_is_never_judged_by_its_base_status(self):
        self.head["target_url"] = f"https://github.com/{REPO}/actions/runs/10"
        with self.assertRaisesRegex(excuse.Refused, "no job 'Vercel' in run 10"):
            self.judge()
        self.assertFalse(any("commits?sha=" in route for route in self.gh.routes))

    IGNORED = "Canceled by Ignored Build Step"

    def pr_files(self, *paths, number=7192, changed=None):
        """The GraphQL read pr_paths makes: the PR into feat-cmux-next whose head is HEAD and its files."""
        self.graphql: list[list[str]] = []
        self.gh.run = pr_graphql(self, self.graphql, paths, number=number, changed=changed)

    def test_rate_limited_vercel_is_no_result_when_the_base_skipped_its_build_and_web_is_untouched(self):
        self.base[self.TIP] = [dict(self.head, state="success", description=self.IGNORED)]
        self.pr_files("tools/fleet-reconcilers/probes.py")
        self.assertEqual(self.judge(), [
            f"excused 'Vercel': no result: \"{self.LIMITED}\" (Vercel built nothing), base status success "
            f"\"{self.IGNORED}\" (a skipped build), and #7192 changes no web/ files"])
        self.assertEqual(len(self.graphql), 1)
        self.assertFalse(any("/compare/" in route for route in self.gh.routes))  # no REST diff read

    def test_rate_limited_vercel_on_a_pr_that_touches_web_is_refused(self):
        self.base[self.TIP] = [dict(self.head, state="success", description=self.IGNORED)]
        self.pr_files("tools/x.py", "web/app/page.tsx")
        with self.assertRaisesRegex(excuse.Refused, r"#7192 changes web/ \(web/app/page.tsx\)"):
            self.judge()

    def test_another_vercel_failure_is_refused_even_when_the_base_skipped_its_build(self):
        self.head["description"] = "Deployment has failed"
        self.base[self.TIP] = [dict(self.head, state="success", description=self.IGNORED)]
        self.pr_files("tools/x.py")
        with self.assertRaisesRegex(excuse.Refused, f"has it success: {self.IGNORED}"):
            self.judge()
        self.assertEqual(self.graphql, [])

    def test_rate_limited_vercel_is_refused_when_github_lists_too_few_files(self):
        self.base[self.TIP] = [dict(self.head, state="success", description=self.IGNORED)]
        self.pr_files("tools/x.py", changed=150)
        with self.assertRaisesRegex(excuse.Refused, "listed 1 of its 150 changed files"):
            self.judge()

    def test_another_red_still_needs_its_own_excuse(self):
        self.gh.jobs[1]["name"] = "brand new red"
        self.gh.logs[1] = log("brand new red", TEST_STEP, "##[error]something new")
        with self.assertRaisesRegex(excuse.Refused, "brand new red"):
            excuse.judge(REPO, "feat-cmux-next", HEAD, [10], self.gh, checks=[self.CONTEXT])


class BaseRedWindow(unittest.TestCase):
    """2026-11-01: the tip Swift suite's red set churns (runs 41282022128, 41298073172, 41303556638), so a failing
    test is the base's when it failed on any of the newest BASE_WINDOW verdicts, read only while one is missing."""

    def setUp(self):
        self.gh = FakeGitHub()
        self.gh.logs[2] = log(SWIFT, TEST_STEP, OTHER)  # the newest red verdict lacks the head's test
        self.gh.base_runs = []
        self.reads = []
        plain = self.gh.log
        self.gh.log = lambda repo, job: (self.reads.append(job["id"]), plain(repo, job))[1]

    def base(self, run_id, hour, lines=(OTHER,), conclusion="failure"):
        self.gh.base_runs.append({"id": run_id, "event": "push", "head_branch": "feat-cmux-next",
                                  "status": "completed", "conclusion": conclusion, "head_sha": BASE_SHA,
                                  "created_at": f"2026-11-01T{hour:02d}:00:00Z"})
        self.gh.jobs[run_id] = dict(failed_job(run_id, run_id, BASE_SHA), conclusion=conclusion)
        self.gh.logs[run_id] = log(SWIFT, TEST_STEP, *lines)

    def judge(self):
        return "\n".join(excuse.judge(REPO, "feat-cmux-next", HEAD, [10], self.gh))

    def test_a_test_red_on_an_older_verdict_only_is_excused_and_named(self):
        self.base(30, 12)
        self.base(29, 11, (ISSUE,))
        text = self.judge()
        self.assertIn("run 30", text)
        self.assertIn("writesTheRequestAfterTheReadyMarkerAndReturnsTheReply() (red on run 29)", text)
        self.assertIn("runs 29", text)

    def test_the_newest_red_verdict_that_covers_every_test_reads_no_older_log(self):
        self.base(30, 12, (ISSUE,))
        self.base(29, 11, (ISSUE,))
        self.judge()
        self.assertEqual([read for read in self.reads if read != 1], [30])

    def test_a_green_verdict_ends_the_window_and_older_reds_do_not_count(self):
        # A green base run passed every test, so an older red may predate a fix.
        self.base(30, 12)
        self.base(29, 11, conclusion="success")
        self.base(28, 10, (ISSUE,))
        with self.assertRaisesRegex(excuse.Refused, "writesTheRequest"):
            self.judge()
        self.assertNotIn(28, self.reads)
        self.assertNotIn(29, self.reads)

    def test_a_test_red_only_outside_the_window_is_the_heads(self):
        for offset in range(excuse.BASE_WINDOW):
            self.base(30 - offset, 12 - offset)
        self.base(30 - excuse.BASE_WINDOW, 12 - excuse.BASE_WINDOW, (ISSUE,))
        with self.assertRaisesRegex(excuse.Refused, "writesTheRequest"):
            self.judge()
        self.assertEqual(len([read for read in self.reads if read != 1]), excuse.BASE_WINDOW)

    def test_a_verdict_older_than_the_window_hours_is_not_read(self):
        self.base(30, 12)
        self.gh.base_runs.append({"id": 29, "event": "push", "head_branch": "feat-cmux-next", "status": "completed",
                                  "conclusion": "failure", "created_at": "2026-10-31T11:00:00Z"})
        self.gh.jobs[29] = failed_job(29, 29, BASE_SHA)
        self.gh.logs[29] = log(SWIFT, TEST_STEP, ISSUE)
        with self.assertRaisesRegex(excuse.Refused, "writesTheRequest"):
            self.judge()
        self.assertNotIn(29, self.reads)

    def test_an_older_red_never_stands_over_a_newer_green(self):
        self.base(30, 12, conclusion="success")
        self.base(29, 11, (ISSUE,))
        with self.assertRaisesRegex(excuse.Refused, "not red on feat-cmux-next run 30"):
            self.judge()

    def test_a_crash_is_never_excused_by_any_window_run(self):
        self.base(30, 12)
        self.base(29, 11, (ISSUE,))
        self.gh.logs[1] = crashed(SWIFT, 6, "writesTheRequestAfterTheReadyMarkerAndReturnsTheReply", [])
        self.gh.logs[29] = self.gh.logs[1]
        with self.assertRaisesRegex(excuse.Refused, "never a base red"):
            self.judge()
        self.assertEqual([read for read in self.reads if read != 1], [])

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
CI_WEB_YML = """
on: {workflow_call: {inputs: {web: {type: string}}}}
jobs:
  scope: {runs-on: x, steps: []}
  web-tests:
    needs: scope
    name: Web tests (${{ matrix.shard }})
    strategy: {matrix: {shard: [1/2, 2/2]}}
    runs-on: x
    steps: []
  react-apps-check-shard:
    name: react-apps-check (${{ matrix.shard }})
    strategy: {matrix: {include: [{shard: 1, shard_count: 2}, {shard: 2, shard_count: 2}]}}
    runs-on: x
    steps: []
  web-status: {name: Web status, needs: [web-tests, react-apps-check-shard], runs-on: x, steps: []}
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


NEW_BASE_SHA = "d" * 40


class StaleBasePass(unittest.TestCase):
    """cmux#31338 at 222ab6e3 (2026-11-02): 'cmux-next guards / defaults-snapshot' was red on feat-cmux-next from
    #31930 on, but every base run from #31930 on was still running its slower jobs, so the newest completed run was
    41418052327 at c47a99fcb9, before #31930 and before the PR's merge-base. Its pass refused the real base red."""

    def setUp(self):
        self.gh = FakeGitHub()
        # The old completed run passed; the newest run, at the merge-base's successor, still runs but its job failed.
        self.gh.jobs[2]["conclusion"] = "success"
        self.gh.jobs[3] = failed_job(3, 30, NEW_BASE_SHA)
        self.gh.logs[3] = self.gh.logs[1]
        self.gh.base_runs = [{"id": 30, "event": "push", "head_branch": "feat-cmux-next", "status": "in_progress",
                              "conclusion": None, "head_sha": NEW_BASE_SHA},
                             {"id": 20, "event": "push", "head_branch": "feat-cmux-next", "status": "completed",
                              "conclusion": "success", "head_sha": BASE_SHA}]

    def judge(self):
        return "\n".join(excuse.judge(REPO, "feat-cmux-next", HEAD, [10], self.gh))

    def test_a_pass_before_the_merge_base_waits_for_a_newer_verdict(self):
        # The running run's job has not finished: the only verdict is the old pass, before the merge-base.
        self.gh.jobs[3].update(status="in_progress", conclusion=None)
        merge_base = NEW_BASE_SHA
        json = self.gh.json

        def answer(route, *, paginate=False):
            if f"/compare/feat-cmux-next...{HEAD}" in route:
                return {"merge_base_commit": {"sha": merge_base}, "files": []}
            if f"/compare/{merge_base}...{BASE_SHA}" in route:
                return {"status": "behind"}
            return json(route, paginate=paginate)

        self.gh.json = answer
        with self.assertRaisesRegex(excuse.Refused, "no feat-cmux-next verdict at or after this PR's merge-base yet: "
                                    "the newest, a pass in run 20, tested bbbbbbbbbbbb, which is behind"):
            self.judge()

    def test_a_pass_at_or_after_the_merge_base_still_blocks(self):
        self.gh.jobs[3].update(status="in_progress", conclusion=None)
        with self.assertRaisesRegex(excuse.Refused, "is not red on feat-cmux-next run 20"):
            self.judge()


WEB_SHARD = "web / Web tests (1/4)"
WEB_STATUS = "web / Web status"
PUSHED_BASE_SHA = "e" * 40


class WebShardBaseGitHub(FakeGitHub):
    """cmux#37667 (2026-11-07): the head's ci.yml run 10 (workflow 7) failed 'web / Web tests (1/4)'. ci.yml runs on
    pull requests only; its one feat-cmux-next run, 20, is an old dispatch at BASE_SHA, behind the PR's merge-base
    NEW_BASE_SHA. On base pushes the same ci-web.yml runs from cmux-next-web.yml: its run 40 at PUSHED_BASE_SHA, after
    the merge-base, has its own verdict for the shard."""

    def __init__(self, name=WEB_SHARD):
        super().__init__()
        self.jobs[1]["name"] = self.jobs[2]["name"] = name
        self.jobs[2]["conclusion"] = "success"
        self.jobs[4] = dict(failed_job(4, 40, PUSHED_BASE_SHA, name))
        self.logs[4] = self.logs[2]
        self.base_runs = [{"id": 20, "event": "workflow_dispatch", "head_branch": "feat-cmux-next",
                           "status": "completed", "conclusion": "success", "head_sha": BASE_SHA,
                           "created_at": "2026-10-06T10:00:00Z"}]
        self.pushed_runs = [{"id": 41, "event": "push", "head_branch": "feat-cmux-next", "status": "completed",
                             "conclusion": "cancelled", "head_sha": PUSHED_BASE_SHA,
                             "created_at": "2026-11-07T10:30:00Z"},
                            {"id": 40, "event": "push", "head_branch": "feat-cmux-next", "status": "completed",
                             "conclusion": "failure", "head_sha": PUSHED_BASE_SHA,
                             "created_at": "2026-11-07T10:00:00Z"},
                            {"id": 42, "event": "pull_request", "head_branch": "feat-cmux-next",
                             "status": "completed", "conclusion": "success", "head_sha": PUSHED_BASE_SHA,
                             "created_at": "2026-11-07T11:00:00Z"}]

    def json(self, route, *, paginate=False):
        self.routes.append(route)
        if f"/compare/feat-cmux-next...{HEAD}" in route:
            return {"merge_base_commit": {"sha": NEW_BASE_SHA}, "files": []}
        if f"/compare/{NEW_BASE_SHA}...{BASE_SHA}" in route:
            return {"status": "behind"}
        if f"/compare/{NEW_BASE_SHA}...{PUSHED_BASE_SHA}" in route:
            return {"status": "ahead"}
        if "/actions/workflows/cmux-next-web.yml/runs?" in route:
            assert "branch=feat-cmux-next" in route and "status=" not in route, route
            return {"workflow_runs": copy.deepcopy(self.pushed_runs)}
        if route.endswith("/actions/runs/10"):
            return {"id": 10, "workflow_id": 7, "name": "CI", "path": ".github/workflows/ci.yml"}
        self.routes.pop()
        return super().json(route, paginate=paginate)


class WebShardBaseVerdict(unittest.TestCase):
    """A ci.yml web shard is judged against the base runs of cmux-next-web.yml (BASE_WORKFLOW_FOR) when ci.yml has no
    feat-cmux-next verdict at or after the PR's merge-base."""

    def judge(self, gh):
        return "\n".join(excuse.judge(REPO, "feat-cmux-next", HEAD, [10], gh))

    def test_a_web_shard_red_on_the_pushed_base_after_the_merge_base_is_a_base_red(self):
        text = self.judge(WebShardBaseGitHub())
        self.assertIn(f"excused '{WEB_SHARD}'", text)
        self.assertIn("run 40", text)

    def red_web_status(self, gh):
        # ci-web.yml's Web status, red only because a web job under its needs is red (cmux#39559, hq#8503).
        gh.jobs[5] = failed_job(5, 10, HEAD, name=WEB_STATUS, step="Check routed web jobs")
        gh.logs[5] = log(WEB_STATUS, "Check routed web jobs", "web-tests: failure")
        return gh

    def test_a_red_web_status_whose_red_shards_are_all_base_reds_is_excused(self):
        for checks, runs in (([WEB_STATUS], []), ([], [10])):
            with self.subTest(checks=checks, runs=runs):
                gh = self.red_web_status(WebShardBaseGitHub())
                text = "\n".join(excuse.judge(REPO, "feat-cmux-next", HEAD, runs, gh, checks=checks))
                self.assertIn(f"excused '{WEB_SHARD}'", text)
                self.assertNotIn(f"'{WEB_STATUS}'", text)

    def test_a_red_web_status_with_one_shard_not_red_on_the_base_blocks(self):
        other = WEB_SHARD.replace("(1/4)", "(2/4)")
        for checks, runs in (([WEB_STATUS], []), ([], [10])):
            with self.subTest(checks=checks, runs=runs):
                gh = self.red_web_status(WebShardBaseGitHub())
                gh.jobs[6] = failed_job(6, 10, HEAD, name=other)
                gh.logs[6] = log(other, TEST_STEP, OTHER.replace("palettePages", "somethingNew"))
                gh.jobs[7] = dict(failed_job(7, 40, PUSHED_BASE_SHA, name=other), conclusion="success",
                                  steps=[{"name": TEST_STEP, "status": "completed", "conclusion": "success"}])
                with self.assertRaisesRegex(excuse.Refused, re.escape(other)):
                    excuse.judge(REPO, "feat-cmux-next", HEAD, runs, gh, checks=checks)

    def test_a_red_web_status_with_no_red_web_job_blocks(self):
        # Its own step failed (a bad route input, say): nothing under it to compare with the base.
        gh = self.red_web_status(WebShardBaseGitHub(name=SWIFT))
        with self.assertRaisesRegex(excuse.Refused, "no failed job under its needs"):
            excuse.judge(REPO, "feat-cmux-next", HEAD, [], gh, checks=[WEB_STATUS])

    def test_a_web_shard_green_on_the_pushed_base_is_the_prs_own_red(self):
        gh = WebShardBaseGitHub()
        gh.jobs[4].update(conclusion="success",
                          steps=[{"name": TEST_STEP, "status": "completed", "conclusion": "success"}])
        with self.assertRaisesRegex(excuse.Refused, "is not red on feat-cmux-next run 40"):
            self.judge(gh)

    def test_a_pushed_base_verdict_before_the_merge_base_does_not_decide(self):
        # cmux-next web's red tested a commit behind the merge-base too: the stale ci.yml pass still refuses.
        gh = WebShardBaseGitHub()
        json = gh.json

        def answer(route, *, paginate=False):
            if f"/compare/{NEW_BASE_SHA}...{PUSHED_BASE_SHA}" in route:
                return {"status": "behind"}
            return json(route, paginate=paginate)

        gh.json = answer
        with self.assertRaisesRegex(excuse.Refused, "no feat-cmux-next verdict at or after this PR's merge-base yet: "
                                    "the newest, a pass in run 20"):
            self.judge(gh)

    def test_a_pull_request_run_of_the_base_caller_is_never_base_evidence(self):
        gh = WebShardBaseGitHub()
        gh.pushed_runs = [run for run in gh.pushed_runs if run["event"] == "pull_request"]
        gh.jobs[4]["run_id"] = 42
        with self.assertRaisesRegex(excuse.Refused, "no feat-cmux-next verdict at or after this PR's merge-base"):
            self.judge(gh)

    def test_a_ci_yml_job_outside_the_web_caller_reads_only_ci_yml(self):
        gh = WebShardBaseGitHub(name=SWIFT)
        with self.assertRaisesRegex(excuse.Refused, "no feat-cmux-next verdict at or after this PR's merge-base yet"):
            self.judge(gh)
        self.assertFalse([route for route in gh.routes if "cmux-next-web.yml" in route], gh.routes)

    def test_a_pr_into_main_never_reads_cmux_next_web(self):
        # cmux-next web runs on pushes to feat-cmux-next only; a dispatch of it on `main` is no evidence for main.
        gh = WebShardBaseGitHub()
        json = gh.json

        def answer(route, *, paginate=False):
            route = route.replace("branch=main", "branch=feat-cmux-next").replace("/compare/main...",
                                                                               "/compare/feat-cmux-next...")
            return json(route, paginate=paginate)

        gh.json = answer
        with self.assertRaisesRegex(excuse.Refused, "no main verdict at or after this PR's merge-base yet"):
            excuse.judge(REPO, "main", HEAD, [10], gh)
        self.assertFalse([route for route in gh.routes if "cmux-next-web.yml" in route], gh.routes)

    def test_a_run_with_no_workflow_path_reads_only_its_own_workflow(self):
        gh = WebShardBaseGitHub()
        json = gh.json

        def answer(route, *, paginate=False):
            if route.endswith("/actions/runs/10"):
                return {"id": 10, "workflow_id": 7}
            return json(route, paginate=paginate)

        gh.json = answer
        with self.assertRaisesRegex(excuse.Refused, "no feat-cmux-next verdict at or after this PR's merge-base yet"):
            self.judge(gh)

    def test_each_base_caller_runs_the_same_called_job_on_base_pushes(self):
        yaml = excuse.yaml_module()
        self.assertTrue(excuse.BASE_WORKFLOW_FOR)
        for (branch, pr_file, job_id), base_file in excuse.BASE_WORKFLOW_FOR.items():
            pr = yaml.safe_load((excuse.WORKFLOWS / pr_file).read_text())
            pushed = yaml.safe_load((excuse.WORKFLOWS / base_file).read_text())
            pr_job, pushed_job = pr["jobs"][job_id], pushed["jobs"][job_id]
            # The same reusable workflow, so the same job names under the same '<id> / ' prefix.
            self.assertTrue(str(pr_job.get("uses", "")).startswith("./.github/workflows/"), pr_job)
            self.assertEqual(pr_job["uses"], pushed_job.get("uses"))
            for where, job in ((pr_file, pr_job), (base_file, pushed_job)):
                self.assertEqual(excuse._check_matcher(job_id, job, where), {"exact": [], "prefixes": [f"{job_id} / "]})
            # The base caller runs on pushes to the base; the PR caller does not (else its own runs would be read).
            pushes = (pushed.get(True, pushed.get("on")) or {}).get("push") or {}
            self.assertIn(branch, pushes.get("branches") or [])
            pr_pushes = (pr.get(True, pr.get("on")) or {}).get("push") or {}
            self.assertNotIn(branch, pr_pushes.get("branches") or [] if isinstance(pr_pushes, dict) else [])


REPLAY = "web / react-apps-base-check (4)"
HEAD_SHARD = "web / react-apps-check (4)"
CAPSULES = "test/agent-pane-no-capsules.test.ts"
CAPSULE_TEST = "agent pane page > rounds its controls as small-radius rects, not capsules"
CAPSULE_ERROR = "expect(received).toBe(expected)"
FOOTER = "test/composer-footer-plain.test.ts"


def web_log(*files, timeouts=()):
    """A webview test job's log (run-webviews-tests.sh): each file is (name, [(test, error, line)])."""
    lines = []
    for name, tests in files:
        lines += [f"START {name} (hard limit 120s)", f"FAIL {name} (raw log retained for the final bounded summary)",
                  f"##[group]FAIL {name}"]
        for test, error, at in tests:
            lines += [f"error: {error}", f"      at <anonymous> (/home/runner/_work/cmux/cmux/webviews/{name}:{at}:22)",
                      f"(fail) {test} [12.00ms]"]
        lines += [" 0 pass", f" {len(tests)} fail", "##[endgroup]"]
    for name in timeouts:
        lines += [f"START {name} (hard limit 120s)", f"TIMEOUT {name} (raw log retained for the final bounded summary)",
                  f"##[group]TIMEOUT {name}", "##[endgroup]"]
    lines.append(f"### webviews tests: 295 files, {len(files) + len(timeouts)} failed or timed out")
    lines += [f"FAIL {name} (limit 120s)" for name, _ in files] + [f"TIMEOUT {name} (limit 120s)" for name in timeouts]
    return "\n".join(f"2026-11-08T09:29:40.2315681Z {line}" for line in lines)


def replay_log(charged, shared=(), base_timeouts=(), passed_alone=()):
    """react-apps-base-check's log: the merge parent's run of the head's reds (BASE_TIMEOUTS timed out there), the
    compare, then the charged files re-run alone on the head and the compare again with that re-run (a test in
    PASSED_ALONE passed alone there: charged before it, a warning after)."""
    def compare(errors, warnings):
        return [f"##[warning]{name}" for name in warnings] + [f"##[error]{name}" for name in errors] + [
            f"{len(errors)} webview test steps red on this change, {len(warnings)} red on the base too, "
            "0 flaky on the base, 0 fixed"]
    first = list(charged) + list(passed_alone)
    lines = web_log(timeouts=base_timeouts).splitlines() + [
        f"2026-11-08T09:29:40.2315681Z {line}" for line in compare(first, shared)]
    lines += [f"2026-11-08T09:30:06.3672619Z \x1b[36;1mecho \"re-running alone on the head:\"\x1b[0m",
              "2026-11-08T09:30:06.3709644Z re-running alone on the head:"]
    lines += web_log((CAPSULES, [(CAPSULE_TEST, CAPSULE_ERROR, 87)])).splitlines()
    lines += [f"2026-11-08T09:30:07.5567707Z {line}" for line in compare(charged, list(shared) + list(passed_alone))]
    return "\n".join(lines)


def web_job(job_id, run_id, sha, name, conclusion="failure"):
    """A webview test job as the jobs API shows it: a continue-on-error step that failed reads as a success there."""
    steps = (["Re-run the change's reds alone on the head", "Fail on the change's own reds"] if "base-check" in name
             else ["Test webviews"])
    return {"id": job_id, "run_id": run_id, "head_sha": sha, "name": name, "status": "completed",
            "conclusion": conclusion, "steps": [
                {"name": "Set up runner", "status": "completed", "conclusion": "success"},
                *({"name": step, "status": "completed", "conclusion": conclusion} for step in steps)]}


class WebReplayGitHub(WebShardBaseGitHub):
    """cmux#34111 at 64617d70 (2026-11-08): the head's ci.yml run 10 failed REPLAY, its merge-parent replay, which
    charged CAPSULES > CAPSULE_TEST to the change; its head shard (4), job 3, passed and printed the test's error. No
    base push runs a replay (ci-web.yml runs it on pull requests only). feat-cmux-next's webview runs are
    cmux-next-web.yml's: run 41 cancelled (coalesced), run 40 whose shard (1), job 5, fails the same test the same way
    and whose shard (2), job 6, passed."""

    def __init__(self):
        super().__init__()
        named = f"{CAPSULES} > {CAPSULE_TEST}"
        self.jobs = {1: web_job(1, 10, HEAD, REPLAY),
                     3: web_job(3, 10, HEAD, HEAD_SHARD, "success"),
                     5: web_job(5, 40, PUSHED_BASE_SHA, "web / react-apps-check (1)"),
                     6: web_job(6, 40, PUSHED_BASE_SHA, "web / react-apps-check (2)", "success")}
        self.logs = {1: replay_log([named]), 3: web_log((CAPSULES, [(CAPSULE_TEST, CAPSULE_ERROR, 87)])),
                     5: web_log((CAPSULES, [(CAPSULE_TEST, CAPSULE_ERROR, 87)]))}
        self.per_test_only = True  # the per-test path never reads the cancelled run 41; the by-name path may
        self.pushed_runs = [run for run in self.pushed_runs if run["id"] in (40, 41)]
        for run in self.pushed_runs:
            run["updated_at"] = run["created_at"]

    def json(self, route, *, paginate=False):
        if "/actions/runs/41/" in route and self.per_test_only:
            raise AssertionError(f"a cancelled coalesced base run is never read: {route}")
        return super().json(route, paginate=paginate)

    def add_base_run(self, run_id, created, shards):
        """A newer (or older) cmux-next web run: SHARDS is {job id: (shard, log or None for a pass)}."""
        self.pushed_runs.append({"id": run_id, "event": "push", "head_branch": "feat-cmux-next",
                                 "status": "completed", "conclusion": "failure", "head_sha": PUSHED_BASE_SHA,
                                 "created_at": created, "updated_at": created})
        for job_id, (shard, text) in shards.items():
            self.jobs[job_id] = web_job(job_id, run_id, PUSHED_BASE_SHA, f"web / react-apps-check ({shard})",
                                        "success" if text is None else "failure")
            if text is not None:
                self.logs[job_id] = text


class WebviewTestReplayPerTest(unittest.TestCase):
    """A red webview replay (`web / react-apps-base-check (N)`) is judged per test against the base's webview runs:
    no base push runs a job of its name, so by name every one was refused as having no base verdict (cmux#34111)."""

    def judge(self, gh):
        return "\n".join(excuse.judge(REPO, "feat-cmux-next", HEAD, [10], gh))

    def test_a_replay_red_that_passes_on_the_base_is_its_own_and_says_which_test(self):
        gh = WebReplayGitHub()
        gh.logs[5] = web_log((FOOTER, [("rests flat", CAPSULE_ERROR, 9)]))
        with self.assertRaisesRegex(excuse.Refused, r"pass or do not run on feat-cmux-next run 40: "
                                    + re.escape(f"{CAPSULES} > {CAPSULE_TEST}")):
            self.judge(gh)

    def test_the_same_test_failing_differently_on_the_base_is_its_own(self):
        gh = WebReplayGitHub()
        gh.logs[5] = web_log((CAPSULES, [(CAPSULE_TEST, "expect(received).toEqual(expected)", 140)]))
        with self.assertRaisesRegex(excuse.Refused, "fail on none of feat-cmux-next run 40 the same way"):
            self.judge(gh)

    def test_a_file_that_timed_out_on_the_merge_parent_is_not_a_cut_short_head_run(self):
        # cmux#34111's replay (2): transcript-toggle-round-trip-browser timed out in the merge parent's run, not the
        # head's; the head's tests were still compared.
        gh = WebReplayGitHub()
        gh.logs[1] = replay_log([f"{CAPSULES} > {CAPSULE_TEST}"],
                                base_timeouts=["test/transcript-toggle-round-trip-browser.test.ts"])
        self.assertIn(f"excused '{REPLAY}'", self.judge(gh))

    def test_a_timeout_in_the_head_rerun_is_the_heads_own(self):
        gh = WebReplayGitHub()
        gh.logs[1] = gh.logs[1].replace("re-running alone on the head:", "re-running alone on the head:\n"
                                        "2026-11-08T09:30:06Z ##[group]TIMEOUT test/x.test.ts\n2026-11-08T09:30:06Z "
                                        "##[endgroup]\n2026-11-08T09:30:06Z TIMEOUT test/x.test.ts (limit 120s)")
        with self.assertRaisesRegex(excuse.Refused, "a cut-short run or a failure no parser names is never a base red"):
            self.judge(gh)

    def test_a_test_that_passed_again_alone_on_the_head_is_no_longer_charged(self):
        # The compare before the head re-run charged FOOTER too; the re-run passed it, and the final verdict warns.
        gh = WebReplayGitHub()
        gh.logs[1] = replay_log([f"{CAPSULES} > {CAPSULE_TEST}"], passed_alone=[f"{FOOTER} > rests flat"])
        self.assertIn(f"excused '{REPLAY}'", self.judge(gh))

    def test_a_test_red_on_an_older_base_run_of_the_window_is_a_base_red(self):
        gh = WebReplayGitHub()
        gh.add_base_run(50, "2026-11-07T12:00:00Z", {7: (1, web_log((FOOTER, [("rests flat", CAPSULE_ERROR, 9)])))})
        text = self.judge(gh)
        self.assertIn(f"{CAPSULES} > {CAPSULE_TEST} (feat-cmux-next run 40)", text)

    def test_a_green_base_run_ends_the_window(self):
        gh = WebReplayGitHub()
        gh.add_base_run(50, "2026-11-07T12:00:00Z", {7: (1, None), 8: (2, None)})
        with self.assertRaisesRegex(excuse.Refused, "every webview test passed on feat-cmux-next run 50"):
            self.judge(gh)
        self.assertFalse([route for route in gh.routes if "/actions/runs/40/" in route], gh.routes)

    def test_a_base_run_whose_shards_did_not_all_finish_is_passed_over(self):
        gh = WebReplayGitHub()
        gh.add_base_run(50, "2026-11-07T12:00:00Z", {7: (1, None), 8: (2, None)})
        gh.jobs[8].update(status="in_progress", conclusion=None)
        gh.pushed_runs[-1].update(status="in_progress", conclusion=None)
        self.assertIn("(feat-cmux-next run 40)", self.judge(gh))

    def test_no_base_webview_run_is_its_own(self):
        gh = WebReplayGitHub()
        gh.pushed_runs = [run for run in gh.pushed_runs if run["id"] == 41]
        with self.assertRaisesRegex(excuse.Refused, "no feat-cmux-next webview test verdict to compare"):
            self.judge(gh)

    def test_a_replay_whose_head_shard_is_missing_or_unreadable_is_its_own(self):
        gh = WebReplayGitHub()
        del gh.jobs[3]
        with self.assertRaisesRegex(excuse.Refused, "no head shard 'web / react-apps-check \\(4\\)'"):
            self.judge(gh)

    def test_an_unreadable_base_log_is_its_own(self):
        gh = WebReplayGitHub()
        log = gh.log

        def refuse(repo, job):
            if job["id"] == 5:
                raise excuse.Refused("GitHub evidence request failed: 502")
            return log(repo, job)

        gh.log = refuse
        with self.assertRaisesRegex(excuse.Refused, "no readable feat-cmux-next webview test log in feat-cmux-next "
                                    "run 40.*unread: job 5: GitHub evidence request failed: 502"):
            self.judge(gh)

    def test_a_replay_that_names_no_test_is_never_a_base_red(self):
        gh = WebReplayGitHub()
        gh.logs[1] = "2026-11-08T09:28:00Z ##[error]Process completed with exit code 1."
        with self.assertRaisesRegex(excuse.Refused, "its replay names no failing webview test"):
            self.judge(gh)

    def test_a_replay_that_also_failed_outside_its_test_steps_is_never_judged_per_test(self):
        # Review F1 on #38380: its tests match the base, but the head re-run's bundles did not build.
        gh = WebReplayGitHub()
        gh.jobs[1]["steps"].insert(1, {"name": "Build head web bundles", "status": "completed",
                                       "conclusion": "failure"})
        with self.assertRaisesRegex(excuse.Refused, "failed outside its webview test steps: Build head web bundles"):
            self.judge(gh)

    def test_a_head_shard_whose_gate_failed_keeps_its_failed_step_comparison(self):
        # Review F1 on #38380: 'Build the web bundles' (continue-on-error) failed, so 'Fail on the gate checks' did;
        # its Bun failure matching the base excuses nothing: it is judged by its name and failed steps, as before.
        gh = WebReplayGitHub()
        del gh.jobs[1]
        gh.jobs[3].update(conclusion="failure")
        gh.jobs[3]["steps"] += [{"name": "Fail on the gate checks", "status": "completed", "conclusion": "failure"}]
        gh.logs[3] += "\n2026-11-08T09:40:00Z ##[error]Gate failed; see the step 'Build the web bundles'."
        gh.per_test_only = False
        with self.assertRaises(excuse.Refused) as refused:
            self.judge(gh)
        self.assertNotIn("judged per test", str(refused.exception))

    def test_a_replay_whose_head_rerun_printed_no_final_verdict_is_refused(self):
        # Review follow-up (1) on #38380: the re-run's failures alone are no charged-test verdict.
        gh = WebReplayGitHub()
        gh.logs[1] = gh.logs[1].rsplit("##[error]", 1)[0].rsplit("\n", 1)[0]
        with self.assertRaisesRegex(excuse.Refused, "no final charged-test verdict"):
            self.judge(gh)

    def test_a_replay_whose_final_verdict_line_was_cut_off_is_refused(self):
        # Review F1 on #38434: the log ends right after "red on the base too".
        gh = WebReplayGitHub()
        gh.logs[1] = gh.logs[1].rsplit(", 0 flaky on the base, 0 fixed", 1)[0]
        with self.assertRaisesRegex(excuse.Refused, "no final charged-test verdict"):
            self.judge(gh)

    def test_a_head_shard_red_matches_the_base_in_another_shard(self):
        gh = WebReplayGitHub()
        del gh.jobs[1]
        gh.jobs[3].update(conclusion="failure")
        gh.jobs[3]["steps"][-1]["conclusion"] = "failure"
        text = self.judge(gh)
        self.assertIn(f"excused '{HEAD_SHARD}'", text)
        self.assertIn("(feat-cmux-next run 40)", text)


def cut_short_log(*results, running=()):
    """A head shard's log as GitHub keeps it after a cancel mid-run (cmux#39676's `web / react-apps-check (1)`): live
    START / PASS / FAIL lines only, then the cancel, with no `##[group]FAIL` log and no closing summary. RESULTS are
    (file, PASS|FAIL|TIMEOUT); RUNNING the files started and never finished."""
    lines = []
    for name, result in results:
        lines += [f"START {name} (hard limit 120s)", f"{result} {name} (raw log retained for the final bounded summary)"]
    lines += [f"START {name} (hard limit 51s)" for name in running]
    lines += ["##[error]The operation was canceled.", "Terminate orphan process: pid (203461) (bun)"]
    return "\n".join(f"2026-11-09T19:24:25.9168732Z {line}" for line in lines)


class CancelledWebShardPerFile(unittest.TestCase):
    """A head shard cancelled or timed out mid-run is judged per file against the base's webview runs: cmux#39676's
    `web / react-apps-check (1)` was cancelled after 31 min while every file it failed fails on feat-cmux-next too, and
    was refused as having no verdict (claude-sr2-coord, 2026-11-09)."""

    def gh(self, log, conclusion="cancelled"):
        gh = WebReplayGitHub()
        del gh.jobs[1]
        gh.jobs[3].update(conclusion=conclusion)
        gh.jobs[3]["steps"][-1]["conclusion"] = "cancelled"
        gh.logs[3] = log
        return gh

    def judge(self, gh):
        return "\n".join(excuse.judge(REPO, "feat-cmux-next", HEAD, [10], gh))

    def test_a_cancelled_shard_whose_red_files_all_fail_on_the_base_is_a_base_red(self):
        text = self.judge(self.gh(cut_short_log((FOOTER, "PASS"), (CAPSULES, "FAIL"))))
        self.assertIn(f"excused '{HEAD_SHARD}': cancelled mid-run", text)
        self.assertIn(f"{CAPSULES} (feat-cmux-next run 40)", text)

    def test_the_file_running_at_the_cancel_counts_as_red_and_must_fail_on_the_base(self):
        # cmux#39676: the cancel came during composer-plus-geometry's retry.
        text = self.judge(self.gh(cut_short_log((FOOTER, "PASS"), running=[CAPSULES]), conclusion="timed_out"))
        self.assertIn(f"excused '{HEAD_SHARD}': timed_out mid-run", text)
        with self.assertRaisesRegex(excuse.Refused, re.escape(f"1 red file(s) pass or do not run on feat-cmux-next "
                                                              f"run 40: {FOOTER}")):
            self.judge(self.gh(cut_short_log((CAPSULES, "FAIL"), running=[FOOTER])))

    def test_one_red_file_the_base_does_not_fail_is_its_own(self):
        with self.assertRaisesRegex(excuse.Refused, re.escape(f"'{HEAD_SHARD}' is cancelled; judged per file")
                                    + ".*" + re.escape(f"pass or do not run on feat-cmux-next run 40: {FOOTER}")):
            self.judge(self.gh(cut_short_log((CAPSULES, "FAIL"), (FOOTER, "FAIL"))))

    def test_a_file_that_passed_its_retry_is_a_pass(self):
        text = self.judge(self.gh(cut_short_log((FOOTER, "FAIL"), (CAPSULES, "FAIL"), (FOOTER, "PASS"))))
        self.assertIn(f"excused '{HEAD_SHARD}'", text)
        self.assertNotIn(FOOTER, text)

    def test_a_cancelled_shard_whose_log_names_no_red_file_still_has_no_verdict(self):
        with self.assertRaisesRegex(excuse.Refused, "is cancelled: it has no verdict to compare with the base"):
            self.judge(self.gh(cut_short_log((FOOTER, "PASS"), (CAPSULES, "PASS"))))

    def test_a_file_that_timed_out_on_the_head_is_its_own(self):
        with self.assertRaisesRegex(excuse.Refused, "timed out \\(a cut-short file is never a base red\\)"):
            self.judge(self.gh(cut_short_log((CAPSULES, "FAIL"), (FOOTER, "TIMEOUT"))))

    def test_a_shard_cancelled_outside_its_test_step_still_has_no_verdict(self):
        gh = self.gh(cut_short_log((CAPSULES, "FAIL")))
        gh.jobs[3]["steps"].insert(1, {"name": "Install webview dependencies", "status": "completed",
                                       "conclusion": "cancelled"})
        with self.assertRaisesRegex(excuse.Refused, "it has no verdict to compare with the base"):
            self.judge(gh)

    def test_a_green_base_run_ends_the_window(self):
        gh = self.gh(cut_short_log((CAPSULES, "FAIL")))
        gh.add_base_run(50, "2026-11-07T12:00:00Z", {7: (1, None), 8: (2, None)})
        with self.assertRaisesRegex(excuse.Refused, "every webview test passed on feat-cmux-next run 50"):
            self.judge(gh)


SIGNED_HOST = "signed host admission"
SIGNED_HOST_FILE = "nightly-next-cua-signed-host.yml"


class SignedHostGitHub(FakeGitHub):
    """cmux#37855 at 960fd459 (2026-11-07): the head's run 10 of nightly-next-cua-signed-host.yml (workflow 7) failed
    'signed host admission'. The workflow runs on pull requests and a schedule, and a schedule fires only from the
    default branch, so feat-cmux-next had no run of it at all."""

    def __init__(self):
        super().__init__()
        self.jobs[1]["name"] = self.jobs[2]["name"] = SIGNED_HOST
        self.base_runs = []
        self.dispatched: list[tuple[str, str, str]] = []

    def json(self, route, *, paginate=False):
        if route.endswith("/actions/runs/10"):
            self.routes.append(route)
            return {"id": 10, "workflow_id": 7, "name": "nightly-next Computer Use signed host",
                    "path": f".github/workflows/{SIGNED_HOST_FILE}"}
        return super().json(route, paginate=paginate)

    def dispatch(self, repo, workflow, ref):
        self.dispatched.append((repo, workflow, ref))
        return 77


class BaseDispatchForPullRequestOnlyWorkflows(unittest.TestCase):
    """A workflow in BASE_DISPATCH with no base verdict starts one dispatch on the base tip and refuses, naming it;
    the check after it completes compares against it as any base run."""

    def judge(self, gh):
        return "\n".join(excuse.judge(REPO, "feat-cmux-next", HEAD, [10], gh))

    def test_no_base_run_dispatches_once_on_the_base_tip(self):
        gh = SignedHostGitHub()
        with self.assertRaisesRegex(excuse.Refused, f"no feat-cmux-next run of its workflow has a verdict.*"
                                    f"dispatched {SIGNED_HOST_FILE} run 77 on the feat-cmux-next tip"):
            self.judge(gh)
        self.assertEqual(gh.dispatched, [(REPO, SIGNED_HOST_FILE, "feat-cmux-next")])

    def test_a_running_dispatch_is_waited_on_not_repeated(self):
        gh = SignedHostGitHub()
        gh.base_runs = [{"id": 77, "event": "workflow_dispatch", "head_branch": "feat-cmux-next",
                         "status": "in_progress", "conclusion": None, "head_sha": BASE_SHA,
                         "created_at": "2026-11-07T14:50:00Z"}]
        with self.assertRaisesRegex(excuse.Refused, "its feat-cmux-next dispatch run 77 is in_progress"):
            self.judge(gh)
        self.assertEqual(gh.dispatched, [])

    def test_a_recent_dispatch_with_no_verdict_is_not_repeated_within_the_hour(self):
        gh = SignedHostGitHub()
        gh.base_runs = [{"id": 77, "event": "workflow_dispatch", "head_branch": "feat-cmux-next",
                         "status": "completed", "conclusion": "cancelled", "head_sha": BASE_SHA,
                         "created_at": "2026-11-07T14:50:00Z"}]
        now = excuse.datetime.fromisoformat("2026-11-07T15:10:00+00:00")
        with unittest.mock.patch.object(excuse, "datetime", wraps=excuse.datetime) as clock:
            clock.now.return_value = now
            with self.assertRaisesRegex(excuse.Refused, "dispatch run 77 gave no verdict for it; "
                                        "the next dispatch starts after 15:50Z"):
                self.judge(gh)
        self.assertEqual(gh.dispatched, [])

    def test_an_old_dispatch_with_no_verdict_dispatches_again(self):
        gh = SignedHostGitHub()
        gh.base_runs = [{"id": 70, "event": "workflow_dispatch", "head_branch": "feat-cmux-next",
                         "status": "completed", "conclusion": "cancelled", "head_sha": BASE_SHA,
                         "created_at": "2026-11-06T10:00:00Z"}]
        with self.assertRaisesRegex(excuse.Refused, "dispatched .* run 77"):
            self.judge(gh)
        self.assertEqual(len(gh.dispatched), 1)

    def test_a_host_that_cannot_dispatch_says_so_and_still_refuses(self):
        gh = SignedHostGitHub()

        def refuse(repo, workflow, ref):
            raise excuse.Refused("lane-gh: the broker refuses POST")

        gh.dispatch = refuse
        with self.assertRaisesRegex(excuse.Refused, "could start from this host .*broker refuses POST"):
            self.judge(gh)

    def test_the_same_red_on_the_dispatched_base_run_is_excused(self):
        gh = SignedHostGitHub()
        gh.base_runs = [{"id": 20, "event": "workflow_dispatch", "head_branch": "feat-cmux-next",
                         "status": "completed", "conclusion": "failure", "head_sha": BASE_SHA,
                         "created_at": "2026-11-07T15:00:00Z"}]
        self.assertIn(f"excused '{SIGNED_HOST}'", self.judge(gh))
        self.assertEqual(gh.dispatched, [])

    def test_the_checks_own_fail_line_is_matched_against_the_base(self):
        # cmux#37855's head and base run 42383535506: the check's FAIL line, then only the generic exit annotation.
        said = ("FAIL: signed app pid {} never kept an accepted host connection to "
                "/var/folders/_2/149jf1ds4_gft1x2_v7b_75m0000gn/T/cmux-cua/61f287448cbb61ce/cua.sock")
        gh = SignedHostGitHub()
        gh.base_runs = [{"id": 20, "event": "workflow_dispatch", "head_branch": "feat-cmux-next",
                         "status": "completed", "conclusion": "failure", "head_sha": BASE_SHA,
                         "created_at": "2026-11-07T15:00:00Z"}]
        gh.logs[1] = log(SIGNED_HOST, TEST_STEP, said.format(1387), "##[error]Process completed with exit code 1.")
        gh.logs[2] = log(SIGNED_HOST, TEST_STEP, said.format(2201), "##[error]Process completed with exit code 1.")
        self.assertIn(f"excused '{SIGNED_HOST}'", self.judge(gh))
        gh.logs[2] = log(SIGNED_HOST, TEST_STEP, "FAIL: unsigned peer was not refused by /tmp/x.sock: 'accepted'",
                         "##[error]Process completed with exit code 1.")
        with self.assertRaises(excuse.Refused):
            self.judge(gh)

    def test_a_fail_line_is_no_error_line_for_another_job(self):
        job = failed_job(1, 10, HEAD, name=SWIFT)
        self.assertEqual(placed_signature(job, log(SWIFT, TEST_STEP, "FAIL: something"))[2], set())

    def test_a_crash_is_never_excused_even_when_the_base_dispatch_fails(self):
        gh = SignedHostGitHub()
        gh.base_runs = [{"id": 20, "event": "workflow_dispatch", "head_branch": "feat-cmux-next",
                         "status": "completed", "conclusion": "failure", "head_sha": BASE_SHA,
                         "created_at": "2026-11-07T15:00:00Z"}]
        gh.logs[1] = log(SIGNED_HOST, TEST_STEP, "Fatal error: Unexpectedly found nil", "##[error]Process completed")
        with self.assertRaisesRegex(excuse.Refused, "never a base red"):
            self.judge(gh)

    def test_a_workflow_outside_base_dispatch_never_dispatches(self):
        gh = SignedHostGitHub()
        json = gh.json

        def answer(route, *, paginate=False):
            if route.endswith("/actions/runs/10"):
                return {"id": 10, "workflow_id": 7, "path": ".github/workflows/ci.yml"}
            return json(route, paginate=paginate)

        gh.json = answer
        with self.assertRaises(excuse.Refused) as refused:
            self.judge(gh)
        self.assertNotIn("dispatch", str(refused.exception).split("tip suite runs)")[-1])
        self.assertEqual(gh.dispatched, [])

    def test_each_base_dispatch_workflow_can_be_dispatched(self):
        yaml = excuse.yaml_module()
        for branch, file in excuse.BASE_DISPATCH:
            workflow = yaml.safe_load((excuse.WORKFLOWS / file).read_text())
            triggers = workflow.get(True, workflow.get("on")) or {}
            self.assertIn("workflow_dispatch", triggers, file)


class RollupsFromNeeds(unittest.TestCase):
    """The rollups (ci-status, Guard status) and the jobs under them come from the workflows' `needs:`."""

    def derive(self, ci=CI_YML, guards=GUARDS_YML, web=CI_WEB_YML):
        with tempfile.TemporaryDirectory() as root:
            for file, text in (("ci.yml", ci), ("ci-guards.yml", guards), ("ci-web.yml", web)):
                if text is not None:
                    (Path(root) / file).write_text(text)
            return excuse.derive_rollups(Path(root))

    def test_the_committed_contract_is_the_workflows(self):
        import yaml  # noqa: F401,PLC0415 - deriving reads YAML; a host without it must not pass this silently
        self.assertEqual(json.loads(excuse.ROLLUPS_FILE.read_text()), excuse.derive_rollups(),
                         "run: python3 scripts/ci/base_red_excuse.py --write-rollups")

    def test_a_host_without_pyyaml_derives_with_the_vendored_copy(self):
        # merge_hold runs this script as `python3 -I` under Homebrew's Python, which has no PyYAML: every
        # cmuxterm-hq rollup red was refused there with "no YAML parser" (2026-11-07, hq#7398). In a fresh
        # interpreter whose `import yaml` fails, the rollups derive from the vendored copy, the same as with PyYAML.
        with tempfile.TemporaryDirectory() as root:
            (Path(root) / "ci.yml").write_text(CI_YML)
            (Path(root) / "ci-guards.yml").write_text(GUARDS_YML)
            (Path(root) / "ci-web.yml").write_text(CI_WEB_YML)
            probe = (
                "import importlib.abc, importlib.machinery, importlib.util, json, sys\n"
                "from pathlib import Path\n"
                "class OnlyVendoredYaml(importlib.abc.MetaPathFinder):\n"
                "    def find_spec(self, name, path=None, target=None):\n"
                "        if name != 'yaml':\n"
                "            return None\n"
                "        vendor = [p for p in sys.path if p.endswith('_vendor')]\n"
                "        if not vendor:\n"
                "            raise ImportError('no PyYAML on this host')\n"
                "        return importlib.machinery.PathFinder.find_spec(name, vendor)\n"
                "sys.meta_path.insert(0, OnlyVendoredYaml())\n"
                "spec = importlib.util.spec_from_file_location('bre', sys.argv[1])\n"
                "m = importlib.util.module_from_spec(spec)\n"
                "spec.loader.exec_module(m)\n"
                "print(json.dumps(m.derive_rollups(Path(sys.argv[2]))))\n"
                "print(m.yaml_module().__file__)\n")
            done = subprocess.run([sys.executable, "-I", "-c", probe, str(ROOT / "scripts/ci/base_red_excuse.py"), root],
                                  capture_output=True, text=True, timeout=60)
        self.assertEqual(done.returncode, 0, done.stderr)
        derived, where = done.stdout.strip().splitlines()
        self.assertIn(str(Path("_vendor") / "yaml" / "__init__.py"), where)
        self.assertEqual(json.loads(derived), self.derive())

    def test_needs_are_followed_and_named_as_actions_names_them(self):
        got = self.derive()
        self.assertEqual(got["run"]["ci-status"]["under"], {
            "changes": {"exact": ["changes"], "prefixes": []},
            "fast-guards": {"exact": ["CI fast guards"], "prefixes": []},
            "web": {"exact": [], "prefixes": ["web / "]}})
        # A called workflow's rollup is named, and its jobs matched, under its caller's name; a matrix job named by
        # one matrix key is each of its exact names.
        self.assertEqual(got["run"]["web / Web status"]["under"], {
            "react-apps-check-shard": {"exact": ["web / react-apps-check (1)", "web / react-apps-check (2)"],
                                       "prefixes": []},
            "scope": {"exact": ["web / scope"], "prefixes": []},
            "web-tests": {"exact": ["web / Web tests (1/2)", "web / Web tests (2/2)"], "prefixes": []}})
        self.assertNotIn("Web status", got["run"])
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
            "a called rollup whose caller calls another workflow": (dict(
                ci=CI_YML.replace("uses: ./.github/workflows/ci-web.yml", "uses: ./.github/workflows/ci-other.yml")),
                "no job web calling"),
            "a matrix name over a key the matrix lacks": (dict(
                web=CI_WEB_YML.replace("matrix.shard }})\n    strategy: {matrix: {shard:",
                                       "matrix.part }})\n    strategy: {matrix: {shard:")),
                "not one matrix key over fixed values"),
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


HQ = "manaflow-ai/cmuxterm-hq"
SKILLS_YML = """
on: {pull_request: {}}
jobs:
  scope: {name: Skill test scope, runs-on: x, steps: []}
  tests-policy: {name: Skill policy tests, needs: scope, runs-on: x, steps: []}
  tests-fleet: {name: Fleet tests, needs: scope, runs-on: x, steps: []}
  tests: {name: Skill documentation tests, needs: [scope, tests-policy, tests-fleet], if: always(), runs-on: x, steps: []}
  other: {name: Other check, runs-on: x, steps: []}
"""
SKILL_DOCS = "Skill documentation tests"


# What an agent host's gh shim (glaeda-gh's API-source guard) answers a `gh api repos/O/R/contents/...` read with.
SOURCE_REFUSAL = ("GitHub evidence request failed: glaeda-gh: reading manaflow-ai/cmuxterm-hq source through the "
                  "GitHub API spends the quota every agent on this account shares")


class HQGitHub(FakeGitHub):
    """FakeGitHub's runs as cmuxterm-hq's (base main), and HQ's skills-tests.yml at main as GraphQL serves a blob.
    A contents API read is refused, as the gh shim on an agent host refuses it."""

    def __init__(self):
        super().__init__()
        self.workflows = {"skills-tests.yml": SKILLS_YML}
        self.blobs, self.source_routes = [], []
        for job_id in (1, 2):
            self.jobs[job_id]["name"] = "Skill test scope"
        self.jobs[3] = {"id": 3, "run_id": 10, "head_sha": HEAD, "name": SKILL_DOCS, "status": "completed",
                        "conclusion": "failure", "steps": [{"name": "All parallel skill shards passed",
                                                            "conclusion": "failure"}]}

    def blob(self, repo, ref, path):
        self.blobs.append((repo, ref, path))
        assert (repo, ref) == (HQ, "main"), (repo, ref)
        file = path.removeprefix(".github/workflows/")
        if file not in self.workflows:
            raise excuse.Refused(f"{repo}@{ref}: {path} is not a text file GitHub served")
        return self.workflows[file]

    def json(self, route, *, paginate=False):
        if "/contents/" in route or "/git/blobs/" in route or "/git/trees/" in route:
            self.source_routes.append(route)
            raise excuse.Refused(SOURCE_REFUSAL)
        assert route.startswith(f"repos/{HQ}/"), route
        route = route.replace(HQ, REPO).replace("branch=main", "branch=feat-cmux-next")
        route = route.replace("/compare/main...", "/compare/feat-cmux-next...")
        return super().json(route, paginate=paginate)


class OtherRepoRollups(unittest.TestCase):
    """Another repo's rollups (OTHER_REPO_ROLLUPS) come from its own workflows at the base, not from this checkout's:
    cmuxterm-hq's Skill documentation tests only reports its shards (hq#7038, hq#7039)."""

    def setUp(self):
        self.gh = HQGitHub()
        patch = unittest.mock.patch.object(excuse, "_REPO_ROLLUPS", {})
        patch.start()
        self.addCleanup(patch.stop)

    def judge(self, runs=(10,)):
        return excuse.judge(HQ, "main", HEAD, list(runs), self.gh)

    def test_the_summary_is_judged_by_its_failed_shards(self):
        lines = "\n".join(self.judge())
        self.assertIn("'Skill test scope'", lines)
        self.assertNotIn(SKILL_DOCS, lines)
        self.assertIn((HQ, "main", ".github/workflows/skills-tests.yml"), self.gh.blobs)
        self.assertEqual(self.gh.source_routes, [], "no contents API read: the gh shim refuses it")
        self.assertEqual(set(excuse.rollups(HQ)["run"][SKILL_DOCS]["under"]), {"scope", "tests-policy", "tests-fleet"})

    def test_one_unexcused_shard_keeps_the_summary_red(self):
        # Every failed job of the run is judged: the base fails the scope shard but not the policy shard.
        self.gh.jobs[4] = failed_job(4, 10, HEAD, name="Skill policy tests")
        self.gh.logs[4] = log("Skill policy tests", TEST_STEP, "##[error]warm sources: ui-climb.yml:test")
        self.gh.jobs[5] = dict(failed_job(5, 20, BASE_SHA, name="Skill policy tests"), conclusion="success")
        with self.assertRaisesRegex(excuse.Refused, "'Skill policy tests'"):
            self.judge()

    def test_a_red_summary_with_failed_jobs_only_outside_its_needs_blocks(self):
        for job_id in (1, 2):
            self.gh.jobs[job_id]["name"] = "Other check"
        with self.assertRaisesRegex(excuse.Refused, "no failed job under its needs"):
            self.judge()

    def test_the_summary_alone_blocks(self):
        self.gh.jobs[1]["conclusion"] = "success"
        with self.assertRaisesRegex(excuse.Refused, "no failed job"):
            self.judge()

    def test_this_checkouts_rollups_are_not_another_repos(self):
        # ci-status is a cmux rollup, not an HQ one: an HQ job of that name is judged as itself.
        self.judge()
        self.assertFalse(excuse.is_aggregate("ci-status", HQ))
        self.assertTrue(excuse.is_aggregate("ci-status"))
        self.assertFalse(excuse.is_aggregate(SKILL_DOCS))

    def test_unreadable_workflows_refuse_every_rollup(self):
        for workflows, said in (({}, "unreadable"),
                                ({"skills-tests.yml": SKILLS_YML.replace("tests: {name", "summary: {name")},
                                 "no job tests")):
            with self.subTest(said), unittest.mock.patch.object(excuse, "_REPO_ROLLUPS", {}):
                self.gh.workflows = workflows
                with self.assertRaisesRegex(excuse.Refused, f"{HQ} rollups at main: .*{said}.*no rollup red is excused"):
                    self.judge()

    def test_a_repo_with_no_rollups_named_judges_every_job_as_itself(self):
        self.assertEqual(excuse.rollups("manaflow-ai/other"), excuse.NO_ROLLUPS)
        excuse.load_rollups("manaflow-ai/other", "main", self.gh)
        self.assertEqual((self.gh.routes, self.gh.source_routes, self.gh.blobs), ([], [], []))

    def test_rollups_not_read_are_refused(self):
        with self.assertRaisesRegex(excuse.Refused, "not read from its workflows"):
            excuse.rollups(HQ)


# hq#9249 (2026-11-11): a child PR into lane/rerun-guard-fixed-on-base, the head of open PR hq#9226 at d755d38b.
# Its 'Skill policy tests' (run 42988800012) failed the LaunchAgent step exactly as the parent's head did (run
# 42985609913); the lane branch has no run of its own, so it was refused as "no lane/... run ... to compare with".
LANE = "lane/rerun-guard-fixed-on-base"
PARENT_SHA = "d755d38ba189a2c4c853ad5b5b2596cf6b3ea9e0"
LAUNCHAGENT_STEP = "Shared clone maintenance LaunchAgent runs the compaction daily"
LAUNCHAGENT_RED = ("AssertionError: ['/bin/bash', '/home/runner/Library/Application Support/cmuxterm-hq/"
                   "shared-clone-maintenance/scripts/shared-clone-maintenance.sh', '/x/a&b/repo']",
                   "FAIL: plist content", "##[error]Process completed with exit code 1.")


def parent_pull(number=9226, sha=PARENT_SHA, ref=LANE, repo=HQ):
    return {"number": number, "state": "open", "head": {"ref": ref, "sha": sha, "repo": {"full_name": repo}}}


class StackedParentGitHub(HQGitHub):
    """hq#9249's shape: head run 10 (Skill policy tests red, its rollup Skill documentation tests red) into LANE, the
    head of open PR #9226 whose run 30 at PARENT_SHA has the same 'Skill policy tests' red. LANE has no push run."""

    def __init__(self):
        super().__init__()
        del self.jobs[2]
        self.base_runs = []
        self.jobs[1] = failed_job(1, 10, HEAD, name="Skill policy tests", step=LAUNCHAGENT_STEP)
        self.logs[1] = log("Skill policy tests", LAUNCHAGENT_STEP, *LAUNCHAGENT_RED)
        self.jobs[2] = failed_job(2, 30, PARENT_SHA, name="Skill policy tests", step=LAUNCHAGENT_STEP)
        self.logs[2] = log("Skill policy tests", LAUNCHAGENT_STEP, *LAUNCHAGENT_RED)
        self.pulls = [parent_pull()]
        self.tip = PARENT_SHA
        self.parent_runs = [{"id": 30, "event": "pull_request", "head_branch": LANE, "head_sha": PARENT_SHA,
                             "status": "completed", "conclusion": "failure", "workflow_id": 7,
                             "created_at": "2026-11-11T08:40:00Z"}]

    def blob(self, repo, ref, path):
        self.blobs.append((repo, ref, path))
        return SKILLS_YML

    def json(self, route, *, paginate=False):
        if route.startswith(f"repos/{HQ}/pulls?"):
            self.routes.append(route)
            assert f"head=manaflow-ai:{LANE}" in route and "state=open" in route, route
            return copy.deepcopy(self.pulls)
        if route == f"repos/{HQ}/branches/{LANE}":
            self.routes.append(route)
            return {"name": LANE, "commit": {"sha": self.tip}}
        if route.startswith(f"repos/{HQ}/actions/workflows/7/runs?head_sha="):
            self.routes.append(route)
            sha = route.split("head_sha=", 1)[1].split("&", 1)[0]
            return {"workflow_runs": [copy.deepcopy(run) for run in self.parent_runs if run["head_sha"] == sha]}
        if route.startswith(f"repos/{HQ}/actions/workflows/7/runs?branch={LANE}"):
            self.routes.append(route)
            return {"workflow_runs": []}  # a lane branch has no push or dispatch run of its own
        return super().json(route, paginate=paginate)


class StackedChildIntoLaneParent(unittest.TestCase):
    """A child PR into a lane branch that heads an open PR is judged by that parent PR's checks at its head
    (stacked_parent): identity-keyed, as any base verdict; anything less refuses."""

    def setUp(self):
        self.gh = StackedParentGitHub()
        patch = unittest.mock.patch.object(excuse, "_REPO_ROLLUPS", {})
        patch.start()
        self.addCleanup(patch.stop)

    def judge(self):
        return excuse.judge(HQ, LANE, HEAD, [10], self.gh)

    def test_hq9249_a_red_the_parents_head_has_too_is_excused(self):
        lines = "\n".join(self.judge())
        self.assertIn("excused 'Skill policy tests'", lines)
        self.assertIn(f"open PR #9226's head {PARENT_SHA[:12]}", lines)
        self.assertIn(f"repos/{HQ}/actions/workflows/7/runs?head_sha={PARENT_SHA}&per_page=100", self.gh.routes)

    def test_a_child_red_the_parents_head_does_not_have_is_refused(self):
        self.gh.logs[1] = log("Skill policy tests", LAUNCHAGENT_STEP, *LAUNCHAGENT_RED[:1],
                              "FAIL: launchd label", LAUNCHAGENT_RED[2])
        with self.assertRaisesRegex(excuse.Refused, "'Skill policy tests'.*not on lane/rerun-guard-fixed-on-base"):
            self.judge()

    def test_a_green_parent_job_makes_the_red_the_childs_own(self):
        self.gh.jobs[2] = dict(self.gh.jobs[2], conclusion="success",
                               steps=[dict(step, conclusion="success") for step in self.gh.jobs[2]["steps"]])
        with self.assertRaisesRegex(excuse.Refused, "passed on .*PR #9226 at its head d755d38ba189.*own"):
            self.judge()

    def test_a_parent_head_with_no_completed_run_is_refused(self):
        for runs in ([], [dict(self.gh.parent_runs[0], status="in_progress", conclusion=None)]):
            with self.subTest(runs=runs):
                self.gh.parent_runs = runs
                with self.assertRaisesRegex(excuse.Refused, "PR #9226's head; its head d755d38ba189 has no completed"):
                    self.judge()

    def test_a_branch_that_moved_past_its_prs_head_is_refused(self):
        self.gh.tip = "c" * 40
        with self.assertRaisesRegex(excuse.Refused, "tip cccccccccccc is not that PR's head d755d38ba189"):
            self.judge()

    def test_two_open_prs_headed_by_the_branch_judge_as_before(self):
        # Ambiguous: no parent is chosen, and the lane branch's own (absent) runs refuse as they always did.
        self.gh.pulls = [parent_pull(), parent_pull(number=9300)]
        with self.assertRaisesRegex(excuse.Refused, f"no {LANE} run of its workflow has a verdict"):
            self.judge()

    def test_a_fork_or_other_ref_is_no_parent(self):
        for pull in (parent_pull(repo="someone/cmuxterm-hq"), parent_pull(ref="lane/other")):
            with self.subTest(pull=pull):
                self.gh.pulls = [pull]
                with self.assertRaisesRegex(excuse.Refused, f"no {LANE} run of its workflow has a verdict"):
                    excuse.judge(HQ, LANE, HEAD, [10], self.gh)

    def test_an_integration_base_never_reads_a_parent(self):
        self.assertIsNone(excuse.stacked_parent(HQ, "main", self.gh, {}))
        self.assertIsNone(excuse.stacked_parent(REPO, "feat-cmux-next", self.gh, {}))
        self.assertFalse(any("/pulls?" in route for route in self.gh.routes))


SOURCE_FAKE_GH = """#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
with open(os.environ["SOURCE_GH_LOG"], "a") as log:
    log.write(json.dumps({"args": args, "override": os.environ.get("GLAEDA_GH_ALLOW_API_SOURCE")}) + "\\n")
if args[:1] == ["api"] and any("/contents/" in a or "/git/blobs/" in a or "/git/trees/" in a
                               or "raw.githubusercontent.com" in a for a in args):
    sys.stderr.write("glaeda-gh: reading source through the GitHub API spends the quota every agent shares\\n")
    sys.exit(2)
if args[:2] == ["api", "graphql"]:
    fields = dict(a.split("=", 1) for a in args[2:] if "=" in a and not a.startswith("-"))
    ref, _, path = fields["expression"].partition(":")
    found = os.path.join(os.environ["SOURCE_GH_TREE"], fields["owner"], fields["name"], ref, path)
    blob = None
    if os.path.isfile(found):
        blob = {"text": open(found).read(), "isBinary": False, "isTruncated": False}
    print(json.dumps({"data": {"repository": {"object": blob}}}))
    sys.exit(0)
sys.stderr.write("fake gh: unexpected call " + " ".join(args) + "\\n")
sys.exit(1)
"""


class GhReadByMethod(unittest.TestCase):
    """gh_read (the gh reads GitHub.run keeps for the judgement) classifies by the HTTP method gh sends (review of
    cmux#41312 at 67c48fb7, F1): an explicit GET reads, any other explicit method writes, a field or --input with no
    method is gh's POST, and a GraphQL call reads only as a query. A write is never answered from the memo."""

    R = f"repos/{REPO}/commits/{HEAD}"
    QUERY = "query($owner: String!) { repository(owner: $owner, name: \"cmux\") { id } }"
    TABLE = (
        # REST with no method and no body: GET.
        (["api", R], True),
        (["api", "--allow-escape-sequences", f"repos/{REPO}/actions/jobs/7/logs"], True),
        (["api", R, "--jq", ".sha"], True),
        (["api", "-H", "Accept: application/vnd.github+json", R], True),
        # An explicit GET reads, in every spelling; its fields are query parameters.
        (["api", "-X", "GET", R], True),
        (["api", "--method", "GET", R], True),
        (["api", "--method=GET", R], True),
        (["api", "-XGET", R], True),
        (["api", "--method", "get", R], True),
        (["api", "-X", "GET", "search/issues", "-f", "q=repo:o/r is:open"], True),
        # Any other explicit method writes.
        (["api", "-X", "POST", f"repos/{REPO}/actions/workflows/w.yml/dispatches", "-f", "ref=main"], False),
        (["api", "--method", "PATCH", f"repos/{REPO}/pulls/1"], False),
        (["api", "--method=PUT", f"repos/{REPO}/pulls/1/merge"], False),
        (["api", "-XDELETE", f"repos/{REPO}/git/refs/heads/x"], False),
        (["api", "-X", "POST", R], False),
        # A field or --input with no method is gh's POST.
        (["api", f"repos/{REPO}/issues/1/comments", "-f", "body=hi"], False),
        (["api", f"repos/{REPO}/issues/1/comments", "-F", "body=@note.md"], False),
        (["api", f"repos/{REPO}/issues/1/labels", "--field", "labels[]=x"], False),
        (["api", f"repos/{REPO}/issues/1/labels", "--raw-field=labels[]=x"], False),
        (["api", f"repos/{REPO}/issues/1/comments", "-fbody=hi"], False),
        (["api", f"repos/{REPO}/statuses/{HEAD}", "--input", "status.json"], False),
        (["api", f"repos/{REPO}/statuses/{HEAD}", "--input=-"], False),
        # GraphQL: a query reads, a mutation writes, and a body gh_read cannot see is a write.
        (["api", "graphql", "-f", f"query={QUERY}", "-f", "owner=manaflow-ai"], True),
        (["api", "graphql", "-f", "query={ viewer { login } }"], True),
        (["api", "graphql", "-F", f"query={QUERY}", "-F", "owner=manaflow-ai"], True),
        (["api", "graphql", "-f", "query=mutation { addComment(input: {}) { clientMutationId } }"], False),
        (["api", "graphql", "-f", "query=\n  mutation M { x }"], False),
        (["api", "graphql", "-F", "query=mutation{x}"], False),
        (["api", "graphql", "-F", "query=@query.graphql"], False),
        (["api", "graphql", "--input", "body.json"], False),
        (["api", "graphql", "-f", "owner=o"], False),
        # Other gh commands: `gh run view` reads; anything else is not a read gh_read knows.
        (["run", "view", "10", "--repo", REPO, "--job", "7", "--log"], True),
        (["run", "rerun", "10", "--failed"], False),
        (["pr", "merge", "1"], False),
    )

    def test_each_argv_shape_by_its_effective_method(self):
        for args, read in self.TABLE:
            with self.subTest(args=args):
                self.assertIs(excuse.gh_read(args), read)

    def test_the_clients_own_reads_are_reads(self):
        owner, _, name = REPO.partition("/")
        blob = ["api", "graphql", "-f", f"query={excuse.BLOB_QUERY}", "-f", f"owner={owner}", "-f", f"name={name}",
                "-f", f"expression={HEAD}:Package.swift"]
        self.assertTrue(excuse.gh_read(blob))
        self.assertTrue(excuse.gh_read(["api", f"repos/{REPO}/commits/{HEAD}/status", "--jq", "."]))


class OneReadPerJudgement(unittest.TestCase):
    """The real gh client at its wire (subprocess.Popen of gh, under main_fix_evidence.GitHub.run): in one judgement
    each read (`gh api` REST and GraphQL, a job's log) goes out once, however often it is asked, and a write every
    time. StaleFfiPinOfAStepARustChange's wire() counts the other entry points (git, the release downloads, the
    compile receipts) through a whole judgement."""

    def test_the_gh_client_reads_each_call_once_per_judgement(self):
        calls: Counter = Counter()

        class Gh:
            def __init__(self, argv, stdout, stderr, **kwargs):
                calls[tuple(argv)] += 1
                blob = {"text": "t", "isBinary": False, "isTruncated": False}
                stdout.write(json.dumps({"data": {"repository": {"object": blob}}} if "graphql" in argv
                                        else {"workflow_run_id": 5}).encode())
                self.returncode = 0

            def wait(self, timeout=None):
                return 0

            def kill(self):
                pass

        github = excuse.GitHub()

        def reads():
            for _ in range(2):
                github.json(f"repos/{REPO}/commits/{HEAD}")
                github.blob(REPO, HEAD, "Package.swift")
                github.log(REPO, {"id": 7, "run_id": 10})
                github.dispatch(REPO, "w.yml", "feat-cmux-next")
        with unittest.mock.patch.object(subprocess, "Popen", Gh):
            excuse.one_judgement(reads)()
            once = dict(calls)
            calls.clear()
            reads()
        writes = {argv: n for argv, n in once.items() if "POST" in argv}
        self.assertEqual(set(writes.values()), {2}, once)
        self.assertEqual({argv: n for argv, n in once.items() if argv not in writes and n != 1}, {})
        self.assertEqual(len(once), 4, once)
        # Outside a judgement every read goes out, as before.
        self.assertEqual(set(calls.values()), {2}, calls)


class SourceReads(unittest.TestCase):
    """Another repo's files (HQ's workflows, OTHER_REPO_ROLLUPS) are read with git or GraphQL, never the REST contents
    API, which an agent host's gh shim refuses as a source read. Nothing sets the shim's one-call override."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="bre-src-"))
        self.addCleanup(subprocess.run, ["rm", "-rf", str(self.tmp)])
        bin_dir = self.tmp / "bin"
        bin_dir.mkdir()
        (bin_dir / "gh").write_text(SOURCE_FAKE_GH)
        (bin_dir / "gh").chmod(0o755)
        self.log = self.tmp / "gh.log"
        self.tree = self.tmp / "tree"
        workflow = self.tree / HQ / "main/.github/workflows/skills-tests.yml"
        workflow.parent.mkdir(parents=True)
        workflow.write_text(SKILLS_YML)
        env = {key: value for key, value in os.environ.items() if key != "GLAEDA_GH_ALLOW_API_SOURCE"}
        env.update(PATH=f"{bin_dir}{os.pathsep}{os.environ.get('PATH', '')}", SOURCE_GH_LOG=str(self.log),
                   SOURCE_GH_TREE=str(self.tree), BASE_RED_EXCUSE_SOURCE_CACHE=str(self.tmp / "cache"))
        patch = unittest.mock.patch.dict(os.environ, env, clear=True)
        patch.start()
        self.addCleanup(patch.stop)
        rollups = unittest.mock.patch.object(excuse, "_REPO_ROLLUPS", {})
        rollups.start()
        self.addCleanup(rollups.stop)

    def calls(self):
        if not self.log.exists():
            return []
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def test_the_real_client_derives_hq_rollups_with_contents_reads_refused(self):
        excuse.load_rollups(HQ, "main", excuse.rate_limit_aware(excuse.GitHub()))
        self.assertEqual(set(excuse.rollups(HQ)["run"][SKILL_DOCS]["under"]), {"scope", "tests-policy", "tests-fleet"})
        calls = self.calls()
        self.assertTrue(calls)
        self.assertTrue(all(call["args"][:2] == ["api", "graphql"] for call in calls), calls)
        self.assertTrue(all(call["override"] is None for call in calls), calls)

    def test_a_missing_file_over_graphql_refuses_every_rollup(self):
        (self.tree / HQ / "main/.github/workflows/skills-tests.yml").unlink()
        with self.assertRaisesRegex(excuse.Refused, f"{HQ} rollups at main: .*not a text file.*no rollup red is excused"):
            excuse.load_rollups(HQ, "main", excuse.GitHub())

    def test_the_classifier_judges_an_hq_red_with_contents_reads_refused(self):
        gh = HQGitHub()
        gh.blob = excuse.GitHub().blob  # the real GraphQL read, through the fake gh above
        lines = "\n".join(excuse.judge(HQ, "main", HEAD, [10], gh))
        self.assertIn("'Skill test scope'", lines)
        self.assertEqual(gh.source_routes, [])
        self.assertTrue(all(call["override"] is None for call in self.calls()))

    def git(self, *args, cwd=None):
        return subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True).stdout

    def origin(self) -> Path:
        work = self.tmp / "origin"
        (work / ".github/workflows").mkdir(parents=True)
        (work / ".github/workflows/skills-tests.yml").write_text(SKILLS_YML.replace("Other check", "From git"))
        self.git("init", "-q", "-b", "main", str(work))
        self.git("-c", "user.email=t@example.com", "-c", "user.name=t", "add", ".", cwd=work)
        self.git("-c", "user.email=t@example.com", "-c", "user.name=t", "commit", "-qm", "workflows", cwd=work)
        self.git("config", "uploadpack.allowFilter", "true", cwd=work)
        return work

    def test_git_answers_first_and_spends_no_api(self):
        work = self.origin()
        with unittest.mock.patch.object(excuse, "git_text", REAL_GIT_TEXT), \
                unittest.mock.patch.object(excuse, "git_remote", lambda repo: work.as_uri()):
            text = excuse.source_text(HQ, "main", ".github/workflows/skills-tests.yml", excuse.GitHub())
            again = excuse.source_text(HQ, "main", ".github/workflows/skills-tests.yml", excuse.GitHub())
        self.assertIn("From git", text)
        self.assertEqual(text, again)
        self.assertEqual(self.calls(), [])
        cache = self.tmp / "cache" / "manaflow-ai__cmuxterm-hq.git"
        self.assertEqual(self.git("--git-dir", str(cache), "for-each-ref"), "", "the run's own fetch ref is removed")

    def test_git_that_cannot_answer_falls_back_to_graphql(self):
        missing = (self.tmp / "no-such-origin").as_uri()
        with unittest.mock.patch.object(excuse, "git_text", REAL_GIT_TEXT), \
                unittest.mock.patch.object(excuse, "git_remote", lambda repo: missing):
            text = excuse.source_text(HQ, "main", ".github/workflows/skills-tests.yml", excuse.GitHub())
        self.assertEqual(text, SKILLS_YML)
        self.assertEqual([call["args"][:2] for call in self.calls()], [["api", "graphql"]])

    def test_no_code_path_sets_the_shims_source_override(self):
        sources = [ROOT / "scripts/ci" / name for name in ("base_red_excuse.py", "main_fix_evidence.py",
                                                           "test_reds.py", "gh_pages.py")]
        sources += sorted((ROOT / ".github/workflows").glob("*.yml"))
        setting = [str(path.relative_to(ROOT)) for path in sources
                   if path.is_file() and "GLAEDA_GH_ALLOW_API_SOURCE" in path.read_text()]
        self.assertEqual(setting, [])


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


class VolatileErrorTokens(unittest.TestCase):
    """An error line naming each run's own temp dir is the same error (2026-11-04, cmux#34660's release-notary red)."""

    NOTARY = "nightly-guards / workflow-guard-tests / release-notary"
    STEP = "Validate nightly builds and signers never cancel or replace a waiting run"

    def judge(self, head_line, base_line, *extra):
        github = FakeGitHub()
        github.jobs = {1: failed_job(1, 10, HEAD, name=self.NOTARY, step=self.STEP),
                       2: failed_job(2, 20, BASE_SHA, name=self.NOTARY, step=self.STEP)}
        github.logs = {1: log(self.NOTARY, self.STEP, head_line, *extra, "##[error]Process completed with exit code 1."),
                       2: log(self.NOTARY, self.STEP, base_line, "##[error]Process completed with exit code 1.")}
        return "\n".join(excuse.judge(REPO, "feat-cmux-next", HEAD, [10], github))

    def test_the_same_error_in_another_temp_dir_is_excused(self):
        text = self.judge("##[error]publish-nightly: lease file /tmp/tmp.Pw5bL0wmeb/lease.json was never released",
                          "##[error]publish-nightly: lease file /tmp/tmp.Zq81xKcd0A/lease.json was never released")
        self.assertIn(f"excused '{self.NOTARY}'", text)
        self.assertIn("<tmp>/lease.json", text)

    def test_the_same_error_under_another_runner_temp_and_checkout_is_excused(self):
        self.assertIn("excused", self.judge(
            "error: /home/runner/work/_temp/4b1c0e2a-9f7d-4d3e-8a55-0c1f2e3d4b5a.sh: publish-nightly holds no lease",
            "error: /Users/ci/actions-runner/_work/_temp/8e2f1a3b-1c2d-4e5f-9a8b-7c6d5e4f3a2b.sh: publish-nightly "
            "holds no lease"))

    def test_another_error_in_another_temp_dir_is_still_refused(self):
        with self.assertRaisesRegex(excuse.Refused, "errors not on feat-cmux-next"):
            self.judge("##[error]publish-nightly: lease file /tmp/tmp.Pw5bL0wmeb/lease.json is corrupt",
                       "##[error]publish-nightly: lease file /tmp/tmp.Zq81xKcd0A/lease.json was never released")

    def test_a_crash_that_names_a_temp_dir_is_never_excused(self):
        crash = "error: Process '/tmp/tmp.Pw5bL0wmeb/swiftpm-testing-helper' exited with unexpected signal code 6"
        with self.assertRaisesRegex(excuse.Refused, "signal"):
            self.judge("##[error]publish-nightly: lease file /tmp/tmp.Pw5bL0wmeb/lease.json was never released",
                       "##[error]publish-nightly: lease file /tmp/tmp.Zq81xKcd0A/lease.json was never released", crash)


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
        # These are two-step `gh run view --log` excerpts of a job served whole as one step's log: they no longer map
        # one to one onto its steps, so the red is refused before any line is compared (step_owners); either refusal
        # keeps it from being excused, and the echo rule is still covered by signature() below.
        with self.assertRaisesRegex(excuse.Refused, "HomeRetryTests.failedHomeLoadRetriesTheFeedOnTheExistingLink|"
                                                    "does not map one to one onto its steps"):
            excuse.judge(REPO, "feat-cmux-next", HEAD, [10], self.gh)

    def test_echoed_script_lines_are_not_error_lines(self):
        # The base log's two steps at their real times, so step_owners places it (the jobs API's steps of run
        # 41138142557's kit job; the macOS step ends the second before the simulator step's header).
        job = dict(self.gh.jobs[2], steps=[
            {"number": 1, "name": "Set up job", "status": "completed", "conclusion": "success",
             "started_at": "2026-10-30T23:15:20Z", "completed_at": "2026-10-30T23:15:30Z"},
            {"number": 2, "name": "swift test (macOS)", "status": "completed", "conclusion": "success",
             "started_at": "2026-10-30T23:15:31Z", "completed_at": "2026-10-30T23:16:37Z"},
            {"number": 3, "name": self.STEP, "status": "completed", "conclusion": "failure",
             "started_at": "2026-10-30T23:16:38Z", "completed_at": "2026-10-30T23:29:27Z"},
            {"number": 4, "name": "Complete job", "status": "completed", "conclusion": "success",
             "started_at": "2026-10-30T23:29:27Z", "completed_at": "2026-10-30T23:29:27Z"}])
        _, tests, errors = excuse.signature(excuse.failed_view(job, self.gh.logs[2], base=True, **UNKNOWN))
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
        _, tests, errors = placed_signature(self.gh.jobs[2], self.gh.logs[2])
        self.assertEqual(tests, set())
        self.assertEqual(errors, set())

    def test_error_outside_ok_wrapper_remains_evidence(self):
        self.gh.logs[2] = log(self.KIT, self.STEP,
                              "error: cmux Computer Use.app validation failed")
        _, tests, errors = placed_signature(self.gh.jobs[2], self.gh.logs[2])
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
            if route.endswith((f"/commits/{HEAD}/status", f"/commits/{HEAD}/statuses?per_page=100&page=1")):
                return status_answer(route, self.statuses)
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

    def test_a_compile_pass_under_startup_failure_reruns_still_counts(self):
        # Review finding on #35949: GitHub's default check-runs list shows only each suite's newest attempt, so a
        # compile pass whose suite was rerun into startup_failure (no jobs) was not seen. Its last real attempt counts.
        self.release_run(5)
        hidden = self.gh.check_runs
        original = self.gh.json

        def json(route, *, paginate=False):
            if f"/commits/{HEAD}/check-runs" in route:
                return [{"check_runs": copy.deepcopy(hidden if "filter=all" in route else [])}]
            return original(route, paginate=paginate)

        self.gh.json = json
        self.assertEqual(excuse.compile_pass_at(REPO, HEAD, self.gh), f"'{self.RELEASE}' (job 1005)")
        # And a red last real attempt still decides over an older green one.
        self.release_run(6, "failure")
        self.assertIsNone(excuse.compile_pass_at(REPO, HEAD, self.gh))

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

    FALLBACK = {"context": "cmux-next/compile", "state": "success",
                "description": "The app compiled and linked in SwiftPM Release (-Onone); fallback compile, controller down"}
    LANE = {"login": "some-lane", "id": 1234, "type": "User"}

    def test_a_look_alike_compile_status_from_anyone_but_its_poster_is_not_a_pass(self):
        """Anyone who can write statuses here can post a cmux-next/compile success. Only its one poster's counts
        (COMPILE_STATUS_POSTER): a lane's or a person's look-alike, or another App's, leaves the head uncompiled."""
        for creator in (self.LANE, {**excuse.COMPILE_STATUS_POSTER, "id": 1}, {**excuse.COMPILE_STATUS_POSTER,
                        "login": "cmux-bot"}, {**excuse.COMPILE_STATUS_POSTER, "type": "User"}, None):
            with self.subTest(creator=creator):
                self.gh.statuses = [{**self.FALLBACK, "creator": creator}]
                with self.assertRaisesRegex(excuse.Refused, "no compile verdict.*nothing else compiled"):
                    self.judge()

    def test_a_look_alike_newer_than_the_posters_red_does_not_hide_it(self):
        """GitHub's combined status shows the newest per context, so a forged success posted after the poster's own
        no-verdict reads as success there. The gate takes the newest of its poster's, which did not pass."""
        self.gh.statuses = [{**self.FALLBACK, "creator": self.LANE},
                            {"context": "cmux-next/compile", "state": "failure",
                             "description": "No compile result for this head in 40 minutes"}]
        with self.assertRaisesRegex(excuse.Refused, "nothing else compiled"):
            self.judge()

    def test_the_fallback_compile_status_passes_with_the_receipts_host_down(self):
        """2026-11-10: with the controller off the receipts host answered HTTP 530 for every commit, and the fallback
        compile's verdict reached the gate only as its poster's cmux-next/compile success. That is a pass at the head
        whatever the receipts host says; it is read before the receipt."""
        def down(repo, sha):
            raise excuse.ReceiptUnreachable(f"the compile receipt of {sha[:12]}: HTTP 530")

        with unittest.mock.patch.object(excuse, "compile_receipt", down):
            self.gh.statuses = [self.FALLBACK]
            self.assertIn("ignored 'cmux-next fleet Release compile': it gave no compile verdict, but the "
                          "cmux-next/compile status compiled", "\n".join(self.judge()))
            # The look-alike is skipped, so the gate reads the receipt, which is down: no pass.
            self.gh.statuses = [{**self.FALLBACK, "creator": self.LANE}]
            with self.assertRaisesRegex(excuse.Refused, "HTTP 530"):
                self.judge()

    @staticmethod
    def timed_out(repo, sha):
        """The receipts host taking the read and never answering (cmux#40722 at 0e521d59, 2026-11-10)."""
        raise excuse.ReceiptUnreachable(f"the compile receipt of {sha[:12]}: TimeoutError: The read operation timed out")

    OVERFLOW = {"context": "cmux-next/compile", "state": "success",
                "description": "The app compiled and linked (fallback run 42900000001, recipe 2 --app --release)",
                "target_url": f"https://github.com/{REPO}/pull/40722"}

    def test_a_receipt_timeout_with_the_overflow_pass_at_the_head_is_excused(self):
        """cmux#40722: the receipts host timed out and the overflow compile had passed at the exact head. Its poster's
        success decides; a no-verdict post by its poster after it (compile-status re-run with the host down) does not
        hide it."""
        with unittest.mock.patch.object(excuse, "compile_receipt", self.timed_out):
            for later in ([], [{"context": "cmux-next/compile", "state": "error", "description":
                                "[no-verdict] No compile verdict: results service down (HTTP 000 for 300 s); re-run"}],
                          [{"context": "cmux-next/compile", "state": "pending",
                            "description": "[overflow] Results service down (HTTP 530); the overflow compile posts"}]):
                with self.subTest(later=later):
                    self.gh.statuses = later + [self.OVERFLOW]
                    self.assertIn("but the cmux-next/compile status compiled", "\n".join(self.judge()))

    def test_a_receipt_timeout_with_no_overflow_status_is_refused_naming_both(self):
        with unittest.mock.patch.object(excuse, "compile_receipt", self.timed_out):
            for statuses, newest in (([], "none posted"),
                                     ([{"context": "cmux-next/compile", "state": "pending",
                                        "description": "The Release compile (-Onone) of this head is running"}],
                                      "pending: The Release compile"),
                                     ([{**self.OVERFLOW, "creator": self.LANE}], "none posted")):
                with self.subTest(newest=newest):
                    self.gh.statuses = statuses
                    with self.assertRaisesRegex(excuse.Refused, r"TimeoutError: The read operation timed out; and no "
                                                r"cmux-next/compile success from its poster at "
                                                + HEAD[:12] + r" \(its newest: " + re.escape(newest)):
                        self.judge()

    def test_a_real_compile_failure_after_the_pass_is_not_a_pass(self):
        with unittest.mock.patch.object(excuse, "compile_receipt", self.timed_out):
            self.gh.statuses = [{"context": "cmux-next/compile", "state": "failure",
                                 "description": "The app did not compile in SwiftPM Release (-Onone); see the log"},
                                self.OVERFLOW]
            with self.assertRaisesRegex(excuse.Refused, "timed out.*its newest: failure: The app did not compile"):
                self.judge()

    def test_an_overflow_pass_at_another_sha_is_refused(self):
        """Only the head's own statuses are read: a pass at another commit (the PR's older head, the base) is never
        this head's."""
        reads = []
        real = self.gh.json

        def json(route, *, paginate=False):
            if "/statuses" in route:
                reads.append(route)
                if f"/commits/{HEAD}/" not in route:
                    return status_answer(route, [self.OVERFLOW])
            return real(route, paginate=paginate)
        self.gh.json = json
        with unittest.mock.patch.object(excuse, "compile_receipt", self.timed_out):
            self.gh.statuses = []
            with self.assertRaisesRegex(excuse.Refused, "timed out; and no cmux-next/compile success"):
                self.judge()
        self.assertTrue(reads and all(f"/commits/{HEAD}/" in route for route in reads), reads)

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

    def test_two_different_forty_hex_digests_are_not_one_red(self):
        # cmux#35902: a bare 40-hex token was masked whatever it was, so a head red naming one digest
        # matched a base red naming another and passed as a base red.
        scheme = "cmux app scheme compile (Debug)"
        self.gh.jobs = {1: failed_job(1, 10, HEAD, scheme, "Build"), 2: failed_job(2, 20, BASE_SHA, scheme, "Build")}
        line = "error: the runtime pack {} is not the one this tree pins"
        self.gh.logs[1] = log(scheme, "Build", line.format("f06132224fc58d3cd5349ed190eaadc44736abf2"))
        self.gh.logs[2] = log(scheme, "Build", line.format("2cadcc0a5426124272e806a9dca5273ce19940ea"))
        with self.assertRaisesRegex(excuse.Refused, "runtime pack"):
            self.judge()

    def test_only_commit_shas_are_masked(self):
        self.assertEqual(excuse.mask_shas(f"defaced 1234567 accede deadbeef1 {HEAD} at 8f0c2e1 tree `5948da7` "
                                          "commit 1234567 for abcdef12"),
                         "defaced 1234567 accede deadbeef1 <sha> at 8f0c2e1 tree `<sha>` commit <sha> for abcdef12")

    def test_a_forty_hex_digest_named_as_a_stored_thing_is_not_masked(self):
        # cmux#35902: every bare 40-hex token was masked, so two digests became one error line.
        digest = "f06132224fc58d3cd5349ed190eaadc44736abf2"
        for named in (f"the artifact {digest} does not match", f"runtime pack {digest} is not pinned",
                      f"checksum `{digest}` differs", f"Digest {digest} unknown"):
            self.assertEqual(excuse.mask_shas(named), named)
        # A commit the line does not name as a stored thing still masks, with or without a keyword.
        self.assertEqual(excuse.mask_shas(f"this run built {HEAD}"), "this run built <sha>")
        self.assertEqual(excuse.mask_shas(f"source stamp {HEAD} != {BASE_SHA}"), "source stamp <sha> != <sha>")

    def test_a_stored_thing_id_after_punctuation_is_not_masked(self):
        # cmux#35941 F1: the pattern took a literal space (and a backtick), so `artifact: <40-hex>` and
        # `checksum=<40-hex>` fell back to the bare branch and two differing digests compared as one red.
        digest = "f06132224fc58d3cd5349ed190eaadc44736abf2"
        for named in (f"artifact: {digest}", f"checksum={digest}", f"digest ({digest})",
                      f"hash [{digest}]", f'pack "{digest}"', f"artifact = {digest}"):
            self.assertEqual(excuse.mask_shas(named), named)

    def test_a_stored_thing_id_after_a_bracket_alone_is_not_masked(self):
        # cmux#35941 F3: the separator still needed a space or a `:`/`=` before its optional bracket, so
        # `artifact(<40-hex>)` and `pack"<40-hex>"` fell back to the bare branch and two differing digests
        # compared as one red.
        digest = "f06132224fc58d3cd5349ed190eaadc44736abf2"
        for named in (f"artifact({digest})", f'pack"{digest}"', f"bundle[{digest}]", f"digest`{digest}`",
                      f"checksum'{digest}'"):
            self.assertEqual(excuse.mask_shas(named), named)
        # Two such ids are still two error lines once every digit is masked too.
        other = "2cadcc0a5426124272e806a9dca5273ce19940ea"
        self.assertNotEqual(excuse.normalise_error(f"##[error]artifact({digest}) does not match"),
                            excuse.normalise_error(f"##[error]artifact({other}) does not match"))

    def test_a_bare_forty_hex_with_no_naming_word_is_still_masked(self):
        # The separator stays required, so the wider separator does not turn the bare branch off: a 40-hex
        # with no stored-thing word before it is each run's own commit and still masks.
        self.assertEqual(excuse.mask_shas(f"({HEAD})"), "(<sha>)")
        self.assertEqual(excuse.mask_shas(f'built "{HEAD}" from [{BASE_SHA}]'), 'built "<sha>" from [<sha>]')
        # A word that names a commit rather than a stored thing masks through a bracket too.
        self.assertEqual(excuse.mask_shas(f"tree({HEAD})"), "tree(<sha>)")
        self.assertEqual(excuse.normalise_error(f"##[error]source stamp {HEAD} != {BASE_SHA}"),
                         excuse.normalise_error(f"##[error]source stamp {BASE_SHA} != {HEAD}"))

    def test_a_preserved_id_keeps_its_digits(self):
        # cmux#35941 F2: normalise_error masks every digit after mask_shas, so two preserved ids that differ
        # only in digits still normalised the same way.
        first = "f06132224fc58d3cd5349ed190eaadc44736abf2"
        second = "f06132224fc58d3cd5349ed190eaadc44736abf3"
        self.assertNotEqual(excuse.normalise_error(f"##[error]artifact: {first} is not pinned"),
                            excuse.normalise_error(f"##[error]artifact: {second} is not pinned"))
        # The rest of the line still normalises: a run number, a duration, a pid vary run to run.
        self.assertEqual(excuse.normalise_error(f"##[error]artifact: {first} after 12 attempts"),
                         excuse.normalise_error(f"##[error]artifact: {first} after 3 attempts"))

    def test_two_different_object_digests_are_two_error_lines(self):
        first = "f06132224fc58d3cd5349ed190eaadc44736abf2"
        second = "2cadcc0a5426124272e806a9dca5273ce19940ea"
        self.assertNotEqual(excuse.normalise_error(f"##[error]artifact {first} does not match"),
                            excuse.normalise_error(f"##[error]artifact {second} does not match"))

    def test_every_compile_status_state_but_fail_is_no_verdict(self):
        """Fail closed: compile-status's own lines are a real red only for "(fail)"."""
        for line in ("cmux-next/compile is not a pass for {} (pending)", "cmux-next/compile is not a pass for {} (pass)",
                     "cmux-next/compile is not a pass for {} (last: queued)",
                     "cmux-next/compile is not a pass for {} (unavailable)", "could not post the pending status",
                     "could not post the handoff status", "could not post the overflow handoff status",
                     "bad head sha '{}'"):
            with self.subTest(line=line):
                self.gh.logs[1] = log(self.FLEET, self.STEP, "##[error]" + line.format(HEAD))
                self.gh.logs[2] = log(self.FLEET, self.STEP, "##[error]" + line.format(BASE_SHA))
                with self.assertRaisesRegex(excuse.Refused, "never a base red"):
                    self.judge()

    def test_a_real_fleet_compile_failure_is_compared_with_the_base(self):
        """With no receipt to read (InheritedCompileRed), the job is compared with the base run, as before. The
        receipt read is a fake: the test never reaches the network."""
        line = "##[error]cmux-next/compile is not a pass for {} (fail)"
        self.gh.logs[1] = log(self.FLEET, self.STEP, line.format(HEAD))
        self.gh.logs[2] = log(self.FLEET, self.STEP, line.format(BASE_SHA))
        read = []
        with unittest.mock.patch.object(excuse, "compile_receipt", lambda repo, sha: read.append(sha)):
            self.assertIn(f"excused '{self.FLEET}'", "\n".join(self.judge()))
        self.assertEqual(read, [HEAD])


class InheritedCompileRed(unittest.TestCase):
    """cmux#38644 (2026-11-09): its head da05de79 branched from feat-cmux-next at 2ff005b8df, while #39301 had broken
    the base's cmux-tui compile, so the fleet's receipt for the head read "fail" and so did the merge-base's; the base
    tip 9cb41fa7 reads "pass" since #39360. The fleet Release compile runs only on pull requests and its
    cmux-next/compile status links the source run, so neither red had a base job to compare with, and both were
    refused. The fleet's receipts are its base verdict: a head fail whose merge-base also fails is inherited."""

    PR_HEAD = "da05de79087627d246d2f281c8d49de902c8c7b9"
    MERGE_BASE = "2ff005b8df2f259ab45f008341f693eb973fc407"
    TIP = "9cb41fa7e9221ea17d2fae506dc8fa91aa788773"
    FLEET = "cmux-next fleet Release compile"
    STEP = "Wait for the fleet Release compile and publish cmux-next/compile"
    SOURCE_RUN = f"https://github.com/{REPO}/actions/runs/42593346606"

    def setUp(self):
        self.receipts = {self.PR_HEAD: "fail", self.MERGE_BASE: "fail", self.TIP: "pass"}
        self.status = {"context": "cmux-next/compile", "state": "failure", "target_url": self.SOURCE_RUN,
                       "description": "The app did not compile in SwiftPM Release (-Onone); see the log"}
        self.gh = FakeGitHub()
        self.gh.jobs = {1: failed_job(1, 10, self.PR_HEAD, self.FLEET, self.STEP)}
        self.gh.logs = {1: log(self.FLEET, self.STEP, "curl: (22) The requested URL returned error: 524",
                               "attempt 1: fail",
                               f"##[error]cmux-next/compile is not a pass for {self.PR_HEAD} (fail)",
                               "##[error]Process completed with exit code 1.")}
        original = self.gh.json

        def json(route, *, paginate=False):
            if f"/compare/feat-cmux-next...{self.PR_HEAD}" in route:
                self.gh.routes.append(route)
                return {"merge_base_commit": {"sha": self.MERGE_BASE}, "base_commit": {"sha": self.TIP}}
            if route.endswith(f"commits/{self.PR_HEAD}/check-runs?filter=all&per_page=100"):
                self.gh.routes.append(route)
                return [{"check_runs": []}]
            if route.endswith((f"commits/{self.PR_HEAD}/status?per_page=100",
                               f"commits/{self.PR_HEAD}/statuses?per_page=100&page=1")):
                self.gh.routes.append(route)
                return status_answer(route, [self.status])
            return original(route, paginate=paginate)

        self.gh.json = json

        def receipt(repo, sha):
            self.assertEqual(repo, REPO)
            state = self.receipts.get(sha)
            return None if state is None else {"repo": repo, "sha": sha, "state": state}

        patch = unittest.mock.patch.object(excuse, "compile_receipt", receipt)
        patch.start()
        self.addCleanup(patch.stop)

    def judge_status(self):
        return excuse.judge(REPO, "feat-cmux-next", self.PR_HEAD, [], self.gh, checks=["cmux-next/compile"])

    def judge_job(self):
        return excuse.judge(REPO, "feat-cmux-next", self.PR_HEAD, [10], self.gh)

    def test_the_status_red_of_a_head_whose_merge_base_fails_is_excused(self):
        audit = "\n".join(self.judge_status())
        self.assertIn("excused 'cmux-next/compile'", audit)
        self.assertIn(f"merge-base {self.MERGE_BASE[:12]}", audit)
        self.assertIn(f"feat-cmux-next {self.TIP[:12]} reads pass", audit)

    def test_the_fleet_job_red_of_a_head_whose_merge_base_fails_is_excused(self):
        audit = "\n".join(self.judge_job())
        self.assertIn(f"excused '{self.FLEET}'", audit)
        self.assertIn("inherited base red", audit)

    def test_a_head_fail_on_a_merge_base_that_passes_is_the_heads(self):
        self.receipts[self.MERGE_BASE] = "pass"
        with self.assertRaisesRegex(excuse.Refused, "the red is this head's"):
            self.judge_status()
        with self.assertRaises(excuse.Refused):
            self.judge_job()

    def test_a_head_with_no_verdict_or_no_receipt_is_never_excused(self):
        for state in ("unavailable", "running", None):
            with self.subTest(state=state):
                self.receipts[self.PR_HEAD] = state
                with self.assertRaisesRegex(excuse.Refused, "not a fail"):
                    self.judge_status()

    def test_a_merge_base_with_no_receipt_does_not_excuse(self):
        del self.receipts[self.MERGE_BASE]
        with self.assertRaisesRegex(excuse.Refused, "reads no receipt"):
            self.judge_status()

    def test_an_unread_receipt_refuses(self):
        def unread(repo, sha):
            raise excuse.Refused(f"the compile receipt of {sha[:12]}: HTTP 524")
        with unittest.mock.patch.object(excuse, "compile_receipt", unread):
            with self.assertRaisesRegex(excuse.Refused, "HTTP 524"):
                self.judge_status()


class ReceiptDownGitHubDecides(unittest.TestCase):
    """2026-11-10: the fleet controller was off and its receipts host answered HTTP 530 for every commit, so every
    compile red inherited_compile_red judged was refused on the unread receipt and the landing queue stopped on one
    service. While the host is unreachable, GitHub decides (github_compile_red): the head's cmux-next/compile fail is
    the base's only when the merge-base (or the newest base commit with one completed) fails the same way."""

    PR_HEAD = InheritedCompileRed.PR_HEAD
    MERGE_BASE = InheritedCompileRed.MERGE_BASE
    TIP = InheritedCompileRed.TIP
    OLDER = "c" * 40
    FAIL = "The app did not compile in SwiftPM Release (-Onone); see the log"

    def setUp(self):
        self.statuses = {self.PR_HEAD: ("failure", self.FAIL), self.MERGE_BASE: ("failure", self.FAIL)}
        self.gh = FakeGitHub()
        original = self.gh.json

        def json(route, *, paginate=False):
            if f"/compare/feat-cmux-next...{self.PR_HEAD}" in route:
                self.gh.routes.append(route)
                return {"merge_base_commit": {"sha": self.MERGE_BASE}, "base_commit": {"sha": self.TIP}}
            if f"commits?sha=feat-cmux-next&per_page={excuse.BASE_STATUS_COMMITS}" in route:
                self.gh.routes.append(route)
                return [{"sha": self.TIP}, {"sha": self.MERGE_BASE}, {"sha": self.OLDER}]
            for sha in (self.PR_HEAD, self.MERGE_BASE, self.TIP, self.OLDER):
                if route.endswith((f"commits/{sha}/status?per_page=100", f"commits/{sha}/status",
                                   f"commits/{sha}/statuses?per_page=100&page=1")):
                    self.gh.routes.append(route)
                    found = self.statuses.get(sha)
                    return status_answer(route, [] if found is None else [
                        {"context": "cmux-next/compile", "state": found[0], "description": found[1],
                         "target_url": InheritedCompileRed.SOURCE_RUN, **dict(found[2:])}])
            if route.endswith(f"commits/{self.PR_HEAD}/check-runs?filter=all&per_page=100"):
                return [{"check_runs": []}]
            return original(route, paginate=paginate)

        self.gh.json = json

        def down(repo, sha):
            raise excuse.ReceiptUnreachable(f"the compile receipt of {sha[:12]}: HTTP 530")

        patch = unittest.mock.patch.object(excuse, "compile_receipt", down)
        patch.start()
        self.addCleanup(patch.stop)

    def judge(self):
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            try:
                return "\n".join(excuse.judge(REPO, "feat-cmux-next", self.PR_HEAD, [], self.gh,
                                               checks=["cmux-next/compile"])), stderr.getvalue()
            finally:
                self.log = stderr.getvalue()

    def test_receipt_down_and_a_look_alike_red_on_base_excuses_nothing(self):
        """A red on the merge-base excuses the head's same red. A look-alike there, by anyone but the poster, is no
        base verdict: the gate reads the poster's newest, and with none it can't compare."""
        lane = ("creator", {"login": "some-lane", "id": 1234, "type": "User"})
        self.statuses[self.MERGE_BASE] = ("failure", self.FAIL, lane)
        with self.assertRaisesRegex(excuse.Refused, "neither path can decide"):
            self.judge()

    def test_receipt_down_and_a_flood_of_statuses_never_hides_the_merge_base_verdict(self):
        """cmux#40609 review F1: 100 statuses under another context fill the statuses list's first page. The poster's
        green at the merge-base is on page 2, so it is read there and the head's red stays its own; and when the
        flood fills every page read, the read refuses instead of reading "none" and looking for a red on another
        base commit (OLDER, which fails the same way)."""
        self.statuses[self.MERGE_BASE] = ("success", "The app compiled and linked in SwiftPM Release (-Onone)")
        self.statuses[self.OLDER] = ("failure", self.FAIL)
        flood = [{"context": "noise", "state": "success", "creator": {"login": "some-lane", "id": 1234,
                                                                       "type": "User"}}] * 100
        original = self.gh.json
        full_pages = {"n": 1}

        def json(route, *, paginate=False):
            if f"commits/{self.MERGE_BASE}/statuses?per_page=100&page=" in route:
                page = int(route.rsplit("=", 1)[1])
                if page <= full_pages["n"]:
                    return copy.deepcopy(flood)
                found = self.statuses[self.MERGE_BASE]
                return [{"context": "cmux-next/compile", "state": found[0], "description": found[1],
                         "creator": dict(excuse.COMPILE_STATUS_POSTER)}] if page == full_pages["n"] + 1 else []
            return original(route, paginate=paginate)

        self.gh.json = json
        with self.assertRaisesRegex(excuse.Refused, "the red is this head's"):
            self.judge()
        full_pages["n"] = excuse.COMPILE_STATUS_PAGES
        with self.assertRaisesRegex(excuse.Refused, "too many statuses"):
            self.judge()

    def test_receipt_down_and_the_red_also_on_base_is_excused(self):
        audit, said = self.judge()
        self.assertIn("excused 'cmux-next/compile'", audit)
        self.assertIn("HTTP 530", audit)
        self.assertIn(f"its merge-base {self.MERGE_BASE[:12]}", audit)
        self.assertIn("decided over GitHub", audit)
        self.assertIn("was decided by GitHub", said)

    def test_receipt_down_and_no_merge_base_status_uses_the_newest_completed_base_commit(self):
        del self.statuses[self.MERGE_BASE]
        self.statuses[self.TIP] = ("pending", "The Release compile (-Onone) of this head is running")
        self.statuses[self.OLDER] = ("failure", self.FAIL)
        audit, _ = self.judge()
        self.assertIn(f"feat-cmux-next {self.OLDER[:12]}", audit)

    def test_receipt_down_and_the_red_green_on_base_is_refused(self):
        self.statuses[self.MERGE_BASE] = ("success", "The app compiled and linked in SwiftPM Release (-Onone)")
        with self.assertRaisesRegex(excuse.Refused, "the red is this head's"):
            self.judge()
        self.assertIn(f"{self.MERGE_BASE[:12]} reads success", self.log)

    def test_receipt_down_and_no_base_data_is_refused_saying_why(self):
        del self.statuses[self.MERGE_BASE]
        with self.assertRaisesRegex(excuse.Refused, "HTTP 530.*no completed cmux-next/compile at its merge-base "
                                                    f"{self.MERGE_BASE[:12]}.*neither path can decide"):
            self.judge()
        self.assertIn("neither the receipts nor GitHub can decide", self.log)

    def test_receipt_down_and_a_no_verdict_head_is_never_a_base_red(self):
        no_result = ("failure", "No compile result for this head in 40 minutes")
        self.statuses[self.PR_HEAD] = self.statuses[self.MERGE_BASE] = no_result
        # Judged as no verdict (COMPILE_STATUS_NO_VERDICT): nothing else compiled the head, so it is refused.
        with self.assertRaisesRegex(excuse.Refused, "no compile verdict .*never a base red"):
            self.judge()

    def test_a_5xx_or_unreachable_host_is_unreachable_and_a_4xx_is_not(self):
        def urlopen_raising(error):
            def urlopen(request, timeout):
                raise error
            return unittest.mock.patch("urllib.request.urlopen", urlopen)
        for error in (urllib.error.HTTPError("u", 530, "x", {}, None), urllib.error.HTTPError("u", 502, "x", {}, None),
                      urllib.error.URLError("connection refused"), TimeoutError("timed out")):
            with self.subTest(error=error), urlopen_raising(error), \
                    self.assertRaises(excuse.ReceiptUnreachable):
                REAL_COMPILE_RECEIPT(REPO, HEAD)
        with urlopen_raising(urllib.error.HTTPError("u", 403, "x", {}, None)), \
                self.assertRaises(excuse.Refused) as caught:
            REAL_COMPILE_RECEIPT(REPO, HEAD)
        self.assertNotIsInstance(caught.exception, excuse.ReceiptUnreachable)


class NoVerdictCompileStatus(InheritedCompileRed):
    """2026-11-10: the controller was off from 01:00Z and its receipts answered HTTP 530, so every PR's
    cmux-next/compile read "No compile result for this head in 40 minutes", and the unread receipt refused each one
    (cmux#40041 at ab52ea3b). A no-verdict status is ignored when another compile passed at the head, as the
    no-verdict fleet job is; with none, it is refused, never compared with the base."""

    MAC = "cmux-next Release compile (Xcode 26)"

    def setUp(self):
        super().setUp()
        self.status["description"] = "No compile result for this head in 40 minutes"
        self.mac_runs = []
        routed = self.gh.json

        def json(route, *, paginate=False):
            if route.endswith(f"commits/{self.PR_HEAD}/check-runs?filter=all&per_page=100"):
                return [{"check_runs": self.mac_runs}]
            if route.endswith((f"commits/{self.PR_HEAD}/status", f"commits/{self.PR_HEAD}/statuses?per_page=100&page=1")):
                return status_answer(route, [self.status])
            if route.endswith("actions/jobs/77"):
                return {"head_sha": self.PR_HEAD, "name": self.MAC, "run_id": 70, "conclusion": "success",
                        "steps": [{"name": "Release compile", "conclusion": "success"}]}
            return routed(route, paginate=paginate)

        self.gh.json = json

        def down(repo, sha):
            raise excuse.ReceiptUnreachable(f"the compile receipt of {sha[:12]}: HTTP 530")

        patch = unittest.mock.patch.object(excuse, "compile_receipt", down)
        patch.start()
        self.addCleanup(patch.stop)

    def mac_pass(self):
        self.mac_runs.append({"id": 5, "name": self.MAC, "head_sha": self.PR_HEAD, "status": "completed",
                              "conclusion": "success", "app": {"slug": "github-actions"},
                              "details_url": f"https://github.com/{REPO}/actions/runs/70/job/77"})

    def test_a_no_verdict_status_is_ignored_when_the_mac_compile_passed(self):
        self.mac_pass()
        audit = "\n".join(self.judge_status())
        self.assertIn("ignored 'cmux-next/compile': it gave no compile verdict", audit)
        self.assertIn(f"'{self.MAC}' (job 77)", audit)

    # cmux#40667: the results service down. compile-status says so itself (no fallback runs) or compile-status-handoff
    # does (the fallback never ran), each with the [no-verdict] marker; and the same prose without it.
    SERVICE_DOWN = ("[no-verdict] No compile verdict: results service down (HTTP 530 for 300 s); no fallback compile "
                    "runs here, re-run this job",
                    "[no-verdict] No compile verdict: results service was down (HTTP 530) and no fallback compile ran; "
                    "re-run all jobs",
                    "No compile verdict: results service down (HTTP 530); no fallback compile runs here, re-run this job",
                    "[no-verdict] No compile result for this head in 40 minutes",
                    "[no-verdict] some future wording")

    def test_a_service_down_status_is_ignored_when_the_mac_compile_passed(self):
        self.mac_pass()
        for description in self.SERVICE_DOWN:
            with self.subTest(description=description):
                self.status["description"] = description
                audit = "\n".join(self.judge_status())
                self.assertIn("ignored 'cmux-next/compile': it gave no compile verdict", audit)
                self.assertIn(f"'{self.MAC}' (job 77)", audit)

    def test_a_service_down_status_with_nothing_compiled_is_refused_not_inherited(self):
        for state in ("error", "failure"):
            for description in self.SERVICE_DOWN:
                with self.subTest(state=state, description=description), \
                        unittest.mock.patch.object(excuse, "inherited_compile_red",
                                                   side_effect=AssertionError("judged as a compile red")):
                    self.status["state"], self.status["description"] = state, description
                    with self.assertRaisesRegex(excuse.Refused, "no compile verdict .* nothing else compiled"):
                        self.judge_status()

    def test_the_marker_is_what_cmux_next_yml_posts(self):
        workflow = (Path(__file__).resolve().parents[1] / ".github/workflows/cmux-next.yml").read_text(encoding="utf-8")
        self.assertGreaterEqual(workflow.count(f'"{excuse.COMPILE_STATUS_NO_VERDICT_MARKER} '), 5)

    def test_a_no_verdict_status_with_nothing_compiled_is_refused(self):
        for description in ("No compile result for this head in 40 minutes (last: running)",
                            "The compile check gave no verdict (unavailable); re-run this job",
                            "The compile result does not match this head; re-run this job"):
            with self.subTest(description=description):
                self.status["description"] = description
                with self.assertRaisesRegex(excuse.Refused, "no compile verdict .* nothing else compiled .*HTTP 530"):
                    self.judge_status()

    def test_a_compile_fail_is_never_ignored_for_a_pass_elsewhere(self):
        """A real fail goes to inherited_compile_red (receipts, else GitHub: ReceiptDownGitHubDecides), Mac pass or
        not."""
        self.mac_pass()
        self.status["description"] = "The app did not compile in SwiftPM Release (-Onone); see the log"
        with unittest.mock.patch.object(excuse, "inherited_compile_red",
                                        lambda *args: "excused 'cmux-next/compile': inherited") as inherited:
            self.assertIn("excused 'cmux-next/compile': inherited", "\n".join(self.judge_status()))

    def test_the_no_verdict_fleet_job_is_ignored_when_the_mac_compile_passed(self):
        self.gh.logs[1] = log(self.FLEET, self.STEP,
                              f"##[error]cmux-next/compile is not a pass for {self.PR_HEAD} (no result)")
        with self.assertRaisesRegex(excuse.Refused, "HTTP 530"):
            self.judge_job()
        self.mac_pass()
        self.assertIn(f"ignored '{self.FLEET}'", "\n".join(self.judge_job()))

    # The inherited-red cases are InheritedCompileRed's; this class's status is no verdict and its receipts unread.
    test_the_status_red_of_a_head_whose_merge_base_fails_is_excused = None
    test_the_fleet_job_red_of_a_head_whose_merge_base_fails_is_excused = None
    test_a_head_fail_on_a_merge_base_that_passes_is_the_heads = None
    test_a_head_with_no_verdict_or_no_receipt_is_never_excused = None
    test_a_merge_base_with_no_receipt_does_not_excuse = None
    test_an_unread_receipt_refuses = None


class CompileReceiptRead(unittest.TestCase):
    """The receipt read: one anonymous GET; a 404 is no receipt, every other failure refuses."""

    def answer(self, body=None, code=None):
        def urlopen(request, timeout):
            url = request.full_url
            self.assertIn("?repo=manaflow-ai%2Fcmux&wait=0", url)
            # The proxy refuses Python's default User-Agent with a 403: the read always names its client.
            self.assertEqual(request.get_header("User-agent"), excuse.COMPILE_RECEIPT_USER_AGENT)
            if code is not None:
                raise urllib.error.HTTPError(url, code, "x", {}, None)
            return contextlib.closing(io.BytesIO(json.dumps(body).encode()))
        return unittest.mock.patch("urllib.request.urlopen", urlopen)

    RECEIPT = {"repo": REPO, "sha": HEAD, "state": "fail", "recipe_version": 2, "configuration": "release-onone"}

    def test_the_receipt_answer_404_and_errors(self):
        with self.answer(self.RECEIPT):
            self.assertEqual(REAL_COMPILE_RECEIPT(REPO, HEAD)["state"], "fail")
        with self.answer(code=404):
            self.assertIsNone(REAL_COMPILE_RECEIPT(REPO, HEAD))
        with self.answer(code=524), self.assertRaisesRegex(excuse.Refused, "HTTP 524"):
            REAL_COMPILE_RECEIPT(REPO, HEAD)
        with self.answer(dict(self.RECEIPT, sha=BASE_SHA)), self.assertRaisesRegex(excuse.Refused, "another commit"):
            REAL_COMPILE_RECEIPT(REPO, HEAD)

    def test_a_receipt_of_another_recipe_or_configuration_refuses(self):
        """The workflow trusts only recipe 2's release-onone receipt (cmux-next.yml's compile-status step): a receipt
        of another recipe never excuses a red."""
        for other in ({"recipe_version": 1}, {"configuration": "debug"}, {"recipe_version": None}, {"configuration": None}):
            with self.subTest(other=other), self.answer(dict(self.RECEIPT, **other)), \
                    self.assertRaisesRegex(excuse.Refused, "another recipe"):
                REAL_COMPILE_RECEIPT(REPO, HEAD)


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
CAR_GUARD_STEP = "Validate the car guards"
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
    return log(GUARD, CAR_GUARD_STEP, *lines)


def ship_comment(sha, verdict="SHIP", login="teamleaderleo", at="2026-11-08T17:20:00Z"):
    """A trusted independent review receipt naming SHA, as risk_tier.py reads it."""
    return {"body": f"Review (codex gpt-6-astra high): {verdict} at {sha}", "created_at": at,
            "user": {"login": login, "type": "User"}, "author_association": "OWNER"}


class FixedOnBaseGitHub(FakeGitHub):
    """The head's guard job red; the newest base run (20, at BASE_SHA, after the merge-base) passes it."""

    def __init__(self, changed=("Sources/App/Feature.swift",), status="ahead"):
        super().__init__()
        self.jobs = {1: failed_job(1, 10, HEAD, name=GUARD, step=CAR_GUARD_STEP),
                     2: dict(failed_job(2, 20, BASE_SHA, name=GUARD, step=CAR_GUARD_STEP), conclusion="success")}
        self.logs = {1: guard_log(CAR_TEST), 2: ""}
        self.changed = list(changed)
        self.status = status
        # The pull request at HEAD (fixed_on_base_pull): open, mergeable, not risk:high, an independent SHIP at the
        # exact head, and the red job failed at the merge-base.
        self.pull = {"number": 38700, "state": "open", "mergeable": True, "mergeable_state": "clean",
                     "labels": [{"name": "risk:low"}], "user": {"login": "agent-author", "type": "User"},
                     "author_association": "MEMBER", "body": "", "head": {"sha": HEAD},
                     "base": {"ref": "feat-cmux-next"}}
        self.comments = [ship_comment(HEAD)]
        self.reviews: list[dict] = []
        self.at_merge_base = "failure"  # the red job's conclusion at MERGE_BASE, None when it has no run there

    @staticmethod
    def pages(listed, paginate):
        # GitHub.json(paginate=True)'s contract: the list of raw pages, one empty page for an empty list.
        if not paginate:
            return list(listed)
        return [list(listed[start:start + 100]) for start in range(0, len(listed), 100)] or [[]]

    def json(self, route, *, paginate=False):
        if f"/compare/feat-cmux-next...{HEAD}" in route:
            self.routes.append(route)
            return {"merge_base_commit": {"sha": MERGE_BASE}, "files": [{"filename": f} for f in self.changed]}
        if f"/compare/{MERGE_BASE}...{BASE_SHA}" in route:
            self.routes.append(route)
            return {"status": self.status}
        if route.endswith(f"/commits/{HEAD}/pulls?per_page=100"):
            self.routes.append(route)
            return [self.pull] if self.pull else []
        if self.pull and route.endswith(f"/pulls/{self.pull['number']}"):
            self.routes.append(route)
            return copy.deepcopy(self.pull)
        if self.pull and route.endswith(f"/issues/{self.pull['number']}/comments"):
            self.routes.append(route)
            return self.pages(self.comments, paginate)
        if self.pull and route.endswith(f"/pulls/{self.pull['number']}/reviews"):
            self.routes.append(route)
            return self.pages(self.reviews, paginate)
        if f"/commits/{MERGE_BASE}/check-runs?check_name=" in route:
            self.routes.append(route)
            name = urllib.parse.unquote(route.split("check_name=", 1)[1].split("&", 1)[0])
            return {"check_runs": [] if self.at_merge_base is None else
                    [{"name": name, "status": "completed", "conclusion": self.at_merge_base}]}
        return super().json(route, paginate=paginate)


KIT = "CmuxMobileKit tests (macOS swift test, iOS simulator)"
KIT_STEP = "swift test (macOS)"
KIT_TEST = ("✘ Test silentDropDetectionBenchmark() recorded an issue at LinkRecoveryTests.swift:145:9: "
            "Expectation failed: (elapsed → 13.4 seconds) <= 6.0 seconds")
KIT_CRATES = ("cmux-mobile-link", "cmux-wg", "cmux-transport")
KIT_LOCK = "\n".join(f'[[package]]\nname = "{name}"\nversion = "0.1.0"\n' for name in KIT_CRATES) + (
    '[[package]]\nname = "tokio"\nversion = "1.0.0"\nsource = "registry+https://github.com/rust-lang/crates.io-index"\n')
KIT_FILES = {
    "cmux-next-ios/CmuxMobileKit/Package.swift": '.package(path: "../../Packages/Shared/CmuxGhosttyKit"),\n'
                                                 '.package(path: "../../vendor/stack-auth-swift-sdk-prerelease"),',
    "Packages/Shared/CmuxGhosttyKit/Package.swift": '.package(name: "CmuxTabsKit", path: "../../iOS/CmuxTabsKit")',
    "Packages/iOS/CmuxTabsKit/Package.swift": "",
    "vendor/stack-auth-swift-sdk-prerelease/Package.swift": "",
    "cmux-next-ios/rust/Cargo.lock": KIT_LOCK,
    "cmux-next-ios/rust/Cargo.toml": '[workspace]\nmembers = ["crates/cmux-mobile-link"]\n'
                                     '[workspace.dependencies]\ncmux-wg = { path = "../../cmux-tui/crates/cmux-wg" }\n',
    "cmux-next-ios/rust/crates/cmux-mobile-link/Cargo.toml": '[package]\nname = "cmux-mobile-link"\n'
                                                             '[dependencies]\ncmux-wg.workspace = true\n',
    "cmux-tui/Cargo.toml": '[workspace]\nmembers = ["crates/cmux-wg"]\n[workspace.dependencies]\ntokio = "1"\n'
                           'cmux-transport = { path = "crates/cmux-transport" }\n',
    "cmux-tui/crates/cmux-wg/Cargo.toml": '[package]\nname = "cmux-wg"\n[dependencies]\ntokio.workspace = true\n'
                                          'cmux-transport.workspace = true\n',
    "cmux-tui/crates/cmux-transport/Cargo.toml": '[package]\nname = "cmux-transport"\n',
}


KIT_BUILD = "Build package and tests"
KIT_SIM = "xcodebuild test (iOS simulator)"
# (step, conclusion, started second, completed second) and (step, second, text): framed_steps and framed_log's form.
KIT_STEPS = [(KIT_BUILD, "success", 3, 9), (KIT_STEP, "failure", 10, 20)]


def kit_lines(*after):
    return [(KIT_BUILD, 3, "##[group]Run swift build --package-path cmux-next-ios/CmuxMobileKit --build-tests"),
            (KIT_STEP, 10, "##[group]Run swift test --package-path cmux-next-ios/CmuxMobileKit"),
            (KIT_STEP, 19, KIT_TEST),
            (KIT_STEP, 19, "✘ Test silentDropDetectionBenchmark() failed after 13.4 seconds with 1 issue."),
            (KIT_STEP, 19, "##[error]Process completed with exit code 1."), *after]


class KitFixedOnBaseGitHub(FixedOnBaseGitHub):
    """CmuxMobileKit's job red on the head (cmux#36988 at d286aa2f); the newest base run passes it. Its log is framed
    like the job-log endpoint's: "Set up job", a STEP_START line per step, "Complete job" (step_owners)."""

    def __init__(self, changed=("cmux-tui/crates/cmux-agent-pane-policy/policy.json",
                                "cmux-next-ios/verify/parity-mac.md", "webviews/src/App.tsx"), files=None):
        super().__init__(changed=changed)
        self.jobs = {1: dict(failed_job(1, 10, HEAD, name=KIT, step=KIT_STEP), steps=framed_steps(KIT_STEPS)),
                     2: dict(failed_job(2, 20, BASE_SHA, name=KIT, step=KIT_STEP), conclusion="success")}
        self.logs = {1: framed_log(kit_lines(), KIT), 2: ""}
        self.files = dict(KIT_FILES if files is None else files)

    def frame(self, steps, lines):
        """The head job's STEPS and its log of LINES, as framed_steps and framed_log write them."""
        self.jobs[1]["steps"] = framed_steps(steps)
        self.logs[1] = framed_log(lines, KIT)

    def blob(self, repo, ref, path):
        assert ref == HEAD, ref
        if path not in self.files:
            raise excuse.Refused(f"{repo}@{ref}: {path} is not a text file GitHub served")
        return self.files[path]


class TrackedTree:
    """This checkout's tree as the classifier reads a tree at a sha: every path git tracks, its text from the working
    tree when it is checked out, else from the index. A sparse checkout leaves whole folders (cmux-next-ios among
    them) out of the working tree, so a reader of the working tree alone sees a cargo root the code under test reaches
    as missing. Nothing here names a root: whatever the code discovers, the tree serves."""

    def __init__(self, root: Path):
        self.root = root
        out = subprocess.run(["git", "-C", str(root), "ls-files", "-s", "-z"], capture_output=True, check=True).stdout
        self.blobs = {}
        for entry in out.decode().split("\0"):
            if entry:
                meta, path = entry.split("\t", 1)
                mode, blob, _stage = meta.split()
                if mode != "160000":  # a submodule has no text here
                    self.blobs[path] = blob
        self.cache: dict[str, str] = {}

    def __contains__(self, path: str) -> bool:
        return path in self.blobs

    def files(self, under: str, suffix: str = "") -> list[str]:
        return sorted(p for p in self.blobs if p.startswith(f"{under}/") and p.endswith(suffix))

    def texts(self, paths) -> dict[str, str]:
        """{path: its text} of the tracked PATHS, the ones not checked out read in one `git cat-file --batch`."""
        missing = [p for p in paths if p in self.blobs and p not in self.cache and not (self.root / p).is_file()]
        for path in paths:
            if path in self.blobs and path not in self.cache and path not in missing:
                self.cache[path] = (self.root / path).read_text(errors="replace")
        if missing:
            out = subprocess.run(["git", "-C", str(self.root), "cat-file", "--batch"], check=True, capture_output=True,
                                 input="".join(f"{self.blobs[p]}\n" for p in missing).encode()).stdout
            at = 0
            for path in missing:
                end = out.index(b"\n", at)
                size = int(out[at:end].split()[2])
                self.cache[path] = out[end + 1:end + 1 + size].decode(errors="replace")
                at = end + 1 + size + 1
        return {p: self.cache[p] for p in paths if p in self.cache}

    def text(self, path: str) -> str | None:
        return self.texts([path]).get(path)

    def write(self, dest: Path, under: list[str], suffixes: tuple[str, ...]) -> Path:
        """DEST holding every tracked file below UNDER that ends in one of SUFFIXES: a tree a reader of files
        (cargo_test_verdict.crate_inputs) walks as it walks a full checkout."""
        paths = sorted({p for d in under for p in self.files(d) if p.endswith(suffixes)})
        for path, text in self.texts(paths).items():
            (dest / path).parent.mkdir(parents=True, exist_ok=True)
            (dest / path).write_text(text)
        return dest


class PackageFixedOnBase(unittest.TestCase):
    """A package job red on a head whose diff cannot reach the package, fixed on the base after its merge-base."""

    def judge(self, github):
        return "\n".join(excuse.judge(REPO, "feat-cmux-next", HEAD, [10], github))

    def test_a_pr_that_touches_a_package_read_is_not_excused(self):
        for path in ("cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileLive/LinkController.swift",
                     "cmux-next-ios/rust/Cargo.lock", "Packages/Shared/CmuxAuthRuntime/Sources/A.swift",
                     "cmux-tui/crates/cmux-wg/src/lib.rs", "cmux-tui/Cargo.toml", "schemas/remote-tab/client.json",
                     "scripts/ci/select-ci-xcode.sh", ".github/workflows/cmux-next-ios-kit.yml",
                     "cmux-tui/spec/full-access-modes.json", "schemas/deeplinks/agent-link.json"):
            with self.subTest(path=path), self.assertRaisesRegex(excuse.Refused, "reads paths the PR changes"):
                self.judge(KitFixedOnBaseGitHub(changed=(path,)))

    def test_a_failed_steps_test_lines_in_a_passing_steps_second_are_never_its_own(self):
        # cmux#36988 at d8cb4c44, job 128332980232: the test step's `Run swift test` header is stamped 07:06:53.1, a
        # second inside both the build step's and the test step's windows, so the header is not shown to be the test
        # step's own: the log does not map one to one onto the steps and nothing is excused (cmux#40542's second
        # Codex BLOCK; LW#4177 F1, hq#8936 F1: a container step that prints no `Run` line looks the same).
        github = KitFixedOnBaseGitHub()
        github.jobs[1]["steps"] = [
            {"number": 1, "name": "Set up job", "status": "completed", "conclusion": "success",
             "started_at": "2026-11-07T07:02:19Z", "completed_at": "2026-11-07T07:02:21Z"},
            {"number": 2, "name": "Build CmuxMobileLinkFFI.xcframework", "status": "completed", "conclusion": "success",
             "started_at": "2026-11-07T07:02:21Z", "completed_at": "2026-11-07T07:06:53Z"},
            {"number": 3, "name": KIT_STEP, "status": "completed", "conclusion": "failure",
             "started_at": "2026-11-07T07:06:53Z", "completed_at": "2026-11-07T07:08:54Z"},
            {"number": 4, "name": "xcodebuild test (iOS simulator)", "status": "completed", "conclusion": "skipped",
             "started_at": "2026-11-07T07:08:54Z", "completed_at": "2026-11-07T07:08:54Z"},
            {"number": 5, "name": "Post Run actions/checkout", "status": "completed", "conclusion": "success",
             "started_at": "2026-11-07T07:08:54Z", "completed_at": "2026-11-07T07:08:55Z"},
            {"number": 6, "name": "Complete job", "status": "completed", "conclusion": "success",
             "started_at": "2026-11-07T07:08:55Z", "completed_at": "2026-11-07T07:08:55Z"}]
        github.logs[1] = "\n".join([
            "2026-11-07T07:02:19.4000000Z Current runner version: '2.338.2'",
            "2026-11-07T07:02:21.3000000Z ##[group]Run bash cmux-next-ios/rust/scripts/build-xcframework.sh",
            "2026-11-07T07:06:53.1000000Z ##[group]Run swift test --package-path cmux-next-ios/CmuxMobileKit",
            "2026-11-07T07:08:54.5717620Z " + KIT_TEST,
            "2026-11-07T07:08:54.5718210Z ✘ Test silentDropDetectionBenchmark() failed after 16.970 seconds with 1 issue.",
            "2026-11-07T07:08:54.9000000Z ##[error]Process completed with exit code 1.",
            "2026-11-07T07:08:54.9500000Z Post job cleanup.",
            "2026-11-07T07:08:55.2000000Z Cleaning up orphan processes"])
        with self.assertRaisesRegex(excuse.Refused, "does not map one to one onto its steps"):
            self.judge(github)
        # With each step's header inside its own step's window only (the post step's too), every section is its
        # step's, so the test lines are the test step's own, in the post step's first second or before it.
        steps = github.jobs[1]["steps"]
        steps[0]["completed_at"] = steps[1]["started_at"] = "2026-11-07T07:02:20Z"
        steps[1]["completed_at"] = steps[2]["started_at"] = "2026-11-07T07:06:52Z"
        steps[2]["completed_at"] = "2026-11-07T07:08:53Z"
        self.assertIn(f"excused '{KIT}': fixed on base", self.judge(github))
        github.logs[1] = github.logs[1].replace("07:08:54.57", "07:08:53.57")
        self.assertIn(f"excused '{KIT}': fixed on base", self.judge(github))

    def test_a_swift_path_package_behind_comments_is_still_followed(self):
        # Comments inside or before the call no longer hide the path (reviews of ce36494d and d13a3060, F1).
        for manifest in ('.package(/* the Mac */ path: "../../macOS/CmuxNext")',
                         '.package /* the Mac */ (path: "../../macOS/CmuxNext")',
                         '.package(\n    // the Mac\n    path: "../../macOS/CmuxNext"\n)'):
            files = dict(KIT_FILES)
            files["Packages/iOS/CmuxTabsKit/Package.swift"] = manifest
            with self.subTest(manifest=manifest), \
                    self.assertRaisesRegex(excuse.Refused, "Packages/macOS/CmuxNext is outside its declared reads"):
                self.judge(KitFixedOnBaseGitHub(files=files))

    def test_a_commented_out_dependency_is_not_followed(self):
        files = dict(KIT_FILES)
        files["Packages/iOS/CmuxTabsKit/Package.swift"] = '// .package(path: "../../macOS/CmuxNext"),\n/* .package(x) */'
        self.assertIn(f"excused '{KIT}': fixed on base", self.judge(KitFixedOnBaseGitHub(files=files)))

    def test_a_swift_package_declared_in_an_unread_form_is_refused(self):
        for manifest, said in (('.package(path: macPath)', "Package.swift:1 declares a package dependency"),
                               ('.package(path: #"../../macOS/CmuxNext"#)', "raw, multiline or interpolated"),
                               # An interpolation's quote would end the literal early and a `/*` in it would then
                               # blank the rest, the next dependency with it (review of 4a2a357a, F1).
                               ('let note = "\\(String("/*"))"\n.package(path: "../../macOS/CmuxNext")',
                                "raw, multiline or interpolated")):
            files = dict(KIT_FILES)
            files["Packages/iOS/CmuxTabsKit/Package.swift"] = manifest
            with self.subTest(manifest=manifest), self.assertRaisesRegex(excuse.Refused, said):
                self.judge(KitFixedOnBaseGitHub(files=files))

    def test_a_url_package_is_read_as_one(self):
        files = dict(KIT_FILES)
        files["Packages/iOS/CmuxTabsKit/Package.swift"] = '.package(url: "https://github.com/a/b", from: "1.0.0")'
        self.assertIn(f"excused '{KIT}': fixed on base", self.judge(KitFixedOnBaseGitHub(files=files)))

    def test_every_directory_of_a_shared_crate_name_is_checked(self):
        # Two path crates named cmux-wg (an aliased dependency): the undeclared one is not hidden by the declared one
        # (review of ce36494d, F2).
        files = dict(KIT_FILES)
        files["cmux-next-ios/rust/crates/cmux-mobile-link/Cargo.toml"] += (
            'old-wg = { package = "cmux-wg", path = "../../../../Packages/macOS/old-wg" }\n')
        files["Packages/macOS/old-wg/Cargo.toml"] = '[package]\nname = "cmux-wg"\n'
        with self.assertRaisesRegex(excuse.Refused, "crate cmux-wg at Packages/macOS/old-wg is outside its declared"):
            self.judge(KitFixedOnBaseGitHub(files=files))

    def test_a_locked_path_crate_no_manifest_reaches_is_refused(self):
        files = dict(KIT_FILES)
        files["cmux-next-ios/rust/Cargo.lock"] = KIT_LOCK + '[[package]]\nname = "cmux-agent-pane-policy"\n'
        with self.assertRaisesRegex(excuse.Refused, "path crates its manifests do not reach: cmux-agent-pane-policy"):
            self.judge(KitFixedOnBaseGitHub(files=files))

    def test_a_glob_member_is_refused(self):
        files = dict(KIT_FILES)
        files["cmux-next-ios/rust/Cargo.toml"] = '[workspace]\nmembers = ["crates/*"]\n'
        with self.assertRaisesRegex(excuse.Refused, "names its members by a glob"):
            self.judge(KitFixedOnBaseGitHub(files=files))

    def test_a_test_step_without_a_failing_test_of_its_own_is_not_excused(self):
        # One step's failing test never covers another test step's compile error (review F2).
        github = KitFixedOnBaseGitHub()
        sim = KIT_SIM
        github.frame(KIT_STEPS + [(sim, "failure", 20, 30)],
                     kit_lines((sim, 21, "##[group]Run xcodebuild test -scheme CmuxMobileKit"),
                               (sim, 25, "error: cannot find 'LinkTestClock' in scope"),
                               (sim, 29, "##[error]Process completed with exit code 65.")))
        with self.assertRaisesRegex(excuse.Refused, re.escape(f"step '{sim}' names no failing test of its own")):
            self.judge(github)

    def test_a_passing_test_steps_line_in_the_next_steps_first_second_never_names_its_test(self):
        # Name-and-window placement (step_lines before it shared step_owners) put a line in the failed step when its
        # stamp fell in that step's [started_at, completed_at + 1s): the macOS step, which passed (its known-issue
        # wrapper), printed its recorded issue at 12:00:20.2, the second the iOS step started in, so the iOS step's
        # compile error read as that test's failure and the red was excused as fixed on the base. The log's order
        # gives the line to the macOS step, but the iOS step's header at 12:00:20.6 is also in the macOS step's window,
        # so the log does not map one to one onto the steps and nothing is excused.
        github = KitFixedOnBaseGitHub()
        sim = KIT_SIM
        github.frame([(KIT_BUILD, "success", 3, 9), (KIT_STEP, "success", 10, 20), (sim, "failure", 20, 30),
                      ("Post Run actions/checkout", "success", 30, 31)],
                     [(KIT_BUILD, 3, "##[group]Run swift build --package-path cmux-next-ios/CmuxMobileKit"),
                      (KIT_STEP, 10, "##[group]Run swift test --package-path cmux-next-ios/CmuxMobileKit"),
                      (KIT_STEP, 20.2, KIT_TEST),
                      (KIT_STEP, 20.3, "✘ Test silentDropDetectionBenchmark() failed after 13.4 seconds with 1 issue."),
                      (sim, 20.6, "##[group]Run xcodebuild test -scheme CmuxMobileKit"),
                      (sim, 25, "error: cannot find 'LinkTestClock' in scope"),
                      (sim, 29, "##[error]Process completed with exit code 65."),
                      ("Post Run actions/checkout", 30.2, "Post job cleanup.")])
        with self.assertRaisesRegex(excuse.Refused, "does not map one to one onto its steps"):
            self.judge(github)

    def test_a_kit_log_with_a_composite_action_is_refused(self):
        # cmux-next-ios kit's "Set up pinned Rust" is a composite action: one STEP_START line per inner step (job
        # 129951569749 printed 13 for 10 steps). The log does not map one to one onto the steps, so no line is told
        # to the step that printed it and the package red is not excused.
        github = KitFixedOnBaseGitHub()
        rust = "Set up pinned Rust"
        github.frame([(rust, "success", 2, 2), ("Cache cargo", "success", 2, 3)] + KIT_STEPS,
                     [(rust, 2.1, "##[group]Run ./.github/actions/setup-cmux-tui-rust"),
                      (rust, 2.2, "##[group]Run set -euo pipefail"),
                      (rust, 2.8, "##[group]Run bash \"$GITHUB_ACTION_PATH/../runner-cargo-home/runner-cargo-home.sh\""),
                      ("Cache cargo", 2.9, "##[group]Run Swatinem/rust-cache@v2"), *kit_lines()])
        with self.assertRaisesRegex(excuse.Refused, "does not map one to one onto its steps"):
            self.judge(github)

    def test_an_unreadable_manifest_is_refused(self):
        for path in ("cmux-next-ios/rust/Cargo.lock", "Packages/iOS/CmuxTabsKit/Package.swift",
                     "cmux-tui/crates/cmux-wg/Cargo.toml"):
            files = {key: value for key, value in KIT_FILES.items() if key != path}
            with self.subTest(path=path), self.assertRaisesRegex(excuse.Refused, f"{path} could not be read"):
                self.judge(KitFixedOnBaseGitHub(files=files))

    def test_a_failed_build_step_is_not_excused(self):
        github = KitFixedOnBaseGitHub()
        github.jobs[1]["steps"][1]["conclusion"] = "failure"
        github.logs[1] += "\n" + log(KIT, "Build package and tests", "error: no such module 'CmuxMobileLive'")
        with self.assertRaisesRegex(excuse.Refused, "'Build package and tests' is not one of the job's test steps"):
            self.judge(github)

    def test_a_crash_in_a_package_job_is_never_excused(self):
        github = KitFixedOnBaseGitHub()
        github.logs[1] += "\n" + log(KIT, KIT_STEP, "error: Exited with unexpected signal code 11")
        with self.assertRaisesRegex(excuse.Refused, "crash"):
            self.judge(github)

    def test_a_base_pass_not_after_the_merge_base_is_not_excused(self):
        github = KitFixedOnBaseGitHub()
        github.status = "identical"
        with self.assertRaisesRegex(excuse.Refused, "not after the merge-base"):
            self.judge(github)

    def test_the_declared_reads_cover_the_tree(self):
        # The Rust crates the manifests reach (cargo_crates, as the classifier resolves them at a head) and every file
        # their sources include_str! (cmux-rd-ffi's tests read schemas/remote-tab/), read from this checkout the way
        # cargo_test_verdict reads a crate's inputs.
        package = excuse.PACKAGE_JOBS[KIT]
        spec = importlib.util.spec_from_file_location("cargo_test_verdict", ROOT / "scripts/ci/cargo_test_verdict.py")
        cargo = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cargo)
        reads = package["reads"] + excuse.GUARD_READS_DEFAULT
        github = KitFixedOnBaseGitHub(files={})
        # The fake serves this checkout's whole tree, read the way the classifier reads a sha's tree (TrackedTree):
        # the cargo roots and crates are the ones cargo_crates discovers, so a new root needs no list here.
        tree = TrackedTree(ROOT)

        def served(repo, ref, path):
            text = tree.text(path)
            if text is None:
                raise excuse.Refused(f"{repo}@{ref}: {path} is not a text file GitHub served")
            return text
        github.blob = served
        crates = sorted(excuse.cargo_crates(REPO, HEAD, package["cargo_lock"], github))
        self.assertIn("cmux-tui/crates/cmux-wg", crates)
        self.assertNotIn("cmux-tui/crates/cmux-agent-pane-policy", crates)
        built = tree.write(Path(tempfile.mkdtemp()), crates + [cargo.WORKSPACE], (".rs", "Cargo.toml"))
        self.addCleanup(shutil.rmtree, built)
        for crate in crates:
            dirs, files = cargo.crate_inputs(built, crate)
            for path in [f"{d}/Cargo.toml" for d in dirs] + files:
                with self.subTest(path=path):
                    self.assertTrue(any(excuse.touches(path, read) for read in reads), path)
        # A repository path its Swift names in a string literal (a test reading a shared spec from the root at run
        # time, which no manifest shows): every one that exists must be a declared read.
        literal = re.compile(r'"((?:[\w.-]+/)+[\w.-]+)"')
        for root in ("cmux-next-ios/CmuxMobileKit", "Packages/Shared", "Packages/iOS", "vendor"):
            sources = [source for source in tree.files(root, ".swift")
                       if root == "cmux-next-ios/CmuxMobileKit" or "Tests" not in source.split("/")]
            # the job runs the kit's own tests; the packages it reaches build only their sources
            self.assertTrue(sources, f"{root} has no Swift in this tree")
            for source, text in tree.texts(sources).items():
                for found in literal.finditer(text):
                    path = found.group(1)
                    if path in tree:
                        with self.subTest(path=path, source=source):
                            self.assertTrue(any(excuse.touches(path, read) for read in reads), path)
        self.assertEqual(excuse.package_reads(REPO, HEAD, package, github), package["reads"])


class FixedOnBase(unittest.TestCase):
    """A guard test red on a head whose merge-base predates the base fix (#27584, #27918, #27905, #27775)."""

    def judge(self, github):
        return "\n".join(excuse.judge(REPO, "feat-cmux-next", HEAD, [10], github))

    def test_a_guard_test_that_passes_on_the_newest_base_is_excused_as_fixed_on_base(self):
        text = self.judge(FixedOnBaseGitHub())
        self.assertIn(f"excused '{GUARD}': fixed on base (passes at {BASE_SHA[:12]}", text)
        self.assertIn("PR does not touch tests/test_car_guards.py, .github/, scripts/, tests/", text)
        self.assertIn(CAR_TEST, text)

    def test_receipts_are_read_across_pages_as_the_real_reader_returns_them(self):
        """GitHub.json(paginate=True) returns pages ([[comment, ...], ...]; no reviews is [[]]); a SHIP on the
        second page still counts (cmux#38792 review)."""
        github = FixedOnBaseGitHub()
        filler = {"body": "noted", "created_at": "2026-11-08T17:00:00Z",
                  "user": {"login": "someone", "type": "User"}, "author_association": "MEMBER"}
        github.comments = [filler] * 100 + [ship_comment(HEAD)]
        self.assertEqual(len(github.json(f"repos/{REPO}/issues/38700/comments", paginate=True)), 2)
        self.assertEqual(github.json(f"repos/{REPO}/pulls/38700/reviews", paginate=True), [[]])
        self.assertIn(f"#38700, SHIP at {HEAD[:12]}", self.judge(github))

    def test_the_pull_request_gates_of_cmuxterm_hq_7948(self):
        """A lane's land and next-autoland agree (cmuxterm-hq#7948): fixed on base also needs an independent SHIP at
        the exact head, no conflict, not risk:high, and the job red at the PR's merge-base."""
        text = self.judge(FixedOnBaseGitHub())
        self.assertIn(f"#38700, SHIP at {HEAD[:12]}, red at the merge-base {MERGE_BASE[:12]}", text)
        cases = []
        github = FixedOnBaseGitHub()
        github.comments = []
        cases.append((github, "no independent SHIP at its exact head"))
        github = FixedOnBaseGitHub()
        github.comments = [ship_comment("d" * 40)]  # a SHIP at an older head only
        cases.append((github, "no independent SHIP at its exact head"))
        github = FixedOnBaseGitHub()
        github.comments = [ship_comment(HEAD), ship_comment(HEAD, "BLOCK", at="2026-11-08T17:30:00Z")]
        cases.append((github, "no independent SHIP at its exact head"))
        github = FixedOnBaseGitHub()
        github.pull["labels"] = [{"name": "risk:high"}]
        cases.append((github, "is risk:high"))
        for field, value in (("mergeable", False), ("mergeable_state", "dirty")):
            github = FixedOnBaseGitHub()
            github.pull[field] = value
            cases.append((github, "conflicting"))
        for conclusion in ("success", None, "cancelled"):
            github = FixedOnBaseGitHub()
            github.at_merge_base = conclusion
            cases.append((github, "no red verdict at the merge-base"))
        github = FixedOnBaseGitHub()
        github.pull = None
        cases.append((github, "no single pull request"))
        for github, said in cases:
            with self.subTest(said=said), self.assertRaisesRegex(excuse.Refused, said):
                self.judge(github)
        # A merged pull request (merge_audit) has no conflict to read.
        github = FixedOnBaseGitHub()
        github.pull.update(state="closed", mergeable=None, mergeable_state="unknown")
        self.assertIn("fixed on base", self.judge(github))

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
        # A pass at the merge-base itself proves no fix; one before it is no base verdict for this PR yet.
        for status, said in (("identical", "not after the merge-base"),
                             ("behind", "no feat-cmux-next verdict at or after this PR's merge-base yet"),
                             ("diverged", "no feat-cmux-next verdict at or after this PR's merge-base yet")):
            with self.subTest(status=status), self.assertRaisesRegex(excuse.Refused, said):
                self.judge(FixedOnBaseGitHub(status=status))

    def test_a_crash_is_never_fixed_on_base(self):
        github = FixedOnBaseGitHub()
        github.logs[1] = guard_log(CAR_TEST, exit_line=False) + "\n" + log(
            GUARD, CAR_GUARD_STEP, "##[error]Process completed with exit code 134.")
        with self.assertRaisesRegex(excuse.Refused, "crash"):
            self.judge(github)

    def test_a_cut_short_run_is_never_fixed_on_base(self):
        github = FixedOnBaseGitHub()
        github.logs[1] = log(GUARD, CAR_GUARD_STEP, "##[group]Run python3 tests/test_car_guards.py",
                             "python3 tests/test_car_guards.py", "shell: /usr/bin/bash -e {0}", "##[endgroup]",
                             f"FAIL: {CAR_TEST} (__main__.FocusedTests.{CAR_TEST})",
                             f'  File "/w/tests/test_car_guards.py", line 160, in {CAR_TEST}',
                             f"{CAR_TEST} (__main__.FocusedTests.{CAR_TEST}) ... ok",
                             "##[error]Process completed with exit code 1.")
        with self.assertRaisesRegex(excuse.Refused, "never a base red"):
            self.judge(github)
        self.assertFalse([route for route in github.routes if "/compare/" in route])

    def failed_steps(self, github, *sections):
        """Serve the head job as failed steps SECTIONS, each (step name, its log text), each its own placed section
        (failed_view reads a failed step's own lines; a second step's lines inside the first's places nothing)."""
        steps, lines = [], []
        for n, (step, text) in enumerate(sections):
            at = 10 + 4 * n
            steps.append((step, "failure", at, at + 2))
            lines += [(step, at if line.startswith("##[group]Run ") else at + 1, line)
                      for line in excuse.lines_of(text)]
        github.jobs[1]["steps"] = framed_steps(steps)
        github.logs[1] = framed_log(lines, GUARD)

    def test_a_failed_step_with_no_guard_test_is_not_excused(self):
        github = FixedOnBaseGitHub()
        self.failed_steps(github, (CAR_GUARD_STEP, guard_log(CAR_TEST)), ("Validate create-dmg", log(
            GUARD, "Validate create-dmg", "##[group]Run ./tests/test_ci_create_dmg_pinned.sh",
            "./tests/test_ci_create_dmg_pinned.sh", "shell: /usr/bin/bash -e {0}", "##[endgroup]",
            "create-dmg is not pinned", "##[error]Process completed with exit code 1.")))
        with self.assertRaisesRegex(excuse.Refused, "names no failing test"):
            self.judge(github)

    def test_a_non_guard_test_job_is_never_fixed_on_base(self):
        # A Swift test reads product code: a pass on the base proves only that the head broke it.
        github = FakeGitHub()
        github.jobs[2]["conclusion"] = "success"
        with self.assertRaisesRegex(excuse.Refused, "not a declared guard job"):
            excuse.judge(REPO, "feat-cmux-next", HEAD, [10], github)
        # Only the merge-base itself is read (before_merge_base, one file), never the PR's diff.
        self.assertFalse([route for route in github.routes if "/compare/" in route and "per_page=1" not in route])

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
        github.logs[1] = log(GUARD, CAR_GUARD_STEP, "##[group]Run python3 tests/test_car_guards.py",
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
        self.failed_steps(github, (CAR_GUARD_STEP, guard_log("test_every_part_of_bun_run_check_runs_in_the_warn_branch",
                                                             file="tests/test_cmux_next_checks_workflow.py")),
                          ("Fail on any red check", log(
                              GUARD, "Fail on any red check", "##[group]Run failed=()", "failed=()",
                              "shell: /usr/bin/bash -e {0}", "##[endgroup]", "##[error]red check: Checks job structure",
                              "##[error]Process completed with exit code 1.")))
        self.assertIn("fixed on base", self.judge(github))
        for path in ("webviews/package.json", "cmux-tui/Cargo.toml", "Native/OptChat/chief/Cargo.toml"):
            github.changed = [path]
            with self.subTest(path=path), self.assertRaisesRegex(excuse.Refused, path):
                self.judge(github)

    def test_a_rollup_naming_more_reds_than_guard_tests_is_not_excused(self):
        github = FixedOnBaseGitHub()
        self.failed_steps(github, (CAR_GUARD_STEP, guard_log(CAR_TEST)), ("Fail on any red check", log(
            GUARD, "Fail on any red check", "##[group]Run failed=()", "failed=()", "shell: /usr/bin/bash -e {0}",
            "##[endgroup]", "##[error]red check: Checks job structure", "##[error]red check: God files",
            "##[error]Process completed with exit code 1.")))
        with self.assertRaisesRegex(excuse.Refused, "rollup names 2 red checks"):
            self.judge(github)

    def test_a_pytest_id_names_its_file(self):
        self.assertEqual(excuse.guard_test_file("tests/test_x.py::Case::test_y", []), "tests/test_x.py")
        self.assertIsNone(excuse.guard_test_file("web/test_x.py::test_y", []))


GUARD_GROUP = excuse.GUARD_GROUP_JOB
GUARD_STEP = excuse.GUARD_GROUP_STEP


def guard_group_log(*lines):
    """A guard group job's log: run_ci_guards.py's head run, then guards_new_reds.py's verdict."""
    return log(GUARD_GROUP, GUARD_STEP, "cmux guards: 270 steps passed, 2 failed, 0 skipped (Linux only) in 150.0s",
               *lines)


class GuardGroupGitHub(FakeGitHub):
    """A pull request's red guard group job (run 10) and the newest feat-cmux-next push run of it (run 20)."""

    def __init__(self, head_lines, base_lines, base_conclusion="success"):
        super().__init__()
        self.jobs = {1: failed_job(1, 10, HEAD, name=GUARD_GROUP, step=GUARD_STEP),
                     2: dict(failed_job(2, 20, BASE_SHA, name=GUARD_GROUP, step=GUARD_STEP),
                             conclusion=base_conclusion)}
        if base_conclusion == "success":
            self.jobs[2]["steps"][-1]["conclusion"] = "success"
        self.logs = {1: guard_group_log(*head_lines), 2: guard_group_log(*base_lines)}
        self.base_runs[1]["conclusion"] = base_conclusion


class GuardGroupPerStep(unittest.TestCase):
    """cmux-next-guards.yml's guard group fails only on a step red on the change and not on its base; its red was
    never excused (not a declared guard job), and the base's own reds in it stayed green on every push (18 steps,
    until #31366). A pull request's red step is excused only when the newest base run of the job lists it red."""

    def judge(self, github):
        return "\n".join(excuse.judge(REPO, "feat-cmux-next", HEAD, [10], github))

    def test_a_step_red_on_the_base_push_judged_at_its_tip_is_excused(self):
        github = GuardGroupGitHub(
            ["##[error]Validate fleet rule lints", "guard red step (new): Validate fleet rule lints",
             "1 guard steps red on this change, 0 red on the base too, 0 flaky on the base, 0 fixed"],
            ["##[error]Validate fleet rule lints", "guard red step (tip): Validate fleet rule lints",
             "guard red step (tip): Lint every workflow", "2 guard steps red at the tip"],
            base_conclusion="failure")
        text = self.judge(github)
        self.assertIn(f"excused '{GUARD_GROUP}'", text)
        self.assertIn("run 20", text)
        self.assertIn("Validate fleet rule lints", text)

    def test_a_step_a_green_base_push_lists_as_red_on_its_base_is_excused(self):
        # A push judged against the previous tip stays green while a red persists, and lists it as `base`.
        github = GuardGroupGitHub(
            ["guard red step (new): Lint every workflow",
             "1 guard steps red on this change, 0 red on the base too, 0 flaky on the base, 0 fixed"],
            ["guard red step (base): Lint every workflow",
             "0 guard steps red on this change, 1 red on the base too, 0 flaky on the base, 0 fixed"])
        self.assertIn(f"excused '{GUARD_GROUP}'", self.judge(github))

    def test_a_new_red_step_is_not_excused(self):
        github = GuardGroupGitHub(
            ["guard red step (new): Validate fleet rule lints", "guard red step (new): Validate the PR design spec check",
             "2 guard steps red on this change, 0 red on the base too, 0 flaky on the base, 0 fixed"],
            ["guard red step (tip): Validate fleet rule lints", "1 guard steps red at the tip"],
            base_conclusion="failure")
        with self.assertRaisesRegex(excuse.Refused, "Validate the PR design spec check"):
            self.judge(github)

    def test_a_step_only_quoted_in_a_failing_steps_output_is_no_base_evidence(self):
        github = GuardGroupGitHub(
            ["guard red step (new): Lint every workflow",
             "1 guard steps red on this change, 0 red on the base too, 0 flaky on the base, 0 fixed"],
            ["0 guard steps red at the tip"], base_conclusion="success")
        github.logs[2] = log(GUARD_GROUP, GUARD_STEP, "AssertionError: guard red step (tip): Lint every workflow",
                             "guard red step (tip): Lint every workflow",
                             "cmux guards: 272 steps passed, 0 failed, 0 skipped (Linux only) in 150.0s",
                             "0 guard steps red at the tip")
        with self.assertRaisesRegex(excuse.Refused, "not on feat-cmux-next run 20"):
            self.judge(github)

    def test_a_base_run_with_no_summary_is_refused(self):
        github = GuardGroupGitHub(
            ["guard red step (new): Lint every workflow",
             "1 guard steps red on this change, 0 red on the base too, 0 flaky on the base, 0 fixed"],
            ["guard red step (base): Lint every workflow"])
        with self.assertRaisesRegex(excuse.Refused, "no red steps with a closing summary"):
            self.judge(github)

    def test_a_base_run_cut_short_before_its_guards_finished_is_refused(self):
        # Verdict lines quoted by a failing step's output, with no run_ci_guards.py closing line, prove nothing.
        github = GuardGroupGitHub(
            ["guard red step (new): Lint every workflow",
             "1 guard steps red on this change, 0 red on the base too, 0 flaky on the base, 0 fixed"], [])
        github.logs[2] = log(GUARD_GROUP, GUARD_STEP, "guard red step (base): Lint every workflow",
                             "0 guard steps red on this change, 1 red on the base too, 0 flaky on the base, 0 fixed")
        with self.assertRaisesRegex(excuse.Refused, "no red steps with a closing summary"):
            self.judge(github)

    def test_a_red_outside_the_guard_comparison_is_refused(self):
        github = GuardGroupGitHub(["guard red step (new): Lint every workflow",
                                   "1 guard steps red on this change, 0 red on the base too, 0 flaky on the base, 0 fixed"],
                                  ["guard red step (base): Lint every workflow",
                                   "0 guard steps red on this change, 1 red on the base too, 0 flaky on the base, 0 fixed"])
        github.jobs[1]["steps"][1]["conclusion"] = "failure"
        with self.assertRaisesRegex(excuse.Refused, "not only"):
            self.judge(github)


class Script(unittest.TestCase):
    def test_a_rate_limited_read_exits_3(self):
        # gh-merge-green reports exit 3 as a rate limit, not a red (main's main_fix_evidence.RateLimited).
        class RateLimited(excuse.Refused):
            pass

        def judge(*args, **kwargs):
            raise RateLimited("GitHub rate-limited `gh api`")

        with unittest.mock.patch.object(excuse, "RateLimited", RateLimited), \
                unittest.mock.patch.object(excuse, "judge", judge), \
                unittest.mock.patch.object(excuse.test_reds, "load_flake_state", lambda *a, **k: None):
            self.assertEqual(excuse.main(["--repo", REPO, "--base", "main", "--sha", HEAD, "--check", "x"]), 3)

    def test_a_rate_limited_rollups_read_exits_3(self):
        # The swallow this covers: load_rollups wraps every Refused from its contents reads as
        # "no rollup red is excused", and main's RateLimited is a Refused, so a rate limit read as a
        # verdict and main() returned 1 where gh-merge-green expects a rate limit (3).
        class RateLimited(excuse.Refused):
            pass

        class Limited:
            def json(self, route, *, paginate=False):
                raise RateLimited("GitHub rate-limited `gh api`; resets in 14 minutes")

            def blob(self, repo, ref, path):
                raise RateLimited("GitHub rate-limited `gh api graphql`; resets in 14 minutes")

            def log(self, repo, job):
                raise AssertionError("no log is read once a read is rate-limited")

        excuse._REPO_ROLLUPS.pop(HQ, None)
        with unittest.mock.patch.object(excuse, "RateLimited", RateLimited), \
                unittest.mock.patch.object(excuse, "GitHub", Limited), \
                unittest.mock.patch.object(excuse.test_reds, "load_flake_state", lambda *a, **k: None):
            self.assertEqual(excuse.main(["--repo", HQ, "--base", "main", "--sha", HEAD, "--check", "x"]), 3)

    def test_an_ordinary_refusal_still_exits_1_with_this_branchs_reader(self):
        # Not patched: this branch's main_fix_evidence.py has no RateLimited, so excuse.RateLimited is the empty
        # tuple. A handler written `except (RateLimited, RateLimitedRead)` is then `except ((), RateLimitedRead)`,
        # a TypeError on every ordinary refusal ("catching classes that do not inherit from BaseException"), so
        # main() would crash instead of saying "not excused" (review of #35947, F1).
        self.assertEqual(excuse.rate_limited_classes(), (excuse.RateLimitedRead,))

        def judge(*args, **kwargs):
            raise excuse.Refused("no failed job found on the head to compare with the base")

        with unittest.mock.patch.object(excuse, "judge", judge), \
                unittest.mock.patch.object(excuse.test_reds, "load_flake_state", lambda *a, **k: None):
            self.assertEqual(excuse.main(["--repo", REPO, "--base", "main", "--sha", HEAD, "--check", "x"]), 1)

    def test_gh_merge_green_asks_the_base_before_refusing_a_red_lane(self):
        text = (ROOT / "scripts/gh-merge-green").read_text()
        self.assertIn("base_red_excuse.py", text)
        # Lint stays unwaivable, and --override still skips the base comparison.
        self.assertIn("--override cannot bypass god-file, l10n or concurrency lint", text)



class LostRunnerIsInfra(unittest.TestCase):
    """A job whose runner was lost (cmux#33162's react-apps-base-check (3), job 126154996598) is infra, not a verdict:
    refused as one that needs a re-run, never compared and never the PR's own red."""

    FIXTURES = Path(__file__).resolve().parent / "fixtures/test_reds"

    def lost(self):
        github = FakeGitHub()
        real = json.loads((self.FIXTURES / "lost-runner-job-126154996598.json").read_text())
        github.jobs[1] = dict(real, id=1, run_id=10, head_sha=HEAD)
        return github

    def test_a_lost_runner_is_infra_from_its_steps_with_no_log_read(self):
        github = self.lost()
        github.log = lambda repo, job: self.fail("a lost runner's log is never read")
        with self.assertRaisesRegex(excuse.Infra, "infra, not a verdict .*still in_progress.*needs a re-run"):
            excuse.judge(REPO, "feat-cmux-next", HEAD, [10], github)

    def test_an_unstored_log_reads_the_annotations(self):
        github = self.lost()
        github.jobs[1]["steps"] = [dict(s, status="completed") for s in github.jobs[1]["steps"]]
        notes = json.loads((self.FIXTURES / "lost-runner-annotations-126154996598.json").read_text())
        blob = (self.FIXTURES / "lost-runner-log-126154996598.txt").read_text()
        plain = github.json

        def json_(route, *, paginate=False):
            if route == f"repos/{REPO}/check-runs/1/annotations":
                return notes
            return plain(route, paginate=paginate)

        def log(repo, job):
            raise excuse.Refused("GitHub evidence request failed: " + blob + "gh: HTTP 404")
        github.json, github.log = json_, log
        with self.assertRaisesRegex(excuse.Infra, "lost communication with the server"):
            excuse.judge(REPO, "feat-cmux-next", HEAD, [10], github)
        notes[:] = []  # no annotation: a log GitHub never stored, with no step failed, is a lost runner too
        with self.assertRaisesRegex(excuse.Infra, "BlobNotFound"):
            excuse.judge(REPO, "feat-cmux-next", HEAD, [10], github)

        def unavailable(repo, job):
            raise excuse.Refused("GitHub evidence request failed: gh: HTTP 502")
        github.log = unavailable  # any other unread log stays the refusal it was
        with self.assertRaises(excuse.Refused) as caught:
            excuse.judge(REPO, "feat-cmux-next", HEAD, [10], github)
        self.assertNotIsInstance(caught.exception, excuse.Infra)
        self.assertIn("HTTP 502", str(caught.exception))

    def test_a_real_test_failure_is_still_compared(self):
        github = FakeGitHub()
        github.logs[1] = log(SWIFT, TEST_STEP, ISSUE, OTHER.replace("palettePages", "somethingNew"))
        with self.assertRaises(excuse.Refused) as caught:
            excuse.judge(REPO, "feat-cmux-next", HEAD, [10], github)
        self.assertNotIsInstance(caught.exception, excuse.Infra)
        self.assertIn("somethingNew", str(caught.exception))

class WsCheckGitHub:
    """teamleaderleo/leo-workspace: a `ws-check` commit status on each commit, linking a cmuxterm-hq run whose one job
    for that commit prints tools/ws_check_run.py's step groups and WS_CHECK_RESULT line."""
    REPO, HOST = "teamleaderleo/leo-workspace", "manaflow-ai/cmuxterm-hq"
    TIP, OLDER, MERGE_BASE = "c" * 40, "d" * 40, "e" * 40

    def __init__(self):
        self.statuses, self.runs, self.jobs, self.logs, self.routes = {}, {}, {}, {}, []
        self.base_commits = [self.TIP, self.OLDER, self.MERGE_BASE]
        # Paths each diff changes: the PR's (main...HEAD) and the base's from the merge-base to OLDER (a fix).
        self.pr_files, self.fix_files, self.fix_status = ["tools/guards.py"], ["tools/test_lane_place.py"], "ahead"

    def verdict(self, sha, run_id, red, *, state="failure", steps=77, description=None, at="2026-11-05T04:44:24Z",
                seconds=""):
        """SHA's ws-check: STATE, run RUN_ID, its red steps RED ({step: [printed lines]})."""
        failed = list(red)
        self.statuses[sha] = [{"context": "ws-check", "state": state, "updated_at": at,
                               "description": description if description is not None else (
                                   f"{len(failed)} of {steps} steps failed: {failed[0]}"[:139] if failed else
                                   f"{steps * 10} tests passed in {steps} steps"),
                               "target_url": f"https://github.com/{self.HOST}/actions/runs/{run_id}"}]
        self.runs[run_id] = {"id": run_id, "display_title": "fleet-reconciler ws-check", "head_sha": "f" * 40}
        self.jobs[run_id] = [{"id": run_id * 10, "run_id": run_id, "name": "plan", "status": "completed",
                              "conclusion": "success", "run_attempt": 1},
                             {"id": run_id * 10 + 1, "run_id": run_id, "name": f"check ({sha}) / check",
                              "status": "completed", "conclusion": "success", "run_attempt": 1}]
        lines = ["##[group].github/workflows/tools-tests.yml test: passing", "Ran 3 tests in 0.1s", "", "OK",
                 "##[endgroup]", "ws-check step ok: .github/workflows/tools-tests.yml test: passing (exit 0, ran 3, "
                 "skipped 0, gh calls 0)"]
        for step, printed in red.items():
            # PRINTED is the step's lines, or {unit: lines} for a step split into units: each unit its own group and
            # result line, labelled "STEP [UNIT]" (leo-workspace ws_check_run.py since its units).
            for label, out in ([(f"{step} [{unit}]", out) for unit, out in printed.items()]
                               if isinstance(printed, dict) else [(step, printed)]):
                lines += [f"##[group]{label}", *out, "##[endgroup]",
                          f"ws-check step FAILED: {label} (exit 1, ran 4, skipped 0, gh calls 0{seconds})"]
        lines.append("WS_CHECK_RESULT=" + json.dumps({"failed": failed, "head": sha, "ok": not failed, "steps": steps,
                                                       "suites": 9, "tests_ran": 400, "tests_skipped": 0}))
        self.logs[run_id * 10 + 1] = "\n".join(f"2026-11-05T04:39:27.9954759Z {line}" for line in lines)

    def json(self, route, *, paginate=False, per_page=100):
        self.routes.append(route)
        for sha, statuses in self.statuses.items():
            if route == f"repos/{self.REPO}/commits/{sha}/status?per_page=100":
                return {"statuses": copy.deepcopy(statuses)}
        if route.startswith(f"repos/{self.REPO}/commits/") and route.endswith("/status?per_page=100"):
            return {"statuses": []}
        for run_id in self.runs:
            if route == f"repos/{self.HOST}/actions/runs/{run_id}":
                return copy.deepcopy(self.runs[run_id])
            if route == f"repos/{self.HOST}/actions/runs/{run_id}/jobs?filter=all&per_page=100":
                return [{"jobs": copy.deepcopy(self.jobs[run_id])}]
        if route == f"repos/{self.REPO}/commits?sha=main&per_page={excuse.WS_CHECK_COMMITS}":
            return [{"sha": sha} for sha in self.base_commits]
        if route == f"repos/{self.REPO}/compare/main...{HEAD}":
            return {"merge_base_commit": {"sha": self.MERGE_BASE}, "files": [{"filename": f} for f in self.pr_files]}
        if route.startswith(f"repos/{self.REPO}/compare/main...{HEAD}"):
            return {"merge_base_commit": {"sha": self.MERGE_BASE}}
        if route == f"repos/{self.REPO}/compare/{self.MERGE_BASE}...{self.OLDER}":
            return {"status": self.fix_status, "files": [{"filename": f} for f in self.fix_files]}
        if route.startswith(f"repos/{self.REPO}/compare/{self.MERGE_BASE}..."):
            return {"status": "ahead"}
        raise AssertionError(f"unexpected route {route}")

    def log(self, repo, job):
        assert repo == self.HOST, repo
        return self.logs[job["id"]]


class WsCheckPerTest(unittest.TestCase):
    """2026-11-05: a leo-workspace head's red ws-check status read "no failed job found on the head to compare with
    the base" (teamleaderleo/leo-workspace#3434 at 790205f3), so no leo-workspace red could be excused. It is judged
    per test against main's ws-check now (WS_CHECK)."""
    RELAY = ".github/workflows/leo-relay-lint.yml lint: no untagged calls for Leo in briefs, lanes and the rulebook"
    DEPLOY = ".github/workflows/tools-tests.yml test: ws-deploy and ws_tree_lock"
    ROOT = "/home/runner/_work/cmuxterm-hq/cmuxterm-hq/"
    VIOLATION = ROOT + "machines/claude-rulebook.md:185: - Classic is frozen."

    def relay_lint(self, *violations, root=None):
        return ["3 line(s) violate the relay rules.",
                *((root or self.ROOT) + v.removeprefix(self.ROOT) for v in violations or (self.VIOLATION,))]

    def ws_deploy(self, *tests):
        printed = []
        for test in tests:
            printed += ["=" * 70, f"ERROR: {test} (__main__.FastForward.{test})", "-" * 70,
                        "Traceback (most recent call last):", "subprocess.CalledProcessError: exit status 128."]
        return printed + ["-" * 70, "Ran 77 tests in 41.360s", "", f"FAILED (errors={len(tests)})"]

    def setUp(self):
        self.gh = WsCheckGitHub()
        self.gh.verdict(HEAD, 1, {self.RELAY: self.relay_lint()})
        self.gh.verdict(self.gh.TIP, 2, {self.RELAY: self.relay_lint()})

    def judge(self, **kwargs):
        return excuse.judge(self.gh.REPO, "main", HEAD, [], self.gh, **kwargs)

    def test_a_lint_red_on_main_too_is_excused(self):
        audit = self.judge()
        self.assertIn(f"excused 'ws-check': every failure on {HEAD[:12]} is red on main too", audit[0])
        self.assertIn(f"excused 'ws-check' step '{self.RELAY}' (no test names: its output): its 2 line(s) are red on "
                      f"main {self.gh.TIP[:12]} too", audit)
        # Named as a check, the same.
        self.assertEqual(self.judge(checks=["ws-check"]), audit)

    def test_a_step_line_with_its_seconds_is_read(self):
        # leo-workspace#3746 (2026-11-07) ends each step line with its time, "(exit 1, ..., gh calls 0, 62.1 s)";
        # read as "names no exit code", no ws-check red could be excused (leo-workspace#3745).
        self.gh.verdict(HEAD, 1, {self.RELAY: self.relay_lint()}, seconds=", 62.1 s")
        self.gh.verdict(self.gh.TIP, 2, {self.RELAY: self.relay_lint()}, seconds=", 0.4 s")
        self.assertIn(f"excused 'ws-check': every failure on {HEAD[:12]} is red on main too", self.judge()[0])

    def test_a_step_split_into_units_is_read_from_each_units_lines(self):
        # leo-workspace#4322 at aa928f1c (run 43011639090): ws_check_run.py labels each unit's group and result line
        # "STEP [UNIT]" and ends it with its CPU (", cpu 16.4 s, 18.3 s)"), while WS_CHECK_RESULT names the STEP. Read
        # only as "ws-check step FAILED: STEP (exit", the red was refused "has no 'ws-check step FAILED: ...' line"
        # though the log held it, so no red split into units could be excused.
        other = ".github/workflows/tools-tests.yml test: every other tools/test_*.py (a new suite runs without a step)"
        red = {other: {"test_ws_deploy_swap.py": self.ws_deploy("test_old_releases_are_pruned"),
                       "test_lane_place.py 2/4": self.ws_deploy("test_place")}}
        self.gh.verdict(HEAD, 1, red, seconds=", cpu 16.4 s, 18.3 s")
        self.gh.verdict(self.gh.TIP, 2, red, seconds=", cpu 15.0 s, 17.9 s")
        audit = self.judge()
        self.assertIn(f"excused 'ws-check': every failure on {HEAD[:12]} is red on main too", audit[0])
        for suite, test in (("test_ws_deploy_swap.py", "test_old_releases_are_pruned"),
                            ("test_lane_place.py", "test_place")):
            self.assertIn(f"excused 'ws-check' test '{other} :: [{suite}] {test} (__main__.FastForward.{test})': "
                          f"red on main {self.gh.TIP[:12]} too (https://github.com/{self.gh.HOST}/actions/runs/2)",
                          audit)
        # A test of one unit that main does not fail is still the head's own, whatever unit main's red is in.
        self.gh.verdict(self.gh.TIP, 2, {other: {"test_ws_deploy_swap.py": self.ws_deploy("test_old_releases_are_pruned")}},
                        seconds=", cpu 15.0 s, 17.9 s")
        with self.assertRaisesRegex(excuse.Refused, r"1 failure\(s\) not on main: .*test_place"):
            self.judge()

    def test_a_same_named_test_in_another_suite_does_not_excuse_it(self):
        # cmux#41298 F1: every suite runs as __main__, so test_new.py's and test_old.py's test_check both print
        # "test_check (__main__.FastForward.test_check)". Read by name alone, main's red in test_old.py excused the
        # head's new red in test_new.py. A test is named with its suite; only a shard number may differ.
        other = ".github/workflows/tools-tests.yml test: every other tools/test_*.py (a new suite runs without a step)"
        self.gh.verdict(HEAD, 1, {other: {"test_new.py": self.ws_deploy("test_check")}})
        self.gh.verdict(self.gh.TIP, 2, {other: {"test_old.py": self.ws_deploy("test_check")}})
        with self.assertRaisesRegex(excuse.Refused, r"1 failure\(s\) not on main: .*\[test_new\.py\] test_check"):
            self.judge()
        # The same suite in another shard is the same test.
        self.gh.verdict(HEAD, 1, {other: {"test_lane_place.py 2/4": self.ws_deploy("test_check")}})
        self.gh.verdict(self.gh.TIP, 2, {other: {"test_lane_place.py 3/4": self.ws_deploy("test_check")}})
        self.assertIn(f"excused 'ws-check': every failure on {HEAD[:12]} is red on main too", self.judge()[0])

    def test_a_test_failing_on_main_too_is_excused_by_name(self):
        red = {self.RELAY: self.relay_lint(), self.DEPLOY: self.ws_deploy("test_units_that_never_let_go")}
        self.gh.verdict(HEAD, 1, red)
        self.gh.verdict(self.gh.TIP, 2, red)
        audit = self.judge()
        self.assertIn(f"excused 'ws-check' test '{self.DEPLOY} :: test_units_that_never_let_go "
                      f"(__main__.FastForward.test_units_that_never_let_go)': red on main {self.gh.TIP[:12]} too "
                      f"(https://github.com/{self.gh.HOST}/actions/runs/2)", audit)

    def test_a_test_main_does_not_fail_is_not_excused_and_named(self):
        self.gh.verdict(HEAD, 1, {self.RELAY: self.relay_lint(), self.DEPLOY: self.ws_deploy("test_ws_deploy")})
        with self.assertRaises(excuse.Refused) as caught:
            self.judge()
        said = str(caught.exception)
        self.assertIn("1 failure(s) not on main", said)
        self.assertIn(f"not excused 'ws-check' test '{self.DEPLOY} :: test_ws_deploy (__main__.FastForward."
                      "test_ws_deploy)': not red on main", said)
        self.assertIn(f"excused 'ws-check' step '{self.RELAY}'", said)

    def test_another_test_of_a_step_red_on_main_is_not_excused(self):
        self.gh.verdict(HEAD, 1, {self.DEPLOY: self.ws_deploy("test_a", "test_b")})
        self.gh.verdict(self.gh.TIP, 2, {self.DEPLOY: self.ws_deploy("test_a")})
        with self.assertRaisesRegex(excuse.Refused, r"1 failure\(s\) not on main: .*test_b"):
            self.judge()

    def test_a_new_lint_violation_in_a_step_red_on_main_is_not_excused(self):
        self.gh.verdict(HEAD, 1, {self.RELAY: self.relay_lint(self.VIOLATION, self.ROOT + "briefs/new.md:3: call")})
        with self.assertRaisesRegex(excuse.Refused, r"1 of 3 line\(s\) not on main .*briefs/new\.md:#: call"):
            self.judge()

    def test_the_same_lint_violation_at_another_line_and_checkout_root_is_excused(self):
        moved = self.VIOLATION.replace(":185:", ":190:")
        self.gh.verdict(HEAD, 1, {self.RELAY: self.relay_lint(moved, root="/home/runner/_work/_temp/lw/")})
        self.assertIn("every failure", self.judge()[0])

    def test_an_unreadable_head_status_is_not_excused(self):
        # A failure whose description names no failed steps (fleet rule lints, no tests ran, a missing result).
        self.gh.statuses[HEAD][0]["description"] = "fleet rule lints: tools/x.py: names a host"
        with self.assertRaisesRegex(excuse.Refused, "names no failed steps"):
            self.judge()
        self.gh.verdict(HEAD, 1, {self.RELAY: self.relay_lint()})
        self.gh.logs[11] = self.gh.logs[11].replace("WS_CHECK_RESULT=", "WS_CHECK_RESULT=not json ")
        with self.assertRaisesRegex(excuse.Refused, "no WS_CHECK_RESULT line listing its failed steps"):
            self.judge()
        self.gh.verdict(HEAD, 1, {self.RELAY: self.relay_lint()})
        self.gh.statuses[HEAD][0]["target_url"] = "https://example.com/run/1"
        with self.assertRaisesRegex(excuse.Refused, "not a manaflow-ai/cmuxterm-hq Actions run"):
            self.judge()

    def test_a_test_list_that_disagrees_with_its_summary_is_not_excused(self):
        red = {self.DEPLOY: self.ws_deploy("test_a")}
        self.gh.verdict(self.gh.TIP, 2, red)
        red = {self.DEPLOY: self.ws_deploy("test_a")[:-1] + ["FAILED (failures=1, errors=1)"]}
        self.gh.verdict(HEAD, 1, red)
        with self.assertRaisesRegex(excuse.Refused, "summaries count 2; its failing tests cannot be listed"):
            self.judge()

    def test_an_unreadable_main_verdict_is_not_excused(self):
        self.gh.logs[21] = self.gh.logs[21].replace(f"ws-check step FAILED: {self.RELAY}", "ws-check step ok: x")
        with self.assertRaisesRegex(excuse.Refused, f"'ws-check' on {self.gh.TIP}: .*has no 'ws-check step FAILED"):
            self.judge()

    def test_main_green_head_red_is_not_excused(self):
        self.gh.verdict(self.gh.TIP, 2, {}, state="success")
        with self.assertRaises(excuse.Refused) as caught:
            self.judge()
        self.assertIn(f"'ws-check' is green on main {self.gh.TIP[:12]}, red on {HEAD[:12]}", str(caught.exception))
        self.assertIn(f"not excused 'ws-check' step '{self.RELAY}' (no test names): passes on main",
                      str(caught.exception))
        # The merge-base has no verdict, so whether the red was there is unknown (WsCheckFixedOnBase).
        self.assertIn(f"the merge-base {self.gh.MERGE_BASE[:12]} has no ws-check verdict", str(caught.exception))
        self.assertNotIsInstance(caught.exception, excuse.FixedOnBase)

    def test_main_green_before_the_merge_base_waits_for_a_newer_verdict(self):
        self.gh.statuses.pop(self.gh.TIP)
        self.gh.base_commits = [self.gh.TIP, self.gh.MERGE_BASE, self.gh.OLDER]
        self.gh.verdict(self.gh.OLDER, 3, {}, state="success")
        original = self.gh.json

        def json(route, **kwargs):
            if route == f"repos/{self.gh.REPO}/compare/{self.gh.MERGE_BASE}...{self.gh.OLDER}?per_page=1":
                return {"status": "behind"}
            return original(route, **kwargs)

        self.gh.json = json
        with self.assertRaisesRegex(excuse.Refused, "is before the merge-base"):
            self.judge()

    def test_a_green_head_exits_0(self):
        # 2026-11-05: a green leo-workspace head read "'ws-check' passed: nothing red to excuse" and exited 1, so a
        # merge check asking about a green head was refused. No failure is exit 0.
        self.gh.verdict(HEAD, 1, {}, state="success", description="12 steps passed")
        audit = self.judge()
        self.assertEqual(audit, [f"'ws-check' passed on {HEAD}: no failure to excuse"])
        self.assertEqual(self.judge(checks=["ws-check"]), audit)

    def test_a_pending_or_error_head_is_no_result(self):
        for state in ("pending", "error"):
            self.gh.verdict(HEAD, 1, {self.RELAY: self.relay_lint()}, state=state, description="running")
            with self.assertRaisesRegex(excuse.Refused, f"'ws-check' has no result on {HEAD}: ws-check is {state}"):
                self.judge()
        self.gh.statuses.pop(HEAD)
        with self.assertRaisesRegex(excuse.Refused, "has no result on .*: no ws-check status"):
            self.judge()

    def test_a_job_whose_last_attempt_never_ran_is_no_result(self):
        self.gh.jobs[1][1]["conclusion"] = "startup_failure"
        with self.assertRaisesRegex(excuse.Refused, "has no result .*is completed/startup_failure"):
            self.judge()

    def test_a_crash_after_a_whole_test_summary_is_not_excused(self):
        red = {self.DEPLOY: self.ws_deploy("test_a")}
        self.gh.verdict(self.gh.TIP, 2, red)
        self.gh.verdict(HEAD, 1, {self.DEPLOY: self.ws_deploy("test_a") + ["Segmentation fault (core dumped)"]})
        with self.assertRaisesRegex(excuse.Refused, "crashed .Segmentation fault"):
            self.judge()
        self.gh.verdict(HEAD, 1, red)
        self.gh.logs[11] = self.gh.logs[11].replace("(exit 1, ran 4", "(exit 139, ran 4")
        with self.assertRaisesRegex(excuse.Refused, "exited 139 .a signal."):
            self.judge()

    def test_a_main_job_with_no_verdict_is_skipped(self):
        self.gh.jobs[2][1]["conclusion"] = "startup_failure"
        self.gh.verdict(self.gh.OLDER, 3, {self.RELAY: self.relay_lint()})
        self.assertIn(f"newest main verdict main {self.gh.OLDER[:12]}", self.judge()[0])

    def test_main_commits_with_no_result_are_skipped_and_an_older_red_verdict_counts(self):
        self.gh.verdict(self.gh.TIP, 2, {self.RELAY: self.relay_lint()}, state="pending", description="running")
        self.gh.verdict(self.gh.OLDER, 3, {self.RELAY: self.relay_lint()})
        self.assertIn(f"newest main verdict main {self.gh.OLDER[:12]}", self.judge()[0])

    def test_a_test_red_on_an_older_main_verdict_within_the_window_counts(self):
        self.gh.verdict(HEAD, 1, {self.DEPLOY: self.ws_deploy("test_flaky")})
        self.gh.verdict(self.gh.TIP, 2, {self.DEPLOY: self.ws_deploy("test_other")})
        self.gh.verdict(self.gh.OLDER, 3, {self.DEPLOY: self.ws_deploy("test_flaky")})
        self.assertIn(f"red on main {self.gh.OLDER[:12]} too", "\n".join(self.judge()))
        # Never past a pass.
        self.gh.base_commits = [self.gh.TIP, self.gh.MERGE_BASE, self.gh.OLDER]
        self.gh.verdict(self.gh.MERGE_BASE, 4, {}, state="success")
        with self.assertRaisesRegex(excuse.Refused, "test_flaky"):
            self.judge()

    def test_a_fast_checks_run_is_read_through_its_snapshot_receipt(self):
        snapshot = "9" * 40
        for sha, run_id in ((HEAD, 1), (self.gh.TIP, 2)):
            self.gh.runs[run_id]["display_title"] = f"Fast checks {snapshot}"
            self.gh.jobs[run_id] = [dict(self.gh.jobs[run_id][1], name="checks", conclusion="failure")]
            self.gh.logs[run_id * 10 + 1] = (self.gh.logs[run_id * 10 + 1].replace(sha, snapshot)
                                             + f"\n2026-11-05T04:39:28.0421097Z FAST_CHECKS_RECEIPT="
                                             + json.dumps({"source_sha": snapshot, "run_id": str(run_id)}))
        self.assertIn("every failure", self.judge()[0])
        # A title that also names the tested repo and commit (`Fast checks SOURCE tests REPO@TESTED`) is the same run.
        self.gh.runs[1]["display_title"] = f"Fast checks {snapshot} tests teamleaderleo/leo-workspace@{HEAD}"
        self.assertIn("every failure", self.judge()[0])
        self.gh.runs[1]["display_title"] = "Fast checks " + "8" * 40
        with self.assertRaisesRegex(excuse.Refused, "is from another checkout"):
            self.judge()

    def merge_base_case(self, merge_base_red, *, tip=None):
        """LW#3538 at 5e80abcb: main's newest verdict is red on another step, a pass ends the window before the
        merge-base, and the head fails what the merge-base failed (MERGE_BASE_RED: its red steps, or a state)."""
        self.gh.base_commits = [self.gh.TIP, self.gh.OLDER]  # the merge-base is past the window and the list
        self.gh.verdict(HEAD, 1, {self.DEPLOY: self.ws_deploy("test_lane_place")})
        self.gh.verdict(self.gh.TIP, 2, tip if tip is not None else {self.RELAY: self.relay_lint()})
        self.gh.verdict(self.gh.OLDER, 3, {}, state="success")
        if isinstance(merge_base_red, dict):
            self.gh.verdict(self.gh.MERGE_BASE, 4, merge_base_red)
        elif merge_base_red is not None:
            self.gh.verdict(self.gh.MERGE_BASE, 4, {}, state=merge_base_red, description="running")

    def test_a_failure_the_merge_base_shares_is_excused_when_main_is_red(self):
        self.merge_base_case({self.DEPLOY: self.ws_deploy("test_lane_place")})
        self.gh.base_commits = [self.gh.TIP]  # no pass between: the list ends before the merge-base
        audit = self.judge(checks=["ws-check"])
        self.assertIn(f"at this PR's merge-base {self.gh.MERGE_BASE[:12]}", audit[0])
        self.assertIn(f"excused 'ws-check' test '{self.DEPLOY} :: test_lane_place (__main__.FastForward.test_lane_place)'"
                      f": red at this PR's merge-base {self.gh.MERGE_BASE[:12]} too, so not this PR's red "
                      f"(https://github.com/{self.gh.HOST}/actions/runs/4)", audit)

    def test_another_failure_at_the_merge_base_is_not_excused(self):
        self.merge_base_case({self.DEPLOY: self.ws_deploy("test_other")})
        with self.assertRaisesRegex(excuse.Refused, r"test_lane_place.*not red on main .* or at the merge-base"):
            self.judge()

    def test_a_green_pending_or_missing_merge_base_verdict_excuses_nothing(self):
        for state in ("success", "pending", None):
            self.gh.statuses.pop(self.gh.MERGE_BASE, None)
            self.merge_base_case(state)
            with self.assertRaisesRegex(excuse.Refused, r"1 failure\(s\) not on main: .*test_lane_place"):
                self.judge()

    def test_an_unreadable_merge_base_verdict_is_refused(self):
        self.merge_base_case({self.DEPLOY: self.ws_deploy("test_lane_place")})
        self.gh.statuses[self.gh.MERGE_BASE][0]["target_url"] = "https://example.com/run/4"
        with self.assertRaisesRegex(excuse.Refused, f"'ws-check' on {self.gh.MERGE_BASE}: .*not a manaflow-ai/"
                                                    "cmuxterm-hq Actions run"):
            self.judge()
        self.merge_base_case({self.DEPLOY: self.ws_deploy("test_lane_place") + ["Segmentation fault (core dumped)"]})
        with self.assertRaisesRegex(excuse.Refused, "a crash is never a base red"):
            self.judge()

    def test_a_merge_base_red_past_a_base_pass_needs_the_pr_to_leave_the_fix_alone(self):
        # LW#3538: main passed at 209e7eb6 (#3524's fix) after the merge-base 187b3ca3, then went red on another step.
        self.merge_base_case({self.DEPLOY: self.ws_deploy("test_lane_place")})
        audit = "\n".join(self.judge())
        self.assertIn(f"(fixed on main at {self.gh.OLDER[:12]} after it; this PR changes none of that fix's paths)",
                      audit)
        self.gh.pr_files = ["tools/guards.py", "tools/test_lane_place.py"]
        with self.assertRaisesRegex(excuse.Refused, "this PR changes what that fix changed: tools/test_lane_place.py"):
            self.judge()
        self.gh.pr_files = [f"f{n}" for n in range(excuse.COMPARE_FILES_CAP)]
        with self.assertRaisesRegex(excuse.Refused, "too many or none"):
            self.judge()
        self.gh.pr_files, self.gh.fix_status = ["tools/guards.py"], "diverged"
        with self.assertRaisesRegex(excuse.Refused, "compares them as 'diverged'"):
            self.judge()

    def test_main_green_still_refuses_though_the_merge_base_shares_the_failure(self):
        # Main proved the fix: updating the branch is the way, and the refusal names the first green commit.
        self.merge_base_case({self.DEPLOY: self.ws_deploy("test_lane_place")}, tip={})
        self.gh.verdict(self.gh.TIP, 2, {}, state="success")
        with self.assertRaisesRegex(excuse.FixedOnBase, f"^fixed on base by {self.gh.OLDER[:12]}: update the branch"):
            self.judge()

    def test_a_cmux_red_is_still_judged_by_its_actions_job(self):
        gh = FakeGitHub()
        audit = excuse.judge(REPO, "feat-cmux-next", HEAD, [10], gh)
        self.assertEqual(len(audit), 1)
        self.assertTrue(audit[0].startswith(f"excused '{SWIFT}'"), audit[0])
        # a cmux head asked about no red is no failure (NoFailureExitsZero), never the ws-check path
        self.assertEqual(excuse.judge(REPO, "feat-cmux-next", HEAD, [], gh),
                         [f"no red run or check named on {HEAD}: no failure to excuse"])


class WsCheckFixedOnBase(unittest.TestCase):
    """2026-11-11: merge_hold refused teamleaderleo/leo-workspace#4199 at e31e643a with "not excused: 'ws-check' is
    green on main e5a6bed1b950, red on e31e643a6b26; not excused 'ws-check' test ...". Its one red,
    tools/test_knowledge_tiers.py's leo-asks room test, failed the same way at the PR's merge-base e8873054 and was
    fixed on main by LW#4196, and the PR touched only tools/lane-gh. The classifier compared the head with main's
    newest verdict alone, so a base red main had since fixed read as the PR's own. It still refuses (the PR needs CI at
    a head that has the fix), but says "fixed on base by <commit>: update the branch". ws_check_red is the one verdict:
    merge_hold's message comes from it, and the lane-gh broker's update_branch guard reads it (--ws-check-verdict) to
    let a SHIP'd PR's base merge through only for "fixed_on_base"."""
    TIERS = ".github/workflows/tools-tests.yml test: every other tools/test_*.py"
    LEO_ASKS = "test_every_page_inlines_whole_within_the_hooks_room (__main__.EveryRuleIsReachable.test_every_page_" \
               "inlines_whole_within_the_hooks_room)"

    def tiers(self, *tests):
        printed = []
        for test in tests:
            printed += ["=" * 70, f"FAIL: {test}", "-" * 70, "AssertionError: 2872 not less than or equal to 2750 : "
                        "leo-asks"]
        return printed + ["-" * 70, "Ran 77 tests in 4.1s", "", f"FAILED (failures={len(tests)})"]

    def setUp(self):
        # main: TIP and OLDER pass, the merge-base (the oldest of the three) failed the leo-asks test.
        self.gh = WsCheckGitHub()
        self.gh.verdict(HEAD, 1, {self.TIERS: self.tiers(self.LEO_ASKS)})
        self.gh.verdict(self.gh.TIP, 2, {}, state="success")
        self.gh.verdict(self.gh.OLDER, 3, {}, state="success")

    def verdict(self):
        return excuse.ws_check_red(self.gh.REPO, "main", HEAD, self.gh)

    def judge(self):
        return excuse.judge(self.gh.REPO, "main", HEAD, [], self.gh, checks=["ws-check"])

    def test_red_at_the_merge_base_and_green_on_main_says_update_the_branch(self):
        self.gh.verdict(self.gh.MERGE_BASE, 4, {self.TIERS: self.tiers(self.LEO_ASKS)})
        verdict = self.verdict()
        self.assertEqual((verdict["kind"], verdict["fix"]), ("fixed_on_base", self.gh.OLDER))
        with self.assertRaises(excuse.FixedOnBase) as caught:
            self.judge()
        said = str(caught.exception)
        self.assertTrue(said.startswith(f"fixed on base by {self.gh.OLDER[:12]}: update the branch"), said)
        self.assertIn(f"red at this PR's merge-base {self.gh.MERGE_BASE[:12]} too", said)
        self.assertNotIn("not excused", said)
        self.assertIsInstance(caught.exception, excuse.Refused)  # it still refuses: CI must run at a head with the fix
        err = io.StringIO()
        with unittest.mock.patch.object(excuse, "GitHub", lambda: self.gh), \
                unittest.mock.patch.object(excuse.test_reds, "load_flake_state", lambda *a, **k: None), \
                contextlib.redirect_stderr(err):
            code = excuse.main(["--repo", self.gh.REPO, "--base", "main", "--sha", HEAD, "--check", "ws-check"])
        self.assertEqual(code, 1)
        self.assertTrue(err.getvalue().startswith(f"fixed on base by {self.gh.OLDER[:12]}: update the branch"),
                        err.getvalue())

    def test_red_only_at_the_head_stays_not_excused(self):
        self.gh.verdict(self.gh.MERGE_BASE, 4, {self.TIERS: self.tiers("test_other (__main__.Other.test_other)")})
        self.assertEqual(self.verdict()["kind"], "head_only")
        with self.assertRaises(excuse.Refused) as caught:
            self.judge()
        self.assertNotIsInstance(caught.exception, excuse.FixedOnBase)
        self.assertIn(f"not excused 'ws-check' test '{self.TIERS} :: {self.LEO_ASKS}'", str(caught.exception))
        self.assertIn(f"not red at this PR's merge-base {self.gh.MERGE_BASE[:12]}", str(caught.exception))
        self.assertNotIn("fixed on base by", str(caught.exception))
        self.gh.verdict(self.gh.MERGE_BASE, 4, {}, state="success")
        self.assertEqual(self.verdict()["kind"], "head_only")

    def test_a_merge_base_with_no_verdict_stays_not_excused_and_says_so(self):
        self.assertEqual(self.verdict()["kind"], "head_only")
        with self.assertRaises(excuse.Refused) as caught:
            self.judge()
        self.assertNotIsInstance(caught.exception, excuse.FixedOnBase)
        self.assertIn(f"not excused 'ws-check' test '{self.TIERS} :: {self.LEO_ASKS}'", str(caught.exception))
        self.assertIn(f"the merge-base {self.gh.MERGE_BASE[:12]} has no ws-check verdict", str(caught.exception))

    def test_red_at_the_merge_base_and_red_on_main_stays_a_base_red(self):
        self.gh.verdict(self.gh.TIP, 2, {self.TIERS: self.tiers(self.LEO_ASKS)})
        self.gh.verdict(self.gh.MERGE_BASE, 4, {self.TIERS: self.tiers(self.LEO_ASKS)})
        verdict = self.verdict()
        self.assertEqual((verdict["kind"], verdict["fix"]), ("base_red", ""))
        audit = self.judge()
        self.assertIn(f"excused 'ws-check': every failure on {HEAD[:12]} is red on main too", audit[0])
        self.assertNotIn("fixed on base by", "\n".join(audit))

    def test_the_verdict_is_printed_as_json_for_the_broker(self):
        # The lane-gh broker's update_branch guard runs this, never a copy of the rule.
        self.gh.verdict(self.gh.MERGE_BASE, 4, {self.TIERS: self.tiers(self.LEO_ASKS)})
        out = io.StringIO()
        with unittest.mock.patch.object(excuse, "GitHub", lambda: self.gh), contextlib.redirect_stdout(out):
            code = excuse.main(["--repo", self.gh.REPO, "--base", "main", "--sha", HEAD, "--ws-check-verdict"])
        self.assertEqual(code, 0)
        said = json.loads(out.getvalue())
        self.assertEqual((said["kind"], said["fix"]), ("fixed_on_base", self.gh.OLDER))
        self.assertTrue(said["message"].startswith(f"fixed on base by {self.gh.OLDER[:12]}: update the branch"))


class SweepGitHub(FakeGitHub):
    """A head like cmux#36958's (2026-11-06): N red jobs, each in its own workflow whose 35 newest base runs cancelled
    the job, and a status with no run link among 32 head runs, none of which has that job (on cmux#36958 it was
    'next-autoland / verdict', now a derived status judged by its parts, DerivedStatusByParts; a jobless status of
    another name is still read this way). Counts the job reads glaeda-gh's sweep limit counts: distinct runs whose
    jobs, or jobs, were read."""

    STATUS = "fleet / verdict"
    SAID = "its own red: cmux-next defaults guard / defaults guard"
    SWEEP = __import__("re").compile(r"^repos/[^/]+/[^/]+/actions/(?:runs/(\d+)/jobs|jobs/(\d+))/?(?:\?.*)?$")

    def __init__(self, reds, *, suites=True, base_logs=None):
        super().__init__()
        self.suites, self.targets, self.graphql = suites, set(), 0
        self.jobs, self.logs, self.runs, self.listed = {}, {}, {}, []
        for k in range(reds):
            name, workflow = f"suite {k}", 70 + k
            self.add_run(1000 + k, workflow, HEAD, "pull_request")
            self.jobs[1000 + k] = failed_job(1000 + k, 1000 + k, HEAD, name=name)
            self.logs[1000 + k] = log(name, TEST_STEP, ISSUE)
            for n in range(36):
                run = 10000 * (k + 1) + n
                self.add_run(run, workflow, BASE_SHA, "push", created=f"2026-11-06T{23 - n // 3:02d}:{59 - n:02d}:00Z")
                self.jobs[run] = dict(failed_job(run, run, BASE_SHA, name=name),
                                      conclusion="cancelled" if n < 35 else "failure")
                self.logs[run] = log(name, TEST_STEP, *(base_logs or (ISSUE, OTHER)))
        for n in range(32):
            self.add_run(500 + n, 99, HEAD, "pull_request")
            self.jobs[500 + n] = dict(failed_job(500 + n, 500 + n, HEAD, name=f"green {n}"), conclusion="success")
            self.listed.append(self.runs[500 + n])

    def add_run(self, run, workflow, sha, event, created="2026-11-06T00:00:00Z"):
        self.runs[run] = {"id": run, "workflow_id": workflow, "head_sha": sha, "event": event, "status": "completed",
                          "conclusion": "failure", "created_at": created, "run_attempt": 1,
                          "updated_at": created, "head_branch": "feat-cmux-next"}
        if self.suites:
            self.runs[run]["check_suite_node_id"] = f"CS_{run}"

    def json(self, route, *, paginate=False):
        self.routes.append(route)
        if match := self.SWEEP.match(route):
            self.targets.add(match.group(0).split("?")[0].replace("/jobs", ""))
        if route.endswith(f"commits/{HEAD}/check-runs?filter=all&per_page=100"):
            return [{"check_runs": []}]
        if route.endswith(f"commits/{HEAD}/status?per_page=100"):
            return {"statuses": [{"context": self.STATUS, "state": "failure", "target_url": "",
                                  "description": self.SAID}]}
        if route.endswith(f"actions/runs?head_sha={HEAD}&per_page=100"):
            return {"workflow_runs": copy.deepcopy(self.listed)}
        if route.endswith(f"commits?sha=feat-cmux-next&per_page={excuse.BASE_STATUS_COMMITS}"):
            return [{"sha": BASE_SHA}]
        if route.endswith(f"commits/{BASE_SHA}/status?per_page=100"):
            return {"statuses": [{"context": self.STATUS, "state": "failure", "description": self.SAID}]}
        if "/actions/workflows/" in route:
            workflow = int(route.split("/actions/workflows/", 1)[1].split("/", 1)[0])
            return {"workflow_runs": [copy.deepcopy(run) for run in self.runs.values()
                                      if run["workflow_id"] == workflow and run["head_sha"] == BASE_SHA]}
        if "/jobs?" in route:
            run = int(route.split("/actions/runs/", 1)[1].split("/", 1)[0])
            return [{"jobs": [copy.deepcopy(job) for job in self.jobs.values() if job["run_id"] == run]}]
        if "/actions/runs/" in route:
            return copy.deepcopy(self.runs[int(route.rsplit("/", 1)[1])])
        return super().json(route, paginate=paginate)

    def run(self, args):
        assert args[:2] == ["api", "graphql"], args
        self.graphql += 1
        query = next(arg for arg in args if arg.startswith("query="))
        name = next(arg for arg in args if arg.startswith("name="))[len("name="):]
        suites = __import__("re").findall(r'"CS_(\d+)"', query)
        assert 0 < len(suites) <= excuse.SUITES_PER_QUERY, suites
        return json.dumps({"data": {"nodes": [
            {"id": f"CS_{run}", "checkRuns": {"pageInfo": {"hasNextPage": False}, "nodes": [
                {"conclusion": (job["conclusion"] or "").upper() or None}
                for job in self.jobs.values() if job["run_id"] == int(run) and job["name"] == name]}}
            for run in suites]}})

    def judge(self, reds):
        try:
            return excuse.judge(REPO, "feat-cmux-next", HEAD, [1000 + k for k in range(reds)], self,
                                checks=[self.STATUS])
        except excuse.Refused as why:
            return f"refused: {why}"


class SweepLimit(unittest.TestCase):
    """glaeda-gh refuses a caller past 30 distinct job reads in ten minutes; merge_hold judges every red of a head in
    one call. Which runs can answer is read from their check suites over GraphQL, and the verdicts do not change."""

    def test_the_same_inputs_give_the_same_verdicts_with_and_without_the_suite_reads(self):
        for reds, base_logs in ((1, None), (4, None), (4, (OTHER,))):
            with self.subTest(reds=reds, base_logs=base_logs):
                read = SweepGitHub(reds, base_logs=base_logs).judge(reds)
                rest = SweepGitHub(reds, suites=False, base_logs=base_logs).judge(reds)
                self.assertEqual(read, rest)
                self.assertTrue(read)
        self.assertIn("excused 'suite 3'", "\n".join(SweepGitHub(4).judge(4)))
        self.assertIn("refused: 'suite 0'", SweepGitHub(4, base_logs=(OTHER,)).judge(4))

    def test_n_reds_stay_under_the_sweep_limit(self):
        limit = 30  # glaeda-gh's GH_SWEEP_MAX
        for reds in (1, 4, 8, 12):
            with self.subTest(reds=reds):
                gh = SweepGitHub(reds)
                self.assertIn(f"excused 'suite {reds - 1}'", "\n".join(gh.judge(reds)))
                # One head run and one base run per red, and none of the 32 head runs the status was looked for in.
                self.assertEqual(len(gh.targets), 2 * reds)
                self.assertLess(len(gh.targets), limit)
                self.assertEqual(gh.graphql, 2 + 2 * reds)  # 32 head runs and 36 base runs each: two requests apiece
        rest = SweepGitHub(1, suites=False)
        rest.judge(1)
        self.assertGreater(len(rest.targets), limit)  # what merge_hold hit on cmux#36958

    def test_a_suite_read_that_fails_reads_every_run_as_before(self):
        gh = SweepGitHub(1)
        gh.run = lambda args: json.dumps({"errors": [{"message": "Something went wrong"}]})
        self.assertEqual(gh.judge(1), SweepGitHub(1, suites=False).judge(1))
        self.assertGreater(len(gh.targets), 30)

    def test_a_completed_base_runs_job_list_is_kept_by_run_attempt_and_update(self):
        with tempfile.TemporaryDirectory() as kept, \
                unittest.mock.patch.dict(os.environ, {"BASE_RED_EXCUSE_JOBS_CACHE": kept}):
            first = SweepGitHub(2)
            first.judge(2)
            second = SweepGitHub(2)
            self.assertEqual(second.judge(2), first.judge(2))
            self.assertEqual(sorted(second.targets), [f"repos/{REPO}/actions/runs/{1000 + k}" for k in range(2)])
            third = SweepGitHub(2)
            third.runs[10035]["updated_at"] = "2026-11-06T23:59:59Z"  # re-run since: read again
            third.judge(2)
            self.assertIn(f"repos/{REPO}/actions/runs/10035", third.targets)
            self.assertNotIn(f"repos/{REPO}/actions/runs/20035", third.targets)


class StaleFfiPinOfAStepARustChange(unittest.TestCase):
    """cmux#37292 (2026-11-06): a Rust-only change to the app FFI is red on "Check the app FFI pin" until its merge
    publishes the release the re-pin names; the base is green on it, so only the rule for that error lets it land."""

    JOB = "cmux-next checks (god files, concurrency, crash safety, l10n)"
    PIN = "Check the app FFI pin"
    ROLLUP = "Fail on any red check"
    PINNED = "3c5c635f412c722d83d844a7f525b19caa3e87ed"

    def pin_log(self, *extra):
        # What scripts/cmux-next/check-app-ffi-pin.sh prints for a PR that changes the FFI sources, word for word,
        # then the job's rollup step.
        return "\n".join([
            log(self.JOB, self.PIN, f"error: the app FFI sources changed since the pinned source {self.PINNED}:",
                " cmux-tui/crates/cmux-layout-reducer/src/auto_archive.rs | 233 +++++",
                " 1 file changed, 233 insertions(+)",
                "Owning lane(s), which publish the release and update the pin:",
                "  sidebar lane (cmux-layout-reducer, -ffi)",
                "Commits since the pin:",
                "  a9825b1005 Leo: cmux-layout-reducer: auto-archive planner in Rust",
                "Fix: the push to feat-cmux-next runs app-ffi-release.yml; publish its artifact (by hand when the run "
                "says so), then pin the new URL and checksum in Package.swift in one commit, in the same push as the "
                "source change when possible.", "##[error]Process completed with exit code 1."),
            log(self.JOB, self.ROLLUP, f"##[error]red check: {self.PIN}", *extra,
                "##[error]Process completed with exit code 1.")])

    class GitHub(FakeGitHub):
        """Also answers the published base pin rule's reads: Package.swift at the head (blob), where the pinned source
        sits against the base (compare) and the head's commit statuses (compile_pass_at)."""

        def __init__(self, case):
            super().__init__()
            self.case = case

        def blob(self, repo, ref, path):
            self.case.assertEqual((repo, ref), (REPO, HEAD))
            self.case.assertIn(path, (excuse.FFI_PIN_MANIFEST, excuse.FFI_PIN_FILE))
            text = self.case.pin_file if path == excuse.FFI_PIN_FILE else self.case.manifest
            if text is None:
                raise excuse.Refused(f"{repo}@{ref}: {path} is not a text file GitHub served")
            return text

        def json(self, route, *, paginate=False):
            if f"/compare/feat-cmux-next...{self.case.pinned}" in route:
                return {"status": self.case.compare}
            if route.endswith((f"/commits/{HEAD}/status", f"/commits/{HEAD}/statuses?per_page=100&page=1")):
                return status_answer(route, self.case.statuses)
            return super().json(route, paginate=paginate)

    STEP_B_PIN = "1f63d516ecfc798e40d2d031ebfcbb8eb1637e48"

    @staticmethod
    def real_release_reader():
        """`excuse` with its real ffi_release_file (setUp patches it), not a second copy of the module."""
        import types
        return types.SimpleNamespace(ffi_release_file=REAL_FFI_RELEASE_FILE, release_download=excuse.release_download,
                                     Refused=excuse.Refused)

    def setUp(self):
        self.gh = self.GitHub(self)
        self.gh.jobs = {1: failed_job(1, 10, HEAD, name=self.JOB, step=self.ROLLUP),
                        2: dict(failed_job(2, 20, BASE_SHA, name=self.JOB, step=self.ROLLUP), conclusion="success")}
        self.gh.logs = {1: self.pin_log(), 2: ""}
        self.graphql: list[list[str]] = []
        # The published base pin rule's inputs, by default all of it but the compile pass.
        self.pin_at_head(self.STEP_B_PIN)
        self.compare, self.statuses = "behind", []
        self.releases: list[str] = []
        self.sums = None  # SHA256SUMS: by default the pinned checksum's archive entry
        published = unittest.mock.patch.object(excuse, "ffi_release_file", self.release_file)
        published.start()
        self.addCleanup(published.stop)
        # Package.swift and app-ffi-pin.json are read as the classifier reads them, git first (git_answers), never
        # with git stubbed out (review of cmux#41266 at 8fafe451, F1).
        self.reads: Counter = Counter()
        self.fail_second = False
        self.git_answers()

    CHECKSUM = "2" * 64

    @staticmethod
    def target(sha, repo=REPO, checksum=CHECKSUM, host="github.com"):
        return ("let appFFI: Target = .binaryTarget(\n    name: \"CCmuxAppFFI\",\n"
                f"    url: \"https://{host}/{repo}/releases/download/cmux-app-ffi-{sha}/"
                "CCmuxAppFFI.xcframework.zip\",\n"
                f"    checksum: \"{checksum}\"\n)\n")

    def pin_at_head(self, sha, repo=REPO):
        self.pinned, self.source = sha, sha
        self.manifest = ("// The FFI pin (scripts/cmux-next/check-app-ffi-pin.sh): https://example.com/x\n"
                         + self.target(sha, repo))
        self.pin_file = None  # the template form: the head has no app-ffi-pin.json

    # cmux#37645's form: app-ffi-pin.json, and Package.swift holding only its loader block (app_ffi_pin.loader).
    JSON_MANIFEST = ("// swift-tools-version: 6.2\n\nimport Foundation\nimport PackageDescription\n\n"
                     "// CmuxNextCloud -> CCmuxAppFFI (Stack auth)\n" + excuse.app_ffi_pin.loader(CHECKSUM)
                     + "    targets: [\n        appFFI,\n    ] + [appFFI]\n")

    def json_pin_at_head(self, sha, checksum=CHECKSUM, manifest=None):
        self.pinned, self.source = sha, sha
        self.pin_file = excuse.app_ffi_pin.render_pin_file(sha, checksum)
        self.manifest = self.JSON_MANIFEST if manifest is None else manifest

    def release_file(self, repo, tag, name):
        self.releases.append(tag)
        if self.source is None:
            return None
        if name == "SOURCE_SHA":
            return self.source + "\n"
        assert name == "SHA256SUMS", name
        return self.sums if self.sums is not None else (f"{self.CHECKSUM}  CCmuxAppFFI.xcframework.zip\n"
                                                        f"{'9' * 64}  CCmuxAppFFI.xcframework.zip.sha256\n")

    def compiled(self):
        self.statuses = [{"context": "cmux-next/compile", "state": "success"}]

    def pr_files(self, *paths, changed=None, page=100, base_oids=()):
        self.gh.run = pr_graphql(self, self.graphql, paths, number=37292, changed=changed, page=page,
                                 base_oids=base_oids)

    def judge(self):
        return excuse.judge(REPO, "feat-cmux-next", HEAD, [10], self.gh)

    RUST = ("cmux-tui/crates/cmux-layout-reducer/src/auto_archive.rs", "cmux-tui/crates/cmux-layout-reducer/src/lib.rs",
            "cmux-tui/crates/cmux-layout-reducer-ffi/src/lib.rs")

    def test_a_rust_only_ffi_change_is_excused_for_its_stale_pin(self):
        self.pr_files(*self.RUST)
        self.assertEqual(self.judge(), [
            f"excused '{self.JOB}': only '{self.PIN}' is red (\"error: the app FFI sources changed since the pinned "
            "source\"), and #37292 changes app FFI inputs, not Packages/macOS/CmuxNext/Package.swift and no Swift: a "
            "step-A Rust change, pinned by the release its merge publishes"])
        self.assertEqual(len(self.graphql), 1)

    def duplicate_rollup(self):
        # #41158's review, F1 at 5fa1ea1d: a second "Fail on any red check", cancelled, beside the failed one. By name
        # the two are one step, and the pin-only excuse took them as the pin's one red.
        self.gh.jobs[1]["steps"].append(dict(self.gh.jobs[1]["steps"][-1], conclusion="cancelled"))

    def test_review_41158_a_duplicate_rollup_step_is_not_the_pin_only_red_placed(self):
        self.pr_files(*self.RUST)
        self.duplicate_rollup()
        self.assertIsNot(excuse.failed_view(self.gh.jobs[1], self.gh.log(REPO, self.gh.jobs[1]), base=False,
                                            **UNKNOWN), excuse.UNPLACED)
        with self.assertRaises(excuse.Refused) as raised:
            self.judge()
        self.assertNotIn("excused", str(raised.exception))

    def test_review_41158_a_duplicate_rollup_step_is_not_the_pin_only_red_unplaced(self):
        self.pr_files(*self.RUST)
        self.gh.logs[1] = self.unplaced_pin_log()
        self.duplicate_rollup()
        self.assertIs(excuse.failed_view(self.gh.jobs[1], self.gh.log(REPO, self.gh.jobs[1]), base=False, **UNKNOWN),
                      excuse.UNPLACED)
        with self.assertRaises(excuse.Refused) as raised:
            self.judge()
        self.assertNotIn("excused", str(raised.exception))

    def unplaced_pin_log(self, *extra):
        """pin_log with its rollup step run through a composite action (two `Run` headers in one step), so step_owners
        cannot place the log (cmux#41086 at 2026-11-11, after #40542)."""
        pin = [line for line in self.pin_log().split("\n") if line.startswith(f"{self.JOB}\t{self.PIN}\t")]
        return "\n".join(pin + [unplaced_log(self.JOB, self.ROLLUP, f"##[error]red check: {self.PIN}", *extra)])

    def test_an_unplaced_pin_log_is_judged_by_the_pin_rules(self):
        # #40542 refused every unplaced pin red, step A's too: the rules read the PR's paths, never the layout.
        self.gh.logs = {1: self.unplaced_pin_log(), 2: ""}
        job = copy.deepcopy(self.gh.jobs[1])
        self.assertIs(excuse.failed_view(job, self.gh.logs[1], base=False, **UNKNOWN), excuse.UNPLACED)
        self.pr_files(*self.RUST)
        self.assertEqual(self.judge(), [
            f"excused '{self.JOB}': only '{self.PIN}' is red (\"error: the app FFI sources changed since the pinned "
            "source\"), and #37292 changes app FFI inputs, not Packages/macOS/CmuxNext/Package.swift and no Swift: a "
            "step-A Rust change, pinned by the release its merge publishes"])

    def test_an_unplaced_pin_red_no_rule_covers_is_refused(self):
        self.gh.logs = {1: self.unplaced_pin_log(), 2: ""}
        self.pr_files("Packages/macOS/CmuxNext/Sources/CmuxNextApp/AppActions.swift")
        with self.assertRaisesRegex(excuse.Refused, "changes Swift .*nor is its pin a published base release"):
            self.judge()
        self.pr_files("scripts/cmux-next/check-app-ffi-pin.sh")
        with self.assertRaisesRegex(excuse.Refused, "changes the app FFI pin check's code"):
            self.judge()

    def test_an_unplaced_pin_red_beside_a_test_red_is_compared_whole_without_the_pin(self):
        # Another red beside a pin a rule covers: the pin's parts leave, the rest must be the base's exactly.
        shared = "##[error]red check: Motion and colour tokens"
        self.gh.logs = {1: self.unplaced_pin_log(shared),
                        2: unplaced_log(self.JOB, self.ROLLUP, shared)}
        self.gh.jobs[2] = failed_job(2, 20, BASE_SHA, name=self.JOB, step=self.ROLLUP)
        self.pr_files(*self.RUST)
        said = "\n".join(self.judge())
        self.assertIn("compared whole", said)
        self.assertIn(f"; set aside '{self.PIN}'", said)
        # The base's own pin red leaves its side too (cmux#41086's base at 2026-11-11).
        self.gh.logs[2] = unplaced_log(self.JOB, self.ROLLUP, "error: the app FFI sources changed since the pinned "
                                       f"source {'4' * 40}:", f"##[error]red check: {self.PIN}", shared)
        self.assertIn("compared whole", "\n".join(self.judge()))
        self.gh.logs[1] = self.unplaced_pin_log(shared, "##[error]red check: Localization")
        with self.assertRaisesRegex(excuse.Refused, "more on this head: .*red check: Localization"):
            self.judge()

    def test_a_pr_of_more_than_one_page_of_files_is_read_to_its_last_file(self):
        # cmux#37362 at 54470673 changes 108 files; GitHub lists at most 100 per page.
        crates = tuple(f"cmux-tui/crates/cmux-actions/src/action_{i}.rs" for i in range(105))
        self.pr_files(*crates, *self.RUST)
        self.assertTrue(self.judge()[0].startswith(f"excused '{self.JOB}': only '{self.PIN}' is red"))
        self.assertEqual([args[-2:] for args in self.graphql], [["-F", "after=null"], ["-f", "after=100"]])

    def test_a_swift_file_past_the_first_page_is_still_refused(self):
        crates = tuple(f"cmux-tui/crates/cmux-actions/src/action_{i}.rs" for i in range(150))
        self.pr_files(*crates, "Packages/macOS/CmuxNext/Sources/CmuxNextApp/Actions.swift", page=50)
        with self.assertRaisesRegex(excuse.Refused, r"#37292 changes Swift \(Packages/.*Actions.swift\)"):
            self.judge()
        self.assertEqual(len(self.graphql), 4)

    def test_a_file_list_shorter_than_changed_files_is_refused(self):
        crates = tuple(f"cmux-tui/crates/cmux-actions/src/action_{i}.rs" for i in range(108))
        self.pr_files(*crates, changed=109)
        with self.assertRaisesRegex(excuse.Refused, "GitHub listed 108 of its 109 changed files"):
            self.judge()

    def test_a_base_that_moves_between_pages_is_refused(self):
        # Review of e97cfeac (F1): the base branch keeps its name when it advances, so pages could list two diffs.
        crates = tuple(f"cmux-tui/crates/cmux-actions/src/action_{i}.rs" for i in range(108))
        self.pr_files(*crates, base_oids=("b" * 40, "c" * 40))
        with self.assertRaisesRegex(excuse.Refused, "#37292: its base moved"):
            self.judge()

    def test_a_rust_change_that_also_changes_the_pin_checks_code_is_refused(self):
        # Review of cmux#39194 (the main copy of this rule): a PR changing the pin check, its workflow or this
        # classifier could make the pin error print for any change, and the step-A rule would excuse it. Its pin is
        # the base's own published release and its app compiled, so the published base pin rule must not excuse it
        # either.
        self.compiled()
        for path in ("scripts/cmux-next/check-app-ffi-pin.sh", ".github/workflows/cmux-next.yml",
                     "scripts/ci/base_red_excuse.py", "scripts/ci/api_call_log/env.sh", "scripts/ci/app_ffi_pin.py"):
            self.pr_files(*self.RUST, path)
            with self.assertRaisesRegex(excuse.Refused, "changes the app FFI pin check's code", msg=path):
                self.judge()

    # cmux#37869's real file set (a new FFI crate): the release workflow's push paths, the router, the licence list and
    # the FFI build script change with every new crate, and none of them decides the pin check's verdict (review of
    # cmux#39471: a broad list refused every recent step-A PR).
    STEP_A_37869 = (".github/workflows/app-ffi-release.yml", "cmux-tui/Cargo.lock", "cmux-tui/Cargo.toml",
                    "cmux-tui/crates/cmux-app-ffi/Cargo.toml", "cmux-tui/crates/cmux-app-ffi/src/lib.rs",
                    "cmux-tui/crates/cmux-cookie-sync/Cargo.toml", "cmux-tui/crates/cmux-cookie-sync/src/lib.rs",
                    "scripts/ci/cmux_next_route.py", "scripts/cmux-next/build-app-ffi.sh",
                    "scripts/cmux-next/check_app_crate_licenses.py", "tests/test_app_crate_licenses.py")

    def test_a_new_crate_with_its_workflow_router_and_licence_changes_is_excused(self):
        self.pr_files(*self.STEP_A_37869)
        self.assertIn(f"only '{self.PIN}' is red", self.judge()[0])

    def test_a_change_with_no_ffi_input_is_refused(self):
        self.pr_files("docs/ci/app-ffi-release.md")
        with self.assertRaisesRegex(excuse.Refused, "changes no app FFI input"):
            self.judge()

    def test_the_rust_bindings_are_ffi_inputs(self):
        # cmux-app-ffi reaches cmux-tui/bindings/rust through a Cargo path dependency, so check-app-ffi-pin.sh counts
        # it (--list-inputs). A PR that changes only bindings/rust/src was told it "changes no app FFI input"
        # (2026-11-10, after #39027 changed cmux-tui/bindings/rust; the main copy is #40136).
        self.pr_files("cmux-tui/bindings/rust/src/generated/types.rs")
        self.assertIn(f"only '{self.PIN}' is red", self.judge()[0])

    def test_the_other_bindings_are_not_ffi_inputs(self):
        # No crate cmux-app-ffi reaches lives there; bindings/rust-sidebar shares the bindings/rust prefix but not its
        # folder.
        for path in ("cmux-tui/bindings/cpp/CMakeLists.txt", "cmux-tui/bindings/python/cmux/__init__.py",
                     "cmux-tui/bindings/rust-sidebar/src/lib.rs"):
            self.pr_files(path)
            with self.assertRaisesRegex(excuse.Refused, "changes no app FFI input", msg=path):
                self.judge()

    # The published base pin (2026-11-07): a step-B PR's pin is a release built from a commit on the base, and its
    # app compile passed at its head against that pin.
    STEP_B = ("Packages/macOS/CmuxNext/Package.swift",
              "Packages/macOS/CmuxNext/Sources/CmuxNextSidebar/Logic/RustSidebarClient.swift")

    def unplaced_rollup_head(self):
        """cmux#40552's unplaced checks job (RollupJobReadsItsNamedReds' fixture) as this case's head: its whole log
        sets the pin aside (a passing step's next-batch lines), so the rollup reading asks the pin rule again."""
        fixtures = ROOT / "tests/fixtures/test_reds"
        job = json.loads((fixtures / "cmux-40552-checks-job-130212680188.json").read_text())
        self.gh.jobs[1] = dict(job, id=1, run_id=10, head_sha=HEAD)
        self.gh.logs[1] = (fixtures / "cmux-40552-checks-job-130212680188.log").read_text(encoding="utf-8")

    def git_answers(self):
        """This case's files from the real excuse.git_text, with git itself faked at subprocess.run: a fetch of any
        ref, then `git show` of Package.swift or app-ffi-pin.json at it, the same text GitHub.blob serves (none when
        the head has no such file). Each fetch and show counts in self.reads; after self.wire(fail_second=True) a
        second fetch of a ref fails, as an unreachable remote does."""
        real_run = subprocess.run

        def run(argv, *args, **kwargs):
            if not argv or argv[0] != "git":
                return real_run(argv, *args, **kwargs)
            answer = subprocess.CompletedProcess(argv, 0, stdout=b"", stderr=b"")
            if "fetch" in argv:
                key = ("git fetch", argv[-1].lstrip("+").split(":")[0])
                self.reads[key] += 1
                answer.returncode = int(self.fail_second and self.reads[key] > 1)
            elif "rev-parse" in argv:
                answer.stdout = b"f" * 40 + b"\n"
            elif "show" in argv:
                path = argv[-1].split(":", 1)[1]
                self.reads[("git show", path)] += 1
                text = {excuse.FFI_PIN_MANIFEST: self.manifest, excuse.FFI_PIN_FILE: self.pin_file}.get(path)
                answer.returncode, answer.stdout = (128, b"") if text is None else (0, text.encode())
            return answer
        cache = tempfile.TemporaryDirectory(prefix="bre-git-")
        self.addCleanup(cache.cleanup)
        for patch in (unittest.mock.patch.object(excuse, "git_text", REAL_GIT_TEXT),
                      unittest.mock.patch.object(subprocess, "run", run),
                      unittest.mock.patch.dict(os.environ, {excuse.SOURCE_CACHE_ENV: cache.name})):
            patch.start()
            self.addCleanup(patch.stop)

    def wire(self, fail_second=False):
        """Every network entry point of one judgement counted by key in self.reads: gh (this suite's fake client is
        the gh transport: its json, run, blob and log), git (git_answers), the release downloads
        (release_download.fetch under the real ffi_release_file) and the compile receipts (urlopen under the real
        compile_receipt; the fleet has none). FAIL_SECOND: a second read of any key fails, as a 503 does."""
        import urllib.error
        self.fail_second = fail_second

        def second(key):
            self.reads[key] += 1
            return fail_second and self.reads[key] > 1

        def through(key, read):
            if second(key):
                raise excuse.Refused(f"GitHub evidence request failed: HTTP 503 Service Unavailable ({key})")
            return read()
        inner_json, inner_run, inner_blob, inner_log = self.gh.json, self.gh.run, self.gh.blob, self.gh.log
        self.gh.json = lambda route, *, paginate=False: through(("gh api", route, paginate),
                                                                lambda: inner_json(route, paginate=paginate))
        self.gh.run = lambda args: through(("gh", *args), lambda: inner_run(args))
        self.gh.blob = lambda repo, ref, path: through(("graphql blob", ref, path), lambda: inner_blob(repo, ref, path))
        self.gh.log = lambda repo, job: through(("gh log", job["id"]), lambda: inner_log(repo, job))

        def fetch(url, out, accept=None, timeout=120):
            if second(("release", url)):
                raise urllib.error.HTTPError(url, 503, "Service Unavailable", {}, None)
            if url.startswith("https://api.github.com/"):  # the release-assets API: no such asset
                Path(out).write_text('{"assets": []}')
                return
            tag, name = url.rsplit("/", 2)[1:]
            text = self.release_file(REPO, tag, name)
            if text is None:
                raise urllib.error.HTTPError(url, 404, "Not Found", {}, None)
            Path(out).write_text(text)

        def urlopen(request, timeout=None):
            url = getattr(request, "full_url", request)
            raise urllib.error.HTTPError(url, 503 if second(("urlopen", url)) else 404, "receipt", {}, None)
        for patch in (unittest.mock.patch.object(excuse, "ffi_release_file", REAL_FFI_RELEASE_FILE),
                      unittest.mock.patch.object(excuse.release_download, "fetch", fetch),
                      unittest.mock.patch.object(excuse, "compile_receipt", REAL_COMPILE_RECEIPT),
                      unittest.mock.patch.object(urllib.request, "urlopen", urlopen)):
            patch.start()
            self.addCleanup(patch.stop)
        return self.reads

    def release_url(self, name):
        return f"https://github.com/{REPO}/releases/download/cmux-app-ffi-{self.STEP_B_PIN}/{name}"

    def test_review_f1_a_second_read_of_a_proven_published_pin_never_overturns_it(self):
        # Review of cmux#41151 at bfa0db5f (F1): a Swift change's pin is a published base release it compiled against.
        # The whole-log reading proves it and sets the pin aside; the rollup reading asks the pin rule again, and its
        # second read of the release files got a 503, refusing what the first proof had excused. Review of cmux#41266
        # at 8fafe451 (F1): the same through git, whose second fetch failed, then GraphQL's 503.
        self.unplaced_rollup_head()
        self.pr_files(*self.STEP_B)
        self.compiled()
        reads = self.wire(fail_second=True)
        said = self.judge()
        self.assertEqual(len(said), 1, said)
        self.assertTrue(said[0].startswith(f"excused '{self.JOB}': only '{self.PIN}' is red"), said)
        self.assertIn(f"pins cmux-app-ffi-{self.STEP_B_PIN}", said[0])
        self.assertEqual(reads[("release", self.release_url("SOURCE_SHA"))], 1)
        self.assertEqual(reads[("git show", excuse.FFI_PIN_MANIFEST)], 1, "Package.swift is read through git")

    def test_one_judgement_reads_each_source_once(self):
        # The class: every network entry point an excuse path reads (gh api, GraphQL, a job's log, git, the release
        # downloads, the compile receipts) is read once per judgement, however many paths ask. A reader added
        # outside the memo fails here on its own.
        self.unplaced_rollup_head()
        self.pr_files(*self.STEP_B)
        self.compiled()
        reads = self.wire()
        self.assertTrue(self.judge()[0].startswith(f"excused '{self.JOB}'"))
        self.assertEqual({key: n for key, n in reads.items() if n > 1}, {})
        self.assertTrue({"gh api", "gh", "gh log", "git fetch", "git show", "release"}
                        <= {key[0] for key in reads}, sorted(reads))
        # A new judgement reads afresh: nothing is kept past the judgement that read it.
        self.judge()
        self.assertEqual(reads[("release", self.release_url("SOURCE_SHA"))], 2)

    def test_review_f1_a_failed_compile_job_read_falls_back_to_the_status(self):
        # Review of cmux#41151 at fd50c9b7 (F1), the same class: compile_pass_at's first source (the head's check runs)
        # is one way to know; a 503 on it moves on to the cmux-next/compile status, which says it compiled.
        self.pr_files(*self.STEP_B)
        self.compiled()
        inner = self.gh.json

        def json(route, *, paginate=False):
            if route.endswith(f"commits/{HEAD}/check-runs?filter=all&per_page=100"):
                raise excuse.Refused("gh: Service Unavailable (HTTP 503)")
            return inner(route, paginate=paginate)
        self.gh.json = json
        self.assertIn(f"the cmux-next/compile status compiled {HEAD} against that pin and passed", self.judge()[0])
        # No source passes and one was unread: refused naming it, never read as "did not compile".
        self.statuses = []
        with self.assertRaisesRegex(excuse.Refused, "its compile jobs \\(gh: Service Unavailable"):
            self.judge()

    def test_a_step_b_pin_on_the_base_that_compiled_is_excused(self):
        # cmux#37428 at 872fe1e7: Swift and a pin of cmux-app-ffi-1f63d516, which other PRs' Rust has since passed.
        self.pr_files(*self.STEP_B)
        self.compiled()
        self.assertEqual(self.judge(), [
            f"excused '{self.JOB}': only '{self.PIN}' is red (\"error: the app FFI sources changed since the pinned "
            f"source\"), and #37292 pins cmux-app-ffi-{self.STEP_B_PIN}, a published release built from 1f63d516ecfc, "
            f"which is on feat-cmux-next, and the cmux-next/compile status compiled {HEAD} against that pin and passed"])
        self.assertEqual(self.releases, [f"cmux-app-ffi-{self.STEP_B_PIN}"] * 2)

    def test_a_re_pin_alone_on_the_base_that_compiled_is_excused(self):
        # cmux#37353: the re-pin bot's Package.swift-only PR, a few FFI commits behind the base tip.
        self.pr_files("Packages/macOS/CmuxNext/Package.swift")
        self.compiled()
        self.assertIn("pins cmux-app-ffi-1f63d516", self.judge()[0])

    def test_a_json_pin_on_the_base_that_compiled_is_excused(self):
        # cmux#37645 moves the pin to app-ffi-pin.json; this classifier runs from the base, so it reads that form
        # before the PR lands. Changing the pin file moves the pin, so only the published base pin rule can excuse it.
        self.json_pin_at_head(self.STEP_B_PIN)
        self.pr_files(excuse.FFI_PIN_FILE, excuse.FFI_PIN_MANIFEST)
        self.compiled()
        self.assertEqual(self.judge(), [
            f"excused '{self.JOB}': only '{self.PIN}' is red (\"error: the app FFI sources changed since the pinned "
            f"source\"), and #37292 pins cmux-app-ffi-{self.STEP_B_PIN}, a published release built from 1f63d516ecfc, "
            f"which is on feat-cmux-next, and the cmux-next/compile status compiled {HEAD} against that pin and passed"])
        self.pr_files(excuse.FFI_PIN_FILE)
        self.assertIn("pins cmux-app-ffi-1f63d516", self.judge()[0])

    def test_a_json_pin_that_also_changes_the_pin_reader_is_refused(self):
        # cmux#37645's own file set: the pin reader (scripts/ci/app_ffi_pin.py) is the pin check's code, so the PR
        # that changes it cannot excuse its own pin red; it lands the reader on its own, or with the pin check green.
        self.json_pin_at_head(self.STEP_B_PIN)
        self.pr_files(excuse.FFI_PIN_FILE, excuse.FFI_PIN_MANIFEST, "scripts/ci/app_ffi_pin.py")
        self.compiled()
        with self.assertRaisesRegex(excuse.Refused, r"changes the app FFI pin check's code \(scripts/ci/app_ffi_pin.py\)"):
            self.judge()

    def test_a_json_pin_off_its_rules_is_refused(self):
        line = f"// app-ffi-pin-checksum: {self.CHECKSUM}\n"
        loader = excuse.app_ffi_pin.LOADER
        for pin_file, manifest, why in (
                (excuse.app_ffi_pin.render_pin_file(self.STEP_B_PIN, self.CHECKSUM).replace(", ", ",  "), None,
                 "is not in its one format"),
                (excuse.app_ffi_pin.render_pin_file(self.STEP_B_PIN, self.CHECKSUM).replace("manaflow-ai/", "x/"),
                 None, "url is not"),
                (None, self.JSON_MANIFEST.replace(line, f"// app-ffi-pin-checksum: {'4' * 64}\n"),
                 "is not Packages/macOS/CmuxNext/app-ffi-pin.json's checksum"),
                (None, self.JSON_MANIFEST.replace(line, ""), "lines, not one"),
                (None, self.JSON_MANIFEST.replace(loader, loader.replace("url: appFFIPin.url,", "url: appFFIPin.checksum,")),
                 "does not hold the one fixed"),
                (None, self.JSON_MANIFEST + self.target(self.STEP_B_PIN), "has 'releases/download/'"),
                (None, self.JSON_MANIFEST + "enum Foundation { }\n", "names a pin loader symbol outside the loader")):
            with self.subTest(why=why):
                self.setUp()
                self.json_pin_at_head(self.STEP_B_PIN, manifest=manifest)
                if pin_file is not None:
                    self.pin_file = pin_file
                self.pr_files(excuse.FFI_PIN_FILE)
                self.compiled()
                with self.assertRaisesRegex(excuse.Refused, why):
                    self.judge()
                self.assertEqual(self.releases, [])

    def test_a_template_manifest_beside_a_pin_file_is_refused(self):
        # A head with app-ffi-pin.json is read in the JSON form only: its Package.swift's own pin does not count.
        self.json_pin_at_head(self.STEP_B_PIN, manifest=self.manifest)
        self.pr_files(excuse.FFI_PIN_FILE)
        self.compiled()
        with self.assertRaisesRegex(excuse.Refused, "has 'releases/download/'|lines, not one"):
            self.judge()

    def test_swift_alone_against_the_base_pin_that_compiled_is_excused(self):
        self.pr_files(self.STEP_B[1])
        self.compiled()
        self.assertIn("a published release built from 1f63d516ecfc", self.judge()[0])

    def test_a_step_b_pin_with_no_compile_pass_is_refused_naming_it(self):
        self.pr_files(*self.STEP_B)
        with self.assertRaisesRegex(excuse.Refused, "changes Packages/macOS/CmuxNext/Package.swift: a PR that moves "
                                    "the pin must pin a release built from its own sources; nor is its pin a "
                                    f"published base release it compiled against: no app compile check passed at "
                                    f"{HEAD}"):
            self.judge()
        self.statuses = [{"context": "cmux-next/compile", "state": "failure"}]
        with self.assertRaisesRegex(excuse.Refused, "no app compile check passed"):
            self.judge()

    # cmux#39251 at 3c886d8d (2026-11-10): Swift beside a published base pin, and every app compile check was skipped by
    # routing, so no cmux-next/compile status was posted; the fleet's own receipt for that head read "pass". The
    # receipt is what that status publishes (cmux-next.yml's compile-status step), read the same strict way.
    RECEIPT = {"version": 1, "repo": REPO, "sha": HEAD, "job_id": "c257c52ddd346afa97008a22", "state": "pass",
               "recipe_version": 2, "configuration": "release-onone",
               "log_url": f"https://github.com/{REPO}/actions/runs/42721510171", "log_url_kind": "source_run"}

    def receipt_answer(self, body):
        """The real receipt reader, with the receipts host answering BODY for HEAD (None: 404, no receipt)."""
        def urlopen(request, timeout):
            self.assertTrue(request.full_url.startswith(f"{excuse.COMPILE_RECEIPTS}/{HEAD}?"), request.full_url)
            if body is None:
                raise urllib.error.HTTPError(request.full_url, 404, "x", {}, None)
            return contextlib.closing(io.BytesIO(json.dumps(body).encode()))
        stack = contextlib.ExitStack()
        stack.enter_context(unittest.mock.patch.object(excuse, "compile_receipt", REAL_COMPILE_RECEIPT))
        stack.enter_context(unittest.mock.patch("urllib.request.urlopen", urlopen))
        return stack

    def test_swift_against_the_base_pin_with_a_passing_fleet_receipt_at_the_head_is_excused(self):
        self.pr_files(*self.STEP_B)
        with self.receipt_answer(self.RECEIPT):
            self.assertEqual(self.judge(), [
                f"excused '{self.JOB}': only '{self.PIN}' is red (\"error: the app FFI sources changed since the pinned "
                f"source\"), and #37292 pins cmux-app-ffi-{self.STEP_B_PIN}, a published release built from "
                "1f63d516ecfc, which is on feat-cmux-next, and the fleet's app compile receipt (job "
                f"c257c52ddd346afa97008a22, recipe 2, release-onone) compiled {HEAD} against that pin and passed"])

    def test_a_fleet_receipt_of_another_commit_is_refused(self):
        self.pr_files(*self.STEP_B)
        with self.receipt_answer(dict(self.RECEIPT, sha=BASE_SHA)), \
                self.assertRaisesRegex(excuse.Refused, "names another commit"):
            self.judge()
        with self.receipt_answer(dict(self.RECEIPT, repo="someone/cmux")), \
                self.assertRaisesRegex(excuse.Refused, "names another commit"):
            self.judge()

    def test_a_fleet_receipt_that_did_not_pass_is_refused(self):
        self.pr_files(*self.STEP_B)
        for state in ("fail", "unavailable", "running", "queued", None):
            with self.subTest(state=state), self.receipt_answer(dict(self.RECEIPT, state=state)), \
                    self.assertRaisesRegex(excuse.Refused, "no app compile check passed"):
                self.judge()
        with self.receipt_answer(None), self.assertRaisesRegex(excuse.Refused, "no app compile check passed"):
            self.judge()

    def test_a_receipt_that_is_not_the_app_compile_is_refused(self):
        """Only the controller's own app check (`--app --release`, recipe 2: release-onone) is the receipt the
        workflow trusts. Another recipe or configuration, or a package check's row (cmux-ci compile-check --package:
        package, ok, no state or configuration), proves nothing about the app."""
        self.pr_files(*self.STEP_B)
        package_row = {"package": "CmuxNext", "repo": REPO, "sha": HEAD, "ok": True, "recipe_version": 2}
        for body in (dict(self.RECEIPT, recipe_version=1), dict(self.RECEIPT, configuration="debug"),
                     dict(self.RECEIPT, configuration=None), package_row):
            with self.subTest(body=body), self.receipt_answer(body), \
                    self.assertRaisesRegex(excuse.Refused, "another recipe"):
                self.judge()

    def test_a_pin_not_on_the_base_is_refused_naming_it(self):
        self.pr_files(*self.STEP_B)
        self.compiled()
        for status in ("ahead", "diverged"):
            with self.subTest(status=status):
                self.compare = status
                with self.assertRaisesRegex(excuse.Refused, f"the pinned release's source 1f63d516ecfc is not an "
                                            f"ancestor of feat-cmux-next \\(it is {status}\\)"):
                    self.judge()

    def test_an_unpublished_pin_is_refused_naming_it(self):
        self.pr_files(*self.STEP_B)
        self.compiled()
        self.source = None
        with self.assertRaisesRegex(excuse.Refused, f"cmux-app-ffi-{self.STEP_B_PIN} is not published"):
            self.judge()
        self.source = "0" * 40
        with self.assertRaisesRegex(excuse.Refused, "records SOURCE_SHA '0000000000"):
            self.judge()

    def test_a_pin_of_another_repository_is_refused(self):
        self.pr_files(*self.STEP_B)
        self.compiled()
        self.pin_at_head(self.STEP_B_PIN, repo="someone/cmux")
        with self.assertRaisesRegex(excuse.Refused, "is not the canonical CCmuxAppFFI pin line"):
            self.judge()
        self.assertEqual(self.releases, [])

    def test_a_step_a_change_reads_nothing_for_the_published_base_pin(self):
        # Step A merges are never held by the published base pin rule: they never ask it.
        self.pr_files(*self.RUST)
        self.source = None
        self.assertIn("a step-A Rust change", self.judge()[0])
        self.assertEqual(self.releases, [])

    def test_the_release_files_are_read_anonymously_and_a_404_is_unpublished(self):
        import io
        import urllib.error
        # setUp replaced the reader in `excuse`; the real one, saved before any patch, reads through the same module.
        module = self.real_release_reader()
        urls = []

        def answer(code):
            # The release download's one HTTP call (github_release_download.py, deadline_http.stream): its stall is
            # the per-wait timeout the caller passes, and an error status raises (raise_errors).
            @contextlib.contextmanager
            def stream(request, seconds=None, *, stall=None, raise_errors=False, **options):
                url = request.full_url
                urls.append((url, stall, request.get_header("Authorization")))
                self.assertTrue(raise_errors)
                if code != 200:
                    raise urllib.error.HTTPError(url, code, "x", {}, None)
                yield io.BytesIO(f"{self.STEP_B_PIN}\n".encode())
            return unittest.mock.patch.object(module.release_download.deadline_http, "stream", stream)

        tag = f"cmux-app-ffi-{self.STEP_B_PIN}"
        with answer(200):
            self.assertEqual(module.ffi_release_file(REPO, tag, "SOURCE_SHA"), f"{self.STEP_B_PIN}\n")
        self.assertEqual(urls, [(f"https://github.com/{REPO}/releases/download/{tag}/SOURCE_SHA", 30, None)])
        # A 404 is GitHub's answer, not an outage: no release-assets API read follows it.
        urls.clear()
        with answer(404):
            self.assertIsNone(module.ffi_release_file(REPO, tag, "SHA256SUMS"))
        self.assertEqual(len(urls), 1)
        with answer(502), \
                self.assertRaisesRegex(module.Refused, "HTTP 502; the pinned release could not be read"):
            module.ffi_release_file(REPO, tag, "SOURCE_SHA")

    def test_a_release_file_whose_download_fails_is_read_through_the_release_assets_api(self):
        # 2026-11-08: every GitHub release download answered 503 or 504 while the release-assets API served the same
        # files, and every published base pin was refused as unread, which held every merge.
        import io
        import urllib.error
        module = self.real_release_reader()
        tag = f"cmux-app-ffi-{self.STEP_B_PIN}"
        download = f"https://github.com/{REPO}/releases/download/{tag}/SOURCE_SHA"
        listing = f"https://api.github.com/repos/{REPO}/releases/tags/{tag}"
        asset = f"https://api.github.com/repos/{REPO}/releases/assets/7"
        asked = []

        @contextlib.contextmanager
        def stream(request, seconds=None, *, stall=None, **options):
            url = getattr(request, "full_url", request)
            auth = request.get_header("Authorization") if hasattr(request, "get_header") else None
            asked.append((url, stall, auth))
            if auth:  # the redirect handler copies request.headers, so the token must not be among them
                self.assertNotIn("Authorization", request.headers)
            if url == download:
                raise urllib.error.HTTPError(url, 503, "Service Unavailable", {}, None)
            if url == listing:
                yield io.BytesIO(json.dumps({"assets": [{"name": "SHA256SUMS", "url": asset + "0"},
                                                        {"name": "SOURCE_SHA", "url": asset}]}).encode())
                return
            if url == asset:
                self.assertEqual(request.get_header("Accept"), "application/octet-stream")
                yield io.BytesIO(f"{self.STEP_B_PIN}\n".encode())
                return
            raise AssertionError(f"unexpected fetch {url}")

        with unittest.mock.patch.object(module.release_download.deadline_http, "stream", stream), \
                unittest.mock.patch.dict(os.environ, {"GH_TOKEN": "t0ken"}):
            self.assertEqual(module.ffi_release_file(REPO, tag, "SOURCE_SHA"), f"{self.STEP_B_PIN}\n")
        # The token goes to api.github.com only, and never on to the asset's storage redirect (unredirected).
        self.assertEqual(asked, [(download, 30, None), (listing, 30, "Bearer t0ken"), (asset, 30, "Bearer t0ken")])

    # The pin is app_ffi_pin.py's canonical block (2026-11-07, after five lexer holes): raw text, nothing skipped. Each
    # attack the lexer once missed now refuses on a forbidden construct, a count, or a line off the template, and no
    # release is read for it.
    DIVERGED = "d" * 40
    NOT_CANONICAL = "is not the canonical CCmuxAppFFI pin line"

    def refused_with(self, manifest, pattern):
        self.pr_files(*self.STEP_B)
        self.compiled()
        self.manifest = manifest
        with self.assertRaisesRegex(excuse.Refused, pattern):
            self.judge()

    def refused_unread(self, manifest, pattern):
        self.refused_with(manifest, pattern)
        self.assertEqual(self.releases, [])

    def inline(self, sha):
        return self.target(sha).replace("let appFFI: Target = ", "").replace("\n", " ").strip()

    def test_a_published_target_in_a_comment_beside_a_diverged_one_is_refused(self):
        published = self.target(self.STEP_B_PIN)
        self.refused_unread("".join(f"// {line}\n" for line in published.splitlines()) + self.target(self.DIVERGED),
                            "has 2 'binaryTarget', not one")
        self.refused_unread("/* an old pin:\n" + published + "*/\n" + self.target(self.DIVERGED),
                            "line 1 has '/\\*'")

    def test_a_pin_in_any_string_or_regex_is_refused(self):
        published = self.target(self.STEP_B_PIN)
        for opening, closing, token in (('"""\n', '"""', '\'"""\''), ('#"', '"#', "'#\"'"), ("#/", "/#", "'#/'"),
                                        ("#" * 64 + '"', '"' + "#" * 64, "'#\"'"),
                                        ("#" * 200 + '"x"' + "#" * 63 + "\n", '"' + "#" * 200, "'#\"'")):
            with self.subTest(opening=opening[:8]):
                self.refused_unread(f"let s = {opening}{published}{closing}\nlet ffiName = \"CCmuxAppFFI\"\n"
                                    + self.target(self.DIVERGED).replace('name: "CCmuxAppFFI"', "name: ffiName"),
                                    f"has {re.escape(token)}, which no canonical pin file has")

    def test_an_interpolation_or_conditional_compilation_is_refused(self):
        self.refused_unread(f'let s = "\\(Target.self/* ) " */{self.inline(self.STEP_B_PIN)})"\n',
                            "has '/\\*'")
        self.refused_unread(f'let s = "\\(Target.self{self.inline(self.STEP_B_PIN)})"\n',
                            "line 1 is not the canonical CCmuxAppFFI pin line")
        self.refused_unread("#if false\n" + self.target(self.STEP_B_PIN) + "#endif\n" + self.target(self.DIVERGED),
                            "has '#if'")

    def test_a_target_off_the_template_is_refused(self):
        published = self.target(self.STEP_B_PIN)
        url = (f"https://github.com/{REPO}/releases/download/cmux-app-ffi-{self.STEP_B_PIN}/"
               "CCmuxAppFFI.xcframework.zip")
        for manifest in (
                published.replace('name: "CCmuxAppFFI"', "name: ffiName"),
                published.replace('name: "CCmuxAppFFI"', 'name: "CCmux" + "AppFFI"'),
                published.replace('name: "CCmuxAppFFI"', 'name: "\\(prefix)AppFFI"'),
                published.replace('url: "https', 'url: "" + "https'),
                published.replace("    checksum:", '    path: "x",\n    checksum:'),
                published.replace("    name:", "  name:"),
                published.replace("let appFFI: Target = ", "let other: Target = "),
                f'.binaryTarget(name: "CCmuxAppFFI", path: local(url: "{url}", checksum: "{self.CHECKSUM}"))\n',
                self.target(self.STEP_B_PIN, host="github.com.evil.example"),
                self.target(self.STEP_B_PIN, repo="someone/cmux")):
            with self.subTest(manifest=manifest[:90]):
                self.refused_unread(manifest, self.NOT_CANONICAL)

    def test_a_second_target_or_declaration_is_refused(self):
        published = self.target(self.STEP_B_PIN)
        self.refused_unread(published + published.replace("let appFFI", "let b"), "has 2 'binaryTarget', not one")
        self.refused_unread("let x = 1\n", "has 0 'binaryTarget', not one")
        self.refused_unread(published + '.target(name: "CCmuxAppFFI", path: "Shim"),\n',
                            "line 6 names CCmuxAppFFI or appFFI outside the canonical pin")
        self.refused_unread(published + "let f = [appFFI].first!\n", "names CCmuxAppFFI or appFFI outside")

    def test_the_fixed_reference_shapes_pass(self):
        self.pr_files(*self.STEP_B)
        self.compiled()
        self.manifest = ("// CmuxNextCloud -> CCmuxAppFFI (Stack auth)\n" + self.target(self.STEP_B_PIN)
                         + '        .target(\n            dependencies: ["CmuxNextDesign", .product(name: "A", package: '
                         '"B"), "CCmuxAppFFI"],\n            dependencies: [\n                "CCmuxAppFFI",\n'
                         "            ]\n    targets: [\n        appFFI,\n    ] + [appFFI]\n")
        self.assertEqual(len(self.judge()), 1)

    def test_a_checksum_that_is_not_the_releases_archive_entry_is_refused(self):
        self.sums = f"{'3' * 64}  CCmuxAppFFI.xcframework.zip\n{self.CHECKSUM}  CCmuxAppFFI.xcframework.zip.sha256\n"
        self.refused_with(self.manifest, "the pinned checksum 222222222222 is not cmux-app-ffi-1f63d516ecfc798e40d2d031e"
                                         "bfcbb8eb1637e48's SHA256SUMS entry")

    def test_a_published_pin_beside_another_red_is_judged_as_before_and_an_unpublished_one_refused(self):
        # Review of 6e7159aa (F1): beside another red, a published base pin leaves the job to the base comparison
        # (None from the rule). An unpublished one still refuses: the comparison could set the pin error aside beside
        # a red the base shares (review of d5c11dd8), so it must not return None.
        self.gh.logs[1] = self.pin_log("##[error]red check: Localized strings are complete")
        self.pr_files(*self.STEP_B)
        self.compiled()
        with self.assertRaisesRegex(excuse.Refused, "not red on feat-cmux-next run 20"):
            self.judge()
        self.source = None
        with self.assertRaisesRegex(excuse.Refused, "nor is its pin a published base release"):
            self.judge()

    def test_the_real_manifest_reads_its_one_pin(self):
        # This checkout's Package.swift (the base it branched from) is canonical.
        text = (ROOT / excuse.FFI_PIN_MANIFEST).read_text(encoding="utf-8")
        pin, checksum, why = excuse.ffi_binary_target(text, REPO)
        self.assertEqual(why, "")
        self.assertRegex(pin, r"^[0-9a-f]{40}$")
        self.assertIn(f"cmux-app-ffi-{pin}/CCmuxAppFFI.xcframework.zip", text)
        self.assertIn(f'checksum: "{checksum}"', text)

    def test_a_crash_exit_beside_the_pin_red_is_never_excused(self):
        # Review F1 (9cac2029): the rule asks only after test_reds.read found no crash or cut-short run.
        self.gh.logs[1] = self.pin_log("##[error]Process completed with exit code 134.")
        self.pr_files(*self.RUST)
        with self.assertRaisesRegex(excuse.Refused, "never a base red"):
            self.judge()
        self.assertEqual(self.graphql, [])

    def test_another_failed_step_with_no_error_line_is_not_hidden(self):
        # Review F2 (9cac2029): a step that failed without printing a recognized error still leaves the rule out.
        self.gh.jobs[1]["steps"].insert(1, {"name": "Localized strings are complete", "status": "completed",
                                            "conclusion": "failure"})
        self.pr_files(*self.RUST)
        with self.assertRaisesRegex(excuse.Refused, "not red on feat-cmux-next run 20"):
            self.judge()
        self.assertEqual(len(self.graphql), 1)  # the path rule passed first

    def test_a_swift_change_is_refused_even_when_another_red_is_shared_with_the_base(self):
        # Review of d5c11dd8: beside a failing test the base shares, the base comparison sets error lines aside, so
        # the pin's path rule is checked wherever the pin error shows.
        name = "test_pin_paths (tests.test_x.T)"
        shared = [f"FAIL: {name}", "Ran 1 test in 0.01s", "FAILED (failures=1)"]
        self.gh.logs[1] = self.pin_log(*shared)
        self.gh.jobs[2]["conclusion"] = "failure"
        self.gh.logs[2] = log(self.JOB, self.ROLLUP, *shared)
        self.pr_files(*self.RUST, "Packages/macOS/CmuxNext/Sources/CmuxNextSidebar/Logic/RustSidebarClient.swift")
        with self.assertRaisesRegex(excuse.Refused, "its app FFI pin is red, and #37292 changes Swift"):
            self.judge()

    def test_other_reds_after_the_path_rule_passes_are_judged_as_before(self):
        self.gh.logs[1] = self.pin_log("##[error]red check: Localized strings are complete")
        self.pr_files(*self.RUST)
        with self.assertRaisesRegex(excuse.Refused, "not red on feat-cmux-next run 20"):
            self.judge()
        self.assertEqual(len(self.graphql), 1)

    def test_a_covered_pin_beside_a_red_the_base_shares_is_set_aside(self):
        # cmux#37767 at 525bb16f: a step-A Rust change whose job also carried a red the base had too. The base never has
        # the pin error, so comparing it with the base refused a PR the pin rule covers.
        shared = "##[error]red check: Localized strings are complete"
        self.gh.logs[1] = self.pin_log(shared)
        self.gh.jobs[2]["conclusion"] = "failure"
        self.gh.logs[2] = log(self.JOB, self.ROLLUP, shared, "##[error]Process completed with exit code 1.")
        self.pr_files(*self.RUST)
        [line] = self.judge()
        self.assertIn("fails the same way", line)
        self.assertIn("red check: Localized strings are complete", line)
        self.assertNotIn("app FFI sources changed since the pinned source:", line.split("; set aside")[0])
        self.assertTrue(line.endswith(
            f"; set aside '{self.PIN}' (\"error: the app FFI sources changed since the pinned source\"): #37292 "
            "changes app FFI inputs, not Packages/macOS/CmuxNext/Package.swift and no Swift: a step-A Rust change, "
            "pinned by the release its merge publishes"), line)

    def test_a_covered_pin_beside_a_red_the_base_lacks_is_refused(self):
        self.gh.logs[1] = self.pin_log("##[error]red check: Localized strings are complete")
        self.gh.jobs[2]["conclusion"] = "failure"
        self.gh.logs[2] = log(self.JOB, self.ROLLUP, "##[error]red check: Swift files are formatted",
                              "##[error]Process completed with exit code 1.")
        self.pr_files(*self.RUST)
        with self.assertRaisesRegex(excuse.Refused, "errors not on feat-cmux-next .*Localized strings are complete"):
            self.judge()

    def test_an_uncovered_pin_beside_a_red_the_base_shares_is_still_refused(self):
        # The set-aside needs the path rule or a published base pin: a Swift change's pin error never leaves.
        shared = "##[error]red check: Localized strings are complete"
        self.gh.logs[1] = self.pin_log(shared)
        self.gh.jobs[2]["conclusion"] = "failure"
        self.gh.logs[2] = log(self.JOB, self.ROLLUP, shared, "##[error]Process completed with exit code 1.")
        self.pr_files(*self.RUST, "Packages/macOS/CmuxNext/Sources/CmuxNextSidebar/Logic/RustSidebarClient.swift")
        self.source = None
        with self.assertRaisesRegex(excuse.Refused, "its app FFI pin is red, and #37292 changes Swift"):
            self.judge()

    def test_a_rollup_that_never_named_the_pin_is_another_red(self):
        # Review of 0e1e7204: the rollup failed before its "red check:" line, so something else broke it.
        self.gh.logs[1] = self.pin_log().replace(f"##[error]red check: {self.PIN}", "Reading the step outcomes")
        self.pr_files(*self.RUST)
        with self.assertRaisesRegex(excuse.Refused, "not red on feat-cmux-next run 20"):
            self.judge()

    def test_the_pin_step_itself_may_report_its_failure(self):
        self.gh.jobs[1]["steps"].insert(1, {"name": self.PIN, "status": "completed", "conclusion": "failure"})
        self.pr_files(*self.RUST)
        self.assertTrue(self.judge()[0].startswith(f"excused '{self.JOB}': only '{self.PIN}' is red"))

    def test_the_pin_error_in_another_job_is_not_this_rule(self):
        self.gh.jobs[1]["name"] = self.gh.jobs[2]["name"] = SWIFT
        self.pr_files(*self.RUST)
        with self.assertRaises(excuse.Refused):
            self.judge()
        self.assertEqual(self.graphql, [])



GALLERY = "health (1)"
RENDER_STEP, REPLAY_STEP = "Render the gallery and judge it", "Judge the red states against the base"
GALLERY_STATE = "agent-pane.subagent-tray#restart-on-hover"
PILL_ASKS = ("SyntaxError: Export named 'pillAsks' not found in module "
             "'/home/runner/_work/cmux/cmux/webviews/src/agent-session/acpmux/needsYou/JumpPill.tsx'.")
OLDER_SHA, OLDEST_SHA = "c" * 40, "d" * 40


def gallery_job(job_id, run_id, sha, *, failed=REPLAY_STEP, render="success"):
    steps = [("Checkout", "success"), ("Choose the entries to render", "success"),
             (RENDER_STEP, render), (REPLAY_STEP, "skipped"),
             ("Record what was rendered", "success")]
    return {"id": job_id, "run_id": run_id, "head_sha": sha, "name": GALLERY, "status": "completed",
            "conclusion": "failure" if failed else "success",
            "steps": [{"name": step, "status": "completed",
                       "conclusion": "failure" if step == failed else conclusion} for step, conclusion in steps]}


def health(*states, reason="did not render: never reported ready after 30000 ms"):
    return json.dumps({"fresh": [{"state": state, "reason": reason} for state in states], "known": [], "slow": []})


class GalleryGitHub(FakeGitHub):
    """A gallery health shard of run 10 whose base replay crashed loading base BASE_SHA. feat-cmux-next's gallery
    health runs: 30 at BASE_SHA (the break: its render wrote no health.json), 20 at OLDER_SHA (2 h older, red on the
    same state), 25 at OLDEST_SHA (60 h older, past the window)."""

    def __init__(self):
        super().__init__()
        self.jobs = {1: gallery_job(1, 10, HEAD), 3: gallery_job(3, 30, BASE_SHA), 2: gallery_job(2, 20, OLDER_SHA),
                     4: gallery_job(4, 25, OLDEST_SHA)}
        self.logs = {1: "\n".join(f"{GALLERY}\t{step}\t2026-11-07T15:48:15.0000000Z {line}" for step, line in (
            (RENDER_STEP, f"- {GALLERY_STATE}: did not render: never reported ready after 30000 ms"),
            (REPLAY_STEP, "##[group]Run set -euo pipefail"),
            (REPLAY_STEP, f"replaying on base {BASE_SHA}: {GALLERY_STATE}"),
            (REPLAY_STEP, PILL_ASKS),
            (REPLAY_STEP, "##[error]Process completed with exit code 1."),
            ("Record what was rendered", "##[group]Run set -euo pipefail")))}
        self.base_runs = [{"id": run, "event": "push", "head_branch": "feat-cmux-next", "status": "completed",
                           "conclusion": "failure", "head_sha": sha, "created_at": f"2026-11-07T{hour}:00:00Z"}
                          for run, sha, hour in ((30, BASE_SHA, 15), (20, OLDER_SHA, 13), (25, OLDEST_SHA, 1))]
        # by artifact id (run * 10): the head's, and each base run's
        self.health = {100: health(GALLERY_STATE), 300: None, 250: health(GALLERY_STATE),
                       200: health(GALLERY_STATE, reason="did not render: never reported ready after 31000 ms")}
        now = excuse.datetime.fromisoformat("2026-11-07T15:00:00+00:00")
        self.commits = [{"sha": sha, "parents": [{"sha": parent}],
                         "commit": {"committer": {"date": (now - excuse.timedelta(hours=hours)).isoformat()}}}
                        for sha, parent, hours in ((BASE_SHA, OLDER_SHA, 0), (OLDER_SHA, OLDEST_SHA, 2),
                                                   (OLDEST_SHA, "e" * 40, 60))]
        self.artifact_reads: list[int] = []
        for job_id in (2, 3, 4):  # a base run red on a push: no base to compare with
            self.logs[job_id] = log(GALLERY, REPLAY_STEP, "##[error]gallery health is red on this push, "
                                                                         "which has no base to compare with")

    def json(self, route, *, paginate=False):
        if route == f"repos/{REPO}/actions/runs/10":
            self.routes.append(route)
            return {"id": 10, "workflow_id": 7, "name": "gallery health", "path": ".github/workflows/gallery-health.yml"}
        if route.startswith(f"repos/{REPO}/commits?sha={BASE_SHA}&"):
            self.routes.append(route)
            return copy.deepcopy(self.commits) if route.endswith("&page=1") else []
        if "/artifacts?" in route:
            self.routes.append(route)
            run = int(route.split("/actions/runs/", 1)[1].split("/", 1)[0])
            # artifact id: the run id times ten
            return {"artifacts": [{"id": run * 10, "name": "gallery-health-1", "expired": False}]}
        return super().json(route, paginate=paginate)

    def artifact_file(self, repo, artifact, member):
        assert member == "health.json", member
        self.artifact_reads.append(artifact)
        return self.health[artifact]

    def run(self, args):
        raise excuse.Refused("no GraphQL here")


class GalleryBaseLoadCrash(unittest.TestCase):
    """A gallery health shard whose base replay crashed loading the base is judged per state against the newest older
    base run with a whole verdict (gallery_crash_verdict)."""

    def judge(self, github):
        return excuse.judge(REPO, "feat-cmux-next", HEAD, [10], github)

    def test_a_crashed_base_replay_falls_back_to_an_older_base_verdict(self):
        github = GalleryGitHub()
        lines = "\n".join(self.judge(github))
        self.assertIn(f"excused '{GALLERY}': its base replay crashed loading feat-cmux-next {BASE_SHA[:12]}", lines)
        self.assertIn("Export named 'pillAsks' not found", lines)
        # run 30 (the break itself) gave no whole result; run 20 is the fallback, named
        self.assertIn(f"against feat-cmux-next {OLDER_SHA[:12]} (run 20)", lines)
        self.assertIn(GALLERY_STATE, lines)
        self.assertEqual(github.artifact_reads, [100, 300, 200])

    def test_a_red_state_the_fallback_base_renders_is_its_own(self):
        github = GalleryGitHub()
        github.health[200] = health("agent-pane.other#state")
        with self.assertRaisesRegex(excuse.Refused, rf"so judged against feat-cmux-next {OLDER_SHA[:12]} \(run 20\)"
                                                    rf": 1 red state\(s\) render or are red another way"):
            self.judge(github)

    def test_a_crash_on_the_pull_request_side_is_never_excused(self):
        github = GalleryGitHub()
        # The head itself does not load: its render wrote no per-state result, so the replay never starts.
        github.logs[1] = "\n".join(f"{GALLERY}\t{step}\t2026-11-07T15:48:15.0000000Z {line}" for step, line in (
            (RENDER_STEP, PILL_ASKS),
            (REPLAY_STEP, "##[group]Run set -euo pipefail"),
            (REPLAY_STEP, "##[error]the render step failed but health.json names no red state")))
        with self.assertRaises(excuse.Refused) as refused:
            self.judge(github)
        self.assertNotIn("base replay crashed", str(refused.exception))
        self.assertEqual(github.artifact_reads, [])

    def test_a_replay_red_without_a_load_error_is_not_a_crash(self):
        github = GalleryGitHub()
        github.logs[1] = github.logs[1].replace(PILL_ASKS, "::error title=gallery health::1 red state(s) render or "
                                                           "are red another way on base bbbbbbbbbbbb: x")
        with self.assertRaises(excuse.Refused) as refused:
            self.judge(github)
        self.assertNotIn("base replay crashed", str(refused.exception))
        self.assertEqual(github.artifact_reads, [])

    def test_no_whole_base_verdict_in_the_window_refuses(self):
        github = GalleryGitHub()
        github.health[200] = json.dumps({"error": "gallery health could not render: SyntaxError"})
        with self.assertRaisesRegex(excuse.Refused, "base replay crashed loading .*; no feat-cmux-next commit in the "
                                                    "last 50 first-parent commits or 48 h"):
            self.judge(github)
        self.assertNotIn(250, github.artifact_reads)  # run 25 is 60 h older: past the window, never read

    def test_a_base_run_red_before_its_verdict_step_is_no_fallback(self):
        github = GalleryGitHub()
        github.jobs[2] = gallery_job(2, 20, OLDER_SHA, failed="Choose the entries to render", render="skipped")
        with self.assertRaisesRegex(excuse.Refused, "no feat-cmux-next commit in the last 50"):
            self.judge(github)


    def test_an_artifact_is_read_from_its_zip_and_held_to_its_cap(self):
        import zipfile
        with tempfile.TemporaryDirectory() as where:
            archive = Path(where) / "a.zip"
            with zipfile.ZipFile(archive, "w") as out:
                out.writestr("health.json", health(GALLERY_STATE))
                out.writestr("shots/one.png", b"\0" * 4096)
            gh = Path(where) / "gh"
            gh.write_text(f"#!/bin/sh\ncat '{archive}'\n")
            gh.chmod(0o755)
            with unittest.mock.patch.dict(os.environ, {"PATH": f"{where}:{os.environ['PATH']}"}):
                reader = excuse.GitHub()
                reader.artifact_file = reader.artifact_file_whole  # the download the range read falls back to
                self.assertEqual(json.loads(reader.artifact_file(REPO, 7, "health.json"))["fresh"][0]["state"],
                                 GALLERY_STATE)
                self.assertIsNone(reader.artifact_file(REPO, 7, "missing.json"))
                with unittest.mock.patch.object(excuse, "ARTIFACT_MAX_BYTES", 100):
                    with self.assertRaisesRegex(excuse.Refused, "artifact 7 is over"):
                        reader.artifact_file(REPO, 7, "health.json")

    def test_an_artifact_download_that_stalls_ends_at_its_deadline(self):
        # gh sends nothing, and a gh wrapper (the agent hosts' shim) whose child holds stdout too: the read ends only
        # when the whole group is killed. A fake gh plays that; a fake timer fires its deadline at once.
        killed = []

        class StalledGh:
            pid = 4242
            returncode = None

            def __init__(self, argv, **options):
                self.options = options
                started.append(self)
                self.stdout = self

            def read(self, size):
                if (self.pid, excuse.signal.SIGKILL) not in killed:
                    raise AssertionError("the read went on before the deadline killed gh's group")
                return b""  # every holder of stdout is gone

            def wait(self):
                self.returncode = -excuse.signal.SIGKILL
                return self.returncode

        class FiresAtOnce:
            def __init__(self, seconds, expire):
                timers.append(seconds)
                self.expire = expire

            def start(self):
                self.expire()

            def cancel(self):
                pass

        started, timers = [], []
        with unittest.mock.patch.object(excuse.subprocess, "Popen", StalledGh), \
                unittest.mock.patch.object(excuse.threading, "Timer", FiresAtOnce), \
                unittest.mock.patch.object(excuse.os, "killpg", lambda pid, sig: killed.append((pid, sig))), \
                unittest.mock.patch.object(excuse, "ARTIFACT_SECONDS", 0.2):
            with self.assertRaisesRegex(excuse.Refused, "took over 0.2 seconds"):
                excuse.GitHub().artifact_file_whole(REPO, 7, "health.json")
        self.assertEqual(timers, [0.2])
        self.assertTrue(started[0].options.get("start_new_session"))  # gh in a group of its own
        self.assertEqual(killed[0], (4242, excuse.signal.SIGKILL))



class ArtifactReadByRange(unittest.TestCase):
    """A gallery-health shard zip is read by range: its end record, central directory and health.json, never the
    whole zip. The shards grew from 18 MB (2026-11-07) to 170-190 MB (feat-cmux-next run 42938607208), past the
    64 MiB whole-download cap, and every gallery-health red was refused with "artifact N is over 67108864 bytes"
    (cmux#40955). A local server plays GitHub's API (a redirect) and the blob host (ranges); a fake gh on PATH
    serves the same zip whole, which is what the classifier read before."""

    BIG = 70 * 1024 * 1024

    def serve(self, archive: Path, *, ranges: bool = True):
        import http.server
        import threading as _threading
        seen = self.seen = {"api_auth": [], "blob_auth": [], "blob_bytes": 0, "blob_requests": 0}
        data = archive.read_bytes()

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self):
                if self.path == f"/repos/{REPO}/actions/artifacts/7/zip":
                    seen["api_auth"].append(self.headers.get("Authorization"))
                    self.send_response(302)
                    self.send_header("Location", f"http://127.0.0.1:{self.server.server_port}/blob/7?sig=x")
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                if self.path.startswith("/blob/7"):
                    seen["blob_auth"].append(self.headers.get("Authorization"))
                    seen["blob_requests"] += 1
                    spec = self.headers.get("Range", "")
                    # Like the real blob host: an explicit range is served, a suffix range (bytes=-N) whole.
                    found = re.fullmatch(r"bytes=(\d+)-(\d*)", spec)
                    if not ranges or not found:
                        body, status = data, 200
                    else:
                        first, last = found.groups()
                        start, end = int(first), min(len(data) - 1, int(last) if last else len(data) - 1)
                        body, status = data[start:end + 1], 206
                    self.send_response(status)
                    if status == 206:
                        self.send_header("Content-Range", f"bytes {start}-{end}/{len(data)}")
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    try:
                        self.wfile.write(body)
                    except (BrokenPipeError, ConnectionResetError):
                        return
                    seen["blob_bytes"] += len(body)
                    return
                self.send_error(404)

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        _threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        return f"http://127.0.0.1:{server.server_port}"

    def shard(self, where: Path, big: int) -> Path:
        archive = where / "gallery-health-1.zip"
        with zipfile.ZipFile(archive, "w") as out:
            out.writestr("health.json", health(GALLERY_STATE))
            with out.open(zipfile.ZipInfo("shots/everything.bin"), "w") as shots:
                chunk = os.urandom(1 << 20)
                for _ in range(big >> 20):
                    shots.write(chunk)
        return archive

    def environment(self, where: Path, archive: Path, api: str) -> dict:
        gh = where / "gh"
        gh.write_text(f"#!/bin/sh\ncat '{archive}'\n")
        gh.chmod(0o755)
        return {"PATH": f"{where}:{os.environ['PATH']}", "GH_TOKEN": "test-token", "GITHUB_API_URL": api}

    def test_a_shard_past_the_whole_download_cap_reads_its_health_by_range(self):
        with tempfile.TemporaryDirectory() as where:
            where = Path(where)
            archive = self.shard(where, self.BIG)
            self.assertGreater(archive.stat().st_size, 64 * 1024 * 1024)
            api = self.serve(archive)
            with unittest.mock.patch.dict(os.environ, self.environment(where, archive, api)):
                text = excuse.GitHub().artifact_file(REPO, 7, "health.json")
            self.assertEqual(json.loads(text)["fresh"][0]["state"], GALLERY_STATE)
            # Constant cost: the end record, the central directory and one small member, not the 70 MiB zip.
            self.assertLess(self.seen["blob_bytes"], 1024 * 1024)
            self.assertEqual(self.seen["api_auth"], ["Bearer test-token"])
            self.assertEqual(set(self.seen["blob_auth"]), {None})  # the token never reaches the blob host

    def test_a_missing_member_is_none_and_reads_no_more(self):
        with tempfile.TemporaryDirectory() as where:
            where = Path(where)
            archive = self.shard(where, self.BIG)
            api = self.serve(archive)
            with unittest.mock.patch.dict(os.environ, self.environment(where, archive, api)):
                self.assertIsNone(excuse.GitHub().artifact_file(REPO, 7, "missing.json"))
            self.assertLess(self.seen["blob_bytes"], 1024 * 1024)

    def test_a_blob_that_answers_ranges_whole_falls_back_to_the_capped_download(self):
        with tempfile.TemporaryDirectory() as where:
            where = Path(where)
            archive = self.shard(where, 2 * 1024 * 1024)
            api = self.serve(archive, ranges=False)
            with unittest.mock.patch.dict(os.environ, self.environment(where, archive, api)):
                reader = excuse.GitHub()
                self.assertEqual(json.loads(reader.artifact_file(REPO, 7, "health.json"))["fresh"][0]["state"],
                                 GALLERY_STATE)
                with unittest.mock.patch.object(excuse, "ARTIFACT_MAX_BYTES", 100):
                    with self.assertRaisesRegex(excuse.Refused, "artifact 7 is over"):
                        reader.artifact_file(REPO, 7, "health.json")

    def test_a_shard_past_both_caps_with_no_range_is_still_refused(self):
        with tempfile.TemporaryDirectory() as where:
            where = Path(where)
            archive = self.shard(where, self.BIG)
            api = self.serve(archive, ranges=False)
            with unittest.mock.patch.dict(os.environ, self.environment(where, archive, api)):
                with self.assertRaisesRegex(excuse.Refused, "artifact 7 is over"):
                    excuse.GitHub().artifact_file(REPO, 7, "health.json")


class FailingStepLogOnly(unittest.TestCase):
    """The excuse quotes, and compares with the base, only the failing step's own lines. On cmux#40369 the static
    checks job failed in "Every page's strings generate with no missing translation" (feat-cmux-next runs 42820823641
    and 42820590433), yet the excuse quoted "pinned license manifest digest changed": expected stderr of a passing
    negative-case test (test_ghostty_licenses.py's `fails("changed manifest", ...)`) in another step, which sent an
    agent after the wrong cause.

    The logs here are framed like a real job log: "Set up job" first, then a `##[group]Run ...` line opening each
    step, then "Complete job" with no line of its own (step_ownership_fixtures)."""

    NAME = ("cmux-next static checks (vt-link-graph, nightly static capabilities, defaults snapshot, "
            "page strings)")
    LICENSES = "The nightly's Ghostty license checks pass on fixtures"
    STRINGS = "Every page's strings generate with no missing translation"
    DIGEST = ("collect-ghostty-licenses.py: error: pinned license manifest is unusable: pinned license manifest "
              f"digest changed: {'1' * 64} != {'2' * 64}")
    COLLECT = "could not collect Ghostty licenses: pinned license manifest digest changed"

    def job(self, job_id, run_id, sha, steps=None):
        return {"id": job_id, "run_id": run_id, "head_sha": sha, "name": self.NAME, "status": "completed",
                "conclusion": "failure", "steps": framed_steps(steps or [
                    (self.LICENSES, "success", 10, 12), (self.STRINGS, "failure", 20, 22)])}

    def sections(self, missing, digest=True):
        """(step, second, text) lines: the license step's negative case prints the digest stderr and passes; the
        strings step fails with its own count."""
        licenses = [(self.LICENSES, 10, "##[group]Run python3 cmux-tui/build-support/notices/ghostty/"
                                        "test_ghostty_licenses.py"),
                    (self.LICENSES, 10, "python3 cmux-tui/build-support/notices/ghostty/test_ghostty_licenses.py"),
                    (self.LICENSES, 10, "##[endgroup]")]
        if digest:
            licenses += [(self.LICENSES, 11, self.DIGEST), (self.LICENSES, 11, self.COLLECT)]
        licenses.append((self.LICENSES, 11, "ok: changed manifest is refused"))
        strings = [(self.STRINGS, 20, "##[group]Run node webviews/scripts/pages/gen-strings.mjs"),
                   (self.STRINGS, 20, "node webviews/scripts/pages/gen-strings.mjs"),
                   (self.STRINGS, 20, "##[endgroup]"),
                   *((self.STRINGS, 21, line) for line in missing),
                   (self.STRINGS, 21, "##[error]Process completed with exit code 1.")]
        return licenses + strings

    def raw(self, lines):
        # The job-log endpoint judge reads (GitHub.log): a timestamp per line, no step column.
        return framed_log(lines, self.NAME)

    def columns(self, lines):
        # `gh run view --log`: job and step columns before the timestamp.
        return framed_log(lines, self.NAME, columns=True)

    def github(self, head, base):
        github = FakeGitHub()
        github.jobs = {1: self.job(1, 10, HEAD), 2: self.job(2, 20, BASE_SHA)}
        github.logs = {1: head, 2: base}
        return github

    def test_the_excuse_quotes_the_failing_steps_error_not_a_passing_steps_negative_case_stderr(self):
        missing = ["settings: 42 strings missing", "  settings.title: missing ja"]
        for fmt in (self.raw, self.columns):
            with self.subTest(log=fmt.__name__):
                github = self.github(fmt(self.sections(missing)), fmt(self.sections(missing)))
                text = "\n".join(excuse.judge(REPO, "feat-cmux-next", HEAD, [10], github))
                self.assertIn("excused", text)
                self.assertIn("settings: # strings missing", text)
                self.assertNotIn("digest changed", text)
                self.assertNotIn("could not collect Ghostty licenses", text)

    def test_a_refusal_names_the_failing_steps_error_not_a_passing_steps_negative_case_stderr(self):
        # The base's license step printed no digest line; its strings step failed on another page. Only the strings
        # error is the head's own, and only it may be named.
        for fmt in (self.raw, self.columns):
            with self.subTest(log=fmt.__name__):
                github = self.github(fmt(self.sections(["settings: 42 strings missing"])),
                                     fmt(self.sections(["home: 3 strings missing"], digest=False)))
                with self.assertRaises(excuse.Refused) as raised:
                    excuse.judge(REPO, "feat-cmux-next", HEAD, [10], github)
                self.assertIn("settings: # strings missing", str(raised.exception))
                self.assertNotIn("digest changed", str(raised.exception))

    def test_the_failing_steps_errors_are_matched_with_the_bases_same_step(self):
        # The head's strings error printed by the base only in a passing step is not the base failing that way.
        line = "settings: 42 strings missing"
        base = self.sections(["home: 3 strings missing"])
        base.insert(3, (self.LICENSES, 11, line))
        for fmt in (self.raw, self.columns):
            with self.subTest(log=fmt.__name__):
                github = self.github(fmt(self.sections([line])), fmt(base))
                with self.assertRaisesRegex(excuse.Refused, "errors not on feat-cmux-next run 20: settings"):
                    excuse.judge(REPO, "feat-cmux-next", HEAD, [10], github)

    def test_a_continue_on_error_step_that_failed_still_counts(self):
        # The jobs API reads a continue-on-error step that failed as a success, and the job's rollup step fails for
        # it. Its section's own `##[error]Process completed` line keeps its errors compared: a different red there
        # is never excused by the rollup lines alone.
        check, rollup = "Main-thread concurrency", "Fail on any red check"
        steps = [(check, "success", 10, 12), (rollup, "failure", 20, 22)]

        def lines(error):
            return [(check, 10, "##[group]Run scripts/cmux-next/check-concurrency.sh"),
                    (check, 10, "##[endgroup]"),
                    (check, 11, f"concurrency: error: {error}"),
                    (check, 11, "##[error]Process completed with exit code 1."),
                    (rollup, 20, "##[group]Run scripts/ci/rollup.sh"),
                    (rollup, 20, "##[endgroup]"),
                    (rollup, 21, f"##[error]red check: {check}"),
                    (rollup, 21, "##[error]Process completed with exit code 1.")]

        for fmt in (self.raw, self.columns):
            with self.subTest(log=fmt.__name__):
                github = self.github(fmt(lines("Sources/New.swift:9 blocks the main thread")),
                                     fmt(lines("Sources/Old.swift:3 blocks the main thread")))
                github.jobs = {1: self.job(1, 10, HEAD, steps), 2: self.job(2, 20, BASE_SHA, steps)}
                with self.assertRaisesRegex(excuse.Refused, "New.swift"):
                    excuse.judge(REPO, "feat-cmux-next", HEAD, [10], github)

    # failed_steps_log is vendored, byte for byte, into cmuxterm-hq tools/fleet-reconcilers/failed_steps_log.py and
    # leo-workspace tools/failed_steps_log.py (base-red-watch reads job logs there and cannot import this script); each
    # copy's test pins the same fingerprint. A change here updates this value and both copies.
    # Each copy keeps STEP_NAMES_UNKNOWN too: step_owners requires a caller to pass it when it reads no workflow.
    VENDORED_FINGERPRINT = "b25a8e4f61d1d373e53ae5fe0797484f4adf9c6cf104dda2d1472f1e8af5a61a"

    def test_the_code_vendored_into_base_red_watch_is_pinned(self):
        import hashlib
        import inspect
        parts = [getattr(excuse, name).pattern for name in ("ANSI", "STAMP", "STEP_START", "SECTION_RED")]
        parts += [str(excuse.STEP_OWNERS_MAX_LINES)]
        parts += [inspect.getsource(getattr(excuse, name))
                  for name in ("lines_of", "_stamp_time", "step_owners", "failed_steps_log")]
        parts += [repr(excuse.STEP_NAMES_UNKNOWN)]  # the sentinel step_owners requires when no workflow is read
        self.assertEqual(hashlib.sha256("\0".join(parts).encode()).hexdigest(), self.VENDORED_FINGERPRINT,
                         "step_owners or failed_steps_log changed: copy them to cmuxterm-hq "
                         "tools/fleet-reconcilers/failed_steps_log.py "
                         "and leo-workspace tools/failed_steps_log.py, and update the fingerprint in all three")

    def adjacent_steps(self):
        # The strings step starts in the second the license step ends: GitHub rounds both to 12:00:12, so a line
        # stamped 12:00:12.5 is in both steps' [started_at, completed_at + 1s) windows.
        return [(self.LICENSES, "success", 10, 12), (self.STRINGS, "failure", 12, 14)]

    def adjacent_sections(self, missing):
        """The license step passes with the digest stderr (second 11); the strings step's annotation is printed at
        12:00:12.5, the second the license step ended in."""
        return [(self.LICENSES, 10, "##[group]Run python3 cmux-tui/build-support/notices/ghostty/"
                                    "test_ghostty_licenses.py"),
                (self.LICENSES, 10, "##[endgroup]"),
                (self.LICENSES, 11, self.DIGEST), (self.LICENSES, 11, self.COLLECT),
                (self.LICENSES, 11, "ok: changed manifest is refused"),
                (self.STRINGS, 12, "##[group]Run node webviews/scripts/pages/gen-strings.mjs"),
                (self.STRINGS, 12, "##[endgroup]"),
                *((self.STRINGS, 12, f"##[error]{line}") for line in missing),
                (self.STRINGS, 13, "##[error]Process completed with exit code 1.")]

    def test_a_line_in_the_second_one_step_ends_and_the_next_starts_never_un_passes_the_passing_step(self):
        # cmux#40497's Codex P2: the failing step's annotation in the shared second read as the license step's too,
        # took it out of "passed" and brought back its whole log, so the excuse quoted "digest changed" again.
        missing = ["settings: 42 strings missing"]
        log = self.raw(self.adjacent_sections(missing))
        scoped = excuse.failed_steps_log(self.job(1, 10, HEAD, self.adjacent_steps()), log, **UNKNOWN)
        # The strings step's header is stamped in the second the license step ended in, so the log does not map one
        # to one onto the steps: the comment keeps the whole log, digest line included, and nothing is excused.
        self.assertIn("digest changed", scoped)
        self.assertIn("##[error]settings: 42 strings missing", scoped)
        github = self.github(log, self.raw(self.adjacent_sections(missing)))
        github.jobs = {1: self.job(1, 10, HEAD, self.adjacent_steps()),
                       2: self.job(2, 20, BASE_SHA, self.adjacent_steps())}
        # Head and base serve the same unplaced log: compared whole and excused on identity (UnplacedSignature).
        self.assertIn("compared whole", "\n".join(excuse.judge(REPO, "feat-cmux-next", HEAD, [10], github)))

    def test_a_continue_on_error_steps_exit_line_in_a_shared_second_still_counts(self):
        # The other side of the ambiguous second: a continue-on-error step that failed (a success to the jobs API)
        # prints the runner's exit line in the second the rollup step starts. That line is the step's own end, so
        # the step's errors stay compared, and a different red there is never excused by the rollup lines alone.
        check, rollup = "Main-thread concurrency", "Fail on any red check"
        steps = [(check, "success", 10, 12), (rollup, "failure", 12, 14)]

        def lines(error):
            return [(check, 10, "##[group]Run scripts/cmux-next/check-concurrency.sh"),
                    (check, 10, "##[endgroup]"),
                    (check, 11, f"concurrency: error: {error}"),
                    (check, 12, "##[error]Process completed with exit code 1."),
                    (rollup, 13, "##[group]Run scripts/ci/rollup.sh"),
                    (rollup, 13, "##[endgroup]"),
                    (rollup, 13, f"##[error]red check: {check}"),
                    (rollup, 13, "##[error]Process completed with exit code 1.")]

        github = self.github(self.raw(lines("Sources/New.swift:9 blocks the main thread")),
                             self.raw(lines("Sources/Old.swift:3 blocks the main thread")))
        github.jobs = {1: self.job(1, 10, HEAD, steps), 2: self.job(2, 20, BASE_SHA, steps)}
        with self.assertRaisesRegex(excuse.Refused, "New.swift"):
            excuse.judge(REPO, "feat-cmux-next", HEAD, [10], github)


# 2026-11-10, six reviews of cmux#40542, hq#8936 and LW#4177 found logs whose STEP_START lines balance out: whole-second
# step times cannot tell which step printed a line, step names repeat, and a composite's extra `Run` line or a step's
# own `::group::Run` stands in for a silent step's missing one. step_owners places a log only when it maps one to one
# onto the steps, each header validated as its step's own; else every line is AMBIGUOUS. One fixture set, copied as is
# into cmuxterm-hq tools/fleet-reconcilers/test_failed_steps_log.py and leo-workspace tools/test_failed_steps_log.py:
# (steps, lines, failed, passed, ambiguous[, errored]). Steps are (name, conclusion, started second, completed second)
# between "Set up job" and "Complete job"; lines are (step, second, text). Each listed text's line has that status;
# failed_steps_log keeps all but the PASSED ones. A case with any AMBIGUOUS text is not placed: the comment keeps
# those lines and every excuse refuses.
def clock(second):
    """12:00:00 plus SECOND as hh:mm:ss, with seven decimals when SECOND is a float."""
    minutes, rest = divmod(second, 60)
    hours, minutes = divmod(int(minutes), 60)
    return f"{12 + hours:02d}:{minutes:02d}:" + (f"{rest:010.7f}" if isinstance(second, float) else f"{rest:02d}")


def framed_steps(steps):
    """STEPS (name, conclusion, started second, completed second) as the jobs API's steps[], numbered, between "Set up
    job" and "Complete job" (a passing one, unless STEPS ends with its own "Complete job")."""
    def at(second):
        return f"2026-11-10T{clock(second)}Z"
    last = steps[-1][3]
    if steps[-1][0] != "Complete job":
        steps = [*steps, ("Complete job", "success", last, last)]
    found = [{"number": 1, "name": "Set up job", "status": "completed", "conclusion": "success",
              "started_at": at(0), "completed_at": at(2)}]
    found += [{"number": n, "name": name, "status": "completed", "conclusion": conclusion,
               "started_at": at(start), "completed_at": at(end)}
              for n, (name, conclusion, start, end) in enumerate(steps, 2)]
    return found


def framed_log(lines, job_name="job", columns=False):
    """LINES (step, second, text) framed by the runner's "Set up job" and "Complete job" lines; an int second is
    printed at half past it. COLUMNS: `gh run view --log`'s job and step columns before the stamp."""
    last = lines[-1][1] if lines else 2
    framed = [("Set up job", 0, "Current runner version: '2.338.2'"),
              ("Set up job", 1, f"Complete job name: {job_name}"),
              *lines, ("Complete job", last, "Cleaning up orphan processes")]
    out = []
    for step, second, text in framed:
        stamp = f"2026-11-10T{clock(second + 0.5 if isinstance(second, int) else second)}Z {text}"
        out.append(f"{job_name}\t{step}\t{stamp}" if columns else stamp)
    return "\n".join(out)


NEW_RED = "concurrency: error: Sources/New.swift:9 blocks the main thread"
NEGATIVE_CASE = "licenses: error: pinned license manifest digest changed"
EXIT = "##[error]Process completed with exit code 1."
OLD_RED = NEW_RED.replace("New.swift:9", "Old.swift:3")
POST_ERROR = "post: error: Sources/New.swift:9 left a lock behind"
# What judge() refuses a head red in New.swift with: its error is not on the base, or its log does not map one to one.
NOT_EXCUSED = "New.swift|does not map one to one onto its steps"


def coe_composite_then_silent_step(end, diag_at, inner_at, rollup, silent="Quick"):
    """A continue-on-error composite (a success to the jobs API) from 10 s to END, a silent passing step SILENT at END,
    a failing rollup over ROLLUP: the composite's diagnostic at DIAG_AT, its inner `Run` line and exit line at INNER_AT
    stand in for the silent step's header (cmux#40542's and hq#8962's Codex P1). A SILENT named like that inner line
    (an unnamed step's name is its header, and the workflow's author picks it) matches it by name too (#40542's
    third Codex BLOCK)."""
    return (
        [("Concurrency", "success", 10, end), (silent, "success", end, end), ("Rollup", "failure", *rollup)],
        [("Concurrency", 10.2, "##[group]Run ./.github/actions/concurrency"), ("Concurrency", diag_at, NEW_RED),
         ("Concurrency", inner_at, "##[group]Run scripts/check-concurrency.sh"), ("Concurrency", inner_at, EXIT),
         ("Rollup", rollup[0] + 0.5, "##[group]Run scripts/rollup.sh"),
         ("Rollup", rollup[0] + 0.6, "##[error]red check: Concurrency")],
        [], [], [NEW_RED, EXIT, "##[error]red check: Concurrency"])


STEP_OWNERSHIP = {
    # A continue-on-error step (a success to the jobs API) ends at 12:00:12, and the next, passing step starts and
    # ends in that second: its header could be either step's, so nothing is placed (cmux#40542's Codex P1).
    "same_second_ending": (
        [("Concurrency", "success", 10, 12), ("Quick", "success", 12, 12), ("Rollup", "failure", 13, 14)],
        [("Concurrency", 10, "##[group]Run scripts/check-concurrency.sh"), ("Concurrency", 11, NEW_RED),
         ("Concurrency", 12.2, EXIT),
         ("Quick", 12.4, "##[group]Run true"), ("Quick", 12.6, "quick: ok"),
         ("Rollup", 13, "##[group]Run scripts/rollup.sh"), ("Rollup", 13, "##[error]red check: Concurrency")],
        [], [], [NEW_RED, EXIT, "quick: ok", "##[error]red check: Concurrency"]),
    # A continue-on-error step that starts and ends inside one second that passing steps share on both sides.
    "short_continue_on_error": (
        [("Build", "success", 10, 12), ("Lint", "success", 12, 12), ("Docs", "success", 12, 13),
         ("Rollup", "failure", 14, 15)],
        [("Build", 10, "##[group]Run make"), ("Build", 11, NEGATIVE_CASE),
         ("Lint", 12.3, "##[group]Run scripts/lint.sh"), ("Lint", 12.4, NEW_RED), ("Lint", 12.5, EXIT),
         ("Docs", 12.7, "##[group]Run scripts/docs.sh"), ("Docs", 12.8, "docs: ok"),
         ("Rollup", 14, "##[group]Run scripts/rollup.sh"), ("Rollup", 14, "##[error]red check: Lint")],
        [], [], [NEGATIVE_CASE, NEW_RED, EXIT, "docs: ok", "##[error]red check: Lint"]),
    # The failing step's header is in the second the passing step ended in (leo-workspace#4164's Codex F1).
    "exit_line_across_the_boundary": (
        [("Licenses", "success", 10, 12), ("Strings", "failure", 12, 13)],
        [("Licenses", 10, "##[group]Run python3 test_licenses.py"), ("Licenses", 11, NEGATIVE_CASE),
         ("Strings", 12.1, "##[group]Run node gen-strings.mjs"), ("Strings", 12.5, "settings: 42 strings missing"),
         ("Strings", 12.999, EXIT)],
        [], [], [NEGATIVE_CASE, "settings: 42 strings missing", EXIT]),
    # Two steps named alike, apart in time: each header is its own step's, so the passing `Check` is dropped
    # (hq#8904's Codex F2).
    "duplicate_names": (
        [("Check", "success", 10, 11), ("Check", "failure", 20, 21)],
        [("Check", 10, "##[group]Run scripts/check.sh --negative"), ("Check", 10.6, NEGATIVE_CASE),
         ("Check", 20, "##[group]Run scripts/check.sh"), ("Check", 20.6, NEW_RED), ("Check", 21, EXIT)],
        [NEW_RED, EXIT], [NEGATIVE_CASE], []),
    # Unnamed steps whose headers match their names, but the second header falls in both steps' windows: a name the
    # workflow's author picks never proves a header is that step's (#40542's third Codex BLOCK), so nothing is placed.
    "unnamed_steps_in_one_second": (
        [("Run python3 test_licenses.py", "success", 10, 12), ("Run node gen-strings.mjs", "failure", 12, 12)],
        [("Licenses", 10, "##[group]Run python3 test_licenses.py"), ("Licenses", 11, NEGATIVE_CASE),
         ("Strings", 12.1, "##[group]Run node gen-strings.mjs"), ("Strings", 12.5, "settings: 42 strings missing"),
         ("Strings", 12.9, EXIT)],
        [], [], [NEGATIVE_CASE, "settings: 42 strings missing", EXIT]),
    # The same two unnamed steps a second apart: each header is in its own step's window alone.
    "unnamed_steps_a_second_apart": (
        [("Run python3 test_licenses.py", "success", 10, 11), ("Run node gen-strings.mjs", "failure", 12, 12)],
        [("Licenses", 10, "##[group]Run python3 test_licenses.py"), ("Licenses", 11, NEGATIVE_CASE),
         ("Strings", 12.1, "##[group]Run node gen-strings.mjs"), ("Strings", 12.5, "settings: 42 strings missing"),
         ("Strings", 12.9, EXIT)],
        ["settings: 42 strings missing", EXIT], [NEGATIVE_CASE], []),
    # A continue-on-error step that failed is a success to the jobs API, but its section has `##[error]` lines: it
    # counts as failed.
    "continue_on_error_section_is_failed": (
        [("Licenses", "success", 3, 5), ("Lint", "success", 10, 12), ("Rollup", "failure", 20, 21)],
        [("Licenses", 3, "##[group]Run python3 test_licenses.py"), ("Licenses", 4, NEGATIVE_CASE),
         ("Lint", 10, "##[group]Run scripts/lint.sh"), ("Lint", 11, NEW_RED), ("Lint", 11.5, EXIT),
         ("Rollup", 20, "##[group]Run scripts/rollup.sh"), ("Rollup", 20.6, "##[error]red check: Lint")],
        ["##[error]red check: Lint"], [NEGATIVE_CASE], [], [NEW_RED, EXIT]),
    # #40542's fourth Codex BLOCK, F1: a passing negative-case step prints text that reads like the runner's exit line,
    # and its script's echo group holds an `##[error]` line; neither is a live annotation, so it stays PASSED.
    "passing_step_echoes_failure_text": (
        [("Negative cases", "success", 10, 12), ("Check", "failure", 20, 22)],
        [("Negative cases", 10, "##[group]Run python3 negative.py"),
         ("Negative cases", 10.1, 'echo "##[error]Process completed with exit code 1."'),
         ("Negative cases", 10.2, "##[endgroup]"), ("Negative cases", 11, NEW_RED),
         ("Negative cases", 11.5, "expected: Process completed with exit code 1."),
         ("Check", 20, "##[group]Run scripts/check-concurrency.sh"), ("Check", 21, OLD_RED), ("Check", 21.5, EXIT)],
        [OLD_RED, EXIT], [NEW_RED, "expected: Process completed with exit code 1."], []),
    # A composite action prints a `Run` line per inner step (cmux-next-ios kit's "Set up pinned Rust", job
    # 129951569749: 13 STEP_START lines for 10 steps): more headers than steps, nothing is placed.
    "composite_action": (
        [("Licenses", "success", 10, 12), ("Strings", "failure", 20, 22)],
        [("Licenses", 10, "##[group]Run ./.github/actions/licenses"), ("Licenses", 10.7, "##[group]Run python3 a.py"),
         ("Licenses", 11, NEGATIVE_CASE),
         ("Strings", 20, "##[group]Run node gen-strings.mjs"), ("Strings", 21, "settings: 42 strings missing"),
         ("Strings", 21, EXIT)],
        [], [], [NEGATIVE_CASE, "settings: 42 strings missing", EXIT]),
    # LW#4177 F1: a failing composite's extra inner `Run` line makes up for a later silent passing step. The count
    # matches, but the inner line is in the composite's times as well as the silent step's.
    "compensating_composite_marker": (
        [("Composite", "failure", 10, 12), ("Silent", "success", 12, 12), ("Rollup", "failure", 13, 14)],
        [("Composite", 10, "##[group]Run ./.github/actions/check"), ("Composite", 11, "check: started"),
         ("Composite", 12.1, "##[group]Run scripts/inner.sh"), ("Composite", 12.2, NEW_RED),
         ("Composite", 12.3, EXIT),
         ("Rollup", 13, "##[group]Run scripts/rollup.sh"), ("Rollup", 13, "##[error]red check: Composite")],
        [], [], ["check: started", NEW_RED, EXIT, "##[error]red check: Composite"]),
    # cmux#40542's and hq#8962's Codex P1, both log formats: a continue-on-error composite, a silent step, a rollup.
    "continue_on_error_composite_then_silent_step_at_12": coe_composite_then_silent_step(12, 11, 12.1, (13, 20)),
    "continue_on_error_composite_then_silent_step_at_14": coe_composite_then_silent_step(14, 11.6, 14.3, (15, 20)),
    "continue_on_error_composite_then_silent_step_named_like_its_inner_run_at_12": coe_composite_then_silent_step(
        12, 11, 12.1, (13, 20), silent="Run scripts/check-concurrency.sh"),
    "continue_on_error_composite_then_silent_step_named_like_its_inner_run_at_14": coe_composite_then_silent_step(
        14, 11.6, 14.3, (15, 20), silent="Run scripts/check-concurrency.sh"),
    # hq#8962's Codex F1: a continue-on-error composite at 10-12 s and, later, a silent passing step at 20-21 s named
    # like the composite's inner `Run` line at 11. Matched by name alone, the inner line and the exit line went to
    # the silent step and New.swift left named_files().
    "continue_on_error_composite_then_later_silent_step_named_like_its_inner_run": (
        [("Concurrency", "success", 10, 12), ("Run scripts/inner.sh", "success", 20, 21),
         ("Rollup", "failure", 22, 23)],
        [("Concurrency", 10.2, "##[group]Run ./.github/actions/concurrency"),
         ("Concurrency", 11, "##[group]Run scripts/inner.sh"), ("Concurrency", 11.3, NEW_RED),
         ("Concurrency", 11.5, EXIT), ("Rollup", 22.5, "##[group]Run scripts/rollup.sh"),
         ("Rollup", 22.6, "##[error]red check: Concurrency")],
        [], [], [NEW_RED, EXIT, "##[error]red check: Concurrency"]),
    # LW#4177's Codex P2: a silent step at :12, then a failed composite at :12-:13 whose outer `Run` line (:12.1) is
    # taken for the silent step's and whose inner one (:12.3) for its own.
    "silent_step_then_failed_composite": (
        [("Quick", "success", 12, 12), ("Check", "failure", 12, 13)],
        [("Check", 12.1, "##[group]Run ./.github/actions/check"), ("Check", 12.2, NEW_RED),
         ("Check", 12.3, "##[group]Run scripts/inner.sh"), ("Check", 12.5, EXIT)],
        [], [], [NEW_RED, EXIT]),
    # hq#8936 F1: a passing `Initialize containers` step prints no `Run` line, and the failing step prints its own
    # `::group::Run diagnostic details`, in the same second.
    "container_step_and_a_self_printed_group": (
        [("Initialize containers", "success", 10, 12), ("Tests", "failure", 12, 14)],
        [("Tests", 12.2, "##[group]Run scripts/tests.sh"), ("Tests", 12.6, "##[group]Run diagnostic details"),
         ("Tests", 12.7, NEW_RED), ("Tests", 13, EXIT)],
        [], [], [NEW_RED, EXIT]),
    # #40542's fifth Codex BLOCK: a passing post step's `Post job cleanup.` opens no script echo, so its own group and
    # the `##[error]` in it are live: the section is ERRORED and kept. So is a passing step whose `##[error]` is in a
    # group of its own, after its echo or nested, or in a group opened before its echo's `##[endgroup]`.
    "post_step_with_its_own_group_and_error": (
        [("Check", "failure", 10, 12), ("Post Run actions/checkout", "success", 13, 13)],
        [("Check", 10, "##[group]Run scripts/check.sh"), ("Check", 10, "##[endgroup]"), ("Check", 11, OLD_RED),
         ("Check", 11.5, EXIT), ("Post Run actions/checkout", 13.1, "Post job cleanup."),
         ("Post Run actions/checkout", 13.2, "##[group]Removing credentials"),
         ("Post Run actions/checkout", 13.3, "##[error]" + POST_ERROR),
         ("Post Run actions/checkout", 13.4, "##[endgroup]")],
        [OLD_RED, EXIT], [], [], ["Post job cleanup.", "##[error]" + POST_ERROR]),
    "groups_that_are_not_the_script_echo": (
        [("Lint", "success", 3, 5), ("Nested", "success", 6, 8), ("Early", "success", 9, 11),
         ("Check", "failure", 12, 14)],
        [("Lint", 3, "##[group]Run scripts/lint.sh"), ("Lint", 3.1, "##[endgroup]"),
         ("Lint", 4, "##[group]Lint details"), ("Lint", 4.1, "##[error]lint: Sources/NewA.swift is not formatted"),
         ("Lint", 4.2, "##[endgroup]"),
         ("Nested", 6, "##[group]Run scripts/nested.sh"), ("Nested", 6.1, "##[endgroup]"),
         ("Nested", 7, "##[group]Outer"), ("Nested", 7.1, "##[group]Inner"),
         ("Nested", 7.2, "##[error]nested: Sources/NewB.swift failed"), ("Nested", 7.3, "##[endgroup]"),
         ("Nested", 7.4, "##[endgroup]"),
         ("Early", 9, "##[group]Run scripts/early.sh"), ("Early", 9.1, "##[group]Before the echo ends"),
         ("Early", 9.2, "##[error]early: Sources/NewC.swift failed"), ("Early", 9.3, "##[endgroup]"),
         ("Check", 12, "##[group]Run scripts/check.sh"), ("Check", 13, OLD_RED), ("Check", 13.5, EXIT)],
        [OLD_RED, EXIT], [], [],
        ["##[error]lint: Sources/NewA.swift is not formatted", "##[error]nested: Sources/NewB.swift failed",
         "##[error]early: Sources/NewC.swift failed"]),
    # "Complete job" failed after a passing step, with no `##[error]` line: the last section is both steps', and which
    # one printed a line is not proven, so it is AMBIGUOUS: kept, never dropped as the passing step's (LW#4181's
    # Codex P2), and never base evidence (#40542's fourth Codex BLOCK, F2).
    "failing_complete_job": (
        [("Build", "success", 10, 12), ("Complete job", "failure", 12, 13)],
        [("Build", 10, "##[group]Run make"), ("Build", 11, "build: ok"), ("Build", 12, "build: done")],
        [], [], ["##[group]Run make", "build: ok", "build: done"]),
    # A step printed no `Run` line: fewer headers than steps, so nothing is placed.
    "fewer_step_starts_than_steps_places_nothing": (
        [("Licenses", "success", 10, 12), ("Strings", "failure", 20, 22)],
        [("Licenses", 11, NEGATIVE_CASE),
         ("Strings", 20, "##[group]Run node gen-strings.mjs"), ("Strings", 21, "settings: 42 strings missing"),
         ("Strings", 21, EXIT)],
        [], [], [NEGATIVE_CASE, "settings: 42 strings missing"]),
    # A passing step prints a line that reads like a step's start, and the next step printed none: the count matches,
    # but that header is outside the times of the step it would be given to.
    "a_section_outside_its_steps_times_places_nothing": (
        [("Licenses", "success", 10, 12), ("Strings", "failure", 20, 22)],
        [("Licenses", 10, "##[group]Run python3 test_licenses.py"), ("Licenses", 10.5, "##[group]Run fixture"),
         ("Licenses", 11, NEGATIVE_CASE),
         ("Strings", 21, "settings: 42 strings missing"), ("Strings", 21, EXIT)],
        [], [], [NEGATIVE_CASE, "settings: 42 strings missing"]),
}


class StepOwnership(unittest.TestCase):
    """step_owners places each line by the log's step order, never by a step's name or its whole-second times alone,
    and says FAILED, ERRORED, PASSED or AMBIGUOUS (STEP_OWNERSHIP); failed_steps_log keeps all but the PASSED lines.
    Detector for cmuxterm-hq docs/handbook/red-quoted-from-a-passing-step.md."""

    def check(self, case):
        steps, lines, failed, passed, ambiguous, *rest = STEP_OWNERSHIP[case]
        errored = rest[0] if rest else []
        for columns in (False, True):
            with self.subTest(columns=columns):
                job, log_text = {"steps": framed_steps(steps)}, framed_log(lines, columns=columns)
                said = {}
                for line, _, status in excuse.step_owners(job, log_text, **UNKNOWN):
                    said.setdefault(excuse.lines_of(line)[0], set()).add(status)
                for status, texts in ((excuse.FAILED, failed), (excuse.PASSED, passed),
                                      (excuse.AMBIGUOUS, ambiguous), ("errored", errored)):
                    for text in texts:
                        self.assertEqual(said.get(text), {status}, text)
                out = excuse.failed_steps_log(job, log_text, **UNKNOWN)
                for text in failed + ambiguous + errored:
                    self.assertIn(text, out)
                for text in passed:
                    self.assertNotIn(text, out)

    def test_same_second_ending(self):
        self.check("same_second_ending")

    def test_short_continue_on_error(self):
        self.check("short_continue_on_error")

    def test_exit_line_across_the_boundary(self):
        self.check("exit_line_across_the_boundary")

    def test_duplicate_names(self):
        self.check("duplicate_names")

    def test_unnamed_steps_in_one_second(self):
        self.check("unnamed_steps_in_one_second")

    def test_unnamed_steps_a_second_apart(self):
        self.check("unnamed_steps_a_second_apart")

    def test_continue_on_error_section_is_failed(self):
        self.check("continue_on_error_section_is_failed")

    def test_composite_action(self):
        self.check("composite_action")

    def test_compensating_composite_marker(self):
        self.check("compensating_composite_marker")

    def test_continue_on_error_composite_then_silent_step_at_12(self):
        self.check("continue_on_error_composite_then_silent_step_at_12")

    def test_continue_on_error_composite_then_silent_step_at_14(self):
        self.check("continue_on_error_composite_then_silent_step_at_14")

    def test_continue_on_error_composite_then_silent_step_named_like_its_inner_run_at_12(self):
        self.check("continue_on_error_composite_then_silent_step_named_like_its_inner_run_at_12")

    def test_continue_on_error_composite_then_silent_step_named_like_its_inner_run_at_14(self):
        self.check("continue_on_error_composite_then_silent_step_named_like_its_inner_run_at_14")

    def test_continue_on_error_composite_then_later_silent_step_named_like_its_inner_run(self):
        self.check("continue_on_error_composite_then_later_silent_step_named_like_its_inner_run")

    def test_silent_step_then_failed_composite(self):
        self.check("silent_step_then_failed_composite")

    def test_container_step_and_a_self_printed_group(self):
        self.check("container_step_and_a_self_printed_group")

    def test_passing_step_echoes_failure_text(self):
        self.check("passing_step_echoes_failure_text")

    def test_post_step_with_its_own_group_and_error(self):
        self.check("post_step_with_its_own_group_and_error")

    def test_groups_that_are_not_the_script_echo(self):
        self.check("groups_that_are_not_the_script_echo")

    def test_failing_complete_job(self):
        self.check("failing_complete_job")

    def test_fewer_step_starts_than_steps_places_nothing(self):
        self.check("fewer_step_starts_than_steps_places_nothing")

    def test_a_section_outside_its_steps_times_places_nothing(self):
        self.check("a_section_outside_its_steps_times_places_nothing")

    def test_ten_thousand_step_starts_are_placed_in_linear_time(self):
        # LW#4181's Codex P2: a log with 10,000 `##[group]Run` lines took 21.6 s to place (each start rescanned every
        # block after it), and hq#8962's F2: 10,000 named steps took 0.62 s (each header rescanned every step's times).
        # Placing is one pass: 10,000 unnamed steps and 10,000 named steps, each with its header in its own second,
        # and one step printing 10,000 headers (not one to one, so nothing is placed), each in well under half a
        # second.
        import time

        def shape(named):
            steps = [(f"Case {n}" if named else f"Run case {n}", "failure" if n == 7_000 else "success",
                      10 + n, 10 + n) for n in range(10_000)]
            lines = [(name, start, f"##[group]Run case {n}") for n, (name, _, start, _) in enumerate(steps)]
            lines.insert(7_001, (steps[7_000][0], 10 + 7_000 + 0.7, NEW_RED))
            lines.insert(3, (steps[2][0], 12.7, NEGATIVE_CASE))
            return steps, lines
        one = [("Build", "success", 3, 5), ("Tests", "failure", 20, 40)]
        flood = [("Build", 3, "##[group]Run make"), ("Build", 4, NEGATIVE_CASE),
                 *(("Tests", 20 + n / 1000, f"##[group]Run case {n}") for n in range(10_000)), ("Tests", 39, NEW_RED)]
        for label, (steps, text), want in (("10,000 unnamed steps", shape(False), (excuse.FAILED, excuse.PASSED)),
                                           ("10,000 named steps", shape(True), (excuse.FAILED, excuse.PASSED)),
                                           ("one step's 10,000 headers", (one, flood), (excuse.AMBIGUOUS,) * 2)):
            job, log_text = {"steps": framed_steps(steps)}, framed_log(text)
            started = time.perf_counter()
            owned = excuse.step_owners(job, log_text, **UNKNOWN)
            took = time.perf_counter() - started
            said = {excuse.lines_of(line)[0]: status for line, _, status in owned}
            with self.subTest(shape=label):
                self.assertEqual((said[NEW_RED], said[NEGATIVE_CASE]), want)
                self.assertLess(took, 0.5, f"step_owners took {took:.2f} s for {label}")

    def test_every_case_has_its_test(self):
        self.assertEqual({name[5:] for name in dir(self) if name.startswith("test_")} & STEP_OWNERSHIP.keys(),
                         STEP_OWNERSHIP.keys())

    def test_codex_repro_a_new_failure_in_a_continue_on_error_step_is_never_excused_by_the_rollup_lines(self):
        # cmux#40542's Codex P1: the continue-on-error step ends at 12:00:12 and a passing step starts and ends in
        # that second. The head fails in Sources/New.swift, the base in Sources/Old.swift; only their identical
        # rollup lines must never excuse the head.
        steps, lines, *_ = STEP_OWNERSHIP["same_second_ending"]
        github = FakeGitHub()
        name = "cmux-next static checks"
        github.jobs = {job_id: {"id": job_id, "run_id": run_id, "head_sha": sha, "name": name,
                                "status": "completed", "conclusion": "failure", "steps": framed_steps(steps)}
                       for job_id, run_id, sha in ((1, 10, HEAD), (2, 20, BASE_SHA))}
        old = [(step, at, text.replace("New.swift:9", "Old.swift:3")) for step, at, text in lines]
        github.logs = {1: framed_log(lines, name), 2: framed_log(old, name)}
        with self.assertRaisesRegex(excuse.Refused, NOT_EXCUSED):
            excuse.judge(REPO, "feat-cmux-next", HEAD, [10], github)

    def test_codex_repro_a_composites_passing_diagnostic_never_excuses_the_head(self):
        # cmux#40542's second Codex BLOCK, F1: a passing negative-case step (a composite action, so its log has an
        # extra `Run` line) prints the head's new diagnostic on purpose; the failing check reports Old.swift on the
        # base and New.swift on the head. Keeping the base's whole log put the passing step's New.swift line in the
        # base's errors, and judge() excused the head's new failure. A base line a passing step may have printed is
        # never base evidence, whether the blocks are placed by time or cannot be placed at all.
        name = "cmux-next static checks"
        steps = [("Negative cases", "success", 10, 12), ("Check", "failure", 20, 22)]

        def lines(where, check_starts=True):
            return [("Negative cases", 10, "##[group]Run ./.github/actions/negative-cases"),
                    ("Negative cases", 10.7, "##[group]Run python3 negative.py"),
                    ("Negative cases", 11, NEW_RED), ("Negative cases", 11.5, "ok: refused as expected"),
                    *([("Check", 20, "##[group]Run scripts/check-concurrency.sh")] if check_starts else []),
                    ("Check", 21, NEW_RED.replace("New.swift:9", where)), ("Check", 21, EXIT)]

        for check_starts in (True, False):
            github = FakeGitHub()
            github.jobs = {job_id: {"id": job_id, "run_id": run_id, "head_sha": sha, "name": name,
                                    "status": "completed", "conclusion": "failure", "steps": framed_steps(steps)}
                           for job_id, run_id, sha in ((1, 10, HEAD), (2, 20, BASE_SHA))}
            github.logs = {1: framed_log(lines("New.swift:9"), name),
                           2: framed_log(lines("Old.swift:3", check_starts), name)}
            with self.subTest(base_placed=check_starts), self.assertRaisesRegex(excuse.Refused, NOT_EXCUSED):
                excuse.judge(REPO, "feat-cmux-next", HEAD, [10], github)

    def test_codex_repro_a_continue_on_error_composites_diagnostic_never_excuses_the_head(self):
        # cmux#40542's and hq#8962's Codex P1: a continue-on-error composite reports success; its inner `Run` line and
        # exit line land in the second a silent passing step shares, so the old placement gave its error to the silent
        # step and dropped its diagnostic, and the head's New.swift was excused against the base's Old.swift because
        # the rollup lines match. In both log formats it is refused.
        name = "cmux-next static checks"
        # #40542's third Codex BLOCK: the silent step named like the composite's inner `Run` line matched it by name
        # alone and the head was excused; a header is a step's only by its name and its stamp in that step's window
        # alone.
        for case in ("continue_on_error_composite_then_silent_step_at_12",
                     "continue_on_error_composite_then_silent_step_at_14",
                     "continue_on_error_composite_then_silent_step_named_like_its_inner_run_at_12",
                     "continue_on_error_composite_then_silent_step_named_like_its_inner_run_at_14",
                     "continue_on_error_composite_then_later_silent_step_named_like_its_inner_run"):
            steps, lines, *_ = STEP_OWNERSHIP[case]
            old = [(step, at, text.replace("New.swift:9", "Old.swift:3")) for step, at, text in lines]
            for columns in (False, True):
                github = FakeGitHub()
                github.jobs = {job_id: {"id": job_id, "run_id": run_id, "head_sha": sha, "name": name,
                                        "status": "completed", "conclusion": "failure", "steps": framed_steps(steps)}
                               for job_id, run_id, sha in ((1, 10, HEAD), (2, 20, BASE_SHA))}
                github.logs = {1: framed_log(lines, name, columns), 2: framed_log(old, name, columns)}
                with self.subTest(case=case, columns=columns), self.assertRaisesRegex(excuse.Refused, NOT_EXCUSED):
                    excuse.judge(REPO, "feat-cmux-next", HEAD, [10], github)

    def judge_pair(self, head_steps, head_lines, base_steps, base_lines, columns):
        name = "cmux-next static checks"
        github = FakeGitHub()
        github.jobs = {job_id: {"id": job_id, "run_id": run_id, "head_sha": sha, "name": name,
                                "status": "completed", "conclusion": "failure", "steps": framed_steps(steps)}
                       for job_id, run_id, sha, steps in ((1, 10, HEAD, head_steps), (2, 20, BASE_SHA, base_steps))}
        github.logs = {1: framed_log(head_lines, name, columns), 2: framed_log(base_lines, name, columns)}
        return excuse.judge(REPO, "feat-cmux-next", HEAD, [10], github)

    def test_codex_repro_a_passing_steps_echoed_exit_line_never_makes_its_lines_base_evidence(self):
        # #40542's fourth Codex BLOCK, F1: on the base a passing negative-case step prints the head's New.swift
        # diagnostic and `expected: Process completed with exit code 1.`; the failing check reports Old.swift on the
        # base and New.swift on the head. SECTION_RED matched the echoed exit text anywhere in a line, so the passing
        # step's section was failed, its New.swift line base evidence, and the head excused.
        steps = [("Negative cases", "success", 10, 12), ("Check", "failure", 20, 22)]

        def lines(where, echo):
            return [("Negative cases", 10, "##[group]Run python3 negative.py"),
                    ("Negative cases", 10.2, "##[endgroup]"),
                    *([("Negative cases", 11, NEW_RED),
                       ("Negative cases", 11.5, "expected: Process completed with exit code 1.")] if echo else []),
                    ("Check", 20, "##[group]Run scripts/check-concurrency.sh"),
                    ("Check", 21, NEW_RED.replace("New.swift:9", where)), ("Check", 21.5, EXIT)]
        for columns in (False, True):
            with self.subTest(columns=columns), self.assertRaisesRegex(excuse.Refused, NOT_EXCUSED):
                self.judge_pair(steps, lines("New.swift:9", False), steps, lines("Old.swift:3", True), columns)

    def test_codex_repro_a_post_steps_own_group_never_hides_its_error(self):
        # #40542's fifth Codex BLOCK: `Post job cleanup.` opens no script echo, but the skip ran to the post step's own
        # `##[endgroup]`, so its `##[error]` line was dropped as a passing step's: the head's New.swift error vanished
        # and the identical check failure was excused. It is the post step's live error, never matched on the base.
        steps = [("Check", "failure", 10, 12), ("Post Run actions/checkout", "success", 13, 13)]

        def lines(post_error):
            return [("Check", 10, "##[group]Run scripts/check.sh"), ("Check", 10.1, "##[endgroup]"),
                    ("Check", 11, OLD_RED), ("Check", 11.5, EXIT),
                    ("Post Run actions/checkout", 13.1, "Post job cleanup."),
                    *([("Post Run actions/checkout", 13.2, "##[group]Removing credentials"),
                       ("Post Run actions/checkout", 13.3, "##[error]" + POST_ERROR),
                       ("Post Run actions/checkout", 13.4, "##[endgroup]")] if post_error else [])]
        for columns in (False, True):
            with self.subTest(columns=columns), self.assertRaisesRegex(excuse.Refused, NOT_EXCUSED):
                self.judge_pair(steps, lines(True), steps, lines(False), columns)

    def test_codex_repro_a_failing_complete_job_never_makes_the_last_steps_lines_base_evidence(self):
        # #40542's fourth Codex BLOCK, F2: on the base "Complete job" failed after a passing last step that printed the
        # head's New.swift diagnostic; the shared last section was promoted to failed, its line base evidence, and the
        # head's New.swift failure excused against the base's Old.swift.
        def steps(complete):
            return [("Check", "failure", 10, 12), ("Negative cases", "success", 20, 22),
                    ("Complete job", complete, 22, 23)]

        def lines(where, echo):
            return [("Check", 10, "##[group]Run scripts/check-concurrency.sh"),
                    ("Check", 11, NEW_RED.replace("New.swift:9", where)), ("Check", 11.5, EXIT),
                    ("Negative cases", 20, "##[group]Run python3 negative.py"),
                    *([("Negative cases", 21, NEW_RED)] if echo else [])]
        for columns in (False, True):
            with self.subTest(columns=columns), self.assertRaisesRegex(excuse.Refused, NOT_EXCUSED):
                self.judge_pair(steps("success"), lines("New.swift:9", False), steps("failure"),
                                lines("Old.swift:3", True), columns)


# A seeded property test over random step layouts (cmux#40542's one-to-one rule): composites, self-printed groups,
# silent steps, same-second boundaries, continue-on-error, duplicate names, a post step, both log formats; inner `Run`
# lines that copy another step's header or an unnamed (`Run ...`) step's name, a later silent step's included
# (#40542's third Codex BLOCK, hq#8962 F1); `##[error]` lines in groups that are not a script's echo (a post step's
# own group, a group before or after the echo ends, nested groups: #40542's fifth); and passing steps that echo
# failure text (an exit-code line, an
# `##[error]` line in their script's echo, error-shaped lines, another step's diagnostic), failing steps that echo
# another failing step's diagnostic on the base, and a failing "Complete job" (#40542's fourth Codex BLOCK). The same
# seed gives the same layouts on every run; a failure names its case number, so `random_layout(Random(SEED + n))`
# rebuilds it.
LAYOUT_SEED = 40542
LAYOUT_CASES = 3000


def random_layout(rng):
    """(steps, head lines, base lines, error-bearing texts, whether judge() may excuse the head against the base) for
    one random job. Each failing or continue-on-error step prints its own error, the same on both sides or New<x>.swift
    on the head and Old<x>.swift on the base (letters, not numbers: errors are compared with numbers masked), and its
    exit line. judge() may excuse only a placed pair whose failures are proven: no continue-on-error step printed an
    error, "Complete job" passed or shares its section with a failed step, and every line a failed step printed on
    the head a step of the same name printed on the base."""
    plan, at = [], rng.choice((2, 3, 3, 3))
    for j in range(rng.randint(1, 6)):
        end = at + rng.choice((0, 0, 1, 2, 3))
        kind = rng.choice(("plain",) * 7 + ("silent", "silent", "composite", "composite", "self_group"))
        verdict = "success" if kind == "silent" else rng.choice(("success", "success", "failure", "continue_on_error"))
        name = (f"Run inner-{rng.randint(0, 5)}.sh" if kind == "silent" and rng.random() < 0.5
                else f"Run script-{j}.sh" if rng.random() < 0.4
                else rng.choice([step[0] for step in plan if not step[0].startswith("Run ")] or [f"Check {j}"])
                if rng.random() < 0.2 else f"Check {j}")
        header = (name if name.startswith("Run ") else
                  f"Run ./.github/actions/a{j}" if kind == "composite" else f"Run script-{j}.sh")
        mine = NEW_RED.replace("New.swift", f"New{chr(65 + j)}.swift")
        theirs = mine.replace("New", "Old") if rng.random() < 0.7 else mine
        plan.append((name, kind, verdict, at, end, header, mine, theirs))
        at = end + rng.choice((0, 0, 1, 2))
    copied = [step[5] for step in plan] + [step[0] for step in plan if step[0].startswith("Run ")]
    diagnostics = [step[6] for step in plan if step[2] != "success" and step[1] != "silent"]
    steps, head, base, red, prev, may = [], [], [], set(), 2.5, True
    for j, (name, kind, verdict, at, end, header, mine, theirs) in enumerate(plan):
        texts, live_error = [], False  # (head text, base text)
        if kind != "silent":
            texts = [(f"##[group]{header}",) * 2]
            if rng.random() < 0.3:
                texts += [(f'echo "##[error]step {j} would fail"',) * 2, ("##[endgroup]",) * 2]
            texts.append((f"step {j}: started",) * 2)
            if kind in ("composite", "self_group"):
                texts.append((f"##[group]{rng.choice(copied) if rng.random() < 0.6 else f'Run inner-{j}.sh'}",) * 2)
            if verdict == "success":
                for echo in ("expected: Process completed with exit code 1.", mine, *diagnostics):
                    if rng.random() < 0.3:
                        texts.append((echo,) * 2)
                if rng.random() < 0.15:
                    # A live `##[error]` in a group that is not the script's echo: its own group (before or after
                    # the echo's `##[endgroup]`) or nested ones. The section is ERRORED: kept, never evidence.
                    error = (f"##[error]{mine}",) * 2
                    texts += ([("##[group]Details",) * 2, error, ("##[endgroup]",) * 2] if rng.random() < 0.5 else
                              [("##[group]Outer",) * 2, ("##[group]Inner",) * 2, error, ("##[endgroup]",) * 2,
                               ("##[endgroup]",) * 2])
                    live_error = True
            else:
                texts.append((mine, theirs))
                if verdict == "failure" and diagnostics and rng.random() < 0.3:
                    texts.append(("", rng.choice(diagnostics)))
                texts.append((EXIT,) * 2)
        stamps = sorted(round(rng.uniform(max(prev, at), end + 0.999), 7) for _ in texts)
        for second, (said, also) in zip(stamps, texts):
            if said:
                head.append((name, second, said))
            base.append((name, second, also))
            if (verdict != "success" or live_error) and said:
                red.add(said)
        prev = stamps[-1] if stamps else prev
        steps.append((name, "failure" if verdict == "failure" else "success", at, end))
        may = may and verdict != "continue_on_error" and not live_error
    at = plan[-1][4] + rng.choice((0, 1))
    if rng.random() < 0.5 or not any(c == "failure" for _, c, _, _ in steps):
        end = at + rng.choice((0, 1))
        texts = ["##[group]Run scripts/ci/rollup.sh", "##[error]red check: Check 0", EXIT]
        stamps = sorted(round(rng.uniform(max(prev, at), end + 0.999), 7) for _ in texts)
        head += [("Rollup", s, t) for s, t in zip(stamps, texts)]
        base += [("Rollup", s, t) for s, t in zip(stamps, texts)]
        red.update(texts)
        steps.append(("Rollup", "failure", at, end))
        prev, at = stamps[-1], end + rng.choice((0, 1))
    if rng.random() < 0.3:
        # A post step: `Post job cleanup.` opens no script echo, so a group of its own and an `##[error]` in it, on
        # the head alone, are live (#40542's fifth Codex BLOCK).
        texts = ["Post job cleanup."]
        own = rng.random() < 0.5
        if own:
            texts += ["##[group]Removing credentials", "##[error]post: error: Sources/NewPost.swift left a lock behind",
                      "##[endgroup]"]
        stamps = sorted(round(rng.uniform(max(prev, at), at + 0.999), 7) for _ in texts)
        head += [("Post Run actions/checkout", second, text) for second, text in zip(stamps, texts)]
        base.append(("Post Run actions/checkout", stamps[0], "Post job cleanup."))
        if own:
            red.update(texts)
            may = False
        steps.append(("Post Run actions/checkout", "success", at, at))
    if rng.random() < 0.15:
        # A failing "Complete job" leaves the last section unproven unless the step it shares it with failed.
        may = may and steps[-1][1] == "failure"
        steps.append(("Complete job", "failure", steps[-1][3], steps[-1][3]))
    failed = {name for name, conclusion, _, _ in steps if conclusion == "failure"}
    printed = {(name, text) for name, _, text in base if name in failed}
    return steps, head, base, red, may and all((name, text) in printed for name, _, text in head if name in failed)


class StepLayouts(unittest.TestCase):
    """LAYOUT_CASES random layouts from LAYOUT_SEED, each in both log formats: failed_steps_log never drops a line of
    a failing or error-bearing section; judge() excuses a log with an ambiguous section only on counted whole-log
    identity with the base's (UnplacedSignature), and a placed one only when the head's and the base's failures are
    both proven failures of the same step (random_layout)."""

    def test_random_step_layouts(self):
        import random
        name, seen = "cmux-next static checks", {"placed": 0, "ambiguous": 0, "excused": 0, "excused across": 0}
        for n in range(LAYOUT_CASES):
            steps, head, base, red, may = random_layout(random.Random(LAYOUT_SEED + n))
            columns = bool(n % 2)
            job = {"steps": framed_steps(steps)}
            head_log, base_log = framed_log(head, name, columns), framed_log(base, name, columns)
            ambiguous = any(status == excuse.AMBIGUOUS for _, _, status in excuse.step_owners(job, head_log, **UNKNOWN))
            seen["ambiguous" if ambiguous else "placed"] += 1
            kept = excuse.failed_steps_log(job, head_log, **UNKNOWN)
            for text in red:
                self.assertIn(text, kept, f"case {n}: {text!r} dropped")
            for pair, allowed in (((head_log, base_log), may), ((head_log, head_log), None)):
                github = FakeGitHub()
                github.jobs = {job_id: {"id": job_id, "run_id": run_id, "head_sha": sha, "name": name,
                                        "status": "completed", "conclusion": "failure", "steps": job["steps"]}
                               for job_id, run_id, sha in ((1, 10, HEAD), (2, 20, BASE_SHA))}
                github.logs = dict(zip((1, 2), pair))
                try:
                    said = excuse.judge(REPO, "feat-cmux-next", HEAD, [10], github)
                except excuse.Refused:
                    continue
                if ambiguous:
                    # Compared whole (UnplacedSignature): only on identity, counted, with the base's whole log.
                    self.assertIn("compared whole", "\n".join(said), f"case {n}")
                    self.assertEqual(excuse.unplaced_signature(github.jobs[1], pair[0]),
                                     excuse.unplaced_signature(github.jobs[2], pair[1]), f"case {n}: {said}")
                    seen["excused whole"] = seen.get("excused whole", 0) + 1
                    continue
                if allowed is not None:
                    self.assertTrue(allowed, f"case {n}: excused without proven failures of the same step: {said}")
                    seen["excused across"] += 1
                seen["excused"] += 1
        # The layouts reach both sides of the rule, and placed reds proven on both sides are still excused.
        self.assertGreater(min(seen.values()), LAYOUT_CASES // 50, seen)


# The STEP_OWNERSHIP cases through step_lines' callers. Every named step gets a test-named name (" tests"; an unnamed
# step keeps its name, which is its header), each line a passing step printed (a PASSED text, or the negative case)
# becomes a quarantined test's failure, FLAKE, and, with OWN, the last section ends with another test's failure, OWN.
# A case step_owners places nothing in is refused by package_tests and never explained by quarantined_only; of the
# placed ones, package_tests reads OWN alone where every failed section is a declared test step naming a test of its
# own (PACKAGE_EXCUSED), and refuses the rest (a continue-on-error section with no test, a failing "Complete job").
FLAKE = "✘ Test sometimes() recorded an issue at A.swift:1:2: Expectation failed: ready == true"
OWN = "✘ Test own() recorded an issue at B.swift:3:4: Expectation failed: done == true"
PACKAGE_EXCUSED = {"duplicate_names", "unnamed_steps_a_second_apart", "passing_step_echoes_failure_text"}


def callers_case(case, columns=False, own=True):
    """(job, log, package) for STEP_OWNERSHIP[CASE] as described above."""
    steps, lines, _, passed, *_ = STEP_OWNERSHIP[case]

    def renamed(name):
        return name if name.startswith("Run ") or name == "Complete job" else f"{name} tests"
    steps = [(renamed(name), conclusion, start, end) for name, conclusion, start, end in steps]
    lines = [(f"{step} tests", second, FLAKE if text in passed or text == NEGATIVE_CASE else text)
             for step, second, text in lines]
    if own:
        lines.append((lines[-1][0], lines[-1][1], OWN))
    job = {"name": "package tests", "steps": framed_steps(steps)}
    package = {"steps": tuple(name for name, _, _, _ in steps if name != "Complete job")}
    return job, framed_log(lines, columns=columns), package


class StepOwnershipCallers(unittest.TestCase):
    """package_tests and quarantined_only read a failed section's lines through failed_view (section_lines), which
    shares failed_steps_log's owner (step_owners): a log that does not map one to one onto its steps places nothing, so
    package_tests refuses (the package red is not excused) and quarantined_only answers False (not excused by
    quarantine)."""

    def test_every_step_ownership_case_through_package_tests(self):
        for case in STEP_OWNERSHIP:
            for columns in (False, True):
                job, log_text, package = callers_case(case, columns)
                with self.subTest(case=case, columns=columns):
                    if case in PACKAGE_EXCUSED:
                        self.assertEqual(excuse.package_tests(package, excuse.failed_view(job, log_text, base=False, **UNKNOWN)),
                                         ["own()"])
                    else:
                        with self.assertRaises(excuse.Refused):
                            excuse.package_tests(package, excuse.failed_view(job, log_text, base=False, **UNKNOWN))

    def test_every_step_ownership_case_through_quarantined_only(self):
        # The passing steps' quarantined failure never explains the failed step, whose own lines name no test.
        for case in STEP_OWNERSHIP:
            for columns in (False, True):
                job, log_text, _ = callers_case(case, columns, own=False)
                with self.subTest(case=case, columns=columns):
                    self.assertFalse(excuse.quarantined_only(excuse.failed_view(job, log_text, base=False, **UNKNOWN),
                                                             {"sometimes()": "hq#1"}))

    def test_section_lines_gives_a_failed_section_its_own_lines_only(self):
        for case, (_, _, _, _, ambiguous, *_) in STEP_OWNERSHIP.items():
            job, log_text, _ = callers_case(case)
            view = excuse.failed_view(job, log_text, base=False, **UNKNOWN)
            with self.subTest(case=case):
                if ambiguous:
                    self.assertIs(view, excuse.UNPLACED)
                    continue
                red = [line for _, lines in excuse.section_lines(view) for line in lines]
                self.assertTrue(any(OWN in line for line in red))
                self.assertFalse(any(FLAKE in line for line in red))

    def test_a_quarantined_failure_in_its_own_step_is_still_excused(self):
        # The positive side: the failed test step's own section names only quarantined tests.
        steps = [("Build", "success", 3, 9), ("Unit tests", "failure", 10, 20)]
        lines = [("Build", 3, "##[group]Run swift build"), ("Unit tests", 10, "##[group]Run swift test"),
                 ("Unit tests", 19, FLAKE), ("Unit tests", 19, "##[error]Process completed with exit code 1.")]
        for columns in (False, True):
            with self.subTest(columns=columns):
                self.assertTrue(excuse.quarantined_only(
                    excuse.failed_view({"name": "swift", "steps": framed_steps(steps)},
                                       framed_log(lines, columns=columns), base=False, **UNKNOWN), {"sometimes()": "hq#1"}))


class UnplacedSignature(unittest.TestCase):
    """signature() of a log step_owners does not place is excuse.UNPLACED, never an empty or partial set a caller
    could subtract a base's from, and every caller refuses on it or treats the red as new (#40542's Codex F1 at
    76dc160c: next_batch's expand_job subtracted the base's signature of such a log from the head's and read a head's
    new Sources/New.swift failure as inherited, because a passing composite printed New.swift on the base too)."""

    STEPS = [("Composite", "success", 10, 12), ("Unit tests", "failure", 20, 22)]

    def lines(self, red, placed=False):
        composite = [("Composite", 10, "##[group]Run ./.github/actions/setup")]
        if not placed:
            composite.append(("Composite", 11, "##[group]Run inner/action@v1"))  # the composite's inner `Run` line
        return composite + [("Composite", 11, NEW_RED),
                            ("Unit tests", 20, "##[group]Run swift test"), ("Unit tests", 21, red),
                            ("Unit tests", 21, EXIT)]

    def job(self, steps=None):
        return {"id": 1, "run_id": 10, "head_sha": HEAD, "name": SWIFT, "status": "completed",
                "conclusion": "failure", "steps": framed_steps(steps or self.STEPS)}

    def test_an_unplaced_log_has_no_signature_on_either_side(self):
        for columns in (False, True):
            text = framed_log(self.lines(OLD_RED), SWIFT, columns=columns)
            for base in (False, True):
                with self.subTest(columns=columns, base=base):
                    self.assertIs(excuse.signature(excuse.failed_view(self.job(), text, base=base, **UNKNOWN)),
                                  excuse.UNPLACED)
            placed = excuse.signature(excuse.failed_view(
                self.job(), framed_log(self.lines(OLD_RED, placed=True), SWIFT, columns=columns), base=True,
                **UNKNOWN))
            self.assertIsNot(placed, excuse.UNPLACED)
            self.assertEqual(placed[0], {"Unit tests"})

    def test_package_tests_refuses_an_unplaced_log(self):
        package = excuse.PACKAGE_JOBS["CmuxMobileKit tests (macOS swift test, iOS simulator)"]
        steps = [("Composite", "success", 10, 12), ("swift test (macOS)", "failure", 20, 22)]
        lines = [(("swift test (macOS)" if step == "Unit tests" else step), at, text)
                 for step, at, text in self.lines(OWN)]
        with self.assertRaises(excuse.Refused):
            excuse.package_tests(package, excuse.failed_view(self.job(steps), framed_log(lines, SWIFT), base=False,
                                                             **UNKNOWN))

    def test_quarantined_only_never_explains_an_unplaced_log(self):
        self.assertFalse(excuse.quarantined_only(excuse.failed_view(self.job(), framed_log(self.lines(FLAKE), SWIFT),
                                                                    base=False, **UNKNOWN), {"sometimes()": "hq#1"}))

    def test_judge_compares_an_unplaced_head_whole(self):
        for columns in (False, True):
            with self.subTest(columns=columns):
                github = FakeGitHub()
                github.jobs = {1: self.job(), 2: dict(self.job(), id=2, run_id=20, head_sha=BASE_SHA)}
                github.logs = {1: framed_log(self.lines(NEW_RED), SWIFT, columns=columns),
                               2: framed_log(self.lines(NEW_RED, placed=True), SWIFT, columns=columns)}
                # Head and base serve the same unplaced log: compared whole and excused on identity (UnplacedSignature).
                self.assertIn("compared whole", "\n".join(excuse.judge(REPO, "feat-cmux-next", HEAD, [10], github)))


class StepNamesAreRequired(unittest.TestCase):
    """step_owners and every reader of it take the workflow's step names as a required keyword (step_names): a call
    without them raises, never quietly places by the "Run " prefix, and a caller that cannot read the workflow says so
    with STEP_NAMES_UNKNOWN (#40542's Codex F1 at 221c7e4d: next_batch's expand_job read no workflow)."""

    def test_a_call_without_the_step_names_raises(self):
        job = {"name": SWIFT, "steps": framed_steps([("Build", "success", 3, 9), ("Unit tests", "failure", 10, 20)])}
        text = framed_log([("Build", 3, "##[group]Run swift build"), ("Unit tests", 10, "##[group]Run swift test"),
                           ("Unit tests", 19, NEW_RED), ("Unit tests", 19, EXIT)], SWIFT)
        for reader in (excuse.step_owners, excuse.failed_steps_log, excuse.failed_view):
            with self.subTest(reader=reader.__name__):
                with self.assertRaises(TypeError):
                    reader(job, text)
                with self.assertRaises(TypeError):
                    reader(job, text, step_names=None)
                role = {"base": False} if reader is excuse.failed_view else {}
                reader(job, text, step_names=excuse.STEP_NAMES_UNKNOWN, **role)
        # Every comparator reads a failed_view alone: a raw log handed to one is a TypeError, never read.
        for comparator in (excuse.signature, excuse.step_errors, excuse.crash_signals, excuse.ratchet_red,
                           excuse.section_lines, excuse.guard_tests, excuse.view_text):
            with self.subTest(comparator=comparator.__name__), self.assertRaises(TypeError):
                comparator(text)
        with self.assertRaises(TypeError):
            excuse.package_tests(excuse.PACKAGE_JOBS["CmuxMobileKit tests (macOS swift test, iOS simulator)"], text)
        with self.assertRaises(TypeError):
            excuse.quarantined_only(text, {})


class NamedRunStepHeader(unittest.TestCase):
    """A step named "Run ..." by its workflow's author is a named step: its header (`Run <its script's first line>`)
    cannot be read off its name, so only its stamp places its header, as for any other named step. Whether a step has
    a `name:` is read from its workflow at the job's head, matched to the jobs API's steps by order; an unnamed step's
    header must still be its name. #40542's sixth Codex BLOCK (F1): cmux-next.yml's "Run package tests (changed suites
    first, then selected targets)" opens with `##[group]Run set -euo pipefail`, and its red, excused on base, was
    refused on head as a log that does not map one to one."""

    NAME = "cmux-next swift checks"
    PATH = ".github/workflows/cmux-next.yml"
    CHECKOUT = "Run actions/checkout@v6"
    BUILD = "Build package and tests"
    TESTS = "Run package tests (changed suites first, then selected targets)"
    RED = "swift: error: Sources/Old.swift:3 blocks the main thread"

    def workflow(self, tests_named=True):
        tests = (f"      - name: {self.TESTS}\n        run: |\n" if tests_named else "      - run: |\n")
        return ("name: cmux-next\non: push\njobs:\n  swift-checks:\n"
                f"    name: {self.NAME}\n    runs-on: macos-26\n    steps:\n"
                "      - uses: actions/checkout@v6\n"
                f"      - name: {self.BUILD}\n        run: swift build\n"
                + tests + "          set -euo pipefail\n          swift test\n")

    def steps(self, tests_name=None):
        found = framed_steps([(self.CHECKOUT, "success", 3, 4), (self.BUILD, "success", 5, 9),
                              (tests_name or self.TESTS, "failure", 10, 20),
                              (f"Post {self.CHECKOUT}", "success", 21, 22)])
        return found

    def lines(self):
        return [(self.CHECKOUT, 3, f"##[group]{self.CHECKOUT}"), (self.CHECKOUT, 3, "##[endgroup]"),
                (self.BUILD, 5, "##[group]Run swift build"), (self.BUILD, 5, "swift build"),
                (self.BUILD, 5, "##[endgroup]"),
                (self.TESTS, 10, "##[group]Run set -euo pipefail"), (self.TESTS, 10, "set -euo pipefail"),
                (self.TESTS, 10, "swift test"), (self.TESTS, 10, "##[endgroup]"),
                (self.TESTS, 19, self.RED), (self.TESTS, 19, EXIT),
                (f"Post {self.CHECKOUT}", 21, "Post job cleanup.")]

    def github(self, fmt, workflow, tests_name=None):
        test = self
        log_text = fmt(self.lines(), self.NAME)

        class Fake(FakeGitHub):
            def json(self, route, *, paginate=False):
                found = super().json(route, paginate=paginate)
                if (isinstance(found, dict) and "/actions/runs/" in route and "/jobs" not in route
                        and "workflow_id" in found):
                    found["path"] = test.PATH
                return found

            def blob(self, repo, ref, path):
                self.blobs.append((repo, ref, path))
                if workflow is None or path != test.PATH:
                    raise excuse.Refused(f"{repo}@{ref}: {path} is not a text file GitHub served")
                return workflow

        github = Fake()
        github.blobs = []
        github.base_runs = [{**run, "path": self.PATH} for run in github.base_runs]
        github.jobs = {1: {"id": 1, "run_id": 10, "head_sha": HEAD, "name": self.NAME, "status": "completed",
                           "conclusion": "failure", "steps": self.steps(tests_name)},
                       2: {"id": 2, "run_id": 20, "head_sha": BASE_SHA, "name": self.NAME, "status": "completed",
                           "conclusion": "failure", "steps": self.steps(tests_name)}}
        github.logs = {1: log_text, 2: log_text}
        return github

    def formats(self):
        return (("raw", lambda lines, name: framed_log(lines, name)),
                ("columns", lambda lines, name: framed_log(lines, name, columns=True)))

    def test_a_step_its_workflow_names_run_something_is_placed_by_its_stamp(self):
        # Codex's repro: the same red on head and base, one header per step, the named step's header its script's.
        for label, fmt in self.formats():
            with self.subTest(log=label):
                github = self.github(fmt, self.workflow())
                text = "\n".join(excuse.judge(REPO, "feat-cmux-next", HEAD, [10], github))
                self.assertIn(f"excused '{self.NAME}'", text)
                self.assertIn("Old.swift", text)
                self.assertIn((REPO, HEAD, self.PATH), github.blobs)
                self.assertIn((REPO, BASE_SHA, self.PATH), github.blobs)

    def test_an_unnamed_step_whose_header_is_not_its_name_still_places_nothing(self):
        # The workflow gives the step no name: the jobs API names it by its script (`Run swift test` here, its
        # header's text in a real log), and a header that is not that name is not proven its own.
        for label, fmt in self.formats():
            with self.subTest(log=label):
                github = self.github(fmt, self.workflow(tests_named=False), tests_name="Run swift test")
                # Head and base serve the same unplaced log: compared whole and excused on identity (UnplacedSignature).
                self.assertIn("compared whole", "\n".join(excuse.judge(REPO, "feat-cmux-next", HEAD, [10], github)))

    def test_an_unread_workflow_leaves_a_run_named_step_unproven(self):
        for label, fmt in self.formats():
            with self.subTest(log=label):
                github = self.github(fmt, None)
                # Head and base serve the same unplaced log: compared whole and excused on identity (UnplacedSignature).
                self.assertIn("compared whole", "\n".join(excuse.judge(REPO, "feat-cmux-next", HEAD, [10], github)))

    def test_a_workflow_whose_steps_do_not_match_the_jobs_steps_proves_nothing(self):
        # A step the workflow does not list (a `Pre` step, a container step) or a name that is not the workflow's
        # leaves the order unproven: the "Run ..." name is not taken for a named step's.
        extra = self.workflow().replace("      - uses: actions/checkout@v6\n",
                                        "      - uses: actions/checkout@v6\n      - name: Lint\n        run: lint\n")
        renamed = self.workflow().replace(f"name: {self.BUILD}", "name: Build the package")
        for label, fmt in self.formats():
            for workflow in (extra, renamed):
                with self.subTest(log=label, workflow=workflow):
                    github = self.github(fmt, workflow)
                    # Head and base serve the same unplaced log: compared whole and excused on identity (UnplacedSignature).
                    self.assertIn("compared whole", "\n".join(excuse.judge(REPO, "feat-cmux-next", HEAD, [10], github)))


class LocalCompositeCannotPose(unittest.TestCase):
    """A local composite action is allowed in a workflow workflow_step_names reads (dep-fleet-6 on #40542): it is one
    step of the jobs API, so it never shifts the order its marks rely on, and its inner steps' `##[group]Run ...` lines
    never become another step's header. Here a failing composite's inner step is named exactly like the header of the
    unnamed step after it (`Run swift test`), which the workflow proves unnamed, so its header text alone would fit.
    - With several inner `Run` lines and the sibling's own header, there are more headers than steps: nothing is
      placed (every line AMBIGUOUS), and the red is refused.
    - With one inner `Run` line and a silent sibling (the counts balance), the inner line's stamp lies in the
      composite's window: inside it alone, it is not in the sibling's; in the second they share, it is in two windows.
      Either way nothing is placed, and no line is ever the sibling's."""

    NAME = "cmux-next swift checks"
    PATH = ".github/workflows/cmux-next.yml"
    CHECKOUT = "Run actions/checkout@v6"
    COMPOSITE = "Set up the toolchain"
    SIBLING = "Run swift test"
    WORKFLOW = ("name: cmux-next\non: push\njobs:\n  swift-checks:\n"
                "    name: cmux-next swift checks\n    runs-on: macos-26\n    steps:\n"
                "      - uses: actions/checkout@v6\n"
                "      - name: Set up the toolchain\n        uses: ./.github/actions/setup-toolchain\n"
                "      - if: always()\n        run: swift test\n")

    def steps(self, composite_end):
        return framed_steps([(self.CHECKOUT, "success", 3, 4), (self.COMPOSITE, "failure", 10, composite_end),
                             (self.SIBLING, "success", composite_end, composite_end + 2),
                             (f"Post {self.CHECKOUT}", "success", composite_end + 3, composite_end + 4)])

    def lines(self, composite_end, inner_at, several):
        composite = [(self.COMPOSITE, 10, "##[group]Run ./.github/actions/setup-toolchain"),
                     (self.COMPOSITE, 10, "##[endgroup]")]
        if several:
            composite += [(self.COMPOSITE, 11, "##[group]Run brew install swiftly"),
                          (self.COMPOSITE, 11, "##[endgroup]")]
        composite += [(self.COMPOSITE, inner_at, f"##[group]{self.SIBLING}"),
                      (self.COMPOSITE, inner_at, "##[endgroup]"),
                      (self.COMPOSITE, inner_at, NEW_RED), (self.COMPOSITE, inner_at, EXIT)]
        sibling = [(self.SIBLING, composite_end, f"##[group]{self.SIBLING}"),
                   (self.SIBLING, composite_end, "##[endgroup]")] if several else []
        return ([(self.CHECKOUT, 3, f"##[group]{self.CHECKOUT}"), (self.CHECKOUT, 3, "##[endgroup]")] + composite
                + sibling + [(f"Post {self.CHECKOUT}", composite_end + 3, "Post job cleanup.")])

    LAYOUTS = {
        # (composite's last second, the inner `Run swift test` line's second, several inner `Run` lines)
        "several inner Run lines, the sibling's own header": (20, 15, True),
        "one inner Run line inside the composite, a silent sibling": (20, 15, False),
        "one inner Run line in the second both share, a silent sibling": (20, 20, False),
    }

    def github(self, log_text, steps):
        test = self

        class Fake(FakeGitHub):
            def json(self, route, *, paginate=False):
                found = super().json(route, paginate=paginate)
                if (isinstance(found, dict) and "/actions/runs/" in route and "/jobs" not in route
                        and "workflow_id" in found):
                    found["path"] = test.PATH
                return found

            def blob(self, repo, ref, path):
                return test.WORKFLOW

        github = Fake()
        github.base_runs = [{**run, "path": self.PATH} for run in github.base_runs]
        github.jobs = {1: {"id": 1, "run_id": 10, "head_sha": HEAD, "name": self.NAME, "status": "completed",
                           "conclusion": "failure", "steps": copy.deepcopy(steps)},
                       2: {"id": 2, "run_id": 20, "head_sha": BASE_SHA, "name": self.NAME, "status": "completed",
                           "conclusion": "failure", "steps": copy.deepcopy(steps)}}
        github.logs = {1: log_text, 2: log_text}
        return github

    def test_a_composites_inner_run_line_is_never_its_siblings_header(self):
        for layout, (end, inner_at, several) in self.LAYOUTS.items():
            for columns in (False, True):
                with self.subTest(layout=layout, columns=columns):
                    steps = self.steps(end)
                    log_text = framed_log(self.lines(end, inner_at, several), self.NAME, columns=columns)
                    job = {"id": 1, "run_id": 10, "head_sha": HEAD, "name": self.NAME, "steps": steps}
                    names = excuse.workflow_step_names(REPO, job, self.PATH, self.github(log_text, steps), {})
                    # The composite does not stop the marks: the workflow proves the sibling unnamed.
                    self.assertEqual(names, {2: False, 3: True, 4: False})
                    owned = excuse.step_owners(job, log_text, step_names=names)
                    self.assertEqual({status for _, _, status in owned}, {excuse.AMBIGUOUS})
                    self.assertFalse(any(index == 3 for _, index, _ in owned), "a line was placed on the sibling")
                    self.assertIs(excuse.failed_view(job, log_text, base=True, step_names=names), excuse.UNPLACED)
                    # Head and base serve the same unplaced log: compared whole and excused on identity (UnplacedSignature).
                    self.assertIn("compared whole", "\n".join(excuse.judge(REPO, "feat-cmux-next", HEAD, [10], self.github(log_text, steps))))


# The step-name detector. A line of step_lines' callers and owner, or of anything else in base_red_excuse.py and
# test_reds.py, never places or looks up a log line by a step's name: a read of a jobs-API step's "name" (`step["name"]`,
# `step.get("name")`, on a step or a name bound from a job's steps[]) and a read of `gh run view --log`'s step column
# (index 1 of a line split on tabs) each need a marker on their line naming why the name is read:
#   `# step-name: display`   a message or audit line names the step;
#   `# step-name: classify`  which declared workflow step this is (SETUP_STEPS, COMPILE_STEPS, PACKAGE_JOBS' steps,
#                            GUARD_GROUP_STEP, the gallery and webview steps, the failed steps signature compares);
#   `# step-name: validate`  step_owners checks a header the log's order already gave a step against that step's
#                            name (an unnamed step's header is its name); a mismatch places nothing.
# Placing a line in a step is step_owners' alone, by the log's order.
STEP_NAME_FILES = ("scripts/ci/base_red_excuse.py", "scripts/ci/test_reds.py")
STEP_NAME_MARKER = re.compile(r"#\s*step-name:\s*([\w-]+)")
STEP_NAME_USES = ("display", "classify", "validate")


def by_name_step_lookups(source, path="<source>"):
    """Each line of SOURCE that reads a step's name or `gh run view --log`'s step column without a STEP_NAME_USES
    marker, as `PATH:LINE: why: text`."""
    import ast
    tree = ast.parse(source)
    text = source.splitlines()

    def root(node):
        while isinstance(node, (ast.Subscript, ast.Attribute, ast.Call)):
            node = node.func if isinstance(node, ast.Call) else node.value
        return node.id if isinstance(node, ast.Name) else ""

    def targets(node):
        return {n.id for n in ast.walk(node) if isinstance(n, ast.Name)}

    def steps_key(node):
        return isinstance(node, ast.Constant) and node.value == "steps"

    def yields_steps(node, tainted):
        """NODE is a job's steps[] or a step of it: `X["steps"]`, `X.get("steps")`, a name bound from one, or a list,
        sort, item or comprehension of those."""
        if isinstance(node, ast.Name):
            return node.id in tainted
        if isinstance(node, ast.Subscript):
            return steps_key(node.slice) or yields_steps(node.value, tainted)
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) and node.func.attr == "get":
            return bool(node.args) and steps_key(node.args[0])
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id in (
                "sorted", "list", "reversed", "next", "iter", "enumerate", "zip"):
            return any(yields_steps(arg, tainted) for arg in node.args)
        if isinstance(node, ast.BoolOp):
            return any(yields_steps(value, tainted) for value in node.values)
        if isinstance(node, (ast.ListComp, ast.SetComp, ast.GeneratorExp)):
            bound = set(tainted)
            for generator in node.generators:
                if yields_steps(generator.iter, bound):
                    bound |= targets(generator.target)
            return yields_steps(node.elt, bound)
        return False

    def tab_split(node):
        return (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) and node.func.attr == "split"
                and bool(node.args) and isinstance(node.args[0], ast.Constant) and node.args[0].value == "\t")

    def own(scope):
        """The nodes of SCOPE outside the functions it defines."""
        stack = list(ast.iter_child_nodes(scope))
        while stack:
            node = stack.pop()
            yield node
            if not isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.Lambda, ast.ClassDef)):
                stack.extend(ast.iter_child_nodes(node))

    def a_step(node, tainted):
        return yields_steps(node, tainted) or root(node) in tainted or "step" in root(node).lower()

    found = {}
    for scope in [tree, *(n for n in ast.walk(tree) if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef,
                                                                        ast.Lambda)))]:
        tainted, columns = set(), set()
        changed = True
        while changed:
            changed = False
            for node in own(scope):
                pairs = []
                if isinstance(node, ast.Assign):
                    pairs = [(target, node.value) for target in node.targets]
                elif isinstance(node, (ast.AnnAssign, ast.NamedExpr)) and node.value is not None:
                    pairs = [(node.target, node.value)]
                elif isinstance(node, (ast.For, ast.comprehension)):
                    pairs = [(node.target, node.iter)]
                for target, value in pairs:
                    if yields_steps(value, tainted) and not targets(target) <= tainted:
                        tainted |= targets(target)
                        changed = True
                    if tab_split(value):
                        columns |= targets(target)
        for node in own(scope):
            why = None
            if isinstance(node, ast.Subscript) and isinstance(node.slice, ast.Constant):
                if node.slice.value == "name" and a_step(node.value, tainted):
                    why = "reads a step's name"
                elif node.slice.value == 1 and (tab_split(node.value) or (isinstance(node.value, ast.Name)
                                                                         and node.value.id in columns)):
                    why = "reads `gh run view --log`'s step column"
            elif (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) and node.func.attr == "get"
                  and node.args and isinstance(node.args[0], ast.Constant) and node.args[0].value == "name"
                  and a_step(node.func.value, tainted)):
                why = "reads a step's name"
            if why is None:
                continue
            marker = STEP_NAME_MARKER.search(text[node.lineno - 1])
            if marker and marker.group(1) in STEP_NAME_USES:
                continue
            found[node.lineno] = f"{path}:{node.lineno}: {why}: {text[node.lineno - 1].strip()}"
    return [found[line] for line in sorted(found)]


class NoStepLookupByName(unittest.TestCase):
    """Detector: no by-name step lookup in base_red_excuse.py or test_reds.py (STEP_NAME_FILES). Every log line's step is
    step_owners' (by the log's order); a step's name is read only for display or to classify a declared step, each
    marked on its line. cmuxterm-hq docs/handbook/red-quoted-from-a-passing-step.md."""

    def test_no_step_is_looked_up_by_name(self):
        found = [line for path in STEP_NAME_FILES for line in by_name_step_lookups((ROOT / path).read_text(), path)]
        self.assertEqual(found, [], "a step's name placed or looked up a line; place lines with step_owners, or mark "
                                    "a display or classify read `# step-name: display|classify`:\n" + "\n".join(found))

    def test_it_finds_name_and_window_placement(self):
        # The shapes step_lines had before it shared step_owners.
        source = "\n".join([
            "def step_lines(job, head_log, only=None):",
            "    metadata = [step for step in job.get('steps') or [] if step.get('conclusion') != 'skipped'",
            "                and (only is None or step.get('name') in only)]",
            "    names = [found.get('name') for found in metadata]",
            "    by_step = {}",
            "    for line in head_log.splitlines():",
            "        parts = line.split('\\t', 2)",
            "        by_step.setdefault(parts[1], []).append(parts[2])",
            "    first = job['steps'][0]['name']",
            "    column = head_log.split('\\t')[1]",
            "    windows = [(item['name'], 0) for item in sorted(job.get('steps'), key=len)]",
            "    return by_step"])
        self.assertEqual([line.split(":")[1] for line in by_name_step_lookups(source)],
                         ["3", "4", "8", "9", "10", "11"])

    def test_it_allows_marked_reads_and_other_names(self):
        source = "\n".join([
            "def ok(job, check, crates):",
            "    said = job['steps'][0].get('name')  # step-name: display",
            "    setup = [step.get('name') for step in job.get('steps')]  # step-name: classify",
            "    other = job.get('name'), check['name'], [crate.get('name') for crate in crates]",
            "    stamp = job['line'].split('\\t', 2)[2]",
            "    wrong = job['steps'][0]['name']  # step-name: placement",
            "    return said, setup, other, stamp, wrong"])
        self.assertEqual([line.split(":")[1] for line in by_name_step_lookups(source)], ["6"])



# failed_view is every comparator's one reader of a job log, head and base alike (#40542's seventh Codex BLOCK, F1, at
# 35f63387: signature() read a head's failing tests from its whole log, a base's from its failed sections, so a passing
# negative-case step's `✘ Test fake()` matched the base's real fake() failure and compare_window excused an unrelated
# new error in the step that failed). Detector for cmuxterm-hq docs/handbook/red-quoted-from-a-passing-step.md.
FAKE_ISSUE = "✘ Test fake() recorded an issue at FakeTests.swift:4:5: Expectation failed: refused as expected"
FAKE_FAILED = "✘ Test fake() failed after 0.001 seconds with 1 issue."
VIEW_STEPS = [("Negative cases", "success", 10, 12), ("Check", "failure", 20, 22)]
CRASH_11 = "error: Process '/tmp/t/swiftpm-testing-helper' exited with unexpected signal code 11"
CRASH_6 = "error: Process '/tmp/t/swiftpm-testing-helper' exited with unexpected signal code 6"
def ratchet(count):
    """The panic ratchet's RED block for one row of COUNT hits."""
    return ("rust-panic-ratchet: RED", f"cmux-core: clippy::unwrap_used {count} > baseline 3", "Fix the hit above")


def view_case(passing, failing):
    """(job, log) for a job whose passing "Negative cases" step prints PASSING and whose failing "Check" step prints
    FAILING, framed so step_owners places every line."""
    lines = [("Negative cases", 10, "##[group]Run python3 negative.py"),
             *(("Negative cases", 11, text) for text in passing),
             ("Check", 20, "##[group]Run scripts/check.sh"), *(("Check", 21, text) for text in failing),
             ("Check", 21, EXIT)]
    job = {"id": 1, "run_id": 10, "head_sha": HEAD, "name": "cmux-next static checks", "status": "completed",
           "conclusion": "failure", "steps": framed_steps(VIEW_STEPS)}
    return job, framed_log(lines, job["name"])


# The Codex repro: the head's passing step prints fake()'s failure (a negative case), its failing step a new error;
# the base's failing step really fails fake().
HEAD_FAKE_IN_PASSING = ((FAKE_ISSUE, FAKE_FAILED), (NEW_RED,))
BASE_FAKE_FAILS = (("ok: refused as expected",), (FAKE_ISSUE, FAKE_FAILED))
COMPARATORS = ("signature", "step_errors", "compare_window", "crash_signals", "ratchet_unmatched",
               "next_batch.expand_job")
# Every function of base_red_excuse.py that compares a head's red with a base's, or decides from a log's lines whether
# a red is excused: each reads failed_views alone (a FailedView parameter, never a raw log), and none places a line
# itself. A function with a FailedView parameter that is not here fails the scan too.
VIEW_COMPARATORS = frozenset({
    "signature", "step_errors", "section_lines", "compare_window", "crash_signals", "ratchet_red",
    "ratchet_unmatched", "package_tests", "guard_tests", "fixed_on_base", "guard_group", "quarantined_only",
    "ffi_pin_step_a", "validate_guard_routes", "judge", "view_text", "fixed_on_base_by_step", "step_evidence",
    "owned_unnamed"})
# The only readers of step_owners: failed_view (every comparator's) and failed_steps_log (what a comment shows, never
# compared).
STEP_OWNERS_READERS = frozenset({"failed_view", "failed_steps_log"})
# Every other function of base_red_excuse.py that takes a raw log (a parameter named log, *_log or *_logs), and why it
# may: it reads it into a failed_view, or only refuses, or reads evidence that is not a step's section. A new one fails
# the scan until it is listed here or reads a failed_view instead.
RAW_LOG_READERS = {
    "generated_stale_host": "only the shared generated-files check's own one error line, to name its host; compares nothing",
    "failed_view": "the one reader: the owned non-passed sections, or UNPLACED",
    "failed_steps_log": "what a comment shows; never compared",
    "step_owners": "the one placer of a line in a step, read by the two above alone",
    "lines_of": "a parser of log lines",
    "unplaced_signature": "an unplaced log's whole-log signature, compared only on identity (UnplacedSignature)",
    "refused_at_setup": "a gate: only refuses",
    "no_verdict": "a gate: a no-verdict compile is ignored only on another pass's proof (compile_pass_at)",
    "summary_red": "a gate: only refuses",
    "summary_no_verdict": "a gate: only refuses",
    "generated_no_verdict": "a gate: only refuses",
    "guard_red_steps": "a parser of the guard group's own verdict lines (guard_group: the head's from its failed_view)",
    "gallery_replay_crash": "the gallery health gate; the verdict compares gallery artifacts (gallery_classify)",
    "gallery_crash_verdict": "compares gallery health artifacts, per state, never log lines",
    "web_test_verdict": "per-test webview verdicts from run-webviews-tests.sh's own per-file blocks",
    "rollup_log_reds": "the rollup's `##[error]red check:` lines its annotations are made from, with its own count",
}
# The functions that read a log from GitHub: they hand it to failed_view, a gate or a per-test verdict above, and
# return no raw log to a comparator.
LOG_FETCHERS = frozenset({"lost_runner_log", "read_head", "base_evidence", "unplaced_base_evidence", "shared_generated_host", "pr_only_step_verdict", "guard_routes_view", "guard_group_report",
                          "web_test_verdict", "cut_short_web_verdict", "windows", "ws_check_verdict", "log"})
RAW_NAME = re.compile(r"^(?:\w+_)?logs?$")
# next_batch's expand_job may read its raw log only into these (keying a red as its own) and failed_view.
# unjudged: an unplaced log split by its echoes, no step judged (owned_unnamed; #41329's review follow-up F3).
NEXT_BATCH_RAW_SINKS = frozenset({"failed_view", "no_verdict", "read", "unjudged"})


def raw_log_reads(source, next_batch_source=None):
    """Each place in SOURCE (base_red_excuse.py) and NEXT_BATCH_SOURCE (next_batch.py) where a comparator could read
    a raw log, as `function: why`: a comparator with a raw-log parameter or name, or calling step_owners, a log read
    or failed_view itself; step_owners called outside STEP_OWNERS_READERS; a log read from GitHub outside
    LOG_FETCHERS; a function taking a FailedView not in VIEW_COMPARATORS; a raw-log parameter not in RAW_LOG_READERS;
    and next_batch's expand_job handing its raw log to anything but NEXT_BATCH_RAW_SINKS."""
    import ast
    found = []

    def called(node):
        func = node.func
        return func.id if isinstance(func, ast.Name) else func.attr if isinstance(func, ast.Attribute) else ""

    def params(fn):
        return [*fn.args.posonlyargs, *fn.args.args, *fn.args.kwonlyargs]

    functions = [node for node in ast.walk(ast.parse(source)) if isinstance(node, (ast.FunctionDef, ast.Lambda))
                 and isinstance(node, ast.FunctionDef)]
    names = {fn.name for fn in functions}
    for fn in functions:
        calls = [node for node in ast.walk(fn) if isinstance(node, ast.Call)]
        annotated = {arg.arg: ast.unparse(arg.annotation) for arg in params(fn) if arg.annotation is not None}
        if any("FailedView" in note for note in annotated.values()) and fn.name not in VIEW_COMPARATORS:
            found.append(f"{fn.name}: takes a FailedView but is not a listed comparator (VIEW_COMPARATORS)")
        if fn.name in VIEW_COMPARATORS:
            for arg in params(fn):
                if RAW_NAME.match(arg.arg):
                    found.append(f"{fn.name}: takes a raw log ({arg.arg})")
            for node in ast.walk(fn):
                if isinstance(node, ast.Name) and RAW_NAME.match(node.id):
                    found.append(f"{fn.name}: reads a raw log ({node.id}, line {node.lineno})")
            for node in calls:
                if called(node) in ("step_owners", "failed_steps_log", "failed_view", "lost_runner_log"):
                    found.append(f"{fn.name}: calls {called(node)} (line {node.lineno}); a comparator reads the "
                                 "failed_view it is given")
        elif fn.name not in RAW_LOG_READERS and fn.name not in LOG_FETCHERS:
            for arg in params(fn):
                if RAW_NAME.match(arg.arg):
                    found.append(f"{fn.name}: takes a raw log ({arg.arg}) and is no listed reader (RAW_LOG_READERS)")
        for node in calls:
            if called(node) == "step_owners" and fn.name not in STEP_OWNERS_READERS:
                found.append(f"{fn.name}: calls step_owners (line {node.lineno}); only failed_view places lines for "
                             "a comparator")
            if (isinstance(node.func, ast.Attribute) and node.func.attr == "log" and len(node.args) == 2
                    and fn.name not in LOG_FETCHERS):
                found.append(f"{fn.name}: reads a log from GitHub (line {node.lineno}) outside LOG_FETCHERS")
    for listed in sorted((VIEW_COMPARATORS | STEP_OWNERS_READERS | RAW_LOG_READERS.keys()) - names):
        found.append(f"{listed}: listed, but no such function")
    if next_batch_source is not None:
        tree = ast.parse(next_batch_source)
        expand = next(node for node in ast.walk(tree) if isinstance(node, ast.FunctionDef)
                      and node.name == "expand_job")
        parents = {child: parent for parent in ast.walk(expand) for child in ast.iter_child_nodes(parent)}
        for node in ast.walk(expand):
            if isinstance(node, ast.Call) and called(node) == "step_owners":
                found.append(f"next_batch.expand_job: calls step_owners (line {node.lineno})")
            if not (isinstance(node, ast.Name) and RAW_NAME.match(node.id) and isinstance(node.ctx, ast.Load)):
                continue
            parent = parents.get(node)
            if isinstance(parent, ast.Compare) and any(isinstance(c, ast.Constant) and c.value is None
                                                       for c in parent.comparators):
                continue  # `log is None`
            if isinstance(parent, ast.Attribute) and parent.attr == "strip":
                continue  # `not log.strip()`
            if isinstance(parent, ast.Call) and node in parent.args and called(parent) in NEXT_BATCH_RAW_SINKS:
                continue
            found.append(f"next_batch.expand_job: reads its raw log (line {node.lineno}) outside failed_view and "
                         "the own-red keys")
    return found


# Every call that reads a log through failed_view names its role, `base=`, which has no default anywhere on the way:
# failed_view itself, and next_batch's expand_job and failed_jobs, which hand theirs on (ROLE_PASSERS). Each other
# caller is listed with the role of each of its calls, in source order, by where that call's log comes from: a base
# run's log is evidence (True: its FAILED sections alone), a head's or a stack's is its red (False: FAILED and
# ERRORED). The follow-up to #40542's Codex F1 at 8dc7e0dc: next_batch read every base run with failed_view's default
# head role, so a base's ERRORED continue-on-error section was base evidence and next-batch said "no new failures" for
# a red judge() refuses. A missing role, a default, a role that is not a literal, or a caller not listed fails the scan.
ROLE_READERS = {"failed_view", "expand_job", "failed_jobs"}
ROLE_PASSERS = {("next_batch", "failed_jobs"): "hands its run's role to expand_job",
                ("next_batch", "expand_job"): "hands its job's role to failed_view"}
ROLES = {
    ("base_red_excuse", "read_head"): (False,),  # the head's red job
    ("base_red_excuse", "guard_routes_view"): (False,),  # validate_guard_routes: the head's routed rollup guard
    ("base_red_excuse", "base_evidence"): (True,),  # a compared base run's job
    ("next_batch", "probe_base"): (True, True),  # the base probe's run, then its rerun
    ("next_batch", "failing_on_base"): (True,),  # the base's newest push run
    ("next_batch", "base_tier_failures"): (True,),  # the base tier's runs
    ("next_batch", "validate"): (False, False),  # the stack's heavy tier run, then its rerun
    ("next_batch", "judge_web"): (False, True),  # the stack's web run, then the base's
}


def role_reads(sources):
    """Each failed_view role that does not follow its log in SOURCES ({module: source}), as `module.function: why`:
    a ROLE_READERS function whose `base` is not keyword-only with no default, a call to one with no `base=`, with a
    role that is not a literal True or False (except a ROLE_PASSERS function handing on its own `base`), with a role
    ROLES does not list for its caller in that order, or from a caller ROLES does not list."""
    import ast
    found, seen = [], set()
    for module, source in sources.items():
        tree = ast.parse(source)
        for fn in ast.walk(tree):
            if not isinstance(fn, ast.FunctionDef):
                continue
            where = f"{module}.{fn.name}"
            if fn.name in ROLE_READERS:
                kwonly = {arg.arg: default for arg, default in zip(fn.args.kwonlyargs, fn.args.kw_defaults)}
                if "base" not in kwonly:
                    found.append(f"{where}: its role `base` is not a keyword-only parameter")
                elif kwonly["base"] is not None:
                    found.append(f"{where}: its role `base` has a default ({ast.unparse(kwonly['base'])}); every "
                                 "caller must choose head or base")
            calls = [node for node in ast.walk(fn) if isinstance(node, ast.Call)
                     and (node.func.id if isinstance(node.func, ast.Name) else
                          node.func.attr if isinstance(node.func, ast.Attribute) else "") in ROLE_READERS]
            # Nested functions are walked on their own: a call belongs to its innermost function.
            inner = {id(node) for sub in ast.walk(fn) if sub is not fn and isinstance(sub, ast.FunctionDef)
                     for node in ast.walk(sub)}
            calls = sorted((call for call in calls if id(call) not in inner),
                           key=lambda call: (call.lineno, call.col_offset))
            if not calls:
                continue
            roles = []
            for call in calls:
                role = next((kw.value for kw in call.keywords if kw.arg == "base"), None)
                if role is None:
                    found.append(f"{where}: calls a failed_view reader with no role (line {call.lineno}); pass "
                                 "base=True for a base run's log, base=False for a head's or a stack's")
                    roles.append(None)
                elif isinstance(role, ast.Constant) and isinstance(role.value, bool):
                    roles.append(role.value)
                elif (module, fn.name) in ROLE_PASSERS and isinstance(role, ast.Name) and role.id == "base":
                    roles.append("passed")
                else:
                    found.append(f"{where}: a role that is not a literal True or False (line {call.lineno}: "
                                 f"base={ast.unparse(role)})")
                    roles.append(None)
            if (module, fn.name) in ROLE_PASSERS:
                if any(role != "passed" for role in roles):
                    found.append(f"{where}: hands on a role that is not its own `base` ({roles})")
                seen.add((module, fn.name))
                continue
            if (module, fn.name) not in ROLES:
                found.append(f"{where}: reads a log through failed_view but is no listed caller (ROLES): name the "
                             "role of each of its calls by where its log comes from")
                continue
            seen.add((module, fn.name))
            if tuple(roles) != ROLES[(module, fn.name)]:
                found.append(f"{where}: roles {tuple(roles)} where its logs' sources give "
                             f"{ROLES[(module, fn.name)]} (True: a base run's, False: a head's or a stack's)")
    for module, name in sorted((ROLES.keys() | ROLE_PASSERS.keys()) - seen):
        found.append(f"{module}.{name}: listed in ROLES, but it makes no such call")
    return found


UNPLACED_CHECKS = "cmux-next checks (god files, concurrency, crash safety, l10n)"
UNPLACED_CHECKS_STEP = "Fail on any red check"
UNPLACED_KIT = "CmuxMobileKit tests (macOS swift test, iOS simulator)"
UNPLACED_KIT_STEP = "swift test (macOS)"


def unplaced_log(job, step, *lines):
    """A failed step's log as a composite action prints it: its own `Run` header and an inner one, so step_owners
    cannot place it (two STEP_START lines in one step) and failed_view is UNPLACED."""
    return log(job, step, "##[group]Run ./.github/actions/run-checks", "##[endgroup]",
               "##[group]Run python3 scripts/ci/run.py", "##[endgroup]", *lines,
               "##[error]Process completed with exit code 1.")


class UnplacedGitHub(FakeGitHub):
    """Head job 1 (run 10) and the newest base job 2 (run 20) of one job whose logs step_owners cannot place."""

    def __init__(self, name, step, head_lines, base_lines, base_conclusion="failure"):
        super().__init__()
        self.jobs = {1: failed_job(1, 10, HEAD, name=name, step=step),
                     2: dict(failed_job(2, 20, BASE_SHA, name=name, step=step), conclusion=base_conclusion)}
        self.logs = {1: unplaced_log(name, step, *head_lines), 2: unplaced_log(name, step, *base_lines)}


class PrOnlyStepGitHub(FakeGitHub):
    """cmux#41046 at b329575b: head 'cmux-next daemon tests' (job 1, run 10) fails its live suites and 'Regenerate
    stale files'; the base's newest verdict of the job (job 2, run 20) fails the live suites and skips the
    regeneration; the base tier (job 3, run 21) fails 'Regenerate stale files' in 'cmux-next generated files'."""

    DAEMON, GEN, SHARED = "cmux-next daemon tests", "cmux-next generated files", excuse.GENERATED_VERDICT_JOB
    LIVE, REGEN = "Run the live-daemon suites", "Regenerate stale files"
    QUIT = "✘ Test keepLeavesTheDaemon() failed after 1.000 seconds with 1 issue."
    MENU = ("✘ Test everyMenuKeepsAShortTopLevel() recorded an issue at ActionSurfaceParityTests.swift:107:13: "
            "Expectation failed: (rows.count → 14) <= (cap → 13)",
            "✘ Test everyMenuKeepsAShortTopLevel() failed after 0.559 seconds with 1 issue.",
            "##[error]the action exports could not be regenerated")

    def __init__(self, menu=MENU, base_regen=None, shared=True, gen_menu=MENU):
        super().__init__()

        def job(job_id, run, sha, name, steps):
            return {"id": job_id, "run_id": run, "head_sha": sha, "name": name, "status": "completed",
                    "conclusion": "failure", "steps": [{"name": "Set up runner", "status": "completed",
                                                         "conclusion": "success"}]
                    + [{"name": step, "status": "completed", "conclusion": state} for step, state in steps]}
        self.jobs = {1: job(1, 10, HEAD, self.DAEMON, [(self.LIVE, "failure"), (self.REGEN, "failure")]),
                     2: job(2, 20, BASE_SHA, self.DAEMON, [(self.LIVE, "failure"), (self.REGEN, base_regen)]),
                     3: job(3, 21, BASE_SHA, self.GEN, [(self.REGEN, "failure")])}
        self.logs = {1: unplaced_log(self.DAEMON, self.LIVE, self.QUIT) + "\n" + log(self.DAEMON, self.REGEN, *menu),
                     2: unplaced_log(self.DAEMON, self.LIVE, self.QUIT),
                     3: log(self.GEN, self.REGEN, *gen_menu)}
        if shared:
            self.jobs[4] = job(4, 10, HEAD, self.SHARED, [("Read the generated files verdict of the shared build",
                                                           "failure")])
            self.logs[4] = log(self.SHARED, "Read the generated files verdict of the shared build",
                               "##[error]Generated cmux-next files are stale. daemon-test's step summary says how to "
                               "regenerate them; its cmux-next-generated-patch artifact holds the regenerated files.",
                               "##[error]Process completed with exit code 1.")
        self.base_runs = [{"id": 21, "event": "workflow_dispatch", "head_branch": "feat-cmux-next",
                           "status": "completed", "conclusion": "failure", "head_sha": BASE_SHA,
                           "created_at": "2026-11-11T07:02:30Z"},
                          {"id": 20, "event": "workflow_dispatch", "head_branch": "feat-cmux-next",
                           "status": "completed", "conclusion": "failure", "head_sha": BASE_SHA,
                           "created_at": "2026-11-11T06:58:50Z"}]


class PrOnlyStepsAreExcusedByAnotherBaseJob(unittest.TestCase):
    """2026-11-11: a pull request's 'cmux-next daemon tests' runs 'Regenerate stale files', which base pushes run in
    'cmux-next generated files' instead; its only red there was the base's everyMenuKeepsAShortTopLevel()."""

    def judge(self, github):
        return "\n".join(excuse.judge(REPO, "feat-cmux-next", HEAD, [10], github))

    def test_a_step_the_base_job_skips_failing_only_another_base_jobs_tests_is_excused(self):
        said = self.judge(PrOnlyStepGitHub())
        self.assertIn("never run in feat-cmux-next run 20's 'cmux-next daemon tests'", said)
        self.assertIn("everyMenuKeepsAShortTopLevel()", said)
        self.assertIn("run 21's 'cmux-next generated files'", said)
        # The shared check's stale verdict is its host's, excused with it.
        self.assertIn(f"excused '{excuse.GENERATED_VERDICT_JOB}': its one red is the 'stale' verdict", said)

    def test_a_green_base_verdict_that_skipped_the_step_still_excuses_it(self):
        # The deadlock (cmux#41086, #40991 on 2026-11-11): the base's daemon job passed and skipped 'Regenerate stale
        # files'; the head failed only that step, on the base tier's menu-cap test.
        github = PrOnlyStepGitHub()
        github.jobs[1]["steps"] = [step for step in github.jobs[1]["steps"] if step["name"] != PrOnlyStepGitHub.LIVE]
        github.logs[1] = unplaced_log(PrOnlyStepGitHub.DAEMON, PrOnlyStepGitHub.REGEN, *PrOnlyStepGitHub.MENU)
        github.jobs[2] = dict(github.jobs[2], conclusion="success",
                              steps=[dict(step, conclusion="success" if step["name"] == PrOnlyStepGitHub.LIVE
                                          else step["conclusion"]) for step in github.jobs[2]["steps"]])
        github.base_runs[1]["conclusion"] = "success"
        said = self.judge(github)
        self.assertIn("never run in feat-cmux-next run 20's", said)
        # A head red in a step the green verdict ran is the PR's own.
        github.jobs[1]["steps"].append({"name": PrOnlyStepGitHub.LIVE, "status": "completed", "conclusion": "failure"})
        github.logs[1] += "\n" + log(PrOnlyStepGitHub.DAEMON, PrOnlyStepGitHub.LIVE, PrOnlyStepGitHub.QUIT)
        with self.assertRaises(excuse.Refused):
            self.judge(github)

    def test_a_test_no_base_job_fails_is_the_prs_own(self):
        mine = ("✘ Test aNewMenuTest() failed after 0.100 seconds with 1 issue.",) + PrOnlyStepGitHub.MENU
        with self.assertRaisesRegex(excuse.Refused, "compared whole"):
            self.judge(PrOnlyStepGitHub(menu=mine))

    def test_an_error_line_no_base_job_prints_is_the_prs_own(self):
        mine = PrOnlyStepGitHub.MENU + ("##[error]a new export error",)
        with self.assertRaisesRegex(excuse.Refused, "compared whole"):
            self.judge(PrOnlyStepGitHub(menu=mine))

    def test_a_step_the_base_job_ran_and_passed_is_the_prs_own(self):
        with self.assertRaisesRegex(excuse.Refused, "compared whole"):
            self.judge(PrOnlyStepGitHub(base_regen="success"))

    def test_without_a_failing_test_nothing_is_matched(self):
        # Matching test IDs only: an extra step whose red names no test is never excused by another job.
        only = ("##[error]the action exports could not be regenerated",)
        with self.assertRaisesRegex(excuse.Refused, "compared whole"):
            self.judge(PrOnlyStepGitHub(menu=only, gen_menu=only))

    def test_a_base_red_from_before_a_newer_pass_of_that_job_never_counts(self):
        # #41253's review: once base fixes the menu cap ('cmux-next generated files' passes in a newer run), its older
        # red must not excuse a PR that breaks the menu again.
        github = PrOnlyStepGitHub()
        github.jobs[5] = {"id": 5, "run_id": 22, "head_sha": BASE_SHA, "name": PrOnlyStepGitHub.GEN,
                          "status": "completed", "conclusion": "success",
                          "steps": [{"name": PrOnlyStepGitHub.REGEN, "status": "completed", "conclusion": "success"}]}
        github.base_runs.insert(0, {"id": 22, "event": "workflow_dispatch", "head_branch": "feat-cmux-next",
                                    "status": "completed", "conclusion": "success", "head_sha": BASE_SHA,
                                    "created_at": "2026-11-11T07:10:00Z"})
        with self.assertRaisesRegex(excuse.Refused, "compared whole"):
            self.judge(github)

    def test_a_head_log_that_says_tests_failed_unnamed_is_the_prs_own(self):
        # #41253's review: a runner line saying tests failed with none named could hide a red no test ID matches.
        # The shared reading (test_reds.read, #41244) refuses it first, before the PR-only step reading is reached.
        with self.assertRaisesRegex(excuse.Refused, "names none|a failure no parser names is never a base red"):
            self.judge(PrOnlyStepGitHub(menu=PrOnlyStepGitHub.MENU + (" 1 fail",)))

    def test_a_stale_shared_check_without_an_excused_host_is_not_excused_by_it(self):
        github = PrOnlyStepGitHub(menu=("✘ Test aNewMenuTest() failed after 0.100 seconds with 1 issue.",))
        with self.assertRaises(excuse.Refused) as caught:
            self.judge(github)
        self.assertNotIn("its one red is the 'stale' verdict", str(caught.exception))
        self.assertIsNone(excuse.generated_stale_host("##[error]The action catalog checks fail on daemon-test"))


class UnplacedLogsAreComparedWhole(unittest.TestCase):
    """2026-11-11: every red in 'cmux-next checks' (cmux#40954) and the CmuxMobileKit tests (cmux#40598 at ea17b848,
    #40664 at bec7c32b) was refused because a composite action's log does not map onto its steps. Compared whole,
    such a red is excused only when the newest base verdict fails with exactly its failed steps, failing tests and
    error lines; anything only the head prints is the PR's own."""

    def judge(self, github):
        return "\n".join(excuse.judge(REPO, "feat-cmux-next", HEAD, [10], github))

    def test_the_log_is_unplaced(self):
        github = UnplacedGitHub(UNPLACED_CHECKS, UNPLACED_CHECKS_STEP, ["##[error]red check: x"], [])
        job = copy.deepcopy(github.jobs[1])
        self.assertIs(excuse.failed_view(job, github.log(REPO, job), base=False, **UNKNOWN), excuse.UNPLACED)

    def test_the_checks_jobs_red_the_base_shares_is_excused(self):
        red = ["##[error]raw colour outside the tokens", "##[error]red check: Motion and colour tokens"]
        said = self.judge(UnplacedGitHub(UNPLACED_CHECKS, UNPLACED_CHECKS_STEP, red, red))
        self.assertIn(f"excused '{UNPLACED_CHECKS}': its log does not map onto its steps, so it was compared whole", said)
        self.assertIn("red check: Motion and colour tokens", said)

    def window(self, head, *bases):
        """UnplacedGitHub whose base has the red verdicts BASES (lines, or "green"), newest first, an hour apart."""
        github = UnplacedGitHub(UNPLACED_KIT, UNPLACED_KIT_STEP, head, [])
        github.base_runs = []
        for n, lines in enumerate(bases):
            run = 30 - n
            green = lines == "green"
            github.base_runs.append({"id": run, "event": "push", "head_branch": "feat-cmux-next",
                                     "status": "completed", "conclusion": "success" if green else "failure",
                                     "head_sha": BASE_SHA, "created_at": f"2026-11-11T{12 - n:02d}:00:00Z"})
            job = failed_job(run, run, BASE_SHA, name=UNPLACED_KIT, step=UNPLACED_KIT_STEP)
            github.jobs[run] = dict(job, conclusion="success") if green else job
            github.logs[run] = unplaced_log(UNPLACED_KIT, UNPLACED_KIT_STEP, *([] if green else lines))
        del github.jobs[2], github.logs[2]
        return github

    def test_identity_with_an_older_red_verdict_of_the_window_is_excused(self):
        # cmux#41086 at 5d0fb077: the newest base run failed one more test (a flake) than the head.
        head = ["✘ Test reconnectsAfterSleep() failed after 1.000 seconds with 1 issue."]
        flake = ["✘ Test aFlakyGateStalls() failed after 9.000 seconds with 1 issue."]
        said = self.judge(self.window(head, head + flake, head))
        self.assertIn("compared whole", said)
        self.assertIn("run 29", said)

    def test_the_window_never_mixes_verdicts_and_a_green_one_ends_it(self):
        head = ["✘ Test reconnectsAfterSleep() failed after 1.000 seconds with 1 issue.",
                "✘ Test aFlakyGateStalls() failed after 9.000 seconds with 1 issue."]
        # Each half on another verdict is no verdict with both.
        with self.assertRaisesRegex(excuse.Refused, "compared whole"):
            self.judge(self.window(head, head[:1], head[1:]))
        with self.assertRaisesRegex(excuse.Refused, "compared whole"):
            self.judge(self.window(head, head[:1], "green", head))

    def test_an_unplaced_app_ffi_pin_red_is_never_excused_whole(self):
        # The pin's rules read the PR's paths (a PR that moves the pin or edits its check is refused): identical masked
        # lines on both sides are no proof, since the pinned sha is masked. So the pin rules are asked (they read the
        # PR's files: this fake has none to give), never the whole-log identity.
        red = ["##[error]red check: Check the app FFI pin",
               "error: the app FFI sources changed since the pinned source 6e1be83c512fc8d963a241da9d389cd95f48ac30:"]
        asked = []

        def pr_paths(*args):
            asked.append(args)
            raise excuse.Refused("no PR files")
        with unittest.mock.patch.object(excuse, "pr_paths", pr_paths), \
                self.assertRaisesRegex(excuse.Refused, "no PR files"):
            self.judge(UnplacedGitHub(UNPLACED_CHECKS, UNPLACED_CHECKS_STEP, red, red))
        self.assertEqual(len(asked), 1)

    def test_a_compiler_warnings_quoted_source_is_no_error_line(self):
        # cmux#41046: the base's build quoted a warning's source 11 times, the head's 6.
        quote = ["53 |     static func interrupted(_ error: Error) -> Bool {",
                 "   |                                      `- warning: use of protocol 'Error' as a type"]
        red = ["✘ Test reconnectsAfterSleep() failed after 1.000 seconds with 1 issue."]
        said = self.judge(UnplacedGitHub(UNPLACED_KIT, UNPLACED_KIT_STEP, quote + red, quote * 2 + red))
        self.assertIn("compared whole", said)

    def test_the_daemon_tests_live_suites_red_the_base_shares_is_excused(self):
        # cmux#40598 at b22f9eff (run 42972264329): 'Run the live-daemon suites' red the same way on base run
        # 42976173821; the daemon job's log is unplaced.
        daemon, live = "cmux-next daemon tests", "Run the live-daemon suites"
        red = ["✘ Test keepLeavesTheDaemonAndTerminalsForTheNextLaunch() recorded an issue at "
               "QuitSessionsTests.swift:18:13: Expectation failed: (hosts.count → 2) == 1",
               "✘ Test keepLeavesTheDaemonAndTerminalsForTheNextLaunch() failed after 205.578 seconds with 1 issue.",
               "✘ Test endTerminalsShutdownRepliesOnTheSubscribedSocket() failed after 1.746 seconds with 1 issue.",
               "##[error]2 red tests: keepLeavesTheDaemonAndTerminalsForTheNextLaunch() QuitSessionsTests.swift:18; "
               "endTerminalsShutdownRepliesOnTheSubscribedSocket() BranchTeardownTests.swift:59"]
        said = self.judge(UnplacedGitHub(daemon, live, red, red))
        self.assertIn(f"excused '{daemon}': its log does not map onto its steps, so it was compared whole", said)
        # One more failing test on the head is its own.
        mine = red + ["✘ Test aNewDaemonTest() failed after 1.000 seconds with 1 issue."]
        with self.assertRaisesRegex(excuse.Refused, "more on this head: .*aNewDaemonTest"):
            self.judge(UnplacedGitHub(daemon, live, mine, red))

    def test_tests_that_differ_only_in_a_digit_are_different_tests(self):
        head = ["✘ Test test2() failed after 1.000 seconds with 1 issue."]
        base = ["✘ Test test3() failed after 1.000 seconds with 1 issue."]
        with self.assertRaisesRegex(excuse.Refused, "failing tests are not .*more on this head: test2"):
            self.judge(UnplacedGitHub(UNPLACED_KIT, UNPLACED_KIT_STEP, head, base))
        # Timings still match: the same test failing after another time is the same test.
        said = self.judge(UnplacedGitHub(UNPLACED_KIT, UNPLACED_KIT_STEP, head,
                                         ["✘ Test test2() failed after 7.250 seconds with 1 issue."]))
        self.assertIn("compared whole", said)

    def test_a_new_check_red_beside_the_bases_is_the_prs_own(self):
        base = ["##[error]red check: Scrollbars thin, one style"]
        head = base + ["##[error]raw colour outside the tokens", "##[error]red check: Motion and colour tokens"]
        with self.assertRaisesRegex(excuse.Refused, r"compared whole, its error lines are not feat-cmux-next run 20.*"
                                    r"more on this head: .*Motion and colour tokens"):
            self.judge(UnplacedGitHub(UNPLACED_CHECKS, UNPLACED_CHECKS_STEP, head, base))

    def test_a_different_check_red_is_the_prs_own(self):
        with self.assertRaisesRegex(excuse.Refused, "more on this head: .*Motion and colour tokens; more on the base"):
            self.judge(UnplacedGitHub(UNPLACED_CHECKS, UNPLACED_CHECKS_STEP,
                                      ["##[error]red check: Motion and colour tokens"],
                                      ["##[error]red check: Scrollbars thin, one style"]))

    def test_the_kit_tests_the_base_fails_too_are_excused(self):
        red = ["✘ Test silentDropDetectionBenchmark() failed after 16.970 seconds with 1 issue."]
        said = self.judge(UnplacedGitHub(UNPLACED_KIT, UNPLACED_KIT_STEP, red, red))
        self.assertIn(f"excused '{UNPLACED_KIT}'", said)
        self.assertIn("silentDropDetectionBenchmark", said)

    def test_a_kit_test_only_the_head_fails_is_the_prs_own(self):
        base = ["✘ Test silentDropDetectionBenchmark() failed after 16.970 seconds with 1 issue."]
        head = base + ["✘ Test reconnectsAfterSleep() failed after 2.100 seconds with 1 issue."]
        with self.assertRaisesRegex(excuse.Refused, "its failing tests are not .*more on this head: .*reconnectsAfterSleep"):
            self.judge(UnplacedGitHub(UNPLACED_KIT, UNPLACED_KIT_STEP, head, base))

    def test_review_41129_f1_a_ratchet_row_counts_in_the_whole_comparison(self):
        # #41129's review at c15725ea: the ratchet's summary error is the same at any count, so 693 at the head was
        # excused against 692 at the base. Its RED rows are compared word for word.
        def ratchet(count):
            return [excuse.RATCHET_RED, f"acpmux: clippy::indexing_slicing {count} > baseline 686",
                    "src/lib.rs:12:5", "Fix the hit or raise the baseline",
                    "##[error]the panic ratchet is red for acpmux; its log above names each new hit"]
        with self.assertRaisesRegex(excuse.Refused, "more on this head: .*indexing_slicing 693"):
            self.judge(UnplacedGitHub(UNPLACED_CHECKS, UNPLACED_CHECKS_STEP, ratchet(693), ratchet(692)))
        self.assertIn("compared whole", self.judge(UnplacedGitHub(UNPLACED_CHECKS, UNPLACED_CHECKS_STEP,
                                                                  ratchet(693), ratchet(693))))

    def test_review_41129_f2_every_xcodebuild_listing_entry_counts(self):
        # #41129's review at c15725ea: names under `Failing tests:` were counted once however often listed.
        listing = ["Failing tests:", "KitTests.reconnectsAfterSleep()"]

        def kit(head, base):
            github = UnplacedGitHub(UNPLACED_KIT, UNPLACED_KIT_STEP, head, base)
            # xcodebuild indents each entry with a tab, which the framed fixture log cannot carry: added as read.
            framed = github.log
            github.log = lambda repo, job: framed(repo, job).replace("Z KitTests.", "Z \tKitTests.")
            return github
        with self.assertRaisesRegex(excuse.Refused, "failing tests are not .*more on this head: .*reconnectsAfterSleep"):
            self.judge(kit(listing + ["** TEST FAILED **"] + listing, listing))
        self.assertIn("compared whole", self.judge(kit(listing, listing)))

    def test_review_41158_f2_an_xcresult_line_and_each_listing_entry_both_count(self):
        # #41158's review F2: a listing entry counted only when no line named its test alone, so with an xcresult
        # `FAILED:` line naming it, two listings at the head matched the base's one.
        failed = ["FAILED: CmuxMobileKit / KitTests / KitTests / reconnectsAfterSleep()"]
        listing = ["Failing tests:", "KitTests.reconnectsAfterSleep()"]

        def kit(head, base):
            github = UnplacedGitHub(UNPLACED_KIT, UNPLACED_KIT_STEP, head, base)
            framed = github.log  # xcodebuild's tab before each entry, as in the #41129 F2 test above
            github.log = lambda repo, job: framed(repo, job).replace("Z KitTests.", "Z \tKitTests.")
            return github
        with self.assertRaisesRegex(excuse.Refused, "failing tests are not .*more on this head: .*reconnectsAfterSleep"):
            self.judge(kit(failed + listing + ["** TEST FAILED **"] + listing, failed + listing))
        self.assertIn("compared whole", self.judge(kit(failed + listing, failed + listing)))

    def test_review_41158_f1_bun_failures_are_named_in_a_whole_log_comparison(self):
        # #41158's review F1: failed_names read no bun `(fail)` line, so a new head failure and an unrelated base
        # flake, both under one `expect()` headline, gave empty test counters and the same error lines: excused.
        def bun(test):
            return ["bun test v1.3.0", "test/agent-pane.test.tsx:", "error: expect(received).toBe(expected)",
                    "Expected: true", "Received: false", f"(fail) agent pane > {test} [1.20ms]", " 0 pass", " 1 fail"]
        with self.assertRaisesRegex(excuse.Refused, "failing tests are not .*more on this head: .*keeps its draft"):
            self.judge(UnplacedGitHub(UNPLACED_KIT, UNPLACED_KIT_STEP, bun("keeps its draft"), bun("scrolls to end")))
        self.assertIn("compared whole", self.judge(UnplacedGitHub(UNPLACED_KIT, UNPLACED_KIT_STEP,
                                                                  bun("keeps its draft"), bun("keeps its draft"))))

    def test_review_41158_f1_a_failure_count_no_test_is_named_by_is_never_compared_whole(self):
        # The rest of #41158's review F1: a runner that says tests failed and whose failures no parser names leaves
        # nothing to tell them apart, so the whole-log fallback refuses rather than excuse on the error lines alone.
        for marker in (" 2 fail", "FAIL test/agent-pane.test.tsx (limit 120s)", "test result: FAILED. 3 passed; 1 failed",
                       "FAILED (failures=1)", "Executed 4 tests, with 1 failure (0 unexpected) in 0.2 (0.3) seconds"):
            with self.subTest(marker=marker):
                said = ["error: expect(received).toBe(expected)", marker]
                with self.assertRaisesRegex(excuse.Refused, "reports more failing tests than it names"):
                    self.judge(UnplacedGitHub(UNPLACED_KIT, UNPLACED_KIT_STEP, said, said))

    def test_a_base_that_fails_more_is_not_enough_either(self):
        # Identity, never a subset: the comparison is the whole log, so what the base fails besides is not proof the
        # head's failures are only those (a red the base hides could be the PR's).
        head = ["✘ Test silentDropDetectionBenchmark() failed after 16.970 seconds with 1 issue."]
        base = head + ["✘ Test reconnectsAfterSleep() failed after 2.100 seconds with 1 issue."]
        with self.assertRaisesRegex(excuse.Refused, "more on the base: .*reconnectsAfterSleep"):
            self.judge(UnplacedGitHub(UNPLACED_KIT, UNPLACED_KIT_STEP, head, base))

    def test_another_failed_step_is_the_prs_own(self):
        github = UnplacedGitHub(UNPLACED_KIT, UNPLACED_KIT_STEP, ["##[error]x"], ["##[error]x"])
        github.jobs[2]["steps"][2]["name"] = "xcodebuild test (iOS simulator)"
        with self.assertRaisesRegex(excuse.Refused, r"its failed steps \(swift test \(macOS\) \(failure\)\) are not"):
            self.judge(github)

    def test_review_41158_f1_a_failed_step_is_keyed_by_name_and_conclusion_with_counts(self):
        # #41158's review F1: failed steps were a set of names, so a cancelled step matched the base's failure and a
        # step that failed twice matched the base's one.
        red = ["✘ Test reconnectsAfterSleep() failed after 1.000 seconds with 1 issue."]
        cancelled = UnplacedGitHub(UNPLACED_KIT, UNPLACED_KIT_STEP, red, red)
        cancelled.jobs[1]["steps"][2]["conclusion"] = "cancelled"
        with self.assertRaisesRegex(excuse.Refused, r"its failed steps \(swift test \(macOS\) \(cancelled\)\) are not "
                                                    r".*\(swift test \(macOS\) \(failure\)\)"):
            self.judge(cancelled)
        twice = UnplacedGitHub(UNPLACED_KIT, UNPLACED_KIT_STEP, red, red)
        twice.jobs[1]["steps"].append(dict(twice.jobs[1]["steps"][2]))
        with self.assertRaisesRegex(excuse.Refused, r"its failed steps \(swift test \(macOS\) \(failure\) x2\) are not"):
            self.judge(twice)
        # The same steps, conclusions and counts are still excused.
        self.assertIn("swift test (macOS) (failure)", self.judge(UnplacedGitHub(UNPLACED_KIT, UNPLACED_KIT_STEP, red, red)))

    def test_a_line_the_base_printed_from_a_passing_step_is_still_new_in_the_failing_one(self):
        # #40542's Codex BLOCK, whole: the base's passing negative case prints the error the head's failing step now
        # prints too. As sets the two logs match; counted, the head prints it once more, and is refused.
        negative = "##[error]error: Sources/New.swift:3: cannot find 'x' in scope"
        base = [negative, "##[error]red check: Scrollbars thin, one style"]
        with self.assertRaisesRegex(excuse.Refused, "error lines are not .*more on this head: .*New.swift"):
            self.judge(UnplacedGitHub(UNPLACED_CHECKS, UNPLACED_CHECKS_STEP, base + [negative], base))

    def test_a_red_that_names_nothing_is_refused(self):
        with self.assertRaisesRegex(excuse.Refused, "names no failing test or error line"):
            self.judge(UnplacedGitHub(UNPLACED_KIT, UNPLACED_KIT_STEP, ["just output"], ["just output"]))

    def test_the_scripts_echo_is_never_a_red(self):
        # The runner echoes each step's script: a `::error::` the script could print is not one it did.
        echo = ["##[group]Run echo \"::error::red check: Motion and colour tokens\"",
                "\x1b[36;1mecho \"::error::red check: Motion and colour tokens\"\x1b[0m",
                "shell: /usr/bin/bash -e {0}", "##[endgroup]"]
        red = ["##[error]red check: Scrollbars thin, one style"]
        said = self.judge(UnplacedGitHub(UNPLACED_CHECKS, UNPLACED_CHECKS_STEP, echo + red, red))
        self.assertIn("compared whole", said)


class FailedViewIsTheOnlyReader(unittest.TestCase):
    """failed_view is the one reader of a job log for every comparator, head and base alike, and the Codex repro of
    #40542's seventh BLOCK is refused."""

    SOURCE = (ROOT / "scripts/ci/base_red_excuse.py").read_text()
    NEXT_BATCH = (ROOT / "scripts/ci/next_batch.py").read_text()

    def test_codex_repro_a_passing_steps_failing_test_never_hides_a_new_error(self):
        # At 35f63387 the head's tests were read from its whole log: the passing negative case's fake() matched the
        # base's failing fake(), a failing test was "on the base", so its errors were never compared and the new
        # New.swift error in the step that failed was excused.
        github = FakeGitHub()
        head_job, head_log = view_case(*HEAD_FAKE_IN_PASSING)
        base_job, base_log = view_case(*BASE_FAKE_FAILS)
        github.jobs = {1: head_job, 2: dict(base_job, id=2, run_id=20, head_sha=BASE_SHA)}
        github.logs = {1: head_log, 2: base_log}
        with self.assertRaisesRegex(excuse.Refused, r"New\.swift"):
            excuse.judge(REPO, "feat-cmux-next", HEAD, [10], github)

    def test_the_same_red_on_both_sides_is_still_excused(self):
        github = FakeGitHub()
        head_job, head_log = view_case(*HEAD_FAKE_IN_PASSING)
        github.jobs = {1: head_job, 2: dict(copy.deepcopy(head_job), id=2, run_id=20, head_sha=BASE_SHA)}
        github.logs = {1: head_log, 2: head_log}
        self.assertIn("excused 'cmux-next static checks'", "\n".join(
            excuse.judge(REPO, "feat-cmux-next", HEAD, [10], github)))

    def test_a_head_view_and_a_base_view_never_hold_a_passing_steps_lines(self):
        job, text = view_case(*HEAD_FAKE_IN_PASSING)
        for base in (False, True):
            view = excuse.failed_view(job, text, base=base, **UNKNOWN)
            with self.subTest(base=base):
                self.assertNotIn("fake()", view.text())
                self.assertIn("New.swift", view.text())
                self.assertEqual(excuse.signature(view)[1], set())

    def test_no_comparator_reads_a_raw_log_or_places_a_line_itself(self):
        self.assertEqual(raw_log_reads(self.SOURCE, self.NEXT_BATCH), [])

    def test_every_failed_view_caller_names_the_role_its_log_has(self):
        self.assertEqual(role_reads({"base_red_excuse": self.SOURCE, "next_batch": self.NEXT_BATCH}), [])

    def test_a_reader_called_without_a_role_raises(self):
        job, text = view_case(*HEAD_FAKE_IN_PASSING)
        with self.assertRaises(TypeError):
            excuse.failed_view(job, text, **UNKNOWN)
        sys.path.insert(0, str(ROOT / "scripts/ci"))
        import next_batch
        controller = next_batch.Controller.__new__(next_batch.Controller)
        controller.job_log = lambda job_id: text
        with self.assertRaises(TypeError):
            controller.expand_job(job["name"], job["id"], job)
        with self.assertRaises(TypeError):
            controller.failed_jobs(1, detail=True)

    def test_the_role_scan_catches_a_wrong_or_missing_role(self):
        # Each fixture puts back a way a log is read with the wrong role: 8dc7e0dc's default head role on next_batch's
        # base reads, a base run read as a head's, a stack's read as a base's, a role that is not a literal, and a new
        # caller no list names.
        def mutated(source, old, new):
            self.assertEqual(source.count(old), 1, old)
            return source.replace(old, new)
        excuse_source, batch = self.SOURCE, self.NEXT_BATCH
        fixtures = {
            "failed_view's default role is back (8dc7e0dc)": (
                mutated(excuse_source, "*, step_names, base: bool) ->", "*, step_names, base: bool = False) ->"),
                batch, "base_red_excuse.failed_view: its role `base` has a default"),
            "expand_job's role has a default": (
                excuse_source, mutated(batch, "job: dict | None = None, *, base: bool)",
                                       "job: dict | None = None, *, base: bool = False)"),
                "next_batch.expand_job: its role `base` has a default"),
            "a base run read with no role": (
                excuse_source, mutated(batch, 'OUTRIGHT_RED, detail=True, base=True)', "OUTRIGHT_RED, detail=True)"),
                "next_batch.failing_on_base: calls a failed_view reader with no role"),
            "the base's web run read as the stack's": (
                excuse_source, mutated(batch, 'failed_jobs(base[0]["id"], detail=True, base=True)',
                                       'failed_jobs(base[0]["id"], detail=True, base=False)'),
                "next_batch.judge_web: roles (False, False)"),
            "the base tier read as the stack's": (
                excuse_source, mutated(batch, 'expand_job(name, job["id"], job, base=True)',
                                       'expand_job(name, job["id"], job, base=False)'),
                "next_batch.base_tier_failures: roles (False,)"),
            "a base job read as the head's": (
                mutated(excuse_source, 'path=run.get("path")),\n                       base=True)',
                        'path=run.get("path")),\n                       base=False)'),
                batch, "base_red_excuse.base_evidence: roles (False,)"),
            "the head read as a base": (
                mutated(excuse_source, "step_names=names, base=False)", "step_names=names, base=True)"),
                batch, "base_red_excuse.read_head: roles (True,)"),
            "a role that is not a literal": (
                excuse_source, mutated(batch, 'failed_jobs(run["id"], detail=True, base=False)',
                                       'failed_jobs(run["id"], detail=True, base=bool(run))'),
                "next_batch.judge_web: a role that is not a literal"),
            "a new unlisted caller": (
                excuse_source + "\n\ndef new_reader(job, text):\n"
                "    return failed_view(job, text, step_names=None, base=True)\n",
                batch, "base_red_excuse.new_reader: reads a log through failed_view but is no listed caller"),
        }
        for label, (source, next_batch, want) in fixtures.items():
            with self.subTest(fixture=label):
                said = role_reads({"base_red_excuse": source, "next_batch": next_batch})
                self.assertTrue(any(line.startswith(want) for line in said), said)

    def test_the_scan_catches_the_bug_reintroduced(self):
        # Each fixture puts back a way a comparator read a raw log: 35f63387's signature() reading a head's tests from
        # the whole log, a comparator placing lines itself, judge() reading a log, next_batch keying a raw log, and a
        # new reader no list names.
        def mutated(old, new, source=None):
            source = self.SOURCE if source is None else source
            self.assertEqual(source.count(old), 1, old)
            return source.replace(old, new)
        fixtures = {
            "signature reads the whole log (35f63387)": (mutated(
                'def signature(view: "FailedView | Unplaced")',
                'def signature(view: "FailedView | Unplaced", log: str = "")').replace(
                "    tests = test_reds.failed_names(test_reds.lines_of(text))\n    return steps,",
                "    tests = test_reds.failed_names(test_reds.lines_of(log or text))\n    return steps,"),
                None, "signature: takes a raw log"),
            "compare_window places lines itself": (mutated(
                "    head_crash = crash_signals(head_view)",
                "    head_crash = {status for _, _, status in step_owners(head_view.job, '', step_names=None)}"),
                None, "compare_window: calls step_owners"),
            "judge reads a log": (mutated(
                "        got = read_head(repo, base, sha, name, job, github, run_reads, base_runs)",
                "        head_log = github.log(repo, job)\n"
                "        got = read_head(repo, base, sha, name, job, github, run_reads, base_runs)"),
                None, "judge: reads a raw log"),
            "a new unlisted reader": (self.SOURCE + "\n\ndef new_errors(job, head_log):\n    return head_log\n",
                                      None, "new_errors: takes a raw log"),
            "next_batch keys a raw log": (self.SOURCE, mutated(
                "        crashes = base_red_excuse.crash_signals(view)",
                "        crashes = base_red_excuse.crash_signals(log)", self.NEXT_BATCH),
                "next_batch.expand_job: reads its raw log"),
        }
        for label, (source, next_batch, want) in fixtures.items():
            with self.subTest(fixture=label):
                said = raw_log_reads(source, next_batch)
                self.assertTrue(any(line.startswith(want) for line in said), said)

    def verdicts(self, comparator, head, base):
        """What COMPARATOR finds on HEAD (passing, failing) that BASE (passing, failing) lacks, each side read through
        its own failed_view."""
        (head_job, head_log), (base_job, base_log) = view_case(*head), view_case(*base)
        head_view = excuse.failed_view(head_job, head_log, base=False, **UNKNOWN)
        base_view = excuse.failed_view(base_job, base_log, base=True, **UNKNOWN)
        if comparator == "signature":
            mine, theirs = excuse.signature(head_view), excuse.signature(base_view)
            return {f"test {t}" for t in mine[1] - theirs[1]} | {f"error {e}" for e in mine[2] - theirs[2]}
        if comparator == "step_errors":
            return {f"{step}: {error}" for step, error in excuse.step_errors(head_view) - excuse.step_errors(base_view)}
        if comparator == "crash_signals":
            return {f"signal {s}" for s in excuse.crash_signals(head_view) - excuse.crash_signals(base_view)}
        if comparator == "ratchet_unmatched":
            if not excuse.ratchet_red(head_view)[0]:
                return set()
            return set(excuse.ratchet_unmatched(head_view, base_view))
        if comparator == "compare_window":
            window = [({"id": 20}, base_view, excuse.signature(base_view), excuse.step_errors(base_view))]
            try:
                excuse.compare_window(REPO, "main", head_job["name"], excuse.signature(head_view), head_view, window,
                                      False, head_pairs=excuse.step_errors(head_view))
            except excuse.Refused as why:
                return {str(why).split(": ", 1)[1]}
            return set()
        if comparator == "next_batch.expand_job":
            sys.path.insert(0, str(ROOT / "scripts/ci"))
            import next_batch
            controller = next_batch.Controller.__new__(next_batch.Controller)
            keys = []
            for job, text, base in ((head_job, head_log, False), (base_job, base_log, True)):
                controller.job_log = lambda job_id, text=text: text
                keys.append(controller.expand_job(job["name"], job["id"], job, base=base))
            return keys[0] - keys[1]
        raise AssertionError(comparator)

    def test_next_batch_and_judge_agree_on_a_base_errored_section(self):
        # Codex's finding on #40542 at 8dc7e0dc: next_batch read its base runs through failed_view's head role, so a
        # base's ERRORED continue-on-error section (a passing lint step that prints an error) was base evidence, and
        # next-batch said "no new failures" for this pair while judge() refused it. Each pair is (head, base), each
        # side (steps, lines) as view_case reads them; judge refusing and next-batch finding a new failure must agree.
        lint_then_rollup = ([("Lint", "success", 10, 12), ("Rollup", "failure", 20, 21)],
                            [("Lint", 10, "##[group]Run scripts/lint.sh"), ("Lint", 11, NEW_RED),
                             ("Lint", 11.5, EXIT), ("Rollup", 20, "##[group]Run scripts/rollup.sh"),
                             ("Rollup", 20.6, "##[error]red check: Lint")])
        repro = (VIEW_STEPS, [("Negative cases", 10, "##[group]Run python3 negative.py"),
                              ("Negative cases", 11, FAKE_ISSUE), ("Negative cases", 11, FAKE_FAILED),
                              ("Check", 20, "##[group]Run scripts/check.sh"), ("Check", 21, NEW_RED),
                              ("Check", 21, EXIT)])
        fails_fake = (VIEW_STEPS, [("Negative cases", 10, "##[group]Run python3 negative.py"),
                                   ("Negative cases", 11, "ok: refused as expected"),
                                   ("Check", 20, "##[group]Run scripts/check.sh"), ("Check", 21, FAKE_ISSUE),
                                   ("Check", 21, FAKE_FAILED), ("Check", 21, EXIT)])
        pairs = {"the reviewer's pair: an ERRORED lint section and a failed rollup on both sides":
                     (lint_then_rollup, lint_then_rollup, True),
                 "the Codex repro of F1 at 35f63387": (repro, fails_fake, True),
                 "the same failed step's red on both sides": (repro, repro, False)}
        sys.path.insert(0, str(ROOT / "scripts/ci"))
        import next_batch

        def job(job_id, run_id, sha, steps):
            return {"id": job_id, "run_id": run_id, "head_sha": sha, "name": "cmux-next static checks",
                    "status": "completed", "conclusion": "failure", "steps": framed_steps(steps)}

        for label, ((head_steps, head_lines), (base_steps, base_lines), refused) in pairs.items():
            with self.subTest(pair=label):
                github = FakeGitHub()
                github.jobs = {1: job(1, 10, HEAD, head_steps), 2: job(2, 20, BASE_SHA, base_steps)}
                github.logs = {1: framed_log(head_lines, "cmux-next static checks"),
                               2: framed_log(base_lines, "cmux-next static checks")}
                try:
                    excuse.judge(REPO, "feat-cmux-next", HEAD, [10], github)
                    judged = "excused"
                except excuse.Refused as why:
                    judged = f"refused: {why}"
                controller = next_batch.Controller.__new__(next_batch.Controller)
                controller.args = unittest.mock.Mock(repo=REPO)
                controller.gh = unittest.mock.Mock()
                controller.gh.api.side_effect = lambda route, **_: {"jobs": [
                    copy.deepcopy(found) for found in github.jobs.values()
                    if f"/runs/{found['run_id']}/" in route]}
                controller.gh.runs.return_value = [{"id": 20, "head_branch": next_batch.BASE, "status": "completed",
                                                    "event": "push", "conclusion": "failure", "head_sha": BASE_SHA}]
                controller.job_log = lambda job_id: github.logs[job_id]
                batch = controller.judge_web({"id": 10, "conclusion": "failure"}, BASE_SHA)
                self.assertEqual(judged.startswith("refused"), refused, judged)
                self.assertEqual(batch.startswith("failed: "), refused,
                                 f"next-batch said {batch!r} where judge() {judged}")

    def test_swapping_head_and_base_mirrors_every_comparator(self):
        # Head and base are read alike: what one side's passing step prints is no failure of a head and no evidence
        # of a base, so a comparator finds on A over B exactly what is A's own, and on B over A what is B's, and nothing
        # on a log over itself.
        pairs = {
            "the Codex repro": (HEAD_FAKE_IN_PASSING, BASE_FAKE_FAILS),
            "crash signals": (((CRASH_11,), (CRASH_6,)), (("ok",), (CRASH_11,))),
            "panic ratchet": ((ratchet(9), ratchet(5)), (("ok",), ratchet(9))),
        }
        # (what A over B finds, what B over A finds): a line each way that is the head's failed step's own.
        want = {
            "the Codex repro": {"signature": ("error " + excuse.normalise_error(NEW_RED), "test fake()"),
                                "step_errors": ("Check: " + excuse.normalise_error(NEW_RED), None),
                                "compare_window": ("New.swift", "fake()"),
                                "next_batch.expand_job": ("error " + excuse.normalise_error(NEW_RED), "test fake()")},
            "crash signals": {"crash_signals": ("signal 6", "signal 11")},
            "panic ratchet": {"ratchet_unmatched": (None, "clippy::unwrap_used 9 > baseline 3")},
        }
        self.assertEqual(set().union(*want.values()), set(COMPARATORS))
        for label, (a, b) in pairs.items():
            for comparator in want[label]:
                with self.subTest(comparator=comparator, pair=label):
                    self.assertEqual(self.verdicts(comparator, a, a), set())
                    self.assertEqual(self.verdicts(comparator, b, b), set())
                    for (head, base), expected in zip(((a, b), (b, a)), want[label][comparator]):
                        found = self.verdicts(comparator, head, base)
                        if expected is None:
                            self.assertEqual(found, set())
                        else:
                            self.assertTrue(any(expected in said for said in found), (expected, found))
                        # Nothing only a passing step printed is ever found: it is neither side's.
                        passing_only = [text for text in head[0] if text not in head[1] and text != "ok"]
                        self.assertFalse([said for said in found for text in passing_only if text in said])


class IsolatedUnpackedRun(unittest.TestCase):
    """merge_hold and the lane-gh broker's update_branch guard run this script as `python3 -I` from a `git archive` of
    scripts/ci unpacked into a cache directory (leo-workspace tools/merge_hold.py classifier_script and
    classifier_argv). -I leaves the script's own directory off sys.path, so every sibling module it reads must load by
    file path or after its own SCRIPT_DIR insert (receipt_grammar). Pins that both halves load from such a copy."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(prefix="base-red-isolated-")
        cls.ci = Path(cls.tmp.name) / "scripts" / "ci"
        shutil.copytree(ROOT / "scripts" / "ci", cls.ci, ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
        cls.env = {k: v for k, v in os.environ.items()
                   if k not in ("BASE_RED_EXCUSE_FIXTURE_SHA", "PYTHONPATH", "PYTHONHOME")}

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def run_isolated(self, *args):
        return subprocess.run([sys.executable, "-I", *args], capture_output=True, text=True, timeout=120,
                              cwd=self.tmp.name, env=self.env, stdin=subprocess.DEVNULL)

    def test_the_ws_check_verdict_cli_runs_from_an_unpacked_copy_under_dash_i(self):
        proc = self.run_isolated(str(self.ci / "base_red_excuse.py"), "--repo", "x/y", "--base", "main",
                                 "--sha", "0" * 40, "--ws-check-verdict")
        said = proc.stdout + proc.stderr
        self.assertNotIn("ImportError", said)
        self.assertNotIn("ModuleNotFoundError", said)
        self.assertNotIn("Traceback", said)
        self.assertEqual(proc.returncode, 1, said)
        self.assertIn(f"not excused: --sha {'0' * 40} is a placeholder, not a commit; nothing was read", proc.stderr)

    def test_receipt_grammar_imports_risk_tier_from_the_copy_under_dash_i(self):
        probe = ("import importlib.util, sys\n"
                 "spec = importlib.util.spec_from_file_location('base_red_excuse', sys.argv[1])\n"
                 "excuse = importlib.util.module_from_spec(spec)\n"
                 "spec.loader.exec_module(excuse)\n"
                 "risk_tier = excuse.receipt_grammar()\n"
                 "print(risk_tier.__file__)\n"
                 "print(callable(risk_tier.signed_off))\n")
        proc = self.run_isolated("-c", probe, str(self.ci / "base_red_excuse.py"))
        said = proc.stdout + proc.stderr
        self.assertEqual(proc.returncode, 0, said)
        self.assertNotIn("ModuleNotFoundError", said)
        self.assertEqual(proc.stdout.splitlines(), [str((self.ci / "risk_tier.py").resolve()), "True"])


class LoadedModuleList(unittest.TestCase):
    """scripts/ci/base_red_excuse.modules.txt lists every scripts/ci path base_red_excuse.py can load, derived here by
    AST: each import (top level or lazy, inside a function) whose module is a scripts/ci file, or a package in a
    scripts/ci directory a string literal names (the _vendor it puts on sys.path); each string literal naming a
    scripts/ci file (Path(__file__).with_name("x.py") for spec_from_file_location, a data file); then the same for
    every sibling module found, transitively. Vendored packages are not read inside. merge_hold and the lane-gh broker
    run base_red_excuse.py from a `git archive` of scripts/ci, and leo-workspace's test fixture is re-archived from
    this list, so a new sibling fails here, at the PR that adds it, not as a broker refusal later."""

    CI = ROOT / "scripts" / "ci"
    LIST = CI / "base_red_excuse.modules.txt"

    @staticmethod
    def loads(ci: Path, rel: str) -> set[str]:
        tree = ast.parse((ci / rel).read_text(), rel)
        entries = {path.name for path in ci.iterdir()}
        literals, modules = set(), set()
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                modules |= {alias.name.split(".")[0] for alias in node.names}
            elif isinstance(node, ast.ImportFrom) and node.level == 0 and node.module:
                modules.add(node.module.split(".")[0])
            elif isinstance(node, ast.Constant) and isinstance(node.value, str) and node.value in entries:
                literals.add(node.value)
        roots = [ci] + [ci / name for name in sorted(literals) if (ci / name).is_dir()]
        found = {name for name in literals if (ci / name).is_file()}
        for module in modules:
            for root in roots:
                if (root / f"{module}.py").is_file():
                    found.add((root / f"{module}.py").relative_to(ci).as_posix())
                    break
                if (root / module / "__init__.py").is_file():
                    found.add((root / module).relative_to(ci).as_posix() + "/")
                    break
        return found

    @classmethod
    def derive(cls, ci: Path) -> set[str]:
        seen, todo = set(), ["base_red_excuse.py"]
        while todo:
            for name in cls.loads(ci, todo.pop()) - seen - {"base_red_excuse.py"}:
                seen.add(name)
                if name.endswith(".py") and "/" not in name:
                    todo.append(name)
        return seen

    @staticmethod
    def listed(text: str) -> set[str]:
        return {line.strip() for line in text.splitlines() if line.strip() and not line.startswith("#")}

    def test_the_checked_in_list_is_every_path_base_red_excuse_loads(self):
        derived, listed = self.derive(self.CI), self.listed(self.LIST.read_text())
        self.assertEqual(sorted(derived - listed), [], f"loaded but not in {self.LIST.name}: add them")
        self.assertEqual(sorted(listed - derived), [], f"in {self.LIST.name} but no longer loaded: remove them")

    def test_every_listed_path_exists(self):
        for name in self.listed(self.LIST.read_text()):
            self.assertTrue((self.CI / name.rstrip("/")).exists(), name)

    def test_a_new_sibling_import_is_found(self):
        # A copy of scripts/ci whose base_red_excuse.py gains a lazy sibling import, and a sibling that loads another
        # by path: both are found, so the list check above fails until they are listed.
        with tempfile.TemporaryDirectory() as tmp:
            ci = Path(tmp)
            for name in self.listed(self.LIST.read_text()) | {"base_red_excuse.py"}:
                if not name.endswith("/"):
                    (ci / name).write_bytes((self.CI / name).read_bytes())
            (ci / "_vendor" / "yaml").mkdir(parents=True)
            (ci / "_vendor" / "yaml" / "__init__.py").write_text("")
            script = ci / "base_red_excuse.py"
            script.write_text(script.read_text() + "\n\ndef _probe():\n    import new_sibling\n    return new_sibling\n")
            (ci / "new_sibling.py").write_text('from pathlib import Path\nNEXT = Path(__file__).with_name("deeper.py")\n')
            (ci / "deeper.py").write_text("")
            derived = self.derive(ci)
        self.assertEqual(derived - self.listed(self.LIST.read_text()), {"new_sibling.py", "deeper.py"})


# cmux#40984 at a6698ad5 (2026-11-11): 'cmux-next checks (god files, concurrency, crash safety, l10n)' failed in its
# continue-on-error step "Motion and colour tokens" (the jobs API calls it a success; the job's rollup step "Fail on any
# red check" names it), #40959 fixed that step on feat-cmux-next, and the job stayed red there for another step, so
# judge() refused it as "errors not on feat-cmux-next any of runs ...". fixed_on_base_by_step judges the failing steps
# alone, keyed by (workflow, job, step): base run 20 (at NEWER, after the merge-base) is the newest base verdict, base
# run 19 (at the merge-base, created before its commit time) the verdict the PR was built on.
class FailedStepIdentity(unittest.TestCase):
    """#41158's review F1, placed: compare_window matched failed steps by name, so a head step the runner cancelled
    was excused by a base whose step of that name failed, the same tests named."""

    def test_a_cancelled_step_is_not_the_bases_failure(self):
        self.assertTrue(excuse.judge(REPO, "feat-cmux-next", HEAD, [10], FakeGitHub())[0].startswith("excused "))
        github = FakeGitHub()
        github.jobs[1]["steps"][2]["conclusion"] = "cancelled"
        with self.assertRaisesRegex(excuse.Refused, r"failed steps not on feat-cmux-next run 20 with the same "
                                                    r"conclusion, as often: Run package tests \(cancelled\)"):
            excuse.judge(REPO, "feat-cmux-next", HEAD, [10], github)

    def test_a_step_failed_twice_is_not_the_bases_one_failure(self):
        github = FakeGitHub()
        github.jobs[1]["steps"].append(dict(github.jobs[1]["steps"][2]))
        with self.assertRaisesRegex(excuse.Refused, r"Run package tests \(failure\) x2"):
            excuse.judge(REPO, "feat-cmux-next", HEAD, [10], github)


class OneVerdictCoversTheHeadsIdentity(unittest.TestCase):
    """#41166's review F1 (found again by tests/test_base_red_excuse_property.py, seed 37): compare_window merged the
    failed-step keys of the whole window (Counter |), so a head whose "Run package tests" failed and a second one was
    cancelled matched the newest base verdict's failure and an older one's cancel: an identity no base run had. Each
    verdict is compared alone."""

    def setUp(self):
        self.gh = FakeGitHub()
        steps = self.gh.jobs[1]["steps"]
        steps.append(dict(steps[2], conclusion="cancelled"))
        self.gh.logs[1] = log(SWIFT, TEST_STEP, ISSUE)
        self.gh.base_runs = []

    def base(self, run_id, hour, conclusions):
        self.gh.base_runs.append({"id": run_id, "event": "push", "head_branch": "feat-cmux-next",
                                  "status": "completed", "conclusion": "failure", "head_sha": BASE_SHA,
                                  "created_at": f"2026-11-11T{hour:02d}:00:00Z"})
        job = failed_job(run_id, run_id, BASE_SHA)
        job["steps"] = job["steps"][:2] + [dict(job["steps"][2], conclusion=c) for c in conclusions]
        self.gh.jobs[run_id] = job
        self.gh.logs[run_id] = log(SWIFT, TEST_STEP, ISSUE)

    def test_a_failure_and_a_cancel_split_over_two_verdicts_is_not_excused(self):
        self.base(30, 12, ["failure"])
        self.base(29, 11, ["cancelled"])
        with self.assertRaisesRegex(excuse.Refused, r"failed steps not on feat-cmux-next any of runs 30, 29 with the "
                                                    r"same conclusion, as often, each verdict alone"):
            excuse.judge(REPO, "feat-cmux-next", HEAD, [10], self.gh)

    def test_one_verdict_with_both_is_still_excused(self):
        self.base(30, 12, ["failure"])
        self.base(29, 11, ["failure", "cancelled"])
        said = excuse.judge(REPO, "feat-cmux-next", HEAD, [10], self.gh)
        self.assertTrue(said[0].startswith(f"excused '{SWIFT}'"), said)


class EveryReportedFailureIsNamed(unittest.TestCase):
    """#41166's review F2 (found again by tests/test_base_red_excuse_property.py, seeds 7 and 12): an unnamed failure
    was recorded only when no failing test was named at all, and the placed comparison never asked, so a log with one
    parsed name and one failure no parser reads (a cargo doc test) was excused as if fully identified. Whenever a
    runner reports more failures than it names, the red is refused, placed or whole."""

    CARGO = ["running 2 tests", "test tests::reconnects ... FAILED", "test src/lib.rs - parse (line 3) ... FAILED",
             "test result: FAILED. 0 passed; 2 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.01s"]

    def test_placed(self):
        github = FakeGitHub()
        github.logs[1] = github.logs[2] = log(SWIFT, TEST_STEP, *self.CARGO)
        with self.assertRaisesRegex(excuse.Refused, "more failing tests than it names .*test result: FAILED"):
            excuse.judge(REPO, "feat-cmux-next", HEAD, [10], github)
        # Every failure named, the same on the base: excused as before.
        named = [line for line in self.CARGO if "src/lib.rs" not in line]
        named[-1] = named[-1].replace("2 failed", "1 failed")
        github.logs[1] = github.logs[2] = log(SWIFT, TEST_STEP, *named)
        self.assertTrue(excuse.judge(REPO, "feat-cmux-next", HEAD, [10], github)[0].startswith("excused "))

    def test_whole_log(self):
        with self.assertRaisesRegex(excuse.Refused, "reports more failing tests than it names .*test result: FAILED"):
            excuse.judge(REPO, "feat-cmux-next", HEAD, [10],
                         UnplacedGitHub(UNPLACED_KIT, UNPLACED_KIT_STEP, self.CARGO, self.CARGO))


def bun_lines(results=(), recap=(), fail=None):
    """One bun invocation of test/a.test.ts: RESULTS printed in the run, a recap of RECAP titles, ` N fail`."""
    out = ["bun test v1.3.0", "test/a.test.ts:"]
    for title in results:
        out += ["error: expect(received).toBe(expected)", f"(fail) {title} [1.00ms]"]
    if recap:
        out += [f"{len(recap)} test{'s' if len(recap) != 1 else ''} failed:", *(f"(fail) {t}" for t in recap)]
    return out + [" 0 pass", f" {len(results) if fail is None else fail} fail"]


class UnnamedFailureRefusedInTheSharedReading(unittest.TestCase):
    """#41222's review, earlier F1: "Move the refusal into the shared path every consumer goes through ... Cover each
    entry point (classify, read, expand_job)". test_reds.read() records a failure no parser names as results that are
    not whole, so read_head refuses it for every judge() path (placed, whole-log, fixed on base, per step, quarantine,
    per-test), and the command line with it; next_batch's expand_job keys it as the job's own
    (tests/test_next_batch.py)."""

    UNNAMED = ["test src/lib.rs - parse (line 3) ... FAILED",
               "test result: FAILED. 0 passed; 1 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.01s"]

    def test_the_fixed_on_base_path(self):
        github = KitFixedOnBaseGitHub()
        self.assertIn("fixed on base", excuse.judge(REPO, "feat-cmux-next", HEAD, [10], github)[0])
        github.logs[1] = framed_log(kit_lines(*((KIT_STEP, 19, line) for line in self.UNNAMED)), KIT)
        with self.assertRaisesRegex(excuse.Refused, "reports more failing tests than it names .*test result: FAILED"):
            excuse.judge(REPO, "feat-cmux-next", HEAD, [10], github)

    def test_the_command_line(self):
        github = KitFixedOnBaseGitHub()
        github.logs[1] = framed_log(kit_lines(*((KIT_STEP, 19, line) for line in self.UNNAMED)), KIT)
        err = io.StringIO()
        with unittest.mock.patch.object(excuse, "GitHub", lambda: github), \
                unittest.mock.patch.object(excuse.test_reds, "load_flake_state", lambda *a, **k: None), \
                contextlib.redirect_stderr(err), contextlib.redirect_stdout(io.StringIO()):
            code = excuse.main(["--repo", REPO, "--base", "feat-cmux-next", "--sha", HEAD, "--run", "10"])
        self.assertEqual(code, 1, err.getvalue())
        self.assertIn("reports more failing tests than it names", err.getvalue())


class PassingStepsNamePassingStepsOnly(unittest.TestCase):
    """#41244's review F1: "read_bun keeps unnamed markers from passing steps, so a passing negative-case step printing
    "(fail)" and "2 fail" makes judge() refuse an unrelated inherited red. Filter Bun's unnamed markers by step
    ownership, the same rule as #41241". read_head and next_batch's expand_job read a placed red's unnamed failures
    from its failed sections alone (owned_unnamed)."""

    NEGATIVE = ["bun test v1.3.0", "test/negative.test.ts:", "error: expect(received).toBe(expected)",
                "(fail) negative > reports a red [1.00ms]", " 0 pass", " 2 fail"]

    def head(self, step):
        """KIT's red with NEGATIVE printed, in log order, by STEP: the passing build step or the failed test step."""
        lines = kit_lines()
        at = 1 if step == KIT_BUILD else len(lines) - 1
        return framed_log(lines[:at] + [(step, 5 if step == KIT_BUILD else 19, line) for line in self.NEGATIVE]
                          + lines[at:], KIT)

    def test_a_passing_steps_bun_count_never_refuses_the_inherited_red(self):
        github = KitFixedOnBaseGitHub()
        github.logs[1] = self.head(KIT_BUILD)
        self.assertIn("fixed on base", excuse.judge(REPO, "feat-cmux-next", HEAD, [10], github)[0])
        # Printed by the failed step, the same count is the red's own.
        github.logs[1] = self.head(KIT_STEP)
        with self.assertRaisesRegex(excuse.Refused, "reports more failing tests than it names .* 2 fail"):
            excuse.judge(REPO, "feat-cmux-next", HEAD, [10], github)


class BunRecapAndRetryCounts(unittest.TestCase):
    """#41222's review F1 (test_reds.py:508): "Two identical `(fail)` recap entries followed by `2 fail` produce one
    identity because `read_bun` deduplicates them, but `recap == 2` prevents an unnamed marker. I reproduced `judge()`
    excusing this against a one-failure base in both comparison paths." And F2 (test_reds.py:493): "A first attempt
    reporting two failures while naming one remains refused after a fully named retry matching the base"."""

    HEAD_RECAP = bun_lines(recap=["a > one", "a > one"], fail=2)
    BASE_RECAP = bun_lines(recap=["a > one"], fail=1)
    RETRIED = bun_lines(results=["a > one"], fail=2) + ["--- retry, alone ---"] + bun_lines(results=["a > one"])
    # The base's file failed twice too, named both times: the whole-log comparison counts both attempts' error lines.
    BASE_ONE = bun_lines(results=["a > one"]) + ["--- retry, alone ---"] + bun_lines(results=["a > one"])

    def placed(self, head, base):
        github = FakeGitHub()
        github.logs[1], github.logs[2] = log(SWIFT, TEST_STEP, *head), log(SWIFT, TEST_STEP, *base)
        return excuse.judge(REPO, "feat-cmux-next", HEAD, [10], github)

    def whole(self, head, base):
        return excuse.judge(REPO, "feat-cmux-next", HEAD, [10],
                            UnplacedGitHub(UNPLACED_KIT, UNPLACED_KIT_STEP, head, base))

    def test_f1_duplicate_recap_titles_are_two_failures_placed_and_whole(self):
        # #41222's review F1 at 6719ba22: "a head with 2 failures is excused against a base with 1 ... Count identities
        # with multiplicity: a name failing twice is 2." Refused against one; the same twice on the base is excused.
        for path, why in ((self.placed, "more often than on any of .*a > one x2 \\(at most x1\\)"),
                          (self.whole, "failing tests are not .*more on this head: a > one")):
            with self.subTest(path=path.__name__):
                with self.assertRaisesRegex(excuse.Refused, why):
                    path(self.HEAD_RECAP, self.BASE_RECAP)
                self.assertTrue(path(self.HEAD_RECAP, self.HEAD_RECAP)[0].startswith("excused "))
                self.assertTrue(path(self.BASE_RECAP, self.BASE_RECAP)[0].startswith("excused "))

    def test_a_recap_only_retry_counts_its_titles_once_placed_and_whole(self):
        # #41329's review F1: two attempts that each recap `a > one` counted it twice, refused against a base that
        # failed it once. The retry drops the superseded attempt's recap titles too.
        retried = self.BASE_RECAP + ["--- retry, alone ---"] + self.BASE_RECAP
        for path in (self.placed, self.whole):
            with self.subTest(path=path.__name__):
                self.assertTrue(path(retried, self.BASE_RECAP)[0].startswith("excused "))
                with self.assertRaisesRegex(excuse.Refused, "a > one"):
                    path(self.HEAD_RECAP + ["--- retry, alone ---"]
                         + self.HEAD_RECAP, self.BASE_RECAP)

    def test_a_result_failing_twice_is_not_the_bases_one_failure_placed(self):
        # The same rule for a name its results print twice: the placed path compared the window by name alone.
        twice = bun_lines(results=["a > one", "a > one"])
        with self.assertRaisesRegex(excuse.Refused, "more often than on any of .*a > one x2 \\(at most x1\\)"):
            self.placed(twice, bun_lines(results=["a > one"]))
        self.assertTrue(self.placed(twice, twice)[0].startswith("excused "))

    def test_f2_a_fully_named_retry_is_judged_alone_placed_and_whole(self):
        for path in (self.placed, self.whole):
            with self.subTest(path=path.__name__):
                self.assertTrue(path(self.RETRIED, self.BASE_ONE)[0].startswith("excused "))
                unnamed_retry = bun_lines(results=["a > one"]) + ["--- retry, alone ---"] + bun_lines(
                    results=["a > one"], fail=2)
                with self.assertRaisesRegex(excuse.Refused, "more failing tests than it names"):
                    path(unnamed_retry, self.BASE_ONE)



class OneVerdictHoldsEachTestsWholeFailure(unittest.TestCase):
    """#41329's review F1: "the identity match and the count can come from different base verdicts. Reproduced: head
    recap-only `A x2`; newest base recap-only `A x1`; older base `A x2` but with a TypeError diagnostic. Neither base
    alone excuses it, yet the combined window does. For each test, require the identity, diagnostic and count to all
    hold on one verdict." """

    HEAD_RECAP = bun_lines(recap=["a > one", "a > one"], fail=2)
    NEWEST = bun_lines(recap=["a > one"], fail=1)
    # bun with no file header names its results by title alone, as the recap does: the same test, its own error.
    OLDER = ["bun test v1.3.0", "TypeError: pane.close is not a function", "(fail) a > one [1.00ms]",
             "TypeError: pane.close is not a function", "(fail) a > one [1.00ms]", " 0 pass", " 2 fail"]

    def judge(self, *bases):
        github = FakeGitHub()
        github.logs[1] = log(SWIFT, TEST_STEP, *self.HEAD_RECAP)
        github.base_runs = []
        for n, lines in enumerate(bases):
            run = 30 - n
            github.base_runs.append({"id": run, "event": "push", "head_branch": "feat-cmux-next",
                                     "status": "completed", "conclusion": "failure", "head_sha": BASE_SHA,
                                     "created_at": f"2026-11-11T{12 - n:02d}:00:00Z"})
            github.jobs[run] = failed_job(run, run, BASE_SHA)
            github.logs[run] = log(SWIFT, TEST_STEP, *lines)
        return excuse.judge(REPO, "feat-cmux-next", HEAD, [10], github)

    def test_each_base_alone_refuses_it(self):
        for bases in ((self.NEWEST,), (self.OLDER,)):
            with self.subTest(base=bases[0][-1]), self.assertRaises(excuse.Refused):
                self.judge(*bases)

    def test_the_window_does_not_combine_one_verdicts_identity_with_anothers_count(self):
        with self.assertRaisesRegex(excuse.Refused, "a > one x2"):
            self.judge(self.NEWEST, self.OLDER)

    def test_one_verdict_with_all_three_still_excuses(self):
        said = self.judge(self.NEWEST, self.HEAD_RECAP)
        self.assertTrue(said[0].startswith(f"excused '{SWIFT}'"), said)



class SplitSectionsAreNeverJudgedAgain(unittest.TestCase):
    """#41329's review follow-up F3 (base_red_excuse.py:1487): "re-parsing the concatenated failed sections runs
    passed_steps again, so a failed section with no ##[error] can be read as passing and its unnamed Bun count dropped.
    Parse each failed section on its own, and never re-judge pass or fail on text that's already been split." A
    FailedView's text is a test_reds.Steps: each section is read as the failed step it was placed as."""

    def sections(self):
        echo = lambda script: [f"2026-11-11T12:00:0{n}.0Z {line}" for n, line in enumerate(
            [f"##[group]Run {script}", "shell: /usr/bin/bash -e {0}", "##[endgroup]"])]
        # A failed step that printed no `##[error]` (the jobs API says it failed), then the step that did.
        quiet = echo("bun test test/a.test.ts") + [f"2026-11-11T12:00:05.0Z {line}" for line in
                                                     bun_lines(results=["a > one"], fail=2)]
        loud = echo("cargo test") + [f"2026-11-11T12:00:09.0Z {line}" for line in (
            "test tests::reconnects ... FAILED",
            "test result: FAILED. 0 passed; 1 failed; 0 ignored; 0 measured; 0 filtered out",
            "##[error]Process completed with exit code 101.")]
        return quiet, loud

    def view(self):
        quiet, loud = self.sections()
        steps = [{"name": "bun", "conclusion": "failure"}, {"name": "cargo", "conclusion": "failure"}]
        return excuse.FailedView({"id": 1, "steps": steps}, False, steps,
                                 [(0, "FAILED", quiet), (1, "FAILED", loud)])

    def test_a_failed_sections_bun_count_is_kept_without_an_error_line(self):
        view = self.view()
        own = excuse.owned_unnamed(excuse.test_reds.read("\n".join(sum(self.sections(), []))), view)
        self.assertEqual(own.unnamed, [" 2 fail"])
        self.assertTrue(any(why.startswith(excuse.test_reds.UNNAMED_WHY) for why in own.truncated), own.truncated)
        unnamed: list = []
        excuse.test_reds.failed_in(excuse.view_text(view), unnamed)
        self.assertEqual(unnamed, [" 2 fail"])


class GuardCrashIsNotItsFinding(unittest.TestCase):
    """hq#9218: the test-integrity guard (`deleted-or-weakened-tests`) prints each `--strict` finding as an `::error`
    naming its kind and path, and its workflow says "the guard itself failed" when it crashed. A crash and a finding,
    or findings on two files, are different reds and never excuse each other; the same crash on both sides is the
    base's broken guard. The reviewer's four cases, and a fifth: findings on two files whose names differ only in a
    digit, which normalise_error masked into one."""

    JOB, STEP = "deleted-or-weakened-tests", "Flag deleted or weakened tests"
    CRASH = ["Traceback (most recent call last):", '  File "test_integrity.py", line 3, in <module>', "OSError: boom",
             "##[error]the guard itself failed (exit 2) and judged nothing; this is not a finding, its traceback is "
             "above", "##[error]Process completed with exit code 2."]

    @staticmethod
    def finding(path):
        return [f"##[error]deleted-test-file: {path}: the file was deleted",
                "##[error]this change deletes or weakens tests (findings above)",
                "##[error]Process completed with exit code 1."]

    def judge(self, head, base):
        github = FakeGitHub()
        github.jobs = {1: failed_job(1, 10, HEAD, name=self.JOB, step=self.STEP),
                       2: failed_job(2, 20, BASE_SHA, name=self.JOB, step=self.STEP)}
        github.logs = {1: log(self.JOB, self.STEP, *head), 2: log(self.JOB, self.STEP, *base)}
        return excuse.judge(REPO, "feat-cmux-next", HEAD, [10], github)

    def test_1_a_crash_on_head_is_not_excused_by_a_finding_on_base(self):
        with self.assertRaisesRegex(excuse.Refused, "errors not on feat-cmux-next run 20: the guard itself failed"):
            self.judge(self.CRASH, self.finding("tests/test_a.py"))

    def test_2_a_finding_on_head_is_not_excused_by_a_crash_on_base(self):
        with self.assertRaisesRegex(excuse.Refused, "errors not on feat-cmux-next run 20: .*deleted-test-file: "
                                                    "tests/test_a.py"):
            self.judge(self.finding("tests/test_a.py"), self.CRASH)

    def test_3_a_finding_on_one_file_is_not_excused_by_one_on_another(self):
        for head, base in (("tests/test_a.py", "tests/test_b.py"), ("tests/test_1.py", "tests/test_2.py")):
            with self.subTest(head=head, base=base), self.assertRaisesRegex(
                    excuse.Refused, f"errors not on feat-cmux-next run 20: deleted-test-file: {re.escape(head)}"):
                self.judge(self.finding(head), self.finding(base))

    def test_4_the_same_crash_on_head_and_base_is_the_bases(self):
        said = self.judge(self.CRASH, self.CRASH)
        self.assertTrue(said[0].startswith(f"excused '{self.JOB}': feat-cmux-next run 20"), said)
        self.assertIn("the guard itself failed", said[0])


    def test_a_directory_that_looks_like_a_file_name_keeps_its_digits_masked(self):
        """Codex on #41172, F1: "run123.build" inside "run123.build-extra/" was read as a file name, so the run's own
        directory kept its digits and the same error on two runs stopped matching. A file name ends its path
        component; the real file's digits still count."""
        def line(run, name="A1.swift"):
            return f"##[error]/tmp/{run}.build-extra/Sources/{name}:12:3: error: cannot find 'x' in scope"
        self.assertEqual(excuse.normalise_error(line("run123")), excuse.normalise_error(line("run456")))
        self.assertNotEqual(excuse.normalise_error(line("run123")), excuse.normalise_error(line("run123", "A2.swift")))
        self.assertNotEqual(excuse.normalise_error("##[error]tests/test_1.py: weakened."),
                            excuse.normalise_error("##[error]tests/test_2.py: weakened."))

class StepFixture:
    """FixedOnBaseByStep's fixture, shared with DerivedStatusByParts (a mixin, so neither runs the other's tests)."""
    JOB = "cmux-next checks (god files, concurrency, crash safety, l10n)"
    MOTION = "Motion and colour tokens"
    SURFACES = "Surface roles"
    UNIT = "Unit tests"
    ROLLUP = "Fail on any red check"
    ORDER = (MOTION, SURFACES, UNIT, ROLLUP)
    QUIET = (MOTION, SURFACES)  # continue-on-error: the rollup names them
    NEWER = "c" * 40
    OLDER = "d" * 40
    MERGE_BASE_TIME = "2026-11-11T01:24:40Z"

    def setUp(self):
        self.notes = {}
        self.dispatches = []  # base runs created before the merge-base, beside run 19 (prior_base_verdict)
        self.caller_only = False  # only BASE_WORKFLOW_FOR's caller runs the job on the base (#41104's review F2)
        self.head_path = ".github/workflows/cmux-next.yml"  # run 10's workflow file

    def side(self, job_id, run_id, sha, states, names=None, rollup=None):
        """(job, log) for a checks job where STATES maps a step to pass (default), red (its conclusion failure),
        quiet-red (a continue-on-error step that failed: a success to the jobs API, named by the rollup), skipped or
        cancelled. NAMES renames the steps in order (a duplicate or empty name); ROLLUP forces the rollup's state."""
        steps, lines, rolled, second, state, errors = [], [], [], 10, "pass", []
        for n, step in enumerate(self.ORDER):
            name = names[n] if names else step
            state = states.get(step, "pass")
            if step == self.ROLLUP:
                state = rollup or ("red" if rolled else "pass")
            if state == "skipped":
                steps.append((name, "skipped", second, second))
                second += 10
                continue
            conclusion = {"red": "failure", "new-red": "failure", "cancelled": "cancelled"}.get(state, "success")
            steps.append((name, conclusion, second, second + 2))
            lines += [(name, second, f"##[group]Run scripts/check-{n}.sh"), (name, second, "##[endgroup]")]
            if step == self.ROLLUP and state == "red":
                lines += [(name, second + 1, f"##[error]red check: {red}") for red in rolled]
                lines.append((name, second + 1, EXIT))
            elif state in ("red", "quiet-red", "new-red", "new-quiet"):
                found = [(f"Sources/A{n}.swift", n + 1, f"{step} broke")]
                if state.startswith("new"):
                    found.append(("Sources/New.swift", 9, f"{step} broke anew"))
                lines += [(name, second + 1, f"/home/runner/work/cmux/cmux/{path}:{line}:3: error: {said}") for path, line, said in found]
                lines.append((name, second + 1, EXIT))
                errors += [{"annotation_level": "failure", "path": path, "start_line": line, "message": said}
                           for path, line, said in found]
                if state in ("quiet-red", "new-quiet"):
                    rolled.append(name)
            else:
                lines.append((name, second + 1, "ok"))
            second += 10
        failed = any(conclusion not in ("success", "skipped") for _, conclusion, _, _ in steps)
        job = {"id": job_id, "run_id": run_id, "head_sha": sha, "name": self.JOB, "status": "completed",
               "conclusion": "failure" if failed else "success", "steps": framed_steps(steps)}
        # The check run's annotations: each step's exit line and error (no step named), the rollup's red checks.
        self.notes[job_id] = [{"annotation_level": "failure", "title": "cmux-next check", "message": f"red check: {red}"}
                              for red in (rolled if state == "red" else ())]
        self.notes[job_id] += errors + [{"annotation_level": "failure", "title": "", "message": EXIT.split("]", 1)[1]},
                               {"annotation_level": "warning", "title": "ratchet debt", "message": "red check: no"}]
        return job, framed_log(lines, self.JOB)

    def github(self, head, newest, prior, *, newest_sha=None):
        test = self

        class GitHub(FakeGitHub):
            def json(self, route, *, paginate=False):
                if f"/compare/feat-cmux-next...{HEAD}" in route:
                    self.routes.append(route)
                    return {"merge_base_commit": {"sha": BASE_SHA,
                                                  "commit": {"committer": {"date": test.MERGE_BASE_TIME}}},
                            "files": []}
                if f"/compare/{BASE_SHA}...{test.OLDER}" in route:
                    self.routes.append(route)
                    return {"status": "behind"}
                if "/annotations?per_page=100" in route:
                    self.routes.append(route)
                    notes = copy.deepcopy(test.notes[int(route.split("/check-runs/", 1)[1].split("/", 1)[0])])
                    # GitHub's pages of 100, read in full only when paginated.
                    pages = [notes[n:n + 100] for n in range(0, max(len(notes), 1), 100)]
                    return pages if paginate else pages[0]
                if route.endswith("/actions/runs/10"):
                    self.routes.append(route)
                    return {"id": 10, "workflow_id": 7, "name": f"cmux-next · {HEAD}", "path": test.head_path}
                if "/actions/workflows/8/runs?" in route:
                    route = route.replace("/actions/workflows/8/", "/actions/workflows/7/")
                if test.caller_only and "/actions/workflows/" in route:
                    # Only the base caller's workflow (BASE_WORKFLOW_FOR) runs the job on the base.
                    if "/actions/workflows/7/runs?" in route:
                        self.routes.append(route)
                        return {"workflow_runs": []}
                    if "/actions/workflows/cmux-next-web.yml/" in route:
                        self.routes.append(route)
                        route = route.replace("/actions/workflows/cmux-next-web.yml/", "/actions/workflows/7/")
                found = super().json(route, paginate=paginate)
                if "/actions/workflows/7/runs?" in route and "&head_sha=" in route:
                    sha = route.split("&head_sha=", 1)[1].split("&", 1)[0]
                    found["workflow_runs"] = [run for run in found["workflow_runs"] + copy.deepcopy(test.dispatches)
                                              if run.get("head_sha") == sha]
                    return found
                if "/actions/workflows/7/runs?" in route and "&created=" in route:
                    found["workflow_runs"] += copy.deepcopy(test.dispatches)
                if "/actions/workflows/7/runs?" in route and "&created=" not in route:
                    # The base's newest runs do not reach back to the merge-base (cmux#40984: 229 commits behind),
                    # so run 19 is never in the window compare_window reads; only the dated read finds it.
                    found["workflow_runs"] = [run for run in found["workflow_runs"] if run["id"] != 19]
                return found

            def run(self, args):
                # SuiteChecks' GraphQL read: each suite's check runs of the name, from this fixture's jobs.
                assert args[:2] == ["api", "graphql"], args
                query = next(arg for arg in args if arg.startswith("query="))
                name = next(arg for arg in args if arg.startswith("name="))[len("name="):]
                return json.dumps({"data": {"nodes": [
                    {"id": f"CS_{run}", "checkRuns": {"pageInfo": {"hasNextPage": False}, "nodes": [
                        {"conclusion": (job["conclusion"] or "").upper() or None}
                        for job in self.jobs.values() if job["run_id"] == int(run) and job["name"] == name]}}
                    for run in re.findall(r'"CS_(\d+)"', query)]}})

        github = GitHub()
        jobs, logs = {}, {}
        for job_id, run_id, sha, (states, extra) in ((1, 10, HEAD, head), (2, 20, newest_sha or self.NEWER, newest),
                                                     (3, 19, BASE_SHA, prior)):
            jobs[job_id], logs[job_id] = self.side(job_id, run_id, sha, states, **extra)
        github.jobs, github.logs = jobs, logs
        github.base_runs = [
            {"id": 20, "event": "push", "head_branch": "feat-cmux-next", "status": "completed",
             "conclusion": jobs[2]["conclusion"], "head_sha": newest_sha or self.NEWER,
             "created_at": "2026-11-11T03:00:00Z"},
            {"id": 19, "event": "push", "head_branch": "feat-cmux-next", "status": "completed",
             "conclusion": jobs[3]["conclusion"], "head_sha": BASE_SHA, "created_at": "2026-11-11T01:10:00Z"}]
        return github

    PURPOSE = {"purpose": "update-branch"}  # the per-step reading's one caller (excuse.PER_STEP_PURPOSE)

    def judge(self, head, newest, prior, purpose="update-branch", **kwargs):
        github = self.github(head, newest, prior, **kwargs)
        return "\n".join(excuse.judge(REPO, "feat-cmux-next", HEAD, [10], github, purpose=purpose)), github

    def refused(self, pattern, head, newest, prior, purpose="update-branch", **kwargs):
        github = self.github(head, newest, prior, **kwargs)
        with self.assertRaisesRegex(excuse.Refused, pattern) as raised:
            excuse.judge(REPO, "feat-cmux-next", HEAD, [10], github, purpose=purpose)
        self.assertNotIn("excused", str(raised.exception))
        return str(raised.exception)



class FixedOnBaseByStep(StepFixture, unittest.TestCase):
    """fixed_on_base_by_step (StepFixture's head and base runs)."""

    def test_the_same_step_green_on_base_is_fixed_on_base_while_the_job_stays_red_there(self):
        # cmux#40984's shape: the head's one red step is fixed on base, whose job is red for another step.
        said, _ = self.judge(({self.MOTION: "quiet-red"}, {}), ({self.SURFACES: "quiet-red"}, {}),
                             ({self.MOTION: "quiet-red"}, {}))
        self.assertTrue(said.startswith(f"excused '{self.JOB}': fixed on base ("), said)
        self.assertEqual(said.splitlines(), [
            f"excused '{self.JOB}': fixed on base (run 10 / {self.JOB}, job 1, workflow .github/workflows/cmux-next.yml;"
            f" step '{self.MOTION}': passes in feat-cmux-next run 20 at cccccccccccc, at or after the merge-base "
            f"{BASE_SHA[:12]}; red in feat-cmux-next run 19 at {BASE_SHA[:12]}, at or before it) "
            f"(https://github.com/{REPO}/actions/runs/20)"])

    def test_the_same_step_green_on_a_green_base_job_is_fixed_on_base(self):
        said, _ = self.judge(({self.MOTION: "quiet-red"}, {}), ({}, {}), ({self.MOTION: "quiet-red"}, {}))
        self.assertTrue(said.startswith(f"excused '{self.JOB}': fixed on base ("), said)

    def test_a_failing_step_by_its_conclusion_green_on_base_is_fixed_on_base(self):
        said, _ = self.judge(({self.UNIT: "red"}, {}), ({self.SURFACES: "quiet-red"}, {}), ({self.UNIT: "red"}, {}))
        self.assertIn(f"step '{self.UNIT}'", said)

    def test_the_same_step_red_on_base_is_not_excused(self):
        self.refused(f"per step: not green in feat-cmux-next run 20: '{self.MOTION}' is failure",
                     ({self.MOTION: "quiet-red"}, {}), ({self.MOTION: "quiet-red"}, {}),
                     ({self.MOTION: "quiet-red"}, {}))

    def test_a_step_of_the_prs_own_is_not_excused(self):
        # Green on the base at the merge-base and after it: the head broke it.
        self.refused("per step: the PR's own red: at or before the merge-base .* run 19 was not red in it: "
                     f"'{self.MOTION}' is success",
                     ({self.MOTION: "quiet-red"}, {}), ({self.SURFACES: "quiet-red"}, {}),
                     ({self.SURFACES: "quiet-red"}, {}))
        # A step only the head has is missing on the base: unknown.
        renamed = [self.MOTION, self.SURFACES, "Unit tests (new)", self.ROLLUP]
        self.refused("per step: step 'Unit tests \\(new\\)' is missing in base job 2",
                     ({self.UNIT: "red"}, {"names": renamed}), ({self.SURFACES: "quiet-red"}, {}),
                     ({self.UNIT: "red"}, {}))

    def test_a_step_skipped_on_base_is_not_green(self):
        # The base job died in its unit tests: its later steps and the rollup were skipped, never fixed.
        order = (self.UNIT, self.MOTION, self.SURFACES, self.ROLLUP)
        with unittest.mock.patch.object(type(self), "ORDER", order):
            self.refused(f"per step: not green in feat-cmux-next run 20: '{self.MOTION}' is skipped",
                         ({self.MOTION: "quiet-red"}, {}),
                         ({self.UNIT: "red", self.MOTION: "skipped", self.SURFACES: "skipped"},
                          {"rollup": "skipped"}),
                         ({self.MOTION: "quiet-red"}, {}))
            # Its own step passed but the rollup that says whether it did was skipped.
            self.refused(f"per step: not green in feat-cmux-next run 20: '{self.MOTION}' is skipped \\(its rollup",
                         ({self.MOTION: "quiet-red"}, {}), ({self.UNIT: "red"}, {"rollup": "skipped"}),
                         ({self.MOTION: "quiet-red"}, {}))

    def test_a_step_cancelled_on_base_is_not_green(self):
        self.refused(f"per step: not green in feat-cmux-next run 20: '{self.UNIT}' is cancelled",
                     ({self.UNIT: "red"}, {}), ({self.UNIT: "cancelled", self.SURFACES: "quiet-red"}, {}),
                     ({self.UNIT: "red"}, {}))
        self.refused(f"'{self.MOTION}' is cancelled \\(its rollup",
                     ({self.MOTION: "quiet-red"}, {}), ({self.UNIT: "red"}, {"rollup": "cancelled"}),
                     ({self.MOTION: "quiet-red"}, {}))

    def test_a_duplicate_step_name_is_unknown_on_either_side(self):
        twice = [self.MOTION, self.MOTION, self.UNIT, self.ROLLUP]
        self.refused(f"per step: step '{self.MOTION}' is named 2 times in head job 1",
                     ({self.MOTION: "quiet-red"}, {"names": twice}), ({self.UNIT: "red"}, {}),
                     ({self.MOTION: "quiet-red"}, {}))
        self.refused(f"per step: step '{self.MOTION}' is named 2 times in base job 2",
                     ({self.MOTION: "quiet-red"}, {}), ({self.UNIT: "red"}, {"names": twice}),
                     ({self.MOTION: "quiet-red"}, {}))

    def test_a_missing_step_name_is_unknown(self):
        self.refused("per step: head job 1 has a step with no name",
                     ({self.UNIT: "red"}, {"names": [self.MOTION, "", self.UNIT, self.ROLLUP]}),
                     ({self.SURFACES: "quiet-red"}, {}), ({self.UNIT: "red"}, {}))
        # The rollup names a red check no step of the head job is.
        renamed = ["Motion tokens", self.SURFACES, self.UNIT, self.ROLLUP]
        github = self.github(({self.MOTION: "quiet-red"}, {"names": renamed}), ({self.SURFACES: "quiet-red"}, {}),
                             ({self.MOTION: "quiet-red"}, {}))
        self.notes[1] = [{"annotation_level": "failure", "message": f"red check: {self.MOTION}"}]
        with self.assertRaisesRegex(excuse.Refused, f"per step: step '{self.MOTION}' is missing in head job 1"):
            excuse.judge(REPO, "feat-cmux-next", HEAD, [10], github, **self.PURPOSE)

    def test_a_base_run_older_than_the_merge_base_is_not_base(self):
        self.refused("per step: feat-cmux-next's newest verdict for it, run 20, tested dddddddddddd, which is behind "
                     "the merge-base",
                     ({self.MOTION: "quiet-red"}, {}), ({self.SURFACES: "quiet-red"}, {}),
                     ({self.MOTION: "quiet-red"}, {}), newest_sha=self.OLDER)

    def test_two_failing_steps_where_only_one_is_green_on_base_is_not_excused(self):
        self.refused(f"per step: not green in feat-cmux-next run 20: '{self.UNIT}' is failure",
                     ({self.MOTION: "quiet-red", self.UNIT: "red"}, {}), ({self.UNIT: "red"}, {}),
                     ({self.MOTION: "quiet-red", self.UNIT: "red"}, {}))

    def test_base_runs_before_the_merge_base_that_never_ran_the_job_cost_no_job_read(self):
        # cmux#40984's 'cmux-next generated files': the newest runs before the merge-base were DEV daily and tip
        # suite dispatches without it. Their suites show no check run of the job, so only run 19's job list is read.
        self.dispatches = [{"id": 30 + n, "event": "workflow_dispatch", "head_branch": "feat-cmux-next",
                            "status": "completed", "conclusion": "failure", "head_sha": BASE_SHA,
                            "check_suite_node_id": f"CS_{30 + n}", "created_at": f"2026-11-11T01:2{n}:00Z"}
                           for n in range(excuse.STEP_PRIOR_JOB_READS + 2)]
        said, github = self.judge(({self.MOTION: "quiet-red"}, {}), ({self.SURFACES: "quiet-red"}, {}),
                                  ({self.MOTION: "quiet-red"}, {}))
        self.assertTrue(said.startswith(f"excused '{self.JOB}': fixed on base ("), said)
        self.assertFalse([route for route in github.routes if re.search(r"/actions/runs/3\d/jobs", route)])

    def test_a_job_name_red_in_two_workflows_is_unknown(self):
        github = self.github(({self.MOTION: "quiet-red"}, {}), ({self.SURFACES: "quiet-red"}, {}),
                             ({self.MOTION: "quiet-red"}, {}))
        other, github.logs[4] = self.side(4, 11, HEAD, {self.MOTION: "quiet-red"})
        github.jobs[4] = other
        github.workflows = {11: 8}
        with self.assertRaisesRegex(excuse.Refused, f"per step: '{re.escape(self.JOB)}' is red in two workflows"):
            excuse.judge(REPO, "feat-cmux-next", HEAD, [10, 11], github, **self.PURPOSE)

    def test_a_rollup_whose_annotations_name_no_red_or_may_be_cut_is_unknown(self):
        for reds in ([], [f"check {n}" for n in range(excuse.ANNOTATION_STEP_CAP)]):
            with self.subTest(reds=len(reds)):
                github = self.github(({self.MOTION: "quiet-red"}, {}), ({self.SURFACES: "quiet-red"}, {}),
                                     ({self.MOTION: "quiet-red"}, {}))
                self.notes[1] = [{"annotation_level": "failure", "message": f"red check: {red}"} for red in reds]
                with self.assertRaisesRegex(excuse.Refused, f"per step: rollup '{self.ROLLUP}' of head job 1 failed, "
                                                            "and its annotations do not name its reds"):
                    excuse.judge(REPO, "feat-cmux-next", HEAD, [10], github, **self.PURPOSE)

    def test_a_head_log_step_owners_cannot_place_is_still_judged_by_its_steps(self):
        # cmux#40984's head job log is not placed (step_owners); its steps and annotations still are its verdict.
        github = self.github(({self.MOTION: "quiet-red"}, {}), ({self.SURFACES: "quiet-red"}, {}),
                             ({self.MOTION: "quiet-red"}, {}))
        github.logs[1] = github.logs[1].replace("##[group]Run scripts/check-1.sh", "##[group]Run a/composite@v1\n"
                                                + github.logs[1].splitlines()[3][:28] + " ##[group]Run inner.sh")
        self.assertIs(excuse.failed_view(github.jobs[1], github.log(REPO, github.jobs[1]), base=False, **UNKNOWN),
                      excuse.UNPLACED)
        said = "\n".join(excuse.judge(REPO, "feat-cmux-next", HEAD, [10], github, **self.PURPOSE))
        self.assertTrue(said.startswith(f"excused '{self.JOB}': fixed on base ("), said)

    # #41117's review at 56ed528a (receipt issuecomment-6788710856) and #41104's at 14c9b7d6 (issuecomment-6788724645).
    def test_review_f1_a_land_never_gets_the_per_step_excuse(self):
        # merge_hold's land (tools/merge_hold.py actions_verdict: no purpose, or --purpose land) judges the same red
        # update_branch would excuse per step: refused, the per-step reading named as not its own.
        fixed = (({self.MOTION: "quiet-red"}, {}), ({self.SURFACES: "quiet-red"}, {}), ({self.MOTION: "quiet-red"}, {}))
        self.assertTrue(self.judge(*fixed)[0].startswith(f"excused '{self.JOB}': fixed on base ("))
        for purpose in (None, "land"):
            with self.subTest(purpose=purpose):
                self.refused(f"per step: the per-step reading is for --purpose update-branch alone .*purpose land",
                             *fixed, purpose=purpose)
        self.refused("purpose 'merge' is not one of land, update-branch; nothing was judged", *fixed, purpose="merge")
        with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
            excuse.main(["--repo", REPO, "--base", "feat-cmux-next", "--sha", HEAD, "--purpose", "merge"])

    def test_review_f1_a_new_failure_in_a_step_red_at_the_merge_base_is_not_excused(self):
        # Unit tests were red at the merge-base, green on the base after it; the head adds an error of its own there.
        self.refused(r"per step: failures not in feat-cmux-next run 19 at the merge-base, so not the base's: .*"
                     r"New\.swift:9: ",
                     ({self.UNIT: "new-red"}, {}), ({}, {}), ({self.UNIT: "red"}, {}))
        # And in a continue-on-error step, whose errors only its job's annotations carry.
        self.refused(r"per step: failures not in feat-cmux-next run 19 at the merge-base, so not the base's: .*"
                     r"New\.swift:9: ",
                     ({self.MOTION: "new-quiet"}, {}), ({}, {}), ({self.MOTION: "quiet-red"}, {}))
        # The same errors as at the merge-base stay excused.
        self.assertIn(f"step '{self.UNIT}'", self.judge(({self.UNIT: "red"}, {}), ({}, {}), ({self.UNIT: "red"}, {}))[0])

    def test_review_f3_the_merge_bases_own_run_is_its_verdict_before_older_runs(self):
        # A push run at the merge-base starts after its commit: created after the merge-base time, it was never read,
        # and an older run's red stood for the merge-base's. Its own run passed the step: the PR's own red.
        self.dispatches = [{"id": 21, "event": "push", "head_branch": "feat-cmux-next", "status": "completed",
                            "conclusion": "success", "head_sha": BASE_SHA, "check_suite_node_id": "CS_21",
                            "created_at": "2026-11-11T01:30:00Z"}]
        github = self.github(({self.MOTION: "quiet-red"}, {}), ({self.SURFACES: "quiet-red"}, {}),
                             ({self.MOTION: "quiet-red"}, {}))
        github.jobs[5], github.logs[5] = self.side(5, 21, BASE_SHA, {})
        with self.assertRaisesRegex(excuse.Refused, "per step: the PR's own red: .* run 21 was not red in it: "
                                                    f"'{self.MOTION}' is success"):
            excuse.judge(REPO, "feat-cmux-next", HEAD, [10], github, **self.PURPOSE)

    def test_review_f4_every_error_annotation_counts_toward_the_cap(self):
        # GitHub keeps 10 error annotations a step: 2 rollup markers beside 8 other errors may be a cut list.
        github = self.github(({self.MOTION: "quiet-red", self.SURFACES: "quiet-red"}, {}), ({self.UNIT: "red"}, {}),
                             ({self.MOTION: "quiet-red", self.SURFACES: "quiet-red"}, {}))
        self.notes[1] += [{"annotation_level": "failure", "message": f"error {n}"} for n in range(5)]
        self.assertEqual(sum(note["annotation_level"] == "failure" for note in self.notes[1]),
                         excuse.ANNOTATION_STEP_CAP)
        with self.assertRaisesRegex(excuse.Refused, f"per step: rollup '{self.ROLLUP}' of head job 1 failed, and its "
                                                    "annotations do not name its reds"):
            excuse.judge(REPO, "feat-cmux-next", HEAD, [10], github, **self.PURPOSE)
        del self.notes[1][-1]  # 9: complete
        said = "\n".join(excuse.judge(REPO, "feat-cmux-next", HEAD, [10], github, **self.PURPOSE))
        self.assertTrue(said.startswith(f"excused '{self.JOB}': fixed on base ("), said)

    def test_review_41104_f1_annotations_are_read_past_their_first_page(self):
        # The base job's rollup names Motion red on its second page, after 100 annotations (Surface roles among them).
        github = self.github(({self.MOTION: "quiet-red"}, {}), ({self.MOTION: "quiet-red", self.SURFACES: "quiet-red"}, {}),
                             ({self.MOTION: "quiet-red"}, {}))
        motion = next(note for note in self.notes[2] if note["message"] == f"red check: {self.MOTION}")
        self.notes[2].remove(motion)
        self.notes[2][1:1] = [{"annotation_level": "warning", "message": f"ratchet {n}"} for n in range(100)]
        self.notes[2].append(motion)
        with self.assertRaisesRegex(excuse.Refused, f"per step: not green in feat-cmux-next run 20: '{self.MOTION}' "
                                                    "is failure"):
            excuse.judge(REPO, "feat-cmux-next", HEAD, [10], github, **self.PURPOSE)
        # A full page that is not continued is a cut list: unknown.
        unpaged = self.github(({self.MOTION: "quiet-red"}, {}), ({self.SURFACES: "quiet-red"}, {}),
                              ({self.MOTION: "quiet-red"}, {}))
        self.notes[1] += [{"annotation_level": "warning", "message": f"ratchet {n}"} for n in range(100)]
        inner = unpaged.json
        unpaged.json = lambda route, *, paginate=False: (inner(route, paginate=paginate)[0]
                                                         if "/annotations" in route and paginate
                                                         else inner(route, paginate=paginate))
        with self.assertRaisesRegex(excuse.Refused, "annotations do not name its reds"):
            excuse.judge(REPO, "feat-cmux-next", HEAD, [10], unpaged, **self.PURPOSE)

    def test_review_41158_f2_a_failing_line_is_matched_by_its_full_path(self):
        # #41158's review F2: path_errors and step_evidence kept the file name alone, so Other/A2.swift at the head
        # matched Sources/A2.swift at the merge-base.
        for step, state in ((self.UNIT, "red"), (self.MOTION, "quiet-red")):
            with self.subTest(step=step):
                github = self.github(({step: state}, {}), ({}, {}), ({step: state}, {}))
                github.logs[1] = github.logs[1].replace("/Sources/A", "/Other/A")
                for note in self.notes[1]:
                    if note.get("path"):
                        note["path"] = note["path"].replace("Sources/", "Other/")
                with self.assertRaisesRegex(excuse.Refused, r"failures not in feat-cmux-next run 19 at the merge-base, "
                                                            r"so not the base's: .*Other/A\d\.swift"):
                    excuse.judge(REPO, "feat-cmux-next", HEAD, [10], github, **self.PURPOSE)
                # The same full path, printed under the runner's checkout root on one side, still matches.
                said, _ = self.judge(({step: state}, {}), ({}, {}), ({step: state}, {}))
                self.assertIn(f"step '{step}'", said)
        self.assertEqual(excuse.repo_path("/home/runner/work/cmux/cmux/Sources/A.swift"), "Sources/A.swift")
        self.assertEqual(excuse.repo_path("./Sources/A.swift"), "Sources/A.swift")
        self.assertNotEqual(excuse.repo_path("/elsewhere/Sources/A.swift"), "Sources/A.swift")

    def test_a_step_absent_at_the_merge_base_and_green_on_base_is_fixed_on_base_for_update_branch_alone(self):
        # hq#9137 at e34418c5: Skill documentation tests failed in "The deleted-or-weakened-tests
        # guard ...", a step the base added after the merge-base (absent from merge-base job 130336035846) and green
        # on main run 42975394561. The merge-base job read its steps, and the step is not one of them.
        guard = "The deleted-or-weakened-tests guard judges tests by what they do and what runs them"
        with unittest.mock.patch.object(type(self), "ORDER", (self.MOTION, self.SURFACES, guard, self.ROLLUP)):
            def absent(purpose="update-branch", newest=None, steps=None, missing_on_base=False):
                github = self.github(({guard: "red"}, {}), (newest or {}, {}), ({}, {}))
                for job in [3] + [2] * missing_on_base:
                    github.jobs[job]["steps"] = [step for step in github.jobs[job]["steps"] if step["name"] != guard]
                if steps is not None:
                    github.jobs[3]["steps"] = steps
                return "\n".join(excuse.judge(REPO, "feat-cmux-next", HEAD, [10], github, purpose=purpose))
            said = absent()
            self.assertTrue(said.startswith(f"excused '{self.JOB}': fixed on base (run 10 / {self.JOB}, "), said)
            self.assertIn(f"'{guard}': passes in feat-cmux-next run 20", said)
            self.assertIn(f"'{guard}' absent from feat-cmux-next run 19 at {BASE_SHA[:12]}, at or before it "
                          "(added to feat-cmux-next since)", said)
            # A land never gets it.
            for purpose in (None, "land"):
                with self.subTest(purpose=purpose), self.assertRaisesRegex(excuse.Refused, "--purpose update-branch alone"):
                    absent(purpose)
            # Missing on the base's newest run still refuses: absence proves nothing there. (Red there, the job-level
            # read judges it as the base's own red, the same failure; the per-step reading never says green.)
            with self.assertRaisesRegex(excuse.Refused, f"step '{guard}' is missing in base job 2"):
                absent(missing_on_base=True)
            # A merge-base job whose steps are unread, or has a nameless step, is not proof the step was absent.
            for steps in ([], [{"name": "", "status": "completed", "conclusion": "success"}]):
                # (No steps at all is no verdict: refused_at_setup.)
                with self.subTest(steps=steps), self.assertRaisesRegex(
                        excuse.Refused, f"per step: (step '{guard}' is missing in merge-base job 3|no feat-cmux-next "
                                        "verdict for it at or before the merge-base)"):
                    absent(steps=steps)
            # hq#9168, the contrast: its merge-base had the step, red there, so the old rule (c) excuses it.
            said = self.judge(({guard: "red"}, {}), ({}, {}), ({guard: "red"}, {}))[0]
            self.assertIn(f"red in feat-cmux-next run 19 at {BASE_SHA[:12]}", said)
            self.assertNotIn("absent from", said)
            # And one green there is the PR's own.
            self.refused(f"the PR's own red: .* run 19 was not red in it: '{guard}' is success",
                         ({guard: "red"}, {}), ({}, {}), ({}, {}))

    def test_review_41104_f2_the_base_callers_workflow_gives_the_merge_bases_verdict(self):
        # ci.yml's web job runs on pull requests alone; cmux-next-web.yml calls it on base pushes (BASE_WORKFLOW_FOR).
        # The base verdict is the caller's, so the merge-base's is read from the caller's runs and named in the line.
        self.caller_only, self.head_path = True, ".github/workflows/ci.yml"
        with unittest.mock.patch.object(type(self), "JOB", "web / cmux-next checks"):
            said, github = self.judge(({self.MOTION: "quiet-red"}, {}), ({self.SURFACES: "quiet-red"}, {}),
                                      ({self.MOTION: "quiet-red"}, {}))
        self.assertTrue(said.startswith("excused 'web / cmux-next checks': fixed on base (run 10 / web / cmux-next "
                                        "checks, job 1, workflow .github/workflows/ci.yml, base workflow "
                                        "cmux-next-web.yml;"), said)
        self.assertIn(f"repos/{REPO}/actions/workflows/cmux-next-web.yml/runs?branch=feat-cmux-next&head_sha={BASE_SHA}"
                      f"&per_page={excuse.STEP_PRIOR_RUNS}", github.routes)

# What judge() refuses a red of the unplaced fixture with when the pin rule does not take it: the base passed the job,
# and the per-step reading finds the head's red step green at the merge-base too (the PR's own red).
NOT_JUDGED = "is not red on feat-cmux-next run 20 .*does not map one to one onto its steps|per step:"


class RollupJobReadsItsNamedReds(unittest.TestCase):
    """2026-11-11, cmux#40552 at fe40e511: its checks job (run 42895363602, job 130212680188) is red only for its
    step-A Rust change's stale app FFI pin, which the step-A rule excuses. Since #40542 (a23139960ea5) step_owners
    does not place its log (more steps start in one second than whole-second times tell apart), so the rule, which
    read the placed log's signature, was never reached; the per-step reading read the rollup's reds from the check
    run's annotations, and run attempt 2 had carried the job over without re-running it, so its check run had none
    (they stayed on attempt 1's check run 130107053043). The rollup's own list still names its reds: the jobs API's
    steps and that list are the job's every red. Read whole (#41158's UnplacedSignature), its log also holds a passing
    step's error-looking next-batch lines, so the pin rule sets the pin aside there. The fixture is the job's log and
    steps, trimmed to steps 53 to 62 (53 prints those lines) with the runner's own around them; its log is still not
    placed."""

    JOB = "cmux-next checks (god files, concurrency, crash safety, l10n)"
    PIN = "Check the app FFI pin"
    FIXTURES = ROOT / "tests/fixtures/test_reds"
    LOG = (FIXTURES / "cmux-40552-checks-job-130212680188.log").read_text(encoding="utf-8").replace("﻿", "")
    EXCUSED = (f"excused '{JOB}': only '{PIN}' is red (\"error: the app FFI sources changed since the pinned "
               "source\"), and #40552 changes app FFI inputs, not Packages/macOS/CmuxNext/Package.swift and no Swift: "
               "a step-A Rust change, pinned by the release its merge publishes")
    RUST = ("cmux-tui/crates/cmux-cloud-machine/src/refusals.rs", "cmux-tui/crates/cmux-cloud-start-core/src/moves/cli.rs")

    def setUp(self):
        test = self
        self.notes: list[dict] = []  # the head check run's annotations: none, as run attempt 2's carried-over job had

        class GitHub(FakeGitHub):
            def json(self, route, *, paginate=False):
                if route.endswith("/check-runs/1/annotations?per_page=100"):
                    self.routes.append(route)
                    if isinstance(test.notes, Exception):
                        raise test.notes  # the read failed: GitHub answered 503
                    return copy.deepcopy(test.notes)
                return super().json(route, paginate=paginate)

            def log(self, repo, job):
                return self.logs[job["id"]]  # the job-log endpoint's own text, steps with their times

        job = json.loads((self.FIXTURES / "cmux-40552-checks-job-130212680188.json").read_text())
        self.gh = GitHub()
        green = [dict(step, conclusion="success") for step in job["steps"]]
        # The base's newest run passed the job: the pin is the head's own red, never the base's.
        self.gh.jobs = {1: dict(job, id=1, run_id=10, head_sha=HEAD),
                        2: dict(job, id=2, run_id=20, head_sha=BASE_SHA, conclusion="success", steps=green)}
        self.gh.logs = {1: self.LOG, 2: ""}
        self.graphql: list[list[str]] = []
        self.files(*self.RUST)

    def files(self, *paths):
        self.gh.run = pr_graphql(self, self.graphql, paths, number=40552)

    def judge(self):
        return excuse.judge(REPO, "feat-cmux-next", HEAD, [10], self.gh)

    def refused(self, pattern):
        with self.assertRaisesRegex(excuse.Refused, pattern) as raised:
            self.judge()
        self.assertNotIn("excused", str(raised.exception))
        return str(raised.exception)

    def rollup(self, *reds, count=None, extra=()):
        """The fixture's log with its rollup's red lines and list naming REDS (COUNT in its summary line)."""
        stamp = "2026-11-10T20:32:21.8714505Z "
        said = [f"{stamp}##[error]red check: {red}" for red in reds]
        said += [f"{stamp}### {len(reds) if count is None else count} cmux-next check(s) failed", stamp.rstrip()]
        said += [f"{stamp}- {red} (failure)" for red in reds] + [stamp.rstrip(), *extra]
        old = ("2026-11-10T20:32:21.8714505Z ##[error]red check: Check the app FFI pin\n"
               "2026-11-10T20:32:21.8718839Z ### 1 cmux-next check(s) failed\n"
               "2026-11-10T20:32:21.8718929Z \n"
               "2026-11-10T20:32:21.8718999Z - Check the app FFI pin (failure)\n"
               "2026-11-10T20:32:21.8719087Z \n")
        self.assertEqual(self.LOG.count(old), 1)
        return self.LOG.replace(old, "\n".join(said) + "\n")

    def test_the_fixture_log_is_not_placed(self):
        self.assertIs(excuse.failed_view(self.gh.jobs[1], self.LOG, base=False, **UNKNOWN), excuse.UNPLACED)
        # Read whole, a passing step's lines are among its errors: only the rollup's list tells the job's reds.
        whole = excuse.unplaced_signature(self.gh.jobs[1], self.LOG)
        self.assertTrue(any(error.startswith("[next-batch") for error in whole.errors), whole.errors)

    def test_a_carried_over_jobs_stale_ffi_pin_is_excused_from_its_rollups_own_list(self):
        self.assertEqual(self.judge(), [self.EXCUSED])
        self.assertEqual(len(self.graphql), 1)

    def test_its_rollup_annotations_excuse_it_too(self):
        # A job that ran in its own attempt: its check run has the annotations, and they are read first.
        self.notes = [{"annotation_level": "failure", "title": "cmux-next check", "message": f"red check: {self.PIN}"}]
        self.assertEqual(self.judge(), [self.EXCUSED])

    def test_the_rollup_log_names_the_reds_its_annotations_would(self):
        self.assertEqual(excuse.rollup_log_reds(self.LOG), {self.PIN})
        two = ("Motion tokens", self.PIN)
        self.assertEqual(excuse.rollup_log_reds(self.rollup(*two)), set(two))
        for case, text in {
            "a count that is not its lines'": self.rollup(self.PIN, count=2),
            "a list that names another check": self.rollup(self.PIN).replace(f"- {self.PIN} (failure)",
                                                                               "- Motion tokens (failure)"),
            "a second summary": self.rollup(self.PIN, extra=["2026-11-10T20:32:21.87Z ### 0 cmux-next check(s) failed"]),
            "a red line away from its summary": self.LOG.replace(
                "2026-11-10T20:31:59.4061566Z ##[group]Run",
                "2026-11-10T20:31:59.4061Z ##[error]red check: Motion tokens\n2026-11-10T20:31:59.4061566Z ##[group]Run"),
            "no summary": self.LOG.replace("### 1 cmux-next check(s) failed", "### checks failed"),
        }.items():
            with self.subTest(case):
                self.assertIsNone(excuse.rollup_log_reds(text))

    def test_another_red_check_beside_the_pin_is_not_excused(self):
        self.gh.logs[1] = self.rollup("Motion tokens", self.PIN)
        self.refused(NOT_JUDGED)

    def test_another_failed_step_beside_the_rollup_is_not_excused(self):
        step = next(step for step in self.gh.jobs[1]["steps"] if step["name"] == "Daemon capabilities export is fresh")
        step["conclusion"] = "failure"
        self.refused(NOT_JUDGED)

    def test_a_rollup_list_that_cannot_be_read_is_not_excused(self):
        self.gh.logs[1] = self.rollup(self.PIN, count=2)
        self.refused(NOT_JUDGED)
        # The per-step reading (update-branch's alone, #41158) says why: no annotation and no readable list.
        with self.assertRaisesRegex(excuse.Refused, "its annotations do not name its reds .*, nor does its log"):
            excuse.judge(REPO, "feat-cmux-next", HEAD, [10], self.gh, purpose=excuse.PER_STEP_PURPOSE)

    def test_a_pin_error_printed_twice_or_not_at_all_is_not_excused(self):
        line = "2026-11-10T20:31:58.7617120Z error: the app FFI sources changed since the pinned source "
        for case, text in {"twice": self.LOG.replace(line, line + "x\n" + line),
                           "not at all": self.LOG.replace(line, "2026-11-10T20:31:58.7617120Z note: ")}.items():
            with self.subTest(case):
                self.gh.logs[1] = text
                self.refused(NOT_JUDGED)

    def test_a_crash_anywhere_in_an_unplaced_log_is_not_excused(self):
        self.gh.logs[1] = self.LOG.replace("2026-11-10T20:31:59.4061566Z ##[group]Run",
                                           "2026-11-10T20:31:59.40Z error: the test helper died on signal 11\n"
                                           "2026-11-10T20:31:59.4061566Z ##[group]Run")
        # test_reds.read finds it before any rule is asked; crashed_anywhere keeps the pin rule from reading past it.
        self.refused("crash")

    def test_review_f1_a_failed_annotation_read_never_refuses_what_the_whole_log_excuses(self):
        # Review of cmux#41151 at fd50c9b7 (F1): the rollup reading's annotation read is an extra one. When it fails,
        # the whole-log rule's verdict stands: an excuse when the log has no other error line, as before #41151.
        self.notes = excuse.Refused("gh: Service Unavailable (HTTP 503)")
        quiet = "\n".join(line for line in self.LOG.splitlines() if "base tier verdict for cmux-next" not in line)
        self.assertFalse([error for error in excuse.unplaced_signature(self.gh.jobs[1], quiet).errors
                          if "next-batch" in error])
        self.gh.logs[1] = quiet
        self.assertEqual(self.judge(), [self.EXCUSED])
        # With the passing step's lines the whole log sets the pin aside, and an unread rollup cannot excuse it: the
        # red is judged as before (refused here), never refused for the read itself.
        self.gh.logs[1] = self.LOG
        self.assertNotIn("503", self.refused(NOT_JUDGED))

    def test_the_pin_rule_still_refuses_a_head_it_does_not_cover(self):
        self.files(*self.RUST, "scripts/cmux-next/check-app-ffi-pin.sh")
        self.refused("changes the app FFI pin check's code")


class RollupLogRedsByStep(StepFixture, unittest.TestCase):
    """fixed_on_base_by_step reads a head rollup's reds the same way: from its check run's annotations, or, when they
    name none (a job a re-run attempt carried over), from the rollup's own list in its log (rollup_log_reds)."""

    PURPOSE = {"purpose": excuse.PER_STEP_PURPOSE}  # the per-step reading's one caller

    def unnamed(self):
        # The head's annotations with no `red check:` one: its file errors stay, which #41158's step reading compares.
        self.notes[1] = [note for note in self.notes[1] if not str(note.get("message", "")).startswith("red check: ")]

    def listed(self, github, *reds):
        # StepFixture's rollup prints its red lines alone; the real one lists them under its summary too.
        lines = github.logs[1].splitlines()
        last = max(n for n, line in enumerate(lines) if "##[error]red check: " in line)
        stamp = lines[last].split(" ", 1)[0]
        lines[last + 1:last + 1] = [f"{stamp} ### {len(reds)} cmux-next check(s) failed", stamp,
                                    *(f"{stamp} - {red} (failure)" for red in reds)]
        github.logs[1] = "\n".join(lines)

    def test_a_head_with_no_annotations_is_judged_by_its_rollups_list(self):
        for placed in (True, False):
            with self.subTest(placed=placed):
                github = self.github(({self.MOTION: "quiet-red"}, {}), ({self.SURFACES: "quiet-red"}, {}),
                                     ({self.MOTION: "quiet-red"}, {}))
                self.unnamed()
                with self.assertRaisesRegex(excuse.Refused, "annotations do not name its reds .*, nor does its log"):
                    excuse.judge(REPO, "feat-cmux-next", HEAD, [10], github, **self.PURPOSE)
                if not placed:
                    github.logs[1] = github.logs[1].replace(
                        "##[group]Run scripts/check-1.sh",
                        "##[group]Run a/composite@v1\n" + github.logs[1].splitlines()[3][:28] + " ##[group]Run inner.sh")
                self.listed(github, self.MOTION)
                said = "\n".join(excuse.judge(REPO, "feat-cmux-next", HEAD, [10], github, **self.PURPOSE))
                self.assertTrue(said.startswith(f"excused '{self.JOB}': fixed on base ("), said)
                self.assertIn(f"step '{self.MOTION}'", said)

    def test_the_rollups_list_never_names_a_red_it_lacks(self):
        # The list names Surface roles too, which the base's newest run fails: not fixed on base.
        github = self.github(({self.MOTION: "quiet-red"}, {}), ({self.SURFACES: "quiet-red"}, {}),
                             ({self.MOTION: "quiet-red"}, {}))
        self.unnamed()
        lines = github.logs[1].splitlines()
        last = max(n for n, line in enumerate(lines) if "##[error]red check: " in line)
        lines.insert(last + 1, lines[last].replace(self.MOTION, self.SURFACES))
        github.logs[1] = "\n".join(lines)
        self.listed(github, self.MOTION, self.SURFACES)
        with self.assertRaisesRegex(excuse.Refused, f"'{self.SURFACES}' is failure"):
            excuse.judge(REPO, "feat-cmux-next", HEAD, [10], github, **self.PURPOSE)


# cmux#40984 at a6698ad5: 'next-autoland / verdict' read "its own red: cmux-next / cmux-next checks (god files,
# concurrency, crash safety, l10n) (and 2 more red, not probed)", and judge() refused it as a status with no job. It is a
# derived status (DERIVED_STATUSES): judged by every red at the head, each judged by judge() itself. Its parts here are
# StepFixture's jobs, renamed: head job 10*i+1 in run 10, the base's newest 10*i+2 in run 20, the merge-base's
# 10*i+3 in run 19.
class DerivedStatusByParts(StepFixture, unittest.TestCase):
    VERDICT = "next-autoland / verdict"
    FAST = "cmux-next fast tier"
    GENERATED = "cmux-next generated files"
    FIXED = ({StepFixture.MOTION: "quiet-red"}, {StepFixture.SURFACES: "quiet-red"},
             {StepFixture.MOTION: "quiet-red"})  # head, newest base, merge-base: fixed on base by its step
    BUILD_FIXED = ({StepFixture.UNIT: "red"}, {}, {StepFixture.UNIT: "red"})
    OWN = ({StepFixture.UNIT: "red"}, {}, {})  # green on base before and after the merge-base

    def parts(self, parts, description, *, extra_checks=(), check_total=None, green_statuses=0, extra_statuses=()):
        """A head whose red jobs are PARTS ((job name, (head, newest, prior) states), ...) and whose derived status
        reads DESCRIPTION."""
        github = self.github(({}, {}), ({}, {}), ({}, {}))
        github.jobs, github.logs = {}, {}
        for n, (name, states) in enumerate(parts):
            for k, (run_id, sha, side) in enumerate(((10, HEAD, states[0]), (20, self.NEWER, states[1]),
                                                     (19, BASE_SHA, states[2]))):
                job_id = 10 * n + k + 1
                job, github.logs[job_id] = self.side(job_id, run_id, sha, side)
                github.jobs[job_id] = dict(job, name=name)
        statuses = [{"context": f"green {n}", "state": "success", "description": "ok"} for n in range(green_statuses)]
        statuses += [{"context": self.VERDICT, "state": "failure", "description": description},
                     {"context": "Vercel", "state": "success", "description": "Deployed"}]
        statuses += copy.deepcopy(list(extra_statuses))
        inner = github.json

        def json(route, *, paginate=False):
            if route.endswith(f"commits/{HEAD}/status?per_page=100"):
                # GitHub's combined status: 100 contexts a page, total_count all of them.
                github.routes.append(route)
                pages = [{"state": "failure", "total_count": len(statuses), "statuses": copy.deepcopy(statuses[n:n + 100])}
                         for n in range(0, len(statuses), 100)]
                return pages if paginate else pages[0]
            found = inner(route, paginate=paginate)
            if route.endswith(f"commits/{HEAD}/check-runs?filter=all&per_page=100"):
                found[0]["check_runs"] += copy.deepcopy(list(extra_checks))
                found[0]["total_count"] = check_total or len(found[0]["check_runs"])
            return found
        github.json = json
        return github

    def own(self, key, more=0):
        return f"its own red: cmux-next / {key}" + (f" (and {more} more red, not probed)" if more else "")

    def test_every_part_excused_excuses_the_derived_status(self):
        github = self.parts([(self.JOB, self.FIXED), (self.FAST, self.BUILD_FIXED)], self.own(self.JOB, 1))
        said = excuse.judge(REPO, "feat-cmux-next", HEAD, [], github, checks=[self.VERDICT], **self.PURPOSE)
        self.assertEqual(sorted(line.split("'")[1] for line in said), sorted([self.JOB, self.FAST, self.VERDICT]))
        self.assertTrue(said[-1].startswith(f"excused '{self.VERDICT}': fixed on base (a derived status: its red is a "
                                            f"function of the 2 red checks at {HEAD[:12]}"), said[-1])

    def test_fast_tier_and_generated_files_go_through_the_per_step_path(self):
        # No rule of their own: their failing step is fixed on base like any other job's.
        github = self.parts([(self.FAST, self.BUILD_FIXED), (self.GENERATED, self.BUILD_FIXED)],
                            self.own(self.FAST, 1))
        said = excuse.judge(REPO, "feat-cmux-next", HEAD, [10], github, checks=[self.VERDICT], **self.PURPOSE)
        for name in (self.FAST, self.GENERATED):
            line = next(line for line in said if line.startswith(f"excused '{name}'"))
            self.assertTrue(line.startswith(f"excused '{name}': fixed on base (run 10 / {name}, "), line)
            self.assertIn(f"step '{self.UNIT}'", line)

    def test_one_part_not_excused_keeps_the_derived_status_red(self):
        github = self.parts([(self.JOB, self.FIXED), (self.FAST, self.OWN)], self.own(self.JOB, 1))
        with self.assertRaisesRegex(excuse.Refused, f"'{self.FAST}'.*per step: the PR's own red: .* run 19 was not "
                                                    f"red in it: '{self.UNIT}' is success"):
            excuse.judge(REPO, "feat-cmux-next", HEAD, [], github, checks=[self.VERDICT], **self.PURPOSE)

    def test_an_unprobed_part_is_not_excused(self):
        # A check still running at the head, or a check-run list that came back short, leaves a part unread.
        running = {"id": 99, "name": "cmux-next daemon tests", "status": "in_progress", "conclusion": None,
                   "app": {"slug": "github-actions"},
                   "details_url": f"https://github.com/{REPO}/actions/runs/10/job/99"}
        for kwargs, pattern in (({"extra_checks": [running]}, "'cmux-next daemon tests' not finished"),
                                ({"check_total": 7}, "came back incomplete \\(1 read of 7\\)")):
            with self.subTest(pattern=pattern):
                github = self.parts([(self.JOB, self.FIXED)], self.own(self.JOB), **kwargs)
                with self.assertRaisesRegex(excuse.Refused, pattern):
                    excuse.judge(REPO, "feat-cmux-next", HEAD, [], github, checks=[self.VERDICT], **self.PURPOSE)

    def test_a_derived_status_naming_a_check_the_head_does_not_have_is_not_excused(self):
        github = self.parts([(self.JOB, self.FIXED)], self.own("cmux-next daemon tests"))
        with self.assertRaisesRegex(excuse.Refused, f"'{self.VERDICT}' names 'cmux-next / cmux-next daemon tests', "
                                                    "which is not red at"):
            excuse.judge(REPO, "feat-cmux-next", HEAD, [], github, checks=[self.VERDICT], **self.PURPOSE)
        # Or counting more reds than the head has.
        github = self.parts([(self.JOB, self.FIXED)], self.own(self.JOB, 2))
        with self.assertRaisesRegex(excuse.Refused, "counts 3 reds, and aaaaaaaaaaaa has 1"):
            excuse.judge(REPO, "feat-cmux-next", HEAD, [], github, checks=[self.VERDICT], **self.PURPOSE)

    def test_f1_a_third_party_red_sharing_an_actions_jobs_name_is_unknown(self):
        # A newer check of another app, red, with the Actions job's name: judged by name, the Actions job's base
        # evidence excused it. Its identity is "other-ci / NAME", never "run 10 / NAME": unknown, not excused.
        other = {"id": 999, "name": self.JOB, "status": "completed", "conclusion": "failure",
                 "app": {"slug": "other-ci"}, "details_url": "https://ci.example.com/build/1"}
        github = self.parts([(self.JOB, self.FIXED)], self.own(self.JOB), extra_checks=[other])
        with self.assertRaisesRegex(excuse.Refused, f"'other-ci / {re.escape(self.JOB)}'"):
            excuse.judge(REPO, "feat-cmux-next", HEAD, [], github, checks=[self.VERDICT], **self.PURPOSE)
        # Another app's red of its own name has no job judge() can rule on either.
        github = self.parts([(self.JOB, self.FIXED)], self.own(self.JOB), extra_checks=[dict(other, name="lint")])
        with self.assertRaisesRegex(excuse.Refused, "'other-ci / lint' is another app's check"):
            excuse.judge(REPO, "feat-cmux-next", HEAD, [], github, checks=[self.VERDICT], **self.PURPOSE)

    def test_f1_one_name_red_in_two_actions_runs_is_unknown(self):
        github = self.parts([(self.JOB, self.FIXED)], self.own(self.JOB))
        twin, github.logs[90] = self.side(90, 11, HEAD, {self.MOTION: "quiet-red"})
        github.jobs[90] = twin
        with self.assertRaisesRegex(excuse.Refused, "red in 2 Actions runs at"):
            excuse.judge(REPO, "feat-cmux-next", HEAD, [], github, checks=[self.VERDICT], **self.PURPOSE)

    def test_f2_a_red_aggregate_part_carries_its_own_judgement(self):
        # ci-status, red for its one failed job under its needs ('macos / ...'), is excused when judged alone; as a
        # part of the derived status it was refused for having no line of its own.
        child = "macos / cmux-next checks"
        github = self.parts([(child, self.FIXED)], self.own("ci-status", 1))
        github.jobs[50] = {"id": 50, "run_id": 10, "head_sha": HEAD, "name": "ci-status", "status": "completed",
                           "conclusion": "failure", "steps": [{"name": "Report", "status": "completed",
                                                                "conclusion": "failure"}]}
        alone = excuse.judge(REPO, "feat-cmux-next", HEAD, [], github, checks=["ci-status"], **self.PURPOSE)
        self.assertTrue(any(line.startswith(f"excused '{child}': fixed on base (") for line in alone), alone)
        said = excuse.judge(REPO, "feat-cmux-next", HEAD, [], github, checks=[self.VERDICT], **self.PURPOSE)
        line = next(line for line in said if line.startswith("excused 'ci-status'"))
        self.assertTrue(line.startswith("excused 'ci-status': fixed on base (run 10 / ci-status: an aggregate"), line)
        self.assertTrue(said[-1].startswith(f"excused '{self.VERDICT}': fixed on base ("), said[-1])

    def test_f3_the_combined_status_is_read_past_100_contexts(self):
        # 101 contexts: the derived status is the 100th, its parts' reds past the first page would be unread.
        github = self.parts([(self.JOB, self.FIXED)], self.own(self.JOB), green_statuses=99)
        github_red = self.parts([(self.JOB, self.FIXED)], self.own(self.JOB), green_statuses=99)
        said = excuse.judge(REPO, "feat-cmux-next", HEAD, [], github, checks=[self.VERDICT], **self.PURPOSE)
        self.assertTrue(said[-1].startswith(f"excused '{self.VERDICT}': fixed on base ("), said[-1])
        # A red context on the second page is a part too: one judge() cannot rule on keeps it red.
        statuses_route = f"repos/{REPO}/commits/{HEAD}/status?per_page=100"
        inner = github_red.json

        def json(route, *, paginate=False):
            found = inner(route, paginate=paginate)
            if route == statuses_route and paginate:
                found[-1]["statuses"].append({"context": "Vercel – docs", "state": "failure", "description": "x"})
                for page in found:
                    page["total_count"] += 1
            return found
        github_red.json = json
        with self.assertRaisesRegex(excuse.Refused, "Vercel – docs"):
            excuse.judge(REPO, "feat-cmux-next", HEAD, [], github_red, checks=[self.VERDICT], **self.PURPOSE)

    def test_review_f2_a_status_and_an_actions_job_of_one_name_are_unknown(self):
        # A failing commit status named as the Actions job: judged by name, both read the job's one line.
        github = self.parts([(self.JOB, self.FIXED)], self.own(self.JOB, 1),
                            extra_statuses=[{"context": self.JOB, "state": "failure", "description": "x"}])
        with self.assertRaisesRegex(excuse.Refused, f"'status / {re.escape(self.JOB)}' and a check run share the name"):
            excuse.judge(REPO, "feat-cmux-next", HEAD, [], github, checks=[self.VERDICT], **self.PURPOSE)
        # A green status beside a red job of its name is unknown too.
        github = self.parts([(self.JOB, self.FIXED)], self.own(self.JOB),
                            extra_statuses=[{"context": self.JOB, "state": "success", "description": "x"}])
        with self.assertRaisesRegex(excuse.Refused, "share the name"):
            excuse.judge(REPO, "feat-cmux-next", HEAD, [], github, checks=[self.VERDICT], **self.PURPOSE)

    def test_review_f1_the_derived_status_gets_no_per_step_excuse_on_a_land(self):
        github = self.parts([(self.JOB, self.FIXED)], self.own(self.JOB))
        with self.assertRaisesRegex(excuse.Refused, "per-step reading is for --purpose update-branch alone"):
            excuse.judge(REPO, "feat-cmux-next", HEAD, [], github, checks=[self.VERDICT])

    def test_a_derived_status_red_for_another_reason_is_not_judged_by_its_parts(self):
        github = self.parts([(self.JOB, self.FIXED)], "conflicting with feat-cmux-next")
        with self.assertRaisesRegex(excuse.Refused, "is not a red of the head's other checks"):
            excuse.judge(REPO, "feat-cmux-next", HEAD, [], github, checks=[self.VERDICT], **self.PURPOSE)



# cmux#41205 at ba8ff399 and cmux#41220 at c7b757f0 (2026-11-11): both red in cmux-next-guards.yml's own-change job
# (step "cmux-next spawn-owner ratchet", job 130449502223) and tooling-tests (test_spawn_owner_ratchet.py's
# test_the_committed_baseline_holds_on_this_tree, job 130449577217), for `check-spawn-owner: cmux-tui/crates/acpmux/
# src/hub/remote_table_bench.rs has 1 spawn line(s) with no owner (a new file).`, a file #41040 added on base. #41227
# fixed it on base and run 43000928251 passed both jobs, but merge_hold and the broker's update_branch refused: "not
# a declared guard job (GUARD_JOBS)". The jobs, their steps and logs are the real ones (tests/fixtures/
# base_red_excuse_spawn_owner: the head jobs, the base run's two jobs, the merge-base run 42998467090's two jobs).
SPAWN_FIXTURES = Path(__file__).resolve().parent / "fixtures/base_red_excuse_spawn_owner"
SPAWN_HEAD, SPAWN_MERGE_BASE, SPAWN_BASE = ("ba8ff399dcc62d673464541c395094e92193c4bd",
                                            "0238fcd45607926b7546c5b1714f4e4a75cb2689",
                                            "83cfd4d7e998b01b6fd31b45fee39658ed1f079f")
SPAWN_HEAD_RUN, SPAWN_BASE_RUN, SPAWN_PRIOR_RUN, SPAWN_WORKFLOW = 42998810174, 43000928251, 42998467090, 379181907
OWN_CHANGE = "cmux-next size cap, crash ratchet, localization debt ratchet, no new generated files"


class SpawnOwnerGitHub:
    """GitHub as judge() read it for cmux#41205 at ba8ff399, from the real jobs and logs; CHANGED is the PR's diff."""

    def __init__(self, changed=("tests/test_ci_sparse_checkout_imports.py",), placed=True):
        self.jobs, self.logs = {}, {}
        for job_id in (130449502223, 130449577217, 130456563743, 130456666797, 130448365318, 130448465080):
            self.jobs[job_id] = json.loads((SPAWN_FIXTURES / f"job-{job_id}.json").read_text())
            if job_id in (130456563743, 130456666797):
                continue  # the base run's passing jobs: their steps are read, never their logs
            text = (SPAWN_FIXTURES / f"job-{job_id}.log").read_text()
            self.logs[job_id] = text
            if placed:
                # The real stamps put the runner's own steps and the next step in one second, which step_owners does
                # not place (cmux#41220 places them by the workflow's step headers). PLACED serves each red job as
                # its one failed step's real lines, framed (framed_steps, framed_log): every line it prints, as
                # printed, at times step_owners places.
                self.jobs[job_id]["steps"], self.logs[job_id] = self.failed_step_only(self.jobs[job_id], text)
        self.changed = list(changed)
        self.runs = {
            SPAWN_HEAD_RUN: {"id": SPAWN_HEAD_RUN, "workflow_id": SPAWN_WORKFLOW, "event": "pull_request",
                             "head_sha": SPAWN_HEAD, "created_at": "2026-11-11T09:52:21Z", "name": "cmux-next guards",
                             "path": ".github/workflows/cmux-next-guards.yml", "status": "completed",
                             "conclusion": "failure"},
            SPAWN_BASE_RUN: {"id": SPAWN_BASE_RUN, "workflow_id": SPAWN_WORKFLOW, "event": "push",
                             "head_branch": "feat-cmux-next", "head_sha": SPAWN_BASE, "created_at": "2026-11-11T10:07:24Z",
                             "status": "completed", "conclusion": "failure"},
            SPAWN_PRIOR_RUN: {"id": SPAWN_PRIOR_RUN, "workflow_id": SPAWN_WORKFLOW, "event": "push",
                              "head_branch": "feat-cmux-next", "head_sha": SPAWN_MERGE_BASE,
                              "created_at": "2026-11-11T09:49:55Z", "status": "completed", "conclusion": "failure"},
        }
        self.pull = {"number": 41205, "state": "open", "mergeable": True, "mergeable_state": "clean",
                     "labels": [{"name": "risk:low"}], "user": {"login": "agent-author", "type": "User"},
                     "author_association": "MEMBER", "body": "", "head": {"sha": SPAWN_HEAD},
                     "base": {"ref": "feat-cmux-next"}}
        self.comments = [ship_comment(SPAWN_HEAD)]
        self.routes: list[str] = []

    def json(self, route, *, paginate=False):
        self.routes.append(route)
        path, _, query = route.partition("?")
        if f"/compare/feat-cmux-next...{SPAWN_HEAD}" in route:
            return {"merge_base_commit": {"sha": SPAWN_MERGE_BASE,
                                          "commit": {"committer": {"date": "2026-11-11T09:49:40Z"}}},
                    "files": [{"filename": name} for name in self.changed]}
        if f"/compare/{SPAWN_MERGE_BASE}...{SPAWN_BASE}" in route:
            return {"status": "ahead"}
        if "/actions/runs/" in path and path.endswith("/jobs"):
            run = int(path.split("/actions/runs/", 1)[1].split("/", 1)[0])
            return [{"jobs": [copy.deepcopy(job) for job in self.jobs.values() if job["run_id"] == run]}]
        if f"/actions/workflows/{SPAWN_WORKFLOW}/runs" in path:
            runs = [copy.deepcopy(run) for run in self.runs.values() if run["event"] == "push"]
            if "head_sha=" in query:
                sha = query.split("head_sha=", 1)[1].split("&", 1)[0]
                runs = [run for run in runs if run["head_sha"] == sha]
            if "created=" in query:
                runs = [run for run in runs if run["id"] == SPAWN_PRIOR_RUN]
            return {"workflow_runs": sorted(runs, key=lambda run: run["created_at"], reverse=True)}
        if "/actions/runs?head_sha=" in route:
            return [{"total_count": 1, "workflow_runs": [copy.deepcopy(self.runs[SPAWN_HEAD_RUN])]}]
        if "/actions/runs/" in path:
            return copy.deepcopy(self.runs[int(path.rsplit("/", 1)[1])])
        if path.endswith("/annotations"):
            return [[]] if paginate else []
        if path.endswith(f"/commits/{SPAWN_HEAD}/pulls"):
            return [self.pull]
        if path.endswith("/pulls/41205"):
            return copy.deepcopy(self.pull)
        if path.endswith("/issues/41205/comments"):
            return [list(self.comments)] if paginate else list(self.comments)
        if path.endswith("/pulls/41205/reviews"):
            return [[]] if paginate else []
        if f"/commits/{SPAWN_MERGE_BASE}/check-runs" in path:
            name = urllib.parse.unquote(query.split("check_name=", 1)[1].split("&", 1)[0])
            return {"check_runs": [{"name": name, "status": "completed", "conclusion": job["conclusion"]}
                                   for job in self.jobs.values() if job["run_id"] == SPAWN_PRIOR_RUN
                                   and job["name"] == name]}
        raise AssertionError(route)

    @staticmethod
    def failed_step_only(job, text):
        """(steps, log) of JOB with only its one failed step, whose section of TEXT is the one with an error line."""
        (step,) = [step for step in job["steps"] if step["conclusion"] == "failure"]
        after = next(later for later in job["steps"] if later["number"] > step["number"]
                     and later["conclusion"] == "success")  # the step that ran next, so the red one is not last
        lines = [excuse.STAMP.sub("", line).lstrip("\ufeff") for line in text.splitlines()]
        starts = [n for n, line in enumerate(lines) if excuse.STEP_START.match(line)] + [len(lines)]
        (at,) = [k for k, (a, b) in enumerate(zip(starts, starts[1:]))
                 if any(line.startswith("##[error]") for line in lines[a:b])]
        section, header = lines[starts[at]:starts[at + 1]], lines[starts[at + 1]]
        return (framed_steps([(step["name"], "failure", 3, 9), (after["name"], "success", 10, 12)]),
                framed_log([(step["name"], 3, line) for line in section] + [(after["name"], 10, header)],
                           job["name"]))

    def log(self, repo, job):
        return self.logs[job["id"]]

    def run(self, args):
        # SuiteChecks' GraphQL read: each suite's check runs of the name, from these jobs.
        assert args[:2] == ["api", "graphql"], args
        query = next(arg for arg in args if arg.startswith("query="))
        name = next(arg for arg in args if arg.startswith("name="))[len("name="):]
        return json.dumps({"data": {"nodes": [
            {"id": f"CS_{run}", "checkRuns": {"pageInfo": {"hasNextPage": False}, "nodes": [
                {"conclusion": (job["conclusion"] or "").upper() or None}
                for job in self.jobs.values() if job["run_id"] == int(run) and job["name"] == name]}}
            for run in re.findall(r'"CS_(\d+)"', query)]}})


class SpawnOwnerFixedOnBase(unittest.TestCase):
    """cmux#41205's two cmux-next-guards.yml reds are fixed on base: excused for a land and for update_branch's base
    merge, and refused when the PR's diff reaches what the check reads."""

    def judge(self, github, purpose=None):
        return excuse.judge(REPO, "feat-cmux-next", SPAWN_HEAD, [SPAWN_HEAD_RUN], github, purpose=purpose)

    def test_41205_at_ba8ff399_is_fixed_on_base_for_a_land(self):
        said = self.judge(SpawnOwnerGitHub())
        self.assertEqual(len(said), 2, said)
        own = next(line for line in said if line.startswith(f"excused '{OWN_CHANGE}': fixed on base ("))
        self.assertIn(f"passes at {SPAWN_BASE[:12]} in feat-cmux-next run {SPAWN_BASE_RUN}", own)
        self.assertIn("PR does not touch scripts/cmux-next/check-spawn-owner.py, "
                      "scripts/cmux-next/spawn-owner-baseline.tsv, cmux-tui/crates/acpmux/", own)
        self.assertIn("check-spawn-owner cmux-tui/crates/acpmux/src/hub/remote_table_bench.rs: 1 spawn line(s) with "
                      "no owner (a new file)", own)
        tooling = next(line for line in said if line.startswith("excused 'tooling-tests': fixed on base ("))
        self.assertIn("PR does not touch tests/test_spawn_owner_ratchet.py, tests/git_fixture_env.py, "
                      "scripts/cmux-next/check-spawn-owner.py", tooling)
        self.assertIn("test_the_committed_baseline_holds_on_this_tree", tooling)

    def test_41205_at_ba8ff399_is_fixed_on_base_for_update_branch(self):
        said = self.judge(SpawnOwnerGitHub(), purpose=excuse.PER_STEP_PURPOSE)
        self.assertEqual(sorted(line.split("': ", 1)[0] for line in said),
                         [f"excused '{OWN_CHANGE}", "excused 'tooling-tests"])
        self.assertTrue(all(": fixed on base (" in line for line in said), said)

    def test_the_real_stamps_get_a_base_merge_and_no_land_until_they_are_placed(self):
        # As GitHub serves them: step_owners does not place these logs (the runner's steps share a second with the
        # next one), so a land is refused on that, never on GUARD_JOBS; update_branch's base merge gets through.
        with self.assertRaisesRegex(excuse.Refused, "does not map one to one onto its steps") as raised:
            self.judge(SpawnOwnerGitHub(placed=False))
        self.assertNotIn("not a declared guard job", str(raised.exception))
        said = self.judge(SpawnOwnerGitHub(placed=False), purpose=excuse.PER_STEP_PURPOSE)
        self.assertEqual(sorted(line.split("': ", 1)[0] for line in said),
                         [f"excused '{OWN_CHANGE}", "excused 'tooling-tests"])
        self.assertTrue(all(": fixed on base (run 42998810174 / " in line for line in said), said)

    def test_the_per_step_reading_matches_the_finding_with_the_merge_bases(self):
        # No SHIP at the head: the job-level rule refuses, and update_branch's per-step reading matches the spawn-owner
        # step's finding (test_reds.CHECK_RULE) with the merge-base run's, where the red was the base's.
        github = SpawnOwnerGitHub()
        github.comments = []
        said = self.judge(github, purpose=excuse.PER_STEP_PURPOSE)
        own = next(line for line in said if line.startswith(f"excused '{OWN_CHANGE}': fixed on base ("))
        self.assertIn("step 'cmux-next spawn-owner ratchet': passes in feat-cmux-next run 43000928251", own)
        self.assertIn(f"red in feat-cmux-next run {SPAWN_PRIOR_RUN}", own)
        # A finding the merge-base did not have is the PR's own: the per-step reading refuses it.
        github = SpawnOwnerGitHub()
        github.comments = []
        github.logs[130448365318] = github.logs[130448365318].replace("remote_table_bench.rs", "other_bench.rs")
        evidence = excuse.step_evidence(excuse.failed_view(
            github.jobs[130449502223], github.logs[130449502223], base=False, **UNKNOWN),
            "cmux-next spawn-owner ratchet")
        self.assertEqual(evidence[0], {"check-spawn-owner cmux-tui/crates/acpmux/src/hub/remote_table_bench.rs: 1 "
                                       "spawn line(s) with no owner (a new file)"})
        with unittest.mock.patch.object(excuse, "green_since", side_effect=excuse.Refused("off")), \
                self.assertRaisesRegex(excuse.Refused, "failures not in feat-cmux-next run 42998467090 at the "
                                                       "merge-base, so not the base's: 'cmux-next spawn-owner ratchet'"):
            self.judge(github, purpose=excuse.PER_STEP_PURPOSE)

    def test_a_diff_that_reaches_the_check_is_refused(self):
        for path in ("scripts/cmux-next/check-spawn-owner.py", "scripts/cmux-next/spawn-owner-baseline.tsv",
                     "cmux-tui/crates/acpmux/src/hub/mod.rs", "cmux-tui/crates/acpmux/src/hub/remote_table_bench.rs"):
            with self.subTest(path=path), self.assertRaisesRegex(excuse.Refused, "reads paths the PR changes"):
                self.judge(SpawnOwnerGitHub(changed=(path,)))
        with self.assertRaisesRegex(excuse.Refused, "reads paths the PR changes: tests/test_spawn_owner_ratchet.py"):
            self.judge(SpawnOwnerGitHub(changed=("tests/test_spawn_owner_ratchet.py",)))

    def test_a_check_line_of_another_shape_is_refused(self):
        # A baseline raised above the base's prints `... raises PATH`: not a finding this rule keys, so not excused.
        github = SpawnOwnerGitHub()
        raised = ("check-spawn-owner: scripts/cmux-next/spawn-owner-baseline.tsv raises cmux-tui/crates/acpmux/src/a.rs"
                  " to 1 (base HEAD^1: 0). The baseline only goes down.")
        text = github.logs[130449502223]
        at = text.index("next: spawn the task")
        stamp = text[:at].rsplit("\n", 1)[1]
        github.logs[130449502223] = text[:at] + raised + "\n" + stamp + text[at:]
        with self.assertRaisesRegex(excuse.Refused, "not its check rule's: check-spawn-owner: scripts/cmux-next/"
                                                    "spawn-owner-baseline.tsv raises"):
            self.judge(github)

    def test_the_check_rule_is_a_named_failure(self):
        line = ("check-spawn-owner: cmux-tui/crates/acpmux/src/hub/remote_table_bench.rs has 1 spawn line(s) with no "
                "owner (a new file).")
        self.assertEqual(excuse.test_reds.failed_names([line]),
                         {"check-spawn-owner cmux-tui/crates/acpmux/src/hub/remote_table_bench.rs: 1 spawn line(s) "
                          "with no owner (a new file)"})
        self.assertEqual(excuse.test_reds.failed_names(["AssertionError: 1 != 0 : " + line]), set(),
                         "a quoted finding is a test's output, never a finding of its own")


class GreenSinceForABaseMerge(unittest.TestCase):
    """dep-fleet-6 (2026-11-11): update_branch's base merge gets through when the newest base verdict for the job is a
    pass made after the head's red run, whatever the job lists declare; a land never does."""

    def github(self):
        github = SpawnOwnerGitHub()
        github.comments = []  # no SHIP: the job-level rule refuses, whatever is declared
        prior = [job for job in github.jobs.values() if job["run_id"] == SPAWN_PRIOR_RUN]
        for job in prior:
            del github.jobs[job["id"]]  # no merge-base verdict: the per-step rule refuses too
        return github

    def test_an_undeclared_job_green_since_gets_its_base_merge(self):
        with unittest.mock.patch.object(excuse, "GUARD_JOBS", frozenset()):
            said = excuse.judge(REPO, "feat-cmux-next", SPAWN_HEAD, [SPAWN_HEAD_RUN], self.github(),
                                purpose=excuse.PER_STEP_PURPOSE)
        own = next(line for line in said if line.startswith(f"excused '{OWN_CHANGE}': fixed on base ("))
        self.assertIn(f"(run {SPAWN_HEAD_RUN} / {OWN_CHANGE}, job 130449502223", own)
        self.assertIn(f"green in feat-cmux-next run {SPAWN_BASE_RUN} at {SPAWN_BASE[:12]}", own)
        self.assertIn("for a base merge alone", own)

    def test_a_land_still_refuses_it(self):
        for purpose in (None, "land"):
            with self.subTest(purpose=purpose), unittest.mock.patch.object(excuse, "GUARD_JOBS", frozenset()), \
                    self.assertRaisesRegex(excuse.Refused, "not a declared guard job") as raised:
                excuse.judge(REPO, "feat-cmux-next", SPAWN_HEAD, [SPAWN_HEAD_RUN], self.github(), purpose=purpose)
            self.assertNotIn("green since", str(raised.exception))

    def test_a_base_pass_older_than_the_red_run_is_not_green_since(self):
        github = self.github()
        github.runs[SPAWN_BASE_RUN]["created_at"] = "2026-11-11T09:52:00Z"
        with unittest.mock.patch.object(excuse, "GUARD_JOBS", frozenset()), \
                self.assertRaisesRegex(excuse.Refused, "green since: .* is not newer than the red run"):
            excuse.judge(REPO, "feat-cmux-next", SPAWN_HEAD, [SPAWN_HEAD_RUN], github,
                         purpose=excuse.PER_STEP_PURPOSE)


class GuardJobsFollowTheWorkflows(unittest.TestCase):
    """The detector for a guard job declaration that drifts from the workflows (2026-11-11, cmux#41205): every job of
    every workflow that runs on pull requests is a declared guard job, a package job, or excluded with a reason, and
    every hard-coded copy of a guard job's name is a name GitHub reports for a job of the workflows."""

    # Workflows that run on pull requests and declare no guard job, each with why. A new one fails
    # test_every_pull_request_workflow_is_classified until it is classified here or in excuse.GUARD_WORKFLOWS.
    NOT_GUARD_WORKFLOWS = {
        "product builds and tests (Swift, Rust, web, backend, cloud, iOS), whose reds read product code": (
            "app-platform.yml", "auth-refresh-tests.yml", "automation-bench.yml", "backend-migrations.yml",
            "backend.yml", "ci.yml", "cloud-journey-pr.yml", "cloud-vm-guest-install.yml", "cloud-vm-image-lock.yml",
            "cloudflare-relay.yml", "cmux-cloud-cli.yml", "cmux-next-crash-class.yml", "cmux-next-cua-helper-identity.yml",
            "cmux-next-media.yml", "cmux-next-motion-golden.yml", "cmux-next-remote-daemon.yml",
            "cmux-next-shell-integration.yml", "cmux-next-shim-cpp.yml", "cmux-tui-sdks.yml", "cmux-tui-spec.yml",
            "cmux-tui-windows-check.yml", "cmux-vm-clients.yml", "cmux-vm-cloud.yml", "cmux-vm.yml", "cmux-vnc.yml",
            "coderouter-ci.yml", "fleet-test-compile.yml", "gallery-advisory.yml", "gallery-health.yml",
            "indexnow-tests.yml", "ios-reliability-matrix.yml", "ios-review-gate.yml", "iroh-v2.yml", "mux.yml",
            "nightly-next-canary.yml", "nightly-next-cua-signed-host.yml", "nightly-next-launch-smoke.yml",
            "r2-upload-tests.yml", "relay-tls.yml", "rust-workspaces.yml", "signing-keychain-macos.yml",
            "swift-acpmux-protocol.yml", "swift-linux-packages.yml", "swift-packages-linux.yml",
            "terminal-hang-diagnostics.yml", "test-ios.yml", "vendored-agent-cursor.yml", "web-complexity.yml",
            "web-complexity-trusted.yml", "web-validation.yml", "cmux-next-ios-kit.yml", "cmux-actions.yml",
            "cmux-skill-contract.yml", "agent-brands.yml",
            # React Doctor (da29cd0a): a ratchet over the React projects' own code.
            "cmux-next-react-doctor.yml"),
        "bots, labels, receipts, comments and policy reads of the pull request or GitHub, not of the tree": (
            "cla-policy-guard.yml", "cla.yml", "classic-frozen-guard.yml", "contributor-welcome.yml", "labels-sync.yml",
            "merge-freeze.yml", "merge-receipt.yml", "namespace-autofix.yml", "pr-body-checks.yml", "risk-tier.yml",
            "thunderdome-label.yml", "cmux-next-pr-autofix-closed-cancel.yml", "cmux-next-pr-autofix.yml",
            "cmux-next-pr-closed-cancel.yml", "language-boundaries.yml", "required-checks-drift.yml",
            "cmux-next-chromium-currency.yml", "ci-cache-receipts.yml"),
        "guard checks of their own whose reds are judged as any job's: no guard test declares its reads yet": (
            "ci-artifact-transport.yml", "classic-api-guard.yml", "cmux-next-batch.yml", "cmux-next-car-guards.yml",
            "cmux-next-fast-gates.yml", "fleet-artifact-cdn.yml", "ios-shared-packages-sync.yml", "pr-checks.yml",
            "release-rails.yml", "repair-nightly-appcast-content-types.yml", "risk-tier-tests.yml"),
    }

    @classmethod
    def setUpClass(cls):
        cls.yaml = excuse.yaml_module()
        cls.workflows = {}
        for path in sorted(excuse.WORKFLOWS.glob("*.y*ml")):
            doc = cls.yaml.safe_load(path.read_text())
            if isinstance(doc, dict):
                cls.workflows[path.name] = doc

    def triggers(self, doc):
        on = doc.get(True, doc.get("on"))
        return {on} if isinstance(on, str) else set(on or ())

    def pull_request_workflows(self):
        return {file for file, doc in self.workflows.items()
                if self.triggers(doc) & {"pull_request", "pull_request_target"}}

    def reported_names(self):
        """Every job name GitHub reports for the workflows' jobs with a fixed name, as it reports it (cut at 100)."""
        names = set()
        for file, doc in self.workflows.items():
            for job_id, job in (doc.get("jobs") or {}).items():
                try:
                    names.update(excuse.github_job_name(name)
                                 for name in excuse._check_matcher(str(job_id), job, file)["exact"])
                except excuse.Refused:
                    pass
        return names

    def test_the_committed_guard_jobs_are_the_workflows(self):
        self.assertEqual(json.loads(excuse.GUARD_JOBS_FILE.read_text()), excuse.derive_guard_jobs(),
                         "run: python3 scripts/ci/base_red_excuse.py --write-rollups")
        self.assertEqual(excuse.GUARD_JOBS, frozenset(excuse.derive_guard_jobs()["jobs"]))

    def test_every_pull_request_workflow_is_classified(self):
        listed = [file for files in self.NOT_GUARD_WORKFLOWS.values() for file in files]
        self.assertEqual(len(listed), len(set(listed)), "a workflow is listed twice")
        guard = set(excuse.GUARD_WORKFLOWS) | {file for file, _ in excuse.GUARD_JOB_IDS}
        self.assertEqual(sorted(self.pull_request_workflows() - guard - set(listed)), [],
                         "a workflow that runs on pull requests is neither in excuse.GUARD_WORKFLOWS nor "
                         "NOT_GUARD_WORKFLOWS: classify its jobs")
        self.assertEqual(sorted(set(listed) - set(self.workflows)), [], "a classified workflow is gone")
        self.assertEqual(sorted(set(listed) & guard), [], "a guard workflow is listed as not one")

    def test_every_job_of_a_guard_workflow_is_declared_or_excluded_with_a_reason(self):
        declared = set(excuse.GUARD_JOB_IDS)
        for file, excluded in excuse.GUARD_WORKFLOWS.items():
            jobs = set((self.workflows[file].get("jobs") or {}))
            with self.subTest(file=file):
                ours = {job for f, job in declared if f == file}
                self.assertEqual(sorted(jobs - ours - set(excluded)), [],
                                 f"{file}: a job is neither declared (GUARD_JOB_IDS) nor excluded (GUARD_WORKFLOWS)")
                self.assertEqual(sorted((ours | set(excluded)) - jobs), [], f"{file}: a classified job is gone")
                self.assertEqual(sorted(ours & set(excluded)), [], f"{file}: a job is declared and excluded")
                self.assertTrue(all(isinstance(why, str) and len(why) > 10 for why in excluded.values()))
        self.assertEqual(sorted({file for file, _ in declared} - set(excuse.GUARD_WORKFLOWS)), [])

    def test_a_renamed_or_new_guard_job_fails_the_detector(self):
        with tempfile.TemporaryDirectory() as root:
            for file in {file for file, _ in excuse.GUARD_JOB_IDS}:
                (Path(root) / file).write_text((excuse.WORKFLOWS / file).read_text())
            renamed = Path(root) / "cmux-next-guards.yml"
            text = renamed.read_text()
            renamed.write_text(text.replace(f"name: {OWN_CHANGE}", "name: cmux-next own change checks"))
            self.assertNotEqual(excuse.derive_guard_jobs(Path(root)), json.loads(excuse.GUARD_JOBS_FILE.read_text()))
            renamed.write_text(text.replace("\n  own-change-checks:", "\n  own-change-checks-v2:"))
            with self.assertRaisesRegex(excuse.Refused, "no job own-change-checks"):
                excuse.derive_guard_jobs(Path(root))

    def test_the_suffixes_and_package_jobs_name_jobs_of_the_workflows(self):
        guards = self.workflows["ci-guards.yml"]["jobs"]
        for suffix in excuse.GUARD_JOB_SUFFIXES:
            job_id, group = suffix.split(" / ")
            self.assertIn(job_id, guards)
            self.assertIn(f"matrix.group == '{group}'", (excuse.WORKFLOWS / "ci-guards.yml").read_text())
        names = self.reported_names()
        for name in excuse.PACKAGE_JOBS:
            self.assertIn(name, names)

    def test_every_hard_coded_copy_of_a_guard_job_name_is_a_name_github_reports(self):
        # The same drift in the other lists that name a guard job: each must be a job name GitHub reports today
        # (pr_red_checks_comment's static checks name was its 101-character `name:`, never reported: GitHub cuts it).
        sys.path.insert(0, str(ROOT / "scripts/ci"))
        import base_red_checks, car_guards, next_batch, pr_red_checks_comment  # noqa: E401,PLC0415
        names = self.reported_names()
        copies = [base_red_checks.CHECKS_JOB, next_batch.CHECKS_JOB, excuse.FFI_PIN_JOB, excuse.GUARD_GROUP_JOB,
                  *car_guards.REUSE["guard"],
                  *(value for kind, value in pr_red_checks_comment.TRACKED if kind == "name")]
        self.assertEqual(sorted(set(copies) - names), [])
        replay = (ROOT / "scripts/ci/affected_tests_replay.py").read_text()
        no_tests = ast.literal_eval(re.search(r"^NO_TESTS = (\(.*\))$", replay, re.M).group(1))
        for prefix in [prefix for prefix in no_tests if prefix.startswith("cmux-next checks")]:
            self.assertTrue(any(name.startswith(prefix) for name in names), prefix)


if __name__ == "__main__":
    unittest.main()
