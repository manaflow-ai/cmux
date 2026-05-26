#!/usr/bin/env python3
"""
Regression coverage for issue #1565.

The bash integration runs several prompt-time reporters in the background. The
test drives a real interactive bash through a PTY so bash job-control
notifications are observable, then fails if the integration leaks `[N] Done`
lines into the prompt stream.
"""

from __future__ import annotations

import os
import pty
import re
import select
import shutil
import socket
import tempfile
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
BASH_INTEGRATION = ROOT / "Resources" / "shell-integration" / "cmux-bash-integration.bash"
PROMPT = "__CMUX_PROMPT__> "
DONE_LINE_RE = re.compile(r"\[\d+\][+-]?\s+Done\b")


def _read_available(fd: int, *, timeout: float = 0.2) -> str:
    deadline = time.monotonic() + timeout
    output = bytearray()
    while time.monotonic() < deadline:
        readable, _, _ = select.select([fd], [], [], 0.02)
        if fd not in readable:
            continue
        try:
            chunk = os.read(fd, 4096)
        except OSError:
            break
        if not chunk:
            break
        output.extend(chunk)
        deadline = time.monotonic() + 0.05
    return output.decode("utf-8", "replace")


def _read_until_prompt(fd: int, *, timeout: float = 5.0) -> str:
    deadline = time.monotonic() + timeout
    output = bytearray()
    prompt = PROMPT.encode()
    while time.monotonic() < deadline:
        readable, _, _ = select.select([fd], [], [], 0.05)
        if fd not in readable:
            continue
        try:
            chunk = os.read(fd, 4096)
        except OSError:
            break
        if not chunk:
            break
        output.extend(chunk)
        if prompt in output:
            return output.decode("utf-8", "replace")
    raise TimeoutError(f"timed out waiting for bash prompt; output so far:\n{output.decode('utf-8', 'replace')}")


def _send_command(fd: int, command: str) -> str:
    os.write(fd, f"{command}\n".encode())
    return _read_until_prompt(fd)


def _run_interactive_bash(socket_path: Path) -> str:
    bash = shutil.which("bash")
    if not bash:
        raise RuntimeError("bash not found")

    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(ROOT)
        os.environ.update(
            {
                "LC_ALL": "C",
                "TERM": "xterm-256color",
                "PS1": PROMPT,
            }
        )
        os.execv(bash, [bash, "--noprofile", "--norc", "-i"])
        os._exit(1)

    transcript = _read_until_prompt(fd)
    commands = [
        "set -m",
        "bind 'set enable-bracketed-paste off'",
        f"source {shlex_quote(BASH_INTEGRATION)}",
        "_cmux_send() { :; }",
        f"CMUX_SOCKET_PATH={shlex_quote(socket_path)}",
        "CMUX_TAB_ID=tab-issue-1565",
        "CMUX_PANEL_ID=panel-issue-1565",
        "_CMUX_TTY_NAME=ttys-issue-1565",
        "_CMUX_TTY_REPORTED=0",
        "_CMUX_PORTS_LAST_RUN=0",
        "_CMUX_PWD_LAST_PWD=/cmux-issue-1565-old-pwd",
        '_CMUX_LAST_PR_ACTION="checkout"',
        '_CMUX_LAST_PR_TARGET="issue-1565"',
        "_cmux_report_tty_once",
        "_cmux_report_shell_activity_state running",
        "_cmux_ports_kick command",
        "_cmux_emit_pr_command_hint",
        "_cmux_prompt_command",
        ":",
        ":",
        "echo __CMUX_DONE__",
    ]
    try:
        for command in commands:
            transcript += _send_command(fd, command)
        os.write(fd, b"exit\n")
        transcript += _read_available(fd, timeout=0.5)
    finally:
        try:
            os.kill(pid, 15)
        except ProcessLookupError:
            pass
        try:
            os.waitpid(pid, os.WNOHANG)
        except ChildProcessError:
            pass
        try:
            os.close(fd)
        except OSError:
            pass
    return transcript


def shlex_quote(path: Path) -> str:
    return "'" + str(path).replace("'", "'\\''") + "'"


def main() -> int:
    if not BASH_INTEGRATION.exists():
        print(f"FAIL: missing bash integration at {BASH_INTEGRATION}")
        return 1

    with tempfile.TemporaryDirectory(prefix="cmux-bash-done-notifications-") as tmp:
        socket_path = Path(tmp) / "cmux.sock"
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            listener.bind(str(socket_path))
            listener.listen(1)
            try:
                transcript = _run_interactive_bash(socket_path)
            except TimeoutError as error:
                print(f"FAIL: {error}")
                return 1
        finally:
            listener.close()

    done_lines = [line for line in transcript.splitlines() if DONE_LINE_RE.search(line)]
    if done_lines:
        print("FAIL: bash integration leaked job completion notifications:")
        for line in done_lines[:20]:
            print(line)
        if len(done_lines) > 20:
            print(f"... {len(done_lines) - 20} more Done lines omitted")
        return 1

    if "no job control" in transcript:
        print("FAIL: bash did not run with interactive job control")
        return 1

    print("PASS: bash integration emitted no '[N] Done' job-control notifications")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
