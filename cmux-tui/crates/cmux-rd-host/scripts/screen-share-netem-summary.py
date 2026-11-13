#!/usr/bin/env python3
"""Summarizes screen-share-netem.py JSON lines into one row per (label, row)."""
import json, statistics, sys

def pct(xs, q):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(round(q / 100 * (len(xs) - 1))))] if xs else None

rows = {}
for path in sys.argv[1:]:
    for line in open(path):
        if not line.startswith("{"):
            continue
        d = json.loads(line)
        row = d.get("row", "")
        if not row and d.get("drop_s") is not None:
            row = f"drop-{d['drop_s']:g}s"
        rows.setdefault((d.get("label", ""), row), []).append(d)
fmt = lambda v: "-" if v is None else f"{v:.0f}"
print("| build | row | connected | recovered | keys arrived | connect p50/p95 ms | first frame p50/p95 ms | input-to-photon p50/p95 ms | stall after full drop p50/max ms | fps | Mbit/s |")
print("|---|---|---|---|---|---|---|---|---|---|---|")
for (label, row), ds in sorted(rows.items()):
    conn = [d["connect_ms"] for d in ds if d.get("connect_ms") is not None]
    ff = [d["first_frame_ms"] for d in ds if d.get("first_frame_ms") is not None]
    g50 = [d["g2g_ms"]["p50"] for d in ds if d.get("g2g_ms")]
    g95 = [d["g2g_ms"]["p95"] for d in ds if d.get("g2g_ms")]
    n_keys = sum(d["g2g_ms"]["n"] for d in ds if d.get("g2g_ms"))
    lost = sum(d.get("lost") or 0 for d in ds)
    recovered = sum(1 for d in ds if d.get("recovered_after_drop", d.get("ok", False)))
    stalls = [s for d in ds for s in (d.get("stalls_ms") or [])]
    fps = [d["frames_per_s"] for d in ds if d.get("frames_per_s") is not None]
    mbit = [d["mbit_per_s"] for d in ds if d.get("mbit_per_s") is not None]
    print(f"| {label} | {row} | {len(conn)}/{len(ds)} | {recovered}/{len(ds)} | {n_keys}/{n_keys + lost} | {fmt(pct(conn,50))}/{fmt(pct(conn,95))} "
          f"| {fmt(pct(ff,50))}/{fmt(pct(ff,95))} | {fmt(statistics.median(g50) if g50 else None)}/{fmt(pct(g95,95))} "
          f"| {fmt(pct(stalls,50))}/{fmt(max(stalls) if stalls else None)} | {fmt(statistics.median(fps) if fps else None)} "
          f"| {statistics.median(mbit):.2f} |" if mbit else "|")
