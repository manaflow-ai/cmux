"""Drawing evidence must come from the sample's pixels, never a route or title."""
import importlib.util
import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

spec = importlib.util.spec_from_file_location("capture", Path(__file__).with_name("ext-rows-capture.py"))
capture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(capture)


class DrawingEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        app = root / "test.app"
        (app / "Contents").mkdir(parents=True)
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "test.isolated"}))
        self.ctx = SimpleNamespace(app=app, work=root, ext=Mock())
        (root / "fixture-ocr").touch()

    def image(self, args, **kwargs):
        self.assertEqual(args[args.index("--window") + 1], "test.isolated")
        Path(args[args.index("--out") + 1]).write_bytes(b"test image")
        return {"exit": 0}

    def test_refusal_stops_without_retry_or_ocr(self):
        self.ctx.ext.return_value = {"exit": 1, "error": "computer_use_off"}
        with patch.object(capture.subprocess, "run") as run:
            result = capture.capture_marker(self.ctx, "pane", "WEB PANE unique")
        self.assertFalse(result["drawn"])
        self.ctx.ext.assert_called_once()
        run.assert_not_called()

    def test_tab_title_is_not_drawing_evidence(self):
        self.ctx.ext.side_effect = self.image
        with patch.object(capture.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "Rows web pane", "")), \
                patch.object(capture.time, "sleep"):
            result = capture.capture_marker(self.ctx, "pane", "WEB PANE unique")
        self.assertFalse(result["drawn"])
        self.assertEqual(len(result["captures"]), 3)

    def test_content_marker_in_captured_pixels_passes(self):
        self.ctx.ext.side_effect = self.image
        with patch.object(capture.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "WEB PANE\nunique", "")):
            result = capture.capture_marker(self.ctx, "pane", "WEB PANE unique")
        self.assertTrue(result["drawn"])
        self.assertTrue(Path(result["captures"][0]["path"]).is_file())

    def test_ocr_error_does_not_count_output_as_proof(self):
        self.ctx.ext.side_effect = self.image
        with patch.object(capture.subprocess, "run", return_value=subprocess.CompletedProcess([], 1, "WEB PANE unique", "failed")):
            result = capture.capture_marker(self.ctx, "pane", "WEB PANE unique")
        self.assertFalse(result["drawn"])
        self.ctx.ext.assert_called_once()


if __name__ == "__main__":
    unittest.main()
