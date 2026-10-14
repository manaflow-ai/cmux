"""Frame-split motion analysis of a terminal recording (verify-ui-video style, numbers
instead of eyeballing): per frame, the vertical shift of the terminal text against the
previous frame, and flashes (a frame unlike both neighbours that are alike).

    python3 motion.py VIDEO [--fps 30] [--start S] [--dur D] [--top 70] [--bottom 0.55]

Band: points from --top to --bottom*874 (keep it above the composer/keyboard).
Output: one line per frame with a shift or a flash; a summary of direction reversals
(content that goes down then up inside 0.5 s = a jump/oscillation) and flashes.
"""
import argparse
import os
import subprocess
import sys
import tempfile

import numpy as np
from PIL import Image


def frames(video, fps, start, dur, width=402):
    d = tempfile.mkdtemp(prefix="tqmotion-")
    cmd = ["ffmpeg", "-v", "error", "-y"] + (["-ss", str(start)] if start else []) + (["-t", str(dur)] if dur else []) + \
          ["-i", video, "-vf", f"fps={fps},scale={width}:-1,format=gray", os.path.join(d, "f%05d.png")]
    subprocess.run(cmd, check=True)
    return d, sorted(os.listdir(d))


def profile(path, top, bottom):
    a = np.asarray(Image.open(path), dtype=np.float32)
    h = a.shape[0]
    band = a[int(top / 874 * h):int(bottom * h), :]
    return band


def shift(prev, cur, maxs=120):
    """Best vertical shift s (cur[y] ~ prev[y - s]), its residual and the zero-shift residual."""
    p = prev.mean(axis=1)
    c = cur.mean(axis=1)
    n = len(p)
    best, bs = None, 0
    for s in range(-maxs, maxs + 1):
        if s >= 0:
            a, b = c[s:], p[:n - s]
        else:
            a, b = c[:n + s], p[-s:]
        if len(a) < n // 2:
            continue
        r = float(np.mean(np.abs(a - b)))
        if best is None or r < best:
            best, bs = r, s
    return bs, best, float(np.mean(np.abs(c - p)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("video")
    ap.add_argument("--fps", type=int, default=30)
    ap.add_argument("--start", type=float)
    ap.add_argument("--dur", type=float)
    ap.add_argument("--top", type=float, default=70)
    ap.add_argument("--bottom", type=float, default=0.5)
    ap.add_argument("--quiet", action="store_true")
    a = ap.parse_args()
    d, fs = frames(a.video, a.fps, a.start, a.dur)
    bands = [profile(os.path.join(d, f), a.top, a.bottom) for f in fs]
    t0 = a.start or 0.0
    moves, flashes = [], []
    for i in range(1, len(bands)):
        s, r, r0 = shift(bands[i - 1], bands[i])
        t = t0 + i / a.fps
        full = float(np.mean(np.abs(bands[i] - bands[i - 1])))
        if s != 0 and r < r0 * 0.7:
            moves.append((t, s))
            if not a.quiet:
                print(f"{t:8.2f}s  shift {s:+4d}px  (resid {r:.1f} vs {r0:.1f})")
        if 0 < i < len(bands) - 1:
            nb = float(np.mean(np.abs(bands[i + 1] - bands[i - 1])))
            if full > 12 and nb < full * 0.35:
                flashes.append((t, round(full, 1), round(nb, 1)))
                print(f"{t:8.2f}s  FLASH  diff to prev {full:.1f}, prev-to-next {nb:.1f}")
    # Reversals: a shift followed within 0.5 s by one of the opposite sign.
    rev = []
    for i, (t, s) in enumerate(moves):
        for t2, s2 in moves[i + 1:]:
            if t2 - t > 0.5:
                break
            if s * s2 < 0 and abs(s) >= 4 and abs(s2) >= 4:
                rev.append((round(t, 2), s, round(t2, 2), s2))
                break
    print(f"frames {len(bands)} @ {a.fps} fps; moves {len(moves)}; reversals {len(rev)}: {rev[:12]}; flashes {len(flashes)}: {flashes[:12]}")


if __name__ == "__main__":
    main()
