#!/usr/bin/env python3
"""perceived-speed.py analyze: a recorded opening reads as painted at once, piecemeal, stalled or unsettled."""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from PIL import Image, ImageDraw

SCRIPT = Path(__file__).resolve().parent.parent / "perceived-speed.py"
FRAME = 1 / 120


def record(folder: Path, frames: list[str], times: list[float] | None = None, trigger: float = 0.1) -> None:
    """Frames as debug.window_record writes them; each name is one drawing of a 400x300 window."""
    times = times or [round(i * FRAME, 5) for i in range(len(frames))]
    for index, kind in enumerate(frames):
        image = Image.new("RGB", (400, 300), (30, 30, 30))
        draw = ImageDraw.Draw(image)
        if kind in ("skeleton", "final"):
            draw.rectangle((0, 0, 400, 28), fill=(60, 60, 60))  # the surface's strip
        if kind == "skeleton":
            draw.rectangle((20, 60, 200, 72), fill=(70, 70, 70))  # a placeholder bar
        if kind == "final":
            draw.rectangle((20, 60, 380, 260), fill=(200, 200, 200))  # the content
        image.save(folder / f"frame-{index:05d}.jpg", quality=90)
    (folder / "frames.json").write_text(json.dumps({"times": times}))
    (folder / "meta.json").write_text(json.dumps({"surface": "test", "trigger": trigger}))


def analyze(folder: Path) -> dict:
    done = subprocess.run([sys.executable, str(SCRIPT), "analyze", str(folder)], capture_output=True, text=True, check=True)
    return json.loads(done.stdout)


class AnalyzeTest(unittest.TestCase):
    def test_a_surface_painted_final_on_its_first_frame(self):
        with tempfile.TemporaryDirectory() as tmp:
            record(Path(tmp), ["blank"] * 24 + ["final"] * 60)
            result = analyze(Path(tmp))
        self.assertEqual(result["diff_area"], 0)
        self.assertEqual(result["repaints"], 0)
        self.assertAlmostEqual(result["first_frame_ms"], (24 * FRAME - 0.1) * 1000, delta=1)

    def test_a_skeleton_then_content_is_piecemeal(self):
        with tempfile.TemporaryDirectory() as tmp:
            record(Path(tmp), ["blank"] * 24 + ["skeleton"] * 30 + ["final"] * 60)
            result = analyze(Path(tmp))
        self.assertGreater(result["diff_area"], 0.3)
        self.assertEqual(result["repaints"], 1)
        self.assertAlmostEqual(result["settle_ms"], (54 * FRAME - 0.1) * 1000, delta=1)

    def test_a_busy_main_thread_drops_frames(self):
        frames = ["blank"] * 24 + ["skeleton"] * 10 + ["final"] * 60
        times = [i * FRAME for i in range(len(frames))]
        times = times[:30] + [t + 6 * FRAME for t in times[30:]]  # six display frames never drawn
        with tempfile.TemporaryDirectory() as tmp:
            record(Path(tmp), frames, times)
            result = analyze(Path(tmp))
        self.assertEqual(result["dropped"], 6)

    def test_a_surface_still_changing_when_the_recording_ends_never_settled(self):
        with tempfile.TemporaryDirectory() as tmp:
            record(Path(tmp), ["blank"] * 24 + ["skeleton"] * 30 + ["final"] * 10)
            result = analyze(Path(tmp))
        self.assertIsNone(result["settle_ms"])


if __name__ == "__main__":
    unittest.main()
