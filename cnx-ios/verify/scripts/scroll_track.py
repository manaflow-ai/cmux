"""scroll_track.py <video.mp4> <start-s> <duration-s> <out.csv>

Measures how terminal content moves between consecutive recorded frames
during a scroll: for each frame pair, the vertical shift (px at 3x) that best
aligns a band of the screen between the toolbar and the composer, and the
residual mean absolute difference after aligning (0 = the new frame is
exactly the old one moved; a wrong row drawn at a row boundary, a stale
viewport or a tear shows up as a residual spike). Pixel-smooth scrolling
shows shifts that are not multiples of the 48 px row and that change
gradually (deceleration), with residuals near zero.
"""
import json, subprocess, sys
import numpy as np

video, start, dur, out = sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), sys.argv[4]
W, H = 1206, 2622
Y0, Y1 = 420, 2200  # band below the toolbar, above the composer
probe = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v", "-read_intervals", f"{start}%+{dur}",
                        "-show_entries", "frame=pts_time", "-of", "json", video], capture_output=True, text=True, check=True)
times = [float(f["pts_time"]) for f in json.loads(probe.stdout)["frames"] if start <= float(f["pts_time"]) <= start + dur]
proc = subprocess.Popen(["ffmpeg", "-nostdin", "-v", "fatal", "-ss", str(start), "-t", str(dur), "-i", video, "-vf", f"crop={W}:{Y1 - Y0}:0:{Y0}",
                         "-fps_mode", "passthrough", "-enc_time_base", "1/1000", "-f", "rawvideo", "-pix_fmt", "gray", "-"],
                        stdout=subprocess.PIPE)
size = W * (Y1 - Y0)
frames = []
while True:
    buf = proc.stdout.read(size)
    if len(buf) < size:
        break
    frames.append(np.frombuffer(buf, np.uint8).reshape(Y1 - Y0, W).astype(np.float32))
proc.wait()

def best_shift(a, b, limit=1100):
    # Content moving up by s px: b[y] == a[y + s]. Coarse profile match, then exact refine.
    pa, pb = a.mean(axis=1), b.mean(axis=1)
    n = len(pa)
    best = (1e9, 0)
    for s in range(-limit, limit + 1):
        lo, hi = max(0, -s), min(n, n - s)
        if hi - lo < n // 3:
            continue
        err = np.abs(pb[lo:hi] - pa[lo + s:hi + s]).mean()
        if err < best[0]:
            best = (err, s)
    s = best[1]
    lo, hi = max(0, -s), min(n, n - s)
    residual = np.abs(b[lo:hi] - a[lo + s:hi + s]).mean()
    return s, residual

rows = []
for k in range(1, len(frames)):
    s, r = best_shift(frames[k - 1], frames[k])
    t = times[k] if k < len(times) else -1
    dt = (times[k] - times[k - 1]) if k < len(times) else 0
    rows.append((t, dt, s, r))
with open(out, "w") as f:
    f.write("t,dt,shift_px,residual\n")
    for row in rows:
        f.write("%.4f,%.4f,%d,%.3f\n" % row)
moving = [r for r in rows if r[2] != 0]
if moving:
    shifts = [abs(r[2]) for r in moving]
    off_grid = sum(1 for s in shifts if s % 48 != 0)
    print(f"pairs={len(rows)} moving={len(moving)} shift px min={min(shifts)} max={max(shifts)} "
          f"not-row-multiples={off_grid}/{len(moving)} residual max={max(r[3] for r in moving):.2f} "
          f"mean={np.mean([r[3] for r in moving]):.2f}")
