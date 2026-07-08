#!/usr/bin/env python3
"""
Regression coverage for bash job-control noise from cmux shell integration.

The bug only appears in an interactive bash attached to a tty. A normal
subprocess cannot reproduce the prompt-time "[N] Done" notifications, so this
test drives bash through a PTY.
"""

from __future__ import annotations

import os
import pty
import re
import select
import shlex
import signal
import socket
import tempfile
import time
from pathlib import Path


PROMPT = "__CMUX_TEST_PROMPT__ "
JOB_DONE_RE = re.compile(r"^\[[0-9]+\][^\n\r]*\bDone\b", re.MULTILINE)


class InteractiveBash:
    def __init__(self, env: dict[str, str]) -> None:
        self.env = env
        self.pid: int | None = None
        self.fd: int | None = None
        self.output = bytearray()

    def __enter__(self) -> "InteractiveBash":
        pid, fd = pty.fork()
        if pid == 0:
            os.execvpe("bash", ["bash", "--noprofile", "--norc", "-i"], self.env)
        self.pid = pid
        self.fd = fd
        self.run(f"PS1='{PROMPT}'")
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        pid = self.pid
        if self.fd is not None:
            try:
                os.write(self.fd, b"exit\n")
                self._read_until(b"exit", timeout=1)
            except OSError:
                pass
        if pid is not None:
            self._wait_or_terminate(pid)
        if self.fd is not None:
            try:
                os.close(self.fd)
            except OSError:
                pass

    def _wait_or_terminate(self, pid: int) -> None:
        deadline = time.time() + 2
        while time.time() < deadline:
            try:
                waited, _ = os.waitpid(pid, os.WNOHANG)
            except ChildProcessError:
                return
            if waited == pid:
                return
            time.sleep(0.05)

        try:
            process_group = os.getpgid(pid)
        except ProcessLookupError:
            process_group = None
        if process_group is not None and process_group != os.getpgrp():
            try:
                os.killpg(process_group, signal.SIGTERM)
            except ProcessLookupError:
                pass
        else:
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass

        deadline = time.time() + 1
        while time.time() < deadline:
            try:
                waited, _ = os.waitpid(pid, os.WNOHANG)
            except ChildProcessError:
                return
            if waited == pid:
                return
            time.sleep(0.05)

        if process_group is not None and process_group != os.getpgrp():
            try:
                os.killpg(process_group, signal.SIGKILL)
            except ProcessLookupError:
                pass
        else:
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        try:
            os.waitpid(pid, 0)
        except ChildProcessError:
            pass

    def run(self, command: str, timeout: float = 5) -> None:
        if self.fd is None:
            raise RuntimeError("bash PTY is not open")
        self._drain()
        os.write(self.fd, command.encode("utf-8") + b"\n")
        chunk = self._read_until(PROMPT.encode("utf-8"), timeout=timeout)
        if PROMPT.encode("utf-8") not in chunk:
            raise AssertionError(
                f"timed out waiting for prompt after {command!r}\n\n"
                f"Captured output:\n{self.text}"
            )

    def _read_until(self, marker: bytes, *, timeout: float) -> bytes:
        if self.fd is None:
            raise RuntimeError("bash PTY is not open")
        deadline = time.time() + timeout
        captured = bytearray()
        while time.time() < deadline:
            ready, _, _ = select.select([self.fd], [], [], 0.1)
            if self.fd not in ready:
                continue
            try:
                data = os.read(self.fd, 4096)
            except OSError:
                break
            if not data:
                break
            captured.extend(data)
            self.output.extend(data)
            if marker in captured:
                break
        return bytes(captured)

    def _drain(self) -> None:
        if self.fd is None:
            raise RuntimeError("bash PTY is not open")
        while True:
            ready, _, _ = select.select([self.fd], [], [], 0.05)
            if self.fd not in ready:
                return
            try:
                data = os.read(self.fd, 4096)
            except OSError:
                return
            if not data:
                return
            self.output.extend(data)

    @property
    def text(self) -> str:
        return self.output.decode("utf-8", errors="replace")


def test_bash_integration_does_not_emit_done_notifications() -> None:
    repo_root = Path(__file__).resolve().parents[1]
    integration_script = repo_root / "Resources/shell-integration/cmux-bash-integration.bash"

    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        socket_path = tmp_path / "cmux.sock"
        repo_path = tmp_path / "repo"
        git_dir = repo_path / ".git"
        bin_path = tmp_path / "bin"
        gh_stub = bin_path / "gh"
        send_log = tmp_path / "send.log"

        git_dir.mkdir(parents=True)
        (git_dir / "HEAD").write_text("ref: refs/heads/feature/bash-done\n", encoding="utf-8")
        bin_path.mkdir()
        gh_stub.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        gh_stub.chmod(0o755)

        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            sock.bind(str(socket_path))
            sock.listen(1)

            env = {
                key: value
                for key, value in os.environ.items()
                if not key.startswith("CMUX")
            }
            env.update(
                {
                    "LC_ALL": "C",
                    "LANG": "C",
                    "PATH": f"{bin_path}{os.pathsep}{os.environ.get('PATH', '')}",
                }
            )

            with InteractiveBash(env) as bash:
                bash.run("set -m")
                bash.run("HISTCONTROL=ignorespace")
                bash.run(f"source {integration_script}")
                bash.run(
                    "_cmux_send() { printf '%s\\n' \"$1\" >> "
                    f"{shlex.quote(str(send_log))}; }}"
                )
                bash.run(f"export CMUX_SOCKET_PATH={shlex.quote(str(socket_path))}")
                bash.run("export CMUX_TAB_ID=tab-test")
                bash.run("export CMUX_PANEL_ID=panel-test")
                bash.run("_CMUX_TTY_NAME=ttys-test")
                bash.run(f"cd {repo_path}")

                # The next prompts exercise the shell-state, port-kick, TTY,
                # CWD, PR-action, and git-branch reporters.
                bash.run("gh pr merge 123")
                bash.run(" true")
                bash.run("cd ..")
                bash.run("true")
                bash.run("sleep 0.2")
                bash.run("echo __CMUX_DONE_CHECK__")

                sent_payloads = (
                    send_log.read_text(encoding="utf-8")
                    if send_log.exists()
                    else ""
                )
                expected_payload = (
                    'report_pr_action merge --tab=tab-test '
                    '--panel=panel-test --target="123"'
                )
                payload_count = sent_payloads.splitlines().count(expected_payload)
                if payload_count != 1:
                    raise AssertionError(
                        "bash integration did not emit exactly one PR action "
                        "payload after the real gh preexec path.\n\n"
                        f"Expected payload:\n{expected_payload}\n\n"
                        f"Observed count: {payload_count}\n\n"
                        f"Sent payloads:\n{sent_payloads}\n\n"
                        f"Full PTY output:\n{bash.text}"
                    )

                done_lines = JOB_DONE_RE.findall(bash.text)
                if done_lines:
                    matching_lines = [
                        line
                        for line in bash.text.splitlines()
                        if JOB_DONE_RE.search(line)
                    ]
                    raise AssertionError(
                        "bash integration emitted job completion notifications:\n"
                        + "\n".join(matching_lines)
                        + "\n\nFull PTY output:\n"
                        + bash.text
                    )
        finally:
            sock.close()


if __name__ == "__main__":
    test_bash_integration_does_not_emit_done_notifications()
    print("PASS: no bash job completion notifications observed")
