#!/usr/bin/env python3
"""Per-run verdicts of the RESIZE VIDEOS suite findings F1, F2, Z1, O1 (5/5 repeat rule).

  repeat_verdict.py RUN_OUT [RUN_OUT ...]

RUN_OUT: a run.py output folder (it holds <case>/video/<case>.{trace.json,events.json,mov.frames.json}).
For each case it prints one line per finding it applies to, REPRODUCED or CLEAN, with the numbers:
  F1  close-in-row, split-*:  a refresh lost (trace interval >= 12.5 ms) in the first 4 motion frames
  F2  close-*:                in the first motion frame two neighbours are more than 100 pt apart (a hole)
  Z1  zoom-*:                 a single trace frame of 33 ms or more during the motion
  O1  split-during-split:     after the second key, a pane overlaps a neighbour by more than 1 pt
Movie check (all cases): the largest gap between complete movie frames in the motion. T1 is judged by eye.
Standard library only.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import judge_trace  # noqa: E402


def keys(video, case):
    try:
        e = json.load(open(os.path.join(video, f"{case}.events.json")))
    except OSError:
        return []
    return [j["uptimeNanos"] / 1e9 for j in e.get("journal", []) if '"down"' in json.dumps(j)]


def judge_case(folder, case):
    video = os.path.join(folder, case, "video")
    tpath = os.path.join(video, f"{case}.trace.json")
    if not os.path.exists(tpath):
        return [f"{case}: NOT RUN (no trace)"]
    trace = judge_trace.load_trace(tpath)
    s, t0 = trace["samples"], float(trace.get("t0_s") or 0)
    frames = None
    fpath = os.path.join(video, f"{case}.mov.frames.json")
    if os.path.exists(fpath):
        frames = json.load(open(fpath)).get("frames")
    r = judge_trace.judge(trace, frames)
    if not r["motion"]:
        return [f"{case}: NO MOTION (set-up?)"]
    f0, f1 = r["motion"]["first_frame"], r["motion"]["last_frame"]
    iv = [(i, float(s[i]["t"]) - float(s[i - 1]["t"])) for i in range(f0, f1 + 1)]
    out = []
    movie = ""
    if frames:
        lo, hi = t0 + float(s[f0 - 1]["t"]) / 1000, t0 + float(s[f1]["t"]) / 1000
        comp = [x[0] for x in frames if x[1] == "complete" and lo - 0.02 <= x[0] <= hi + 0.02]
        gaps = [b - a for a, b in zip(comp, comp[1:])]
        movie = f"; movie max gap {max(gaps) * 1000:.1f} ms" if gaps else "; movie: no frames in motion"
    if "close" in case or "split" in case:
        early = [(i, round(x, 2)) for i, x in iv[:4] if x >= 12.5]
        out.append(f"{case} F1 {'REPRODUCED' if early else 'CLEAN'} first 4 intervals {[round(x, 2) for _, x in iv[:4]]}{movie}")
    if "close" in case:
        holes = [d for d in r["defects"] if d["kind"] == "gap" and d["frame"] == f0]
        size = max((float(d["what"].split(":")[1].split("pt")[0]) for d in holes), default=0)
        out.append(f"{case} F2 {'REPRODUCED' if size > 100 else 'CLEAN'} hole {size:.1f} pt in trace frame {f0}")
    if "zoom" in case:
        big = [(i, round(x, 2)) for i, x in iv if x >= 33]
        out.append(f"{case} Z1 {'REPRODUCED' if big else 'CLEAN'} frames >= 33 ms {big}{movie}")
    if "split-during-split" in case:
        ks = keys(video, case)
        t2 = (ks[1] - t0) * 1000 if len(ks) > 1 else None
        ov = [d for d in r["defects"] if d["kind"] == "overlap" and t2 is not None and float(d["t_ms"]) >= t2]
        worst = max((abs(float(d["what"].split(":")[1].split("pt")[0])) for d in ov), default=0)
        out.append(f"{case} O1 {'REPRODUCED' if worst > 1 else 'CLEAN'} overlap after 2nd key: {len(ov)} frames, worst {worst:.1f} pt")
    return out


def main():
    for folder in sys.argv[1:]:
        for case in sorted(os.listdir(folder)):
            if os.path.isdir(os.path.join(folder, case, "video")):
                for line in judge_case(folder, case):
                    print(f"{os.path.basename(folder.rstrip('/'))}  {line}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
