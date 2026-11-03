#!/usr/bin/env python3
"""Before/after table of xtp_align.py reports (RESIZE VIDEOS suite).

  xtp_table.py LABEL=RUNS_GLOB [LABEL=RUNS_GLOB ...]

Each RUNS_GLOB matches run folders; each case folder there needs xtp-align.json (xtp_align.py --json). Prints per
label and motion (close; zoom; unzoom): runs, refreshes lost (each run), main-thread Running ms (median, max), the key
turn's Running ms (median), the first 2 motion-frame intervals (median), and the first-frame Running ms (median).
"""
import glob
import json
import os
import statistics
import sys


def motions(report, case):
    out = []
    names = ["close"] if "close" in case else ["zoom", "unzoom"]
    for name, m in zip(names, [m for m in report["motions"] if "error" not in m]):
        out.append((name, m))
    return out


def main():
    rows = {}
    for arg in sys.argv[1:]:
        label, pattern = arg.split("=", 1)
        for f in sorted(glob.glob(os.path.join(pattern, "*", "xtp-align.json"))):
            rep = json.load(open(f))
            if not rep.get("valid"):
                continue
            case = os.path.basename(os.path.dirname(f))
            for name, m in motions(rep, case):
                rows.setdefault((label, name), []).append(m)
    print(f"{'build':22} {'motion':7} {'runs':>4}  {'lost per run':14} {'main ms med/max':16} {'key turn med':12} {'1st,2nd interval':18} {'1st frame ms'}")
    for (label, name), ms in rows.items():
        lost = [m["refreshes_lost"] for m in ms]
        run = [m["main_running_ms"] for m in ms]
        turn = [m["key_turn_running_ms"] for m in ms]
        iv1 = [m["per_interval_ms_and_running_ms"][0][0] for m in ms]
        iv2 = [m["per_interval_ms_and_running_ms"][1][0] for m in ms if len(m["per_interval_ms_and_running_ms"]) > 1]
        f1 = [m["per_interval_ms_and_running_ms"][0][1] for m in ms]
        print(f"{label:22} {name:7} {len(ms):4d}  {str(lost):14} {statistics.median(run):6.0f} / {max(run):<6d}  {statistics.median(turn):8.0f}     "
              f"{statistics.median(iv1):6.2f}, {statistics.median(iv2) if iv2 else 0:6.2f}     {statistics.median(f1):5.0f}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
