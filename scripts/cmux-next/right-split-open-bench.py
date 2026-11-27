#!/usr/bin/env python3
"""Right split open, first frame, with the snapshot-first open off and on (goal instant-splits).

Launches the tagged app, then for each arm (`--arms off,on`) sets `DesignSettings.splitSnapshotOpen` through
`debug.motion {"action":"kind","name":"splitSnapshotOpen","value":...}`, and --rounds times presses Cmd-D (the real
key path, `debug.key`) in the first workspace, waits --settle seconds, and closes the new pane with Cmd-W (untimed).
The numbers are the app's own always-on frame timing (TransitionFrameLog, `right_split_open` lines of
`~/Library/Logs/cmux-next/<tag>/frame-timing.jsonl`): the key press's event timestamp to the first Core Animation
commit that shows the split begin. Off, that is the held snap that shows the live panes (`path: live`); on, the
retained picture's flushed commit (`path: snapshot`). An `on` press the layout could not open from a picture falls
back to the live path and counts as `live` in the on arm.

  right-split-open-bench.py --app APP [--rounds 20] [--arms off,on] [--settle 0.6] [--json FILE]
Fleet: cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/split-spring.sh \\
         --ref SHA --artifact artifacts/split-spring/report.json --arg=--suite=right-split-open
"""
import argparse, glob, json, os, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bench_launch import BenchApp  # noqa: E402
import frame_timing  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--tag", help="(accepted; the app's tag comes from its bundle name)")
parser.add_argument("--app", required=True)
parser.add_argument("--out", default=None)
parser.add_argument("--json")
parser.add_argument("--rounds", type=int, default=20)
parser.add_argument("--arms", default="off,on")
parser.add_argument("--settle", type=float, default=0.6)
opts, _unknown = parser.parse_known_args()
BUDGET_MS = 16.0
bench = BenchApp(opts.app, out=opts.out)


def logs_since(started_ms):
    """Every right_split_open row of this Mac's frame-timing logs written since `started_ms`."""
    root = os.path.join(os.path.expanduser("~"), "Library", "Logs", "cmux-next")
    lines = []
    for path in sorted(glob.glob(os.path.join(root, "*", frame_timing.OLDER)) + glob.glob(os.path.join(root, "*", frame_timing.FILE))):
        with open(path, encoding="utf-8", errors="replace") as handle:
            lines.extend(handle)
    rows, _ = frame_timing.read_lines(lines)
    return [r for r in rows if r["transition"] == "right_split_open" and r.get("at_ms", 0) >= started_ms]


def key(letter, modifiers):
    reply = bench.rpc("debug.key", {"key": letter, "modifiers": modifiers})
    return reply.get("error") if isinstance(reply, dict) else None


def main():
    bench.launch()
    time.sleep(2)  # test harness: the first terminal draws
    report = {"host": os.uname().nodename, "rounds": opts.rounds, "budget_ms": BUDGET_MS, "arms": {}, "errors": []}
    for arm in [a for a in opts.arms.split(",") if a]:
        bench.rpc("debug.motion", {"action": "kind", "name": "splitSnapshotOpen", "value": arm == "on"})
        state = (bench.rpc("debug.motion", {"action": "read"}) or {}).get("split_snapshot_open")
        started_ms = int(time.time() * 1000)
        for _ in range(opts.rounds):
            error = key("d", ["command"])
            if error:
                report["errors"].append(f"{arm} Cmd-D: {error}")
            time.sleep(opts.settle)  # test harness: the split lands and its picture goes
            error = key("w", ["command"])
            if error:
                report["errors"].append(f"{arm} Cmd-W: {error}")
            time.sleep(opts.settle)
        time.sleep(1.5)  # the log's writer coalesces for 1 s
        rows = logs_since(started_ms)
        stats = frame_timing.summarize(rows)
        report["arms"][arm] = {"flag_read_back": state, "rows": len(rows), "by_path": stats,
                               "all": frame_timing.summarize([{**r, "path": None} for r in rows]).get("right_split_open")}
        print(f"{arm}: flag {state}  " + "  ".join(
            f"{k}: n {s['count']} p50 {s['p50_ms']} p95 {s['p95_ms']} max {s['max_ms']} ms (event {s['from_event']})"
            for k, s in stats.items()) or f"{arm}: no right_split_open rows", flush=True)
    print("RESULT " + json.dumps(report), flush=True)
    if opts.json:
        with open(opts.json, "w") as handle:
            json.dump(report, handle, indent=1)
    return all(arm.get("rows") for arm in report["arms"].values())


ok = False
try:
    ok = main()
finally:
    bench.stop()
sys.exit(0 if ok else 1)
