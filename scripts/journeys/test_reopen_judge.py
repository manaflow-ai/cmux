#!/usr/bin/env python3
"""reopen_judge.py on a synthetic film with known times: the window at 250 ms, the panes' last content at 450 ms
and the marker's echo at 850 ms after main(); the film's clock found from the cursor jumps; one pane that shows
its content, goes blank and comes back is a flash. Run with numpy and imageio-ffmpeg:
    python3 scripts/journeys/test_reopen_judge.py"""
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import reopen_judge as J  # noqa: E402

FPS = 30
W, H = 640, 360
START = 1000.0          # record_started_wall
OFFSET = 0.05           # true wall = START + pts + OFFSET
WINDOW = {"x": 40, "y": 40, "w": 560, "h": 300}
PANE_A = {"x": 50, "y": 60, "w": 260, "h": 270, "cell_w": 8, "cell_h": 16, "origin_x": 54, "origin_y": 64}
PANE_B = {"x": 330, "y": 60, "w": 260, "h": 270, "cell_w": 8, "cell_h": 16, "origin_x": 334, "origin_y": 64}
CELL_A = {"row": 5, "col": 3, "x": 54 + 3 * 8, "y": 64 + 5 * 16, "w": 8, "h": 16}
JUMPS = [(0.40, 450), (0.65, 500), (0.90, 550), (1.15, 600)]   # film time, x on the menu bar
END, GONE, PROC = 2.0, 2.1, 2.45                                  # film times
MAIN = PROC + 0.05
WINDOW_AT, CONTENT_AT, KEY_AT, ECHO_AT = 2.7, 2.9, 3.2, 3.3


def pattern(rect, seed):
    rng = np.random.default_rng(seed)
    return (rng.integers(0, 2, size=(rect["h"] // 4, rect["w"] // 4)) * 200 + 30).astype(np.uint8).repeat(4, 0).repeat(4, 1)


def frame(t, flash=False):
    f = np.full((H, W), 90, np.uint8)                      # desktop
    cursor_x = 380
    for at, x in JUMPS:
        if t >= at:
            cursor_x = x
    f[2:20, cursor_x - 4:cursor_x + 6] = 255               # the pointer on the menu bar
    shown = t < END or t >= WINDOW_AT
    if shown:
        f[WINDOW["y"]:WINDOW["y"] + WINDOW["h"], WINDOW["x"]:WINDOW["x"] + WINDOW["w"]] = 20
    content = t < END or t >= CONTENT_AT
    if flash and 3.0 <= t < 3.1:
        content = False
    if shown and content:
        for rect, seed in ((PANE_A, 1), (PANE_B, 2)):
            p = pattern(rect, seed)
            f[rect["y"]:rect["y"] + p.shape[0], rect["x"]:rect["x"] + p.shape[1]] = p
        f[CELL_A["y"]:CELL_A["y"] + 16, CELL_A["x"]:CELL_A["x"] + 24] = 20   # an empty prompt cell
    if t >= ECHO_AT:
        for d in range(8):   # an "x": two diagonals
            f[CELL_A["y"] + 4 + d, CELL_A["x"] + 1 + (d * 6) // 8] = 240
            f[CELL_A["y"] + 4 + d, CELL_A["x"] + 6 - (d * 6) // 8] = 240
    return f


def make_film(path, flash=False):
    exe = J.ffmpeg_exe()
    frames = b"".join(frame(i / FPS, flash).tobytes() for i in range(int(4.0 * FPS)))
    subprocess.run([exe, "-y", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "gray", "-s", f"{W}x{H}", "-r", str(FPS),
                    "-i", "-", "-c:v", "libx264", "-qp", "0", "-pix_fmt", "yuv420p", str(path)], input=frames, check=True)


def record():
    wall = lambda t: START + t + OFFSET
    return {"cycle": 1, "how": "kill-app", "screen": {"w": W, "h": H, "scale": 1, "hz": 60},
            "record_started_wall": START, "sync_method": "CGWarpMouseCursorPosition",
            "sync": [{"x": x, "y": 11, "sent_wall": wall(t) - 0.010, "done_wall": wall(t) + 0.004} for t, x in JUMPS],
            "end_wall": wall(END), "gone_wall": wall(GONE), "open_wall": wall(PROC - 0.2),
            "process_start_wall": wall(PROC), "main_wall": wall(MAIN),
            "before": {"server_windows": [dict(WINDOW, order=0, number=1)]},
            "pane_rects": {"a": PANE_A, "b": PANE_B},
            "markers": [{"pane": "a", "focused_before": True, "cell": CELL_A, "key_sent_wall": wall(KEY_AT),
                         "key_done_wall": wall(KEY_AT) + 0.02}],
            "differences": [], "app_marks_ms": {}, "movie": "reopen-1.mp4"}


class VerdictTest(unittest.TestCase):
    def row(self, **panes):
        base = {"window_ms": 200.0, "all_content_ms": max(p["content_ms"] for p in panes.values()), "all_echo_ms": None,
                "differences": [], "panes": panes}
        return base

    def test_pane_not_in_first_window_frame_fails(self):
        fails = J.verdict(self.row(a={"content_ms": 200.0}, b={"content_ms": 400.0}))
        self.assertTrue(any("not in the first window frame" in f for f in fails), fails)
        self.assertTrue(any("> 300 ms" in f for f in fails), fails)

    def test_clean_cycle_passes(self):
        self.assertEqual(J.verdict(self.row(a={"content_ms": 200.0}, b={"content_ms": 200.0})), [])

    def test_lost_key_fails_only_with_a_precise_key(self):
        precise = {"content_ms": 200.0, "key_sent_ms": 210.0, "key_path": "CGEventPost HID", "key_precise": True}
        self.assertTrue(any("never echoed" in f for f in J.verdict(self.row(a=precise))))
        self.assertEqual(J.verdict(self.row(a=dict(precise, echo_ms=450.0))), [])
        self.assertTrue(any("echoed at 650.0" in f for f in J.verdict(self.row(a=dict(precise, echo_ms=650.0)))))
        cua = dict(precise, key_path="cua press_key (foreground HID)", key_precise=False)
        self.assertEqual(J.verdict(self.row(a=cua)), [])


class JudgeTest(unittest.TestCase):
    def judge(self, flash=False):
        with tempfile.TemporaryDirectory() as tmp:
            movie = Path(tmp) / "reopen-1.mp4"
            make_film(movie, flash)
            return J.judge_cycle(record(), movie)

    def test_times_from_main(self):
        out = self.judge()
        step = 1000 / FPS
        self.assertIsNotNone(out["clock"]["offset_s"], out["clock"])
        self.assertAlmostEqual(out["clock"]["offset_s"], OFFSET, delta=1 / FPS)
        self.assertAlmostEqual(out["window_ms"], (WINDOW_AT - MAIN) * 1000, delta=step + 1)
        self.assertAlmostEqual(out["all_content_ms"], (CONTENT_AT - MAIN) * 1000, delta=step + 1)
        self.assertAlmostEqual(out["panes"]["a"]["echo_ms"], (ECHO_AT - MAIN) * 1000, delta=step + 1)
        self.assertIsNone(out["panes"]["b"].get("echo_ms"))
        self.assertEqual(out["panes"]["a"]["lost_after_shown_frames"], 0)
        self.assertEqual(out["window_refreshes"], round(out["window_ms"] / (1000 / 60), 1))

    def test_flash_after_content(self):
        out = self.judge(flash=True)
        self.assertGreater(out["panes"]["a"]["lost_after_shown_frames"], 0, json.dumps(out["panes"]))
        self.assertGreater(out["panes"]["b"]["lost_after_shown_frames"], 0)


if __name__ == "__main__":
    unittest.main()
