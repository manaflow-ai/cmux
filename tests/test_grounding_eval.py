#!/usr/bin/env python3
"""scripts/measure/grounding-eval/grounding_eval.py: prompts, parsers, scaling and scoring.

The end-to-end case runs `run` against a fake OpenAI-compatible server that answers like each model
family, on generated screenshots, so a parser or coordinate bug shows as a wrong accuracy. Needs Pillow.
Run: python3 tests/test_grounding_eval.py (about 2 s, no GPU, no network).
"""
from __future__ import annotations

import http.server
import importlib.util
import json
import sys
import tempfile
import threading
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("grounding_eval", ROOT / "scripts/measure/grounding-eval/grounding_eval.py")
ge = importlib.util.module_from_spec(SPEC)
sys.modules["grounding_eval"] = ge
SPEC.loader.exec_module(ge)


class SmartResizeTests(unittest.TestCase):
    def test_multiple_of_factor_and_within_bounds(self):
        h, w = ge.smart_resize(1440, 2560, 28, 3136, 12845056)
        self.assertEqual((h % 28, w % 28), (0, 0))
        self.assertEqual((h, w), (1428, 2548))

    def test_downscales_over_max(self):
        h, w = ge.smart_resize(2880, 5120, 28, 3136, 4800000)
        self.assertLessEqual(h * w, 4800000)
        self.assertAlmostEqual(w / h, 5120 / 2880, delta=0.05)

    def test_upscales_under_min(self):
        h, w = ge.smart_resize(1080, 1920, 28, 2000000, 4800000)
        self.assertGreaterEqual(h * w, 2000000)


class ParserTests(unittest.TestCase):
    def test_holo_json_is_thousandths_of_the_sent_image(self):
        self.assertEqual(ge.parse_point("holo", '{"x": 500, "y": 250}', 2000, 1000), (1000.0, 250.0))

    def test_holo_ignores_thinking(self):
        text = "<think>the x is 900</think>{'x': 100, 'y': 100}"
        self.assertEqual(ge.parse_point("holo", text, 1000, 1000), (100.0, 100.0))

    def test_opencua_pyautogui(self):
        self.assertEqual(ge.parse_point("opencua", "```python\npyautogui.click(x=1443, y=343)\n```", 1, 1),
                         (1443.0, 343.0))

    def test_gta1_pair(self):
        self.assertEqual(ge.parse_point("gta1", "(812,77)", 1, 1), (812.0, 77.0))

    def test_venus_box_center(self):
        self.assertEqual(ge.parse_point("venus", "[100,200,300,400]", 1, 1), (200.0, 300.0))

    def test_unparseable_is_none(self):
        for family in ("holo", "opencua", "gta1", "venus"):
            self.assertIsNone(ge.parse_point(family, "I cannot find it.", 100, 100), family)


class TargetTests(unittest.TestCase):
    def test_box_edges_count(self):
        target = {"kind": "box", "box": [10, 10, 20, 20]}
        self.assertTrue(ge.point_in_target(10, 20, target))
        self.assertFalse(ge.point_in_target(21, 15, target))

    def test_polygon(self):
        target = {"kind": "polygon", "points": [(0, 0), (10, 0), (10, 10), (0, 10)]}
        self.assertTrue(ge.point_in_target(5, 5, target))
        self.assertFalse(ge.point_in_target(15, 5, target))


class FakeServer(http.server.BaseHTTPRequestHandler):
    """Answers like `family` would, aiming at the center of the box named in the instruction."""
    family = "holo"
    requests: list[dict] = []

    def log_message(self, *args):
        pass

    def do_GET(self):
        self._reply({"data": [{"id": "fake"}]})

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        FakeServer.requests.append(body)
        from PIL import Image
        import base64, io
        url = body["messages"][-1]["content"][0]["image_url"]["url"]
        image = Image.open(io.BytesIO(base64.b64decode(url.split(",", 1)[1])))
        w, h = image.size
        text = body["messages"][-1]["content"][1]["text"]
        # Instructions are "click at FX,FY": the fraction of the image to aim at.
        fx, fy = (float(v) for v in text.rsplit("click at ", 1)[1].split()[0].rstrip(".").split(","))
        x, y = fx * w, fy * h
        answer = {
            "holo": json.dumps({"x": round(fx * 1000), "y": round(fy * 1000)}),
            "opencua": f"pyautogui.click(x={x:.0f}, y={y:.0f})",
            "gta1": f"({x:.0f},{y:.0f})",
            "venus": f"[{x - 2:.0f},{y - 2:.0f},{x + 2:.0f},{y + 2:.0f}]",
        }[FakeServer.family]
        self._reply({"choices": [{"message": {"content": answer}}], "timings": {"peak_memory_gb": 3.5}})

    def _reply(self, payload):
        data = json.dumps(payload).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


class EndToEndTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        try:
            import PIL  # noqa: F401
        except ImportError:
            raise unittest.SkipTest("Pillow is not installed")
        cls.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), FakeServer)
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()
        cls.endpoint = f"http://127.0.0.1:{cls.server.server_address[1]}/v1"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def make_data(self, root: Path) -> None:
        from PIL import Image
        ssp = root / "screenspot-pro"
        (ssp / "annotations").mkdir(parents=True)
        (ssp / "images" / "app").mkdir(parents=True)
        Image.new("RGB", (2560, 1440), "white").save(ssp / "images/app/a.png")
        rows = [
            # Right: the fake aims at the box center.
            {"img_filename": "app/a.png", "bbox": [1000, 500, 1100, 560], "instruction": "click at 0.41015625,0.36805556",
             "id": "a0", "group": "Creative", "ui_type": "icon"},
            # Wrong: the fake aims far from the box.
            {"img_filename": "app/a.png", "bbox": [10, 10, 40, 40], "instruction": "click at 0.9,0.9",
             "id": "a1", "group": "Office", "ui_type": "text"},
        ]
        (ssp / "annotations/app.json").write_text(json.dumps(rows))
        owg = root / "osworld-g"
        (owg / "images").mkdir(parents=True)
        Image.new("RGB", (1920, 1080), "white").save(owg / "images/b.png")
        (owg / "annotations.json").write_text(json.dumps([
            {"id": "b0", "image_path": "b.png", "image_size": [1920, 1080], "instruction": "click at 0.5,0.5",
             "box_type": "bbox", "box_coordinates": [940, 520, 40, 40], "GUI_types": ["Icon"]},
            {"id": "b1", "image_path": "b.png", "image_size": [1920, 1080], "instruction": "click at 0.25,0.25",
             "box_type": "polygon", "box_coordinates": [460, 250, 500, 250, 500, 290, 460, 290], "GUI_types": ["Button"]},
        ]))

    def test_every_family_scores_the_same_answers(self):
        for model, family in [("holo-3.1-4b", "holo"), ("opencua-7b", "opencua"), ("gta1-7b", "gta1"),
                              ("ui-venus-ground-7b", "venus")]:
            with self.subTest(family=family), tempfile.TemporaryDirectory() as tmp:
                tmp = Path(tmp)
                self.make_data(tmp / "data")
                FakeServer.family = family
                FakeServer.requests = []
                out = tmp / "r.json"
                code = ge.main(["run", "--data", str(tmp / "data"), "--model", model, "--endpoint", self.endpoint,
                                "--server", "fake", "--out", str(out)])
                self.assertEqual(code, 0)
                result = json.loads(out.read_text())
                ssp, owg = result["benchmarks"]["screenspot-pro"], result["benchmarks"]["osworld-g"]
                self.assertEqual((ssp["n"], ssp["correct"]), (2, 1))
                self.assertEqual(ssp["canvas"], {"n": 1, "accuracy": 1.0})
                self.assertEqual(ssp["by_group"]["Office"]["accuracy"], 0.0)
                self.assertEqual((owg["n"], owg["correct"]), (2, 2))
                self.assertEqual(result["memory_gb"]["peak"], 3.5)
                self.assertEqual(result["latency_ms"]["n"], 4)
                body = FakeServer.requests[0]
                self.assertEqual(body["temperature"], 0.0)
                self.assertFalse(body["chat_template_kwargs"]["enable_thinking"])
                if family == "gta1":
                    self.assertIn("height 1428 and width 2548", body["messages"][0]["content"])
                table = ge.summarize([str(out)])
                self.assertIn(f"| {model} |", table)

    def test_resume_keeps_finished_samples(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            self.make_data(tmp / "data")
            FakeServer.family = "holo"
            out = tmp / "r.json"
            args = ["run", "--data", str(tmp / "data"), "--model", "holo2-4b", "--endpoint", self.endpoint,
                    "--bench", "osworld-g", "--out", str(out)]
            self.assertEqual(ge.main(args), 0)
            FakeServer.requests = []
            self.assertEqual(ge.main(args + ["--resume"]), 0)
            self.assertEqual(FakeServer.requests, [])
            result = json.loads(out.read_text())
            self.assertEqual(result["benchmarks"]["osworld-g"]["correct"], 2)
            self.assertEqual((result["latency_ms"]["n"], result["memory_gb"]["peak"]), (2, 3.5))


if __name__ == "__main__":
    unittest.main()
