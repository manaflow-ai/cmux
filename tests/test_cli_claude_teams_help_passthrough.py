#!/usr/bin/env python3
"""
Regression test: `cmux claude-teams --help` passes through to Claude.
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

    with tempfile.TemporaryDirectory(prefix="cmux-claude-teams-help-") as td:
        tmp = Path(td)
        home = tmp / "home"
        real_bin = tmp / "real-bin"
        home.mkdir(parents=True, exist_ok=True)
        real_bin.mkdir(parents=True, exist_ok=True)

        argv_log = tmp / "argv.log"

        make_executable(
            real_bin / "claude",
            """#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$@" > "$FAKE_ARGV_LOG"
""",
        )

        env = os.environ.copy()
        env["HOME"] = str(home)
        env["PATH"] = f"{real_bin}:/usr/bin:/bin"
        env["FAKE_ARGV_LOG"] = str(argv_log)

        proc = subprocess.run(
            [cli_path, "claude-teams", "--help"],
            capture_output=True,
            text=True,
            check=False,
            env=env,
            timeout=30,
        )

        if proc.returncode != 0:
            print("FAIL: `cmux claude-teams --help` exited non-zero")
            print(f"exit={proc.returncode}")
            print(f"stdout={proc.stdout.strip()}")
            print(f"stderr={proc.stderr.strip()}")
            return 1

        if not argv_log.exists():
            print("FAIL: launcher intercepted --help instead of invoking Claude")
            print(f"stdout={proc.stdout.strip()}")
            print(f"stderr={proc.stderr.strip()}")
            return 1

        argv_lines = argv_log.read_text(encoding="utf-8").splitlines()
        if argv_lines[:2] != ["--teammate-mode", "auto"]:
            print(f"FAIL: expected launcher to prepend --teammate-mode auto, got {argv_lines!r}")
            return 1

        if "--help" not in argv_lines:
            print(f"FAIL: expected --help to reach Claude, got {argv_lines!r}")
            return 1

    print("PASS: cmux claude-teams forwards --help to Claude")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
