#!/usr/bin/env python3
"""Render a 1024x1024 App Store subscription promotional image in the cmux brand.

The mark is the app icon's chevron (ios/cmux/Assets.xcassets/AppIcon.appiconset),
redrawn as a vector so it stays sharp, with the icon's cyan-to-indigo gradient and
glow. The background is the deep navy-to-indigo field of the App Store
screenshots (ios/AppStoreReview/screenshots). No text: the App Store shows the
subscription's display name and price next to the image.

Usage: render_promotional_image.py OUT.png   (needs Pillow)
"""
import sys

from PIL import Image, ImageChops, ImageDraw, ImageFilter

SIZE = 1024
SS = 4  # supersampling factor
# Chevron outline on the app icon's 1024 grid.
CHEVRON = [(324, 196), (782, 514), (324, 832), (324, 690), (570, 514), (324, 338)]
CYAN = (5, 206, 255)
INDIGO = (84, 108, 244)
BG_TOP_LEFT = (12, 29, 39)
BG_CENTER = (26, 62, 110)
BG_BOTTOM_RIGHT = (37, 43, 95)


def lerp(a, b, t):
    return tuple(round(x + (y - x) * t) for x, y in zip(a, b))


def background(n):
    """Diagonal navy-to-indigo field with a soft lift in the middle."""
    img = Image.new("RGB", (n, n))
    px = img.load()
    for y in range(n):
        for x in range(n):
            t = (x + y) / (2 * (n - 1))
            base = lerp(BG_TOP_LEFT, BG_CENTER, t * 2) if t < 0.5 else lerp(BG_CENTER, BG_BOTTOM_RIGHT, (t - 0.5) * 2)
            dx, dy = x / n - 0.5, y / n - 0.5
            lift = max(0.0, 1.0 - (dx * dx + dy * dy) * 4.0) * 0.18
            px[x, y] = lerp(base, (60, 110, 190), lift)
    return img


def gradient(n):
    """Horizontal cyan-to-indigo gradient over the chevron's x span."""
    img = Image.new("RGB", (n, n))
    draw = ImageDraw.Draw(img)
    x0, x1 = 324 * n / 1024, 782 * n / 1024
    for x in range(n):
        t = min(1.0, max(0.0, (x - x0) / (x1 - x0)))
        draw.line([(x, 0), (x, n)], fill=lerp(CYAN, INDIGO, t ** 1.4))
    return img


def main(out):
    n = SIZE * SS
    # Center the chevron (bounds x 324..782, y 196..832 on the icon grid), nudged
    # right 28 px so its visual mass, which sits left of its bounding box, is centered.
    scale = 0.78
    cx, cy = (324 + 782) / 2, (196 + 832) / 2
    pts = [((x - cx) * scale + 512 + 28, (y - cy) * scale + 512) for x, y in CHEVRON]
    pts = [(x * SS, y * SS) for x, y in pts]

    mask = Image.new("L", (n, n), 0)
    ImageDraw.Draw(mask).polygon(pts, fill=255)

    canvas = background(SIZE).resize((n, n), Image.BICUBIC)

    # Glow: the icon's blue halo, wide and faint, then tight and brighter.
    for radius, strength, color in ((90, 0.55, (40, 150, 255)), (28, 0.65, (70, 190, 255))):
        halo = mask.filter(ImageFilter.GaussianBlur(radius * SS / 2))
        halo = halo.point(lambda v, s=strength: round(v * s))
        canvas = Image.composite(Image.new("RGB", (n, n), color), canvas, halo)

    fill = gradient(n)
    canvas = Image.composite(fill, canvas, mask)

    # A faint top-edge highlight on the mark, as on the icon.
    edge = ImageChops.subtract(mask, mask.transform(mask.size, Image.AFFINE, (1, 0, 0, 0, 1, -8 * SS)))
    edge = edge.filter(ImageFilter.GaussianBlur(3 * SS)).point(lambda v: round(v * 0.25))
    canvas = Image.composite(Image.new("RGB", (n, n), (255, 255, 255)), canvas, edge)

    canvas.resize((SIZE, SIZE), Image.LANCZOS).save(out, "PNG", optimize=True)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
