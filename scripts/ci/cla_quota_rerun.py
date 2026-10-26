#!/usr/bin/env python3
"""Re-run CLA checks that failed only because the GITHUB_TOKEN budget was spent.

CLA Assistant and CLA policy guard are required on main and run on the repository's
GITHUB_TOKEN. When that installation budget runs out ("API rate limit exceeded for
installation", 2026-10-06 and from 21:10Z on 2026-10-25), both fail, and they stay red
until someone re-runs them by hand, often while the budget is still spent. Both files
are a trusted control plane: a change to either needs a trusted maintainer's review
(scripts/ci/validate-cla-policy.rb), so the retry lives here instead. ci-cla-quota-rerun.yml
runs this every 10 minutes:

1. One `rate_limit` read of the workflow token's budget (free). Under the floor, a re-run
   now would fail the same way. When that budget resets within WAIT_FOR_RESET, the pass
   sleeps until just after the reset and reads it once more: one planned pass per reset,
   in the minutes before push-triggered workflows drain the budget again. Otherwise it
   stops. Re-runs are capped so the pass leaves the floor's share for everything else
   (RERUN_COST GITHUB_TOKEN calls are reserved per re-run).
2. The newest pull_request_target runs of both workflows (one read each).
3. The open pull requests into main and feat-cmux-next (a page or a few), so a run counts
   only at the head its pull request still has. Fork pull requests are matched by head
   SHA: GitHub lists no pull request on a fork's run.
4. Only each head's newest run counts. A CLA Assistant run is re-run when its failed
   job's log says the API rate limit was exceeded. A CLA policy guard run reports every
   error, a spent budget included, as "rejected the proposed policy" (validate-cla-policy.rb
   rescues PolicyError and hides the reason), so a guard failure is re-run only with
   evidence of an API failure: its own log shows a 403 or rate limit before the reject,
   or a CLA Assistant job, on any pull request, logged "API rate limit exceeded for
   installation" within
   GUARD_WINDOW of it (the budget is the repository's, shared by both). A reject with
   neither is never re-run: it is reported as a possible real policy rejection.

A re-run changes no policy: the same trusted workflow runs again on the same head. Reads and re-runs use
GH_TOKEN (the janitor's App token, its own budget); RATE_TOKEN is the workflow token
whose budget is measured. Never fails the sweep: every error is a warning.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from typing import Any, Callable

API = "https://api.github.com"
WORKFLOWS = {"cla.yml": "assistant", "cla-policy-guard.yml": "guard"}
RATE_LIMITED = re.compile(r"rate limit exceeded|secondary rate limit", re.IGNORECASE)
# Only the repository installation's own budget, the one CLA policy guard spends too.
INSTALLATION_LIMITED = re.compile(r"API rate limit exceeded for installation", re.IGNORECASE)
# What a failed GitHub API read looks like in a log. "403" alone matches hashes and ids.
API_FAILURE = re.compile(r"rate limit|\bHTTP 403\b|\b403 Forbidden\b|\(HTTP 403\)", re.IGNORECASE)
GUARD_REJECT = "rejected the proposed policy"
GUARD_WINDOW = dt.timedelta(minutes=15)
BASES = ("main", "feat-cmux-next")
MAX_PULL_PAGES = 5
FLOOR_SHARE = 0.1
FLOOR_MIN = 500
RERUN_COST = 40  # GITHUB_TOKEN calls a CLA Assistant or CLA policy guard re-run spends, generously
WAIT_FOR_RESET = dt.timedelta(minutes=15)  # under the cron's observed 25-40 minute gaps
RESET_GRACE = dt.timedelta(seconds=20)
MAX_AGE = dt.timedelta(hours=24)
MAX_ATTEMPT = 20
MAX_GUARD_ATTEMPT = 8
MAX_LOG_READS = 12  # CLA Assistant logs per sweep
MAX_GUARD_READS = 12  # CLA policy guard logs, and CLA Assistant logs read as their evidence
MAX_RERUNS = 8


class GitHub:
    def __init__(self, token: str, repo: str) -> None:
        self.token, self.repo, self.calls = token, repo, 0

    def request(self, method: str, path: str, raw: bool = False) -> Any:
        self.calls += 1
        req = urllib.request.Request(API + path, method=method, data=b"" if method == "POST" else None)
        # Not sent on the redirect: job logs redirect to signed blob storage.
        req.add_unredirected_header("Authorization", f"Bearer {self.token}")
        req.add_header("Accept", "application/vnd.github+json")
        req.add_header("X-GitHub-Api-Version", "2022-11-28")
        with urllib.request.urlopen(req, timeout=30) as response:
            body = response.read()
        if raw:
            return body.decode("utf-8", "replace")
        return json.loads(body) if body else {}


def budget(rate: dict[str, Any]) -> tuple[int, dt.datetime | None, str]:
    """How many re-runs the workflow token's budget allows above the floor, when it resets,
    and a line saying so."""
    core = (rate.get("resources") or {}).get("core") or rate.get("rate") or {}
    limit, remaining = int(core.get("limit") or 0), int(core.get("remaining") or 0)
    floor = max(FLOOR_MIN, int(limit * FLOOR_SHARE))
    reset = dt.datetime.fromtimestamp(int(core["reset"]), dt.timezone.utc) if core.get("reset") else None
    allowed = max(0, (remaining - floor) // RERUN_COST) if limit > 0 else 0
    at = f", resets {reset:%H:%M:%SZ}" if reset else ""
    return min(MAX_RERUNS, allowed), reset, f"{remaining} of {limit} left (floor {floor}{at})"


def open_heads(gh: GitHub, log: Callable[[str], None]) -> dict[str, int]:
    """Head SHA -> number of each open pull request into BASES (read per base, so other bases
    never use up the pages). Matching on the head SHA covers fork pull requests, whose runs
    list no pull request."""
    heads: dict[str, int] = {}
    for base in BASES:
        for page in range(1, MAX_PULL_PAGES + 1):
            pulls = gh.request("GET", f"/repos/{gh.repo}/pulls?state=open&base={base}&per_page=100&page={page}") or []
            for pull in pulls:
                if (pull.get("base") or {}).get("ref") == base and (pull.get("head") or {}).get("sha"):
                    heads[pull["head"]["sha"]] = int(pull.get("number") or 0)
            if len(pulls) < 100:
                break
        else:
            log(f"::warning title=CLA quota re-run::over {MAX_PULL_PAGES * 100} open pull requests into {base}; "
                "the rest are not scanned this sweep")
    return heads


def eligible(run: dict[str, Any], heads: dict[str, int]) -> bool:
    """The run's head is an open pull request's head into BASES. A same-repository run names
    its pull requests: one of them must be into BASES and still at the run's head (a force
    push since leaves it stale, even when another pull request has that SHA now)."""
    head = run.get("head_sha")
    if head not in heads:
        return False
    prs = run.get("pull_requests") or []
    return not prs or any((pr.get("base") or {}).get("ref") in BASES and (pr.get("head") or {}).get("sha") == head
                          for pr in prs)


def when(stamp: str | None) -> dt.datetime | None:
    try:
        return dt.datetime.fromisoformat((stamp or "").replace("Z", "+00:00"))
    except ValueError:
        return None


def recent(run: dict[str, Any], now: dt.datetime) -> bool:
    stamp = when(run.get("updated_at") or run.get("created_at"))
    return stamp is not None and now - stamp <= MAX_AGE


def workflow_runs(gh: GitHub, workflow: str) -> list[dict[str, Any]]:
    query = "event=pull_request_target&per_page=100"
    return gh.request("GET", f"/repos/{gh.repo}/actions/workflows/{workflow}/runs?{query}").get("workflow_runs") or []


def latest_failures(runs: list[dict[str, Any]], heads: dict[str, int], now: dt.datetime) -> list[dict[str, Any]]:
    """Each pull request head's newest run, when that run failed at the head an open pull
    request into BASES still has. An older failure whose head was re-run since (passed,
    running or failed again) is never replayed: its event's base can be stale."""
    newest: dict[str, dict[str, Any]] = {}
    for run in runs:
        head = run.get("head_sha") or ""
        if head and int(run.get("id") or 0) > int(newest.get(head, {}).get("id") or 0):
            newest[head] = run
    return [run | {"number": heads[run["head_sha"]]} for run in newest.values()
            if run.get("status") == "completed" and run.get("conclusion") == "failure"
            and recent(run, now) and eligible(run, heads) and int(run.get("run_attempt") or 1) < MAX_ATTEMPT]


def failed_job(gh: GitHub, run: dict[str, Any]) -> tuple[str, dt.datetime | None]:
    """The log and completion time of the run's failed job ("" when none failed)."""
    jobs = gh.request("GET", f"/repos/{gh.repo}/actions/runs/{run['id']}/jobs?filter=latest&per_page=10").get("jobs") or []
    for job in jobs:
        if job.get("conclusion") == "failure":
            log = gh.request("GET", f"/repos/{gh.repo}/actions/jobs/{job['id']}/logs", raw=True)
            return log, when(job.get("completed_at")) or when(run.get("updated_at"))
    return "", None


def guard_api_failure(log: str) -> bool:
    """The guard's own log shows a failed API read before its generic reject."""
    before = log.split(GUARD_REJECT, 1)[0]
    return bool(API_FAILURE.search(before))


def rotated(runs: list[dict[str, Any]], now: dt.datetime) -> list[dict[str, Any]]:
    """Oldest first, starting at a slot that moves every sweep, so a bounded scan reaches every
    candidate in turn and genuine failures cannot hold the read budget."""
    runs = sorted(runs, key=lambda run: int(run["id"]))
    if not runs:
        return runs
    start = (int(now.timestamp()) // 600) % len(runs)
    return runs[start:] + runs[:start]


def plan(gh: GitHub, now: dt.datetime, log: Callable[[str], None], limit: int = MAX_RERUNS) -> list[dict[str, Any]]:
    """The runs to re-run: CLA Assistant failures whose log shows the rate limit, and CLA
    policy guard failures with evidence of an API failure (guard_api_failure, or a
    rate-limited CLA Assistant job within GUARD_WINDOW). Log reads are bounded by
    MAX_LOG_READS and MAX_GUARD_READS and rotate, so genuine failures cannot hold the read budget."""
    heads = open_heads(gh, log)
    assistant_runs = workflow_runs(gh, "cla.yml")
    guard_runs = workflow_runs(gh, "cla-policy-guard.yml")
    chosen: list[dict[str, Any]] = []
    limited_at: list[dt.datetime] = []  # when a CLA Assistant job hit the installation rate limit
    seen: set[int] = set()  # CLA Assistant runs whose log was read
    # Guards keep half the slots, so standing Assistant failures cannot starve them.
    assistant_limit = limit - limit // 2
    reads = 0
    for run in rotated(latest_failures(assistant_runs, heads, now), now):
        if reads >= MAX_LOG_READS:
            break
        reads += 1
        seen.add(run["id"])
        text, finished = failed_job(gh, run)
        if RATE_LIMITED.search(text):
            if finished and INSTALLATION_LIMITED.search(text):
                limited_at.append(finished)
            if len(chosen) < assistant_limit:
                chosen.append(run)
        else:
            log(f"CLA Assistant run {run['id']} for #{run['number']} failed for another reason; left alone")

    guards = [run for run in rotated(latest_failures(guard_runs, heads, now), now)
              if int(run.get("run_attempt") or 1) < MAX_GUARD_ATTEMPT]
    # A guard reject whose own log hides the cause can still be matched to a spent budget
    # through any rate-limited CLA Assistant failure in its window, re-run or not.
    extra = [run for run in assistant_runs if run.get("conclusion") == "failure" and recent(run, now)]
    reads = 0
    for run in guards:
        if reads >= MAX_GUARD_READS or len(chosen) >= limit:
            break
        reads += 1
        text, finished = failed_job(gh, run)
        near = lambda stamp: finished is not None and abs(stamp - finished) <= GUARD_WINDOW  # noqa: E731
        evidence = guard_api_failure(text) or any(near(stamp) for stamp in limited_at)
        if not evidence and finished is not None:
            for other in extra:
                stamp = when(other.get("updated_at"))
                if reads >= MAX_GUARD_READS or stamp is None or not near(stamp) or other["id"] in seen:
                    continue
                seen.add(other["id"])
                reads += 1
                other_text, other_finished = failed_job(gh, other)
                if INSTALLATION_LIMITED.search(other_text) and other_finished:
                    limited_at.append(other_finished)
                    if near(other_finished):
                        evidence = True
                        break
        if evidence:
            chosen.append(run)
        else:
            log(f"::warning title=CLA policy guard reject left alone::run {run['id']} for #{run['number']} at "
                f"{run['head_sha'][:12]} shows no API failure and no rate-limited CLA Assistant within "
                f"{int(GUARD_WINDOW.total_seconds() // 60)} min; possibly a real policy rejection, not re-run")
    return chosen


def main(argv: list[str] | None = None, now: dt.datetime | None = None,
         sleep: Callable[[float], None] = time.sleep) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args(argv)
    repo = os.environ.get("GITHUB_REPOSITORY", "")
    token, rate_token = os.environ.get("GH_TOKEN", ""), os.environ.get("RATE_TOKEN", "")
    if not (repo and token and rate_token):
        print("cla-quota-rerun: GITHUB_REPOSITORY, GH_TOKEN and RATE_TOKEN are required; nothing to do")
        return 0
    now = now or dt.datetime.now(dt.timezone.utc)
    try:
        rate_gh = GitHub(rate_token, repo)
        limit, reset, text = budget(rate_gh.request("GET", "/rate_limit"))
        if not limit and reset is not None and dt.timedelta(0) < reset - now <= WAIT_FOR_RESET:
            wait = reset + RESET_GRACE - now
            print(f"cla-quota-rerun: the workflow token's budget is low ({text}); "
                  f"one pass {int(wait.total_seconds())} s from now, just after the reset")
            sleep(wait.total_seconds())
            now += wait
            limit, reset, text = budget(rate_gh.request("GET", "/rate_limit"))
        if not limit:
            print(f"cla-quota-rerun: the workflow token's budget is low ({text}); a re-run would fail the same way")
            return 0
        gh = GitHub(token, repo)
        runs = plan(gh, now, print, limit)
        for run in runs:
            name = run.get("name") or "CLA"
            print(f"cla-quota-rerun: {'would re-run' if args.dry_run else 're-running'} {name} run {run['id']} "
                  f"for #{run['number']} at {run['head_sha'][:12]} (attempt {run.get('run_attempt')})")
            if not args.dry_run:
                gh.request("POST", f"/repos/{repo}/actions/runs/{run['id']}/rerun-failed-jobs")
        print(f"cla-quota-rerun: budget {text}; {len(runs)} re-run(s), {gh.calls} App call(s)")
    except (urllib.error.URLError, OSError, ValueError, KeyError) as error:
        print(f"::warning title=CLA quota re-run::{error}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
