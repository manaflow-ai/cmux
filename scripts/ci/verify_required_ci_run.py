#!/usr/bin/env python3
"""Verify that an exact pull-request SHA completed the required CI workflow."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from dataclasses import dataclass
from typing import Any, Callable, Iterable


class RequiredCIVerificationError(RuntimeError):
    """Raised when the required CI run is missing or failed."""


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
    return RunSummary(
        run_id=int(raw["id"]),
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

    candidates = [
        _run_summary(run)
        for run in runs
        if str(run.get("head_sha", "")) == expected_sha
        and str(run.get("path", "")) == ".github/workflows/ci.yml"
    ]
    if not candidates:
        return None
    return max(candidates, key=lambda run: run.created_at)


def verify_ci_jobs(jobs: Iterable[dict[str, Any]], *, run: RunSummary) -> None:
    """Require a successful aggregate ``ci-status`` job in the exact run."""

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
    try:
        completed = subprocess.run(
            ["gh", "api", endpoint],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=os.environ.copy(),
        )
    except (OSError, subprocess.CalledProcessError) as error:
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
    sleep: Callable[[float], None] = time.sleep,
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
    deadline = now() + max(1, timeout_seconds)
    endpoint = f"repos/{repository}/actions/workflows/ci.yml/runs?event=pull_request&head_sha={expected_sha}&per_page=20"
    last_state = "not-found"
    api_failures = 0
    while now() < deadline:
        try:
            payload = api(endpoint)
            api_failures = 0
        except RequiredCIVerificationError as error:
            api_failures += 1
            last_state = f"api-error: {error}"
            if api_failures >= 3:
                raise
            sleep(max(1, poll_seconds))
            continue
        raw_runs = payload.get("workflow_runs", [])
        if not isinstance(raw_runs, list):
            raise RequiredCIVerificationError("GitHub API returned malformed workflow_runs")
        run = select_exact_ci_run(raw_runs, expected_sha=expected_sha)
        if run is not None:
            last_state = f"{run.status}/{run.conclusion or 'pending'}"
            if run.status == "completed":
                if run.conclusion != "success":
                    raise RequiredCIVerificationError("required CI workflow was not successful")
                try:
                    jobs_payload = api(f"repos/{repository}/actions/runs/{run.run_id}/jobs?per_page=100")
                except RequiredCIVerificationError as error:
                    api_failures += 1
                    last_state = f"api-error: {error}"
                    if api_failures >= 3:
                        raise
                    sleep(max(1, poll_seconds))
                    continue
                raw_jobs = jobs_payload.get("jobs", [])
                if not isinstance(raw_jobs, list):
                    raise RequiredCIVerificationError("GitHub API returned malformed jobs")
                verify_ci_jobs(raw_jobs, run=run)
                return run
        sleep(max(1, poll_seconds))

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
    try:
        run = verify_repository_ci(
            repository=args.repository,
            expected_sha=args.sha,
            browser_required=args.browser_required,
            browser_result=args.browser_result,
            timeout_seconds=args.timeout_seconds,
            poll_seconds=args.poll_seconds,
        )
    except RequiredCIVerificationError as error:
        print("::error::required CI verification failed", file=sys.stderr)
        return 1
    print("required CI verification passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
