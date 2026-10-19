#!/usr/bin/env python3
"""Decide when cmux-next-fast-tier-seed.yml seeds, and which old seeds it drops.

    gh api 'repos/R/actions/caches?ref=refs/heads/feat-cmux-next&key=cmux-next-fast-v2-' \\
      | fast-tier-seed-due.py due --minutes 30
    ... | fast-tier-seed-due.py stale --keep 2

Reads the Actions cache listing (`{"actions_caches": [...]}`) on stdin.

`due` prints `due=true` when no fast-tier entry is younger than --minutes. A
seed is a full Blacksmith macOS build (about 7 minutes), and feat-cmux-next
takes a push every few minutes, so seeding every push would cost a Mac build
per merge for a few minutes' freshness: a pull request rebuilds only what
changed since its seed (the replayed input times).

`stale` prints the ids of every fast-tier entry but the newest --keep. The
repository's Actions cache is capped at 10 GB and evicts least recently used
entries; a superseded seed is never restored again (restore-keys pick the
newest), so it only crowds out other workflows' entries until it is deleted.
Keeping the previous seed lets a restore that already chose it finish.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timedelta, timezone
import json
import sys

PREFIX = "cmux-next-fast-v2-"


def parse_time(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(timezone.utc)


def fast_tier_entries(listing: dict) -> list[dict]:
    entries = [entry for entry in listing.get("actions_caches", []) if str(entry.get("key", "")).startswith(PREFIX)]
    return sorted(entries, key=lambda entry: parse_time(entry["created_at"]), reverse=True)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    due = commands.add_parser("due")
    due.add_argument("--minutes", type=int, required=True)
    due.add_argument("--now", help="ISO time; defaults to the current time")
    stale = commands.add_parser("stale")
    stale.add_argument("--keep", type=int, required=True)
    args = parser.parse_args(argv)

    entries = fast_tier_entries(json.load(sys.stdin))
    if args.command == "due":
        now = parse_time(args.now) if args.now else datetime.now(timezone.utc)
        fresh = entries and now - parse_time(entries[0]["created_at"]) < timedelta(minutes=args.minutes)
        print(f"due={'false' if fresh else 'true'}")
    else:
        for entry in entries[args.keep:]:
            print(entry["id"])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
