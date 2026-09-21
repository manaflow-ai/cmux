#!/usr/bin/env python3
"""Exercise the Linux route CLI and the real required-status gate."""

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from test_ci_change_areas import (
    linux_preflight_needs, run_guard_status, run_linux_preflight, workflow_job_step_script,
)


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "scripts/ci/detect_linux_guard_changes.py"
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


def route(paths, event="pull_request", macos="false"):
    with tempfile.TemporaryDirectory(prefix="cmux-linux-routes-") as temp:
        path = Path(temp) / "changed.txt"
        if paths is not None:
            path.write_text("\n".join(paths), encoding="utf-8")
        result = subprocess.run(
            [sys.executable, str(HELPER), "--event-name", event,
             "--macos", macos, "--files-from", str(path)],
            capture_output=True, text=True, check=True,
        )
    return dict(line.split("=", 1) for line in result.stdout.splitlines())


class LinuxGuardRoutingTests(unittest.TestCase):
    def test_candidate_router_cannot_disable_its_own_guards(self):
        script = workflow_job_step_script("changes", "Route Linux guard suites")
        for changed in ("scripts/ci/detect_linux_guard_changes.py", ".github/workflows/ci.yml"):
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
                self.assertEqual(dict(line.split("=", 1) for line in output.read_text().splitlines()),
                                 dict.fromkeys(JOBS, "true"))

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
