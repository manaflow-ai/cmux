"""Integration tests run by cargo test --test inputkey with its freshly built shotdiff."""
import importlib.util
import json
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import zlib

ROOT = Path(__file__).resolve().parents[4]
sys.path.insert(0, str(ROOT / "scripts/cmux-next"))
import desktop_goldens as goldens


def png(path, size, shade=0):
    width, height = size

    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data))

    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    data = zlib.compress((b"\0" + bytes([shade]) * (3 * width)) * height)
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", data) + chunk(b"IEND", b""))


class DesktopGoldens(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.repo = Path(tmp.name)
        self.root = self.repo / "stores"
        self.runtime = "macos-25A-2x"
        self.cases = [{"id": "hello", "params": {"width": 400}}]
        self.git("init", "-q")
        (self.repo / ".github").mkdir()
        shutil.copy(ROOT / ".github/golden-inputs.json", self.repo / ".github")
        self.change("Packages/macOS/CmuxNext/Sources/View.swift", "v1")
        self.addCleanup(patch.stopall)
        patch.object(goldens, "ROOT", self.repo).start()

    def git(self, *args):
        subprocess.run(["git", "-C", self.repo, "-c", "user.name=Test", "-c", "user.email=test@example.com",
                        "-c", "commit.gpgsign=false", *args], check=True, stdout=subprocess.DEVNULL)

    def change(self, name, value):
        path = self.repo / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(value)
        self.git("add", name)
        self.git("commit", "-qm", name)

    def store(self, engine="webkit", runtime=None, cases=None, rev="HEAD"):
        return goldens.gallery_store(self.root, runtime or self.runtime, rev, engine,
                                     cases or self.cases, goldens.GALLERY_SELECTOR)

    def cli(self, operation, folder, *extra):
        with patch.object(sys, "argv", ["desktop_goldens", operation, "--dir", str(folder), "--root", str(self.root),
                                       "--runtime", self.runtime, "--rev", "HEAD", *map(str, extra)]):
            goldens.main()

    def test_source_runtime_variant_and_recipe(self):
        original = self.store()
        chrome = lambda: goldens.store_path(self.root, self.runtime, "HEAD", "desktop-chrome", "look-rest-2x")
        chrome_first = chrome()
        self.assertNotEqual(original, self.store("chromium"))
        self.assertNotEqual(original, self.store(runtime="macos-25B-2x"))
        self.assertNotEqual(original, self.store(cases=[{"id": "hello", "params": {"width": 800}}]))
        self.change("cmux-next-ios/Views/Other.swift", "unrelated")
        self.assertEqual(original, self.store())
        self.assertEqual(chrome_first, chrome())
        self.change("Packages/macOS/CmuxNext/Sources/View.swift", "v2")
        self.assertNotEqual(original, self.store())
        self.assertNotEqual(chrome_first, chrome())
        self.assertEqual(original, self.store(rev="HEAD~1"))
        current = self.store()
        self.change("webviews/src/gallery/hello.ts", "changed pixels")
        self.assertNotEqual(current, self.store())

    def test_gallery_driver_restores_with_b7_metadata(self):
        manifest = self.repo / "manifest.json"
        manifest.write_text(json.dumps(self.cases))
        metadata = {"family": "desktop-gallery", "runtime": "mac-gallery", "variants": {}}
        for engine in ("chromium", "webkit"):
            key = {"key": engine + "-key", "revision": "HEAD"}
            metadata["variants"][engine] = key
            filename = f"hello-{engine}.png"
            png(self.repo / filename, (4, 4))
            rows = [{"id": "hello", "engine": engine, "ready": True,
                     "screenshot": filename, "input_key": key}]
            goldens.file_gallery(self.store(engine), self.cases, rows, engine, self.repo)
        keys = self.repo / "input-keys.json"
        keys.write_text(json.dumps(metadata))
        out = self.repo / "render"
        app_binary = self.repo / "Test.app/Contents/MacOS/Test"
        app_binary.parent.mkdir(parents=True)
        app_binary.touch()
        argv = ["gallery-mac-reference", "--tag", "test", "--app", str(self.repo / "Test.app"),
                "--gallery", str(self.repo), "--manifest", str(manifest), "--out", str(out),
                "--golden-root", str(self.root), "--runtime", self.runtime, "--rev", "HEAD",
                "--input-keys", str(keys)]
        spec = importlib.util.spec_from_file_location(
            "gallery_reference_test", ROOT / "scripts/cmux-next/gallery-mac-reference.py")
        driver = importlib.util.module_from_spec(spec)
        with patch.object(sys, "argv", argv), patch("socketserver.ThreadingTCPServer"), patch("threading.Thread"):
            spec.loader.exec_module(driver)
        with patch.object(driver, "run_engine", side_effect=AssertionError("cache hit must not capture")):
            self.assertEqual(driver.main(), 0)
        run = json.loads((out / "run.json").read_text())
        self.assertEqual(run["input_keys"], metadata)
        self.assertEqual(run["reference_runtime"], self.runtime)
        self.assertEqual(run["revision"], "HEAD")
        rows = json.loads((out / "results.json").read_text())
        for row in rows:
            self.assertEqual(row["input_key"], metadata["variants"][row["engine"]])
            self.assertTrue((out / row["screenshot"]).is_file())

    def test_gallery_restore_preserves_first_complete_render(self):
        for engine in ("chromium", "webkit"):
            filename = f"hello-{engine}.png"
            rows = [{"id": "hello", "engine": engine, "ready": True, "screenshot": filename}]
            png(self.repo / filename, (4, 4))
            store = self.store(engine)
            with self.assertRaises(ValueError):
                goldens.file_gallery(store, self.cases, [dict(rows[0], error="timeout")], engine, self.repo)
            self.assertFalse(store.exists())
            goldens.file_gallery(store, self.cases, rows, engine, self.repo)
            png(self.repo / filename, (4, 4), 255)
            goldens.file_gallery(store, self.cases, rows, engine, self.repo)
        manifest = self.repo / "cases.json"
        manifest.write_text(json.dumps(self.cases))
        restored = self.repo / "restored"
        self.cli("restore-gallery", restored, "--manifest", manifest)
        rows = json.loads((restored / "results.json").read_text())
        self.assertEqual([row["engine"] for row in rows], ["chromium", "webkit"])
        reference = self.repo / "reference.png"
        png(reference, (4, 4))
        for row in rows:
            goldens.shotdiff("compare", reference, restored / row["screenshot"])

    def test_native_crops_round_trip_or_fail_as_a_set(self):
        for name, size in zip(goldens.CROPS, [(640, 400), (380, 800), (1280, 40)]):
            png(self.repo / f"{name}.png", size)
        self.cli("file-chrome", self.repo)
        restored = self.repo / "crops"
        self.cli("restore-chrome", restored)
        for name in goldens.CROPS:
            goldens.shotdiff("compare", self.repo / f"{name}.png", restored / f"{name}.png")
        png(self.repo / "ref-sidebar.png", (190, 400))
        with self.assertRaises(ValueError):
            self.cli("file-chrome", self.repo)


if __name__ == "__main__":
    unittest.main()
