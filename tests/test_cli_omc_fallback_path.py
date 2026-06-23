#!/usr/bin/env python3
"""
Regression test: `cmux omc` preserves fallback provider dirs in PATH.
"""

from __future__ import annotations

import os
import subprocess
import tempfile
from pathlib import Path

from claude_teams_test_utils import resolve_cmux_cli


def make_executable(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(0o755)


def main() -> int:
    try:
        cli_path = resolve_cmux_cli()
    except Exception as exc:
        print(f"FAIL: {exc}")
        return 1

    with tempfile.TemporaryDirectory(prefix="cmux-omc-fallback-path-") as td:
        root = Path(td)
        fallback_bin = root / ".bun" / "bin"
        fallback_bin.mkdir(parents=True, exist_ok=True)

        make_executable(
            fallback_bin / "omc-node-helper",
            """#!/usr/bin/env bash
set -euo pipefail
printf 'helper:%s\\n' "$0"
printf 'args:%s\\n' "$*"
""",
        )
        make_executable(
            fallback_bin / "omc",
            """#!/usr/bin/env bash
set -euo pipefail
command -v omc-node-helper
omc-node-helper "$@"
""",
        )

        env = os.environ.copy()
        env["HOME"] = str(root)
        env["PATH"] = "/usr/bin:/bin"
        env["CMUX_CLI_SENTRY_DISABLED"] = "1"
        env["CMUX_SOCKET_PATH"] = str(root / "missing.sock")

        proc = subprocess.run(
            [cli_path, "omc", "--version"],
            capture_output=True,
            text=True,
            check=False,
            env=env,
            timeout=30,
        )

        if proc.returncode != 0:
            print("FAIL: `cmux omc --version` failed with omc in a fallback dir")
            print(f"exit={proc.returncode}")
            print(f"stdout={proc.stdout.strip()}")
            print(f"stderr={proc.stderr.strip()}")
            return 1

        lines = proc.stdout.strip().splitlines()
        expected_helper = str(fallback_bin / "omc-node-helper")
        expected = [
            expected_helper,
            f"helper:{expected_helper}",
            "args:--version",
        ]
        if lines != expected:
            print(f"FAIL: expected fallback helper to remain on PATH, got {lines!r}")
            return 1

    print("PASS: cmux omc preserves fallback provider dirs in PATH")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
