#!/usr/bin/env python3
"""Regression test for nested Codex Teams help/version passthrough."""

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
    except RuntimeError as error:
        print(f"SKIP: {error}")
        return 0

    with tempfile.TemporaryDirectory(prefix="cmux-codex-teams-info-") as td:
        root = Path(td)
        fake_bin = root / "bin"
        fake_bin.mkdir()
        codex_log = root / "codex.log"
        make_executable(
            fake_bin / "codex",
            """#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" > "$FAKE_CODEX_LOG"
""",
        )

        env = os.environ.copy()
        env["HOME"] = str(root)
        env["PATH"] = f"{fake_bin}:/usr/bin:/bin"
        env["CMUX_CLI_SENTRY_DISABLED"] = "1"
        env["CMUX_SOCKET_PATH"] = str(root / "missing.sock")
        env["FAKE_CODEX_LOG"] = str(codex_log)

        for invocation in (
            ("help",),
            ("help", "resume"),
            ("resume", "--help"),
            ("resume", "session-id", "--version"),
            ("exec", "review", "--help"),
        ):
            codex_log.unlink(missing_ok=True)
            result = subprocess.run(
                [cli_path, "codex-teams", *invocation],
                capture_output=True,
                text=True,
                check=False,
                env=env,
                timeout=30,
            )
            if result.returncode != 0 or not codex_log.exists():
                print(f"FAIL: nested Codex informational invocation {invocation!r} required a live surface")
                print(f"stderr={result.stderr.strip()}")
                return 1
            if codex_log.read_text(encoding="utf-8").strip() != " ".join(invocation):
                print(f"FAIL: nested Codex informational invocation {invocation!r} was not passed through")
                return 1

        codex_log.unlink(missing_ok=True)
        launch = subprocess.run(
            [cli_path, "codex-teams", "resume", "--", "--help"],
            capture_output=True,
            text=True,
            check=False,
            env=env,
            timeout=30,
        )
        if launch.returncode == 0 or codex_log.exists():
            print("FAIL: Codex help after -- bypassed managed launch context")
            return 1

    print("PASS: nested Codex Teams help/version bypasses launch context without crossing --")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
