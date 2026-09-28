#!/usr/bin/env python3
"""The UI test request and dispatch split across PR CI and a default-branch workflow."""
from __future__ import annotations

import datetime as dt
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest import mock

import yaml

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/ui_tests_dispatch.py"
CI = ROOT / ".github/workflows/ci.yml"
DISPATCH = ROOT / ".github/workflows/ci-ui-tests.yml"

spec = importlib.util.spec_from_file_location("ui_tests_dispatch", SCRIPT)
assert spec and spec.loader
ui = importlib.util.module_from_spec(spec)
sys.modules["ui_tests_dispatch"] = ui
spec.loader.exec_module(ui)

REPO = "manaflow-ai/cmux"
HEAD = "a" * 40
MERGE = "b" * 40


def ci_run(**overrides):
    run = {
        "id": 100, "path": ".github/workflows/ci.yml", "event": "pull_request", "head_sha": HEAD,
        "head_repository": {"full_name": REPO}, "pull_requests": [{"number": 7}], "status": "in_progress",
        "created_at": "2026-09-28T10:00:00Z", "run_started_at": "2026-09-28T10:00:00Z", "html_url": "https://github.com/manaflow-ai/cmux/actions/runs/100",
    }
    run.update(overrides)
    return run


class FakeGitHub(ui.GitHub):
    """Answers `get` from a route table; each value is a list consumed in order (last one repeats)."""

    def __init__(self, routes: dict, request: dict | bytes | None = None) -> None:
        super().__init__(REPO, "token")
        self.routes = {key: list(value) for key, value in routes.items()}
        self.request = request
        self.calls: list[str] = []
        self.posts: list[str] = []

    def get(self, path):
        path = path.replace("{repo}", REPO)
        self.calls.append(path)
        for prefix, answers in self.routes.items():
            if path.startswith(prefix):
                answer = answers.pop(0) if len(answers) > 1 else answers[0]
                return answer() if callable(answer) else answer
        raise AssertionError(f"unexpected GET {path}")

    def post(self, path):
        self.posts.append(path.replace("{repo}", REPO))

    def download(self, run_id, name, directory):
        body = self.request if isinstance(self.request, bytes) else json.dumps(self.request).encode()
        (Path(directory) / "request.json").write_bytes(body)


RUN = f"repos/{REPO}/actions/runs/100/attempts/1"
ARTIFACTS = f"repos/{REPO}/actions/runs/100/artifacts"
FILES = f"repos/{REPO}/pulls/7/files"
ARTIFACT = {"artifacts": [{"name": "ui-tests-request-1", "expired": False}]}
NO_ARTIFACT = {"artifacts": []}


class RequestTests(unittest.TestCase):
    def test_selectors_must_be_plain_class_or_method_names(self) -> None:
        self.assertEqual(ui.build_request("cmuxUITests/A cmuxUITests/B/testC", HEAD, MERGE)["selectors"],
                         ["cmuxUITests/A", "cmuxUITests/B/testC"])
        for bad in ("", "--force", "cmuxUITests/A --runner=x", "cmuxTests/A", "cmuxUITests/A/b/c",
                    "cmuxUITests/A;rm", " ".join(f"cmuxUITests/C{i}" for i in range(9)), "cmuxUITests/A cmuxUITests/A"):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                ui.build_request(bad, HEAD, MERGE)
        with self.assertRaises(ValueError):
            ui.build_request("cmuxUITests/A", "main", MERGE)

    def test_the_trusted_side_revalidates_the_artifact(self) -> None:
        good = {"head_sha": HEAD, "merge_sha": MERGE, "selectors": ["cmuxUITests/A"]}
        self.assertEqual(ui.parse_request(json.dumps(good).encode(), HEAD)["selectors"], ["cmuxUITests/A"])
        for bad in (
            {**good, "head_sha": "c" * 40},  # not the head GitHub reports for the run
            {**good, "selectors": ["--workflow-ref=evil"]},
            {**good, "selectors": "cmuxUITests/A"},
            {**good, "merge_sha": "refs/heads/x"},
            [good],
        ):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                ui.parse_request(json.dumps(bad).encode(), HEAD)
        with self.assertRaises(ValueError):
            ui.parse_request(b" " * (ui.MAX_REQUEST_BYTES + 1), HEAD)


class AwaitRequestTests(unittest.TestCase):
    def test_serves_a_same_repository_pull_request_once_its_request_lands(self) -> None:
        request = {"head_sha": HEAD, "merge_sha": MERGE, "selectors": ["cmuxUITests/A"]}
        gh = FakeGitHub({
            RUN: [ci_run()],
            FILES: [[{"filename": "Sources/x.swift"}, {"filename": "cmuxUITests/AUITests.swift"}]],
            ARTIFACTS: [NO_ARTIFACT, NO_ARTIFACT, ARTIFACT],
        }, request)
        sleeps = []
        self.assertEqual(ui.await_request(gh, "100", "1", sleep=sleeps.append), request)
        self.assertEqual(len(sleeps), 2)

    def test_returns_nothing_without_a_cmux_ui_tests_change(self) -> None:
        gh = FakeGitHub({RUN: [ci_run()], FILES: [[{"filename": "Sources/x.swift"}]]})
        self.assertIsNone(ui.await_request(gh, "100", "1", sleep=self.fail))
        self.assertFalse(any("artifacts" in call for call in gh.calls))

    def test_a_rename_out_of_cmux_ui_tests_still_counts(self) -> None:
        gh = FakeGitHub({FILES: [[{"filename": "x.swift", "previous_filename": "cmuxUITests/x.swift"}]]})
        self.assertTrue(ui.touches_ui_tests(gh, [7]))

    def test_a_truncated_file_listing_waits_instead_of_skipping(self) -> None:
        page = [{"filename": f"f{i}"} for i in range(100)]
        gh = FakeGitHub({FILES: [page]})
        self.assertIsNone(ui.touches_ui_tests(gh, [7]))
        self.assertIsNone(ui.touches_ui_tests(gh, []))

    def test_refuses_forks_other_workflows_and_events(self) -> None:
        for run in (ci_run(head_repository={"full_name": "someone/cmux"}), ci_run(path=".github/workflows/x.yml"),
                    ci_run(event="merge_group")):
            with self.subTest(run=run):
                gh = FakeGitHub({RUN: [run]})
                self.assertIsNone(ui.await_request(gh, "100", "1", sleep=self.fail))
                self.assertEqual(gh.calls, [RUN])

    def test_stops_when_the_attempt_completes_without_a_request(self) -> None:
        gh = FakeGitHub({
            RUN: [ci_run(), ci_run(), ci_run(status="completed")],
            FILES: [[{"filename": "cmuxUITests/AUITests.swift"}]],
            ARTIFACTS: [NO_ARTIFACT],
        })
        self.assertIsNone(ui.await_request(gh, "100", "1", sleep=lambda _: None))

    def test_a_request_whose_attempt_completed_is_not_dispatched(self) -> None:
        # ui-tests was cancelled or gave up, so nothing would read the verdict.
        request = {"head_sha": HEAD, "merge_sha": "", "selectors": ["cmuxUITests/A"]}
        gh = FakeGitHub({
            RUN: [ci_run(), ci_run(status="completed")],
            FILES: [[{"filename": "cmuxUITests/AUITests.swift"}]],
            ARTIFACTS: [ARTIFACT],
        }, request)
        self.assertIsNone(ui.await_request(gh, "100", "1", sleep=self.fail))

    def test_a_malformed_request_fails_instead_of_dispatching(self) -> None:
        gh = FakeGitHub({RUN: [ci_run()], FILES: [[{"filename": "cmuxUITests/A.swift"}]], ARTIFACTS: [ARTIFACT]},
                        {"head_sha": HEAD, "selectors": ["-x"]})
        with self.assertRaises(ValueError):
            ui.await_request(gh, "100", "1", sleep=self.fail)


def dispatch_run(conclusion="success", status="completed", title=None, run_id=900, branch="main"):
    return {"id": run_id, "status": status, "conclusion": conclusion, "created_at": "2026-09-28T10:00:05Z",
            "head_branch": branch,
            "display_title": title or ui.dispatch_title("100", "1"), "html_url": f"https://x/{run_id}"}


def jobs(step_conclusion):
    return {"jobs": [{"name": ui.DISPATCH_JOB_NAME, "steps": [
        {"name": "Wait for the UI test request", "conclusion": "success"},
        {"name": ui.DISPATCH_STEP_NAME, "conclusion": step_conclusion}]}]}


LIST = f"repos/{REPO}/actions/workflows/ci-ui-tests.yml/runs"


class AwaitVerdictTests(unittest.TestCase):
    def verdict(self, routes) -> int:
        gh = FakeGitHub({RUN: [ci_run()], **routes})
        return ui.await_verdict(gh, "100", "1", sleep=lambda _: None)

    def test_mirrors_a_dispatch_that_ran_and_passed(self) -> None:
        other = dispatch_run(title=ui.dispatch_title("101", "1"), run_id=901)
        self.assertEqual(self.verdict({
            LIST: [{"workflow_runs": [other]}, {"workflow_runs": [other, dispatch_run(status="queued")]}],
            f"repos/{REPO}/actions/runs/900/jobs": [jobs("success")],
            f"repos/{REPO}/actions/runs/900": [dispatch_run(status="in_progress"), dispatch_run()],
        }), 0)

    def test_fails_on_failed_tests(self) -> None:
        self.assertEqual(self.verdict({
            LIST: [{"workflow_runs": [dispatch_run()]}],
            f"repos/{REPO}/actions/runs/900/jobs": [jobs("failure")],
            f"repos/{REPO}/actions/runs/900": [dispatch_run(conclusion="failure")],
        }), 1)

    def test_a_dispatch_run_that_found_no_request_is_not_a_pass(self) -> None:
        self.assertEqual(self.verdict({
            LIST: [{"workflow_runs": [dispatch_run()]}],
            f"repos/{REPO}/actions/runs/900/jobs": [jobs("skipped")],
            f"repos/{REPO}/actions/runs/900": [dispatch_run()],
        }), 1)

    def test_gives_up_when_no_dispatch_run_appears(self) -> None:
        clock = iter(range(0, 10**6, 600))
        gh = FakeGitHub({RUN: [ci_run()], LIST: [{"workflow_runs": []}]})
        self.assertEqual(ui.await_verdict(gh, "100", "1", sleep=lambda _: None, now=lambda: next(clock)), 1)

    def test_looks_up_runs_created_around_the_attempt(self) -> None:
        gh = FakeGitHub({LIST: [{"workflow_runs": []}]})
        ui.find_dispatch_run(gh, "100", "1", dt.datetime(2026, 9, 28, 9, 50, tzinfo=dt.timezone.utc))
        self.assertIn("created=%3E%3D2026-09-28T09:50:00Z", gh.calls[0])

    def lookup_since(self, run: dict, attempt: str) -> str:
        gh = FakeGitHub({f"repos/{REPO}/actions/runs/100/attempts/{attempt}": [run], LIST: [{"workflow_runs": []}]})
        clock = iter(range(0, 10**6, 600))
        ui.await_verdict(gh, "100", attempt, sleep=lambda _: None, now=lambda: next(clock))
        return next(call for call in gh.calls if call.startswith(LIST))

    def test_a_run_that_queued_for_hours_is_found_from_its_creation(self) -> None:
        # A labeled run waits behind the running one; its dispatch run was
        # created when it was requested, not when it started.
        queued = ci_run(created_at="2026-09-28T07:00:00Z", run_started_at="2026-09-28T10:00:00Z")
        self.assertIn("created=%3E%3D2026-09-28T06:50:00Z", self.lookup_since(queued, "1"))
        # A re-run's dispatch run is created when the re-run starts.
        self.assertIn("created=%3E%3D2026-09-28T09:50:00Z", self.lookup_since(queued, "2"))

    def test_only_a_default_branch_run_counts(self) -> None:
        gh = FakeGitHub({LIST: [{"workflow_runs": [dispatch_run(branch="other")]}]})
        self.assertIsNone(ui.find_dispatch_run(gh, "100", "1", dt.datetime(2026, 9, 28, tzinfo=dt.timezone.utc)))


E2E_LIST = f"repos/{REPO}/actions/workflows/test-e2e.yml/runs"
E2E_JOBS = f"repos/{REPO}/actions/runs/700/jobs"
OWN_JOBS = f"repos/{REPO}/actions/runs/100/attempts/1/jobs"
NOW = dt.datetime(2026, 9, 28, 10, 30, tzinfo=dt.timezone.utc)


def e2e_run(title=None, run_id=700):
    return {"id": run_id, "created_at": "2026-09-28T10:10:00Z", "html_url": f"https://x/{run_id}",
            "display_title": title or f"cmuxUITests/A,cmuxUITests/B on glaeda-std-xcode-26.6 @ {MERGE} [abc]"}


def build_job(status="in_progress", runner="mini", steps=()):
    return {"name": "build", "status": status, "conclusion": None, "runner_name": runner,
            "labels": ["glaeda-std-xcode-26.6"], "created_at": "2026-09-28T10:20:00Z",
            "started_at": "2026-09-28T10:25:00Z" if runner else None, "steps": list(steps)}


class ProgressTests(unittest.TestCase):
    def setUp(self) -> None:
        every = mock.patch.object(ui, "PROGRESS_EVERY", 1)
        every.start()
        self.addCleanup(every.stop)

    def progress(self, routes) -> "ui.Progress":
        gh = FakeGitHub(routes)
        return ui.Progress(gh, "100", "1", ["cmuxUITests/A", "cmuxUITests/B"], [MERGE, HEAD],
                           dt.datetime(2026, 9, 28, 9, 50, tzinfo=dt.timezone.utc), now=lambda: NOW)

    def test_reports_admission_until_the_test_run_appears_then_its_steps(self) -> None:
        admission = {"name": "macos / macOS compile admission", "status": "in_progress", "runner_name": "mini-7",
                     "started_at": "2026-09-28T10:27:00Z", "steps": [{"name": "Compile app-host test product", "status": "in_progress"}]}
        other = e2e_run(title=f"cmuxUITests/A on glaeda-std-xcode-26.6 @ {MERGE} [x]", run_id=701)
        progress = self.progress({
            E2E_LIST: [{"workflow_runs": [other]}, {"workflow_runs": [other, e2e_run()]}],
            OWN_JOBS: [{"jobs": [admission]}],
            E2E_JOBS: [
                {"jobs": [build_job(status="queued", runner=None)]},
                {"jobs": [build_job(steps=[
                    {"name": "Build the app-host and UI test product", "status": "completed", "conclusion": "skipped"},
                    {"name": "Run selected tests", "status": "in_progress", "started_at": "2026-09-28T10:28:30Z"}])]},
                {"jobs": [build_job(status="completed") | {"conclusion": "success"}, {"name": "test", "status": "completed", "conclusion": "skipped"}]},
            ],
        })
        self.assertIsNone(progress.report(), "no run with exactly these selectors yet")
        self.assertEqual(progress.report(),
                         "Waiting for compile admission's product: compiling on mini-7 for 3m00s, "
                         "at 'Compile app-host test product'.")
        self.assertEqual(progress.report(), "UI test run: https://x/700")
        self.assertEqual(progress.report(), "UI test run: build is queued for glaeda-std-xcode-26.6 for 10m00s.")
        self.assertEqual(progress.report(),
                         "UI test run: build on mini for 5m00s, testing 2 selected classes for 1m30s; "
                         "adopted the compiled product, no build.")
        self.assertEqual(progress.report(), "UI test run finished (build success, test skipped); waiting for its verdict.")
        # One read per report: the listing, the admission job, then the test run's jobs.
        self.assertEqual(len(progress.gh.calls), 6)
        self.assertIn("event=workflow_dispatch&created=%3E%3D2026-09-28T09:50:00Z", progress.gh.calls[0])

    def test_reports_a_compile_and_a_queued_admission(self) -> None:
        progress = self.progress({
            E2E_LIST: [{"workflow_runs": [e2e_run()]}],
            E2E_JOBS: [{"jobs": [build_job(steps=[
                {"name": "Build the app-host and UI test product", "status": "in_progress",
                 "started_at": "2026-09-28T10:26:00Z"}])]}],
        })
        progress.report()
        self.assertEqual(progress.report(),
                         "UI test run: build on mini for 5m00s, compiling the app and UI tests for 4m00s.")
        queued = {"name": "macos / macOS compile admission", "status": "queued", "runner_name": None,
                  "labels": ["blacksmith-12vcpu-macos-26"], "created_at": "2026-09-28T10:15:00Z"}
        progress = self.progress({E2E_LIST: [{"workflow_runs": []}], OWN_JOBS: [{"jobs": [queued]}]})
        progress.report()
        self.assertEqual(progress.report(), "Waiting for compile admission's product: admission is queued "
                                            "for blacksmith-12vcpu-macos-26 for 15m00s.")

    def test_a_failed_read_skips_a_line_and_never_raises(self) -> None:
        def fail():
            raise subprocess.CalledProcessError(1, "gh", stderr="HTTP 502")

        def fork_failed():
            raise BlockingIOError(35, "Resource temporarily unavailable")
        progress = self.progress({E2E_LIST: [fail, fork_failed], OWN_JOBS: [{"unexpected": True}]})
        self.assertIsNone(progress.report())
        self.assertEqual(progress.report(), "Waiting for the dispatcher to start a UI test run.")
        self.assertIsNone(progress.report(), "an OSError from spawning gh is only a skipped line")

    def test_reads_once_every_third_poll(self) -> None:
        with mock.patch.object(ui, "PROGRESS_EVERY", 3):
            progress = self.progress({E2E_LIST: [{"workflow_runs": []}], OWN_JOBS: [{"jobs": []}]})
            for _ in range(6):
                progress.report()
        self.assertEqual(len(progress.gh.calls), 2)

    def test_matches_the_same_selectors_in_any_order_and_looks_again_after_a_run_ends(self) -> None:
        swapped = e2e_run(title=f"cmuxUITests/B,cmuxUITests/A on glaeda-std-xcode-26.6 @ {HEAD} [abc]")
        newer = e2e_run(run_id=702) | {"created_at": "2026-09-28T10:40:00Z"}
        progress = self.progress({
            E2E_LIST: [{"workflow_runs": [swapped]}, {"workflow_runs": [swapped, newer]}],
            E2E_JOBS: [{"jobs": [build_job(status="completed") | {"conclusion": "failure"}]}],
        })
        self.assertEqual(progress.report(), "UI test run: https://x/700")
        progress.report()
        self.assertIsNone(progress.e2e)
        self.assertEqual(progress.report(), "UI test run: https://x/702")

    def test_progress_never_changes_the_verdict(self) -> None:
        gh = FakeGitHub({
            RUN: [ci_run()],
            LIST: [{"workflow_runs": [dispatch_run()]}],
            f"repos/{REPO}/actions/runs/900/jobs": [jobs("success")],
            f"repos/{REPO}/actions/runs/900": [dispatch_run(status="in_progress"), dispatch_run()],
            E2E_LIST: [lambda: (_ for _ in ()).throw(subprocess.TimeoutExpired("gh", 120))],
        })
        self.assertEqual(ui.await_verdict(gh, "100", "1", sleep=lambda _: None,
                                          selectors=["cmuxUITests/A"], revisions=[MERGE, HEAD]), 0)
        self.assertEqual(sum(call.startswith(E2E_LIST) for call in gh.calls), 1)

    def test_ci_passes_what_names_the_test_run(self) -> None:
        steps = yaml.safe_load(CI.read_text())["jobs"]["ui-tests"]["steps"]
        wait = next(step for step in steps if step.get("name") == "Wait for the UI test run")
        self.assertEqual(wait["env"]["SELECTORS"], "${{ needs.changes.outputs.ui_selectors }}")
        self.assertEqual(wait["env"]["MERGE_SHA"], "${{ github.sha }}")


class DispatchTests(unittest.TestCase):
    def test_cancels_the_dispatched_run_when_the_ci_attempt_finishes(self) -> None:
        command = [sys.executable, "-c",
                   "import signal; print('Run: https://github.com/manaflow-ai/cmux/actions/runs/555', flush=True); signal.pause()"]
        # The attempt finishes only after the dispatcher has named its run.
        gh = FakeGitHub({RUN: [lambda: ci_run(status="completed" if job.dispatched else "in_progress")]})
        job = ui.Dispatch(gh, command, "100", "1")
        self.assertEqual(job.run(interval=0.2, tick=0.1), 130)
        self.assertEqual(gh.posts, [f"repos/{REPO}/actions/runs/555/cancel"])

    def test_cancels_the_dispatched_run_when_this_run_is_cancelled(self) -> None:
        gh = FakeGitHub({RUN: [ci_run()]})
        command = [sys.executable, "-c",
                   "import signal; print('Run: https://github.com/manaflow-ai/cmux/actions/runs/556', flush=True); signal.pause()"]
        job = ui.Dispatch(gh, command, "100", "1")

        def cancel_once_named() -> None:
            while not job.dispatched:
                threading.Event().wait(0.05)
            job.stop.set()
        threading.Thread(target=cancel_once_named, daemon=True).start()
        self.assertEqual(job.run(interval=60, tick=0.1), 130)
        self.assertEqual(gh.posts, [f"repos/{REPO}/actions/runs/556/cancel"])

    def test_leaves_a_run_it_attached_to_running(self) -> None:
        command = [sys.executable, "-c",
                   "import signal; print('x is already queued at y on z; reusing that run instead of dispatching.'); "
                   "print('Run: https://github.com/manaflow-ai/cmux/actions/runs/557', flush=True); signal.pause()"]
        gh = FakeGitHub({RUN: [lambda: ci_run(status="completed" if job.dispatched else "in_progress")]})
        job = ui.Dispatch(gh, command, "100", "1")
        self.assertEqual(job.run(interval=0.2, tick=0.1), 130)
        self.assertEqual(gh.posts, [])

    def test_returns_the_dispatcher_verdict(self) -> None:
        gh = FakeGitHub({RUN: [ci_run()]})
        for code in (0, 1):
            with self.subTest(code=code):
                job = ui.Dispatch(gh, [sys.executable, "-c", f"raise SystemExit({code})"], "100", "1")
                self.assertEqual(job.run(interval=60, tick=0.05), code)
        self.assertEqual(gh.posts, [])

    def test_request_command_writes_what_the_trusted_side_accepts(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory) / "request.json"
            env = {"SELECTORS": "cmuxUITests/A", "HEAD_SHA": HEAD, "MERGE_SHA": MERGE, "PATH": "/usr/bin:/bin"}
            subprocess.run([sys.executable, str(SCRIPT), "request", "--out", str(out)], env=env, check=True,
                           capture_output=True)
            self.assertEqual(ui.parse_request(out.read_bytes(), HEAD)["selectors"], ["cmuxUITests/A"])
            env["SELECTORS"] = "cmuxUITests/A --force"
            result = subprocess.run([sys.executable, str(SCRIPT), "request", "--out", str(out)], env=env,
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)


class WorkflowTests(unittest.TestCase):
    def test_pull_request_ci_holds_no_write_token(self) -> None:
        document = yaml.safe_load(CI.read_text(encoding="utf-8"))
        self.assertNotEqual((document.get("permissions") or {}).get("actions"), "write")
        for name, job in document["jobs"].items():
            with self.subTest(job=name):
                self.assertNotIn("write", str((job.get("permissions") or {}).get("actions")))
        job = document["jobs"]["ui-tests"]
        self.assertEqual(job["permissions"], {"contents": "read", "actions": "read"})
        steps = job["steps"]
        self.assertEqual(steps[0]["if"], "github.event.pull_request.head.repo.full_name != github.repository")
        upload = next(step for step in steps if str(step.get("uses", "")).startswith("actions/upload-artifact@"))
        self.assertEqual(upload["with"]["name"], ui.request_artifact("${{ github.run_attempt }}"))
        runs = "\n".join(str(step.get("run", "")) for step in steps[1:])
        self.assertIn("ui_tests_dispatch.py request", runs)
        self.assertIn("ui_tests_dispatch.py await-verdict", runs)
        self.assertNotIn("run-e2e.sh", runs)

    def test_the_dispatching_workflow_runs_from_the_default_branch(self) -> None:
        document = yaml.safe_load(DISPATCH.read_text(encoding="utf-8"))
        on = document.get("on", document.get(True))
        self.assertEqual(on["workflow_run"], {"workflows": ["CI"], "types": ["requested"]})
        self.assertEqual(document["permissions"], {})
        job = document["jobs"]["dispatch"]
        self.assertEqual(job["name"], ui.DISPATCH_JOB_NAME)
        self.assertEqual(job["permissions"]["actions"], "write")
        self.assertIn("github.event.workflow_run.head_repository.full_name == github.repository", job["if"])
        steps = job["steps"]
        checkouts = [step for step in steps if str(step.get("uses", "")).startswith("actions/checkout@")]
        self.assertTrue(checkouts)
        for checkout in checkouts:
            self.assertEqual(checkout["with"]["ref"], "${{ github.event.repository.default_branch }}")
            self.assertIs(checkout["with"]["persist-credentials"], False)
        dispatch = next(step for step in steps if step.get("name") == ui.DISPATCH_STEP_NAME)
        self.assertEqual(dispatch["working-directory"], "dispatcher")
        # The runner signals the step's shell on cancel; exec makes that the
        # script, which then cancels the dispatched run.
        self.assertTrue(dispatch["run"].startswith("exec python3 "), dispatch["run"])
        self.assertLess(steps.index(checkouts[-1]), steps.index(dispatch))
        # Untrusted values reach scripts only through the environment.
        for step in steps:
            self.assertNotIn("steps.request.outputs", str(step.get("run", "")))
        title = document["run-name"]
        self.assertIn("UI tests for CI run {0} attempt {1}", title)
        self.assertEqual(ui.dispatch_title("{0}", "{1}"), "UI tests for CI run {0} attempt {1}")


if __name__ == "__main__":
    unittest.main(buffer=True)
