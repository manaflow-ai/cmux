#!/usr/bin/env python3
"""chat-open-bench.py's summary: a case with an open that showed no content, or with no empty time,
is reported as failed with its valid count, never as a median over the opens that survived."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import chat_open_summary as cos  # noqa: E402


def open_(first, empty=0.0, **extra):
    return {"first_content_ms": first, "longest_empty_ms": empty, "flashes": 0, **extra}


class SummaryTests(unittest.TestCase):
    def test_complete_case_reports_medians(self):
        summary = cos.summarize([open_(100, 10), open_(300, 30), open_(200, 20)])
        self.assertTrue(summary["complete"])
        self.assertEqual((summary["n"], summary["ok"]), (3, 3))
        self.assertEqual(summary["first_content_ms"]["median"], 200)
        self.assertEqual(summary["longest_empty_ms"], 20)
        self.assertEqual(cos.cell(summary, "sidebar"), "200, empty 20, 0 flashes")

    def test_timed_out_open_fails_the_case(self):
        # The slow open timed out: a median of the other two (150) would look faster than the truth.
        summary = cos.summarize([open_(100), open_(200), {"timed_out": True, "longest_empty_ms": 15000}])
        self.assertFalse(summary["complete"])
        self.assertEqual((summary["n"], summary["ok"]), (3, 2))
        self.assertIsNone(summary["first_content_ms"]["median"])
        self.assertEqual(cos.cell(summary, "sidebar"), "FAILED (2/3 valid)")

    def test_timed_out_open_with_numbers_still_fails_the_case(self):
        # The trace gave up but still reported the times it had: they are not the open's.
        slow = open_(15000, 15000, timed_out=True)
        summary = cos.summarize([open_(100), open_(200), slow])
        self.assertFalse(summary["complete"])
        self.assertEqual((summary["n"], summary["ok"], summary["timed_out"]), (3, 2, 1))
        self.assertEqual(cos.cell(summary, "big"), "FAILED (2/3 valid)")
        errored = cos.summarize([open_(100), open_(120, error="wait: closed")])
        self.assertEqual(cos.cell(errored, "subagent"), "FAILED (1/2 valid)")

    def test_missing_empty_time_is_missing_not_zero(self):
        summary = cos.summarize([open_(100, 50), {"first_content_ms": 120, "flashes": 0}])
        self.assertFalse(summary["complete"])
        self.assertIsNone(summary["longest_empty_ms"])
        self.assertEqual(cos.cell(summary, "restore"), "FAILED (1/2 valid)")

    def test_error_and_empty_cases_fail(self):
        self.assertFalse(cos.summarize([{"error": "arm: None"}])["complete"])
        self.assertFalse(cos.summarize([])["complete"])


if __name__ == "__main__":
    unittest.main()
