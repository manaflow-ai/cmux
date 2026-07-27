#!/usr/bin/env python3
"""Regression test for https://github.com/manaflow-ai/cmux/issues/7035.

`cmux claude-teams` must honor a Claude Binary Path configured as a launch
*command* (a /bin/sh snippet forwarding the arguments via "$@") — e.g. a
`claude` that only exists as a shell function — instead of failing with
"Claude Code was not found" when no claude binary is on PATH.
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

    with tempfile.TemporaryDirectory(prefix="cmux-claude-teams-custom-command-") as td:
        tmp = Path(td)
        home = tmp / "home"
        home.mkdir(parents=True, exist_ok=True)
        log = tmp / "argv.log"
        logger = tmp / "log-args.sh"
        make_executable(
            logger,
            f"""#!/bin/sh
printf '%s\\n' "custom-claude $*" > "{log}"
""",
        )

        env = os.environ.copy()
        env["HOME"] = str(home)
        # No claude binary anywhere: the launch command is the only way in.
        env["PATH"] = "/usr/bin:/bin"
        env["CMUX_CUSTOM_CLAUDE_PATH"] = f'"{logger}" "$@"'
        env.pop("CMUX_CLAUDE_CUSTOM_COMMAND_ACTIVE", None)

        proc = subprocess.run(
            [cli_path, "claude-teams", "--version"],
            capture_output=True,
            text=True,
            check=False,
            env=env,
            timeout=30,
        )

        if proc.returncode != 0:
            print("FAIL: `cmux claude-teams --version` failed with a custom launch command")
            print(f"exit={proc.returncode}")
            print(f"stdout={proc.stdout.strip()}")
            print(f"stderr={proc.stderr.strip()}")
            return 1

        if not log.exists():
            print("FAIL: the configured launch command never ran")
            print(f"stdout={proc.stdout.strip()}")
            print(f"stderr={proc.stderr.strip()}")
            return 1

        recorded = log.read_text(encoding="utf-8").strip()
        if "--version" not in recorded:
            print(f"FAIL: launch command lost the claude-teams arguments: {recorded!r}")
            return 1

    print("PASS: cmux claude-teams honors a custom claude launch command (issue #7035)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
