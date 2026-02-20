#!/usr/bin/env python3
"""
Lint test to catch SwiftUI patterns that cause performance issues.

This test checks for:
1. Text(_:style:) with auto-updating date styles (.time, .timer, .relative)
   These cause continuous view updates and can lead to high CPU usage.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path
from typing import List, Tuple


def get_repo_root():
    """Get the repository root directory."""
    # Try git first
    result = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"],
        capture_output=True,
        text=True,
    )
    if result.returncode == 0:
        return Path(result.stdout.strip())

    # Fall back to nearby directories that look like the repo root.
    cwd = Path.cwd()
    if (cwd / "Sources").exists():
        return cwd

    for candidate in [cwd.parent, cwd.parent.parent]:
        if (candidate / "Sources").exists() and list(candidate.glob("*.xcodeproj")):
            return candidate

    # Last resort: use current directory
    return cwd


def find_swift_files(repo_root: Path) -> List[Path]:
    """Find all Swift files in Sources directory (excluding vendored code)."""
    sources_dir = repo_root / "Sources"
    if not sources_dir.exists():
        return []
    return list(sources_dir.rglob("*.swift"))


def check_autoupdating_text_styles(files: List[Path]) -> List[Tuple[Path, int, str]]:
    """
    Check for Text(_:style:) with auto-updating date styles.

    These patterns cause continuous SwiftUI view updates:
    - Text(date, style: .time)      - updates every second/minute
    - Text(date, style: .timer)     - updates continuously
    - Text(date, style: .relative)  - updates periodically
    - Text(date, style: .offset)    - updates periodically

    Instead, use static formatting:
    - Text(date.formatted(date: .omitted, time: .shortened))
    """
    violations = []

    # Patterns that indicate auto-updating Text with Date
    # The key patterns are: Text(something, style: .time/timer/relative/offset)
    problematic_patterns = [
        "style: .time",
        "style: .timer",
        "style: .relative",
        "style: .offset",
        "style:.time",
        "style:.timer",
        "style:.relative",
        "style:.offset",
    ]

    for file_path in files:
        try:
            content = file_path.read_text()
            lines = content.split('\n')

            for line_num, line in enumerate(lines, start=1):
                # Skip comments
                stripped = line.strip()
                if stripped.startswith("//"):
                    continue

                for pattern in problematic_patterns:
                    if pattern in line:
                        violations.append((file_path, line_num, line.strip()))
                        break
        except Exception as e:
            print(f"Warning: Could not read {file_path}: {e}", file=sys.stderr)

    return violations


def main():
    """Run the lint checks."""
    repo_root = get_repo_root()
    swift_files = find_swift_files(repo_root)

    print(f"Checking {len(swift_files)} Swift files for performance issues...")

    # Check for auto-updating Text styles
    violations = check_autoupdating_text_styles(swift_files)

    if violations:
        print("\n❌ LINT FAILURES: Auto-updating Text styles found")
        print("=" * 60)
        print("These patterns cause continuous SwiftUI view updates and high CPU usage:")
        print()

        for file_path, line_num, line in violations:
            rel_path = file_path.relative_to(repo_root)
            print(f"  {rel_path}:{line_num}")
            print(f"    {line}")
            print()

        print("FIX: Replace with static formatting:")
        print("  Instead of:  Text(date, style: .time)")
        print("  Use:         Text(date.formatted(date: .omitted, time: .shortened))")
        print()
        return 1

    print("✅ No auto-updating Text style patterns found")
    return 0


if __name__ == "__main__":
    sys.exit(main())
