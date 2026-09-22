#!/usr/bin/env python3
"""Exercise the Linux route CLI and the real required-status gate."""

import ast
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import yaml

from test_ci_change_areas import (
    linux_preflight_needs,
    module,
    run_guard_status,
    run_linux_preflight,
    run_tests_gate,
    tests_gate_needs,
    workflow_job_block,
    workflow_job_step_script,
)


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "scripts/ci/detect_linux_guard_changes.py"
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
from workflow_guard_groups import GROUPS, PATH_OWNERS, STEP_OWNERS
JOBS = {
    "linux_guard_tests": "workflow-guard-tests",
    "linux_guard_history": "workflow-guard-history",
    "linux_guard_cli": "workflow-guard-cli-scripts",
    "linux_guard_source": "workflow-guard-source-lints",
    "ghosttykit_release": "ghosttykit-release-check",
}
REUSABLE_GUARDS = {
    route: job for route, job in JOBS.items() if route != "ghosttykit_release"
}


def route_decision(paths, event="pull_request", macos="false"):
    with tempfile.TemporaryDirectory(prefix="cmux-linux-routes-") as temp:
        path = Path(temp) / "changed.txt"
        if paths is not None:
            path.write_text("\n".join(paths), encoding="utf-8")
        result = subprocess.run(
            [sys.executable, str(HELPER), "--event-name", event,
             "--macos", macos, "--files-from", str(path)],
            capture_output=True, text=True, check=True,
        )
    outputs = dict(line.split("=", 1) for line in result.stdout.splitlines())
    groups = tuple(json.loads(outputs.pop("linux_guard_test_groups")))
    return outputs, groups


def route(paths, event="pull_request", macos="false"):
    return route_decision(paths, event=event, macos=macos)[0]


class LinuxGuardRoutingTests(unittest.TestCase):
    def test_guard_ownership_manifest_has_no_duplicate_literal_keys(self):
        source = (ROOT / "scripts/ci/workflow_guard_groups.py").read_text(encoding="utf-8")
        tree = ast.parse(source)
        assignments = {
            node.targets[0].id: node.value
            for node in tree.body
            if isinstance(node, ast.Assign)
            and len(node.targets) == 1
            and isinstance(node.targets[0], ast.Name)
            and node.targets[0].id in {"STEP_OWNERS", "PATH_OWNERS"}
        }
        self.assertEqual(set(assignments), {"STEP_OWNERS", "PATH_OWNERS"})

        for name, value in assignments.items():
            self.assertIsInstance(value, ast.Dict, name)
            keys = []
            for key in value.keys:
                self.assertIsInstance(key, ast.Constant, (name, ast.dump(key)))
                self.assertIsInstance(key.value, str, (name, ast.dump(key)))
                keys.append(key.value)
            duplicates = sorted({key for key in keys if keys.count(key) > 1})
            self.assertEqual(duplicates, [], (name, duplicates))

    def test_cloud_machine_workflow_skips_macos_for_control_plane_only_prs(self):
        workflow_path = ROOT / ".github/workflows/cloud-machine-tests.yml"
        workflow = workflow_path.read_text(encoding="utf-8")
        changes = workflow_job_block("changes", workflow_path)
        lifecycle = workflow_job_block("lifecycle", workflow_path)

        self.assertIn("uses: ./.github/workflows/resolve-dispatch-ref.yml", workflow)
        self.assertIn(
            "ref: ${{ inputs.ref }}",
            workflow_job_block("resolve-ref", workflow_path),
        )
        self.assertIn("blacksmith-4vcpu-ubuntu-2404", changes)
        self.assertIn("Detect cloud-machine package changes", changes)
        self.assertIn("/pulls/{pr_number}/files?per_page=100&page={page}", changes)
        self.assertIn('startswith("Packages/macOS/CmuxCloudMachines/")', changes)
        self.assertNotIn("actions/checkout", changes)
        self.assertIn("pull-requests: read", workflow)
        self.assertIn("needs: [changes, resolve-ref]", lifecycle)
        self.assertIn(
            "if: ${{ needs.changes.outputs.should_run == 'true' }}",
            lifecycle,
        )
        self.assertIn("ref: ${{ needs.resolve-ref.outputs.sha }}", lifecycle)
        self.assertNotIn("inputs.ref || github.ref", workflow)

    def test_ios_shell_ui_test_only_change_skips_macos(self):
        actual = module.classify_files([
            "Packages/iOS/CmuxMobileShellUI/Tests/CmuxMobileShellUITests/WorkspaceListScrollUpdateTests.swift"
        ])
        self.assertFalse(actual.macos)
        self.assertFalse(actual.web)
        self.assertFalse(actual.release_build)

    def test_candidate_router_cannot_disable_its_own_guards(self):
        script = workflow_job_step_script("changes", "Route Linux guard suites")
        for changed in (
            "scripts/ci/detect_linux_guard_changes.py",
            "scripts/ci/workflow_guard_groups.py",
            ".github/workflows/ci.yml",
            ".github/workflows/ci-guards.yml",
        ):
            with self.subTest(changed=changed), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                changed_file = root / "changed.txt"
                changed_file.write_text(changed + "\n")
                output = root / "output"
                helper = root / "scripts/ci/detect_linux_guard_changes.py"
                helper.parent.mkdir(parents=True)
                helper.write_text('raise SystemExit("candidate helper must not run")\n')
                actual_script = script.replace("/tmp/cmux-ci-changed-files.txt", str(changed_file))
                result = subprocess.run(
                    ["bash", "-c", actual_script], cwd=root, capture_output=True, text=True,
                    env={**os.environ, "GITHUB_OUTPUT": str(output),
                         "EVENT_NAME": "pull_request", "MACOS": "false"},
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                routed = dict(line.split("=", 1) for line in output.read_text().splitlines())
                groups = tuple(json.loads(routed.pop("linux_guard_test_groups")))
                self.assertEqual(routed, dict.fromkeys(JOBS, "true"))
                self.assertEqual(groups, GROUPS)

    def test_testflight_change_routes_only_observing_test_groups(self):
        outputs, groups = route_decision([
            ".github/workflows/ios-testflight.yml",
            "ios/scripts/upload-testflight.sh",
            "tests/test_ios_appstore_lane_identity.py",
        ])
        # Preserve the outer fail-open routes for workflow edits while trimming
        # only the expensive workflow-guard-tests matrix.
        self.assertEqual(outputs, dict.fromkeys(JOBS, "true"))
        self.assertEqual(
            groups,
            ("preflight", "ci", "release-ios", "quality-determinism"),
        )

    def test_unknown_and_policy_inputs_fail_open_to_every_test_group(self):
        for changed in (
            "new-area/input",
            ".github/workflows/ci-guards.yml",
            "scripts/ci/workflow_guard_groups.py",
            "tests/test_ci_release_guard_structure.py",
        ):
            with self.subTest(changed=changed):
                _, groups = route_decision([changed])
                self.assertEqual(groups, GROUPS)

    def test_guard_step_ownership_manifest_matches_workflow(self):
        workflow = yaml.safe_load(
            (ROOT / ".github/workflows/ci-guards.yml").read_text(encoding="utf-8")
        )
        job = workflow["jobs"]["workflow-guard-tests"]
        self.assertEqual(
            job["strategy"]["matrix"]["group"],
            "${{ fromJSON(inputs.linux_guard_test_groups) }}",
        )

        actual = {}
        direct_path = re.compile(
            r"(?:\./)?((?:tests(?:_v2)?|scripts|ios/tests)/[A-Za-z0-9_./-]+)"
        )
        for step in job["steps"]:
            condition = step.get("if", "")
            match = re.fullmatch(r"\$\{\{ matrix\.group == '([^']+)' \}\}", condition)
            if match is None:
                continue
            name = step["name"]
            group = match.group(1)
            self.assertNotIn(name, actual)
            actual[name] = group

            paths = set(direct_path.findall(step.get("run", "")))
            if (
                step.get("working-directory") == "agent-chat"
                and "test/claude-environment.test.ts" in step.get("run", "")
            ):
                paths.add("agent-chat/test/claude-environment.test.ts")
            if name == "Initialize Ghostty for Zig version guard":
                paths.add("ghostty")
            for path in paths:
                self.assertIn(path, PATH_OWNERS, (name, path))
                self.assertIn(group, PATH_OWNERS[path], (name, path, group))

        self.assertEqual(actual, STEP_OWNERS)

    def test_linux_preflight_skips_when_macos_route_is_false(self):
        block = workflow_job_block("linux-preflight")
        self.assertIn(
            "if: ${{ always() && needs.changes.outputs.macos != 'false' }}",
            block,
        )

        no_macos = tests_gate_needs(macos="false", macos_result="skipped")
        no_macos["linux-preflight"]["result"] = "skipped"
        result = run_tests_gate(no_macos)
        self.assertEqual(result.returncode, 0, result.stderr)

        macos = tests_gate_needs()
        macos["linux-preflight"]["result"] = "skipped"
        result = run_tests_gate(macos)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("linux preflight did not pass: skipped", result.stderr)

    def test_docs_skip_all_five_guards_and_gate_succeeds(self):
        for path in ("CLAUDE.md", "AGENTS.md", "Packages/macOS/AGENTS.md",
                     "README.md", "README.ja.md", "docs/build.md", "plans/cache.md"):
            with self.subTest(path=path):
                outputs = route([path])
                self.assertEqual(outputs, dict.fromkeys(JOBS, "false"))
                guard_result = run_guard_status(
                    inputs={route_name: outputs[route_name] for route_name in REUSABLE_GUARDS},
                    results=dict.fromkeys(REUSABLE_GUARDS.values(), "skipped"),
                )
                self.assertEqual(guard_result.returncode, 0, guard_result.stderr)
                result = run_linux_preflight(linux_preflight_needs(
                    outputs=outputs,
                    results={"guards": "skipped", "ghosttykit-release-check": "skipped"},
                ))
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_native_edit_keeps_source_contracts_without_history_or_cli_guards(self):
        outputs = route(["Sources/Settings.swift", "CLAUDE.md"], macos="true")
        self.assertEqual(outputs, {
            "linux_guard_tests": "true", "linux_guard_history": "false",
            "linux_guard_cli": "false", "linux_guard_source": "true",
            "ghosttykit_release": "true",
        })

    def test_cloud_skill_and_its_known_test_keep_only_the_owning_guard(self):
        paths = [
            "skills/cmux-cloud-vm/SKILL.md",
            "skills/cmux-cloud-vm/references/agent-workflows.md",
            "skills/cmux-cloud-vm/references/commands.md",
            "skills/cmux-cloud-vm/references/guest.md",
            "tests/test_cloud_vm_skill_coverage.py",
        ]
        expected = {name: "true" if name == "linux_guard_tests" else "false"
                    for name in JOBS}
        for changed in [[path] for path in paths] + [paths]:
            with self.subTest(changed=changed):
                outputs = route(changed)
                self.assertEqual(outputs, expected)
                guard_results = {
                    job: "success" if outputs[route_name] == "true" else "skipped"
                    for route_name, job in REUSABLE_GUARDS.items()
                }
                guard_result = run_guard_status(
                    inputs={route_name: outputs[route_name] for route_name in REUSABLE_GUARDS},
                    results=guard_results,
                )
                self.assertEqual(guard_result.returncode, 0, guard_result.stderr)
                result = run_linux_preflight(linux_preflight_needs(
                    outputs=outputs,
                    results={"guards": "success", "ghosttykit-release-check": "skipped"},
                ))
                self.assertEqual(result.returncode, 0, result.stderr)
        for unknown in ("tests/test_new_cloud_contract.py",
                        "skills/cmux-cloud-vm/references/new-contract.md",
                        "skills/cmux-cloud-vm/scripts/check.py"):
            with self.subTest(unknown=unknown):
                self.assertEqual(route(paths + [unknown]), dict.fromkeys(JOBS, "true"))
        self.assertEqual(route(paths + ["Sources/Settings.swift"], macos="true"), {
            "linux_guard_tests": "true", "linux_guard_history": "false",
            "linux_guard_cli": "false", "linux_guard_source": "true",
            "ghosttykit_release": "true",
        })

    def test_persistent_mac_control_plane_runs_only_its_own_guard_lane(self):
        expected = {
            name: "true" if name == "linux_guard_tests" else "false" for name in JOBS
        }
        expected_groups = {
            "scripts/ci/persistent_mac_route.py": ("preflight",),
            "scripts/ci/build_graph_health.py": ("preflight",),
            "tests/test_build_graph_health.py": ("preflight", "quality-determinism"),
            "scripts/ci/swift_incremental_diagnostics.py": ("preflight",),
            "tests/test_ci_persistent_mac_compile.py": ("preflight", "quality-determinism"),
            "tests/test_swift_incremental_diagnostics.py": ("preflight", "quality-determinism"),
            "tests/test_ci_self_hosted_guard.sh": ("preflight", "quality-determinism"),
        }
        for path, groups in expected_groups.items():
            with self.subTest(path=path):
                outputs, actual_groups = route_decision([path])
                self.assertEqual(outputs, expected)
                self.assertEqual(actual_groups, groups)

    def test_macos_admission_helpers_run_only_workflow_guard_contracts(self):
        expected = {
            name: "true" if name == "linux_guard_tests" else "false" for name in JOBS
        }
        for path in (
            "scripts/ci/build_input_fingerprint.py",
            "scripts/ci/find_admitted_build.py",
            "scripts/ci/app_host_test_products.py",
            "scripts/ci/compile-app-host-test-product.sh",
            "scripts/ci/product_input_identity.py",
            "scripts/ci/peer_product_source.py",
            "scripts/ci/restore-app-host-test-product.sh",
            "scripts/ci/reuse_app_host_products.py",
            "scripts/ci/sanitize-xcode-source-packages-cache.py",
        ):
            with self.subTest(path=path):
                self.assertEqual(route([path]), expected)

    def test_unknown_ci_helper_still_runs_every_guard(self):
        self.assertEqual(
            route(["scripts/ci/future_unknown_helper.py"]),
            dict.fromkeys(JOBS, "true"),
        )

    def test_web_edit_skips_native_history_cli_and_binary_download(self):
        outputs = route(["web/app/page.tsx"])
        self.assertEqual(outputs, {
            name: "true" if name == "linux_guard_tests" else "false" for name in JOBS
        })

    def test_manifest_and_guard_inputs_keep_their_coverage(self):
        for path, selected in (
            ("Packages/macOS/CmuxSettings/Package.swift", "linux_guard_history"),
            ("cmux.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved", "linux_guard_history"),
            ("cmux.xcodeproj/project.pbxproj", "linux_guard_history"),
            ("ios/cmux.xcworkspace/contents.xcworkspacedata", "linux_guard_history"),
            ("Packages/macOS/CmuxSettings/.gitignore", "linux_guard_history"),
            ("tests/test_check_package_resolved_policy.py", "linux_guard_history"),
            ("scripts/check-package-resolved-policy.py", "linux_guard_history"),
            ("Resources/bin/start-cmux-profiling", "linux_guard_cli"),
            ("scripts/ci/resolve-cmux-tui-client-commit.sh", "linux_guard_cli"),
            ("tests/test_start_cmux_profiling.sh", "linux_guard_cli"),
            ("tests/test_ci_resolve_cmux_tui_client_commit.sh", "linux_guard_cli"),
        ):
            with self.subTest(path=path):
                self.assertEqual(route([path])[selected], "true")

    def test_executable_docs_and_unknown_inputs_never_take_docs_shortcut(self):
        for path in (
            "skills/cmux-cua/AGENTS.md", "docs/cli-contract.md",
            "skills/unknown/SKILL.md", "ghostty", ".gitmodules",
            "scripts/download-prebuilt-ghosttykit.sh", "scripts/ghosttykit-checksums.txt",
            ".github/workflows/ci.yml", "scripts/ci/detect_linux_guard_changes.py",
            "tests/test_ci_linux_guard_routing.py", "new-area/input",
            "scripts/build-ghostty-cli-helper.sh", "scripts/ghostty-zig-version.sh",
            "tests/test_ghostty_cli_helper_cache.sh", "tests/test_ghostty_cli_helper_cache_failures.py",
            "../README.md",
        ):
            with self.subTest(path=path):
                self.assertEqual(route(["CLAUDE.md", path]), dict.fromkeys(JOBS, "true"))

    def test_missing_empty_or_uncertain_diff_and_non_pr_events_run_all(self):
        for paths in (None, []):
            self.assertEqual(route(paths), dict.fromkeys(JOBS, "true"))
        for event in ("merge_group", "workflow_dispatch", "push", ""):
            self.assertEqual(route(["README.md"], event=event), dict.fromkeys(JOBS, "true"))
        self.assertEqual(route(["README.md"], macos=""), dict.fromkeys(JOBS, "true"))

    def test_gate_rejects_selected_guard_skip_failure_or_cancellation(self):
        for route_name, job in REUSABLE_GUARDS.items():
            for outcome in ("skipped", "failure", "cancelled"):
                with self.subTest(job=job, outcome=outcome):
                    result = run_guard_status(results={job: outcome})
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(f"{job}: {outcome} (route {route_name}=true)", result.stderr)

        for outcome in ("skipped", "failure", "cancelled"):
            with self.subTest(job="ghosttykit-release-check", outcome=outcome):
                result = run_linux_preflight(linux_preflight_needs(
                    results={"ghosttykit-release-check": outcome},
                ))
                self.assertNotEqual(result.returncode, 0)

    def test_gate_rejects_bad_or_missing_route_even_if_job_succeeded(self):
        valid_guard_inputs = dict.fromkeys(REUSABLE_GUARDS, "true")
        for route_name in REUSABLE_GUARDS:
            missing = dict(valid_guard_inputs)
            del missing[route_name]
            self.assertNotEqual(run_guard_status(inputs=missing).returncode, 0)
            for value in ("", "False", "invalid"):
                invalid = dict(valid_guard_inputs)
                invalid[route_name] = value
                self.assertNotEqual(run_guard_status(inputs=invalid).returncode, 0)

        needs = linux_preflight_needs()
        del needs["changes"]["outputs"]["ghosttykit_release"]
        self.assertNotEqual(run_linux_preflight(needs).returncode, 0)
        for value in ("", "False", "invalid"):
            needs["changes"]["outputs"]["ghosttykit_release"] = value
            self.assertNotEqual(run_linux_preflight(needs).returncode, 0)

if __name__ == "__main__":
    unittest.main()
