"""screen-eval-marker-locate finds the host's latency marker where the viewer draws it, at its true cell size.

Builds marker-locate.swift with swiftc and runs it on synthetic screenshots: the marker as
cmux-rd-host/scripts/mac-marker draws it (cells 0..15 the counter's bits, least significant first, white
for 1 and black for 0; cells 16..19 white, black, white, black; then four cells of gray click pad), on
a background. macOS only (CoreGraphics); elsewhere the tests skip.

    python3 scripts/measure/screen-stream-eval/test_marker_locate.py
"""
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib

HERE = Path(__file__).resolve().parent
COUNTER = 0xA5C3  # bits 0 and 1 set, so cell 0 is white; bit 15 set, so cell 15 is white beside guard 16
WHITE, BLACK, PAD = 255, 0, 128  # NSColor.white, .black and .gray, as mac-marker fills them


def write_png(path: Path, width: int, height: int, pixels: bytearray) -> None:
    """An 8-bit RGB PNG of `pixels` (one gray byte per pixel), with no colour profile."""
    raw = bytearray()
    for y in range(height):
        raw.append(0)
        for v in pixels[y * width:(y + 1) * width]:
            raw += bytes((v, v, v))

    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
                     + chunk(b"IDAT", zlib.compress(bytes(raw), 6)) + chunk(b"IEND", b""))


def screenshot(path: Path, width: int, height: int, origin: tuple[int, int], cell: int,
               above: int, below: int) -> None:
    """The marker at `origin` with `cell` px cells; rows above the marker's bottom are `above` (a menu
    bar), the rest `below` (the viewer's content)."""
    ox, oy = origin
    pixels = bytearray(above if y < oy + cell else below for y in range(height) for _ in range(width))
    for i in range(24):
        if i >= 20:
            value = PAD
        elif i >= 16:
            value = WHITE if i % 2 == 0 else BLACK
        else:
            value = WHITE if COUNTER >> i & 1 else BLACK
        for y in range(max(0, oy), min(height, oy + cell)):
            start, end = max(0, ox + i * cell), min(width, ox + (i + 1) * cell)
            pixels[y * width + start:y * width + end] = bytes((value,)) * max(0, end - start)
    write_png(path, width, height, pixels)


@unittest.skipUnless(sys.platform == "darwin" and shutil.which("swiftc"), "needs macOS CoreGraphics and swiftc")
class MarkerLocateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.work = Path(tempfile.mkdtemp(prefix="marker-locate-test."))
        cls.tool = cls.work / "screen-eval-marker-locate"
        subprocess.run(["swiftc", "-O", "-o", str(cls.tool), str(HERE / "marker-locate.swift")], check=True)

    @classmethod
    def tearDownClass(cls) -> None:
        shutil.rmtree(cls.work, ignore_errors=True)

    def locate(self, name: str, width: int, height: int, origin: tuple[int, int], cell: int,
               above: int, below: int) -> str:
        png = self.work / f"{name}.png"
        screenshot(png, width, height, origin, cell, above, below)
        done = subprocess.run([str(self.tool), str(png)], capture_output=True, text=True, timeout=120)
        self.assertEqual(done.returncode, 0, done.stderr)
        return done.stdout.strip()

    def test_marker_at_left_edge_keeps_its_cell_size(self) -> None:
        # The fleet case: Screen Sharing shows the host's display from x 0, below a 30 px menu bar.
        # Before the fix: "origin 18,30 cell 31 at 700,45", and observe read every cell off centre.
        self.assertEqual(self.locate("left-edge", 1280, 720, (0, 30), 32, above=236, below=31),
                         "origin 0,30 cell 32 at 704,46")

    def test_marker_at_top_left_corner(self) -> None:
        self.assertEqual(self.locate("corner", 1280, 720, (0, 0), 32, above=236, below=31),
                         "origin 0,0 cell 32 at 704,16")

    def test_scaled_marker_inside_the_image(self) -> None:
        # A viewer that scales the host's 32 px cells to 26 px, in a window at 100,200 on a dark desktop.
        self.assertEqual(self.locate("scaled", 1280, 720, (100, 200), 26, above=31, below=236),
                         "origin 100,200 cell 26 at 672,213")


if __name__ == "__main__":
    unittest.main()
