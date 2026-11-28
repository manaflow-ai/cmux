#!/usr/bin/env python3
"""`cmux clear_git_branch` reaches the socket like `report_git_branch` (#21993).

The Pi extension clears a session's sidebar branch with
`cmux clear_git_branch --workspace <id> --panel <id>` when its cwd is not a git
repository. The CLI forwarded `report_pwd`, `report_git_branch` and
`report_pr_action` but had no `clear_git_branch`, so that call failed with
`Unknown command` and exit 2, and a stale branch stayed in the sidebar.

This runs the real CLI with the argv the Pi extension builds, from a directory
that is not a git repository, against a socket that records each request, and
checks that the clear arrives as the socket's own `clear_git_branch` line,
scoped to the same workspace and panel as the sibling `report_git_branch`.
"""

from __future__ import annotations

import shlex
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from claude_teams_test_utils import resolve_cmux_cli  # noqa: E402
from fake_socket_env import cli_environment, unwrap_capability  # noqa: E402

WORKSPACE_ID = "11111111-1111-4111-8111-111111111111"
SURFACE_ID = "22222222-2222-4222-8222-222222222222"


class RecordingSocket:
    """Answers every v1 line with `OK` and records it."""

    def __init__(self, path: Path) -> None:
        self.path = path
        self.lines: list[str] = []
        self._lock = threading.Lock()
        self._stop = threading.Event()
        self._ready = threading.Event()
        self._thread = threading.Thread(target=self._serve, daemon=True)

    def __enter__(self) -> "RecordingSocket":
        self._thread.start()
        if not self._ready.wait(timeout=3):
            raise RuntimeError("fake socket did not start")
        return self

    def __exit__(self, *_exc: object) -> None:
        self._stop.set()
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
                client.connect(str(self.path))
        except OSError:
            pass
        self._thread.join(timeout=3)

    def take(self) -> list[str]:
        with self._lock:
            lines, self.lines = self.lines, []
        return lines

    def _serve(self) -> None:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
            server.bind(str(self.path))
            server.listen(8)
            server.settimeout(0.1)
            self._ready.set()
            while not self._stop.is_set():
                try:
                    connection, _ = server.accept()
                except socket.timeout:
                    continue
                threading.Thread(target=self._handle, args=(connection,), daemon=True).start()

    def _handle(self, connection: socket.socket) -> None:
        try:
            with connection, connection.makefile("rwb") as stream:
                for raw in stream:
                    line = unwrap_capability(raw.decode("utf-8").rstrip("\r\n"))
                    with self._lock:
                        self.lines.append(line)
                    stream.write(b"OK\n")
                    stream.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass


def run_cli(cli: str, server: RecordingSocket, cwd: Path, argv: list[str]) -> tuple[subprocess.CompletedProcess[str], list[str]]:
    env = cli_environment(server.path, home=cwd / "home", CMUX_WORKSPACE_ID=WORKSPACE_ID, CMUX_SURFACE_ID=SURFACE_ID)
    result = subprocess.run([cli, *argv], cwd=cwd, env=env, capture_output=True, text=True, timeout=30, check=False)
    return result, server.take()


def main() -> int:
    cli = resolve_cmux_cli()
    failures: list[str] = []
    # The Pi extension's sidebar target: `--surface` becomes `--panel`.
    target = ["--workspace", WORKSPACE_ID, "--panel", SURFACE_ID]
    # A Unix socket path is limited to 104 bytes on macOS, and the default
    # temporary directory there is long enough to overrun it, so use /tmp.
    socket_dir = Path(tempfile.mkdtemp(prefix="cmux-cgb-", dir="/tmp"))
    try:
        with tempfile.TemporaryDirectory(prefix="cmux-clear-git-branch-") as td:
            cwd = Path(td)
            (cwd / "home").mkdir()
            with RecordingSocket(socket_dir / "s.sock") as server:
                for command, argv in [
                    ("report_git_branch", ["report_git_branch", "main", "--status=unknown", *target]),
                    ("clear_git_branch", ["clear_git_branch", *target]),
                ]:
                    result, lines = run_cli(cli, server, cwd, argv)
                    if result.returncode != 0 or result.stdout.strip() != "OK":
                        failures.append(
                            f"{command}: exit {result.returncode}, stdout={result.stdout!r}, stderr={result.stderr.strip()!r}"
                        )
                        continue
                    sent = [shlex.split(line) for line in lines if line.split(" ", 1)[0] == command]
                    if len(sent) != 1:
                        failures.append(f"{command}: expected one {command} line, socket got {lines!r}")
                        continue
                    words = sent[0]
                    if f"--tab={WORKSPACE_ID}" not in words:
                        failures.append(f"{command}: not scoped to the workspace: {words!r}")
                    panel = words.index("--panel") if "--panel" in words else -1
                    if panel < 0 or panel + 1 >= len(words) or words[panel + 1] != SURFACE_ID:
                        failures.append(f"{command}: not scoped to the panel: {words!r}")
    finally:
        shutil.rmtree(socket_dir, ignore_errors=True)

    if failures:
        print("FAIL: clear_git_branch must reach the socket like report_git_branch")
        for failure in failures:
            print(f"  - {failure}")
        return 1
    print("PASS: the Pi extension's clear_git_branch call reaches the socket")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
