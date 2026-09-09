#!/usr/bin/env python3
"""Asserts docs/cli-command-tree.txt matches `cmux __dump-command-tree`.

The snapshot is how CLI surface changes stay reviewable: any command, flag, or
completion-kind change shows up as a diff hunk in this file.
"""
from __future__ import annotations

import os
import subprocess
import sys
import tempfile
from pathlib import Path


def repo_root() -> Path:
    return Path(__file__).resolve().parent.parent


def main() -> int:
    cli = os.environ.get("CMUX_CLI_BIN")
    if not cli or not os.access(cli, os.X_OK):
        print("FAIL: set CMUX_CLI_BIN to the built cmux binary")
        return 1

    # A controlled environment, like the other CLI-spawning tests here. An
    # ambient CMUX_CLI_LEGACY_PARSER=1 routes `__dump-command-tree` to the legacy
    # parser, which emits no dump at all and fails this as a snapshot drift; an
    # ambient CMUX_SOCKET_PATH or CMUX_TAG points the binary at a running app,
    # and the real home lets it read or write user state.
    with tempfile.TemporaryDirectory() as tmpdir:
        home = os.path.join(tmpdir, "home")
        os.mkdir(home)
        env = {
            key: value
            for key, value in os.environ.items()
            if not key.startswith(("CMUX_", "CMUXD_"))
        }
        env["CMUX_CLI_SENTRY_DISABLED"] = "1"
        env["CMUX_SOCKET_PATH"] = os.path.join(tmpdir, "absent.sock")
        env["HOME"] = home
        env["CFFIXED_USER_HOME"] = home
        proc = subprocess.run(
            [cli, "__dump-command-tree"],
            text=True, capture_output=True, check=False, timeout=30.0, env=env,
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
