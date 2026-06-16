#!/usr/bin/env python3
"""Validate a restored SwiftPM source-package cache before CI builds use it."""

from __future__ import annotations

import os
import re
import sys
from pathlib import Path


MAX_SCAN_BYTES = 4 * 1024 * 1024
PACKAGE_PATH_RE = re.compile(
    rb"/[A-Za-z0-9_./+@=-]*(?:\.ci-source-packages|\.spm-cache)"
    rb"(?:/[^\x00\r\n\"'<> ]*)?"
)


def has_required_binary_artifacts(cache_dir: Path) -> bool:
    sparkle = cache_dir / "artifacts" / "sparkle" / "Sparkle" / "Sparkle.xcframework"
    if not sparkle.is_dir():
        print(f"Missing Sparkle binary artifact: {sparkle}", file=sys.stderr)
        return False

    sentry_artifacts = list(
        (cache_dir / "artifacts" / "sentry-cocoa").glob("*/*.xcframework")
    )
    if not any(path.is_dir() for path in sentry_artifacts):
        print(
            f"Missing Sentry binary artifact under: {cache_dir / 'artifacts' / 'sentry-cocoa'}",
            file=sys.stderr,
        )
        return False

    return True


def iter_scannable_files(cache_dir: Path):
    for dirpath, dirnames, filenames in os.walk(cache_dir):
        dirnames[:] = [
            name
            for name in dirnames
            if name not in {".git", ".build", "DerivedData"}
        ]
        for filename in filenames:
            path = Path(dirpath) / filename
            try:
                stat = path.stat()
            except OSError:
                continue
            if stat.st_size > MAX_SCAN_BYTES:
                continue
            yield path


def stale_cache_references(cache_dir: Path) -> list[tuple[Path, str]]:
    current_cache = os.path.realpath(cache_dir)
    stale: list[tuple[Path, str]] = []

    for path in iter_scannable_files(cache_dir):
        try:
            data = path.read_bytes()
        except OSError:
            continue
        if b".ci-source-packages" not in data and b".spm-cache" not in data:
            continue

        for match in PACKAGE_PATH_RE.finditer(data):
            reference = match.group(0).decode("utf-8", errors="ignore")
            normalized = os.path.realpath(reference)
            if normalized == current_cache or normalized.startswith(current_cache + os.sep):
                continue
            stale.append((path, reference))
            if len(stale) >= 10:
                return stale

    return stale


def main() -> int:
    if len(sys.argv) != 2:
        print(
            "usage: validate_swift_package_cache.py <source-packages-dir>",
            file=sys.stderr,
        )
        return 2

    cache_dir = Path(sys.argv[1])
    if not cache_dir.is_dir():
        print(f"Swift package cache directory does not exist: {cache_dir}", file=sys.stderr)
        return 1

    if not has_required_binary_artifacts(cache_dir):
        return 1

    stale = stale_cache_references(cache_dir)
    if stale:
        print(
            "Swift package cache contains stale absolute source-package paths:",
            file=sys.stderr,
        )
        for path, reference in stale:
            print(f"  {path}: {reference}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
