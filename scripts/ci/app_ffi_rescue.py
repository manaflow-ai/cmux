#!/usr/bin/env python3
"""Rescue app-ffi-release.yml's build to Blacksmith macOS when no owned runner took it (hq#3690).

The build's runs-on is fixed when its job is created, and GitHub never re-routes a queued job: on 2026-11-16 run
43978720557's `build xcframework` sat queued on glaeda-side-std-xcode-26.6 from 23:23Z to 02:38Z behind about 70
pull request jobs and was cancelled having never had a runner, while the FFI pin it publishes kept feat-cmux-next's
startup path waiting. The owned-pool rescue (owned_pool_rescue.py) runs from main's copy and does not watch this
workflow, so the release watches its own build.

This runs as the workflow's `rescue` job, beside the build. Every POLL_S it reads its own run attempt's jobs (one
call, the job's GITHUB_TOKEN). It ends as soon as the build has a runner or has finished. A build GitHub still holds
queued with no runner RESCUE_MINUTES after this watch first saw it queued is rescued: this dispatches the workflow on
the same ref with `rescue: blacksmith`, whose build takes a Blacksmith macOS label ahead of every owned route (the
build holds no secret; the Linux publish job does), and then cancels its own run, so the dispatched run's build takes
its place in the concurrency group (it builds the ref's tip, which holds this run's commit). The jobs API can list a
build that waits for an older build in its concurrency group as queued too (2026-11-17: run 43993339863's build read
`queued` while 43978720557's held the group). Such a build may be rescued for that wait as well: its replacement
waits in the group on the Blacksmith route instead, and a rescued run never rescues again, so there is no loop. The
watch ends after WATCH_MINUTES whatever it saw.

Only BLACKSMITH_SWITCH (vars.CI_BLACKSMITH_MACOS) `pr-rescue` or `on` rescues; anything else (off) only watches and
reports. A rescued run never rescues again (the workflow's `rescue` job is skipped when inputs.rescue is set).
"""
from __future__ import annotations

import json
import os
import sys
import time
import urllib.error
import urllib.request
from typing import Any, Callable, Mapping

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import deadline_http  # noqa: E402

BUILD_JOB = "build xcframework"
RESCUE_MINUTES = 20.0  # coordinator (claude-sr2-coord), 2026-11-17: "If still unplaced after 20 min, it goes to Blacksmith"
WATCH_MINUTES = 100.0  # the build's own wait in its concurrency group plus RESCUE_MINUTES, bounded
POLL_S = 120.0  # at most WATCH_MINUTES * 60 / POLL_S (50) reads of one jobs page per run
RESCUE_SWITCHES = ("pr-rescue", "on")
RESCUE_INPUT = "blacksmith"
WORKFLOW_FILE = "app-ffi-release.yml"
API = "https://api.github.com"

WAIT, DONE, RESCUE = "wait", "done", "rescue"


def build_job(jobs: list[Mapping[str, Any]]) -> Mapping[str, Any] | None:
    """The build job of a run attempt's jobs, or None while GitHub has not created it."""
    return next((job for job in jobs if job.get("name") == BUILD_JOB), None)


def decide(job: Mapping[str, Any] | None, queued_since: float | None, now: float,
           minutes: float = RESCUE_MINUTES) -> tuple[str, float | None]:
    """(WAIT, DONE or RESCUE; the time the watch first saw the build queued with no runner, or None). Pure.

    DONE once the build has a runner or is no longer queued (running, finished, cancelled). RESCUE once it has stayed
    queued with no runner for `minutes` of this watch. A job not created yet, or one waiting for its concurrency group
    (status pending or waiting), resets nothing and rescues nothing."""
    if job is None:
        return WAIT, queued_since
    status = str(job.get("status") or "")
    if job.get("runner_name") or status in ("in_progress", "completed"):
        return DONE, queued_since
    if status != "queued":
        return WAIT, None
    since = now if queued_since is None else queued_since
    return (RESCUE if now - since >= minutes * 60 else WAIT), since


def _api(method: str, path: str, token: str, body: Mapping[str, Any] | None = None) -> Any:
    request = urllib.request.Request(
        f"{API}/{path}", method=method, data=None if body is None else json.dumps(body).encode(),
        headers={"Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json",
                 "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "cmux/app-ffi-rescue"})
    # deadline_http bounds the whole call, not each socket read (tests/test_ci_no_bare_urlopen.py); an HTTP error
    # status still raises urllib's HTTPError, as urlopen did.
    _status, raw, _headers = deadline_http.request(request, 30, raise_errors=True)
    return json.loads(raw) if raw else None


def watch(env: Mapping[str, str], api: Callable[..., Any] = _api, clock: Callable[[], float] = time.time,
          sleep: Callable[[float], None] = time.sleep, out: Callable[[str], None] = print) -> str:
    """The watch loop: returns DONE, RESCUE (after dispatching and cancelling) or WAIT (the watch timed out)."""
    repo, run, attempt = env["GITHUB_REPOSITORY"], env["GITHUB_RUN_ID"], env.get("GITHUB_RUN_ATTEMPT") or "1"
    token, ref = env["GH_TOKEN"], env.get("GITHUB_REF_NAME") or "feat-cmux-next"
    switch = (env.get("CI_BLACKSMITH_MACOS") or "").strip()
    start, queued_since = clock(), None
    while True:
        now = clock()
        try:
            page = api("GET", f"repos/{repo}/actions/runs/{run}/attempts/{attempt}/jobs?per_page=100", token)
            jobs = list((page or {}).get("jobs") or [])
        except (urllib.error.URLError, TimeoutError, ValueError) as error:
            out(f"jobs unread ({type(error).__name__}: {error}); next read in {POLL_S:.0f} s")
            jobs = None
        if jobs is not None:
            verdict, queued_since = decide(build_job(jobs), queued_since, now)
            if verdict == DONE:
                out(f"{BUILD_JOB} has a runner or ended: nothing to rescue")
                return DONE
            if verdict == RESCUE:
                waited = (now - queued_since) / 60
                if switch not in RESCUE_SWITCHES:
                    out(f"::warning::{BUILD_JOB} queued {waited:.0f} min with no runner; vars.CI_BLACKSMITH_MACOS is "
                        f"`{switch}`, not one of {', '.join(RESCUE_SWITCHES)}, so it is left queued")
                    return WAIT
                out(f"::warning::{BUILD_JOB} queued {waited:.0f} min with no runner: dispatching {WORKFLOW_FILE} on "
                    f"{ref} with rescue={RESCUE_INPUT} (Blacksmith macOS), then cancelling run {run} (hq#3690)")
                api("POST", f"repos/{repo}/actions/workflows/{WORKFLOW_FILE}/dispatches", token,
                    {"ref": ref, "inputs": {"rescue": RESCUE_INPUT}})
                api("POST", f"repos/{repo}/actions/runs/{run}/cancel", token)
                return RESCUE
        if now - start >= WATCH_MINUTES * 60:
            out(f"watched {WATCH_MINUTES:.0f} min; {BUILD_JOB} never stayed queued {RESCUE_MINUTES:.0f} min on a label")
            return WAIT
        sleep(POLL_S)


def main() -> int:
    watch(os.environ)
    return 0


if __name__ == "__main__":
    sys.exit(main())
