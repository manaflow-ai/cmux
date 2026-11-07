#!/usr/bin/env python3
"""Mean color of a rect (points) per frame, e.g. to measure a dimming backdrop.
Usage: lum.py frames_dir x0,y0,x1,y1 [first] [last]"""
import glob, os, sys
import numpy as np
from PIL import Image
d = sys.argv[1]; x0, y0, x1, y1 = [int(float(v) * 3) for v in sys.argv[2].split(",")]
files = sorted(glob.glob(os.path.join(d, "*.png")))
first = int(sys.argv[3]) if len(sys.argv) > 3 else 1
last = int(sys.argv[4]) if len(sys.argv) > 4 else len(files)
for i in range(first, min(last, len(files)) + 1):
    a = np.asarray(Image.open(files[i - 1]).convert("RGB"))[y0:y1, x0:x1].reshape(-1, 3).mean(axis=0)
    print(f"{i:4d} {1000*(i-1)/60:7.1f}ms  #{int(a[0]):02X}{int(a[1]):02X}{int(a[2]):02X}  lum={0.2126*a[0]+0.7152*a[1]+0.0722*a[2]:6.1f}")
