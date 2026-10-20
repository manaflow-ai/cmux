#!/usr/bin/env python3
"""Regression coverage for cmux issue #8953.

Drive the bundled cmux and Ghostty zsh integrations through a real interactive
PTY.  The prompt deliberately renders only the final path component while the
working directory is long, matching the issue's config-independent reproducer.
cmux must not infer prompt wrapping from ``PWD`` or write spacer rows into the
PTY, and it must preserve Ghostty's zsh prompt markers rather than rewriting
their redraw semantics.
"""

from __future__ import annotations

import fcntl
import os
import pty
import select
import shutil
import signal
import socket
import struct
import tempfile
import termios
import threading
import time
from dataclasses import dataclass
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
CMUX_INTEGRATION_DIR = REPO_ROOT / "Resources/shell-integration"
GHOSTTY_RESOURCES_DIR = REPO_ROOT / "ghostty/src"

PROMPT_END = b"\x1b]133;B\x07"
GHOSTTY_FRESH_PROMPT = b"\x1b]133;A;cl=line\x07"
CMUX_REDRAW_PROMPT = b"\x1b]133;A;redraw=last;cl=line\x07"
KEYBOARD_RESET = b"\x1b[>m\x1b[<8u"


@dataclass(frozen=True)
class SessionResult:
    columns: int
    resized_columns: int
    output: bytes

    @property
    def spacer_count(self) -> int:
        return self.output.count(KEYBOARD_RESET + b"\r\n")

    @property
    def prompt_count(self) -> int:
        return self.output.count(KEYBOARD_RESET)


def _serve_socket(listener: socket.socket, stop: threading.Event) -> None:
    """Drain cmux metadata messages so detached hook clients exit promptly."""
    while not stop.is_set():
        try:
            connection, _ = listener.accept()
        except (TimeoutError, OSError):
            continue

        with connection:
            connection.settimeout(0.2)
            while True:
                try:
                    if not connection.recv(65_536):
                        break
                except (TimeoutError, OSError):
                    break


def _read_until(
    master_fd: int,
    output: bytearray,
    marker: bytes,
    search_from: int,
    *,
    timeout: float = 10.0,
) -> int:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        marker_index = output.find(marker, search_from)
        if marker_index != -1:
            return marker_index + len(marker)

        readable, _, _ = select.select([master_fd], [], [], 0.2)
        if master_fd not in readable:
            continue
        try:
            chunk = os.read(master_fd, 65_536)
        except OSError as error:
            raise AssertionError(
                f"PTY closed before marker {marker!r}; output={bytes(output)!r}"
            ) from error
        if not chunk:
            break
        output.extend(chunk)

    raise AssertionError(f"timed out waiting for marker {marker!r}; output={bytes(output)!r}")


def _wait_for_child(pid: int, master_fd: int, output: bytearray) -> int:
    deadline = time.monotonic() + 10.0
    master_open = True
    while time.monotonic() < deadline:
        waited_pid, status = os.waitpid(pid, os.WNOHANG)
        if waited_pid == pid:
            return os.waitstatus_to_exitcode(status)

        if not master_open:
            time.sleep(0.01)
            continue
        readable, _, _ = select.select([master_fd], [], [], 0.2)
        if master_fd not in readable:
            continue
        try:
            chunk = os.read(master_fd, 65_536)
        except OSError:
            master_open = False
            continue
        if chunk:
            output.extend(chunk)
        else:
            master_open = False

    os.kill(pid, signal.SIGKILL)
    os.waitpid(pid, 0)
    raise AssertionError(f"interactive zsh did not exit; output={bytes(output)!r}")


def _capture_session(columns: int) -> SessionResult:
    with tempfile.TemporaryDirectory(prefix=f"cmux-issue-8953-{columns}-", dir="/tmp") as tmp:
        root = Path(tmp)
        home = root / "home"
        user_zdotdir = root / "minzdot"
        cwd = home / "cmux-blank-repro/aaaaaaaaaa/bbbbbbbbbb/cccccccccc/dddddddddd"
        user_zdotdir.mkdir(parents=True)
        cwd.mkdir(parents=True)
        (user_zdotdir / ".zshrc").write_text("PROMPT='%1~ '\n", encoding="utf-8")

        assert len(str(cwd)) >= 73, f"fixture cwd is not deep enough: {cwd}"

        socket_path = root / "cmux.sock"
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.set_inheritable(False)
        listener.bind(str(socket_path))
        listener.listen()
        listener.settimeout(0.1)

        env = {
            key: value
            for key, value in os.environ.items()
            if not key.startswith(("CMUX_", "GHOSTTY_")) and key not in {"ZDOTDIR", "TMUX"}
        }
        env.update(
            {
                "HOME": str(home),
                "SHELL": "/bin/zsh",
                "TERM": "xterm-256color",
                "ZDOTDIR": str(CMUX_INTEGRATION_DIR),
                "CMUX_ZSH_ZDOTDIR": str(user_zdotdir),
                "CMUX_SHELL_INTEGRATION": "1",
                "CMUX_SHELL_INTEGRATION_DIR": str(CMUX_INTEGRATION_DIR),
                "CMUX_LOAD_GHOSTTY_ZSH_INTEGRATION": "1",
                "GHOSTTY_RESOURCES_DIR": str(GHOSTTY_RESOURCES_DIR),
                "CMUX_SOCKET_PATH": str(socket_path),
                "CMUX_TAB_ID": "tab-issue-8953",
                "CMUX_PANEL_ID": "panel-issue-8953",
                "CMUX_TEST_FORCE_KEYBOARD_RESET": "1",
                # Keep command-start timestamps nonzero without waiting for the
                # real shell clock to advance after startup.
                "EPOCHSECONDS": "1234567890",
            }
        )

        pid, master_fd = pty.fork()
        if pid == 0:
            os.chdir(cwd)
            os.execve("/bin/zsh", ["zsh", "-d", "-i"], env)

        resized_columns = columns + 1
        fcntl.ioctl(
            master_fd,
            termios.TIOCSWINSZ,
            struct.pack("HHHH", 24, columns, 0, 0),
        )

        stop = threading.Event()
        server = threading.Thread(target=_serve_socket, args=(listener, stop), daemon=True)
        server.start()

        output = bytearray()
        search_from = 0
        child_reaped = False
        try:
            search_from = _read_until(master_fd, output, PROMPT_END, search_from)
            os.write(master_fd, b"echo AAA\n")

            search_from = _read_until(master_fd, output, PROMPT_END, search_from)
            fcntl.ioctl(
                master_fd,
                termios.TIOCSWINSZ,
                struct.pack("HHHH", 24, resized_columns, 0, 0),
            )
            search_from = _read_until(master_fd, output, PROMPT_END, search_from)
            os.write(master_fd, b"echo BBB\n")

            search_from = _read_until(master_fd, output, PROMPT_END, search_from)
            os.write(master_fd, b"exit\n")
            exit_code = _wait_for_child(pid, master_fd, output)
            child_reaped = True
            assert exit_code == 0, f"interactive zsh exited {exit_code}; output={bytes(output)!r}"
        finally:
            if not child_reaped:
                try:
                    os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                try:
                    os.waitpid(pid, 0)
                except ChildProcessError:
                    pass
            os.close(master_fd)
            stop.set()
            listener.close()
            server.join(timeout=1.0)

        return SessionResult(
            columns=columns,
            resized_columns=resized_columns,
            output=bytes(output),
        )


def main() -> int:
    if shutil.which("zsh") is None:
        print("SKIP: zsh is not installed")
        return 0

    results = [_capture_session(columns) for columns in (40, 140)]
    failures: list[str] = []

    for result in results:
        if result.prompt_count != 3:
            failures.append(
                f"cols={result.columns}: expected 3 cmux prompt cycles, saw {result.prompt_count}"
            )
        if result.spacer_count != 0:
            failures.append(
                f"cols={result.columns}: cmux wrote {result.spacer_count} spacer newline(s)"
            )
        if CMUX_REDRAW_PROMPT in result.output:
            failures.append(
                f"cols={result.columns}: cmux rewrote Ghostty's zsh prompt marker to redraw=last"
            )
        if result.output.count(GHOSTTY_FRESH_PROMPT) != 4:
            failures.append(
                f"cols={result.columns}->{result.resized_columns}: expected 4 unmodified Ghostty "
                "fresh-prompt markers (including the SIGWINCH redraw), "
                f"saw {result.output.count(GHOSTTY_FRESH_PROMPT)}"
            )

    if failures:
        print("FAIL: " + "\nFAIL: ".join(failures))
        return 1

    print(
        "PASS: short zsh prompts and SIGWINCH redraws emit no spacer rows "
        "and retain Ghostty prompt semantics"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
