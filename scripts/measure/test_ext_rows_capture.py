"""Drawing evidence must come from the sample's pixels, never a route or title."""
import importlib.util
import json
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
        self.windows = [{"window_id": "242", "app_id": "test.isolated", "title": ""}]

    def image(self, args, **kwargs):
        if "list_windows" in args:
            self.assertEqual(json.loads(args[-1]), {"app_id": "test.isolated"})
            self.assertIn("--json", args)
            return {"exit": 0, "json": {"windows": self.windows}}
        self.assertIn(args[args.index("--window") + 1], [w["window_id"] for w in self.windows
                                                       if w["app_id"] == "test.isolated"])
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
        self.assertEqual(self.ctx.ext.call_count, 2)

    def test_three_windows_marker_in_last_window_binds_native_id(self):
        self.windows = [{"window_id": wid, "app_id": "test.isolated", "title": ""}
                        for wid in ("247", "243", "242")]
        # Even if discovery returns an unrelated app, it is never captured.
        self.windows.insert(0, {"window_id": "999", "app_id": "other.app"})
        self.ctx.ext.side_effect = self.image
        def ocr(args, **kwargs):
            text = "WEB PANE unique" if args[-1].endswith("-242.png") else "Rows web pane"
            return subprocess.CompletedProcess(args, 0, text, "")
        with patch.object(capture.subprocess, "run", side_effect=ocr):
            result = capture.capture_marker(self.ctx, "pane", "WEB PANE unique")
        self.assertTrue(result["drawn"])
        self.assertEqual(result["window_id"], "242")
        self.assertEqual([c["window_id"] for c in result["captures"]], ["247", "243", "242"])
        self.assertEqual(len({c["path"] for c in result["captures"]}), 3)

    def test_invalid_or_denied_discovery_never_captures(self):
        for windows in ([], [{"app_id": "other.app", "window_id": "242"}],
                        [{"app_id": "test.isolated", "window_id": "test.isolated"}],
                        [{"app_id": "test.isolated", "window_id": "242", "denied": True}],
                        self.windows * 2):
            with self.subTest(windows=windows):
                self.ctx.ext.reset_mock()
                self.windows = windows
                self.ctx.ext.side_effect = self.image
                with patch.object(capture.subprocess, "run") as run:
                    result = capture.capture_marker(self.ctx, "pane", "WEB PANE unique")
                self.assertFalse(result["drawn"])
                self.ctx.ext.assert_called_once()
                run.assert_not_called()

    def test_capture_refusal_stops_before_other_windows(self):
        self.windows *= 2
        self.windows[1] = {"app_id": "test.isolated", "window_id": "243"}
        self.ctx.ext.side_effect = [
            {"exit": 0, "json": {"windows": self.windows}},
            {"exit": 1, "error": "app_denied"},
        ]
        with patch.object(capture.subprocess, "run") as run:
            result = capture.capture_marker(self.ctx, "pane", "WEB PANE unique")
        self.assertFalse(result["drawn"])
        self.assertEqual(self.ctx.ext.call_count, 2)
        run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
