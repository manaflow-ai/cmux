#!/usr/bin/env python3
"""Main-thread time per close / zoom from an xctrace Time Profiler, on the APP's clock (RESIZE VIDEOS suite).

  xtp_align.py CASE_DIR [--json OUT]

CASE_DIR: one journey's output (diag-xtp.txt = the time-profile export, diag-closetrace.json = debug.motion
trace_stop, result.json). No Python clock is used: every time comes from the app or from xctrace.
  1. Coarse offset. The case calls debug.stall (60 ms busy loop on the main thread) before the key. In the display-link
     trace that is the one gap of 50 ms or more before the motion (ticks h_a, h_b); in the profile it is the run of
     main-thread samples whose stack has the stall's ContinuousClock loop in AppControl (start p_s). The stall began
     in [h_a, h_b - 60 ms], so offset = p_s - stall start lies in a known interval.
  2. Fine offset. Inside that interval, the offset that puts the most profile samples of the trace's own per-tick
     sampler (MotionFrameTrace.tick) within 0..2 ms after a trace tick. Resolution 0.1 ms.
  3. Key-down times from the app's input journal (result.json: the hid_key step's events, else video events).
  4. Per key: window = [key-down, landing + 1 refresh] (landing = the last trace tick whose pane rects changed in this
     motion). Main-thread Running ms in the window, per display interval, and the top frames.
  Check: the profile's first main-thread sample (on the app clock) must come before the first key (else NOT VALID).
Standard library only.
"""
import argparse
import json
import os
import sys
from collections import Counter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import xtp_frames  # noqa: E402

KEYS = ("CmuxNext", "Terminal", "Layout", "Pane", "Screen", "Motion", "FrameScheduler", "ghostty", "Action", "Close",
        "Zoom", "Retire", "Host", "CA::Transaction", "layoutSubtree", "CA::Context")


def stall_run(samples):
    # debug.stall's busy loop: ContinuousClock.now, which an optimized build shows as swift_get_time /
    # clock_gettime / mach_continuous_time (the AppControl closure is not on every sample's stack).
    def is_stall(fr):
        return any(k in f for f in fr for k in ("ContinuousClock", "swift_get_time", "mach_continuous_time"))
    hit = [x for x in samples if x["state"] == "Running" and is_stall(x["frames"])]
    if not hit:
        return None
    hit.sort(key=lambda x: x["t_ms"])
    # the longest run of hits with gaps under 5 ms
    best, cur = [], [hit[0]]
    for a, b in zip(hit, hit[1:]):
        if b["t_ms"] - a["t_ms"] < 2.5:
            cur.append(b)
        else:
            best = max(best, cur, key=len)
            cur = [b]
    best = max(best, cur, key=len)
    return best[0]["t_ms"], best[-1]["t_ms"], len(best)


def journal_keys(trace):
    """Key-downs of letter or named keys (not modifier flags) from the app's input journal in the trace file."""
    keys = []
    for e in trace.get("journal") or []:
        k = ((e.get("kind") or {}).get("key") or {}).get("_0") or {}
        if k.get("phase") == "down" and k.get("keyClass") != "modifier" and e.get("uptimeNanos"):
            keys.append(e["uptimeNanos"] / 1e9)
    return sorted(set(keys))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("case_dir")
    ap.add_argument("--keys", help="key-down host times (s), comma separated, if result.json has none")
    ap.add_argument("--json")
    opts = ap.parse_args()
    d = opts.case_dir
    trace = json.load(open(os.path.join(d, "diag-closetrace.json")))
    s, t0 = trace["samples"], float(trace["t0_s"])
    refresh = float(trace.get("refresh_ms") or 8.33) / 1000
    ticks = [t0 + float(x["t"]) / 1000 for x in s]
    samples = [x for x in xtp_frames.load_samples(os.path.join(d, "diag-xtp.txt")) if x["thread"].startswith("Main Thread")]
    run = stall_run(samples)
    if not run:
        sys.exit("NOT VALID: no debug.stall run in the profile")
    p_s, p_e, n_s = run
    gaps = [(ticks[i - 1], ticks[i]) for i in range(1, len(ticks)) if ticks[i] - ticks[i - 1] >= 0.050]
    if not gaps:
        sys.exit("NOT VALID: no 50 ms gap in the display-link trace")
    h_a, h_b = gaps[0]
    lo, hi = p_s / 1000 - (h_b - 0.060), p_s / 1000 - h_a  # offset (s) = profile time - host time
    if hi < lo:
        lo, hi = hi, lo
    tick_samples = [x["t_ms"] / 1000 for x in samples if any("MotionFrameTrace.tick" in f for f in x["frames"])]
    best, best_score, o = None, -1, lo
    while o <= hi + 1e-9:
        score = 0
        j = 0
        for p in tick_samples:
            h = p - o
            # nearest tick at or before h
            while j + 1 < len(ticks) and ticks[j + 1] <= h:
                j += 1
            if 0 <= h - ticks[j] <= 0.002:
                score += 1
        if score > best_score:
            best, best_score = o, score
        o += 0.0001
    off = best
    keys = [float(k) for k in opts.keys.split(",")] if opts.keys else journal_keys(trace)
    if not keys:
        sys.exit("NOT VALID: no key-down in the app's input journal (diag-closetrace.json journal)")
    first_host = samples[0]["t_ms"] / 1000 - off
    report = {"offset_s": round(off, 6), "coarse_interval_ms": round((hi - lo) * 1000, 2), "fine_matches": best_score,
              "tick_samples": len(tick_samples), "stall_samples": n_s,
              "profile_first_sample_before_key_s": round(keys[0] - first_host, 3),
              "valid": first_host < keys[0], "motions": []}
    moving = [i for i in range(1, len(s)) if s[i].get("panes") != s[i - 1].get("panes")]
    for n, k in enumerate(keys):
        nxt = keys[n + 1] if n + 1 < len(keys) else float("inf")
        mv = [i for i in moving if k <= ticks[i] < nxt]
        if not mv:
            report["motions"].append({"key_s": k, "error": "no motion after this key"})
            continue
        land = ticks[mv[-1]] + refresh
        win = [x for x in samples if k <= x["t_ms"] / 1000 - off < land]
        run_ms = sum(1 for x in win if x["state"] == "Running")
        per = []
        for i in range(mv[0], mv[-1] + 1):
            a, b = ticks[i - 1], ticks[i]
            ms = sum(1 for x in win if x["state"] == "Running" and a <= x["t_ms"] / 1000 - off < b)
            per.append([round((b - a) * 1000, 2), ms])
        # the turn from the key to the first motion tick
        turn = sum(1 for x in win if x["state"] == "Running" and x["t_ms"] / 1000 - off < ticks[mv[0]])
        c = Counter()
        for x in win:
            if x["state"] == "Running":
                for f in set(xtp_frames.interesting(x["frames"])):
                    if any(kk in f for kk in KEYS):
                        c[f] += 1
        lost = sum(max(0, round(iv / (refresh * 1000)) - 1) for iv, _ in per)
        report["motions"].append({"key_s": round(k, 6), "first_motion_ms_after_key": round((ticks[mv[0]] - k) * 1000, 2),
                                  "landing_ms_after_key": round((land - k) * 1000, 2), "frames": len(per),
                                  "main_running_ms": run_ms, "key_turn_running_ms": turn, "refreshes_lost": lost,
                                  "per_interval_ms_and_running_ms": per, "top": c.most_common(12)})
    if opts.json:
        json.dump(report, open(opts.json, "w"), indent=1)
    print(f"offset {report['offset_s']} s (coarse {report['coarse_interval_ms']} ms wide, {best_score}/{len(tick_samples)} tick samples "
          f"matched), stall {n_s} samples; profile first sample {report['profile_first_sample_before_key_s']} s before the key: "
          f"{'VALID' if report['valid'] else 'NOT VALID'}")
    for m in report["motions"]:
        if "error" in m:
            print("  ", m)
            continue
        print(f"  key {m['key_s']}: first motion +{m['first_motion_ms_after_key']} ms, lands +{m['landing_ms_after_key']} ms, "
              f"{m['frames']} frames, refreshes lost {m['refreshes_lost']}; main thread Running {m['main_running_ms']} ms "
              f"(key turn {m['key_turn_running_ms']} ms)")
        print("     first 6 intervals [interval ms, running ms]:", m["per_interval_ms_and_running_ms"][:6])
        print("     top:", [(f[:70], n) for f, n in m["top"][:6]])
    return 0 if report["valid"] else 1


if __name__ == "__main__":
    sys.exit(main())
