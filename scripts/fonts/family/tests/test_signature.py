"""The signature axis machinery, with a test-only kind (dots become squares; not a design choice): the axis
lands in fvar, the swap reaches simple glyphs and composites at every weight, and the line box holds.

Run: python3 -m unittest discover -s scripts/fonts/family/tests -v
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
import signature  # noqa: E402
from fontTools.pens.boundsPen import BoundsPen  # noqa: E402
from fontTools.ttLib import TTFont  # noqa: E402


@signature.kind("test-square", ["i", "j", "period", "colon", "idieresis"])
def square(contour, glyph_name, step):
    if not signature.is_dot(contour):
        return None
    x0, y0, x1, y1 = signature.bounds(contour)
    return [[(x0, y0, True), (x0, y1, True), (x1, y1, True), (x1, y0, True)]]


SIGNATURE = {
    "kind": "test-square",
    "tag": "TSIG",
    "name": "Test signature",
    "steps": [{"name": "Plain", "from": 0, "to": 50}, {"name": "Square", "from": 50, "to": 100}],
}




class SignatureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        spec = json.loads((HERE / "fixture.json").read_text())
        spec["signature"] = SIGNATURE
        cls.dir = Path(tempfile.mkdtemp(prefix="cmux-sig-"))
        spec_path = cls.dir / "spec.json"
        spec_path.write_text(json.dumps(spec))
        cls.out = cls.dir / "out"
        cls.manifest = build.build(spec_path, cls.out, ttf=False)

    @classmethod
    def tearDownClass(cls) -> None:
        shutil.rmtree(cls.dir)

    def fonts(self):
        for face in self.manifest["faces"]:
            yield face, TTFont(self.out / face["file"])

    def test_axis_on_every_face(self) -> None:
        for face, font in self.fonts():
            tags = [axis.axisTag for axis in font["fvar"].axes]
            self.assertIn("TSIG", tags, face["file"])
            self.assertIn("Square", [font["name"].getDebugName(i.subfamilyNameID) for i in font["fvar"].instances])

    def signature_swap(self, font: TTFont) -> dict[str, str]:
        mine = [mapping for box, mapping in signature.swaps(font) if "TSIG" in box]
        self.assertEqual(len(mine), 1)
        return mine[0]

    def test_swap_draws_a_square_dot_at_every_weight(self) -> None:
        for face, font in self.fonts():
            mapping = self.signature_swap(font)
            cmap = font.getBestCmap()
            for char in "i.:":
                self.assertIn(cmap[ord(char)], mapping, f"{face['file']} {char!r}")
            has_wght = any(a.axisTag == "wght" for a in font["fvar"].axes)
            for wght in (300, 400, 700) if has_wght else (None,):
                glyphs = font.getGlyphSet(location={"wght": wght} if wght else {})
                for char in "i.":
                    plain, swapped = BoundsPen(glyphs), BoundsPen(glyphs)
                    glyphs[cmap[ord(char)]].draw(plain)
                    glyphs[mapping[cmap[ord(char)]]].draw(swapped)
                    # The square fills the round dot's box: the same bounds, at every weight.
                    for a, b in zip(plain.bounds, swapped.bounds):
                        self.assertAlmostEqual(a, b, delta=3, msg=f"{face['file']} {char!r} wght {wght}")
                    self.assertEqual(glyphs[cmap[ord(char)]].width, glyphs[mapping[cmap[ord(char)]]].width)

    def test_composites_follow(self) -> None:
        for face, font in self.fonts():
            name = font.getBestCmap()[ord("ï")]
            if font["glyf"][name].isComposite():
                self.assertIn(name, self.signature_swap(font), face["file"])

    def test_line_box_holds(self) -> None:
        self.assertEqual(check.check(self.out, 8), [])

    def test_unknown_kind_is_refused(self) -> None:
        font = TTFont(self.out / self.manifest["faces"][0]["file"])
        with self.assertRaises(SystemExit):
            signature.apply_signature(font, {**SIGNATURE, "kind": "nope"}, {})


if __name__ == "__main__":
    unittest.main()


class WeftTests(unittest.TestCase):
    """The Selvedge axis (`WEFT`): the fixture family with the real kind."""

    @classmethod
    def setUpClass(cls) -> None:
        spec = json.loads((HERE / "fixture.json").read_text())
        spec["signature"] = {"kind": "weft", "tag": "WEFT", "name": "Selvedge", "max": 100}
        cls.dir = Path(tempfile.mkdtemp(prefix="cmux-weft-"))
        (cls.dir / "spec.json").write_text(json.dumps(spec))
        cls.manifest = build.build(cls.dir / "spec.json", cls.dir / "out", ttf=False)

    @classmethod
    def tearDownClass(cls) -> None:
        shutil.rmtree(cls.dir)

    def test_threads_grow_and_nothing_reflows(self) -> None:
        from fontTools.pens.boundsPen import BoundsPen as Bounds

        for face in self.manifest["faces"]:
            font = TTFont(self.dir / "out" / face["file"])
            self.assertIn("WEFT", [a.axisTag for a in font["fvar"].axes])
            cmap = font.getBestCmap()
            for char in "nhl":
                name = cmap[ord(char)]
                cut, weft = font.getGlyphSet(location={"WEFT": 0}), font.getGlyphSet(location={"WEFT": 100})
                self.assertEqual(cut[name].width, weft[name].width, f"{face['file']} {char}")
                b0, b1 = Bounds(cut), Bounds(weft)
                cut[name].draw(b0)
                weft[name].draw(b1)
                advance = cut[name].width
                # At 0 the thread has no area and sits on the stem foot: the glyph keeps its own bounds. At 100 it
                # reaches past the advance, toward the next letter, from the baseline up.
                self.assertLess(b0.bounds[2], advance + 5, f"{face['file']} {char}")
                self.assertGreaterEqual(b1.bounds[2], advance + 25, f"{face['file']} {char}")
                self.assertGreaterEqual(b1.bounds[1], b0.bounds[1] - 1, f"{face['file']} {char}")

    def test_box_holds(self) -> None:
        self.assertEqual(check.check(self.dir / "out", 8), [])
