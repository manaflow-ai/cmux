"""Builds the fixture family (fonts vendored in the repo, no network) and checks it, then breaks one face's
line box and expects check.py to refuse it.

Run: python3 -m unittest discover -s scripts/fonts/family/tests -v   (needs fontTools and brotli)
"""

from __future__ import annotations

import json
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

import build  # noqa: E402
import check  # noqa: E402
from fontTools.ttLib import TTFont  # noqa: E402


class FamilyBuildTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.out = Path(tempfile.mkdtemp(prefix="cmux-family-"))
        cls.manifest = build.build(HERE / "fixture.json", cls.out, ttf=False)

    @classmethod
    def tearDownClass(cls) -> None:
        shutil.rmtree(cls.out)

    def test_every_face_on_one_line_box(self) -> None:
        self.assertEqual(check.check(self.out, 8), [])

    def test_matched_faces_share_the_x_height(self) -> None:
        matched = [face for face in self.manifest["faces"] if face["name"] != "Display"]
        self.assertEqual({face["x_height"] for face in matched}, {520})

    def test_names_are_ours(self) -> None:
        for face in self.manifest["faces"]:
            names = TTFont(self.out / face["file"])["name"]
            self.assertEqual(names.getDebugName(16), f"Fixture Type {face['name']}")
            for record in names.names:
                if record.nameID not in (0, 13, 14) and record.nameID < 256:
                    self.assertNotIn("Fraunces", record.toUnicode())

    def test_weight_axis_survives(self) -> None:
        sans = next(face for face in self.manifest["faces"] if face["name"] == "Sans")
        self.assertEqual(sans["axes"], [["wght", 300.0, 400.0, 800.0]])

    def test_check_refuses_a_shifted_face(self) -> None:
        broken = Path(tempfile.mkdtemp(prefix="cmux-family-broken-"))
        try:
            shutil.copytree(self.out, broken, dirs_exist_ok=True)
            face = self.manifest["faces"][1]["file"]
            font = TTFont(broken / face)
            font["hhea"].ascent += 20
            font.save(broken / face)
            problems = check.check(broken, 8)
            self.assertTrue(any(face in problem and "hhea" in problem for problem in problems), problems)
        finally:
            shutil.rmtree(broken)

    def test_family_box_is_quillets(self) -> None:
        # The same 1.2 em box as Quillet (960 / -240), so swapping between the two families moves no line.
        self.assertEqual(self.manifest["line_box"], [960, -240])

    def test_box_from_ink_when_the_spec_names_none(self) -> None:
        spec = json.loads((HERE / "fixture.json").read_text())
        del spec["line_box"]
        spec_path = self.out / "auto.json"
        spec_path.write_text(json.dumps(spec))
        manifest = build.build(spec_path, self.out / "auto", ttf=False)
        ascender, descender = manifest["line_box"]
        self.assertGreater(ascender, 900)
        self.assertLess(descender, -200)
        self.assertEqual(check.check(self.out / "auto", 8), [])

    def test_face_limit(self) -> None:
        spec = json.loads((HERE / "fixture.json").read_text())
        spec["faces"] = spec["faces"] * 3
        spec_path = self.out / "too-many.json"
        spec_path.write_text(json.dumps(spec))
        with self.assertRaises(SystemExit) as raised:
            build.build(spec_path, self.out / "too-many", ttf=False)
        self.assertIn("limit is 8", str(raised.exception))


if __name__ == "__main__":
    unittest.main()
