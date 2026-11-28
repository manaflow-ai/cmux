"""A workflow's inline `python3 -c '...'` parses on the fleet Macs' python3 (3.9, older than 3.12).

Before PEP 701 (3.12) an f-string's {expression} may not hold a backslash. cmux-next-ios-verify-auto.yml's step
summary line read `{r[\\"pr\\"]}` inside an f-string: a SyntaxError on the Macs' python3, so runs 46184439255 and
46184226923 (11-28) went red after ios_verify had written its record. A newer Python parses the line fine, so only
this scan (or a Mac) sees it.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
# An f-string opening, then a { ... } whose body holds a backslash before it closes.
BACKSLASH_IN_FIELD = re.compile(r"""\bf(["'])(?:(?!\1)[^\n{])*\{[^}\n]*\\""")
INLINE = re.compile(r"python3?(?:\.\d+)?(?:\s+-[A-Za-z]+)*\s+-c\s+'([^']*)'")


class WorkflowInlinePythonTests(unittest.TestCase):
    def test_no_backslash_inside_an_f_string_field(self) -> None:
        bad = []
        for path in sorted((ROOT / ".github").rglob("*.y*ml")):
            for number, line in enumerate(path.read_text().splitlines(), 1):
                for body in INLINE.findall(line):
                    if BACKSLASH_IN_FIELD.search(body):
                        bad.append(f"{path.relative_to(ROOT)}:{number}")
        self.assertEqual(bad, [], "a backslash inside an f-string {field} is a SyntaxError before Python 3.12")

    def test_the_scan_sees_the_11_28_line(self) -> None:
        line = """python3 -I -c 'import json, sys; r = json.load(open(sys.argv[1])); print(f"#{r[\\"pr\\"]}")' x"""
        self.assertTrue(BACKSLASH_IN_FIELD.search(INLINE.findall(line)[0]))
        fixed = """python3 -I -c 'import json, sys; r = {}; print("#%s" % (r["pr"],))' x"""
        self.assertFalse(BACKSLASH_IN_FIELD.search(INLINE.findall(fixed)[0]))


if __name__ == "__main__":
    unittest.main()
