#!/usr/bin/env python3
"""cmux-next.yml's landing compile: every feat-cmux-next landing compiles the DEV Release app at once.

dev-landing-place (scripts/ci/dev_landing_place.py) picks the owned Mac whose cache is nearest,
dev-landing-compile compiles there and records the app under the reuse key the DEV run reads,
and leaves the holder record the next landing's placement reads. These pin the wiring:
landings only, never cancelled, one producer of a landing's DEV app, Blacksmith only as overflow.
"""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

import dev_landing_place as place  # noqa: E402
import dev_release_product_reuse as reuse  # noqa: E402


class WorkflowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.jobs = yaml.load((ROOT / ".github/workflows/cmux-next.yml").read_text(), Loader=yaml.BaseLoader)["jobs"]

    def test_only_feat_cmux_next_landings_run_it(self):
        condition = self.jobs["dev-landing-place"]["if"]
        self.assertIn("github.event_name == 'push' && github.ref == 'refs/heads/feat-cmux-next'", condition)
        self.assertIn("vars.CMUX_NEXT_DEV_LANDING_COMPILE", condition)
        self.assertEqual(self.jobs["dev-landing-compile"]["needs"], "dev-landing-place")

    def test_each_landing_compiles_in_its_own_never_cancelled_group(self):
        concurrency = self.jobs["dev-landing-compile"]["concurrency"]
        self.assertIn("github.run_id", concurrency["group"])
        self.assertEqual(concurrency["cancel-in-progress"], "false")
        for job in ("dev-landing-place", "dev-landing-compile"):
            self.assertNotIn("push-head-preflight", str(self.jobs[job].get("needs", "")),
                             "a superseded landing still compiles: it warms the next one")

    def test_runs_on_takes_the_placement_then_blacksmith(self):
        runs_on = self.jobs["dev-landing-compile"]["runs-on"]
        self.assertIn("fromJSON(needs.dev-landing-place.outputs.runs_on)", runs_on)
        self.assertTrue(runs_on.rstrip(" }").endswith("'blacksmith-12vcpu-macos-26'"), runs_on)
        self.assertIn("needs.dev-landing-place.outputs.runner_label", self.jobs["dev-landing-compile"]["env"]["CMUX_NEXT_RUNNER"])

    def test_the_compile_records_its_app_where_the_dev_run_looks(self):
        job = self.jobs["dev-landing-compile"]
        self.assertIn(job["name"], reuse.PRODUCER_JOBS, "the DEV run's lookup refuses a record of an unknown job")
        steps = {step.get("name"): step for step in job["steps"]}
        self.assertIn("job_input_fingerprint.py dev-release-product", steps["Look up the DEV Release app compiled on the same inputs"]["run"])
        self.assertEqual(steps["Upload the cmux NEXT DEV Release app"]["with"]["name"],
                         reuse.PRODUCT_PREFIX + "${{ github.sha }}")
        self.assertEqual(steps["Upload the DEV Release app record"]["with"]["name"],
                         reuse.RECORD_PREFIX + "${{ steps.dev-product.outputs.key }}")
        compile_run = steps["Compile the cmux NEXT DEV Release app"]["run"]
        self.assertIn("scripts/cmux-next/compile-dev-release.sh", compile_run)
        # The DEV run's key inputs: the same build settings as cmux-scheme-compile's DEV step.
        dev = {step.get("id"): step for step in self.jobs["cmux-scheme-compile"]["steps"]}["compile-cmux-next-dev-release"]["env"]
        landing = steps["Compile the cmux NEXT DEV Release app"]["env"]
        for key in ("CMUX_NEXT_CONFIGURATION", "CMUX_NEXT_PRODUCT_NAME", "CMUX_NEXT_BUNDLE_ID",
                    "CMUX_NEXT_CODE_SIGN_ENTITLEMENTS", "CMUX_NEXT_AUTH_CALLBACK_SCHEME", "CMUX_NEXT_TUI_MODE",
                    "CMUX_NEXT_BROWSER_DATA_IMPORT", "CMUX_NEXT_COMPILATION_CACHE", "CMUX_NEXT_SWIFT_COMPILATION_MODE"):
            self.assertEqual(landing[key], dev[key], key)

    def test_a_host_build_leaves_the_record_the_picker_reads(self):
        steps = {step.get("name"): step for step in self.jobs["dev-landing-compile"]["steps"]}
        upload = steps["Record this host's cache for the next landing's placement"]
        self.assertEqual(upload["with"]["name"], place.HOLDER_PREFIX + "${{ steps.report.outputs.holder }}")
        self.assertEqual(upload["with"]["overwrite"], "true")
        self.assertIn("scripts/cmux-next/dev-cas-holder.sh", steps["Report the landing compile"]["run"])
        # The DEV run's host build moves a host's cache too.
        dev = {step.get("name"): step for step in self.jobs["cmux-scheme-compile"]["steps"]}
        self.assertIn("scripts/cmux-next/dev-cas-holder.sh", dev["Record this host's cache for the next landing's placement"]["run"])
        # Its record's commit is the run's head_sha: a same-tree dispatch compiles another commit.
        self.assertIn("inputs.same_tree_sha == '' || inputs.same_tree_sha == github.sha",
                      dev["Record this host's cache for the next landing's placement"]["if"])
        self.assertEqual(dev["Upload this host's cache record"]["with"]["name"],
                         place.HOLDER_PREFIX + "${{ steps.dev-holder.outputs.holder }}")

    def test_a_push_has_one_producer_of_its_dev_app(self):
        # While the landing compile is on, cmux-scheme-compile builds a push's DEV app only when it is off.
        dev = {step.get("id"): step for step in self.jobs["cmux-scheme-compile"]["steps"]}
        for step_id in ("dev-product", "compile-cmux-next-dev-release"):
            condition = dev[step_id]["if"]
            push_branch = condition[:condition.index("(github.event_name == 'workflow_dispatch'")]
            self.assertIn("github.event_name == 'push'", push_branch)
            # The exact complement of dev-landing-place's condition: one of the two produces.
            self.assertIn("(format('{0}', vars.CMUX_NEXT_DEV_LANDING_COMPILE) == '0' || github.repository != 'manaflow-ai/cmux')",
                          push_branch)
        landing = self.jobs["dev-landing-place"]["if"]
        self.assertIn("github.repository == 'manaflow-ai/cmux'", landing)
        self.assertIn("format('{0}', vars.CMUX_NEXT_DEV_LANDING_COMPILE) != '0'", landing)


if __name__ == "__main__":
    unittest.main()
