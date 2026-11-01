#!/usr/bin/env python3
"""Warn when the workflow GITHUB_TOKEN's hourly budget runs low.

Every workflow in the repository draws on one GITHUB_TOKEN budget an hour. When
it ran out on 2026-10-25, every NEXT nightly's legacy publish failed with "API
rate limit exceeded for installation" and nothing said why beforehand. This reads
GET /rate_limit with that token (the endpoint does not count against the budget)
and, when the core budget's remaining share is under the threshold (20%), writes
a `::warning::` annotation and a step-summary section naming the reset time.

With ISSUE_TOKEN set (a token with issues: write; the queue janitor passes its
cmux-bot token), a low budget also opens one issue titled TITLE, or comments on
the open one when it has not been updated for an hour, so a person sees it
outside the run log without a comment every sweep. A healthy budget writes
nothing. Every failure is a warning: this never fails the job that runs it.

    BUDGET_TOKEN=<github.token> python3 scripts/ci/github_token_budget.py [--threshold 0.2]
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from datetime import datetime, timedelta, timezone

TITLE = "GITHUB_TOKEN hourly budget is running low"


def gh(args: list[str], token: str) -> str:
    env = {**os.environ, "GH_TOKEN": token}
    return subprocess.run(["gh", *args], check=True, capture_output=True, text=True, env=env, timeout=60).stdout


def low(core: dict, threshold: float) -> bool:
    limit = int(core.get("limit") or 0)
    return limit > 0 and int(core.get("remaining") or 0) < threshold * limit


def report(core: dict) -> str:
    reset = datetime.fromtimestamp(int(core.get("reset") or 0), timezone.utc)
    return (f"GITHUB_TOKEN core budget: {core.get('remaining')} of {core.get('limit')} left "
            f"({core.get('used')} used), resets {reset:%Y-%m-%d %H:%MZ}.")


def file_issue(repo: str, token: str, text: str, run_url: str, now: datetime | None = None) -> str:
    now = now or datetime.now(timezone.utc)
    # The open alerts, and separately the most recently updated ones of any state: a person who
    # closes the alert must not get a new issue on every low sweep within the hour.
    def listed(state: str, search: str) -> list[dict]:
        return json.loads(gh(["issue", "list", "-R", repo, "--state", state, "--search", search,
                              "--json", "number,title,state,updatedAt", "--limit", "20"], token))
    found = (listed("all", f'in:title "{TITLE}" sort:updated-desc')
             + listed("open", f'in:title "{TITLE}"'))
    body = (f"{text}\n\nSeen by {run_url}. Every workflow shares this budget; when it runs out, "
            "publish and release steps fail with \"API rate limit exceeded for installation\". "
            "Look for a new polling loop or per-run fan-out on github.token "
            "(tests/test_ci_no_github_token_polling.py), and move heavy readers to an App token.")
    ours = [issue for issue in found if issue.get("title") == TITLE]

    def updated(issue: dict) -> datetime:
        return datetime.fromisoformat(str(issue.get("updatedAt") or "1970-01-01T00:00:00Z").replace("Z", "+00:00"))

    # Any alert touched within the hour, open or closed (closing one updates it), says enough.
    for issue in ours:
        if now - updated(issue) < timedelta(hours=1):
            return f"#{issue['number']} was updated within the hour"
    for issue in ours:
        if str(issue.get("state", "")).upper() == "OPEN":
            gh(["issue", "comment", str(issue["number"]), "-R", repo, "--body", body], token)
            return f"commented on #{issue['number']}"
    out = gh(["issue", "create", "-R", repo, "--title", TITLE, "--body", body], token)
    return f"opened {out.strip()}"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("--threshold", type=float, default=0.2)
    args = parser.parse_args(argv)
    token = os.environ.get("BUDGET_TOKEN") or os.environ.get("GH_TOKEN", "")
    repo = os.environ.get("GITHUB_REPOSITORY", "")
    run_url = f"{os.environ.get('GITHUB_SERVER_URL', 'https://github.com')}/{repo}/actions/runs/{os.environ.get('GITHUB_RUN_ID', '')}"
    try:
        core = json.loads(gh(["api", "rate_limit"], token))["resources"]["core"]
    except (OSError, subprocess.SubprocessError, ValueError, KeyError, TypeError) as error:
        print(f"::warning title=GITHUB_TOKEN budget::could not read /rate_limit: {str(error)[:200]}")
        return 0
    text = report(core)
    print(text)
    if not low(core, args.threshold):
        return 0
    print(f"::warning title=GITHUB_TOKEN budget low::{text}")
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as handle:
            handle.write(f"### GITHUB_TOKEN budget low\n\n{text}\n")
    issue_token = os.environ.get("ISSUE_TOKEN", "")
    if issue_token and repo:
        try:
            print(file_issue(repo, issue_token, text, run_url))
        except (OSError, subprocess.SubprocessError, ValueError) as error:
            print(f"::warning title=GITHUB_TOKEN budget::could not file the issue: {str(error)[:200]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
