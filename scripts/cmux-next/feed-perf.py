#!/usr/bin/env python3
"""Feed list scroll and live-update bench: summarizes the report a DEBUG cmux-next app writes when it runs with
CMUX_NEXT_FEED_BENCH=<path> (CmuxNextFeed/Views/FeedBench.swift), the Mac twin of the iPhone rig's
CMUX_MOBILE_FEED_STRESS (cmux-next-ios/verify/feedperf).

Launch the tagged app with the variables, open the Feed panel (`action.run {"id": "feed.show"}` on its control socket),
and the app seeds the list and runs three phases on display frames: scroll (down and back at the set speed), scroll-live
(the same while live events arrive) and live (events only). Then:

  feed-perf.py REPORT.json [REPORT.json ...] [--markdown PATH]

prints, per report and phase: frames, p50/p95/p99/max frame interval, frames over 1.5 refresh periods, hitch ms per
second (time past one refresh period in those frames, over the phase's length), and the AppKit list's renders and
reloaded rows (0 for the SwiftUI list, which keeps no counts). Slow numbers are data, not failures.
"""
import argparse, json, os


def percentile(values, p):
    if not values:
        return 0.0
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(round(p / 100 * (len(ordered) - 1))))]


def summarize(path):
    report = json.load(open(path))
    rows = []
    for phase in report["phases"]:
        intervals = phase["intervals_ms"]
        refresh = percentile(intervals, 50) or 16.67
        long = [i for i in intervals if i > refresh * 1.5]
        duration = max(sum(intervals) / 1000, 0.001)
        rows.append({
            "report": os.path.basename(path), "phase": phase["name"], "frames": len(intervals),
            "refresh_ms": round(refresh, 2), "p50_ms": round(percentile(intervals, 50), 2),
            "p95_ms": round(percentile(intervals, 95), 2), "p99_ms": round(percentile(intervals, 99), 2),
            "max_ms": round(max(intervals or [0]), 2), "long_frames": len(long),
            "hitch_ms_per_s": round(sum(i - refresh for i in long) / duration, 1),
            "renders": phase.get("renders", 0), "rows_reloaded": phase.get("rows_reloaded", 0),
        })
    return report, rows


parser = argparse.ArgumentParser()
parser.add_argument("reports", nargs="+")
parser.add_argument("--markdown")
args = parser.parse_args()

cols = ["report", "phase", "frames", "p50_ms", "p95_ms", "p99_ms", "max_ms", "long_frames", "hitch_ms_per_s", "renders", "rows_reloaded"]
lines = ["| " + " | ".join(cols) + " |", "|" + "---|" * len(cols)]
everything = []
for path in args.reports:
    report, rows = summarize(path)
    everything.append({"report": path, "settings": {k: report[k] for k in ("count", "seconds", "speed", "live_hz")}, "phases": rows})
    lines += ["| " + " | ".join(str(r[c]) for c in cols) + " |" for r in rows]
print("\n".join(lines))
print("REPORT-JSON " + json.dumps(everything))
if args.markdown:
    open(args.markdown, "w").write("\n".join(lines) + "\n")
