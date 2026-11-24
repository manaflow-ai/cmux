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
  cap          it has failed MAX_ATTEMPTS times: no more automatic re-runs. The request fails and names the run, so a
               person reads why it fails instead of a fourth attempt rebuilding it.

Usage: cmux_tui_tree_request_rerun.py --attempt N --conclusion C   (prints full, failed-jobs or cap)
"""

from __future__ import annotations

import argparse
import sys

MAX_ATTEMPTS = 3
STOPPED = {"failure", "cancelled", "timed_out", "startup_failure"}


def decide(attempt: int, conclusion: str) -> str:
    if conclusion in STOPPED:
        return "cap" if attempt >= MAX_ATTEMPTS else "failed-jobs"
    return "full"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--attempt", type=int, required=True)
    parser.add_argument("--conclusion", required=True)
    args = parser.parse_args(argv)
    print(decide(args.attempt, args.conclusion.strip().lower()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
