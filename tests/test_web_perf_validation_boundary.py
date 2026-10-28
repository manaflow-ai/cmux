#!/usr/bin/env python3
"""Keep untrusted measurement and trusted policy evaluation in separate jobs.

Job and checkout provenance are the security boundary here: measurement can
rewrite every file on its runner, including RUNNER_TEMP and installed tools.
Artifacts crossing into validation are data, never executable policy.
"""
from pathlib import Path
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[1]


class WebPerfValidationBoundaryTests(unittest.TestCase):
    def test_policy_evaluation_has_its_own_fresh_hosted_runner_and_base_checkout(self):
        workflow = yaml.load(
            (ROOT / ".github/workflows/cmux-next-web-perf.yml").read_text(),
            Loader=yaml.BaseLoader,
        )
        jobs = workflow["jobs"]
        measuring = [(key, job) for key, job in jobs.items()
                     if any("scripts/latency/run.ts" in step.get("run", "") for step in job["steps"])]
        validating = [(key, job) for key, job in jobs.items()
                      if any("scripts/latency/validate.ts" in step.get("run", "") for step in job["steps"])]
        self.assertEqual(len(measuring), 1)
        self.assertEqual(len(validating), 1)
        measure_id, _ = measuring[0]
        validate_id, validator = validating[0]
        self.assertNotEqual(measure_id, validate_id, "head code can overwrite same-runner policy and tools")
        self.assertIn(measure_id, validator["needs"])
        self.assertIn("blacksmith-4vcpu-ubuntu-2404", validator["runs-on"])
        self.assertNotIn("vars.LINUX_RUNNER", validator["runs-on"])
        checkouts = [step for step in validator["steps"] if step.get("uses", "").startswith("actions/checkout@")]
        self.assertEqual(len(checkouts), 1)
        self.assertIn("github.event.pull_request.base.sha", checkouts[0]["with"]["ref"])
        self.assertNotIn("head.sha", checkouts[0]["with"]["ref"])
        self.assertTrue(any(step.get("uses", "").startswith("actions/download-artifact@") for step in validator["steps"]))
        for step in validator["steps"]:
            self.assertFalse(step.get("uses", "").startswith("./"), "candidate actions must not execute during validation")
            command = step.get("run", "")
            self.assertNotIn("bun install", command)
            self.assertNotIn("scripts/latency/run.ts", command)
            if "scripts/latency/validate.ts" in command:
                self.assertIn("--trace-dir", command)
                self.assertNotIn("$RUNNER_TEMP/web-perf-validator", command)


if __name__ == "__main__":
    unittest.main()
