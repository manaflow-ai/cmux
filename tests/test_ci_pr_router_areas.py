#!/usr/bin/env python3
"""The PR router routes by CI area (pr_router.py change_areas, reaches; RFD 0023 plus the CI area map).

Leo, ask-5ad71ec59c clause 11: "The existing changes job already routes work, so it would output areas instead of
raw path filters, and a PR runs only what its areas need." The route job writes `areas` (the change's [[area]]
names of docs/benches/relevance-map.toml, or `all` when it cannot tell), and a callee with `areas` starts only
when the change touches one of them (or one of its `affects` globs). An unreadable map starts it (fail open).
"""
from __future__ import annotations

import json
import os
import re
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/ci"))
import pr_router  # noqa: E402

LAYOUT = "Packages/macOS/CmuxNext/Sources/CmuxNextLayout/Model/LayoutModel.swift"
PALETTE = "Packages/macOS/CmuxNext/Sources/CmuxNextPalette/PaletteView.swift"
MOTION = "cmux-next-motion-frames.yml"
EVENT = {"action": "synchronize", "pull_request": {"draft": False}}


class ChangeAreas(unittest.TestCase):
    def test_paths_take_their_area(self):
        self.assertEqual(pr_router.change_areas([LAYOUT, PALETTE]), ["Palette and omnibar", "Pane layout"])

    def test_unmapped_path_takes_a_default_area(self):
        got = pr_router.change_areas(["zz-nowhere/file.txt"])
        self.assertEqual(got, ["default:zz-nowhere"])

    def test_unknown_files_or_map_mean_all(self):
        self.assertIsNone(pr_router.change_areas(None))
        with tempfile.TemporaryDirectory() as d:
            bad = Path(d) / "map.toml"
            bad.write_text("[[area]\nbroken")
            self.assertIsNone(pr_router.change_areas([LAYOUT], bad))
            self.assertIsNone(pr_router.change_areas([LAYOUT], Path(d) / "missing.toml"))

    def test_areas_output(self):
        self.assertEqual(pr_router.areas_output(None), "all")
        self.assertEqual(json.loads(pr_router.areas_output([LAYOUT])), ["Pane layout"])
        with tempfile.TemporaryDirectory() as d:
            out = Path(d) / "out"
            old = os.environ.get("GITHUB_OUTPUT")
            os.environ["GITHUB_OUTPUT"] = str(out)
            os.environ.pop("GITHUB_STEP_SUMMARY", None)
            try:
                pr_router.write_outputs([], {}, [PALETTE])
            finally:
                if old is None:
                    os.environ.pop("GITHUB_OUTPUT")
                else:
                    os.environ["GITHUB_OUTPUT"] = old
            line = next(l for l in out.read_text().splitlines() if l.startswith("areas="))
            self.assertEqual(json.loads(line.split("=", 1)[1]), ["Palette and omnibar"])


class Reaches(unittest.TestCase):
    config = {"areas": ["Pane layout"], "affects": [".github/workflows/x.yml"]}

    def test_area_hit_and_miss(self):
        self.assertTrue(pr_router.reaches(self.config, [LAYOUT]))
        self.assertFalse(pr_router.reaches(self.config, [PALETTE]))

    def test_affects_glob_still_reaches(self):
        self.assertTrue(pr_router.reaches(self.config, [".github/workflows/x.yml"]))

    def test_no_areas_key_is_affects_alone(self):
        self.assertTrue(pr_router.reaches({}, [PALETTE]))
        self.assertFalse(pr_router.reaches({"affects": ["a/**"]}, [PALETTE]))

    def test_unreadable_map_fails_open(self):
        with tempfile.TemporaryDirectory() as d:
            self.assertTrue(pr_router.reaches({"areas": ["Pane layout"]}, [PALETTE], Path(d) / "missing.toml"))


class MotionFramesReadsAreas(unittest.TestCase):
    def setUp(self):
        self.callees = json.loads((ROOT / "scripts/ci/pr_router.json").read_text())["callees"]

    def test_motion_frames_routes_by_area(self):
        self.assertEqual(self.callees[MOTION]["areas"], ["Pane layout", "Palette and omnibar"])
        for path in (LAYOUT, PALETTE):
            start, why = pr_router.route(EVENT, {MOTION: self.callees[MOTION]}, [path])
            self.assertIn(MOTION, start, why)
        start, why = pr_router.route(EVENT, {MOTION: self.callees[MOTION]}, ["web/src/app.ts"])
        self.assertNotIn(MOTION, start, why)

    def test_every_callee_area_is_a_map_area(self):
        known = pr_router.area_names()
        for name, config in self.callees.items():
            self.assertLessEqual(set(config.get("areas", [])), known, name)

    def test_route_job_checks_out_the_map_and_exports_areas(self):
        text = (ROOT / ".github/workflows/pr-router.yml").read_text()
        for path in ("docs/benches/relevance-map.toml", "scripts/bench/benchlib/__init__.py",
                     "scripts/bench/benchlib/relevance.py"):
            self.assertRegex(text, rf"(?m)^\s+{re.escape(path)}$")
        self.assertIn("areas: ${{ steps.route.outputs.areas }}", text)

    def test_relevance_imports_only_stdlib(self):
        # The route job's sparse checkout holds relevance.py and its package marker only.
        src = (ROOT / "scripts/bench/benchlib/relevance.py").read_text()
        local = re.findall(r"(?m)^\s*from \.|^\s*from benchlib|^\s*import benchlib", src)
        self.assertEqual(local, [])


if __name__ == "__main__":
    unittest.main()
