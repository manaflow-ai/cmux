#!/usr/bin/env python3
"""Score scroll smoothness in an iPhone screen recording of a list.

Usage: ios/scripts/scroll-smoothness.py RECORDING.mp4 [--scale 3] [--csv OUT.csv]
Requires numpy (python3 -m pip install numpy) and ffmpeg.

For every pair of frames it finds the vertical shift that best aligns the list
area. Because list rows repeat, each coarse candidate and its one- and two-row
aliases are re-scored at full pixel resolution, where the row text tells them
apart. From that motion it reports:
- layout shifts: frames where rows moved relative to each other (alignment
  still leaves a residual), which rigid scrolling never produces;
- stalls: frames with no movement in the middle of a scroll, and catch-ups:
  frames that jump well past what their neighbours predict. Together they are
  missed display deadlines, which read as a jerk or a jump;
- hitch ratio: milliseconds of missed frames per second of scrolling (Apple:
  under 5 good, over 10 critical).

Record on the device (Control Center screen recording is a steady 60 fps).
Simulator recordings are variable rate and are not a reliable input.
"""
import argparse, json, subprocess
import numpy as np

parser = argparse.ArgumentParser()
parser.add_argument("video")
parser.add_argument("--scale", type=int, default=3, help="device pixels per point")
parser.add_argument("--csv", help="write per-frame motion here")
args = parser.parse_args()
video, scale = args.video, args.scale

probe = json.loads(subprocess.check_output([
    "ffprobe", "-v", "error", "-select_streams", "v:0",
    "-show_entries", "stream=width,height:frame=pts_time", "-of", "json", video]))
w, h = probe["streams"][0]["width"], probe["streams"][0]["height"]
pts = [float(f["pts_time"]) for f in probe["frames"]]
raw = subprocess.check_output(["ffmpeg", "-v", "error", "-i", video, "-fps_mode", "passthrough",
                               "-vf", "format=gray", "-f", "rawvideo", "-"])
full = np.frombuffer(raw, np.uint8).reshape(-1, h, w)
W, H = w // scale, h // scale
coarse = full[:, :H * scale, :W * scale].reshape(-1, H, scale, W, scale).mean(axis=(2, 4))
top, bottom = int(H * 0.11), int(H * 0.80)
left, right = int(W * 0.03), int(W * 0.93)
max_shift = 140
pitch = 92


def coarse_errors(a, b):
    band = b[top + max_shift:bottom - max_shift, left:right]
    return np.array([
        np.mean(np.abs(a[top + max_shift + s:bottom - max_shift + s, left:right] - band))
        for s in range(-max_shift, max_shift + 1)])


def fine_error(a, b, shift_px):
    m = max_shift * scale
    t, bt = top * scale + m, bottom * scale - m
    l, r = left * scale, right * scale
    return float(np.mean(np.abs(a[t + shift_px:bt + shift_px, l:r].astype(np.int16)
                                - b[t:bt, l:r].astype(np.int16))))


motion = []
for i in range(1, min(len(full), len(pts))):
    errs = coarse_errors(coarse[i - 1], coarse[i])
    if float(errs[max_shift]) == 0.0:
        motion.append((pts[i], pts[i] - pts[i - 1], 0.0, 0.0))
        continue
    best = int(np.argmin(errs)) - max_shift
    scored = []
    for k in (-2, -1, 0, 1, 2):
        c = best + k * pitch
        if abs(c) > max_shift:
            continue
        for d in range(-scale, scale + 1):
            px = c * scale + d
            if abs(px) <= max_shift * scale:
                scored.append((fine_error(full[i - 1], full[i], px), px))
    err, px = min(scored)
    motion.append((pts[i], pts[i] - pts[i - 1], px / scale, err))

if args.csv:
    with open(args.csv, "w") as f:
        f.write("t,dt,shift_pt,residual\n")
        for row in motion:
            f.write("%.4f,%.4f,%.2f,%.3f\n" % row)

t = np.array([m[0] for m in motion]); dt = np.array([m[1] for m in motion])
v = np.array([m[2] for m in motion]); res = np.array([m[3] for m in motion])
frame = float(np.median(dt)) if len(dt) else 1 / 60
moving = np.abs(v) >= 0.5
stalls, catchups, shifts = [], [], []
scroll_time = hitch_ms = 0.0
for i in range(len(motion)):
    near = [j for j in range(max(0, i - 3), min(len(motion), i + 4)) if j != i and moving[j]]
    in_motion = any(j < i for j in near) and any(j > i for j in near)
    if not in_motion and not moving[i]:
        continue
    scroll_time += dt[i]
    missed = max(0.0, round(dt[i] / frame) - 1)
    predicted = float(np.median(np.abs(v[near]))) if near else 0.0
    if not moving[i] and in_motion and predicted >= 1.5:
        missed += 1
        stalls.append((t[i], predicted))
    elif moving[i] and predicted >= 1.5 and abs(v[i]) > 1.8 * predicted + 2:
        catchups.append((t[i], v[i], predicted))
    hitch_ms += missed * frame * 1000
    if res[i] > 1.0:
        shifts.append((t[i], res[i]))

print(f"scrolling {scroll_time:.2f}s  layout shifts {len(shifts)}  stalls {len(stalls)}  "
      f"catch-ups {len(catchups)}  hitch ratio {hitch_ms / max(scroll_time, 1e-6):.1f} ms/s")
for s in shifts:
    print(f"  shift   t={s[0]:.3f}s residual {s[1]:.2f}")
for s in stalls:
    print(f"  stall   t={s[0]:.3f}s expected ~{s[1]:.1f}pt/frame")
for c in catchups:
    print(f"  catchup t={c[0]:.3f}s moved {c[1]:.1f}pt vs ~{c[2]:.1f}")
