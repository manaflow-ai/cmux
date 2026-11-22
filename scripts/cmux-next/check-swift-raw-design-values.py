#!/usr/bin/env python3
"""Raw corner radii and layer orders in the app's Swift outside the design packages: a ratchet.

Leo, 2026-11-22: "the shifting projects and sizing of stuff ... we need to prevent this once and for all". A
corner typed as a number in a feature module drifts from the design scale with no one deciding it; a layer
order typed as a number stacks against every other module's guess. The values belong to the design packages
(CmuxNextDesign: Metrics, PopupStyle, TooltipMetrics, CmuxDialogMetrics; CmuxNextDesignTokens: DesignTokens).

Fails when a Swift file under Packages/macOS/CmuxNext/Sources, outside CmuxNextDesign*, has MORE than its
baseline row (scripts/cmux-next/swift-raw-design-values-baseline.tsv) of:
  corner     a non-zero numeric corner radius: `layer.cornerRadius = 8`, `cornerRadius: 16` (an argument),
             `var panelCornerRadius: CGFloat = 10`, the number being the whole expression. Use a Metrics corner
             (`Metrics.surfaceCornerRadius`, `Metrics.buttonCornerRadius`, `Metrics.cornerRadius(nestedIn:inset:)`)
             or a design-package constant.
  zposition  a numeric `zPosition = N`. Name the order where the layers are made.
A count below its baseline fails too until the baseline is lowered (`--update-baseline`, which refuses to raise
a count), so the ratchet only moves down. The patterns are design-system-census.py's (one definition), which
counts the same two numbers for the design packages too.

    python3 -I scripts/cmux-next/check-swift-raw-design-values.py [--root DIR] [--baseline FILE] [--update-baseline]

Tests: scripts/cmux-next/tests/test_design_system_guards.py.
"""
from __future__ import annotations

import argparse
import importlib.util
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
SOURCES = "Packages/macOS/CmuxNext/Sources"
DESIGN_PREFIX = "CmuxNextDesign"
BASELINE = os.path.join(HERE, "swift-raw-design-values-baseline.tsv")
HEADER = "# path\tkind\tcount (scripts/cmux-next/check-swift-raw-design-values.py; may only go down)\n"

_spec = importlib.util.spec_from_file_location("design_system_census", os.path.join(HERE, "design-system-census.py"))
census = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(census)


def count(text: str) -> tuple[dict[str, int], list[int]]:
    code = census.strip_swift(text)
    found, lines = {"corner": 0, "zposition": 0}, []
    for kind, pattern in (("corner", census.CORNER_LITERAL), ("zposition", census.ZPOSITION_LITERAL)):
        for match in pattern.finditer(code):
            if kind == "corner" and float(match.group(1)) == 0:
                continue
            found[kind] += 1
            lines.append(code.count("\n", 0, match.start()) + 1)
    return found, sorted(set(lines))


def scan(root: str) -> tuple[dict[tuple[str, str], int], dict[str, list[int]]]:
    counts, where = {}, {}
    for rel, path in census.walk(root, SOURCES, (".swift",)):
        if rel.split("/", 1)[0].startswith(DESIGN_PREFIX):
            continue
        with open(path, encoding="utf-8", errors="replace") as handle:
            found, lines = count(handle.read())
        repo_rel = f"{SOURCES}/{rel}"
        for kind, value in found.items():
            if value:
                counts[(repo_rel, kind)] = value
        if lines:
            where[repo_rel] = lines
    return counts, where


def read_baseline(path: str) -> dict[tuple[str, str], int]:
    rows = {}
    if os.path.exists(path):
        with open(path, encoding="utf-8") as handle:
            for line in handle:
                line = line.rstrip("\n")
                if line and not line.startswith("#"):
                    file, kind, value = line.split("\t")
                    rows[(file, kind)] = int(value)
    return rows


def write_baseline(path: str, counts: dict[tuple[str, str], int]) -> None:
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(HEADER)
        for (file, kind), value in sorted(counts.items()):
            if value:
                handle.write(f"{file}\t{kind}\t{value}\n")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", default=REPO)
    parser.add_argument("--baseline", default=BASELINE)
    parser.add_argument("--update-baseline", action="store_true")
    args = parser.parse_args(argv)

    baseline = read_baseline(args.baseline)
    counts, where = scan(args.root)
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
        return f"  {file}: {now} raw {kind} literals, baseline {before}{at}"

    if args.update_baseline:
        if grew and os.path.exists(args.baseline):
            print("check-swift-raw-design-values: refusing to raise the baseline:", file=sys.stderr)
            for row in grew:
                print(describe(*row), file=sys.stderr)
            return 1
        write_baseline(args.baseline, counts)
        print(f"check-swift-raw-design-values: baseline written ({len(counts)} rows)")
        return 0

    status = 0
    if grew:
        status = 1
        print("check-swift-raw-design-values: new numeric corner radii or zPositions outside the design packages:",
              file=sys.stderr)
        for row in grew:
            print(describe(*row), file=sys.stderr)
        print("  use a Metrics corner (surfaceCornerRadius, buttonCornerRadius, cornerRadius(nestedIn:inset:)) or a "
              "CmuxNextDesign constant; name a layer order where its layers are made.", file=sys.stderr)
    if shrank:
        status = 1
        print("check-swift-raw-design-values: fewer than the baseline; lower it "
              "(python3 -I scripts/cmux-next/check-swift-raw-design-values.py --update-baseline):", file=sys.stderr)
        for row in shrank:
            print(describe(*row), file=sys.stderr)
    if status == 0:
        corners = sum(v for (_, kind), v in counts.items() if kind == "corner")
        orders = sum(v for (_, kind), v in counts.items() if kind == "zposition")
        print(f"check-swift-raw-design-values: ok ({corners} corner and {orders} zPosition literals left in the baseline)")
    return status


if __name__ == "__main__":
    sys.exit(main())
