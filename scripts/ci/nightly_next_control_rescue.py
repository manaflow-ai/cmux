#!/usr/bin/env python3
"""Bounded rescue adapter for NEXT's tick and feed-watch control runs.

The default branch owns the broad persistent-pool rescue.  This small adapter
is fetched from the reviewed NEXT tooling branch and handles only the two
light control workflows: if their first attempt never acquires a runner, it
cancels that attempt and requests one full retry so the admission picker gets
another live read.  All other events are delegated to the default rescue
script supplied by the caller.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import time
import urllib.request
from pathlib import Path
from typing import Any, Mapping, Sequence

CONTROL_PATHS = frozenset({
    ".github/workflows/nightly-next-tick.yml",
    ".github/workflows/nightly-next-feed-watch.yml",
})
CONTROL_EVENTS = frozenset({"schedule", "workflow_dispatch", "workflow_run"})
CONTROL_JOBS = frozenset({"admit", "request", "watch"})
WAIT_SECONDS = 180
POLL_SECONDS = 15
API = "https://api.github.com"


def control_target(event: Mapping[str, Any], repository: str) -> Mapping[str, Any] | None:
    run = event.get("workflow_run") or {}
    if run.get("path") not in CONTROL_PATHS or run.get("event") not in CONTROL_EVENTS:
        return None
    if str((run.get("head_repository") or {}).get("full_name") or "").casefold() != repository.casefold():
        return None
    if int(run.get("run_attempt") or 0) != 1:
        return None
    return run


def control_started(jobs: Sequence[Mapping[str, Any]]) -> bool:
    """Whether a control job has acquired execution on its first attempt."""
    for job in jobs:
        name = str(job.get("name") or "").split("(", 1)[0].strip()
        if name not in CONTROL_JOBS:
            continue
        # GitHub reports queued jobs with runner_id 0. A runner assignment or
        # started_at timestamp is the execution proof; queued/pending jobs are
        # still eligible for the bounded no-start rescue even when visible.
        if job.get("started_at") or job.get("status") == "in_progress":
            return True
        if job.get("status") == "completed" and job.get("conclusion") not in (None, "skipped"):
            return True
        if job.get("runner_id") not in (None, 0) or job.get("runner_name"):
            return True
    return False


class Actions:
    def __init__(self, token: str, repository: str) -> None:
        self.token = token
        self.repository = repository

    def request(self, method: str, path: str) -> Any:
        request = urllib.request.Request(
            f"{API}/repos/{self.repository}{path}",
            headers={"Accept": "application/vnd.github+json", "Authorization": f"Bearer {self.token}",
                     "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "cmux-nightly-next-control-rescue"},
            method=method,
        )
        with urllib.request.urlopen(request, timeout=15) as response:
            payload = response.read()
        return json.loads(payload) if payload else {}

    def jobs(self, run_id: int, attempt: int) -> list[Mapping[str, Any]]:
        body = self.request("GET", f"/actions/runs/{run_id}/attempts/{attempt}/jobs?per_page=100")
        return [job for job in body.get("jobs") or [] if isinstance(job, Mapping)]

    def cancel(self, run_id: int) -> None:
        self.request("POST", f"/actions/runs/{run_id}/cancel")

    def rerun(self, run_id: int) -> None:
        self.request("POST", f"/actions/runs/{run_id}/rerun")


def rescue_control(api: Actions, run: Mapping[str, Any], *, sleep=time.sleep, clock=time.monotonic) -> str:
    run_id = int(run["id"])
    deadline = clock() + WAIT_SECONDS
    while clock() < deadline:
        try:
            jobs = api.jobs(run_id, 1)
        except Exception:  # noqa: BLE001 - transient reads stay bounded and fail closed
            sleep(POLL_SECONDS)
            continue
        if control_started(jobs):
            return "started"
        sleep(min(POLL_SECONDS, max(0.0, deadline - clock())))
    # A final read closes the race between the last poll and cancellation.
    try:
        final_jobs = api.jobs(run_id, 1)
    except Exception:  # noqa: BLE001 - never cancel without a final readable state
        return "unreadable"
    if control_started(final_jobs):
        return "started"
    try:
        current = api.request("GET", f"/actions/runs/{run_id}")
    except Exception:  # noqa: BLE001 - fail closed on a race-check outage
        return "unreadable"
    if (current.get("path") not in CONTROL_PATHS
            or int(current.get("run_attempt") or 0) != 1
            or current.get("status") == "completed"):
        return "changed"
    # The run can acquire a runner between the first final read and this
    # mutation. Read the current attempt once more immediately before cancel.
    try:
        current_jobs = api.jobs(run_id, 1)
    except Exception:  # noqa: BLE001 - never cancel without a final readable state
        return "unreadable"
    if control_started(current_jobs):
        return "started"
    api.cancel(run_id)
    # The Actions API accepts the full rerun once cancellation settles. The
    # workflow's own requested event remains bounded by its job timeout.
    settle = clock() + POLL_SECONDS * 4
    while clock() < settle:
        state = api.request("GET", f"/actions/runs/{run_id}")
        if state.get("status") == "completed":
            api.rerun(run_id)
            return "rerun"
        sleep(POLL_SECONDS)
    return "cancelled; rerun pending settlement"


def _delegate() -> int:
    path = os.environ.get("MAIN_RESCUE_SCRIPT", "scripts/ci/owned_pool_rescue.py")
    return subprocess.call([sys.executable, path], env=os.environ.copy())


def main() -> int:
    event_path = os.environ.get("GITHUB_EVENT_PATH", "")
    repository = os.environ.get("GITHUB_REPOSITORY", "")
    if not event_path or not repository:
        return _delegate()
    try:
        event = json.loads(Path(event_path).read_text())
        run = control_target(event, repository)
    except (OSError, TypeError, ValueError, json.JSONDecodeError):
        run = None
    if run is None:
        return _delegate()
    token = (os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN") or "").strip()
    if not token:
        return 0
    result = rescue_control(Actions(token, repository), run)
    print(f"nightly-next control rescue: {result}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
