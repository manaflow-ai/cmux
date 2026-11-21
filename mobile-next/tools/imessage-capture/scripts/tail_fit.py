#!/usr/bin/env python3
"""Fit a parametric iMessage bubble path (3 round corners + tail corner) to a
measured bubble in a 3x screenshot, by coordinate descent on the tail control
points, minimizing XOR area between rasterized path and traced coverage mask.

The path is defined in body coordinates (W x H body rect, tail hanging below
the bottom-right corner for a sent bubble). Prints fitted parameters and the
final SwiftUI Path code.

Usage: tail_fit.py image.png seed_x seed_y body_x body_y W H [--mirror]
  body_x/body_y/W/H: body rect in points (from outline.py); --mirror for received (tail bottom-left).
"""
import argparse, json
import numpy as np
from PIL import Image, ImageDraw

K = 0.5523

def cubic(p0, c1, c2, p1, n=24):
    t = np.linspace(0, 1, n)[:, None]
    return ((1-t)**3)*p0 + 3*((1-t)**2)*t*c1 + 3*(1-t)*t*t*c2 + t**3*p1

def path_points(W, H, r, p):
    """p: dict of tail params, offsets relative to bottom-right corner (dx leftwards, dy downwards)."""
    P = lambda x, y: np.array([x, y], float)
    pts = []
    pts += [P(r, 0), P(W - r, 0)]
    pts += list(cubic(P(W - r, 0), P(W - r + K*r, 0), P(W, r - K*r), P(W, r)))
    # straight right edge down to start of bottom-right shoulder
    y_s = H - p["shoulder"]
    pts += [P(W, y_s)]
    neck = P(W - p["neck_dx"], H + p["neck_dy"])
    pts += list(cubic(P(W, y_s), P(W, y_s + p["c1"]), P(neck[0] + p["c2"], neck[1] - p["c3"]), neck))
    tip = P(W - p["tip_dx"], H + p["tip_dy"])
    pts += list(cubic(neck, P(neck[0], neck[1] + p["c4"]), P(tip[0] - p["c5"], tip[1] - p["c6"]), tip))
    base = P(W - p["base_dx"], H)
    pts += list(cubic(tip, P(tip[0] - p["c7"], tip[1] + p["c8"]), P(base[0] + p["c9"], H), base))
    pts += [P(r, H)]
    pts += list(cubic(P(r, H), P(r - K*r, H), P(0, H - r + K*r), P(0, H - r)))
    pts += [P(0, r)]
    pts += list(cubic(P(0, r), P(0, r - K*r), P(r - K*r, 0), P(r, 0)))
    return pts

def raster(pts, w_px, h_px, ox, oy, ss=4):
    im = Image.new("L", (w_px * ss, h_px * ss), 0)
    d = ImageDraw.Draw(im)
    d.polygon([((x - ox) * 3 * ss, (y - oy) * 3 * ss) for x, y in pts], fill=255)
    return np.asarray(im.resize((w_px, h_px), Image.BOX)).astype(float) / 255

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("image"); ap.add_argument("sx", type=float); ap.add_argument("sy", type=float)
    ap.add_argument("bx", type=float); ap.add_argument("by", type=float)
    ap.add_argument("W", type=float); ap.add_argument("H", type=float)
    ap.add_argument("--r", type=float, default=None)
    ap.add_argument("--mirror", action="store_true")
    a = ap.parse_args()
    img = np.asarray(Image.open(a.image).convert("RGB")).astype(float)
    if a.mirror:
        img = img[:, ::-1]
        Wimg = img.shape[1] / 3
        a.sx = Wimg - a.sx; a.bx = Wimg - (a.bx + a.W)
    fill = img[int(a.sy*3), int(a.sx*3)]
    bg = img[int(a.sy*3), 3]
    span = np.linalg.norm(fill - bg)
    cov = np.clip(((img - bg) @ (fill - bg)) / span**2, 0, 1)
    # crop region around the tail corner: right 30pt x bottom 30pt (+10 below)
    ox, oy = a.bx + a.W - 32, a.by + a.H - 26
    wpx, hpx = int(40 * 3), int(36 * 3)
    # Connected component of the bubble (flood fill from the seed), then fill each row
    # between its extreme pixels so text/emoji inside the bubble count as filled.
    from collections import deque
    inside = cov > 0.5
    Hh, Ww = inside.shape
    seen = np.zeros_like(inside)
    q = deque([(int(a.sy*3), int(a.sx*3))]); seen[q[0]] = True
    while q:
        y, x = q.popleft()
        for ny, nx in ((y+1, x), (y-1, x), (y, x+1), (y, x-1)):
            if 0 <= ny < Hh and 0 <= nx < Ww and inside[ny, nx] and not seen[ny, nx]:
                seen[ny, nx] = True; q.append((ny, nx))
    filled = cov.copy() * 0
    for y in np.unique(np.nonzero(seen)[0]):
        xs = np.nonzero(seen[y])[0]
        l, rr = xs.min(), xs.max()
        filled[y, l:rr+1] = 1.0
        if l > 0: filled[y, l-1] = cov[y, l-1]
        if rr + 1 < Ww: filled[y, rr+1] = cov[y, rr+1]
    meas = filled[int(oy*3):int(oy*3)+hpx, int(ox*3):int(ox*3)+wpx]
    r = a.r if a.r else min(20.0, a.H / 2)
    p = dict(shoulder=20.0, neck_dx=10.5, neck_dy=0.0, tip_dx=8.4, tip_dy=6.7, base_dx=21.5,
             c1=8.0, c2=6.0, c3=3.0, c4=3.0, c5=1.0, c6=2.0, c7=3.0, c8=0.0, c9=4.0)
    def err(pp):
        pts = [(x + a.bx, y + a.by) for x, y in path_points(a.W, a.H, r, pp)]
        return float(np.abs(raster(pts, wpx, hpx, ox, oy) - meas).sum()) / 9.0  # pt^2
    best = err(p)
    step = 1.0
    while step > 0.04:
        improved = False
        for k in list(p):
            for s in (step, -step):
                q = dict(p); q[k] = q[k] + s
                e = err(q)
                if e < best - 1e-4:
                    p, best, improved = q, e, True
        if not improved:
            step /= 2
    meas_area = meas.sum() / 9.0
    print(json.dumps({k: round(v, 2) for k, v in p.items()}))
    print(f"r={r:.2f}  XOR area in 40x36pt window: {best:.3f} pt^2 (filled area {meas_area:.1f} pt^2)")

if __name__ == "__main__":
    main()
