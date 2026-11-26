#!/usr/bin/env python3
"""scripts/ci/shotdiff.py: perceptual compare, regions, content-addressed store, check and bless.

Run: uv run --with numpy --with pillow python3 tests/test_shotdiff.py
"""

from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "ci" / "shotdiff.py"


def load():
    spec = importlib.util.spec_from_file_location("shotdiff", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


sd = load()
np = sd.np
Image = sd.Image


def screen(width=120, height=200, seed=0):
    """A synthetic UI: a header bar, text-like stripes, a button, a soft gradient."""
    rng = np.random.default_rng(seed)
    img = np.full((height, width, 4), 255, dtype=np.uint8)
    img[..., :3] = np.linspace(235, 250, width, dtype=np.uint8)[None, :, None]
    img[:20, :, :3] = [30, 30, 40]
    for row in range(40, height - 40, 12):
        length = int(rng.integers(width // 3, width - 10))
        img[row:row + 4, 8:8 + length, :3] = [60, 60, 70]
    img[height - 30:height - 10, 20:width - 20, :3] = [0, 110, 230]
    return img


def png(arr) -> bytes:
    import io
    out = io.BytesIO()
    Image.fromarray(arr, "RGBA").save(out, format="PNG")
    return out.getvalue()


class CompareTest(unittest.TestCase):
    def test_identical_bytes(self):
        a = png(screen())
        r = sd.compare(a, a)
        self.assertTrue(r.ok and r.identical)
        self.assertEqual(r.ssim, 1.0)

    def test_same_pixels_different_encoding(self):
        arr = screen()
        import io
        out = io.BytesIO()
        Image.fromarray(arr, "RGBA").save(out, format="PNG", compress_level=1)
        r = sd.compare(png(arr), out.getvalue())
        self.assertTrue(r.identical)

    def test_dither_and_antialias_noise_pass(self):
        arr = screen()
        noisy = arr.copy()
        rng = np.random.default_rng(1)
        rgb = arr[..., :3].astype(int)
        edge = np.zeros(arr.shape[:2], dtype=bool)
        edge[1:, :] |= (np.abs(np.diff(rgb, axis=0)).max(axis=2) > 30)
        edge[:, 1:] |= (np.abs(np.diff(rgb, axis=1)).max(axis=2) > 30)
        jitter = rng.integers(-2, 3, size=rgb.shape)  # renderer dither everywhere
        jitter[edge] = rng.integers(-12, 13, size=(int(edge.sum()), 3))  # antialiasing on edges
        noisy[..., :3] = np.clip(rgb + jitter, 0, 255).astype(np.uint8)
        r = sd.compare(png(arr), png(noisy))
        self.assertTrue(r.ok, r.reasons)
        self.assertFalse(r.identical)
        self.assertEqual(r.changed, 0.0)

    def test_moved_button_fails(self):
        arr = screen()
        moved = arr.copy()
        moved[170:190, 20:100, :3] = arr[0, 60, :3]
        moved[150:170, 20:100, :3] = [0, 110, 230]
        r = sd.compare(png(arr), png(moved))
        self.assertFalse(r.ok)
        self.assertTrue(any("SSIM" in x or "moved" in x for x in r.reasons))
        x, y, w, h = r.box
        self.assertTrue(150 <= y <= 170 and w >= 70)

    def test_size_change_fails(self):
        r = sd.compare(png(screen(120, 200)), png(screen(120, 210)))
        self.assertFalse(r.ok)
        self.assertIn("size", r.reasons[0])

    def test_ignored_region_hides_clock(self):
        arr = screen()
        clock = arr.copy()
        clock[2:18, 80:118, :3] = [250, 250, 250]
        self.assertFalse(sd.compare(png(arr), png(clock)).ok)
        spec = {"regions": [{"name": "clock", "rect": [0.0, 0.0, 1.0, 0.1], "ignore": True}]}
        r = sd.compare(png(arr), png(clock), spec)
        self.assertTrue(r.ok, r.reasons)
        self.assertTrue(r.regions[0].ignored)

    def test_region_with_looser_bounds(self):
        arr = screen()
        glass = arr.copy()
        rng = np.random.default_rng(2)
        patch = glass[60:120, 10:110, :3].astype(int) + rng.integers(-40, 41, size=(60, 100, 3))
        glass[60:120, 10:110, :3] = np.clip(patch, 0, 255).astype(np.uint8)
        self.assertFalse(sd.compare(png(arr), png(glass)).ok)
        loose = {"regions": [{"name": "glass", "rect": [10, 60, 100, 60], "ssim_min": 0.3,
                              "changed_max": 1.0}]}
        r = sd.compare(png(arr), png(glass), loose)
        self.assertTrue(r.ok, r.reasons)
        self.assertLess(r.regions[0].ssim, 0.985)
        strict = {"regions": [{"name": "glass", "rect": [10, 60, 100, 60], "ssim_min": 0.99}]}
        r = sd.compare(png(arr), png(glass), strict)
        self.assertFalse(r.ok)
        self.assertTrue(any(x.startswith("glass:") for x in r.reasons))

    def test_transparent_pixels_compare_as_seen(self):
        a = np.zeros((40, 40, 4), dtype=np.uint8)
        b = a.copy()
        b[..., :3] = 255  # different hidden color, both fully transparent
        self.assertTrue(sd.compare(png(a), png(b)).ok)

    def test_diff_image_written_on_failure_only(self):
        arr = screen()
        moved = arr.copy()
        moved[100:140, 30:90, :3] = [200, 0, 0]
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "d.png"
            sd.compare(png(arr), png(arr), None, out)
            self.assertFalse(out.exists())
            sd.compare(png(arr), png(moved), None, out)
            self.assertTrue(out.exists())

    def test_unknown_spec_key_refused(self):
        with self.assertRaises(sd.ShotdiffError):
            sd.merge_spec({"ssim": 0.9})

    def test_fraction_and_pixel_rects(self):
        self.assertEqual(sd.region_box([0.5, 0.0, 0.5, 1.0], 100, 50), (50, 0, 100, 50))
        self.assertEqual(sd.region_box([1, 1, 10, 10], 100, 50), (1, 1, 11, 11))
        self.assertEqual(sd.region_box([90, 40, 50, 50], 100, 50), (90, 40, 100, 50))

    def test_phone_size_speed(self):
        a = screen(1179, 2556)
        b = a.copy()
        b[500:540, 100:600, :3] = 0
        start = time.monotonic()
        r = sd.compare(png(a), png(b))
        elapsed = time.monotonic() - start
        self.assertFalse(r.ok)
        print(f"\n  1179x2556 compare: {elapsed:.2f}s", file=sys.stderr)
        self.assertLess(elapsed, 20)


class StoreAndCheckTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.store = self.root / "store"
        self.shots = self.root / "shots"
        (self.shots / "iphone").mkdir(parents=True)
        self.manifest = self.root / "goldens.json"
        self.base = screen()
        (self.shots / "iphone" / "home.png").write_bytes(png(self.base))
        (self.shots / "iphone" / "settings.png").write_bytes(png(screen(seed=5)))

    def tearDown(self):
        self.tmp.cleanup()

    def run_cli(self, *args):
        return sd.main([str(a) for a in args])

    def test_put_get_is_content_addressed(self):
        data = png(self.base)
        store = sd.Store(str(self.store))
        digest = store.put(data)
        self.assertEqual(digest, sd.sha256_bytes(data))
        self.assertTrue((self.store / "objects" / digest[:2] / f"{digest}.png").is_file())
        self.assertEqual(store.put(data), digest)
        self.assertEqual(store.get(digest), data)

    def test_corrupt_object_refused(self):
        store = sd.Store(str(self.store))
        digest = store.put(png(self.base))
        (self.store / store.object_key(digest)).write_bytes(b"x")
        with self.assertRaises(sd.ShotdiffError):
            store.get(digest)

    def test_refs(self):
        store = sd.Store(str(self.store))
        digest = store.put(png(self.base))
        self.assertIsNone(store.ref_get("mac/inputs-abc"))
        store.ref_set("mac/inputs-abc", digest)
        self.assertEqual(store.ref_get("mac/inputs-abc"), digest)
        with self.assertRaises(sd.ShotdiffError):
            store.ref_set("../escape", digest)

    def test_bless_then_check_passes_then_catches_a_change(self):
        self.assertEqual(self.run_cli("bless", "--manifest", self.manifest, "--store", self.store,
                                      "--shots", self.shots), 0)
        manifest = json.loads(self.manifest.read_text())
        self.assertEqual(sorted(manifest["surfaces"]), ["iphone/home", "iphone/settings"])
        report = self.root / "summary.md"
        self.assertEqual(self.run_cli("check", "--manifest", self.manifest, "--store", self.store,
                                      "--shots", self.shots, "--report", report), 0)
        self.assertIn("2 identical", report.read_text())

        changed = self.base.copy()
        changed[60:120, 10:110, :3] = [255, 0, 0]
        (self.shots / "iphone" / "home.png").write_bytes(png(changed))
        (self.shots / "iphone" / "new-sheet.png").write_bytes(png(screen(seed=9)))
        diffs = self.root / "diffs"
        out_json = self.root / "out.json"
        self.assertEqual(self.run_cli("check", "--manifest", self.manifest, "--store", self.store,
                                      "--shots", self.shots, "--report", report, "--diff-dir", diffs,
                                      "--json-out", out_json), 1)
        text = report.read_text()
        self.assertIn("1 failed", text)
        self.assertIn("`iphone/new-sheet` | new", text)
        self.assertTrue((diffs / "iphone" / "home.diff.png").is_file())
        rows = {r["surface"]: r["status"] for r in json.loads(out_json.read_text())}
        self.assertEqual(rows, {"iphone/home": "failed", "iphone/settings": "same", "iphone/new-sheet": "new"})
        self.assertEqual(self.run_cli("check", "--manifest", self.manifest, "--store", self.store,
                                      "--shots", self.shots, "--report", report, "--warn-only"), 0)

    def test_missing_shot_and_missing_golden_fail(self):
        self.run_cli("bless", "--manifest", self.manifest, "--store", self.store, "--shots", self.shots)
        (self.shots / "iphone" / "settings.png").unlink()
        report = self.root / "r.md"
        self.assertEqual(self.run_cli("check", "--manifest", self.manifest, "--store", self.store,
                                      "--shots", self.shots, "--report", report), 1)
        self.assertIn("missing", report.read_text())
        empty = self.root / "empty-store"
        self.assertEqual(self.run_cli("check", "--manifest", self.manifest, "--store", empty,
                                      "--shots", self.shots, "--report", report), 1)
        self.assertIn("is not in", report.read_text())

    def test_manifest_spec_and_defaults_apply(self):
        self.run_cli("bless", "--manifest", self.manifest, "--store", self.store, "--shots", self.shots,
                     "iphone/home")
        manifest = json.loads(self.manifest.read_text())
        manifest["defaults"] = {"regions": [{"name": "status-bar", "rect": [0.0, 0.0, 1.0, 0.1], "ignore": True}]}
        self.manifest.write_text(json.dumps(manifest))
        clock = self.base.copy()
        clock[2:18, 80:118, :3] = [250, 250, 250]
        (self.shots / "iphone" / "home.png").write_bytes(png(clock))
        (self.shots / "iphone" / "settings.png").unlink()
        report = self.root / "r.md"
        self.assertEqual(self.run_cli("check", "--manifest", self.manifest, "--store", self.store,
                                      "--shots", self.shots, "--report", report), 0, report.read_text())
        self.assertIn("within", report.read_text())

    def test_compare_cli_exit_codes(self):
        a = self.shots / "iphone" / "home.png"
        b = self.shots / "iphone" / "settings.png"
        self.assertEqual(self.run_cli("compare", a, a), 0)
        self.assertEqual(self.run_cli("compare", a, b), 1)
        self.assertEqual(self.run_cli("compare", a, self.root / "nope.png"), 2)


if __name__ == "__main__":
    unittest.main()
