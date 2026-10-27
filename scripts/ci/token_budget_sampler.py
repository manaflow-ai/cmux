#!/usr/bin/env python3
"""Sample this job's GITHUB_TOKEN core budget (ci-token-budget-sampler.yml).

`sample` reads GET /rate_limit, which does not count against the budget,
every SAMPLE_SECONDS until --minutes have passed, and writes one CSV row per
read: the UTC time, remaining, used, limit and the bucket's reset (epoch).
The reset tells the buckets apart: GitHub keeps more than one GITHUB_TOKEN
bucket for the repository and a job's token draws on one of them.

Stop condition: the deadline (--minutes, at most MAX_MINUTES). A failed read
is logged and skipped; MAX_FAILURES failures in a row end the run, since the
endpoint is then unreachable and the series would be empty anyway.
"""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import json
import os
import sys
import time
import urllib.error
import urllib.request
from typing import Callable

API = os.environ.get("GITHUB_API_URL", "https://api.github.com").rstrip("/")
SAMPLE_SECONDS = 5
MAX_MINUTES = 120
MAX_FAILURES = 12
FIELDS = ("time", "remaining", "used", "limit", "reset")


def read_core(token: str) -> dict[str, int]:
    request = urllib.request.Request(f"{API}/rate_limit", headers={
        "Accept": "application/vnd.github+json",
        "Authorization": f"Bearer {token}",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "cmux-token-budget-sampler",
    })
    with urllib.request.urlopen(request, timeout=15) as response:
        core = json.load(response)["resources"]["core"]
    return {key: int(core[key]) for key in ("remaining", "used", "limit", "reset")}


def sample(token: str, minutes: float, out: str, *,
           read: Callable[[str], dict[str, int]] = read_core,
           now: Callable[[], float] = time.monotonic,
           wall: Callable[[], float] = time.time,
           sleep: Callable[[float], None] = time.sleep) -> int:
    # The deadline and pacing use the monotonic clock, so a clock change neither stretches nor cuts the window.
    deadline = now() + minutes * 60
    rows = failures = 0
    buckets: set[int] = set()
    with open(out, "w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=FIELDS)
        writer.writeheader()
        while now() < deadline:
            started = now()
            try:
                core = read(token)
            except (urllib.error.URLError, OSError, KeyError, ValueError) as error:
                failures += 1
                print(f"read failed ({failures} in a row): {error}", file=sys.stderr)
                if failures >= MAX_FAILURES:
                    print("token-budget: too many failed reads; stopping", file=sys.stderr)
                    break
            else:
                failures = 0
                stamp = dt.datetime.fromtimestamp(wall(), dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
                writer.writerow({"time": stamp, **core})
                handle.flush()
                rows += 1
                if core["reset"] not in buckets:
                    buckets.add(core["reset"])
                    reset = dt.datetime.fromtimestamp(core["reset"], dt.timezone.utc).strftime("%H:%M:%SZ")
                    print(f"token-budget: {stamp} bucket resets {reset}: {core['remaining']} of {core['limit']} left")
            sleep(max(0.0, min(SAMPLE_SECONDS - (now() - started), deadline - now())))
    print(f"token-budget: {rows} reads written to {out}")
    return 0 if rows else 1


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    run = sub.add_parser("sample")
    run.add_argument("--minutes", type=float, required=True)
    run.add_argument("--out", required=True)
    args = parser.parse_args(argv)
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN") or ""
    if not token:
        print("token-budget: GH_TOKEN is required", file=sys.stderr)
        return 2
    if not 0 < args.minutes <= MAX_MINUTES:
        print(f"token-budget: --minutes must be in (0, {MAX_MINUTES}]", file=sys.stderr)
        return 2
    return sample(token, args.minutes, args.out)


if __name__ == "__main__":
    raise SystemExit(main())
