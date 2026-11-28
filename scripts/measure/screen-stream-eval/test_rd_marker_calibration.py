"""rd_marker_calibration.py crops the rd ladder's OCR only from this repeat's marker in both actual images.

    python3 -I scripts/measure/screen-stream-eval/test_rd_marker_calibration.py
"""
import importlib.util
import json
import struct
import tempfile
import unittest
import zlib
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("rd_marker_calibration", HERE / "rd_marker_calibration.py")
cal = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cal)

NONCE = "9f10515277a8909021333b8268c3eea8"
OTHER = "0123456789abcdef0123456789abcdef"


def scene_for(display, nonce=NONCE, streamed_width=None, top=30.0):
    """scene.swift's geometry: cell = 32 * display points / streamed pixels, text below nine rows."""
    streamed_width = streamed_width or cal.stream_size((display[0] * 2, display[1] * 2))[0]
    cell = 32 * display[0] / streamed_width
    reserved = top + 9 * cell
    return {"schema": "cmux.source-scene/1", "nonce": nonce, "display_size_points": list(display),
            "marker_origin_points": [0, top], "cell_size_points": cell,
            "content_rect_points": [0, reserved, display[0], display[1] - reserved]}


def words_of(nonce):
    b = bytes.fromhex(nonce)
    return [b[i] | (b[i + 1] << 8) for i in range(0, 16, 2)]


def render(size, scene, nonce=NONCE, shift=(0, 0), noise=0, counter=0x5a5a):
    """The source display as an image of `size`: the marker drawn at the scene's geometry, the text
    region a stripe pattern. `shift` moves the marker in pixels; `noise` nudges every pixel's value."""
    w, h = size
    scale = w / scene["display_size_points"][0]
    rows = [bytearray(b"\xff" * 3 * w) for _ in range(h)]
    cx, cy, cw, ch = scene["content_rect_points"]
    for y in range(int(cy * scale), min(h, int((cy + ch) * scale))):
        if (y // 7) % 3 == 0:
            rows[y][:] = b"\x20" * (3 * w)
    cell = scene["cell_size_points"] * scale
    ox, oy = scene["marker_origin_points"][0] * scale + shift[0], scene["marker_origin_points"][1] * scale + shift[1]
    for row, word in enumerate([counter] + words_of(nonce)):
        for column in range(20):
            white = (word >> column) & 1 == 1 if column < 16 else [True, False, True, False][column - 16]
            x0, x1 = int(round(ox + column * cell)), int(round(ox + (column + 1) * cell))
            for y in range(int(round(oy + row * cell)), int(round(oy + (row + 1) * cell))):
                if 0 <= y < h:
                    lo, hi = max(0, x0), min(w, x1)
                    if hi > lo:
                        rows[y][3 * lo:3 * hi] = (b"\xff" if white else b"\x00") * (3 * (hi - lo))
    if noise:
        for r in rows:
            for i in range(0, len(r), 97):
                r[i] = max(0, r[i] - noise) if r[i] > 127 else min(255, r[i] + noise)
    return [bytes(r) for r in rows]


def write_png(path, rows, filters=(0,), alpha=False):
    """PNG with each row's filter cycling through `filters` (0 none .. 4 Paeth)."""
    w, channels = len(rows[0]) // 3, 4 if alpha else 3
    raw, prev = bytearray(), bytes(w * channels)
    for y, rgb in enumerate(rows):
        line = bytes(v for i in range(w) for v in (rgb[3 * i:3 * i + 3] + (b"\xff" if alpha else b""))) if alpha else rgb
        kind = filters[y % len(filters)]
        out = bytearray()
        for i, v in enumerate(line):
            a = line[i - channels] if i >= channels else 0
            b, c = prev[i], prev[i - channels] if i >= channels else 0
            if kind == 0:
                pred = 0
            elif kind == 1:
                pred = a
            elif kind == 2:
                pred = b
            elif kind == 3:
                pred = (a + b) >> 1
            else:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pred = a if pa <= pb and pa <= pc else b if pb <= pc else c
            out.append((v - pred) & 255)
        raw += bytes([kind]) + out
        prev = line
    chunk = lambda kind, data: struct.pack("!I", len(data)) + kind + data + struct.pack("!I", zlib.crc32(kind + data))
    ihdr = struct.pack("!IIBBBBB", w, len(rows), 8, 6 if alpha else 2, 0, 0, 0)
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(bytes(raw), 1))
                     + chunk(b"IEND", b""))


def write_ppm(path, rows):
    path.write_bytes(f"P6\n{len(rows[0]) // 3} {len(rows)}\n255\n".encode() + b"".join(rows))


DISPLAY = (480, 270)            # points; host screenshot 960x540 at 2 px/pt; stream the same size
HOST = (960, 540)
LADDER_DISPLAY = (2000, 1125)   # points; host 4000x2250 at 2 px/pt; stream fitted to 3840x2160
LADDER_HOST = (4000, 2250)


class Calibrate(unittest.TestCase):
    def run_case(self, scene, host_rows, viewer_rows, nonce=NONCE, host_filters=(0,)):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            (d / "scene.json").write_text(json.dumps(scene))
            write_png(d / "host.png", host_rows, host_filters)
            write_ppm(d / "viewer", viewer_rows)
            argv = ["rd_marker_calibration.py", "calibrate", str(d / "scene.json"), nonce, str(d / "host.png"),
                    str(d / "viewer"), str(d / "cal.json"), str(d / "viewer-crop.ppm")]
            code = cal.main(argv)
            result = json.loads((d / "cal.json").read_text())
            crop = (d / "viewer-crop.ppm").read_bytes() if (d / "viewer-crop.ppm").exists() else None
            return code, result, crop

    def test_same_size_frame_is_verified_with_crops_below_the_marker(self):
        scene = scene_for(DISPLAY)
        code, out, crop = self.run_case(scene, render(HOST, scene), render(HOST, scene, noise=40))
        self.assertEqual(code, 0, out.get("reason"))
        self.assertIs(out["verified"], True)
        self.assertEqual(out["observed_viewer_nonce"], NONCE)
        self.assertEqual(out["observed_host_nonce"], NONCE)
        top = round(scene["content_rect_points"][1] * 2)
        self.assertEqual(out["host_crop"], [0, top, 960, 540 - top])
        self.assertEqual(out["viewer_crop"], out["host_crop"])
        image = cal.read_ppm(crop)
        self.assertEqual((image.width, image.height), (960, 540 - top))

    def test_ladder_frame_scaled_to_the_stream_size_is_verified_at_its_own_scale(self):
        scene = scene_for(LADDER_DISPLAY)
        stream = cal.stream_size(LADDER_HOST)
        self.assertEqual(stream, (3840, 2160))
        code, out, crop = self.run_case(scene, render(LADDER_HOST, scene), render(stream, scene, noise=30))
        self.assertEqual(code, 0, out.get("reason"))
        self.assertAlmostEqual(out["viewer_pixels_per_host_pixel"], 0.96)
        self.assertEqual(out["viewer_crop"][2:], [3840, 2160 - out["viewer_crop"][1]])
        self.assertEqual(out["host_crop"][0:3], [0, round(scene["content_rect_points"][1] * 2), 4000])
        image = cal.read_ppm(crop)
        self.assertEqual((image.width, image.height), tuple(out["viewer_crop"][2:]))

    def test_every_png_filter_decodes_the_same_marker(self):
        scene = scene_for(DISPLAY)
        code, out, _ = self.run_case(scene, render(HOST, scene), render(HOST, scene), host_filters=(0, 1, 2, 3, 4))
        self.assertEqual(code, 0, out.get("reason"))

    def test_rung_frame_not_scaled_back_up_refuses(self):
        scene = scene_for(DISPLAY)
        code, out, crop = self.run_case(scene, render(HOST, scene), render((640, 360), scene))
        self.assertEqual(code, 1)
        self.assertIn("not the stream size 960x540", out["reason"])
        self.assertIsNone(crop)

    def test_viewer_showing_the_previous_repeat_refuses(self):
        scene = scene_for(DISPLAY)
        code, out, _ = self.run_case(scene, render(HOST, scene), render(HOST, scene, nonce=OTHER))
        self.assertEqual(code, 1)
        self.assertIn(f"viewer frame shows nonce {OTHER}", out["reason"])

    def test_host_screenshot_of_another_repeat_refuses(self):
        scene = scene_for(DISPLAY)
        code, out, _ = self.run_case(scene, render(HOST, scene, nonce=OTHER), render(HOST, scene))
        self.assertEqual(code, 1)
        self.assertIn("host screenshot shows nonce", out["reason"])

    def test_scene_from_another_repeat_refuses(self):
        scene = scene_for(DISPLAY, nonce=OTHER)
        code, out, _ = self.run_case(scene, render(HOST, scene, nonce=OTHER), render(HOST, scene, nonce=OTHER))
        self.assertEqual(code, 1)
        self.assertIn("is not this repeat's", out["reason"])

    def test_marker_moved_in_the_viewer_frame_refuses(self):
        scene = scene_for(DISPLAY)
        for shift in ((32, 0), (0, 32), (0, -32)):
            code, out, _ = self.run_case(scene, render(HOST, scene), render(HOST, scene, shift=shift))
            self.assertEqual(code, 1, shift)
            self.assertIn("in the viewer frame", out["reason"])

    def test_letterboxed_viewer_frame_refuses(self):
        scene = scene_for(DISPLAY)
        code, out, _ = self.run_case(scene, render(HOST, scene), render((960, 600), scene))
        self.assertEqual(code, 1)
        self.assertIn("display's aspect", out["reason"])

    def test_no_marker_in_the_host_screenshot_refuses(self):
        scene = scene_for(DISPLAY)
        blank = [b"\xff" * 3 * HOST[0]] * HOST[1]
        code, out, _ = self.run_case(scene, blank, render(HOST, scene))
        self.assertEqual(code, 1)
        self.assertIn("in the host screenshot", out["reason"])

    def test_scene_cell_not_the_stream_cell_refuses(self):
        scene = scene_for(DISPLAY, streamed_width=1920)  # a scene that thought the stream was wider
        code, out, _ = self.run_case(scene, render(HOST, scene), render(HOST, scene))
        self.assertEqual(code, 1)
        self.assertIn("not the 32 stream pixels", out["reason"])

    def test_malformed_nonce_refuses(self):
        scene = scene_for(DISPLAY)
        code, out, _ = self.run_case(scene, render(HOST, scene), render(HOST, scene), nonce="XYZ")
        self.assertEqual(code, 1)


class Receipt(unittest.TestCase):
    VERIFIED = {"schema": cal.SCHEMA, "verified": True, "expected_nonce": NONCE, "host_crop": [0, 1, 2, 3],
                "viewer_crop": [0, 1, 2, 3], "host_image": {"width": 4, "height": 4},
                "viewer_image": {"width": 4, "height": 4}, "viewer_pixels_per_host_pixel": 1.0}

    def test_verified_with_a_cer_is_ready(self):
        out = cal.receipt({"cer": 0.03}, self.VERIFIED)
        self.assertIs(out["comparison_ready"], True)
        self.assertEqual(out["cer"], 0.03)
        self.assertEqual(out["crops"]["current_source_nonce"], NONCE)

    def test_unverified_is_never_ready_and_carries_no_cer(self):
        out = cal.receipt({"cer": 0.03}, {"schema": cal.SCHEMA, "verified": False, "reason": "stale nonce"})
        self.assertIs(out["comparison_ready"], False)
        self.assertIsNone(out["cer"])
        self.assertIn("stale nonce", out["crops"]["reason"])

    def test_no_cer_is_not_ready(self):
        self.assertIs(cal.receipt({"cer": None}, self.VERIFIED)["comparison_ready"], False)
        self.assertIs(cal.receipt({"cer": float("nan")}, self.VERIFIED)["comparison_ready"], False)

    def test_cli_with_missing_files_writes_not_ready(self):
        with tempfile.TemporaryDirectory() as d:
            ocr = Path(d) / "ocr.json"
            self.assertEqual(cal.main(["x", "receipt", str(ocr), str(Path(d) / "none.json")]), 0)
            out = json.loads(ocr.read_text())
            self.assertIs(out["comparison_ready"], False)
            self.assertIsInstance(out["crops"], dict)


if __name__ == "__main__":
    unittest.main()
