#!/usr/bin/env python3
"""Flag literal styling in iOS view code: theme tokens only.

The class is "UI with literal styling instead of theme tokens"
(docs/ios-theme-tokens.md). A view that writes `Color(red: ...)`,
`.foregroundStyle(.orange)` or `.font(.system(size: 15))` picks its own
color or size, so it misses dark mode, Dynamic Type, the terminal theme and
every later palette change. The fix is a semantic system style or a named
token in the surface's theme type.

Rules (each finding names file:line and the token to use):

  literal-color      Color(red:/white:/hue:), Color(.sRGB/.displayP3, ...),
                     UIColor(red:/white:/hue:/displayP3Red:), #colorLiteral,
                     and hex helpers called with a string literal.
  hue-color          a named hue (Color.blue, UIColor.systemOrange,
                     .foregroundStyle(.red), .tint(.green), ...).
  literal-font-size  .system(size: N), UIFont.systemFont(ofSize: N) and the
                     other point-size font constructors with a number.
  literal-radius     cornerRadius: N, only in packages whose theme defines a
  literal-padding    radius or padding token (THEMED_METRICS below).

Not checked: tests (`/Tests/`, `*Tests.swift`, `/cmuxUITests/`), debug and
preview files (under `/Debug/`, or whose code starts inside `#if ... DEBUG`),
anything after `#Preview` or a `PreviewProvider` in a file, and the token
definitions themselves (files whose name ends in Theme, Palette, Colors or
Tokens, with an optional `+Extension`, e.g. `TerminalTheme+UIKit.swift`).
Comments and string contents are masked first (scripts/swift_source_mask.py).
A line, or one of the two above it, carrying `lint:allow` is skipped.

Existing violations live in scripts/lint-ios-theme-tokens-baseline.txt, keyed
by rule, path and the line's text (not its number), with repeats counted. A
finding beyond the baseline count fails; a baseline entry that no longer
matches is reported as a warning so the count only goes down. Rewrite the
baseline after removing violations with --update-baseline; it refuses to add
entries unless --accept-new is passed too.

Exit codes: 0 clean, 1 new violations, 2 usage error.
"""

from __future__ import annotations

import argparse
import re
import sys
from collections import Counter
from dataclasses import dataclass
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from swift_source_mask import mask_swift_source  # noqa: E402

DEFAULT_ROOTS = ("Packages/iOS", "ios/cmux", "ios/cmuxPackage/Sources")
DEFAULT_BASELINE = "scripts/lint-ios-theme-tokens-baseline.txt"

HUES = "red|orange|yellow|green|mint|teal|cyan|blue|indigo|purple|pink|brown|gray"
SYSTEM_HUES = "systemRed|systemOrange|systemYellow|systemGreen|systemMint|systemTeal|systemCyan|systemBlue|systemIndigo|systemPurple|systemPink|systemBrown|systemGray"
STYLE_MODIFIERS = "foregroundStyle|foregroundColor|tint|accentColor|background|fill|stroke|strokeBorder|listRowBackground|shadow|border"

COLOR_TOKEN = (
    "a semantic color (.primary, .secondary, Color.accentColor / .tint, "
    "PlatformPalette.systemBackground) or a named token in the surface's theme type"
)
HUE_TOKEN = (
    "Color.accentColor / .tint for brand and selection; for status, a named "
    "token in the surface's theme type (e.g. a connected/warning/failure color) "
    "so every surface shows one status palette"
)
FONT_TOKEN = (
    "a text style (.font(.body), .system(.title2, design: .monospaced), "
    "UIFont.preferredFont(forTextStyle:)) or a size scaled with @ScaledMetric / UIFontMetrics"
)


@dataclass(frozen=True)
class Rule:
    name: str
    pattern: re.Pattern
    token: str
    needs_string_argument: bool = False


RULES = (
    Rule(
        "literal-color",
        re.compile(
            r"\b(?:UI|NS)?Color\(\s*(?:red|white|hue|displayP3Red)\s*:"
            r"|\bColor\(\s*\.(?:sRGB|sRGBLinear|displayP3)\s*,"
            r"|#colorLiteral\("
        ),
        COLOR_TOKEN,
    ),
    Rule(
        "literal-color",
        re.compile(r"\b(?:UI|NS)?Color\(\s*(?:hex|hexString|rgb|hexValue)\s*:"),
        COLOR_TOKEN,
        needs_string_argument=True,
    ),
    Rule(
        "hue-color",
        re.compile(
            rf"\b(?:Color|UIColor)\.(?:{HUES}|{SYSTEM_HUES})\b"
            rf"|\.(?:{STYLE_MODIFIERS})\(\s*\.(?:{HUES})\b"
        ),
        HUE_TOKEN,
    ),
    Rule(
        "literal-font-size",
        re.compile(
            r"\.system\(\s*size:\s*[0-9]"
            r"|\bUIFont\.(?:systemFont|boldSystemFont|italicSystemFont|monospacedSystemFont|monospacedDigitSystemFont)\(\s*ofSize:\s*[0-9]"
            r"|\bUIFont\(\s*name:[^)]*size:\s*[0-9]"
            r"|\.custom\([^)]*size:\s*[0-9]"
        ),
        FONT_TOKEN,
    ),
)

# Radius and padding literals are flagged only where the surface's theme
# defines tokens for them. Add a package here when its theme gains them.
THEMED_METRICS = {
    "Packages/iOS/CmuxMobileChanges/": {
        "literal-radius": "ChangesTheme.groupedCornerRadius",
        "literal-padding": "ChangesTheme.rowVerticalPadding / ChangesTheme.hunkSpacing",
    },
}
RADIUS_PATTERN = re.compile(r"\bcornerRadius:\s*[0-9]|\.cornerRadius\(\s*[0-9]")
PADDING_PATTERN = re.compile(r"\.padding\(\s*(?:\.[a-zA-Z]+\s*,\s*)?[0-9]")

TEST_PATH = re.compile(r"(?:^|/)(?:Tests|cmuxUITests|Debug)/|Tests?\.swift$")
TOKEN_FILE = re.compile(r"(?:Theme|Palette|Colors|Tokens)(?:\+[A-Za-z]+)?\.swift$")
PREVIEW_START = re.compile(r"^\s*#Preview\b|:\s*PreviewProvider\b")
ALLOW = "lint:allow"


@dataclass(frozen=True)
class Finding:
    rule: str
    path: str
    line: int
    text: str
    token: str

    @property
    def key(self) -> tuple[str, str, str]:
        return (self.rule, self.path, self.text)


def normalize(text: str) -> str:
    return " ".join(text.split())[:120]


def skipped_path(path: str) -> bool:
    name = path.rsplit("/", 1)[-1]
    return bool(TEST_PATH.search(path) or TOKEN_FILE.search(name)) or "/.build/" in path


def debug_only(masked: list[str]) -> bool:
    """True when the file's code starts inside `#if ... DEBUG` (a debug fixture or preview)."""
    for line in masked:
        stripped = line.strip()
        if not stripped or stripped.startswith("import ") or stripped.startswith("@preconcurrency import "):
            continue
        return stripped.startswith("#if") and "DEBUG" in stripped and "!DEBUG" not in stripped.replace(" ", "")
    return False


def scan_source(path: str, source: str) -> list[Finding]:
    original = source.splitlines()
    masked = mask_swift_source(source).splitlines()
    if debug_only(masked):
        return []
    metrics = next((m for prefix, m in THEMED_METRICS.items() if path.startswith(prefix)), {})
    findings: list[Finding] = []
    for index, masked_line in enumerate(masked):
        if PREVIEW_START.search(masked_line):
            break
        window = original[max(0, index - 2) : index + 1]
        if any(ALLOW in line for line in window):
            continue
        raw = original[index]
        seen: set[str] = set()
        for rule in RULES:
            for match in rule.pattern.finditer(masked_line):
                if rule.needs_string_argument and not raw[match.end() :].lstrip().startswith(('"', '#"')):
                    continue
                if rule.name not in seen:
                    seen.add(rule.name)
                    findings.append(Finding(rule.name, path, index + 1, normalize(raw), rule.token))
        for rule_name, pattern in (("literal-radius", RADIUS_PATTERN), ("literal-padding", PADDING_PATTERN)):
            if rule_name in metrics and pattern.search(masked_line):
                findings.append(Finding(rule_name, path, index + 1, normalize(raw), metrics[rule_name]))
    return findings


def scan(root: Path, roots: tuple[str, ...]) -> list[Finding]:
    findings: list[Finding] = []
    for scope in roots:
        base = root / scope
        if not base.is_dir():
            continue
        for file in sorted(base.rglob("*.swift")):
            path = file.relative_to(root).as_posix()
            if skipped_path(path):
                continue
            findings.extend(scan_source(path, file.read_text(encoding="utf-8", errors="replace")))
    return findings


def read_baseline(path: Path) -> Counter:
    counts: Counter = Counter()
    if not path.is_file():
        return counts
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        parts = line.split("\t", 2)
        if len(parts) == 3:
            counts[tuple(parts)] += 1
    return counts


BASELINE_HEADER = """\
# Literal styling in iOS view code that predates the theme-token lint
# (scripts/lint_ios_theme_tokens.py, docs/ios-theme-tokens.md). The count only
# goes down: fix a line, then run the lint with --update-baseline. Never add
# lines by hand. Format: rule<TAB>path<TAB>line text (repeats count).
"""


def write_baseline(path: Path, findings: list[Finding]) -> None:
    rows = sorted("\t".join(f.key) for f in findings)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(BASELINE_HEADER + "".join(row + "\n" for row in rows), encoding="utf-8")


def package_of(path: str) -> str:
    parts = path.split("/")
    if parts[0] == "Packages" and len(parts) > 2:
        return "/".join(parts[:3])
    return "/".join(parts[:2])


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", default=str(Path(__file__).resolve().parents[1]))
    parser.add_argument("--baseline", default=DEFAULT_BASELINE)
    parser.add_argument("--scope", action="append", help="directory to scan, relative to --root (repeatable)")
    parser.add_argument("--update-baseline", action="store_true", help="rewrite the baseline to the current findings")
    parser.add_argument("--accept-new", action="store_true", help="with --update-baseline, also add new findings")
    parser.add_argument("--summary", action="store_true", help="print the finding count by package and rule")
    args = parser.parse_args(argv)

    root = Path(args.root)
    baseline_path = root / args.baseline
    findings = scan(root, tuple(args.scope) if args.scope else DEFAULT_ROOTS)
    baseline = read_baseline(baseline_path)

    remaining = Counter(baseline)
    new: list[Finding] = []
    for finding in findings:
        if remaining[finding.key] > 0:
            remaining[finding.key] -= 1
        else:
            new.append(finding)
    stale = +remaining

    if args.summary:
        by_package: Counter = Counter((package_of(f.path), f.rule) for f in findings)
        for (package, rule), count in sorted(by_package.items()):
            print(f"{count:5d}  {package}  {rule}")
        print(f"{len(findings):5d}  total")
        return 0

    if args.update_baseline:
        if new and not args.accept_new:
            for finding in new:
                print(f"ERROR   {finding.rule:<28} {finding.path}:{finding.line}  {finding.text}")
            print(f"refusing to add {len(new)} new finding(s) to the baseline; fix them (or pass --accept-new)")
            return 1
        write_baseline(baseline_path, findings)
        print(f"wrote {len(findings)} finding(s) to {args.baseline}")
        return 0

    for finding in new:
        # Same shape as scripts/lint-ios-package-conventions.sh, so the PR-diff
        # gate (scripts/ci/lint-ios-conventions-diff.sh) reads these lines too.
        print(f"ERROR   {finding.rule:<28} {finding.path}:{finding.line}  {finding.text}")
        print(f"        use: {finding.token}")
    for (rule, path, text), count in sorted(stale.items()):
        print(f"WARN    baseline entry no longer found ({count}x): {rule} {path}  {text}")
    if stale:
        print(f"Run python3 scripts/lint_ios_theme_tokens.py --update-baseline to drop {sum(stale.values())} fixed entr(y/ies).")
    if new:
        print(f"FAIL: {len(new)} literal style value(s) in iOS view code; use theme tokens (docs/ios-theme-tokens.md).")
        return 1
    print(f"OK: no new literal styling ({len(findings)} baselined).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
