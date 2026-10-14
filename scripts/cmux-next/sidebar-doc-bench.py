#!/usr/bin/env python3
"""Commit cost of personal sidebar writes at scale, at the daemon socket.

Starts a daemon on a fresh state dir, creates N workspaces (default 2000)
with two groups, then times, per request (wall clock at the socket):
- workspace.create (a creation commit: personal row + sidebar adoption),
- workspace.place  (a personal reorder: one row to a new index),
- workspace_group.update (a personal group rename),
- sidebar.move (only when the daemon has sidebar-doc-v1).
Prints median and p95 in ms for each. Compare two binaries with the same N.

`--subscriber old|doc` keeps one `session.events` stream open during the
timed requests (read on a thread): `old` echoes nothing (it gets the
placement restatement), `doc` echoes sidebar-doc-v1 and placement-shift-v1.

Usage: sidebar-doc-bench.py --binary path/to/cmux-tui [--count 2000] [--samples 40]
                            [--subscriber none|old|doc]
"""

from __future__ import annotations

import argparse
import importlib.util
import statistics
import sys
import tempfile
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("sidebar_doc_live", HERE / "sidebar-doc-live.py")
live = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(live)


def timed(samples: list[float], action) -> object:
    started = time.perf_counter()
    result = action()
    samples.append((time.perf_counter() - started) * 1000)
    return result


def report(name: str, samples: list[float]) -> None:
    ordered = sorted(samples)
    p95 = ordered[max(0, int(len(ordered) * 0.95) - 1)]
    print(f"{name}: median {statistics.median(ordered):.2f} ms, p95 {p95:.2f} ms, n={len(ordered)}", flush=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--count", type=int, default=2000)
    parser.add_argument("--samples", type=int, default=40)
    parser.add_argument("--subscriber", choices=["none", "old", "doc"], default="none")
    args = parser.parse_args()
    work = Path(tempfile.mkdtemp(prefix="sbbench-"))
    state = work / "state"
    state.mkdir(mode=0o700)
    sock = Path(tempfile.mkdtemp(prefix="sb", dir="/tmp")) / "s.sock"
    daemon = live.Daemon(args.binary.resolve(), state, sock)
    daemon.start()
    try:
        caps = daemon.raw({"cmd": "identify"})["capabilities"]
        ids = []
        started = time.perf_counter()
        for index in range(args.count):
            created = daemon.ok("workspace.create", {"name": f"w{index}", "initial_content": "empty"}, mutate=True)
            ids.append(created["value"]["workspace_id"])
        print(f"seeded {args.count} workspaces in {time.perf_counter() - started:.1f} s", flush=True)
        groups = [daemon.ok("workspace_group.create", {"name": f"g{i}"}, mutate=True)["value"]["id"] for i in range(2)]
        for index, workspace in enumerate(ids[:20]):
            daemon.ok("workspace.place", {"workspace": workspace, "group": groups[index % 2]}, mutate=True)
        if args.subscriber != "none":
            stream = live.EventStream(daemon, ["sidebar-doc-v1", "placement-shift-v1"] if args.subscriber == "doc" else None)
            threading.Thread(target=lambda: [None for _ in stream.lines(3600.0)], daemon=True).start()
            print(f"subscriber: {args.subscriber}", flush=True)
        creates, places, renames, moves = [], [], [], []
        for sample in range(args.samples):
            timed(creates, lambda: daemon.ok(
                "workspace.create", {"name": f"x{sample}", "initial_content": "empty"}, mutate=True))
            target = ids[(sample * 37) % len(ids)]
            timed(places, lambda: daemon.ok(
                "workspace.place", {"workspace": target, "index": (sample * 53) % len(ids)}, mutate=True))
            timed(renames, lambda: daemon.ok(
                "workspace_group.update", {"workspace_group": groups[0], "name": f"g0-{sample}"}, mutate=True))
        report("workspace.create", creates)
        report("workspace.place", places)
        report("workspace_group.update", renames)
        if "sidebar-doc-v1" in caps:
            doc = daemon.ok("sidebar.get")
            local = daemon.raw({"cmd": "identify"})["registry_id"]
            items = [live.ws_item(doc, local, w)["id"] for w in ids[100:100 + args.samples]]
            for sample, item in enumerate(items):
                section = "sec_pinned" if sample % 2 == 0 else f"sec_m_{local}"
                timed(moves, lambda: daemon.ok(
                    "sidebar.move", {"items": [item], "to": {"section": section, "index": 0}}, mutate=True))
            report("sidebar.move", moves)
    finally:
        daemon.stop()
    return 0


if __name__ == "__main__":
    sys.exit(main())
