#!/usr/bin/env python3
"""Summarize the flood bench's agent workload (cmux-next-ios-sim.sh bench, `agent`).

Usage: ios_sim_agent_typing.py AGENT_JSON [FRAME_LOG_NDJSON]

AGENT_JSON is the app's flood-bench.json for `-CmuxMobileFloodBenchMode agent`
(keys typed through the native keyboard path while an agent CLI's live area
redraws). FRAME_LOG_NDJSON is the terminal's frame log of the same run
(`-CmuxMobileFrameLog`). Prints Markdown: per phase, each key's main-thread
time, key-to-echo latency and main-queue latency; then, while output streamed,
the display-link frame intervals, hitches and the screen's main-thread work
per frame, split by signpost.
"""

import json
import os
import sys


def pct(values, q):
    values = sorted(values)
    if not values:
        return 0.0
    return values[min(len(values) - 1, int(q * (len(values) - 1)))]


def main(argv):
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    summary = json.load(open(argv[1]))["summary"]
    print("")
    print("### Agent CLI typing (keys through insertText while the live area redraws 30 times a second)")
    print("")
    print("| Phase | Keys | Key main-thread p50 / p95 / max ms | Echo p50 / p90 / max ms | Main-queue ping p50 / p99 / max ms | Main CPU ms/s |")
    print("| --- | --- | --- | --- | --- | --- |")
    for phase in ("idle", "flood", "after"):
        p = summary.get(phase, {})
        print(
            f"| {phase} | {p.get('keyCount', 0)} | {p.get('keyMainP50ms', '-')} / {p.get('keyMainP95ms', '-')} / {p.get('keyMainMaxms', '-')} | "
            f"{p.get('echoP50ms', '-')} / {p.get('echoP90ms', '-')} / {p.get('echoMaxms', '-')} | "
            f"{p.get('pingP50ms', '-')} / {p.get('pingP99ms', '-')} / {p.get('pingMaxms', '-')} | {p.get('mainCPUmsPerSecondAvg', '-')} |"
        )
    path = argv[2] if len(argv) > 2 else ""
    if not path or not os.path.exists(path):
        return 0
    frames = [json.loads(line) for line in open(path) if line.strip()]
    live = [f for f in frames if f.get("streaming")]
    if not live:
        print("")
        print("Terminal frame log: no frame while output streamed.")
        return 0
    work = [f.get("work_ms", 0.0) for f in live]
    intervals = [f.get("dt_ms", 0.0) for f in live]
    target = pct([f.get("target_ms", 0.0) for f in live], 0.5) or 8.33
    parts = {}
    for f in live:
        for name, ms in f.get("parts", {}).items():
            parts.setdefault(name, []).append(ms)
    print("")
    print(
        f"Terminal frame log while streaming: {len(live)} frames; interval p50 / p95 / max "
        f"{pct(intervals, .5):.1f} / {pct(intervals, .95):.1f} / {max(intervals):.1f} ms; "
        f"hitches (over 1.5 frames) {sum(1 for d in intervals if d > target * 1.5)}; "
        f"screen work per frame p50 / p95 / max {pct(work, .5):.2f} / {pct(work, .95):.2f} / {max(work):.2f} ms"
    )
    print("")
    print("| Part | Frames | Total ms | p95 ms | Max ms |")
    print("| --- | --- | --- | --- | --- |")
    for name, values in sorted(parts.items(), key=lambda kv: -sum(kv[1])):
        print(f"| {name} | {len(values)} | {sum(values):.1f} | {pct(values, .95):.2f} | {max(values):.2f} |")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
