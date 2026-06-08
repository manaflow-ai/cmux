#!/usr/bin/env python3
"""End-to-end coverage for `cmux attach` (bare-terminal surface attach).

Drives the real `cmux attach` CLI client against a running app over the control
socket and asserts the wire behavior the host side promises:

  * cold attach replays the pane's scrollback tail, then streams live output
  * keystrokes typed into the attached terminal reach the pane's PTY
  * `--read-only` views output but never injects input
  * detach leaves the pane running (it is not a close)
  * the client's terminal size min-arbitrates with the GUI, and detaching
    restores the GUI's own size

The client is a separate raw-socket process, so it is spawned under a real pty
(it requires a TTY) with a controlled window size. CI only.
"""

from __future__ import annotations

import fcntl
import glob
import os
import pty
import select
import struct
import sys
import subprocess
import termios
import threading
import time
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError
from pane_resize_test_support import clean_line, wait_for


SOCKET_PATH = os.environ.get("CMUX_SOCKET_PATH", "/tmp/cmux-debug.sock")


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _find_cli_binary() -> str:
    env_cli = os.environ.get("CMUXTERM_CLI") or os.environ.get("CMUX_CLI_BIN")
    if env_cli and os.path.isfile(env_cli) and os.access(env_cli, os.X_OK):
        return env_cli

    fixed = os.path.expanduser("~/Library/Developer/Xcode/DerivedData/cmux-tests-v2/Build/Products/Debug/cmux")
    if os.path.isfile(fixed) and os.access(fixed, os.X_OK):
        return fixed

    candidates = glob.glob(os.path.expanduser("~/Library/Developer/Xcode/DerivedData/**/Build/Products/Debug/cmux"), recursive=True)
    candidates += glob.glob("/tmp/cmux-*/Build/Products/Debug/cmux")
    candidates = [p for p in candidates if os.path.isfile(p) and os.access(p, os.X_OK)]
    if not candidates:
        raise cmuxError("Could not locate cmux CLI binary; set CMUXTERM_CLI")
    candidates.sort(key=lambda p: os.path.getmtime(p), reverse=True)
    return candidates[0]


def _set_winsize(fd: int, cols: int, rows: int) -> None:
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))


def _spawn_attach(cli: str, surface: str, cols: int = 80, rows: int = 24, read_only: bool = False):
    """Spawn `cmux attach` under a pty with the given window size.

    Returns (proc, master_fd). Read the pane's output from master_fd; write
    keystrokes to it. The CLI requires a TTY, hence the pty.
    """
    master_fd, slave_fd = pty.openpty()
    _set_winsize(slave_fd, cols, rows)
    args = [cli, "--socket", SOCKET_PATH, "attach", surface]
    if read_only:
        args.append("--read-only")
    proc = subprocess.Popen(
        args,
        stdin=slave_fd,
        stdout=slave_fd,
        stderr=subprocess.PIPE,
        close_fds=True,
    )
    os.close(slave_fd)
    return proc, master_fd


def _read_until(master_fd: int, needle: bytes, timeout: float = 6.0) -> bytes:
    deadline = time.time() + timeout
    buf = bytearray()
    while time.time() < deadline:
        ready, _, _ = select.select([master_fd], [], [], max(0.0, deadline - time.time()))
        if master_fd not in ready:
            continue
        try:
            chunk = os.read(master_fd, 65536)
        except OSError:
            break
        if not chunk:
            break
        buf += chunk
        if needle in buf:
            return bytes(buf)
    raise cmuxError(f"Timed out waiting for {needle!r} in attach output; last={bytes(buf)[-400:]!r}")


def _drain(master_fd: int, settle: float = 0.4) -> None:
    deadline = time.time() + settle
    while time.time() < deadline:
        ready, _, _ = select.select([master_fd], [], [], max(0.0, deadline - time.time()))
        if master_fd not in ready:
            continue
        try:
            if not os.read(master_fd, 65536):
                break
        except OSError:
            break


def _start_drain(master_fd: int):
    """Continuously read (discard) the pty master while an attach is held open
    but we are not otherwise reading it. Without this the slave's output buffer
    fills, the CLI blocks on `write(stdout)`, and it can no longer process a
    detach. Returns (stop_event, thread); call stop after the client exits."""
    stop = threading.Event()

    def run() -> None:
        while not stop.is_set():
            ready, _, _ = select.select([master_fd], [], [], 0.2)
            if master_fd not in ready:
                continue
            try:
                if not os.read(master_fd, 65536):
                    break
            except OSError:
                break

    thread = threading.Thread(target=run, daemon=True)
    thread.start()
    return stop, thread


def _detach(proc, master_fd: int) -> None:
    """Detach by sending Ctrl+\\ (0x1C), then wait for the client to exit."""
    try:
        os.write(master_fd, b"\x1c")
    except OSError:
        pass
    try:
        proc.wait(timeout=6.0)
    except subprocess.TimeoutExpired:
        proc.kill()
        raise cmuxError("cmux attach did not exit after Ctrl+\\ detach")


def _cleanup(proc, master_fd: int) -> None:
    if proc.poll() is None:
        proc.kill()
        try:
            proc.wait(timeout=3.0)
        except Exception:
            pass
    try:
        os.close(master_fd)
    except OSError:
        pass


def _scrollback(client: cmux, surface: str) -> str:
    payload = client._call("surface.read_text", {"surface_id": surface, "scrollback": True}) or {}
    return str(payload.get("text") or "")


def _scrollback_has(client: cmux, surface: str, token: str) -> bool:
    return any(token == clean_line(line) or token in line for line in _scrollback(client, surface).splitlines())


def _wait_shell_ready(client: cmux, surface: str) -> None:
    for _ in range(5):
        token = f"CMUX_READY_{uuid.uuid4().hex[:8]}"
        client.send_surface(surface, f"echo {token}\n")
        try:
            wait_for(lambda: _scrollback_has(client, surface, token), timeout_s=3.0)
            return
        except cmuxError:
            time.sleep(0.15)
    raise cmuxError("terminal surface never produced shell output")


def _pane_columns(client: cmux, surface: str, timeout_s: float = 4.0) -> int:
    """The pane's *PTY* width, as the shell sees it via `tput cols`.

    This reflects the real `TIOCSWINSZ` the host applies on attach (size
    arbitration resizes the pane's terminal, which the shell observes through a
    SIGWINCH). It is render-independent, so it works for an off-screen surface
    where the GUI render grid would report nothing.
    """
    marker = f"COLS_{uuid.uuid4().hex[:6]}"
    client.send_surface(surface, f'printf "{marker}=%s\\n" "$(tput cols)"\n')
    box: dict[str, int] = {}

    def got() -> bool:
        for line in reversed(_scrollback(client, surface).splitlines()):
            cleaned = clean_line(line)
            if cleaned.startswith(f"{marker}="):
                value = cleaned.split("=", 1)[1].strip()
                if value.isdigit():
                    box["v"] = int(value)
                    return True
        return False

    wait_for(got, timeout_s=timeout_s)
    return box["v"]


def _settle_columns(client: cmux, surface: str, want: int, timeout_s: float = 6.0) -> int:
    """Re-probe the PTY width until it reaches `want` (or time out). Each probe
    sends one command, so this avoids spamming the pane the way a tight
    `wait_for` over `_pane_columns` would."""
    deadline = time.time() + timeout_s
    last = -1
    while time.time() < deadline:
        last = _pane_columns(client, surface)
        if last == want:
            return last
        time.sleep(0.3)
    return last


def _check_replay_and_live(cli: str, client: cmux, surface: str) -> None:
    replay_token = f"ATTACH_REPLAY_{uuid.uuid4().hex[:8]}"
    client.send_surface(surface, f"echo {replay_token}\n")
    wait_for(lambda: _scrollback_has(client, surface, replay_token), timeout_s=3.0)

    proc, master_fd = _spawn_attach(cli, surface, read_only=True)
    try:
        # Cold attach must replay the scrollback tail that already contains the
        # pre-attach marker.
        _read_until(master_fd, replay_token.encode(), timeout=6.0)

        # Live: output produced after attach must stream to the client.
        live_token = f"ATTACH_LIVE_{uuid.uuid4().hex[:8]}"
        client.send_surface(surface, f"echo {live_token}\n")
        _read_until(master_fd, live_token.encode(), timeout=6.0)
    finally:
        _detach(proc, master_fd)
        _cleanup(proc, master_fd)

    # Detach is not a close: the pane survives and still responds.
    _must(any(str(surface) == sid for _, sid, _ in client.list_surfaces()), "surface vanished after detach")
    _wait_shell_ready(client, surface)


def _check_read_only_blocks_input(cli: str, client: cmux, surface: str) -> None:
    proc, master_fd = _spawn_attach(cli, surface, read_only=True)
    try:
        _drain(master_fd, settle=0.5)
        blocked = f"ATTACH_READONLY_{uuid.uuid4().hex[:8]}"
        os.write(master_fd, f"echo {blocked}\n".encode())
        time.sleep(1.0)
        _must(not _scrollback_has(client, surface, blocked),
              "read-only attach forwarded input to the pane")
    finally:
        _detach(proc, master_fd)
        _cleanup(proc, master_fd)


def _check_input_roundtrip(cli: str, client: cmux, surface: str) -> None:
    proc, master_fd = _spawn_attach(cli, surface, read_only=False)
    try:
        _drain(master_fd, settle=0.5)
        token = f"ATTACH_INPUT_{uuid.uuid4().hex[:8]}"
        os.write(master_fd, f"echo {token}\n".encode())
        # The keystrokes must reach the pane's PTY and echo back through it.
        _read_until(master_fd, token.encode(), timeout=6.0)
        wait_for(lambda: _scrollback_has(client, surface, token), timeout_s=4.0)
    finally:
        _detach(proc, master_fd)
        _cleanup(proc, master_fd)
    # Pane still alive after a read-write detach.
    _must(any(str(surface) == sid for _, sid, _ in client.list_surfaces()), "surface vanished after detach")


def _check_size_arbitration(cli: str, client: cmux, surface: str) -> None:
    base_cols = _pane_columns(client, surface)
    _must(base_cols > 0, f"could not read base column count: {base_cols}")
    target_cols = 40 if base_cols > 45 else max(10, base_cols - 5)
    _must(target_cols < base_cols, f"GUI surface too narrow to test arbitration (base={base_cols})")

    proc, master_fd = _spawn_attach(cli, surface, cols=target_cols, rows=12, read_only=True)
    # Hold the attach open while we probe via the socket; drain its output so the
    # CLI never blocks on a full pty and can still process the detach.
    stop, _thread = _start_drain(master_fd)
    try:
        # min(gui, attachment): the pane's PTY shrinks to the smaller client.
        got = _settle_columns(client, surface, target_cols)
        _must(got == target_cols, f"attach did not arbitrate width: got {got}, want {target_cols} (base {base_cols})")
    finally:
        _detach(proc, master_fd)
        stop.set()
        _cleanup(proc, master_fd)

    # Last client gone -> the GUI's own size is restored.
    restored = _settle_columns(client, surface, base_cols)
    _must(restored == base_cols, f"width not restored after detach: got {restored}, want {base_cols}")


def main() -> int:
    cli = _find_cli_binary()
    client = cmux(SOCKET_PATH)
    client.connect()

    workspace = None
    surface = None
    try:
        workspace = client.new_workspace()
        client.select_workspace(workspace)
        surface = client.new_surface(panel_type="terminal")
        _wait_shell_ready(client, surface)

        _check_replay_and_live(cli, client, surface)
        _check_read_only_blocks_input(cli, client, surface)
        _check_input_roundtrip(cli, client, surface)
        _check_size_arbitration(cli, client, surface)
    finally:
        try:
            if workspace is not None:
                client.close_workspace(client._resolve_workspace_id(workspace))
        except Exception:
            pass
        client.close()

    print("PASS: cmux attach replay/live/input/read-only/detach/size-arbitration")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
