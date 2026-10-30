#!/usr/bin/env python3
"""perceived-speed.py analyze: a recorded opening reads as painted at once, piecemeal, stalled or unsettled;
find-socket picks the slot app's debug socket by bundle id."""

from __future__ import annotations

import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
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


def serve(path: str, bundle_id: str) -> socket.socket:
    """A debug socket that answers system.identify for one app."""
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(path)
    server.listen()

    def loop():
        while True:
            try:
                conn, _ = server.accept()
            except OSError:
                return
            with conn:
                conn.recv(65536)
                conn.sendall((json.dumps({"id": 1, "result": {"bundle_id": bundle_id}}) + "\n").encode())

    threading.Thread(target=loop, daemon=True).start()
    return server


class FindSocketTest(unittest.TestCase):
    def find(self, *args: str) -> subprocess.CompletedProcess:
        return subprocess.run([sys.executable, str(SCRIPT), "find-socket", *args], capture_output=True, text=True, timeout=30)

    def test_picks_the_socket_whose_app_names_the_bundle_id(self):
        with tempfile.TemporaryDirectory(dir="/tmp") as tmp:
            stale = Path(tmp, "cmux-debug-old.sock")
            stale.touch()  # left by a quit app: nobody listens
            other = serve(os.path.join(tmp, "cmux-debug--aaaa.sock"), "com.cmuxterm.app.debug.other.capslot1")
            mine = serve(os.path.join(tmp, "cmux-debug--bbbb.sock"), "com.cmuxterm.app.debug.mine.capslot2")
            try:
                done = self.find("com.cmuxterm.app.debug.mine.capslot2", tmp)
                missing = self.find("com.cmuxterm.app.debug.gone.capslot3", tmp)
            finally:
                other.close()
                mine.close()
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(done.stdout.strip(), os.path.join(tmp, "cmux-debug--bbbb.sock"))
        self.assertEqual(missing.returncode, 1)

    def test_skips_sockets_older_than_the_launch(self):
        with tempfile.TemporaryDirectory(dir="/tmp") as tmp:
            server = serve(os.path.join(tmp, "cmux-debug--cccc.sock"), "com.cmuxterm.app.debug.mine.capslot2")
            try:
                done = self.find("com.cmuxterm.app.debug.mine.capslot2", "--since", str(time.time() + 3600), tmp)
            finally:
                server.close()
        self.assertEqual(done.returncode, 1)


if __name__ == "__main__":
    unittest.main()
