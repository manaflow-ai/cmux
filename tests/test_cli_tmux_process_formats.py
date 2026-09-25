#!/usr/bin/env python3
"""Exercise tmux process formats with a real PTY behind a fake app socket."""

from __future__ import annotations

import os
import json
import pty
import re
import select
import signal
import socketserver
import tempfile
import threading
import time
from pathlib import Path

from claude_teams_test_utils import resolve_cmux_cli
from test_cli_omx_hud_tmux_split import (
    FakeCmuxState,
    FakeCmuxUnixServer,
    PANE_ID,
    run_cli,
)


class ProcessHandler(socketserver.StreamRequestHandler):
    def handle(self):
        while line := self.rfile.readline():
            line = line.decode().strip()
            if line.startswith("_cmux_capability_v1 "):
                line = line.split(" ", 2)[2]
            if line.startswith("auth "):
                self.wfile.write(b"OK\n")
                self.wfile.flush()
                continue
            request = json.loads(line)
            try:
                result = self.server.state.handle(request["method"], request.get("params", {}))
                reply = {"id": request["id"], "ok": True, "result": result}
            except RuntimeError as error:
                reply = {"id": request["id"], "ok": False,
                         "error": {"code": "not_found", "message": str(error)}}
            self.wfile.write((json.dumps(reply) + "\n").encode())
            self.wfile.flush()


class ProcessState(FakeCmuxState):
    def __init__(self, master: int, tty: str) -> None:
        super().__init__()
        self.master = master
        self.tty = tty
        self.start_command: str | None = None

    def handle(self, method, params):
        result = super().handle(method, params)
        if method == "surface.list":
            result["surfaces"][0].update(
                tty=self.tty,
                foreground_pid=os.tcgetpgrp(self.master),
                tmux_start_command=self.start_command,
            )
        return result


def read_until(master: int, pattern: bytes) -> re.Match[bytes]:
    output = b""
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if select.select([master], [], [], 0.1)[0]:
            output += os.read(master, 8192)
            if match := re.search(pattern, output):
                return match
    raise AssertionError(f"PTY never reached {pattern!r}: {output!r}")


def main() -> None:
    cli = resolve_cmux_cli()
    pid, master = pty.fork()
    if pid == 0:
        os.execve("/bin/sh", ["sh", "-i"], {"PATH": "/usr/bin:/bin", "PS1": "test> "})
    try:
        os.write(master, b"printf 'PROCESS_READY %s %s\\n' $$ \"$(tty)\"\n")
        ready = read_until(master, rb"PROCESS_READY (\d+) (/dev/[^\s]+)")
        shell_pid = int(ready[1])
        tty = ready[2].decode()
        assert shell_pid == pid
        state = ProcessState(master, tty)
        with tempfile.TemporaryDirectory(prefix="tmux-process-") as directory:
            home = Path(directory)
            socket_path = home / "socket"
            with FakeCmuxUnixServer(str(socket_path), state) as server:
                server.RequestHandlerClass = ProcessHandler
                thread = threading.Thread(target=server.serve_forever, daemon=True)
                thread.start()
                try:
                    def check(command: str, expected_command: str) -> None:
                        result = run_cli(cli, socket_path, home, [
                            "__tmux-compat", command, "-t", f"%{PANE_ID}",
                            *(["-p"] if command == "display-message" else []),
                            "-F", "#{pane_dead}|#{pane_current_command}|#{pane_pid}|#{pane_tty}",
                        ])
                        assert result.returncode == 0, result.stderr
                        expected = f"0|{expected_command}|{shell_pid}|{tty}"
                        assert result.stdout.strip() == expected, (expected, result.stdout, result.stderr)

                    check("display-message", "sh")
                    check("list-panes", "sh")
                    state.start_command = "node old-command.js"
                    check("display-message", "sh")
                    os.write(master, b"sleep 30\n")
                    deadline = time.monotonic() + 10
                    while os.tcgetpgrp(master) == pid and time.monotonic() < deadline:
                        time.sleep(0.01)
                    foreground_pid = os.tcgetpgrp(master)
                    assert foreground_pid != pid, "shell did not start the foreground job"
                    check("display-message", "sleep")
                    check("list-panes", "sleep")
                    os.kill(foreground_pid, signal.SIGTERM)
                    os.write(master, b"printf 'PROCESS_RETURNED\\n'\n")
                    read_until(master, rb"\r\nPROCESS_RETURNED\r\n")
                    check("display-message", "sh")
                finally:
                    server.shutdown()
                    thread.join(timeout=5)
    finally:
        os.close(master)
        os.kill(pid, signal.SIGKILL)
        os.waitpid(pid, 0)
    print("PASS: tmux process formats follow the foreground job and preserve the shell PID and TTY")


if __name__ == "__main__":
    main()
