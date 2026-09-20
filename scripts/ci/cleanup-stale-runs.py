#!/usr/bin/env python3
"""Report or remove Actions runs stranded by closed pull requests.

The scheduled workflow is deliberately report-only.  Destructive cleanup is
available only from an explicit workflow_dispatch and is bounded by a small
action limit.  Runs with no pull request, or with any open pull request for
their commit, are always ignored.
"""

from __future__ import annotations

import datetime as dt
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from typing import Any


API = "https://api.github.com"


def parse_time(value: str) -> dt.datetime:
    return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))


def classify_run(
    run: dict[str, Any], pull_requests: list[dict[str, Any]], *, now: dt.datetime, min_age_seconds: int
) -> str | None:
    """Return an eligible reason, or None when the run must be preserved."""
    if not pull_requests or any(pr.get("state") == "open" for pr in pull_requests):
        return None
    created_at = run.get("created_at")
    if not created_at:
        return None
    if (now - parse_time(created_at)).total_seconds() < min_age_seconds:
        return None
    if any(pr.get("merged_at") for pr in pull_requests):
        return "merged PR"
    if any(pr.get("state") == "closed" for pr in pull_requests):
        return "closed PR"
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

    def runs(self, status: str) -> list[dict[str, Any]]:
        result: list[dict[str, Any]] = []
        for page in range(1, 11):
            query = urllib.parse.urlencode({"status": status, "per_page": 100, "page": page})
            payload = self.request("GET", f"/repos/{self.repo}/actions/runs?{query}")
            page_runs = payload.get("workflow_runs", [])
            result.extend(page_runs)
            if len(page_runs) < 100:
                break
        return result

    def pull_requests_for_commit(self, sha: str) -> list[dict[str, Any]]:
        path = f"/repos/{self.repo}/commits/{urllib.parse.quote(sha, safe='')}/pulls"
        return self.request("GET", path, missing_is_empty=True)


def env_bool(name: str, default: bool = False) -> bool:
    return os.environ.get(name, "true" if default else "false").lower() in {"1", "true", "yes"}


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
    now = dt.datetime.now(dt.timezone.utc)
    eligible: list[tuple[dict[str, Any], str]] = []
    try:
        for status in ("queued", "in_progress"):
            for run in janitor.runs(status):
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
        method = "DELETE" if run.get("status") == "queued" else "POST"
        try:
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
