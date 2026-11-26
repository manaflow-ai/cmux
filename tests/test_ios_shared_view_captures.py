#!/usr/bin/env python3
"""Transport checks only; synthetic PNGs here are never render evidence."""
from __future__ import annotations

import base64
import hashlib
import importlib.util
import struct
import tempfile
import unittest
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("captures", ROOT / "scripts/ci/ios_shared_view_captures.py")
captures = importlib.util.module_from_spec(spec)
spec.loader.exec_module(captures)


def png_chunk(kind, payload):
    return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload))


PNG = (b"\x89PNG\r\n\x1a\n"
       + png_chunk(b"IHDR", struct.pack(">IIBBBBB", 128, 128, 8, 2, 0, 0, 0))
       + png_chunk(b"IDAT", zlib.compress((b"\0" + bytes(range(128)) * 3) * 128))
       + png_chunk(b"IEND", b""))


def stream(png=PNG):
    encoded = base64.b64encode(png).decode()
    lines = []
    for name in captures.NAMES:
        lines.append(f"RUNNER: B8B_PNG_BEGIN {name} {hashlib.sha256(png).hexdigest()} {len(encoded)}\n")
        for offset in range(0, len(encoded), 240):
            lines.append(f"RUNNER: B8B_PNG_CHUNK {name} {offset} {encoded[offset:offset + 240]}\n")
        lines.append(f"RUNNER: B8B_PNG_END {name}\n")
    return lines


class CaptureTests(unittest.TestCase):
    def test_real_png_round_trip_with_duplicate_console_delivery(self):
        lines = stream()
        result = captures.screenshots([line for line in lines for _ in range(2)])
        self.assertEqual(set(result), set(captures.NAMES))
        for png, metadata in result.values():
            self.assertEqual(png, PNG)
            self.assertEqual(metadata["width"], 128)

    def test_missing_or_truncated_chunks_fail(self):
        for lines in ([], stream()[:-1], stream()[:1] + stream()[2:],
                      [line[:100] + "\n" for line in stream()]):
            with self.subTest(lines=len(lines)), self.assertRaises(ValueError):
                captures.screenshots(lines)

    def test_corrupt_payload_fails_hash(self):
        lines = stream()
        lines[1] = lines[1].replace("iVBOR", "jVBOR")
        with self.assertRaisesRegex(ValueError, "hash mismatch"):
            captures.screenshots(lines)

    def test_non_png_and_oversized_declarations_fail(self):
        with self.assertRaises(ValueError):
            captures.screenshots(stream(b"not a PNG"))
        lines = stream()
        lines[0] = f"B8B_PNG_BEGIN {captures.NAMES[0]} {'0' * 64} {captures.MAX_ENCODED + 1}\n"
        with self.assertRaises(ValueError):
            captures.screenshots(lines)

    def test_only_executed_passing_render_test_is_accepted(self):
        case = '<testcase classname="B8bIOSHarnessUITests" name="testSharedViewsRenderInIOSHarness">{}</testcase>'
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "junit.xml"
            for content in ("", case.format("<skipped/>"), case.format("<failure/>"),
                            '<testcase classname="Other" name="test"/>'):
                path.write_text("<testsuite>" + content + "</testsuite>")
                with self.subTest(content=content), self.assertRaises(ValueError):
                    captures.require_render_test(path)
            path.write_text("<testsuite>" + case.format("") + "</testsuite>")
            captures.require_render_test(path)


if __name__ == "__main__":
    unittest.main()
