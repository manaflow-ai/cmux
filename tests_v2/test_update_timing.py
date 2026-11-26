#!/usr/bin/env python3
"""
Verify update UI timing constants so update indicators are visible long enough.
"""

from pathlib import Path
import re
import sys


ROOT = Path(__file__).resolve().parents[1]
TIMING_FILE = ROOT / "Sources" / "Update" / "UpdateTiming.swift"


def read_constants(text: str) -> dict[str, float]:
    constants = {}
    pattern = re.compile(r"static let (\w+): TimeInterval = ([0-9.]+)")
    for match in pattern.finditer(text):
        constants[match.group(1)] = float(match.group(2))
    return constants


def main() -> int:
    if not TIMING_FILE.exists():
        print(f"Missing {TIMING_FILE}")
        return 1

    constants = read_constants(TIMING_FILE.read_text())
    required = {
        "minimumCheckDisplayDuration": 2.0,
        "noUpdateDisplayDuration": 5.0,
    }

    failures = []
    for name, expected in required.items():
        actual = constants.get(name)
        if actual is None:
            failures.append(f"{name} missing")
            continue
        if actual != expected:
            failures.append(f"{name} = {actual} (expected {expected})")

    if failures:
        print("Update timing test failed:")
        for failure in failures:
            print(f"  - {failure}")
        return 1

    print("Update timing test passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
