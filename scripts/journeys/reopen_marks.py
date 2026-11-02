#!/usr/bin/env python3
"""REOPEN without film: the app's own launch marks per cycle (reopen-N.json of ext_reopen's reopen_video with
film false), from main(). Not film evidence (cmux-ad 01:30Z); it says what the app believes it drew.

    reopen_marks.py DIR [DIR ...]

Per cycle: first_window_frame_committed, launch.visible_terminals_drawn (every visible terminal drew; the dogfood
line and #31621 have it), launch_terminals_frame_shown_max_ms (#31621: the max over panes of their saved frame
shown), the first pane's terminal.launch_frame_shown, whether every visible terminal's frame was up by the first
window frame, the exactness differences and the keys received. Standard library only. (Do not run
reopen_judge.py --verdict on a no-film folder: "no film" counts as FAIL there.) The app marks and
launch_terminals_frame_shown_max_ms (#31621) are ms since the process start; this subtracts main_start."""
import json
import re
import sys
from pathlib import Path


def ms(marks, name):
    main = marks.get("main_start")
    v = marks.get(name)
    return round(v - main, 1) if isinstance(v, (int, float)) and isinstance(main, (int, float)) else None


def pct(values, q):
    """Linear interpolation between ranks, as reopen_judge.py's pct."""
    v = sorted(x for x in values if x is not None)
    if not v:
        return None
    k = (len(v) - 1) * q
    lo, hi = int(k), min(int(k) + 1, len(v) - 1)
    return round(v[lo] + (v[hi] - v[lo]) * (k - lo), 1)


def main():
    rows = []
    for d in map(Path, sys.argv[1:]):
        for p in sorted(d.glob("reopen-*.json"), key=lambda p: int(re.search(r"(\d+)", p.stem).group(1))):
            r = json.loads(p.read_text())
            marks = r.get("app_marks_ms") or {}
            window = ms(marks, "first_window_frame_committed")
            drawn = ms(marks, "launch.visible_terminals_drawn")
            per_pane_max = r.get("launch_terminals_frame_shown_max_ms")
            if isinstance(per_pane_max, (int, float)) and isinstance(marks.get("main_start"), (int, float)):
                per_pane_max = round(per_pane_max - marks["main_start"], 1)
            last = per_pane_max if per_pane_max is not None else drawn
            row = {"dir": str(d), "cycle": r.get("cycle"), "film": r.get("film", True), "window_ms": window,
                   "first_pane_frame_ms": ms(marks, "terminal.launch_frame_shown"), "all_drawn_ms": drawn,
                   "per_pane_frame_max_ms": per_pane_max,
                   "all_in_first_window_frame": None if last is None or window is None else last <= window + 0.5,
                   "pre_main_ms": marks.get("main_start"), "differences": r.get("differences") or [],
                   "received": [m.get("received") for m in r.get("markers") or []]}
            rows.append(row)
            print(json.dumps(row))
    summary = {k: {"p50": pct([r[k] for r in rows], 0.5), "p95": pct([r[k] for r in rows], 0.95),
                   "max": max([r[k] for r in rows if r[k] is not None], default=None)}
               for k in ("window_ms", "first_pane_frame_ms", "all_drawn_ms", "per_pane_frame_max_ms", "pre_main_ms")}
    summary["cycles"] = len(rows)
    summary["all_in_first_window_frame"] = sum(1 for r in rows if r["all_in_first_window_frame"])
    summary["cycles_with_differences"] = sum(1 for r in rows if [x for x in r["differences"] if not x.startswith("NOT COMPARED")])
    print(json.dumps(summary, indent=1))


if __name__ == "__main__":
    main()
