#!/usr/bin/env python3
"""launch-matrix.sh's summary: runs.jsonl -> one LM-TABLE line per app x scenario, and report.json.

usage: launch-matrix-summary.py RUNS_JSONL REPORT_JSON

Each LM-TABLE holds, per number, median, min, max and n over the scenario's launches that had a window (errors are
counted, not summarised): the times from the open request (proc_start, window_on_screen, first_visible_frame,
interactive) and the resources at first interactive (at_*) and after the idle settle (settled_*). frame_sources,
interactive_evidence and interactive_blockers say which numbers are fallbacks. report.json holds the tables and every run.
"""
from __future__ import annotations

import json
import statistics
import sys

TIMES = ("proc_start", "window_on_screen", "first_visible_frame", "interactive")
RESOURCES = ("procs", "threads", "rss_mb", "footprint_mb", "cpu_ms", "disk_read_mb", "pageins")
SETTLED_ONLY = ("idle_cpu_pct", "idle_wakeups_per_s")


def stats(values):
    vals = [v for v in values if isinstance(v, (int, float)) and not isinstance(v, bool)]
    if not vals:
        return None
    return {"median": round(statistics.median(vals), 1), "min": min(vals), "max": max(vals), "n": len(vals)}


def table(app: str, scenario: str, runs: list[dict]) -> dict:
    done = [r for r in runs if not r.get("error") and r.get("window_on_screen") is not None]
    row = {"app": app, "scenario": scenario, "n": len(runs), "errors": len(runs) - len(done),
           "frame_sources": sorted({r.get("frame_source", "?") for r in done}),
           "interactive_blockers": sorted({r["interactive_blocker"] for r in done if r.get("interactive_blocker")}),
           "interactive_evidence": sorted({r["interactive_evidence"] for r in done if r.get("interactive_evidence")}),
           "load_median": stats([r.get("load") for r in runs]),
           "other_instance_runs": sum(1 for r in runs if r.get("other_instance_pids")),
           "error_texts": sorted({str(r["error"])[:120] for r in runs if r.get("error")})}
    for key in TIMES:
        row[key] = stats([r.get(key) for r in done])
    for key in RESOURCES:
        row["at_" + key] = stats([(r.get("at_interactive") or {}).get(key) for r in done])
        row["settled_" + key] = stats([(r.get("settled") or {}).get(key) for r in done])
    for key in SETTLED_ONLY:
        row["settled_" + key] = stats([(r.get("settled") or {}).get(key) for r in done])
    return row


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    try:
        runs = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
    except FileNotFoundError:
        runs = []
    tables = []
    for app in dict.fromkeys(r.get("app_name", "?") for r in runs):
        for scenario in dict.fromkeys(r.get("scenario", "?") for r in runs if r.get("app_name", "?") == app):
            t = table(app, scenario, [r for r in runs if r.get("app_name", "?") == app and r.get("scenario") == scenario])
            tables.append(t)
            print("LM-TABLE", json.dumps(t, sort_keys=True), flush=True)
    with open(sys.argv[2], "w") as f:
        json.dump({"schema": "launch-matrix/v1", "tables": tables, "runs": runs}, f, indent=1, sort_keys=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
