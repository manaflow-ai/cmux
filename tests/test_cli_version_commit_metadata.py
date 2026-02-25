#!/usr/bin/env python3
"""Regression test: CLI version output wiring keeps commit metadata support."""

from __future__ import annotations

import subprocess
from pathlib import Path


def get_repo_root() -> Path:
    result = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode == 0:
        return Path(result.stdout.strip())
    return Path.cwd()


def require(content: str, needle: str, message: str, failures: list[str]) -> None:
    if needle not in content:
        failures.append(message)


def main() -> int:
    repo_root = get_repo_root()
    cli_path = repo_root / "CLI" / "cmux.swift"
    if not cli_path.exists():
        print(f"FAIL: missing expected file: {cli_path}")
        return 1

    content = cli_path.read_text(encoding="utf-8")
    failures: list[str] = []

    require(
        content,
        'let commit = info["CMUXCommit"].flatMap { normalizedCommitHash($0) }',
        "versionSummary no longer reads CMUXCommit metadata",
        failures,
    )
    require(
        content,
        'return "\\(baseSummary) [\\(commit)]"',
        "versionSummary no longer appends commit metadata",
        failures,
    )
    require(
        content,
        'if let commit = dictionary["CMUXCommit"] as? String,',
        "Info.plist parsing no longer reads CMUXCommit",
        failures,
    )
    require(
        content,
        "if let commit = gitCommitHash(at: current) {",
        "Project fallback no longer probes git commit hash",
        failures,
    )
    require(
        content,
        '["git", "-C", directory.path, "rev-parse", "--short=9", "HEAD"]',
        "Git commit probe command changed unexpectedly",
        failures,
    )
    require(
        content,
        'normalizedCommitHash(ProcessInfo.processInfo.environment["CMUX_COMMIT"])',
        "Environment commit fallback (CMUX_COMMIT) is missing",
        failures,
    )

    if failures:
        print("FAIL: CLI version commit metadata regression(s) detected")
        for failure in failures:
            print(f"- {failure}")
        return 1

    print("PASS: CLI version commit metadata wiring is intact")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
