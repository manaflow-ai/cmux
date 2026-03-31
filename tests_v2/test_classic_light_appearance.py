#!/usr/bin/env python3
"""E2E: Classic Light appearance mode renders a light terminal background.

Activates Classic Light mode via `defaults write`, triggers a config reload,
captures a screenshot, and verifies the terminal background pixels are bright
(RGB average >= 200).  Restores the original appearance mode on exit.

Usage:
    CMUX_SOCKET=/tmp/cmux-debug-<tag>.sock python3 tests_v2/test_classic_light_appearance.py
"""

import os
import select
import socket
import struct
import sys
import time
import zlib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError

SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")

# Pixel brightness threshold: RGB average must be >= this value for "light".
LIGHT_THRESHOLD = 200

# How many pixels to sample from the center region of the screenshot.
SAMPLE_SIZE = 100

# Percentage of sampled pixels that must be light.
LIGHT_PIXEL_RATIO = 0.7


def _send_v1_command(socket_path: str, command: str, timeout_s: float = 5.0) -> str:
    """Send a v1 (plain text) command to the cmux socket and return the response."""
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.connect(socket_path)
    sock.setblocking(False)
    sock.sendall((command + "\n").encode())

    data = b""
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        ready, _, _ = select.select([sock], [], [], 0.5)
        if ready:
            try:
                chunk = sock.recv(4096)
                if not chunk:
                    break
                data += chunk
                if b"\n" in data:
                    break
            except BlockingIOError:
                continue
        elif data:
            break
    sock.close()
    return data.decode().strip()


def _parse_png_pixels(image_path: str) -> tuple[list[tuple[int, int, int]], int, int]:
    """Parse a PNG file using only stdlib (struct + zlib). Returns (pixels, width, height).

    Supports 8-bit RGB and RGBA color types (the format macOS screenshots use).
    Each pixel is an (R, G, B) tuple.
    """
    with open(image_path, "rb") as f:
        data = f.read()

    # Validate PNG signature.
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise RuntimeError(f"Not a valid PNG file: {image_path}")

    pos = 8
    width = height = bit_depth = color_type = 0
    idat_chunks: list[bytes] = []

    while pos < len(data):
        chunk_len = struct.unpack(">I", data[pos:pos + 4])[0]
        chunk_type = data[pos + 4:pos + 8]
        chunk_data = data[pos + 8:pos + 8 + chunk_len]
        pos += 12 + chunk_len  # 4 (len) + 4 (type) + data + 4 (crc)

        if chunk_type == b"IHDR":
            width, height, bit_depth, color_type = struct.unpack(">IIBB", chunk_data[:10])
            interlace = chunk_data[12]
            if interlace != 0:
                raise RuntimeError("Interlaced PNGs are not supported")
        elif chunk_type == b"IDAT":
            idat_chunks.append(chunk_data)
        elif chunk_type == b"IEND":
            break

    if width == 0 or height == 0:
        raise RuntimeError("PNG IHDR chunk not found or invalid")
    if bit_depth != 8:
        raise RuntimeError(f"Unsupported PNG bit depth: {bit_depth} (only 8-bit supported)")
    if color_type not in (2, 6):  # 2 = RGB, 6 = RGBA
        raise RuntimeError(f"Unsupported PNG color type: {color_type} (only RGB/RGBA supported)")

    bpp = 3 if color_type == 2 else 4
    raw = zlib.decompress(b"".join(idat_chunks))

    # Reconstruct scanlines with PNG filtering.
    stride = width * bpp
    pixels: list[tuple[int, int, int]] = []
    prev_row = bytes(stride)

    for y in range(height):
        row_start = y * (stride + 1)
        filter_type = raw[row_start]
        scanline = bytearray(raw[row_start + 1:row_start + 1 + stride])

        if filter_type == 1:  # Sub
            for i in range(bpp, stride):
                scanline[i] = (scanline[i] + scanline[i - bpp]) & 0xFF
        elif filter_type == 2:  # Up
            for i in range(stride):
                scanline[i] = (scanline[i] + prev_row[i]) & 0xFF
        elif filter_type == 3:  # Average
            for i in range(stride):
                left = scanline[i - bpp] if i >= bpp else 0
                scanline[i] = (scanline[i] + (left + prev_row[i]) // 2) & 0xFF
        elif filter_type == 4:  # Paeth
            for i in range(stride):
                a = scanline[i - bpp] if i >= bpp else 0
                b = prev_row[i]
                c = prev_row[i - bpp] if i >= bpp else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pr = a if pa <= pb and pa <= pc else (b if pb <= pc else c)
                scanline[i] = (scanline[i] + pr) & 0xFF

        prev_row = bytes(scanline)
        for x in range(width):
            offset = x * bpp
            pixels.append((scanline[offset], scanline[offset + 1], scanline[offset + 2]))

    return pixels, width, height


def _sample_background_brightness(image_path: str) -> tuple[float, float]:
    """Sample pixels from the center of a screenshot and return (avg_brightness, light_ratio)."""
    pixels, width, height = _parse_png_pixels(image_path)

    cx, cy = width // 2, height // 2
    radius = min(width, height) // 6
    total_brightness = 0.0
    light_count = 0
    sampled = 0
    step = max(1, (2 * radius) // SAMPLE_SIZE)

    for dy in range(-radius, radius, step):
        for dx in range(-radius, radius, step):
            px, py = cx + dx, cy + dy
            if 0 <= px < width and 0 <= py < height:
                r, g, b = pixels[py * width + px]
                avg = (r + g + b) / 3.0
                total_brightness += avg
                if avg >= LIGHT_THRESHOLD:
                    light_count += 1
                sampled += 1
                if sampled >= SAMPLE_SIZE:
                    break
        if sampled >= SAMPLE_SIZE:
            break

    if sampled == 0:
        raise RuntimeError("No pixels sampled")

    return total_brightness / sampled, light_count / sampled


def main() -> int:
    # 1. Query current appearance mode via socket, then set classicLight.
    print("Querying current appearance mode via socket...")
    original_mode = _send_v1_command(SOCKET_PATH, "set_appearance_mode").removeprefix("OK ")
    print(f"Original appearance mode: {original_mode or '(not set)'}")

    try:
        # 2. Set Classic Light mode via socket (sets UserDefaults in-process + reloads config).
        print("Setting appearance mode to classicLight via socket...")
        result = _send_v1_command(SOCKET_PATH, "set_appearance_mode classicLight")
        if not result.startswith("OK"):
            print(f"FAIL: set_appearance_mode returned: {result}", file=sys.stderr)
            return 1
        time.sleep(2.0)  # Wait for theme application and re-render.

        with cmux(SOCKET_PATH) as c:

            # 3. Capture screenshot.
            print("Taking screenshot...")
            result = c.screenshot(label="classic_light_verify")
            screenshot_path = result.get("path")
            if not screenshot_path:
                print(f"FAIL: screenshot returned no path: {result}", file=sys.stderr)
                return 1

            if not Path(screenshot_path).exists():
                print(f"FAIL: screenshot file not found: {screenshot_path}", file=sys.stderr)
                return 1

            print(f"Screenshot saved: {screenshot_path}")

            # 4. Analyze pixel brightness.
            avg_brightness, light_ratio = _sample_background_brightness(screenshot_path)
            print(f"Average brightness: {avg_brightness:.1f} / 255")
            print(f"Light pixel ratio:  {light_ratio:.1%} (threshold: {LIGHT_PIXEL_RATIO:.0%})")

            if light_ratio >= LIGHT_PIXEL_RATIO:
                print("PASS: Terminal background is light in Classic Light mode.")
                return 0
            else:
                print(
                    f"FAIL: Only {light_ratio:.1%} of sampled pixels are light "
                    f"(need {LIGHT_PIXEL_RATIO:.0%}). "
                    f"Average brightness: {avg_brightness:.1f}.",
                    file=sys.stderr,
                )
                return 1

    finally:
        # Restore original appearance mode via socket.
        _send_v1_command(SOCKET_PATH, f"set_appearance_mode {original_mode}")
        print(f"Restored appearance mode to: {original_mode}")


if __name__ == "__main__":
    sys.exit(main())
