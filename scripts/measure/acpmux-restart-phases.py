#!/usr/bin/env python3
"""Reads the `acpmux-restart-phases:` lines of scripts/measure/acpmux-restart-phases.sh (path argument)
and prints a markdown table: median [min-max] ms from the daemon's spawn, one row per hosted/idle case."""
import json
import statistics
import sys


def cells(rows, pick):
    values = [v for v in (pick(r) for r in rows) if v is not None]
    if not values:
        return "-"
    return f"{statistics.median(values):.0f} [{min(values):.0f}-{max(values):.0f}]"


def main(path):
    cases = {}
    for line in open(path):
        if line.startswith("acpmux-restart-phases: "):
            row = json.loads(line.split(": ", 1)[1])
            cases.setdefault((row["hosted"], row["idle"]), []).append(row)
    print("| hosted | idle | n | ready line | status | live attach | idle attach | adoption done | startup done |")
    print("|---|---|---|---|---|---|---|---|---|")
    for (hosted, idle), rows in sorted(cases.items()):
        print(
            f"| {hosted} | {idle} | {len(rows)} | {cells(rows, lambda r: r['ready_line_ms'])} | "
            f"{cells(rows, lambda r: r['status_ms'])} | "
            f"{cells(rows, lambda r: (r['hosted_attach'] or {}).get('ms'))} | "
            f"{cells(rows, lambda r: (r['idle_attach'] or {}).get('ms'))} | "
            f"{cells(rows, lambda r: r['adopted_ms'])} | {cells(rows, lambda r: r['startup_ms'])} |"
        )


main(sys.argv[1])
