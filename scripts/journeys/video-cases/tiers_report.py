#!/usr/bin/env python3
"""HARNESS CORES: the split key turn and the main thread's core tiers, per case, from the app's own clock (no profiler).

  tiers_report.py CASE_DIR [CASE_DIR ...] [--json OUT]

CASE_DIR: one journey's output with diag-closetrace.json (debug.motion trace: display-link ticks and the input
journal) and diag-tiers.json (ext_tiers: the main thread's cumulative CPU ms and cycles per core tier, CLOCK_UPTIME_RAW).
Per case:
  - key: the first non-modifier key-down in the app's journal; first motion: the first trace tick after it whose pane
    rects changed; landing: the last such tick + 1 refresh; refreshes lost: as xtp_align.py (each interval of the
    motion counts round(interval / refresh) - 1).
  - key turn: main-thread CPU ms per tier from the key to the first motion tick; motion: from the key to the landing.
  - stall: the 60 ms debug.stall busy loop before the key (the 70 ms sampler window with the most main-thread CPU in
    the 1.5 s before the key): CPU ms per tier.
  - GHz: cycles / CPU time per tier in the motion window (the tier's clock while the main thread ran there).
Then, per arm (the last dash-separated part of the case id: xtp or noxtp), p50 / p95 / max of the key turn wall time (key to first motion),
the refreshes lost and the share of main-thread CPU on each tier. Standard library only.
"""
import argparse
import json
import os
import statistics
from collections import defaultdict


def at(rows, t_ns):
    """The sampler row at or just before t_ns (cumulative counters)."""
    best = rows[0]
    for r in rows:
        if r[0] > t_ns:
            break
        best = r
    return best


def delta(rows, a_ns, b_ns, n):
    ra, rb = at(rows, a_ns), at(rows, b_ns)
    ms = [rb[1 + i] - ra[1 + i] for i in range(n)]
    cyc = [rb[1 + n + i] - ra[1 + n + i] for i in range(n)]
    return ms, cyc


def case(d):
    trace = json.load(open(os.path.join(d, "diag-closetrace.json")))
    tiers = json.load(open(os.path.join(d, "diag-tiers.json")))
    s, t0 = trace["samples"], float(trace["t0_s"])
    refresh = float(trace.get("refresh_ms") or 8.33) / 1000
    ticks = [t0 + float(x["t"]) / 1000 for x in s]
    keys = []
    for e in trace.get("journal") or []:
        k = ((e.get("kind") or {}).get("key") or {}).get("_0") or {}
        if k.get("phase") == "down" and k.get("keyClass") != "modifier" and e.get("uptimeNanos"):
            keys.append(e["uptimeNanos"] / 1e9)
    if not keys:
        return {"case": d, "error": "no key-down in the journal"}
    k = sorted(keys)[0]
    moving = [i for i in range(1, len(s)) if s[i].get("panes") != s[i - 1].get("panes") and ticks[i] >= k]
    if not moving:
        return {"case": d, "error": "no motion after the key"}
    first, land = ticks[moving[0]], ticks[moving[-1]] + refresh
    per = [ticks[i] - ticks[i - 1] for i in range(moving[0], moving[-1] + 1)]
    lost = sum(max(0, round(iv / refresh) - 1) for iv in per)
    rows, levels = tiers["rows"], tiers["levels"]
    n = len(levels)
    ns = lambda sec: int(sec * 1e9)
    if not (rows[0][0] < ns(k) and rows[-1][0] > ns(land)):
        return {"case": d, "error": "the tier sampler does not cover the key to the landing"}
    turn_ms, _ = delta(rows, ns(k), ns(first), n)
    mot_ms, mot_cyc = delta(rows, ns(k), ns(land), n)
    # the stall: the 70 ms window with the most main CPU in the 1.5 s before the key
    best, best_ms = None, -1.0
    for r in rows:
        if not (ns(k - 1.5) <= r[0] <= ns(k) - ns(0.07)):
            continue
        ms, _ = delta(rows, r[0], r[0] + ns(0.07), n)
        if sum(ms) > best_ms:
            best, best_ms = ms, sum(ms)
    ghz = [round(mot_cyc[i] / (mot_ms[i] * 1e6), 2) if mot_ms[i] > 0.2 else None for i in range(n)]
    return {"case": d, "levels": levels, "key_turn_wall_ms": round((first - k) * 1000, 2),
            "landing_ms": round((land - k) * 1000, 1), "refreshes_lost": lost,
            "key_turn_cpu_ms": [round(x, 2) for x in turn_ms], "motion_cpu_ms": [round(x, 2) for x in mot_ms],
            "stall_cpu_ms": [round(x, 2) for x in best] if best else None, "motion_ghz": ghz,
            "sampler_interval_ms": round((rows[-1][0] - rows[0][0]) / 1e6 / max(1, len(rows) - 1), 2),
            "ps_top": tiers.get("ps", [])[:6]}


def pct(v, p):
    v = sorted(v)
    return v[min(len(v) - 1, max(0, int(round(p * len(v) + 0.5)) - 1))]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("dirs", nargs="+")
    ap.add_argument("--json")
    o = ap.parse_args()
    out = [case(d) for d in o.dirs]
    arms = defaultdict(list)
    for c in out:
        name = os.path.basename(os.path.normpath(c["case"]))
        if "error" in c:
            print(f"{name}: {c['error']}")
            continue
        lv = [x[0] for x in c["levels"]]
        fmt = lambda v: " ".join(f"{a} {b:.1f}" for a, b in zip(lv, v))
        print(f"{name}: key turn {c['key_turn_wall_ms']} ms wall (CPU {fmt(c['key_turn_cpu_ms'])}), lands +{c['landing_ms']} ms, "
              f"lost {c['refreshes_lost']}; motion CPU {fmt(c['motion_cpu_ms'])}; stall {fmt(c['stall_cpu_ms'] or [])}; "
              f"GHz {c['motion_ghz']}")
        arms[name.rsplit("-", 1)[-1]].append(c)
    summary = {}
    for arm, cs in sorted(arms.items()):
        turn = [c["key_turn_wall_ms"] for c in cs]
        lost = [c["refreshes_lost"] for c in cs]
        n = len(cs[0]["levels"])
        tot = [sum(c["motion_cpu_ms"][i] for c in cs) for i in range(n)]
        turn_tot = [sum(c["key_turn_cpu_ms"][i] for c in cs) for i in range(n)]
        stall_tot = [sum((c["stall_cpu_ms"] or [0] * n)[i] for c in cs) for i in range(n)]
        share = lambda v: {cs[0]["levels"][i]: round(100 * v[i] / max(1e-9, sum(v)), 1) for i in range(n)}
        summary[arm] = {"runs": len(cs), "key_turn_ms": {"p50": statistics.median(turn), "p95": pct(turn, 0.95), "max": max(turn)},
                        "refreshes_lost": {"p50": statistics.median(lost), "p95": pct(lost, 0.95), "max": max(lost)},
                        "motion_cpu_share_pct": share(tot), "key_turn_cpu_share_pct": share(turn_tot),
                        "stall_cpu_share_pct": share(stall_tot)}
        print(f"\n{arm} ({len(cs)} runs): key turn p50 {summary[arm]['key_turn_ms']['p50']} p95 {summary[arm]['key_turn_ms']['p95']} "
              f"max {summary[arm]['key_turn_ms']['max']} ms; refreshes lost p50 {summary[arm]['refreshes_lost']['p50']} "
              f"max {summary[arm]['refreshes_lost']['max']}\n  main CPU share by tier: key turn {summary[arm]['key_turn_cpu_share_pct']}, "
              f"whole motion {summary[arm]['motion_cpu_share_pct']}, 60 ms stall {summary[arm]['stall_cpu_share_pct']}")
    if o.json:
        json.dump({"cases": out, "arms": summary}, open(o.json, "w"), indent=1)


if __name__ == "__main__":
    main()
