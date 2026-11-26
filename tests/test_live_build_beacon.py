#!/usr/bin/env python3
"""The `cmux live` build-done beacon (RFD 0152): a landed swap writes it where acpmux looks
(cmux-tui/crates/acpmux/src/hub/live_builds.rs), whole, with the tree; a failed build writes none."""
import importlib.util
import json
import os
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts/cmux-next" / file)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module  # dataclasses look their module up here
    spec.loader.exec_module(module)
    return module


beacon = load("live_build_beacon", "live_build_beacon.py")
rust_live = load("rust_live", "rust-live.py")
spec = importlib.util.spec_from_file_location("live_mode", ROOT / "scripts/live-code/live-mode.py")
live_mode = importlib.util.module_from_spec(spec)
sys.modules["live_mode"] = live_mode
spec.loader.exec_module(live_mode)


class Beacon(unittest.TestCase):
    def test_the_path_matches_the_daemons(self):
        with mock.patch.dict(os.environ, {"HOME": "/h", "XDG_CACHE_HOME": ""}, clear=False):
            os.environ.pop("CMUX_LIVE_BUILD_BEACON", None)
            want = ("/h/Library/Caches/cmux-next/live-build-done.json" if sys.platform == "darwin"
                    else "/h/.cache/cmux-next/live-build-done.json")
            self.assertEqual(str(beacon.beacon_path()), want)
        with mock.patch.dict(os.environ, {"CMUX_LIVE_BUILD_BEACON": "/x/b.json"}):
            self.assertEqual(str(beacon.beacon_path()), "/x/b.json")

    def test_a_swap_writes_the_tree_whole(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "deep/live-build-done.json"
            with mock.patch.dict(os.environ, {"CMUX_LIVE_BUILD_BEACON": str(path)}):
                before = int(time.time() * 1000)
                self.assertTrue(beacon.built("rust", tmp))
            entry = json.loads(path.read_text())
            self.assertEqual(entry["surface"], "rust")
            self.assertEqual(entry["tree"], str(Path(tmp).resolve()))
            self.assertGreaterEqual(entry["at"], before)
            self.assertEqual([p.name for p in path.parent.iterdir()], ["live-build-done.json"], "no staged file left")

    def test_an_unwritable_place_is_not_an_error(self):
        with mock.patch.dict(os.environ, {"CMUX_LIVE_BUILD_BEACON": "/proc/nope/b.json"}):
            self.assertFalse(beacon.built("rust", "/w"))


class RustLoop(unittest.TestCase):
    def record(self, outcome):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "b.json"
            loop = mock.Mock(state=Path(tmp) / "state", tree=Path(tmp), on_swap=None)
            with mock.patch.dict(os.environ, {"CMUX_LIVE_BUILD_BEACON": str(path)}):
                rust_live.Loop.record(loop, {"outcome": outcome})
            return json.loads(path.read_text()) if path.exists() else None

    def test_a_landed_swap_tells_acpmux(self):
        entry = self.record("swapped")
        self.assertEqual(entry["surface"], "rust")

    def test_a_failed_build_does_not(self):
        self.assertIsNone(self.record("build_failed"))


class SwiftLoop(unittest.TestCase):
    def test_an_applied_patch_tells_acpmux(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            log, path = tmp / "live-code.log", tmp / "b.json"
            log.write_text("")
            phases = live_mode.Phases(tmp / "phases.jsonl", log=log, tree=tmp)
            phases.waiting["patch1"] = (time.monotonic(), {"files": ["a.swift"], "placed_at": 1.0, "heard_at": 1.0})
            with log.open("a") as f:
                f.write("applied patch1.dylib ok load_ms=3 at=2.5\n")
            with mock.patch.dict(os.environ, {"CMUX_LIVE_BUILD_BEACON": str(path)}):
                phases.settle()
            self.assertEqual(json.loads(path.read_text())["surface"], "swift")


if __name__ == "__main__":
    unittest.main()
