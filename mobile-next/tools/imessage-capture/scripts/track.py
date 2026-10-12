#!/usr/bin/env python3
"""Track an element across a PNG frame sequence by color, and fit a spring.

For each frame, pixels inside --region (points) whose RGB is within --tol of
--color are collected; the bbox (in points, 3x scale) is reported. The chosen
--prop (x0, x1, y0, y1, w, h, cx, cy, area) is normalized from first to last
value and fitted with a damped spring step response; the result is printed
as SwiftUI `.spring(response:dampingFraction:)` parameters.

Usage:
  track.py <frames_dir> --color 52,199,89 --tol 30 --region x0,y0,x1,y1 \
           --prop x0 [--fps 60] [--csv out.csv] [--min-px 50]
"""
import argparse, csv, glob, math, os
import numpy as np
from PIL import Image

SCALE = 3.0

def bbox(img, color, tol, region, min_px):
    a = np.asarray(img.convert("RGB")).astype(np.int16)
    x0, y0, x1, y1 = [int(round(v * SCALE)) for v in region]
    sub = a[y0:y1, x0:x1]
    d = np.abs(sub - np.array(color, dtype=np.int16)).max(axis=2)
    m = d <= tol
    n = int(m.sum())
    if n < min_px:
        return None
    ys, xs = np.nonzero(m)
    bx0, bx1 = xs.min() + x0, xs.max() + x0 + 1
    by0, by1 = ys.min() + y0, ys.max() + y0 + 1
    return dict(x0=bx0 / SCALE, y0=by0 / SCALE, x1=bx1 / SCALE, y1=by1 / SCALE,
                w=(bx1 - bx0) / SCALE, h=(by1 - by0) / SCALE,
                cx=(bx0 + bx1) / 2 / SCALE, cy=(by0 + by1) / 2 / SCALE, area=n / SCALE / SCALE)

def spring(t, omega, zeta):
    if zeta < 1:
        wd = omega * math.sqrt(1 - zeta * zeta)
        return 1 - math.exp(-zeta * omega * t) * (math.cos(wd * t) + zeta * omega / wd * math.sin(wd * t))
    if zeta == 1:
        return 1 - (1 + omega * t) * math.exp(-omega * t)
    s = math.sqrt(zeta * zeta - 1)
    r1, r2 = -omega * (zeta - s), -omega * (zeta + s)
    return 1 + (r2 * math.exp(r1 * t) - r1 * math.exp(r2 * t)) / (r1 - r2)

def fit_spring(ts, ys):
    best = None
    for resp in np.arange(0.10, 1.20, 0.005):
        omega = 2 * math.pi / resp
        for zeta in np.arange(0.40, 1.51, 0.01):
            err = sum((spring(t, omega, zeta) - y) ** 2 for t, y in zip(ts, ys))
            if best is None or err < best[0]:
                best = (err, resp, zeta)
    return best

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("frames")
    ap.add_argument("--color", required=True)
    ap.add_argument("--tol", type=int, default=24)
    ap.add_argument("--region", default="0,0,402,874")
    ap.add_argument("--prop", default="x0")
    ap.add_argument("--fps", type=float, default=60)
    ap.add_argument("--csv")
    ap.add_argument("--min-px", type=int, default=50)
    ap.add_argument("--start", type=int, default=None, help="first frame index of motion (1-based)")
    ap.add_argument("--end", type=int, default=None, help="last frame index of motion (1-based)")
    a = ap.parse_args()
    color = [int(v) for v in a.color.split(",")]
    region = [float(v) for v in a.region.split(",")]
    files = sorted(glob.glob(os.path.join(a.frames, "*.png")))
    rows = []
    for i, f in enumerate(files, 1):
        b = bbox(Image.open(f), color, a.tol, region, a.min_px)
        rows.append((i, b))
    if a.csv:
        with open(a.csv, "w", newline="") as fh:
            w = csv.writer(fh)
            w.writerow(["frame", "t_ms", "x0", "y0", "x1", "y1", "w", "h", "cx", "cy", "area"])
            for i, b in rows:
                t = (i - 1) * 1000 / a.fps
                w.writerow([i, f"{t:.1f}"] + ([f"{b[k]:.2f}" for k in ["x0", "y0", "x1", "y1", "w", "h", "cx", "cy", "area"]] if b else [""] * 9))
    vals = [(i, b[a.prop]) for i, b in rows if b]
    if not vals:
        print("no matches"); return
    # Detect motion window: first and last frame where value differs from neighbours.
    if a.start is None or a.end is None:
        changes = [i for (i, v), (_, pv) in zip(vals[1:], vals[:-1]) if abs(v - pv) > 0.34]
        if not changes:
            print("no motion"); return
        s = a.start or changes[0] - 1
        e = a.end or changes[-1]
    else:
        s, e = a.start, a.end
    sel = [(i, v) for i, v in vals if s <= i <= e]
    v0, v1 = sel[0][1], sel[-1][1]
    print(f"{a.prop}: frame {s}->{e} ({e - s} frames, {1000 * (e - s) / a.fps:.0f} ms), {v0:.2f} -> {v1:.2f} pt")
    if abs(v1 - v0) < 0.5:
        return
    ts = [(i - s) / a.fps for i, _ in sel]
    ys = [(v - v0) / (v1 - v0) for _, v in sel]
    err, resp, zeta = fit_spring(ts, ys)
    overshoot = max(ys) - 1
    print(f"spring fit: response={resp:.3f}s dampingFraction={zeta:.2f} rms={math.sqrt(err / len(ts)):.3f} overshoot={overshoot * 100:.1f}%")
    print("frame  t_ms   value   progress")
    for (i, v), t, y in zip(sel, ts, ys):
        print(f"{i:5d} {t * 1000:6.1f} {v:7.2f} {y:7.3f}")

if __name__ == "__main__":
    main()
