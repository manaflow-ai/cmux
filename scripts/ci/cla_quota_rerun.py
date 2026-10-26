#!/usr/bin/env python3
"""Re-run CLA checks that failed only because the GITHUB_TOKEN budget was spent.

CLA Assistant and CLA policy guard are required on main and run on the repository's
GITHUB_TOKEN. When that installation budget runs out ("API rate limit exceeded for
installation", 2026-10-06 and from 21:10Z on 2026-10-25), both fail, and they stay red
until someone re-runs them by hand, often while the budget is still spent. Both files
are a trusted control plane: a change to either needs a trusted maintainer's review
(scripts/ci/validate-cla-policy.rb), so the retry lives here instead. ci-queue-janitor.yml
runs this every sweep:

1. One `rate_limit` read of the workflow token's budget (free). Under the floor, stop:
   a re-run now would fail the same way.
2. The newest pull_request_target runs of both workflows (one read each).
3. Only each pull request head's newest run counts, and only when it failed at the head
   the pull request still has. A CLA Assistant run is re-run when its failed job's log
   says the API rate limit was exceeded. A CLA policy guard run reports every error,
   a spent budget included, as "rejected the proposed policy" (validate-cla-policy.rb
   rescues PolicyError), so its failure is re-run while its attempt is under 8: a
   genuine rejection is deterministic and stops there.

Only a run whose head is still its pull request's head is touched. Reads and re-runs use
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
import urllib.error
import urllib.request
from typing import Any, Callable

API = "https://api.github.com"
WORKFLOWS = {"cla.yml": "assistant", "cla-policy-guard.yml": "guard"}
RATE_LIMITED = re.compile(r"rate limit exceeded|secondary rate limit", re.IGNORECASE)
FLOOR_SHARE = 0.2
FLOOR_MIN = 500
MAX_AGE = dt.timedelta(hours=24)
MAX_ATTEMPT = 20
MAX_GUARD_ATTEMPT = 8
MAX_LOG_READS = 12
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


def budget_ok(rate: dict[str, Any]) -> tuple[bool, str]:
    core = (rate.get("resources") or {}).get("core") or rate.get("rate") or {}
    limit, remaining = int(core.get("limit") or 0), int(core.get("remaining") or 0)
    floor = max(FLOOR_MIN, int(limit * FLOOR_SHARE))
    return remaining >= floor and limit > 0, f"{remaining} of {limit} left (floor {floor})"


def current_head(run: dict[str, Any]) -> bool:
    """The run tested its pull request's head as it is now (a fork's run lists no pull request)."""
    prs = run.get("pull_requests") or []
    return bool(prs) and (prs[0].get("head") or {}).get("sha") == run.get("head_sha")


def recent(run: dict[str, Any], now: dt.datetime) -> bool:
    stamp = run.get("updated_at") or run.get("created_at") or ""
    try:
        when = dt.datetime.fromisoformat(stamp.replace("Z", "+00:00"))
    except ValueError:
        return False
    return now - when <= MAX_AGE


def latest_failures(gh: GitHub, workflow: str, now: dt.datetime) -> list[dict[str, Any]]:
    """Each pull request head's newest run of `workflow`, when that run failed at the head the
    pull request still has. An older failure whose head was re-run since (passed, running or
    failed again) is never replayed: its event's base can be stale."""
    query = "event=pull_request_target&per_page=100"
    runs = gh.request("GET", f"/repos/{gh.repo}/actions/workflows/{workflow}/runs?{query}").get("workflow_runs") or []
    newest: dict[str, dict[str, Any]] = {}
    for run in runs:
        head = run.get("head_sha") or ""
        if head and int(run.get("id") or 0) > int(newest.get(head, {}).get("id") or 0):
            newest[head] = run
    return [run for run in newest.values()
            if run.get("status") == "completed" and run.get("conclusion") == "failure"
            and recent(run, now) and current_head(run) and int(run.get("run_attempt") or 1) < MAX_ATTEMPT]


def rate_limited_log(gh: GitHub, run: dict[str, Any]) -> bool:
    jobs = gh.request("GET", f"/repos/{gh.repo}/actions/runs/{run['id']}/jobs?filter=latest&per_page=10").get("jobs") or []
    for job in jobs:
        if job.get("conclusion") == "failure":
            return bool(RATE_LIMITED.search(gh.request("GET", f"/repos/{gh.repo}/actions/jobs/{job['id']}/logs", raw=True)))
    return False


def rotated(runs: list[dict[str, Any]], now: dt.datetime) -> list[dict[str, Any]]:
    """Oldest first, starting at a slot that moves every sweep, so a bounded scan reaches every
    candidate in turn and genuine failures cannot hold the read budget."""
    runs = sorted(runs, key=lambda run: int(run["id"]))
    if not runs:
        return runs
    start = (int(now.timestamp()) // 600) % len(runs)
    return runs[start:] + runs[:start]


def plan(gh: GitHub, now: dt.datetime, log: Callable[[str], None]) -> list[dict[str, Any]]:
    """The runs to re-run: CLA Assistant failures whose log shows the rate limit, and every CLA
    policy guard failure (its reason is hidden by design; a genuine rejection is deterministic
    and stops at MAX_GUARD_ATTEMPT). Guards come first: they need no log read."""
    chosen = [run for run in rotated(latest_failures(gh, "cla-policy-guard.yml", now), now)
              if int(run.get("run_attempt") or 1) < MAX_GUARD_ATTEMPT][:MAX_RERUNS // 2]
    reads = 0
    for run in rotated(latest_failures(gh, "cla.yml", now), now):
        if reads >= MAX_LOG_READS or len(chosen) >= MAX_RERUNS:
            break
        reads += 1
        if rate_limited_log(gh, run):
            chosen.append(run)
        else:
            log(f"CLA Assistant run {run['id']} failed for another reason; left alone")
    return chosen


def main(argv: list[str] | None = None, now: dt.datetime | None = None) -> int:
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
        ok, text = budget_ok(GitHub(rate_token, repo).request("GET", "/rate_limit"))
        if not ok:
            print(f"cla-quota-rerun: the workflow token's budget is low ({text}); a re-run would fail the same way")
            return 0
        gh = GitHub(token, repo)
        runs = plan(gh, now, print)
        for run in runs:
            name = run.get("name") or "CLA"
            print(f"cla-quota-rerun: {'would re-run' if args.dry_run else 're-running'} {name} run {run['id']} "
                  f"for #{run['pull_requests'][0].get('number')} at {run['head_sha'][:12]} (attempt {run.get('run_attempt')})")
            if not args.dry_run:
                gh.request("POST", f"/repos/{repo}/actions/runs/{run['id']}/rerun-failed-jobs")
        print(f"cla-quota-rerun: budget {text}; {len(runs)} re-run(s), {gh.calls} App call(s)")
    except (urllib.error.URLError, OSError, ValueError, KeyError) as error:
        print(f"::warning title=CLA quota re-run::{error}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
