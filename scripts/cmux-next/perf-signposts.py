#!/usr/bin/env python3
"""Read cmux's always-on signpost intervals and print p50/p95/max per name.

The same names exist in Debug and Release builds (Packages/macOS/CmuxNext/Sources/
CmuxNextSignposts/SignpostName.swift, plans/cmux-next/architecture-refactor-DESIGN.md
section 7), so this measures what users run. It streams the unified log
(`log stream --signpost --style ndjson`) for one process while a scenario runs, pairs each
interval's begin and end by signpost id, and groups the durations by name and by the `id=` or
`kind=` field of the begin message. For `action.commit` it also reports input to frame
(the interval plus the begin's `input_age_ms`, when the action came from an OS event).

Run it on the fleet host that runs the app (never on Lawrence's Mac), and report the display's
refresh rate next to frame numbers.

Usage:
  perf-signposts.py --pid PID [--category action ...] [--seconds N | -- COMMAND ...] [--json]
  perf-signposts.py --from FILE.ndjson [--json]     summarize a saved stream
  perf-signposts.py --save FILE.ndjson ...           also keep the raw stream
  perf-signposts.py --self-test                      check the parser on a built-in sample

Without --seconds or a COMMAND it streams until Ctrl-C.
"""

from __future__ import annotations

import argparse
import json
import re
import signal
import statistics
import subprocess
import sys
import time
from datetime import datetime

SUBSYSTEM = "com.cmuxterm.app.next"
TIMESTAMP = re.compile(r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+)([+-]\d{4})$")


def parse_time(text: str) -> float:
    match = TIMESTAMP.match(text)
    if not match:
        raise ValueError(f"unexpected timestamp {text!r}")
    return datetime.strptime(match.group(1) + match.group(2), "%Y-%m-%d %H:%M:%S.%f%z").timestamp()


def fields(message: str) -> dict[str, str]:
    return dict(part.split("=", 1) for part in message.split() if "=" in part)


def pair(lines) -> list[dict]:
    """Begin/end pairs as {name, category, ms, fields}."""
    open_intervals: dict[tuple, tuple[float, dict]] = {}
    done = []
    for line in lines:
        line = line.strip()
        if not line.startswith("{"):
            continue
        event = json.loads(line)
        if event.get("eventType") != "signpostEvent" or event.get("subsystem") != SUBSYSTEM:
            continue
        key = (event.get("processID"), event.get("category"), event.get("signpostName"), event.get("signpostID"))
        kind = event.get("signpostType")
        at = parse_time(event["timestamp"])
        if kind == "begin":
            open_intervals[key] = (at, fields(event.get("eventMessage", "")))
        elif kind == "end" and key in open_intervals:
            start, info = open_intervals.pop(key)
            done.append({"name": key[2], "category": key[1], "ms": (at - start) * 1000, "fields": info})
    return done


def percentile(values: list[float], fraction: float) -> float:
    ordered = sorted(values)
    index = min(len(ordered) - 1, max(0, round(fraction * (len(ordered) - 1))))
    return ordered[index]


def summarize(intervals: list[dict]) -> list[dict]:
    groups: dict[tuple[str, str], list[float]] = {}
    for interval in intervals:
        detail = interval["fields"].get("id") or interval["fields"].get("kind") or ""
        groups.setdefault((interval["name"], detail), []).append(interval["ms"])
        groups.setdefault((interval["name"], "*"), []).append(interval["ms"])
        age = interval["fields"].get("input_age_ms")
        if interval["name"] == "action.commit" and age and float(age) >= 0:
            groups.setdefault(("action.input_to_frame", detail), []).append(interval["ms"] + float(age))
    rows = []
    for (name, detail), values in sorted(groups.items()):
        rows.append({
            "name": name, "detail": detail, "count": len(values),
            "p50_ms": round(statistics.median(values), 3),
            "p95_ms": round(percentile(values, 0.95), 3),
            "max_ms": round(max(values), 3),
        })
    return rows


def stream(args) -> list[str]:
    predicate = f'subsystem == "{SUBSYSTEM}"'
    if args.category:
        predicate += " AND category IN {" + ", ".join(f'"{c}"' for c in args.category) + "}"
    command = ["/usr/bin/log", "stream", "--signpost", "--style", "ndjson", "--predicate", predicate,
               "--process", str(args.pid)]
    log = subprocess.Popen(command, stdout=subprocess.PIPE, text=True)
    lines: list[str] = []
    try:
        # The log tool prints its filter line once it is attached; start the scenario after it.
        first = log.stdout.readline()
        lines.append(first)
        if args.command:
            subprocess.run(args.command, check=False)
        elif args.seconds:
            time.sleep(args.seconds)  # the measurement window itself, not a wait for a condition
        else:
            signal.pause()
    except KeyboardInterrupt:
        pass
    finally:
        log.send_signal(signal.SIGINT)
        rest, _ = log.communicate(timeout=10)
        lines.extend(rest.splitlines())
    return lines


SAMPLE = """Filtering the log data using "subsystem == ..."
{"eventType":"signpostEvent","subsystem":"com.cmuxterm.app.next","category":"action","signpostName":"action.commit","signpostID":7,"signpostType":"begin","processID":1,"timestamp":"2026-10-23 04:55:41.243635-0700","eventMessage":"id=tab.new origin=user input_age_ms=1.50"}
{"eventType":"signpostEvent","subsystem":"com.cmuxterm.app.next","category":"action","signpostName":"action.perform","signpostID":8,"signpostType":"begin","processID":1,"timestamp":"2026-10-23 04:55:41.243700-0700","eventMessage":"id=tab.new origin=user input_age_ms=1.50"}
{"eventType":"signpostEvent","subsystem":"com.cmuxterm.app.next","category":"action","signpostName":"action.perform","signpostID":8,"signpostType":"end","processID":1,"timestamp":"2026-10-23 04:55:41.245700-0700","eventMessage":""}
{"eventType":"signpostEvent","subsystem":"com.cmuxterm.app.next","category":"action","signpostName":"action.commit","signpostID":7,"signpostType":"end","processID":1,"timestamp":"2026-10-23 04:55:41.249635-0700","eventMessage":""}
{"eventType":"signpostEvent","subsystem":"other","category":"action","signpostName":"action.commit","signpostID":7,"signpostType":"end","processID":1,"timestamp":"2026-10-23 04:55:41.259635-0700","eventMessage":""}
"""


def self_test() -> int:
    rows = {(r["name"], r["detail"]): r for r in summarize(pair(SAMPLE.splitlines()))}
    assert abs(rows[("action.perform", "tab.new")]["p50_ms"] - 2.0) < 1e-6, rows
    assert abs(rows[("action.commit", "tab.new")]["p50_ms"] - 6.0) < 1e-6, rows
    assert abs(rows[("action.input_to_frame", "tab.new")]["p50_ms"] - 7.5) < 1e-6, rows
    assert rows[("action.commit", "*")]["count"] == 1, rows
    print("self-test ok")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--pid", type=int)
    parser.add_argument("--from", dest="source")
    parser.add_argument("--save")
    parser.add_argument("--category", action="append")
    parser.add_argument("--seconds", type=float)
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.command and args.command[0] == "--":
        args.command = args.command[1:]
    if args.self_test:
        return self_test()
    if args.source:
        with open(args.source) as handle:
            lines = handle.read().splitlines()
    elif args.pid:
        lines = stream(args)
    else:
        parser.error("--pid or --from is required")
    if args.save:
        with open(args.save, "w") as handle:
            handle.write("\n".join(lines) + "\n")
    rows = summarize(pair(lines))
    if args.json:
        print(json.dumps(rows))
        return 0
    print(f"{'name':28} {'detail':36} {'n':>5} {'p50':>9} {'p95':>9} {'max':>9}")
    for row in rows:
        print(f"{row['name']:28} {row['detail'][:36]:36} {row['count']:5} {row['p50_ms']:9.3f} {row['p95_ms']:9.3f} {row['max_ms']:9.3f}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
