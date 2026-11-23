#!/usr/bin/env python3
"""The perf cron's cef-resize part (split-spring-terminal.py --suite=cef-resize): late frames and the frame's commit
time while panes and the window resize beside a Chromium page, as perf-cron rows.

Leo, 2026-11-19: "a lot of this is just applying things properly and having those measurements in so that we're aware
of things". cef-resize-sync-bench.py measured a hosted page's resize wait only in hand runs, which nothing stored.

This runs that bench's `light` command on the cron's app: pane-perf-terminal.py --browser (the top-left pane is a
Chromium page), layouts 1x2 and 4x2, actions `drag` (a pane divider dragged out and back, one event per 120 Hz frame)
and `window` (Window > Zoom and back, the window's own animated resize). It runs the build as it ships: layer hosting
on and every resize deadline 0 (CEFLayerHosting's defaults; the browserResize.layerHosting and .syncDeadline tunables
that cef-resize-sync-bench.py's modes set are gone, and the app refuses them as unknown keys). Per layout and action it
writes report.json's `rows` (perf-cron.py's budgets kind):
- cef_resize.<action>.<layout>.missed: display frames missed during the resize (median of the rounds), budget 0:
  plans/cmux-next/cef-layer-hosting-DESIGN.md "Live resize": "Every motion frame must show the page at that frame's
  size, in the same CA transaction as the pane";
- cef_resize.<action>.<layout>.commit_p95_ms: the p95 Core Animation commit while the resize runs (it holds
  Chromium's pre-commit wait), budget half a display frame (4.17 ms at 120 Hz): the same design doc caps a page's
  resize wait there (CEFResizeSyncDeadline), since cmux's own frame work keeps the rest of the frame.
A layout and action the bench left no number for gets no row, and the report is incomplete. `window` gives two rows
per layout, window-zoom and window-unzoom; 1x2 has no divider to drag, so drag runs on 4x2 only. A window that was not
key when the bench started keeps its row names, with window_inactive true on the row.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
LAYOUTS = "1x2,4x2"
ACTIONS = "drag,window"
DEFAULT_REFRESH_MS = 1000 / 120  # the cron's virtual display (perf-cron.py VDISPLAY_HZ)
COMMIT_FLOOR_MS = 0.5
MISSED_FLOOR = 0.5  # perf-cron.py COUNT_FLOOR: one whole frame regresses
# The rows the bench gives: pane-perf-terminal.py splits `window` into Zoom and its way back, and 1x2's one column has
# no vertical divider to drag ("not applicable", step 5574ba49fb74 on 2026-11-19).
EXPECTED = (("drag", "4x2"), ("window-zoom", "1x2"), ("window-unzoom", "1x2"), ("window-zoom", "4x2"),
            ("window-unzoom", "4x2"))
INACTIVE = "-inactive"  # pane-perf-terminal.py's layout suffix when the window was not key at the start


def rows_from(report: dict) -> list[dict]:
    """perf-cron rows from pane-perf-terminal.py's report.json `summary` (pure)."""
    rows = []
    for r in report.get("summary") if isinstance(report.get("summary"), list) else []:
        if not isinstance(r, dict):
            continue
        layout, action = r.get("layout"), r.get("action")
        if not isinstance(layout, str) or not isinstance(action, str) or not layout or not action:
            continue
        inactive = layout.endswith(INACTIVE)
        layout = layout[:-len(INACTIVE)] if inactive else layout  # the row keeps its name; the flag says how it ran
        refresh = r.get("refresh_ms") if isinstance(r.get("refresh_ms"), (int, float)) and 2 <= r["refresh_ms"] <= 50 \
            else None
        prefix = f"cef_resize.{action}.{layout}"
        if isinstance(r.get("missed"), (int, float)):
            rows.append({"name": f"{prefix}.missed", "p50": r["missed"], "p95": r["missed"], "unit": "frames",
                         "budget": 0, "floor": MISSED_FLOOR, "refresh_ms": refresh,
                         "window_inactive": inactive})
        if isinstance(r.get("commit_p95_ms"), (int, float)):
            budget = round((refresh or DEFAULT_REFRESH_MS) / 2, 2)
            rows.append({"name": f"{prefix}.commit_p95_ms", "p50": r["commit_p95_ms"], "p95": r["commit_p95_ms"],
                         "unit": "ms", "budget": budget, "floor": COMMIT_FLOOR_MS, "refresh_ms": refresh,
                         "commit_max_ms": r.get("commit_max_ms"), "window_inactive": inactive})
    return rows


def missing_from(rows: list[dict]) -> list[str]:
    """Why the report is incomplete (pure): a layout and action the bench gives with no rows."""
    have = {r["name"].rsplit(".", 1)[0] for r in rows if r["name"].endswith(".missed")}
    return [f"{a} {lay}: no rows" for a, lay in EXPECTED if f"cef_resize.{a}.{lay}" not in have]


def bench_cmd(args: argparse.Namespace, out: str) -> list[str]:
    """cef-resize-sync-bench.py's `light` command (pure)."""
    return [sys.executable, os.path.join(HERE, "pane-perf-terminal.py"), "--app", args.app, "--tag", args.tag,
            "--out", out, "--actions", ACTIONS, "--rounds", str(args.rounds), "--json", os.path.join(out, "report.json"),
            "--browser", "--layouts", LAYOUTS]


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
        with open(os.path.join(out, "report.json")) as f:
            bench = json.load(f)
    except (OSError, ValueError):
        bench = {}
    rows = rows_from(bench)
    report = {"rows": rows, "bench_status": status, "layouts": LAYOUTS, "actions": ACTIONS,
              "summary": bench.get("summary"), "macos": bench.get("macos"), "host": bench.get("host")}
    missing = missing_from(rows)
    if missing:
        report["incomplete"] = missing
    with open(args.json, "w") as f:
        json.dump(report, f, indent=1)
    for r in rows:
        print(f"cef-resize: {r['name']} = {r['p95']} {r['unit']} (budget {r['budget']})")
    # pane-perf-terminal.py exits 1 when any round missed a frame; the rows carry that judgment, and the cron fetches
    # report.json only from a step that exits 0. A part with rows missing fails.
    return 1 if missing else 0


if __name__ == "__main__":
    raise SystemExit(main())
