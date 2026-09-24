#!/usr/bin/env python3
"""Cancel a pull request CI run whose required Linux job has failed.

ci-status accepts only `success` or `skipped` from every job it needs, so once
one of the fast Linux jobs below concludes `failure` the pull request is red on
this head whatever the macOS jobs find. macos-debounce declines admission when
the failure lands before it admits; this covers the failure that lands after,
when the run's macOS jobs already hold the Mac pools.

ci.yml's `macos-fail-fast` job runs this only when `needs:` reports such a
failure, so there is no polling: at most one GraphQL read (the pull request's
state, head, labels and changed paths, in the shape the queue janitor reads)
and one cancel of this run. ci-status runs on cancellation and reports the
failure.

The exemptions are the queue janitor's (`doomed_run_kept`, `protected_reason`,
`resolve_pull_request`): a re-run attempt, the `no-janitor` label, a diff that
changes the app-host shards' inputs or cannot be read in full, and a pull
request that is closed or has moved to a newer head all keep the run. Failures
of macOS jobs stay with the janitor's `doomed` category and its grace window.
"""

from __future__ import annotations

import json
import os
import sys
from collections.abc import Mapping, Sequence
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
from queue_janitor import (  # noqa: E402
    GitHub,
    doomed_run_kept,
    protected_reason,
    resolve_pull_request,
)

# Required Linux jobs that run beside macOS admission. `needs:` waits for all
# of them, so none may take a Mac. ci.yml's macos-fail-fast job lists exactly
# these, and tests/test_ci_pr_fail_fast.py checks both facts.
FAST_LINUX_JOBS = (
    "guards",
    "ghosttykit-release-check",
    "browser",
    "web",
    "suite-coverage",
)

# ci-status inputs deliberately not watched, and why.
NOT_WATCHED = {
    "changes": "a failed router admits no macOS work",
    "static-preflight": "the macos call and claude-wrapper both need it to pass",
    "macos-debounce": "declines macOS admission itself",
    "linux-preflight": "fails only after a watched job or the router already has",
    "claude-wrapper": "runs on a Mac",
    "cli": "runs on a Mac",
    "remote-daemon": "its native tests run on a Mac",
    "macos": "macOS failures belong to the queue janitor",
    "tests": "reads the macos result",
}


def failed_linux_jobs(needs: Mapping[str, Any]) -> list[str]:
    """The fast Linux jobs `needs` reports as `failure`, in a stable order."""
    return sorted(
        name for name in FAST_LINUX_JOBS
        if (needs.get(name) or {}).get("result") == "failure"
    )


def workflow_path(workflow_ref: str) -> str:
    """`owner/repo/.github/workflows/ci.yml@ref` -> `.github/workflows/ci.yml`."""
    parts = workflow_ref.split("@", 1)[0].split("/", 2)
    return parts[2] if len(parts) == 3 else ""


def run_from_env(env: Mapping[str, str]) -> dict[str, Any]:
    """This run in the Actions API's shape, from the event instead of a read."""
    def number(key: str) -> int | None:
        value = (env.get(key) or "").strip()
        return int(value) if value.isdigit() else None

    pr_number = number("PR_NUMBER")
    return {
        "id": number("CI_RUN_ID"),
        "event": env.get("GITHUB_EVENT_NAME") or "",
        "name": env.get("GITHUB_WORKFLOW") or "",
        "path": workflow_path(env.get("CI_WORKFLOW_REF") or ""),
        "head_branch": env.get("HEAD_REF") or "",
        "head_sha": env.get("HEAD_SHA") or "",
        "run_attempt": number("CI_RUN_ATTEMPT"),
        "status": "in_progress",
        "head_repository": {"owner": {"login": env.get("HEAD_OWNER") or ""}},
        "pull_requests": [{"number": pr_number}] if pr_number is not None else [],
    }


def verdict(run: Mapping[str, Any], failed: Sequence[str], pr: Mapping[str, Any] | None) -> tuple[str, str]:
    """("cancel" | "keep", reason)."""
    if not failed:
        return "keep", "no watched Linux job failed"
    protected = protected_reason(run)
    if protected:
        return "keep", f"protected run: {protected}"
    if run.get("event") != "pull_request":
        return "keep", f"{run.get('event')} run, not a pull request"
    if pr is None:
        return "keep", "pull request could not be resolved"
    number = pr.get("number")
    if pr.get("state") != "OPEN":
        return "keep", f"PR #{number} is {str(pr.get('state')).lower()}; the janitor owns stale runs"
    if pr.get("headRefOid") != run.get("head_sha"):
        return "keep", f"PR #{number} head moved on; the newer run owns ci-status"
    kept = doomed_run_kept(run, pr)
    if kept:
        return "keep", kept
    names = ", ".join(f"`{name}`" for name in failed)
    return "cancel", f"{names} failed, so ci-status for PR #{number} is red whatever macOS finds"


def decide(github: Any, run: Mapping[str, Any], failed: Sequence[str], *, dry_run: bool) -> str:
    """Apply the verdict with at most one read and one cancel of this run."""
    if not failed:
        return "kept: no watched Linux job failed"
    pr = None
    branch = str(run.get("head_branch") or "")
    if run.get("event") == "pull_request" and branch:
        pr = resolve_pull_request(run, github.pull_requests([branch]).get(branch, ()))
    action, reason = verdict(run, failed, pr)
    if action != "cancel":
        return f"kept: {reason}"
    if dry_run:
        return f"would cancel: {reason}"
    github.cancel(run["id"])
    return f"cancelled: {reason}"


def main() -> int:
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    repo = os.environ.get("GH_REPO") or os.environ.get("GITHUB_REPOSITORY")
    run = run_from_env(os.environ)
    if not token or not repo or run["id"] is None:
        print("pr-fail-fast: GH_TOKEN, GH_REPO and CI_RUN_ID are required", file=sys.stderr)
        return 2
    try:
        needs = json.loads(os.environ.get("CI_NEEDS") or "{}")
    except json.JSONDecodeError:
        print("pr-fail-fast: CI_NEEDS is not JSON", file=sys.stderr)
        return 2
    dry_run = (os.environ.get("DRY_RUN") or "").lower() in {"1", "true", "yes"}
    github = GitHub(token, repo)
    try:
        outcome = decide(github, run, failed_linux_jobs(needs), dry_run=dry_run)
    except RuntimeError as error:
        print(f"pr-fail-fast: {error}", file=sys.stderr)
        return 1
    mode = "dry run" if dry_run else "live"
    summary = (
        f"## macOS fail fast ({mode})\n\nRun {run['id']}: {outcome}.\n\n_{github.calls} API call(s)._\n"
    )
    print(summary)
    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary_path:
        with open(summary_path, "a", encoding="utf-8") as handle:
            handle.write(summary)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
