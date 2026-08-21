#!/usr/bin/env python3
"""Asserts docs/cli-command-tree.txt matches `cmux __dump-command-tree`.

The snapshot is how CLI surface changes stay reviewable: any command, flag, or
completion-kind change shows up as a diff hunk in this file.
"""
from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path


def repo_root() -> Path:
    return Path(__file__).resolve().parent.parent


def main() -> int:
    cli = os.environ.get("CMUX_CLI_BIN")
    if not cli or not os.access(cli, os.X_OK):
        print("FAIL: set CMUX_CLI_BIN to the built cmux binary")
        return 1

    proc = subprocess.run(
        [cli, "__dump-command-tree"],
        text=True, capture_output=True, check=False, timeout=30.0,
    )
    if proc.returncode != 0:
        print(f"FAIL: __dump-command-tree exited {proc.returncode}\n{proc.stderr}")
        return 1

    snapshot = repo_root() / "docs" / "cli-command-tree.txt"
    expected = snapshot.read_text(encoding="utf-8")
    if proc.stdout != expected:
        print(
            "FAIL: CLI command tree drifted from docs/cli-command-tree.txt\n"
            f"Regenerate with: {cli} __dump-command-tree > {snapshot}"
        )
        return 1

    print(f"PASS: CLI command tree matches snapshot ({len(expected.splitlines())} lines)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
