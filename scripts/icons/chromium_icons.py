#!/usr/bin/env python3
"""Converts the vendored Chromium vector icons into a cmux icon source batch.

Chromium draws its browser UI from `.icon` files (ui/gfx/vector_icon_types.h): a list of path
commands on a square canvas (16, 20 or 24 dp), filled in the icon color. design/icons/chromium/
vendors the exact upstream files cmux's browser chrome uses, pinned to one revision
(manifest.json), with Chromium's LICENSE (BSD-3-Clause). This script turns each into one entry of
design/icons/source/chromium.json, so scripts/icons/build_pack.py puts it in the one pack that the
native app and the web views both draw:

- each command maps 1:1 onto SVG path syntax (R_ commands become relative ones, ARC_TO is A,
  CUBIC_TO_SHORTHAND is S), and the canvas scales to the 24-unit grid, so an icon drawn at N points
  is Chrome's icon at N dp;
- the fill rule is Chrome's: even-odd unless the representation says FILL_RULE_NONZERO;
- Line and Solid are the same drawing, since Chrome has one form.

Run it after changing manifest.json or a vendored file, then run build_pack.py. --check fails when
chromium.json is out of date.
"""
import argparse
import json
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
VENDOR = REPO / "design" / "icons" / "chromium"
OUTPUT = REPO / "design" / "icons" / "source" / "chromium.json"
GRID = 24
# The canvas of an .icon file without CANVAS_DIMENSIONS (gfx::kReferenceSizeDip).
DEFAULT_CANVAS = 48

# .icon command -> (SVG letter, argument count).
COMMANDS = {
    "MOVE_TO": ("M", 2), "R_MOVE_TO": ("m", 2),
    "LINE_TO": ("L", 2), "R_LINE_TO": ("l", 2),
    "H_LINE_TO": ("H", 1), "R_H_LINE_TO": ("h", 1),
    "V_LINE_TO": ("V", 1), "R_V_LINE_TO": ("v", 1),
    "CUBIC_TO": ("C", 6), "R_CUBIC_TO": ("c", 6),
    "CUBIC_TO_SHORTHAND": ("S", 4), "R_CUBIC_TO_SHORTHAND": ("s", 4),
    "ARC_TO": ("A", 7), "R_ARC_TO": ("a", 7),
    "CLOSE": ("Z", 0),
}
# Commands that change how the path draws but have no SVG path equivalent: only the fill rule and
# NEW_PATH are supported; anything else (strokes, colors, clips, transitions) is refused so it is
# never dropped.
FILL_RULE = "FILL_RULE_NONZERO"
# Starts another path of the same icon (drawn in the same color here).
NEW_PATH = "NEW_PATH"
# Metadata with no effect on the drawing here: FLIPS_IN_RTL mirrors the icon in right-to-left
# layouts, which cmux's browser chrome does not mirror.
IGNORED = {"FLIPS_IN_RTL"}


def strip_comments(text):
    return re.sub(r"//[^\n]*", "", text)


def representations(text):
    """Splits an .icon file into {canvas: (tokens)}, one per CANVAS_DIMENSIONS block."""
    tokens = [t for t in re.split(r"[,\s]+", strip_comments(text)) if t]
    reps, current, canvas = {}, None, None
    for token in tokens:
        if token == "CANVAS_DIMENSIONS":
            canvas = None
            current = []
            continue
        if canvas is None and current is not None and not token[0].isalpha():
            canvas = int(float(token.rstrip("f")))
            reps[canvas] = current
            continue
        if current is None:
            # No CANVAS_DIMENSIONS: Chrome's reference canvas, 48 dp (gfx::kReferenceSizeDip).
            current = []
            canvas = DEFAULT_CANVAS
            reps[canvas] = current
        current.append(token)
    return reps


def to_svg_paths(tokens):
    """Returns [(SVG path data, fill rule)] for one representation's tokens: one path per
    NEW_PATH, each filled even-odd unless it says FILL_RULE_NONZERO (as gfx::PaintVectorIcon)."""
    paths, out, rule, i = [], [], "evenodd", 0
    while i < len(tokens):
        name = tokens[i]
        i += 1
        if name == FILL_RULE:
            rule = "nonzero"
            continue
        if name in IGNORED:
            continue
        if name == NEW_PATH:
            if out:
                paths.append((" ".join(out), rule))
            out, rule = [], "evenodd"
            continue
        if name not in COMMANDS:
            raise ValueError(f"unsupported .icon command {name}")
        letter, arity = COMMANDS[name]
        args = [float(t.rstrip("f")) for t in tokens[i:i + arity]]
        if len(args) != arity:
            raise ValueError(f"{name} needs {arity} arguments")
        i += arity
        out.append(letter + (" " + " ".join(fmt(a) for a in args) if args else ""))
    if out:
        paths.append((" ".join(out), rule))
    return paths


def fmt(v):
    s = f"{round(v, 4):.4f}".rstrip("0").rstrip(".")
    return "0" if s in ("-0", "") else s


def svg(paths, canvas):
    scale = fmt(GRID / canvas)
    body = "".join(f"<path fill-rule='{rule}' d='{d}'/>" for d, rule in paths)
    return (f"<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 {GRID} {GRID}'>"
            f"<g fill='currentColor' transform='scale({scale})'>{body}</g></svg>")


def build():
    manifest = json.loads((VENDOR / "manifest.json").read_text())
    icons = []
    for entry in manifest["icons"]:
        source = VENDOR / "src" / entry["file"]
        reps = representations(source.read_text())
        canvas = entry["canvas"]
        if canvas not in reps:
            raise ValueError(f"{entry['file']} has no {canvas} dp representation (has {sorted(reps)})")
        drawing = svg(to_svg_paths(reps[canvas]), canvas)
        icon = {
            "name": entry["name"],
            "meaning": entry["meaning"],
            "line": drawing,
            "solid": drawing,
            "alts": [],
            "note": (f"Chromium {entry['file']} ({canvas} dp canvas, scaled {fmt(GRID / canvas)} to the {GRID} grid), "
                     f"revision {manifest['revision'][:12]}, BSD-3-Clause, The Chromium Authors. "
                     "Generated by scripts/icons/chromium_icons.py; do not edit."),
            "source": "chromium",
            "upstream": entry["file"],
            "sf": entry["sf"],
        }
        if entry.get("replaces"):
            icon["replaces"] = entry["replaces"]
        icons.append(icon)
    return json.dumps({"batch": "chromium", "icons": icons}, indent=1, ensure_ascii=False) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--check", action="store_true", help="fail when chromium.json is out of date")
    args = parser.parse_args()
    text = build()
    if args.check:
        if not OUTPUT.exists() or OUTPUT.read_text() != text:
            print("design/icons/source/chromium.json is out of date; run scripts/icons/chromium_icons.py", file=sys.stderr)
            return 1
        return 0
    OUTPUT.write_text(text)
    print(f"{len(json.loads(text)['icons'])} Chromium icons -> {OUTPUT.relative_to(REPO)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
