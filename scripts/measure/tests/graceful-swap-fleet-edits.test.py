#!/usr/bin/env python3
"""graceful-swap-fleet.py's saves still land: each EDITS anchor is in its file exactly once. When a page drops the
text a save edits (Settings lost its title on 2026-11-23), every film of that series showed nothing and read as a
missed hot swap. Reads EDITS from the source, so the test needs none of the fleet script's imports."""
import ast
import os
import re
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
SOURCE = open(os.path.join(HERE, "..", "graceful-swap-fleet.py"), encoding="utf-8").read()


def edits():
    block = re.search(r"^EDITS = (\{.*?^\})", SOURCE, re.S | re.M)
    assert block, "graceful-swap-fleet.py has no EDITS block"
    return ast.literal_eval(block.group(1))


class Anchors(unittest.TestCase):
    def test_each_anchor_is_in_its_file_once(self):
        for kind, (rel, plain, marked) in edits().items():
            with self.subTest(kind=kind):
                text = open(os.path.join(ROOT, rel), encoding="utf-8").read()
                self.assertEqual(text.count(plain), 1, f"{kind}: {rel} should hold {plain!r} once")
                self.assertNotIn(marked, text, f"{kind}: {rel} is left with the save's mark")


if __name__ == "__main__":
    unittest.main()
