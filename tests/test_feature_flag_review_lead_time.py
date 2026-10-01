#!/usr/bin/env python3
"""Test the feature flag review lead-time report with a fixed calendar date."""

import datetime
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import unittest
from unittest import mock


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

    def test_already_passed_date_stays_at_risk(self):
        flags = [self.flag("expired-release", "2026-09-29")]
        self.assertEqual(self.report.build_report(flags, TODAY)[0]["key"], "expired-release")

    def test_expired_flag_has_negative_days_remaining(self):
        flags = [self.flag("expired-release", "2026-09-28")]
        self.assertEqual(self.report.build_report(flags, TODAY)[0]["daysRemaining"], -2)

    def test_malformed_date_is_ignored(self):
        flags = [self.flag("malformed-release", "2026-13-01")]
        self.assertEqual(self.report.build_report(flags, TODAY), [])

    def test_missing_key_can_be_sorted_and_rendered(self):
        flags = [self.flag(None, "2026-10-05"), self.flag("soon-release", "2026-10-05")]
        report = self.report.build_report(flags, TODAY)
        self.assertEqual(len(report), 2)
        self.assertIn("<missing key>", self.report.render_report(report))

    def test_linter_import_exposes_collector(self):
        self.assertTrue(callable(self.report._load_linter().collect_flags))

    def test_main_consumes_collector_without_live_dates(self):
        linter = mock.Mock()
        linter.collect_flags.return_value = ([], [])
        output = io.StringIO()
        with mock.patch.object(self.report, "_load_linter", return_value=linter), \
             contextlib.redirect_stdout(output):
            self.assertEqual(self.report.main(["--json"]), 0)
        self.assertEqual(json.loads(output.getvalue()), [])
        linter.collect_flags.assert_called_once_with()

    def test_broken_seam_emits_error_payload_and_still_exits_zero(self):
        output = io.StringIO()
        with mock.patch.object(self.report, "_load_linter", return_value=object()), \
             contextlib.redirect_stdout(output):
            self.assertEqual(self.report.main(["--json"]), 0)
        payload = json.loads(output.getvalue())
        self.assertIsInstance(payload, dict)
        self.assertIn("collect_flags", payload["error"])


if __name__ == "__main__":
    unittest.main()
