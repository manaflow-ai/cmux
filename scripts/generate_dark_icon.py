#!/usr/bin/env python3
"""Generate dark mode app icon variants.

Takes the AppIcon PNGs (white background with blue chevron) and creates
dark mode variants by recompositing the foreground over a dark background.

The algorithm estimates foreground opacity from each pixel's deviation from
white, then recomposites that foreground over the dark background color.
This preserves the chevron gradient and handles anti-aliased edges cleanly.
"""
import json
import os

from PIL import Image

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Apple systemBackground dark
DARK_BG = (28, 28, 30)

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


def make_dark(img: Image.Image) -> Image.Image:
    """Convert a light-background icon to dark-background.

    For each pixel, estimates the foreground alpha from max deviation from
    white, then recomposites over the dark background:
        new_channel = original - (1 - fg_alpha) * (255 - dark_bg)
    """
    img = img.convert("RGBA")
    w, h = img.size
    pixels = img.load()

    for y in range(h):
        for x in range(w):
            r, g, b, a = pixels[x, y]
            if a == 0:
                continue

            # Foreground alpha: how much this pixel deviates from white
            max_dev = max(255 - r, 255 - g, 255 - b)
            fg_alpha = max_dev / 255.0

            # Recomposite: C' = C - (1-a)*(255-D)
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

    # Add dark entries for each size
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

    print(f"\n{icon_set}:")
    for filename, pixel_size in SIZES:
        src_path = os.path.join(src_dir, filename)
        if not os.path.exists(src_path):
            print(f"  SKIP {filename} (not found)")
            continue

        base, ext = os.path.splitext(filename)
        dst_path = os.path.join(src_dir, f"{base}_dark{ext}")

        img = Image.open(src_path)
        if img.size != (pixel_size, pixel_size):
            img = img.resize((pixel_size, pixel_size), Image.LANCZOS)

        dark_img = make_dark(img)
        dark_img.save(dst_path, "PNG")
        print(f"  {base}_dark{ext} ({pixel_size}x{pixel_size})")

    update_contents_json(src_dir)


def main():
    # Only generate for the main AppIcon (release builds).
    # Debug and Nightly icons can be extended later.
    generate_dark_icons("AppIcon")


if __name__ == "__main__":
    main()
