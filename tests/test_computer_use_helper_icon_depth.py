#!/usr/bin/env python3
"""The Computer Use helper icon ships 8-bit renditions.

Icon Composer exports 16 bits per channel. The icon ships twice, in the app's
Resources and as the helper's AppIcon, so 16-bit renditions cost 2.06 MB per
copy where 8-bit ones in the same Display P3 profile cost 0.72 MB.
"""

from __future__ import annotations

import struct
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ICON = ROOT / "Resources/ComputerUseHelperIcon.icns"
GENERATOR = ROOT / "scripts/generate-computer-use-helper-icon.swift"
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


def png_renditions(data: bytes) -> dict[str, bytes]:
    if data[:4] != b"icns":
        raise AssertionError("not an icns file")
    renditions: dict[str, bytes] = {}
    offset = 8
    while offset < len(data):
        if offset + 8 > len(data):
            raise AssertionError("truncated icns element header")
        kind, length = struct.unpack(">4sI", data[offset : offset + 8])
        if length < 8:
            raise AssertionError(f"icns element {kind!r} has length {length}")
        body = data[offset + 8 : offset + length]
        if body.startswith(PNG_SIGNATURE):
            renditions[kind.decode("ascii")] = body
        offset += length
    return renditions


def bit_depth(png: bytes) -> int:
    # IHDR is the first chunk: width, height, then bit depth.
    if png[12:16] != b"IHDR":
        raise AssertionError("PNG without a leading IHDR chunk")
    return png[24]


class ComputerUseHelperIconDepthTests(unittest.TestCase):
    def test_png_renditions_are_8_bit(self) -> None:
        renditions = png_renditions(ICON.read_bytes())
        self.assertIn("ic10", renditions, "missing the 1024 px rendition")
        depths = {kind: bit_depth(png) for kind, png in renditions.items()}
        self.assertEqual({kind: 8 for kind in depths}, depths)

    def test_generator_writes_8_bit_renditions(self) -> None:
        source = GENERATOR.read_text(encoding="utf-8")
        self.assertIn("bitsPerComponent: 8", source)


if __name__ == "__main__":
    unittest.main()
