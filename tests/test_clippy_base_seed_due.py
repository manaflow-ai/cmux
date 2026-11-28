from __future__ import annotations

import importlib.util
import unittest
from datetime import datetime, timezone
from pathlib import Path

spec = importlib.util.spec_from_file_location("due", Path(__file__).resolve().parents[1] / "scripts/ci/clippy_base_seed_due.py")
due = importlib.util.module_from_spec(spec)
spec.loader.exec_module(due)
NOW = datetime(2026, 11, 27, 12, 0, tzinfo=timezone.utc)


class Due(unittest.TestCase):
    def test_fresh_delta_is_not_due(self):
        got, _ = due.decide(datetime(2026, 11, 27, 11, 0, tzinfo=timezone.utc), [], NOW, 120)
        self.assertFalse(got)

    def test_old_or_missing_delta_is_due(self):
        self.assertTrue(due.decide(datetime(2026, 11, 27, 9, 0, tzinfo=timezone.utc), [], NOW, 120)[0])
        self.assertTrue(due.decide(None, [], NOW, 120)[0])

    def test_lockfile_change_is_due(self):
        fresh = datetime(2026, 11, 27, 11, 59, tzinfo=timezone.utc)
        self.assertTrue(due.decide(fresh, [{"modified": ["cmux-tui/Cargo.lock"]}], NOW, 120)[0])
        self.assertFalse(due.decide(fresh, [{"modified": ["cmux-tui/src/main.rs"]}], NOW, 120)[0])


if __name__ == "__main__":
    unittest.main()
