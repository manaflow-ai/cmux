#!/usr/bin/env python3
"""scripts/static-analysis/ratchet.py: zizmor findings are keyed per file, audit and severity, and only a
count above its baseline (or a file zizmor cannot audit that the baseline does not list) is new; new findings
are reported (warning, exit 0) unless CMUX_STATIC_ANALYSIS_BLOCKING=1 makes them fail."""

from __future__ import annotations

import importlib.util
import json
import os
import sys
import unittest
from collections import Counter
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("sa_ratchet", ROOT / "scripts/static-analysis/ratchet.py")
ratchet = importlib.util.module_from_spec(spec)
sys.modules["sa_ratchet"] = ratchet
spec.loader.exec_module(ratchet)


def finding(path: str, ident: str, severity: str, row: int) -> dict:
    def loc(kind: str, p: str) -> dict:
        return {"symbolic": {"key": {"Local": {"verbatim_path": p}}, "kind": kind},
                "concrete": {"location": {"start_point": {"row": row}}}}
    return {"ident": ident, "determinations": {"severity": severity},
            "locations": [loc("Related", "other.yml"), loc("Primary", path)]}


class RatchetTest(unittest.TestCase):
    def test_counts_key_by_primary_location_and_list_unaudited_files(self) -> None:
        counts = ratchet.zizmor_counts(
            [finding("a.yml", "template-injection", "High", 3), finding("a.yml", "template-injection", "High", 9),
             finding("b.yml", "artipacked", "Medium", 1)],
            "== files: 3 audited\nzizmor failed: .github/workflows/release.yml (exit 1)\n")
        self.assertEqual(counts, Counter({
            "a.yml|template-injection|High": 2,
            "b.yml|artipacked|Medium": 1,
            f".github/workflows/release.yml|{ratchet.CRASH}|-": 1,
        }))

    def test_a_moved_line_keeps_its_key(self) -> None:
        self.assertEqual(ratchet.zizmor_counts([finding("a.yml", "x", "Low", 3)], ""),
                         ratchet.zizmor_counts([finding("a.yml", "x", "Low", 30)], ""))

    def test_only_a_count_above_its_baseline_fails(self) -> None:
        baseline = {"a.yml|x|High": 2, "b.yml|y|Low": 1}
        over, under = ratchet.compare(Counter({"a.yml|x|High": 2}), baseline)
        self.assertEqual((over, under), ({}, 1))
        over, _ = ratchet.compare(Counter({"a.yml|x|High": 3, "c.yml|z|Medium": 1}), baseline)
        self.assertEqual(over, {"a.yml|x|High": (2, 3), "c.yml|z|Medium": (0, 1)})

    def test_the_committed_baseline_is_well_formed(self) -> None:
        data = json.loads(ratchet.ZIZMOR_BASELINE.read_text())
        self.assertEqual(data["total"], sum(data["findings"].values()))
        for key, n in data["findings"].items():
            self.assertEqual(len(key.split("|")), 3, key)
            self.assertGreater(n, 0, key)

    def test_report_only_by_default_and_blocking_only_when_set(self) -> None:
        with mock.patch.dict(os.environ, {}, clear=False):
            os.environ.pop("CMUX_STATIC_ANALYSIS_BLOCKING", None)
            self.assertFalse(ratchet.blocking())
            self.assertEqual(ratchet.verdict(True), 0)
            self.assertTrue(ratchet.annotate("a.yml", "m").startswith("::warning file=a.yml::"))
        with mock.patch.dict(os.environ, {"CMUX_STATIC_ANALYSIS_BLOCKING": "1"}):
            self.assertEqual(ratchet.verdict(True), 1)
            self.assertEqual(ratchet.verdict(False), 0)
            self.assertEqual(ratchet.annotate("a.yml", "m", 4), "::error file=a.yml,line=4::m")

    def test_the_workflow_ships_report_only(self) -> None:
        workflow = (ROOT / ".github/workflows/ci-guards.yml").read_text()
        self.assertIn('CMUX_STATIC_ANALYSIS_BLOCKING: "0"', workflow)


if __name__ == "__main__":
    unittest.main()
