#!/usr/bin/env python3
"""Collect XCTest launch samples; a passing suite without its samples fails CI."""

import argparse
from collections import Counter
import json
import math
from pathlib import Path
import re
import sys


def read_samples(path):
    rows = []
    for line in path.read_text().splitlines():
        match = re.search(r"LAUNCHTTI (\{.*\})", line)
        if match:
            row = json.loads(match.group(1))
            if row.get("flow") not in ("chat", "terminal") or row.get("phase") not in ("warm", "cold"):
                raise ValueError(f"{path}: invalid flow or phase")
            keys = ["list_ms", "open_ms", "tti_ms"]
            if row["flow"] == "terminal":
                keys.append("echo_ms")
            for key in keys:
                value = row.get(key)
                if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value < 0:
                    raise ValueError(f"{path}: invalid {key}")
            rows.append(row)
    return rows


def collect(out):
    rows = []
    # Select one transport per result bundle. The same sample can appear in
    # both stdout and its attachment; identical samples within a run still count.
    consoles = [out / "ui-console.txt", *sorted((out / "ui-cold").glob("*-console.txt"))]
    for console in consoles:
        attachments = console.with_name(console.name.removesuffix("-console.txt") + "-attachments")
        attached = []
        for path in sorted(attachments.rglob("*.txt")):
            attached.extend(read_samples(path))
        rows.extend(attached if attached else read_samples(console) if console.exists() else [])
    return rows


def expected_counts(suites, cold_runs):
    expected = {}
    for selector in suites:
        selector = selector.removeprefix("-only-testing:CmuxMobileAppUITests/")
        suite, _, method = selector.partition("/")
        if suite not in ("LaunchTTIUITests", "LaunchTTIColdUITests"):
            continue
        phase = "cold" if suite == "LaunchTTIColdUITests" else "warm"
        for flow, test in (("chat", "testChatOpen"), ("terminal", "testTerminalInput")):
            if not method or method == test + phase.title():
                expected[(flow, phase)] = cold_runs if phase == "cold" else 10
    return expected


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("out", type=Path)
    parser.add_argument("--cold-runs", type=int, default=10)
    parser.add_argument("--suites", nargs=argparse.REMAINDER, default=[])
    args = parser.parse_args()
    try:
        rows = collect(args.out)
        (args.out / "launch-tti.jsonl").write_text("".join(json.dumps(row) + "\n" for row in rows))
        counts = Counter((row["flow"], row["phase"]) for row in rows)
        for group, expected in expected_counts(args.suites, args.cold_runs).items():
            if counts[group] != expected:
                raise ValueError(f"{group[0]} {group[1]}: expected {expected} samples, got {counts[group]}")
    except (OSError, ValueError) as error:
        message = f"launch TTI extraction failed: {error}\n"
        (args.out / "launch-tti-error.txt").write_text(message)
        print(message, file=sys.stderr, end="")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
