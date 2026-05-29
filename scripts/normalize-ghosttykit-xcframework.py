#!/usr/bin/env python3
from pathlib import Path
import plistlib
import sys


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: normalize-ghosttykit-xcframework.py <GhosttyKit.xcframework>")

    root = Path(sys.argv[1])
    plist_path = root / "Info.plist"
    if not plist_path.exists():
        return

    with plist_path.open("rb") as handle:
        plist = plistlib.load(handle)

    updated = False
    for library in plist.get("AvailableLibraries", []):
        if library.get("SupportedPlatform") != "macos":
            continue
        identifier = library.get("LibraryIdentifier")
        if not identifier:
            continue
        old_name = library.get("LibraryPath") or library.get("BinaryPath")
        if old_name != "ghostty-internal.a":
            continue

        slice_dir = root / identifier
        old_path = slice_dir / old_name
        new_path = slice_dir / "libghostty-internal.a"
        if old_path.exists() and not new_path.exists():
            old_path.rename(new_path)

        library["BinaryPath"] = "libghostty-internal.a"
        library["LibraryPath"] = "libghostty-internal.a"
        updated = True

    if updated:
        with plist_path.open("wb") as handle:
            plistlib.dump(plist, handle)


if __name__ == "__main__":
    main()
