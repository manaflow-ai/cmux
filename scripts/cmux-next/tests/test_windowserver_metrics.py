#!/usr/bin/env python3
"""Pure tests for the WindowServer CPU-time parser used by Mac measurements."""

import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))

from windowserver_metrics import parse_process_time  # noqa: E402


class ProcessTimeTests(unittest.TestCase):
    def test_common_ps_formats(self):
        self.assertEqual(parse_process_time("7.25"), 7.25)
        self.assertEqual(parse_process_time("02:07.25"), 127.25)
        self.assertEqual(parse_process_time("01:02:07.25"), 3727.25)

    def test_day_prefix_is_not_multiplied_again(self):
        self.assertEqual(parse_process_time("2-01:02:07.25"), 176527.25)

    def test_invalid_format_is_rejected(self):
        with self.assertRaises(ValueError):
            parse_process_time("yesterday")


if __name__ == "__main__":
    unittest.main()
