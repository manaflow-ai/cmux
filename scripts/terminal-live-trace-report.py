#!/usr/bin/env python3
"""Summarize live terminal-path traces from an iOS diagnostics export.

Input: the text timeline exported from iOS Settings > Diagnostics (the
DiagnosticLog export), which contains "Terminal operation trace" lines with
trace_id / operation / phase fields and per-phase elapsed milliseconds.
Optionally, a tagged Mac debug log (/tmp/cmux-debug-<tag>.log) adds host-side
`host.grid` / `host.flush` stamps to the picture.

Output: a per-keystroke waterfall for liveInput traces (dispatch -> sent ->
echo -> presented), stage percentiles, discard-reason counts for liveFrame
traces, and a one-line verdict naming the dominant stage.

Usage:
  scripts/terminal-live-trace-report.py <ios-export.txt> [mac-debug.log]
"""

import re
import sys
from collections import defaultdict

PHASE_ORDER = ["started", "requestSent", "responseReceived", "presented"]
FIELD_RE = re.compile(r"([A-Za-z_][A-Za-z0-9_]*)=([^\s]+)")
MS_KEYS = ("elapsed", "duration", "ms", "lag")


def parse_export(path):
    inputs = defaultdict(dict)   # trace_id -> {phase: elapsed_ms or None}
    discards = defaultdict(int)  # reason -> count
    frames = {"decoded": 0, "presented": 0, "presented_ms": []}
    for line in open(path, errors="replace"):
        if "Terminal operation trace" not in line and "terminalTrace" not in line:
            continue
        fields = dict(FIELD_RE.findall(line))
        operation = fields.get("operation")
        phase = fields.get("phase")
        if not operation or not phase:
            continue
        elapsed = None
        for key, value in fields.items():
            if any(key.startswith(k) for k in MS_KEYS):
                match = re.match(r"(\d+)", value)
                if match:
                    elapsed = int(match.group(1))
        if operation == "liveInput":
            trace_id = fields.get("trace_id", "?")
            inputs[trace_id][phase] = elapsed
        elif operation == "liveFrame":
            if phase == "discarded":
                discards[fields.get("reason", fields.get("detail_3", "?"))] += 1
            elif phase == "decoded":
                frames["decoded"] += 1
            elif phase == "presented":
                frames["presented"] += 1
                if elapsed is not None:
                    frames["presented_ms"].append(elapsed)
    return inputs, discards, frames


def percentile(values, fraction):
    if not values:
        return None
    ordered = sorted(values)
    index = min(len(ordered) - 1, int(fraction * (len(ordered) - 1) + 0.5))
    return ordered[index]


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    inputs, discards, frames = parse_export(sys.argv[1])

    stage_values = defaultdict(list)
    complete = 0
    print(f"liveInput traces: {len(inputs)}")
    print("\ntrace_id          sent  echo  visible  (ms from dispatch)")
    for trace_id, phases in sorted(inputs.items()):
        sent = phases.get("requestSent")
        echo = phases.get("responseReceived")
        visible = phases.get("presented")
        if "failed" in phases:
            print(f"{trace_id:16s}  FAILED SEND")
            continue
        row = [
            f"{trace_id:16s}",
            f"{sent if sent is not None else '?':>5}",
            f"{echo if echo is not None else '?':>5}",
            f"{visible if visible is not None else '?':>7}",
        ]
        print("  ".join(str(part) for part in row))
        if sent is not None:
            stage_values["dispatch->sent"].append(sent)
        if echo is not None:
            stage_values["dispatch->echo"].append(echo)
            if sent is not None:
                stage_values["sent->echo (network+host+program)"].append(max(0, echo - sent))
        if visible is not None:
            complete += 1
            stage_values["dispatch->visible"].append(visible)
            if echo is not None:
                stage_values["echo->visible (phone apply+present)"].append(max(0, visible - echo))

    print(f"\ncomplete keystroke traces: {complete}")
    print("\nstage percentiles (ms):")
    dominant = (None, -1)
    for stage, values in stage_values.items():
        p50 = percentile(values, 0.5)
        p95 = percentile(values, 0.95)
        print(f"  {stage:38s} p50={p50:>6} p95={p95:>6} n={len(values)}")
        if "->" in stage and stage.startswith(("sent->", "echo->")) and p95 is not None and p95 > dominant[1]:
            dominant = (stage, p95)

    print(f"\nliveFrame: decoded={frames['decoded']} presented={frames['presented']}")
    if frames["presented_ms"]:
        print(
            f"  receipt->present p50={percentile(frames['presented_ms'], 0.5)}ms"
            f" p95={percentile(frames['presented_ms'], 0.95)}ms"
        )
    if discards:
        print("  discards:")
        for reason, count in sorted(discards.items(), key=lambda item: -item[1]):
            print(f"    {reason}: {count}")

    if dominant[0]:
        print(f"\nverdict: dominant stage at p95 is '{dominant[0]}' ({dominant[1]}ms)")
    if len(sys.argv) > 2:
        grid = re.findall(r"host\.grid .*exp_us=(\d+)", open(sys.argv[2], errors="replace").read())
        if grid:
            values = [int(v) / 1000 for v in grid]
            print(
                f"\nmac host.grid export (from debug log): n={len(values)}"
                f" p50={percentile(values, 0.5):.1f}ms p95={percentile(values, 0.95):.1f}ms"
            )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
