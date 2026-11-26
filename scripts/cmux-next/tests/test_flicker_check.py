#!/usr/bin/env python3
"""flicker-check.py (and recording-shifts-report.py, which runs it on CI's recordings) on seeded recordings: a layout shift (rows pushed down by a
banner, a card pushed sideways), a blink, a glide, content arriving in place, a
still screen, a jump in a 30 fps capture, and the flashes of
docs/cmux-next/spurious-ui.md (a notice, a spinner or a pushing banner that
comes and goes in under 3 s) beside what must not read as one (a notice that
stays, one shown for a real 5 s outage, a caret, content replaced for good). The recordings are YUV4MPEG2
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
REPORT = ROOT / "scripts/cmux-next/recording-shifts-report.py"
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
              card: bool = False, extra_line: bool = False, blink: bool = False, notice: bool = False,
              spinner: int | None = None, caret: bool = False, replaced: bool = False) -> bytearray:
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
        if notice:
            # A chip drawn over the bottom right, pushing nothing: "Reconnecting..." with a dot.
            rect(250, 205, 120, 24, 150)
            rect(258, 213, 8, 8, 240)
            rect(272, 214, 70, 6, 60)
        if spinner is not None:
            # A loading indicator whose lit quarter turns every frame.
            rect(300, 120, 32, 32, 70)
            qx, qy = ((0, 0), (16, 0), (16, 16), (0, 16))[spinner % 4]
            rect(300 + qx, 120 + qy, 16, 16, 230)
        if caret:
            rect(220, 196, 3, 10, 240)
        if replaced:
            # The bottom block drawn with other content, for good.
            rect(8, 200, W - 16, 30, 60)
            rect(20, 210, 150, 8, 200)
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


class Flashes(unittest.TestCase):
    """The flash class of docs/cmux-next/spurious-ui.md: something drawn and then gone again, the screen as it was."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.screen = Screen()

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def flashes(self, report: dict) -> list[dict]:
        return [e for e in report["events"] if e["kind"] == "flash"]

    def test_a_notice_shown_for_a_second_fails_as_one_flash(self) -> None:
        still, shown = self.screen.frame(), self.screen.frame(notice=True)
        path = write_y4m(self.dir / "notice.y4m", [still] * 20 + [shown] * 60 + [still] * 20)
        code, report = run(path)
        self.assertEqual(code, 1, report["events"])
        flashes = self.flashes(report)
        self.assertEqual(len(flashes), 1, report["events"])
        self.assertEqual((flashes[0]["frame"], flashes[0]["duration_ms"]), (20, 1000))
        box = flashes[0]["box"]
        self.assertTrue(box[0] <= 250 and box[2] >= 370 and box[1] <= 205 and box[3] >= 229, box)
        self.assertEqual([e["kind"] for e in report["events"]], ["flash"])

    def test_a_spinner_for_a_load_that_was_already_done_fails_as_a_flash(self) -> None:
        still = self.screen.frame()
        spinning = [self.screen.frame(spinner=k // 4) for k in range(48)]
        path = write_y4m(self.dir / "spinner.y4m", [still] * 20 + spinning + [still] * 20)
        code, report = run(path)
        self.assertEqual(code, 1)
        self.assertEqual(len(self.flashes(report)), 1, report["events"])
        self.assertEqual(self.flashes(report)[0]["duration_ms"], 800)

    def test_a_banner_that_pushes_rows_and_goes_is_a_flash_and_two_jumps(self) -> None:
        still, pushed = self.screen.frame(), self.screen.frame(push_from=64, push=24)
        path = write_y4m(self.dir / "pushback.y4m", [still] * 20 + [pushed] * 90 + [still] * 20)
        code, report = run(path)
        self.assertEqual(code, 1)
        self.assertEqual(report["counts"]["flash"], 1, report["events"])
        self.assertEqual(report["counts"]["jump"], 2, report["events"])

    def test_a_notice_that_stays_is_lasting_state_and_passes(self) -> None:
        path = write_y4m(self.dir / "stays.y4m",
                         [self.screen.frame()] * 20 + [self.screen.frame(notice=True)] * 240)
        code, report = run(path)
        self.assertEqual((code, report["events"]), (0, []))

    def test_a_notice_for_a_real_five_second_outage_passes(self) -> None:
        still, shown = self.screen.frame(), self.screen.frame(notice=True)
        path = write_y4m(self.dir / "outage.y4m", [still] * 20 + [shown] * 300 + [still] * 20)
        code, report = run(path)
        self.assertEqual((code, report["events"]), (0, []))
        code, report = run(path, "--flash-ms", "6000")
        self.assertEqual(report["counts"]["flash"], 1, "--flash-ms widens the window")

    def test_content_replaced_for_good_is_no_flash(self) -> None:
        path = write_y4m(self.dir / "replaced.y4m",
                         [self.screen.frame()] * 20 + [self.screen.frame(replaced=True)] * 100)
        code, report = run(path)
        self.assertEqual(self.flashes(report), [], report["events"])

    def test_a_blinking_caret_is_no_flash(self) -> None:
        frames = []
        for k in range(8):
            frames += [self.screen.frame(caret=k % 2 == 0)] * 30
        path = write_y4m(self.dir / "caret.y4m", frames)
        code, report = run(path)
        self.assertEqual((code, report["events"]), (0, []))

    def test_a_two_frame_blink_stays_a_blink(self) -> None:
        still, lit = self.screen.frame(), self.screen.frame(blink=True)
        path = write_y4m(self.dir / "blink2.y4m", [still] * 10 + [lit] * 2 + [still] * 10)
        _, report = run(path)
        self.assertEqual(self.flashes(report), [], report["events"])
        self.assertEqual(report["counts"]["blink"] > 0, True)


class Report(unittest.TestCase):
    """recording-shifts-report.py: one row per recording, a JSON beside each, exit 0 whatever it finds."""

    def test_rows_count_the_planted_jump_and_never_fail_the_run(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp) / "media" / "after"
            folder.mkdir(parents=True)
            screen = Screen()
            write_y4m(folder / "banner.y4m", [screen.frame()] * 10 + [screen.frame(push_from=64, push=24)] * 10)
            write_y4m(folder / "still.y4m", [screen.frame()] * 10)
            (folder / "broken.mov").write_bytes(b"not a movie")
            summary = Path(tmp) / "summary.md"
            proc = subprocess.run([sys.executable, "-I", str(REPORT), str(Path(tmp) / "media"), "--summary", str(summary)],
                                  capture_output=True, text=True, timeout=300, env={"PATH": "/nonexistent"})
            self.assertEqual(proc.returncode, 0, proc.stderr)
            rows = {line.split("`")[1]: line for line in proc.stdout.splitlines() if line.startswith("| `")}
            self.assertIn("| 1 | 0 | 0 | 0 | 0 | 0.17s (0,24)px", rows["after/banner.y4m"])
            self.assertIn("| 10 | 0 | 0 | 0 | 0 | 0 | - |", rows["after/still.y4m"])
            self.assertIn("not read", next(v for k, v in rows.items() if k.endswith("broken.mov")))
            self.assertEqual(json.loads((folder / "banner.y4m.shifts.json").read_text())["counts"]["jump"], 1)
            self.assertEqual(summary.read_text().strip(), proc.stdout.strip())


if __name__ == "__main__":
    unittest.main()
