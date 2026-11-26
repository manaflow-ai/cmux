#!/usr/bin/env python3
"""Raw values per webviews directory, to pick the next one the closed kit closes (RFD 0040).

For each directory under webviews/src (its own files, not its subdirectories), over product files only
(no *.test.*, *.gallery.*, generated files): raw px, hex and rgb()/rgba() literals in .ts, .tsx and .css,
and in .tsx the closed kit's doors: raw elements (`<div`, `<button`: a lowercase tag after a non-word
character, outside strings and comments, so `Promise<void>` is not one), `style={` and `className=`.
A directory whose doors are 0 can close with no drawn value moving; one with doors needs a kit piece
for each before it can.
Approximate (regex, no type check): `tsc -p tsconfig.closed.json` with the pragma is the real answer.
  python3 -I scripts/measure/closed-kit-census.py [DIR ...]
DIRs are relative to webviews/src; with none, it prints every directory with a .tsx file, fewest doors first.
"""
import os
import re
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "webviews", "src")
ELEMENT = re.compile(r"(?<![\w.$])<([a-z][a-z0-9]*)(?=[\s/>])")
STYLE = re.compile(r"\bstyle=\{")
CLASS = re.compile(r"\bclassName=")
PX = re.compile(r"(?<![\w.$-])-?\d+(?:\.\d+)?px\b")
HEX = re.compile(r"(?<![\w&])#(?:[0-9a-fA-F]{8}|[0-9a-fA-F]{6}|[0-9a-fA-F]{3,4})\b")
RGBA = re.compile(r"\brgba?\(")
# Strings and comments, dropped before the doors are counted (a `<name>` in a comment is not an element).
CODE_NOISE = re.compile(r'"(?:\\.|[^"\\\n])*"|\'(?:\\.|[^\'\\\n])*\'|`(?:\\.|[^`\\])*`|/\*.*?\*/|//[^\n]*', re.S)


def product(name: str) -> bool:
    return (
        name.endswith((".ts", ".tsx", ".css"))
        and ".test." not in name
        and ".gallery." not in name
        and "generated" not in name
    )


def census(rel: str) -> dict:
    path = os.path.join(ROOT, rel)
    row = dict(dir=rel, tsx=0, elements=0, style=0, className=0, px=0, hex=0, rgba=0)
    for name in sorted(os.listdir(path)):
        full = os.path.join(path, name)
        if not os.path.isfile(full) or not product(name):
            continue
        text = open(full, encoding="utf-8", errors="ignore").read()
        if name.endswith(".tsx"):
            row["tsx"] += 1
            code = CODE_NOISE.sub(" ", text)
            row["elements"] += len(ELEMENT.findall(code))
            row["style"] += len(STYLE.findall(code))
            row["className"] += len(CLASS.findall(code))
        row["px"] += len(PX.findall(text))
        row["hex"] += len(HEX.findall(text))
        row["rgba"] += len(RGBA.findall(text))
    row["doors"] = row["elements"] + row["style"] + row["className"]
    row["raw"] = row["px"] + row["hex"] + row["rgba"]
    return row


def main(argv: list[str]) -> int:
    dirs = [a.strip("/") for a in argv if not a.startswith("--")]
    if not dirs:
        for here, _, files in os.walk(ROOT):
            if any(product(f) and f.endswith(".tsx") for f in files):
                dirs.append(os.path.relpath(here, ROOT))
    rows = [census(d) for d in dirs]
    if not [a for a in argv if not a.startswith("--")]:
        rows.sort(key=lambda r: (r["doors"], r["raw"], r["dir"]))
    print("| directory | .tsx | raw elements | style | className | px | hex | rgb(a) |")
    print("|---|---|---|---|---|---|---|---|")
    for r in rows:
        print(
            f"| `{r['dir']}` | {r['tsx']} | {r['elements']} | {r['style']} | {r['className']} | {r['px']} | {r['hex']} | {r['rgba']} |"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
