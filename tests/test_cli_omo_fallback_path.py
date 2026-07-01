#!/usr/bin/env python3
"""
Regression test: `cmux omo` preserves fallback OpenCode dirs in PATH.
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

    with tempfile.TemporaryDirectory(prefix="cmux-omo-fallback-path-") as td:
        root = Path(td)
        fallback_bin = root / ".bun" / "bin"
        fallback_bin.mkdir(parents=True, exist_ok=True)

        user_config_dir = root / ".config" / "opencode"
        plugin_dir = user_config_dir / "node_modules" / "oh-my-openagent"
        plugin_dir.mkdir(parents=True)

        make_executable(
            fallback_bin / "opencode-node-helper",
            """#!/usr/bin/env bash
set -euo pipefail
printf 'helper:%s\\n' "$0"
printf 'args:%s\\n' "$*"
""",
        )
        make_executable(
            fallback_bin / "opencode",
            """#!/usr/bin/env bash
set -euo pipefail
command -v opencode-node-helper
exec opencode-node-helper "$@"
""",
        )

        env = os.environ.copy()
        env["HOME"] = str(root)
        env["PATH"] = "/usr/bin:/bin"
        env["CMUX_CLI_SENTRY_DISABLED"] = "1"
        env["CMUX_SOCKET_PATH"] = str(root / "missing.sock")

        proc = subprocess.run(
            [cli_path, "omo", "--version", "--port", "19777"],
            capture_output=True,
            text=True,
            check=False,
            env=env,
            timeout=30,
        )

        if proc.returncode != 0:
            print("FAIL: `cmux omo` failed with OpenCode in a fallback dir")
            print(f"exit={proc.returncode}")
            print(f"stdout={proc.stdout.strip()}")
            print(f"stderr={proc.stderr.strip()}")
            return 1

        lines = proc.stdout.strip().splitlines()
        expected_helper = str(fallback_bin / "opencode-node-helper")
        expected = [
            expected_helper,
            f"helper:{expected_helper}",
            "args:--version --port 19777",
        ]
        if lines != expected:
            print(f"FAIL: expected fallback helper to remain on PATH, got {lines!r}")
            return 1

    with tempfile.TemporaryDirectory(prefix="cmux-omo-fallback-install-path-") as td:
        root = Path(td)
        fallback_bin = root / ".bun" / "bin"
        fallback_bin.mkdir(parents=True, exist_ok=True)

        make_executable(
            fallback_bin / "opencode-node-helper",
            """#!/usr/bin/env bash
set -euo pipefail
printf 'helper:%s\\n' "$0"
printf 'args:%s\\n' "$*"
""",
        )
        make_executable(
            fallback_bin / "opencode",
            """#!/usr/bin/env bash
set -euo pipefail
command -v opencode-node-helper
exec opencode-node-helper "$@"
""",
        )
        make_executable(
            fallback_bin / "bun",
            """#!/usr/bin/env bash
set -euo pipefail
command -v opencode-node-helper >&2
mkdir -p "$PWD/node_modules/oh-my-openagent"
""",
        )

        env = os.environ.copy()
        env["HOME"] = str(root)
        env["PATH"] = "/usr/bin:/bin"
        env["CMUX_CLI_SENTRY_DISABLED"] = "1"
        env["CMUX_SOCKET_PATH"] = str(root / "missing.sock")

        proc = subprocess.run(
            [cli_path, "omo", "--version", "--port", "19778"],
            capture_output=True,
            text=True,
            check=False,
            env=env,
            timeout=30,
        )

        if proc.returncode != 0:
            print("FAIL: `cmux omo` failed to install OMO with bun in a fallback dir")
            print(f"exit={proc.returncode}")
            print(f"stdout={proc.stdout.strip()}")
            print(f"stderr={proc.stderr.strip()}")
            return 1

        lines = proc.stdout.strip().splitlines()
        expected_helper = str(fallback_bin / "opencode-node-helper")
        expected = [
            expected_helper,
            f"helper:{expected_helper}",
            "args:--version --port 19778",
        ]
        if lines != expected:
            print(f"FAIL: expected fallback install PATH to reach helper, got {lines!r}")
            return 1

    with tempfile.TemporaryDirectory(prefix="cmux-omo-skip-app-bundle-path-") as td:
        root = Path(td)
        fallback_bin = root / ".bun" / "bin"
        stale_app_bin = root / "Older cmux.app" / "Contents" / "Resources" / "bin"
        fallback_bin.mkdir(parents=True, exist_ok=True)
        stale_app_bin.mkdir(parents=True, exist_ok=True)
        user_config_dir = root / ".config" / "opencode"
        plugin_dir = user_config_dir / "node_modules" / "oh-my-openagent"
        plugin_dir.mkdir(parents=True, exist_ok=True)

        make_executable(
            stale_app_bin / "opencode",
            """#!/usr/bin/env bash
set -euo pipefail
printf 'FAIL: stale bundled opencode was executed\\n' >&2
exit 42
""",
        )
        make_executable(
            fallback_bin / "opencode-node-helper",
            """#!/usr/bin/env bash
set -euo pipefail
printf 'helper:%s\\n' "$0"
printf 'args:%s\\n' "$*"
""",
        )
        make_executable(
            fallback_bin / "opencode",
            """#!/usr/bin/env bash
set -euo pipefail
command -v opencode-node-helper
exec opencode-node-helper "$@"
""",
        )

        env = os.environ.copy()
        env["HOME"] = str(root)
        env["PATH"] = f"{stale_app_bin}:/usr/bin:/bin"
        env["CMUX_CLI_SENTRY_DISABLED"] = "1"
        env["CMUX_SOCKET_PATH"] = str(root / "missing.sock")

        proc = subprocess.run(
            [cli_path, "omo", "--version", "--port", "19779"],
            capture_output=True,
            text=True,
            check=False,
            env=env,
            timeout=30,
        )

        if proc.returncode != 0:
            print("FAIL: `cmux omo` failed when stale app-bundled OpenCode was first on PATH")
            print(f"exit={proc.returncode}")
            print(f"stdout={proc.stdout.strip()}")
            print(f"stderr={proc.stderr.strip()}")
            return 1

        lines = proc.stdout.strip().splitlines()
        expected_helper = str(fallback_bin / "opencode-node-helper")
        expected = [
            expected_helper,
            f"helper:{expected_helper}",
            "args:--version --port 19779",
        ]
        if lines != expected:
            print(f"FAIL: expected app-bundled OpenCode to be skipped, got {lines!r}")
            return 1

    print("PASS: cmux omo preserves fallback OpenCode dirs in PATH")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
