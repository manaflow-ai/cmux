#!/usr/bin/env python3
"""The perf cron's cef-resize part (split-spring-terminal.py --suite=cef-resize): late frames and the frame's commit
time while panes and the window resize beside a Chromium page, as perf-cron rows.

Leo, 2026-11-19: "a lot of this is just applying things properly and having those measurements in so that we're aware
of things". cef-resize-sync-bench.py measured a hosted page's resize wait only in hand runs, which nothing stored.

This runs cef-resize-sync-bench.py on the cron's app in the shipped mode only, `on0` (layer hosting on, the default;
`browserResize.syncDeadline` 0, the default since cmux-ad m19), its `light` bench (pane-perf-terminal.py --browser:
the top-left pane is a Chromium page) and two resize actions: `drag` (a pane divider dragged out and back, one event
per 120 Hz frame) and `window` (Window > Zoom and back, the window's own animated resize). Per layout and action it
writes report.json's `rows` (perf-cron.py's budgets kind):
- cef_resize.<action>.<layout>.missed: display frames missed during the resize (median of the rounds), budget 0:
  plans/cmux-next/cef-layer-hosting-DESIGN.md "Live resize": "Every motion frame must show the page at that frame's
  size, in the same CA transaction as the pane";
- cef_resize.<action>.<layout>.commit_p95_ms: the p95 Core Animation commit while the resize runs (it holds
  Chromium's pre-commit wait), budget half a display frame (4.17 ms at 120 Hz): the same design doc caps a page's
  resize wait there (CEFResizeSyncDeadline), since cmux's own frame work keeps the rest of the frame.
A layout and action the bench left no number for gets no row, and the report is incomplete.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
MODE = "on0"
BENCH = "light"
ACTIONS = "drag,window"
DEFAULT_REFRESH_MS = 1000 / 120  # the cron's virtual display (perf-cron.py VDISPLAY_HZ)
COMMIT_FLOOR_MS = 0.5
MISSED_FLOOR = 0.5  # perf-cron.py COUNT_FLOOR: one whole frame regresses


def rows_from(summary: dict) -> list[dict]:
    """perf-cron rows from cef-resize-sync-bench.py's summary.json (pure)."""
    result = ((summary.get("modes") or {}).get(MODE) or {}).get(BENCH) or {}
    rows = []
    for r in result.get("rows") if isinstance(result.get("rows"), list) else []:
        layout, action = r.get("layout"), r.get("action")
        if not layout or not action:
            continue
        refresh = r.get("refresh_ms") if isinstance(r.get("refresh_ms"), (int, float)) and 2 <= r["refresh_ms"] <= 50 \
            else None
        prefix = f"cef_resize.{action}.{layout}"
        if isinstance(r.get("missed"), (int, float)):
            rows.append({"name": f"{prefix}.missed", "p50": r["missed"], "p95": r["missed"], "unit": "frames",
                         "budget": 0, "floor": MISSED_FLOOR, "refresh_ms": refresh})
        if isinstance(r.get("commit_p95_ms"), (int, float)):
            budget = round((refresh or DEFAULT_REFRESH_MS) / 2, 2)
            rows.append({"name": f"{prefix}.commit_p95_ms", "p50": r["commit_p95_ms"], "p95": r["commit_p95_ms"],
                         "unit": "ms", "budget": budget, "floor": COMMIT_FLOOR_MS, "refresh_ms": refresh,
                         "commit_max_ms": r.get("commit_max_ms")})
    return rows


def missing_from(summary: dict, rows: list[dict]) -> list[str]:
    """Why the report is incomplete (pure): the mode was not valid, or the bench left no number."""
    validity = (summary.get("validity") or {}).get(MODE) or {}
    if not validity.get("ok"):
        return [f"{MODE}: not a valid layer-hosted run (cef-layer-verify.py)"]
    have = {r["name"].rsplit(".", 1)[0] for r in rows if r["name"].endswith(".missed")}
    if not have:
        return [f"{MODE} {BENCH}: the bench left no rows"]
    return [f"{a}: no rows" for a in ACTIONS.split(",") if not any(h.startswith(f"cef_resize.{a}.") for h in have)]


def bench_cmd(args: argparse.Namespace, out: str) -> list[str]:
    return [sys.executable, os.path.join(HERE, "cef-resize-sync-bench.py"), "--app", args.app, "--tag", args.tag,
            "--out", out, "--label", "cron", "--modes", MODE, "--benches", BENCH, "--actions", ACTIONS,
            "--rounds", str(args.rounds)]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app", required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--json", required=True, help="the part's report.json")
    parser.add_argument("--out", default=None, help="split-spring's artifact folder (the bench's own output goes there)")
    parser.add_argument("--rounds", type=int, default=3)
    args, _rest = parser.parse_known_args(argv)  # split-spring's own args are not this suite's
    out = os.path.join(args.out or os.path.dirname(os.path.abspath(args.json)), "cef-resize")
    os.makedirs(out, exist_ok=True)
    status = subprocess.run(bench_cmd(args, out), cwd=ROOT).returncode
    try:
        with open(os.path.join(out, "summary.json")) as f:
            summary = json.load(f)
    except (OSError, ValueError):
        summary = {}
    rows = rows_from(summary)
    report = {"rows": rows, "bench_status": status, "mode": MODE, "actions": ACTIONS}
    missing = missing_from(summary, rows)
    if missing:
        report["incomplete"] = missing
    with open(args.json, "w") as f:
        json.dump(report, f, indent=1)
    for r in rows:
        print(f"cef-resize: {r['name']} = {r['p95']} {r['unit']} (budget {r['budget']})")
    return status or (1 if missing else 0)


if __name__ == "__main__":
    raise SystemExit(main())
