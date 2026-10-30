#!/usr/bin/env python3
"""Drop a warm tour DerivedData's prebuilt modules when a binary pin changes.

    media_module_cache_stamp.py clear  --source DIR --derived-data DIR
    media_module_cache_stamp.py record --source DIR --derived-data DIR

The cmux-next tour (.github/workflows/cmux-next-media.yml) keeps one
DerivedData per tag warm across a pull request's tours. Xcode copies a binary
target's headers (GhosttyNextKit's ghostty.h) into Build/Products/Debug/include,
but it does not rebuild the explicit Clang module it precompiled from them. So
when a later tour on the same Mac brings a new GhosttyNextKit pin, every Swift
module importing it fails with "ghostty.h has been modified since the module
file ... was built" (job 117892119256: that Mac last built the tag with
e6a27a1fb, the new head pins ced99dcde).

The key is every sha256 literal in the source's tracked Package.swift files
(the binary targets' checksums change with their URLs) plus every tracked
Package.resolved. `clear`, before the build, removes the dir's build state
when the stamp is missing or differs, then stamps it: what is left was built
from no other pin, whether the build then succeeds or not. `record`, after a
build that succeeded, writes the stamp too. A dir that does not exist yet has
nothing to clear.

The build state is the whole Build dir and the module caches, not only the
precompiled module dirs. With only those gone, Xcode's build description in
Build/Intermediates.noindex/XCBuildData still listed the removed .pcm files
as built, and the next compile failed within a minute on "module file
'.../ExplicitPrecompiledModules/Darwin-*.pcm' not found": all 14 such tour
failures on 2026-10-19 (e.g. job 118285853270) ran right after a clear of that
dir. A failed build never recorded the stamp, so each retry cleared and failed
again. The package checkouts in SourcePackages stay; the build after a pin
change is otherwise cold.
"""

from __future__ import annotations

import argparse
import hashlib
import re
import shutil
import subprocess
import sys
from pathlib import Path

STAMP = "cmux-binary-pins.stamp"
# Products, intermediates, the build description and the explicit module
# builds under Build, the implicit module cache, and the SDK stat caches.
BUILD_STATE = (
    "Build",
    "ModuleCache.noindex",
    "SDKStatCaches.noindex",
)
CHECKSUM = re.compile(r"\b[0-9a-f]{64}\b")


def tracked(source: Path, pattern: str) -> list[str]:
    result = subprocess.run(
        ["git", "-C", str(source), "ls-files", "-z", "--", pattern],
        check=True,
        stdout=subprocess.PIPE,
    )
    return sorted(name for name in result.stdout.decode().split("\0") if name)


def pin_key(source: Path) -> str:
    """A hash of the binary pins the source tree builds against."""
    digest = hashlib.sha256()
    for name in tracked(source, "*Package.swift"):
        text = (source / name).read_text(errors="replace")
        for checksum in CHECKSUM.findall(text):
            digest.update(f"{name} {checksum}\n".encode())
    for name in tracked(source, "*Package.resolved"):
        digest.update(f"{name}\n".encode())
        digest.update((source / name).read_bytes())
    return digest.hexdigest()


def clear(source: Path, derived: Path) -> None:
    if not derived.is_dir():
        print(f"{derived} does not exist yet: nothing to clear")
        return
    key = pin_key(source)
    stamp = derived / STAMP
    try:
        previous = stamp.read_text().strip()
    except OSError:
        previous = ""
    if previous == key:
        print(f"binary pins unchanged since the last build in {derived} ({key[:12]})")
        return
    why = f"changed ({previous[:12]} -> {key[:12]})" if previous else f"not recorded (now {key[:12]})"
    print(f"binary pins {why}: clearing the build state in {derived}")
    stamp.unlink(missing_ok=True)
    for relative in BUILD_STATE:
        path = derived / relative
        if path.is_symlink():
            path.unlink()
        elif path.exists():
            shutil.rmtree(path)
        else:
            continue
        print(f"  removed {relative}")
    stamp.write_text(key + "\n")


def record(source: Path, derived: Path) -> None:
    if not derived.is_dir():
        print(f"{derived} does not exist: no stamp written", file=sys.stderr)
        return
    key = pin_key(source)
    (derived / STAMP).write_text(key + "\n")
    print(f"recorded binary pins {key[:12]} in {derived}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("mode", choices=("clear", "record"))
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--derived-data", required=True, type=Path)
    args = parser.parse_args(argv)
    (clear if args.mode == "clear" else record)(args.source, args.derived_data)
    return 0


if __name__ == "__main__":
    sys.exit(main())
