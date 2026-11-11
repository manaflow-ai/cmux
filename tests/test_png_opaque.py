#!/usr/bin/env python3
"""scripts/ci/png_opaque.py: App Store screenshots lose their alpha channel and no pixel.

App Store Connect refuses a screenshot with an alpha channel; `simctl io screenshot` writes RGBA.
Run: python3 -I THIS.
"""
import pathlib
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib

ROOT = pathlib.Path(__file__).resolve().parents[1]
HELPER = ROOT / "scripts/ci/png_opaque.py"
SCRIPT = ROOT / "scripts/ci/cmux-next-ios-sim.sh"
sys.path.insert(0, str(HELPER.parent))
import png_opaque  # noqa: E402


def chunk(kind, body):
    return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF)


def png(width, height, pixels, color=6, filters=(0,)):
    """A PNG of `pixels` (bytes, 4 or 3 per pixel), each row with the next filter type in turn."""
    bpp = 4 if color == 6 else 3
    stride = width * bpp
    rows, prev = [], bytes(stride)
    for y in range(height):
        line = pixels[y * stride:(y + 1) * stride]
        kind = filters[y % len(filters)]
        enc = bytearray(stride)
        for i in range(stride):
            a = line[i - bpp] if i >= bpp else 0
            b = prev[i]
            c = prev[i - bpp] if i >= bpp else 0
            pred = {0: 0, 1: a, 2: b, 3: (a + b) >> 1}.get(kind)
            if kind == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pred = a if pa <= pb and pa <= pc else b if pb <= pc else c
            enc[i] = (line[i] - pred) & 0xFF
        rows.append(bytes([kind]) + bytes(enc))
        prev = line
    ihdr = struct.pack(">IIBBBBB", width, height, 8, color, 0, 0, 0)
    return png_opaque.SIGNATURE + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(b"".join(rows))) + chunk(b"IEND", b"")


def decode_rgb(data):
    header = idat = None
    idat = b""
    for kind, body in png_opaque.chunks(data):
        if kind == b"IHDR":
            header = struct.unpack(">IIBBBBB", body)
        elif kind == b"IDAT":
            idat += body
    width, height, _, color, _, _, _ = header
    return color, bytes(png_opaque.unfilter(zlib.decompress(idat), width, height, 3 if color == 2 else 4))


class PngOpaqueTest(unittest.TestCase):
    def setUp(self):
        self.width, self.height = 7, 10
        self.rgb = bytes((x * 37 + y * 11 + k * 5) & 0xFF for y in range(self.height) for x in range(self.width) for k in range(3))
        self.rgba = b"".join(self.rgb[i:i + 3] + b"\xff" for i in range(0, len(self.rgb), 3))

    def run_helper(self, data):
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp) / "shot.png"
            path.write_bytes(data)
            p = subprocess.run([sys.executable, "-I", str(HELPER), str(path)], capture_output=True, text=True)
            return p, path.read_bytes()

    def test_opaque_rgba_becomes_rgb_with_the_same_pixels_under_every_filter(self):
        p, out = self.run_helper(png(self.width, self.height, self.rgba, filters=(0, 1, 2, 3, 4)))
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(decode_rgb(out), (2, self.rgb))

    def test_rgb_is_left_as_it_is(self):
        data = png(self.width, self.height, self.rgb, color=2)
        p, out = self.run_helper(data)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(out, data)

    def test_a_see_through_pixel_is_refused_and_the_file_kept(self):
        rgba = bytearray(self.rgba)
        rgba[7] = 128
        data = png(self.width, self.height, bytes(rgba))
        p, out = self.run_helper(data)
        self.assertEqual(p.returncode, 1)
        self.assertIn("not fully opaque", p.stderr)
        self.assertEqual(out, data)

    def test_step_script_flattens_app_store_shots(self):
        self.assertIn("python3 -I scripts/ci/png_opaque.py", SCRIPT.read_text())


if __name__ == "__main__":
    unittest.main()
