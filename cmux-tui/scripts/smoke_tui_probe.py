"""Small terminal probe used by the scripted TUI smoke test."""

from __future__ import annotations

import os
from pathlib import Path
import shlex


_PROBE_SOURCE = r'''import os, select, termios, time, tty

fd = os.open(os.environ.get("CMUX_TUI_SMOKE_TTY", "/dev/tty"), os.O_RDWR)
old = termios.tcgetattr(fd)
try:
    tty.setraw(fd)
    os.write(fd, b"\x1b]11;?\x1b\\")
    data = b""
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline and not (
        data.endswith(b"\x1b\\") or data.endswith(b"\x07")
    ):
        readable, _, _ = select.select([fd], [], [], max(0, deadline - time.monotonic()))
        if not readable:
            break
        data += os.read(fd, 128)
finally:
    termios.tcsetattr(fd, termios.TCSADRAIN, old)
    os.close(fd)
print(data.decode("ascii", "ignore").replace("\x1b", "<ESC>").replace("\x07", "<BEL>"))
print("cmux-tui-osc-probe-complete")
'''


def write_osc_probe_script(directory: str | os.PathLike[str]) -> Path:
    path = Path(directory) / "cmux-tui-osc-probe.py"
    path.write_text(_PROBE_SOURCE, encoding="utf-8")
    return path


def osc_probe_command(path: str | os.PathLike[str]) -> str:
    return f"python3 {shlex.quote(os.fspath(path))}"
