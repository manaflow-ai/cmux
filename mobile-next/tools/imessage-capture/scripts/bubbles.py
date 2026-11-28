#!/usr/bin/env python3
"""Detect message bubbles in a 3x transcript screenshot and measure them.

Finds connected components of the bubble fill color, reports bbox in points,
estimates corner radius from the top-left/top-right curve, and traces the
tail outline (pixels below the rounded body) as an SVG path in points.
Usage: bubbles.py image.png --color 52,199,89 [--tol 20] [--svg-out tails.svg]
"""
import argparse
import numpy as np
from PIL import Image
from collections import deque

def components(mask):
    h, w = mask.shape
    seen = np.zeros_like(mask, dtype=bool)
    out = []
    for y in range(0, h, 3):
        for x in range(0, w, 3):
            if mask[y, x] and not seen[y, x]:
                q = deque([(y, x)]); seen[y, x] = True; pts = []
                while q:
                    cy, cx = q.popleft(); pts.append((cy, cx))
                    for ny, nx in ((cy + 1, cx), (cy - 1, cx), (cy, cx + 1), (cy, cx - 1)):
                        if 0 <= ny < h and 0 <= nx < w and mask[ny, nx] and not seen[ny, nx]:
                            seen[ny, nx] = True; q.append((ny, nx))
                if len(pts) > 3000:
                    out.append(np.array(pts))
    return out

def corner_radius(m, y0, x0, x1):
    """Radius from the inset of the first filled pixel on the top row vs straight side."""
    # Walk down rows from the top edge; radius ~ number of rows until the left edge reaches its minimum.
    rows = m[y0:y0 + 200, :]
    lefts = []
    for r in rows:
        xs = np.nonzero(r[x0:x1])[0]
        lefts.append(xs[0] if len(xs) else None)
    base = min(v for v in lefts if v is not None)
    for i, v in enumerate(lefts):
        if v is not None and v <= base + 0:
            return i / 3.0
    return None

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("image")
    ap.add_argument("--color", required=True)
    ap.add_argument("--tol", type=int, default=20)
    a = ap.parse_args()
    img = np.asarray(Image.open(a.image).convert("RGB")).astype(np.int16)
    col = np.array([int(v) for v in a.color.split(",")], dtype=np.int16)
    mask = np.abs(img - col).max(axis=2) <= a.tol
    for comp in sorted(components(mask), key=lambda c: c[:, 0].min()):
        ys, xs = comp[:, 0], comp[:, 1]
        y0, y1, x0, x1 = ys.min(), ys.max() + 1, xs.min(), xs.max() + 1
        local = np.zeros((y1 - y0, x1 - x0), dtype=bool)
        local[ys - y0, xs - x0] = True
        widths = local.sum(axis=1)
        # Body width = the modal full row width; tail rows are those at the bottom narrower than body.
        body_w = np.percentile(widths, 75)
        r_top = corner_radius(local, 0, 0, local.shape[1])
        # Body bottom: last row where the row spans >= 60% of the body width.
        full_rows = np.nonzero(widths >= body_w * 0.6)[0]
        print(f"bubble bbox pt x={x0/3:.2f} y={y0/3:.2f} w={(x1-x0)/3:.2f} h={(y1-y0)/3:.2f}  "
              f"top-corner-radius~{r_top}pt  rows>60%: {full_rows.min()/3:.1f}-{full_rows.max()/3:.1f}pt")
        # Left/right edge profile for the bottom 30pt (tail region), in points relative to bbox.
        prof = []
        for ry in range(max(0, local.shape[0] - 90), local.shape[0], 3):
            xs_r = np.nonzero(local[ry])[0]
            if len(xs_r):
                prof.append((ry / 3, xs_r[0] / 3, (xs_r[-1] + 1) / 3))
        print("   bottom profile (y, left, right) pt:", " ".join(f"({p[0]:.0f},{p[1]:.1f},{p[2]:.1f})" for p in prof))

if __name__ == "__main__":
    main()
