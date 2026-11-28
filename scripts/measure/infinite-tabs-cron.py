#!/usr/bin/env python3
"""The perf cron's infinite-tabs part (split-spring-terminal.py --suite=infinite-tabs): the app with 500 browser tabs,
200 workspaces and 100 agent chats, all but the front workspace hibernated, against the same app empty
(scripts/cmux-next/bench_infinite_tabs.py), as perf-cron rows `infinite_tabs.mac.*` on every measured tip.

Goal infinite-tabs-flat reads infinite_tabs.mac.memory_vs_empty (cmuxterm-hq NOW's infinite_tabs_memory_vs_empty_mac,
target 1.2x). Before this part it came only from a person's cmux-ci step (scripts/measure/infinite-tabs.sh), so the row
read "hand step ... unconfirmed (one run)" and went STALE past 24 h (2026-11-28). The bench prints one PERF_ROW line
per headline; this runs it on the cron's tagged bench app and writes them as report.json `rows` (the budgets kind).

A run that built under 90 % of the tabs, workspaces or chats asked for (the bench's exit 3: an app with no Chromium
engine opens none of the tabs) measured another mix: its rows are not stored and the part fails, so the goal never
reads a ratio of a smaller app.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
BENCH = os.path.join(ROOT, "scripts", "cmux-next", "bench_infinite_tabs.py")
FAKE_AGENT = os.path.join(ROOT, "cmux-tui", "crates", "acpmux", "tests", "fake_agent.py")
GOAL_ROW = "infinite_tabs.mac.memory_vs_empty"


def rows_from(log: str) -> list[dict]:
    """The bench's PERF_ROW lines as perf-cron rows (pure): the last row of a name wins; a malformed line is skipped."""
    rows: dict[str, dict] = {}
    for line in log.splitlines():
        if not line.startswith("PERF_ROW "):
            continue
        try:
            row = json.loads(line[len("PERF_ROW "):])
        except ValueError:
            continue
        if isinstance(row, dict) and isinstance(row.get("name"), str) and isinstance(row.get("p95"), (int, float)):
            rows[row["name"]] = row
    return list(rows.values())


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app", required=True)
    parser.add_argument("--json", required=True, help="the part's report.json")
    parser.add_argument("--out", default=None, help="split-spring's artifact folder")
    args, _rest = parser.parse_known_args(argv)  # split-spring's own args are not this suite's
    out = os.path.join(args.out or os.path.dirname(os.path.abspath(args.json)), "infinite-tabs")
    os.makedirs(out, exist_ok=True)
    proc = subprocess.run([sys.executable, BENCH, "--app", args.app, "--fake-agent", FAKE_AGENT,
                           "--out", os.path.join(out, "infinite-tabs.json")], cwd=ROOT, capture_output=True, text=True,
                          env={**os.environ, "CMUX_BENCH_LAUNCH": "direct"})
    log = proc.stdout + proc.stderr
    with open(os.path.join(out, "infinite-tabs.log"), "w") as f:
        f.write(log)
    sys.stdout.write(log[-4000:])
    rows = rows_from(log)
    names = {r["name"] for r in rows}
    report: dict = {"rows": rows if proc.returncode == 0 else [], "bench_status": proc.returncode}
    if proc.returncode != 0:
        report["incomplete"] = [f"the bench exited {proc.returncode}" + (" (built under 90 % of the tabs, workspaces or "
                                "chats asked for: another mix, not stored)" if proc.returncode == 3 else "")]
    elif GOAL_ROW not in names:
        report["incomplete"] = [f"no {GOAL_ROW} row"]
    with open(args.json, "w") as f:
        json.dump(report, f, indent=1)
    for r in report["rows"]:
        print(f"infinite-tabs: {r['name']} = {r['p95']} {r['unit']}")
    return 0 if report["rows"] and GOAL_ROW in names else 1


if __name__ == "__main__":
    raise SystemExit(main())
