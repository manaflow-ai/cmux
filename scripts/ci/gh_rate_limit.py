#!/usr/bin/env python3
"""Say when GitHub's API quota resets, so gh-merge-green refuses a rate-limited merge at once.

    gh_rate_limit.py [--after-limit] one line: each pool's remaining calls and reset time
                                     (--after-limit: a read was just refused, so a pool with
                                     calls left means GitHub's secondary limit)
    gh_rate_limit.py --exhausted P   print `spent` when pool P (core, graphql) has no calls left

`gh api rate_limit` costs no quota, so it still answers when both pools are spent.
On 2026-10-20 a rate-limited GraphQL read fell back to REST, which was spent too,
and gh-merge-green refused only after about 30 minutes, with no reset time.
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import time
from typing import Callable

# The same phrases gh-merge-green's graphql_quota_error matches: GitHub's primary and
# secondary limits, from GraphQL or REST. "remaining=0" alone is not one.
QUOTA = re.compile(
    r"(^|[^0-9A-Za-z])(api\s+rate\s+limit\s+(already\s+)?exceeded|secondary\s+rate\s+limit|rate\s+limit\s+exceeded"
    r"|graphql[^\x00-\x1f]*(api\s+rate\s+limit|secondary\s+rate\s+limit|quota))([^0-9A-Za-z]|$)",
    re.IGNORECASE)
POOLS = ("graphql", "core")


class RateLimited(RuntimeError):
    """A GitHub read hit the API rate limit; the message says when it resets."""


def is_rate_limited(text: str) -> bool:
    return bool(QUOTA.search(text or ""))


def read_limits(run: Callable[[list[str]], str] | None = None) -> dict:
    """`gh api rate_limit`'s resources, or {} when it cannot be read."""
    if run is None:
        def run(args: list[str]) -> str:
            out = subprocess.run(["gh", *args], capture_output=True, text=True, timeout=30)
            if out.returncode:
                raise RuntimeError(out.stderr.strip()[:200])
            return out.stdout
    try:
        resources = json.loads(run(["api", "rate_limit"])).get("resources")
    except Exception:
        return {}
    return resources if isinstance(resources, dict) else {}


def exhausted(limits: dict, pool: str, now: float | None = None) -> bool:
    entry = limits.get(pool) or {}
    remaining, reset = entry.get("remaining"), entry.get("reset")
    if not isinstance(remaining, int) or not isinstance(reset, (int, float)):
        return False
    return remaining <= 0 and reset > (time.time() if now is None else now)


def describe(limits: dict, now: float | None = None, after_limit: bool = False) -> str:
    """`graphql 0 of 5000 left, resets 09:12:00Z (in 14m); core ...`; a secondary limit has no reset time."""
    now = time.time() if now is None else now
    parts = []
    for pool in POOLS:
        entry = limits.get(pool) or {}
        remaining, limit, reset = entry.get("remaining"), entry.get("limit"), entry.get("reset")
        if not isinstance(remaining, int) or not isinstance(reset, (int, float)):
            continue
        wait = max(0, int(reset - now))
        when = time.strftime("%H:%M:%SZ", time.gmtime(reset))
        parts.append(f"{pool} {remaining} of {limit} left, resets {when} (in {wait // 60}m{wait % 60:02d}s)")
    if not parts:
        return "the reset time is unknown (gh api rate_limit could not be read)"
    text = "; ".join(parts)
    if after_limit and not any(exhausted(limits, pool, now) for pool in POOLS):
        text += ("; neither pool is spent, so this is GitHub's secondary (abuse) limit, which gives no reset "
                 "time: retry in a few minutes")
    return text


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--exhausted", choices=POOLS, help="print `spent` when this pool has no calls left")
    parser.add_argument("--after-limit", action="store_true", help="a GitHub read was just rate-limited")
    args = parser.parse_args(argv)
    limits = read_limits()
    if args.exhausted:
        # Printed, not an exit status: a python3 that fails or is stubbed out must read as "not spent".
        if exhausted(limits, args.exhausted):
            print("spent")
        return 0
    print(describe(limits, after_limit=args.after_limit))
    return 0


if __name__ == "__main__":
    sys.exit(main())
