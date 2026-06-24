#!/usr/bin/env python3
"""Bezel-less landscape iPad framing for App Store screenshots.

frameit has no current/landscape iPad frame, so the iPad is composited here: the
real (latest) iPad screen, rounded corners + soft shadow, on the tranquil
background with a localized title. No drawn/fake bezel. Output keeps the captured
landscape pixel size (a valid App Store iPad size). iPhone shots are framed by
frameit; this only touches iPad captures.

Usage: compose_ipad.py <screenshots_dir>
"""
import json
import os
import re
import sys
from PIL import Image, ImageDraw, ImageFont, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
FONT_CANDIDATES = [
    "/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
    "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
]


def font_path():
    for c in FONT_CANDIDATES:
        if os.path.exists(c):
            return c
    raise SystemExit("no usable title font found")


def load_titles():
    en = json.load(open(os.path.join(HERE, "titles.en.json"), encoding="utf-8"))
    loc = {}
    tj = os.path.join(HERE, "titles.json")
    if os.path.exists(tj):
        loc = json.load(open(tj, encoding="utf-8"))
    return en, loc


def wrap(draw, text, font, max_w):
    if " " not in text:  # CJK
        lines, cur = [], ""
        for ch in text:
            if draw.textlength(cur + ch, font=font) <= max_w:
                cur += ch
            else:
                lines.append(cur); cur = ch
        if cur:
            lines.append(cur)
        return lines
    lines, cur = [], ""
    for w in text.split(" "):
        t = (cur + " " + w).strip()
        if draw.textlength(t, font=font) <= max_w:
            cur = t
        else:
            lines.append(cur); cur = w
    if cur:
        lines.append(cur)
    return lines


def compose(raw_path, out_path, bg_img, title, fpath):
    shot = Image.open(raw_path).convert("RGB")
    W, H = shot.size
    canvas = bg_img.resize((W, H)).convert("RGBA")
    draw = ImageDraw.Draw(canvas)

    title_size = int(H * 0.050)
    font = ImageFont.truetype(fpath, title_size)
    lines = wrap(draw, title, font, int(W * 0.9))
    line_h = int(title_size * 1.2)
    top = int(H * 0.045)
    y = top
    for ln in lines:
        w = draw.textlength(ln, font=font)
        draw.text(((W - w) / 2, y), ln, font=font, fill=(255, 255, 255))
        y += line_h

    title_zone = top + line_h * len(lines) + int(H * 0.03)
    avail_h = H - title_zone - int(H * 0.05)
    scale = avail_h / H
    dw, dh = int(W * scale), int(H * scale)
    dev = shot.resize((dw, dh))
    radius = int(dh * 0.045)

    dx = (W - dw) // 2
    dy = title_zone

    shadow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    pad = int(dw * 0.012)
    ImageDraw.Draw(shadow).rounded_rectangle(
        [dx - pad, dy - pad, dx + dw + pad, dy + dh + pad],
        radius=radius + pad, fill=(0, 0, 0, 120))
    shadow = shadow.filter(ImageFilter.GaussianBlur(int(dw * 0.02)))
    canvas = Image.alpha_composite(canvas, shadow)

    mask = Image.new("L", (dw, dh), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, dw, dh], radius=radius, fill=255)
    canvas.paste(dev, (dx, dy), mask)
    canvas.convert("RGB").save(out_path, quality=92)


def main():
    ss = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else os.path.join(HERE, "..", "screenshots")
    bg = Image.open(os.path.join(HERE, "background.jpg"))
    en, loc = load_titles()
    fpath = font_path()
    n = 0
    for locale in sorted(os.listdir(ss)):
        d = os.path.join(ss, locale)
        if not os.path.isdir(d):
            continue
        titles = loc.get(locale) or loc.get(locale.split("-")[0]) or en
        for f in sorted(os.listdir(d)):
            if not f.endswith(".png") or f.endswith("_framed.png") or "ipad" not in f.lower():
                continue
            m = re.match(r"(.+?)-(\d+)-(.+?)\.png", f)
            if not m:
                continue
            title = titles.get(f"{m.group(2)}-{m.group(3)}") or en.get(f"{m.group(2)}-{m.group(3)}") or ""
            compose(os.path.join(d, f), os.path.join(d, f[:-4] + "_framed.png"), bg, title, fpath)
            n += 1
    print(f"composed {n} bezel-less iPad screenshots")


if __name__ == "__main__":
    main()
