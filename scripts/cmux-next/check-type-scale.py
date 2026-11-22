#!/usr/bin/env python3
"""Type-scale ratchet: font sizes (webviews/src/ui/README.md, "Type scale").

Fails when a webview source file has MORE raw font sizes than its baseline row:
  size  a literal font size outside the token file: `font-size: 12px` / `1.2rem` / `11pt`, a `font:`
        shorthand with a literal size (`font: 13px/18px ...`), JS `fontSize: 12` / `fontSize: "12px"`,
        and Tailwind `text-[12px]` / `text-[0.8rem]` / `text-[length:...]`.
  Allowed: the type tokens (`var(--text-*)`, Tailwind `text-caption`, `text-detail`, `text-body`,
  `text-control`, `text-title`, `text-heading`, `text-content`), `inherit`, and relative sizes
  (`em`, `%`, keywords such as `smaller`). The tokens live in webviews/src/pages/shared/desktop.css,
  which is not scanned.
A count below its baseline fails too, until the baseline is lowered (`--update-baseline`), so the
ratchet only moves down. `--update-baseline` refuses to raise a count (it writes the first baseline
when the file does not exist).

  python3 scripts/cmux-next/check-type-scale.py [--root DIR] [--baseline FILE] [--update-baseline]
"""
import argparse
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
EXTENSIONS = (".css", ".ts", ".tsx", ".js", ".mjs")
# The token definitions themselves.
TOKEN_FILES = ("pages/shared/desktop.css",)

LITERAL = r"\d*\.?\d+(?:px|rem|pt)\b"
CSS_SIZE = re.compile(r"font-size\s*:\s*([^;}\n]*)")
CSS_FONT = re.compile(r"(?<![\w-])font\s*:\s*([^;}\n]*)")
JS_SIZE = re.compile(r"fontSize\s*[:=]\s*([\"'`]?)(\d*\.?\d+)(px|rem|pt)?\1")
TW_SIZE = re.compile(r"(?<![\w-])text-\[(?:length:)?(" + LITERAL + r"|[^\]\s]*(?:px|rem|pt)[^\]\s]*)\]")


def scan_dir(root):
    nested = os.path.join(root, "webviews", "src")
    return nested if os.path.isdir(nested) else os.path.join(root, "src")


def sources(root):
    base_dir = scan_dir(root)
    for base, dirs, files in os.walk(base_dir):
        dirs[:] = [d for d in dirs if d not in ("node_modules", "generated")]
        for name in files:
            if not name.endswith(EXTENSIONS) or ".test." in name or name.endswith(".d.ts"):
                continue
            path = os.path.join(base, name)
            inner = os.path.relpath(path, base_dir).replace(os.sep, "/")
            if inner in TOKEN_FILES:
                continue
            yield os.path.relpath(path, root).replace(os.sep, "/"), path


def count(text):
    lines = []

    def hit(match):
        lines.append(text.count("\n", 0, match.start()) + 1)

    for match in CSS_SIZE.finditer(text):
        if re.search(LITERAL, match.group(1)):
            hit(match)
    for match in CSS_FONT.finditer(text):
        value = match.group(1)
        # `font: inherit`, `font: var(...)`, keywords: only a literal size counts.
        if re.search(LITERAL, value):
            hit(match)
    for match in JS_SIZE.finditer(text):
        if match.group(3) != "em":
            hit(match)
    for match in TW_SIZE.finditer(text):
        hit(match)
    return {"size": len(lines)}, sorted(set(lines))


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
        handle.write("# path\tkind\tcount (scripts/cmux-next/check-type-scale.py; may only go down)\n")
        for (file, kind), value in sorted(counts.items()):
            if value:
                handle.write(f"{file}\t{kind}\t{value}\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", default=REPO)
    parser.add_argument("--baseline", default=os.path.join(HERE, "type-scale-baseline.tsv"))
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
        file, _ = key
        at = f" (lines {', '.join(map(str, where.get(file, [])[:8]))})" if where.get(file) else ""
        return f"  {file}: {now} raw font sizes, baseline {before}{at}"

    if args.update_baseline:
        if grew and os.path.exists(args.baseline):
            print("check-type-scale: refusing to raise the baseline; use the type tokens instead:", file=sys.stderr)
            for row in grew:
                print(describe(*row), file=sys.stderr)
            return 1
        write_baseline(args.baseline, counts)
        print(f"check-type-scale: baseline written ({len([v for v in counts.values() if v])} rows)")
        return 0

    status = 0
    if grew:
        status = 1
        print("check-type-scale: new raw font sizes (webviews/src/ui/README.md, Type scale):", file=sys.stderr)
        for row in grew:
            print(describe(*row), file=sys.stderr)
        print("  use font-size: var(--text-*) / Tailwind text-caption|detail|body|control|title|heading|content.",
              file=sys.stderr)
    if shrank:
        status = 1
        print("check-type-scale: fewer raw font sizes than the baseline; lower the baseline "
              "(python3 scripts/cmux-next/check-type-scale.py --update-baseline):", file=sys.stderr)
        for row in shrank:
            print(describe(*row), file=sys.stderr)
    if status == 0:
        total = sum(counts.values())
        print(f"check-type-scale: ok ({total} raw font sizes left in the baseline)")
    return status


if __name__ == "__main__":
    sys.exit(main())
