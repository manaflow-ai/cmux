import importlib.util
import json
import struct
import sys
import tempfile
import unittest
import zlib
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("same_pixels", HERE / "same_pixels.py")
same_pixels = importlib.util.module_from_spec(spec)
spec.loader.exec_module(same_pixels)


def png(path: Path, w: int, h: int) -> None:
    ihdr = struct.pack("!IIBBBBB", w, h, 8, 2, 0, 0, 0)
    chunk = lambda kind, data: struct.pack("!I", len(data)) + kind + data + struct.pack("!I", zlib.crc32(kind + data))
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IEND", b""))


def ppm(path: Path, w: int, h: int) -> None:
    path.write_bytes(f"P6\n{w} {h}\n255\n".encode() + b"\xff" * 3 * w * h)


class SamePixels(unittest.TestCase):
    def run_on(self, host_size, viewer_size, ocr, crop=None):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            png(d / "host.png", *host_size)
            ppm(d / "viewer", *viewer_size)
            (d / "ocr.json").write_text(json.dumps(ocr))
            argv = ["same_pixels.py", str(d / "ocr.json"), str(d / "host.png"), str(d / "viewer")]
            self.assertEqual(same_pixels.main(argv + ([crop] if crop else [])), 0)
            return json.loads((d / "ocr.json").read_text())

    def test_equal_sizes_are_ready_with_a_whole_image_receipt(self):
        out = self.run_on((64, 32), (64, 32), {"cer": 0.07, "host_chars": 10})
        self.assertIs(out["comparison_ready"], True)
        self.assertEqual(out["cer"], 0.07)
        self.assertEqual(out["crops"]["host_crop"], [0, 0, 64, 32])
        self.assertEqual(out["crops"]["viewer_pixels_per_host_pixel"], [1.0, 1.0])
        self.assertIn("same pixels", out["crops"]["coordinate_space"])

    def test_a_crop_is_kept_in_the_receipt(self):
        out = self.run_on((64, 32), (64, 32), {"cer": 0.0}, crop="0,8,64,24")
        self.assertIs(out["comparison_ready"], True)
        self.assertEqual(out["crops"]["viewer_crop"], [0, 8, 64, 24])

    def test_different_sizes_are_not_ready_and_say_why(self):
        out = self.run_on((64, 32), (32, 16), {"cer": 0.07})
        self.assertIs(out["comparison_ready"], False)
        self.assertIn("differ", out["crops"]["reason"])

    def test_no_cer_is_not_ready(self):
        out = self.run_on((64, 32), (64, 32), {"cer": None})
        self.assertIs(out["comparison_ready"], False)

    def test_eval_aggregate_reads_the_receipt_as_ready(self):
        # eval.py's aggregate needs comparison_ready true and a crops dict on every repeat.
        out = self.run_on((64, 32), (64, 32), {"cer": 0.07})
        self.assertIsInstance(out["crops"], dict)
        self.assertIs(out["crops"]["comparison_ready"], True)


if __name__ == "__main__":
    unittest.main()
