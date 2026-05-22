#!/usr/bin/env python3
"""Regression: tmux resize/layout round-trips must redraw cleanly inside cmux.

The bug report for #3118 is visual, not logical: tmux's pane model is correct, but after
layout-changing operations the embedded terminal can leave borders/cells in the wrong place.

We validate this through runtime behavior only:
  1. Launch plain tmux (`-f /dev/null`) inside a cmux terminal surface.
  2. Fill panes with deterministic output and hide the cursor to keep screenshots stable.
  3. Apply a real tmux layout/resize key sequence, then apply the inverse sequence.
  4. Capture panel PNGs and verify the terminal returns to the same pixels (within baseline noise).

If the bug reproduces, the intermediate snapshot changes a lot as expected, but the final
snapshot still differs materially from the original due to stale borders/cells.
"""

import os
import shlex
import struct
import sys
import time
import zlib
from pathlib import Path
from typing import Callable

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")


def _wait_for(pred: Callable[[], bool], timeout_s: float, step_s: float = 0.05) -> None:
    start = time.time()
    while time.time() - start < timeout_s:
        if pred():
            return
        time.sleep(step_s)
    raise cmuxError("Timed out waiting for condition")


def _wait_for_terminal_focus(c: cmux, panel_id: str, timeout_s: float = 6.0) -> None:
    start = time.time()
    panel_lower = panel_id.lower()
    while time.time() - start < timeout_s:
        try:
            c.activate_app()
        except Exception:
            pass

        try:
            if c.is_terminal_focused(panel_id):
                return
        except Exception:
            pass

        try:
            for _idx, sid, focused in c.list_surfaces():
                if sid.lower() == panel_lower and focused:
                    return
        except Exception:
            pass

        time.sleep(0.05)

    raise cmuxError(f"Timed out waiting for terminal focus: {panel_id}")


def _render_stats(c: cmux, panel_id: str) -> dict:
    stats = c.render_stats(panel_id)
    if not bool(stats.get("inWindow")):
        raise cmuxError(f"panel not in window: {panel_id} stats={stats}")
    return stats


def _wait_for_present_change(c: cmux, panel_id: str, baseline_present: int, timeout_s: float = 2.5) -> dict:
    last = {}

    def changed() -> bool:
        nonlocal last
        last = _render_stats(c, panel_id)
        return int(last.get("presentCount", 0) or 0) > baseline_present

    _wait_for(changed, timeout_s=timeout_s, step_s=0.05)
    return last


def _panel_snapshot_retry(c: cmux, panel_id: str, label: str, timeout_s: float = 3.0) -> dict:
    start = time.time()
    last_err: Exception | None = None
    while time.time() - start < timeout_s:
        try:
            return dict(c.panel_snapshot(panel_id, label=label) or {})
        except Exception as e:
            last_err = e
            if "Failed to capture panel image" not in str(e):
                raise
            time.sleep(0.05)
    raise cmuxError(f"Timed out waiting for panel_snapshot: panel_id={panel_id} label={label}: {last_err!r}")


def _read_png_rgba(path: Path) -> tuple[int, int, bytes]:
    data = path.read_bytes()
    signature = b"\x89PNG\r\n\x1a\n"
    if not data.startswith(signature):
        raise cmuxError(f"not a PNG: {path}")

    offset = len(signature)
    width = height = 0
    bit_depth = color_type = interlace = -1
    idat_chunks: list[bytes] = []

    while offset + 8 <= len(data):
        length = struct.unpack(">I", data[offset : offset + 4])[0]
        chunk_type = data[offset + 4 : offset + 8]
        chunk_start = offset + 8
        chunk_end = chunk_start + length
        chunk_data = data[chunk_start:chunk_end]
        offset = chunk_end + 4  # skip CRC

        if chunk_type == b"IHDR":
            width, height, bit_depth, color_type, _compression, _filter, interlace = struct.unpack(
                ">IIBBBBB", chunk_data
            )
        elif chunk_type == b"IDAT":
            idat_chunks.append(chunk_data)
        elif chunk_type == b"IEND":
            break

    if width <= 0 or height <= 0:
        raise cmuxError(f"missing PNG size: {path}")
    if bit_depth != 8 or interlace != 0 or color_type not in {2, 6}:
        raise cmuxError(
            f"unsupported PNG format: path={path} bit_depth={bit_depth} color_type={color_type} interlace={interlace}"
        )

    bpp = 4 if color_type == 6 else 3
    stride = width * bpp
    raw = zlib.decompress(b"".join(idat_chunks))

    expected = height * (stride + 1)
    if len(raw) != expected:
        raise cmuxError(f"unexpected PNG payload size: path={path} got={len(raw)} want={expected}")

    rows = bytearray(height * stride)

    def paeth(a: int, b: int, c: int) -> int:
        p = a + b - c
        pa = abs(p - a)
        pb = abs(p - b)
        pc = abs(p - c)
        if pa <= pb and pa <= pc:
            return a
        if pb <= pc:
            return b
        return c

    for y in range(height):
        row_start = y * (stride + 1)
        filter_type = raw[row_start]
        src = raw[row_start + 1 : row_start + 1 + stride]
        dst_off = y * stride
        prev_off = (y - 1) * stride

        for x in range(stride):
            left = rows[dst_off + x - bpp] if x >= bpp else 0
            up = rows[prev_off + x] if y > 0 else 0
            up_left = rows[prev_off + x - bpp] if y > 0 and x >= bpp else 0
            value = src[x]

            if filter_type == 0:
                out = value
            elif filter_type == 1:
                out = (value + left) & 0xFF
            elif filter_type == 2:
                out = (value + up) & 0xFF
            elif filter_type == 3:
                out = (value + ((left + up) // 2)) & 0xFF
            elif filter_type == 4:
                out = (value + paeth(left, up, up_left)) & 0xFF
            else:
                raise cmuxError(f"unsupported PNG filter {filter_type} in {path}")

            rows[dst_off + x] = out

    if color_type == 6:
        return width, height, bytes(rows)

    rgba = bytearray(width * height * 4)
    src_i = 0
    dst_i = 0
    while src_i < len(rows):
        rgba[dst_i] = rows[src_i]
        rgba[dst_i + 1] = rows[src_i + 1]
        rgba[dst_i + 2] = rows[src_i + 2]
        rgba[dst_i + 3] = 255
        src_i += 3
        dst_i += 4
    return width, height, bytes(rgba)


def _count_changed_pixels(path_a: Path, path_b: Path, threshold: int = 8) -> int:
    width_a, height_a, rgba_a = _read_png_rgba(path_a)
    width_b, height_b, rgba_b = _read_png_rgba(path_b)
    if (width_a, height_a) != (width_b, height_b):
        raise cmuxError(f"snapshot dimensions differ: {path_a}={width_a}x{height_a} {path_b}={width_b}x{height_b}")

    changed = 0
    i = 0
    count = min(len(rgba_a), len(rgba_b))
    while i + 3 < count:
        dr = abs(rgba_a[i] - rgba_b[i])
        dg = abs(rgba_a[i + 1] - rgba_b[i + 1])
        db = abs(rgba_a[i + 2] - rgba_b[i + 2])
        if dr + dg + db > threshold:
            changed += 1
        i += 4
    return changed


def _ratio(changed_pixels: int, width: int, height: int) -> float:
    return float(max(0, changed_pixels)) / float(max(1, width * height))


def _pane_script(prefix: str) -> str:
    return (
        "printf '\\033[0m\\033[40m\\033[97m\\033[2J\\033[H\\033[?25l'; "
        f"seq -f '{prefix}:%03g' 1 200; "
        "sleep 100000"
    )


def _run_shell(c: cmux, panel_id: str, command: str, wait_s: float = 0.12) -> None:
    c.send_surface(panel_id, command + "\n")
    time.sleep(wait_s)


def _launch_tmux(
    c: cmux,
    panel_id: str,
    *,
    socket_name: str,
    session_name: str,
    pane_scripts: list[str],
    setup_commands: list[str],
) -> None:
    tmux = f"tmux -L {shlex.quote(socket_name)} -f /dev/null"
    session_ref = shlex.quote(session_name)

    _run_shell(c, panel_id, f"{tmux} kill-server >/dev/null 2>&1 || true", wait_s=0.18)
    _run_shell(c, panel_id, f"{tmux} new-session -d -s {session_ref} {shlex.quote(pane_scripts[0])}", wait_s=0.18)

    common = [
        f"{tmux} set-option -t {session_ref} status off",
        f"{tmux} set-option -t {session_ref} display-time 0",
        f"{tmux} set-option -t {session_ref} bell-action none",
        f"{tmux} set-option -t {session_ref} pane-border-style fg=white",
        f"{tmux} set-option -t {session_ref} pane-active-border-style fg=white",
    ]
    for command in common + setup_commands:
        _run_shell(c, panel_id, command, wait_s=0.12)

    _run_shell(c, panel_id, f"exec {tmux} attach -t {session_ref}", wait_s=0.45)


def _prefixed_shortcut(c: cmux, combo: str, settle_s: float = 0.35) -> None:
    c.activate_app()
    c.simulate_shortcut("ctrl+b")
    time.sleep(0.06)
    c.simulate_shortcut(combo)
    time.sleep(settle_s)


def _assert_roundtrip_visual_stability(
    c: cmux,
    panel_id: str,
    *,
    label: str,
    apply_change: Callable[[], None],
    apply_revert: Callable[[], None],
    min_change_ratio: float = 0.02,
    max_roundtrip_ratio: float = 0.0025,
) -> None:
    baseline0 = _panel_snapshot_retry(c, panel_id, f"{label}_baseline0")
    time.sleep(0.25)
    baseline1 = _panel_snapshot_retry(c, panel_id, f"{label}_baseline1")

    width = int(baseline1["width"])
    height = int(baseline1["height"])
    if width <= 0 or height <= 0:
        raise cmuxError(f"invalid baseline snapshot size for {label}: {baseline1}")

    base0_path = Path(baseline0["path"])
    base1_path = Path(baseline1["path"])
    noise_px = _count_changed_pixels(base0_path, base1_path)
    noise_ratio = _ratio(noise_px, width, height)

    baseline_present = int(_render_stats(c, panel_id).get("presentCount", 0) or 0)
    apply_change()
    change_stats = _wait_for_present_change(c, panel_id, baseline_present)
    time.sleep(0.15)
    changed = _panel_snapshot_retry(c, panel_id, f"{label}_changed")
    changed_path = Path(changed["path"])
    changed_px = _count_changed_pixels(base1_path, changed_path)
    changed_ratio = _ratio(changed_px, width, height)

    required_change = max(min_change_ratio, noise_ratio * 6.0)
    if changed_ratio <= required_change:
        raise cmuxError(
            f"{label}: change step did not materially redraw.\n"
            f"  noise_ratio={noise_ratio:.5f}\n"
            f"  changed_ratio={changed_ratio:.5f}\n"
            f"  required_change={required_change:.5f}\n"
            f"  changed_present={change_stats.get('presentCount')}\n"
            f"  snapshots: {base0_path} {base1_path} {changed_path}"
        )

    apply_revert()
    reverted_present = int(change_stats.get("presentCount", 0) or 0)
    _wait_for_present_change(c, panel_id, reverted_present)
    time.sleep(0.15)
    final = _panel_snapshot_retry(c, panel_id, f"{label}_final")
    final_path = Path(final["path"])
    roundtrip_px = _count_changed_pixels(base1_path, final_path)
    roundtrip_ratio = _ratio(roundtrip_px, width, height)

    allowed_roundtrip = max(max_roundtrip_ratio, noise_ratio * 6.0)
    if roundtrip_ratio > allowed_roundtrip:
        raise cmuxError(
            f"{label}: round-trip left stale pixels behind.\n"
            f"  noise_ratio={noise_ratio:.5f}\n"
            f"  changed_ratio={changed_ratio:.5f}\n"
            f"  roundtrip_ratio={roundtrip_ratio:.5f}\n"
            f"  allowed_roundtrip={allowed_roundtrip:.5f}\n"
            f"  snapshots: {base0_path} {base1_path} {changed_path} {final_path}"
        )


def _new_workspace_with_panel(c: cmux) -> str:
    ws_id = c.new_workspace()
    c.select_workspace(ws_id)
    time.sleep(0.3)
    surfaces = c.list_surfaces()
    if not surfaces:
        raise cmuxError("expected initial surface")
    return next((sid for _i, sid, focused in surfaces if focused), surfaces[0][1])


def _run_layout_roundtrip_case(c: cmux, token: str) -> None:
    panel_id = _new_workspace_with_panel(c)
    socket_name = f"cmux3118-layout-{token}"
    session_name = f"cmux3118layout{token}"
    _launch_tmux(
        c,
        panel_id,
        socket_name=socket_name,
        session_name=session_name,
        pane_scripts=[_pane_script("A"), _pane_script("B"), _pane_script("C")],
        setup_commands=[
            f"tmux -L {shlex.quote(socket_name)} -f /dev/null split-window -h -t {shlex.quote(session_name)}:0 {shlex.quote(_pane_script('B'))}",
            f"tmux -L {shlex.quote(socket_name)} -f /dev/null split-window -v -t {shlex.quote(session_name)}:0.0 {shlex.quote(_pane_script('C'))}",
            f"tmux -L {shlex.quote(socket_name)} -f /dev/null select-layout -t {shlex.quote(session_name)}:0 tiled",
            f"tmux -L {shlex.quote(socket_name)} -f /dev/null select-pane -t {shlex.quote(session_name)}:0.0",
        ],
    )

    _wait_for_terminal_focus(c, panel_id)
    time.sleep(0.5)

    _assert_roundtrip_visual_stability(
        c,
        panel_id,
        label="tmux_layout",
        apply_change=lambda: _prefixed_shortcut(c, "opt+1"),
        apply_revert=lambda: _prefixed_shortcut(c, "opt+5"),
    )


def _run_resize_roundtrip_case(c: cmux, token: str) -> None:
    panel_id = _new_workspace_with_panel(c)
    socket_name = f"cmux3118-resize-{token}"
    session_name = f"cmux3118resize{token}"
    _launch_tmux(
        c,
        panel_id,
        socket_name=socket_name,
        session_name=session_name,
        pane_scripts=[_pane_script("L"), _pane_script("R")],
        setup_commands=[
            f"tmux -L {shlex.quote(socket_name)} -f /dev/null split-window -h -t {shlex.quote(session_name)}:0 {shlex.quote(_pane_script('R'))}",
            f"tmux -L {shlex.quote(socket_name)} -f /dev/null select-pane -t {shlex.quote(session_name)}:0.1",
        ],
    )

    _wait_for_terminal_focus(c, panel_id)
    time.sleep(0.5)

    _assert_roundtrip_visual_stability(
        c,
        panel_id,
        label="tmux_resize",
        apply_change=lambda: _prefixed_shortcut(c, "ctrl+left"),
        apply_revert=lambda: _prefixed_shortcut(c, "ctrl+right"),
    )


def main() -> int:
    token = str(int(time.time() * 1000))
    with cmux(SOCKET_PATH) as c:
        c.activate_app()
        time.sleep(0.2)
        _run_layout_roundtrip_case(c, token)
        _run_resize_roundtrip_case(c, token)

    print("PASS: tmux resize/layout round-trips redraw cleanly")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
