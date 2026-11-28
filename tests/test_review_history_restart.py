"""collect --restart must not leave a stale cursor behind an emptied cache."""
import argparse
import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/review-history.py"
spec = importlib.util.spec_from_file_location("review_history", SCRIPT)
assert spec is not None and spec.loader is not None
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)


class RestartCursorTests(unittest.TestCase):
    def test_interrupted_restart_does_not_resume_from_old_cursor(self):
        with tempfile.TemporaryDirectory() as directory:
            cache = Path(directory) / "review-history.jsonl"
            cursor = cache.with_suffix(cache.suffix + ".cursor")
            cursor.write_text("2026-08-03")  # a previous run's position
            cache.write_text("")

            args = argparse.Namespace(
                since="2026-07-01", cache=str(cache), restart=True, until="2026-13-45",
                repo="o/r", window_days=2, page=20, max_pages=1, floor=0,
            )
            # --until is invalid, so the restart stops before any page is written.
            with self.assertRaises(ValueError):
                module.collect(args)

            self.assertFalse(cursor.exists(), "the stale cursor must be discarded with the cache")

    def test_a_stop_at_any_reset_step_leaves_no_cursor_over_an_emptied_cache(self):
        # The cursor must be invalidated before, or together with, the cache truncation.
        for step in ("unlink", "write_text"):
            with self.subTest(failing_step=step), tempfile.TemporaryDirectory() as directory:
                cache = Path(directory) / "review-history.jsonl"
                cursor = cache.with_suffix(cache.suffix + ".cursor")
                cursor.write_text("2026-08-03")
                cache.write_text('{"number": 1, "mergedAt": "2026-08-02T00:00:00Z", "comments": []}\n')
                args = argparse.Namespace(
                    since="2026-07-01", cache=str(cache), restart=True, until=None,
                    repo="o/r", window_days=2, page=20, max_pages=1, floor=0,
                )
                # The restart stops at this reset step, as on a failed file operation.
                with mock.patch.object(Path, step, side_effect=OSError(step)), self.assertRaises(OSError):
                    module.collect(args)

                self.assertFalse(
                    cursor.exists() and cache.read_text() == "",
                    "the old cursor survived over an emptied cache, so the next run would skip the windows before it",
                )


if __name__ == "__main__":
    unittest.main()
