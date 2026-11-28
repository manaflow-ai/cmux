#!/usr/bin/env python3
"""ui-preview-worker.py's pixel diff: the message says how much of each scene changed and where, so a lane that cannot
fetch the tailnet-only pictures (fs-agent-lane-28, 2026-11-28: four 25 s timeouts) can still act on the look."""
from __future__ import annotations

import importlib.util
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("ui_preview_worker", ROOT / "ui-preview-worker.py")
upw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(upw)

try:
    from PIL import Image
except ImportError:  # the diff is None without Pillow; the message then lists the URLs alone
    Image = None


class DiffText(unittest.TestCase):
    def test_text(self) -> None:
        self.assertEqual(upw.diff_text({"changed_px": 2500, "pct": 0.17, "bbox": [10, 20, 300, 40]}),
                         "2,500 px changed (0.17%), within x 10-300 y 20-40")
        self.assertEqual(upw.diff_text({"size": [[2, 2], [4, 4]]}), "size changed 2x2 -> 4x4")


@unittest.skipIf(Image is None, "no Pillow")
class PixelDiff(unittest.TestCase):
    def test_changed_box_and_noise(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            a, b, c = Path(tmp, "a.png"), Path(tmp, "b.png"), Path(tmp, "c.png")
            Image.new("RGB", (100, 50), (0, 0, 0)).save(a)
            img = Image.new("RGB", (100, 50), (3, 3, 3))  # under the threshold: antialiasing noise
            for x in range(10, 20):
                for y in range(5, 10):
                    img.putpixel((x, y), (255, 255, 255))
            img.save(b)
            self.assertEqual(upw.pixel_diff(a, b), {"changed_px": 50, "pct": 1.0, "bbox": [10, 5, 20, 10]})
            Image.new("RGB", (2, 2)).save(c)
            self.assertEqual(upw.pixel_diff(a, c), {"size": [[100, 50], [2, 2]]})


if __name__ == "__main__":
    unittest.main()
