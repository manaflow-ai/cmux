"""scripts/gallery-matrix/parity.py: pairs Linux and Mac gallery renders and judges each with shotdiff.

Needs numpy and Pillow: `uv run --with numpy --with pillow python3 tests/test_gallery_parity.py`.
"""
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
try:
    import numpy as np
    from PIL import Image
except ImportError:  # pragma: no cover - the CI python has them; a bare python skips
    np = None


def load_parity():
    spec = importlib.util.spec_from_file_location("gallery_parity", ROOT / "scripts/gallery-matrix/parity.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@unittest.skipIf(np is None or not (ROOT / "scripts/ci/shotdiff.py").exists(), "needs numpy, Pillow and shotdiff")
class ParityTest(unittest.TestCase):
    def setUp(self):
        self.parity = load_parity()
        self.dir = Path(tempfile.mkdtemp())
        rng = np.random.default_rng(1)
        self.base = (rng.random((120, 160, 3)) * 40 + 100).astype("uint8")

    def side(self, name, cases):
        folder = self.dir / name
        folder.mkdir()
        rows = []
        for case_id, image, extra in cases:
            row = {"id": case_id, "engine": "chromium", "params": {"entry": case_id.split("--")[0]}, **extra}
            if image is not None:
                Image.fromarray(image).save(folder / f"{case_id}-chromium.png")
                row["screenshot"] = f"{case_id}-chromium.png"
            rows.append(row)
        (folder / "results.json").write_text(json.dumps(rows))
        return folder

    def test_verdicts(self):
        moved = self.base.copy()
        moved[20:80, 20:120] = 255
        taller = np.concatenate([self.base, self.base[:10]])
        linux = self.side("linux", [("same--dark", self.base, {}), ("moved--dark", moved, {}),
                                    ("tall--dark", taller, {}), ("gone--dark", None, {"error": "never ready"})])
        mac = self.side("mac", [("same--dark", self.base, {}), ("moved--dark", self.base, {}),
                                ("tall--dark", self.base, {}), ("gone--dark", self.base, {})])
        tolerances = {"default": {"ssim_min": 0.97}, "entries": {"moved": {"mac_only": True, "why": "test"}}}
        report = self.parity.build(linux, mac, tolerances, None)
        verdicts = {p["id"]: p["verdict"] for p in report["pairs"]}
        self.assertEqual(verdicts, {"same--dark": "same", "moved--dark": "differs", "tall--dark": "size",
                                    "gone--dark": "missing"})
        self.assertTrue(report["entries"]["moved"]["mac_only"])
        self.assertIn("| moved |", self.parity.markdown(report))

    def test_strict_ignores_mac_only(self):
        moved = self.base.copy()
        moved[20:80, 20:120] = 255
        linux = self.side("linux", [("moved--dark", moved, {})])
        mac = self.side("mac", [("moved--dark", self.base, {})])
        tolerances = self.dir / "tol.json"
        tolerances.write_text(json.dumps({"default": {}, "entries": {"moved": {"mac_only": True}}}))
        args = ["--linux", str(linux), "--mac", str(mac), "--out", str(self.dir / "p.json"), "--tolerances", str(tolerances)]
        self.assertEqual(self.parity.main([*args, "--strict"]), 0)
        tolerances.write_text(json.dumps({"default": {}, "entries": {}}))
        self.assertEqual(self.parity.main([*args, "--strict"]), 1)


if __name__ == "__main__":
    sys.exit(unittest.main())
