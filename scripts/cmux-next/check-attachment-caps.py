#!/usr/bin/env python3
"""Reject user attachment size-cap constants in attachment/upload code.

Preview budgets and transport chunk sizes remain valid; this guard specifically catches the
MAX_*BYTES naming pattern that historically represented a hard user-file rejection.
"""

from __future__ import annotations

import argparse
import re
from pathlib import Path

FORBIDDEN = re.compile(r"\bMAX_[A-Z0-9_]*BYTES\b")
EXCLUDED = {".git", ".build", "node_modules", "dist", "fixtures", "generated"}
SCAN_ROOTS = (
    "webviews/src",
    "Packages/Shared/CmuxHomeCore/Sources/CmuxHomeCore/Attachments",
    "Packages/macOS/CmuxNext/Sources",
    "Packages/iOS/CmuxMobileShellModel/Sources/CmuxMobileShellModel/TaskComposerAttachment.swift",
    "backend/packages/home-core/src/conversation/attachments.ts",
    "backend/apps/api/src/home-attachments.ts",
    "cmux-tui/crates/cmux-conversation/src/attachments.rs",
    "cmux-tui/crates/cmux-conversation/src/link_preview.rs",
)


def files(root: Path, paths: tuple[str, ...] | None = None) -> list[Path]:
    if paths is None:
        paths = SCAN_ROOTS
    found: list[Path] = []
    for raw in paths:
        path = root / raw
        if path.is_file():
            found.append(path)
        elif path.is_dir():
            found.extend(
                sorted(
                    item
                    for item in path.rglob("*")
                    if item.is_file()
                    and any("attachment" in part.lower() or "upload" in part.lower() for part in item.relative_to(path).parts + (item.name,))
                )
            )
    return found


def violations(root: Path, paths: tuple[str, ...] | None = None) -> list[str]:
    result: list[str] = []
    for path in files(root, paths):
        try:
            lines = path.read_text(encoding="utf-8").splitlines()
        except UnicodeDecodeError:
            continue
        for line_number, line in enumerate(lines, 1):
            for match in FORBIDDEN.finditer(line):
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
