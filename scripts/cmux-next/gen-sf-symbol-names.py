#!/usr/bin/env python3
"""Writes the bundled SF Symbols name snapshot for the icon picker's Symbols tab
(Packages/macOS/CmuxNext/Sources/CmuxNextApp/Resources/IconPickerSymbols.txt): the
names in this Mac's system symbol catalog that macOS MIN_MACOS (the package's deployment target)
already draws, sorted, one per line. At run time the app adds
names a newer system knows (IconPickerSymbols.names); without the system file it uses this
snapshot, so the tab is never empty (plans/cmux-next/icons.md).

  scripts/cmux-next/gen-sf-symbol-names.py          # regenerate from this Mac
  scripts/cmux-next/gen-sf-symbol-names.py --check  # the snapshot is sorted, unique and valid
"""
import plistlib
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "Packages/macOS/CmuxNext/Sources/CmuxNextApp/Resources/IconPickerSymbols.txt"
CATALOG = Path("/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources/name_availability.plist")
MIN_MACOS = (26, 0)
NAME = re.compile(r"^[a-z0-9]+(\.[a-z0-9]+)*$")


def check() -> int:
    names = OUT.read_text().splitlines()
    bad = [n for n in names if not NAME.match(n) or len(n) > 128]
    if bad or names != sorted(set(names)) or not names:
        print(f"error: {OUT} must be non-empty, sorted, unique symbol names (bad: {bad[:5]})", file=sys.stderr)
        return 1
    print(f"symbol snapshot ok ({len(names)} names)")
    return 0


def main() -> int:
    if "--check" in sys.argv:
        return check()
    with CATALOG.open("rb") as handle:
        catalog = plistlib.load(handle)
    releases = catalog["year_to_release"]

    def drawn_on_minimum(year: str) -> bool:
        version = releases.get(year, {}).get("macOS")
        return version is not None and tuple(int(p) for p in version.split(".")) <= MIN_MACOS

    names = sorted(
        n for n, year in catalog["symbols"].items() if NAME.match(n) and len(n) <= 128 and drawn_on_minimum(year)
    )
    OUT.write_text("\n".join(names) + "\n")
    print(f"wrote {OUT.relative_to(ROOT)} ({len(names)} names)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
