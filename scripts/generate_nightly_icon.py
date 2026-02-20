#!/usr/bin/env python3
"""Generate nightly app icon variants with a purple 'NIGHTLY' banner.

Follows the same pattern as AppIcon-Debug (orange DEV banner) but uses
a purple banner with 'NIGHTLY' text.
"""
import os
import sys
from PIL import Image, ImageDraw, ImageFont

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC_DIR = os.path.join(REPO, "Assets.xcassets", "AppIcon.appiconset")
DST_DIR = os.path.join(REPO, "Assets.xcassets", "AppIcon-Nightly.appiconset")

# Purple color for nightly (distinct from orange DEV)
BANNER_COLOR = (128, 0, 255)  # vibrant purple
TEXT_COLOR = (255, 255, 255)

# Icon sizes: (filename, pixel_size)
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


def add_nightly_banner(img: Image.Image) -> Image.Image:
    """Add a purple 'NIGHTLY' banner at the bottom of the icon."""
    img = img.convert("RGBA")
    w, h = img.size

    # Banner proportions matching the debug icon style
    banner_height = max(int(h * 0.18), 4)
    banner_y = h - banner_height

    draw = ImageDraw.Draw(img)

    # Draw the banner rectangle
    draw.rectangle([0, banner_y, w, h], fill=BANNER_COLOR)

    # For very small icons (16px), skip text - just use the color band
    if w < 32:
        return img

    # Find a suitable font size
    text = "NIGHTLY"
    target_text_height = int(banner_height * 0.6)
    font_size = max(target_text_height, 6)

    # Try to use a system font
    font = None
    for font_path in [
        "/System/Library/Fonts/SFCompact-Bold.otf",
        "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
        "/System/Library/Fonts/Helvetica.ttc",
        "/Library/Fonts/Arial Bold.ttf",
    ]:
        if os.path.exists(font_path):
            try:
                font = ImageFont.truetype(font_path, font_size)
                break
            except Exception:
                continue

    if font is None:
        font = ImageFont.load_default()

    # Center the text in the banner
    bbox = draw.textbbox((0, 0), text, font=font)
    text_w = bbox[2] - bbox[0]
    text_h = bbox[3] - bbox[1]
    text_x = (w - text_w) // 2
    text_y = banner_y + (banner_height - text_h) // 2 - bbox[1]

    draw.text((text_x, text_y), text, fill=TEXT_COLOR, font=font)

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
        # Resize if needed (shouldn't be, but just in case)
        if img.size != (pixel_size, pixel_size):
            img = img.resize((pixel_size, pixel_size), Image.LANCZOS)

        result = add_nightly_banner(img)
        result.save(dst_path, "PNG")
        print(f"  {filename} ({pixel_size}x{pixel_size})")

    print(f"\nGenerated {len(SIZES)} icons in {DST_DIR}")


if __name__ == "__main__":
    main()
