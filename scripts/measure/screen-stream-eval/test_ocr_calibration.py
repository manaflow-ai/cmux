"""ocr_calibration.py binds a calibrated OCR crop to the run, verified only when both markers were located.

    python3 -s scripts/measure/screen-stream-eval/test_ocr_calibration.py
"""
import contextlib
import importlib.util
import io
import json
import re
import struct
import tempfile
import unittest
import zlib
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("ocr_calibration", HERE / "ocr_calibration.py")
cal = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cal)

# scene.swift's geometry on a 1920x1080 point display (seen in run c9339d12's source-scene-1.json).
SCENE = {"schema": "cmux.source-scene/1", "nonce": "9f10515277a8909021333b8268c3eea8",
         "display_size_points": [1920, 1080], "marker_origin_points": [0, 30], "cell_size_points": 32,
         "content_rect_points": [0, 318, 1920, 762]}
OBSERVER = {"schema": "cmux.presented-marker-series/2", "pid": 4242, "window": 77,
            "window_geometry_points": [100, 50, 1440, 838], "expected_nonce": SCENE["nonce"]}
READINESS = {"requested_host": "192.0.2.1", "quality_profile": "high", "expected_nonce": SCENE["nonce"],
             "observer": OBSERVER}
HOST = (1920, 1080)
HOST_MARKER = "origin 0,30 cell 32 at 704,46"
# Screen Sharing's window: a 28 px title bar, then the display at 0.75 (1440x810).
VIEWER = (1440, 838)
VIEWER_MARKER = "origin 0,50 cell 24 at 528,62"


def png(path: Path, w: int, h: int) -> None:
    chunk = lambda kind, data: struct.pack("!I", len(data)) + kind + data + struct.pack("!I", zlib.crc32(kind + data))
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack("!IIBBBBB", w, h, 8, 2, 0, 0, 0))
                     + chunk(b"IEND", b""))


class Calibrate(unittest.TestCase):
    def test_both_markers_give_a_verified_bound_calibration(self):
        out = cal.calibrate(SCENE, READINESS, HOST, VIEWER, HOST_MARKER, VIEWER_MARKER)
        self.assertIs(out["verified"], True, out.get("reason"))
        self.assertEqual(out["schema"], "cmux.screen-ocr-calibration/1")
        self.assertEqual(out["host_crop"], [0, 318, 1920, 762])
        # Fit by width: 1440 / 1920 = 0.75 px/pt; the display's top is 50 - 30 * 0.75 = 27.5.
        self.assertEqual(out["viewer_crop"], [0, 266, 1440, 572])
        self.assertIn("fit by width", out["evidence"])
        self.assertIn(SCENE["nonce"], out["evidence"])
        self.assertEqual(out["host_image"], {"width": 1920, "height": 1080})
        self.assertEqual(out["viewer_image"], {"width": 1440, "height": 838})
        self.assertEqual(out["source_content_rect_points"], SCENE["content_rect_points"])
        self.assertEqual(out["source_display_size_points"], SCENE["display_size_points"])
        self.assertEqual((out["requested_host"], out["quality_profile"]), ("192.0.2.1", "high"))
        self.assertEqual((out["pid"], out["window"], out["window_geometry_points"]), (4242, 77, [100, 50, 1440, 838]))

    def test_the_binding_covers_every_field_ocr_swift_compares(self):
        source = (HERE / "ocr.swift").read_text()
        block = source[source.index("let binding: [String: Any] = ["):]
        block = block[:block.index("\n    ]\n")]
        keys = set(re.findall(r'"([a-z_]+)":', block)) - {"width", "height"}  # image sizes' own keys
        self.assertEqual(len(keys), 11, keys)
        out = cal.calibrate(SCENE, READINESS, HOST, VIEWER, HOST_MARKER, VIEWER_MARKER)
        for key in keys:
            self.assertIsNotNone(out.get(key), key)

    def test_no_viewer_marker_is_not_verified(self):
        out = cal.calibrate(SCENE, READINESS, HOST, VIEWER, HOST_MARKER, "")
        self.assertIs(out["verified"], False)
        self.assertIn("viewer frame", out["reason"])
        self.assertNotIn("evidence", out)

    def test_no_host_marker_is_not_verified(self):
        out = cal.calibrate(SCENE, READINESS, HOST, VIEWER, "", VIEWER_MARKER)
        self.assertIs(out["verified"], False)
        self.assertIn("host screenshot", out["reason"])

    def test_a_host_cell_off_the_screenshot_scale_is_not_verified(self):
        out = cal.calibrate(SCENE, READINESS, HOST, VIEWER, "origin 0,60 cell 64 at 1408,92", VIEWER_MARKER)
        self.assertIs(out["verified"], False)
        self.assertIn("disagrees", out["reason"])

    def test_a_viewer_showing_part_of_the_display_is_not_verified(self):
        out = cal.calibrate(SCENE, READINESS, HOST, (900, 600), HOST_MARKER, VIEWER_MARKER)
        self.assertIs(out["verified"], False)
        self.assertIn("whole content rect", out["reason"])

    def test_missing_readiness_is_not_verified(self):
        out = cal.calibrate(SCENE, None, HOST, VIEWER, HOST_MARKER, VIEWER_MARKER)
        self.assertIs(out["verified"], False)
        self.assertIn("readiness", out["reason"])

    def test_a_retina_host_and_an_oversized_viewer_map_through_observe_pixels(self):
        # A 3840x2160 host shot (2 px/pt), and a 5120x2908 viewer window: the display at 8/3 px/pt below
        # a 28 px bar, so the marker sits at y 28 + 80 = 108 with 85.3 px cells. marker-locate fits the
        # window into 3840x2160 first (2160 / 2908 binds) and prints in those pixels.
        viewer = (5120, 2908)
        factor = cal.observe_factor(viewer)
        marker = f"origin 0,{round(108 * factor)} cell {round(85.333 * factor)} at 0,0"
        out = cal.calibrate(SCENE, READINESS, (3840, 2160), viewer, "origin 0,60 cell 64 at 1408,92", marker)
        self.assertIs(out["verified"], True, out.get("reason"))
        self.assertEqual(out["host_crop"], [0, 636, 3840, 1524])
        self.assertEqual(out["viewer_crop"][2], 5120)
        self.assertLessEqual(abs(out["viewer_crop"][1] - (28 + 318 * 5120 / 1920)), 3)

    def test_main_writes_the_file_and_prints_both_crops(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            (d / "scene.json").write_text(json.dumps(SCENE))
            (d / "ready.json").write_text(json.dumps(READINESS))
            png(d / "host.png", *HOST)
            png(d / "viewer", *VIEWER)
            argv = ["ocr_calibration.py", str(d / "scene.json"), str(d / "ready.json"), str(d / "host.png"),
                    str(d / "viewer"), HOST_MARKER, VIEWER_MARKER, str(d / "cal.json")]
            stdout = io.StringIO()
            with contextlib.redirect_stdout(stdout):
                self.assertEqual(cal.main(argv), 0)
            self.assertEqual(stdout.getvalue().split(), ["0,318,1920,762", "0,266,1440,572"])
            self.assertIs(json.loads((d / "cal.json").read_text())["verified"], True)
            argv[6] = ""
            with contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(cal.main(argv), 1)
            self.assertIs(json.loads((d / "cal.json").read_text())["verified"], False)


if __name__ == "__main__":
    unittest.main()
