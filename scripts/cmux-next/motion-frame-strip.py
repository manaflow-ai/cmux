#!/usr/bin/env python3
"""Frame strip for one recorded motion scenario (cx-bqm6, cx-ai79).

Reads OUT/<scenario>/ from sidebar-motion-record.py (`debug.window_record`
JPEGs plus frames.json, and OUT/sidebar.json for the sidebar crop), finds
the first frame that changed, and writes OUT/strip-<scenario>.png: COUNT
crops of the sidebar, EVERY frames apart, each labelled with its frame index
and time since the change. EVERY=1 shows every frame, which is how a motion
change is checked before it lands: each in-between frame must be clean.

Usage: motion-frame-strip.py OUT SCENARIO [EVERY=2] [COUNT=16]
Needs Pillow.
"""
import json
import os
import sys

from PIL import Image, ImageChops, ImageDraw

root, name = sys.argv[1], sys.argv[2]
every = int(sys.argv[3]) if len(sys.argv) > 3 else 2
count = int(sys.argv[4]) if len(sys.argv) > 4 else 16
folder = os.path.join(root, name)
with open(os.path.join(root, "sidebar.json")) as f:
    side = json.load(f)
with open(os.path.join(folder, "frames.json")) as f:
    times = json.load(f)["times"]
frames = sorted(f for f in os.listdir(folder) if f.endswith(".jpg"))
width, height = Image.open(os.path.join(folder, frames[0])).size
# Retina captures are twice the window's points.
px_per_pt = 2 if width > 1600 else 1
crop_w = int(side["width"] * px_per_pt)
bottom = max((r["window_frame"]["y"] + r["window_frame"]["height"] for r in side["rows"]), default=400) + 160
crop_h = min(height, int(bottom * px_per_pt))


def crop(frame):
    return Image.open(os.path.join(folder, frame)).convert("RGB").crop((0, 0, crop_w, crop_h))


first = crop(frames[0])
start = next((i for i, f in enumerate(frames) if ImageChops.difference(first, crop(f)).getbbox()), 0)
pick = list(range(max(0, start - 1), min(len(frames), start - 1 + every * count), every))
shrink = 0.5 if px_per_pt == 2 else 1
tw, th = int(crop_w * shrink), int(crop_h * shrink)
sheet = Image.new("RGB", (tw * len(pick), th + 18), "white")
draw = ImageDraw.Draw(sheet)
for k, i in enumerate(pick):
    sheet.paste(crop(frames[i]).resize((tw, th)), (k * tw, 18))
    draw.text((k * tw + 4, 2), f"#{i} {1000 * (times[i] - times[start]):+.0f}ms", fill="black")
out = os.path.join(root, f"strip-{name}.png")
sheet.save(out)
print(out, "start frame", start, "of", len(frames))
