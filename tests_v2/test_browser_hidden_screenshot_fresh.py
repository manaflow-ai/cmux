#!/usr/bin/env python3
"""Regression: hidden browser screenshots reflect the current WKWebView frame."""

import base64
import os
import struct
import sys
import time
import urllib.parse
import zlib
from pathlib import Path
from typing import Iterable

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET_PATH", "/tmp/cmux-debug.sock")


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _data_url(html: str) -> str:
    return "data:text/html;charset=utf-8," + urllib.parse.quote(html)


def _wait_until(pred, timeout_s: float, label: str) -> None:
    deadline = time.time() + timeout_s
    last_exc = None
    while time.time() < deadline:
        try:
            if pred():
                return
        except Exception as exc:  # noqa: BLE001
            last_exc = exc
        time.sleep(0.05)
    if last_exc is not None:
        raise cmuxError(f"Timed out waiting for {label}: {last_exc}")
    raise cmuxError(f"Timed out waiting for {label}")


def _focused_workspace_id(c: cmux) -> str:
    focused = (c.identify().get("focused") or {})
    return str(focused.get("workspace_id") or "")


def _focused_surface_id(c: cmux) -> str:
    focused = (c.identify().get("focused") or {})
    return str(focused.get("surface_id") or "")


def _value(res: dict):
    return (res or {}).get("value")


def _decode_png_rgb(png: bytes) -> tuple[int, int, Iterable[tuple[int, int, int]]]:
    if not png.startswith(b"\x89PNG\r\n\x1a\n"):
        raise cmuxError("Screenshot payload is not a PNG")

    width = 0
    height = 0
    bit_depth = 0
    color_type = 0
    idat = bytearray()
    offset = 8
    while offset + 8 <= len(png):
        length = struct.unpack(">I", png[offset : offset + 4])[0]
        kind = png[offset + 4 : offset + 8]
        data = png[offset + 8 : offset + 8 + length]
        offset += 12 + length

        if kind == b"IHDR":
            width, height, bit_depth, color_type, compression, filter_method, interlace = struct.unpack(
                ">IIBBBBB", data
            )
            _must(bit_depth == 8, f"Expected 8-bit PNG, got bit depth {bit_depth}")
            _must(compression == 0 and filter_method == 0 and interlace == 0, "Unsupported PNG encoding")
            _must(color_type in (2, 6), f"Unsupported PNG color type: {color_type}")
        elif kind == b"IDAT":
            idat.extend(data)
        elif kind == b"IEND":
            break

    _must(width > 0 and height > 0 and len(idat) > 0, "PNG missing IHDR/IDAT")

    channels = 4 if color_type == 6 else 3
    stride = width * channels
    raw = zlib.decompress(bytes(idat))
    prev = [0] * stride
    pixels: list[tuple[int, int, int]] = []
    pos = 0

    for _y in range(height):
        filter_type = raw[pos]
        pos += 1
        scanline = list(raw[pos : pos + stride])
        pos += stride

        for i, val in enumerate(scanline):
            left = scanline[i - channels] if i >= channels else 0
            up = prev[i]
            up_left = prev[i - channels] if i >= channels else 0
            if filter_type == 0:
                restored = val
            elif filter_type == 1:
                restored = val + left
            elif filter_type == 2:
                restored = val + up
            elif filter_type == 3:
                restored = val + ((left + up) // 2)
            elif filter_type == 4:
                p = left + up - up_left
                pa = abs(p - left)
                pb = abs(p - up)
                pc = abs(p - up_left)
                predictor = left if pa <= pb and pa <= pc else up if pb <= pc else up_left
                restored = val + predictor
            else:
                raise cmuxError(f"Unsupported PNG filter type: {filter_type}")
            scanline[i] = restored & 0xFF

        for x in range(width):
            base = x * channels
            pixels.append((scanline[base], scanline[base + 1], scanline[base + 2]))
        prev = scanline

    return width, height, pixels


def _dominant_channel_counts(png_base64: str) -> tuple[int, int, int, int, int]:
    png = base64.b64decode(png_base64)
    width, height, pixels_iter = _decode_png_rgb(png)
    pixels = list(pixels_iter)
    _must(len(pixels) == width * height, "Decoded PNG pixel count mismatch")

    step = max(1, len(pixels) // 5000)
    red = 0
    green = 0
    blue = 0
    sampled = 0
    for r, g, b in pixels[::step]:
        sampled += 1
        if r >= 180 and g <= 80 and b <= 80:
            red += 1
        if g >= 180 and r <= 80 and b <= 80:
            green += 1
        if b >= 180 and r <= 80 and g <= 80:
            blue += 1
    return sampled, red, green, blue, step


def _screenshot_color_counts(c: cmux, surface_id: str) -> tuple[int, int, int, int, int]:
    shot = c._call("browser.screenshot", {"surface_id": surface_id}, timeout_s=20.0) or {}
    payload = str(shot.get("png_base64") or "")
    _must(len(payload) > 100, f"Expected screenshot payload: {shot}")
    return _dominant_channel_counts(payload)


def main() -> int:
    html = """
<!doctype html>
<html>
  <head>
    <title>cmux-hidden-screenshot-fresh</title>
    <style>
      html, body, #app {
        width: 100%;
        height: 100%;
        margin: 0;
      }
      body {
        background: rgb(255, 0, 0);
      }
    </style>
  </head>
  <body>
    <main id="app" data-state="red"></main>
  </body>
</html>
""".strip()

    with cmux(SOCKET_PATH) as c:
        browser_ws = c.current_workspace()
        opened = c._call("browser.open_split", {"url": "about:blank"}) or {}
        surface_id = str(opened.get("surface_id") or "")
        _must(surface_id != "", f"browser.open_split returned no surface_id: {opened}")

        c._call("browser.navigate", {"surface_id": surface_id, "url": _data_url(html)})
        _wait_until(
            lambda: str(
                _value(c._call("browser.eval", {"surface_id": surface_id, "script": "document.readyState"})) or ""
            ).lower()
            == "complete",
            timeout_s=5.0,
            label="initial page load",
        )

        sampled, red, green, _blue, _step = _screenshot_color_counts(c, surface_id)
        _must(red > sampled * 0.75, f"Visible seed screenshot should be red: sampled={sampled} red={red} green={green}")

        visible_ws = c.new_workspace()
        c.select_workspace(visible_ws)
        visible_surface = _focused_surface_id(c)
        _must(_focused_workspace_id(c) == visible_ws, "Failed to switch to the visible workspace")
        _must(visible_surface != "", "Visible workspace has no focused surface")

        mutation = """
(() => {
  document.body.style.background = 'rgb(0, 255, 0)';
  const app = document.querySelector('#app');
  if (app) app.setAttribute('data-state', 'green');
  window.__cmuxHiddenScreenshotState = 'green';
  return window.__cmuxHiddenScreenshotState;
})()
""".strip()
        mutated = c._call("browser.eval", {"surface_id": surface_id, "script": mutation}) or {}
        _must(str(_value(mutated)) == "green", f"Hidden DOM mutation did not apply: {mutated}")
        _wait_until(
            lambda: str(
                _value(c._call("browser.eval", {"surface_id": surface_id, "script": "window.__cmuxHiddenScreenshotState || ''"}))
                or ""
            )
            == "green",
            timeout_s=3.0,
            label="hidden DOM mutation",
        )

        before_ws = _focused_workspace_id(c)
        before_surface = _focused_surface_id(c)
        sampled, red, green, _blue, _step = _screenshot_color_counts(c, surface_id)
        after_ws = _focused_workspace_id(c)
        after_surface = _focused_surface_id(c)

        _must(before_ws == visible_ws and after_ws == visible_ws, f"Screenshot changed workspace focus: before={before_ws} after={after_ws}")
        _must(
            before_surface == visible_surface and after_surface == visible_surface,
            f"Screenshot changed surface focus: before={before_surface} after={after_surface}",
        )
        _must(green > sampled * 0.75, f"Hidden screenshot should be current green frame: sampled={sampled} red={red} green={green}")
        _must(red < sampled * 0.10, f"Hidden screenshot is stale red frame: sampled={sampled} red={red} green={green}")

        c.select_workspace(browser_ws)

    print("PASS: hidden browser screenshot reflects current frame without stealing focus")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
