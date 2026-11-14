#!/usr/bin/env python3
"""Per frame, find the first y (points) scanning down (or up) inside a vertical band
where the band's median luminance crosses a threshold for N consecutive rows.
Used for the keyboard's top edge (gray keyboard under a white transcript).
Usage: edge_scan.py frames_dir --x 150,250 --y 300,874 --below 235 [--up] [--rows 6]"""
import argparse, glob, os
import numpy as np
from PIL import Image
ap = argparse.ArgumentParser()
ap.add_argument("frames"); ap.add_argument("--x", default="150,250"); ap.add_argument("--y", default="300,874")
ap.add_argument("--below", type=float, default=None); ap.add_argument("--above", type=float, default=None)
ap.add_argument("--rows", type=int, default=6); ap.add_argument("--up", action="store_true")
ap.add_argument("--first", type=int, default=1); ap.add_argument("--last", type=int, default=10**9)
a = ap.parse_args()
x0, x1 = [int(float(v) * 3) for v in a.x.split(",")]; y0, y1 = [int(float(v) * 3) for v in a.y.split(",")]
files = sorted(glob.glob(os.path.join(a.frames, "*.png")))
out = []
for i, f in enumerate(files, 1):
    if i < a.first or i > a.last: continue
    im = np.asarray(Image.open(f).convert("RGB")).astype(float)
    L = (0.2126*im[..., 0] + 0.7152*im[..., 1] + 0.0722*im[..., 2])[y0:y1, x0:x1]
    med = np.median(L, axis=1)
    hit = (med < a.below) if a.below is not None else (med > a.above)
    rng = range(len(hit) - a.rows, -1, -1) if a.up else range(len(hit) - a.rows)
    y = None
    for r in rng:
        if hit[r:r + a.rows].all():
            y = (y0 + r) / 3; break
    out.append((i, y))
print(" ".join(f"{i}:{'-' if y is None else f'{y:.2f}'}" for i, y in out))
