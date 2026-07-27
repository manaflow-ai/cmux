#!/usr/bin/env python3
"""Regression: terminal models must delegate native frees to the teardown owner."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SURFACE_DIRECTORY = ROOT / "Packages/macOS/CmuxTerminal/Sources/CmuxTerminal/Surface"
SURFACE_SOURCES = sorted(SURFACE_DIRECTORY.rglob("*.swift"))


def _release_build_lines(source: Path):
    """Yield code that can compile outside DEBUG-only conditional branches."""
    conditionals = []

    for line_number, line in enumerate(source.read_text(encoding="utf-8").splitlines(), start=1):
        directive = line.strip()
        parent_skipped = conditionals[-1]["skipped"] if conditionals else False

        if directive.startswith("#if "):
            condition = directive.removeprefix("#if ").strip()
            branch_kind = "debug" if condition == "DEBUG" else "release" if condition == "!DEBUG" else "other"
            conditionals.append(
                {
                    "parent_skipped": parent_skipped,
                    "branch_kind": branch_kind,
                    "skipped": parent_skipped or branch_kind == "debug",
                }
            )
            continue

        if directive.startswith("#elseif "):
            if conditionals:
                condition = directive.removeprefix("#elseif ").strip()
                frame = conditionals[-1]
                branch_kind = "debug" if condition == "DEBUG" else "release" if condition == "!DEBUG" else "other"
                frame["branch_kind"] = branch_kind
                frame["skipped"] = frame["parent_skipped"] or branch_kind == "debug"
            continue

        if directive == "#else":
            if conditionals:
                frame = conditionals[-1]
                frame["skipped"] = frame["parent_skipped"] or frame["branch_kind"] == "release"
            continue

        if directive == "#endif":
            if conditionals:
                conditionals.pop()
            continue

        if not (conditionals and conditionals[-1]["skipped"]):
            yield line_number, line


def main() -> int:
    if not SURFACE_SOURCES:
        raise AssertionError(f"No Swift surface sources found under {SURFACE_DIRECTORY.relative_to(ROOT)}")

    violations = []
    for source in SURFACE_SOURCES:
        for line_number, line in _release_build_lines(source):
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
