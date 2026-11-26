#!/usr/bin/env python3
"""launch-matrix.sh --growth's owner summary: which process of the app's tree spends the idle CPU.

usage: launch-matrix-growth.py GROWTH_LOG [--burst PCT]

Reads the LM-GROWTH lines (one a minute; each names its top spenders in "top") and prints:
  LM-GROWTH-BURST  one per burst minute (the tree at >= PCT % of a core, default 50): the minute, the tree's CPU %,
                   the top process and its share of the minute, and that process's top thread
  LM-GROWTH-OWNER  one per process name, most CPU first: CPU s over the run, CPU s in burst minutes, the minutes it was
                   the top spender in a burst, MB written
  LM-GROWTH-VERDICT  the process that spent the most CPU in burst minutes, and its share of all burst CPU
The CPU s per process is the sum of its cpu_pct over minutes (cpu_pct x 60 s / 100), so a process outside a minute's
top N is not counted that minute (raise LM_GROWTH_TOP to count more).
"""
from __future__ import annotations

import json
import sys


def rows(lines):
    for line in lines:
        if not line.startswith("LM-GROWTH "):
            continue
        try:
            row = json.loads(line[len("LM-GROWTH "):])
        except ValueError:
            continue
        if isinstance(row.get("minute"), int) and row["minute"] > 0 and "cpu_pct" in row:
            yield row


def summarize(lines, burst_pct=50.0):
    owners: dict[str, dict] = {}
    bursts = []
    for row in rows(lines):
        burst = row["cpu_pct"] >= burst_pct
        top = row.get("top") or []
        for proc in top:
            o = owners.setdefault(proc["name"], {"name": proc["name"], "cpu_s": 0.0, "burst_cpu_s": 0.0,
                                                 "burst_top_minutes": [], "written_mb": 0.0})
            cpu_s = proc.get("cpu_pct", 0.0) * 0.6
            o["cpu_s"] += cpu_s
            o["written_mb"] += proc.get("written_mb", 0.0)
            if burst:
                o["burst_cpu_s"] += cpu_s
        if burst and top:
            lead = top[0]
            owners[lead["name"]]["burst_top_minutes"].append(row["minute"])
            threads = lead.get("threads") or []
            bursts.append({"minute": row["minute"], "tree_cpu_pct": row["cpu_pct"], "process": lead["name"],
                           "pid": lead.get("pid"), "process_cpu_pct": lead.get("cpu_pct"),
                           "share": round(lead.get("cpu_pct", 0.0) / row["cpu_pct"], 3) if row["cpu_pct"] else None,
                           "thread": threads[0]["name"] if threads else None,
                           "thread_cpu_pct": threads[0]["cpu_pct"] if threads else None})
    ranked = sorted(owners.values(), key=lambda o: (-o["cpu_s"], o["name"]))
    for o in ranked:
        o["cpu_s"] = round(o["cpu_s"], 1)
        o["burst_cpu_s"] = round(o["burst_cpu_s"], 1)
        o["written_mb"] = round(o["written_mb"], 1)
    verdict = None
    burst_total = sum(o["burst_cpu_s"] for o in ranked)
    if burst_total > 0:
        lead = max(ranked, key=lambda o: o["burst_cpu_s"])
        verdict = {"process": lead["name"], "burst_cpu_s": lead["burst_cpu_s"],
                   "share_of_burst_cpu": round(lead["burst_cpu_s"] / burst_total, 3), "burst_minutes": len(bursts)}
    return bursts, ranked, verdict


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__.strip())
        return 2
    burst = 50.0
    if "--burst" in argv:
        burst = float(argv[argv.index("--burst") + 1])
    with open(argv[0], encoding="utf-8", errors="replace") as f:
        bursts, owners, verdict = summarize(f, burst)
    for b in bursts:
        print("LM-GROWTH-BURST", json.dumps(b, sort_keys=True))
    for o in owners:
        print("LM-GROWTH-OWNER", json.dumps(o, sort_keys=True))
    print("LM-GROWTH-VERDICT", json.dumps(verdict or {"process": None, "burst_minutes": 0}, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
