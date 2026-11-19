#!/usr/bin/env python3
"""Report or remove Actions runs stranded by closed pull requests, or queued at a superseded head.

The scheduled workflow is deliberately report-only.  Destructive cleanup is
available only from an explicit workflow_dispatch and is bounded by a small
action limit.  Runs with no pull request, or with any open pull request for
their commit, are always ignored.

SUPERSEDED=true (dispatch only) also cancels queued pull_request runs whose
pull request is open at a newer head (classify_superseded): on 2026-11-19 cmux
had 2,500 queued runs against 118 in progress while Blacksmith's Linux labels
stalled, many of them at heads a later push had replaced. A run whose head is
any open pull request's head, a run that has started, a push or schedule run,
and every nightly, dev, promote or release workflow are always kept; each
cancel re-reads the run and its pull request first.
"""

from __future__ import annotations

import datetime as dt
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from typing import Any


API = "https://api.github.com"
# Workflows a superseded-head cancel never touches, by file name or run name.
PROTECTED_WORKFLOW = re.compile(r"nightly|promote|release|appcast|notariz|(?:^|[-_ /])dev(?:[-_ .]|$)", re.I)
SUPERSEDED_MIN_AGE_SECONDS = 600
SUPERSEDED_LIMIT_MAX = 500


def parse_time(value: str) -> dt.datetime:
    return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))


def may_be_eligible(run: dict[str, Any], *, now: dt.datetime, min_age_seconds: int) -> bool:
    """Whether the run's own facts allow cleanup, before any pull request is read.

    classify_run() preserves every run this rejects whatever its pull requests
    say, so main() reads a commit's pull requests only for runs that pass. The
    janitor read them for every queued and in-progress run (about 140, each a
    GITHUB_TOKEN request, twice an hour) while nearly all were pushes, side
    lanes or younger than a day.
    """
    # Commit-to-PR association also exists for main pushes and scheduled runs.
    # Only ordinary PR runs are eligible; unknown event/state facts fail closed.
    if run.get("event") != "pull_request" or run.get("status") not in {"queued", "in_progress"}:
        return False
    created_at = run.get("created_at")
    if not created_at:
        return False
    return (now - parse_time(created_at)).total_seconds() >= min_age_seconds


def classify_run(
    run: dict[str, Any], pull_requests: list[dict[str, Any]], *, now: dt.datetime, min_age_seconds: int
) -> str | None:
    """Return an eligible reason, or None when the run must be preserved."""
    if not may_be_eligible(run, now=now, min_age_seconds=min_age_seconds):
        return None
    if not pull_requests or any(pr.get("state") != "closed" for pr in pull_requests):
        return None
    if any(pr.get("merged_at") for pr in pull_requests):
        return "merged PR"
    if any(pr.get("state") == "closed" for pr in pull_requests):
        return "closed PR"
    return None


def classify_superseded(run: dict[str, Any], open_heads: dict[int, str], *, now: dt.datetime) -> str | None:
    """'superseded head' when RUN is a queued pull_request run of an open PR whose head has moved on, else None.

    OPEN_HEADS maps every open pull request's number to its head sha. A run at any open pull request's head is kept
    (one commit can head two PRs), as is a run that names no pull request, has started, is younger than
    SUPERSEDED_MIN_AGE_SECONDS, or belongs to a PROTECTED_WORKFLOW."""
    if run.get("event") != "pull_request" or run.get("status") != "queued":
        return None
    sha = str(run.get("head_sha") or "")
    try:
        age = (now - parse_time(str(run.get("created_at") or ""))).total_seconds()
    except ValueError:
        # A missing or malformed time keeps the run rather than ending the job with a traceback.
        return None
    if not sha or age < SUPERSEDED_MIN_AGE_SECONDS:
        return None
    if PROTECTED_WORKFLOW.search(str(run.get("path") or "")) or PROTECTED_WORKFLOW.search(str(run.get("name") or "")):
        return None
    if sha in open_heads.values():
        return None
    numbers = [pr.get("number") for pr in run.get("pull_requests") or [] if isinstance(pr, dict)]
    if numbers and all(n in open_heads and open_heads[n] != sha for n in numbers):
        return "superseded head"
    return None


class GitHub:
    def __init__(self, token: str, repo: str) -> None:
        self.repo = repo
        self.headers = {
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "cmux-stale-run-janitor",
        }

    def request(self, method: str, path: str, *, missing_is_empty: bool = False) -> Any:
        request = urllib.request.Request(API + path, headers=self.headers, method=method)
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                if response.status == 204:
                    return {}
                return json.load(response)
        except urllib.error.HTTPError as error:
            if error.code == 404 and missing_is_empty:
                return []
            raise RuntimeError(f"GitHub API request failed ({error.code})") from error
        except urllib.error.URLError as error:
            raise RuntimeError("GitHub API request failed") from error

    def runs(self, status: str, pages: int = 10) -> list[dict[str, Any]]:
        """The repository's pull_request runs in `status` (classify_run() keeps every other event)."""
        result: list[dict[str, Any]] = []
        for page in range(1, pages + 1):
            query = urllib.parse.urlencode({"status": status, "event": "pull_request", "per_page": 100, "page": page})
            payload = self.request("GET", f"/repos/{self.repo}/actions/runs?{query}")
            page_runs = payload.get("workflow_runs", [])
            result.extend(page_runs)
            if len(page_runs) < 100:
                break
        return result

    def open_heads(self) -> dict[int, str]:
        """Every open pull request's number and head sha, paged until an empty page (at most 60 pages)."""
        heads: dict[int, str] = {}
        for page in range(1, 61):
            query = urllib.parse.urlencode({"state": "open", "per_page": 100, "page": page})
            payload = self.request("GET", f"/repos/{self.repo}/pulls?{query}")
            if not payload:
                return heads
            for pr in payload:
                heads[int(pr["number"])] = str(pr["head"]["sha"])
        raise RuntimeError("more than 6,000 open pull requests: the superseded pass would not see them all")

    def pull_requests_for_commit(self, sha: str) -> list[dict[str, Any]]:
        path = f"/repos/{self.repo}/commits/{urllib.parse.quote(sha, safe='')}/pulls"
        return self.request("GET", path, missing_is_empty=True)


def env_bool(name: str, default: bool = False) -> bool:
    return os.environ.get(name, "true" if default else "false").lower() in {"1", "true", "yes"}


def superseded_pass(janitor: GitHub, repo: str, *, cleanup: bool, limit: int) -> int:
    """Cancel (or, without CLEANUP, list) up to LIMIT queued runs at a superseded head; 1 on any failure."""
    try:
        open_heads = janitor.open_heads()
        now = dt.datetime.now(dt.timezone.utc)
        eligible = [run for run in janitor.runs("queued", pages=25)
                    if classify_superseded(run, open_heads, now=now)]
    except RuntimeError as error:
        print(f"stale-run-janitor: superseded: {error}", file=sys.stderr)
        return 1
    print(f"stale-run-janitor: superseded {'CLEANUP' if cleanup else 'DRY-RUN'}; open_prs={len(open_heads)}; "
          f"eligible={len(eligible)}; limit={limit}")
    if not cleanup:
        for run in eligible[:limit]:
            print(f"would cancel run {run.get('id')} ({run.get('path')}, {run.get('head_sha', '')[:12]}, superseded head)")
        return 0
    cancelled = failures = 0
    for run in eligible[:limit]:
        run_id = run.get("id")
        endpoint = f"/repos/{repo}/actions/runs/{run_id}"
        try:
            # The run can start, and its pull request can move back to this head, after the inventory.
            current = janitor.request("GET", endpoint)
            live = dict(open_heads)
            for number in {pr.get("number") for pr in current.get("pull_requests") or [] if isinstance(pr, dict)}:
                if number in live:
                    pr = janitor.request("GET", f"/repos/{repo}/pulls/{number}")
                    if pr.get("state") == "open":
                        live[number] = str(pr["head"]["sha"])
                    else:
                        del live[number]
            # Any other pull request pushed back to this commit since the inventory makes it a live head again.
            for pr in janitor.pull_requests_for_commit(str(current.get("head_sha") or "")):
                if isinstance(pr, dict) and pr.get("state") == "open" and isinstance(pr.get("number"), int):
                    live[pr["number"]] = str(pr["head"]["sha"])
            if not classify_superseded(current, live, now=dt.datetime.now(dt.timezone.utc)):
                print(f"preserved run {run_id}: no longer a queued run at a superseded head")
                continue
            janitor.request("POST", endpoint + "/cancel")
            cancelled += 1
            print(f"cancelled run {run_id} ({current.get('path')}, {current.get('head_sha', '')[:12]}, superseded head)")
        except (RuntimeError, KeyError, TypeError) as error:
            failures += 1
            print(f"failed run {run_id}: {error}", file=sys.stderr)
    print(f"stale-run-janitor: superseded cancelled={cancelled}; failures={failures}")
    return 1 if failures else 0


def main() -> int:
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    repo = os.environ.get("GH_REPO") or os.environ.get("GITHUB_REPOSITORY")
    if not token or not repo:
        print("stale-run-janitor: GH_TOKEN and GH_REPO are required", file=sys.stderr)
        return 2

    try:
        min_age_minutes = int(os.environ.get("MIN_AGE_MINUTES", "1440"))
        max_actions = int(os.environ.get("MAX_ACTIONS", "25"))
    except ValueError:
        print("stale-run-janitor: MIN_AGE_MINUTES and MAX_ACTIONS must be integers", file=sys.stderr)
        return 2
    if min_age_minutes < 1 or max_actions < 1:
        print("stale-run-janitor: age and action limits must be positive", file=sys.stderr)
        return 2
    if max_actions > 25:
        print("stale-run-janitor: MAX_ACTIONS must not exceed 25", file=sys.stderr)
        return 2

    cleanup_requested = env_bool("CLEANUP") and os.environ.get("GITHUB_EVENT_NAME") == "workflow_dispatch"
    janitor = GitHub(token, repo)
    if env_bool("SUPERSEDED") and os.environ.get("GITHUB_EVENT_NAME") == "workflow_dispatch":
        try:
            limit = int(os.environ.get("MAX_SUPERSEDED", "200"))
        except ValueError:
            limit = 0
        if not 1 <= limit <= SUPERSEDED_LIMIT_MAX:
            print(f"stale-run-janitor: MAX_SUPERSEDED must be 1..{SUPERSEDED_LIMIT_MAX}", file=sys.stderr)
            return 2
        return superseded_pass(janitor, repo, cleanup=cleanup_requested, limit=limit)
    now = dt.datetime.now(dt.timezone.utc)
    eligible: list[tuple[dict[str, Any], str]] = []
    try:
        for status in ("queued", "in_progress"):
            for run in janitor.runs(status):
                if not may_be_eligible(run, now=now, min_age_seconds=min_age_minutes * 60):
                    continue
                # Read per run, not per commit: a pull request can close between two runs of one commit.
                prs = janitor.pull_requests_for_commit(run.get("head_sha", ""))
                reason = classify_run(run, prs, now=now, min_age_seconds=min_age_minutes * 60)
                if reason:
                    eligible.append((run, reason))
    except RuntimeError as error:
        print(f"stale-run-janitor: {error}", file=sys.stderr)
        return 1

    mode = "CLEANUP" if cleanup_requested else "DRY-RUN"
    print(f"stale-run-janitor: {mode}; eligible={len(eligible)}; limit={max_actions}")
    if not cleanup_requested:
        for run, reason in eligible[:max_actions]:
            print(f"would process run {run.get('id')} ({run.get('status')}, {reason})")
        return 0

    processed = 0
    failures = 0
    for run, reason in eligible[:max_actions]:
        run_id = run.get("id")
        endpoint = f"/repos/{repo}/actions/runs/{run_id}"
        try:
            # Runs can complete and PRs can reopen after inventory collection.
            current = janitor.request("GET", endpoint)
            prs = janitor.pull_requests_for_commit(current.get("head_sha", ""))
            reason = classify_run(current, prs, now=dt.datetime.now(dt.timezone.utc),
                                  min_age_seconds=min_age_minutes * 60)
            if not reason:
                print(f"preserved run {run_id}: no longer eligible")
                continue
            method = "DELETE" if current.get("status") == "queued" else "POST"
            janitor.request(method, endpoint + ("/cancel" if method == "POST" else ""))
            processed += 1
            print(f"processed run {run_id} ({reason})")
        except RuntimeError as error:
            failures += 1
            print(f"failed run {run_id}: {error}", file=sys.stderr)
    print(f"stale-run-janitor: processed={processed}; failures={failures}")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
