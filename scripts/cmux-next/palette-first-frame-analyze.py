#!/usr/bin/env python3
"""Per-display-frame palette opens from a launch recording: find each open, write contact sheets and videos.

analyze.py FRAMES_DIR OUT_DIR LABEL

An "open" is a frame whose mean absolute difference from the frame before is large after a quiet stretch.
For each open it writes OUT/LABEL-open-K.png: the frame before and the next 6 frames side by side (index and ms on
each), and prints, per frame, how much it differs from the frame after it settled (frame +12), so a pill that
comes in one frame late shows as frame +1 differing from settled while +2 does not.
"""
import json
import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageStat

frames_dir, out, label = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
out.mkdir(parents=True, exist_ok=True)
meta = json.loads((frames_dir / "frames.json").read_text())
rows = meta["frames"] if isinstance(meta, dict) else meta
files = sorted(frames_dir.glob("frame-*.jpg"))
times = [float(r.get("t", r.get("time", r.get("seconds", 0)))) if isinstance(r, dict) else float(r) for r in rows]
print(f"{label}: {len(files)} frames, keys {list(rows[0].keys()) if rows and isinstance(rows[0], dict) else '?'}")


def small(i):
    return Image.open(files[i]).convert("L").resize((240, 150))


def diff(a, b):
    return ImageStat.Stat(ImageChops.difference(a, b)).mean[0]


thumbs = [small(i) for i in range(len(files))]
d = [0.0] + [diff(thumbs[i - 1], thumbs[i]) for i in range(1, len(files))]
opens, quiet = [], 0
for i, v in enumerate(d):
    if v > 2.0 and quiet >= 10:
        opens.append(i)
    quiet = quiet + 1 if v <= 0.6 else 0
report = []
for k, i in enumerate(opens):
    settled = min(i + 12, len(files) - 1)
    row = []
    for j in range(i - 1, min(i + 6, len(files))):
        row.append({"frame": j, "ms": round((times[j] - times[i - 1]) * 1000, 1) if times else None,
                    "vs_prev": round(d[j], 2), "vs_settled": round(diff(thumbs[j], thumbs[settled]), 2)})
    report.append({"open": k, "first_frame": i, "settled_frame": settled, "frames": row})
    print(json.dumps(report[-1]))
    imgs = [Image.open(files[j]).convert("RGB") for j in range(i - 1, min(i + 6, len(files)))]
    w, h = imgs[0].size
    scale = 560 / w
    tw, th = int(w * scale), int(h * scale)
    sheet = Image.new("RGB", (tw * len(imgs), th + 28), "white")
    draw = ImageDraw.Draw(sheet)
    for n, im in enumerate(imgs):
        sheet.paste(im.resize((tw, th)), (n * tw, 28))
        r = row[n]
        draw.text((n * tw + 6, 6), f"{label} frame {r['frame']} ({'before key' if n == 0 else f'+{n}'}) {r['ms']} ms",
                  fill="black")
    sheet.save(out / f"{label}-open-{k}.png")
    seg = out / f"{label}-open-{k}"
    seg.mkdir(exist_ok=True)
    for n, j in enumerate(range(max(0, i - 15), min(i + 45, len(files)))):
        (seg / f"f-{n:04d}.jpg").write_bytes(files[j].read_bytes())
(out / f"{label}-report.json").write_text(json.dumps(report, indent=1))
fps = round((len(times) - 1) / (times[-1] - times[0])) if len(times) > 1 and times[-1] > times[0] else 60
vf = "pad=ceil(iw/2)*2:ceil(ih/2)*2"
subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-framerate", str(fps), "-pattern_type", "glob", "-i",
                str(frames_dir / "frame-*.jpg"), "-vf", vf, "-pix_fmt", "yuv420p", str(out / f"{label}-realtime.mp4")],
               check=True)
subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-framerate", "4", "-pattern_type", "glob", "-i",
                str(frames_dir / "frame-*.jpg"), "-vf", vf, "-pix_fmt", "yuv420p", str(out / f"{label}-4fps.mp4")],
               check=True)
print(f"fps {fps}; wrote {out}")
