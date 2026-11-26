#!/usr/bin/env python3
"""How cmux-tui-tree-request.yml re-runs a commit's completed cmux-tui artifacts run.

efficiency-scout, 2026-11-21 22:37Z: "Make re-runs go through the coalescing too, or cap automatic re-runs of these
legs." Leo, 2026-11-21 11:10Z: "we are NOT in a position to be letting inefficiencies pile up and procrastinating...
even 300 vms every fucking hour is a huge fucking luxury"

A tree request used to POST /rerun on whatever run the commit had, at any attempt. On 2026-11-21 (12-24Z, ci-dash
feed) 70 requests re-ran 26 feat-cmux-next runs in full: 27 runner-hours of musl legs alone. 20 of those attempts
failed. A failed attempt was then re-run in full again (attempts 3 and 4), rebuilding every leg that had already
passed, past the cap of 3 that cmux_tui_artifacts_retry.py and cmux_tui_tree_handoff.py keep.

  full         the run built nothing to keep: it was coalesced (base-coalesce.yml, its builds skipped) and succeeded.
               A full re-run is the only way to build its tree (attempt > 1 always runs past the coalescing).
  failed-jobs  it built and failed, was cancelled or timed out: re-run only its failed jobs. The legs that passed keep
               their artifacts, and the publish jobs re-run because they failed or were skipped.
  compile-error  it failed, and a build leg failed on a Rust compile error (cmux_tui_tree_handoff.compile_error_failure):
               a re-run builds the same source and fails on the same rustc error. 2026-11-23 and 11-24, while
               feat-cmux-next did not compile, attempts 2 and 3 rebuilt all three targets and the daemon tests for
               about 75 runner-min each and failed on the same E0599 and E0062. The request fails and names the run,
               like cap; the next push of a new key builds it, and a person can still re-run it (gh run rerun RUN).
               Read only when REPOSITORY and RUN_ID are set (cmux-tui-tree-request.yml sets them): an unreadable
               job list or log is no evidence, and the run is re-run as before.
  cap          it has failed MAX_ATTEMPTS times: no more automatic re-runs. The request fails and names the run, so a
               person reads why it fails instead of a fourth attempt rebuilding it.

Usage: [REPOSITORY=O/R RUN_ID=ID GH_TOKEN=T] cmux_tui_tree_request_rerun.py --attempt N --conclusion C
       (prints full, failed-jobs, compile-error or cap). The run is passed by environment, not flags: the request
       runs this script from the requested commit's checkout, which may predate them.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Any, Callable, Mapping, Sequence

sys.path.insert(0, str(Path(__file__).resolve().parent))
from cmux_tui_tree_handoff import compile_error_failure  # noqa: E402

MAX_ATTEMPTS = 3
STOPPED = {"failure", "cancelled", "timed_out", "startup_failure"}


def decide(attempt: int, conclusion: str) -> str:
    if conclusion in STOPPED:
        return "cap" if attempt >= MAX_ATTEMPTS else "failed-jobs"
    return "full"


def _gh_api(path: str) -> str | None:
    result = subprocess.run(["gh", "api", path], capture_output=True, text=True)
    return result.stdout if result.returncode == 0 else None


def failed_on_compile_error(repo: str, run_id: str, api: Callable[[str], str | None] = _gh_api) -> bool:
    """Whether the run's latest attempt failed a build leg on a Rust compile error (one job page, one log per failed
    build leg)."""
    page = api(f"repos/{repo}/actions/runs/{run_id}/jobs?filter=latest&per_page=100")
    try:
        jobs: Sequence[Mapping[str, Any]] = json.loads(page or "")["jobs"]
    except (ValueError, KeyError, TypeError):
        return False
    return compile_error_failure(jobs, lambda job: api(f"repos/{repo}/actions/jobs/{job['id']}/logs"))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--attempt", type=int, required=True)
    parser.add_argument("--conclusion", required=True)
    args = parser.parse_args(argv)
    how = decide(args.attempt, args.conclusion.strip().lower())
    repo, run_id = os.environ.get("REPOSITORY", ""), os.environ.get("RUN_ID", "")
    if how == "failed-jobs" and repo and run_id and failed_on_compile_error(repo, run_id):
        how = "compile-error"
    print(how)
    return 0


if __name__ == "__main__":
    sys.exit(main())
