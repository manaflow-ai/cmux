#!/usr/bin/env python3
"""
Regression: bash shell integration background helpers must not leak job
completion notices into the user's terminal output.
"""

from __future__ import annotations

import os
import re
import select
import shutil
import signal
import socket
import stat
import subprocess
import tempfile
import time
from contextlib import suppress
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SHELL_DIR = ROOT / "Resources" / "shell-integration"
ANSI_ESCAPE_RE = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
DONE_LINE_RE = re.compile(r"^\[[0-9]+\](?:[+-]|\s)\s+Done\b")


def _bash_version(path: str) -> tuple[int, ...] | None:
    try:
        result = subprocess.run(
            [path, "--version"],
            capture_output=True,
            text=True,
            timeout=4,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None

    if result.returncode != 0:
        return None

    match = re.search(r"version\s+([0-9]+(?:\.[0-9]+)*)", result.stdout)
    if not match:
        return None
    return tuple(int(part) for part in match.group(1).split("."))


def _find_bash_with_inline_ps0() -> str | None:
    candidates = [
        os.environ.get("CMUX_TEST_BASH", ""),
        shutil.which("bash") or "",
        "/opt/homebrew/bin/bash",
        "/usr/local/bin/bash",
        "/bin/bash",
    ]
    seen: set[str] = set()
    for candidate in candidates:
        if not candidate or candidate in seen:
            continue
        seen.add(candidate)
        version = _bash_version(candidate)
        if version is not None and version >= (5, 3):
            return candidate
    return None


class BoundUnixSocket:
    def __init__(self, path: Path) -> None:
        self.path = path
        self.sock: socket.socket | None = None

    def __enter__(self) -> BoundUnixSocket:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.bind(str(self.path))
        self.sock.listen(16)
        self.sock.setblocking(False)
        return self

    def accept_pending(self) -> None:
        if self.sock is None:
            return
        while True:
            try:
                conn, _ = self.sock.accept()
            except BlockingIOError:
                return
            conn.close()

    def __exit__(self, exc_type, exc, tb) -> None:
        if self.sock is not None:
            self.sock.close()
        try:
            self.path.unlink()
        except FileNotFoundError:
            pass


def _write_executable(path: Path, contents: str) -> None:
    path.write_text(contents, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


def _clean_line(raw: str) -> str:
    return ANSI_ESCAPE_RE.sub("", raw).replace("\r", "").strip()


def _drain_pty(fd: int, output: bytearray, *, quiet_after: float = 0.2) -> None:
    deadline = time.time() + quiet_after
    while time.time() < deadline:
        readable, _, _ = select.select([fd], [], [], 0.05)
        if fd not in readable:
            continue
        try:
            chunk = os.read(fd, 4096)
        except OSError:
            return
        if not chunk:
            return
        output.extend(chunk)
        deadline = time.time() + quiet_after


def _terminate_child(pid: int, *, grace: float = 0.5) -> None:
    with suppress(ProcessLookupError):
        os.kill(pid, signal.SIGTERM)

    deadline = time.time() + grace
    while time.time() < deadline:
        try:
            waited_pid, _ = os.waitpid(pid, os.WNOHANG)
        except ChildProcessError:
            return
        if waited_pid == pid:
            return
        time.sleep(0.05)

    with suppress(ProcessLookupError):
        os.kill(pid, signal.SIGKILL)
    with suppress(ChildProcessError):
        os.waitpid(pid, 0)


def _run_interactive_bash(bash_path: str, tmp: Path) -> tuple[int, str, str]:
    socket_path = tmp / "cmux.sock"
    send_log_path = tmp / "send.log"
    bin_dir = tmp / "bin"
    bin_dir.mkdir(parents=True, exist_ok=True)

    fake_send_tool = (
        "#!/bin/sh\n"
        'cat >> "$CMUX_TEST_SEND_LOG"\n'
        'printf "\\n" >> "$CMUX_TEST_SEND_LOG"\n'
        "sleep 0.05\n"
        "exit 0\n"
    )
    for tool in ("ncat", "socat", "nc"):
        _write_executable(bin_dir / tool, fake_send_tool)
    _write_executable(bin_dir / "gh", "#!/bin/sh\nexit 0\n")

    env = dict(os.environ)
    env.update(
        {
            "PATH": f"{bin_dir}:/usr/bin:/bin:/usr/sbin:/sbin",
            "CMUX_SOCKET_PATH": str(socket_path),
            "CMUX_WORKSPACE_ID": "workspace-bash-done-noise",
            "CMUX_TAB_ID": "tab-bash-done-noise",
            "CMUX_PANEL_ID": "panel-bash-done-noise",
            "CMUX_TEST_SEND_LOG": str(send_log_path),
            "PS1": "CMUX_TEST_PROMPT> ",
            "PROMPT_COMMAND": "",
        }
    )

    with BoundUnixSocket(socket_path) as bound_socket:
        pid, fd = os.forkpty()
        if pid == 0:
            os.chdir(str(ROOT))
            os.execve(bash_path, [bash_path, "--noprofile", "--norc", "-i"], env)

        commands = "\n".join(
            [
                f'source "{SHELL_DIR / "cmux-bash-integration.bash"}"',
                "sleep 5 & cmux_user_bg_pid=$!",
                "echo OK",
                "gh pr view 123",
                "sleep 0.2",
                "echo AFTER",
                "cmux_current_bang=$!",
                'echo "CMUX_TEST_USER_BG_PID=$cmux_user_bg_pid"',
                'echo "CMUX_TEST_CURRENT_BANG=$cmux_current_bang"',
                (
                    'if [[ "$cmux_current_bang" != "$cmux_user_bg_pid" ]]; then '
                    'echo "CMUX_TEST_BANG_CHANGED"; fi'
                ),
                'kill "$cmux_user_bg_pid" 2>/dev/null || true',
                'wait "$cmux_user_bg_pid" 2>/dev/null || true',
                "sleep 0.2",
                "exit 0",
                "",
            ]
        )
        os.write(fd, commands.encode())

        output = bytearray()
        deadline = time.time() + 8
        exit_status = 1
        while time.time() < deadline:
            bound_socket.accept_pending()
            readable, _, _ = select.select([fd], [], [], 0.05)
            if fd in readable:
                try:
                    chunk = os.read(fd, 4096)
                except OSError:
                    break
                if not chunk:
                    break
                output.extend(chunk)

            waited_pid, status = os.waitpid(pid, os.WNOHANG)
            if waited_pid == pid:
                exit_status = os.waitstatus_to_exitcode(status)
                _drain_pty(fd, output)
                break
        else:
            _terminate_child(pid)
            _drain_pty(fd, output, quiet_after=0.05)
            return 124, output.decode(errors="replace"), ""

    send_log = ""
    if send_log_path.exists():
        send_log = send_log_path.read_text(encoding="utf-8", errors="replace")
    return exit_status, output.decode(errors="replace"), send_log


def main() -> int:
    bash_path = _find_bash_with_inline_ps0()
    if bash_path is None:
        if os.environ.get("CI"):
            print("FAIL: CI must provide Bash >= 5.3 for inline PS0 regression coverage")
            return 1
        print("SKIP: no Bash >= 5.3 found for inline PS0 regression coverage")
        return 0

    with tempfile.TemporaryDirectory(prefix="cmux-bash-done-noise-") as td:
        rc, output, send_log = _run_interactive_bash(bash_path, Path(td))

    if rc == 124:
        print("FAIL: timed out waiting for interactive bash to exit")
        print(output)
        return 1

    if "OK" not in output or "AFTER" not in output:
        print(f"FAIL: interactive bash did not run the probe commands, rc={rc}")
        print(output)
        return 1

    cleaned_lines = [_clean_line(raw) for raw in output.splitlines()]
    user_bg_matches = re.findall(r"CMUX_TEST_USER_BG_PID=([0-9]+)", output)
    current_bang_matches = re.findall(r"CMUX_TEST_CURRENT_BANG=([0-9]+)", output)
    if not user_bg_matches or not current_bang_matches:
        print("FAIL: interactive bash did not report $! preservation markers")
        print(output)
        return 1
    if user_bg_matches[-1] != current_bang_matches[-1] or "CMUX_TEST_BANG_CHANGED" in cleaned_lines:
        print("FAIL: cmux bash prompt helpers changed the user's last background PID")
        print(output)
        return 1

    expected_pr_action = (
        'report_pr_action view --tab=tab-bash-done-noise '
        '--panel=panel-bash-done-noise --target="123"'
    )
    if expected_pr_action not in send_log:
        print("FAIL: Bash 5.3 PS0 preexec did not report the gh pr command")
        print(send_log)
        return 1

    done_lines = [
        line
        for line in cleaned_lines
        if DONE_LINE_RE.match(line)
    ]
    if done_lines:
        print("FAIL: cmux bash integration leaked background job completion notices")
        for line in done_lines:
            print(line)
        return 1

    print("PASS: bash integration background helpers stay out of the user-visible job table")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
