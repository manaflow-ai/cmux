#!/usr/bin/env python3
"""Reads the app's always-on transition frame log (TransitionFrameLog.swift, goal instant-splits) and prints, per
transition, the count and the p50 / p95 / max of `ms` (the input event to the end of the first Core Animation commit
that carries the change). A drag's work line (`divider_drag_work`: `ms` its first move to its release, `moves`, and
what the browser's page counters moved in it: `detaches`, `attaches`, `fence_joined`, `fence_missed`, ...) also
gets each counter's mean and max per drag.

    python3 scripts/cmux-next/frame_timing.py                      # every app's log on this Mac
    python3 scripts/cmux-next/frame_timing.py FILE...              # given files (frame-timing.jsonl, .1)
    python3 scripts/cmux-next/frame_timing.py --transition divider_drag --last 200 --json
    python3 scripts/cmux-next/frame_timing.py --table              # one row per surface x transition, worst first

`--table` is the frame timeline (goal instant-splits): per surface (the content kind of the panes the transition
showed: terminal, browser, agent, page, ..., mixed; `unknown` when a line has none) and transition (with its path), the
count, the first frame's p50 and p95 (`ms`: input to the first frame's commit), the settle's p95 (`settled_ms`: input
to the last moving commit), the share of first frames that showed a pane with no content (`blank_first_frame`, over
the lines that carry it), the largest end-point drift (`drift_px`: device pixels between a pane's final frame and its
target rect) and the 16 ms budget (`ok` when the first frame's p95 is within it). The worst first-frame p95 is first.

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
# Fields of a row that are no per-drag counter.
SKIP_FIELDS = {"transition", "ms", "commit_ms", "input_ts", "first_frame_ts", "event", "build", "at_ms", "path",
               "settled_ts", "settled_ms", "surface", "blank_first_frame", "drift_px"}
# The budget of a first frame: one 60 Hz refresh.
BUDGET_MS = 16.0
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
    transition's newest N. A row with a `path` (right_split_open: `snapshot` or `live`) counts under
    `transition/path`, so a flag's off and on runs are apart."""
    by = {}
    for row in rows:
        if transition and row["transition"] != transition:
            continue
        path = row.get("path")
        key = f"{row['transition']}/{path}" if isinstance(path, str) and path else row["transition"]
        by.setdefault(key, []).append(row)
    out = {}
    for name, group in sorted(by.items()):
        if last:
            group = group[-last:]
        ms = [float(r["ms"]) for r in group]
        out[name] = {"count": len(ms), "p50_ms": pct(ms, 0.5), "p95_ms": pct(ms, 0.95), "max_ms": round(max(ms), 2),
                     "from_event": sum(1 for r in group if r.get("event") is True)}
        counters = {}
        for row in group:
            for key, value in row.items():
                if key not in SKIP_FIELDS and isinstance(value, int) and not isinstance(value, bool):
                    counters.setdefault(key, []).append(value)
        if counters:
            out[name]["per_drag"] = {key: {"mean": round(sum(v) / len(v), 2), "max": max(v)} for key, v in sorted(counters.items())}
    return out


def _number(value):
    return float(value) if isinstance(value, (int, float)) and not isinstance(value, bool) else None


def table(rows, transition=None, last=None, budget_ms=BUDGET_MS):
    """The frame-timeline table: one dict per surface x transition (`transition/path` when a line has a path), worst
    first-frame p95 first (then worst settle). Work lines (`*_work`) are no transition's frames and are left out.
    `blank_pct` and `max_drift_px` are None when no line of the row carries the field; `settled_p95_ms` falls back
    to `ms` for a line written before the settle was logged."""
    by = {}
    for row in rows:
        name = row["transition"]
        if name.endswith("_work") or (transition and name != transition):
            continue
        path = row.get("path")
        key = (row.get("surface") if isinstance(row.get("surface"), str) and row.get("surface") else "unknown",
               f"{name}/{path}" if isinstance(path, str) and path else name)
        by.setdefault(key, []).append(row)
    out = []
    for (surface, name), group in by.items():
        if last:
            group = group[-last:]
        first = [float(r["ms"]) for r in group]
        settled = [_number(r.get("settled_ms")) if _number(r.get("settled_ms")) is not None else float(r["ms"]) for r in group]
        flags = [r["blank_first_frame"] for r in group if isinstance(r.get("blank_first_frame"), bool)]
        drifts = [d for d in (_number(r.get("drift_px")) for r in group) if d is not None]
        p95 = pct(first, 0.95)
        out.append({"surface": surface, "transition": name, "n": len(group), "first_p50_ms": pct(first, 0.5),
                    "first_p95_ms": p95, "settled_p95_ms": pct(settled, 0.95),
                    "blank_pct": round(100.0 * sum(flags) / len(flags), 1) if flags else None,
                    "max_drift_px": round(max(drifts), 2) if drifts else None,
                    "budget_ms": budget_ms, "budget": "ok" if p95 <= budget_ms else "over"})
    out.sort(key=lambda r: (-r["first_p95_ms"], -r["settled_p95_ms"], r["surface"], r["transition"]))
    return out


TABLE_COLUMNS = [("surface", "surface"), ("transition", "transition"), ("n", "n"), ("first_p50_ms", "ff p50"),
                 ("first_p95_ms", "ff p95"), ("settled_p95_ms", "settled p95"), ("blank_pct", "blank %"),
                 ("max_drift_px", "max drift px"), ("budget", "16ms")]


def format_table(entries):
    """`table()`'s rows as aligned text, a header first; "-" for a field no line carried."""
    if not entries:
        return "no timed transitions"
    budget = entries[0].get("budget_ms", BUDGET_MS)
    heads = [(key, f"{budget:g}ms" if key == "budget" else head) for key, head in TABLE_COLUMNS]
    cells = [[head for _, head in heads]] + [["-" if e.get(key) is None else str(e[key]) for key, _ in heads] for e in entries]
    widths = [max(len(row[i]) for row in cells) for i in range(len(heads))]
    return "\n".join("  ".join(c.ljust(w) if i < 2 else c.rjust(w) for i, (c, w) in enumerate(zip(row, widths))).rstrip()
                     for row in cells)


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
    parser.add_argument("--transition", help="only this transition (divider_drag, right_split_open)")
    parser.add_argument("--last", type=int, help="each transition's newest N rows only")
    parser.add_argument("--json", action="store_true", help="print JSON")
    parser.add_argument("--table", action="store_true", help="one row per surface x transition, worst first-frame p95 first")
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
        if args.table:
            report[name] = {"table": table(rows, args.transition, args.last), "skipped": skipped}
    if args.json:
        print(json.dumps(report, indent=2, sort_keys=True))
        return 0
    for name, entry in report.items():
        print(f"{name}" + (f" (skipped {entry['skipped']} lines)" if entry["skipped"] else ""))
        if args.table:
            print(format_table(entry["table"]))
            continue
        if not entry["transitions"]:
            print("  no rows")
        for transition, s in entry["transitions"].items():
            print(f"  {transition}: count {s['count']}  p50 {s['p50_ms']} ms  p95 {s['p95_ms']} ms  max {s['max_ms']} ms"
                  f"  (from event {s['from_event']})")
            if s.get("per_drag"):
                print("    per drag: " + "  ".join(f"{k} {v['mean']} (max {v['max']})" for k, v in s["per_drag"].items()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
