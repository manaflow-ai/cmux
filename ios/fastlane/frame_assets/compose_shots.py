#!/usr/bin/env python3
"""Compose premium App Store screenshots with ImageMagick.

Why this instead of `fastlane frameit` directly: frameit fits the whole (tall)
device under the title inside the fixed App Store canvas, which shrinks the
device and leaves big dead margins. Here we stitch the screenshot into the real
device frame ourselves and place it LARGE (bleeding off the bottom) under a bold
header, for a polished, full composition. We still use frameit's real frame PNGs
(the same Facebook Design frames frameit uses), downloaded on demand.

- iPhone: real iPhone 17 Pro Max frame (Silver), stitched + large + bold header.
- iPad (landscape): bezel-less rounded screen, large, + bold header (frameit has
  no current/landscape iPad frame).

Usage: compose_shots.py <screenshots_dir>
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
MAGICK = shutil.which("magick") or shutil.which("convert")
FRAME_DIR = os.path.expanduser("~/.fastlane/frameit/latest")
IPHONE_FRAME = "Apple iPhone 17 Pro Max Silver.png"
IPHONE_FRAME_URL = ("https://fastlane.github.io/frameit-frames/latest/"
                    "Apple%20iPhone%2017%20Pro%20Max%20Silver.png")
# Screen offset of the screenshot inside the frame (from frameit offsets.json).
IPHONE_SCREEN_OFFSET = (75, 66)
IPHONE_FRAME_SIZE = (1470, 3000)

# Apple's SF Pro for the header (the native iOS font); a Unicode font covers
# locales SF Pro lacks glyphs for (CJK, Arabic, Hebrew, Thai, Hindi, ...).
SF_PRO = "/System/Library/Fonts/SFNS.ttf"
FONT_UNICODE = "/System/Library/Fonts/Supplemental/Arial Unicode.ttf"
FONT_CANDIDATES = [SF_PRO, "/System/Library/Fonts/SFNSRounded.ttf", FONT_UNICODE,
                   "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"]


def font_for(title):
    # SF Pro for Latin/Cyrillic/Greek; fall back to a Unicode font for scripts
    # SF Pro doesn't cover (CJK etc.).
    if any(ord(c) > 0x52F for c in title) and os.path.exists(FONT_UNICODE):
        return FONT_UNICODE
    return next((c for c in FONT_CANDIDATES if os.path.exists(c)), FONT_UNICODE)


def ensure_iphone_frame():
    path = os.path.join(FRAME_DIR, IPHONE_FRAME)
    if not os.path.exists(path):
        os.makedirs(FRAME_DIR, exist_ok=True)
        urllib.request.urlretrieve(IPHONE_FRAME_URL, path)
    return path


def load_titles():
    en = json.load(open(os.path.join(HERE, "titles.en.json"), encoding="utf-8"))
    loc = {}
    tj = os.path.join(HERE, "titles.json")
    if os.path.exists(tj):
        loc = json.load(open(tj, encoding="utf-8"))
    return en, loc


def identify(path):
    w, h = subprocess.check_output([MAGICK, "identify", "-format", "%w %h", path], text=True).split()
    return int(w), int(h)


def header_layer(tmp, title, cw, font, pt, box_w, box_h):
    cap = os.path.join(tmp, "cap.png")
    cmd = [MAGICK, "-background", "none", "-fill", "white", "-font", font]
    if font == SF_PRO:  # SF Pro is a variable font; render heavy for a bold header
        cmd += ["-weight", "800"]
    cmd += ["-pointsize", str(pt), "-size", f"{box_w}x{box_h}", "-gravity", "center",
            f"caption:{title}", cap]
    subprocess.run(cmd, check=True)
    return cap


def compose_iphone(raw, out, bg, title, frame):
    cw, ch = 1320, 2868
    fw, fh = IPHONE_FRAME_SIZE
    ox, oy = IPHONE_SCREEN_OFFSET
    font = font_for(title)
    with tempfile.TemporaryDirectory() as tmp:
        device = os.path.join(tmp, "device.png")
        subprocess.run([MAGICK, "-size", f"{fw}x{fh}", "xc:none",
                        "(", raw, "-geometry", f"+{ox}+{oy}", ")", "-composite",
                        frame, "-composite", device], check=True)
        dw = int(cw * 0.885)
        dh = int(fh * dw / fw)
        dx = (cw - dw) // 2
        dy = int(ch * 0.18)
        base = os.path.join(tmp, "base.png")
        subprocess.run([MAGICK, bg, "-resize", f"{cw}x{ch}^", "-gravity", "center",
                        "-extent", f"{cw}x{ch}", base], check=True)
        cap = header_layer(tmp, title, cw, font, 120, int(cw * 0.88), 320)
        subprocess.run([
            MAGICK, base,
            "(", device, "-resize", f"{dw}x{dh}!",
            "(", "+clone", "-background", "black", "-shadow", "55x42+0+26", ")", "+swap",
            "-background", "none", "-layers", "merge", "+repage", ")",
            "-gravity", "north", "-geometry", f"+0+{dy}", "-compose", "over", "-composite",
            cap, "-gravity", "north", "-geometry", f"+0+{int(ch*0.05)}", "-compose", "over", "-composite",
            out,
        ], check=True)


def compose_ipad(raw, out, bg, title):
    w, h = identify(raw)
    font = font_for(title)
    with tempfile.TemporaryDirectory() as tmp:
        dh = int(h * 0.80)
        dw = int(w * dh / h)
        r = int(dh * 0.05)
        dx = (w - dw) // 2
        dy = int(h * 0.165)
        base = os.path.join(tmp, "base.png")
        screen = os.path.join(tmp, "screen.png")
        subprocess.run([MAGICK, bg, "-resize", f"{w}x{h}^", "-gravity", "center",
                        "-extent", f"{w}x{h}", base], check=True)
        subprocess.run([MAGICK, raw, "-resize", f"{dw}x{dh}!",
                        "(", "+clone", "-alpha", "transparent", "-background", "none",
                        "-fill", "white", "-draw", f"roundrectangle 0,0,{dw-1},{dh-1},{r},{r}", ")",
                        "-compose", "DstIn", "-composite", screen], check=True)
        cap = header_layer(tmp, title, w, font, int(h * 0.05), int(w * 0.8), int(h * 0.12))
        subprocess.run([
            MAGICK, base,
            "(", screen, "-background", "black", "-shadow", "55x40+0+22", ")",
            "-gravity", "northwest", "-geometry", f"+{dx-int(dw*0.012)}+{dy-int(dw*0.006)}",
            "-compose", "over", "-composite",
            screen, "-gravity", "northwest", "-geometry", f"+{dx}+{dy}", "-composite",
            cap, "-gravity", "north", "-geometry", f"+0+{int(h*0.04)}", "-compose", "over", "-composite",
            out,
        ], check=True)


def main():
    if not MAGICK:
        raise SystemExit("ImageMagick not found")
    ss = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else os.path.join(HERE, "..", "screenshots")
    bg_portrait = os.path.join(HERE, "bg_portrait.jpg")
    bg_landscape = os.path.join(HERE, "bg_landscape.jpg")
    frame = ensure_iphone_frame()
    en, loc = load_titles()
    n = 0
    for locale in sorted(os.listdir(ss)):
        d = os.path.join(ss, locale)
        if not os.path.isdir(d):
            continue
        titles = loc.get(locale) or loc.get(locale.split("-")[0]) or en
        for f in sorted(os.listdir(d)):
            if not f.endswith(".png") or f.endswith("_framed.png"):
                continue
            m = re.match(r"(.+?)-(\d+)-(.+?)\.png", f)
            if not m:
                continue
            title = titles.get(f"{m.group(2)}-{m.group(3)}") or en.get(f"{m.group(2)}-{m.group(3)}") or ""
            src, dst = os.path.join(d, f), os.path.join(d, f[:-4] + "_framed.png")
            if "ipad" in m.group(1).lower():
                compose_ipad(src, dst, bg_landscape, title)
            else:
                compose_iphone(src, dst, bg_portrait, title, frame)
            n += 1
    print(f"composed {n} framed screenshots")


if __name__ == "__main__":
    main()
