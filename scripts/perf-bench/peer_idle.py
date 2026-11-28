#!/usr/bin/env python3
"""One idle launch of a peer app (Claude desktop, ChatGPT desktop), written as bench_memory.py writes a terminal
launch, so perf-idle-ab.sh peer= and NOW's idle-footprint reconciler read it as they read cmux NEXT's.

The launch is a first install's: its own empty home and TMPDIR (rivals.App.launch, the same switches rivals.py
gives each app). After --settle s it idles --measure s and reads phys_footprint of every process of the app
(procs.Instance: its descendants, the processes run from its bundle and those it is responsible for), summed
per process kind (procs.kind_of) and per RFD 0062 group (rivals.group_of).

Usage: peer_idle.py --name claude|chatgpt --app BUNDLE --profile DIR [--settle 20] [--measure 60] --out FILE.json
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import rivals  # noqa: E402  (imports procs lazily, so the grouping below runs on Linux)

PEERS = ("claude", "chatgpt")


def sample(memory: dict, measure: float, label: str = "idle-1") -> dict:
    """bench_memory.py's idle sample shape from one procs.Instance.memory(per_pid=True) read: the total, each
    kind's footprint (and process count), each group's footprint, and the processes themselves."""
    kinds: dict[str, dict] = {}
    for row in memory.get("pids") or []:
        entry = kinds.setdefault(row["kind"], {"footprint_mb": 0.0, "n": 0})
        entry["footprint_mb"] = round(entry["footprint_mb"] + row["footprint_mb"], 1)
        entry["n"] += 1
    groups = {g: v["memory"] for g, v in rivals.by_group({k: e["footprint_mb"] for k, e in kinds.items()}, {}).items()}
    return {"label": label, "measure_s": measure, "time": round(time.time()),
            "total_footprint_mb": memory.get("mb"), "processes": memory.get("processes"),
            "kinds": dict(sorted(kinds.items(), key=lambda kv: -kv[1]["footprint_mb"])),
            "groups": {g: round(mb, 1) for g, mb in groups.items()},
            "pids": [{**row, "group": rivals.group_of(row["kind"])} for row in memory.get("pids") or []]}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--name", required=True, choices=PEERS)
    parser.add_argument("--app", required=True)
    parser.add_argument("--profile", required=True, help="a new empty folder: the launch's home and TMPDIR")
    parser.add_argument("--settle", type=float, default=20)
    parser.add_argument("--measure", type=float, default=60)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    if os.path.exists(args.profile) and os.listdir(args.profile):
        print(f"peer_idle: --profile {args.profile} is not empty", file=sys.stderr)
        return 2
    app = rivals.App(args.name, args.app, helper=None)
    report = {"app": args.app, "peer": args.name, "settle_s": args.settle, "samples": []}
    try:
        app.launch(args.profile)
        time.sleep(args.settle)  # bench: the launch settles before the idle window
        launch = app.instance.memory(per_pid=True)
        report["samples"].append(sample(launch, 0, "idle-launch"))
        time.sleep(args.measure)  # bench: the idle window
        report["samples"].append(sample(app.instance.memory(per_pid=True), args.measure))
    finally:
        if app.instance:
            app.instance.end(grace=15)
    with open(args.out, "w") as handle:
        json.dump(report, handle, indent=1)
    last = report["samples"][-1]
    print(f"PEER-IDLE {args.name} total_footprint_mb {last['total_footprint_mb']} processes {last['processes']} "
          + " ".join(f"{g} {mb}" for g, mb in last["groups"].items()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
