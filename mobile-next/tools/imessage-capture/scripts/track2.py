#!/usr/bin/env python3
"""Component tracker for animation frames (3x PNGs at 60 fps).

Per frame: build a predicate mask inside --region (points), label connected
components on a 1/3-pt grid, choose one by --pick, report its bbox in points.
Predicates:
  green      g - max(r,b) > T           (SMS bubble / translucent green)
  blue       b - max(r,g) > T           (iMessage-blue send button / bubble)
  dark       luminance < T              (text, black UI)
  notwhite   any channel < 255 - T      (anything on a white background)
  color:R,G,B  max channel diff <= T
Then prints a per-frame table and fits a damped spring to --prop between
--start and --end (auto-detected when omitted).

Usage: track2.py frames_dir --pred green --thresh 40 --region x0,y0,x1,y1 --pick lowest --prop y0
"""
import argparse, glob, math, os
from collections import deque
import numpy as np
from PIL import Image

def mask_for(a, pred, T):
    r, g, b = a[..., 0], a[..., 1], a[..., 2]
    if pred == "green":
        return (g - np.maximum(r, b)) > T
    if pred == "blue":
        return (b - np.maximum(r, g)) > T
    if pred == "dark":
        return (0.2126 * r + 0.7152 * g + 0.0722 * b) < T
    if pred == "notwhite":
        return a.min(axis=2) < 255 - T
    if pred.startswith("color:"):
        c = np.array([int(v) for v in pred[6:].split(",")])
        return np.abs(a - c).max(axis=2) <= T
    raise SystemExit("bad pred")

def components(m, min_px):
    h, w = m.shape
    lab = np.zeros((h, w), np.int32); out = []
    n = 0
    for y, x in zip(*np.nonzero(m)):
        if lab[y, x]:
            continue
        n += 1; q = deque([(y, x)]); lab[y, x] = n; pts = []
        while q:
            cy, cx = q.popleft(); pts.append((cy, cx))
            for ny, nx in ((cy+1, cx), (cy-1, cx), (cy, cx+1), (cy, cx-1)):
                if 0 <= ny < h and 0 <= nx < w and m[ny, nx] and not lab[ny, nx]:
                    lab[ny, nx] = n; q.append((ny, nx))
        if len(pts) >= min_px:
            p = np.array(pts); out.append(p)
    return out

def spring(t, omega, zeta):
    if zeta < 1:
        wd = omega * math.sqrt(1 - zeta * zeta)
        return 1 - math.exp(-zeta * omega * t) * (math.cos(wd * t) + zeta * omega / wd * math.sin(wd * t))
    if abs(zeta - 1) < 1e-9:
        return 1 - (1 + omega * t) * math.exp(-omega * t)
    s = math.sqrt(zeta * zeta - 1); r1, r2 = -omega * (zeta - s), -omega * (zeta + s)
    return 1 + (r2 * math.exp(r1 * t) - r1 * math.exp(r2 * t)) / (r1 - r2)

def fit_spring(ts, ys):
    best = None
    for resp in np.arange(0.10, 1.50, 0.005):
        om = 2 * math.pi / resp
        for z in np.arange(0.40, 1.60, 0.01):
            e = sum((spring(t, om, z) - y) ** 2 for t, y in zip(ts, ys))
            if best is None or e < best[0]:
                best = (e, resp, z)
    return best

def bezier_y(x1, y1, x2, y2, x):
    # solve cubic-bezier timing curve y for given x via bisection
    lo, hi = 0.0, 1.0
    for _ in range(40):
        t = (lo + hi) / 2
        bx = 3*(1-t)**2*t*x1 + 3*(1-t)*t*t*x2 + t**3
        if bx < x: lo = t
        else: hi = t
    t = (lo + hi) / 2
    return 3*(1-t)**2*t*y1 + 3*(1-t)*t*t*y2 + t**3

def fit_bezier(ts, ys, dur):
    best = None
    grid = np.arange(0.0, 1.01, 0.05)
    for x1 in grid:
        for x2 in grid:
            for y2 in np.arange(0.6, 1.21, 0.05):
                e = sum((bezier_y(x1, 0, x2, y2, t / dur) - y) ** 2 for t, y in zip(ts, ys))
                if best is None or e < best[0]:
                    best = (e, x1, x2, y2)
    return best

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("frames")
    ap.add_argument("--pred", default="green"); ap.add_argument("--thresh", type=float, default=40)
    ap.add_argument("--region", default="0,0,402,874")
    ap.add_argument("--pick", default="lowest", choices=["lowest", "highest", "largest", "leftmost", "rightmost", "union"])
    ap.add_argument("--prop", default="y0")
    ap.add_argument("--min-px", type=int, default=30)
    ap.add_argument("--start", type=int); ap.add_argument("--end", type=int)
    ap.add_argument("--first", type=int, default=1); ap.add_argument("--last", type=int, default=10**9)
    ap.add_argument("--bezier", action="store_true", help="also fit a cubic-bezier timing curve")
    ap.add_argument("--quiet", action="store_true")
    ap.add_argument("--from-value", type=float, default=None,
                    help="known value at animation start (e.g. off-screen x); fits an unknown start time too")
    a = ap.parse_args()
    x0, y0, x1, y1 = [float(v) for v in a.region.split(",")]
    files = sorted(glob.glob(os.path.join(a.frames, "*.png")))
    rows = {}
    for i, f in enumerate(files, 1):
        if i < a.first or i > a.last:
            continue
        im = np.asarray(Image.open(f).convert("RGB"), dtype=np.int16)
        sub = im[int(y0*3):int(y1*3), int(x0*3):int(x1*3)]
        m = mask_for(sub, a.pred, a.thresh)[::1, ::1]
        # work on a 1pt grid for labelling speed, then refine bbox at full res
        small = m.reshape(m.shape[0]//3, 3, m.shape[1]//3, 3).any(axis=(1, 3)) if m.shape[0] % 3 == 0 and m.shape[1] % 3 == 0 else m[::3, ::3]
        comps = components(small, a.min_px)
        if not comps:
            rows[i] = None; continue
        key = {"lowest": lambda c: c[:, 0].max(), "highest": lambda c: -c[:, 0].min(), "largest": len,
               "leftmost": lambda c: -c[:, 1].min(), "rightmost": lambda c: c[:, 1].max()}
        if a.pick == "union":
            c = np.concatenate(comps)
        else:
            c = max(comps, key=key[a.pick])
        cy0, cy1, cx0, cx1 = c[:, 0].min(), c[:, 0].max() + 1, c[:, 1].min(), c[:, 1].max() + 1
        fine = m[cy0*3:cy1*3, cx0*3:cx1*3]
        ys, xs = np.nonzero(fine)
        bx0 = x0 + (cx0*3 + xs.min()) / 3; bx1 = x0 + (cx0*3 + xs.max() + 1) / 3
        by0 = y0 + (cy0*3 + ys.min()) / 3; by1 = y0 + (cy0*3 + ys.max() + 1) / 3
        rows[i] = dict(x0=bx0, y0=by0, x1=bx1, y1=by1, w=bx1-bx0, h=by1-by0, cx=(bx0+bx1)/2, cy=(by0+by1)/2, area=len(c))
    if not a.quiet:
        print("frame  t_ms     x0      y0      x1      y1       w       h")
        for i in sorted(rows):
            b = rows[i]
            print(f"{i:5d} {1000*(i-1)/60:6.1f} " + (" ".join(f"{b[k]:7.2f}" for k in ["x0", "y0", "x1", "y1", "w", "h"]) if b else "   -"))
    vals = [(i, rows[i][a.prop]) for i in sorted(rows) if rows[i]]
    if a.start is None or a.end is None:
        ch = [i for (i, v), (_, pv) in zip(vals[1:], vals[:-1]) if abs(v - pv) > 0.34]
        if not ch:
            print("no motion"); return
        s = a.start or ch[0] - 1; e = a.end or ch[-1]
    else:
        s, e = a.start, a.end
    sel = [(i, v) for i, v in vals if s <= i <= e]
    v0, v1 = sel[0][1], sel[-1][1]
    print(f"\n{a.prop}: frames {s}->{e} = {e-s} frames = {1000*(e-s)/60:.0f} ms; {v0:.2f} -> {v1:.2f} pt (delta {v1-v0:+.2f})")
    if abs(v1 - v0) < 0.5:
        return
    ts = [(i - s) / 60 for i, _ in sel]; ys = [(v - v0) / (v1 - v0) for _, v in sel]
    err, resp, z = fit_spring(ts, ys)
    # settle time: last frame where |progress-1| > 1%
    settle = max([t for t, y in zip(ts, ys) if abs(y - 1) > 0.01] + [0])
    print(f"spring fit: response={resp:.3f}s dampingFraction={z:.2f}  rms={math.sqrt(err/len(ts)):.3f}  "
          f"max={max(ys)*100:.1f}%  t(50%)={next(t for t, y in zip(ts, ys) if y >= 0.5)*1000:.0f}ms  settle(1%)={settle*1000:.0f}ms")
    if a.from_value is not None:
        # model: v(t) = v0 + (v1 - v0) * spring(t - t0), v0 known, t0 <= first sample
        best = None
        ts_abs = [(i - s) / 60 for i, _ in sel]
        vs = [v for _, v in sel]
        for t0 in np.arange(-0.25, 0.0001, 1 / 240):
            for resp in np.arange(0.10, 1.20, 0.01):
                om = 2 * math.pi / resp
                for z in np.arange(0.50, 1.61, 0.02):
                    e = sum((a.from_value + (v1 - a.from_value) * spring(t - t0, om, z) - v) ** 2 for t, v in zip(ts_abs, vs))
                    if best is None or e < best[0]:
                        best = (e, t0, resp, z)
        e, t0, resp, z = best
        print(f"spring fit with known start {a.from_value:.1f}: start {(-t0)*1000:.0f}ms before frame {s}, "
              f"response={resp:.2f}s dampingFraction={z:.2f} rms={math.sqrt(e/len(vs)):.2f}pt")
    if a.bezier:
        dur = ts[-1]
        be = fit_bezier(ts, ys, dur)
        print(f"bezier fit over {dur*1000:.0f}ms: cubic-bezier({be[1]:.2f}, 0, {be[2]:.2f}, {be[3]:.2f})  rms={math.sqrt(be[0]/len(ts)):.3f}")
    print("progress: " + " ".join(f"{y:.3f}" for y in ys))

if __name__ == "__main__":
    main()
