#!/usr/bin/env python3
"""Build a labelled contact sheet from a PNG frame directory.
Usage: contact.py <frames_dir> <out.png> [cols] [thumb_width] [first] [last] [step]
Env CROP=x0,y0,x1,y1 (points, 3x frames) crops each frame first."""
import glob, os, sys
from PIL import Image, ImageDraw

d, out = sys.argv[1], sys.argv[2]
cols = int(sys.argv[3]) if len(sys.argv) > 3 else 10
tw = int(sys.argv[4]) if len(sys.argv) > 4 else 201
files = sorted(glob.glob(os.path.join(d, "*.png")))
first = int(sys.argv[5]) if len(sys.argv) > 5 else 1
last = int(sys.argv[6]) if len(sys.argv) > 6 else len(files)
step = int(sys.argv[7]) if len(sys.argv) > 7 else 1
sel = [(i, files[i - 1]) for i in range(first, last + 1, step)]
crop = [int(float(v) * 3) for v in os.environ["CROP"].split(",")] if os.environ.get("CROP") else None
def load(f):
    im = Image.open(f).convert("RGB")
    return im.crop(crop) if crop else im
im0 = load(sel[0][1]); th = int(im0.height * tw / im0.width)
rows = (len(sel) + cols - 1) // cols
sheet = Image.new("RGB", (cols * (tw + 4) + 4, rows * (th + 4) + 4), (128, 128, 128))
dr = ImageDraw.Draw(sheet)
for k, (i, f) in enumerate(sel):
    x, y = 4 + (k % cols) * (tw + 4), 4 + (k // cols) * (th + 4)
    sheet.paste(load(f).resize((tw, th), Image.LANCZOS), (x, y))
    dr.rectangle([x, y, x + 46, y + 16], fill=(255, 255, 255))
    dr.text((x + 3, y + 2), f"{i} {1000*(i-1)/60:.0f}ms", fill=(220, 0, 0))
sheet.save(out)
print(out, len(sel), "frames")
