#!/usr/bin/env python3
"""System-blue ratchet (a warning, not a failure): UI code paints the theme, never the system accent
or a hardcoded blue (cx-wqn5).

Counts, per source file, the places that would draw macOS's or WebKit's default blue or a fixed
blue instead of a theme token:
  swift  NSColor.controlAccentColor, keyboardFocusIndicatorColor, selectedContentBackgroundColor,
         alternateSelectedControlColor, selectedControlColor, linkColor, systemBlue, NSColor.blue,
         Color.accentColor, Color.blue, a bare `.accentColor` style and `.tint(.blue)`-style modifiers.
  css    the CSS system colors AccentColor, AccentColorText, Highlight, HighlightText, LinkText,
         SelectedItem, -webkit-focus-ring-color and -apple-system-blue / -control-accent.
  any    a hex (#rgb, #rrggbb) or rgb() literal whose OKLCH hue is blue (220-275 degrees) with
         chroma 0.08 or more.
Theme tokens replace them: Palette.accent / focusRing / selectionFill natively, `--cmux-accent`,
`--cmux-on-accent`, `--cmux-selection` and `--agent-accent` on pages.

Prints a warning (a GitHub `::warning` annotation under CI) for each file over its baseline row and
always exits 0: style ratchets warn. `--update-baseline` rewrites the baseline to today's counts.
Theme data (bundled palettes, syntax colors, brand catalogs, mocks) is not scanned (SKIP).

Documented exception: Messages' blue in the Chief chat's iMessage bubble style
(`home.chiefBubbleStyle` = `imessage`, the default): HomeThemePalette.messagesBlue and MessagesLab's
measured blue (Packages/Shared/CmuxMessagesLab, skipped as vendored Messages data). The `theme`
style takes the theme's accent and surface; nothing outside the iMessage style may borrow that blue.

Documented exception: agent chat links (`--agent-link-base` in
webviews/src/agent-session/shared/styles.css) are blue in every theme (Leo 2026-10-19, "links are
blue, period", #22345); its two literals are its baseline row.

  python3 scripts/cmux-next/check-system-blue.py [--root DIR] [--baseline FILE] [--update-baseline]
"""
import argparse
import math
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
TREES = ("webviews/src", "Packages/macOS/CmuxNext/Sources", "Packages/Shared")
EXTENSIONS = (".swift", ".css", ".ts", ".tsx")
# Theme data, generated catalogs, vendor code and fixtures: colors there are content, not chrome.
SKIP = (
    "Packages/Shared/CmuxTheme/",
    "Packages/Shared/CMUXMobileCore/Sources/CMUXMobileCore/TerminalTheme.swift",
    "Packages/Shared/CmuxAgentBrands/",
    # Each agent session's cursor identity colors, ported from the cmux-cua renderer.
    "Packages/Shared/CmuxAgentCursor/Sources/CmuxAgentCursor/AgentCursorPalette.swift",
    "Packages/Shared/CmuxMessagesLab/",
    "Packages/macOS/CmuxNext/Sources/CmuxNextDesign/GroupColor",
    "Packages/macOS/CmuxNext/Sources/CmuxNextAgentActivity/AgentActivityMockSource.swift",
    "Packages/macOS/CmuxNext/Sources/CmuxNextSettings/Schema/SettingsSchemaSamples.swift",
    "webviews/src/theme/",
    "webviews/src/syntax-colors.ts",
    "webviews/src/appearance.ts",
    "webviews/src/pierre-options.ts",
    "webviews/src/find/",
    "webviews/src/gallery/",
    "webviews/src/agent-session/shared/agentBrands.generated.ts",
    "webviews/src/agent-session/acpmux/diffTheme.ts",
    # Language and framework brand colors for the project picker's glyphs.
    "webviews/src/agent-session/acpmux/projectGlyphs.tsx",
    "webviews/src/agent-session/acpmux-preview/",
    "webviews/src/agent-session/acpmux/prototype/",
    "webviews/src/pages/settings/mockThemes.ts",
)

SWIFT_API = re.compile(
    r"\b(?:NSColor\.)?(?:controlAccentColor|keyboardFocusIndicatorColor|selectedContentBackgroundColor"
    r"|alternateSelectedControlColor|selectedControlColor|systemBlue)\b"
    r"|\bNSColor\.(?:blue|linkColor)\b|\bColor\.(?:accentColor|blue)\b|(?<![\w.])\.accentColor\b"
    # SwiftUI's implicit `.blue` in a style modifier; elsewhere `.blue` is usually a group color case.
    r"|\b(?:foregroundStyle|foregroundColor|tint|fill|stroke|background|accentColor)\(\s*\.blue\b"
)
CSS_SYSTEM = re.compile(
    r"(?<![\w-])(?:AccentColor|AccentColorText|Highlight|HighlightText|LinkText|SelectedItem)(?![\w-])"
    r"|-webkit-focus-ring-color|-apple-system-(?:blue|control-accent)"
)
# #rgb, #rgba, #rrggbb and #rrggbbaa; the alpha digits are ignored.
HEX = re.compile(r"#([0-9a-fA-F]{8}|[0-9a-fA-F]{6}|[0-9a-fA-F]{3,4})(?![0-9a-zA-Z])")
RGB = re.compile(r"rgba?\(\s*(\d{1,3})\s*,?\s*(\d{1,3})\s*,?\s*(\d{1,3})")
# A comment line, but not a CSS rule that starts with the universal selector (`* {`, `*::selection`).
COMMENT = re.compile(r"^\s*(?://|/\*|\*(?:\s|$)(?![^{}]*[{}]))")


def oklch(r, g, b):
    def linear(c):
        c /= 255
        return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4

    r, g, b = linear(r), linear(g), linear(b)
    l = (0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b) ** (1 / 3)
    m = (0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b) ** (1 / 3)
    s = (0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b) ** (1 / 3)
    a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
    bb = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
    return math.hypot(a, bb), math.degrees(math.atan2(bb, a)) % 360


def is_blue(r, g, b):
    chroma, hue = oklch(r, g, b)
    return chroma >= 0.08 and 220 <= hue <= 275


def hits(path, text):
    count = 0
    for line in text.splitlines():
        if COMMENT.match(line):
            continue
        if path.endswith(".swift"):
            count += len(SWIFT_API.findall(line))
        if path.endswith(".css"):
            count += len(CSS_SYSTEM.findall(line))
        for match in HEX.finditer(line):
            digits = match.group(1)
            if len(digits) <= 4:
                digits = "".join(c * 2 for c in digits)
            if is_blue(*(int(digits[i : i + 2], 16) for i in (0, 2, 4))):
                count += 1
        for match in RGB.finditer(line):
            channels = [int(value) for value in match.groups()]
            if max(channels) <= 255 and is_blue(*channels):
                count += 1
    return count


def scan(root):
    counts = {}
    for tree in TREES:
        base = os.path.join(root, tree)
        for directory, dirs, files in os.walk(base):
            dirs[:] = [d for d in dirs if d not in ("node_modules", "generated", ".build", "Tests")]
            for name in files:
                if not name.endswith(EXTENSIONS) or ".gallery." in name or ".test." in name:
                    continue
                full = os.path.join(directory, name)
                rel = os.path.relpath(full, root)
                if rel.startswith(SKIP):
                    continue
                with open(full, encoding="utf-8", errors="replace") as handle:
                    count = hits(rel, handle.read())
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
                try:
                    rel, count = line.rstrip("\n").split("\t")
                    rows[rel] = int(count)
                except ValueError:
                    # A warning ratchet never fails the build, not even on a mangled baseline row.
                    print(f"check-system-blue: ignoring malformed baseline row: {line.strip()!r}")
    return rows


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", default=REPO)
    parser.add_argument("--baseline", default=os.path.join(HERE, "system-blue-baseline.tsv"))
    parser.add_argument("--update-baseline", action="store_true")
    args = parser.parse_args()
    counts = scan(args.root)
    if args.update_baseline:
        with open(args.baseline, "w", encoding="utf-8") as handle:
            handle.write("# check-system-blue.py baseline: path<TAB>count (lower it; never raise it by hand)\n")
            for rel in sorted(counts):
                handle.write(f"{rel}\t{counts[rel]}\n")
        print(f"check-system-blue: baseline written ({sum(counts.values())} in {len(counts)} files)")
        return 0
    baseline = read_baseline(args.baseline)
    over = {rel: (count, baseline.get(rel, 0)) for rel, count in counts.items() if count > baseline.get(rel, 0)}
    if not over:
        print(f"check-system-blue: ok ({sum(counts.values())} left in the baseline)")
        return 0
    annotate = os.environ.get("GITHUB_ACTIONS") == "true"
    print("check-system-blue: new system-accent or hardcoded-blue colors (warning; use theme tokens):")
    for rel, (count, base) in sorted(over.items()):
        message = f"{count} system-accent or blue literals, baseline {base}: use Palette.accent / --cmux-accent"
        print(f"::warning file={rel}::{message}" if annotate else f"  {rel}: {message}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
