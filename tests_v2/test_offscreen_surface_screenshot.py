#!/usr/bin/env python3
"""
Proof for `debug.surface.screenshot`: focus-free, occlusion-proof,
native-resolution ground-truth capture of a terminal surface.

Drives a tagged cmux dev instance over its debug socket only. It launches
NOTHING except a tiny borderless overlay window (swift-interpreted helper)
used to fully occlude the tagged cmux window; the overlay ignores mouse
events, never activates, and is killed on exit.

Checks, in order:
  1. writes a distinctive pattern (red/green/blue background bands plus a
     text sentinel) to the focused pane and waits for it via read_text
  2. captures once to learn the window frame, then covers that frame with
     the overlay and waits until the RPC itself reports
     window_occlusion_visible == false (the compositor's own occlusion state)
  3. captures while fully occluded AND while the app is not active, asserts
     the capture is native 2x (Retina), decodes the PNG (pure stdlib), and
     verifies the pattern bands are present
  4. captures twice and asserts the pixels are byte-identical (determinism)
  5. captures with scale=1 and asserts logical-size output

Usage:
    python3 tests_v2/test_offscreen_surface_screenshot.py --socket /tmp/cmux-debug-<tag>.sock

Refuses to run against /tmp/cmux-debug.sock (the user's own instance).
"""

import argparse
import os
import struct
import subprocess
import sys
import tempfile
import time
import zlib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError

SENTINEL = "OSCAP-SENTINEL-7391"

OVERLAY_SWIFT = r'''
import AppKit

let values = CommandLine.arguments.dropFirst().compactMap(Double.init)
guard values.count == 4 else { fatalError("usage: overlay x y w h") }
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let frame = NSRect(x: values[0], y: values[1], width: values[2], height: values[3])
let window = NSWindow(
    contentRect: frame,
    styleMask: [.borderless],
    backing: .buffered,
    defer: false
)
window.level = .floating
window.backgroundColor = .black
window.isOpaque = true
window.ignoresMouseEvents = true
window.collectionBehavior = [.canJoinAllSpaces, .stationary]
window.orderFrontRegardless()
print("OVERLAY-READY")
FileHandle.standardOutput.synchronizeFile()
app.run()
'''


def decode_png_rgba(path: str):
    """Minimal PNG decoder (stdlib only): 8-bit RGB/RGBA, non-interlaced.
    Returns (width, height, rows) where rows[y] is a bytearray of RGBA."""
    data = Path(path).read_bytes()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG"
    pos = 8
    width = height = None
    bit_depth = color_type = None
    idat = bytearray()
    while pos < len(data):
        (length,) = struct.unpack(">I", data[pos:pos + 4])
        ctype = data[pos + 4:pos + 8]
        chunk = data[pos + 8:pos + 8 + length]
        pos += 12 + length
        if ctype == b"IHDR":
            width, height, bit_depth, color_type, _, _, interlace = struct.unpack(
                ">IIBBBBB", chunk
            )
            assert bit_depth == 8, f"unsupported bit depth {bit_depth}"
            assert color_type in (2, 6), f"unsupported color type {color_type}"
            assert interlace == 0, "interlaced PNG unsupported"
        elif ctype == b"IDAT":
            idat.extend(chunk)
        elif ctype == b"IEND":
            break
    raw = zlib.decompress(bytes(idat))
    channels = 4 if color_type == 6 else 3
    stride = width * channels
    rows = []
    prev = bytearray(stride)
    offset = 0
    for _ in range(height):
        filter_type = raw[offset]
        offset += 1
        line = bytearray(raw[offset:offset + stride])
        offset += stride
        if filter_type == 1:  # Sub
            for i in range(channels, stride):
                line[i] = (line[i] + line[i - channels]) & 0xFF
        elif filter_type == 2:  # Up
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 0xFF
        elif filter_type == 3:  # Average
            for i in range(stride):
                left = line[i - channels] if i >= channels else 0
                line[i] = (line[i] + ((left + prev[i]) >> 1)) & 0xFF
        elif filter_type == 4:  # Paeth
            for i in range(stride):
                left = line[i - channels] if i >= channels else 0
                up = prev[i]
                ul = prev[i - channels] if i >= channels else 0
                p = left + up - ul
                pa, pb, pc = abs(p - left), abs(p - up), abs(p - ul)
                if pa <= pb and pa <= pc:
                    pred = left
                elif pb <= pc:
                    pred = up
                else:
                    pred = ul
                line[i] = (line[i] + pred) & 0xFF
        prev = line
        if channels == 3:
            rgba = bytearray()
            for i in range(0, stride, 3):
                rgba.extend(line[i:i + 3])
                rgba.append(255)
            rows.append(rgba)
        else:
            rows.append(line)
    return width, height, rows


def count_band_pixels(rows, classify):
    return sum(
        1
        for line in rows
        for i in range(0, len(line), 4)
        if classify(line[i], line[i + 1], line[i + 2])
    )


def is_red(r, g, b):
    return r > 170 and g < 130 and b < 120


def is_green(r, g, b):
    return g > 150 and r < 160 and b < 120


def is_blue(r, g, b):
    return b > 150 and r < 120 and g < 130


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--socket", required=True, help="Tagged debug socket path")
    parser.add_argument(
        "--out-dir",
        default="",
        help="Directory for evidence PNGs (default: mkdtemp)",
    )
    args = parser.parse_args()

    if os.path.realpath(args.socket) == "/tmp/cmux-debug.sock":
        print("FAIL: refusing to run against the user's default socket", file=sys.stderr)
        return 2

    out_dir = Path(args.out_dir) if args.out_dir else Path(
        tempfile.mkdtemp(prefix="oscap-proof-")
    )
    out_dir.mkdir(parents=True, exist_ok=True)

    c = cmux(args.socket)
    c.connect()
    overlay = None
    overlay_src = out_dir / "overlay.swift"
    failures = []

    def check(name, ok, detail=""):
        status = "ok" if ok else "FAIL"
        print(f"  [{status}] {name}" + (f" ({detail})" if detail else ""))
        if not ok:
            failures.append(name)

    try:
        surfaces = c.list_surfaces()
        if not surfaces:
            print("FAIL: no surfaces in the current workspace", file=sys.stderr)
            return 2
        panel = surfaces[0][1]

        # 1. Distinctive pattern: 4 rows each of red/green/blue background
        # bands (truecolor SGR over spaces) plus a text sentinel; hide the
        # cursor so repeated captures are pixel-identical.
        print("== writing pattern")
# NOTE: the client's send unescaper turns \\n into a raw newline and
        # passes unknown escapes (\\e) through, so printf-level newlines are
        # written as \\\\n to survive as printf's own \n escape.
        script = (
            "clear; "
            "for i in 1 2 3 4; do printf '\\e[48;2;255;0;0m%80s\\e[0m\\\\n' ''; done; "
            "for i in 1 2 3 4; do printf '\\e[48;2;0;255;0m%80s\\e[0m\\\\n' ''; done; "
            "for i in 1 2 3 4; do printf '\\e[48;2;0;0;255m%80s\\e[0m\\\\n' ''; done; "
            f"printf '{SENTINEL}\\\\n'; printf '\\e[?25l'"
        )
        c.send_surface(panel, script + "\\n")
        deadline = time.time() + 15
        while time.time() < deadline:
            if SENTINEL in c.read_terminal_text(panel):
                break
            time.sleep(0.2)
        else:
            print("FAIL: sentinel never appeared in read_text", file=sys.stderr)
            return 2

        # 2. Learn the window frame from a first capture.
        print("== baseline capture (window frame discovery)")
        baseline = c.surface_screenshot(
            panel, path=str(out_dir / "baseline.png")
        )
        frame = baseline.get("window_frame") or {}
        if not frame:
            print("FAIL: capture returned no window_frame", file=sys.stderr)
            return 2
        print(f"   window_frame={frame} native_scale={baseline.get('native_scale')}")

        # 3. Fully occlude that frame with a floating overlay (margin on every
        # side), then wait for the compositor to report the window occluded.
        print("== occluding window with overlay")
        overlay_src.write_text(OVERLAY_SWIFT)
        margin = 40
        overlay = subprocess.Popen(
            [
                "swift", str(overlay_src),
                str(frame["x"] - margin), str(frame["y"] - margin),
                str(frame["width"] + 2 * margin), str(frame["height"] + 2 * margin),
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
        assert overlay.stdout is not None
        ready_line = overlay.stdout.readline().strip()
        if ready_line != "OVERLAY-READY":
            print(f"FAIL: overlay helper did not start ({ready_line!r})", file=sys.stderr)
            return 2

        occluded = None
        deadline = time.time() + 20
        while time.time() < deadline:
            probe = c.surface_screenshot(
                panel, path=str(out_dir / "occluded.png")
            )
            if not probe.get("window_occlusion_visible", True):
                occluded = probe
                break
            time.sleep(0.5)
        if occluded is None:
            print(
                "FAIL: window never reported occluded; is something moving the overlay?",
                file=sys.stderr,
            )
            return 2

        # 4. The occluded, non-frontmost capture is the proof.
        print("== verifying occluded capture")
        check(
            "window fully occluded at capture time",
            occluded.get("window_occlusion_visible") is False,
        )
        check("app not active at capture time", occluded.get("app_active") is False)
        check(
            "capture is native 2x",
            float(occluded.get("native_scale", 0)) == 2.0
            and float(occluded.get("scale", 0)) == 2.0,
            f"scale={occluded.get('scale')}",
        )
        check(
            "pixel dims are 2x logical dims",
            occluded.get("width_px")
            == round(occluded.get("points_width", 0) * 2)
            and occluded.get("height_px")
            == round(occluded.get("points_height", 0) * 2),
            f"{occluded.get('width_px')}x{occluded.get('height_px')} px vs "
            f"{occluded.get('points_width')}x{occluded.get('points_height')} pt",
        )
        check(
            "color space tagged display-p3",
            occluded.get("color_space") == "display-p3",
        )

        width, height, rows = decode_png_rgba(occluded["path"])
        check(
            "decoded PNG matches reported dims",
            width == occluded.get("width_px") and height == occluded.get("height_px"),
        )
        # Each band is 4 rows x 80 cols of solid background. Expect a
        # substantial pixel count per color (thousands of device pixels).
        min_band = 80 * 4 * 40  # well under the true count, well over noise
        red = count_band_pixels(rows, is_red)
        green = count_band_pixels(rows, is_green)
        blue = count_band_pixels(rows, is_blue)
        check("red band present", red > min_band, f"{red} px")
        check("green band present", green > min_band, f"{green} px")
        check("blue band present", blue > min_band, f"{blue} px")

        # 5. Determinism: two occluded captures decode to identical pixels.
        print("== verifying determinism")
        again = c.surface_screenshot(panel, path=str(out_dir / "occluded-2.png"))
        _, _, rows2 = decode_png_rgba(again["path"])
        check(
            "repeat capture is pixel-identical",
            rows == rows2,
        )

        # 6. Explicit --scale 1 produces logical-resolution output.
        print("== verifying --scale 1")
        one = c.surface_screenshot(
            panel, scale=1, path=str(out_dir / "occluded-1x.png")
        )
        check(
            "scale=1 halves pixel dims",
            one.get("width_px") == round(one.get("points_width", 0))
            and one.get("height_px") == round(one.get("points_height", 0)),
            f"{one.get('width_px')}x{one.get('height_px')} px",
        )
    finally:
        if overlay is not None:
            overlay.terminate()
            try:
                overlay.wait(timeout=5)
            except subprocess.TimeoutExpired:
                overlay.kill()
        c.close()

    print()
    print(f"evidence: {out_dir}")
    if failures:
        print(f"FAIL: {len(failures)} check(s) failed: {', '.join(failures)}")
        return 1
    print("PASS: occluded, non-frontmost, native-2x, Display P3, deterministic")
    return 0


if __name__ == "__main__":
    sys.exit(main())
