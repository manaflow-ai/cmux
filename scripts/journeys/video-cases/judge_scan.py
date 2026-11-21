#!/usr/bin/env python3
"""Pixel checks of one layout motion from the recorder's exact scan lines (RESIZE VIDEOS suite).

  judge_scan.py MOVIE.mov.scan --trace TRACE.json [--row K] [--json OUT.json] [--idle]

MOVIE.mov.scan: `debug.motion` record_*'s scan file (a JSON header line, then per complete frame a float64-le
host time, each kept row, each kept column, BGRA). TRACE.json: the `trace_stop` reply of the same run (pane rects
per display tick, `t0_s` its first tick's host time).

For each recorded frame inside the motion (the trace's first to last moving tick, +- 3 refreshes):
  repeat     the frame's kept row is the same as the frame before while the layout moved between them
  shifted    (--idle: panes show still content) a pane that only moves sideways between two frames shows
             content that is not the frame before's content moved by the same amount: stale, stretched or
             redrawn content (the share of differing pixels is given)
  edge       the picture's pane edges along the row do not sit where the trace says (the content lags or leads
             the layout by more than 1 device pixel)
Prints the defects with their movie frame index (the n-th complete frame = the n-th frame in the movie when every
frame went in; frames.json says which did not). Needs numpy (venv /work/tmp/resize-suite/venv).
"""
import argparse
import json
import struct
import sys

import numpy as np


def read_scan(path):
    with open(path, "rb") as f:
        header = json.loads(f.readline())
        w, h = int(header["width"]), int(header["height"])
        rows, cols = header["rows"], header["columns"]
        size = 8 + 4 * (len(rows) * w + len(cols) * h)
        frames = []
        while True:
            rec = f.read(size)
            if len(rec) < size:
                break
            t = struct.unpack("<d", rec[:8])[0]
            px = np.frombuffer(rec[8:], dtype=np.uint8)
            r = px[:4 * len(rows) * w].reshape(len(rows), w, 4)[:, :, [2, 1, 0]]  # BGRA -> RGB
            c = px[4 * len(rows) * w:].reshape(len(cols), h, 4)[:, :, [2, 1, 0]]
            frames.append((t, r, c))
    return header, frames


def load_trace(path):
    with open(path) as f:
        data = json.load(f)
    for key in ("trace", "result", "value"):
        if isinstance(data, dict) and "samples" not in data and isinstance(data.get(key), dict):
            data = data[key]
    return data


def panes_at(sample):
    return {str(r[0]): [float(v) for v in r[1:6]] for r in sample.get("panes") or [] if isinstance(r, list) and len(r) >= 6}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("scan")
    ap.add_argument("--trace", required=True)
    ap.add_argument("--row", type=int, default=1, help="which kept row (index into the header's rows; default the middle one)")
    ap.add_argument("--scale", type=float, default=2.0)
    ap.add_argument("--idle", action="store_true", help="the panes show still content (idle load): check moved content")
    ap.add_argument("--json")
    opts = ap.parse_args()
    header, frames = read_scan(opts.scan)
    trace = load_trace(opts.trace)
    samples, t0 = trace["samples"], float(trace.get("t0_s") or 0)
    refresh = float(trace.get("refresh_ms") or 8.33) / 1000
    times = [t0 + float(s["t"]) / 1000 for s in samples]
    shown = [panes_at(s) for s in samples]
    moving = [i for i in range(1, len(shown)) if shown[i] != shown[i - 1]]
    if not moving:
        print("no motion in the trace")
        return 2
    lo, hi = times[moving[0] - 1] - 3 * refresh, times[moving[-1]] + 3 * refresh
    y = header["rows"][opts.row]
    ypt = y / opts.scale

    def sample_for(t):
        # The newest trace tick at or before the frame's display time (the layout that frame can show).
        best = None
        for i, ts in enumerate(times):
            if ts <= t + 0.25 * refresh:
                best = i
            else:
                break
        return best

    defects = []
    prev = None
    for n, (t, rows, _cols) in enumerate(frames):
        if not lo <= t <= hi:
            prev = (n, t, rows, None)
            continue
        k = sample_for(t)
        layout = shown[k] if k is not None else {}
        row = rows[opts.row].astype(np.int16)
        if prev is not None and prev[3] is not None:
            pn, pt, prows, pk = prev
            prow = prows[opts.row].astype(np.int16)
            if shown[pk] != layout and np.array_equal(prow, row):
                defects.append({"kind": "repeat", "movie_frame": n, "t_ms": round((t - t0) * 1000, 2),
                                "what": f"same picture as frame {pn} while the layout moved (trace ticks {pk} -> {k})"})
            if opts.idle:
                for pane, r in layout.items():
                    q = shown[pk].get(pane)
                    if not q or r[4] < 0.999 or q[4] < 0.999 or not (r[1] <= ypt < r[1] + r[3]):
                        continue
                    if abs(r[2] - q[2]) > 0.01:
                        continue  # a resize, not a move
                    dx = int(round((r[0] - q[0]) * opts.scale))
                    a0, a1 = int(round(q[0] * opts.scale)) + 4, int(round((q[0] + q[2]) * opts.scale)) - 4
                    seg_prev = prow[a0:a1]
                    seg_now = row[a0 + dx:a1 + dx]
                    if len(seg_prev) < 16 or len(seg_now) != len(seg_prev):
                        continue
                    diff = (np.abs(seg_now - seg_prev).max(axis=1) > 12).mean()
                    if diff > 0.02:
                        defects.append({"kind": "shifted", "movie_frame": n, "t_ms": round((t - t0) * 1000, 2),
                                        "what": f"pane {pane} moved {dx:+d} px; {100 * diff:.1f}% of its row differs from "
                                                f"frame {pn} moved by the same amount"})
        prev = (n, t, rows, k)
    counts = {}
    for d in defects:
        counts[d["kind"]] = counts.get(d["kind"], 0) + 1
    report = {"frames": len(frames), "row_px": y, "counts": counts, "defects": defects}
    if opts.json:
        with open(opts.json, "w") as f:
            json.dump(report, f, indent=1)
    print(f"{len(frames)} complete frames; row y={y} px; defects: {counts or 'none'}")
    for d in defects[:60]:
        print(f"  {d['kind']:8} movie frame {d['movie_frame']:5} t={d['t_ms']} ms  {d['what']}")
    return 1 if defects else 0


if __name__ == "__main__":
    sys.exit(main())
