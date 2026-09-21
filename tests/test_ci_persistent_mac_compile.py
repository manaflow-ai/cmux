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
SEMANTIC_ENTRYPOINT = ROOT / "scripts/ci/persistent-mac-semantic-entrypoint.sh"


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
    def test_bounded_observation_handles_ready_timeout_and_cancel(self):
        class FakeEvent:
            def __init__(self, clock, *, cancel_on_wait=False):
                self.clock = clock
                self.cancel_on_wait = cancel_on_wait

            def wait(self, seconds):
                self.clock[0] += seconds
                return self.cancel_on_wait

        clock = [0.0]
        attempts = []
        ready = route.observe_until(
            10.0,
            2.0,
            lambda: "ready" if len(attempts) >= 2 else attempts.append("try"),
            cancel_event=FakeEvent(clock),
            monotonic=lambda: clock[0],
        )
        self.assertEqual(ready, "ready")
        self.assertEqual(len(attempts), 2)

        clock = [0.0]
        timed_out = route.observe_until(
            5.0,
            2.0,
            lambda: None,
            cancel_event=FakeEvent(clock),
            monotonic=lambda: clock[0],
        )
        self.assertIsNone(timed_out)
        self.assertEqual(clock[0], 5.0)

        clock = [0.0]
        with self.assertRaisesRegex(route.RoutingCanceled, "canceled"):
            route.observe_until(
                5.0,
                1.0,
                lambda: None,
                cancel_event=FakeEvent(clock, cancel_on_wait=True),
                monotonic=lambda: clock[0],
            )

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

    def test_live_verification_binds_the_originating_ci_run(self):
        class API:
            def __init__(self, run_overrides=None):
                self.run_overrides = run_overrides or {}

            def api(self, path):
                if path.startswith("actions/runs/"):
                    value = {
                        "id": 123,
                        "event": "pull_request",
                        "run_attempt": 2,
                        "path": ".github/workflows/ci.yml",
                        "head_sha": "a" * 40,
                        "head_repository": {"full_name": "manaflow-ai/cmux"},
                        "pull_requests": [{
                            "number": 13198,
                            "head": {"sha": "b" * 40},
                            "base": {"sha": "c" * 40},
                        }],
                    }
                    value.update(self.run_overrides)
                    return value
                if path == "pulls/13198":
                    return {
                        "state": "open",
                        "author_association": "MEMBER",
                        "head": {"sha": "b" * 40, "repo": {"full_name": "manaflow-ai/cmux"}},
                        "base": {"sha": "c" * 40},
                        "merge_commit_sha": "a" * 40,
                    }
                if path == "git/commits/" + "a" * 40:
                    return {"tree": {"sha": "d" * 40}}
                raise AssertionError(path)

        live = args(
            run_id="123",
            run_attempt="2",
            source_sha="a" * 40,
            source_tree="d" * 40,
            source_parent1="c" * 40,
            head_sha="b" * 40,
        )
        self.assertEqual(route.verify_live_request(API(), live), (True, "verified"))
        self.assertEqual(
            route.verify_live_request(API({"event": "push"}), live),
            (False, "source_run_event_mismatch"),
        )
        self.assertEqual(
            route.verify_live_request(API({"head_sha": "e" * 40}), live),
            (False, "source_run_source_mismatch"),
        )
        self.assertEqual(
            route.verify_live_request(API({"pull_requests": [{"number": 99}]}), live),
            (False, "source_run_pr_mismatch"),
        )

    def test_route_budget_always_fits_controller_window(self):
        self.assertTrue(route.valid_budget(90, 480))
        self.assertTrue(route.valid_budget(120, 480))
        self.assertFalse(route.valid_budget(121, 480))
        self.assertFalse(route.valid_budget(120, 481))
        self.assertFalse(route.valid_budget(120, 500))

    def test_observe_only_budget_is_short_and_bounded(self):
        self.assertTrue(route.valid_observe_budget(5))
        self.assertTrue(route.valid_observe_budget(60))
        self.assertFalse(route.valid_observe_budget(4))
        self.assertFalse(route.valid_observe_budget(61))

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
        cls.semantic_entrypoint = SEMANTIC_ENTRYPOINT.read_text()
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
        self.assertIn("cmux-workload-result.json", self.producer)
        self.assertIn("semantic profile:", self.producer)

    def test_dispatch_authority_is_default_branch_only(self):
        self.assertIn("  workflow_run:", self.router)
        self.assertIn("    workflows: [CI]", self.router)
        self.assertIn("    types: [in_progress]", self.router)
        self.assertIn("\npermissions: {}\n", self.router)
        self.assertIn("      actions: write", self.router)
        self.assertIn("          ref: main", self.router)
        self.assertIn("persistent-mac-route-request-", self.router)
        route_text = ROUTE.read_text()
        self.assertIn('actions/runs/{args.run_id}', route_text)
        self.assertIn('"source_run_source_mismatch"', route_text)
        self.assertIn('"source_run_pr_mismatch"', route_text)
        self.assertNotIn("actions: write", self.ci)
        admission = self.ci.split("  macos-compile-admission:", 1)[1].split(
            "  app-host-unit-tests:", 1
        )[0]
        self.assertNotIn("  persistent-mac-compile-route:", self.ci)
        self.assertIn("      actions: read", admission)
        self.assertIn("      pull-requests: read", admission)
        self.assertIn("--observe-only", admission)
        self.assertIn("--observe-seconds 60", admission)

    def test_ci_routes_only_trusted_prs_and_preserves_hosted_fallback(self):
        admission = self.ci.split("  macos-compile-admission:", 1)[1].split(
            "  app-host-unit-tests:", 1
        )[0]
        self.assertIn("vars.CI_PERSISTENT_MAC_COMPILE", admission)
        self.assertIn("persistent-mac-route-request-", self.ci)
        self.assertIn("steps.source-identity.outputs.valid == 'true'", self.ci)
        self.assertIn("source_identity_valid: ${{ steps.source-identity.outputs.valid }}", self.ci)
        self.assertIn("needs.changes.outputs.source_identity_valid == 'true'", admission)
        self.assertIn("github.event.pull_request.head.repo.full_name == github.repository", admission)
        self.assertIn("github.event.pull_request.author_association == 'MEMBER'", admission)
        self.assertIn("github.event.pull_request.author_association == 'OWNER'", admission)
        self.assertNotIn("- persistent-mac-compile-route", admission)
        self.assertIn("steps.persistent-restore.outputs.hit != 'true'", admission)
        self.assertIn("actions/download-artifact@37930b1c2abaa49bbe596cd826c3c89aef350131", admission)
        self.assertIn("run-id: ${{ steps.persistent-route.outputs.producer_run_id }}", admission)

    def test_persistent_product_revalidation_retains_admission_checks(self):
        admission = self.ci.split("  macos-compile-admission:", 1)[1].split(
            "  app-host-unit-tests:", 1
        )[0]
        self.assertIn("persistent producer source identity mismatch", admission)
        self.assertIn("persistent semantic profile identity mismatch", admission)
        self.assertIn("persistent semantic validator mismatch", admission)
        self.assertIn("persistent semantic cleanup incomplete", admission)
        self.assertIn("persistent semantic Xcode identity mismatch", admission)
        self.assertIn("Package.resolved identity mismatch", admission)
        self.assertIn("submodule identity mismatch", admission)
        self.assertIn("Xcode identity mismatch", admission)
        self.assertIn("macOS SDK build mismatch", admission)
        self.assertIn("python3 scripts/swift_warning_budget.py", admission)
        self.assertIn("python3 tests/test_cli_version_memory_guard.py", admission)
        self.assertIn("python3 tests/test_cli_contract_help.py", admission)
        self.assertIn("python3 tests/test_cli_config_doctor.py", admission)
        self.assertIn("macos-compile-admission-metrics-", admission)
        self.assertIn('"classification": classification', admission)

    def test_glaeda_owns_native_state_while_cmux_owns_compile_semantics(self):
        profile = self.profile["profiles"]["ci-compile-admission"]
        self.assertEqual(profile["engine"], "script")
        self.assertEqual(
            self.profile["cache_policies"]["ci-compile-admission"],
            "native",
        )
        self.assertNotIn("preparations", self.profile)
        self.assertEqual(
            profile["executable"],
            "scripts/ci/persistent-mac-semantic-entrypoint.sh",
        )
        self.assertEqual(
            profile["arguments"],
            ["{products}/semantic-state", "{products}/semantic-result.json"],
        )
        self.assertIn(
            "{module_cache}",
            profile["environment"]["CMUX_CI_MODULE_CACHE_PATH"],
        )
        self.assertIn("cmux.macos.compile-admission", self.semantic_entrypoint)
        self.assertIn("--generation 1", self.semantic_entrypoint)
        self.assertIn("state_class=cold", self.semantic_entrypoint)
        self.assertIn("state_class=compiler-warm", self.semantic_entrypoint)
        self.assertIn("cmux_workload_profile.py", self.semantic_entrypoint)
        self.assertIn("#13411", self.semantic_entrypoint)
        self.assertTrue(SEMANTIC_ENTRYPOINT.stat().st_mode & 0o111)

        self.assertIn("--expected-commit", self.driver)
        self.assertIn("--expected-tree", self.driver)
        self.assertIn("require_clean=True", self.driver)
        self.assertIn('"cmux-workload-result"', self.driver)
        self.assertIn('"cmux.macos.compile-admission"', self.driver)
        self.assertIn('"cmux.compile-admission/v1"', self.driver)
        self.assertIn("Package.resolved changed during canonical compile admission", self.driver)
        self.assertIn("quarantine_state(project, args.request_id + \"-semantic-failed\")", self.driver)
        self.assertIn('"cold-reset"', self.driver)
        self.assertIn('"partially-warm"', self.driver)
        self.assertIn('"hot"', self.driver)

    def test_canonical_semantic_receipt_validation_is_fail_closed(self):
        commit = "a" * 40
        tree = "b" * 40
        valid = {
            "document_type": "cmux-workload-result",
            "schema_version": 1,
            "source": {
                "repository": "manaflow-ai/cmux",
                "commit": commit,
                "tree": tree,
            },
            "profile": {"id": "cmux.macos.compile-admission", "generation": 1},
            "semantic_validator": "cmux.compile-admission/v1",
            "result": "passed",
            "validation": {"missing_required_artifact_classes": []},
            "cleanup": {"state": "complete", "process_group_settled": True},
            "benchmark": {
                "state_class": "compiler-warm",
                "semantic_comparison_key": "sha256:" + "c" * 64,
                "comparison_context_key": "sha256:" + "d" * 64,
            },
            "toolchain": {
                "identity": "sha256:" + "e" * 64,
                "observations": {},
            },
            "stage_timings": [
                {"stage": "setup", "seconds": 1.0},
                {"stage": "dependency_preparation", "seconds": 2.0},
                {"stage": "compile", "seconds": 3.0},
                {"stage": "validation", "seconds": 4.0},
            ],
        }
        self.assertIs(driver.validate_semantic_result(valid, commit, tree), valid)
        bad = json.loads(json.dumps(valid))
        bad["cleanup"]["state"] = "forced"
        with self.assertRaisesRegex(driver.Refusal, "cleanup"):
            driver.validate_semantic_result(bad, commit, tree)
        bad = json.loads(json.dumps(valid))
        bad["profile"]["generation"] = 2
        with self.assertRaisesRegex(driver.Refusal, "profile"):
            driver.validate_semantic_result(bad, commit, tree)


if __name__ == "__main__":
    unittest.main()
