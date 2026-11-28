#!/usr/bin/env python3
"""Layer ratchet: z-index and transparency (webviews/src/ui/README.md, "Layers and transparency").

Fails when a webview source file has MORE of these than its baseline row:
  z         raw z-index numbers: `z-index: 51`, `zIndex: 4` / `.style.zIndex = '9'`, Tailwind `z-50`,
            `z-[3]`. Allowed: 0, auto, and the layer tokens (`var(--layer-*)`, Tailwind `z-(--layer-*)`).
  backdrop  `backdrop-filter` (or a Tailwind `backdrop-*` class) in a file that has no
            reduced-transparency fallback (`prefers-reduced-transparency`, `data-reduce-transparency`,
            or a `var(--surface-blur)` value, which the shared tokens already turn off).
A count below its baseline fails too, until the baseline is lowered (`--update-baseline`), so the
ratchet only moves down. `--update-baseline` refuses to raise a count (it writes the first baseline
when the file does not exist).

  python3 scripts/cmux-next/check-layers.py [--root DIR] [--baseline FILE] [--update-baseline]
"""
import argparse
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
EXTENSIONS = (".css", ".ts", ".tsx", ".js", ".mjs")

CSS_Z = re.compile(r"z-index\s*:\s*(-?\d+)")
JS_Z = re.compile(r"zIndex\s*[:=]\s*[\"'`]?(-?\d+)")
TW_Z = re.compile(r"(?<![\w-])-?z-(\d+|\[[^\]\s]*\])(?![\w-])")
BACKDROP = re.compile(r"backdrop-filter\s*:\s*([^;}\n]*)|(?<![\w-])backdrop-(?:blur|saturate|brightness|contrast|opacity|\()")
FALLBACK = re.compile(r"prefers-reduced-transparency|data-reduce-transparency")


def scan_dir(root):
    nested = os.path.join(root, "webviews", "src")
    return nested if os.path.isdir(nested) else os.path.join(root, "src")


def sources(root):
    for base, dirs, files in os.walk(scan_dir(root)):
        dirs[:] = [d for d in dirs if d not in ("node_modules", "generated")]
        for name in files:
            if not name.endswith(EXTENSIONS) or ".test." in name or name.endswith(".d.ts"):
                continue
            path = os.path.join(base, name)
            yield os.path.relpath(path, root).replace(os.sep, "/"), path


def count(text):
    z = 0
    lines = []
    for pattern in (CSS_Z, JS_Z):
        for match in pattern.finditer(text):
            if match.group(1) != "0":
                z += 1
                lines.append(text.count("\n", 0, match.start()) + 1)
    for match in TW_Z.finditer(text):
        if match.group(1) not in ("0", "[0]"):
            z += 1
            lines.append(text.count("\n", 0, match.start()) + 1)
    backdrop = 0
    if not FALLBACK.search(text):
        for match in BACKDROP.finditer(text):
            value = (match.group(1) or "").strip()
            if value in ("none", "") and match.group(1) is not None:
                continue
            if "var(--surface-blur)" in value:
                continue
            backdrop += 1
    return {"z": z, "backdrop": backdrop}, sorted(set(lines))


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
        handle.write("# path\tkind\tcount (scripts/cmux-next/check-layers.py; may only go down)\n")
        for (file, kind), value in sorted(counts.items()):
            if value:
                handle.write(f"{file}\t{kind}\t{value}\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", default=REPO)
    parser.add_argument("--baseline", default=os.path.join(HERE, "layers-baseline.tsv"))
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
        what = "raw z-index" if kind == "z" else "backdrop-filter without a reduced-transparency fallback"
        at = f" (lines {', '.join(map(str, where.get(file, [])[:8]))})" if kind == "z" and where.get(file) else ""
        return f"  {file}: {now} {what}, baseline {before}{at}"

    if args.update_baseline:
        # The first baseline records the tree as it is; after that the ratchet only moves down.
        if grew and os.path.exists(args.baseline):
            print("check-layers: refusing to raise the baseline; use the layer tokens instead:", file=sys.stderr)
            for row in grew:
                print(describe(*row), file=sys.stderr)
            return 1
        write_baseline(args.baseline, counts)
        print(f"check-layers: baseline written ({len([v for v in counts.values() if v])} rows)")
        return 0

    status = 0
    if grew:
        status = 1
        print("check-layers: new layer or transparency violations (webviews/src/ui/README.md, Layers and transparency):", file=sys.stderr)
        for row in grew:
            print(describe(*row), file=sys.stderr)
        print("  use z-index: var(--layer-*) / Tailwind z-(--layer-*), and give translucent surfaces a "
              "prefers-reduced-transparency fallback (or backdrop-filter: var(--surface-blur)).", file=sys.stderr)
    if shrank:
        status = 1
        print("check-layers: fewer violations than the baseline; lower the baseline "
              "(python3 scripts/cmux-next/check-layers.py --update-baseline):", file=sys.stderr)
        for row in shrank:
            print(describe(*row), file=sys.stderr)
    if status == 0:
        z = sum(v for (f, k), v in counts.items() if k == "z")
        b = sum(v for (f, k), v in counts.items() if k == "backdrop")
        print(f"check-layers: ok ({z} raw z-index and {b} bare backdrop-filter left in the baseline)")
    return status


if __name__ == "__main__":
    sys.exit(main())
