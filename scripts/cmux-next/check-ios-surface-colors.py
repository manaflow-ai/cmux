#!/usr/bin/env python3
"""iPhone surface colors: the app's views draw theme and design-system colors, never a literal color or
an opaque stock surface (Leo 2026-11-22, on a black "1 subagent" card over his themed wallpaper: "WHAT
THE FUCK IT'S ALL UNTHEMED ... THEME IT").

Counts, per Swift file under cmux-next-ios/CmuxMobileKit/Sources, the places that paint a color the
theme does not own:
  literal   Color/UIColor .black .white .gray .red ... ; Color(red:/white:/hue:) and UIColor(red:/white:);
            Color(.sRGB, ...); #colorLiteral; a bare `.black`/`.white` in a style modifier.
  system    the system grounds: systemBackground, secondarySystemBackground, tertiarySystemBackground,
            the grouped grounds and systemGray2...6.
  stock     the opaque stock chat surfaces: cmuxMobileCard, cmuxMobileCodeBackground,
            cmuxMobileSurfaceRaised and the standard theme's `surfaceRaised`.
Draw these instead (cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileDesign/ContentSurface.swift):
`cmuxMobileContentSurface(.card | .inset, in:)` for what sits in the page (the design scale's surface
levels, ink over clear) and `cmuxMobileFloatingGlass(in:)` for what floats over it; text takes
`.primary`/`.secondary` or the Mac palette.

A line that needs a literal (an alpha mask, a scrim over a photo, the Chief chat's iMessage blue) says
why with `// color-literal-allow: <reason>` on that line. The token definitions themselves are not
scanned (SKIP). Fails when a file has more hits than its row in the baseline; `--update-baseline`
rewrites the baseline to today's counts (lower it; never raise it by hand).

  python3 scripts/cmux-next/check-ios-surface-colors.py [--root DIR] [--baseline FILE] [--update-baseline]
"""
import argparse
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
TREE = "cmux-next-ios/CmuxMobileKit/Sources"
# Where the theme's colors are defined: these files are the tokens.
SKIP = (
    "cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileDesign/Accent.swift",
    "cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileDesign/ChatLookFixture.swift",
    "cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileDesign/ChatTokens.swift",
    "cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileDesign/Colors.swift",
    "cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileDesign/ContentSurface.swift",
    "cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileDesign/MacTheme.swift",
    "cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileDesign/TerminalHostTheme.swift",
    "cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileDesign/Theme.swift",
)
ALLOW = "color-literal-allow:"
NAMED = r"(?:black|white|gray|grey|darkGray|lightGray|red|green|blue|orange|yellow|purple|pink|brown|cyan|magenta|mint|teal|indigo)"
PATTERNS = (
    re.compile(r"\b(?:Color|UIColor|CGColor)\." + NAMED + r"\b"),
    re.compile(r"\b(?:Color|UIColor)\(\s*(?:red|white|hue|displayP3Red)\s*:"),
    re.compile(r"\bColor\(\s*\.(?:sRGB|displayP3|sRGBLinear)\b"),
    re.compile(r"#colorLiteral\("),
    re.compile(r"\b(?:foregroundStyle|foregroundColor|tint|fill|stroke|background|strokeBorder|shadow)\(\s*(?:color:\s*)?\.(?:black|white|gray)\b"),
    re.compile(r"\b(?:secondary|tertiary)?System(?:Grouped)?Background\b|\bsystem(?:Grouped)?Background\b|\bsystemGray[2-6]\b"),
    re.compile(r"\bcmuxMobile(?:Card|CodeBackground|SurfaceRaised)\b|\bcolors\.surfaceRaised\b"),
)
COMMENT = re.compile(r"^\s*(?://|/\*|\*)")


def hits(text):
    count = 0
    for line in text.splitlines():
        if COMMENT.match(line) or ALLOW in line:
            continue
        code = line.split("//", 1)[0]
        count += sum(len(pattern.findall(code)) for pattern in PATTERNS)
    return count


def scan(root):
    counts = {}
    for directory, dirs, files in os.walk(os.path.join(root, TREE)):
        dirs[:] = [d for d in dirs if d not in (".build", "Tests")]
        for name in files:
            if not name.endswith(".swift"):
                continue
            full = os.path.join(directory, name)
            rel = os.path.relpath(full, root)
            if rel in SKIP:
                continue
            with open(full, encoding="utf-8", errors="replace") as handle:
                count = hits(handle.read())
            if count:
                counts[rel] = count
    return counts


def read_baseline(path):
    rows = {}
    if os.path.exists(path):
        with open(path, encoding="utf-8") as handle:
            for line in handle:
                if not line.strip() or line.startswith("#"):
                    continue
                rel, count = line.rstrip("\n").split("\t")
                rows[rel] = int(count)
    return rows


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", default=REPO)
    parser.add_argument("--baseline", default=os.path.join(HERE, "ios-surface-colors-baseline.tsv"))
    parser.add_argument("--update-baseline", action="store_true")
    args = parser.parse_args(argv)
    counts = scan(args.root)
    if args.update_baseline:
        with open(args.baseline, "w", encoding="utf-8") as handle:
            handle.write("# check-ios-surface-colors.py baseline: path<TAB>count (lower it; never raise it by hand)\n")
            for rel in sorted(counts):
                handle.write(f"{rel}\t{counts[rel]}\n")
        print(f"check-ios-surface-colors: baseline written ({sum(counts.values())} in {len(counts)} files)")
        return 0
    baseline = read_baseline(args.baseline)
    over = {rel: (count, baseline.get(rel, 0)) for rel, count in counts.items() if count > baseline.get(rel, 0)}
    if not over:
        print(f"check-ios-surface-colors: ok ({sum(counts.values())} left in the baseline)")
        return 0
    annotate = os.environ.get("GITHUB_ACTIONS") == "true"
    print("check-ios-surface-colors: new literal colors or opaque stock surfaces in iPhone views:")
    for rel, (count, base) in sorted(over.items()):
        message = (f"{count} literal colors or stock surfaces, baseline {base}: draw cmuxMobileContentSurface / "
                   f"cmuxMobileFloatingGlass, or mark a needed literal `// {ALLOW} <reason>`")
        print(f"::error file={rel}::{message}" if annotate else f"  {rel}: {message}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
