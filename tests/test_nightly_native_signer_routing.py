#!/usr/bin/env python3
"""Native activation preserves the Linux fallback, dependency and trust contracts."""
import os
from pathlib import Path
import sys
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/ci"))
sys.path.insert(0, str(ROOT / "tests"))
import nightly_native_signing as native
from test_nightly_trusted_routing import evaluate, parse_expression
from test_ci_signing_owned_mac import CLAIM_GATE

DOC = yaml.safe_load((ROOT / ".github/workflows/nightly.yml").read_text())
JOBS = ("signer-app", "signer-app-notary", "signer-dmg")
PICK = "needs.pick-nightly-sign-runner.outputs."


def enabled_env():
    return dict(GITHUB_REPOSITORY="manaflow-ai/cmux", GITHUB_REF="refs/heads/nightly-next",
                GITHUB_EVENT_NAME="push", GITHUB_RUN_ATTEMPT="1", ENABLED="1", OWNED_ENABLED="1",
                NATIVE_SIGNER_CAPABILITY="keychain-v1", NIGHTLY_ONLY_LABEL=native.LABEL)


def context(pool=native.LABEL, **changes):
    value = {"github.repository": "manaflow-ai/cmux", "github.repository_owner": "manaflow-ai",
             "github.event_name": "push", "github.run_attempt": 1,
             PICK + "native_owned_pool": pool, PICK + "attempt": "1",
             PICK + "linux": "blacksmith-4vcpu-ubuntu-2404",
             PICK + "linux_alternate": "blacksmith-16vcpu-ubuntu-2404",
             "needs.decide.outputs.track": "nightly-next", "inputs.sign_pool": True,
             "needs.decide.outputs.should_build": "true", "needs.decide.outputs.variants": '["arm64"]',
             "_cancelled": False}
    for name in JOBS:
        for dependency in DOC["jobs"][name]["needs"]:
            value["needs." + dependency + ".result"] = "success"
    value["needs.signer-build.result"] = "skipped" if pool else "success"
    value.update(changes)
    return value


def expression(source, values):
    return evaluate(parse_expression(source.removeprefix("${{").removesuffix("}}").replace(
        "cancelled()", "_cancelled")), values)


class NativeActivation(unittest.TestCase):
    def test_exact_proven_capability_is_required(self):
        good = enabled_env()
        self.assertEqual(native.native_pool(good), native.LABEL)
        for key in good:
            for replacement in ("", "unknown", good[key] + " "):
                with self.subTest(key=key, replacement=replacement):
                    self.assertEqual(native.native_pool({**good, key: replacement}), "")
        for change in ({"GITHUB_RUN_ATTEMPT": "2"}, {"GITHUB_EVENT_NAME": "workflow_dispatch"},
                       {"GITHUB_EVENT_NAME": "pull_request"}, {"GITHUB_REPOSITORY": "manaflow-ai/another"},
                       {"GITHUB_REF": "refs/heads/main"}, {"NIGHTLY_ONLY_LABEL": "macos-26"}):
            self.assertEqual(native.native_pool({**good, **change}), "")

    def test_cli_outputs_no_phantom_pool_when_disabled(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "output"
            for capability, expected in (("", ""), (native.CAPABILITY, native.LABEL)):
                output.write_text("")
                native.main({**enabled_env(), "GITHUB_OUTPUT": str(output),
                             "NATIVE_SIGNER_CAPABILITY": capability})
                self.assertEqual(output.read_text(), f"owned_pool={expected}\n")

    def test_native_jobs_use_owned_path_but_retry_ignores_stale_pick(self):
        for name in JOBS:
            route = DOC["jobs"][name]["runs-on"]
            with self.subTest(job=name):
                self.assertEqual(expression(route, context()), native.LABEL)
                self.assertEqual(expression(route, context("")), "blacksmith-4vcpu-ubuntu-2404")
                self.assertEqual(expression(route, context(**{"github.run_attempt": 2})),
                                 "blacksmith-16vcpu-ubuntu-2404")

    def test_native_path_skips_unused_compiler_and_allows_only_that_skip(self):
        compiler = DOC["jobs"]["signer-build"]
        self.assertFalse(expression(compiler["if"], context()))
        self.assertTrue(expression(compiler["if"], context("")))
        for name in JOBS:
            job = DOC["jobs"][name]
            self.assertTrue(expression(job["if"], context()))
            self.assertTrue(expression(job["if"], context("")))
            for dependency in job["needs"]:
                for result in ("failure", "cancelled", "skipped"):
                    if dependency == "signer-build" and result == "skipped":
                        continue
                    with self.subTest(job=name, dependency=dependency, result=result):
                        self.assertFalse(expression(job["if"], context(**{
                            f"needs.{dependency}.result": result})))
            self.assertFalse(expression(job["if"], context("", **{"needs.signer-build.result": "skipped"})))
            self.assertFalse(expression(job["if"], context(**{"_cancelled": True})))

    def test_native_capability_does_not_enable_disabled_pool_modes(self):
        step = next(step for step in DOC["jobs"]["pick-nightly-sign-runner"]["steps"]
                    if step.get("id") == "native-signing")
        self.assertTrue(expression(step["if"], context()))
        for change in ({"needs.decide.outputs.fast_build": "true"},
                       {"needs.decide.outputs.notary_paused": "true"},
                       {"needs.decide.outputs.build_only": "true"},
                       {"inputs.sign_pool": False},
                       {"inputs.nightly_next_unsigned_run": "123"}):
            self.assertFalse(expression(step["if"], context(**change)))

    def test_claim_before_credentials_and_unconditional_native_cleanup(self):
        for name in JOBS:
            job = DOC["jobs"][name]
            steps = job["steps"]
            self.assertEqual(steps[0]["run"].strip(), CLAIM_GATE.strip())
            claim = next(i for i, step in enumerate(steps)
                         if "signing-runner-claim.sh" in step.get("run", ""))
            first_secret = next(i for i, step in enumerate(steps) if "secrets." in str(step))
            self.assertLess(claim, first_secret)
            self.assertNotIn("secrets.", str(job["env"]))
            cleanup = steps[-1]
            self.assertEqual(cleanup["if"], "always() && runner.os == 'macOS'")
            self.assertIn('signing-keychain.sh delete --keychain "$CMUX_NATIVE_SIGNING_KEYCHAIN"', cleanup["run"])
            self.assertEqual(job["env"]["CMUX_NATIVE_SIGNING_KEYCHAIN"], "build.keychain")
            for step in steps:
                if step.get("name") == "Install the signer" or step.get("with", {}).get("name") == "${{ needs.signer-build.outputs.artifact }}":
                    self.assertEqual(step["if"], "runner.os != 'macOS'")


if __name__ == "__main__":
    unittest.main()
