#!/usr/bin/env python3
"""Generate nightly app icon by recoloring the Debug icon.

Takes the AppIcon-Debug icons (which have an orange "DEV" banner) and:
1. Recolors the orange banner to purple
2. Replaces the "DEV" text with "NIGHTLY"

This preserves the exact same icon design, glow effects, and chevron
positioning as the debug icon.
"""
import os
from PIL import Image, ImageDraw, ImageFont

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC_DIR = os.path.join(REPO, "Assets.xcassets", "AppIcon-Debug.appiconset")
DST_DIR = os.path.join(REPO, "Assets.xcassets", "AppIcon-Nightly.appiconset")

# Debug banner color: (255, 107, 0) orange
# Target: purple
PURPLE = (140, 60, 220)

SIZES = [
    ("16.png", 16),
    ("16@2x.png", 32),
    ("32.png", 32),
    ("32@2x.png", 64),
    ("128.png", 128),
    ("128@2x.png", 256),
    ("256.png", 256),
    ("256@2x.png", 512),
    ("512.png", 512),
    ("512@2x.png", 1024),
]


def recolor_banner(img: Image.Image) -> Image.Image:
    """Recolor the orange banner to purple and replace DEV with NIGHTLY."""
    img = img.convert("RGBA")
    w, h = img.size
    pixels = img.load()

    # Pass 1: Recolor orange pixels to purple.
    # The debug icon's banner is (255, 107, 0) with anti-aliased edges.
    # We detect "orange-ish" pixels and remap them to purple, preserving
    # the relative luminance and alpha for smooth edges.
    for y in range(h):
        for x in range(w):
            r, g, b, a = pixels[x, y]
            if a == 0:
                continue
            # Detect orange: high R, moderate G, very low B
            if r > 180 and g < 180 and b < 100 and r > g and r - b > 100:
                # How "orange" is this pixel (0-1)?
                # Pure orange = (255,107,0), so measure closeness
                orange_strength = min(r / 255.0, 1.0)
                # Remap to purple, preserving the intensity
                nr = int(PURPLE[0] * orange_strength)
                ng = int(PURPLE[1] * orange_strength)
                nb = int(PURPLE[2] * orange_strength)
                pixels[x, y] = (nr, ng, nb, a)

    # Pass 2: Replace the "DEV" text with "NIGHTLY".
    # First, blank out the existing text by filling the text region with
    # the banner color, then draw "NIGHTLY" centered.
    #
    # The banner occupies roughly the bottom 18% of the icon.
    banner_y = int(h * 0.82)
    banner_h = h - banner_y

    # Find the text bounding box by looking for white/light pixels in the banner
    # (the DEV text is white on orange, now white on purple)
    text_pixels = []
    for y in range(banner_y, h):
        for x in range(w):
            r, g, b, a = pixels[x, y]
            # White or near-white text pixels
            if r > 220 and g > 220 and b > 220 and a > 200:
                text_pixels.append((x, y))

    if text_pixels:
        # Erase old text by painting over with the banner purple
        min_x = min(p[0] for p in text_pixels)
        max_x = max(p[0] for p in text_pixels)
        min_y = min(p[1] for p in text_pixels)
        max_y = max(p[1] for p in text_pixels)

        # Expand slightly to catch anti-aliased edges
        pad = max(2, int(h * 0.005))
        min_x = max(0, min_x - pad)
        max_x = min(w - 1, max_x + pad)
        min_y = max(banner_y, min_y - pad)
        max_y = min(h - 1, max_y + pad)

        # Fill the text area with the banner color
        draw = ImageDraw.Draw(img)
        draw.rectangle([min_x, min_y, max_x, max_y], fill=(*PURPLE, 255))

        # Now draw "NIGHTLY" centered in the banner
        text = "NIGHTLY"
        text_area_h = max_y - min_y
        font_size = max(int(text_area_h * 0.85), 6)

        font = None
        for font_path in [
            "/System/Library/Fonts/SFCompact-Bold.otf",
            "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
            "/System/Library/Fonts/Helvetica.ttc",
        ]:
            if os.path.exists(font_path):
                try:
                    font = ImageFont.truetype(font_path, font_size)
                    break
                except Exception:
                    continue
        if font is None:
            font = ImageFont.load_default()

        # Center in the banner
        bbox = draw.textbbox((0, 0), text, font=font)
        tw = bbox[2] - bbox[0]
        th = bbox[3] - bbox[1]
        tx = (w - tw) // 2
        ty = banner_y + (banner_h - th) // 2 - bbox[1]

        draw.text((tx, ty), text, fill=(255, 255, 255, 255), font=font)

    return img


def main():
    os.makedirs(DST_DIR, exist_ok=True)

    for filename, pixel_size in SIZES:
        src_path = os.path.join(SRC_DIR, filename)
        dst_path = os.path.join(DST_DIR, filename)

        if not os.path.exists(src_path):
            print(f"  SKIP {filename} (source not found)")
            continue

        img = Image.open(src_path)
        if img.size != (pixel_size, pixel_size):
            img = img.resize((pixel_size, pixel_size), Image.LANCZOS)

        result = recolor_banner(img)
        result.save(dst_path, "PNG")
        print(f"  {filename} ({pixel_size}x{pixel_size})")

    print(f"\nGenerated {len(SIZES)} icons in {DST_DIR}")


if __name__ == "__main__":
    main()
