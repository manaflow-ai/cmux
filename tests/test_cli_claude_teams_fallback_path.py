#!/usr/bin/env python3
"""
Regression test: `cmux claude-teams` preserves fallback provider dirs in PATH.
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

    with tempfile.TemporaryDirectory(prefix="cmux-claude-teams-fallback-path-") as td:
        tmp = Path(td)
        home = tmp / "home"
        fallback_bin = home / ".bun" / "bin"
        fallback_bin.mkdir(parents=True, exist_ok=True)

        make_executable(
            fallback_bin / "claude-node-helper",
            """#!/usr/bin/env bash
set -euo pipefail
printf 'helper:%s\\n' "$0"
""",
        )
        make_executable(
            fallback_bin / "claude",
            """#!/usr/bin/env bash
set -euo pipefail
command -v claude-node-helper
claude-node-helper
""",
        )

        env = os.environ.copy()
        env["HOME"] = str(home)
        env["PATH"] = "/usr/bin:/bin"
        env.pop("CMUX_CUSTOM_CLAUDE_PATH", None)

        proc = subprocess.run(
            [cli_path, "claude-teams", "--version"],
            capture_output=True,
            text=True,
            check=False,
            env=env,
            timeout=30,
        )

        if proc.returncode != 0:
            print("FAIL: `cmux claude-teams --version` failed with Claude in a fallback dir")
            print(f"exit={proc.returncode}")
            print(f"stdout={proc.stdout.strip()}")
            print(f"stderr={proc.stderr.strip()}")
            return 1

        lines = proc.stdout.strip().splitlines()
        expected_helper = str(fallback_bin / "claude-node-helper")
        if lines != [expected_helper, f"helper:{expected_helper}"]:
            print(f"FAIL: expected fallback helper to remain on PATH, got {lines!r}")
            return 1

    print("PASS: cmux claude-teams preserves fallback provider dirs in PATH")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
