#!/usr/bin/env python3
"""idle_cpu.py --host-load N: N busy-loop processes for the measured windows, so a bench can read a daemon's
wakeups on a busy Mac (a busy host wakes every timer late; the acpmux lag canary read that as a block and woke
100 times a second, task 21). Each loop is a child this bench starts, and each is ended after.
Run: python3 -I scripts/cmux-next/tests/test_idle_cpu_host_load.py (not a CI job)."""
import ctypes, os, sys, time, unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
if sys.platform == "darwin":
    import idle_cpu  # noqa: E402
else:
    with mock.patch.object(ctypes, "CDLL", mock.MagicMock()):
        import idle_cpu  # noqa: E402


class HostLoad(unittest.TestCase):
    def test_loops_run_and_end(self):
        with idle_cpu.host_load(2) as loops:
            self.assertEqual(len(loops), 2)
            time.sleep(0.3)
            self.assertTrue(all(loop.poll() is None for loop in loops), "every loop runs")
        self.assertTrue(all(loop.poll() is not None for loop in loops), "every loop ended")

    def test_none_starts_nothing(self):
        with idle_cpu.host_load(0) as loops:
            self.assertEqual(loops, [])

    def test_the_option_is_bounded(self):
        self.assertEqual(idle_cpu.parse_args(["--app", "/x.app", "--host-load", "8"]).host_load, 8)
        for bad in ("-1", "65"):
            with self.assertRaises(SystemExit), mock.patch("sys.stderr"):
                idle_cpu.check_args(idle_cpu.parse_args(["--app", "/x.app", "--host-load", bad]))


if __name__ == "__main__":
    unittest.main()
