#!/usr/bin/env python3
"""Decide whether cmux-machine-channel-cargo-seed.yml builds the thin musl pair now, so it saves the R2 cargo cache.

    machine_channel_cargo_seed_due.py --minutes 60 --commits "$COMMITS_JSON"
    machine_channel_cargo_seed_due.py --minutes 60 --commits '[]' --pointers pointers.json --now 2026-11-26T20:00:00Z  # tests

Prints `due=true` and why, or `due=false`. Due when either thin musl leg's newest workspace delta is older than
--minutes or missing (its public `latest/` pointer, scripts/ci/r2-cache.sh, Last-Modified), or when this push
changed a cargo key input (a Cargo.lock or cmux-tui/rust-toolchain.toml, the `Key the cargo build in R2` inputs), so
the dependency entry for the new inputs exists before the pull request heads built on it need it. An unreadable
pointer is due: a seed costs one build per leg, a stale cache costs every PR head build its workspace.

Why: only a feat-cmux-next build holds the cache's write credentials (the next-cache-writer environment), and the
only one that built the thin legs was cmux-machine-channel.yml's push run. That run builds only when the channel
needs the commit and no merged PR head's build is taken (PR_HEAD_FAST_LANE), and its group keeps one run waiting
(a newer push replaces it): 95 of 100 runs since 06Z on 2026-11-26 were cancelled. So the 3,362 PR head builds
a day restored a dependency entry for an older Cargo.lock (11e80282 for a 57140a46 head, run 45731579747) and no
workspace delta: 89 third-party and all 252 workspace crates compiled, 12.5 min of a 15 min job.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timedelta, timezone
from email.utils import parsedate_to_datetime
import json
from pathlib import Path
import re
import sys
import urllib.error
import urllib.request

PUBLIC_URL = "https://ci-cache-next.cmux.com"
# The namespace r2-cache.sh saves both legs under: both cross-build on x86_64 Linux pool runners.
NAMESPACE = "v1/Linux-X64"
LEGS = ("x86_64-unknown-linux-musl", "aarch64-unknown-linux-musl")
# `Key the cargo build in R2`'s inputs (cmux-tui-build-package.yml).
KEY_INPUT = re.compile(r"^(?:cmux-tui/(?:.+/)?Cargo\.lock|cmux-tui/rust-toolchain\.toml|first-party-apps/cloud/server/Cargo\.lock)$")


def pointer(leg: str) -> str:
    return f"{NAMESPACE}/latest/cmux-tui-cargo-ws-v1-{leg}-thin-"


def read_pointer_time(path: str, timeout: int = 15) -> datetime | None:
    request = urllib.request.Request(f"{PUBLIC_URL}/{path}", method="HEAD")
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            value = response.headers.get("Last-Modified")
    except (urllib.error.URLError, TimeoutError, OSError):
        return None
    return parsedate_to_datetime(value).astimezone(timezone.utc) if value else None


def changed_inputs(commits: list[dict]) -> list[str]:
    paths = {p for c in commits for field in ("added", "modified", "removed") for p in (c.get(field) or [])}
    return sorted(p for p in paths if KEY_INPUT.match(p))


def decide(times: dict[str, datetime | None], commits: list[dict], now: datetime, minutes: int) -> tuple[bool, str]:
    inputs = changed_inputs(commits)
    if inputs:
        return True, f"this push changed a cargo key input: {', '.join(inputs)}"
    for leg in LEGS:
        when = times.get(leg)
        if when is None:
            return True, f"no readable workspace delta for {leg}"
        if now - when >= timedelta(minutes=minutes):
            return True, f"{leg}'s newest workspace delta is {int((now - when).total_seconds() // 60)} min old"
    return False, f"both legs' workspace deltas are under {minutes} min old"


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--minutes", type=int, required=True)
    parser.add_argument("--commits", default="[]", help="the push event's commits (toJSON(github.event.commits))")
    parser.add_argument("--now", help="ISO time; defaults to the current time")
    parser.add_argument("--pointers", help="JSON {leg: ISO time or null} instead of reading the bucket")
    args = parser.parse_args(argv)

    try:
        commits = json.loads(args.commits or "[]") or []
    except json.JSONDecodeError:
        commits = []
    now = datetime.fromisoformat(args.now.replace("Z", "+00:00")) if args.now else datetime.now(timezone.utc)
    if args.pointers:
        raw = json.loads(Path(args.pointers).read_text(encoding="utf-8"))
        times = {leg: datetime.fromisoformat(v.replace("Z", "+00:00")) if v else None for leg, v in raw.items()}
    else:
        times = {leg: read_pointer_time(pointer(leg)) for leg in LEGS}
    due, why = decide(times, commits, now, args.minutes)
    print(f"due={'true' if due else 'false'}")
    print(f"why={why}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
