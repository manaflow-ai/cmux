#!/usr/bin/env python3
"""Exercise receipt classification and the real composite's shell wiring."""

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("receipt", ROOT / "scripts/ci/cache_restore_receipt.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class CacheRestoreReceiptTests(unittest.TestCase):
    def test_all_routes_distinguish_exact_prefix_unavailable_and_error(self):
        for route in ("github", "warp", "r2"):
            for outcome, hit, matched, expected in (
                ("success", "true", "family-exact", "exact"),
                ("success", "false", "family-older", "prefix"),
                ("success", "", "", "miss_or_unavailable"),
                ("success", "false", "", "miss_or_unavailable"),
                ("failure", "true", "family-exact", "error"),
                ("cancelled", "", "", "cancelled"),
            ):
                with self.subTest(route=route, expected=expected):
                    env = {f"CACHE_{route.upper()}_OUTCOME": outcome,
                           f"CACHE_{route.upper()}_HIT": hit,
                           f"CACHE_{route.upper()}_MATCHED": matched,
                           "CACHE_STARTED_NS": "1000000000"}
                    result = MODULE.receipt(env, 3500000000)
                    self.assertEqual(result["result"], expected)
                    self.assertEqual(result["elapsed_seconds"], 2.5)
                    self.assertEqual(result["matched_key"], matched or None)

    def test_missing_ambiguous_and_invalid_clock_evidence_remains_unknown(self):
        for env in ({}, {"CACHE_GITHUB_OUTCOME": "success", "CACHE_R2_OUTCOME": "success"}):
            self.assertEqual(MODULE.receipt(env, 100)["result"], "unknown")
        for started in ("", "not-a-clock", "-1", "101"):
            self.assertIsNone(MODULE.receipt({"CACHE_STARTED_NS": started}, 100)["elapsed_seconds"])

    def test_real_composite_reports_provider_outputs_without_changing_cache_contract(self):
        action = yaml.safe_load((ROOT / ".github/actions/cache-restore/action.yml").read_text())
        steps = action["runs"]["steps"]
        start = next(step for step in steps if step.get("id") == "receipt-clock")
        report = next(step for step in steps if step.get("id") == "receipt")
        self.assertTrue(start["continue-on-error"])
        self.assertEqual(report["if"], "always()")
        self.assertTrue(report["continue-on-error"])
        self.assertEqual(action["inputs"]["backend"]["default"], "")
        self.assertEqual(action["outputs"]["cache-hit"]["value"],
                         "${{ steps.github.outputs.cache-hit || steps.warp.outputs.cache-hit || steps.r2.outputs.cache-hit }}")
        # Resolve only the expressions present in the real measurement step;
        # external cache actions are simulated at their documented output boundary.
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            env = {**os.environ, "GITHUB_OUTPUT": str(directory / "output"),
                   "GITHUB_STEP_SUMMARY": str(directory / "summary"),
                   "GITHUB_ACTION_PATH": str(ROOT / ".github/actions/cache-restore")}
            subprocess.run(["bash", "-e", "-c", start["run"]], env=env, check=True)
            timestamp = (directory / "output").read_text().strip().split("=", 1)[1]
            values = {"inputs.backend": "warp", "inputs.key": "xcode-cas-quote'\n```$never_execute",
                      "steps.receipt-clock.outputs.started_ns": timestamp}
            for route in ("github", "warp", "r2"):
                values[f"steps.{route}.outcome"] = "success" if route == "github" else "skipped"
                values[f"steps.{route}.outputs.cache-hit"] = "false" if route == "github" else ""
                values[f"steps.{route}.outputs.cache-matched-key"] = "xcode-cas-prior" if route == "github" else ""
            for name, expression in report["env"].items():
                env[name] = values[expression.removeprefix("${{ ").removesuffix(" }}")]
            output = subprocess.check_output(["bash", "-e", "-c", report["run"]], env=env, text=True)
            record = json.loads(output.removeprefix("CMUX_CACHE_RESTORE "))
            self.assertEqual(record["action_route"], "github-cache")
            self.assertEqual(record["requested_backend"], "warp")
            self.assertEqual(record["result"], "prefix")
            self.assertEqual(record["key"], values["inputs.key"])
            self.assertGreaterEqual(record["elapsed_seconds"], 0)
            self.assertIn("physical storage provider", (directory / "summary").read_text())


if __name__ == "__main__":
    unittest.main()
