#!/usr/bin/env python3
"""Bezel-less landscape iPad framing for App Store screenshots, via ImageMagick.

frameit has no current/landscape iPad frame, so the iPad is composited here: the
real (latest) iPad screen, rounded corners + soft shadow, on the tranquil
background with a localized title. No drawn/fake bezel. Uses `magick` (the same
C library frameit already requires) for speed and zero extra dependencies (no
Pillow). iPhone shots are framed by frameit; this only touches iPad captures.

Usage: compose_ipad.py <screenshots_dir>
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
MAGICK = shutil.which("magick") or shutil.which("convert")
FONT_CANDIDATES = [
    "/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
    "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
]


def font_path():
    # Prefer the staged title font (next to the screenshots) for parity with frameit.
    return next((c for c in FONT_CANDIDATES if os.path.exists(c)), None)


def load_titles():
    en = json.load(open(os.path.join(HERE, "titles.en.json"), encoding="utf-8"))
    loc = {}
    tj = os.path.join(HERE, "titles.json")
    if os.path.exists(tj):
        loc = json.load(open(tj, encoding="utf-8"))
    return en, loc


def identify(path):
    out = subprocess.check_output([MAGICK, "identify", "-format", "%w %h", path], text=True)
    w, h = out.split()
    return int(w), int(h)


def compose(raw_path, out_path, bg_path, title, font, staged_font):
    W, H = identify(raw_path)
    title_h = int(H * 0.14)
    gap = int(H * 0.03)
    bottom = int(H * 0.05)
    dh = H - title_h - gap - bottom
    dw = int(W * dh / H)
    dx = (W - dw) // 2
    dy = title_h + gap
    r = int(dh * 0.045)
    use_font = staged_font if (staged_font and os.path.exists(staged_font)) else font

    with tempfile.TemporaryDirectory() as tmp:
        base = os.path.join(tmp, "base.png")
        screen = os.path.join(tmp, "screen.png")
        # Background covered to the exact output size.
        subprocess.run([MAGICK, bg_path, "-resize", f"{W}x{H}^", "-gravity", "center",
                        "-extent", f"{W}x{H}", base], check=True)
        # Screen: resize + rounded-corner alpha.
        subprocess.run([
            MAGICK, raw_path, "-resize", f"{dw}x{dh}!",
            "(", "+clone", "-alpha", "transparent", "-background", "none",
            "-fill", "white", "-draw", f"roundrectangle 0,0,{dw-1},{dh-1},{r},{r}", ")",
            "-compose", "DstIn", "-composite", screen,
        ], check=True)
        # Composite a soft shadow, then the screen, then the title caption.
        cmd = [
            MAGICK, base,
            "(", screen, "-background", "black", "-shadow", "55x34+0+16", ")",
            "-gravity", "northwest", "-geometry", f"+{dx-int(dw*0.012)}+{dy-int(dw*0.006)}",
            "-compose", "over", "-composite",
            screen, "-gravity", "northwest", "-geometry", f"+{dx}+{dy}", "-composite",
        ]
        if title:
            cmd += [
                "(", "-background", "none", "-fill", "white",
                "-font", use_font, "-pointsize", str(int(H * 0.052)),
                "-size", f"{int(W * 0.9)}x", "-gravity", "center",
                f"caption:{title}", ")",
                "-gravity", "north", "-geometry", f"+0+{int(H * 0.045)}",
                "-compose", "over", "-composite",
            ]
        cmd += [out_path]
        subprocess.run(cmd, check=True)


def main():
    if not MAGICK:
        raise SystemExit("ImageMagick (magick/convert) not found")
    ss = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else os.path.join(HERE, "..", "screenshots")
    bg_path = os.path.join(HERE, "background.jpg")
    en, loc = load_titles()
    font = font_path()
    n = 0
    for locale in sorted(os.listdir(ss)):
        d = os.path.join(ss, locale)
        if not os.path.isdir(d):
            continue
        staged_font = os.path.join(d, "title_font.ttf")
        titles = loc.get(locale) or loc.get(locale.split("-")[0]) or en
        for f in sorted(os.listdir(d)):
            if not f.endswith(".png") or f.endswith("_framed.png") or "ipad" not in f.lower():
                continue
            m = re.match(r"(.+?)-(\d+)-(.+?)\.png", f)
            if not m:
                continue
            title = titles.get(f"{m.group(2)}-{m.group(3)}") or en.get(f"{m.group(2)}-{m.group(3)}") or ""
            compose(os.path.join(d, f), os.path.join(d, f[:-4] + "_framed.png"),
                    bg_path, title, font, staged_font)
            n += 1
    print(f"composed {n} bezel-less iPad screenshots (ImageMagick)")


if __name__ == "__main__":
    main()
