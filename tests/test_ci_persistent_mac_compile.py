#!/usr/bin/env python3
"""Regression coverage for the persistent-Mac compile-admission pilot."""

from __future__ import annotations

import argparse
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
ROUTE = ROOT / "scripts/ci/persistent_mac_route.py"
CI = ROOT / ".github/workflows/ci.yml"
PRODUCER = ROOT / ".github/workflows/persistent-macos-compile.yml"
ROUTER = ROOT / ".github/workflows/persistent-macos-router.yml"
PROFILE = ROOT / "glaeda.apple.json"
DRIVER = ROOT / "scripts/ci/run-persistent-mac-compile.py"


spec = importlib.util.spec_from_file_location("persistent_mac_route", ROUTE)
route = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(route)


driver_spec = importlib.util.spec_from_file_location("persistent_mac_driver", DRIVER)
driver = importlib.util.module_from_spec(driver_spec)
assert driver_spec.loader is not None
driver_spec.loader.exec_module(driver)


def args(**overrides):
    values = {
        "selector": "pilot",
        "event_name": "pull_request",
        "head_repository": "manaflow-ai/cmux",
        "repository": "manaflow-ai/cmux",
        "author_association": "MEMBER",
        "cohort": "13198,feature/persistent",
        "pr_number": "13198",
        "head_ref": "feature/persistent",
    }
    values.update(overrides)
    return argparse.Namespace(**values)


class RoutingTests(unittest.TestCase):
    def test_retry_wait_retries_with_bounded_backoff_without_fixed_sleep(self):
        current = [0.0]
        waits = []
        probes = []

        def clock():
            return current[0]

        def wait(delay):
            waits.append(delay)
            current[0] += delay
            return False

        waiter = route.RetryWait(clock=clock, wait=wait)

        def probe():
            probes.append(current[0])
            return (len(probes) == 3, "ready" if len(probes) == 3 else None)

        self.assertEqual(waiter.until(10.0, probe), "ready")
        self.assertEqual(len(probes), 3)
        self.assertEqual(waits, [0.5, 1.0])

    def test_retry_wait_is_cancellation_aware(self):
        waiter = route.RetryWait()
        waiter.cancel()
        with self.assertRaises(route.RetryCancelled):
            waiter.until(route.now() + 10, lambda: (False, None))

    def test_only_trusted_same_repository_members_are_eligible(self):
        self.assertEqual(route.eligibility(args()), (True, "pilot"))
        self.assertEqual(
            route.eligibility(args(head_repository="someone/cmux")),
            (False, "untrusted_repository"),
        )
        self.assertEqual(
            route.eligibility(args(author_association="CONTRIBUTOR")),
            (False, "untrusted_author"),
        )
        self.assertEqual(
            route.eligibility(args(event_name="merge_group")),
            (False, "event_not_pull_request"),
        )

    def test_selector_and_cohort_are_reversible(self):
        for selector in ("", "0", "off", "false"):
            self.assertEqual(route.eligibility(args(selector=selector)), (False, "selector_off"))
        self.assertEqual(
            route.eligibility(args(pr_number="99", head_ref="other")),
            (False, "outside_pilot_cohort"),
        )
        self.assertEqual(route.eligibility(args(selector="all", cohort="")), (True, "all"))
        self.assertEqual(
            route.eligibility(args(selector="unexpected")),
            (False, "invalid_selector"),
        )

    def test_route_budget_always_fits_controller_window(self):
        self.assertTrue(route.valid_budget(90, 480))
        self.assertTrue(route.valid_budget(120, 480))
        self.assertFalse(route.valid_budget(121, 480))
        self.assertFalse(route.valid_budget(120, 481))
        self.assertFalse(route.valid_budget(120, 500))

    def test_output_helpers_record_hosted_fallback_and_persistent_success(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "output"
            output.touch()
            self.assertEqual(route.fallback(output, "queue_timeout", producer_run_id=42), 0)
            values = dict(line.split("=", 1) for line in output.read_text().splitlines())
            self.assertEqual(values["use_persistent"], "false")
            self.assertEqual(values["fallback_reason"], "queue_timeout")
            self.assertEqual(values["producer_run_id"], "42")

            output.write_text("")
            self.assertEqual(
                route.success(
                    output,
                    run_id=43,
                    artifact_id=99,
                    queue_seconds=1.25,
                    allocated_seconds=31.5,
                ),
                0,
            )
            values = dict(line.split("=", 1) for line in output.read_text().splitlines())
            self.assertEqual(values["use_persistent"], "true")
            self.assertEqual(values["producer_run_id"], "43")
            self.assertEqual(values["artifact_id"], "99")
            self.assertEqual(values["queue_to_start_seconds"], "1.25")
            self.assertEqual(values["producer_allocated_seconds"], "31.5")


class StateRetentionTests(unittest.TestCase):
    def test_quarantine_pruning_keeps_only_newest_owned_store(self):
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory)
            glaeda = project / ".glaeda"
            glaeda.mkdir()
            old = []
            for index in range(3):
                path = glaeda / f"apple-build-quarantine-run-{index}"
                path.mkdir()
                (path / "marker").write_text(str(index))
                os_time = 1_000_000_000 + index
                path.touch()
                import os
                os.utime(path, ns=(os_time, os_time))
                old.append(path)
            unrelated = glaeda / "unrelated"
            unrelated.mkdir()

            driver.prune_quarantine_stores(project)

            remaining = sorted(glaeda.glob("apple-build-quarantine-*"))
            self.assertEqual(len(remaining), driver.QUARANTINE_RETAINED_STORES)
            self.assertEqual(remaining[0].name, old[-1].name)
            self.assertTrue(unrelated.is_dir())


class WorkflowContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.ci = CI.read_text()
        cls.producer = PRODUCER.read_text()
        cls.router = ROUTER.read_text()
        cls.driver = DRIVER.read_text()
        cls.profile = json.loads(PROFILE.read_text())

    def test_producer_is_manual_dedicated_and_credential_minimized(self):
        self.assertIn("  workflow_dispatch:", self.producer)
        for trigger in ("pull_request:", "pull_request_target:", "push:", "schedule:", "merge_group:"):
            self.assertNotIn(f"  {trigger}", self.producer)
        self.assertEqual(
            self.producer.count("      group: cmux-persistent-compile"),
            1,
        )
        self.assertEqual(self.producer.split("on:", 1)[1].split("permissions:", 1)[0].count("  workflow_dispatch:"), 1)
        self.assertIn("\npermissions: {}\n", self.producer)
        self.assertIn("      labels: [self-hosted, macOS, ARM64, cmux-persistent-macos-compile]", self.producer)
        self.assertIn("  compile:", self.producer)
        compile_block = self.producer.split("  compile:", 1)[1]
        self.assertIn("    permissions: {}", compile_block)
        self.assertNotIn("secrets.", self.producer)
        self.assertNotIn("actions/checkout@", self.producer)
        self.assertRegex(self.producer, r"(?m)^      GLAEDA_REF: [a-f0-9]{40}$")

    def test_dispatch_authority_is_default_branch_only(self):
        self.assertIn("  workflow_run:", self.router)
        self.assertIn("    workflows: [CI]", self.router)
        self.assertIn("    types: [in_progress]", self.router)
        self.assertIn("\npermissions: {}\n", self.router)
        self.assertIn("      actions: write", self.router)
        self.assertIn("          ref: main", self.router)
        self.assertIn("persistent-mac-route-request-", self.router)
        self.assertNotIn("actions: write", self.ci)
        route_block = self.ci.split("  persistent-mac-compile-route:", 1)[1].split(
            "  macos-compile-admission:", 1
        )[0]
        self.assertIn("      actions: read", route_block)
        self.assertIn("--observe-only", route_block)

    def test_ci_routes_only_trusted_prs_and_preserves_hosted_fallback(self):
        route_block = self.ci.split("  persistent-mac-compile-route:", 1)[1].split(
            "  macos-compile-admission:", 1
        )[0]
        self.assertIn("vars.CI_PERSISTENT_MAC_COMPILE", route_block)
        self.assertIn("persistent-mac-route-request-", self.ci)
        self.assertIn("github.event.pull_request.head.repo.full_name == github.repository", route_block)
        self.assertIn("github.event.pull_request.author_association == 'MEMBER'", route_block)
        self.assertIn("github.event.pull_request.author_association == 'OWNER'", route_block)
        admission = self.ci.split("  macos-compile-admission:", 1)[1].split(
            "  app-host-unit-tests:", 1
        )[0]
        self.assertNotIn("needs.persistent-mac-compile-route.result == 'success'", admission)
        self.assertIn("steps.persistent-restore.outputs.hit != 'true'", admission)
        self.assertIn("actions/download-artifact@37930b1c2abaa49bbe596cd826c3c89aef350131", admission)
        self.assertIn("run-id: ${{ needs.persistent-mac-compile-route.outputs.producer_run_id }}", admission)

    def test_persistent_product_revalidation_retains_admission_checks(self):
        admission = self.ci.split("  macos-compile-admission:", 1)[1].split(
            "  app-host-unit-tests:", 1
        )[0]
        self.assertIn("persistent producer source identity mismatch", admission)
        self.assertIn("Package.resolved identity mismatch", admission)
        self.assertIn("submodule identity mismatch", admission)
        self.assertIn("Xcode identity mismatch", admission)
        self.assertIn("macOS SDK build mismatch", admission)
        self.assertIn("python3 scripts/swift_warning_budget.py", admission)
        self.assertIn("python3 tests/test_cli_version_memory_guard.py", admission)
        self.assertIn("python3 tests/test_cli_contract_help.py", admission)
        self.assertIn("macos-compile-admission-metrics-", admission)
        self.assertIn('"classification": classification', admission)

    def test_glaeda_profile_owns_native_cache_paths_but_not_result_authority(self):
        profile = self.profile["profiles"]["ci-compile-admission"]
        self.assertEqual(profile["engine"], "script")
        self.assertEqual(
            self.profile["cache_policies"]["ci-compile-admission"],
            "native",
        )
        self.assertEqual(
            self.profile["preparations"]["ci-compile-admission"]["engine"],
            "xcode",
        )
        self.assertIn("{derived_data}", profile["arguments"])
        self.assertIn("{source_packages}", profile["arguments"])
        self.assertIn("{module_cache}", profile["environment"]["CMUX_CI_MODULE_CACHE_PATH"])
        self.assertEqual(profile["arguments"][-1], "{derived_data}/persistent-build-aggregate.log")
        self.assertNotEqual(profile["arguments"][-1], "{derived_data}/cmux-build.log")
        self.assertIn("--expected-commit", self.driver)
        self.assertIn("--expected-tree", self.driver)
        self.assertIn("require_clean=True", self.driver)
        self.assertIn("Package.resolved changed during package readiness", self.driver)
        self.assertIn('"cold-reset"', self.driver)
        self.assertIn('"partially-warm"', self.driver)
        self.assertIn('"hot"', self.driver)


if __name__ == "__main__":
    unittest.main()
