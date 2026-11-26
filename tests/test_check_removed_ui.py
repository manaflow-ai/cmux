#!/usr/bin/env python3
"""scripts/cmux-next/check-removed-ui.py: an element Leo asked to remove fails CI when it is back."""
from __future__ import annotations

import importlib.util
import io
import json
import os
import subprocess
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/cmux-next/check-removed-ui.py"
LIST = ROOT / "scripts/cmux-next/removed-ui.json"
spec = importlib.util.spec_from_file_location("check_removed_ui", SCRIPT)
check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check)

ROW = {
    "id": "blinking-dot",
    "what": "the sidebar's blinking dot",
    "leo": "let's get rid of the blinking dot asap?",
    "ask": "ask-27caf770fa",
    "date": "2026-10-21",
    "removed_by": "cmux#1",
    "pattern": r"\bBlinkingDot\b",
    "paths": ["webviews/src/"],
}


class RemovedUiTest(unittest.TestCase):
    def repo(self, files: dict[str, str], rows: list[dict]) -> str:
        d = tempfile.mkdtemp()
        subprocess.run(["git", "init", "-q", d], check=True)
        for rel, text in files.items():
            p = Path(d, rel)
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(text)
        Path(d, "scripts/cmux-next").mkdir(parents=True, exist_ok=True)
        Path(d, check.LIST).write_text(json.dumps(rows))
        subprocess.run(["git", "-C", d, "add", "-A"], check=True)
        return d

    def run_check(self, root: str) -> tuple[int, str]:
        out = io.StringIO()
        with redirect_stdout(out):
            code = check.main(["--root", root])
        return code, out.getvalue()

    def test_a_removed_element_coming_back_fails_and_names_the_line(self) -> None:
        root = self.repo({"webviews/src/sidebar/Row.tsx": "import x\nexport const a = <BlinkingDot />\n"}, [ROW])
        code, out = self.run_check(root)
        self.assertEqual(code, 1)
        self.assertIn("file=webviews/src/sidebar/Row.tsx,line=2", out)
        self.assertIn("ask-27caf770fa", out)

    def test_absent_element_passes(self) -> None:
        root = self.repo({"webviews/src/sidebar/Row.tsx": "export const a = <Dot />\n"}, [ROW])
        self.assertEqual(self.run_check(root)[0], 0)

    def test_tests_and_docs_may_name_it(self) -> None:
        root = self.repo({
            "webviews/src/sidebar/Row.test.tsx": "expect(q('BlinkingDot')).toBeNull()\n",
            "webviews/src/sidebar/README.md": "BlinkingDot was removed\n",
        }, [ROW])
        self.assertEqual(self.run_check(root)[0], 0)

    def test_outside_the_rows_paths_passes(self) -> None:
        root = self.repo({"Packages/Other.swift": "BlinkingDot\n"}, [ROW])
        self.assertEqual(self.run_check(root)[0], 0)

    def test_a_restored_row_is_skipped(self) -> None:
        row = dict(ROW, restored='Leo, 2026-11-26: "bring the dot back"')
        root = self.repo({"webviews/src/sidebar/Row.tsx": "<BlinkingDot />\n"}, [row])
        self.assertEqual(self.run_check(root)[0], 0)

    def test_a_row_missing_leos_words_is_refused(self) -> None:
        row = {k: v for k, v in ROW.items() if k != "leo"}
        root = self.repo({}, [row])
        code, out = self.run_check(root)
        self.assertEqual(code, 1)
        self.assertIn("missing leo", out)

    def test_the_tracked_list_is_well_formed_and_nothing_on_it_is_back(self) -> None:
        rows, problems = check.load(str(LIST))
        self.assertEqual(problems, [])
        self.assertGreater(len(rows), 0)
        for row in rows:
            self.assertRegex(row["ask"], r"^ask-[0-9a-f]{10}$|^cmux#\d+$")
        code, out = self.run_check(str(ROOT))
        self.assertEqual(code, 0, out)


if __name__ == "__main__":
    unittest.main()
