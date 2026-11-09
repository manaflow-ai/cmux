#!/usr/bin/env python3
"""Cancel cmux NEXT DEV publish runs that a newer one supersedes before their Mac jobs start.

cmux-next-dev-daily.yml runs once per source run ("cmux NEXT DEV daily · publish <source run id>").
Its Linux jobs (signer, sign, runner) finish in minutes, and its Mac jobs (verify, the tip DMG build,
the tip deltas) then wait for a Mac. On 2026-11-09 13:30Z seven publish runs were open, each with its
Linux jobs done and its Mac jobs queued on glaeda-std-xcode-26.6 (1 of 57 runners online); the runner
owner cancelled four by hand. Publish and the tip feed refuse to roll back (not_newer), so an older run
whose Mac jobs have not started can never publish once a newer source run is in flight, but it still
holds a Mac queue slot.

The rule, run by the publisher's `supersede` job once its own run has a signed app:

- A candidate is an open publish run of this workflow on main (workflow_dispatch), other than this run,
  whose source run id is lower than this run's, that has a Mac job not yet finished and no job running.
  A Mac job a runner has taken (queued, with a runner name) counts as running.
- The OLDEST candidate is kept: its queued Mac job is closest to a runner. "Oldest" is the earliest
  creation time of its unfinished Mac jobs (the queue position), then the run's own creation time, then
  the lower source run id. This run is kept as well. Every other candidate is cancelled.
- A run with a running job, a run with a newer (or the same) source run id, a run whose Mac jobs are all
  finished, a run whose jobs cannot be read, and every run of another workflow, branch or title are left
  alone. Each run's jobs are read again right before its cancel.

Why the oldest stays: no concurrency group (see the comment on the workflow's sign job). A group keeps one
pending run and replaces it with each newer handoff, so while the signer waited for a runner nothing
published for over six hours (2026-10-26). Cancelling every older run would do the same whenever the Mac
wait is longer than the handoff interval: each new handoff would cancel the one before it before it got a
Mac. Keeping the oldest candidate means the run nearest a runner always goes on, so the channel moves
forward, and at most two runs per channel wait for a Mac (the oldest and the newest).

    cmux_next_dev_publish_supersede.py --run-id ID --source-run-id SOURCE [--repo OWNER/REPO]

Needs GH_TOKEN with actions: write. The workflow runs it with `python3 -I`; it imports nothing local.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.request
from collections.abc import Callable, Mapping, Sequence
from typing import Any, Protocol

REPO = "manaflow-ai/cmux"
WORKFLOW = "cmux-next-dev-daily.yml"
WORKFLOW_PATH = f".github/workflows/{WORKFLOW}"
BRANCH = "main"
TITLE = re.compile(r"^cmux NEXT DEV daily · publish ([0-9]+)$")
# The Mac jobs of cmux-next-dev-daily.yml (verify, tip-dmg-build, tip-deltas), by their rendered names.
MAC_JOBS = (
    "Verify signed cmux NEXT DEV",
    "Build the unsigned cmux NEXT DEV tip DMG",
    "Add deltas to the cmux NEXT DEV tip feed",
)
# The run statuses listed. A run whose Mac jobs wait is in_progress (its Linux jobs ran), or queued after
# a re-run of failed jobs; a run still waiting, pending or requested has not signed, so it has no Mac job.
LISTED_STATUSES = ("in_progress", "queued")


class Api(Protocol):
    """The GitHub REST calls this script makes; tests pass a fake."""

    def get(self, path: str) -> Any: ...

    def post(self, path: str, body: dict) -> int: ...


class GitHub:
    """GitHub's REST API with one token."""

    def __init__(self, token: str, api_url: str = "https://api.github.com"):
        self.token = token
        self.api_url = api_url.rstrip("/")

    def _request(self, method: str, path: str, body: dict | None = None) -> tuple[int, bytes]:
        data = json.dumps(body).encode() if body is not None else None
        request = urllib.request.Request(f"{self.api_url}/{path}", data=data, method=method, headers={
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
        })
        request.add_unredirected_header("Authorization", f"Bearer {self.token}")
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return response.status, response.read()
        except urllib.error.HTTPError as error:
            return error.code, error.read()

    def get(self, path: str) -> Any:
        status, payload = self._request("GET", path)
        if status != 200:
            raise RuntimeError(f"GET {path}: HTTP {status}")
        return json.loads(payload)

    def post(self, path: str, body: dict) -> int:
        return self._request("POST", path, body)[0]


def source_of(run: Mapping[str, Any]) -> int | None:
    """The source run id a publish run publishes, from its title; None for anything else."""
    for title in (run.get("display_title"), run.get("name")):
        match = TITLE.match(str(title or ""))
        if match:
            return int(match.group(1))
    return None


def is_mac_job(job: Mapping[str, Any]) -> bool:
    name = str(job.get("name") or "")
    return any(name == mac or name.startswith(mac + " (") for mac in MAC_JOBS)


def running(jobs: Sequence[Mapping[str, Any]]) -> str:
    """The name of a job of the run that has started and not finished, or "" when none has.

    A Mac job a runner has taken (queued, with a runner name: in its runner's setup) counts. Any running
    job keeps the run, a Linux one too: a publish, notarization or feed write is never cut short."""
    for job in jobs:
        status = job.get("status")
        if status == "in_progress" or (status != "completed" and job.get("runner_name")):
            return str(job.get("name") or job.get("id"))
    return ""


def unfinished_mac_jobs(jobs: Sequence[Mapping[str, Any]]) -> list[Mapping[str, Any]]:
    return [job for job in jobs if is_mac_job(job) and job.get("status") != "completed"]


def why_not_candidate(jobs: Sequence[Mapping[str, Any]] | None) -> str:
    """Why a lower-source publish run is not a candidate, or "" when it is."""
    if jobs is None:
        return "its jobs could not be read"
    busy = running(jobs)
    if busy:
        return f"{busy} is running"
    if not unfinished_mac_jobs(jobs):
        return "no Mac job of it waits"
    return ""


def queue_key(run: Mapping[str, Any], jobs: Sequence[Mapping[str, Any]], source: int) -> tuple[str, str, int]:
    """Sorts the candidate nearest a Mac runner first: its unfinished Mac jobs' earliest creation, then the
    run's own creation, then its source run id. ISO 8601 UTC stamps sort as strings; a missing one last."""
    created = [str(job.get("created_at")) for job in unfinished_mac_jobs(jobs) if job.get("created_at")]
    return (min(created) if created else "~", str(run.get("created_at") or "~"), source)


def open_runs(api: Api, repo: str) -> list[Mapping[str, Any]]:
    """This workflow's open workflow_dispatch runs on main, one listing per status, deduplicated by id."""
    found: dict[int, Mapping[str, Any]] = {}
    for status in LISTED_STATUSES:
        listed = api.get(f"repos/{repo}/actions/workflows/{WORKFLOW}/runs?branch={BRANCH}"
                         f"&event=workflow_dispatch&status={status}&per_page=100")
        for run in (listed or {}).get("workflow_runs") or []:
            if isinstance(run, Mapping) and isinstance(run.get("id"), int):
                found[run["id"]] = run
    return list(found.values())


def read_jobs(api: Api, repo: str, run_id: int, log: Callable[[str], None]) -> list[Mapping[str, Any]] | None:
    try:
        listed = api.get(f"repos/{repo}/actions/runs/{run_id}/jobs?filter=latest&per_page=100")
    except (RuntimeError, urllib.error.URLError, OSError, ValueError) as error:
        log(f"could not read the jobs of publish run {run_id} ({error}); left alone")
        return None
    return [job for job in (listed or {}).get("jobs") or [] if isinstance(job, Mapping)]


def cancel_superseded(api: Api, repo: str, run_id: int, source_run_id: int,
                      log: Callable[[str], None] = print) -> list[int]:
    """Cancel the publish runs this one supersedes, except the oldest; returns the cancelled run ids.

    `run_id` is this publish run and `source_run_id` the source run it publishes. See the module docstring
    for the rule."""
    candidates: list[tuple[tuple[str, str, int], int, int]] = []
    for run in open_runs(api, repo):
        other, source = run.get("id"), source_of(run)
        if (other == run_id or source is None or run.get("event") != "workflow_dispatch"
                or run.get("head_branch") != BRANCH or run.get("status") not in LISTED_STATUSES
                or run.get("path", WORKFLOW_PATH) != WORKFLOW_PATH):
            continue
        if source >= source_run_id:
            log(f"publish run {other} (source {source}) is not older than source {source_run_id}; left alone")
            continue
        jobs = read_jobs(api, repo, other, log)
        why = why_not_candidate(jobs)
        if why:
            log(f"publish run {other} (source {source}): {why}; left alone")
            continue
        candidates.append((queue_key(run, jobs or [], source), other, source))
    if not candidates:
        log("no older publish run waits for a Mac; nothing to cancel")
        return []
    candidates.sort()
    _, kept, kept_source = candidates[0]
    log(f"keeping publish run {kept} (source {kept_source}): the oldest waiting for a Mac, nearest a runner")
    cancelled: list[int] = []
    for _, other, source in candidates[1:]:
        # Read again right before the cancel: a Mac job may have started since the first read.
        why = why_not_candidate(read_jobs(api, repo, other, log))
        if why:
            log(f"publish run {other} (source {source}): {why} now; left alone")
            continue
        status = api.post(f"repos/{repo}/actions/runs/{other}/cancel", {})
        if status in (202, 204):
            cancelled.append(other)
            log(f"cancelled publish run {other} (source {source}): superseded by source {source_run_id}, "
                f"and publish run {kept} (source {kept_source}) is nearer a Mac; none of its Mac jobs started")
        else:
            log(f"could not cancel publish run {other} (source {source}): HTTP {status}")
    return cancelled


def main(argv: Sequence[str] | None = None, env: Mapping[str, str] | None = None,
         api: Api | None = None) -> int:
    env = os.environ if env is None else env
    parser = argparse.ArgumentParser(description=(__doc__ or "").splitlines()[0])
    parser.add_argument("--repo", default=env.get("GITHUB_REPOSITORY") or REPO)
    parser.add_argument("--run-id", default=env.get("GITHUB_RUN_ID") or "")
    parser.add_argument("--source-run-id", default=env.get("SOURCE_RUN_ID") or "")
    args = parser.parse_args(argv)
    if not str(args.run_id).isdigit() or not str(args.source_run_id).isdigit():
        print(f"error: --run-id ({args.run_id!r}) and --source-run-id ({args.source_run_id!r}) must be numbers",
              file=sys.stderr)
        return 2
    if api is None:
        token = env.get("GH_TOKEN") or env.get("GITHUB_TOKEN") or ""
        if not token:
            print("error: GH_TOKEN is not set", file=sys.stderr)
            return 2
        api = GitHub(token, env.get("GITHUB_API_URL") or "https://api.github.com")
    try:
        cancel_superseded(api, args.repo, int(args.run_id), int(args.source_run_id))
    except (RuntimeError, urllib.error.URLError, OSError, ValueError) as error:
        # Best effort: a missed cancel only leaves a superseded run queued, as before this job existed.
        print(f"::warning title=DEV publish supersede::could not list the open publish runs ({error}); "
              "nothing cancelled")
    return 0


if __name__ == "__main__":
    sys.exit(main())
