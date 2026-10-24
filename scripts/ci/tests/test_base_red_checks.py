#!/usr/bin/env python3
import importlib.util
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("base_red_checks", ROOT / "base_red_checks.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class BaseRedChecksTests(unittest.TestCase):
    def test_parses_failed_summary_and_ansi(self):
        text = "\x1b[31m### 2 cmux-next check(s) failed\x1b[0m\n- Main-thread concurrency (failure)\n- Crash safety (timed_out)\n"
        self.assertEqual(module.failed_names(text), {"Main-thread concurrency", "Crash safety"})

    def test_green_summary_has_no_reds(self):
        self.assertEqual(module.failed_names("All blocking cmux-next checks passed.\\n"), set())


if __name__ == "__main__":
    unittest.main()
