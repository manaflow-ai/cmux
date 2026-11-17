#!/usr/bin/env python3
"""Cancel an older app-ffi-release.yml run whose build still waits for a runner, so this newer run builds.

The build job's concurrency group (app-ffi-release-build-<ref>, cancel-in-progress: false) never cancels a
running build, and GitHub keeps one pending run behind it. But a build queued for a runner counts as the
group's running job too. Run 43978720557 (2026-11-16) queued its build on the saturated side-std label for
hours, and every newer FFI run (43979315440, 43982240915, 43985437623) went pending behind it and was then
replaced by the next one: nothing built or published, and feat-cmux-next stayed red on the app FFI pin.

The placement job of each new push or dispatch on the branch runs this. It cancels each older, unfinished run
of the workflow on the same branch whose build job has not started on a runner (queued or pending), so the
group keeps the newest run. A build already on a runner when its jobs are read is never cancelled (a runner
taking it in the instant between that read and the cancel is the one gap): an older build mid-compile finishes
and publishes its own tag, as before. Skipping an older release loses nothing, since the re-pin pins the
newest published release.

Calls (GITHUB_TOKEN, actions: write): one runs list, one jobs read per older unfinished run, one cancel per
waiting build. Any failed call is printed and ends the step without failing the placement.
"""

from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.request
from typing import Any, Callable, Iterable, Mapping

WORKFLOW_FILE = "app-ffi-release.yml"
BUILD_JOB_NAME = "build xcframework"
# Job states before a runner takes the job: queued for a runner, or pending in the concurrency group.
WAITING_STATUSES = frozenset({"queued", "pending", "waiting", "requested"})
UNFINISHED_RUN_STATUSES = frozenset({"queued", "in_progress", "pending", "waiting", "requested"})

Request = Callable[[str, str], Any]


def waiting_build(jobs: Iterable[Mapping[str, Any]]) -> bool:
    """Whether the run's build has not started on a runner.

    An unfinished run with no build job yet is still in its own placement: GitHub creates the build only once
    its `needs` end, and that build would then enter the group ahead of this run's and queue there.
    """
    for job in jobs:
        if job.get("name") == BUILD_JOB_NAME:
            return job.get("status") in WAITING_STATUSES and not job.get("runner_name")
    return True


def older_unfinished(runs: Iterable[Mapping[str, Any]], own_id: int, branch: str) -> list[int]:
    """Ids of runs on `branch` older than this one (lower id) and not finished, oldest first."""
    ids = []
    for run in runs:
        try:
            run_id = int(run.get("id") or 0)
        except (TypeError, ValueError):
            continue
        if (0 < run_id < own_id and run.get("head_branch") == branch
                and run.get("status") in UNFINISHED_RUN_STATUSES):
            ids.append(run_id)
    return sorted(ids)


def supersede(request: Request, repo: str, own_id: int, branch: str, log: Callable[[str], None] = print) -> list[int]:
    """Cancel each older run on `branch` whose build waits for a runner; the ids cancelled."""
    listing = request("GET", f"/repos/{repo}/actions/workflows/{WORKFLOW_FILE}/runs?branch={branch}&per_page=30")
    cancelled = []
    for run_id in older_unfinished(listing.get("workflow_runs") or [], own_id, branch):
        jobs = request("GET", f"/repos/{repo}/actions/runs/{run_id}/jobs?filter=latest&per_page=100")
        if not waiting_build(jobs.get("jobs") or []):
            log(f"run {run_id}: its build is running or done; it keeps the group")
            continue
        request("POST", f"/repos/{repo}/actions/runs/{run_id}/cancel")
        log(f"run {run_id}: its build had not started on a runner; cancelled so run {own_id} builds the newer commit")
        cancelled.append(run_id)
    return cancelled


def github_request(token: str, api: str) -> Request:
    def request(method: str, path: str) -> Any:
        req = urllib.request.Request(api.rstrip("/") + path, method=method, headers={
            "Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28"})
        with urllib.request.urlopen(req, timeout=30) as response:
            body = response.read()
        return json.loads(body) if body.strip() else {}
    return request


def main(env: Mapping[str, str] = os.environ) -> int:
    token = env.get("GH_TOKEN", "")
    repo = env.get("GITHUB_REPOSITORY", "")
    branch = env.get("GITHUB_REF_NAME", "")
    try:
        own_id = int(env.get("GITHUB_RUN_ID", ""))
    except ValueError:
        own_id = 0
    if not (token and repo and branch and own_id):
        print("ffi_build_supersede: GH_TOKEN, GITHUB_REPOSITORY, GITHUB_REF_NAME or GITHUB_RUN_ID is unset; nothing done")
        return 0
    try:
        supersede(github_request(token, env.get("GITHUB_API_URL", "https://api.github.com")), repo, own_id, branch)
    except (urllib.error.URLError, OSError, ValueError) as error:
        print(f"::warning::ffi_build_supersede: {error}; an older waiting build may still hold the group")
    return 0


if __name__ == "__main__":
    sys.exit(main())
