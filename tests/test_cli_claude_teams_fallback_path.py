#!/usr/bin/env python3
"""
Regression test: `cmux claude-teams` preserves fallback provider dirs in PATH.
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

    with tempfile.TemporaryDirectory(prefix="cmux-claude-teams-fallback-path-") as td:
        tmp = Path(td)
        home = tmp / "home"
        fallback_bin = home / ".bun" / "bin"
        managed_bin = tmp / "cmux-cli-shims" / "surface-1"
        fallback_bin.mkdir(parents=True, exist_ok=True)
        managed_bin.mkdir(parents=True, exist_ok=True)

        make_executable(
            managed_bin / "claude",
            "#!/usr/bin/env bash\necho managed-claude-shim-must-not-run >&2\nexit 42\n",
        )

        claude_log = tmp / "claude.log"
        codex_log = tmp / "codex.log"

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
printf 'ran\n' > "$FAKE_CLAUDE_LOG"
command -v claude-node-helper
claude-node-helper
""",
        )
        make_executable(
            fallback_bin / "codex",
            """#!/usr/bin/env bash
set -euo pipefail
printf 'ran\n' > "$FAKE_CODEX_LOG"
exit 86
""",
        )

        env = os.environ.copy()
        env["HOME"] = str(home)
        env["PATH"] = "/usr/bin:/bin"
        env["TMPDIR"] = str(tmp)
        env["CMUX_CLAUDE_WRAPPER_SHIM"] = str(managed_bin / "claude")
        env["CMUX_CLAUDE_WRAPPER_SHIM_ROOT"] = str(managed_bin)
        env["FAKE_CLAUDE_LOG"] = str(claude_log)
        env["FAKE_CODEX_LOG"] = str(codex_log)
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

        claude_log.unlink()
        unmanaged_env = env.copy()
        unmanaged_env.pop("CMUX_CLAUDE_WRAPPER_SHIM", None)
        unmanaged_env.pop("CMUX_CLAUDE_WRAPPER_SHIM_ROOT", None)

        informational = subprocess.run(
            [cli_path, "claude-teams", "--version"],
            capture_output=True,
            text=True,
            check=False,
            env=unmanaged_env,
            timeout=30,
        )
        if informational.returncode != 0 or not claude_log.exists():
            print("FAIL: unmanaged informational invocation should retain compatibility fallback")
            return 1
        claude_log.unlink()

        for real_args in (["start a team"], ["--tmux", "explain --version"]):
            unmanaged = subprocess.run(
                [cli_path, "claude-teams", *real_args],
                capture_output=True,
                text=True,
                check=False,
                env=unmanaged_env,
                timeout=30,
            )
            if unmanaged.returncode == 0:
                print(f"FAIL: unmanaged real launch succeeded for args {real_args!r}")
                return 1
            if claude_log.exists():
                print(f"FAIL: unmanaged real launch reached Claude for args {real_args!r}")
                return 1
            if not unmanaged.stderr.strip():
                print(f"FAIL: unmanaged launch lacked actionable guidance for args {real_args!r}")
                return 1

        contextless = subprocess.run(
            [cli_path, "claude-teams", "start a team"],
            capture_output=True,
            text=True,
            check=False,
            env=env,
            timeout=30,
        )
        if contextless.returncode == 0 or claude_log.exists():
            print("FAIL: real Teams launch accepted a managed root without a live surface context")
            return 1

        with focused_cmux_server(tmp / "focused-cmux.sock") as (socket_path, requests):
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
                [cli_path, "claude-teams", "start a team"],
                capture_output=True,
                text=True,
                check=False,
                env=focused_env,
                timeout=30,
            )
            focused_codex = subprocess.run(
                [cli_path, "codex-teams", "start a team"],
                capture_output=True,
                text=True,
                check=False,
                env=focused_env,
                timeout=30,
            )
        if focused.returncode == 0 or claude_log.exists():
            print("FAIL: contextless Teams launch borrowed the globally focused cmux surface")
            return 1
        if focused_codex.returncode == 0 or codex_log.exists():
            print("FAIL: contextless Codex Teams launch borrowed the globally focused cmux surface")
            return 1
        if "system.identify" in requests:
            print(f"FAIL: contextless Teams launch consulted mutable focus: {requests!r}")
            return 1

        managed_tmux = managed_bin / "tmux"
        managed_tmux.unlink()
        forged_env = env.copy()
        forged_tmp = tmp / "different-temp-root"
        forged_tmp.mkdir()
        forged_env["TMPDIR"] = str(forged_tmp)
        forged = subprocess.run(
            [cli_path, "claude-teams", "start a team"],
            capture_output=True,
            text=True,
            check=False,
            env=forged_env,
            timeout=30,
        )
        if forged.returncode == 0 or claude_log.exists() or managed_tmux.exists():
            print("FAIL: forged managed-root environment was accepted outside the trusted temp base")
            return 1

    print("PASS: provider fallback survives while real Teams launches require managed routing")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
