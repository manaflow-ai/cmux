#!/usr/bin/env python3
"""Comparison sheets: the top of each capture, stacked with a label, one sheet per appearance.

  sheet.py --out SHEET.png --rows "Label=path.png[@x,y,w,h]" ...   (crop in pixels; default: the top 200 px, 1400 px wide)
"""
import argparse
from PIL import Image, ImageDraw, ImageFont

p = argparse.ArgumentParser()
p.add_argument("--out", required=True)
p.add_argument("--rows", nargs="+", required=True)
p.add_argument("--width", type=int, default=1400)
p.add_argument("--height", type=int, default=200)
p.add_argument("--dark", action="store_true")
a = p.parse_args()
font = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", 26)
label_h = 40
tiles = []
for row in a.rows:
    label, spec = row.split("=", 1)
    path, _, crop = spec.partition("@")
    image = Image.open(path).convert("RGB")
    x, y, w, h = (int(v) for v in crop.split(",")) if crop else (0, 0, a.width, a.height)
    tiles.append((label, image.crop((x, y, x + w, y + h))))
width = max(t.width for _, t in tiles)
sheet = Image.new("RGB", (width, sum(label_h + t.height for _, t in tiles)), (30, 30, 30) if a.dark else (250, 250, 250))
draw = ImageDraw.Draw(sheet)
y = 0
for label, tile in tiles:
    draw.text((8, y + 6), label, font=font, fill=(235, 235, 235) if a.dark else (20, 20, 20))
    sheet.paste(tile, (0, y + label_h))
    y += label_h + tile.height
sheet.save(a.out)
print(a.out, sheet.size)
