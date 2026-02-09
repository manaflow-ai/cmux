#!/usr/bin/env python3
"""
Regression test: creating a new terminal surface (nested tab) inside an existing split
must become interactive and render output immediately, without requiring a focus toggle.

Bug: after many splits, creating a new tab could show only initial output (e.g. "Last login")
and then appear "frozen" until the user alt-tabs or changes pane focus. Input would be
buffered and only appear after refocus.

We validate rendering by:
  1) Taking two baseline screenshots (to estimate noise like cursor blink).
  2) Typing a command that prints many lines.
  3) Taking an "after" screenshot and asserting the focused panel region changed
     materially vs baseline.
"""

import os
import struct
import sys
import time
import zlib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmuxterm-debug.sock")


def _take_screenshot(c: cmux, label: str) -> Path:
    resp = c._send_command(f"screenshot {label}")
    if not resp.startswith("OK "):
        raise cmuxError(f"screenshot failed: {resp}")
    parts = resp.split(" ", 2)
    if len(parts) < 3:
        raise cmuxError(f"unexpected screenshot response: {resp}")
    path = Path(parts[2])
    if not path.exists():
        raise cmuxError(f"screenshot path missing: {path}")
    return path


def _wait_for_terminal_focus(c: cmux, panel_id: str, timeout_s: float = 2.0) -> None:
    start = time.time()
    while time.time() - start < timeout_s:
        if c.is_terminal_focused(panel_id):
            return
        time.sleep(0.05)
    raise cmuxError(f"Timed out waiting for terminal focus: {panel_id}")


# ---------------------------------------------------------------------------
# Minimal PNG decode (RGB/RGBA, 8-bit, non-interlaced) for diffing screenshots.
# ---------------------------------------------------------------------------


def _paeth(a: int, b: int, c: int) -> int:
    p = a + b - c
    pa = abs(p - a)
    pb = abs(p - b)
    pc = abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    if pb <= pc:
        return b
    return c


def _unfilter_scanline(ftype: int, row: bytearray, prev: bytes, bpp: int) -> None:
    if ftype == 0:
        return
    if ftype == 1:  # Sub
        for i in range(len(row)):
            left = row[i - bpp] if i >= bpp else 0
            row[i] = (row[i] + left) & 0xFF
        return
    if ftype == 2:  # Up
        for i in range(len(row)):
            up = prev[i] if prev else 0
            row[i] = (row[i] + up) & 0xFF
        return
    if ftype == 3:  # Average
        for i in range(len(row)):
            left = row[i - bpp] if i >= bpp else 0
            up = prev[i] if prev else 0
            row[i] = (row[i] + ((left + up) >> 1)) & 0xFF
        return
    if ftype == 4:  # Paeth
        for i in range(len(row)):
            left = row[i - bpp] if i >= bpp else 0
            up = prev[i] if prev else 0
            up_left = prev[i - bpp] if (prev and i >= bpp) else 0
            row[i] = (row[i] + _paeth(left, up, up_left)) & 0xFF
        return
    raise cmuxError(f"unsupported PNG filter type: {ftype}")


def _read_png_rgba(path: Path) -> tuple[int, int, bytes]:
    data = path.read_bytes()
    if not data.startswith(b"\x89PNG\r\n\x1a\n"):
        raise cmuxError(f"not a PNG: {path}")

    i = 8
    width = height = None
    bit_depth = color_type = None
    interlace = None
    idat = bytearray()

    while i + 8 <= len(data):
        length = struct.unpack(">I", data[i:i + 4])[0]
        i += 4
        ctype = data[i:i + 4]
        i += 4
        chunk = data[i:i + length]
        i += length
        i += 4  # CRC

        if ctype == b"IHDR":
            width = struct.unpack(">I", chunk[0:4])[0]
            height = struct.unpack(">I", chunk[4:8])[0]
            bit_depth = chunk[8]
            color_type = chunk[9]
            interlace = chunk[12]
        elif ctype == b"IDAT":
            idat.extend(chunk)
        elif ctype == b"IEND":
            break

    if width is None or height is None:
        raise cmuxError(f"PNG missing IHDR: {path}")
    if bit_depth != 8:
        raise cmuxError(f"unsupported PNG bit depth={bit_depth}: {path}")
    if interlace != 0:
        raise cmuxError(f"unsupported PNG interlace={interlace}: {path}")
    if color_type not in (2, 6):  # RGB or RGBA
        raise cmuxError(f"unsupported PNG color type={color_type}: {path}")

    raw = zlib.decompress(bytes(idat))
    src_bpp = 4 if color_type == 6 else 3
    stride = width * src_bpp
    expected = height * (1 + stride)
    if len(raw) < expected:
        raise cmuxError(f"truncated PNG data: {path} (got={len(raw)} expected>={expected})")

    out = bytearray()

    pos = 0
    prev = bytes([0] * stride)
    for _y in range(height):
        ftype = raw[pos]
        pos += 1
        row = bytearray(raw[pos:pos + stride])
        pos += stride
        _unfilter_scanline(ftype, row, prev, src_bpp)
        prev = bytes(row)
        if color_type == 6:
            out.extend(row)
        else:
            # Expand RGB -> RGBA (opaque)
            for x in range(0, len(row), 3):
                out.extend(row[x:x + 3])
                out.append(255)

    return width, height, bytes(out)


def _crop_rgba(buf: bytes, img_w: int, img_h: int, x: int, y: int, w: int, h: int) -> bytes:
    # x,y are top-left in image coordinates.
    x0 = max(0, min(img_w, x))
    y0 = max(0, min(img_h, y))
    x1 = max(0, min(img_w, x0 + max(0, w)))
    y1 = max(0, min(img_h, y0 + max(0, h)))
    cw = max(0, x1 - x0)
    ch = max(0, y1 - y0)
    if cw == 0 or ch == 0:
        return b""

    out = bytearray(cw * ch * 4)
    row_bytes = cw * 4
    for row in range(ch):
        src = ((y0 + row) * img_w + x0) * 4
        dst = row * row_bytes
        out[dst:dst + row_bytes] = buf[src:src + row_bytes]
    return bytes(out)


def _diff_ratio(a: bytes, b: bytes) -> float:
    if len(a) != len(b):
        raise cmuxError(f"diff buffers differ in length: {len(a)} vs {len(b)}")
    if not a:
        return 0.0
    changed = 0
    # byte-level diff is sufficient; we're looking for large, persistent changes.
    for i in range(len(a)):
        if a[i] != b[i]:
            changed += 1
    return changed / float(len(a))


def _focused_panel_rect(c: cmux, panel_id: str) -> dict:
    payload = c.layout_debug()
    selected = payload.get("selectedPanels") or []
    for row in selected:
        if (row.get("panelId") or "").lower() == panel_id.lower():
            frame = row.get("viewFrame")
            if not frame:
                raise cmuxError(f"layout_debug missing viewFrame for panel {panel_id}")
            return frame
    raise cmuxError(f"panel not found in selectedPanels: {panel_id}")


def main() -> int:
    with cmux(SOCKET_PATH) as c:
        c.activate_app()
        time.sleep(0.2)

        c.new_workspace()
        time.sleep(0.3)

        # Create a dense layout (similar to "4 splits") to exercise attach/focus races.
        for _ in range(4):
            c.new_split("right")
            time.sleep(0.25)

        panes = c.list_panes()
        if len(panes) < 2:
            raise cmuxError(f"expected multiple panes, got: {panes}")

        mid = len(panes) // 2
        c.focus_pane(mid)
        time.sleep(0.2)

        # Create a new nested tab in the focused pane.
        new_id = c.new_surface(panel_type="terminal")
        time.sleep(0.35)

        # Ensure the app/key window is active before asserting first-responder focus.
        c.activate_app()
        time.sleep(0.2)

        # The new surface should be focused and interactive immediately.
        _wait_for_terminal_focus(c, new_id, timeout_s=2.0)

        frame = _focused_panel_rect(c, new_id)
        # Inset a bit to avoid edges/dividers that can change due to rounding.
        inset = 8
        rect = {
            "x": float(frame["x"]) + inset,
            "y": float(frame["y"]) + inset,
            "width": max(0.0, float(frame["width"]) - inset * 2),
            "height": max(0.0, float(frame["height"]) - inset * 2),
        }

        # Baseline screenshots to estimate noise (cursor blink, etc).
        ss0 = _take_screenshot(c, "newtab_baseline0")
        time.sleep(0.25)
        ss1 = _take_screenshot(c, "newtab_baseline1")

        # Type a command that prints many lines (large visual delta).
        c.simulate_type("for i in {1..40}; do echo CMUX_DRAW_$i; done")
        c.simulate_shortcut("enter")
        time.sleep(0.45)

        ss2 = _take_screenshot(c, "newtab_after")

        w0, h0, p0 = _read_png_rgba(ss0)
        w1, h1, p1 = _read_png_rgba(ss1)
        w2, h2, p2 = _read_png_rgba(ss2)
        if (w0, h0) != (w1, h1) or (w0, h0) != (w2, h2):
            raise cmuxError(f"screenshot dims differ: {(w0,h0)} {(w1,h1)} {(w2,h2)}")

        # Convert window coords (origin bottom-left) -> image coords (origin top-left).
        rx = int(round(rect["x"]))
        ry = int(round(float(h0) - (rect["y"] + rect["height"])))
        rw = int(round(rect["width"]))
        rh = int(round(rect["height"]))

        c0 = _crop_rgba(p0, w0, h0, rx, ry, rw, rh)
        c1 = _crop_rgba(p1, w1, h1, rx, ry, rw, rh)
        c2 = _crop_rgba(p2, w2, h2, rx, ry, rw, rh)
        if not c0 or not c2:
            raise cmuxError(f"cropped region empty (frame={frame}, rect={rect}, img={(w0,h0)})")

        noise = _diff_ratio(c0, c1)
        change = _diff_ratio(c0, c2)

        # Require a material visual change relative to baseline noise.
        threshold = max(0.01, noise * 4.0)
        if change <= threshold:
            # Diagnostics: try a focus toggle and capture evidence; in the bug, this "unfreezes".
            try:
                other = 0 if mid != 0 else min(1, len(panes) - 1)
                c.focus_pane(other)
                time.sleep(0.25)
                c.focus_pane(mid)
                time.sleep(0.35)
                ss3 = _take_screenshot(c, "newtab_after_refocus")
                w3, h3, p3 = _read_png_rgba(ss3)
                if (w3, h3) == (w0, h0):
                    c3 = _crop_rgba(p3, w3, h3, rx, ry, rw, rh)
                    refocus_change = _diff_ratio(c0, c3) if c3 else 0.0
                else:
                    refocus_change = 0.0
            except Exception:
                refocus_change = -1.0

            raise cmuxError(
                "New tab did not render output immediately after typing.\n"
                f"  noise_ratio={noise:.5f}\n"
                f"  change_ratio={change:.5f} (threshold={threshold:.5f})\n"
                f"  refocus_change_ratio={refocus_change:.5f}\n"
                f"  screenshots: {ss0} {ss1} {ss2}"
            )

    print("PASS: new tab renders immediately after many splits")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
