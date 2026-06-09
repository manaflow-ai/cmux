#!/usr/bin/env python3
"""
Regression test for Ctrl+C and Ctrl+D delivery to a cmux terminal.

The VM runner starts cmux before invoking this script. The test drives the
terminal through the debug socket and verifies foreground processes receive the
same control characters a user would type.
"""

import os
import shlex
import sys
import time
import uuid
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET_PATH", "/tmp/cmux-debug.sock")


def _wait_for_marker(marker: Path, timeout_s: float = 5.0) -> str:
    start = time.time()
    while time.time() - start < timeout_s:
        try:
            return marker.read_text(encoding="utf-8").strip()
        except FileNotFoundError:
            time.sleep(0.05)
    raise cmuxError(f"Timed out waiting for marker: {marker}")


def _focused_terminal(c: cmux) -> tuple[str, str]:
    c.activate_app()
    workspace_id = c.new_workspace()
    c.select_workspace(workspace_id)

    start = time.time()
    last_health = []
    while time.time() - start < 5.0:
        last_health = c.surface_health()
        terminal = next((h for h in last_health if h.get("type") == "terminal" and h.get("in_window")), None)
        if terminal is not None:
            surface = str(terminal.get("id") or terminal.get("index"))
            c.focus_surface(surface)
            return workspace_id, surface
        time.sleep(0.1)

    raise cmuxError(f"Timed out waiting for terminal surface: {last_health}")


def _send_python(c: cmux, surface: str, code: str) -> None:
    c.send_surface(surface, f"python3 -c {shlex.quote(code)}\n")


def _wait_for_shell(c: cmux, surface: str, root: Path, token: str) -> None:
    marker = root / f"cmux-shell-ready-{token}"
    marker.unlink(missing_ok=True)
    c.send_surface(surface, f"printf shell-ready > {shlex.quote(str(marker))}\n")
    value = _wait_for_marker(marker, timeout_s=5.0)
    if value != "shell-ready":
        raise cmuxError(f"Expected shell-ready marker, got {value!r}")


def _test_ctrl_c(c: cmux, surface: str, root: Path, token: str) -> None:
    ready = root / f"cmux-ctrl-c-ready-{token}"
    done = root / f"cmux-ctrl-c-done-{token}"
    ready.unlink(missing_ok=True)
    done.unlink(missing_ok=True)

    _send_python(
        c,
        surface,
        f"""
import pathlib
import signal
import sys
import time

ready = pathlib.Path({str(ready)!r})
done = pathlib.Path({str(done)!r})

def handle_sigint(signum, frame):
    done.write_text("sigint", encoding="utf-8")
    print("CMUX_CTRL_C_DONE {token}", flush=True)
    sys.exit(0)

signal.signal(signal.SIGINT, handle_sigint)
ready.write_text("ready", encoding="utf-8")
print("CMUX_CTRL_C_READY {token}", flush=True)

while True:
    time.sleep(0.1)
""",
    )

    _wait_for_marker(ready, timeout_s=5.0)
    c.send_key_surface(surface, "ctrl-c")
    value = _wait_for_marker(done, timeout_s=5.0)
    if value != "sigint":
        raise cmuxError(f"Expected SIGINT marker, got {value!r}")
    _wait_for_shell(c, surface, root, f"{token}-after-ctrl-c")


def _test_ctrl_d(c: cmux, surface: str, root: Path, token: str) -> None:
    ready = root / f"cmux-ctrl-d-ready-{token}"
    done = root / f"cmux-ctrl-d-done-{token}"
    ready.unlink(missing_ok=True)
    done.unlink(missing_ok=True)

    _send_python(
        c,
        surface,
        f"""
import pathlib
import sys

ready = pathlib.Path({str(ready)!r})
done = pathlib.Path({str(done)!r})
ready.write_text("ready", encoding="utf-8")
print("CMUX_CTRL_D_READY {token}", flush=True)
data = sys.stdin.read()
done.write_text(f"eof:{{len(data)}}", encoding="utf-8")
print("CMUX_CTRL_D_DONE {token}", flush=True)
""",
    )

    _wait_for_marker(ready, timeout_s=5.0)
    c.send_key_surface(surface, "ctrl-d")
    value = _wait_for_marker(done, timeout_s=5.0)
    if not value.startswith("eof:"):
        raise cmuxError(f"Expected EOF marker, got {value!r}")


def main() -> int:
    token = uuid.uuid4().hex[:12]
    root = Path("/tmp")

    with cmux(SOCKET_PATH) as c:
        _workspace_id, surface = _focused_terminal(c)
        _test_ctrl_c(c, surface, root, token)
        _test_ctrl_d(c, surface, root, token)

    print("PASS: Ctrl+C SIGINT and Ctrl+D EOF delivered to terminal process")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
