#!/usr/bin/env python3
"""Audit how cmux-next frames each backdrop painting across window shapes and pane layouts.

Usage: framing_sheet.py [--sheet OUT.png] [--only ID,ID]   (the sheet needs Pillow with AVIF)

It mirrors BackdropArtMetadata.placement (Packages/macOS/CmuxNext/Sources/CmuxNextDesign/
BackdropArtPlacement.swift) over art/manifest.json's `subject` boxes and prints, for each window
shape, how many works keep their subject whole in the part of the window the sidebar and a docked
agent chat leave visible, how many shrink over the blurred fill, and which lose part of it. With
--sheet it draws every work at every shape: the subject box in green, the covered columns shaded.
Keep the constants in step with the Swift file.
"""
import argparse
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
MANIFEST = ROOT / "art/manifest.json"
FULL = ROOT / "art/full"
IMAGE = (1600, 1000)
MAXIMUM_ZOOM = 1.4
MINIMUM_SHRINK = 0.7
NARROWEST = 0.35
SIDEBAR = 240
AGENT = 420
# (name, window size, covered columns in points from the left edge)
SHAPES = [
    ("16:10", (1512, 945), []),
    ("16:10 sidebar+agent", (1512, 945), [(0, SIDEBAR), (SIDEBAR, SIDEBAR + AGENT)]),
    ("21:9 sidebar+agent", (2560, 1080), [(0, SIDEBAR), (SIDEBAR, SIDEBAR + AGENT)]),
    ("half screen", (756, 945), []),
    ("half screen agent", (756, 945), [(0, AGENT * 0.6)]),
]


def visible_span(width, covered):
    gaps, start = [], 0.0
    for low, high in sorted((min(max(a, 0), width), min(max(b, 0), width)) for a, b in covered):
        if low > start:
            gaps.append((start, low))
        start = max(start, high)
    if start < width:
        gaps.append((start, width))
    widest = max(gaps, key=lambda g: g[1] - g[0], default=(0, width))
    if (widest[1] - widest[0]) / width < NARROWEST:
        return (0, width)
    return widest


class Axis:
    def __init__(self, view, image, subject, span, soft=False):
        self.view, self.image, self.subject, self.span, self.soft = view, image, subject, span, soft

    def centered(self, scale):
        return (self.span[0] + self.span[1]) / 2 - (self.subject[0] + self.subject[1]) / 2 * self.image * scale

    def covering(self, scale):
        extent = self.image * scale
        low = max(self.view - extent, self.span[0] - self.subject[0] * extent)
        high = min(0, self.span[1] - self.subject[1] * extent)
        if low > high + 1e-6:
            if not self.soft:
                return None
            # Too tall: keep the subject's top (the heads), as near as covering allows.
            return min(max(self.span[0] - self.subject[0] * extent, self.view - extent), 0)
        return min(max(self.centered(scale), low), max(low, high))

    def nearest(self, scale):
        return min(max(self.centered(scale), self.view - self.image * scale), 0)

    def shrunk(self, scale):
        extent = self.image * scale
        low = self.span[0] - self.subject[0] * extent
        high = self.span[1] - self.subject[1] * extent
        centered = min(max(self.centered(scale), low), max(low, high))
        if extent >= self.view:
            return min(max(centered, max(low, self.view - extent)), min(max(low, high), 0))
        return centered


def placement(subject, view, span):
    """(scale, origin x, origin y, outcome) with outcome 'keeps', 'fills' or 'cuts'."""
    vw, vh = view
    iw, ih = IMAGE
    cover = max(vw / iw, vh / ih)
    x = Axis(vw, iw, (subject[0], subject[2]), span)
    y = Axis(vh, ih, (subject[1], subject[3]), (0, vh), soft=True)
    steps = 16
    for step in range(steps + 1):
        scale = cover * (1 + (MAXIMUM_ZOOM - 1) * step / steps)
        ox, oy = x.covering(scale), y.covering(scale)
        if ox is not None and oy is not None:
            return scale, ox, oy, "keeps"
    fit = min((span[1] - span[0]) / (iw * max(subject[2] - subject[0], 0.01)), cover)
    if fit >= cover * MINIMUM_SHRINK:
        return fit, x.shrunk(fit), y.covering(fit) if fit == cover else y.shrunk(fit), "fills"
    return cover, x.nearest(cover), y.nearest(cover), "cuts"


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--sheet", type=Path)
    parser.add_argument("--only")
    args = parser.parse_args()
    works = json.loads(MANIFEST.read_text())["works"]
    if args.only:
        wanted = set(args.only.split(","))
        works = [w for w in works if w["id"] in wanted]
    rows = []
    for name, view, covered in SHAPES:
        span = visible_span(view[0], covered)
        counts = {"keeps": 0, "fills": 0, "cuts": []}
        for work in works:
            result = placement(work["subject"], view, span)
            rows.append((work, name, view, covered, result))
            if result[3] == "cuts":
                counts["cuts"].append(work["id"])
            else:
                counts[result[3]] += 1
        print(f"{name:22} keeps {counts['keeps']:3}  fills {counts['fills']:3}  cuts {len(counts['cuts']):3}  "
              + " ".join(counts["cuts"][:8]) + (" …" if len(counts["cuts"]) > 8 else ""))
    if args.sheet:
        draw(rows, works, args.sheet)


def draw(rows, works, out):
    from PIL import Image, ImageDraw, ImageFilter
    scale = 0.12
    cells = [(round(v[0] * scale), round(v[1] * scale)) for _, v, _ in SHAPES]
    width = sum(c[0] for c in cells) + 10 * len(cells) + 10
    height = max(c[1] for c in cells) + 22
    sheet = Image.new("RGB", (width, height * len(works) + 10), "white")
    for index, work in enumerate(works):
        art = Image.open(FULL / f"{work['id']}.avif").convert("RGB")
        blurred = art.filter(ImageFilter.GaussianBlur(24))
        x0, y0 = 10, index * height + 18
        ImageDraw.Draw(sheet).text((10, y0 - 15), work["id"], fill="black")
        for (_, view, covered), cell in zip(SHAPES, cells):
            row = next(r for r in rows if r[0] is work and r[2] == view and r[3] == covered)
            s, ox, oy, outcome = row[4]
            canvas = blurred.resize(cell)
            shown = art.resize((max(1, round(IMAGE[0] * s * scale)), max(1, round(IMAGE[1] * s * scale))))
            canvas.paste(shown, (round(ox * scale), round(oy * scale)))
            d = ImageDraw.Draw(canvas, "RGBA")
            for a, b in covered:
                d.rectangle((a * scale, 0, b * scale, cell[1]), fill=(0, 0, 0, 140))
            sx = [ox + v * IMAGE[0] * s for v in (work["subject"][0], work["subject"][2])]
            sy = [oy + v * IMAGE[1] * s for v in (work["subject"][1], work["subject"][3])]
            color = {"keeps": (0, 220, 0), "fills": (0, 160, 255), "cuts": (255, 40, 40)}[outcome]
            d.rectangle((sx[0] * scale, sy[0] * scale, sx[1] * scale, sy[1] * scale), outline=color, width=2)
            sheet.paste(canvas, (x0, y0))
            x0 += cell[0] + 10
    sheet.save(out)
    print("wrote", out)


if __name__ == "__main__":
    main()
