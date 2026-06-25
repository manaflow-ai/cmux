#!/usr/bin/env python3
"""Compose premium App Store screenshots with ImageMagick.

- iPhone: the screenshot is masked to the device frame's REAL screen opening
  (extracted from the frame's alpha, so the screen follows the bezel's exact
  rounded corners) and placed under the real iPhone 17 Pro Max frame, large and
  bleeding off the bottom, under a bold SF Pro header.
- iPad (landscape): large bezel-less rounded screen with a bold header (frameit
  has no current/landscape iPad frame).
- Agent shots (Claude/Codex/OpenCode/pi) show the agent's logo before the header.
- Backgrounds are tranquil nature photos (bg_portrait/bg_landscape).

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
LOGO_DIR = os.path.join(HERE, "logos")
MAGICK = shutil.which("magick") or shutil.which("convert")
FRAME_DIR = os.path.expanduser("~/.fastlane/frameit/latest")
IPHONE_FRAME = "Apple iPhone 17 Pro Max Silver.png"
IPHONE_FRAME_URL = ("https://fastlane.github.io/frameit-frames/latest/"
                    "Apple%20iPhone%2017%20Pro%20Max%20Silver.png")
IPHONE_SCREEN_OFFSET = (75, 66)
IPHONE_FRAME_SIZE = (1470, 3000)
# The iPhone 17 Pro Max frame PNG paints the physical cutouts (a pill + a
# separate camera hole). iOS renders one unified black Dynamic Island, so we
# paint a single rounded pill over the frame's island. Coords are in frame
# space (calibrated to this frame's island bbox); r = height/2 for a full pill.
IPHONE_ISLAND = (547, 99, 922, 210, 55)
BG_P_DIR = os.path.join(HERE, "backgrounds", "p")
BG_L_DIR = os.path.join(HERE, "backgrounds", "l")

SF_PRO = "/System/Library/Fonts/SFNS.ttf"
FONT_UNICODE = "/System/Library/Fonts/Supplemental/Arial Unicode.ttf"
FONT_CANDIDATES = [SF_PRO, "/System/Library/Fonts/SFNSRounded.ttf", FONT_UNICODE,
                   "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"]
# shot name (from <Device>-<NN>-<Name>.png) -> agent logo file
LOGOS = {"claude": "Claude.png", "codex": "Codex.png", "opencode": "OpenCode.png", "pi": "Pi.png"}


def bg_list(d, fallback):
    if os.path.isdir(d):
        fs = sorted(os.path.join(d, f) for f in os.listdir(d)
                    if f.lower().endswith((".jpg", ".jpeg", ".png")))
        if fs:
            return fs
    return [fallback]


def font_for(title):
    if any(ord(c) > 0x52F for c in title) and os.path.exists(FONT_UNICODE):
        return FONT_UNICODE
    return next((c for c in FONT_CANDIDATES if os.path.exists(c)), FONT_UNICODE)


def ensure_iphone_frame():
    path = os.path.join(FRAME_DIR, IPHONE_FRAME)
    if not os.path.exists(path):
        os.makedirs(FRAME_DIR, exist_ok=True)
        urllib.request.urlretrieve(IPHONE_FRAME_URL, path)
    return path


def build_opening_mask(frame, out):
    # White = the frame's screen opening (the transparent region enclosed by the
    # opaque bezel). bezel->white; flood-fill the OUTER transparent area from a
    # corner; the still-black inner region is the opening, so invert.
    tmp = out + ".bezel.png"
    subprocess.run([MAGICK, frame, "-alpha", "extract", "-threshold", "50%", tmp], check=True)
    subprocess.run([MAGICK, tmp, "-bordercolor", "black", "-border", "1",
                    "-fill", "white", "-draw", "color 0,0 floodfill", "-shave", "1x1",
                    "-negate", out], check=True)
    os.remove(tmp)


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


def header_image(tmp, title, font, pt, box_w, logo):
    cap = os.path.join(tmp, "cap.png")
    cmd = [MAGICK, "-background", "none", "-fill", "white", "-font", font]
    if font == SF_PRO:
        cmd += ["-weight", "800"]
    cmd += ["-pointsize", str(pt), "-size", f"{box_w}x", "-gravity", "center",
            f"caption:{title}", "-trim", "+repage", cap]
    subprocess.run(cmd, check=True)
    if not logo or not os.path.exists(logo):
        return cap
    out = os.path.join(tmp, "header.png")
    # Small inline logo: roughly the title's cap height, sitting just before the
    # text (not a big badge). +smush joins them horizontally, vertically centered.
    lh = int(pt * 0.82)
    lg = os.path.join(tmp, "lg.png")
    subprocess.run([MAGICK, logo, "-resize", f"{lh}x{lh}", lg], check=True)
    subprocess.run([MAGICK, lg, cap, "-background", "none", "+smush", str(int(pt * 0.2)), out], check=True)
    return out


def compose_iphone(raw, out, bg, frame, mask, title, font, logo):
    cw, ch = 1320, 2868
    fw, fh = IPHONE_FRAME_SIZE
    ox, oy = IPHONE_SCREEN_OFFSET
    with tempfile.TemporaryDirectory() as tmp:
        placed = os.path.join(tmp, "placed.png")
        masked = os.path.join(tmp, "masked.png")
        device = os.path.join(tmp, "device.png")
        subprocess.run([MAGICK, "-size", f"{fw}x{fh}", "xc:black",
                        "(", raw, "-geometry", f"+{ox}+{oy}", ")", "-composite", placed], check=True)
        subprocess.run([MAGICK, placed, mask, "-alpha", "off",
                        "-compose", "CopyOpacity", "-composite", masked], check=True)
        subprocess.run([MAGICK, "-size", f"{fw}x{fh}", "xc:none",
                        masked, "-composite", frame, "-composite", device], check=True)
        # Unify the Dynamic Island (cover the frame's pill + camera hole).
        x0, y0, x1, y1, r = IPHONE_ISLAND
        subprocess.run([MAGICK, device, "-fill", "black",
                        "-draw", f"roundrectangle {x0},{y0},{x1},{y1},{r},{r}", device], check=True)
        dw = int(cw * 0.95)
        dh = int(fh * dw / fw)
        dy = int(ch * 0.165)
        base = os.path.join(tmp, "base.png")
        subprocess.run([MAGICK, bg, "-resize", f"{cw}x{ch}^", "-gravity", "center",
                        "-extent", f"{cw}x{ch}", base], check=True)
        hdr = header_image(tmp, title, font, 104, int(cw * 0.9), logo)
        subprocess.run([
            MAGICK, base,
            "(", device, "-resize", f"{dw}x{dh}!",
            "(", "+clone", "-background", "black", "-shadow", "55x42+0+26", ")", "+swap",
            "-background", "none", "-layers", "merge", "+repage", ")",
            "-gravity", "north", "-geometry", f"+0+{dy}", "-compose", "over", "-composite",
            hdr, "-gravity", "north", "-geometry", f"+0+{int(ch*0.05)}", "-compose", "over", "-composite",
            out,
        ], check=True)


def compose_ipad(raw, out, bg, title, font, logo):
    w, h = identify(raw)
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
                        "(", "+clone", "-alpha", "transparent", "-background", "none", "-fill", "white",
                        "-draw", f"roundrectangle 0,0,{dw-1},{dh-1},{r},{r}", ")",
                        "-compose", "DstIn", "-composite", screen], check=True)
        hdr = header_image(tmp, title, font, int(h * 0.05), int(w * 0.8), logo)
        subprocess.run([
            MAGICK, base,
            "(", screen, "-background", "black", "-shadow", "55x40+0+22", ")",
            "-gravity", "northwest", "-geometry", f"+{dx-int(dw*0.012)}+{dy-int(dw*0.006)}",
            "-compose", "over", "-composite",
            screen, "-gravity", "northwest", "-geometry", f"+{dx}+{dy}", "-composite",
            hdr, "-gravity", "north", "-geometry", f"+0+{int(h*0.04)}", "-compose", "over", "-composite",
            out,
        ], check=True)


def main():
    if not MAGICK:
        raise SystemExit("ImageMagick not found")
    ss = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else os.path.join(HERE, "..", "screenshots")
    # Per-screen backgrounds: each screen (01..06) gets its own bg from the set,
    # so the listing has varied (not repeated) backdrops. iPhone + iPad of the
    # same screen share a theme (same index). Falls back to the single legacy bg.
    bgs_p = bg_list(BG_P_DIR, os.path.join(HERE, "bg_portrait.jpg"))
    bgs_l = bg_list(BG_L_DIR, os.path.join(HERE, "bg_landscape.jpg"))
    frame = ensure_iphone_frame()
    mask = os.path.join(tempfile.gettempdir(), "cmux_iphone_opening_mask.png")
    build_opening_mask(frame, mask)
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
            name = m.group(3)
            title = titles.get(f"{m.group(2)}-{name}") or en.get(f"{m.group(2)}-{name}") or ""
            font = font_for(title)
            logo_file = LOGOS.get(name.lower())
            logo = os.path.join(LOGO_DIR, logo_file) if logo_file else None
            src, dst = os.path.join(d, f), os.path.join(d, f[:-4] + "_framed.png")
            idx = int(m.group(2)) - 1  # screen 01 -> bg index 0
            if "ipad" in m.group(1).lower():
                compose_ipad(src, dst, bgs_l[idx % len(bgs_l)], title, font, logo)
            else:
                compose_iphone(src, dst, bgs_p[idx % len(bgs_p)], frame, mask, title, font, logo)
            n += 1
    print(f"composed {n} framed screenshots")


if __name__ == "__main__":
    main()
