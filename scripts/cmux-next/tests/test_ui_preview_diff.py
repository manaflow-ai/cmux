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
        self.warmed = set()

    def stop_shooter(self) -> None:
        self.calls.append("stop_shooter")

    def stop(self) -> None:
        self.calls.append("stop")
        self.warmed.clear()

    def start(self) -> None:
        self.calls.append("start")
        self.warmed.clear()

    def shoot_resident(self, spec):
        self.calls.append("warm" if spec["out"].endswith(".warm") else "resident")
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
        self.assertEqual(calls, ["warm", "resident", "stop_shooter", "stop", "start", "warm", "cold"])

    def test_other_errors_do_not_restart(self) -> None:
        err, calls = self.shoot(False)
        self.assertIn("took no shot: boom", err)
        self.assertEqual(calls, ["warm", "resident"])


class ColdVite(StubGallery):
    """A vite whose first page of an entry draws a frame its later pages do not (modules, fonts and styles still
    arriving when the frame marks ready): the preshoot's agent-pane.access-offer, cached as the next push's before,
    read 7.91% changed against every warm after (#65743, 11-28)."""

    def __init__(self, out: Path) -> None:
        super().__init__(out, False)
        self.drawn: set[str] = set()

    def stop(self) -> None:
        super().stop()
        self.drawn.clear()

    def shoot_resident(self, spec):
        super().shoot_resident(spec)
        rows = []
        for shot in spec["shots"]:
            frame = b"warm" if shot["entry"] in self.drawn else b"cold"
            self.drawn.add(shot["entry"])
            Path(spec["out"], f"{shot['name']}.png").write_bytes(frame)
            rows.append({"name": shot["name"], "file": f"{shot['name']}.png"})
        return rows


class ColdFirstShot(unittest.TestCase):
    """The detector for a measured shot that is an entry's first page on a fresh vite (handbook: ui-preview)."""

    def test_measured_shot_is_never_a_fresh_vites_first_frame(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            g = ColdVite(Path(tmp))
            out = Path(tmp, "shots")
            shots = g.shoot(["agent-pane.access-offer"], out, {})
            self.assertEqual((out / shots["agent-pane.access-offer"]).read_bytes(), b"warm")
            self.assertEqual(g.calls, ["warm", "resident"])
            self.assertFalse(Path(tmp, ".shots.warm").exists(), "the warm-up frame is discarded")

    def test_a_warm_vite_shoots_once_and_a_restart_warms_again(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            g = ColdVite(Path(tmp))
            g.shoot(["agent-pane.access-offer"], Path(tmp, "a"), {})
            g.calls.clear()
            g.shoot(["agent-pane.access-offer"], Path(tmp, "b"), {})
            self.assertEqual(g.calls, ["resident"])
            g.stop()
            g.calls.clear()
            shots = g.shoot(["agent-pane.access-offer"], Path(tmp, "c"), {})
            self.assertEqual(g.calls, ["warm", "resident"])
            self.assertEqual(Path(tmp, "c", shots["agent-pane.access-offer"]).read_bytes(), b"warm")

    def test_absent_entries_are_not_warmed(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            g = ColdVite(Path(tmp))
            g.shoot(["agent-pane.gone"], Path(tmp, "s"), {"agent-pane.gone": "a" * 40})
            self.assertEqual(g.calls, ["resident"])


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
