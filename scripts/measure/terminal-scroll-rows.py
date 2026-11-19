#!/usr/bin/env python3
"""Terminal scroll rows (goal terminal-scroll-integrity) from `cmux-tui __scroll-probe --json` reports.

    terminal-scroll-rows.py [REPORTS]

REPORTS (or stdin when it is left out or `-`) holds the probe's JSON reports, one per line; blank lines are
skipped. Prints one `PERF_ROW {...}` line per row, then the rows as one JSON object (`{"rows": [...]}`) on a
line of its own. Rows, per surface (the report's `surface`: local, ssh, cloud):
  terminal.scroll.<surface>.<view>.{blank_rows,missing_rows,jumps}  (view: mirror, daemon)
  terminal.scroll.<surface>.bad  (their sum)
Counts, lower is better, target 0. With several reports for a surface each row is the worst (p95) and the
median (p50). Used by terminal-scroll-stress-linux.sh and the Cloud journey (scripts/cmux-next/cloud-journey.ts).
"""
import json
import sys

source = open(sys.argv[1]) if len(sys.argv) > 1 and sys.argv[1] != "-" else sys.stdin
reports = [json.loads(line) for line in source if line.strip()]
by = {}
for r in reports:
    s = r["surface"]
    for view in ("mirror", "daemon"):
        for key in ("blank_rows", "missing_rows", "jumps"):
            by.setdefault(f"terminal.scroll.{s}.{view}.{key}", []).append(r["views"][view][key])
    by.setdefault(f"terminal.scroll.{s}.bad", []).append(r["bad"])
rows = []
for name, values in by.items():
    ordered = sorted(values)
    # Integer counts: a regression is one more blank, missing or jumped row (floor 0.5).
    rows.append({"name": name, "p50": ordered[len(ordered) // 2], "p95": ordered[-1], "unit": "rows",
                 "target": 0, "floor": 0.5, "runs": len(values)})
for row in rows:
    print("PERF_ROW " + json.dumps(row))
print(json.dumps({"rows": rows}))
