"""launch_tti_check reads each round's binders from its own launch-times.jsonl row (startup-under-100ms)."""
import datetime
import json
import plistlib
import sys
import tempfile
import time
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import launch_tti_check as tti  # noqa: E402


def iso(t: float) -> str:
    return datetime.datetime.fromtimestamp(t, datetime.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


class LaunchRowBinders(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        self.app = self.root / "cmux NIGHTLY.app"
        (self.app / "Contents").mkdir(parents=True)
        with open(self.app / "Contents" / "Info.plist", "wb") as f:
            plistlib.dump({"CFBundleIdentifier": "com.example.nightly", "CFBundleExecutable": "cmux"}, f)
        self.home = self.root / "h"
        self.rows = self.home / "Library" / "Application Support" / "com.example.nightly" / "launch-times.jsonl"
        self.rows.parent.mkdir(parents=True)

    def write(self, *records):
        self.rows.write_text("".join(json.dumps(r) + "\n" for r in records))

    def test_this_launch_row(self):
        now = time.time()
        self.write({"started_at": iso(now - 30), "binders": {"old": 9.0}},
                   {"started_at": iso(now), "binders": {"bindApp": 41.5, "WindowHandlers.bind": 3.0}})
        self.assertEqual(tti.launch_row_binders(str(self.home), self.app, now, wait=0),
                         {"bindApp": 41.5, "WindowHandlers.bind": 3.0})

    def test_only_an_older_row_reads_none(self):
        now = time.time()
        self.write({"started_at": iso(now - 30), "binders": {"old": 9.0}})
        self.assertIsNone(tti.launch_row_binders(str(self.home), self.app, now, wait=0))

    def test_row_without_binders_and_missing_file(self):
        now = time.time()
        self.assertIsNone(tti.launch_row_binders(str(self.home), self.app, now, wait=0))
        self.write({"started_at": iso(now)})
        self.assertIsNone(tti.launch_row_binders(str(self.home), self.app, now, wait=0))

    def test_medians_slowest_first(self):
        rows = [{"binders": {"a": 10.0, "b": 50.0}}, {"binders": {"a": 30.0, "b": 70.0}}, {"binders": None}, {}]
        self.assertEqual(list(tti.binder_medians(rows).items()), [("b", 60.0), ("a", 20.0)])


if __name__ == "__main__":
    unittest.main()
