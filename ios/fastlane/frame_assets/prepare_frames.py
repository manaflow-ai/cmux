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
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


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

    shutil.copy(os.path.join(HERE, "Framefile.json"), os.path.join(ss, "Framefile.json"))
    shutil.copy(os.path.join(HERE, "background.jpg"), os.path.join(ss, "background.jpg"))

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
