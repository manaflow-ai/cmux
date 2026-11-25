#!/usr/bin/env python3
"""thread_wakes.record never fills a disk: it refuses when the volume has less than `min_free` bytes, ends a
recording whose folder grows past `max_bytes`, and leaves nothing behind (cmux20-bench, 2026-11-23: a bench step
left the volume with 2 GiB free and failed the next ones).
Run: python3 -I scripts/cmux-next/tests/test_thread_wakes_cap.py (not a CI job)."""
from __future__ import annotations

import os
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import thread_wakes  # noqa: E402

GROW = [sys.executable, "-I", "-c",
        "import os,sys,time\n"
        "f=open(os.path.join(sys.argv[1],'big'),'wb')\n"
        "while True: f.write(b'x'*(1<<20)); f.flush(); time.sleep(0.01)\n"]


class Cap(unittest.TestCase):
    def test_a_recording_past_the_size_cap_is_ended_and_says_so(self):
        folder = tempfile.mkdtemp()
        try:
            started = time.monotonic()
            rc, log = thread_wakes._run_bounded(GROW + [folder], 60, watch=folder, max_bytes=8 << 20)
            self.assertEqual(rc, thread_wakes.OVER_SIZE)
            self.assertIn("over", log)
            self.assertLess(time.monotonic() - started, 30)
        finally:
            import shutil
            shutil.rmtree(folder, ignore_errors=True)

    def test_too_little_free_disk_refuses_before_recording(self):
        with mock.patch.object(thread_wakes, "free_bytes", return_value=5 << 30), \
                mock.patch.object(thread_wakes, "_run_bounded") as run:
            got = thread_wakes.record(1, 5, min_free=30 << 30)
        self.assertIn("free", got["error"])
        run.assert_not_called()

    def test_nothing_is_left_after_an_oversize_recording(self):
        made = []
        real = tempfile.mkdtemp

        def mkdtemp(*a, **k):
            made.append(real(*a, **k))
            return made[-1]

        def grow(command, timeout, watch=None, max_bytes=None):
            open(os.path.join(watch, "big"), "wb").write(b"x" * 1024)
            return thread_wakes.OVER_SIZE, "over the size cap"

        with mock.patch.object(thread_wakes.tempfile, "mkdtemp", side_effect=mkdtemp), \
                mock.patch.object(thread_wakes, "_run_bounded", side_effect=grow), \
                mock.patch.object(thread_wakes, "free_bytes", return_value=100 << 30):
            got = thread_wakes.record(1, 5)
        self.assertIn("size", got["error"])
        self.assertFalse(os.path.exists(made[0]))

    def test_a_trace_is_at_most_fifteen_seconds(self):
        with mock.patch.object(thread_wakes, "free_bytes", return_value=100 << 30), \
                mock.patch.object(thread_wakes, "_run_bounded", return_value=(1, "")) as run:
            thread_wakes.record(1, 600)
        self.assertIn("15s", run.call_args.args[0])


if __name__ == "__main__":
    unittest.main()
