#!/usr/bin/env python3
"""
Regression test: `cmux claude-teams` injects the tmux-style auto-mode env.
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


def read_text(path: Path) -> str:
    if not path.exists():
        return ""
    return path.read_text(encoding="utf-8").strip()


def main() -> int:
    try:
        cli_path = resolve_cmux_cli()
    except Exception as exc:
        print(f"FAIL: {exc}")
        return 1

    with tempfile.TemporaryDirectory(prefix="cmux-claude-teams-env-") as td:
        tmp = Path(td)
        real_bin = tmp / "real-bin"
        real_bin.mkdir(parents=True, exist_ok=True)

        env_log = tmp / "agent-teams.log"
        tmux_log = tmp / "tmux-path.log"
        cmux_bin_log = tmp / "cmux-bin.log"
        argv_log = tmp / "argv.log"
        tmux_env_log = tmp / "tmux-env.log"
        tmux_pane_log = tmp / "tmux-pane.log"
        term_log = tmp / "term.log"
        term_program_log = tmp / "term-program.log"
        socket_path_log = tmp / "socket-path.log"
        socket_password_log = tmp / "socket-password.log"
        fake_home = tmp / "home"
        fake_home.mkdir(parents=True, exist_ok=True)

        make_executable(
            real_bin / "claude",
            """#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "${CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS-__UNSET__}" > "$FAKE_AGENT_TEAMS_LOG"
command -v tmux > "$FAKE_TMUX_PATH_LOG"
printf '%s\\n' "${CMUX_CLAUDE_TEAMS_CMUX_BIN-__UNSET__}" > "$FAKE_CMUX_BIN_LOG"
printf '%s\\n' "$@" > "$FAKE_ARGV_LOG"
printf '%s\\n' "${TMUX-__UNSET__}" > "$FAKE_TMUX_ENV_LOG"
printf '%s\\n' "${TMUX_PANE-__UNSET__}" > "$FAKE_TMUX_PANE_LOG"
printf '%s\\n' "${TERM-__UNSET__}" > "$FAKE_TERM_LOG"
printf '%s\\n' "${TERM_PROGRAM-__UNSET__}" > "$FAKE_TERM_PROGRAM_LOG"
printf '%s\\n' "${CMUX_SOCKET_PATH-__UNSET__}" > "$FAKE_SOCKET_PATH_LOG"
printf '%s\\n' "${CMUX_SOCKET_PASSWORD-__UNSET__}" > "$FAKE_SOCKET_PASSWORD_LOG"
""",
        )

        env = os.environ.copy()
        env["HOME"] = str(fake_home)
        env["PATH"] = f"{real_bin}:/usr/bin:/bin"
        env["FAKE_AGENT_TEAMS_LOG"] = str(env_log)
        env["FAKE_TMUX_PATH_LOG"] = str(tmux_log)
        env["FAKE_CMUX_BIN_LOG"] = str(cmux_bin_log)
        env["FAKE_ARGV_LOG"] = str(argv_log)
        env["FAKE_TMUX_ENV_LOG"] = str(tmux_env_log)
        env["FAKE_TMUX_PANE_LOG"] = str(tmux_pane_log)
        env["FAKE_TERM_LOG"] = str(term_log)
        env["FAKE_TERM_PROGRAM_LOG"] = str(term_program_log)
        env["FAKE_SOCKET_PATH_LOG"] = str(socket_path_log)
        env["FAKE_SOCKET_PASSWORD_LOG"] = str(socket_password_log)
        env["TMUX"] = "__HOST_TMUX__"
        env["TMUX_PANE"] = "%999"
        env["TERM"] = "xterm-256color"
        env["TERM_PROGRAM"] = "__HOST_TERM_PROGRAM__"
        explicit_socket_path = str(tmp / "explicit-cmux.sock")
        explicit_socket_password = "topsecret"

        proc = subprocess.run(
            [
                cli_path,
                "--socket",
                explicit_socket_path,
                "--password",
                explicit_socket_password,
                "claude-teams",
                "--version",
            ],
            capture_output=True,
            text=True,
            check=False,
            env=env,
            timeout=30,
        )

        if proc.returncode != 0:
            print("FAIL: `cmux claude-teams --version` exited non-zero")
            print(f"exit={proc.returncode}")
            print(f"stdout={proc.stdout.strip()}")
            print(f"stderr={proc.stderr.strip()}")
            return 1

        agent_teams_value = read_text(env_log)
        if agent_teams_value != "1":
            print(f"FAIL: expected CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1, got {agent_teams_value!r}")
            return 1

        tmux_path = read_text(tmux_log)
        if not tmux_path:
            print("FAIL: fake claude did not observe a tmux binary in PATH")
            return 1

        tmux_name = Path(tmux_path).name
        if tmux_name != "tmux":
            print(f"FAIL: expected tmux shim path to end with 'tmux', got {tmux_path!r}")
            return 1

        if "claude-teams-bin" not in tmux_path:
            print(f"FAIL: expected stable tmux shim path, got {tmux_path!r}")
            return 1

        if tmux_path.startswith(str(real_bin)):
            print(f"FAIL: expected cmux tmux shim to shadow PATH, got {tmux_path!r}")
            return 1

        cmux_bin_value = read_text(cmux_bin_log)
        if not cmux_bin_value or cmux_bin_value == "__UNSET__":
            print("FAIL: missing CMUX_CLAUDE_TEAMS_CMUX_BIN")
            return 1

        if not os.path.exists(cmux_bin_value):
            print(f"FAIL: CMUX_CLAUDE_TEAMS_CMUX_BIN does not exist: {cmux_bin_value!r}")
            return 1

        argv_lines = argv_log.read_text(encoding="utf-8").splitlines()
        if argv_lines[:2] != ["--teammate-mode", "auto"]:
            print(f"FAIL: expected launcher to prepend --teammate-mode auto, got {argv_lines!r}")
            return 1

        if "--version" not in argv_lines:
            print(f"FAIL: expected launcher to preserve user args, got {argv_lines!r}")
            return 1

        tmux_env_value = read_text(tmux_env_log)
        if tmux_env_value in {"", "__UNSET__"}:
            print("FAIL: expected a fake TMUX env value")
            return 1

        tmux_pane_value = read_text(tmux_pane_log)
        if tmux_pane_value in {"", "__UNSET__"} or not tmux_pane_value.startswith("%"):
            print(f"FAIL: expected a fake TMUX_PANE value, got {tmux_pane_value!r}")
            return 1

        term_value = read_text(term_log)
        if term_value != "screen-256color":
            print(f"FAIL: expected TERM=screen-256color, got {term_value!r}")
            return 1

        term_program_value = read_text(term_program_log)
        if term_program_value != "__UNSET__":
            print(f"FAIL: expected TERM_PROGRAM to be unset, got {term_program_value!r}")
            return 1

        socket_path_value = read_text(socket_path_log)
        if socket_path_value != explicit_socket_path:
            print(f"FAIL: expected CMUX_SOCKET_PATH={explicit_socket_path!r}, got {socket_path_value!r}")
            return 1

        socket_password_value = read_text(socket_password_log)
        if socket_password_value != explicit_socket_password:
            print(
                "FAIL: expected CMUX_SOCKET_PASSWORD to preserve the explicit CLI override, "
                f"got {socket_password_value!r}"
            )
            return 1

    print("PASS: cmux claude-teams injects the auto-mode tmux env and shim")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
