#!/usr/bin/env python3
"""Detector tests; native CURRENT-build acceptance still requires fresh capture artifacts."""
import copy
import json
from pathlib import Path
import tempfile
import unittest

from PIL import Image, ImageDraw

import new_tab_split_acceptance as acceptance


FIXTURE = Path(__file__).with_name("fixtures") / "new-tab-split-baseline"


class NativeFixtureTests(unittest.TestCase):
    def test_recorded_right_geometry_rejects_requested_down(self):
        record = json.loads((FIXTURE / "capture.json").read_text())
        rect, ms, window, target = acceptance.target_geometry(record["strip"], record["trace"], "right")
        self.assertEqual(rect, [880, 1, 216, 715])
        self.assertAlmostEqual(ms, 135.55, places=1)
        with self.assertRaisesRegex(ValueError, "not a split down"):
            acceptance.target_geometry(record["strip"], record["trace"], "down")

    def test_recorded_target_is_empty_after_geometry_and_paints_later(self):
        # Real target-only compositor crops. This validates the detector, NOT current app code.
        with Image.open(FIXTURE / "target-138ms.png") as early, \
                Image.open(FIXTURE / "target-351ms.png") as first, \
                Image.open(FIXTURE / "target-684ms.png") as final:
            self.assertFalse(acceptance.nonblank(early))
            self.assertTrue(acceptance.nonblank(final))
            self.assertGreater(acceptance.changed_pixels(early, final), 0)
            self.assertEqual(acceptance.changed_pixels(first, final), 0)


class AcceptanceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        old = ["source", 0, 0, 100, 100]
        source = ["source", 0, 0, 49, 100]
        target = ["target", 50, 0, 50, 100]
        self.trace = {"t0_s": 1, "refresh_ms": 10, "samples": [
            {"t": 0, "window": [100, 100], "panes": [old]},
            {"t": 30, "window": [100, 100], "panes": [source, target]},
            {"t": 200, "window": [100, 100], "panes": [source, target]}]}
        self.strip = {"sent_host_s": 1.02, "capture": "screencapturekit", "key": {"action": "splitRight"},
                      "frames": [{"ms": 20 + i * 10, "file": "content.png"} for i in range(8)]}
        self.endpoint = {"sent_host_s": 4.1, "capture": "screencapturekit",
                         "frames": [{"ms": i * 10, "file": "content.png"} for i in range(8)]}
        self.action = {"ran": True, "action": "splitRight"}
        self.field = {"focused": True}
        self.focus = {"windows": [{"model": {"resolved_pane": "target", "resolved_tab": "new-tab"},
                                   "layout_focused_pane": "target",
                                   "topology": [{"pane": "target", "selected": "new-tab"}]}]}
        image = Image.new("RGB", (100, 100), (30, 30, 30))
        draw = ImageDraw.Draw(image)
        for i in range(20):
            draw.line((60, 30 + i, 90, 30 + i), fill=(50 + i * 8,) * 3)
        image.save(self.directory / "content.png")
        Image.new("RGB", (100, 100), (30, 30, 30)).save(self.directory / "empty.png")

    def run_capture(self):
        return acceptance.accept(self.strip, self.trace, self.action, self.endpoint, self.field, self.focus,
                                 self.directory, self.directory, "right")

    def test_current_capture_contract_accepts_stable_target(self):
        self.assertTrue(self.run_capture()["pass"])

    def test_late_composer_fails_even_when_geometry_is_final(self):
        self.strip["frames"][0]["file"] = "empty.png"
        self.assertFalse(self.run_capture()["pass"])

    def test_refused_or_noop_action_cannot_pass(self):
        self.action["ran"] = False
        with self.assertRaisesRegex(ValueError, "refused"):
            self.run_capture()

    def test_same_capture_endpoint_cannot_pass(self):
        self.endpoint["sent_host_s"] = self.strip["sent_host_s"]
        with self.assertRaisesRegex(ValueError, "independently"):
            self.run_capture()

    def test_another_ready_new_tab_cannot_satisfy_target_readiness(self):
        self.focus["windows"][0]["model"]["resolved_pane"] = "source"
        with self.assertRaisesRegex(ValueError, "not bound"):
            self.run_capture()

    def test_focused_tab_must_match_target_selected_tab(self):
        self.focus["windows"][0]["topology"][0]["selected"] = "old-tab"
        with self.assertRaisesRegex(ValueError, "does not match"):
            self.run_capture()

    def test_missing_focus_receipt_cannot_pass(self):
        self.focus = {}
        with self.assertRaisesRegex(ValueError, "not bound"):
            self.run_capture()

    def test_blank_or_changing_endpoint_cannot_pass(self):
        endpoint = copy.deepcopy(self.endpoint)
        for frame in self.endpoint["frames"]:
            frame["file"] = "empty.png"
        with self.assertRaisesRegex(ValueError, "blank"):
            self.run_capture()
        self.endpoint = endpoint
        self.endpoint["frames"][0]["file"] = "empty.png"
        with self.assertRaisesRegex(ValueError, "still changing"):
            self.run_capture()

    def test_legitimate_other_pane_motion_is_not_compared(self):
        with Image.open(self.directory / "content.png") as image:
            ImageDraw.Draw(image).rectangle((0, 0, 40, 99), fill="white")
            image.save(self.directory / "other-pane.png")
        self.strip["frames"][0]["file"] = "other-pane.png"
        self.assertTrue(self.run_capture()["pass"])


if __name__ == "__main__":
    unittest.main()
