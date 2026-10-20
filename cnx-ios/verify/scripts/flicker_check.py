"""flicker_check.py <video> <start> <dur>: per-frame vertical shift of the
content against the first frame and mean luminance, to catch a page that
alternates between two layouts frame to frame (the tab-zoom flicker)."""
import glob, os, subprocess, sys, tempfile
import numpy as np
from PIL import Image
v, s, d = sys.argv[1], sys.argv[2], sys.argv[3]
with tempfile.TemporaryDirectory() as t:
    subprocess.run(["ffmpeg", "-v", "error", "-ss", s, "-t", d, "-i", v, "-vf", "scale=402:-1", "-fps_mode", "passthrough",
                    "-frame_pts", "1", "-enc_time_base", "1/1000", f"{t}/f_%08d.png"], check=True)
    fs = sorted(glob.glob(f"{t}/*.png"))
    prev, flips, last = None, 0, None
    for f in fs:
        a = np.asarray(Image.open(f).convert("L")).astype(float)
        prof = a[120:700, 20:380].mean(axis=1)
        if prev is not None:
            sh = min(range(-80, 81), key=lambda k: np.mean((np.roll(prof, k)[100:480] - prev[100:480]) ** 2))
            if last is not None and sh != 0 and last != 0 and np.sign(sh) != np.sign(last):
                flips += 1
            last = sh if sh != 0 else last
        prev = prof
    print(f"frames={len(fs)} direction_reversals={flips}")
