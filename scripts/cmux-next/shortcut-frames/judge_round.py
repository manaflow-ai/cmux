#!/usr/bin/env python3
"""SHORTCUT FRAMES: judge every recording of one journey round (the HARNESS kit's output) with judge.py.

  judge_round.py --result RUN/<journey>/result.json --videos DIR --out DIR [--python PY]

DIR holds the kit's files per recording (<case>.mov, .mov.frames.json, .meta.json, .events.json). For each movie:
the presses whose key-down time (hid_log.py, from the result's debug.action_budget reads) falls inside its frames go
to judge.py with the movie's own display refresh (meta.json refresh_ms; KIT.md: a 60 Hz movie is no 120 Hz evidence,
and the report says which it was). Writes OUT/<case>.judge.json and OUT/<case>.hid.ndjson, prints one line per movie.
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import hid_log  # noqa: E402


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--result", required=True)
    p.add_argument("--videos", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--python", default=sys.executable)
    a = p.parse_args()
    os.makedirs(a.out, exist_ok=True)
    rows = [r for r in hid_log.presses(json.load(open(a.result, encoding="utf-8"))) if "t_ns" in r]
    status = 0
    for movie in sorted(glob.glob(os.path.join(a.videos, "*.mov"))):
        case = os.path.basename(movie)[:-4]
        frames_path = movie + ".frames.json"
        frames = json.load(open(frames_path, encoding="utf-8"))["frames"]
        times = [float(f[0]) for f in frames if f[2]]
        if not times:
            print(f"{case}: no frame in the movie")
            continue
        lo, hi = int(times[0] * 1e9), int(times[-1] * 1e9)
        mine = [r for r in rows if lo <= r["t_ns"] <= hi]
        if not mine:
            print(f"{case}: no press inside the movie")
            continue
        meta_path = os.path.join(a.videos, case + ".meta.json")
        meta = json.load(open(meta_path, encoding="utf-8")) if os.path.exists(meta_path) else {}
        refresh_ms = float(meta.get("refresh_ms") or 0) or 1000 / 120
        hid_path = os.path.join(a.out, case + ".hid.ndjson")
        with open(hid_path, "w", encoding="utf-8") as f:
            for r in mine:
                f.write(json.dumps(r) + "\n")
        out = os.path.join(a.out, case + ".judge.json")
        cmd = [a.python, os.path.join(HERE, "judge.py"), "--video", movie, "--frames", frames_path, "--hid", hid_path,
               "--refresh-hz", f"{1000 / refresh_ms:.3f}", "--out", out]
        if "anim-on" in case:
            cmd.append("--animated")
        done = subprocess.run(cmd, capture_output=True, text=True)
        if done.returncode not in (0, 1):
            print(f"{case}: judge failed: {done.stderr[-600:]}")
            status = 1
            continue
        report = json.load(open(out, encoding="utf-8"))
        report["refresh_ms"] = refresh_ms
        report["display"] = meta.get("display") or meta.get("display_check")
        json.dump(report, open(out, "w", encoding="utf-8"), indent=1)
        for name, s in report["summary"].items():
            print(f"{case}: {name}: presses {s['presses']}, refreshes p50/p95/max {s['refreshes_p50']}/"
                  f"{s['refreshes_p95']}/{s['refreshes_max']} at {1000 / refresh_ms:.1f} Hz, defects {s['defects'] or 'none'}")
    return status


if __name__ == "__main__":
    sys.exit(main())
