#!/usr/bin/env python3
"""Drop Xcode SourcePackages state that stores checkout-absolute paths."""

from __future__ import annotations

import argparse
from pathlib import Path


def display_path(path: Path) -> str:
    try:
        return str(path.relative_to(Path.cwd()))
    except ValueError:
        return str(path)


def remove_workspace_state(source_packages_dir: Path) -> list[Path]:
    if not source_packages_dir.exists():
        return []

    state_file = source_packages_dir / "workspace-state.json"
    if not state_file.is_file():
        return []

    state_file.unlink()
    return [state_file]


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Remove Xcode SourcePackages workspace-state.json files after a "
            "cache restore. These state files can contain absolute paths from "
            "a previous checkout; Xcode recreates them during package resolve."
        )
    )
    parser.add_argument(
        "source_packages_dir",
        type=Path,
        help="Path passed to xcodebuild -clonedSourcePackagesDirPath",
    )
    args = parser.parse_args()

    source_packages_dir = args.source_packages_dir.resolve()
    removed = remove_workspace_state(source_packages_dir)
    if removed:
        for path in removed:
            print(f"removed stale Xcode SourcePackages state: {display_path(path)}")
    else:
        print(
            "no Xcode SourcePackages workspace-state.json files found under "
            f"{display_path(source_packages_dir)}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
