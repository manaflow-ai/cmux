#!/usr/bin/env python3
"""Re-run CLA checks that failed only because the GITHUB_TOKEN budget was spent.

CLA Assistant and CLA policy guard are required on main and run on the repository's
GITHUB_TOKEN. When that installation budget runs out ("API rate limit exceeded for
installation", 2026-10-06 and from 21:10Z on 2026-10-25), both fail, and they stay red
until someone re-runs them by hand, often while the budget is still spent. Both files
are a trusted control plane: a change to either needs a trusted maintainer's review
(scripts/ci/validate-cla-policy.rb), so the retry lives here instead. ci-cla-quota-rerun.yml
runs this when a CLA run fails (and when one of this janitor's re-runs completes, so a
backlog drains pass by pass), and every 10 minutes as a fallback: GitHub fires that cron
late or not at all (12:35Z to 14:19Z on 2026-10-26, while #25466 sat blocked for 80 min).

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
   evidence of an API failure: its own log shows a 403 or rate limit before the reject;
   or its pull request changes none of the paths the guard validates (POLICY_PATHS), so
   it proposes no policy and a failed read is the likely reject (a retry heuristic, not
   proof: a stale event base or an old policy with no usable test merge is rejected too,
   which is why it holds only while the run is below NO_POLICY_MAX_ATTEMPT); or a CLA Assistant job, on any pull
   request, logged "API rate limit exceeded for installation" within GUARD_WINDOW of it
   (the budget is the repository's, shared by both). None of these needs the response's
   x-ratelimit headers or a particular 403 wording. A reject with none of them is never
   re-run: it is reported as a possible real policy rejection.

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
# Every path validate-cla-policy.rb reads as policy (CLA_POLICY_PATHS and GUARD_PATHS there;
# tests/test_cla_quota_rerun.py keeps the two lists equal). A pull request that changes none
# of them proposes no policy: the guard passes it unless a GitHub read fails.
POLICY_PATHS = frozenset({
    ".github/workflows/cla.yml", "CLA.md", ".github/scripts/rerun-failed-cla.sh",
    ".github/scripts/refresh-cla-check.sh", ".github/workflows/cla-policy-guard.yml",
    "scripts/ci/validate-cla-policy.rb",
})
# A no-policy pull request's guard is re-run on this evidence while its attempt is below
# this: a branch far behind a policy change on main can still be rejected for real.
NO_POLICY_MAX_ATTEMPT = 3
MAX_FILE_PAGES = 3  # 300 changed files; a larger pull request gets no evidence this way
GUARD_WINDOW = dt.timedelta(minutes=15)
BASES = ("main", "feat-cmux-next")
MAX_PULL_PAGES = 5
FLOOR_SHARE = 0.1
FLOOR_MIN = 500
RERUN_COST = 40  # GITHUB_TOKEN calls a CLA Assistant or CLA policy guard re-run spends, generously
# A pass that finds the budget spent waits for a reset this close (the job's timeout covers
# it, and the App token, minted at the start, lives an hour). Rejects start passes, so the
# last reject before a reset leaves one pass waiting for it.
WAIT_FOR_RESET = dt.timedelta(minutes=40)
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


def open_heads(gh: GitHub, log: Callable[[str], None]) -> dict[str, set[int]]:
    """Head SHA -> numbers of the open pull requests into BASES at it (read per base, so other
    bases never use up the pages). Matching on the head SHA covers fork pull requests, whose runs
    list no pull request."""
    heads: dict[str, set[int]] = {}
    for base in BASES:
        for page in range(1, MAX_PULL_PAGES + 1):
            # Most recently updated first: a fresh reject's pull request was just pushed or edited.
            pulls = gh.request("GET", f"/repos/{gh.repo}/pulls?state=open&base={base}&per_page=100"
                                      f"&sort=updated&direction=desc&page={page}") or []
            for pull in pulls:
                if (pull.get("base") or {}).get("ref") == base and (pull.get("head") or {}).get("sha"):
                    heads.setdefault(pull["head"]["sha"], set()).add(int(pull.get("number") or 0))
            if len(pulls) < 100:
                break
        else:
            log(f"::warning title=CLA quota re-run::over {MAX_PULL_PAGES * 100} open pull requests into {base}; "
                "the rest are not scanned this sweep")
    return heads


def pull_number(run: dict[str, Any], heads: dict[str, set[int]]) -> int | None:
    """The open pull request into BASES this run is for, at the head it still has; None when
    there is none. A same-repository run names its pull requests, and one of them must be
    among the open ones at that head: a closed one, or one force-pushed since, does not count
    even when another open pull request has that SHA now. A fork's run names none, so its
    head SHA alone decides."""
    head = run.get("head_sha") or ""
    numbers = heads.get(head) or set()
    prs = run.get("pull_requests") or []
    if not prs:
        return min(numbers) if numbers else None
    for pr in prs:
        number = int(pr.get("number") or 0)
        if number in numbers and (pr.get("head") or {}).get("sha") == head:
            return number
    return None


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


def latest_failures(runs: list[dict[str, Any]], heads: dict[str, set[int]], now: dt.datetime) -> list[dict[str, Any]]:
    """Each pull request head's newest run, when that run failed at the head an open pull
    request into BASES still has. An older failure whose head was re-run since (passed,
    running or failed again) is never replayed: its event's base can be stale."""
    newest: dict[str, dict[str, Any]] = {}
    for run in runs:
        head = run.get("head_sha") or ""
        if head and int(run.get("id") or 0) > int(newest.get(head, {}).get("id") or 0):
            newest[head] = run
    return [run | {"number": pull_number(run, heads)} for run in newest.values()
            if run.get("status") == "completed" and run.get("conclusion") == "failure"
            and recent(run, now) and pull_number(run, heads) is not None and int(run.get("run_attempt") or 1) < MAX_ATTEMPT]


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


def proposes_no_policy(gh: GitHub, number: int) -> bool:
    """The pull request changes, adds, removes or renames none of POLICY_PATHS. False when
    that is not known (over MAX_FILE_PAGES of files)."""
    for page in range(1, MAX_FILE_PAGES + 1):
        files = gh.request("GET", f"/repos/{gh.repo}/pulls/{number}/files?per_page=100&page={page}") or []
        for item in files:
            if {item.get("filename"), item.get("previous_filename")} & POLICY_PATHS:
                return False
        if len(files) < 100:
            return True
    return False


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
    policy guard failures with evidence of an API failure (guard_api_failure, a pull request
    that proposes no policy, or a rate-limited CLA Assistant job within GUARD_WINDOW). Log
    and file reads are bounded by
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
        if not evidence and int(run.get("run_attempt") or 1) < NO_POLICY_MAX_ATTEMPT and reads < MAX_GUARD_READS:
            reads += 1
            evidence = proposes_no_policy(gh, run["number"])
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
                f"{run['head_sha'][:12]} changes CLA policy (or was re-run on that evidence already) and "
                f"shows no API failure and no rate-limited CLA Assistant within "
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
