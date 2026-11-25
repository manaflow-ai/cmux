#!/usr/bin/env python3
"""flicker-check.py on seeded recordings: a layout shift (rows pushed down by a
banner, a card pushed sideways), a blink, a glide, content arriving in place, a
still screen, and a jump in a 30 fps capture. The recordings are YUV4MPEG2
files written here, so the test needs neither ffmpeg nor numpy, and a change
that stops the detector seeing a planted shift fails CI.

  python3 -I scripts/cmux-next/tests/test_flicker_check.py
"""

from __future__ import annotations

import importlib.util
import json
import random
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "scripts/cmux-next/flicker-check.py"
spec = importlib.util.spec_from_file_location("flicker_check", SCRIPT)
check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check)

W, H = 384, 240
BACKGROUND, INK, BANNER = 24, 210, 120


class Screen:
    """A grey screen of text-like lines: each line a row of dashes of its own lengths."""

    def __init__(self, seed: int = 7, lines: int = 9, top: int = 20, pitch: int = 22):
        rng = random.Random(seed)
        self.lines = []
        for n in range(lines):
            dashes, x = [], 12
            while x < W - 40:
                length = rng.randint(6, 40)
                dashes.append((x, length))
                x += length + rng.randint(4, 14)
            self.lines.append((top + n * pitch, dashes))

    def frame(self, *, push_from: int | None = None, push: int = 0, card_dx: int = 0,
              card: bool = False, extra_line: bool = False, blink: bool = False) -> bytearray:
        px = bytearray([BACKGROUND]) * (W * H)

        def rect(x: int, y: int, w: int, h: int, value: int) -> None:
            for row in range(max(0, y), min(H, y + h)):
                start, end = row * W + max(0, x), row * W + min(W, x + w)
                if end > start:
                    px[start:end] = bytes([value]) * (end - start)

        for y, dashes in self.lines:
            if push_from is not None and y >= push_from:
                y += push
            for x, length in dashes:
                rect(x, y, length, 7, INK)
        if push_from is not None and push:
            rect(8, push_from - 2, W - 16, push - 4, BANNER)
        if card:
            # A card with its own content: a frame and three short bars.
            rect(40 + card_dx, 210, 90, 26, 90)
            for k, length in enumerate((60, 30, 45)):
                rect(46 + card_dx + k * 2, 214 + k * 7, length, 4, 230)
        if extra_line:
            # A new line drawn in the empty space under the last one: arrives, moves nothing.
            rect(12, 225, 200, 7, INK)
        if blink:
            rect(300, 30, 40, 40, 255)
        return px


def write_y4m(path: Path, frames: list[bytearray], fps: int = 60) -> Path:
    with path.open("wb") as out:
        out.write(f"YUV4MPEG2 W{W} H{H} F{fps}:1 Ip A1:1 Cmono\n".encode())
        for frame in frames:
            out.write(b"FRAME\n")
            out.write(bytes(frame))
    return path


def run(path: Path, *extra: str) -> tuple[int, dict]:
    report = path.with_suffix(".json")
    proc = subprocess.run([sys.executable, "-I", str(SCRIPT), str(path), "--json", str(report), *extra],
                          capture_output=True, text=True, timeout=300)
    return proc.returncode, json.loads(report.read_text())


class SeededRecordings(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.screen = Screen()

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def kinds(self, report: dict) -> list[str]:
        return [e["kind"] for e in report["events"]]

    def test_rows_pushed_down_by_a_banner_fail_as_one_jump(self) -> None:
        still = self.screen.frame()
        pushed = self.screen.frame(push_from=64, push=24)
        path = write_y4m(self.dir / "banner.y4m", [still] * 20 + [pushed] * 20)
        code, report = run(path)
        self.assertEqual(code, 1, report)
        jumps = [e for e in report["events"] if e["kind"] == "jump"]
        self.assertEqual(len(jumps), 1, report["events"])
        self.assertEqual((jumps[0]["dx"], jumps[0]["dy"]), (0, 24))
        self.assertEqual(jumps[0]["frame"], 20)
        self.assertEqual(report["counts"]["jump"], 1)

    def test_a_card_pushed_sideways_fails_as_a_jump(self) -> None:
        before = self.screen.frame(card=True)
        after = self.screen.frame(card=True, card_dx=30)
        path = write_y4m(self.dir / "card.y4m", [before] * 15 + [after] * 15)
        code, report = run(path)
        self.assertEqual(code, 1, report)
        jumps = [e for e in report["events"] if e["kind"] == "jump"]
        self.assertEqual(len(jumps), 1, report["events"])
        self.assertEqual((jumps[0]["dx"], jumps[0]["dy"]), (30, 0))

    def test_a_still_screen_passes(self) -> None:
        path = write_y4m(self.dir / "still.y4m", [self.screen.frame()] * 30)
        code, report = run(path)
        self.assertEqual((code, report["events"]), (0, []))

    def test_content_that_arrives_in_place_is_no_jump(self) -> None:
        path = write_y4m(self.dir / "arrive.y4m",
                         [self.screen.frame()] * 15 + [self.screen.frame(extra_line=True)] * 15)
        code, report = run(path)
        self.assertNotIn("jump", self.kinds(report), report["events"])
        self.assertEqual(code, 0, report["events"])

    def test_a_card_that_glides_is_reported_and_passes(self) -> None:
        frames = [self.screen.frame(card=True)] * 10
        frames += [self.screen.frame(card=True, card_dx=3 * k) for k in range(1, 17)]
        frames += [frames[-1]] * 10
        path = write_y4m(self.dir / "glide.y4m", frames)
        code, report = run(path)
        self.assertEqual(code, 0, report["events"])
        self.assertIn("glide", self.kinds(report))
        self.assertNotIn("jump", self.kinds(report))

    def test_a_blink_still_fails(self) -> None:
        still, lit = self.screen.frame(), self.screen.frame(blink=True)
        path = write_y4m(self.dir / "blink.y4m", [still] * 10 + [lit] * 2 + [still] * 10)
        code, report = run(path)
        self.assertEqual(code, 1)
        self.assertIn("blink", self.kinds(report))
        self.assertNotIn("jump", self.kinds(report))

    def test_a_jump_in_a_30_fps_capture_is_still_one_jump(self) -> None:
        still = self.screen.frame()
        pushed = self.screen.frame(push_from=108, push=16)
        path = write_y4m(self.dir / "thirty.y4m", [still] * 10 + [pushed] * 10, fps=30)
        code, report = run(path, "--report-only")
        self.assertEqual(code, 0, "--report-only exits 0")
        self.assertEqual(report["counts"]["jump"], 1, report["events"])
        self.assertEqual(report["events"][0]["ms"], 333)

    def test_a_scaled_crop_reads_the_move_in_source_pixels(self) -> None:
        # 768 wide: twice the analysed width, so a 24 px push reads as 12 analysed px and is reported as 24 again.
        global W, H
        saved = (W, H)
        W, H = 768, 480
        try:
            big = Screen(lines=18, top=40, pitch=24)
            path = write_y4m(self.dir / "big.y4m", [big.frame()] * 8 + [big.frame(push_from=136, push=24)] * 8)
        finally:
            W, H = saved
        code, report = run(path)
        jumps = [e for e in report["events"] if e["kind"] == "jump"]
        self.assertEqual(code, 1)
        self.assertEqual(len(jumps), 1, report["events"])
        self.assertEqual(jumps[0]["dy"], 24)


if __name__ == "__main__":
    unittest.main()
