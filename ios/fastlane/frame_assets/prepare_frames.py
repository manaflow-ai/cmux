#!/usr/bin/env python3
"""Stage frameit assets into the captured screenshots directory.

- Copies Framefile.json + background.jpg into <screenshots>/.
- Writes a localized title.strings into each <screenshots>/<locale>/ dir from
  titles.json (localized) with titles.en.json as the fallback.

Usage: prepare_frames.py [screenshots_dir]
Default screenshots_dir: ../screenshots relative to this file.
"""
import json
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

# frameit has no frame for the 13" iPad Pro M4/M5 (2064x2752 -> "unsupported
# screen size"), but it does frame the 12.9" iPad Pro (2048x2732). Resize iPad
# captures to 12.9" so the real frame applies; Apple accepts 2048x2732 for the
# 13"/12.9" iPad class.
IPAD_13 = (2064, 2752)
IPAD_129 = (2048, 2732)


def resize_ipad_captures(ss):
    for root, _dirs, files in os.walk(ss):
        for f in files:
            if not f.endswith(".png") or f.endswith("_framed.png") or "ipad" not in f.lower():
                continue
            p = os.path.join(root, f)
            try:
                dims = subprocess.check_output(
                    ["sips", "-g", "pixelWidth", "-g", "pixelHeight", p], text=True)
            except Exception:
                continue
            if f"pixelWidth: {IPAD_13[0]}" in dims and f"pixelHeight: {IPAD_13[1]}" in dims:
                subprocess.run(["sips", "-z", str(IPAD_129[1]), str(IPAD_129[0]), p],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                print(f"resized iPad capture to 12.9\": {os.path.relpath(p, ss)}")


def load_titles():
    en = json.load(open(os.path.join(HERE, "titles.en.json"), encoding="utf-8"))
    localized = {}
    tj = os.path.join(HERE, "titles.json")
    if os.path.exists(tj):
        localized = json.load(open(tj, encoding="utf-8"))
    return en, localized


def main():
    ss = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "..", "screenshots")
    ss = os.path.abspath(ss)
    if not os.path.isdir(ss):
        raise SystemExit(f"screenshots dir not found: {ss}")

    resize_ipad_captures(ss)

    shutil.copy(os.path.join(HERE, "Framefile.json"), os.path.join(ss, "Framefile.json"))
    shutil.copy(os.path.join(HERE, "background.jpg"), os.path.join(ss, "background.jpg"))

    # frameit resolves Framefile "font" relative to the screenshots dir, so stage
    # a title font there. Prefer a bundled font; else copy a system font (macOS
    # CI + local). Not committed when sourced from the system (licensing).
    font_dest = os.path.join(ss, "title_font.ttf")
    bundled = os.path.join(HERE, "title_font.ttf")
    if os.path.exists(bundled):
        shutil.copy(bundled, font_dest)
    else:
        candidates = [
            "/System/Library/Fonts/Supplemental/Arial Rounded Bold.ttf",
            "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
            "/System/Library/Fonts/Supplemental/Arial.ttf",
            "/Library/Fonts/Arial.ttf",
            "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
        ]
        src_font = next((c for c in candidates if os.path.exists(c)), None)
        if not src_font:
            raise SystemExit("no title font found; bundle frame_assets/title_font.ttf")
        shutil.copy(src_font, font_dest)
    print(f"title font staged from {'bundled' if os.path.exists(bundled) else 'system'}")

    en, localized = load_titles()
    for loc in sorted(os.listdir(ss)):
        d = os.path.join(ss, loc)
        if not os.path.isdir(d):
            continue
        titles = localized.get(loc) or localized.get(loc.split("-")[0]) or en
        lines = []
        for key, val in titles.items():
            v = str(val).replace("\\", "\\\\").replace('"', '\\"')
            lines.append(f'"{key}" = "{v}";')
        with open(os.path.join(d, "title.strings"), "w", encoding="utf-8") as fh:
            fh.write("\n".join(lines) + "\n")
        print(f"title.strings: {loc} ({len(lines)} titles)")


if __name__ == "__main__":
    main()
