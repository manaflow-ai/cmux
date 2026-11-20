#!/usr/bin/env python3
"""The longest silent gap of each step in GitHub Actions job logs, and the step_watchdog.py limit it gives.

Each line of a job log starts with its time (`2026-11-20T11:59:19.0833643Z ...`) and each `run:` step starts with a
`##[group]Run ...` line. A step's silent gap is the longest time between two of its lines; its watchdog limit
(step_watchdog.py --silent-seconds) is the longest gap over the logs read, times --factor (2), rounded up to a minute,
and at least --floor seconds.

    python3 scripts/ci/step_silence_gaps.py job-1.log job-2.log ...          # one table over every log
    python3 scripts/ci/step_silence_gaps.py --json job-*.log

A log the watchdog would have ended (a cancelled job) belongs in the run of interest, not in the sizing: size from
green runs.
"""

from __future__ import annotations

import argparse
import json
import math
import re
import sys
from datetime import datetime
from pathlib import Path
from typing import Iterable, Optional

STAMP = re.compile(r"^(?:\ufeff)?(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(?:\.(\d+))?Z ?(.*)$")
STEP_START = re.compile(r"^##\[group\]Run (.*)$")
# The runner's own lines after the last step: not part of any step's silence.
JOB_END = ("Post job cleanup.", "Cleaning up orphan processes")


def stamp_seconds(date: str, fraction: Optional[str]) -> float:
    value = datetime.strptime(date, "%Y-%m-%dT%H:%M:%S").timestamp()
    if fraction:
        value += float("0." + fraction)
    return value


def steps(lines: Iterable[str]) -> list[dict]:
    """[{name, start, end, lines, gap, gap_after}] in log order; name is the step's first `Run` line."""
    found: list[dict] = []
    current: Optional[dict] = None
    last: Optional[float] = None
    for raw in lines:
        match = STAMP.match(raw.rstrip("\n"))
        if not match:
            continue
        at = stamp_seconds(match.group(1), match.group(2))
        text = match.group(3)
        start = STEP_START.match(text)
        if start or text.startswith(JOB_END):
            if current:
                found.append(current)
            current = None
            if start:
                current = {"name": start.group(1).strip()[:120], "start": at, "end": at, "lines": 0, "gap": 0.0,
                           "gap_after": ""}
                last = at
            continue
        if current is None:
            continue
        gap = at - (last if last is not None else at)
        if gap > current["gap"]:
            current["gap"] = gap
            current["gap_after"] = text[:160]
        current["end"] = at
        current["lines"] += 1
        last = at
    if current:
        found.append(current)
    return found


def limit(gap: float, factor: float, floor: float) -> int:
    return max(int(floor), int(math.ceil(gap * factor / 60.0)) * 60)


def merge(per_log: list[list[dict]]) -> dict[str, dict]:
    """The steps of several logs of one job, by name: the longest gap and duration seen, and how many logs."""
    merged: dict[str, dict] = {}
    for found in per_log:
        for step in found:
            row = merged.setdefault(step["name"], {"name": step["name"], "logs": 0, "gap": 0.0, "gap_after": "",
                                                   "longest": 0.0})
            row["logs"] += 1
            row["longest"] = max(row["longest"], step["end"] - step["start"])
            if step["gap"] >= row["gap"]:
                row["gap"], row["gap_after"] = step["gap"], step["gap_after"]
    return merged


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n", 1)[0])
    parser.add_argument("logs", nargs="+", type=Path)
    parser.add_argument("--factor", type=float, default=2.0)
    parser.add_argument("--floor", type=float, default=120.0, help="the smallest limit suggested (seconds)")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)
    per_log = [steps(path.read_text(encoding="utf-8", errors="replace").splitlines()) for path in args.logs]
    rows = sorted(merge(per_log).values(), key=lambda row: -row["longest"])
    for row in rows:
        row["limit"] = limit(row["gap"], args.factor, args.floor)
    if args.json:
        json.dump(rows, sys.stdout, indent=1)
        print()
        return 0
    print(f"{'longest s':>9} {'gap s':>7} {'limit s':>7} {'logs':>4}  step  (line after the gap)")
    for row in rows:
        print(f"{row['longest']:9.0f} {row['gap']:7.0f} {row['limit']:7d} {row['logs']:4d}  {row['name']}"
              f"  ({row['gap_after'][:80]})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
