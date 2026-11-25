#!/usr/bin/env python3
"""Exercise malformed cursor-feed handling without sending native input."""

import itertools
import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

import test_cmux_cua_drag_cursor as harness
import test_cmux_cua_divider_drags as divider


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


class DividerGeometryTests(unittest.TestCase):
    """A moving cursor is insufficient proof that a pane divider actually moved."""

    @staticmethod
    def layout(axis, position=400):
        """Create a two-pane layout with a one-point divider and fixed outer size."""
        first = {"x": 0, "y": 0, "width": 800, "height": 800}
        second = dict(first)
        coordinate, size = ("x", "width") if axis == "horizontal" else ("y", "height")
        first[size] = position
        second[coordinate] = position + 1
        second[size] = 799 - position
        return {"workspace_id": "workspace", "panes": [
            {"id": "first", "pixel_frame": first},
            {"id": "second", "pixel_frame": second},
        ]}

    def test_both_axes_and_directions_resize_adjacent_panes(self):
        """Accept real opposing size changes while preserving the container."""
        for axis in ("horizontal", "vertical"):
            for direction in (-1, 1):
                with self.subTest(axis=axis, direction=direction):
                    result = divider.verify_resize(self.layout(axis), self.layout(axis, 400 + direction * 80), axis, direction)
                    self.assertEqual(result["first_pane_delta"], direction * 80)
                    self.assertEqual(result["second_pane_delta"], -direction * 80)

    def test_no_resize_or_wrong_direction_fails(self):
        """Reject successful input acknowledgements without the requested resize."""
        for axis in ("horizontal", "vertical"):
            for position in (400, 320):
                with self.subTest(axis=axis, position=position), self.assertRaises(AssertionError):
                    divider.verify_resize(self.layout(axis), self.layout(axis, position), axis, 1)

    def test_replaced_pane_or_detached_neighbor_fails(self):
        """Reject geometry changes caused by different panes or a broken split."""
        before = self.layout("horizontal")
        after = self.layout("horizontal", 480)
        after["panes"][1]["id"] = "replacement"
        with self.assertRaises(AssertionError):
            divider.verify_resize(before, after, "horizontal", 1)
        after = self.layout("horizontal", 480)
        after["panes"][1]["pixel_frame"]["x"] += 50
        with self.assertRaises(AssertionError):
            divider.verify_resize(before, after, "horizontal", 1)


class DividerFailureEvidenceTests(unittest.TestCase):
    """Subprocess errors must leave the failed matrix case in the report."""

    def test_command_failure_and_timeout_preserve_case(self):
        """Exercise failures before, during, and after a drag through the CLI runner."""
        for stage in ("select", "before", "drag", "after"):
            for timeout in (False, True):
                with self.subTest(stage=stage, timeout=timeout), tempfile.TemporaryDirectory() as directory:
                    root = Path(directory)
                    plan = {axis: {"workspace": axis, "from": [100, 100], "to": end}
                            for axis, end in (("horizontal", [180, 100]), ("vertical", [100, 180]))}
                    (root / "plan.json").write_text(json.dumps(plan))
                    argv = ["matrix", "--driver", "unused-driver", "--socket", "unused-helper",
                            "--cmux-cli", "unused-cli", "--cmux-socket", "unused-app",
                            "--feed", str(root / "feed"), "--pid", "1", "--window-id", "2",
                            "--plan", str(root / "plan.json"), "--out-dir", str(root / "output")]
                    command = ["failed-command", stage]
                    error = (subprocess.TimeoutExpired(command, 15, output=b"partial\xff", stderr=b"timeout")
                             if timeout else subprocess.CalledProcessError(7, command, output="partial", stderr="failed"))
                    geometry = json.dumps(DividerGeometryTests.layout("horizontal"))
                    completed = subprocess.CompletedProcess([], 0, "{}", "")
                    before = subprocess.CompletedProcess([], 0, geometry, "")
                    calls = {"select": [error], "before": [completed, error],
                             "drag": [completed, before, error],
                             "after": [completed, before, completed, error]}[stage]
                    with patch("sys.argv", argv), patch.object(divider.subprocess, "run", side_effect=calls):
                        with self.assertRaises(AssertionError):
                            divider.main()
                    report = json.loads((root / "output" / "summary.json").read_text())
                    self.assertFalse(report["passed"])
                    self.assertEqual(len(report["cases"]), 1)
                    failed = report["cases"][0]
                    self.assertFalse(failed["passed"])
                    self.assertEqual(failed["command"], command)
                    self.assertEqual(failed["returncode"], None if timeout else 7)
                    self.assertIsInstance(failed["stdout"], str)
                    self.assertIsInstance(failed["stderr"], str)


if __name__ == "__main__":
    unittest.main()
