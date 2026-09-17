#!/usr/bin/env python3
"""
Regression test: `cmux omc` preserves fallback provider dirs in PATH.
"""

from __future__ import annotations

import os
import subprocess
import tempfile
from pathlib import Path

from claude_teams_test_utils import focused_cmux_server, resolve_cmux_cli


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
        omc_log = root / "omc.log"

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
printf 'ran\\n' > "$FAKE_OMC_LOG"
command -v omc-node-helper
omc-node-helper "$@"
""",
        )

        env = os.environ.copy()
        env["HOME"] = str(root)
        env["PATH"] = "/usr/bin:/bin"
        env["CMUX_CLI_SENTRY_DISABLED"] = "1"
        env["CMUX_SOCKET_PATH"] = str(root / "missing.sock")
        env["FAKE_OMC_LOG"] = str(omc_log)

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

        for invocation in (
            ("ask", "review", "this"),
            ("capabilities", "check"),
            ("config",),
            ("config-notify-profile", "work", "--show"),
            ("config-stop-callback", "telegram", "--show"),
            ("doctor", "conflicts"),
            ("help",),
            ("info",),
            ("install",),
            ("postinstall",),
            ("session", "search", "provider-routing"),
            ("setup",),
            ("teleport", "list"),
            ("test-prompt", "ultrawork fix bugs"),
            ("team", "api", "claim-task", "--input", "{}", "--json"),
            ("team", "shutdown", "demo"),
            ("team", "status", "demo"),
            ("team", "--help"),
            ("team", "-h"),
            ("update",),
            ("update-reconcile",),
            ("version",),
        ):
            omc_log.unlink(missing_ok=True)
            informational = subprocess.run(
                [cli_path, "omc", *invocation],
                capture_output=True,
                text=True,
                check=False,
                env=env,
                timeout=30,
            )
            if informational.returncode != 0 or not omc_log.exists():
                print(f"FAIL: positional non-launch command {invocation!r} required a live surface")
                print(f"stderr={informational.stderr.strip()}")
                return 1
            expected_args = " ".join(invocation)
            if informational.stdout.strip().splitlines()[-1] != f"args:{expected_args}":
                print(f"FAIL: positional command {invocation!r} was not passed through")
                return 1

        omc_log.unlink(missing_ok=True)
        for invocation in (
            ("start a team",),
            ("team",),
            ("team", "resume"),
            ("team", "1:codex", "review this"),
        ):
            omc_log.unlink(missing_ok=True)
            real_launch = subprocess.run(
                [cli_path, "omc", *invocation],
                capture_output=True,
                text=True,
                check=False,
                env=env,
                timeout=30,
            )
            if real_launch.returncode == 0 or omc_log.exists():
                print(f"FAIL: real OMC launch {invocation!r} continued without a live cmux surface context")
                return 1
        with focused_cmux_server(root / "focused-cmux.sock") as (socket_path, requests):
            focused_env = env.copy()
            focused_env["CMUX_SOCKET_PATH"] = socket_path
            for key in (
                "CMUX_WORKSPACE_ID",
                "CMUX_SURFACE_ID",
                "CMUX_PANEL_ID",
                "CMUX_TAB_ID",
                "CMUX_PANE_ID",
            ):
                focused_env.pop(key, None)
            focused = subprocess.run(
                [cli_path, "omc", "start a team"],
                capture_output=True,
                text=True,
                check=False,
                env=focused_env,
                timeout=30,
            )
        if focused.returncode == 0 or omc_log.exists():
            print("FAIL: contextless OMC launch borrowed the globally focused cmux surface")
            return 1
        if "system.identify" in requests:
            print(f"FAIL: contextless OMC launch consulted mutable focus: {requests!r}")
            return 1

    print("PASS: OMC preserves informational fallback and fails closed for real launches")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
