#!/usr/bin/env python3
"""web-bundle-key.py's relative_specifiers finds exactly what its SPECIFIER regex finds, in the same order.

The regex tried every lead-in at every character: 9.5 s over webviews/ on Python 3.9, most of `cmux app try`'s
plan (team-dev-build-swap's retry: plan 3.5 s of a 5 s budget). relative_specifiers walks back from each "./"
instead. These cases hold it to the regex: every file the key scans, the edge cases of each lead-in, and random
strings made of the characters the two read.

    python3 tests/test_web_bundle_key_specifiers.py
"""
from __future__ import annotations

import importlib.util
import os
import random
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("web_bundle_key_under_test", ROOT / "scripts/cmux-next/web-bundle-key.py")
key = importlib.util.module_from_spec(spec)
spec.loader.exec_module(key)


def by_regex(text: str) -> list[str]:
    return [m.group(1) for m in key.SPECIFIER.finditer(text)]


def walked(text: str) -> list[str]:
    return list(key.relative_specifiers(text))


CASES = [
    'import x from "./a";', "import x from'../b'", 'import("./c")', "import  (\n  './d')", "import './e.css'",
    '@import "./f.css";', '@source "../g";', 'url(./h.png)', 'url( "./i.svg" )', 'new URL("./j", import.meta.url)',
    'new\n\tURL(`./k`)', 'newURL("./l")', 'newxURL("./z")', 'new.URL("./z")', 'new URL ("./m")', 'xfrom "./n"',
    'from_ "./o"', '_import "./p"',
    'a.from "./q"', '$from "./r"', 'from "..../s"', 'from ".../t"', 'from "./"', 'from "./u/./v"', 'from"./w"',
    "from ./x/from './y'", "from './a' from './b'", "import import './c'", "durl(./d)", "@importx './e'",
    "url(\"./f\")'./g'", 'from "./h)i"', "from `./j k`", "import './l'", "fromé './m'", "é from './n'",
    "from './o'", "./from './p'", "import(./q)", "import (('./r'", "from\"\"./s", "from ''./t",
]


class Specifiers(unittest.TestCase):
    def test_edge_cases_match_the_regex(self) -> None:
        for text in CASES:
            with self.subTest(text=text):
                self.assertEqual(walked(text), by_regex(text))

    def test_random_strings_match_the_regex(self) -> None:
        tokens = ["from", "import", "@import", "@source", "url(", "new", "URL", "(", ")", " ", "\n", "\t", " ",
                  '"', "'", "`", ".", "..", "./", "../", "/", "a", "_", "é", "x/", "$"]
        rng = random.Random(59891)
        for _ in range(20000):
            text = "".join(rng.choice(tokens) for _ in range(rng.randint(1, 14)))
            self.assertEqual(walked(text), by_regex(text), repr(text))

    def test_every_scanned_webviews_file_matches_the_regex(self) -> None:
        listed = subprocess.run(["git", "-C", str(ROOT), "ls-files", "-z", "--", "webviews"], capture_output=True,
                                check=True).stdout.split(b"\0")
        files = [os.fsdecode(p) for p in listed if p.endswith(tuple(s.encode() for s in key.SCANNED_SUFFIXES))]
        if not files:
            self.skipTest("no webviews/ in this checkout")
        for rel in files:
            try:
                text = (ROOT / rel).read_text(encoding="utf-8", errors="replace")
            except OSError:
                continue
            self.assertEqual(walked(text), by_regex(text), rel)


if __name__ == "__main__":
    unittest.main()
