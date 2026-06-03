#!/usr/bin/env python3
"""
Regression coverage for stale shell-side git branch payloads after cwd changes.

The shell integrations must not let an async reporter for an old repository path
repopulate the sidebar branch after the shell has moved to a non-git directory.
"""

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


def _shell_command(kind: str) -> str:
    if kind == "zsh":
        return textwrap.dedent(
            """\
            source "$CMUX_TEST_SCRIPT"
            precmd_functions=()
            preexec_functions=()
            _cmux_send() { print -r -- "$1" >> "$CMUX_TEST_SEND_LOG"; }
            cd "$CMUX_TEST_REPO"
            _cmux_start_git_head_watch
            cd "$CMUX_TEST_NONREPO"
            printf '%s\\n' 'ref: refs/heads/new-old-branch' > "$CMUX_TEST_REPO/.git/HEAD"
            sleep 2
            _cmux_stop_git_head_watch
            _cmux_report_git_branch_for_path "$PWD"
            """
        )

    if kind == "bash":
        return textwrap.dedent(
            """\
            source "$CMUX_TEST_SCRIPT"
            _cmux_send() { printf '%s\\n' "$1" >> "$CMUX_TEST_SEND_LOG"; }
            _cmux_send_bg() { _cmux_send "$1"; }
            cd "$CMUX_TEST_REPO"
            cd "$CMUX_TEST_NONREPO"
            _CMUX_TTY_REPORTED=1
            _CMUX_PORTS_LAST_RUN=$(_cmux_now)
            _CMUX_PWD_LAST_PWD="$PWD"
            _cmux_prompt_command
            _cmux_report_git_branch_for_path "$CMUX_TEST_REPO"
            _cmux_report_git_branch_for_path "$PWD"
            sleep 1
            """
        )

    raise ValueError(f"Unsupported shell kind: {kind}")


def _read_lines(path: Path) -> list[str]:
    if not path.exists():
        return []
    return [line.strip() for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def _run_case(
    base: Path,
    *,
    shell: str,
    shell_args: list[str],
    script: Path,
) -> tuple[int, str]:
    repo = base / shell / "repo"
    nonrepo = base / shell / "nonrepo"
    socket_path = base / shell / "cmux.sock"
    send_log = base / shell / "send.log"
    head_file = repo / ".git" / "HEAD"

    head_file.parent.mkdir(parents=True, exist_ok=True)
    nonrepo.mkdir(parents=True, exist_ok=True)
    head_file.write_text("ref: refs/heads/old-branch\n", encoding="utf-8")

    env = dict(os.environ)
    env["CMUX_SOCKET_PATH"] = str(socket_path)
    env["CMUX_TAB_ID"] = "00000000-0000-0000-0000-000000000001"
    env["CMUX_PANEL_ID"] = "00000000-0000-0000-0000-000000000002"
    env["CMUX_TEST_SCRIPT"] = str(script)
    env["CMUX_TEST_REPO"] = str(repo)
    env["CMUX_TEST_NONREPO"] = str(nonrepo)
    env["CMUX_TEST_SEND_LOG"] = str(send_log)

    with BoundUnixSocket(socket_path):
        result = subprocess.run(
            [shell, *shell_args, _shell_command(shell)],
            env=env,
            capture_output=True,
            text=True,
            timeout=12,
        )

    output = (result.stdout or "") + (result.stderr or "")
    if result.returncode != 0:
        return result.returncode, f"{shell}: shell failed\n{output}"

    lines = _read_lines(send_log)
    stale_reports = [line for line in lines if line.startswith("report_git_branch ")]
    clear_reports = [line for line in lines if line.startswith("clear_git_branch ")]
    if stale_reports:
        return 1, f"{shell}: stale branch report was emitted after cwd left repo: {lines}"
    if not clear_reports:
        return 1, f"{shell}: expected non-git cwd to emit clear_git_branch: {lines}"
    return 0, f"{shell}: ok"


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    cases = [
        ("zsh", ["-f", "-c"], root / "Resources/shell-integration/cmux-zsh-integration.zsh"),
        ("bash", ["--noprofile", "--norc", "-c"], root / "Resources/shell-integration/cmux-bash-integration.bash"),
    ]

    base = Path("/tmp") / f"cmux_shell_git_branch_stale_cwd_{os.getpid()}"
    try:
        shutil.rmtree(base, ignore_errors=True)
        base.mkdir(parents=True, exist_ok=True)

        failures: list[str] = []
        for shell, shell_args, script in cases:
            if not script.exists():
                print(f"SKIP: missing integration script at {script}")
                continue
            rc, detail = _run_case(base, shell=shell, shell_args=shell_args, script=script)
            if rc != 0:
                failures.append(detail)

        if failures:
            print("FAIL:")
            for failure in failures:
                print(failure)
            return 1

        print("PASS: shell git branch reports are scoped to the current cwd")
        return 0
    finally:
        shutil.rmtree(base, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
