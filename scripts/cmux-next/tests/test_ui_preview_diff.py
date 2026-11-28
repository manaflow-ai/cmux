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


class StubGallery(upw.Gallery):
    """A gallery whose vite and shooters are recorded calls: the first resident shot fails as on a stale module graph
    (fs-agent-lane rescue pushes, 11-28 00-12Z), the cold shot after a vite restart lands."""

    def __init__(self, out: Path, stale: bool) -> None:
        self.name, self.port, self.out, self.stale, self.calls = "g0", 5199, out, stale, []

    def stop_shooter(self) -> None:
        self.calls.append("stop_shooter")

    def stop(self) -> None:
        self.calls.append("stop")

    def start(self) -> None:
        self.calls.append("start")

    def shoot_resident(self, spec):
        self.calls.append("resident")
        return [{"name": "pages.home", "error": "TypeError: Failed to fetch dynamically imported module: "
                                                "http://127.0.0.1:5199/src/x.tsx?t=1764300000" if self.stale else "boom"}]

    def shoot_once(self, spec, out):
        self.calls.append("cold")
        (out / "pages.home.png").write_bytes(b"png")
        return [{"name": "pages.home", "file": "pages.home.png"}]

    def scenes(self, files):
        return ["gallery.warm"]

    def entry_ids(self):
        return {"agent-pane.b", "agent-pane.a", "pages.home", "gallery.warm"}


class StaleModuleRetry(unittest.TestCase):
    def shoot(self, stale: bool):
        with tempfile.TemporaryDirectory() as tmp:
            g = StubGallery(Path(tmp), stale)
            try:
                return g.shoot(["pages.home"], Path(tmp, "shots"), {}), g.calls
            except upw.LookError as err:
                return str(err), g.calls

    def test_stale_module_restarts_vite_and_shoots_cold(self) -> None:
        shots, calls = self.shoot(True)
        self.assertEqual(shots, {"pages.home": "pages.home.png"})
        self.assertEqual(calls, ["resident", "stop_shooter", "stop", "start", "cold"])

    def test_other_errors_do_not_restart(self) -> None:
        err, calls = self.shoot(False)
        self.assertIn("took no shot: boom", err)
        self.assertEqual(calls, ["resident"])


class EveryScreen(unittest.TestCase):
    def test_config_and_dev_server_files(self) -> None:
        for f in ("webviews/vite.config.acpmux-pane.mjs", "webviews/vite.config.ts",
                  "webviews/dev-server/hotSwapTiming.ts"):
            self.assertTrue(upw.EVERY_SCREEN.match(f), f)
        for f in ("webviews/src/vite.config.ts", "webviews/src/pages/Home.tsx"):
            self.assertFalse(upw.EVERY_SCREEN.match(f), f)

    def test_representative_entries(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(StubGallery(Path(tmp), False).representative_entries(),
                             ["gallery.warm", "agent-pane.a", "pages.home"])


if __name__ == "__main__":
    unittest.main()
