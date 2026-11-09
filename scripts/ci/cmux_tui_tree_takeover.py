#!/usr/bin/env python3
"""Take over a cmux-tui tree whose owning artifacts run ended without publishing it.

One cmux-tui artifacts run owns the publish of a tree key (tree-preflight's
claim, tree-owner-wait). Every other commit with that key waits on it: its
cmux-next run leaves a `cmux-next-tree-wait-<key>` marker, and its own artifacts
run builds nothing. When the owner ends without publishing (a failed build, a
cancel, or jobs GitHub never created), the waiters used to go red with "artifacts
run N ended without publishing tree K" and stayed red until some later commit
published the key (2026-11-09: run 42673437035 on a lane branch owned tree
c9b813e8; GitHub never created its x86_64 musl build job, and feat-cmux-next's
tip daemon suite and base tier went red for it).

A waiter takes the publish over instead. For a waiting feat-cmux-next commit it
dispatches cmux-tui-tree-request.yml, which re-runs that commit's own artifacts
run when the tree is still missing and no run of the key is active; the re-run
wins the claim, builds and publishes the key, and its publish starts every
waiter's tree jobs through the markers, which stay. The publish itself is
unchanged: publish-cmux-tui-tree.py still writes the tree once, and a second
publisher of the same key still meets the claim.

Only feat-cmux-next commits are taken over (their push run holds the R2 publish
credentials; cmux-tui-tree-request.yml refuses any other commit). A commit whose
artifacts run is already active is publishing: nothing is started. A run already
on its MAX_ATTEMPT-th attempt is not re-run (the hand-off's cap,
cmux_tui_tree_handoff.py): the waiter then reports the tree unavailable in red,
as before, so a key that cannot build is still seen.

Callers:
- cmux_next_tree_notify.py --state failed, before it dispatches red same-tree
  runs: one takeover per key covers every marker.
- cmux-next.yml's same-tree job, when it is about to report a tree unavailable
  (a dispatch from an owner that ran an older notify, or a push whose probe found
  its publisher ended): `--commit SHA` exits 0 when the publish was taken over.

usage: cmux_tui_tree_takeover.py --repo OWNER/NAME --commit SHA [--key KEY]
Needs GH_TOKEN with actions: write.
"""
from __future__ import annotations

import argparse
import os
import re
import sys
from typing import Callable, Iterable, Protocol

SHA = re.compile(r"^[0-9a-f]{40}$")
BRANCH = "feat-cmux-next"
ARTIFACTS_WORKFLOW = "cmux-tui-artifacts.yml"
REQUEST_WORKFLOW = "cmux-tui-tree-request.yml"
# A commit's artifacts run is re-run at most twice for a takeover (attempt 3 is its last), like the hand-off.
MAX_ATTEMPT = 3


class Api(Protocol):
    def get(self, path: str): ...
    def post(self, path: str, body: dict) -> int: ...


def trusted_runs(runs: Iterable[object]) -> list[dict]:
    """The commit's artifacts runs that can publish: feat-cmux-next pushes and dispatches."""
    return [run for run in runs if isinstance(run, dict) and run.get("head_branch") == BRANCH
            and run.get("event") in ("push", "workflow_dispatch")]


def take_over(api: Api, *, repo: str, commit: str, key: str = "") -> tuple[bool, str]:
    """(taken over, why). True when a publisher of the commit's tree is active or was just requested."""
    tree = f"tree {key}" if key else f"the tree of {commit[:12]}"
    if not SHA.match(commit):
        return False, f"{commit!r} is not a 40-hex commit"
    listing = api.get(f"repos/{repo}/actions/workflows/{ARTIFACTS_WORKFLOW}/runs?head_sha={commit}&per_page=50")
    runs = trusted_runs(listing.get("workflow_runs", []) if isinstance(listing, dict) else [])
    if not runs:
        return False, (f"{commit[:12]} has no {BRANCH} cmux-tui artifacts run to publish {tree} "
                       f"(only a {BRANCH} commit's run holds the publish credentials)")
    active = [run for run in runs if run.get("status") != "completed"]
    if active:
        return True, f"cmux-tui artifacts run {active[0].get('html_url') or active[0].get('id')} of {commit[:12]} is publishing {tree}"
    latest = max(runs, key=lambda run: int(run.get("id") or 0))
    attempt = int(latest.get("run_attempt") or 1)
    if attempt >= MAX_ATTEMPT:
        return False, (f"cmux-tui artifacts run {latest.get('html_url') or latest.get('id')} of {commit[:12]} "
                       f"already ended {attempt} times without publishing {tree} (cap {MAX_ATTEMPT})")
    status = api.post(f"repos/{repo}/actions/workflows/{REQUEST_WORKFLOW}/dispatches",
                      {"ref": BRANCH, "inputs": {"commit": commit}})
    if status != 204:
        return False, f"dispatching {REQUEST_WORKFLOW} for {commit[:12]} was refused (HTTP {status})"
    return True, (f"dispatched {REQUEST_WORKFLOW} for {commit[:12]}: it re-runs that commit's cmux-tui artifacts "
                  f"run {latest.get('html_url') or latest.get('id')} (attempt {attempt}), which builds and "
                  f"publishes {tree}; its publish starts the waiting tree jobs")


def take_over_any(api: Api, *, repo: str, commits: Iterable[str], key: str = "",
                  log: Callable[[str], None] = print) -> bool:
    """Tries each distinct commit in order until one takes the publish over."""
    seen: set[str] = set()
    for commit in commits:
        if commit in seen:
            continue
        seen.add(commit)
        try:
            taken, why = take_over(api, repo=repo, commit=commit, key=key)
        except (RuntimeError, OSError, ValueError) as error:
            log(f"::warning::could not take over the publish from {commit[:12]}: {error}")
            continue
        log(why)
        if taken:
            return True
    return False


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo", required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--key", default="")
    args = parser.parse_args(argv)
    token = os.environ.get("GH_TOKEN", "")
    if not token:
        print("::warning::no GH_TOKEN; cannot take over the tree publish")
        return 1
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from cmux_next_tree_notify import GitHub  # noqa: E402

    api = GitHub(token, os.environ.get("GITHUB_API_URL", "https://api.github.com"))
    return 0 if take_over_any(api, repo=args.repo, commits=[args.commit], key=args.key) else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
