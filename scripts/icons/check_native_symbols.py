#!/usr/bin/env python3
"""Ratchet: native chrome icons come from the cmux pack (CmuxNextIcons), not raw SF Symbols.

Every icon the app draws comes from one registry, design/icons/source, generated into CmuxNextIcons
(`NSImage.icon(_:)`, `Icon(...)`, `NSImage.icon(symbol:)` for an SF name the pack stands in for).
This counts the calls that draw an SF Symbol directly, per Swift source file under Packages/macOS
(Sources only; tests and the CmuxNextIcons fallback itself are left out):

    Image(systemName:  NSImage(systemSymbolName:  systemImage:  NSImage.systemSymbol(

Today's calls are recorded in scripts/icons/native-symbols-baseline.json. A file may not go above its
count and a file not listed may not add one. A count that drops must be lowered in the same PR
(`--update-baseline`, which refuses to raise any count), so the baseline stays the real debt.

Run: python3 scripts/icons/check_native_symbols.py [--update-baseline]
"""
import json
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
ROOT = REPO / "Packages" / "macOS"
BASELINE = Path(__file__).with_name("native-symbols-baseline.json")
# The pack's own SF fallback (an icon name the pack lacks) is the one place that may draw a symbol.
EXEMPT = ("Packages/macOS/CmuxNext/Sources/CmuxNextIcons/",)
CALL = re.compile(r"\bImage\(systemName:|\bNSImage\(systemSymbolName:|\bsystemImage:|\bNSImage\.systemSymbol\(")


def counts():
    found = {}
    paths = (p for sources in ROOT.glob("*/Sources") for p in sources.rglob("*.swift"))
    for path in sorted(paths):
        rel = path.relative_to(REPO).as_posix()
        if rel.startswith(EXEMPT):
            continue
        n = 0
        for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
            code = line.split("//", 1)[0]
            n += len(CALL.findall(code))
        if n:
            found[rel] = n
    return found


def main(argv):
    actual = counts()
    base = json.loads(BASELINE.read_text()) if BASELINE.exists() else {}
    grew = {f: n for f, n in actual.items() if n > base.get(f, 0)}
    if "--update-baseline" in argv:
        if grew and BASELINE.exists():
            for f, n in sorted(grew.items()):
                print(f"baseline would grow: {f}: {base.get(f, 0)} -> {n}", file=sys.stderr)
            return 1
        BASELINE.write_text(json.dumps(dict(sorted(actual.items())), indent=1) + "\n")
        print(f"native symbols baseline: {sum(actual.values())} calls in {len(actual)} files")
        return 0
    errors = []
    for f, n in sorted(grew.items()):
        errors.append(
            f"{f}: {n} raw SF Symbol calls (baseline {base.get(f, 0)}); draw a pack icon "
            "(NSImage.icon(.name) / Icon(.name), or add the drawing to design/icons/source)"
        )
    for f, allowed in sorted(base.items()):
        n = actual.get(f, 0)
        if n < allowed:
            errors.append(
                f"{f}: {n} raw SF Symbol calls, baseline {allowed}; lower it with "
                "python3 scripts/icons/check_native_symbols.py --update-baseline"
            )
    for e in errors:
        print(f"native symbols: {e}", file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
