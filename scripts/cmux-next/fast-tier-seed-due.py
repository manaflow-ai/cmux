#!/usr/bin/env python3
"""Decide whether cmux-next-fast-tier-seed.yml seeds the fast-tier R2 cache now.

    fast-tier-seed-due.py --minutes 30 --endpoint-url URL --bucket cmux-ci-cache-next
    fast-tier-seed-due.py --minutes 30 --listing objects.json   # tests
    fast-tier-seed-due.py --minutes 30 ... --pools '[{"pool": "blacksmith", "workspace": "/Users/runner/_work/cmux/cmux", ...}]'

Prints `due=true` when no fast-tier Swift archive in the bucket is younger than
--minutes. A seed is a full Blacksmith macOS build (about 7 minutes), and
feat-cmux-next takes a push every few minutes, so seeding every push would cost
a Mac build per merge for a few minutes' freshness: a pull request rebuilds only
what changed since its seed (the replayed input times). An unreadable bucket is
due: a seed costs a build, a skipped one costs every pull request one.

With --pools it prints `pools=<JSON>`: the pools whose own newest seed is that old,
each entry as given (the seed job's matrix). A pool's seeds are the swift archives
whose key holds the workspace-path hash fast-tier-cache-key.sh puts in the prefix
(sha256 of the path, 12 hex digits): a fast tier that checks out to another path
never restores the pool's seed, so each pool is due on its own seeds.

The listing (bucket credentials: AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY) is
r2_cache_census.py's, objects as {"key", "last_modified"}.
"""
from __future__ import annotations

import argparse
import hashlib
from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
import re
import sys

# The swift archive is saved last in a seed, so its time is the seed's.
SEED_ARCHIVE = re.compile(r"^v1/[^/]+/objects/cmux-next-fast-v3-swift-[A-Za-z0-9._-]+\.tar\.(?:zst|gz)$")


def parse_time(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(timezone.utc)


def place(workspace: str) -> str:
    """fast-tier-cache-key.sh's `place`: the workspace path's sha256, 12 hex digits."""
    return hashlib.sha256(workspace.encode("utf-8")).hexdigest()[:12]


def due(objects: list[dict], now: datetime, minutes: int, workspace: str | None = None) -> bool:
    marker = f"-{place(workspace)}-" if workspace else ""
    times = [parse_time(item["last_modified"]) for item in objects
             if SEED_ARCHIVE.match(item.get("key", "")) and marker in item.get("key", "") and item.get("last_modified")]
    return not times or now - max(times) >= timedelta(minutes=minutes)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--minutes", type=int, required=True)
    parser.add_argument("--now", help="ISO time; defaults to the current time")
    parser.add_argument("--listing", help="a JSON object list instead of listing the bucket")
    parser.add_argument("--endpoint-url")
    parser.add_argument("--bucket")
    parser.add_argument("--pools", help="JSON list of {pool, runner, workspace, ...}; prints the due ones")
    args = parser.parse_args(argv)

    if args.listing:
        objects = json.loads(Path(args.listing).read_text(encoding="utf-8"))
    else:
        sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "ci"))
        import r2_cache_census as census  # noqa: E402

        try:
            objects, _ = census.collect(args.endpoint_url, args.bucket)
        except Exception as error:  # noqa: BLE001 - any listing failure seeds
            print(f"could not list {args.bucket} ({error}); seeding", file=sys.stderr)
            objects = []
    now = parse_time(args.now) if args.now else datetime.now(timezone.utc)
    if args.pools:
        pools = json.loads(args.pools)
        print("pools=" + json.dumps([p for p in pools if due(objects, now, args.minutes, p["workspace"])],
                                    separators=(",", ":")))
        return 0
    print(f"due={'true' if due(objects, now, args.minutes) else 'false'}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
