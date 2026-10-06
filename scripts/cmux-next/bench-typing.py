#!/usr/bin/env python3
"""Keystroke-to-frame latency for one cmux-next terminal, hop by hop.

Launch a tagged cmux-next with CMUX_NEXT_TYPING_PROBE=<csv> (see
TypingLatencyProbe.swift), focus a terminal at a shell prompt, then run:

  scripts/cmux-next/bench-typing.py --pid PID --csv PATH [--samples 60]

Each sample is one real key-down posted to the app by CuaDriver
(`press_key`, background delivery), paced wider than a round trip so one
key is in flight at a time. The app's probe writes one CSV row per key:
milliseconds after the event's timestamp at which AppKit dispatch began
and ended, Ghostty called io_write, the attach socket took the input, the
echo was decoded, reached the main actor, was parsed, and the first frame
after that parse was handed to Core Animation (`contents_ms`). The photon
follows at the compositor's next vsync, at most one refresh later.

Prints median, p95 and range per hop and per segment, and writes the same
as JSON next to the CSV.
"""

import argparse
import csv
import json
import statistics
import subprocess
import sys
import time
from pathlib import Path

HOPS = [
    "dispatch_start_ms", "dispatch_end_ms", "io_write_ms", "socket_submit_ms",
    "output_decoded_ms", "output_main_ms", "output_parsed_ms", "contents_ms",
]
SEGMENTS = [
    ("event to dispatch", None, "dispatch_start_ms"),
    ("dispatch to io_write", "dispatch_start_ms", "io_write_ms"),
    ("io_write to socket", "io_write_ms", "socket_submit_ms"),
    ("socket to echo decoded (daemon, host, shell)", "socket_submit_ms", "output_decoded_ms"),
    ("decoded to main actor", "output_decoded_ms", "output_main_ms"),
    ("main actor to parsed", "output_main_ms", "output_parsed_ms"),
    ("parsed to frame contents", "output_parsed_ms", "contents_ms"),
]


def summarize(values):
    values = sorted(values)
    if not values:
        return None
    p95 = values[min(len(values) - 1, round(0.95 * (len(values) - 1)))]
    return {"n": len(values), "median": round(statistics.median(values), 2), "p95": round(p95, 2),
            "min": round(values[0], 2), "max": round(values[-1], 2)}


def press(driver, pid, key):
    payload = json.dumps({"pid": pid, "key": key})
    subprocess.run([driver, "call", "press_key", payload], check=True, capture_output=True, timeout=10)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--pid", type=int, required=True)
    parser.add_argument("--csv", type=Path, required=True)
    parser.add_argument("--samples", type=int, default=60)
    parser.add_argument("--warmup", type=int, default=5)
    parser.add_argument("--interval", type=float, default=0.3, help="seconds between keys")
    parser.add_argument("--keys", default="abcdefghijklmnopqrstuvwxyz")
    parser.add_argument("--driver", default=str(Path.home() / ".local/bin/cua-driver"))
    parser.add_argument("--analyze-only", action="store_true", help="summarize an existing CSV")
    args = parser.parse_args()

    if not args.analyze_only:
        rows_before = len(args.csv.read_text().splitlines()) - 1 if args.csv.exists() else 0
        if rows_before < 0:
            sys.exit(f"{args.csv} has no header: was the app launched with CMUX_NEXT_TYPING_PROBE?")
        for index in range(args.warmup + args.samples):
            press(args.driver, args.pid, args.keys[index % len(args.keys)])
            time.sleep(args.interval)
            if (index + 1) % 40 == 0:
                press(args.driver, args.pid, "return")
                time.sleep(args.interval)
        time.sleep(1)

    with args.csv.open() as handle:
        rows = list(csv.DictReader(handle))
    complete = [row for row in rows if row["complete"] == "1"]
    measured = complete[args.warmup:] if not args.analyze_only else complete
    result = {
        "rows": len(rows), "complete": len(complete), "measured": len(measured),
        "io_write_on_main": sum(row["io_write_on_main"] == "1" for row in measured),
        "hops": {hop: summarize([float(row[hop]) for row in measured if row[hop]]) for hop in HOPS},
        "segments": {},
    }
    for name, start, end in SEGMENTS:
        values = [float(row[end]) - (float(row[start]) if start else 0.0)
                  for row in measured if row[end] and (start is None or row[start])]
        result["segments"][name] = summarize(values)

    print(f"rows={result['rows']} complete={result['complete']} measured={result['measured']} "
          f"io_write_on_main={result['io_write_on_main']}")
    print(f"{'from key event (ms)':<46} {'median':>8} {'p95':>8} {'min':>8} {'max':>8}")
    for hop, stats in result["hops"].items():
        if stats:
            print(f"{hop:<46} {stats['median']:>8} {stats['p95']:>8} {stats['min']:>8} {stats['max']:>8}")
    print(f"\n{'segment (ms)':<46} {'median':>8} {'p95':>8} {'min':>8} {'max':>8}")
    for name, stats in result["segments"].items():
        if stats:
            print(f"{name:<46} {stats['median']:>8} {stats['p95']:>8} {stats['min']:>8} {stats['max']:>8}")
    args.csv.with_suffix(".summary.json").write_text(json.dumps(result, indent=2) + "\n")


if __name__ == "__main__":
    main()
