#!/usr/bin/env python3
"""A same-key tree owner's state from the build controller's run feed, with no GitHub read.

cmux-tui-artifacts.yml's tree-owner-wait reads the run that owns its tree key. It used to
read it from the Actions API with the routing App's token (installation 164690637), whose
budget runner placement also needs. In the 24 h before cmux#48592 about 20 of those jobs
an hour read the owner. cmux#48592's CDN check saved none of these reads: in job
137333436826 (2026-11-22) owner 45059180516 was still building, so the tree was not on the
CDN, and the job made three Actions reads (the run twice, its jobs once).

The controller already holds every active run and job of manaflow-ai/cmux from GitHub's
webhooks. It serves them to CI runners on its public route
(gh-events.cmux.com/v1/github/actions?repo=manaflow-ai/cmux), and expected_wait.py
reads that route too. That feed lists only active runs and jobs, so it answers "still
building", the common case. For an owner it does not list (one that ended, or one it
missed), and for a stale or unreachable feed, this answers "unknown" (exit 3), and the
caller reads GitHub as before.

  cmux_tui_owner_feed.py run RUN_ID      print the run in the Actions API's shape (status, event,
                                          head_branch, run_started_at, created_at), exit 0; else exit 3
  cmux_tui_owner_feed.py handoff RUN_ID  exit 0 if the run's hand-off job ("report an unpublished
                                          cmux-tui tree to cmux-next") is running; exit 1 if it has not
                                          started (it is queued, or another of the run's jobs is still
                                          active: the hand-off needs them all, so it runs last); exit 3
                                          if the feed cannot tell

Environment: CMUX_TUI_RUN_FEED_URL (default: the public route above), REPOSITORY,
RUNNER_TEMP (where one fetch is cached for FEED_CACHE_S, so one step reads the feed once).
The feed is fetched with curl, like the steps around it, so their tests' fake curl answers it.
"""

from __future__ import annotations

import datetime as dt
import json
import os
import subprocess
import sys
import time

FEED_URL = "https://gh-events.cmux.com/v1/github/actions?repo=manaflow-ai/cmux"
ACTIVE = ("queued", "in_progress", "waiting", "pending", "requested")
HANDOFF_JOB = "report an unpublished cmux-tui tree to cmux-next"
# The receiver takes a delivery every few seconds on manaflow-ai/cmux. A feed whose newest one is
# older than this has lost its webhooks, so its "active" can be a run that already ended.
MAX_DELIVERY_AGE = dt.timedelta(minutes=2)
FEED_CACHE_S = 10
UNKNOWN = 3


def parse_time(value: object) -> dt.datetime | None:
    if not isinstance(value, str) or not value:
        return None
    try:
        moment = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    return moment if moment.tzinfo else moment.replace(tzinfo=dt.timezone.utc)


def fetch(url: str, cache: str | None) -> dict | None:
    """The feed, from CACHE when it was fetched under FEED_CACHE_S ago; None when unreadable."""
    if cache and os.path.exists(cache) and time.time() - os.path.getmtime(cache) < FEED_CACHE_S:
        try:
            return json.load(open(cache, encoding="utf-8"))
        except (OSError, ValueError):
            pass
    try:
        body = subprocess.run(
            ["curl", "--fail", "--silent", "--show-error", "--compressed", "--connect-timeout", "5",
             "--max-time", "20", url],
            capture_output=True, text=True, check=True, timeout=30).stdout
        feed = json.loads(body)
    except (OSError, subprocess.SubprocessError, ValueError):
        return None
    if not isinstance(feed, dict):
        return None
    if cache:
        try:
            with open(cache, "w", encoding="utf-8") as handle:
                json.dump(feed, handle)
        except OSError:
            pass
    return feed


def fresh(feed: dict, now: dt.datetime) -> bool:
    newest = parse_time(feed.get("receiver_last_delivery"))
    return newest is not None and now - MAX_DELIVERY_AGE <= newest <= now + dt.timedelta(minutes=1)


def active_run(feed: dict, run_id: int, repo: str | None) -> dict | None:
    for run in feed.get("runs") or ():
        if isinstance(run, dict) and str(run.get("id")) == str(run_id) and run.get("status") in ACTIVE:
            if repo and run.get("repo") and str(run["repo"]).lower() != repo.lower():
                return None
            return run
    return None


def attempt_jobs(feed: dict, run: dict) -> list[dict]:
    attempt = run.get("attempt") or 1
    return [job for job in feed.get("jobs") or ()
            if isinstance(job, dict) and str(job.get("run_id")) == str(run.get("id"))
            and (job.get("attempt") or 1) == attempt]


def run_view(feed: dict, run_id: int, repo: str | None, now: dt.datetime) -> dict | None:
    """The owner as the Actions API shows it, or None when the feed cannot say.

    run_started_at is the latest attempt's start, which the lease measures. For attempt 1 that is
    the run's created_at. A re-run's start is the earliest of its attempt's active jobs: a
    lower bound on its age, so an error can only delay a takeover, never cause one.
    """
    if not fresh(feed, now):
        return None
    run = active_run(feed, run_id, repo)
    if run is None:
        return None
    attempt = run.get("attempt") or 1
    if attempt == 1:
        started = run.get("created_at")
    else:
        starts = [moment for job in attempt_jobs(feed, run)
                  if (moment := parse_time(job.get("started_at") or job.get("created_at"))) is not None]
        if not starts:
            return None
        started = min(starts).strftime("%Y-%m-%dT%H:%M:%SZ")
    if not parse_time(started):
        return None
    return {"id": run.get("id"), "status": run.get("status"), "conclusion": None, "event": run.get("event"),
            "head_branch": run.get("head_branch"), "head_sha": run.get("head_sha"), "run_attempt": attempt,
            "run_started_at": started, "created_at": run.get("created_at"), "source": "controller run feed"}


def handoff(feed: dict, run_id: int, repo: str | None, now: dt.datetime) -> int:
    if not fresh(feed, now):
        return UNKNOWN
    run = active_run(feed, run_id, repo)
    if run is None:
        return UNKNOWN
    jobs = [job for job in attempt_jobs(feed, run) if job.get("status") in ACTIVE]
    if any(job.get("name") == HANDOFF_JOB and job.get("status") != "queued" for job in jobs):
        return 0
    return 1 if jobs else UNKNOWN


def main(argv: list[str]) -> int:
    if len(argv) != 2 or argv[0] not in ("run", "handoff") or not argv[1].isdigit():
        print("usage: cmux_tui_owner_feed.py run|handoff RUN_ID", file=sys.stderr)
        return 2
    temp = os.environ.get("RUNNER_TEMP")
    feed = fetch(os.environ.get("CMUX_TUI_RUN_FEED_URL") or FEED_URL,
                 os.path.join(temp, "cmux-tui-run-feed.json") if temp else None)
    if feed is None:
        return UNKNOWN
    now = dt.datetime.now(dt.timezone.utc)
    repo = os.environ.get("REPOSITORY") or os.environ.get("GITHUB_REPOSITORY")
    if argv[0] == "handoff":
        return handoff(feed, int(argv[1]), repo, now)
    view = run_view(feed, int(argv[1]), repo, now)
    if view is None:
        return UNKNOWN
    print(json.dumps(view))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
