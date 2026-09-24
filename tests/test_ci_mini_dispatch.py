#!/usr/bin/env python3
"""Regression coverage for the owned-Mac dispatch helpers in mini_dispatch.py."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("mini_dispatch", ROOT / "scripts/ci/mini_dispatch.py")
dispatch = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(dispatch)


class RetryWaitTests(unittest.TestCase):
    def test_retry_wait_retries_with_bounded_backoff_without_fixed_sleep(self):
        current = [0.0]
        waits = []
        probes = []

        def clock():
            return current[0]

        def wait(delay):
            waits.append(delay)
            current[0] += delay
            return False

        waiter = dispatch.RetryWait(clock=clock, wait=wait)

        def probe():
            probes.append(current[0])
            return (len(probes) == 3, "ready" if len(probes) == 3 else None)

        self.assertEqual(waiter.until(10.0, probe), "ready")
        self.assertEqual(len(probes), 3)
        self.assertEqual(waits, [0.5, 1.0])

    def test_retry_wait_is_cancellation_aware(self):
        waiter = dispatch.RetryWait()
        waiter.cancel()
        with self.assertRaises(dispatch.RetryCancelled):
            waiter.until(dispatch.now() + 10, lambda: (False, None))


if __name__ == "__main__":
    unittest.main()
