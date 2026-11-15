"""A GitHub Actions expression `cond && a || b` gives b whenever a is falsy, so `&& 0 ||`, `&& false ||`,
`&& '' ||` and `&& null ||` are always their right side. gallery-health.yml's checkout had
`push && 0 || 2` and fetched depth 2 on every push (review of cmux#40994). Quote the value ('0') or flip the
condition; this test fails on the pattern in any workflow or composite action."""

from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FALSY_MIDDLE = re.compile(r"&&\s*(0|false|''|null)\s*\|\|")


class FalsyTernaryInExpressions(unittest.TestCase):
    def test_no_expression_picks_a_falsy_value_with_and_or(self) -> None:
        files = sorted((ROOT / ".github").rglob("*.yml")) + sorted((ROOT / ".github").rglob("*.yaml"))
        self.assertTrue(files)
        found = []
        for path in files:
            for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
                if "${{" in line and FALSY_MIDDLE.search(line):
                    found.append(f"{path.relative_to(ROOT)}:{number}: {line.strip()}")
        self.assertEqual(found, [], "`cond && <falsy> || x` is always x; quote the value or flip the condition")

    def test_the_pattern_is_caught(self) -> None:
        self.assertIsNotNone(FALSY_MIDDLE.search("${{ github.event_name == 'push' && 0 || 2 }}"))
        self.assertIsNone(FALSY_MIDDLE.search("${{ github.event_name == 'push' && '0' || '2' }}"))


if __name__ == "__main__":
    unittest.main()
