#!/usr/bin/env python3
"""Shell integrations clear stale PR state once when git watching is disabled."""

from __future__ import annotations

import os
import shutil
import socket
import subprocess
import textwrap
from pathlib import Path


class BoundUnixSocket:
    def __init__(self, path: Path) -> None:
        self.path = path
        self.sock: socket.socket | None = None

    def __enter__(self) -> "BoundUnixSocket":
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.bind(str(self.path))
        self.sock.listen(1)
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        if self.sock is not None:
            self.sock.close()
        try:
            self.path.unlink()
        except FileNotFoundError:
            pass


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    shell_dir = root / "Resources" / "shell-integration"
    base = Path("/tmp") / f"cmux_disabled_git_watch_{os.getpid()}"
    socket_path = base / "cmux.sock"
    expected = (
        "clear_pr --tab=00000000-0000-0000-0000-000000000001 "
        "--panel=00000000-0000-0000-0000-000000000002"
    )

    cases = [
        (
            "bash",
            ["bash", "--noprofile", "--norc", "-c"],
            shell_dir / "cmux-bash-integration.bash",
            "_cmux_prompt_command",
        ),
        (
            "zsh",
            ["zsh", "-f", "-c"],
            shell_dir / "cmux-zsh-integration.zsh",
            "_cmux_precmd",
        ),
    ]

    try:
        shutil.rmtree(base, ignore_errors=True)
        base.mkdir(parents=True)

        ran = []
        for name, shell_command, script, prompt_function in cases:
            if shutil.which(shell_command[0]) is None:
                if name == "bash":
                    print("FAIL: bash is required for disabled git-watch coverage")
                    return 1
                print(f"SKIP: {name} coverage requires {shell_command[0]}")
                continue

            send_log = base / f"{name}-send.log"
            hint_file = base / f"{name}-pr-action-hint"
            hint_file.write_text("merge\t123\n", encoding="utf-8")

            command = textwrap.dedent(
                f"""\
                source "$CMUX_TEST_SCRIPT"
                _cmux_send_bg() {{ printf '%s\\n' "$1" >> "$CMUX_TEST_SEND_LOG"; }}
                {prompt_function}
                {prompt_function}
                """
            )
            env = dict(os.environ)
            env["CMUX_TEST_SCRIPT"] = str(script)
            env["CMUX_TEST_SEND_LOG"] = str(send_log)
            env["CMUX_SOCKET_PATH"] = str(socket_path)
            env["CMUX_TAB_ID"] = "00000000-0000-0000-0000-000000000001"
            env["CMUX_PANEL_ID"] = "00000000-0000-0000-0000-000000000002"
            env["CMUX_NO_GIT_WATCH"] = "1"
            env["_CMUX_PR_ACTION_HINT_FILE"] = str(hint_file)

            with BoundUnixSocket(socket_path):
                result = subprocess.run(
                    shell_command + [command],
                    env=env,
                    capture_output=True,
                    text=True,
                    timeout=8,
                )

            if result.returncode != 0:
                print(f"FAIL: {name} prompt command failed")
                print(result.stdout)
                print(result.stderr)
                return 1

            send_lines = send_log.read_text(encoding="utf-8").splitlines() if send_log.exists() else []
            clear_count = sum(1 for line in send_lines if line == expected)
            if clear_count == 0:
                print(f"FAIL: {name} disabled git-watch path did not clear the panel PR badge")
                print("\n".join(send_lines))
                return 1
            if clear_count != 1:
                print(f"FAIL: {name} disabled git-watch path sent repeated clear_pr commands")
                print("\n".join(send_lines))
                return 1

            if hint_file.exists():
                print(f"FAIL: {name} disabled git-watch path did not remove the PR command hint file")
                return 1
            ran.append(name)

        print(f"PASS: shell disabled git-watch paths clear stale PR state once ({', '.join(ran)})")
        return 0
    finally:
        shutil.rmtree(base, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
