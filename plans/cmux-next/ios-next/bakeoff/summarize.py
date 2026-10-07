#!/usr/bin/env python3
"""Prints the d2-bakeoff.md tables from results/*.json (median of repeats)."""
import glob, json, os, re, statistics, sys

here = os.path.dirname(os.path.abspath(__file__))
results = sys.argv[1] if len(sys.argv) > 1 else os.path.join(here, "results")

def get(r, *path):
    for p in path:
        if r is None: return None
        r = r.get(p)
    return r

def med(rs, *path):
    vals = [v for v in (get(r, *path) for r in rs) if v is not None]
    return statistics.median(vals) if vals else None

def fmt(v, d=1):
    return "n/a" if v is None else f"{v:.{d}f}"

groups = {}
for f in sorted(glob.glob(os.path.join(results, "*.json"))):
    name = re.sub(r"-r\d+$", "", os.path.basename(f)[:-5])
    groups.setdefault(name, []).append(json.load(open(f)))

print("| Rig | runs | first byte p50 ms | RTT p50/p99 ms | under bulk p50/p99 ms | flood Mbit/s (CPU ms/MiB) | bulk Mbit/s (CPU ms/MiB) | raw Mbit/s | reconnect ms | roam ms (session kept) | max RSS MiB |")
print("| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |")
for name, rs in groups.items():
    kept = [not any(get(r, "roam", "sessionReconnected") or [True]) for r in rs if get(r, "roam")]
    errors = sum(len(r["errors"]) for r in rs)
    print(f"| {name} | {len(rs)}{' (' + str(errors) + ' err)' if errors else ''} | {fmt(med(rs,'coldConnect','firstByte','p50'))} "
          f"| {fmt(med(rs,'rttIdle','p50'),2)}/{fmt(med(rs,'rttIdle','p99'),2)} "
          f"| {fmt(med(rs,'rttUnderBulk','rtt','p50'))}/{fmt(med(rs,'rttUnderBulk','rtt','p99'))} "
          f"| {fmt(med(rs,'terminalFlood','megabitsPerSecond'),0)} ({fmt(med(rs,'terminalFlood','cpuMillisecondsPerMiB'),0)}) "
          f"| {fmt(med(rs,'bulkFile','megabitsPerSecond'),0)} ({fmt(med(rs,'bulkFile','cpuMillisecondsPerMiB'),0)}) "
          f"| {fmt(med(rs,'rawTransport','megabitsPerSecond'),0)} "
          f"| {fmt(med(rs,'reconnect','recovered','p50'))} | {fmt(med(rs,'roam','recovered','p50'))} ({'yes' if kept and all(kept) else 'no' if kept else 'n/a'}) "
          f"| {fmt(med(rs,'memory','finalMaxResidentMiB'),0)} |")
