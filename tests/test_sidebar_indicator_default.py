#!/usr/bin/env python3
"""
Regression test for the default sidebar active workspace indicator style.
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path


def get_repo_root() -> Path:
    result = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"],
        capture_output=True,
        text=True,
    )
    if result.returncode == 0:
        return Path(result.stdout.strip())
    return Path.cwd()


def main() -> int:
    repo_root = get_repo_root()
    tab_manager = repo_root / "Sources" / "TabManager.swift"

    if not tab_manager.exists():
        print(f"FAIL: Missing file {tab_manager}")
        return 1

    content = tab_manager.read_text(encoding="utf-8")
    pattern = r"static let defaultStyle:\s*SidebarActiveTabIndicatorStyle\s*=\s*\.leftRail\b"

    if re.search(pattern, content) is None:
        rel = tab_manager.relative_to(repo_root)
        print(f"FAIL: Expected default style `.leftRail` in {rel}")
        return 1

    print("PASS: sidebar indicator default style is left rail")
    return 0


if __name__ == "__main__":
    sys.exit(main())
