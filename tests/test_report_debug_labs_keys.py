#!/usr/bin/env python3
"""Test the Debug and Labs key report: its age cut, case order and the case ledger."""

import datetime
import importlib.util
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
REPORT = ROOT / "scripts/report-debug-labs-keys.py"
TODAY = datetime.date(2026, 11, 5)


def load_report():
    spec = importlib.util.spec_from_file_location("debug_labs_keys_report", REPORT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class DebugLabsKeysReportTests(unittest.TestCase):
    def setUp(self):
        self.report = load_report()

    def key(self, key, kind="debug"):
        return {"key": key, "kind": kind, "type": "Bool", "default": "false", "source": "x.swift:1"}

    def added(self, date, pr=1):
        return {"commit": "abc", "added": date, "author": "Leo", "subject": "s", "pr": pr, "beforeHistory": False}

    def test_lists_only_keys_older_than_the_cut(self):
        keys = [self.key("a.debug.old"), self.key("a.debug.week"), self.key("a.debug.unseen")]
        added = {"a.debug.old": self.added("2026-10-01"), "a.debug.week": self.added("2026-10-29")}
        report = self.report.build_report(keys, added, {}, TODAY)
        self.assertEqual([row["key"] for row in report["keys"]], ["a.debug.old"])
        self.assertEqual(report["keys"][0]["ageDays"], 35)
        self.assertEqual(report["keys"][0]["case"], "")

    def test_orders_flips_and_deletes_first_and_keeps_last(self):
        keys = [self.key(name) for name in ("k.keep", "k.none", "k.delete", "k.flip")]
        added = {key["key"]: self.added("2026-10-01") for key in keys}
        cases = {"k.keep": {"case": "keep", "why": "w"}, "k.delete": {"case": "delete", "why": "w"},
                 "k.flip": {"case": "flip", "why": "w"}}
        report = self.report.build_report(keys, added, cases, TODAY)
        self.assertEqual([row["key"] for row in report["keys"]], ["k.flip", "k.delete", "k.none", "k.keep"])

    def test_names_cases_whose_key_is_gone(self):
        report = self.report.build_report([], {}, {"gone.key": {"case": "keep", "why": "w"}}, TODAY)
        self.assertEqual(report["staleCases"], ["gone.key"])

    def test_every_case_in_the_ledger_is_valid(self):
        # A case whose key a later PR deleted is the report's to list (staleCases), never a red:
        # deleting a flag must not have to edit the ledger in the same PR.
        cases = self.report.load_cases()
        self.assertTrue(all(case["case"] in self.report.CASE_KINDS for case in cases.values()))

    def test_reads_a_tunable_declaration_default(self):
        keys = {item["key"]: item for item in self.report.debug_keys()}
        self.assertEqual(keys["agentPane.debug.needsYouPill"]["default"], "false")
        self.assertEqual(keys["agentPane.debug.thoughtHeader"]["default"], ".duration")


if __name__ == "__main__":
    unittest.main()
