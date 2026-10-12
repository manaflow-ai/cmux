#!/usr/bin/env python3
"""Sample the median color of rectangles (in points) from a 3x screenshot.
Usage: sample_colors.py image.png name:x0,y0,x1,y1 [...]"""
import sys
import numpy as np
from PIL import Image

img = np.asarray(Image.open(sys.argv[1]).convert("RGB"))
for spec in sys.argv[2:]:
    name, rect = spec.split(":")
    x0, y0, x1, y1 = [int(round(float(v) * 3)) for v in rect.split(",")]
    px = img[y0:y1, x0:x1].reshape(-1, 3)
    med = np.median(px, axis=0).astype(int)
    print(f"{name:28s} #{med[0]:02X}{med[1]:02X}{med[2]:02X}  rgb({med[0]},{med[1]},{med[2]})")
