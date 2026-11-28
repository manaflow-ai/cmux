#!/usr/bin/env python3
"""The hedged nightly-next verdict: one row per signer, the flake signal on a split, never a red."""
from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/ci"))

import nightly_next_hedge_verdict as v  # noqa: E402

SHA = "a" * 40


def env(tmp: Path, **kw) -> dict:
    base = {"TIP_SHA": SHA, "PRIMARY_HOST": "signer-a", "PRIMARY_COMPILE_RED": "false",
            "PRIMARY_LEFT": "false", "PRIMARY_RESULT": "success", "HEDGE_HOST": "signer-b",
            "HEDGE_COMPILE": "pass", "ROWS_OUT": str(tmp / "rows.jsonl"),
            "GITHUB_STEP_SUMMARY": str(tmp / "summary.md")}
    base.update(kw)
    return base


class VerdictTests(unittest.TestCase):
    def run_main(self, **kw):
        with tempfile.TemporaryDirectory() as d:
            tmp = Path(d)
            self.assertEqual(v.main(env(tmp, **kw)), 0)
            rows = [json.loads(x) for x in (tmp / "rows.jsonl").read_text().splitlines()]
            return rows, (tmp / "summary.md").read_text()

    def test_both_green_is_two_rows_and_no_flake(self):
        rows, text = self.run_main()
        self.assertEqual([r["role"] for r in rows], ["primary", "hedge"])
        self.assertEqual([r["compile"] for r in rows], ["pass", "pass"])
        self.assertFalse(rows[0]["flake"])
        self.assertTrue(all(r["sha"] == SHA for r in rows))
        self.assertIn("| primary | signer-a |", text)
        self.assertNotIn("Flake signal", text)

    def test_red_on_one_signer_green_on_the_other_is_the_flake_signal(self):
        rows, text = self.run_main(PRIMARY_COMPILE_RED="true", PRIMARY_RESULT="failure")
        self.assertEqual([r["compile"] for r in rows], ["fail", "pass"])
        self.assertTrue(rows[1]["flake"])
        self.assertIn("Flake signal", text)

    def test_red_on_both_is_a_code_red_not_a_flake(self):
        rows, _ = self.run_main(PRIMARY_COMPILE_RED="true", HEDGE_COMPILE="fail")
        self.assertFalse(rows[0]["flake"])

    def test_a_red_after_the_compile_still_compiled(self):
        self.assertEqual(v.primary_compile("false", "false", "failure"), "pass")

    def test_a_build_that_left_or_was_cancelled_did_not_build(self):
        self.assertEqual(v.primary_compile("false", "true", "success"), "not built")
        self.assertEqual(v.primary_compile("", "", "cancelled"), "not built")
        self.assertEqual(v.hedge_compile(""), "not built")
        self.assertFalse(v.split("not built", "fail"))

    def test_no_token_means_no_minutes_not_a_red(self):
        self.assertEqual(v.job_minutes({}), {"primary": None, "hedge": None})

    def test_minutes_from_job_times(self):
        job = {"started_at": "2026-11-28T01:00:00Z", "completed_at": "2026-11-28T01:30:30Z"}
        self.assertEqual(v.minutes(job), 30.5)
        self.assertIsNone(v.minutes({"started_at": None}))


if __name__ == "__main__":
    unittest.main()
