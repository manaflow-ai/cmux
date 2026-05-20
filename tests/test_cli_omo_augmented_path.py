#!/usr/bin/env python3
"""
Regression test: cmux omo must use its augmented provider PATH when finding
opencode and the package manager used to install oh-my-openagent.
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

    with tempfile.TemporaryDirectory(prefix="cmux-omo-augmented-path-") as td:
        root = Path(td)
        home_bin = root / ".bun" / "bin"
        home_bin.mkdir(parents=True)

        make_executable(
            home_bin / "opencode",
            """#!/bin/sh
set -eu
printf '%s\\n' "${OPENCODE_CONFIG_DIR-}" > "$HOME/opencode-config-dir.log"
printf '%s\\n' "$PATH" > "$HOME/opencode-path.log"
""",
        )
        make_executable(
            home_bin / "bun",
            """#!/bin/sh
set -eu
printf '%s\\n' "$PATH" > "$HOME/bun-path.log"
package="${4:-oh-my-openagent}"
mkdir -p "node_modules/$package"
""",
        )

        env = os.environ.copy()
        env["HOME"] = str(root)
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        env["CMUX_CLI_SENTRY_DISABLED"] = "1"
        env["CMUX_SOCKET_PATH"] = str(root / "missing.sock")

        run = subprocess.run(
            [cli_path, "omo", "--model", "test"],
            capture_output=True,
            text=True,
            check=False,
            env=env,
            timeout=20,
        )

        if run.returncode != 0:
            print("FAIL: cmux omo did not launch through augmented provider PATH")
            print(f"exit={run.returncode}")
            print(f"stdout={run.stdout.strip()}")
            print(f"stderr={run.stderr.strip()}")
            return 1

        expected_config_dir = str(root / ".cmuxterm" / "omo-config")
        config_log = root / "opencode-config-dir.log"
        if config_log.read_text(encoding="utf-8").strip() != expected_config_dir:
            print("FAIL: fake opencode did not receive OPENCODE_CONFIG_DIR")
            return 1

        expected_bin = str(home_bin)
        bun_path = root / "bun-path.log"
        opencode_path = root / "opencode-path.log"
        if expected_bin not in bun_path.read_text(encoding="utf-8").split(":"):
            print("FAIL: fake bun did not receive augmented PATH")
            return 1
        if expected_bin not in opencode_path.read_text(encoding="utf-8").split(":"):
            print("FAIL: fake opencode did not receive augmented PATH")
            return 1

    print("PASS: cmux omo uses augmented provider PATH")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
