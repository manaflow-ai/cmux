#!/usr/bin/env python3
"""Regression: terminal models must delegate native frees to the teardown owner."""

import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SURFACE_DIRECTORY = ROOT / "Packages/macOS/CmuxTerminal/Sources/CmuxTerminal/Surface"
SURFACE_SOURCES = sorted(SURFACE_DIRECTORY.rglob("*.swift"))
ALLOWED_TEST_HELPERS = {
    "TerminalSurface+Debug.swift": {
        "releaseSurfaceForTesting",
        "replaceSurfaceWithFreedPointerForTesting",
    }
}


def _enclosing_function_name(lines: list[str], line_index: int) -> str:
    """Return the nearest Swift function declaration before a source line."""
    for line in reversed(lines[: line_index + 1]):
        match = re.search(r"\bfunc\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(", line)
        if match:
            return match.group(1)
    return ""


def main() -> int:
    """Reject direct native frees outside the two explicit DEBUG test helpers."""
    if not SURFACE_SOURCES:
        raise AssertionError(f"No Swift surface sources found under {SURFACE_DIRECTORY.relative_to(ROOT)}")

    violations = []
    for source in SURFACE_SOURCES:
        lines = source.read_text(encoding="utf-8").splitlines()
        allowed_helpers = ALLOWED_TEST_HELPERS.get(source.name, set())
        for line_index, line in enumerate(lines):
            code = line.split("//", 1)[0]
            if "ghostty_surface_free(" not in code:
                continue
            if _enclosing_function_name(lines, line_index) in allowed_helpers:
                continue
            violations.append(f"{source.relative_to(ROOT)}:{line_index + 1}: {line.strip()}")

    if violations:
        details = "\n".join(violations)
        raise AssertionError(
            "TerminalSurface owns model state, but it must not directly free Ghostty runtime surfaces. "
            "Queue every native free through TerminalSurfaceRuntimeTeardownCoordinator so Ghostty thread joins "
            f"cannot block the main actor:\n{details}"
        )

    print("PASS: terminal runtime frees are owned by the teardown coordinator")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
