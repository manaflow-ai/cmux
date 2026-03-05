#!/usr/bin/env python3
"""Regression guard for issue #666 (sidebar branch stuck after checkout)."""

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


def require(content: str, needle: str, message: str, failures: list[str]) -> None:
    if needle not in content:
        failures.append(message)


def main() -> int:
    repo_root = get_repo_root()
    zsh_path = repo_root / "Resources" / "shell-integration" / "cmux-zsh-integration.zsh"
    bash_path = repo_root / "Resources" / "shell-integration" / "cmux-bash-integration.bash"

    required_paths = [zsh_path, bash_path]
    missing_paths = [str(path) for path in required_paths if not path.exists()]
    if missing_paths:
        print("Missing expected files:")
        for path in missing_paths:
            print(f"  - {path}")
        return 1

    zsh_content = zsh_path.read_text(encoding="utf-8")
    bash_content = bash_path.read_text(encoding="utf-8")

    failures: list[str] = []

    require(
        zsh_content,
        "_CMUX_GIT_HEAD_SIGNATURE",
        "zsh integration is missing git HEAD signature tracking",
        failures,
    )
    require(
        zsh_content,
        "_cmux_git_head_signature",
        "zsh integration is missing git HEAD signature helper",
        failures,
    )
    require(
        zsh_content,
        '"$head_signature" != "$_CMUX_GIT_HEAD_SIGNATURE"',
        "zsh integration no longer compares git HEAD signatures",
        failures,
    )
    require(
        zsh_content,
        "_CMUX_GIT_FORCE=1",
        "zsh integration no longer forces git probe refresh on HEAD changes",
        failures,
    )

    require(
        bash_content,
        "_CMUX_GIT_HEAD_SIGNATURE",
        "bash integration is missing git HEAD signature tracking",
        failures,
    )
    require(
        bash_content,
        "_cmux_git_head_signature",
        "bash integration is missing git HEAD signature helper",
        failures,
    )
    require(
        bash_content,
        "git_head_changed=1",
        "bash integration no longer flags HEAD changes for immediate refresh",
        failures,
    )
    require(
        bash_content,
        '|| "$git_head_changed" == "1"',
        "bash integration no longer restarts running git probes on HEAD change",
        failures,
    )

    if failures:
        print("FAIL: issue #666 regression(s) detected")
        for failure in failures:
            print(f"- {failure}")
        return 1

    print("PASS: issue #666 checkout refresh guards are present")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
