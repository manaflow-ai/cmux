#!/usr/bin/env python3
"""Exercise malformed cursor-feed handling without sending native input."""

import itertools
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

import test_cmux_cua_drag_cursor as harness


class CursorFeedTests(unittest.TestCase):
    """Malformed observations must fail the live check with diagnostics intact."""

    def test_malformed_visible_feed_is_unavailable(self):
        """Reject missing, nonnumeric, and nonfinite coordinates at the read boundary."""
        with tempfile.TemporaryDirectory() as directory:
            feed = Path(directory) / "feed.json"
            for coordinates in ({}, {"x": 1}, {"y": 2}, {"x": None, "y": 2},
                                {"x": "1", "y": 2}, {"x": True, "y": 2},
                                {"x": float("nan"), "y": 2},
                                {"x": 1, "y": float("inf")}):
                with self.subTest(coordinates=coordinates):
                    feed.write_text(json.dumps({"session": "test", "visible": True, **coordinates}))
                    self.assertIsNone(harness.read_feed(feed, "test"))
            for value in ([], None, 42):
                with self.subTest(value=value):
                    feed.write_text(json.dumps(value))
                    self.assertIsNone(harness.read_feed(feed, "test"))
            valid = {"session": "test", "visible": True, "x": 1.5, "y": -2}
            feed.write_text(json.dumps(valid))
            self.assertEqual(harness.read_feed(feed, "test"), valid)
            self.assertIsNone(harness.read_feed(feed, "other-session"))

    def test_malformed_release_preserves_trace(self):
        """Run the release polling path with a bad record and retain the failed trace."""
        with tempfile.TemporaryDirectory() as directory:
            feed = Path(directory) / "feed.json"
            output = Path(directory) / "trace.json"
            feed.write_text(json.dumps({"session": "test", "visible": True}))
            argv = ["drag-test", "--driver", "unused-driver", "--socket", "unused-socket",
                    "--feed", str(feed), "--pid", "1", "--window-id", "2",
                    "--from", "10", "20", "--to", "100", "20",
                    "--session", "test", "--out", str(output)]
            process = Mock(returncode=0)
            process.poll.return_value = 0
            process.communicate.return_value = ('{"isError":false}', "")
            pointer = Mock()
            pointer.snapshot.return_value = {"x": 100, "y": 20, "pressed": False}
            with patch("sys.argv", argv), \
                 patch.object(harness, "NativePointer", return_value=pointer), \
                 patch.object(harness.subprocess, "Popen", return_value=process), \
                 patch.object(harness.time, "monotonic", side_effect=itertools.count()), \
                 patch.object(harness.time, "sleep"):
                with self.assertRaises(AssertionError):
                    harness.main()
            trace = json.loads(output.read_text())
            self.assertGreaterEqual(len(trace["samples"]), 2)
            self.assertTrue(all(sample["feed"] is None for sample in trace["samples"]))


if __name__ == "__main__":
    unittest.main()
