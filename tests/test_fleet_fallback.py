#!/usr/bin/env python3
"""A Mac job that falls from its fleet job partner says why (docs/ci/cmux-next-workflow-notes/2026-11-25-fleet-fallback.md)."""
from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
import re
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/cmux-next.yml"
STEP = "Say why this runs on a Mac (fleet fallback)"

spec = importlib.util.spec_from_file_location("fleet_fallback", ROOT / "scripts/ci/fleet_fallback.py")
ff = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ff)

# Mac job -> the fleet jobs whose answer it takes.
PARTNERS = {
    "cmux-scheme-compile": ["cmux-scheme-compile-fleet"],
    "swift-canary": ["swift-canary-fleet"],
    "release-compile": ["app-compile-fleet", "release-compile-fast"],
}


class Reason(unittest.TestCase):
    def test_a_taken_answer_is_no_fall(self):
        self.assertIsNone(ff.reason("success", "pass", []))
        self.assertIsNone(ff.reason("success", "superseded", [("g", False)]))

    def test_a_caller_that_takes_only_pass_records_superseded_as_a_fall(self):
        # The scheme compile accepts only pass: a superseded answer there means the Mac compiles, so it is recorded.
        self.assertEqual(ff.reason("success", "superseded", [], {"pass"})[0], "verdict")
        self.assertIsNone(ff.reason("success", "pass", [], {"pass"}))

    def test_a_false_gate_names_itself(self):
        kind, text = ff.reason("skipped", "", [("CI_SCHEME_COMPILE_FLEET is not 0", False), ("owner", True)])
        self.assertEqual(kind, "gate")
        self.assertIn("CI_SCHEME_COMPILE_FLEET is not 0", text)
        self.assertNotIn("owner", text)

    def test_a_skip_with_every_gate_held_says_so(self):
        self.assertEqual(ff.reason("skipped", "", [("owner", True)])[0], "skipped")
        self.assertEqual(ff.reason("", "", [])[0], "skipped")

    def test_failed_cancelled_and_other_verdicts(self):
        self.assertEqual(ff.reason("failure", "", [])[0], "failure")
        self.assertEqual(ff.reason("cancelled", "", [])[0], "cancelled")
        kind, text = ff.reason("success", "unavailable", [])
        self.assertEqual(kind, "verdict")
        self.assertIn("unavailable", text)
        self.assertIn("nothing", ff.reason("success", "", [])[1])

    def test_main_warns_summarizes_logs_and_never_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            summary = Path(tmp) / "summary.md"
            out = io.StringIO()
            with mock.patch.dict(os.environ, {"GITHUB_STEP_SUMMARY": str(summary), "GITHUB_RUN_ID": "7"}), \
                    contextlib.redirect_stdout(out):
                code = ff.main(["--job", "mac", "--fleet", "fleet", "--result", "skipped",
                                "--gate", "CI_X is not 0=false", "--gate", "owner=true"])
            self.assertEqual(code, 0)
            text = out.getvalue()
            self.assertIn("::warning title=fleet fallback::mac runs on a Mac", text)
            record = json.loads(text.split("fleet-fallback: ", 1)[1].splitlines()[0])
            self.assertEqual(record["kind"], "gate")
            self.assertEqual(record["gates"], {"CI_X is not 0": False, "owner": True})
            self.assertEqual(record["run"], "7")
            self.assertIn("Fleet fallback", summary.read_text())

    def test_main_is_quiet_when_the_answer_was_taken(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(ff.main(["--job", "mac", "--fleet", "fleet", "--result", "success", "--verdict", "pass"]), 0)
        self.assertNotIn("::warning", out.getvalue())


class Workflow(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.jobs = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]

    def test_every_mac_partner_says_why_it_fell(self):
        for mac, fleets in PARTNERS.items():
            with self.subTest(mac=mac):
                for fleet in fleets:
                    self.assertIn(fleet, self.jobs[mac]["needs"])
                steps = [s.get("name") for s in self.jobs[mac]["steps"]]
                self.assertIn(STEP, steps)
                # After the checkout that brings the script, before any Mac work.
                self.assertLess(steps.index("Drop stale submodule checkouts (self-hosted reused workspace)"),
                                steps.index(STEP))
                step = self.jobs[mac]["steps"][steps.index(STEP)]
                self.assertIs(step["continue-on-error"], True)
                self.assertIn("scripts/ci/fleet_fallback.py", step["run"])
                for fleet in fleets:
                    self.assertIn(f"needs.{fleet}.result", step["env"]["FLEET_RESULT"])
                    self.assertIn(f"needs.{fleet}.outputs.verdict", step["env"]["FLEET_VERDICT"])

    def test_every_named_gate_is_in_its_fleet_job_if(self):
        for mac, fleets in PARTNERS.items():
            step = next(s for s in self.jobs[mac]["steps"] if s.get("name") == STEP)
            gates = {k: v for k, v in step["env"].items() if k.startswith("FLEET_GATE_")}
            self.assertTrue(gates, mac)
            fleet_ifs = " ".join(self.jobs[f]["if"] for f in fleets)
            for key, value in gates.items():
                with self.subTest(mac=mac, gate=key):
                    self.assertIn(f'--gate "${key}"', step["run"])
                    expr = re.fullmatch(r"[^=]+=\$\{\{ (.*) \}\}", value).group(1)
                    # A per-event gate is "<other event> || <the fleet job's condition>".
                    leaf = expr.split(" || ", 1)[-1]
                    self.assertIn(leaf, fleet_ifs)

    def test_the_scheme_step_runs_exactly_when_the_fleet_app_is_not_taken(self):
        step = next(s for s in self.jobs["cmux-scheme-compile"]["steps"] if s.get("name") == STEP)
        self.assertEqual(step["if"], "${{ inputs.dev_daily != true && env.CMUX_SCHEME_FLEET_JOB == '' }}")
        self.assertIn("(vars.CI_SCHEME_COMPILE_FLEET || '1') != '0'", step["env"]["FLEET_GATE_0"])


if __name__ == "__main__":
    unittest.main()
