#!/usr/bin/env python3
"""Generate the release candidate app icon by recoloring the Debug icon."""
import os
from PIL import Image, ImageDraw, ImageFont

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC_DIR = os.path.join(REPO, "Assets.xcassets", "AppIcon-Debug.appiconset")
DST_DIR = os.path.join(REPO, "Assets.xcassets", "AppIcon-RC.appiconset")

TEAL = (0, 150, 136)

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


def load_font(size: int) -> ImageFont.ImageFont:
    for font_path in [
        "/System/Library/Fonts/SFCompact-Bold.otf",
        "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
        "/System/Library/Fonts/Helvetica.ttc",
    ]:
        if os.path.exists(font_path):
            try:
                return ImageFont.truetype(font_path, size)
            except Exception:
                continue
    return ImageFont.load_default()


def recolor_banner(img: Image.Image) -> Image.Image:
    img = img.convert("RGBA")
    w, h = img.size
    pixels = img.load()

    for y in range(h):
        for x in range(w):
            r, g, b, a = pixels[x, y]
            if a == 0:
                continue
            if r > 180 and g < 180 and b < 100 and r > g and r - b > 100:
                orange_strength = min(r / 255.0, 1.0)
                pixels[x, y] = (
                    int(TEAL[0] * orange_strength),
                    int(TEAL[1] * orange_strength),
                    int(TEAL[2] * orange_strength),
                    a,
                )

    banner_y = int(h * 0.82)
    banner_h = h - banner_y
    text_pixels = []

    for y in range(banner_y, h):
        for x in range(w):
            r, g, b, a = pixels[x, y]
            if r > 220 and g > 220 and b > 220 and a > 200:
                text_pixels.append((x, y))

    if not text_pixels:
        return img

    min_x = min(p[0] for p in text_pixels)
    max_x = max(p[0] for p in text_pixels)
    min_y = min(p[1] for p in text_pixels)
    max_y = max(p[1] for p in text_pixels)
    pad = max(2, int(h * 0.005))
    min_x = max(0, min_x - pad)
    max_x = min(w - 1, max_x + pad)
    min_y = max(banner_y, min_y - pad)
    max_y = min(h - 1, max_y + pad)

    draw = ImageDraw.Draw(img)
    draw.rectangle([min_x, min_y, max_x, max_y], fill=(*TEAL, 255))

    text = "RC"
    text_area_h = max_y - min_y
    font = load_font(max(int(text_area_h * 1.05), 6))
    bbox = draw.textbbox((0, 0), text, font=font)
    tw = bbox[2] - bbox[0]
    th = bbox[3] - bbox[1]
    tx = (w - tw) // 2
    ty = banner_y + (banner_h - th) // 2 - bbox[1]
    draw.text((tx, ty), text, fill=(255, 255, 255, 255), font=font)
    return img


def main() -> None:
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

        recolor_banner(img).save(dst_path, "PNG")
        print(f"  {filename} ({pixel_size}x{pixel_size})")

    print(f"\nGenerated {len(SIZES)} icons in {DST_DIR}")


if __name__ == "__main__":
    main()
