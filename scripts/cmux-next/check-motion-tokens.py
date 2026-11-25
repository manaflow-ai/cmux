#!/usr/bin/env python3
"""Motion and colour token ratchet for cmux NEXT: no new raw animation duration, no new raw colour outside the
token files (Leo, 2026-11-10: "the slow animations, ugly, incoherent UI ... we need to be holding ourselves to high
standards").

    python3 scripts/cmux-next/check-motion-tokens.py [--root DIR] [--baseline FILE] [--update-baseline] [--list]

Counts, per file (scripts/cmux-next/motion_inventory.py does the reading):
  duration  an animation duration that does not come from the shared motion tokens, where no other check sees it:
            a page-local duration property (`--x-close: calc(var(--agent-motion-move) * 0.6)`), a token multiplied
            or offset off the scale, a script's CSS string or Web Animations duration, a `*_FADE_MS`-style
            constant, the acpmux web page and the first-party apps' panes; a native MotionTunables or Rust
            design-tokens.json duration off the scale. Literals in webviews stylesheet declarations are
            webviews/scripts/check-design-tokens.ts's (its own shrink-only baseline); Swift outside the Motion
            folders is check-motion.sh's. Loops, hover-intent ramps and 0 are not durations here.
  colour    a raw colour: in Swift `NSColor(red:)`, `Color(white:)`, `CGColor(srgbRed:)`, `NSColor(hex:)` ...;
            in a page a hex or rgb()/hsl()/oklch() literal in a script string or a page-local colour property
            (`--x: #fff` outside the token files). Theme data and the token files are not read
            (motion_inventory.COLOUR_TOKEN_PATHS).
A reviewed exception carries `motion-allow: <reason>` (a duration) or `colour-allow: <reason>` (a colour) on the
line.

The baseline (scripts/cmux-next/motion-tokens-baseline.tsv: kind, path, count) only shrinks. A file over its row,
or a file with no row, fails. A file under its row passes with a note to lower it; `--update-baseline` lowers and
drops rows and never raises one or adds one.
"""
from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import motion_inventory as mi  # noqa: E402

BASELINE = Path(__file__).resolve().parent / "motion-tokens-baseline.tsv"
HEADER = "# check-motion-tokens.py baseline: kind<TAB>path<TAB>count (it only shrinks: --update-baseline)"


def counts(root: Path) -> tuple[dict[tuple[str, str], int], dict[tuple[str, str], list[str]]]:
    found: dict[tuple[str, str], int] = {}
    where: dict[tuple[str, str], list[str]] = {}
    for path, sites in mi.raw_durations(mi.inventory(root)).items():
        found[("duration", path)] = len(sites)
        where[("duration", path)] = [f"{path}:{s.line}: {s.text}" for s in sites]
    for path, hits in mi.raw_colours(root).items():
        found[("colour", path)] = len(hits)
        where[("colour", path)] = [f"{path}:{line}: {text}" for line, text in hits]
    return found, where


def read_baseline(path: Path) -> dict[tuple[str, str], int]:
    rows: dict[tuple[str, str], int] = {}
    if not path.exists():
        return rows
    for line in path.read_text().splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        kind, file, count = line.split("\t")
        rows[(kind, file)] = int(count)
    return rows


def write_baseline(path: Path, rows: dict[tuple[str, str], int]) -> None:
    lines = [HEADER] + [f"{kind}\t{file}\t{count}" for (kind, file), count in sorted(rows.items()) if count > 0]
    path.write_text("\n".join(lines) + "\n")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", type=Path, default=mi.REPO)
    parser.add_argument("--baseline", type=Path, default=BASELINE)
    parser.add_argument("--update-baseline", action="store_true", help="lower rows to today's counts (never raise)")
    parser.add_argument("--write-initial-baseline", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--list", action="store_true", help="print every hit, not only the files over their row")
    args = parser.parse_args()
    found, where = counts(args.root.resolve())
    if args.write_initial_baseline:
        write_baseline(args.baseline, found)
        print(f"check-motion-tokens: wrote {len(found)} rows to {args.baseline}")
        return 0
    baseline = read_baseline(args.baseline)
    over = {key: n for key, n in found.items() if n > baseline.get(key, 0)}
    under = {key: n for key, n in baseline.items() if found.get(key, 0) < n}
    annotate = os.environ.get("GITHUB_ACTIONS") == "true"
    if args.list:
        for key in sorted(where):
            for hit in where[key]:
                print(f"{key[0]}: {hit}")
    if args.update_baseline:
        lowered = {key: min(n, found.get(key, 0)) for key, n in baseline.items()}
        write_baseline(args.baseline, lowered)
        print(f"check-motion-tokens: lowered {len(under)} row(s); {len(over)} file(s) still over (never raised)")
    elif under:
        print(f"check-motion-tokens: {len(under)} file(s) are under their row; lower it: "
              "python3 scripts/cmux-next/check-motion-tokens.py --update-baseline")
    if over:
        print("check-motion-tokens: new raw animation durations or colours (use the motion tokens "
              "(schemas/motion-scale/motion-scale.json, --cmux-motion-*, MOTION_MS) or the theme's colour tokens, "
              "or mark a reviewed exception with motion-allow: / colour-allow: and a reason):")
        for key, n in sorted(over.items()):
            print(f"  {key[0]} {key[1]}: {n} (baseline {baseline.get(key, 0)})")
            for hit in where.get(key, []):
                print(f"    {hit}")
                if annotate:
                    file, line = hit.split(":", 2)[:2]
                    print(f"::error file={file},line={line}::raw {key[0]} outside the tokens")
        return 1
    total = sum(found.values())
    print(f"check-motion-tokens: ok ({total} raw hits, all in the baseline)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
