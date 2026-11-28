#!/usr/bin/env python3
"""Has the degenerate lab already run tonight? `done_today.py KEY` reads stdin: the GitHub artifacts
list (`GET /repos/OWNER/REPO/actions/artifacts?name=KEY`) and prints `true` when an unexpired artifact
named KEY came from a nightly-next run, else `false`.

The day marker used to live only in the Actions cache. The cmux repo's cache sits at its 10 GB cap
(per-commit Rust caches turn it over within hours), so the marker was evicted within the hour and the
whole ~2 h-per-job matrix ran again on the next push the same day: 3 full nightly runs on 2026-11-28
(46105117340, 46116717122, 46128617287), about 1.3k runner-min each. An artifact is kept for its
retention period, not on a cache's LRU, so the marker holds for the day.
"""
from __future__ import annotations

import json
import sys


def done(listing: dict, key: str, branch: str = "nightly-next") -> bool:
    for a in listing.get("artifacts") or []:
        if a.get("name") != key or a.get("expired"):
            continue
        if (a.get("workflow_run") or {}).get("head_branch") == branch:
            return True
    return False


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: done_today.py KEY < artifacts.json", file=sys.stderr)
        return 2
    try:
        listing = json.load(sys.stdin)
    except ValueError:
        listing = {}
    print("true" if done(listing, sys.argv[1]) else "false")
    return 0


if __name__ == "__main__":
    sys.exit(main())
