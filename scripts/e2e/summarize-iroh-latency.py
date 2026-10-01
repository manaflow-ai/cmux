#!/usr/bin/env python3
import json
import sys
from pathlib import Path

if len(sys.argv) != 4:
    raise SystemExit("usage: summarize-iroh-latency.py STATE OUTPUT JOURNAL_DIR")
state_path, output_path, journal_dir = map(Path, sys.argv[1:])
state = {}
for line in state_path.read_text(encoding="utf-8").splitlines():
    key, separator, value = line.partition("=")
    if separator:
        state[key] = value
try:
    applied_delay = float(state["delay_ms"])
except (KeyError, ValueError):
    raise SystemExit("latency state has no valid delay_ms")

samples = []
for path in sorted(journal_dir.glob("*-ios-iroh-v2-journal-success-*.jsonl")):
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        try:
            value = json.loads(raw)
        except json.JSONDecodeError:
            continue
        stack = [value]
        while stack:
            item = stack.pop()
            if isinstance(item, dict):
                for key, child in item.items():
                    if key in {"rtt_ms", "a_rtt_ms"}:
                        try:
                            number = float(child)
                        except (TypeError, ValueError):
                            continue
                        if number >= 0:
                            samples.append(number)
                    elif isinstance(child, (dict, list)):
                        stack.append(child)
            elif isinstance(item, list):
                stack.extend(item)

if not samples:
    raise SystemExit("latency impairment was applied but no IROH RTT samples were recorded")
samples.sort()

def percentile(percent):
    index = min(len(samples) - 1, max(0, int(round((len(samples) - 1) * percent))))
    return samples[index]

summary = {
    "appliedDelayMs": applied_delay,
    "sampleCount": len(samples),
    "rttMs": {"p50": percentile(0.50), "p95": percentile(0.95), "max": samples[-1]},
    "journalFiles": [str(path) for path in sorted(journal_dir.glob("*-ios-iroh-v2-journal-success-*.jsonl"))],
}
output_path.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
if summary["rttMs"]["p95"] < applied_delay:
    raise SystemExit(
        f"observed IROH RTT p95 {summary['rttMs']['p95']}ms did not reflect applied {applied_delay}ms delay"
    )
print(json.dumps(summary, sort_keys=True))
