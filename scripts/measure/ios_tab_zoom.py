#!/usr/bin/env python3
"""The iPhone tab grid zoom bench's report (TabZoomFrameTimeUITests; workflow cmux-next-ios-tab-zoom.yml).

Leo, 2026-11-25: "the transitioning into and out of the iOS grid is still slow".

Reads the UI test's console (cmux-next-ios-sim.sh `test ui=TabZoomFrameTimeUITests`, evidence.zip's
ui-console.txt): per scene (`idle`: the demo's three tabs; `many`: 27 tabs, 25 live terminals with long
scrollback) and direction (to_grid, to_page), the zooms' frame times from the app's own display-link log
(TABZOOM_SUMMARY), the main thread inside each zoom from its tracer (TABZOOM_MAIN), and the views re-run
while it moved (TABZOOM_WORK).

  frames, duration_ms_max   display frames of a zoom and the longest zoom, tap to settled
  first_frame_ms_max        the tap to the zoom's first drawn frame (setup; one 120 Hz frame is 8.3 ms)
  worst_ms                  the longest frame interval of any zoom
  over_8_3ms, over_16_7ms   frame intervals longer than a 120 Hz and a 60 Hz frame (dropped frames)
  main_max_ms, main_busy_ms the main thread's longest run-loop iteration in a zoom, and all its
                            iterations of 4 ms or more summed (`-cmux-mobile-input-latency`)
  grid, cards               grid and card bodies re-run in a zoom: counted, so the same on any host

The work budget (`grid` at most GRID_BUDGET a zoom, `cards` at most CARD_BUDGET) is host-independent
and fails the report (exit 1), as the UI test does; frame times and main-thread numbers depend on the
host and are warnings only (exit 0), past one 120 Hz frame of setup or any 60 Hz drop.

usage: ios_tab_zoom.py --console ui-console.txt --out report.json
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

SCHEMA = "cmux-mobile-bench/tab-zoom/v1"
# TabZoomFrameTimeUITests.gridBodiesPerZoom and cardBodiesPerZoom.
GRID_BUDGET = 3
CARD_BUDGET = 54
FRAME_120_MS = 8.3
PAIR = re.compile(r"(\w+)=(\S+)")


def number(value: str) -> float | int | str:
    try:
        return int(value)
    except ValueError:
        try:
            return float(value)
        except ValueError:
            return value


def fields(line: str, tag: str) -> dict | None:
    at = line.find(tag + " ")
    if at < 0:
        return None
    return {k: number(v) for k, v in PAIR.findall(line[at + len(tag):])}


def parse(text: str) -> dict:
    summaries, main, work = [], [], []
    for line in text.splitlines():
        for tag, sink in (("TABZOOM_SUMMARY", summaries), ("TABZOOM_MAIN", main), ("TABZOOM_WORK", work)):
            row = fields(line, tag)
            if row is not None and row not in sink:
                sink.append(row)
    return {"summaries": summaries, "main": main, "work": work}


def report(parsed: dict) -> dict:
    failures, warnings = [], []
    for w in parsed["work"]:
        if w.get("grid", -1) < 0 or w["grid"] > GRID_BUDGET or w.get("cards", 0) > CARD_BUDGET:
            failures.append(f"zoom {w.get('zoom')} {w.get('direction')}: grid {w.get('grid')} (at most {GRID_BUDGET}), "
                            f"cards {w.get('cards')} (at most {CARD_BUDGET}) re-ran while it moved")
    for s in parsed["summaries"]:
        name = f"{s.get('scene', 'idle')} {s.get('direction')}"
        if s.get("first_frame_ms_max", 0) > FRAME_120_MS * 2:
            warnings.append(f"{name}: tap to first frame {s['first_frame_ms_max']} ms (one 120 Hz frame is {FRAME_120_MS})")
        if s.get("over_16_7ms", 0) > 0:
            warnings.append(f"{name}: {s['over_16_7ms']} frames over 16.7 ms")
    lines = ["| scene | direction | zooms | first frame ms (max) | worst frame ms | over 8.3 ms | over 16.7 ms | longest zoom ms |",
             "|---|---|---|---|---|---|---|---|"]
    for s in parsed["summaries"]:
        lines.append(f"| {s.get('scene', 'idle')} | {s.get('direction')} | {s.get('zooms')} | {s.get('first_frame_ms_max')} | "
                     f"{s.get('worst_ms')} | {s.get('over_8_3ms')} | {s.get('over_16_7ms')} | {s.get('duration_ms_max', '-')} |")
    if parsed["main"]:
        busiest = max(parsed["main"], key=lambda m: m.get("main_max_ms", 0))
        lines.append("")
        lines.append(f"Main thread in a zoom (many): longest iteration {busiest.get('main_max_ms')} ms, "
                     f"busy {max(m.get('main_busy_ms', 0) for m in parsed['main'])} ms at most.")
    if parsed["work"]:
        lines.append(f"Views re-run in a zoom: grid {max(w.get('grid', 0) for w in parsed['work'])} at most "
                     f"(budget {GRID_BUDGET}), cards {max(w.get('cards', 0) for w in parsed['work'])} (budget {CARD_BUDGET}).")
    return {"schema": SCHEMA, **parsed, "failures": failures, "warnings": warnings, "table_md": "\n".join(lines) + "\n"}


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    ap.add_argument("--console", required=True, type=Path, help="the UI run's console (ui-console.txt)")
    ap.add_argument("--out", required=True, type=Path)
    args = ap.parse_args(argv)
    text = args.console.read_text(errors="replace") if args.console.exists() else ""
    out = report(parse(text))
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(out, indent=2) + "\n")
    print(out["table_md"])
    for w in out["warnings"]:
        print(f"warning: {w}")
    if not out["summaries"]:
        print("ios_tab_zoom.py: no TABZOOM_SUMMARY lines in the console", file=sys.stderr)
        return 1
    for f in out["failures"]:
        print(f"failure: {f}", file=sys.stderr)
    return 1 if out["failures"] else 0


if __name__ == "__main__":
    sys.exit(main())
