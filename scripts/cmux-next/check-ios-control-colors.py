#!/usr/bin/env python3
"""iPhone controls: a button, a key or a control draws theme colors, never a literal one (Leo, 2026-11-23:
"the jump to bottom isn't themed properly. and isn't glassed properly. and the send button has no reason
to be white on whatever. ... these buttons may not be themed properly either.").

The stricter half of check-ios-surface-colors.py: a literal color in a *control* counts here even when the
surface check's per-file baseline still has room for it. Control code is:
  - the body of a `Button { ... } label: { ... }`, `Button(...) { ... }`, `Menu`, `Toggle`, `ShareLink` or
    `PasteButton` (from its line to its closing brace);
  - a ButtonStyle's or ToggleStyle's `makeBody(configuration:)`;
  - any line that sets a control's fill or glass: `cmuxMobilePressBackground(`, `cmuxMobilePressFill(`,
    `.glassEffect(... .tint(`, `baseBackgroundColor`, `baseForegroundColor`, `setTitleColor(`,
    `UIButton.Configuration`.
In it, the surface check's literal patterns count, and so does a bare named color in a style
modifier (`.tint(.orange)`, `.foregroundStyle(.red)`).

Draw instead: `CmuxMobileTheme.standard.colors.{label,label2,accent,onAccent,danger,success,warning}`,
`Color.cmuxMobileAccent`/`cmuxMobileOnAccent`, `cmuxMobileFloatingGlass(in:interactive:)` for glass.
A needed literal says why with `// color-literal-allow: <reason>` on its line. Fails when a file has more
control hits than its row in ios-control-colors-baseline.tsv; `--update-baseline` writes today's counts
(lower it; never raise it by hand). `--list` prints each hit.

  python3 scripts/cmux-next/check-ios-control-colors.py [--root DIR] [--baseline FILE] [--update-baseline] [--list]
"""
import argparse
import importlib.util
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("surface_colors", os.path.join(HERE, "check-ios-surface-colors.py"))
surface = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(surface)

REPO = surface.REPO
TREE = surface.TREE
ALLOW = surface.ALLOW
NAMED = surface.NAMED
LITERALS = surface.PATTERNS[:5] + (
    re.compile(r"\b(?:foregroundStyle|foregroundColor|tint|fill|stroke|background|strokeBorder|"
               r"cmuxMobilePressBackground)\(\s*\." + NAMED + r"\b"),
    re.compile(r"\bUIColor\.system(?:Blue|Red|Green|Orange|Yellow|Pink|Purple|Teal|Indigo|Gray)\b|"
               r"\(\s*\.system(?:Blue|Red|Green|Orange|Yellow|Pink|Purple|Teal|Indigo|Gray)\b"),
)
OPENS = re.compile(r"\b(?:Button|Menu|Toggle|ShareLink|PasteButton)\b\s*(?:\(|\{)|\bfunc makeBody\(configuration")
CONTROL_LINE = re.compile(r"cmuxMobilePress(?:Background|Fill)\(|glassEffect\([^)]*\.tint\(|baseBackgroundColor|"
                          r"baseForegroundColor|setTitleColor\(|UIButton\.Configuration")
COMMENT = surface.COMMENT


def literal_count(code):
    """Literal colors on one line; two patterns matching the same color count it once."""
    spans = sorted(m.span() for p in LITERALS for m in p.finditer(code))
    count, end = 0, -1
    for start, stop in spans:
        if start >= end:
            count += 1
        end = max(end, stop)
    return count


def control_hits(text):
    """(line number, line) of each literal color in control code."""
    found = []
    depth = 0          # brace depth inside the outermost open control, 0 when outside
    for number, line in enumerate(text.splitlines(), 1):
        if COMMENT.match(line):
            continue
        code = line.split("//", 1)[0]
        opens = depth == 0 and OPENS.search(code)
        inside = depth > 0 or bool(opens)
        if (inside or CONTROL_LINE.search(code)) and ALLOW not in line:
            found.extend([(number, line.strip())] * literal_count(code))
        if inside:
            depth += code.count("{") - code.count("}")
            if depth < 0 or (opens and "{" not in code and "(" in code and depth == 0):
                depth = 0
    return found


def scan(root):
    counts, lines = {}, {}
    for directory, dirs, files in os.walk(os.path.join(root, TREE)):
        dirs[:] = [d for d in dirs if d not in (".build", "Tests")]
        for name in files:
            if not name.endswith(".swift"):
                continue
            full = os.path.join(directory, name)
            rel = os.path.relpath(full, root)
            if rel in surface.SKIP:
                continue
            with open(full, encoding="utf-8", errors="replace") as handle:
                found = control_hits(handle.read())
            if found:
                counts[rel] = len(found)
                lines[rel] = found
    return counts, lines


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", default=REPO)
    parser.add_argument("--baseline", default=os.path.join(HERE, "ios-control-colors-baseline.tsv"))
    parser.add_argument("--update-baseline", action="store_true")
    parser.add_argument("--list", action="store_true")
    args = parser.parse_args(argv)
    counts, lines = scan(args.root)
    if args.list:
        for rel in sorted(lines):
            for number, line in lines[rel]:
                print(f"{rel}:{number}: {line}")
    if args.update_baseline:
        with open(args.baseline, "w", encoding="utf-8") as handle:
            handle.write("# check-ios-control-colors.py baseline: path<TAB>count (lower it; never raise it by hand)\n")
            for rel in sorted(counts):
                handle.write(f"{rel}\t{counts[rel]}\n")
        print(f"check-ios-control-colors: baseline written ({sum(counts.values())} in {len(counts)} files)")
        return 0
    baseline = surface.read_baseline(args.baseline)
    over = {rel: (count, baseline.get(rel, 0)) for rel, count in counts.items() if count > baseline.get(rel, 0)}
    if not over:
        print(f"check-ios-control-colors: ok ({sum(counts.values())} left in the baseline)")
        return 0
    annotate = os.environ.get("GITHUB_ACTIONS") == "true"
    print("check-ios-control-colors: new literal colors in iPhone controls:")
    for rel, (count, base) in sorted(over.items()):
        message = (f"{count} literal colors in controls, baseline {base}: use the theme's colors "
                   f"(CmuxMobileTheme.standard.colors, cmuxMobileAccent) and cmuxMobileFloatingGlass, "
                   f"or mark a needed literal `// {ALLOW} <reason>`")
        print(f"::error file={rel}::{message}" if annotate else f"  {rel}: {message}")
        for number, line in lines[rel]:
            print(f"    {rel}:{number}: {line}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
