#!/usr/bin/env python3
"""Regression guard for CMUXTERM-MACOS-B0 startup snapshot size protection."""

from __future__ import annotations

import subprocess
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


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def require(content: str, needle: str, message: str, failures: list[str]) -> None:
    if needle not in content:
        failures.append(message)


def main() -> int:
    repo_root = get_repo_root()
    session_persistence_path = repo_root / "Sources" / "SessionPersistence.swift"
    if not session_persistence_path.exists():
        print(f"Missing expected file: {session_persistence_path}")
        return 1

    content = read_text(session_persistence_path)
    failures: list[str] = []

    require(
        content,
        "maxSnapshotBytes",
        "Session persistence policy is missing a max snapshot size limit",
        failures,
    )
    require(
        content,
        "snapshotFileSize(at: fileURL)",
        "Session restore no longer checks snapshot file size before decode",
        failures,
    )
    require(
        content,
        "session.restore.skipped.oversize_snapshot",
        "Oversized startup snapshots are no longer breadcrumbed for diagnostics",
        failures,
    )
    require(
        content,
        "data.count <= SessionPersistencePolicy.maxSnapshotBytes",
        "Session restore no longer enforces decoded data size limit",
        failures,
    )

    if failures:
        print("FAIL: issue B0 regression(s) detected")
        for failure in failures:
            print(f"- {failure}")
        return 1

    print("PASS: issue B0 startup snapshot size guards are present")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
