#!/usr/bin/env python3
"""Type-scale ratchet for the app: raw font sizes and off-scale weights in CmuxNext Swift.

The one type scale is schemas/type-scale/type-scale.json (Swift: `TypeScale`, `Typography`). Fails when
a Swift source file under Packages/macOS/CmuxNext/Sources has MORE than its baseline row of:
  size    a literal font size: `.systemFont(ofSize: 12)`, `monospacedSystemFont(ofSize: 11.5, ...)`,
          `monospacedDigitSystemFont`, `boldSystemFont`, `NSFont(name: ..., size: 13)`, SwiftUI
          `.system(size: 12)`. Use `TypeScale.<step>` or a `Typography` font.
  weight  a weight off the scale's two (`TypeScale.regular`, `TypeScale.emphasis`): `.medium`, `.bold`,
          `.heavy`, `.black`, `.light`, `.thin`, `.ultraLight` after `weight:`.
A count below its baseline fails too, until the baseline is lowered (`--update-baseline`), so the
ratchet only moves down. `--update-baseline` refuses to raise a count (it writes the first baseline
when the file does not exist).

  python3 scripts/cmux-next/check-swift-type-scale.py [--root DIR] [--baseline FILE] [--update-baseline]
"""
import argparse
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
SOURCES = "Packages/macOS/CmuxNext/Sources"
# The scale's own definitions, and the DEBUG text probes (cx-8w027.12, cx-8w027.26), which draw the
# off-scale fonts chrome still uses (12 pt medium, 10.5 pt) to measure them; no chrome draws theirs.
# Sleepy Mode's scene is illustration, not chrome: a 96 pt moon glyph, a 64 pt thin clock and
# animated Zs on a full-screen night sky, none of which is a step of the scale.
SKIP = (
    "CmuxNextDesign/TypeScale.generated.swift",
    "CmuxNextDesign/Text/LabelParityProbe.swift",
    "CmuxNextDesign/Text/TextWeightProbe.swift",
    "CmuxNextApp/SleepyMode/SleepySceneView.swift",
)

NUMBER = r"\d+(?:\.\d+)?"
SIZE = re.compile(
    r"(?:(?:systemFont|monospacedSystemFont|monospacedDigitSystemFont|boldSystemFont)\(ofSize:\s*" + NUMBER + r"\b"
    r"|NSFont\(name:[^)\n]*size:\s*" + NUMBER + r"\b"
    r"|\.system\(size:\s*" + NUMBER + r"\b)")
WEIGHT = re.compile(r"weight:\s*(?:NSFont\.Weight|Font\.Weight)?\.(medium|bold|heavy|black|light|thin|ultraLight)\b")
COMMENT = re.compile(r"//[^\n]*")


def sources(root):
    base_dir = os.path.join(root, SOURCES)
    for base, dirs, files in os.walk(base_dir):
        for name in files:
            if not name.endswith(".swift"):
                continue
            path = os.path.join(base, name)
            inner = os.path.relpath(path, base_dir).replace(os.sep, "/")
            if inner in SKIP:
                continue
            yield os.path.relpath(path, root).replace(os.sep, "/"), path


def count(text):
    text = COMMENT.sub("", text)
    found, lines = {}, []
    for kind, pattern in (("size", SIZE), ("weight", WEIGHT)):
        hits = list(pattern.finditer(text))
        found[kind] = len(hits)
        lines += [text.count("\n", 0, hit.start()) + 1 for hit in hits]
    return found, sorted(set(lines))


def read_baseline(path):
    rows = {}
    if os.path.exists(path):
        with open(path, encoding="utf-8") as handle:
            for line in handle:
                line = line.rstrip("\n")
                if not line or line.startswith("#"):
                    continue
                file, kind, value = line.split("\t")
                rows[(file, kind)] = int(value)
    return rows


def write_baseline(path, counts):
    with open(path, "w", encoding="utf-8") as handle:
        handle.write("# path\tkind\tcount (scripts/cmux-next/check-swift-type-scale.py; may only go down)\n")
        for (file, kind), value in sorted(counts.items()):
            if value:
                handle.write(f"{file}\t{kind}\t{value}\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", default=REPO)
    parser.add_argument("--baseline", default=os.path.join(HERE, "swift-type-scale-baseline.tsv"))
    parser.add_argument("--update-baseline", action="store_true")
    args = parser.parse_args()

    baseline = read_baseline(args.baseline)
    counts, where = {}, {}
    for rel, path in sources(args.root):
        with open(path, encoding="utf-8", errors="replace") as handle:
            found, lines = count(handle.read())
        for kind, value in found.items():
            if value:
                counts[(rel, kind)] = value
        where[rel] = lines

    grew, shrank = [], []
    for key in sorted(set(counts) | set(baseline)):
        now, before = counts.get(key, 0), baseline.get(key, 0)
        if now > before:
            grew.append((key, now, before))
        elif now < before:
            shrank.append((key, now, before))

    def describe(key, now, before):
        file, kind = key
        at = f" (lines {', '.join(map(str, where.get(file, [])[:8]))})" if where.get(file) else ""
        return f"  {file}: {now} raw font {kind}s, baseline {before}{at}"

    if args.update_baseline:
        if grew and os.path.exists(args.baseline):
            print("check-swift-type-scale: refusing to raise the baseline; use TypeScale or Typography:", file=sys.stderr)
            for row in grew:
                print(describe(*row), file=sys.stderr)
            return 1
        write_baseline(args.baseline, counts)
        print(f"check-swift-type-scale: baseline written ({len([v for v in counts.values() if v])} rows)")
        return 0

    status = 0
    if grew:
        status = 1
        print("check-swift-type-scale: new raw font sizes or weights (schemas/type-scale/type-scale.json):", file=sys.stderr)
        for row in grew:
            print(describe(*row), file=sys.stderr)
        print("  use TypeScale.caption|detail|body|title|heading and TypeScale.regular|emphasis, or a Typography font.",
              file=sys.stderr)
    if shrank:
        status = 1
        print("check-swift-type-scale: fewer than the baseline; lower it "
              "(python3 scripts/cmux-next/check-swift-type-scale.py --update-baseline):", file=sys.stderr)
        for row in shrank:
            print(describe(*row), file=sys.stderr)
    if status == 0:
        sizes = sum(v for (_, kind), v in counts.items() if kind == "size")
        weights = sum(v for (_, kind), v in counts.items() if kind == "weight")
        print(f"check-swift-type-scale: ok ({sizes} raw font sizes and {weights} off-scale weights left in the baseline)")
    return status


if __name__ == "__main__":
    sys.exit(main())
