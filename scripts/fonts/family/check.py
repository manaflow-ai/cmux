#!/usr/bin/env python3
"""Checks a built family (build.py's output directory): at most `--max-faces` faces, every face on one line
box (hhea and typo, USE_TYPO_METRICS), win metrics that cover the box and the ink, every name renamed. A face whose box differs would move lines when a reader swaps faces,
so this is the 0 px line-shift check on the files themselves; the gallery's no-shift entry measures the same
in a browser.

Usage: check.py DIR [--max-faces 8]
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from fontTools.ttLib import TTFont


def boxes(font: TTFont) -> dict:
    hhea, os2 = font["hhea"], font["OS/2"]
    return {
        "hhea": (hhea.ascent, hhea.descent, hhea.lineGap),
        "typo": (os2.sTypoAscender, os2.sTypoDescender, os2.sTypoLineGap),
        "win": (os2.usWinAscent, -os2.usWinDescent),
        "use_typo": bool(os2.fsSelection & (1 << 7)),
        "upem": font["head"].unitsPerEm,
    }


def check(out: Path, max_faces: int) -> list[str]:
    manifest = json.loads((out / "manifest.json").read_text())
    ascender, descender = manifest["line_box"]
    want = {
        "hhea": (ascender, descender, 0),
        "typo": (ascender, descender, 0),
        "use_typo": True,
        "upem": 1000,
    }
    problems = []
    if len(manifest["faces"]) > max_faces:
        problems.append(f"{len(manifest['faces'])} faces, the limit is {max_faces}")
    for face in manifest["faces"]:
        font = TTFont(out / face["file"])
        got = boxes(font)
        for key, value in want.items():
            if got[key] != value:
                problems.append(f"{face['file']}: {key} is {got[key]}, the family's is {value}")
        head = font["head"]
        win_ascent, win_descent = got["win"]
        if win_ascent < max(ascender, head.yMax) or win_descent > min(descender, head.yMin):
            problems.append(f"{face['file']}: win {got['win']} does not cover the box and the ink {head.yMin}..{head.yMax}")
        family = font["name"].getDebugName(16) or font["name"].getDebugName(1)
        if not family or not family.startswith(manifest["family"]):
            problems.append(f"{face['file']}: family name {family!r} is not {manifest['family']!r}")
        if face.get("base") and face["base"].lower() not in manifest["family"].lower():
            for record in font["name"].names:
                if record.nameID in (1, 4, 6, 16) and face["base"].lower() in record.toUnicode().lower():
                    problems.append(f"{face['file']}: name {record.nameID} still says {face['base']!r}")
    return problems


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("out", type=Path)
    parser.add_argument("--max-faces", type=int, default=8)
    args = parser.parse_args()
    problems = check(args.out, args.max_faces)
    for problem in problems:
        print(problem, file=sys.stderr)
    if problems:
        sys.exit(1)
    print(f"{args.out}: every face on one line box")


if __name__ == "__main__":
    main()
