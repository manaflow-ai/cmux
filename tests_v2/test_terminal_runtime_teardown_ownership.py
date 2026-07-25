#!/usr/bin/env python3
"""Regression: terminal models must delegate native frees to the teardown owner."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SURFACE_SOURCES = [
    ROOT
    / "Packages/macOS/CmuxTerminal/Sources/CmuxTerminal/Surface/TerminalSurface+RuntimeLifecycle.swift",
    ROOT / "Packages/macOS/CmuxTerminal/Sources/CmuxTerminal/Surface/TerminalSurface.swift",
]


def main() -> int:
    violations = []
    for source in SURFACE_SOURCES:
        for line_number, line in enumerate(source.read_text(encoding="utf-8").splitlines(), start=1):
            code = line.split("//", 1)[0]
            if "ghostty_surface_free(" in code:
                violations.append(f"{source.relative_to(ROOT)}:{line_number}: {line.strip()}")

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
