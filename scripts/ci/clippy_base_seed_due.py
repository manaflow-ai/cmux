#!/usr/bin/env python3
"""Decide whether cmux-tui-clippy-seed.yml builds the base's clippy target now.

    clippy_base_seed_due.py --minutes 120 --commits "$COMMITS_JSON"
    clippy_base_seed_due.py --minutes 120 --commits '[]' --pointer-time 2026-11-27T10:00:00Z --now 2026-11-27T11:00:00Z  # tests

Prints `due=true` or `due=false` on stdout and why on stderr. Due when the newest workspace delta (the public `latest/`
pointer of scripts/ci/r2-cache.sh, Last-Modified) is missing, unreadable or older than --minutes, or when this push
changed a cargo key input (a Cargo.lock, the toolchain pin or .cargo/config.toml), so the dependency entry for the
new inputs exists before the clippy-changed steps that restore it need it. An unreadable pointer is due: a seed costs
one clippy run on the post-merge batch, a stale seed costs every cold clippy-changed step its workspace.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timedelta, timezone
from email.utils import parsedate_to_datetime
import json
import re
import sys
import urllib.error
import urllib.request

PUBLIC_URL = "https://ci-cache-next.cmux.com"
POINTER = "v1/Linux-X64/latest/cmux-tui-clippy-seed-ws-v1-"
KEY_INPUT = re.compile(r"^(?:cmux-tui/(?:.+/)?Cargo\.lock|cmux-tui/rust-toolchain\.toml|\.cargo/config\.toml)$")


def read_pointer_time(timeout: int = 15) -> datetime | None:
    request = urllib.request.Request(f"{PUBLIC_URL}/{POINTER}", method="HEAD")
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            value = response.headers.get("Last-Modified")
    except (urllib.error.URLError, TimeoutError, OSError):
        return None
    return parsedate_to_datetime(value).astimezone(timezone.utc) if value else None


def changed_inputs(commits: list[dict]) -> list[str]:
    paths = {p for c in commits for field in ("added", "modified", "removed") for p in (c.get(field) or [])}
    return sorted(p for p in paths if KEY_INPUT.match(p))


def decide(when: datetime | None, commits: list[dict], now: datetime, minutes: int) -> tuple[bool, str]:
    inputs = changed_inputs(commits)
    if inputs:
        return True, f"this push changed a cargo key input: {', '.join(inputs)}"
    if when is None:
        return True, "no readable workspace delta"
    age = now - when
    if age >= timedelta(minutes=minutes):
        return True, f"the newest workspace delta is {int(age.total_seconds() // 60)} min old"
    return False, f"the newest workspace delta is under {minutes} min old"


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--minutes", type=int, required=True)
    parser.add_argument("--commits", default="[]", help="the push event's commits (toJSON(github.event.commits))")
    parser.add_argument("--now", help="ISO time; defaults to the current time")
    parser.add_argument("--pointer-time", help="ISO time (or `none`) instead of reading the bucket")
    args = parser.parse_args(argv)
    try:
        commits = json.loads(args.commits or "[]") or []
    except json.JSONDecodeError:
        commits = []
    now = datetime.fromisoformat(args.now.replace("Z", "+00:00")) if args.now else datetime.now(timezone.utc)
    if args.pointer_time:
        when = None if args.pointer_time == "none" else datetime.fromisoformat(args.pointer_time.replace("Z", "+00:00"))
    else:
        when = read_pointer_time()
    due, why = decide(when, commits, now, args.minutes)
    print(f"due={'true' if due else 'false'}")
    print(f"why={why}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
