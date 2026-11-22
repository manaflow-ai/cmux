#!/usr/bin/env python3
"""scripts/static-analysis/ratchet.py: a change fails only on a zizmor finding it adds that is in the explicit
ZIZMOR_HOLES allowlist (High severity, the repository's own .github/, each audit's own condition) or on a gitleaks
secret it commits; every other new finding is a warning, and a finding already on the base never counts."""

from __future__ import annotations

import importlib.util
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

WF = ".github/workflows/x.yml"

HEAD_CHECKOUT = """on: pull_request_target
jobs:
  build:
    steps:
      - uses: actions/checkout@v4
        with:
          persist-credentials: false
          ref: ${{ github.event.pull_request.head.sha }}
      - run: make
"""

BASE_CHECKOUT = """on: pull_request_target
jobs:
  label:
    steps:
      - uses: actions/checkout@v4
      - run: gh api repos/o/r/commits/${{ github.event.pull_request.head.sha }}
      - uses: actions/labeler@v5
        with:
          ref: ${{ github.event.pull_request.head.sha }}
"""


def finding(path: str, ident: str, severity: str, row: int, confidence: str = "High") -> dict:
    def loc(kind: str, p: str) -> dict:
        return {"symbolic": {"key": {"Local": {"verbatim_path": p}}, "kind": kind},
                "concrete": {"location": {"start_point": {"row": row}}}}
    return {"ident": ident, "determinations": {"severity": severity, "confidence": confidence},
            "locations": [loc("Related", "other.yml"), loc("Primary", path)]}


class RatchetTest(unittest.TestCase):
    def test_the_hole_allowlist_is_exactly_this(self) -> None:
        # Widening what fails a pull request is a decision, not a drive-by: change this set and the docstring together.
        self.assertEqual(set(ratchet.ZIZMOR_HOLES), {
            "template-injection", "dangerous-triggers", "cache-poisoning", "artipacked", "insecure-commands",
            "hardcoded-container-credentials", "bot-conditions"})

    def test_counts_key_by_primary_location_and_list_unaudited_files(self) -> None:
        counts = ratchet.zizmor_counts(
            [finding("a.yml", "template-injection", "High", 3), finding("a.yml", "template-injection", "High", 9),
             finding("b.yml", "artipacked", "Medium", 1, "Low")],
            "== files: 3 audited\nzizmor failed: .github/workflows/release.yml (exit 1)\n")
        self.assertEqual(counts, Counter({
            "a.yml|template-injection|High|High": 2,
            "b.yml|artipacked|Medium|Low": 1,
            f".github/workflows/release.yml|{ratchet.CRASH}|-|-": 1,
        }))
        self.assertEqual(ratchet.finding_key(finding("a.yml", "x", "Low", 4))[1:], ("a.yml", 5))

    def test_a_moved_line_keeps_its_key(self) -> None:
        self.assertEqual(ratchet.zizmor_counts([finding("a.yml", "x", "Low", 3)], ""),
                         ratchet.zizmor_counts([finding("a.yml", "x", "Low", 30)], ""))

    def test_only_what_the_head_adds_over_the_base_is_new(self) -> None:
        base = Counter({f"{WF}|a|High|High": 2, ".github/old.yml|b|Low|High": 1})
        head = Counter({f"{WF}|a|High|High": 3, ".github/new.yml|b|Low|High": 1, f"{WF}|c|Medium|Low": 1})
        self.assertEqual(ratchet.new_findings(base, head, {".github/old.yml": ".github/new.yml"}),
                         {f"{WF}|a|High|High": (2, 3), f"{WF}|c|Medium|Low": (0, 1)})
        self.assertEqual(ratchet.new_findings(base, base, {}), {})

    def test_checks_out_head(self) -> None:
        self.assertTrue(ratchet.checks_out_head(HEAD_CHECKOUT))
        self.assertFalse(ratchet.checks_out_head(BASE_CHECKOUT))
        self.assertTrue(ratchet.checks_out_head("      - run: gh pr checkout ${{ github.head_ref }}\n"))
        self.assertTrue(ratchet.checks_out_head("      - run: git fetch origin refs/pull/1/head && "
                                                "git checkout refs/pull/1/head\n"))

    def test_is_hole(self) -> None:
        self.assertTrue(ratchet.is_hole(f"{WF}|template-injection|High|High", ""))
        self.assertTrue(ratchet.is_hole(".github/actions/a/action.yml|cache-poisoning|High|Low", ""))
        # Not under .github/: a fixture GitHub never runs.
        self.assertFalse(ratchet.is_hole("tests/fixtures/action.yml|template-injection|High|High", ""))
        # Below High, or an audit outside the allowlist.
        self.assertFalse(ratchet.is_hole(f"{WF}|template-injection|Medium|High", ""))
        self.assertFalse(ratchet.is_hole(f"{WF}|unpinned-uses|High|High", ""))
        self.assertFalse(ratchet.is_hole(f"{WF}|{ratchet.CRASH}|-|-", ""))
        # artipacked only at High confidence.
        self.assertTrue(ratchet.is_hole(f"{WF}|artipacked|High|High", ""))
        self.assertFalse(ratchet.is_hole(f"{WF}|artipacked|High|Low", ""))
        # dangerous-triggers only when the workflow takes the head into its workspace.
        self.assertTrue(ratchet.is_hole(f"{WF}|dangerous-triggers|High|Medium", HEAD_CHECKOUT))
        self.assertFalse(ratchet.is_hole(f"{WF}|dangerous-triggers|High|Medium", BASE_CHECKOUT))

    def test_blocking_by_default_and_off_only_when_zero(self) -> None:
        with mock.patch.dict(os.environ, {}, clear=False):
            os.environ.pop("CMUX_STATIC_ANALYSIS_BLOCKING", None)
            self.assertTrue(ratchet.blocking())
            self.assertEqual(ratchet.verdict(["k"]), 1)
            self.assertEqual(ratchet.verdict([]), 0)
        with mock.patch.dict(os.environ, {"CMUX_STATIC_ANALYSIS_BLOCKING": "0"}):
            self.assertFalse(ratchet.blocking())
            self.assertEqual(ratchet.verdict(["k"]), 0)
        self.assertEqual(ratchet.annotate("error", "a.yml", "m", 4), "::error file=a.yml,line=4::m")
        self.assertEqual(ratchet.annotate("warning", "a.yml", "m"), "::warning file=a.yml::m")

    def test_the_workflows_ship_failing_on(self) -> None:
        self.assertIn('CMUX_STATIC_ANALYSIS_BLOCKING: "1"', (ROOT / ".github/workflows/ci-guards.yml").read_text())
        guards = (ROOT / ".github/workflows/cmux-next-guards.yml").read_text()
        self.assertIn('CMUX_STATIC_ANALYSIS_BLOCKING: "1"', guards)
        self.assertIn("ratchet.py zizmor --base HEAD^1 --head HEAD", guards)
        self.assertIn("ratchet.py gitleaks --base HEAD^1 --head HEAD", guards)


if __name__ == "__main__":
    unittest.main()
