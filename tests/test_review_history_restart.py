"""collect --restart must not leave a stale cursor behind an emptied cache."""
import argparse
import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/review-history.py"
spec = importlib.util.spec_from_file_location("review_history", SCRIPT)
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


if __name__ == "__main__":
    unittest.main()
