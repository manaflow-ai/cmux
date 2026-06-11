#!/usr/bin/env python3
"""
Regression test: terminal regex highlights must be visible in the window.

This intentionally uses the full-window debug `screenshot` command instead of
`panel_snapshot`. `panel_snapshot` captures the terminal IOSurface directly and
does not include AppKit overlay views.
"""

import json
import os
import struct
import subprocess
import sys
import time
import zlib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET_PATH", "/tmp/cmux-debug.sock")
CONFIG_PATH = Path.home() / ".config" / "cmux" / "cmux.json"
MARKER = "CMUX_HIGHLIGHT_REPRO"
HIGHLIGHT_COLOR = "#00FF00FF"
MIN_GREEN_PIXELS = 600


def _wait_for(predicate, timeout_s: float, step_s: float = 0.05) -> None:
    start = time.time()
    while time.time() - start < timeout_s:
        if predicate():
            return
        time.sleep(step_s)
    raise cmuxError("Timed out waiting for condition")


def _capture_screenshot(client: cmux, label: str) -> Path:
    response = client._send_command(f"screenshot {label}").strip()
    if not response.startswith("OK "):
        raise cmuxError(f"screenshot failed: {response}")
    parts = response.split(" ", 2)
    if len(parts) != 3:
        raise cmuxError(f"screenshot parse failed: {response}")
    path = Path(parts[2])
    if not path.exists():
        raise cmuxError(f"screenshot path does not exist: {path}")
    return path


def _write_regex_highlight_config() -> bytes | None:
    previous = CONFIG_PATH.read_bytes() if CONFIG_PATH.exists() else None
    CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "terminal": {
            "regexHighlights": [
                f"{HIGHLIGHT_COLOR}\t{MARKER}",
            ],
        },
    }
    CONFIG_PATH.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    return previous


def _restore_config(previous: bytes | None) -> None:
    if previous is None:
        try:
            CONFIG_PATH.unlink()
        except FileNotFoundError:
            pass
        return

    CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)
    CONFIG_PATH.write_bytes(previous)


def _read_regex_highlight_default(bundle_id: str) -> str | None:
    result = subprocess.run(
        ["defaults", "read", bundle_id, "terminal.regexHighlights"],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        return None
    return result.stdout.rstrip("\n")


def _write_regex_highlight_default(bundle_id: str, value: str) -> None:
    subprocess.run(
        ["defaults", "write", bundle_id, "terminal.regexHighlights", "-string", value],
        check=False,
        capture_output=True,
    )


def _delete_regex_highlight_default(bundle_id: str) -> None:
    subprocess.run(
        ["defaults", "delete", bundle_id, "terminal.regexHighlights"],
        check=False,
        capture_output=True,
    )


def _png_rgb_rows(path: Path) -> tuple[int, int, list[bytes], int]:
    data = path.read_bytes()
    if not data.startswith(b"\x89PNG\r\n\x1a\n"):
        raise cmuxError(f"not a PNG: {path}")

    pos = 8
    width = 0
    height = 0
    bit_depth = 0
    color_type = 0
    idat = bytearray()
    while pos + 8 <= len(data):
        length = struct.unpack(">I", data[pos:pos + 4])[0]
        chunk_type = data[pos + 4:pos + 8]
        chunk_data = data[pos + 8:pos + 8 + length]
        pos += 12 + length
        if chunk_type == b"IHDR":
            width, height, bit_depth, color_type, _compression, _filter, interlace = struct.unpack(
                ">IIBBBBB",
                chunk_data,
            )
            if bit_depth != 8 or color_type not in (2, 6) or interlace != 0:
                raise cmuxError(
                    f"unsupported PNG format: bit_depth={bit_depth} "
                    f"color_type={color_type} interlace={interlace}"
                )
        elif chunk_type == b"IDAT":
            idat.extend(chunk_data)
        elif chunk_type == b"IEND":
            break

    if width <= 0 or height <= 0:
        raise cmuxError(f"missing PNG dimensions: {path}")

    channels = 3 if color_type == 2 else 4
    stride = width * channels
    raw = zlib.decompress(bytes(idat))
    rows: list[bytes] = []
    prev = bytearray(stride)
    cursor = 0
    for _ in range(height):
        filter_type = raw[cursor]
        cursor += 1
        current = bytearray(raw[cursor:cursor + stride])
        cursor += stride
        for i in range(stride):
            left = current[i - channels] if i >= channels else 0
            up = prev[i]
            up_left = prev[i - channels] if i >= channels else 0
            if filter_type == 0:
                pass
            elif filter_type == 1:
                current[i] = (current[i] + left) & 0xFF
            elif filter_type == 2:
                current[i] = (current[i] + up) & 0xFF
            elif filter_type == 3:
                current[i] = (current[i] + ((left + up) // 2)) & 0xFF
            elif filter_type == 4:
                pa = abs(up - up_left)
                pb = abs(left - up_left)
                pc = abs(left + up - 2 * up_left)
                predictor = left if pa <= pb and pa <= pc else up if pb <= pc else up_left
                current[i] = (current[i] + predictor) & 0xFF
            else:
                raise cmuxError(f"unsupported PNG filter type: {filter_type}")
        rows.append(bytes(current))
        prev = current

    return width, height, rows, channels


def _count_green_pixels(path: Path) -> int:
    _width, _height, rows, channels = _png_rgb_rows(path)
    count = 0
    for row in rows:
        for i in range(0, len(row), channels):
            red = row[i]
            green = row[i + 1]
            blue = row[i + 2]
            if red <= 70 and green >= 180 and blue <= 90:
                count += 1
    return count


def main() -> int:
    bundle_id = cmux.default_bundle_id()
    previous_config = _write_regex_highlight_config()
    previous_default = _read_regex_highlight_default(bundle_id)
    _delete_regex_highlight_default(bundle_id)
    screenshot_path: Path | None = None
    try:
        with cmux(SOCKET_PATH) as client:
            if not client.ping():
                raise cmuxError(f"Socket ping failed on {SOCKET_PATH}")

            response = client._send_command("reload_config")
            if not response.startswith("OK"):
                raise cmuxError(f"reload_config failed: {response}")

            client.activate_app()
            time.sleep(0.25)

            workspace_id = client.new_workspace()
            client.select_workspace(workspace_id)
            time.sleep(0.4)

            surfaces = client.list_surfaces()
            if not surfaces:
                raise cmuxError("Expected at least 1 surface after new_workspace")
            panel_id = next((sid for _i, sid, focused in surfaces if focused), surfaces[0][1])
            _wait_for(lambda: client.is_terminal_focused(panel_id), timeout_s=3.0)

            client.send_surface(panel_id, f"printf '{MARKER}\\n'\n")
            _wait_for(lambda: MARKER in client.read_terminal_text(panel_id), timeout_s=4.0)

            time.sleep(0.35)
            screenshot_path = _capture_screenshot(client, "terminal_regex_highlight")
            green_pixels = _count_green_pixels(screenshot_path)
            if green_pixels < MIN_GREEN_PIXELS:
                raise cmuxError(
                    "Expected configured terminal regex highlight to be visibly green.\n"
                    f"green_pixels={green_pixels} min_green_pixels={MIN_GREEN_PIXELS}\n"
                    f"screenshot_path={screenshot_path}"
                )
    finally:
        _restore_config(previous_config)
        if previous_default is None:
            _delete_regex_highlight_default(bundle_id)
        else:
            _write_regex_highlight_default(bundle_id, previous_default)
        try:
            with cmux(SOCKET_PATH) as client:
                client._send_command("reload_config")
        except Exception:
            pass

    print(f"PASS: terminal regex highlight visible in screenshot {screenshot_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
