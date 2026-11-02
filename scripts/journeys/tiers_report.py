#!/usr/bin/env python3
"""Each measured turn of a round with the core tier it started on (HARNESS CORES, STATUS 7767). Standard library only.

  tiers_report.py CASE_DIR [CASE_DIR ...] [--json OUT]

On the M6 minis a turn whose main thread starts on the Efficiency cores costs about 2x one that starts on Super, so
compare frame numbers per start tier. A CASE_DIR is one journey's output, in either layout:
  - a film: video/<name>.trace.json, <name>.events.json and <name>.tiers.json (ext_video video_start .. video_stop);
  - no film: diag-closetrace.json (the debug.motion trace with the input journal) and diag-tiers.json (tiers_start).
Per key-down in the app's input journal:
  first motion: the first trace tick at or after the key whose pane rects changed (before the next key);
  landing: the last such tick + 1 refresh; refreshes lost: each interval of the motion counts round(interval /
  refresh) - 1 (as xtp_align.py);
  start tier, ms to Super and E/P CPU ms before Super: ext_tiers.turn_tiers (the first 100 ms after the key);
  key turn CPU ms per tier: from the key to the first motion tick.
Then per arm (the last dash-separated part of the case folder name, e.g. xtp / noxtp; one arm when names do not
differ) and per start tier: p50 / p95 / max of key to first motion and of the refreshes lost.
"""
import argparse
import glob
import json
import os
import statistics
import sys
from collections import defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ext_tiers  # noqa: E402


def key_downs(journal):
    keys = []
    for e in journal or []:
        k = ((e.get("kind") or {}).get("key") or {}).get("_0") or {}
        if k.get("phase") == "down" and k.get("keyClass") != "modifier" and e.get("uptimeNanos"):
            keys.append(e["uptimeNanos"] / 1e9)
    return sorted(set(keys))


def recordings(d):
    """(label, trace, journal, tiers, refresh_ms) for each recording of case folder D."""
    out = []
    if os.path.exists(os.path.join(d, "diag-closetrace.json")) and os.path.exists(os.path.join(d, "diag-tiers.json")):
        trace = json.load(open(os.path.join(d, "diag-closetrace.json")))
        out.append(("", trace, trace.get("journal"), json.load(open(os.path.join(d, "diag-tiers.json"))), trace.get("refresh_ms")))
    for tiers_path in sorted(glob.glob(os.path.join(d, "video", "*.tiers.json"))):
        base = tiers_path[: -len(".tiers.json")]
        if not (os.path.exists(base + ".trace.json") and os.path.exists(base + ".events.json")):
            continue
        trace = json.load(open(base + ".trace.json"))
        meta = json.load(open(base + ".meta.json")) if os.path.exists(base + ".meta.json") else {}
        out.append((os.path.basename(base), trace, json.load(open(base + ".events.json")).get("journal"),
                    json.load(open(tiers_path)), meta.get("refresh_ms") or trace.get("refresh_ms")))
    return out


def turns(trace, journal, tiers, refresh_ms):
    s, t0 = trace.get("samples") or [], float(trace.get("t0_s") or 0)
    refresh = float(refresh_ms or 8.33) / 1000
    ticks = [t0 + float(x["t"]) / 1000 for x in s]
    keys = key_downs(journal)
    moving = [i for i in range(1, len(s)) if s[i].get("panes") != s[i - 1].get("panes")]
    levels, rows = tiers["levels"], tiers["rows"]
    out = []
    for n, (k, tier) in enumerate(zip(keys, ext_tiers.turn_tiers(tiers, keys))):
        nxt = keys[n + 1] if n + 1 < len(keys) else float("inf")
        mv = [i for i in moving if k <= ticks[i] < nxt]
        turn = {"key_s": round(k, 6), "start_tier": tier["start_tier"], "ms_to_super": tier["ms_to_super"],
                "e_cpu_ms_before_super": tier["e_cpu_ms_before_super"], "tier_error": tier.get("error")}
        if not mv:
            turn["error"] = "no motion after this key"
            out.append(turn)
            continue
        first = ticks[mv[0]]
        per = [ticks[i] - ticks[i - 1] for i in range(mv[0], mv[-1] + 1)]
        turn.update({"first_motion_ms": round((first - k) * 1000, 2), "landing_ms": round((ticks[mv[-1]] + refresh - k) * 1000, 1),
                     "refreshes_lost": sum(max(0, round(iv / refresh) - 1) for iv in per)})
        a, b = int(k * 1e9), int(first * 1e9)
        before = [r for r in rows if r[0] <= a]
        upto = [r for r in rows if r[0] <= b]
        if before and upto:
            turn["key_turn_cpu_ms"] = {levels[i]: round(upto[-1][1 + i] - before[-1][1 + i], 2) for i in range(len(levels))}
        out.append(turn)
    return out


def pct(values, p):
    v = sorted(values)
    return v[min(len(v) - 1, max(0, int(round(p * len(v) + 0.5)) - 1))]


def stats(values):
    return {"n": len(values), "p50": round(statistics.median(values), 2), "p95": round(pct(values, 0.95), 2), "max": round(max(values), 2)}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("dirs", nargs="+")
    ap.add_argument("--json")
    o = ap.parse_args()
    names = [os.path.basename(os.path.normpath(d)) for d in o.dirs]
    arm_of = (lambda name: name.rsplit("-", 1)[-1]) if len({n.rsplit("-", 1)[-1] for n in names}) > 1 else (lambda name: "all")
    cases, groups = [], defaultdict(list)
    for d, name in zip(o.dirs, names):
        recs = recordings(d)
        if not recs:
            print(f"{name}: no trace with a tier file")
            continue
        for label, trace, journal, tiers, refresh in recs:
            for t in turns(trace, journal, tiers, refresh):
                t.update({"case": name, "recording": label})
                cases.append(t)
                where = f"{name}{'/' + label if label else ''}"
                if "error" in t:
                    print(f"{where} key {t['key_s']}: {t['error']}")
                    continue
                print(f"{where} key {t['key_s']}: start {t['start_tier']}, Super after {t['ms_to_super']} ms "
                      f"({t['e_cpu_ms_before_super']} CPU ms before it); first motion +{t['first_motion_ms']} ms, "
                      f"lands +{t['landing_ms']} ms, lost {t['refreshes_lost']}; key turn CPU {t.get('key_turn_cpu_ms')}")
                groups[(arm_of(name), "all")].append(t)
                groups[(arm_of(name), t["start_tier"] or "idle")].append(t)
    summary = {}
    for (arm, tier), ts in sorted(groups.items()):
        summary[f"{arm}/{tier}"] = {"first_motion_ms": stats([t["first_motion_ms"] for t in ts]),
                                    "refreshes_lost": stats([t["refreshes_lost"] for t in ts])}
        f, lost = summary[f"{arm}/{tier}"]["first_motion_ms"], summary[f"{arm}/{tier}"]["refreshes_lost"]
        print(f"{arm}, start tier {tier}: {f['n']} turns; first motion p50 {f['p50']} p95 {f['p95']} max {f['max']} ms; "
              f"refreshes lost p50 {lost['p50']} p95 {lost['p95']} max {lost['max']}")
    if o.json:
        json.dump({"turns": cases, "groups": summary}, open(o.json, "w"), indent=1)


if __name__ == "__main__":
    main()
