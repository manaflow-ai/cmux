#!/usr/bin/env python3
"""Reads the app's always-on transition frame log (TransitionFrameLog.swift, goal instant-splits) and prints, per
transition, the count and the p50 / p95 / max of `ms` (the input event to the end of the first Core Animation commit
that carries the change).

    python3 scripts/cmux-next/frame_timing.py                      # every app's log on this Mac
    python3 scripts/cmux-next/frame_timing.py FILE...              # given files (frame-timing.jsonl, .1)
    python3 scripts/cmux-next/frame_timing.py --transition divider_drag --last 200 --json

The log is `~/Library/Logs/cmux-next/<tag or release>/frame-timing.jsonl` (one folder per build) and its older half
`frame-timing.1.jsonl`; both are read, older first. Lines that do not parse are skipped and counted. Standard library
only (python3 scripts/cmux-next/test_frame_timing.py).
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import sys

FILE = "frame-timing.jsonl"
OLDER = "frame-timing.1.jsonl"


def pct(values, q):
    """The nearest-rank percentile `q` (0..1) of `values`, as split_scale_metrics.pct; None when empty."""
    values = sorted(values)
    if not values:
        return None
    return round(values[min(len(values) - 1, int(round((len(values) - 1) * q)))], 2)


def read_lines(lines):
    """Rows (dicts with a numeric `ms` and a `transition`) and the count of lines skipped."""
    rows, skipped = [], 0
    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except ValueError:
            skipped += 1
            continue
        ms = row.get("ms") if isinstance(row, dict) else None
        if not isinstance(row, dict) or not isinstance(row.get("transition"), str) or isinstance(ms, bool) \
                or not isinstance(ms, (int, float)) or ms < 0:
            skipped += 1
            continue
        rows.append(row)
    return rows, skipped


def summarize(rows, transition=None, last=None):
    """{transition: {count, p50_ms, p95_ms, max_ms, from_event}} over `rows` (oldest first); `last` keeps each
    transition's newest N."""
    by = {}
    for row in rows:
        if transition and row["transition"] != transition:
            continue
        by.setdefault(row["transition"], []).append(row)
    out = {}
    for name, group in sorted(by.items()):
        if last:
            group = group[-last:]
        ms = [float(r["ms"]) for r in group]
        out[name] = {"count": len(ms), "p50_ms": pct(ms, 0.5), "p95_ms": pct(ms, 0.95), "max_ms": round(max(ms), 2),
                     "from_event": sum(1 for r in group if r.get("event") is True)}
    return out


def default_files(home=None):
    """Each build's log pair on this Mac, older half first, grouped by build tag folder."""
    logs = os.path.join(home or os.path.expanduser("~"), "Library", "Logs", "cmux-next")
    groups = {}
    for path in sorted(glob.glob(os.path.join(logs, "*", FILE))):
        folder = os.path.dirname(path)
        older = os.path.join(folder, OLDER)
        groups[os.path.basename(folder)] = ([older] if os.path.exists(older) else []) + [path]
    return groups


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("files", nargs="*", help="log files (default: every app's on this Mac)")
    parser.add_argument("--transition", help="only this transition (divider_drag)")
    parser.add_argument("--last", type=int, help="each transition's newest N rows only")
    parser.add_argument("--json", action="store_true", help="print JSON")
    args = parser.parse_args(argv)
    groups = {"files": args.files} if args.files else default_files()
    if not groups:
        print(f"no {FILE} under ~/Library/Logs/cmux-next/* (no transition timed yet?)", file=sys.stderr)
        return 1
    report = {}
    for name, files in groups.items():
        lines = []
        for path in files:
            with open(path, encoding="utf-8", errors="replace") as handle:
                lines.extend(handle)
        rows, skipped = read_lines(lines)
        report[name] = {"transitions": summarize(rows, args.transition, args.last), "skipped": skipped}
    if args.json:
        print(json.dumps(report, indent=2, sort_keys=True))
        return 0
    for name, entry in report.items():
        print(f"{name}" + (f" (skipped {entry['skipped']} lines)" if entry["skipped"] else ""))
        if not entry["transitions"]:
            print("  no rows")
        for transition, s in entry["transitions"].items():
            print(f"  {transition}: count {s['count']}  p50 {s['p50_ms']} ms  p95 {s['p95_ms']} ms  max {s['max_ms']} ms"
                  f"  (from event {s['from_event']})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
