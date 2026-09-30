#!/usr/bin/env python3
"""Test the feature flag review lead-time report with a fixed calendar date."""

import datetime
import importlib.util
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
REPORT = ROOT / "scripts/report-feature-flag-review-lead-time.py"
TODAY = datetime.date(2026, 9, 30)


def load_report():
    spec = importlib.util.spec_from_file_location("feature_flag_review_report", REPORT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class FeatureFlagReviewLeadTimeTests(unittest.TestCase):
    def setUp(self):
        self.report = load_report()

    def flag(self, key, review):
        return {"key": key, "source": "Example.swift", "reviewBy": review}

    def test_nothing_at_risk(self):
        flags = [self.flag("later-release", "2026-11-01")]
        self.assertEqual(self.report.build_report(flags, TODAY), [])

    def test_one_flag_at_risk(self):
        flags = [self.flag("soon-release", "2026-10-05")]
        self.assertEqual(
            self.report.build_report(flags, TODAY),
            [{
                "key": "soon-release",
                "source": "Example.swift",
                "reviewBy": "2026-10-05",
                "daysRemaining": 5,
            }],
        )

    def test_already_passed_date_is_not_at_risk(self):
        flags = [self.flag("expired-release", "2026-09-29")]
        self.assertEqual(self.report.build_report(flags, TODAY), [])

    def test_malformed_date_is_ignored(self):
        flags = [self.flag("malformed-release", "2026-13-01")]
        self.assertEqual(self.report.build_report(flags, TODAY), [])


if __name__ == "__main__":
    unittest.main()
