#!/usr/bin/env python3
"""
Regression: zsh integration hooks should degrade quietly when the job table is full.

The zsh job table has a fixed maximum size. Once user jobs or prompt plugins fill
it, cmux's injected Ghostty zsh integration must not keep surfacing hook errors on
every prompt redraw.
"""

from __future__ import annotations

import os
import pty
import select
import shutil
import signal
import subprocess
import tempfile
import time
from pathlib import Path


ERROR_NEEDLE = b"job table full or recursion limit exceeded"


def _read_available(master: int, output: bytearray, deadline: float) -> None:
    while time.time() < deadline:
        readable, _, _ = select.select([master], [], [], 0.05)
        if master not in readable:
            continue
        try:
            chunk = os.read(master, 4096)
        except OSError:
            return
        if not chunk:
            return
        output.extend(chunk)


def _send(master: int, text: str) -> None:
    os.write(master, text.encode("utf-8"))


def _capture_saturated_session(env: dict[str, str], zsh_path: str) -> bytes:
    master, slave = pty.openpty()
    proc = subprocess.Popen(
        [zsh_path, "-d", "-i"],
        stdin=slave,
        stdout=slave,
        stderr=slave,
        env=env,
        start_new_session=True,
        close_fds=True,
    )
    os.close(slave)

    output = bytearray()
    try:
        _read_available(master, output, time.time() + 0.75)
        _send(master, "print __CMUX_READY__\n")
        _read_available(master, output, time.time() + 1.0)
        _send(master, "for i in {1..1100}; do sleep 600 & done\n")
        _read_available(master, output, time.time() + 8.0)
        _send(master, "print __CMUX_AFTER_FILL__\n")
        _read_available(master, output, time.time() + 1.0)
        for _ in range(3):
            _send(master, "\n")
            _read_available(master, output, time.time() + 0.5)
    finally:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        finally:
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
            os.close(master)

    return bytes(output)


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    cmux_wrapper_dir = root / "Resources" / "shell-integration"
    ghostty_resources_dir = root / "ghostty" / "src"
    if not (cmux_wrapper_dir / ".zshenv").exists():
        print(f"SKIP: missing cmux zsh wrapper at {cmux_wrapper_dir}")
        return 0
    if not (ghostty_resources_dir / "shell-integration" / "zsh" / "ghostty-integration").exists():
        print(f"SKIP: missing Ghostty zsh integration at {ghostty_resources_dir}")
        return 0

    zsh_path = shutil.which("zsh")
    if zsh_path is None:
        print("SKIP: zsh not installed")
        return 0

    base = Path(tempfile.mkdtemp(prefix="cmux_ghostty_zsh_jobs_"))
    try:
        home = base / "home"
        home.mkdir(parents=True, exist_ok=True)
        for filename in (".zshenv", ".zprofile", ".zshrc"):
            (home / filename).write_text("", encoding="utf-8")

        env = dict(os.environ)
        env["HOME"] = str(home)
        env["ZDOTDIR"] = str(cmux_wrapper_dir)
        env["CMUX_ZSH_ZDOTDIR"] = str(home)
        env["CMUX_SHELL_INTEGRATION"] = "1"
        env["CMUX_SHELL_INTEGRATION_DIR"] = str(cmux_wrapper_dir)
        env["CMUX_LOAD_GHOSTTY_ZSH_INTEGRATION"] = "1"
        env["GHOSTTY_RESOURCES_DIR"] = str(ghostty_resources_dir)
        env["GHOSTTY_SHELL_FEATURES"] = "cursor,title"
        env.pop("GHOSTTY_BIN_DIR", None)

        output = _capture_saturated_session(env, zsh_path)
        if b"__CMUX_AFTER_FILL__" not in output:
            print("FAIL: saturated zsh session did not reach the post-fill prompt")
            print(output.decode("utf-8", "replace")[-4000:])
            return 1
        if ERROR_NEEDLE in output:
            print("FAIL: zsh integration hooks emitted job-table saturation errors")
            print(output.decode("utf-8", "replace")[-4000:])
            return 1

        print("PASS: zsh integration hooks stay quiet when the job table is saturated")
        return 0
    finally:
        shutil.rmtree(base, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
