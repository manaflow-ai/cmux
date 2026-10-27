#!/usr/bin/env python3
"""Reject user attachment size-cap constants in attachment/upload code.

Preview budgets and transport chunk sizes remain valid; this guard specifically catches the
MAX_*BYTES naming pattern that historically represented a hard user-file rejection.
"""

from __future__ import annotations

import argparse
import os
import re
from pathlib import Path

# Protocol frames/ranges, filename validation and terminal ACK buffers do not reject an
# original: transfer loops split files at these boundaries. Never exempt a file/total cap.
TRANSPORT_BOUNDS = {"MAX_CHUNK_BYTES", "MAX_RANGE_BYTES", "MAX_MESSAGE_BYTES", "MAX_NAME_BYTES", "MAX_PENDING_INPUT_ACK_BYTES"}
FORBIDDEN = re.compile(r"\bMAX_[A-Z0-9_]*BYTES\b")
EXCLUDED = {".git", ".build", "node_modules", "dist", "fixtures", "generated", "tests", "test", "__tests__", "vendor", "target", "build", "third_party"}
SOURCE_SUFFIXES = {".swift", ".rs", ".ts", ".tsx", ".js", ".mjs"}


def files(root: Path) -> list[Path]:
    found: list[Path] = []
    for folder, directories, names in os.walk(root):
        directories[:] = [name for name in directories if name.lower() not in EXCLUDED and not name.endswith("Tests") and not name.startswith(".")]
        for name in names:
            path = Path(folder) / name
            relative = path.relative_to(root)
            if path.suffix not in SOURCE_SUFFIXES or ".test." in name or ".spec." in name:
                continue
            if any("attachment" in part.lower() or "upload" in part.lower() for part in relative.parts):
                found.append(path)
    return sorted(found)


def violations(root: Path) -> list[str]:
    result: list[str] = []
    for path in files(root):
        try:
            lines = path.read_text(encoding="utf-8").splitlines()
        except UnicodeDecodeError:
            continue
        for line_number, line in enumerate(lines, 1):
            for match in FORBIDDEN.finditer(line):
                if match.group(0) in TRANSPORT_BOUNDS:
                    continue
                result.append(f"{path.relative_to(root)}:{line_number}: {match.group(0)}")
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", nargs="?", type=Path, default=Path(__file__).resolve().parents[2])
    args = parser.parse_args()
    found = violations(args.root.resolve())
    if found:
        print("attachment cap names are forbidden in attachment/upload paths:")
        print("\n".join(found))
        return 1
    print("attachment cap guard: clean")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
