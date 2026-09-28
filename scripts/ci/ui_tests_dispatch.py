#!/usr/bin/env python3
"""Run a pull request's changed UI test classes without a write token in PR CI.

Dispatching test-e2e.yml takes `actions: write`. A pull_request run takes
ci.yml from the pull request, so any job there holding that permission is a job
a same-repository author can rewrite. The work is split across the trust
boundary instead:

- ci.yml's `ui-tests` job (read-only, the pull request's code) validates the
  selectors its `changes` job chose and uploads them as a request artifact
  named for its run attempt (`request`), then waits for the verdict of the
  dispatch that serves it and reports it as its own result (`await-verdict`),
  so ci-status still gates on the UI tests.
- ci-ui-tests.yml runs from the default branch on every CI run attempt
  (`workflow_run: requested`). It waits for that attempt's request
  (`await-request`), re-validates it, and runs main's dispatcher on it
  (`dispatch`). When the CI attempt finishes first (cancelled by a newer push,
  or its `ui-tests` job gave up) it cancels the dispatched run.

Nothing from the request artifact is trusted beyond selectors that match
`cmuxUITests/<Class>[/<method>]` and a merge SHA used only to fetch objects;
the head SHA must equal the one GitHub reports for the CI run.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import threading
import time
from typing import Any, Callable

CI_WORKFLOW_PATH = ".github/workflows/ci.yml"
DISPATCH_WORKFLOW_FILE = "ci-ui-tests.yml"
# ci-ui-tests.yml's job and step that run the dispatcher. The waiting side
# requires this step to have succeeded, so a dispatch run that found no request
# (it gave up, or its pre-check saw no UI test change) never reads as a pass.
DISPATCH_JOB_NAME = "Run requested UI tests"
DISPATCH_STEP_NAME = "Run the requested UI test classes"

SELECTOR = re.compile(r"cmuxUITests/[A-Za-z_][A-Za-z0-9_]*(?:/[A-Za-z_][A-Za-z0-9_]*)?")
SHA = re.compile(r"[0-9a-f]{40}")
# choose_ci_suite.MAX_UI_SELECTORS: more than one focused run takes is a coverage gap there.
MAX_SELECTORS = 8
MAX_REQUEST_BYTES = 16_384
UI_TEST_PREFIX = "cmuxUITests/"
# Not a test class: test-e2e.yml reads this entry as "replay the UI fuzzer's
# checked-in repros (dogfood/fuzz/regressions) against the app", after the
# selected classes or alone.
FUZZ_REGRESSIONS_SELECTOR = "cmuxUITests/FuzzRegressions"
# What those repros exercise: the sidebar, splits and panes, and the main
# window's size, plus the fuzzer and its repros. choose_ci_suite.py adds the
# selector for a diff that touches one; a path ending in "/" is a directory.
FUZZ_REGRESSION_PATHS = (
    "dogfood/fuzz/",
    "scripts/fuzz",
    "vendor/bonsplit",
    "Packages/macOS/CmuxPanes/",
    "Packages/macOS/CmuxSidebar/",
    "Sources/Sidebar/",
    "Sources/App/CmuxMainWindow.swift",
    "Sources/App/MainWindowFrameReconciler.swift",
    "Sources/AppDelegate+WindowFramePolicy.swift",
)
# Workspace's split code: Workspace+EqualizeSplitsSupport.swift and the like.
FUZZ_REGRESSION_PATTERN = re.compile(r"Sources/Workspace\+[^/]*Split[^/]*\.swift")
# The files API lists at most 3000 files of a pull request.
MAX_FILE_PAGES = 30
POLL_SECONDS = 60
# The request follows compile admission, usually tens of minutes after the
# attempt starts, so its wait reads less often.
REQUEST_POLL_SECONDS = 120
# How long the waiting side looks for the dispatch run of its attempt. The
# dispatch run is created when the CI attempt is, so it normally exists before
# `ui-tests` starts.
FIND_DISPATCH_SECONDS = 20 * 60
MAX_CONSECUTIVE_ERRORS = 10
RUN_LINE = re.compile(r"^Run: https://github\.com/[^/]+/[^/]+/actions/runs/(\d+)")
# dispatch-focused-test.py attaches to an identical run already in flight;
# that run belongs to whoever started it and is never cancelled from here.
REUSED_LINE = "reusing that run instead of dispatching"


def request_artifact(attempt: int | str) -> str:
    return f"ui-tests-request-{attempt}"


def dispatch_title(run_id: int | str, attempt: int | str) -> str:
    """ci-ui-tests.yml's run-name for one CI run attempt."""
    return f"UI tests for CI run {run_id} attempt {attempt}"


def rerun_dispatch(run_id: int | str, attempt: int | str, ref: str = "main") -> tuple[str, dict]:
    """The workflow_dispatch that serves a CI attempt a bot re-ran.

    A re-run made with GITHUB_TOKEN (the owned-pool rescue, failure
    attribution) may not emit workflow_run, so those callers start this
    workflow themselves. Returns (path under repos/<repo>/, body). A duplicate
    from a workflow_run event joins the same concurrency group and replaces it.
    """
    return (f"actions/workflows/{DISPATCH_WORKFLOW_FILE}/dispatches",
            {"ref": ref, "inputs": {"run_id": str(run_id), "run_attempt": str(attempt)}})


def validate_selectors(selectors: object) -> list[str]:
    if not isinstance(selectors, list) or not selectors:
        raise ValueError("no UI test selectors to run")
    if len(selectors) > MAX_SELECTORS:
        raise ValueError(f"{len(selectors)} UI test selectors; one focused run takes at most {MAX_SELECTORS}")
    for selector in selectors:
        if not isinstance(selector, str) or not SELECTOR.fullmatch(selector):
            raise ValueError(f"refusing UI test selector {selector!r}: not cmuxUITests/<Class>[/<method>]")
    if len(set(selectors)) != len(selectors):
        raise ValueError("duplicate UI test selectors")
    return list(selectors)


def build_request(selectors_text: str, head_sha: str, merge_sha: str) -> dict:
    if not SHA.fullmatch(head_sha):
        raise ValueError(f"head {head_sha!r} is not a full commit SHA")
    if merge_sha and not SHA.fullmatch(merge_sha):
        raise ValueError(f"merge {merge_sha!r} is not a full commit SHA")
    return {
        "head_sha": head_sha,
        "merge_sha": merge_sha,
        "selectors": validate_selectors(selectors_text.split()),
    }


def parse_request(raw: bytes, head_sha: str) -> dict:
    """The request artifact, validated against the CI run GitHub reports."""
    if len(raw) > MAX_REQUEST_BYTES:
        raise ValueError(f"request is {len(raw)} bytes, over {MAX_REQUEST_BYTES}")
    data = json.loads(raw)
    if not isinstance(data, dict):
        raise ValueError("request is not a JSON object")
    if data.get("head_sha") != head_sha:
        raise ValueError(f"request names head {data.get('head_sha')!r}, not the CI run's head {head_sha}")
    merge_sha = data.get("merge_sha") or ""
    if not isinstance(merge_sha, str) or (merge_sha and not SHA.fullmatch(merge_sha)):
        raise ValueError(f"request merge {merge_sha!r} is not a full commit SHA")
    return {"head_sha": head_sha, "merge_sha": merge_sha, "selectors": validate_selectors(data.get("selectors"))}


class GitHub:
    """`gh api` with an optional separate read token (its own rate limit)."""

    def __init__(self, repository: str, token: str, read_token: str = "") -> None:
        self.repository = repository
        self.token = token
        self.read_token = read_token

    def _gh(self, args: list[str], token: str) -> str:
        env = {**os.environ, "GH_TOKEN": token}
        return subprocess.run(
            ["gh", *args], env=env, capture_output=True, text=True, timeout=120, check=True,
        ).stdout

    def get(self, path: str) -> Any:
        path = path.replace("{repo}", self.repository)
        if self.read_token:
            try:
                return json.loads(self._gh(["api", path], self.read_token))
            except subprocess.CalledProcessError as error:
                # An expired installation token (401) or a read the App may not
                # make (403) goes to the job token; anything else is a real error.
                if not re.search(r"HTTP 40[13]\b", error.stderr or ""):
                    raise
                if "HTTP 401" in (error.stderr or ""):
                    self.read_token = ""
        return json.loads(self._gh(["api", path], self.token))

    def post(self, path: str) -> None:
        self._gh(["api", "-X", "POST", path.replace("{repo}", self.repository)], self.token)

    def download(self, run_id: int | str, name: str, directory: str) -> None:
        self._gh(["run", "download", str(run_id), "--repo", self.repository, "--name", name, "--dir", directory],
                 self.read_token or self.token)


def source_attempt(gh: GitHub, run_id: int | str, attempt: int | str) -> dict:
    return gh.get(f"repos/{{repo}}/actions/runs/{run_id}/attempts/{attempt}")


def serves(run: dict, repository: str) -> str | None:
    """Why this CI run is not one to serve, or None when it is."""
    if run.get("path") != CI_WORKFLOW_PATH:
        return f"run is {run.get('path')!r}, not {CI_WORKFLOW_PATH}"
    if run.get("event") != "pull_request":
        return f"run is a {run.get('event')!r} run, not a pull request's"
    head_repository = str((run.get("head_repository") or {}).get("full_name", ""))
    if head_repository.casefold() != repository.casefold():
        return f"run is from {head_repository!r}, a fork; its ui-tests job refuses it"
    if not SHA.fullmatch(str(run.get("head_sha", ""))):
        return "run has no head SHA"
    return None


def fuzz_regression_path(path: str) -> bool:
    """Whether a change to `path` asks for the UI fuzzer's regression replays."""
    return FUZZ_REGRESSION_PATTERN.fullmatch(path) is not None or any(
        path.startswith(entry) if entry.endswith("/") else path == entry or path.startswith(entry + "/")
        for entry in FUZZ_REGRESSION_PATHS)


def touches_ui_tests(gh: GitHub, pull_numbers: list[int]) -> bool | None:
    """Whether any of these pull requests changes cmuxUITests/ or a fuzz regression path; None when unknown.

    Only those changes yield selectors (choose_ci_suite.changed_ui_selectors and
    FUZZ_REGRESSIONS_SELECTOR), so this spares every other pull request the wait
    for a request.
    """
    if not pull_numbers:
        return None
    for number in pull_numbers:
        for page in range(1, MAX_FILE_PAGES + 1):
            files = gh.get(f"repos/{{repo}}/pulls/{number}/files?per_page=100&page={page}")
            for entry in files:
                for name in (entry.get("filename"), entry.get("previous_filename")):
                    if isinstance(name, str) and (name.startswith(UI_TEST_PREFIX) or fuzz_regression_path(name)):
                        return True
            if len(files) < 100:
                break
        else:
            return None  # Truncated listing: cannot rule it out.
    return False


API_ERRORS = (subprocess.CalledProcessError, subprocess.TimeoutExpired, json.JSONDecodeError)


def retrying(read: Callable[[], Any], *, sleep: Callable[[float], None], interval: float = 10) -> Any:
    """One read, retried through transient API errors."""
    for tries in range(1, MAX_CONSECUTIVE_ERRORS + 1):
        try:
            return read()
        except API_ERRORS as error:
            print(f"GitHub API error ({tries}): {getattr(error, 'stderr', '') or error}", file=sys.stderr, flush=True)
            if tries == MAX_CONSECUTIVE_ERRORS:
                raise
            sleep(interval)
    raise AssertionError("unreachable")


def poll(check: Callable[[], Any], *, sleep: Callable[[float], None], interval: float = POLL_SECONDS) -> Any:
    """Call `check` until it returns non-None, tolerating transient API errors."""
    errors = 0
    while True:
        try:
            result = check()
            errors = 0
        except API_ERRORS as error:
            errors += 1
            print(f"GitHub API error ({errors}): {getattr(error, 'stderr', '') or error}", file=sys.stderr, flush=True)
            if errors >= MAX_CONSECUTIVE_ERRORS:
                raise
            result = None
        if result is not None:
            return result
        sleep(interval)


def await_request(gh: GitHub, run_id: str, attempt: str, *, sleep: Callable[[float], None] = time.sleep) -> dict | None:
    """The validated request of this CI attempt, or None when it will make none."""
    run = retrying(lambda: source_attempt(gh, run_id, attempt), sleep=sleep)
    reason = serves(run, gh.repository)
    if reason:
        print(f"Nothing to run: {reason}.", flush=True)
        return None
    head_sha = run["head_sha"]
    numbers = [int(pr["number"]) for pr in run.get("pull_requests") or [] if isinstance(pr.get("number"), int)]
    touched = retrying(lambda: touches_ui_tests(gh, numbers), sleep=sleep)
    if touched is False:
        print(f"Nothing to run: pull request {numbers} changes nothing under {UI_TEST_PREFIX} "
              "and no path the fuzz regressions cover.", flush=True)
        return None
    name = request_artifact(attempt)
    print(f"Waiting for {name} from {run.get('html_url', run_id)} (head {head_sha}).", flush=True)

    def check() -> dict | bool | None:
        # Status first: an artifact uploaded before the attempt completed is
        # then always seen by the artifact read that follows.
        status = source_attempt(gh, run_id, attempt).get("status")
        artifacts = gh.get(f"repos/{{repo}}/actions/runs/{run_id}/artifacts?name={name}&per_page=100")
        found = [a for a in artifacts.get("artifacts", []) if a.get("name") == name and not a.get("expired")]
        if status == "completed":
            # Nothing waits for a verdict any more: ui-tests was cancelled or gave up.
            return False
        if found:
            with tempfile.TemporaryDirectory() as directory:
                gh.download(run_id, name, directory)
                return parse_request((Path(directory) / "request.json").read_bytes(), head_sha)
        return None

    request = poll(check, sleep=sleep, interval=REQUEST_POLL_SECONDS)
    if request is False:
        print(f"Nothing to run: the CI attempt completed, so nothing waits for {name}.", flush=True)
        return None
    return request


class Dispatch:
    """Main's dispatcher on one request, cancelled with the CI attempt it serves."""

    def __init__(self, gh: GitHub, command: list[str], run_id: str, attempt: str) -> None:
        self.gh = gh
        self.command = command
        self.run_id = run_id
        self.attempt = attempt
        self.dispatched: str | None = None
        self.reused = False
        self.stop = threading.Event()

    def _read(self, process: subprocess.Popen) -> None:
        assert process.stdout is not None
        for line in process.stdout:
            print(line, end="", flush=True)
            if REUSED_LINE in line:
                self.reused = True
            match = RUN_LINE.match(line)
            if match:
                self.dispatched = match.group(1)

    def _source_finished(self) -> bool:
        try:
            return source_attempt(self.gh, self.run_id, self.attempt).get("status") == "completed"
        except API_ERRORS:
            return False

    def run(self, interval: float = POLL_SECONDS, tick: float = 1.0) -> int:
        process = subprocess.Popen(
            self.command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, start_new_session=True,
        )
        reader = threading.Thread(target=self._read, args=(process,), daemon=True)
        reader.start()
        reason = ""
        waited = 0.0
        while process.poll() is None:
            if self.stop.wait(tick):
                reason = "this run was cancelled"
                break
            waited += tick
            if waited >= interval:
                waited = 0.0
                if process.poll() is None and self._source_finished():
                    reason = "the CI attempt it serves finished, so nothing waits for its verdict"
                    break
        if process.poll() is None:
            # The runner kills a cancelled step seconds after signalling it, so
            # the dispatched run is cancelled before the local process is reaped.
            print(f"Stopping the dispatch: {reason}.", flush=True)
            try:
                os.killpg(process.pid, signal.SIGINT)
            except ProcessLookupError:
                pass
            if self.dispatched and self.reused:
                print(f"Leaving run {self.dispatched} running: it was already in flight for another caller.", flush=True)
            elif self.dispatched:
                try:
                    self.gh.post(f"repos/{{repo}}/actions/runs/{self.dispatched}/cancel")
                    print(f"Cancelled run {self.dispatched}.", flush=True)
                except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
                    print(f"::warning::could not cancel run {self.dispatched}: {error}", flush=True)
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait()
            reader.join(timeout=5)
            process.stdout.close()
            return 130
        reader.join(timeout=5)
        process.stdout.close()
        return process.returncode


def write_outputs(values: dict[str, str]) -> None:
    path = os.environ.get("GITHUB_OUTPUT")
    if not path:
        return
    with open(path, "a", encoding="utf-8") as handle:
        for key, value in values.items():
            handle.write(f"{key}={value}\n")


def github_from_env() -> GitHub:
    return GitHub(
        os.environ["REPOSITORY"],
        os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN") or "",
        os.environ.get("READ_TOKEN") or "",
    )


def parse_time(value: str) -> dt.datetime:
    return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))


def find_dispatch_run(gh: GitHub, run_id: str, attempt: str, since: dt.datetime,
                      default_branch: str = "main") -> dict | None:
    """The newest default-branch ci-ui-tests.yml run serving this attempt, created since `since`."""
    title = dispatch_title(run_id, attempt)
    created = since.strftime("%Y-%m-%dT%H:%M:%SZ")
    matches = []
    for page in range(1, 11):
        runs = gh.get(
            f"repos/{{repo}}/actions/workflows/{DISPATCH_WORKFLOW_FILE}/runs"
            f"?created=%3E%3D{created}&per_page=100&page={page}"
        ).get("workflow_runs", [])
        matches.extend(run for run in runs
                       if run.get("display_title") == title and run.get("head_branch") == default_branch)
        if len(runs) < 100:
            break
    return max(matches, key=lambda run: run.get("created_at", ""), default=None)


def dispatch_step_conclusion(gh: GitHub, dispatch_run_id: int | str) -> str | None:
    jobs = gh.get(f"repos/{{repo}}/actions/runs/{dispatch_run_id}/jobs?filter=latest&per_page=100").get("jobs", [])
    for job in jobs:
        if job.get("name") != DISPATCH_JOB_NAME:
            continue
        for step in job.get("steps") or []:
            if step.get("name") == DISPATCH_STEP_NAME:
                return step.get("conclusion")
    return None


E2E_WORKFLOW_FILE = "test-e2e.yml"
ADMISSION_JOB = "macOS compile admission"
# test-e2e.yml's macOS jobs, in order; the Linux jobs before them take seconds.
E2E_MACOS_JOBS = ("build", "test")
E2E_COMPILE_STEP = "Build the app-host and UI test product"
E2E_TESTS_STEP = "Run selected tests"
# Progress reads once every this many verdict polls (60 s each), so the wait
# makes a third more REST calls on the job token, not twice as many.
PROGRESS_EVERY = 3


def _seconds(start: str | None, end: dt.datetime) -> int | None:
    if not start:
        return None
    return max(0, int((end - parse_time(start)).total_seconds()))


def _duration(seconds: int | None) -> str:
    if seconds is None:
        return "?"
    minutes, rest = divmod(seconds, 60)
    return f"{minutes}m{rest:02d}s" if minutes else f"{rest}s"


class Progress:
    """One line per poll on what the UI test run is doing, so the wait never looks stuck.

    Each report makes one bounded read beside the verdict's own: the jobs of
    the test-e2e.yml run serving this request once it is known, otherwise
    either the listing that finds that run (by its title: the selectors, and
    the merge or head it tests) or this attempt's compile admission, whose
    product the dispatch waits for. Progress is only ever printed: a failed
    or odd read skips a line and never touches the verdict.
    """

    def __init__(self, gh: GitHub, run_id: str, attempt: str, selectors: list[str], revisions: list[str],
                 since: dt.datetime, now: Callable[[], dt.datetime] | None = None) -> None:
        self.gh = gh
        self.run_id = run_id
        self.attempt = attempt
        self.test_filter = ",".join(selectors)
        self.count = len(selectors)
        self.revisions = [revision for revision in revisions if revision]
        self.since = since
        self.now = now or (lambda: dt.datetime.now(dt.timezone.utc))
        self.e2e: dict | None = None
        self.polls = 0
        self.ticks = 0

    def report(self) -> str | None:
        """Every PROGRESS_EVERY-th poll: its read then adds a third to the wait's."""
        self.polls += 1
        if self.polls % PROGRESS_EVERY:
            return None
        self.ticks += 1
        try:
            line = self._line()
        except Exception as error:  # noqa: BLE001 - progress must never touch the verdict
            print(f"(progress unavailable this minute: {type(error).__name__})", flush=True)
            line = None
        if line:
            print(line, flush=True)
        return line

    def _line(self) -> str | None:
        if self.e2e is None:
            if self.ticks % 2 == 1:
                self.e2e = self._find_e2e()
                if self.e2e is not None:
                    return f"UI test run: {self.e2e.get('html_url')}"
                return None
            return self._admission()
        return self._e2e_state()

    def _find_e2e(self) -> dict | None:
        if not self.test_filter or not self.revisions:
            return None
        created = self.since.strftime("%Y-%m-%dT%H:%M:%SZ")
        runs = self.gh.get(
            f"repos/{{repo}}/actions/workflows/{E2E_WORKFLOW_FILE}/runs"
            f"?event=workflow_dispatch&created=%3E%3D{created}&per_page=100"
        ).get("workflow_runs", [])

        wanted = sorted(self.test_filter.split(","))

        def ours(run: dict) -> bool:
            # An identical run already in flight is reused whatever order it
            # names the same selectors in.
            title = str(run.get("display_title") or "")
            return (sorted(title.split(" on ", 1)[0].split(",")) == wanted
                    and any(f" @ {revision}" in title for revision in self.revisions))

        return max((run for run in runs if ours(run)), key=lambda run: run.get("created_at", ""), default=None)

    def _admission(self) -> str | None:
        jobs = self.gh.get(
            f"repos/{{repo}}/actions/runs/{self.run_id}/attempts/{self.attempt}/jobs?per_page=100"
        ).get("jobs", [])
        job = next((job for job in jobs if str(job.get("name", "")).endswith(ADMISSION_JOB)), None)
        now = self.now()
        if job is None:
            return "Waiting for the dispatcher to start a UI test run."
        if job.get("status") == "completed":
            return (f"Compile admission ended {job.get('conclusion')}; waiting for the dispatcher "
                    "to start a UI test run on its product.")
        if job.get("started_at") and job.get("runner_name") and job.get("status") == "in_progress":
            step = next((step for step in job.get("steps") or [] if step.get("status") == "in_progress"), None)
            doing = f", at '{step.get('name')}'" if step else ""
            return (f"Waiting for compile admission's product: compiling on {job['runner_name']} for "
                    f"{_duration(_seconds(job['started_at'], now))}{doing}.")
        labels = ", ".join(job.get("labels") or []) or "a runner"
        return (f"Waiting for compile admission's product: admission is queued for {labels} "
                f"for {_duration(_seconds(job.get('created_at'), now))}.")

    def _e2e_state(self) -> str | None:
        assert self.e2e is not None
        jobs = self.gh.get(f"repos/{{repo}}/actions/runs/{self.e2e['id']}/jobs?filter=latest&per_page=30").get("jobs", [])
        now = self.now()
        by_name = {job.get("name"): job for job in jobs}
        macos = [by_name[name] for name in E2E_MACOS_JOBS if name in by_name]
        live = next((job for job in macos if job.get("status") != "completed"), None)
        if live is None:
            if macos and all(job.get("status") == "completed" for job in macos):
                done = [f"{job['name']} {job.get('conclusion')}" for job in macos]
                # Look again next time: the dispatcher may start a newer run.
                self.e2e = None
                return f"UI test run finished ({', '.join(done)}); waiting for its verdict."
            pending = [job for job in jobs if job.get("status") != "completed"]
            if pending:
                return f"UI test run: {pending[0].get('name')} is {pending[0].get('status')} (Linux setup)."
            return None
        name = live.get("name")
        if live.get("status") != "in_progress" or not live.get("runner_name"):
            labels = ", ".join(live.get("labels") or []) or "a runner"
            return (f"UI test run: {name} is queued for {labels} "
                    f"for {_duration(_seconds(live.get('created_at'), now))}.")
        steps = live.get("steps") or []
        step = next((step for step in steps if step.get("status") == "in_progress"), None)
        compiled = next((step for step in steps if step.get("name") == E2E_COMPILE_STEP), None)
        product = ""
        if compiled and compiled.get("conclusion") == "skipped":
            product = "; adopted the compiled product, no build"
        elif compiled and compiled.get("status") == "completed":
            product = f"; compiled in {_duration(_seconds(compiled.get('started_at'), parse_time(compiled['completed_at'])))}"
        doing = "between steps"
        if step is not None:
            doing = f"'{step.get('name')}' for {_duration(_seconds(step.get('started_at'), now))}"
            if step.get("name") == E2E_TESTS_STEP:
                doing = (f"testing {self.count} selected class{'es' if self.count != 1 else ''} "
                         f"for {_duration(_seconds(step.get('started_at'), now))}")
            elif step.get("name") == E2E_COMPILE_STEP:
                doing = f"compiling the app and UI tests for {_duration(_seconds(step.get('started_at'), now))}"
        return (f"UI test run: {name} on {live['runner_name']} for "
                f"{_duration(_seconds(live.get('started_at'), now))}, {doing}{product}.")


def await_verdict(gh: GitHub, run_id: str, attempt: str, *, sleep: Callable[[float], None] = time.sleep,
                  now: Callable[[], float] = time.monotonic, default_branch: str = "main",
                  selectors: list[str] | None = None, revisions: list[str] | None = None) -> int:
    run = retrying(lambda: source_attempt(gh, run_id, attempt), sleep=sleep)
    # The dispatch run is created when the attempt is requested: for attempt 1
    # that is the run's creation (a labeled run can then queue for hours before
    # it starts); a re-run is requested when its attempt starts.
    requested = run["created_at"] if str(attempt) == "1" else run["run_started_at"]
    since = parse_time(requested) - dt.timedelta(minutes=10)
    deadline = now() + FIND_DISPATCH_SECONDS

    def find() -> dict | bool | None:
        match = find_dispatch_run(gh, run_id, attempt, since, default_branch)
        if match is not None:
            return match
        return False if now() >= deadline else None

    found = poll(find, sleep=sleep)
    if found is False:
        print(
            f"::error::No {DISPATCH_WORKFLOW_FILE} run titled {dispatch_title(run_id, attempt)!r} appeared, "
            "so nothing dispatched the UI tests. Re-run this job: a re-run requests them again.",
            flush=True,
        )
        return 1
    print(f"UI tests for this run: {found.get('html_url')}", flush=True)
    progress = Progress(gh, run_id, attempt, selectors or [], revisions or [], since) if selectors else None

    def check() -> dict | None:
        run = gh.get(f"repos/{{repo}}/actions/runs/{found['id']}")
        if run.get("status") == "completed":
            return run
        if progress is not None:
            progress.report()
        return None

    finished = poll(check, sleep=sleep)
    step = retrying(lambda: dispatch_step_conclusion(gh, found["id"]), sleep=sleep)
    if finished.get("conclusion") == "success" and step == "success":
        print(f"UI tests passed: {found.get('html_url')}", flush=True)
        return 0
    if step in (None, "skipped"):
        print(f"::error::{found.get('html_url')} ended {finished.get('conclusion')} without running the UI tests. "
              "Re-run this job to request them again.", flush=True)
    else:
        print(f"::error::UI tests {finished.get('conclusion')}: {found.get('html_url')}", flush=True)
    return 1


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    request = sub.add_parser("request", help="validate SELECTORS and write the request (ci.yml, read-only)")
    request.add_argument("--out", required=True)
    sub.add_parser("await-verdict", help="wait for the dispatch run serving RUN_ID/RUN_ATTEMPT (ci.yml)")
    sub.add_parser("await-request", help="wait for SOURCE_RUN_ID/SOURCE_RUN_ATTEMPT's request (ci-ui-tests.yml)")
    sub.add_parser("dispatch", help="run main's dispatcher on the validated request (ci-ui-tests.yml)")
    args = parser.parse_args(argv)

    try:
        if args.command == "request":
            body = build_request(os.environ.get("SELECTORS", ""), os.environ.get("HEAD_SHA", ""),
                                 os.environ.get("MERGE_SHA", ""))
            Path(args.out).write_text(json.dumps(body), encoding="utf-8")
            print(f"Requesting {' '.join(body['selectors'])} at {body['head_sha']}.", flush=True)
            return 0
        if args.command == "await-verdict":
            # SELECTORS and the revisions only name the run to report
            # progress on; the verdict never reads them.
            return await_verdict(github_from_env(), os.environ["RUN_ID"], os.environ["RUN_ATTEMPT"],
                                 default_branch=os.environ.get("DEFAULT_BRANCH") or "main",
                                 selectors=os.environ.get("SELECTORS", "").split(),
                                 revisions=[os.environ.get("MERGE_SHA", ""), os.environ.get("HEAD_SHA", "")])
        if args.command == "await-request":
            found = await_request(github_from_env(), os.environ["SOURCE_RUN_ID"], os.environ["SOURCE_RUN_ATTEMPT"])
            if found is None:
                write_outputs({"requested": "false"})
                return 0
            print(f"Request: {' '.join(found['selectors'])} at {found['head_sha']}.", flush=True)
            write_outputs({
                "requested": "true",
                "head_sha": found["head_sha"],
                "merge_sha": found["merge_sha"],
                "selectors": " ".join(found["selectors"]),
            })
            return 0
        if args.command == "dispatch":
            head_sha = os.environ["HEAD_SHA"]
            if not SHA.fullmatch(head_sha):
                raise ValueError(f"head {head_sha!r} is not a full commit SHA")
            selectors = validate_selectors(os.environ.get("SELECTORS", "").split())
            command = ["scripts/run-e2e.sh", *selectors, "--ref", head_sha, "--wait", "--no-video"]
            # A re-run of the CI attempt dispatches again, even past a failure at this head.
            if int(os.environ["SOURCE_RUN_ATTEMPT"]) > 1:
                command.append("--force")
            gh = github_from_env()
            job = Dispatch(gh, command, os.environ["SOURCE_RUN_ID"], os.environ["SOURCE_RUN_ATTEMPT"])
            for signum in (signal.SIGINT, signal.SIGTERM):
                signal.signal(signum, lambda _signum, _frame: job.stop.set())
            return job.run()
    except ValueError as error:
        print(f"::error::{error}", flush=True)
        return 1
    return 2


if __name__ == "__main__":
    sys.exit(main())
