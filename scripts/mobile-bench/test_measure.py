#!/usr/bin/env python3
"""measure.py against synthetic clips whose answers are known.

    python3 scripts/mobile-bench/test_measure.py

A striped panel slides up the screen on a SwiftUI spring at 120 fps, after a
known delay, with known dropped frames; measure.py must recover the delay, the
drops and the spring.
"""
from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import measure  # noqa: E402

W, H, FPS = 120, 260, 120


def panel_frame(top: float) -> bytes:
    rows = []
    for y in range(H):
        if y >= top:
            v = 200 if (int(y - top) // 6) % 2 == 0 else 150
        else:
            v = 30 + (y % 13)
        rows.append(bytes([v]) * W)
    return b"".join(rows)


def write_clip(d: Path, *, delay_s: float, response: float, damping: float, drop: set[int],
               stim_s: float = 0.5, total_s: float = 2.0, flow: str = "keyboard-show") -> None:
    y0, y1 = 0.85 * H, 0.5 * H
    frames, last = [], None
    for i in range(int(total_s * FPS)):
        t = i / FPS
        rel = t - stim_s - delay_s
        top = y0 if rel <= 0 else y0 + (y1 - y0) * measure.spring(rel, response, damping)
        f = panel_frame(round(top))
        if i in drop and last is not None:
            f = last  # the screen did not update in this slot
        frames.append(f)
        last = f
    ff = measure.ffmpeg_bin()
    subprocess.run([ff, "-hide_banner", "-loglevel", "error", "-y", "-f", "rawvideo", "-pix_fmt", "gray",
                    "-s", f"{W}x{H}", "-r", str(FPS), "-i", "-", "-c:v", "libx264", "-qp", "0",
                    "-pix_fmt", "yuv420p", str(d / "clip.mp4")], input=b"".join(frames), check=True)
    (d / "meta.json").write_text(json.dumps({"app": "synthetic", "flow": flow, "source": "test",
                                             "stimulus_t": stim_s, "fps_nominal": FPS}))


class MeasureTests(unittest.TestCase):
    def run_case(self, **kw):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            write_clip(d, **kw)
            return measure.measure(d, HERE / "flows.json")

    def test_spring_delay_and_drops(self):
        stim, delay = 0.5, 0.050
        # three dropped slots inside the motion (frames 70, 71 and 80; motion starts at frame 66)
        res = self.run_case(delay_s=delay, response=0.35, damping=0.86, drop={70, 71, 80}, stim_s=stim)
        self.assertAlmostEqual(res["response_ms"], delay * 1000, delta=1000 / FPS + 0.5)
        self.assertEqual(res["dropped"], 3)
        self.assertEqual(res["bursts"], 1)
        self.assertEqual(res["jumps"], 0)
        c = res["curve"]
        self.assertEqual(c["direction"], "up")
        self.assertAlmostEqual(c["spring_response_s"], 0.35, delta=0.03)
        self.assertAlmostEqual(c["spring_damping_fraction"], 0.86, delta=0.08)

    def test_bouncy_spring_overshoots(self):
        res = self.run_case(delay_s=0.0, response=0.5, damping=0.5, drop=set())
        self.assertEqual(res["dropped"], 0)
        c = res["curve"]
        self.assertAlmostEqual(c["spring_damping_fraction"], 0.5, delta=0.08)
        self.assertGreater(c["overshoot_pct"], 10)

    def test_jump_is_flagged(self):
        # a 120 ms freeze then the panel lands in one frame: dropped frames and a jump
        drop = set(range(62, 77))
        res = self.run_case(delay_s=0.0, response=0.3, damping=1.0, drop=drop)
        self.assertGreaterEqual(res["jumps"], 1)
        self.assertGreater(res["worst_gap_ms"], 100)


if __name__ == "__main__":
    unittest.main()
