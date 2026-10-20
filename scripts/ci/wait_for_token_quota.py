#!/usr/bin/env python3
"""Sleep until the job token's REST quota resets, then return.

The nightly attests its SSH daemon assets from a small Linux job. Persisting
an attestation is a REST call made with the run's installation token, and a
burst of repository CI can use up that token's hourly quota: nightly-next run
39368582348 lost a 17-minute build to "API rate limit exceeded for
installation". After a failed attempt the job runs this, which reads
GET /rate_limit (free: it does not count against the quota) and sleeps until
the core quota resets, at least FLOOR seconds (a secondary rate limit clears
within a minute or so) and at most CAP seconds. It never fails the job: an
unreadable quota sleeps FLOOR * 2.

Usage: wait_for_token_quota.py [--floor 60] [--cap 3660]   (GH_TOKEN, GITHUB_API_URL)
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.request

MARGIN = 10


def wait_seconds(rate: dict | None, now: float, floor: int, cap: int) -> int:
    """How long to sleep for a /rate_limit answer read at `now`."""
    if not rate:
        return min(cap, floor * 2)
    core = rate.get("resources", {}).get("core", {})
    reset = core.get("reset")
    remaining = core.get("remaining")
    if not isinstance(reset, (int, float)):
        return min(cap, floor * 2)
    if isinstance(remaining, int) and remaining > 0:
        # Quota left: the failure was a secondary limit or a transient error.
        return min(cap, floor)
    return int(min(cap, max(floor, reset - now + MARGIN)))


def read_rate_limit() -> dict | None:
    url = os.environ.get("GITHUB_API_URL", "https://api.github.com").rstrip("/") + "/rate_limit"
    request = urllib.request.Request(url, headers={
        "Accept": "application/vnd.github+json",
        "Authorization": f"Bearer {os.environ.get('GH_TOKEN', '')}",
        "X-GitHub-Api-Version": "2022-11-28",
    })
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)
    except Exception as error:  # noqa: BLE001 - any failure means "wait the fallback"
        print(f"could not read the token's rate limit: {error}", file=sys.stderr)
        return None


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--floor", type=int, default=60)
    parser.add_argument("--cap", type=int, default=3660)
    args = parser.parse_args(argv)
    rate = read_rate_limit()
    core = (rate or {}).get("resources", {}).get("core", {})
    seconds = wait_seconds(rate, time.time(), args.floor, args.cap)
    print(f"token quota: remaining={core.get('remaining')} reset={core.get('reset')}; waiting {seconds} s before the next attempt")
    time.sleep(seconds)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
