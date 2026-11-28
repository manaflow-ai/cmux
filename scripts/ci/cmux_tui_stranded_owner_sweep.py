#!/usr/bin/env python3
"""Hand on the tree keys of owner runs whose latest attempt ended in startup_failure.

A run that defers a tree key to its owner is re-run only by that owner's hand-off (notify-unpublished-tree,
scripts/ci/cmux_tui_tree_handoff.py). An owner attempt that ends in startup_failure runs no job, so it never hands
off, and the run that deferred to it stays stranded: 2026-11-25, run 45706112297 deferred tree 37e3abb5 to owner run
45704131744, whose latest attempt ended in startup_failure, and the nightly-next tick refused every commit of that
tree.

The feat-cmux-next sweep job (cmux-tui-artifacts.yml sweep-pending-tree-notify) runs this on every feat-cmux-next
push that publishes. It reads one page of recent feat-cmux-next push runs, keeps the ones whose latest attempt ended
in startup_failure within a deferred marker's lifetime, reads each one's key from its owner marker
(cmux-tui-tree-owner-KEY or cmux-tui-tree-feat-builder-KEY, left by an earlier attempt), and runs the owner's own
hand-off for it. The hand-off re-runs one deferred run under its attempt cap and deletes that run's marker, so a later
sweep finds nothing more to do for that key.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
import re
import sys
from typing import Any, Callable, Iterable, Mapping, Sequence

sys.path.insert(0, str(Path(__file__).resolve().parent))
import cmux_tui_tree_handoff as handoff_mod  # noqa: E402

# A deferred marker is kept 1 day (retention-days: 1); an older owner has no marker left to act on.
MARKER_LIFETIME = timedelta(days=1)
# Owners handed on per sweep: each costs about 3 API reads (artifacts, jobs, deferred markers).
MAX_OWNERS = 5
OWNER_MARKER = re.compile(r"^cmux-tui-tree-(?:owner|feat-builder)-([0-9a-f]{40})$")
RUNS_PATH = ("repos/{repo}/actions/workflows/cmux-tui-artifacts.yml/runs"
             "?branch=feat-cmux-next&event=push&exclude_pull_requests=true&per_page=100")


def _created(run: Mapping[str, Any]) -> datetime | None:
    try:
        return datetime.strptime(str(run.get("created_at")), "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except ValueError:
        return None


def stranded_owners(runs: Iterable[Mapping[str, Any]], *, self_run: int, now: datetime) -> list[int]:
    """Run ids whose latest attempt completed in startup_failure within a marker's lifetime, in listing
    order (GitHub lists newest first)."""
    owners = []
    for run in runs:
        created = _created(run)
        if (run.get("status") != "completed" or run.get("conclusion") != "startup_failure"
                or not run.get("id") or int(run["id"]) == self_run
                or created is None or now - created > MARKER_LIFETIME):
            continue
        owners.append(int(run["id"]))
    return owners[:MAX_OWNERS]


def owner_keys(artifacts: Iterable[Mapping[str, Any]]) -> list[str]:
    """The tree keys a run's unexpired owner markers name, in listing order, once each."""
    keys: list[str] = []
    for artifact in artifacts:
        match = OWNER_MARKER.match(str(artifact.get("name") or ""))
        if match and not artifact.get("expired") and match.group(1) not in keys:
            keys.append(match.group(1))
    return keys


def sweep(repo: str, *, self_run: int, now: datetime,
          api: Callable[[str, str], Sequence[Mapping[str, Any]]],
          hand_off: Callable[[str, int, str], None]) -> list[str]:
    """Hand on every stranded owner's key; the reasons of the ones that could not be handed on."""
    failed: list[str] = []
    runs = api(RUNS_PATH.format(repo=repo), "workflow_runs")
    owners = stranded_owners(runs, self_run=self_run, now=now)
    if not owners:
        print("No feat-cmux-next tree owner ended in startup_failure in the last day.")
    for owner in owners:
        try:
            keys = owner_keys(api(f"repos/{repo}/actions/runs/{owner}/artifacts?per_page=100", "artifacts"))
            if not keys:
                print(f"Run {owner} ended in startup_failure and owned no tree key; nothing to hand on.")
            for key in keys:
                print(f"Run {owner} ended in startup_failure without handing tree {key} on; handing it on now.")
                hand_off(repo, owner, key)
        except handoff_mod.QuotaRefused as error:
            failed.append(f"run {owner}: API limit, no attempt before {error.retry_before}")
        except Exception as error:  # one owner's failure does not stop the next owner
            failed.append(f"run {owner}: {error}")
    return failed


def _api(path: str, key: str) -> Sequence[Mapping[str, Any]]:
    """The runs listing is one page (the newest 100 feat-cmux-next pushes span many hours), every other list is read
    whole in bounded pages; both through the hand-off's _gh, which moves to GH_TOKEN_SPARE on a rate limit."""
    if key != "workflow_runs":
        return handoff_mod._list(path, key)
    result = handoff_mod._gh("api", f"{path}&page=1")
    if result.returncode != 0:
        raise RuntimeError(f"gh api {path} failed: {result.stderr.strip()}")
    return json.loads(result.stdout).get(key, [])


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--repo", required=True)
    parser.add_argument("--run-id", required=True, type=int, help="this run, never swept")
    args = parser.parse_args(argv)
    if not os.environ.get("GH_TOKEN"):
        print("::error title=stranded tree owners not swept::the sweep needs GH_TOKEN")
        return 1
    failed = sweep(args.repo, self_run=args.run_id, now=datetime.now(timezone.utc),
                   api=_api, hand_off=handoff_mod.handoff)
    if failed:
        print("::error title=stranded tree owners not handed on::" + "; ".join(failed)
              + ". Dispatch cmux-tui-tree-request.yml with a commit of the tree, or re-run a deferred run.")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
