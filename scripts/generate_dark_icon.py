#!/usr/bin/env python3
"""Generate dark mode app icon variants.

Composites the Figma chevron layer (on transparent background) over a dark
squircle background derived from the light icon's alpha channel. This
preserves the exact chevron colors and glow without any halo artifacts.

Requires the Figma export at: design/cmux-icon-chevron.png
Falls back to mathematical recomposition if the Figma layer is missing.
"""
import json
import os
import sys

from PIL import Image, ImageFilter

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Apple systemBackground dark
DARK_BG = (28, 28, 30)

# Figma chevron layer (exported from Figma at native resolution)
FIGMA_CHEVRON = os.path.join(REPO, "design", "cmux-icon-chevron.png")

# The Figma export is ~25% larger than the repo icon. Scale and offset
# computed by matching the solid chevron (sat>0.5) bounding box center
# between the repo light icon and the scaled Figma chevron layer.
FIGMA_SCALE = 0.7996
FIGMA_OFFSET = (290, 187)

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


def make_dark_from_figma(light_1024: Image.Image, chevron: Image.Image) -> Image.Image:
    """Create dark icon by compositing Figma chevron over dark background.

    Uses the light icon's alpha channel for the squircle shape mask,
    fills it with the dark background color, then composites the
    chevron layer on top at the precomputed offset.
    """
    size = 1024
    light = light_1024.convert("RGBA")
    if light.size != (size, size):
        light = light.resize((size, size), Image.LANCZOS)

    # Create dark background with the squircle shape from the light icon
    dark_bg = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    light_px = light.load()
    dark_px = dark_bg.load()
    for y in range(size):
        for x in range(size):
            _, _, _, a = light_px[x, y]
            if a > 0:
                dark_px[x, y] = (DARK_BG[0], DARK_BG[1], DARK_BG[2], a)

    # Scale chevron
    chev = chevron.convert("RGBA")
    cw, ch = chev.size
    scaled_w = int(cw * FIGMA_SCALE)
    scaled_h = int(ch * FIGMA_SCALE)
    chev = chev.resize((scaled_w, scaled_h), Image.LANCZOS)
    ox, oy = FIGMA_OFFSET

    # Build enhanced glow: brighten the chevron, blur at two radii
    glow_src = chev.copy()
    glow_px = glow_src.load()
    for y in range(scaled_h):
        for x in range(scaled_w):
            r, g, b, a = glow_px[x, y]
            if a > 0:
                glow_px[x, y] = (
                    min(255, int(r * 1.2)),
                    min(255, int(g * 1.2)),
                    min(255, int(b * 1.2)),
                    min(255, int(a * 1.1)),
                )

    glow_canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    glow_canvas.paste(glow_src, (ox, oy), glow_src)

    # Wide soft glow + tighter glow
    glow_wide = glow_canvas.filter(ImageFilter.GaussianBlur(radius=25))
    glow_tight = glow_canvas.filter(ImageFilter.GaussianBlur(radius=12))

    # Reduce glow opacity
    for glow, factor in [(glow_wide, 0.45), (glow_tight, 0.35)]:
        gpx = glow.load()
        for y in range(size):
            for x in range(size):
                r, g, b, a = gpx[x, y]
                gpx[x, y] = (r, g, b, int(a * factor))

    # Composite: dark bg -> wide glow -> tight glow -> sharp chevron
    result = Image.alpha_composite(dark_bg, glow_wide)
    result = Image.alpha_composite(result, glow_tight)
    chev_canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    chev_canvas.paste(chev, (ox, oy), chev)
    result = Image.alpha_composite(result, chev_canvas)

    return result


def make_dark_fallback(img: Image.Image) -> Image.Image:
    """Fallback: mathematical recomposition when Figma layer is unavailable."""
    img = img.convert("RGBA")
    w, h = img.size
    pixels = img.load()

    for y in range(h):
        for x in range(w):
            r, g, b, a = pixels[x, y]
            if a == 0:
                continue
            max_dev = max(255 - r, 255 - g, 255 - b)
            fg_alpha = min(max_dev / 60.0, 1.0)
            bg_factor = 1.0 - fg_alpha
            nr = max(0, int(r - bg_factor * (255 - DARK_BG[0])))
            ng = max(0, int(g - bg_factor * (255 - DARK_BG[1])))
            nb = max(0, int(b - bg_factor * (255 - DARK_BG[2])))
            pixels[x, y] = (nr, ng, nb, a)

    return img


def update_contents_json(icon_dir: str) -> None:
    """Add dark appearance entries to Contents.json."""
    contents_path = os.path.join(icon_dir, "Contents.json")
    with open(contents_path) as f:
        contents = json.load(f)

    # Remove any existing dark entries to avoid duplicates
    images = [
        img for img in contents["images"]
        if not any(
            ap.get("value") == "dark"
            for ap in img.get("appearances", [])
        )
    ]

    dark_images = []
    for img in images:
        filename = img.get("filename", "")
        if not filename:
            continue
        base, ext = os.path.splitext(filename)
        dark_entry = {
            "appearances": [
                {"appearance": "luminosity", "value": "dark"}
            ],
            "filename": f"{base}_dark{ext}",
            "idiom": img["idiom"],
            "scale": img["scale"],
            "size": img["size"],
        }
        dark_images.append(dark_entry)

    # Interleave: light, dark, light, dark, ...
    merged = []
    for i, img in enumerate(images):
        merged.append(img)
        if i < len(dark_images):
            merged.append(dark_images[i])

    contents["images"] = merged
    with open(contents_path, "w") as f:
        json.dump(contents, f, indent=2)
        f.write("\n")
    print(f"  Updated {contents_path}")


def generate_dark_icons(icon_set: str) -> None:
    """Generate dark variants for an icon set."""
    src_dir = os.path.join(REPO, "Assets.xcassets", f"{icon_set}.appiconset")
    if not os.path.isdir(src_dir):
        print(f"SKIP {icon_set} (not found)")
        return

    use_figma = os.path.exists(FIGMA_CHEVRON)
    if use_figma:
        print(f"\n{icon_set} (using Figma chevron layer):")
        chevron = Image.open(FIGMA_CHEVRON)
        light_1024_path = os.path.join(src_dir, "512@2x.png")
        light_1024 = Image.open(light_1024_path)
        dark_1024 = make_dark_from_figma(light_1024, chevron)
    else:
        print(f"\n{icon_set} (fallback: mathematical recomposition):")
        dark_1024 = None

    for filename, pixel_size in SIZES:
        src_path = os.path.join(src_dir, filename)
        if not os.path.exists(src_path):
            print(f"  SKIP {filename} (not found)")
            continue

        base, ext = os.path.splitext(filename)
        dst_path = os.path.join(src_dir, f"{base}_dark{ext}")

        if use_figma:
            # Downscale the 1024x1024 Figma composite
            dark_img = dark_1024.resize((pixel_size, pixel_size), Image.LANCZOS)
        else:
            img = Image.open(src_path)
            if img.size != (pixel_size, pixel_size):
                img = img.resize((pixel_size, pixel_size), Image.LANCZOS)
            dark_img = make_dark_fallback(img)

        dark_img.save(dst_path, "PNG")
        print(f"  {base}_dark{ext} ({pixel_size}x{pixel_size})")

    update_contents_json(src_dir)


def main():
    generate_dark_icons("AppIcon")


if __name__ == "__main__":
    main()
