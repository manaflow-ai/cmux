#!/usr/bin/env python3
"""acpmux ls latency against a running daemon: the harness of cmuxterm-hq
docs/findings/2026-11-23-acpmux-cli-startup-tax.md, as a tool.

Runs each command N times, alternating, after one warm-up, and prints its stdout bytes, median and
p95 wall time, and median child CPU (RUSAGE_CHILDREN: the launched acpmux only, not the daemon).
It also times the daemon's `_acpmux/sessions` pages over the socket alone (no CLI), the part a
list's row count scales: `raw limit=1000` is one page as `acpmux ls` asks for it.

Read-only: it lists, never changes a session. Run on any host with a daemon:
  python3 scripts/measure/acpmux-ls-latency.py [--samples 20] [--acpmux acpmux]
    [--socket ~/.acpmux/acpmux.sock] [--json OUT]
"""

import argparse
import json
import os
import resource
import socket
import statistics
import subprocess
import time

COMMANDS = [
    ("version", ["--version"]),
    ("ls limit 1", ["--json", "ls", "--machine", "local", "--limit", "1", "--fields", "name,status"]),
    ("ls limit 100", ["--json", "ls", "--machine", "local", "--limit", "100", "--fields", "name,status"]),
    ("ls local", ["--json", "ls", "--machine", "local", "--fields", "name,status"]),
    ("ls local full rows", ["--json", "ls", "--machine", "local"]),
]

RAW = [
    ("raw limit=1", {"limit": 1, "localOnly": True}),
    ("raw limit=1000", {"limit": 1000, "localOnly": True}),
]


def p95(values):
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, round(0.95 * (len(ordered) - 1)))]


def run(acpmux, argv):
    before = resource.getrusage(resource.RUSAGE_CHILDREN)
    start = time.perf_counter()
    done = subprocess.run([acpmux, *argv], capture_output=True, check=False)
    wall = (time.perf_counter() - start) * 1000
    after = resource.getrusage(resource.RUSAGE_CHILDREN)
    cpu = ((after.ru_utime - before.ru_utime) + (after.ru_stime - before.ru_stime)) * 1000
    return wall, cpu, len(done.stdout)


def raw(path, params):
    with socket.socket(socket.AF_UNIX) as conn:
        conn.connect(path)
        start = time.perf_counter()
        line = {"jsonrpc": "2.0", "id": 1, "method": "_acpmux/sessions", "params": params}
        conn.sendall((json.dumps(line) + "\n").encode())
        buf = bytearray()
        while not buf.endswith(b"\n"):
            chunk = conn.recv(1 << 20)
            if not chunk:
                break
            buf += chunk
        wall = (time.perf_counter() - start) * 1000
    result = json.loads(buf).get("result") or {}
    return wall, len(buf), len(result.get("sessions") or [])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--samples", type=int, default=20)
    parser.add_argument("--acpmux", default="acpmux")
    parser.add_argument("--socket", default=os.path.expanduser("~/.acpmux/acpmux.sock"))
    parser.add_argument("--json")
    args = parser.parse_args()
    samples = {label: [] for label, _ in COMMANDS + RAW}
    for _, argv in COMMANDS:
        run(args.acpmux, argv)
    for _ in range(args.samples):
        for label, argv in COMMANDS:
            samples[label].append(run(args.acpmux, argv))
        for label, params in RAW:
            samples[label].append(raw(args.socket, params))
    print("| command | stdout bytes | rows | median wall | p95 wall | median child CPU |")
    print("| --- | ---: | ---: | ---: | ---: | ---: |")
    out = {}
    for label, rows in samples.items():
        walls = [r[0] for r in rows]
        if label.startswith("raw"):
            size, count, cpu = rows[-1][1], rows[-1][2], None
        else:
            size, count, cpu = rows[-1][2], None, statistics.median(r[1] for r in rows)
        out[label] = {"bytes": size, "rows": count, "median_ms": statistics.median(walls),
                      "p95_ms": p95(walls), "child_cpu_ms": cpu}
        cpu_text = "-" if cpu is None else f"{cpu:.2f} ms"
        print(f"| {label} | {size:,} | {count if count is not None else '-'} | "
              f"{statistics.median(walls):.2f} ms | {p95(walls):.2f} ms | {cpu_text} |")
    if args.json:
        with open(args.json, "w") as f:
            json.dump(out, f, indent=2)


if __name__ == "__main__":
    main()
