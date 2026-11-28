"""Render cmux-next backdrop art (cx-t2x.7): 1600x1000 AVIF plus measured metadata.

Usage: render_backdrop_art.py SRC_DIR framing.json OUT_DIR   (needs Pillow with AVIF)

SRC_DIR holds the Commons downloads as <slug>.jpg (about 2560 px long side; the URLs are in
art/manifest.json). framing.json maps slug -> one of:
  {"mode": "auto"}
      wide works (>= 1.15:1) crop to 16:10 with text on the darker half; others go "side".
  {"mode": "crop", "box": [x0, y0, x1, y1], "focal": [x, y], "quiet": "left"|"right"}
      box in source fractions; it is widened/narrowed to 16:10 around its centre.
  {"mode": "side", "side": "left"|"right", "scale": 1.0}
      the whole work at canvas height on that side, over a blurred, darkened
      cover-fill of itself; the text sits on the other side.
Optional per slug: "quality" (AVIF, default 50), "darken" (side backdrop, default 0.32),
"inset" [l, t, r, b] fractions trimmed first (frames, arched tops), "circle" (round works),
"trim": false (keep near-uniform margins, which are otherwise trimmed).
Writes OUT_DIR/<slug>.avif, OUT_DIR/preview/<slug>.jpg and OUT_DIR/metadata.json.
"""
import json
import sys
from pathlib import Path

from PIL import Image, ImageFilter, ImageEnhance, ImageOps

W, H = 1600, 1000


def luminance(rgb):
    def lin(c):
        c = c / 255
        return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4
    r, g, b = rgb
    return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)


def cover(img, w, h):
    return ImageOps.fit(img, (w, h), Image.LANCZOS)


def render_crop(img, spec):
    sw, sh = img.size
    x0, y0, x1, y1 = spec["box"]
    bw, bh = (x1 - x0) * sw, (y1 - y0) * sh
    cx, cy = (x0 + x1) / 2 * sw, (y0 + y1) / 2 * sh
    if bw / bh > W / H:
        bh = bw * H / W
    else:
        bw = bh * W / H
    if bw > sw:
        bw, bh = sw, sw * H / W
    if bh > sh:
        bh, bw = sh, sh * W / H
    left = min(max(cx - bw / 2, 0), sw - bw)
    top = min(max(cy - bh / 2, 0), sh - bh)
    out = img.crop((round(left), round(top), round(left + bw), round(top + bh))).resize((W, H), Image.LANCZOS)
    focal = spec.get("focal", [0.5, 0.45])
    return out, focal, spec.get("quiet", "left")


def render_side(img, spec):
    side = spec["side"]
    scale = spec.get("scale", 1.0)
    back = cover(img, W, H).filter(ImageFilter.GaussianBlur(48))
    back = ImageEnhance.Brightness(back).enhance(spec.get("darken", 0.32))
    fh = round(H * scale)
    fw = round(img.width * fh / img.height)
    if fw > W * 0.75:
        fw = round(W * 0.75)
        fh = round(img.height * fw / img.width)
    front = img.resize((fw, fh), Image.LANCZOS)
    x = W - fw if side == "right" else 0
    y = (H - fh) // 2
    # Feather the inner edge into the backdrop.
    feather = max(8, round(fw * 0.08))
    mask = Image.new("L", (fw, fh), 255)
    px = mask.load()
    if spec.get("circle"):
        from PIL import ImageDraw
        mask = Image.new("L", (fw, fh), 0)
        ImageDraw.Draw(mask).ellipse((2, 2, fw - 3, fh - 3), fill=255)
        mask = mask.filter(ImageFilter.GaussianBlur(3))
        feather = 0
    for i in range(feather):
        a = round(255 * (i + 1) / (feather + 1))
        col = i if side == "right" else fw - 1 - i
        for j in range(fh):
            px[col, j] = a
    back.paste(front, (x, y), mask)
    focal = [(x + fw / 2) / W, 0.45]
    quiet = "left" if side == "right" else "right"
    return back, focal, quiet


def extremes(img):
    """The darkest and lightest pixels at full size: the legibility floor must hold over every
    one of them, so a moon or a flame a downscale would average away still counts."""
    colors = img.convert("RGB").getcolors(maxcolors=1 << 24)
    by_luminance = sorted((luminance(color), color) for _, color in colors)
    return by_luminance[0][1], by_luminance[-1][1]


def measure(img, quiet):
    small = img.resize((160, 100), Image.BILINEAR)
    lums = [luminance(p) for p in small.getdata()]
    mean = sum(lums) / len(lums)
    darkest, lightest = extremes(img)
    qx = (0, 64) if quiet == "left" else (96, 160)
    qpix = [small.getpixel((x, y)) for x in range(*qx) for y in range(100)]
    qmean = sum(luminance(p) for p in qpix) / len(qpix)
    pal = small.quantize(colors=3, method=Image.Quantize.MEDIANCUT)
    counts = sorted(pal.getcolors(), reverse=True)
    raw = pal.getpalette()
    palette = [raw[i * 3:i * 3 + 3] for _, i in counts]
    return {
        "tone": "dark" if mean < 0.16 else "light",
        "mean_luminance": round(mean, 4),
        "quiet_luminance": round(qmean, 4),
        "darkest": list(darkest),
        "lightest": list(lightest),
        "palette": palette,
    }


def trim_margins(img, limit=0.12):
    """Drops near-uniform border rows/columns (paper margins, frames' flat edges, scan borders)."""
    gray = img.convert("L")
    w, h = gray.size
    def flat(box):
        region = gray.crop(box)
        hist = region.histogram()
        n = sum(hist)
        mean = sum(i * c for i, c in enumerate(hist)) / n
        var = sum(c * (i - mean) ** 2 for i, c in enumerate(hist)) / n
        return var ** 0.5 < 9
    top = 0
    while top < h * limit and flat((0, top, w, top + 2)):
        top += 2
    bottom = h
    while h - bottom < h * limit and flat((0, bottom - 2, w, bottom)):
        bottom -= 2
    left = 0
    while left < w * limit and flat((left, top, left + 2, bottom)):
        left += 2
    right = w
    while w - right < w * limit and flat((right - 2, top, right, bottom)):
        right -= 2
    return img.crop((left, top, right, bottom))


def auto_spec(img):
    w, h = img.size
    if w / h >= 1.15:
        gray = img.convert("L").resize((64, 32))
        left = sum(gray.crop((0, 0, 32, 32)).getdata())
        right = sum(gray.crop((32, 0, 64, 32)).getdata())
        quiet = "left" if left <= right else "right"
        return {"mode": "crop", "box": [0, 0, 1, 1], "focal": [0.5, 0.45], "quiet": quiet}
    return {"mode": "side", "side": "right"}


def main():
    src, crops_path, out = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
    crops = json.loads(crops_path.read_text())
    (out / "preview").mkdir(parents=True, exist_ok=True)
    meta = {}
    for slug, spec in crops.items():
        img = Image.open(src / f"{slug}.jpg").convert("RGB")
        if spec.get("trim", True):
            img = trim_margins(img)
        if "inset" in spec:
            l, t, r, b = spec["inset"]
            img = img.crop((round(img.width * l), round(img.height * t),
                            round(img.width * (1 - r)), round(img.height * (1 - b))))
        if spec.get("mode", "auto") == "auto":
            spec = {**auto_spec(img), **{k: v for k, v in spec.items() if k != "mode"}}
        if spec["mode"] == "crop":
            rendered, focal, quiet = render_crop(img, spec)
        else:
            rendered, focal, quiet = render_side(img, spec)
        path = out / f"{slug}.avif"
        rendered.save(path, "AVIF", quality=spec.get("quality", 50), speed=4)
        rendered.resize((480, 300), Image.LANCZOS).save(out / "preview" / f"{slug}.jpg", quality=80)
        info = measure(rendered, quiet)
        info.update({"focal": [round(focal[0], 3), round(focal[1], 3)], "quiet": quiet,
                     "bytes": path.stat().st_size})
        meta[slug] = info
        info["mode"] = spec["mode"]
        print(slug, info["bytes"], info["tone"], info["mean_luminance"], flush=True)
    (out / "metadata.json").write_text(json.dumps(meta, indent=1))


if __name__ == "__main__":
    main()
