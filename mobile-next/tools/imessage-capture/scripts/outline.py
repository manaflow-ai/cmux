#!/usr/bin/env python3
"""Trace a bubble outline with sub-pixel precision from a 3x screenshot.

Flood-fills from a seed point (pt) over pixels "closer to the fill than to the
background", fills interior holes (text), then for every pixel row finds the
left/right 50%-coverage crossing with linear interpolation. Prints the outline
(in points, relative to the bubble's bounding box) simplified with
Ramer-Douglas-Peucker, plus body metrics.

Usage: outline.py image.png seed_x seed_y [--bg 255,255,255] [--eps 0.12] [--svg out.svg]
"""
import argparse
from collections import deque
import numpy as np
from PIL import Image

def rdp(pts, eps):
    if len(pts) < 3:
        return pts
    a, b = np.array(pts[0]), np.array(pts[-1])
    ab = b - a
    n = np.linalg.norm(ab) or 1e-9
    d = [abs(ab[0] * (p[1] - a[1]) - ab[1] * (p[0] - a[0])) / n for p in pts[1:-1]]
    i = int(np.argmax(d)) + 1
    if d[i - 1] > eps:
        return rdp(pts[:i + 1], eps)[:-1] + rdp(pts[i:], eps)
    return [pts[0], pts[-1]]

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("image"); ap.add_argument("sx", type=float); ap.add_argument("sy", type=float)
    ap.add_argument("--bg", default=None)
    ap.add_argument("--eps", type=float, default=0.12)
    ap.add_argument("--svg")
    a = ap.parse_args()
    img = np.asarray(Image.open(a.image).convert("RGB")).astype(float)
    H, W, _ = img.shape
    sx, sy = int(a.sx * 3), int(a.sy * 3)
    fill = img[sy, sx]
    bg = np.array([float(v) for v in a.bg.split(",")]) if a.bg else img[sy, 2]
    span = np.linalg.norm(fill - bg)
    # coverage: projection of (pixel - bg) onto (fill - bg)
    cov = np.clip(((img - bg) @ (fill - bg)) / (span * span), 0, 1)
    inside = cov > 0.5
    # Flood fill from seed through 'inside', but allow passing through text by using a coarse closing:
    seen = np.zeros((H, W), bool)
    q = deque([(sy, sx)]); seen[sy, sx] = True
    lim = 600  # max half-size in px
    while q:
        y, x = q.popleft()
        for ny, nx in ((y+1, x), (y-1, x), (y, x+1), (y, x-1)):
            if 0 <= ny < H and 0 <= nx < W and not seen[ny, nx] and inside[ny, nx] and abs(ny - sy) < lim and abs(nx - sx) < 1200:
                seen[ny, nx] = True; q.append((ny, nx))
    ys, xs = np.nonzero(seen)
    y0, y1 = ys.min(), ys.max()
    left, right = [], []
    for y in range(y0, y1 + 1):
        row = np.nonzero(seen[y])[0]
        if not len(row):
            continue
        l, r = row.min(), row.max()
        # sub-pixel: coverage of the boundary pixels
        lx = l - cov[y, l - 1] + 0.5 if l > 0 else l
        rx = r + 0.5 + (cov[y, r + 1] if r + 1 < W else 0)
        left.append(((lx) / 3, (y + 0.5) / 3))
        right.append(((rx) / 3, (y + 0.5) / 3))
    bx0 = min(p[0] for p in left); by0 = y0 / 3
    bx1 = max(p[0] for p in right); by1 = (y1 + 1) / 3
    widths = [r[0] - l[0] for l, r in zip(left, right)]
    print(f"bbox pt x={bx0:.2f} y={by0:.2f} w={bx1-bx0:.2f} h={by1-by0:.2f}  fill=#{int(fill[0]):02X}{int(fill[1]):02X}{int(fill[2]):02X}")
    outline = left + right[::-1]
    rel = [(round(x - bx0, 2), round(y - by0, 2)) for x, y in outline]
    simp = rdp(rel, a.eps)
    print(f"outline points (relative to bbox, pt), {len(simp)} after RDP eps={a.eps}:")
    print(" ".join(f"{x:.2f},{y:.2f}" for x, y in simp))
    if a.svg:
        w, h = bx1 - bx0, by1 - by0
        d = "M" + " L".join(f"{x:.2f},{y:.2f}" for x, y in simp) + " Z"
        open(a.svg, "w").write(f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w:.2f} {h:.2f}" width="{w*3:.0f}" height="{h*3:.0f}"><path d="{d}" fill="#34C759"/></svg>\n')

if __name__ == "__main__":
    main()
