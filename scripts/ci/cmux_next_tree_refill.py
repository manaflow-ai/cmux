#!/usr/bin/env python3
"""A pull request's own run makes sure its deferred same-tree tiers have a run that fills them.

DEFERRED_TREE_HAS_A_FILLER (cmux#51086). cmux-next's path routing defers a pull request's daemon and scheme
tiers to the artifacts run that publishes its cmux-tui tree, and leaves a wait marker for that run's notify.
On 2026-11-22 cmux#50471 (head 0d0b49cc, tree ca63fe36) deferred to run 45060021944 while the rate limit hid
that run's state. The run hung in a download until its job limit cancelled it; its failed notify and its
hand-off were refused on the spent quota, so nothing filled the pull request's `cmux-next daemon tests
(same-tree)` status. Every re-run of the pull request's run read the same rate limit and deferred to it again;
only re-running 45060021944's failed jobs by hand unblocked it.

So when the probe could not read the publisher (rate-limited) or read that it ended without publishing, it
writes tree_refill=1 and tree_source=<publisher sha>, and cmux-next.yml's same-tree-refill job runs this. It
waits out the rate limit (WAIT_BUDGET_S in all, the token's own reset), then:

  the tree is published               -> the ready notify starts the tree jobs (open same-tree runs dedupe it)
  an artifacts run of the sha is open -> nothing: its publish or its failed notify fills the tiers
  the newest one ended unpublished    -> its failed jobs are re-run, below attempt 3 (cmux_next_tree_notify.refill)
  no run, or the re-run is refused    -> the failed notify reports the tiers red (a same-tree run posts them)

Exit 0 on every verdict; 1 when GitHub could not be read within the budget (the job's red names the miss).

usage: cmux_next_tree_refill.py --repo OWNER/NAME --key KEY --publisher-sha SHA [--reason TEXT]
Needs GH_TOKEN with actions: write, contents: read and pull-requests: read.
"""

from __future__ import annotations

import argparse
import os
import sys
import time
from pathlib import Path
from typing import Callable

sys.path.insert(0, str(Path(__file__).resolve().parent))
import cmux_next_tree_notify as notify  # noqa: E402

# The job's timeout-minutes is 65: an installation's spent hour resets at most an hour later.
WAIT_BUDGET_S = 3600
# Waits after a refusal that names no reset (a secondary limit), in order; the last repeats.
BACKOFF_S = (30, 60, 120, 300)


def publisher_run(api: notify.Api, repo: str, sha: str) -> tuple[str, int]:
    """("open", id), ("ended", id) of the newest artifacts run of SHA, or ("none", 0)."""
    listing = api.get(f"repos/{repo}/actions/workflows/cmux-tui-artifacts.yml/runs?head_sha={sha}&per_page=20")
    runs = [run for run in listing.get("workflow_runs", []) if isinstance(run, dict) and run.get("id")]
    if not runs:
        return "none", 0
    if any(run.get("status") in notify.OPEN for run in runs):
        return "open", max(int(run["id"]) for run in runs if run.get("status") in notify.OPEN)
    return "ended", max(int(run["id"]) for run in runs)


def check(api: notify.Api, *, repo: str, key: str, sha: str, reason: str, log: Callable[[str], None] = print,
          fetch_completion: Callable[[str], object | None] = notify.fetch_completion,
          make: Callable[..., int] | None = None) -> str:
    """One look; returns published, live, rerun or reported (cmux_next_tree_notify.refill's words)."""
    reason = reason or f"tree {key}: no cmux-tui artifacts run publishes it"
    completion = fetch_completion(key)
    if notify.completion_attests(completion, key):
        return notify.refill(api, repo=repo, key=key, run_id=0, reason=reason, log=log, make=make,
                             fetch_completion=lambda _key: completion)
    state, run_id = publisher_run(api, repo, sha) if notify.SHA.match(sha) else ("none", 0)
    if state == "open":
        log(f"tree {key}: artifacts run {run_id} of {sha[:12]} is open; its publish or its failed notify fills "
            f"the same-tree tiers")
        return "live"
    if state == "none":
        reason = f"tree {key}: no cmux-tui artifacts run of {sha[:12] or 'its publisher'} exists to publish it"
    return notify.refill(api, repo=repo, key=key, run_id=run_id, reason=reason, log=log, make=make,
                         fetch_completion=lambda _key: None)


def wait_for(api: notify.GitHub | notify.Api, error: Exception, backoffs: int, now: float) -> float | None:
    """Seconds until a call GitHub refused on its rate limit may pass; None when the refusal is no rate limit."""
    status, payload, headers = getattr(api, "last", (0, b"", {}))
    if not notify.rate_limited(status, headers, payload):
        return None
    lowered = {str(name).lower(): str(value) for name, value in (headers or {}).items()}
    retry_after = lowered.get("retry-after", "").strip()
    if retry_after.isdigit():
        return max(1.0, float(retry_after))
    reset = lowered.get("x-ratelimit-reset", "").strip()
    if lowered.get("x-ratelimit-remaining") == "0" and reset.isdigit():
        return max(1.0, int(reset) - now + 5)
    return float(BACKOFF_S[min(backoffs, len(BACKOFF_S) - 1)])


def run(api: notify.Api, args: argparse.Namespace, *, log: Callable[[str], None] = print,
        sleep: Callable[[float], None] = time.sleep, now: Callable[[], float] = time.time,
        fetch_completion: Callable[[str], object | None] = notify.fetch_completion) -> int:
    started = now()
    backoffs = 0
    while True:
        try:
            verdict = check(api, repo=args.repo, key=args.key, sha=args.publisher_sha, reason=args.reason, log=log,
                            fetch_completion=fetch_completion)
        except (RuntimeError, OSError, ValueError) as error:
            wait = wait_for(api, error, backoffs, now())
            left = WAIT_BUDGET_S - (now() - started)
            if wait is None or wait > left:
                why = "not a rate limit" if wait is None else f"its reset is {int(wait)} s away, past this job's budget"
                log(f"::error title=same-tree refill::tree {args.key}: GitHub refused the check ({error}; {why}). "
                    f"Re-run this job once the limit resets: it starts the tree jobs, re-runs the publisher or "
                    f"reports the tiers red")
                return 1
            log(f"tree {args.key}: GitHub refused the check on its rate limit ({error}); waiting {int(wait)} s")
            backoffs += 1
            sleep(wait)
            continue
        log(f"::notice title=same-tree refill::tree {args.key}: {verdict}")
        return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo", required=True)
    parser.add_argument("--key", required=True)
    parser.add_argument("--publisher-sha", default="")
    parser.add_argument("--reason", default="")
    args = parser.parse_args(argv)
    if not notify.SHA.match(args.key):
        print(f"::error title=same-tree refill::not a tree key: {args.key!r}")
        return 1
    token = os.environ.get("GH_TOKEN", "")
    if not token:
        print("::error title=same-tree refill::no GH_TOKEN")
        return 1
    api = notify.GitHub(token, os.environ.get("GITHUB_API_URL", "https://api.github.com"),
                        os.environ.get("GH_TOKEN_SPARE", ""))
    return run(api, args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
