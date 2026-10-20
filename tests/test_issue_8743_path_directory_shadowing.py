#!/usr/bin/env python3
"""
Regression test for https://github.com/manaflow-ai/cmux/issues/8743.

`FileManager.isExecutableFile(atPath:)` returns true for directories on macOS, so a
directory named like a provider binary earlier on PATH used to shadow the real
executable and make the launch fail at execv. The PATH walk must skip directories
and keep looking.
"""

from __future__ import annotations

import os
import subprocess
import tempfile
from pathlib import Path

from claude_teams_test_utils import resolve_cmux_cli

# cmux subcommand -> executable name its PATH walk looks for.
PROVIDERS = (("omx", "omx"), ("omc", "omc"))


def make_executable(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(0o755)


def check_provider(cli_path: str, command: str, executable: str) -> int:
    with tempfile.TemporaryDirectory(prefix=f"cmux-{command}-shadow-") as td:
        root = Path(td)

        # A directory named exactly like the provider binary, earlier on PATH.
        shadow_dir = root / "shadow"
        (shadow_dir / executable).mkdir(parents=True, exist_ok=True)
        (shadow_dir / executable).chmod(0o755)

        real_bin = root / "real"
        real_bin.mkdir(parents=True, exist_ok=True)
        make_executable(
            real_bin / executable,
            f"""#!/usr/bin/env bash
set -euo pipefail
printf 'real-{executable}:%s\\n' "$0"
""",
        )

        env = os.environ.copy()
        env["HOME"] = str(root)
        env["PATH"] = f"{shadow_dir}:{real_bin}:/usr/bin:/bin"
        env["CMUX_CLI_SENTRY_DISABLED"] = "1"
        env["CMUX_SOCKET_PATH"] = str(root / "missing.sock")

        proc = subprocess.run(
            [cli_path, command, "--version"],
            capture_output=True,
            text=True,
            check=False,
            env=env,
            timeout=30,
        )

        expected = f"real-{executable}:{real_bin / executable}"
        if proc.returncode != 0 or expected not in proc.stdout:
            print(f"FAIL: `cmux {command} --version` did not run the real executable")
            print(f"exit={proc.returncode}")
            print(f"stdout={proc.stdout.strip()}")
            print(f"stderr={proc.stderr.strip()}")
            return 1

        if str(shadow_dir / executable) in proc.stdout or str(shadow_dir / executable) in proc.stderr:
            print(f"FAIL: `cmux {command}` selected the shadowing directory")
            return 1

    return 0


def main() -> int:
    try:
        cli_path = resolve_cmux_cli()
    except Exception as exc:
        print(f"FAIL: {exc}")
        return 1

    failures = sum(
        check_provider(cli_path, command, executable) for command, executable in PROVIDERS
    )
    if failures:
        return 1

    print("PASS: PATH resolution skips directories named like provider binaries")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
