#!/usr/bin/env python3
"""
Regression test: opening Settings should not feel frozen on first present.

This exercises the real Settings open command through the debug socket and
measures the time until the app can capture the presented Settings window. The
bug in issue 3384 was a main-thread first-present stall from constructing every
Settings pane eagerly.
"""

import os
import struct
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET_PATH", cmux.DEFAULT_SOCKET_PATH)
FIRST_OPEN_BUDGET_MS = 1_000.0
SETTINGS_WINDOW_IDENTIFIER = "cmux.settings"
SETTINGS_MIN_WIDTH = 820
SETTINGS_MIN_HEIGHT = 540


def _app_pid_for_socket(socket_path: str) -> int:
    try:
        output = subprocess.check_output(["lsof", "-t", socket_path], text=True)
    except subprocess.CalledProcessError as exc:
        raise cmuxError(f"Could not find cmux process for socket {socket_path}") from exc

    for line in output.splitlines():
        stripped = line.strip()
        if stripped.isdigit():
            return int(stripped)
    raise cmuxError(f"lsof returned no process id for socket {socket_path}: {output!r}")


def _png_size(path: str) -> tuple[int, int]:
    with open(path, "rb") as f:
        header = f.read(24)

    if len(header) < 24 or header[:8] != b"\x89PNG\r\n\x1a\n":
        raise cmuxError(f"Screenshot is not a PNG: {path}")

    return struct.unpack(">II", header[16:24])


def _capture_main_window_size(c: cmux, label: str) -> tuple[int, int]:
    screenshot = c.screenshot(label)
    path = str(screenshot.get("path") or "")
    if not path:
        raise cmuxError(f"debug.window.screenshot returned no path: {screenshot}")
    return _png_size(path)


def _looks_like_settings_size(size: tuple[int, int]) -> bool:
    width, height = size
    return width >= SETTINGS_MIN_WIDTH and height >= SETTINGS_MIN_HEIGHT


def _settings_window_is_presented(state: dict) -> bool:
    return (
        state.get("identifier") == SETTINGS_WINDOW_IDENTIFIER
        and bool(state.get("visible"))
        and (bool(state.get("main")) or bool(state.get("key")))
    )


def _measure_settings_first_capture(c: cmux) -> tuple[float, tuple[int, int]]:
    start = time.perf_counter()
    c.open_settings(activate=True)
    deadline = start + (FIRST_OPEN_BUDGET_MS / 1000.0) + 1.0
    last_size = (0, 0)
    while time.perf_counter() < deadline:
        if _settings_window_is_presented(c.settings_window_state()):
            last_size = _capture_main_window_size(c, "settings-open-latency")
            return (time.perf_counter() - start) * 1000.0, last_size
        time.sleep(0.02)
    return (time.perf_counter() - start) * 1000.0, last_size


def main() -> int:
    _ = _app_pid_for_socket(SOCKET_PATH)

    with cmux(SOCKET_PATH) as c:
        try:
            before_state = c.settings_window_state()
            if bool(before_state.get("exists")):
                raise cmuxError(
                    "Settings window already exists before the first-present latency measurement"
                )

            first_open_ms, settings_size = _measure_settings_first_capture(c)
        finally:
            try:
                c.close_settings()
            except cmuxError:
                pass

    if first_open_ms > FIRST_OPEN_BUDGET_MS:
        raise cmuxError(
            f"Settings first present capture took {first_open_ms:.1f} ms, "
            f"expected <= {FIRST_OPEN_BUDGET_MS:.0f} ms"
        )

    if not _looks_like_settings_size(settings_size):
        raise cmuxError(f"Expected Settings-sized screenshot, got {settings_size[0]}x{settings_size[1]}")

    print(
        f"PASS: Settings first present capturable in {first_open_ms:.1f} ms "
        f"({settings_size[0]}x{settings_size[1]})"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
