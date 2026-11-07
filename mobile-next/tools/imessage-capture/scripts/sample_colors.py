#!/usr/bin/env python3
"""Sample colors / glyph boxes from a 3x screenshot.

Usage: sample_colors.py image.png name:x0,y0,x1,y1[:mode] ...
modes:
  median (default)  median color of the rect
  dark              color of the darkest pixel (text color on light bg)
  light             color of the lightest pixel (text color on dark/colored bg)
  inkdark           bbox (pt) of pixels darker than the rect's median by >60 (glyph bounds)
  inklight          bbox (pt) of pixels lighter than the rect's median by >60
  top / bottom      median of the top / bottom 2 pt rows (gradient check)
"""
import sys
import numpy as np
from PIL import Image

img = np.asarray(Image.open(sys.argv[1]).convert("RGB")).astype(int)
lum = 0.2126 * img[..., 0] + 0.7152 * img[..., 1] + 0.0722 * img[..., 2]

def hexc(c):
    return f"#{int(c[0]):02X}{int(c[1]):02X}{int(c[2]):02X}"

for spec in sys.argv[2:]:
    parts = spec.split(":")
    name, rect = parts[0], parts[1]
    mode = parts[2] if len(parts) > 2 else "median"
    x0, y0, x1, y1 = [int(round(float(v) * 3)) for v in rect.split(",")]
    px = img[y0:y1, x0:x1]; L = lum[y0:y1, x0:x1]
    flat = px.reshape(-1, 3)
    if mode == "median":
        out = hexc(np.median(flat, axis=0))
    elif mode in ("top", "bottom"):
        rows = px[:6] if mode == "top" else px[-6:]
        out = hexc(np.median(rows.reshape(-1, 3), axis=0))
    elif mode in ("dark", "light"):
        idx = np.argmin(L) if mode == "dark" else np.argmax(L)
        out = hexc(flat[idx])
    elif mode in ("inkdark", "inklight"):
        med = np.median(L)
        m = (L < med - 60) if mode == "inkdark" else (L > med + 60)
        ys, xs = np.nonzero(m)
        if len(xs) == 0:
            out = "none"
        else:
            out = (f"x={(x0+xs.min())/3:.2f}..{(x0+xs.max()+1)/3:.2f} y={(y0+ys.min())/3:.2f}..{(y0+ys.max()+1)/3:.2f} "
                   f"(w={(xs.max()-xs.min()+1)/3:.2f} h={(ys.max()-ys.min()+1)/3:.2f})")
    print(f"{name:30s} {mode:9s} {out}")
