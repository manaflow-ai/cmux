#!/usr/bin/env python3
"""Verify that an exact pull-request SHA completed the required CI workflow."""

from __future__ import annotations

import argparse
import json
import os
import re
import signal
import subprocess
import sys
import threading
import time
from dataclasses import dataclass
from typing import Any, Callable, Iterable


class RequiredCIVerificationError(RuntimeError):
    """Raised when the required CI run is missing or failed."""


class CancellationAwareWait:
    """Wait for a bounded retry interval while honoring cancellation.

    GitHub cancels superseded ``pull_request_target`` runs by sending a
    termination signal. An event-backed wait lets the signal handler wake the
    watcher immediately instead of leaving a stale process parked for the
    whole polling interval. Tests can inject a deterministic wait and
    cancellation predicate without touching wall-clock time.
    """

    def __init__(
        self,
        *,
        wait: Callable[[float], None] | None = None,
        cancelled: Callable[[], bool] | None = None,
    ) -> None:
        self._event = threading.Event()
        self._wait = wait or self._event.wait
        self._cancelled = cancelled or self._event.is_set

    def cancel(self) -> None:
        """Wake a pending wait and mark the poller cancelled."""

        self._event.set()

    def is_cancelled(self) -> bool:
        """Return whether cancellation was requested."""

        return self._cancelled()

    def wait(self, seconds: float) -> None:
        """Wait for *seconds* or raise when cancellation is observed."""

        if self.is_cancelled():
            raise RequiredCIVerificationError("required CI watcher was cancelled")

        self._wait(max(0.0, seconds))
        if self.is_cancelled():
            raise RequiredCIVerificationError("required CI watcher was cancelled")


_GH_API_TIMEOUT_SECONDS = 30
_GH_ENDPOINT_RE = re.compile(
    r"^repos/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/actions/"
    r"(?:workflows/ci\.yml/runs|runs/[0-9]+/jobs)"
    r"(?:\?[A-Za-z0-9_.=&-]+)?$"
)


@dataclass(frozen=True)
class RunSummary:
    """The immutable fields used to identify a CI run."""

    run_id: int
    status: str
    conclusion: str | None
    path: str
    head_sha: str
    created_at: str


def _run_summary(raw: dict[str, Any]) -> RunSummary:
    try:
        run_id = int(raw["id"])
    except (KeyError, TypeError, ValueError) as error:
        raise RequiredCIVerificationError("GitHub API returned a malformed workflow run") from error
    return RunSummary(
        run_id=run_id,
        status=str(raw.get("status", "")),
        conclusion=raw.get("conclusion"),
        path=str(raw.get("path", "")),
        head_sha=str(raw.get("head_sha", "")),
        created_at=str(raw.get("created_at", "")),
    )


def select_exact_ci_run(
    runs: Iterable[dict[str, Any]],
    *,
    expected_sha: str,
) -> RunSummary | None:
    """Select the newest CI workflow run whose head and workflow path match."""

    candidates: list[RunSummary] = []
    for raw_run in runs:
        if not isinstance(raw_run, dict):
            continue
        if str(raw_run.get("head_sha", "")).lower() != expected_sha.lower():
            continue
        workflow_path = str(raw_run.get("path", "")).split("@", 1)[0]
        if workflow_path != ".github/workflows/ci.yml":
            continue
        try:
            candidates.append(_run_summary(raw_run))
        except RequiredCIVerificationError:
            # A malformed API item cannot be accepted as evidence. Ignore it
            # and continue polling for a valid exact run; if none appears the
            # bounded watcher fails closed.
            continue
    if not candidates:
        return None
    return max(candidates, key=lambda run: run.created_at)


def verify_ci_jobs(jobs: Iterable[dict[str, Any]], *, run: RunSummary) -> None:
    """Require a successful aggregate ``ci-status`` job in the exact run."""

    if run.status != "completed" or run.conclusion != "success":
        raise RequiredCIVerificationError("required CI workflow was not successful")

    matching = [
        job
        for job in jobs
        if str(job.get("name", "")) == "ci-status"
        or str(job.get("name", "")).startswith("ci-status / ")
    ]
    if len(matching) != 1:
        raise RequiredCIVerificationError(
            "required CI aggregate job was missing or duplicated"
        )
    job = matching[0]
    if job.get("status") != "completed" or job.get("conclusion") != "success":
        raise RequiredCIVerificationError("required CI aggregate job was not successful")


def _gh_json(endpoint: str) -> dict[str, Any]:
    if not _GH_ENDPOINT_RE.fullmatch(endpoint):
        raise RequiredCIVerificationError("GitHub API request was outside the allowed endpoint")
    try:
        completed = subprocess.run(
            ["gh", "api", endpoint],
            check=True,
            capture_output=True,
            text=True,
            env=os.environ.copy(),
            timeout=_GH_API_TIMEOUT_SECONDS,
        )
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        raise RequiredCIVerificationError("GitHub API request failed") from error
    try:
        value = json.loads(completed.stdout)
    except json.JSONDecodeError as error:
        raise RequiredCIVerificationError("GitHub API returned invalid JSON") from error
    if not isinstance(value, dict):
        raise RequiredCIVerificationError("GitHub API returned an invalid response")
    return value


def verify_repository_ci(
    *,
    repository: str,
    expected_sha: str,
    browser_required: str = "unknown",
    browser_result: str = "unknown",
    timeout_seconds: int = 5_400,
    poll_seconds: int = 30,
    now: Callable[[], float] = time.monotonic,
    sleep: Callable[[float], None] | None = None,
    cancelled: Callable[[], bool] | None = None,
    api: Callable[[str], dict[str, Any]] = _gh_json,
) -> RunSummary:
    """Wait for and verify the exact CI run for ``expected_sha``."""

    if len(expected_sha) != 40 or any(character not in "0123456789abcdef" for character in expected_sha.lower()):
        raise RequiredCIVerificationError("expected SHA must be a full 40-character commit SHA")
    if browser_required not in {"true", "false"}:
        raise RequiredCIVerificationError("browser verification route was not resolved")
    if browser_required == "true" and browser_result != "success":
        raise RequiredCIVerificationError("required browser verification was not successful")
    if browser_required == "false" and browser_result not in {"success", "skipped"}:
        raise RequiredCIVerificationError("browser verification had an unexpected result")
    wait_for_retry = CancellationAwareWait(wait=sleep, cancelled=cancelled)
    deadline = now() + max(1, timeout_seconds)
    endpoint = f"repos/{repository}/actions/workflows/ci.yml/runs?event=pull_request&head_sha={expected_sha.lower()}&per_page=100"
    api_failures = 0
    while now() < deadline:
        if wait_for_retry.is_cancelled():
            raise RequiredCIVerificationError("required CI watcher was cancelled")
        try:
            payload = api(endpoint)
            api_failures = 0
        except RequiredCIVerificationError:
            api_failures += 1
            if api_failures >= 3:
                raise
            wait_for_retry.wait(max(1, poll_seconds))
            continue
        raw_runs = payload.get("workflow_runs", [])
        if not isinstance(raw_runs, list):
            raise RequiredCIVerificationError("GitHub API returned malformed workflow_runs")
        run = select_exact_ci_run(raw_runs, expected_sha=expected_sha)
        if run is not None:
            if run.status == "completed":
                if run.conclusion != "success":
                    raise RequiredCIVerificationError("required CI workflow was not successful")
                try:
                    jobs_payload = api(f"repos/{repository}/actions/runs/{run.run_id}/jobs?per_page=100")
                except RequiredCIVerificationError:
                    api_failures += 1
                    if api_failures >= 3:
                        raise
                    wait_for_retry.wait(max(1, poll_seconds))
                    continue
                raw_jobs = jobs_payload.get("jobs", [])
                if not isinstance(raw_jobs, list):
                    raise RequiredCIVerificationError("GitHub API returned malformed jobs")
                verify_ci_jobs(raw_jobs, run=run)
                return run
        wait_for_retry.wait(max(1, poll_seconds))

    raise RequiredCIVerificationError("required CI workflow did not complete before timeout")


def parse_args(argv: Iterable[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", default=os.environ.get("GITHUB_REPOSITORY", ""))
    parser.add_argument("--sha", default=os.environ.get("EXPECTED_SHA", ""))
    parser.add_argument("--timeout-seconds", type=int, default=5_400)
    parser.add_argument("--poll-seconds", type=int, default=30)
    parser.add_argument("--browser-required", default=os.environ.get("BROWSER_REQUIRED", "unknown"))
    parser.add_argument("--browser-result", default=os.environ.get("BROWSER_RESULT", "unknown"))
    return parser.parse_args(list(argv))


def main(argv: Iterable[str] | None = None) -> int:
    args = parse_args(argv or sys.argv[1:])
    if not args.repository:
        print("::error::repository is required", file=sys.stderr)
        return 1
    waiter = CancellationAwareWait()
    previous_handlers: dict[int, Any] = {}

    def request_cancel(signum: int, _frame: Any) -> None:
        del signum
        waiter.cancel()

    for signum in (signal.SIGINT, signal.SIGTERM):
        previous_handlers[signum] = signal.signal(signum, request_cancel)
    try:
        verify_repository_ci(
            repository=args.repository,
            expected_sha=args.sha,
            browser_required=args.browser_required,
            browser_result=args.browser_result,
            timeout_seconds=args.timeout_seconds,
            poll_seconds=args.poll_seconds,
            sleep=waiter.wait,
            cancelled=waiter.is_cancelled,
        )
    except RequiredCIVerificationError:
        print("::error::required CI verification failed", file=sys.stderr)
        return 1
    finally:
        for signum, handler in previous_handlers.items():
            signal.signal(signum, handler)
    print("required CI verification passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
