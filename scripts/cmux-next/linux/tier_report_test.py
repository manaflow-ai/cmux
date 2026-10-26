#!/usr/bin/env python3
"""Tests for tier-report.py: receipt contract checks, totals, done checks and the doc markers.

Run: python3 -I scripts/cmux-next/linux/tier_report_test.py (stdlib unittest).
"""

from __future__ import annotations

import copy
import importlib.util
import io
import json
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

HERE = Path(__file__).resolve().parent
_SPEC = importlib.util.spec_from_file_location("tier_report", HERE / "tier-report.py")
tier_report = importlib.util.module_from_spec(_SPEC)
sys.modules[_SPEC.name] = tier_report  # dataclasses look the module up by name
_SPEC.loader.exec_module(tier_report)


def tests(executed, failed=0, linux=0, skipped=0):
    return {"executed": executed, "passed": executed - failed, "failed": failed,
            "skipped": skipped, "linuxExpected": linux}


TIER = {
    "schema": "cmux-linux-swift-v1",
    "runner": "tier",
    "sha": "a" * 40,
    "toolchain": "Swift version 6.2.4 (swift-6.2.4-RELEASE)",
    "startedAt": "2026-10-26T10:00:00Z",
    "sanitize": None,
    "fallback": None,
    "clean": True,
    "buildMs": 412_000,
    "testMs": 61_500,
    "units": [
        {"name": "CmuxNextCompat", "kind": "source", "status": "built"},
        {"name": "CmuxNextActions", "kind": "source", "status": "built"},
        {"name": "CmuxNextBridge", "kind": "source", "status": "failed"},
        {"name": "CmuxNextCompatTests", "kind": "test", "status": "built",
         "tests": tests(40, failed=1, linux=1)},
        {"name": "CmuxNextActionsTests", "kind": "test", "status": "built",
         "tests": tests(200, failed=2, linux=0, skipped=3)},
    ],
    "incremental": [{"target": "CmuxNextTerminalGeometry", "ms": 21_400}],
    "errorsQueue": {"errors": 17, "files": 5},
}

SHARED = {
    "schema": "cmux-linux-swift-v1",
    "runner": "shared",
    "sha": "b" * 40,
    "toolchain": "Swift version 6.2.4 (swift-6.2.4-RELEASE)",
    "startedAt": "2026-10-26T09:00:00Z",
    "sanitize": None,
    "clean": False,
    "buildMs": 90_000,
    "testMs": 30_000,
    "units": [{"name": f"Pkg{i}", "kind": "package", "status": "built",
               "tests": tests(120)} for i in range(26)],
    "incremental": [],
    "errorsQueue": None,
}


class TierReportTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def write(self, name, data):
        path = self.dir / name
        path.write_text(json.dumps(data), encoding="utf-8")
        return str(path)

    def run_main(self, *argv):
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            code = tier_report.main(list(argv))
        return code, out.getvalue(), err.getvalue()

    def checks(self, summary):
        return {c.name: c for c in tier_report.done_checks(summary)}

    def test_totals_come_from_the_receipt(self):
        s = tier_report.summarize(self.write("tier.json", TIER))
        self.assertEqual(s.built, {"source": 2, "test": 2, "package": 0})
        self.assertEqual(s.failed_units, ["CmuxNextBridge"])
        self.assertEqual(s.tests, {"executed": 240, "passed": 237, "failed": 3, "skipped": 3,
                                   "linuxExpected": 1})
        self.assertAlmostEqual(s.max_linux_share, 1 / 40)
        self.assertEqual(s.max_linux_unit, "CmuxNextCompatTests")
        self.assertEqual(s.incremental, {"CmuxNextTerminalGeometry": 21_400})

    def test_tier_done_checks(self):
        c = self.checks(tier_report.summarize(self.write("tier.json", TIER)))
        self.assertFalse(c["1 source targets built"].met)
        self.assertEqual(c["1 tests executed"].target, ">= 1500")
        # Two failures have no [ linux ] line, and one unit failed to build.
        self.assertEqual(c["1 failures outside [ linux ]"].value, "2")
        self.assertFalse(c["1 failures outside [ linux ]"].met)
        self.assertTrue(c["1 largest [ linux ] share"].met)
        self.assertTrue(c["3 clean tier build"].met)
        self.assertTrue(c["3 incremental CmuxNextTerminalGeometry"].met)

    def test_fallback_lowers_the_test_target(self):
        data = copy.deepcopy(TIER)
        data["fallback"] = "task 119 refused; waves 0-1 only"
        c = self.checks(tier_report.summarize(self.write("tier.json", data)))
        self.assertEqual(c["1 tests executed (fallback)"].target, ">= 1000")

    def test_warm_or_sanitized_build_is_not_a_clean_build(self):
        data = copy.deepcopy(TIER)
        data["clean"] = False
        c = self.checks(tier_report.summarize(self.write("tier.json", data)))
        self.assertFalse(c["3 clean tier build"].met)
        self.assertEqual(c["3 clean tier build"].value, "not a clean, unsanitized build")

    def test_linux_share_over_five_percent(self):
        data = copy.deepcopy(TIER)
        data["units"][3]["tests"] = tests(40, failed=3, linux=3)
        c = self.checks(tier_report.summarize(self.write("tier.json", data)))
        self.assertFalse(c["1 largest [ linux ] share"].met)
        self.assertEqual(c["1 largest [ linux ] share"].value, "7.5 % (CmuxNextCompatTests)")

    def test_missing_incremental_is_not_measured(self):
        data = copy.deepcopy(TIER)
        data["incremental"] = []
        c = self.checks(tier_report.summarize(self.write("tier.json", data)))
        self.assertEqual(c["3 incremental CmuxNextTerminalGeometry"].value, "not measured")
        self.assertFalse(c["3 incremental CmuxNextTerminalGeometry"].met)

    def test_shared_done_checks(self):
        c = self.checks(tier_report.summarize(self.write("shared.json", SHARED)))
        self.assertTrue(c["2 packages built"].met)
        self.assertTrue(c["2 tests executed"].met)
        self.assertEqual(c["2 tests executed"].value, "3120")
        self.assertNotIn("3 clean tier build", c)

    def test_contract_errors_name_the_field(self):
        cases = [
            (lambda d: d.pop("buildMs"), "missing 'buildMs'"),
            (lambda d: d.update(schema="cmux-oracle-build-v1"), ".schema:"),
            (lambda d: d.update(runner="mac"), ".runner: 'mac' is not one of"),
            (lambda d: d["units"][0].update(status="ok"), ".units[0].status:"),
            (lambda d: d["units"][3]["tests"].update(passed=1), ".units[3].tests: passed 1"),
            (lambda d: d["units"][3]["tests"].update(linuxExpected=5),
             ".units[3].tests: linuxExpected 5 > failed 1"),
            (lambda d: d["units"][3]["tests"].update(executed=True), "expected int"),
            (lambda d: d.update(buildMs=-1), ".buildMs: negative -1"),
            (lambda d: d["units"].append(dict(d["units"][0])), "appears twice"),
        ]
        for mutate, message in cases:
            data = copy.deepcopy(TIER)
            mutate(data)
            code, out, err = self.run_main(self.write("bad.json", data))
            self.assertEqual(code, 2, message)
            self.assertEqual(out, "")
            self.assertIn(message, err)

    def test_not_json_is_exit_2(self):
        path = self.dir / "broken.json"
        path.write_text("{", encoding="utf-8")
        code, _, err = self.run_main(str(path))
        self.assertEqual(code, 2)
        self.assertIn("not JSON", err)

    def test_unmet_checks_still_exit_0_and_rows_are_oldest_first(self):
        self.write("linux-tier.json", TIER)
        self.write("linux-shared.json", SHARED)
        code, out, _ = self.run_main(str(self.dir))
        self.assertEqual(code, 0)
        rows = [line for line in out.splitlines() if line.startswith("| 2026-")]
        self.assertEqual([r.split(" | ")[1] for r in rows], ["shared", "tier"])
        self.assertIn("| 1 source targets built | >= 30 | 2 | no |", out)
        self.assertIn("Failed units: `CmuxNextBridge`", out)
        self.assertIn(tier_report.hashlib.sha256(
            (self.dir / "linux-tier.json").read_bytes()).hexdigest(), out)

    def test_sanitized_receipt_is_not_the_done_check_receipt(self):
        self.write("tier.json", TIER)
        data = copy.deepcopy(TIER)
        data.update(sanitize="thread", startedAt="2026-10-26T11:00:00Z", sha="c" * 40)
        self.write("tier-tsan.json", data)
        code, out, _ = self.run_main("--json", str(self.dir))
        self.assertEqual(code, 0)
        payload = json.loads(out)
        self.assertEqual(len(payload["receipts"]), 2)
        self.assertEqual(payload["receipts"][1]["sanitize"], "thread")
        code, md, _ = self.run_main(str(self.dir))
        self.assertIn("newest tier receipt (`aaaaaaaaaaaa`", md)

    def test_write_doc_replaces_only_between_markers(self):
        doc = self.dir / "oracle-DESIGN.md"
        doc.write_text("# Title\n\nBefore.\n\n" + tier_report.BEGIN_MARKER + "\nold\n"
                       + tier_report.END_MARKER + "\n\nAfter.\n", encoding="utf-8")
        receipt = self.write("tier.json", TIER)
        code, out, _ = self.run_main("--write-doc", str(doc), receipt)
        self.assertEqual(code, 0)
        text = doc.read_text(encoding="utf-8")
        self.assertTrue(text.startswith("# Title\n\nBefore.\n\n" + tier_report.BEGIN_MARKER
                                        + "\n" + out))
        self.assertTrue(text.endswith(tier_report.END_MARKER + "\n\nAfter.\n"))
        self.assertNotIn("\nold\n", text)
        # A second run gives the same file.
        self.run_main("--write-doc", str(doc), receipt)
        self.assertEqual(doc.read_text(encoding="utf-8"), text)

    def test_write_doc_without_markers_is_exit_2(self):
        doc = self.dir / "plain.md"
        doc.write_text("# no markers\n", encoding="utf-8")
        code, _, err = self.run_main("--write-doc", str(doc), self.write("tier.json", TIER))
        self.assertEqual(code, 2)
        self.assertIn("no linux-tier-report begin/end markers", err)

    def test_no_receipts_says_so(self):
        code, out, _ = self.run_main(str(self.dir))
        self.assertEqual(code, 0)
        self.assertTrue(out.startswith("No receipt yet."))

    def test_repo_doc_has_the_markers(self):
        doc = HERE.parents[2] / "plans" / "cmux-next" / "oracle-DESIGN.md"
        text = doc.read_text(encoding="utf-8")
        self.assertIn(tier_report.BEGIN_MARKER, text)
        self.assertIn(tier_report.END_MARKER, text)


if __name__ == "__main__":
    unittest.main()
