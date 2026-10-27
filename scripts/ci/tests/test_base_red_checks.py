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

    def test_pending_previous_tip_is_warning_only(self):
        original = module.api
        try:
            module.api = lambda _base, _token, _path: (
                b'{"check_runs":[{"name":"cmux-next checks (god files, concurrency, crash safety, l10n)",'
                b'"status":"in_progress"}]}'
            )
            self.assertIsNone(module.base_reds("manaflow-ai/cmux", "before", "https://api.github.com", "token"))
        finally:
            module.api = original

    def test_completed_previous_tip_still_reads_failed_names(self):
        original = module.api
        try:
            def fake_api(_base, _token, path):
                if "/check-runs?" in path:
                    return (
                        b'{"check_runs":[{"name":"cmux-next checks (god files, concurrency, crash safety, l10n)",'
                        b'"status":"completed","conclusion":"failure",'
                        b'"details_url":"https://github.com/manaflow-ai/cmux/actions/runs/1/job/42"}]}'
                    )
                return b"- Main-thread concurrency (failure)\n"
            module.api = fake_api
            self.assertEqual(
                module.base_reds("manaflow-ai/cmux", "before", "https://api.github.com", "token"),
                {"Main-thread concurrency"},
            )
        finally:
            module.api = original


if __name__ == "__main__":
    unittest.main()
