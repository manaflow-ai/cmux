# Keep CI change-area routing exercised when guard policy files change.
#!/usr/bin/env python3
"""Behavioral tests for the CI path filter."""

from __future__ import annotations

import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import textwrap
from pathlib import Path
from typing import Optional
from unittest.mock import patch

import yaml


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "scripts" / "ci" / "detect_ci_change_areas.py"
CI_WORKFLOW = ROOT / ".github" / "workflows" / "ci.yml"
GUARD_WORKFLOW = ROOT / ".github" / "workflows" / "ci-guards.yml"
WEB_WORKFLOW = ROOT / ".github" / "workflows" / "ci-web.yml"
MACOS_WORKFLOW = ROOT / ".github" / "workflows" / "ci-macos.yml"
WEB_VALIDATION_WORKFLOW = ROOT / ".github" / "workflows" / "web-validation.yml"
BROWSER_WORKFLOW = ROOT / ".github" / "workflows" / "cmux-browser.yml"
REMOTE_DAEMON_WORKFLOW = ROOT / ".github" / "workflows" / "remote-daemon.yml"
GUARD_JOBS = (
    "workflow-guard-tests",
    "workflow-guard-history",
    "workflow-guard-cli-scripts",
    "workflow-guard-source-lints",
)
GUARD_ROUTE_JOBS = {
    "linux_guard_tests": "workflow-guard-tests",
    "linux_guard_history": "workflow-guard-history",
    "linux_guard_cli": "workflow-guard-cli-scripts",
    "linux_guard_source": "workflow-guard-source-lints",
}
WEB_JOBS = (
    "web-subarea-scope",
    "web-typecheck",
    "web-production-build",
    "web-tests",
    "web-instant-navigation",
    "react-apps-check",
    "diff-sidecar-check",
    "web-db-migrations",
    "agent-session-web-resources",
)
MACOS_JOBS = (
    "macos-compile-admission",
    "app-host-unit-tests",
    "cli-product-tests",
    "swift-package-tests",
    "tests-build-and-lag",
    "release-admission",
    "release-build",
)
CI_STATUS_FALLBACK_WORKFLOW = ROOT / ".github" / "workflows" / "ci-status-fallback.yml"
PERF_ACTIVATION_WORKFLOW = ROOT / ".github" / "workflows" / "perf-activation.yml"

spec = importlib.util.spec_from_file_location("detect_ci_change_areas", HELPER)
assert spec and spec.loader
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)

WEB_SUBAREAS_HELPER = ROOT / "scripts" / "ci" / "web_subareas.py"
web_subareas_spec = importlib.util.spec_from_file_location("web_subareas", WEB_SUBAREAS_HELPER)
assert web_subareas_spec and web_subareas_spec.loader
web_subareas = importlib.util.module_from_spec(web_subareas_spec)
sys.modules[web_subareas_spec.name] = web_subareas
web_subareas_spec.loader.exec_module(web_subareas)

SELECT_PACKAGE_TESTS_HELPER = ROOT / "scripts" / "ci" / "select_package_tests.py"
select_package_tests_spec = importlib.util.spec_from_file_location(
    "select_package_tests", SELECT_PACKAGE_TESTS_HELPER
)
assert select_package_tests_spec and select_package_tests_spec.loader
select_package_tests = importlib.util.module_from_spec(select_package_tests_spec)
sys.modules[select_package_tests_spec.name] = select_package_tests
select_package_tests_spec.loader.exec_module(select_package_tests)

TEST_EXECUTION_VALIDATOR = ROOT / "scripts" / "ci" / "validate_test_execution_registry.py"
validator_spec = importlib.util.spec_from_file_location("validate_test_execution_registry", TEST_EXECUTION_VALIDATOR)
assert validator_spec and validator_spec.loader
test_execution_validator = importlib.util.module_from_spec(validator_spec)
sys.modules[validator_spec.name] = test_execution_validator
validator_spec.loader.exec_module(test_execution_validator)


def test_execution_registry_lane_discovery_ignores_yaml_comments() -> None:
    workflow = """
# scripts/ci/run_python_test_lane.py --lane full-line-comment
run: echo ok # scripts/ci/run_python_test_lane.py --lane inline-comment
run: scripts/ci/run_python_test_lane.py --lane live-lane # trailing comment
"""
    assert test_execution_validator.runner_lanes_from_workflow_text(workflow) == {"live-lane"}


def assert_areas(
    paths: list[str],
    *,
    macos: bool,
    web: bool,
    agent_session_web: bool = False,
) -> None:
    actual = module.classify_files(paths)
    assert actual.macos is macos, (paths, actual)
    assert actual.web is web, (paths, actual)
    assert actual.agent_session_web is agent_session_web, (paths, actual)
    # The Release build is a macOS job, so it can never run without that area.
    assert actual.macos or not actual.release_build, (paths, actual)


def test_test_only_changes_skip_the_release_build() -> None:
    for paths in (
        ["cmuxTests/WorkspaceRemoteConnectionTests.swift"],
        ["cmuxUITests/SidebarUITests.swift", "cmuxTests/GhosttyConfigTests.swift"],
        ["Packages/macOS/CmuxTerminal/Tests/CmuxTerminalTests/FakeTerminalEngine.swift", "docs/ci.md"],
    ):
        actual = module.classify_files(paths)
        assert actual.macos is True, (paths, actual)
        assert actual.release_build is False, (paths, actual)


def test_open_wrapper_changes_skip_the_release_build() -> None:
    paths = ["Resources/bin/open", "tests/test_open_wrapper.py"]
    actual = module.classify_files(paths)
    assert actual.macos is True, (paths, actual)
    assert actual.web is False, (paths, actual)
    assert actual.release_build is False, (paths, actual)


def test_resources_bin_release_neutral_inputs_are_text_scripts() -> None:
    # The Release lane validates compiled binaries' slices; a bundled text
    # script cannot fail it. A binary in this list would skip that check.
    scripts = sorted(p for p in module.RELEASE_BUILD_NEUTRAL_INPUTS if p.startswith("Resources/bin/"))
    assert scripts
    for path in scripts:
        data = (ROOT / path).read_bytes()
        assert b"\0" not in data, f"{path} is not a text script"
        actual = module.classify_files([path])
        assert actual.macos is True, (path, actual)
        assert actual.release_build is False, (path, actual)


def test_linux_guard_only_scripts_reach_no_other_runner() -> None:
    references = module.load_macos_job_test_references(ROOT)
    assert references is not None
    guard_jobs = yaml.safe_load(GUARD_WORKFLOW.read_text(encoding="utf-8"))["jobs"]
    for path in sorted(module.LINUX_GUARD_ONLY_SCRIPTS):
        assert (ROOT / path).is_file(), path
        # The stem, so a name built as stem + ".py" is found too.
        name = path.rsplit("/", 1)[-1].rsplit(".", 1)[0]
        referrers = subprocess.run(
            ["git", "grep", "-lF", name], cwd=ROOT, capture_output=True, text=True, check=True,
        ).stdout.split()
        for referrer in referrers:
            if referrer in {path, "scripts/ci/detect_ci_change_areas.py"} or referrer.endswith(".md"):
                continue
            if referrer == ".github/workflows/ci-guards.yml":
                for job_name, job in guard_jobs.items():
                    if name in yaml.safe_dump(job):
                        assert module.is_plainly_linux_runner(str(job.get("runs-on", ""))), (path, job_name)
                continue
            if referrer.startswith("tests/"):
                assert module.is_guard_only_test(referrer, references), (path, referrer)
                continue
            if referrer.endswith(".swift"):
                # Comments and failure messages may point at the lint, but a
                # Swift file that names it must not launch processes at all.
                source = (ROOT / referrer).read_text(encoding="utf-8")
                launches = r"\bProcess\s*[.(]|executableURL|launchPath|posix_spawn|\bNSTask\b|\bsystem\(|\bpopen\("
                assert not re.search(launches, source), (path, referrer)
                continue
            raise AssertionError(f"{referrer} names {path}; it may run on a Mac")
        actual = module.classify_files([path])
        assert not (actual.macos or actual.release_build or actual.web or actual.cli), (path, actual)


def test_anything_the_app_can_build_from_runs_the_release_build() -> None:
    for path in (
        "Sources/AppDelegate.swift",
        "cmux.xcodeproj/project.pbxproj",
        "Packages/macOS/CmuxTerminal/Sources/CmuxTerminal/TerminalEngine.swift",
        "Packages/macOS/CmuxTerminal/Package.swift",
        "Resources/Localizable.xcstrings",
        "scripts/thin-app-bundle.sh",
        "tests/test_thin_app_bundle.sh",
        "package.json",
        "some-new-top-level-dir/file.txt",
    ):
        paths = ["cmuxTests/GhosttyConfigTests.swift", path]
        actual = module.classify_files(paths)
        assert actual.macos is True, (paths, actual)
        assert actual.release_build is True, (paths, actual)


def test_cli_sources_use_dedicated_cli_workflow_without_app_host_compile() -> None:
    cli_workflow = (ROOT / ".github/workflows/cli-pipe-regressions.yml").read_text()
    assert "  workflow_call:" in cli_workflow
    assert "-scheme cmux-cli" in cli_workflow

    actual = module.classify_files(["CLI/cmux.swift", "CLI/FeedEventClassifier.swift"])
    assert actual.macos is False
    assert actual.web is False
    assert actual.agent_session_web is False
    assert actual.cli is True
    assert actual.release_build is False


def test_cli_workflow_inputs_route_the_required_cli_lane() -> None:
    for path in (
        "tests/test_cli_broken_pipe_writes.py",
        "tests/test_cli_socket_operation_deadline.py",
        "tests/test_cli_config_doctor.py",
        "tests/test_cli_glaeda_execution.py",
        "tests/fixtures/glaeda-external-request.json",
        "tests/fixtures/glaeda-external-result.json",
        "scripts/generate-cmux-config-schema.py",
        "web/data/cmux.schema.json",
        "cmux.xcodeproj/project.pbxproj",
        "Packages/macOS/CmuxFoundation/Sources/CmuxFoundation/Process/AgentPIDProcessIdentity.swift",
        ".github/workflows/cli-pipe-regressions.yml",
        # Steps of cli-pipe-regressions.yml other than the build.
        "scripts/select-ci-xcode.sh",
        "scripts/install-rust-ci.sh",
        "Native/DiffSidecar/rust-toolchain.toml",
        "scripts/download-prebuilt-ghosttykit.sh",
        "scripts/ghosttykit-checksums.txt",
        "ghostty",
        "vendor/bonsplit",
        ".github/actions/cache-restore/action.yml",
        "scripts/ci/r2-cache.sh",
        "scripts/ci/cache_restore_receipt.py",
        "scripts/ci/sanitize-xcode-source-packages-cache.py",
        # test_cli_config_doctor.py runs this helper.
        "skills/cmux-settings/scripts/cmux-settings",
    ):
        assert module.classify_files([path]).cli is True, path


def test_every_declared_cli_lane_input_exists() -> None:
    for path in module.CLI_LANE_EXACT_INPUTS:
        assert (ROOT / path).exists(), path
    for prefix in module.CLI_LANE_INPUT_PREFIXES:
        assert (ROOT / prefix).is_dir(), prefix


def test_cli_lane_routes_the_cmux_cli_target_closure() -> None:
    inputs = module.load_cli_target_inputs()
    assert inputs is not None
    # Products the cmux-cli target links, so a change to them can break its
    # build even though the app-host suite would also catch it.
    assert "Packages/macOS/CmuxCore" in inputs.package_directories
    assert "Packages/macOS/CmuxFoundation" in inputs.package_directories
    assert "Packages/Shared/CMUXMobileCore" in inputs.package_directories
    # Packages no cmux-cli product reaches.
    assert "Packages/macOS/CmuxTerminal" not in inputs.package_directories
    assert not any(
        directory.startswith("Packages/iOS/") for directory in inputs.package_directories
    )

    assert module.classify_files(["Packages/macOS/CmuxCore/Sources/CmuxCore/Cmux.swift"]).cli is True
    # Shared app sources the cmux-cli target compiles.
    assert module.classify_files(["Sources/AutomationRule.swift"]).cli is True
    # A package's test sources cannot reach the cmux-cli binary.
    assert module.classify_files([
        "Packages/macOS/CmuxCore/Tests/CmuxCoreTests/CmuxCoreTests.swift"
    ]).cli is False


def test_cli_lane_routes_stdlib_shadowing_ci_helpers() -> None:
    # The lane runs `python3 scripts/ci/cache_restore_receipt.py`, which puts
    # scripts/ci first on sys.path.
    assert module.classify_files(["scripts/ci/json.py"]).cli is True
    assert module.classify_files(["scripts/ci/subprocess.py"]).cli is True
    assert module.classify_files(["scripts/ci/queue_janitor.py"]).cli is False


XCODE_PROJECT = "cmux.xcodeproj/project.pbxproj"
CLI_SOURCE_REFERENCE = "B9000001A1B2C3D4E5F60719 /* cmux.swift */"


def with_build_setting(project: str, configuration: str) -> str:
    """Add a build setting to one XCBuildConfiguration of the real project."""
    anchor = f"\t\t{configuration} /* Debug */ = {{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {{\n"
    assert project.count(anchor) == 1, configuration
    return project.replace(anchor, anchor + "\t\t\t\tCMUX_ROUTING_PROBE = 1;\n")


def cli_neutral_project_edits(project: str) -> dict[str, str]:
    """Real-shaped pbxproj edits the cmux-cli build cannot observe."""
    test_reference = "path = AboutLicensesResourceTests.swift;"
    assert project.count(test_reference) == 1
    return {
        # Renaming a cmuxTests source, as a test-adding PR's pbxproj edit does.
        "test file": project.replace(test_reference, "path = AboutLicensesResourceTests2.swift;"),
        # The app target's own Debug configuration.
        "app setting": with_build_setting(project, "A5001082"),
    }


def cli_relevant_project_edits(project: str) -> dict[str, str]:
    """pbxproj edits that change what the cmux-cli target compiles or how."""
    cli_reference = f"{CLI_SOURCE_REFERENCE} = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = cmux.swift;"
    child = f"\t\t\t\t{CLI_SOURCE_REFERENCE},\n"
    main_group = "\t\tA5001040 = {\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n"
    assert project.count(cli_reference) == 1
    assert project.count(child) == 1
    assert project.count(main_group) == 1
    return {
        "cli source path": project.replace(cli_reference, cli_reference.replace("path = cmux.swift;", "path = cmux2.swift;")),
        # Moving the file changes its location even though no object it
        # references changed.
        "cli source moved": project.replace(child, "").replace(main_group, main_group + child),
        "cli setting": with_build_setting(project, "B9000008A1B2C3D4E5F60719"),
        "project setting": with_build_setting(project, "A5001080"),
    }


def test_pbxproj_edits_outside_the_cmux_cli_build_skip_the_cli_lane() -> None:
    # Of the 86 main commits that routed the CLI lane between 2026-09-20 and
    # 2026-09-23, 24 did so only through a project.pbxproj edit that left the
    # cmux-cli target alone (app and test file wiring) or an app test scheme.
    project = (ROOT / XCODE_PROJECT).read_text(encoding="utf-8")
    for label, head in cli_neutral_project_edits(project).items():
        assert head != project, label
        assert module.cli_xcode_project_change_is_neutral(project, head), label
    for label, head in cli_relevant_project_edits(project).items():
        assert head != project, label
        assert not module.cli_xcode_project_change_is_neutral(project, head), label
    # Unreadable input keeps the lane.
    assert not module.cli_xcode_project_change_is_neutral(project, project[:-200])
    assert not module.cli_xcode_project_change_is_neutral(
        project, project.replace('name = "cmux-cli";', 'name = "cmux-cli-renamed";')
    )


def test_only_the_schemes_the_cli_route_builds_select_it() -> None:
    schemes = "cmux.xcodeproj/xcshareddata/xcschemes"
    assert module.classify_files([f"{schemes}/cmux-cli.xcscheme"]).cli is True
    for scheme in ("cmux-unit", "cmux-ci", "cmux"):
        assert module.classify_files([f"{schemes}/{scheme}.xcscheme"]).cli is False, scheme
    assert module.classify_files(
        ["cmux.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"]
    ).cli is True


def test_package_changes_route_the_package_test_lane() -> None:
    # PRs #13786 and #13790 move ~150 assertions into package test targets.
    # Under the compile-only pull-request suite the only macOS signal is
    # compile admission, which builds package library targets and never their
    # test targets, so those assertions would land with zero CI execution.
    for path in (
        "Packages/macOS/CmuxSettingsUI/Tests/CmuxSettingsUITests/SettingsSearchIndexTests.swift",
        "Packages/macOS/CmuxSettingsUI/Sources/CmuxSettingsUI/Bindings/SettingReadDriver.swift",
        "Packages/macOS/CmuxSettings/Package.swift",
        # A dependency of packages the job runs, reached through Package.swift
        # path dependencies rather than by name.
        "Packages/Shared/CMUXMobileCore/Sources/CMUXMobileCore/Whatever.swift",
        # CmuxCommandPalette's declared extra input.
        "Native/CommandPaletteNucleoFFI/src/lib.rs",
    ):
        assert module.classify_files([path]).swift_packages is True, path


def test_routed_lane_names_the_packages_the_job_would_run() -> None:
    # The area is the job's own selection, so routing and the job's package
    # list cannot disagree about what a change affects.
    assert module.swift_package_test_selection(
        ["Packages/macOS/CmuxSettingsUI/Tests/CmuxSettingsUITests/SettingsSearchIndexTests.swift"]
    ) == ("CmuxSettingsUI",)
    # A dependency pulls in its dependents, and nothing else.
    settings = module.swift_package_test_selection(["Packages/macOS/CmuxSettings/Package.swift"])
    assert "CmuxSettings" in settings and "CmuxSettingsUI" in settings
    # CmuxBrowser depends on CmuxSettings, so it is a dependent; CmuxGit is not.
    assert "CmuxBrowser" in settings
    assert "CmuxGit" not in settings
    assert module.swift_package_test_selection(["Sources/AppDelegate.swift"]) == ()


def test_non_package_changes_leave_the_package_test_lane_unrouted() -> None:
    # The lane costs a macOS runner, so it stays narrow. Everything here is
    # either covered by another lane or cannot reach a package test target.
    for path in (
        "Sources/AppDelegate.swift",
        "cmuxTests/GhosttyConfigTests.swift",
        "cmuxUITests/SidebarUITests.swift",
        "cmux.xcodeproj/project.pbxproj",
        "CLI/cmux.swift",
        "web/app/page.tsx",
        "webviews/src/agent-session/index.tsx",
        "docs/ci.md",
        "README.md",
        "package.json",
        "Resources/Localizable.xcstrings",
        # A package the job does not run. Routing it would start the lane only
        # for it to select nothing and test nothing.
        "Packages/iOS/CmuxMobileShellUI/Tests/CmuxMobileShellUITests/Foo.swift",
    ):
        assert module.classify_files([path]).swift_packages is False, path


def test_lane_wide_inputs_do_not_turn_the_lane_into_a_full_sweep() -> None:
    # select_package_tests.py fails open for these: each one selects all 33
    # packages, which on a pull request is the 30-minute sweep under another
    # name. Over the last 200 merged pull requests, routing them would have
    # queued 34 full runs. They keep their coverage from the push to main.
    for path in (
        ".github/workflows/ci-macos.yml",
        ".github/workflows/ci.yml",
        "scripts/ci/select_package_tests.py",
        "scripts/ci/run-swift-testing-suites.sh",
        "scripts/download-prebuilt-ghosttykit.sh",
        ".xcode-version",
        "ghostty",
        # An unowned scripts/ci helper forces every other area open; the
        # package lane is the one area where fail-open means a full sweep.
        "scripts/ci/queue_janitor.py",
    ):
        assert path in set(select_package_tests.GLOBAL_INPUTS) or path.startswith("scripts/ci/"), path
        assert module.classify_files([path]).swift_packages is False, path


def test_package_lane_reads_the_job_package_list_from_the_workflow() -> None:
    packages = module.swift_package_test_packages()
    assert packages is not None
    # The same list the job's "Select package tests" step declares.
    workflow = MACOS_WORKFLOW.read_text(encoding="utf-8")
    body = workflow.split("PACKAGES=(", 1)[1].split("\n          )", 1)[0]
    assert set(packages) == set(body.split()), set(packages) ^ set(body.split())
    assert "CmuxSettingsUI" in packages
    for name in packages:
        assert (ROOT / "Packages").glob(f"*/{name}/Package.swift"), name


def test_package_lane_does_not_widen_any_other_area() -> None:
    # Routing the package lane must not drag the 30-minute suite along: a
    # package test source still skips the Release build, and nothing here
    # turns on web or CLI work.
    actual = module.classify_files([
        "Packages/macOS/CmuxSettingsUI/Tests/CmuxSettingsUITests/SettingsSearchIndexTests.swift"
    ])
    assert actual.swift_packages is True
    assert actual.release_build is False
    assert actual.web is False
    assert actual.agent_session_web is False
    assert actual.cli is False


def test_app_and_web_only_changes_skip_the_cli_lane() -> None:
    for path in (
        "Sources/AppDelegate.swift",
        "Packages/macOS/CmuxTerminal/Sources/CmuxTerminal/TerminalEngine.swift",
        "webviews/src/agent-session/index.tsx",
        "Resources/Localizable.xcstrings",
        "docs/ci.md",
    ):
        assert module.classify_files([path]).cli is False, path


def test_ci_script_only_change_skips_the_cli_lane_but_keeps_linux_guards() -> None:
    # PR #13721 (ci/queue-janitor) and its neighbours queued the macOS CLI lane
    # behind the Blacksmith pool for CI work the lane never runs.
    changed = [
        ".github/workflows/ci-guards.yml",
        ".github/workflows/ci-queue-janitor.yml",
        "scripts/ci/queue_janitor.py",
        "scripts/ci/workflow_guard_groups.py",
        "tests/test-execution.toml",
        "tests/test_ci_queue_janitor.py",
    ]
    assert module.classify_files(changed).cli is False

    with tempfile.TemporaryDirectory() as temp_dir:
        files_path = Path(temp_dir) / "files.txt"
        files_path.write_text("\n".join(changed) + "\n", encoding="utf-8")
        result = subprocess.run(
            [
                sys.executable,
                str(ROOT / "scripts/ci/detect_linux_guard_changes.py"),
                "--event-name",
                "pull_request",
                "--macos",
                "false",
                "--files-from",
                str(files_path),
            ],
            capture_output=True,
            text=True,
            check=True,
        )
    guards = dict(
        line.split("=", 1) for line in result.stdout.splitlines() if "=" in line
    )
    assert guards["linux_guard_tests"] == "true", result.stdout


HANG_WORKFLOW = ROOT / ".github" / "workflows" / "terminal-hang-diagnostics.yml"


def hang_diagnostics_paths() -> list[str]:
    workflow = yaml.safe_load(HANG_WORKFLOW.read_text(encoding="utf-8"))
    return list(workflow[True]["pull_request"]["paths"])


def runs_hang_diagnostics(path: str) -> bool:
    for pattern in hang_diagnostics_paths():
        expression = "".join(
            ".*" if part == "**" else ("[^/]*" if part == "*" else re.escape(part))
            for part in re.split(r"(\*\*|\*)", pattern)
        )
        if re.fullmatch(expression, path):
            return True
    return False


def test_terminal_sources_the_hang_jobs_build_run_the_diagnostics() -> None:
    for path in (
        "Sources/TerminalPortalReconciliationScheduler.swift",
        "cmuxTests/TerminalPortalReconciliationReentrancyTests.swift",
        "tests/run_terminal_portal_reconciliation_tests.sh",
        "Packages/Shared/CMUXMobileCore/Sources/CMUXMobileCore/TerminalWorkInterval.swift",
        "Packages/Shared/CmuxSentryTelemetry/Sources/CmuxSentryTelemetry/TerminalWorkSentryContext.swift",
        "cmux.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
        "scripts/select-ci-xcode.sh",
        "scripts/terminal-hang-release-gate.py",
        "tests/test_terminal_hang_release_gate.py",
        ".github/workflows/terminal-hang-diagnostics.yml",
    ):
        assert runs_hang_diagnostics(path), path


def test_unrelated_app_changes_skip_the_two_macos_hang_diagnostics_jobs() -> None:
    for path in (
        "Sources/Workspace.swift",
        "Sources/AppDelegate.swift",
        "Sources/GhosttyTerminalView.swift",
        "Packages/macOS/CmuxTerminal/Sources/CmuxTerminal/TerminalEngine.swift",
        "Packages/iOS/CmuxMobileTerminal/Sources/CmuxMobileTerminal/Terminal.swift",
        "web/app/page.tsx",
    ):
        assert not runs_hang_diagnostics(path), path


def test_hang_diagnostics_paths_cover_every_file_its_jobs_read() -> None:
    workflow = HANG_WORKFLOW.read_text(encoding="utf-8")
    jobs = workflow.partition("\njobs:\n")[2]
    # Keeps the filter honest as the jobs change: every repository file the job
    # steps name must be routed, and every routed pattern must match something.
    references = {
        reference.lstrip("./")
        for reference in re.findall(r"[\w./+-]+\.(?:swift|sh|py|json|resolved|toml)", jobs)
    }
    references |= {
        f"{package}/Package.swift" for package in re.findall(r"--package-path (\S+)", jobs)
    }
    assert "tests/run_terminal_portal_reconciliation_tests.sh" in references
    for reference in sorted(references):
        if not (ROOT / reference).exists():
            continue
        assert runs_hang_diagnostics(reference), reference
    for pattern in hang_diagnostics_paths():
        assert list(ROOT.glob(pattern)), pattern
    assert "workflow_dispatch:" in workflow


def test_release_build_follows_the_other_areas_when_macos_is_skipped_or_forced() -> None:
    assert module.classify_files(["docs/ci.md"]).release_build is False
    assert module.classify_files([".github/workflows/ci.yml"]).release_build is True
    assert module.classify_files([".github/workflows/ci-guards.yml"]).release_build is False
    assert module.ChangeAreas.all().cli is True
    assert module.ChangeAreas.all().release_build is True


def test_release_build_waits_for_linux_preflight_admission() -> None:
    admission = workflow_job_block("release-admission", MACOS_WORKFLOW)
    release = workflow_job_block("release-build", MACOS_WORKFLOW)
    status = workflow_job_block("macos-status", MACOS_WORKFLOW)

    assert "runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || vars.LINUX_RUNNER || 'blacksmith-4vcpu-ubuntu-2404' }}" in admission
    assert 'TARGET_JOB: "linux-preflight"' in admission
    assert "actions/runs/{run_id}/jobs?filter=latest&per_page=100" in admission
    assert "- release-admission" in release
    assert "needs.release-admission.result == 'success'" in release
    assert "- release-admission" in status


def test_native_diff_sidecar_inputs_route_the_web_workflow_explicitly() -> None:
    for path in (
        "Sources/Panels/DiffSidecarBridge.swift",
        "Native/DiffSidecar/src/server.rs",
        "scripts/build-diff-sidecar.sh",
    ):
        actual = module.classify_files([path])
        assert actual.macos is True, (path, actual)
        assert actual.web is True, (path, actual)


def test_test_only_pull_request_routes_macos_without_the_release_build() -> None:
    result, outputs = run_detect_step_for_paths(["cmuxTests/GhosttyConfigTests.swift"])

    assert result.returncode == 0, result.stderr
    assert outputs == ["macos=true", "web=false", "agent_session_web=false", "cli=false", "swift_packages=false", "release_build=false"]


def test_docs_only_skips_expensive_areas() -> None:
    assert_areas(["docs/ci.md", "README.md"], macos=False, web=False)


def test_agent_instructions_and_skill_docs_skip_expensive_areas() -> None:
    assert_areas(
        [
            "CLAUDE.md",
            "AGENTS.md",
            "Packages/iOS/AGENTS.md",
            "skills/cmux-testing/references/local-vs-ci-validation.md",
            "skills/cmux/SKILL.md",
        ],
        macos=False,
        web=False,
    )


def test_operational_ci_helpers_skip_product_areas() -> None:
    # Janitors, census/reporting and registry validation run only in Linux
    # workflows and are never read by the Xcode product.
    for path in (
        "scripts/ci/cleanup-stale-runs.py",
        "scripts/ci/queue_janitor.py",
        "scripts/ci/triage-radar.py",
        "scripts/ci/notify-indexnow.py",
        "scripts/ci/r2_cache_census.py",
        "scripts/ci/r2_cache_prune.py",
        "scripts/ci/verify-r2-canary.py",
        "scripts/ci/build_graph_health.py",
        "scripts/ci/validate_test_execution_registry.py",
        "scripts/ci/app_host_failure_census.py",
        "scripts/ci/swift_incremental_diagnostics.py",
        "scripts/ci/cmux_workload_profile.py",
        "scripts/ci/r2-canary-cloudflare.py",
    ):
        assert_areas([path], macos=False, web=False)


def test_web_subarea_router_keeps_web_without_macos() -> None:
    # Editing the ci-web.yml subarea router must still run web validation --
    # the helper lists itself in ALL_SUBAREA_INPUTS -- but never a Mac.
    actual = module.classify_files(["scripts/ci/web_subareas.py"])
    assert actual.web is True, actual
    assert actual.macos is False, actual
    assert actual.release_build is False, actual


def test_routing_policy_and_build_helpers_still_run_macos() -> None:
    # The boundary the carveout must not cross: the router itself decides
    # macOS selection, and the shard helper is a real macOS build input.
    for path in (
        # Routing policy: these decide macOS selection, so they must not
        # certify themselves.
        "scripts/ci/detect_ci_change_areas.py",
        "scripts/ci/detect_linux_guard_changes.py",
        "scripts/ci/workflow_guard_groups.py",
        # Reached from a macOS job: directly, through run-app-host-xcodebuild.sh,
        # through the cache-restore composite action, and through
        # run_python_test_lane.py respectively.
        "scripts/ci/cmux_unit_test_shard.py",
        "scripts/ci/xcodebuild_noninteractive.py",
        "scripts/ci/cache_restore_receipt.py",
        "scripts/ci/test_execution_registry.py",
    ):
        assert_areas([path], macos=True, web=True, agent_session_web=True)


def test_contributor_prose_skips_expensive_areas() -> None:
    assert_areas(
        ["STYLE.md", "CONTRIBUTING.md", ".github/pull_request_template.md"],
        macos=False,
        web=False,
    )
    # The Release build is the expensive half of the waste: a writing-guidance
    # edit used to select a universal app build.
    assert module.classify_files(["STYLE.md"]).release_build is False


def test_bundled_root_markdown_still_runs_macos() -> None:
    # THIRD_PARTY_LICENSES.md is root Markdown like the files above, but it
    # ships in Resources/ and AboutLicenseContent.swift reads it, so it is a
    # real product input. This is the boundary the prose carveout must not cross.
    assert_areas(["THIRD_PARTY_LICENSES.md"], macos=True, web=False)


def test_bundled_and_executable_skill_files_run_macos() -> None:
    # The app bundles skills/cmux-cua as a folder resource.
    assert_areas(["skills/cmux-cua/SKILL.md"], macos=True, web=False)
    assert_areas(["skills/cmux-settings/scripts/cmux-settings"], macos=True, web=False)
    assert_areas(["skills/cmux-browser/agents/openai.yaml"], macos=True, web=False)


def test_cli_contract_doc_runs_macos_contract_tests() -> None:
    assert_areas(["docs/cli-contract.md"], macos=True, web=False)


def test_changelog_runs_web_validation() -> None:
    assert_areas(["CHANGELOG.md"], macos=True, web=True)


def test_web_only_runs_web_without_macos() -> None:
    assert_areas(["web/app/page.tsx", "webviews/src/diff/App.tsx"], macos=False, web=True)
    assert_areas(
        [
            "workers/presence/src/index.ts",
            "config/iroh/managed-relay-catalog.json",
            "vercel.json",
            ".vercelignore",
        ],
        macos=False,
        web=True,
    )


def test_macos_config_stays_macos_relevant() -> None:
    assert_areas(["config/IrohRelayPolicyProduction.xcconfig"], macos=True, web=True)


def test_standalone_browser_and_remote_daemon_skip_app_host_macos() -> None:
    browser_area = module.classify_files(["cmux-browser/src/main.ts"])
    assert browser_area.macos is False
    assert browser_area.release_build is False

    daemon_area = module.classify_files(["daemon/remote/cmd/cmuxd-remote/cli.go"])
    assert daemon_area.macos is False
    assert daemon_area.release_build is False


def test_required_ci_owns_standalone_browser_and_remote_daemon_pr_validation() -> None:
    changes = workflow_job_block("changes")
    assert "browser: ${{ steps.standalone.outputs.browser }}" in changes
    assert "remote_daemon: ${{ steps.standalone.outputs.remote_daemon }}" in changes
    route = workflow_job_step_script("changes", "Route standalone project workflows")
    assert "cmux-browser/*|.github/workflows/cmux-browser.yml" in route
    assert "daemon/remote/*|scripts/*remote_daemon*" in route

    browser_job = workflow_job_block("browser")
    assert "uses: ./.github/workflows/cmux-browser.yml" in browser_job
    daemon_job = workflow_job_block("remote-daemon")
    assert "uses: ./.github/workflows/remote-daemon.yml" in daemon_job

    browser_text = BROWSER_WORKFLOW.read_text(encoding="utf-8")
    assert "  workflow_call:" in browser_text
    assert "  pull_request:" not in browser_text
    assert "group: cmux-browser-${{ github.ref }}" in browser_text
    remote_text = REMOTE_DAEMON_WORKFLOW.read_text(encoding="utf-8")
    assert "  workflow_call:" in remote_text
    assert "  pull_request:" not in remote_text
    assert "      - name: Reject stale pull request rerun" in remote_text


def test_standalone_routes_preserve_missing_empty_and_owned_diffs() -> None:
    script = workflow_job_step_script("changes", "Route standalone project workflows")
    script = script.replace("/tmp/cmux-ci-changed-files.txt", '"$CHANGED_FILES"')
    cases = (
        (None, "true", "true", "true"),
        ("", "false", "false", "false"),
        ("README.md\n", "false", "false", "false"),
        (".github/workflows/ci.yml\n", "true", "true", "true"),
        ("cmux-browser/src/main.ts\n", "true", "false", "false"),
        ("daemon/remote/main.go\n", "false", "true", "false"),
    )
    for contents, browser, daemon, wrapper in cases:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            changed = root / "changed.txt"
            if contents is not None:
                changed.write_text(contents)
            output = root / "output.txt"
            subprocess.run(["bash", "-c", isolate_ci_tmp(script, root)], check=True, capture_output=True,
                           env={**os.environ, "CHANGED_FILES": str(changed), "GITHUB_OUTPUT": str(output)})
            assert output.read_text().splitlines() == [f"claude_wrapper={wrapper}", f"browser={browser}", f"remote_daemon={daemon}", f"remote_daemon_native={daemon}"]


def test_publishing_changes_keep_daemon_linux_checks_without_native_rerun() -> None:
    script = workflow_job_step_script("changes", "Route standalone project workflows")
    script = script.replace("/tmp/cmux-ci-changed-files.txt", '\"$CHANGED_FILES\"')
    cases = (
        (".github/workflows/nightly.yml\nscripts/sparkle_generate_appcast.sh\n", "false"),
        (".github/workflows/release.yml\n", "false"),
        (".github/workflows/nightly.yml\ndaemon/remote/main.go\n", "true"),
        ("daemon/remote/go.mod\n", "true"),
        ("scripts/build_remote_daemon.sh\n", "true"),
        ("tests/test_remote_daemon_release_assets.py\n", "true"),
        (".github/workflows/remote-daemon.yml\n", "true"),
        (".github/workflows/ci.yml\n", "true"),
        (None, "true"),
    )
    for contents, native in cases:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            changed, output = root / "changed", root / "output"
            if contents is not None:
                changed.write_text(contents)
            subprocess.run(["bash", "-c", isolate_ci_tmp(script, root)], check=True, capture_output=True,
                           env={**os.environ, "CHANGED_FILES": str(changed), "GITHUB_OUTPUT": str(output)})
            values = dict(line.split("=", 1) for line in output.read_text().splitlines())
            assert values["remote_daemon"] == "true", (contents, values)
            assert values.get("remote_daemon_native") == native, (contents, values)


def test_diff_failure_does_not_look_like_a_known_empty_standalone_diff() -> None:
    detector = detect_step_script().replace("/tmp/cmux-ci-changed-files.txt", '"$CHANGED_FILES"')
    route = workflow_job_step_script("changes", "Route standalone project workflows")
    route = route.replace("/tmp/cmux-ci-changed-files.txt", '"$CHANGED_FILES"')
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        git = root / "git"
        git.write_text("#!/bin/sh\nexit 1\n")
        git.chmod(0o755)
        changed = root / "changed.txt"
        output = root / "output.txt"
        env = {**os.environ, "PATH": str(root) + os.pathsep + os.environ["PATH"],
               "EVENT_NAME": "pull_request", "BASE_SHA": "missing", "MERGE_SHA": "missing",
               "CHANGED_FILES": str(changed), "GITHUB_OUTPUT": str(output)}
        subprocess.run(["bash", "-c", isolate_ci_tmp(detector, root)], env=env, capture_output=True, check=True)
        assert not changed.exists(), "failed git diff must not leave its truncated output behind"
        subprocess.run(["bash", "-c", isolate_ci_tmp(route, root)], env=env, capture_output=True, check=True)
        assert output.read_text().splitlines()[-3:] == ["browser=true", "remote_daemon=true", "remote_daemon_native=true"]


def test_remote_daemon_rejects_stale_heads_before_allocating_macos() -> None:
    jobs = yaml.safe_load(REMOTE_DAEMON_WORKFLOW.read_text())["jobs"]
    admission = jobs["remote-daemon-admission"]
    assert "LINUX_RUNNER" in admission["runs-on"]
    assert jobs["remote-daemon-macos-tests"]["needs"] == "remote-daemon-admission"
    script = admission["steps"][0]["run"]
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        gh = root / "gh"
        gh.write_text('#!/bin/sh\n[ "$CURRENT_HEAD" != unavailable ] || exit 1\nprintf "%s\\n" "$CURRENT_HEAD"\n')
        gh.chmod(0o755)
        for current, expected in (("head", 0), ("newer-head", 1), ("unavailable", 0)):
            env = {**os.environ, "PATH": str(root) + os.pathsep + os.environ["PATH"],
                   "GITHUB_REPOSITORY": "example/repo", "PR_NUMBER": "1",
                   "RUN_HEAD_SHA": "head", "CURRENT_HEAD": current}
            result = subprocess.run(["bash", "-c", script], env=env, capture_output=True)
            assert result.returncode == expected, (current, result.stderr)


def test_cmux_tui_only_skips_macos() -> None:
    # cmux-tui is a standalone Rust project with its own `cmux-tui` workflow; its
    # changes must not require the macOS app-host tests.
    assert_areas(
        ["cmux-tui/crates/cmux-tui-core/src/browser.rs", "cmux-tui/README.md", "cmux-tui/docs/protocol.md"],
        macos=False,
        web=False,
    )


def test_website_only_does_not_run_agent_session_resource_check() -> None:
    assert_areas(["web/app/page.tsx"], macos=False, web=True, agent_session_web=False)
    assert_areas(["scripts/ci/web_validation.py"], macos=False, web=True, agent_session_web=False)


def test_review_rules_skip_app_builds_but_preserve_unknown_and_mixed_inputs() -> None:
    paths = [".coderabbit.yaml", ".greptile/rules.md",
             ".github/review-bot-rules/user-facing-errors.md"]
    for changed in [[path] for path in paths] + [paths]:
        assert module.classify_files(changed) == module.ChangeAreas(
            macos=False,
            web=False,
            agent_session_web=False,
            cli=False,
            swift_packages=False,
            release_build=False,
        )
    for unknown in (".greptile/new-policy.json", ".github/review-bot-rules/new-rule.md",
                    ".coderabbit.yml", ".github/swift-warning-budget.tsv"):
        actual = module.classify_files(paths + [unknown])
        assert actual.macos and actual.release_build, (unknown, actual)
    actual = module.classify_files(paths + ["Sources/App.swift"])
    assert actual.macos and actual.release_build, actual
    actual = module.classify_files(paths + ["web/app/page.tsx"])
    assert not actual.macos and actual.web, actual


def test_review_rules_workflow_skips_native_but_still_requires_linux_guards() -> None:
    _, outputs = run_detect_step_for_paths([
        ".coderabbit.yaml", ".greptile/rules.md",
        ".github/review-bot-rules/user-facing-errors.md",
    ])
    assert outputs == [
        "macos=false",
        "web=false",
        "agent_session_web=false",
        "cli=false",
        "swift_packages=false",
        "release_build=false",
    ]
    result = run_linux_preflight(linux_preflight_needs(
        outputs=dict(line.split("=", 1) for line in outputs), results={"guards": "failure"},
    ))
    assert result.returncode != 0, result.stdout


def test_agent_session_webview_sources_run_bundled_asset_check() -> None:
    assert_areas(
        ["webviews/src/agent-session/shared/message.test.ts"],
        macos=True,
        web=True,
        agent_session_web=True,
    )


def test_markdown_viewer_resources_run_webviews_asset_guard() -> None:
    assert_areas(
        ["Resources/markdown-viewer/webviews-app/index.js", "Resources/markdown-viewer/marked.min.js"],
        macos=True,
        web=True,
        agent_session_web=True,
    )


def test_markdown_viewer_webview_app_does_not_run_agent_session_resource_check() -> None:
    assert_areas(
        ["Resources/markdown-viewer/webviews-app/index.js"],
        macos=True,
        web=True,
        agent_session_web=False,
    )


def test_root_agent_web_dependencies_run_web_and_macos() -> None:
    assert_areas(
        ["package.json", "bun.lock"],
        macos=True,
        web=True,
        agent_session_web=True,
    )


def test_agent_session_resources_run_web_and_macos() -> None:
    assert_areas(
        ["Resources/agent-session-react/index.js"],
        macos=True,
        web=True,
        agent_session_web=True,
    )
    assert_areas(
        ["Resources/agent-session-solid/index.js"],
        macos=True,
        web=True,
        agent_session_web=True,
    )
    assert_areas(["Resources/agent-session-backup/index.js"], macos=True, web=False)


def test_ios_only_skips_main_macos_ci() -> None:
    assert_areas(["ios/cmux/ContentView.swift"], macos=False, web=False)


def test_ios_packages_keep_macos_dependency_coverage() -> None:
    assert_areas(
        ["Packages/iOS/CmuxMobileRPC/Sources/CmuxMobileRPC/MobileTerminalLaneConnection.swift"],
        macos=True,
        web=False,
    )


def test_pbx_list_ids_accepts_bare_and_commented_references() -> None:
    body = textwrap.dedent(
        """\
        packageProductDependencies = (
            COMMENTED /* Root */,
            BARE,
        );
        """
    )

    assert module._pbx_list_ids(body, "packageProductDependencies") == [
        "COMMENTED",
        "BARE",
    ]


def test_pbx_list_ids_rejects_present_malformed_optional_lists() -> None:
    assert module._pbx_list_ids("name = cmux;", "dependencies") == []
    assert module._pbx_list_ids("dependencies = (\n);", "dependencies") == []

    for body in ("dependencies = (\nTARGET,\n", "dependencies = TARGET;"):
        try:
            module._pbx_list_ids(body, "dependencies")
        except ValueError as error:
            assert "unreadable pbx list dependencies" in str(error)
        else:
            raise AssertionError("present malformed optional PBX list must fail open")


def test_macos_ios_package_closure_matches_current_desktop_graph() -> None:
    assert module.macos_ios_package_closure(ROOT) == frozenset(
        {
            "Packages/iOS/CmuxMobileDiagnostics",
            "Packages/iOS/CmuxMobilePairedMac",
            "Packages/iOS/CmuxMobileRPC",
            "Packages/iOS/CmuxMobileShellModel",
            "Packages/iOS/CmuxMobileSupport",
            "Packages/iOS/CmuxMobileTransport",
        }
    )


def test_ios_package_routing_follows_desktop_dependency_closure() -> None:
    mac_relevant = (
        "CmuxMobileDiagnostics",
        "CmuxMobilePairedMac",
        "CmuxMobileRPC",
        "CmuxMobileShellModel",
        "CmuxMobileSupport",
        "CmuxMobileTransport",
    )
    for package in mac_relevant:
        path = f"Packages/iOS/{package}/Sources/{package}/Probe.swift"
        actual = module.classify_files([path])
        assert actual.macos is True, (path, actual)
        assert actual.release_build is True, (path, actual)

    for package in ("CmuxMobileAnalytics", "CmuxMobileShellUI"):
        path = f"Packages/iOS/{package}/Sources/{package}/Probe.swift"
        actual = module.classify_files([path])
        assert actual.macos is False, (path, actual)
        assert actual.release_build is False, (path, actual)


def test_ios_package_routing_preserves_nested_package_roots() -> None:
    original = module.load_macos_ios_package_closure
    module.load_macos_ios_package_closure = lambda: frozenset(
        {"Packages/iOS/Group/Leaf"}
    )
    try:
        covered = module.classify_files(
            ["Packages/iOS/Group/Leaf/Sources/Leaf/Probe.swift"]
        )
        sibling = module.classify_files(
            ["Packages/iOS/Group/Other/Sources/Other/Probe.swift"]
        )
    finally:
        module.load_macos_ios_package_closure = original

    assert covered.macos is True, covered
    assert covered.release_build is True, covered
    assert sibling.macos is False, sibling
    assert sibling.release_build is False, sibling


def test_recent_ios_pr_shapes_skip_unobservable_macos_compile() -> None:
    # PR #13441: iOS-only ShellUI sources plus an unrelated reusable guard workflow.
    pr_13441 = [
        ".github/workflows/ci-guards.yml",
        "Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/TaskComposer/TaskComposerAttachmentPickerModifier.swift",
        "Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/TaskComposer/TaskComposerAttachmentStager.swift",
        "Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/TaskComposer/TaskComposerSheet+Attachments.swift",
        "Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/TerminalComposerView.swift",
    ]
    actual = module.classify_files(pr_13441)
    assert actual.macos is False, actual
    assert actual.release_build is False, actual

    # PR #13459: iOS-only analytics plus web and docs work. Web still routes.
    pr_13459 = [
        "Packages/iOS/CmuxMobileAnalytics/Sources/CmuxMobileAnalytics/MobileNetworkOutcomeReporter.swift",
        "Packages/iOS/CmuxMobileAnalytics/Tests/CmuxMobileAnalyticsTests/MobileNetworkOutcomeReporterTests.swift",
        "docs/transport-sentry-diagnostics.md",
        "web/services/observability/mobileNetworkOutcome.ts",
        "web/tests/mobile-network-observability-route.test.ts",
    ]
    actual = module.classify_files(pr_13459)
    assert actual.macos is False, actual
    assert actual.release_build is False, actual
    assert actual.web is True, actual


def test_macos_ios_package_closure_is_derived_transitively() -> None:
    with tempfile.TemporaryDirectory() as temporary_directory:
        root = Path(temporary_directory)
        project = root / "cmux.xcodeproj"
        project.mkdir()
        (project / "project.pbxproj").write_text(
            textwrap.dedent(
                """\
                /* Begin PBXNativeTarget section */
                    TARGET /* cmux */ = {
                        isa = PBXNativeTarget;
                        name = cmux;
                        packageProductDependencies = (
                            PRODUCT /* DesktopRoot */,
                        );
                    };
                /* End PBXNativeTarget section */

                /* Begin XCLocalSwiftPackageReference section */
                    ROOTREF /* XCLocalSwiftPackageReference "DesktopRoot" */ = {
                        isa = XCLocalSwiftPackageReference;
                        relativePath = Packages/macOS/DesktopRoot;
                    };
                /* End XCLocalSwiftPackageReference section */

                /* Begin XCSwiftPackageProductDependency section */
                    PRODUCT /* DesktopRoot */ = {
                        isa = XCSwiftPackageProductDependency;
                        package = ROOTREF /* XCLocalSwiftPackageReference "DesktopRoot" */;
                        productName = DesktopRoot;
                    };
                /* End XCSwiftPackageProductDependency section */
                """
            ),
            encoding="utf-8",
        )
        packages = {
            "Packages/macOS/DesktopRoot": (
                "DesktopRoot",
                '.package(path: "../../iOS/Bridge"),',
            ),
            "Packages/iOS/Bridge": (
                "Bridge",
                '.package(path: "../Leaf"),',
            ),
            "Packages/iOS/Leaf": ("Leaf", ""),
            "Packages/iOS/Ignored": ("Ignored", ""),
        }
        for directory, (name, dependency) in packages.items():
            package = root / directory
            package.mkdir(parents=True)
            dependencies = f"dependencies: [{dependency}]," if dependency else ""
            (package / "Package.swift").write_text(
                textwrap.dedent(
                    f"""\
                    // swift-tools-version: 6.0
                    import PackageDescription
                    let package = Package(
                        name: "{name}",
                        products: [.library(name: "{name}", targets: ["{name}"])],
                        {dependencies}
                        targets: [.target(name: "{name}")]
                    )
                    """
                ),
                encoding="utf-8",
            )

        assert module.macos_ios_package_closure(root) == frozenset(
            {"Packages/iOS/Bridge", "Packages/iOS/Leaf"}
        )


def test_macos_ios_package_closure_rejects_ambiguous_unowned_product() -> None:
    with tempfile.TemporaryDirectory() as temporary_directory:
        root = Path(temporary_directory)
        project = root / "cmux.xcodeproj"
        project.mkdir()
        (project / "project.pbxproj").write_text(
            textwrap.dedent(
                """\
                /* Begin PBXNativeTarget section */
                    TARGET /* cmux */ = {
                        isa = PBXNativeTarget;
                        name = cmux;
                        packageProductDependencies = (
                            PRODUCTA /* RootA */,
                            PRODUCTB /* RootB */,
                            AMBIGUOUS /* SharedUI */,
                        );
                    };
                /* End PBXNativeTarget section */

                /* Begin XCLocalSwiftPackageReference section */
                    REFA /* XCLocalSwiftPackageReference "RootA" */ = {
                        isa = XCLocalSwiftPackageReference;
                        relativePath = Packages/macOS/RootA;
                    };
                    REFB /* XCLocalSwiftPackageReference "RootB" */ = {
                        isa = XCLocalSwiftPackageReference;
                        relativePath = Packages/macOS/RootB;
                    };
                /* End XCLocalSwiftPackageReference section */

                /* Begin XCSwiftPackageProductDependency section */
                    PRODUCTA /* RootA */ = {
                        isa = XCSwiftPackageProductDependency;
                        package = REFA /* XCLocalSwiftPackageReference "RootA" */;
                        productName = RootA;
                    };
                    PRODUCTB /* RootB */ = {
                        isa = XCSwiftPackageProductDependency;
                        package = REFB /* XCLocalSwiftPackageReference "RootB" */;
                        productName = RootB;
                    };
                    AMBIGUOUS /* SharedUI */ = {
                        isa = XCSwiftPackageProductDependency;
                        productName = SharedUI;
                    };
                /* End XCSwiftPackageProductDependency section */
                """
            ),
            encoding="utf-8",
        )
        for directory, name in (
            ("Packages/macOS/RootA", "RootA"),
            ("Packages/macOS/RootB", "RootB"),
        ):
            package = root / directory
            package.mkdir(parents=True)
            (package / "Package.swift").write_text(
                textwrap.dedent(
                    f"""\
                    // swift-tools-version: 6.0
                    import PackageDescription
                    let package = Package(
                        name: "{name}",
                        products: [
                            .library(name: "{name}", targets: ["{name}"]),
                            .library(name: "SharedUI", targets: ["{name}"]),
                        ],
                        targets: [.target(name: "{name}")]
                    )
                    """
                ),
                encoding="utf-8",
            )

        try:
            module.macos_ios_package_closure(root)
        except ValueError:
            pass
        else:
            raise AssertionError("ambiguous package product ownership must fail open")


def test_macos_ios_package_closure_rejects_xcode_path_escape() -> None:
    with tempfile.TemporaryDirectory() as temporary_directory:
        root = Path(temporary_directory) / "repo"
        root.mkdir()
        project = root / "cmux.xcodeproj"
        project.mkdir()
        (project / "project.pbxproj").write_text(
            textwrap.dedent(
                """\
                /* Begin PBXNativeTarget section */
                    TARGET /* cmux */ = {
                        isa = PBXNativeTarget;
                        name = cmux;
                        packageProductDependencies = (
                            PRODUCT /* Escape */,
                        );
                    };
                /* End PBXNativeTarget section */

                /* Begin XCLocalSwiftPackageReference section */
                    ESCAPE /* XCLocalSwiftPackageReference "Escape" */ = {
                        isa = XCLocalSwiftPackageReference;
                        relativePath = ../outside;
                    };
                /* End XCLocalSwiftPackageReference section */

                /* Begin XCSwiftPackageProductDependency section */
                    PRODUCT /* Escape */ = {
                        isa = XCSwiftPackageProductDependency;
                        package = ESCAPE /* XCLocalSwiftPackageReference "Escape" */;
                        productName = Escape;
                    };
                /* End XCSwiftPackageProductDependency section */
                """
            ),
            encoding="utf-8",
        )
        outside = root.parent / "outside"
        outside.mkdir()
        (outside / "Package.swift").write_text(
            '// swift-tools-version: 6.0\nimport PackageDescription\n',
            encoding="utf-8",
        )

        try:
            module.macos_ios_package_closure(root)
        except ValueError as error:
            assert "escapes repository" in str(error)
        else:
            raise AssertionError("escaping Xcode package roots must fail open")


def test_ios_package_dependency_parser_failure_fails_open_to_macos() -> None:
    original = module.load_macos_ios_package_closure
    module.load_macos_ios_package_closure = lambda: None
    try:
        actual = module.classify_files(
            ["Packages/iOS/CmuxMobileAnalytics/Sources/CmuxMobileAnalytics/AnalyticsEmitter.swift"]
        )
    finally:
        module.load_macos_ios_package_closure = original

    assert actual.macos is True, actual
    assert actual.release_build is True, actual


def test_app_source_runs_macos() -> None:
    assert_areas(["Sources/AppDelegate.swift"], macos=True, web=False)


def test_workflow_changes_run_everything() -> None:
    assert_areas(
        [".github/workflows/ci.yml"],
        macos=True,
        web=True,
        agent_session_web=True,
    )


def test_publishing_helpers_skip_unrelated_product_builds() -> None:
    helpers = ["scripts/ci/download-run-artifact.py", "scripts/prebuild_sparkle_deltas.sh", "scripts/sparkle_generate_appcast.sh"]
    for path in helpers:
        actual = module.classify_files([path])
        assert not any((actual.macos, actual.web, actual.agent_session_web, actual.cli, actual.swift_packages, actual.release_build)), (path, actual)
    actual = module.classify_files(helpers + ["Sources/AppDelegate.swift"])
    assert actual.macos and actual.release_build
    actual = module.classify_files(helpers + ["scripts/ci/unknown_publishing_helper.py"])
    assert actual.macos and actual.release_build and actual.web
    result, outputs = run_detect_step_for_paths(helpers + [".github/workflows/nightly.yml", "tests/test_sparkle_generate_appcast_no_deltas.sh"])
    assert outputs == ["macos=false", "web=false", "agent_session_web=false", "cli=false", "swift_packages=false", "release_build=false"], (result.stdout, outputs)


def test_macos_admission_control_helpers_run_admission_without_web_or_release() -> None:
    for path in (
        "scripts/ci/build_input_fingerprint.py",
        "scripts/ci/find_admitted_build.py",
    ):
        actual = module.classify_files([path])
        assert actual.macos is True, (path, actual)
        assert actual.web is False, (path, actual)
        assert actual.agent_session_web is False, (path, actual)
        assert actual.release_build is False, (path, actual)


def test_macos_test_product_ci_helpers_run_admission_without_web_or_release() -> None:
    for path in (
        "scripts/ci/app_host_test_products.py",
        "scripts/ci/app_host_layer_transport.py",
        "scripts/ci/parallel_artifact_download.py",
        "scripts/ci/canonical-build-root.sh",
        "scripts/ci/compile-app-host-test-product.sh",
        "scripts/ci/product_input_identity.py",
        "scripts/ci/peer_product_source.py",
        "scripts/ci/restore-app-host-test-product.sh",
        "scripts/ci/reuse_app_host_products.py",
        "scripts/ci/sanitize-xcode-source-packages-cache.py",
    ):
        actual = module.classify_files([path])
        assert actual.macos is True, (path, actual)
        assert actual.web is False, (path, actual)
        assert actual.agent_session_web is False, (path, actual)
        assert actual.release_build is False, (path, actual)


def test_unknown_ci_helper_still_fails_open_to_every_area_the_lane_can_reach() -> None:
    actual = module.classify_files(["scripts/ci/future_unknown_helper.py"])
    assert actual.macos is True
    assert actual.web is True
    assert actual.agent_session_web is True
    assert actual.release_build is True
    # cli-pipe-regressions.yml runs no unowned scripts/ci helper, so a new one
    # cannot change its result unless it shadows an import of a helper the lane
    # does run; test_cli_lane_routes_stdlib_shadowing_ci_helpers covers that.
    assert actual.cli is False


def test_guard_workflow_and_self_hosted_guard_skip_product_areas() -> None:
    for path in (
        ".github/workflows/ci-guards.yml",
        "tests/test_ci_self_hosted_guard.sh",
    ):
        assert_areas([path], macos=False, web=False)


def test_reusable_web_workflow_edit_runs_every_owned_web_job() -> None:
    actual = module.classify_files([".github/workflows/ci-web.yml"])
    assert actual.macos is False
    assert actual.web is True
    assert actual.agent_session_web is True
    assert actual.release_build is False


def test_reusable_macos_workflow_edit_runs_owned_macos_jobs() -> None:
    actual = module.classify_files([".github/workflows/ci-macos.yml"])
    assert actual.macos is True
    assert actual.web is False
    assert actual.agent_session_web is False
    assert actual.release_build is True


def test_other_workflow_changes_skip_macos_and_web() -> None:
    # Unrelated workflow edits are validated by the guard lane and by their
    # own workflow triggers. The reusable guard workflow itself is part of CI
    # routing and is intentionally covered by the fail-open assertion above.
    assert_areas(
        [".github/workflows/relay-tls.yml", ".github/actionlint.yaml"],
        macos=False,
        web=False,
    )


def test_linux_registry_changes_skip_native_but_preserve_native_changes() -> None:
    base = 'version = 1\n[[test]]\npath = "tests/native.py"\nlane = "macos-shell"\n'
    guard = '\n[[test]]\npath = "tests/guard.py"\nlane = "linux-guard"\n'
    assert module.test_registry_change_is_linux_only(base, base + guard)
    assert module.test_registry_change_is_linux_only(base + guard, base)
    assert module.test_registry_change_is_linux_only(base, base + '\n# comment\n')
    for candidate in (
        base.replace('macos-shell', 'linux-guard'),
        base.replace('native.py', 'other.py'),
        base + 'requirements = ["fish"]\n',
        base.replace('version = 1', 'version = 2'),
        'invalid TOML',
        base + guard + guard,
    ):
        assert not module.test_registry_change_is_linux_only(base, candidate), candidate
    assert not module.test_registry_change_is_linux_only('invalid TOML', base)


def test_registry_cli_uses_base_and_keeps_mixed_product_changes() -> None:
    base = 'version = 1\n[[test]]\npath = "tests/native.py"\nlane = "macos-shell"\n'
    with tempfile.TemporaryDirectory() as temp_dir:
        root = Path(temp_dir)
        (root / 'tests').mkdir()
        head = root / 'tests/test-execution.toml'
        head.write_text(base + '\n[[test]]\npath = "tests/guard.py"\nlane = "linux-guard"\n')
        before = root / 'base.toml'
        before.write_text(base)
        files = root / 'files.txt'
        files.write_text('tests/test-execution.toml\n')
        env = {**os.environ, 'CMUX_CI_HEAD_TEST_REFERENCE_ROOT': str(root)}
        command = [sys.executable, str(HELPER), '--event-name', 'pull_request',
                   '--files-from', str(files), '--test-registry-base', str(before)]
        result = subprocess.run(command, env=env, capture_output=True, text=True, check=True)
        assert 'macos=false' in result.stdout, result.stdout
        assert 'release_build=false' in result.stdout, result.stdout
        files.write_text('tests/test-execution.toml\nSources/AppDelegate.swift\n')
        result = subprocess.run(command, env=env, capture_output=True, text=True, check=True)
        assert 'macos=true' in result.stdout, result.stdout
        before.unlink()
        files.write_text('tests/test-execution.toml\n')
        result = subprocess.run(command, env=env, capture_output=True, text=True, check=True)
        assert 'macos=true' in result.stdout, result.stdout


def test_guard_only_tests_skip_macos() -> None:
    # Referenced only by Linux jobs in the CI caller or reusable guard workflow.
    assert_areas(["tests/test_ci_self_hosted_guard.sh"], macos=False, web=False)
    assert_areas(
        [".github/workflows/ios-testflight.yml", "tests/test_ios_testflight_main_push_filter.py"],
        macos=False,
        web=False,
    )


def test_tests_run_by_macos_jobs_run_macos() -> None:
    assert_areas(["tests/test_cli_contract_help.py"], macos=True, web=False)
    # A macOS job runs these through a glob.
    assert_areas(["tests/test_nushell_integration_hooks.py"], macos=True, web=False)
    # Shared by a Linux guard job and release-build.
    assert_areas(["tests/test_install_cmux_tui_client.sh"], macos=True, web=False)


def test_unreferenced_tests_run_macos() -> None:
    # Nothing in ci.yml names it, so a macOS-run test may import it.
    assert_areas(["tests/some_new_helper.py"], macos=True, web=False)


def test_guard_only_change_with_app_source_runs_macos() -> None:
    assert_areas(
        [".github/workflows/relay-tls.yml", "Sources/AppDelegate.swift"],
        macos=True,
        web=False,
    )


def test_only_a_plainly_linux_job_makes_a_test_guard_only() -> None:
    def workflow(runs_on: str) -> str:
        return (
            "name: CI\njobs:\n  guard:\n"
            "    runs-on: ${{ vars.LINUX_RUNNER || 'blacksmith-4vcpu-ubuntu-2404' }}\n"
            "    steps:\n      - run: python3 tests/test_guard.py\n"
            f"  other:\n    runs-on:{runs_on}\n"
            "    steps:\n      - run: python3 tests/test_other.py\n"
        )

    for runs_on in (
        " ${{ matrix.runner }}",
        " ${{ needs.pick.outputs.runner }}",
        "\n      - self-hosted\n      - arm64",
        "\n      group: big-macs",
        " ${{ vars.MACOS_RUNNER_15 || 'blacksmith-6vcpu-macos-15' }}",
        " ${{ vars.LINUX_RUNNER || vars.MACOS_RUNNER_15 }}",
    ):
        references = module.macos_job_test_references(workflow(runs_on))
        assert module.is_guard_only_test("tests/test_guard.py", references), runs_on
        assert not module.is_guard_only_test("tests/test_other.py", references), runs_on

    references = module.macos_job_test_references(workflow(" ubuntu-24.04"))
    assert module.is_guard_only_test("tests/test_other.py", references)


CI_DIFF_BASE = """name: CI
on:
  pull_request:
env:
  FOO: "1"
jobs:
  changes:
    runs-on: ${{ vars.LINUX_RUNNER || 'blacksmith-4vcpu-ubuntu-2404' }}
    steps:
      - run: route
  workflow-guard-tests:
    runs-on: ${{ vars.LINUX_RUNNER || 'blacksmith-4vcpu-ubuntu-2404' }}
    steps:
      - run: guard
  macos-compile-admission:
    runs-on: ${{ vars.MACOS_RUNNER_15 || 'blacksmith-6vcpu-macos-15' }}
    steps:
      - run: compile
  ci-status:
    runs-on: ${{ vars.LINUX_RUNNER || 'blacksmith-4vcpu-ubuntu-2404' }}
    steps:
      - run: gate
"""


def test_ci_workflow_change_is_linux_only_for_linux_job_edits() -> None:
    linux_only = module.ci_workflow_change_is_linux_only
    assert linux_only(CI_DIFF_BASE, CI_DIFF_BASE.replace("- run: guard", "- run: guard\n      - run: more"))
    added_linux_job = CI_DIFF_BASE.replace(
        "  ci-status:",
        "  new-linux:\n    runs-on: ubuntu-24.04\n    steps:\n      - run: x\n  ci-status:",
    )
    assert linux_only(CI_DIFF_BASE, added_linux_job)


def test_ci_workflow_change_runs_macos_when_it_could_matter() -> None:
    linux_only = module.ci_workflow_change_is_linux_only
    for head in (
        CI_DIFF_BASE.replace("- run: compile", "- run: compile --faster"),
        CI_DIFF_BASE.replace("blacksmith-6vcpu-macos-15", "blacksmith-6vcpu-macos-26"),
        CI_DIFF_BASE.replace('FOO: "1"', 'FOO: "2"'),
        CI_DIFF_BASE.replace("- run: route", "- run: route --differently"),
        CI_DIFF_BASE.replace("- run: gate", "- run: gate || true"),
        # A Linux job that becomes a macOS job, and a removed macOS job.
        CI_DIFF_BASE.replace(
            "  workflow-guard-tests:\n    runs-on: ${{ vars.LINUX_RUNNER || 'blacksmith-4vcpu-ubuntu-2404' }}",
            "  workflow-guard-tests:\n    runs-on: ${{ matrix.runner }}",
        ),
        CI_DIFF_BASE.replace(
            "  macos-compile-admission:\n    runs-on: ${{ vars.MACOS_RUNNER_15 || 'blacksmith-6vcpu-macos-15' }}\n    steps:\n      - run: compile\n",
            "",
        ),
        "not a workflow",
    ):
        assert not linux_only(CI_DIFF_BASE, head), head
    assert not linux_only("not a workflow", CI_DIFF_BASE)
    assert not linux_only(CI_DIFF_BASE, CI_DIFF_BASE)


def edit_job(workflow: str, job: str, marker: str = "# edited") -> str:
    """Append a comment line to one top-level job's block."""
    parts = module.split_workflow_jobs(workflow)
    assert parts is not None
    preamble, jobs = parts
    assert job in jobs, job
    edited = jobs[job].rstrip("\n") + f"\n    {marker}\n\n"
    # The split drops each job's two-space indent.
    return preamble + "\njobs:\n" + "".join(
        "  " + (edited if name == job else block) for name, block in jobs.items()
    )


def areas(**selected: bool) -> object:
    return module.ChangeAreas(**{
        name: selected.get(name, False)
        for name in ("macos", "web", "agent_session_web", "cli", "swift_packages", "release_build")
    })


def test_ci_workflow_job_edits_select_only_the_area_they_call() -> None:
    real = CI_WORKFLOW.read_text(encoding="utf-8")
    change_areas = module.ci_workflow_change_areas
    # Plainly Linux jobs, including the gates that decide whether macOS runs
    # without executing Mac work themselves, select nothing.
    for job in ("macos-admission-gate", "static-preflight", "linux-preflight", "suite-coverage"):
        assert change_areas(real, edit_job(real, job)) == areas(), job
    # A caller job selects the area of the reusable workflow it calls: its
    # `with:` inputs, `if:` and `needs:` all live in that block.
    assert change_areas(real, edit_job(real, "macos")) == areas(macos=True, release_build=True)
    assert change_areas(real, edit_job(real, "web")) == areas(web=True, agent_session_web=True)
    assert change_areas(real, edit_job(real, "cli")) == areas(cli=True)
    assert change_areas(
        real, edit_job(edit_job(real, "cli"), "macos-admission-gate"),
    ) == areas(cli=True)


def test_ci_workflow_job_edits_fail_open_when_the_area_is_unknown() -> None:
    real = CI_WORKFLOW.read_text(encoding="utf-8")
    change_areas = module.ci_workflow_change_areas
    # Routing jobs, the preamble every job inherits, callers of workflows
    # without a product area, and non-Linux jobs outside a called workflow.
    for head in (
        edit_job(real, "changes"),
        edit_job(real, "ci-status"),
        edit_job(real, "guards"),
        edit_job(real, "browser"),
        edit_job(real, "claude-wrapper"),
        real.replace("\njobs:\n", "\n# preamble edit\njobs:\n", 1),
        "not a workflow",
        real,
    ):
        assert change_areas(real, head) is None
    # The macOS caller keeps macOS when it is renamed or removed.
    renamed = real.replace("\n  macos:\n", "\n  macos-renamed:\n", 1)
    assert change_areas(real, renamed) == areas(macos=True, release_build=True)


def test_ci_workflow_areas_route_through_classify_files() -> None:
    selected = module.classify_files(
        [module.CI_WORKFLOW_PATH], ci_workflow_areas=areas(cli=True),
    )
    assert selected == areas(cli=True)
    assert module.classify_files([module.CI_WORKFLOW_PATH]) == areas(
        macos=True, web=True, agent_session_web=True, cli=True, release_build=True,
    )


def test_macos_workflow_job_edits_select_release_only_for_release_jobs() -> None:
    real = MACOS_WORKFLOW.read_text(encoding="utf-8")
    change_areas = module.macos_workflow_change_areas
    mac_only = areas(macos=True)
    with_release = areas(macos=True, release_build=True)
    for job in ("app-host-unit-tests", "tests-build-and-lag"):
        assert change_areas(real, edit_macos_job(real, job)) == mac_only, job
    # Admission builds the product the CLI lane restores, so it also runs that lane.
    assert change_areas(real, edit_macos_job(real, "macos-compile-admission")) == areas(macos=True, cli=True)
    # swift-package-tests produces the helper release-build consumes through
    # its outputs, and macos-status reports the Release verdict.
    for job in ("release-admission", "release-build", "swift-package-tests", "macos-status"):
        assert change_areas(real, edit_macos_job(real, job)) == with_release, job
    assert change_areas(
        real, edit_macos_job(edit_macos_job(real, "app-host-unit-tests"), "release-build"),
    ) == with_release
    for head in (
        real.replace("\njobs:\n", "\nconcurrency: edited\njobs:\n", 1),
        "not a workflow",
        real,
    ):
        assert change_areas(real, head) is None


def edit_macos_job(workflow: str, job: str) -> str:
    """Change one ci-macos.yml job; a comment alone changes no job there."""
    return edit_job(workflow, job, marker="edited: true")


def test_macos_workflow_comment_edits_change_no_job() -> None:
    real = MACOS_WORKFLOW.read_text(encoding="utf-8")
    change_areas = module.macos_workflow_change_areas
    # The macOS area still runs the file; no job's own lane does.
    for job in ("release-build", "cli-product-tests", "macos-compile-admission"):
        assert change_areas(real, edit_job(real, job)) == areas(macos=True), job
    in_preamble = real.replace("\njobs:\n", "\n# preamble comment\njobs:\n", 1)
    assert change_areas(real, in_preamble) == areas(macos=True)


def test_macos_workflow_input_edits_reach_only_the_jobs_that_read_them() -> None:
    real = MACOS_WORKFLOW.read_text(encoding="utf-8")
    change_areas = module.macos_workflow_change_areas
    entry = "      pr_xcode_app:\n        required: false\n        default: \"\"\n        type: string\n"
    assert entry in real
    # A new input nothing reads yet reaches no job.
    added = real.replace(entry, entry + "      new_knob:\n        required: false\n        default: \"\"\n        type: string\n", 1)
    assert change_areas(real, added) == areas(macos=True)
    # A changed input reaches every job that reads it, and no other.
    changed = real.replace(entry, entry.replace('default: ""', 'default: "x"'), 1)
    jobs = module.split_workflow_jobs(real)[1]
    readers = {name for name, block in jobs.items() if "inputs.pr_xcode_app" in block}
    assert readers and readers != set(jobs)
    assert change_areas(real, changed) == areas(
        macos=True,
        release_build=bool(readers & module._release_jobs(jobs)),
        cli=bool(readers & module.MACOS_CLI_LANE_JOBS),
    )
    # release_build itself is read by the Release jobs.
    release_entry = "      release_build:\n        required: true\n        type: string\n"
    assert release_entry in real
    retyped = real.replace(release_entry, release_entry.replace("required: true", "required: false"), 1)
    assert change_areas(real, retyped).release_build
    # An input the workflow's own env reads reaches every job through it.
    macos_entry = "      macos:\n        required: true\n        type: string\n"
    assert macos_entry in real and "inputs.macos" in module.split_workflow_jobs(real)[0]
    assert change_areas(real, real.replace(macos_entry, macos_entry.replace("required: true", "required: false"), 1)) is None
    # Anything else above `jobs:` still reaches every job.
    assert change_areas(real, real.replace("permissions:\n  contents: read", "permissions:\n  contents: write", 1)) is None


def test_macos_workflow_input_parsing_refuses_what_it_cannot_split() -> None:
    real = MACOS_WORKFLOW.read_text(encoding="utf-8")
    change_areas = module.macos_workflow_change_areas
    entry = "      unit_in_admission:\n        required: false\n        default: \"\"\n        type: string\n"
    assert entry in real
    # A trailing comment still names the input it opens.
    commented = real.replace(entry, entry.replace("unit_in_admission:", "unit_in_admission: # set by choose_ci_suite.py"), 1)
    edited = commented.replace(
        "unit_in_admission: # set by choose_ci_suite.py\n        required: false\n        default: \"\"",
        "unit_in_admission: # set by choose_ci_suite.py\n        required: false\n        default: \"true\"", 1,
    )
    assert commented != edited
    assert change_areas(commented, edited) == change_areas(real, real.replace(entry, entry.replace('default: ""', 'default: "true"'), 1))
    assert change_areas(commented, edited).cli
    # A flow-style input cannot be split, so every job runs.
    flow = real.replace(entry, entry + '      release_flavor: {type: string, required: false, default: "a"}\n', 1)
    assert change_areas(flow, flow.replace('default: "a"}', 'default: "b"}')) is None


def test_macos_workflow_release_feeders_are_derived_from_outputs() -> None:
    base = (
        "name: M\non: workflow_call\njobs:\n"
        "  compile:\n    runs-on: macos-15\n    outputs:\n      key: x\n    steps:\n      - run: a\n"
        "  helper:\n    runs-on: macos-15\n    outputs:\n      path: y\n    steps:\n      - run: b\n"
        "  shard:\n    runs-on: macos-15\n    needs: compile\n"
        "    steps:\n      - run: ${{ needs.compile.outputs.key }}\n"
        "  release:\n    needs: [compile, helper]\n"
        "    if: ${{ inputs.release_build == 'true' && needs.compile.result == 'success' }}\n"
        "    runs-on: macos-15\n    steps:\n      - run: ${{ needs.helper.outputs.path }}\n"
    )
    change_areas = module.macos_workflow_change_areas
    assert change_areas(base, base.replace("- run: a", "- run: a2")) == areas(macos=True)
    assert change_areas(base, base.replace("- run: b", "- run: b2")) == areas(macos=True, release_build=True)
    assert change_areas(base, base.replace("- run: ${{ needs.compile", "- run: x ${{ needs.compile")) == areas(macos=True)
    assert change_areas(base, base.replace("- run: ${{ needs.helper", "- run: x ${{ needs.helper")) == areas(
        macos=True, release_build=True,
    )


def test_macos_workflow_areas_route_through_classify_files() -> None:
    path = ".github/workflows/ci-macos.yml"
    assert module.classify_files([path], macos_workflow_areas=areas(macos=True)) == areas(macos=True)
    assert module.classify_files([path], macos_workflow_areas=areas(macos=True, cli=True)) == areas(
        macos=True, cli=True,
    )
    # Without a job-by-job comparison every job runs, the CLI lane included.
    assert module.classify_files([path]) == areas(macos=True, release_build=True, cli=True)


def test_macos_workflow_cli_lane_edits_route_the_cli_lane() -> None:
    real = MACOS_WORKFLOW.read_text(encoding="utf-8")
    change_areas = module.macos_workflow_change_areas
    assert change_areas(real, edit_macos_job(real, "cli-product-tests")).cli
    assert change_areas(real, edit_macos_job(real, "macos-compile-admission")).cli
    assert not change_areas(real, edit_macos_job(real, "app-host-unit-tests")).cli


def test_cli_product_lane_scripts_route_the_cli_lane() -> None:
    # Every repository script cli-product-tests runs is a CLI lane input.
    real = MACOS_WORKFLOW.read_text(encoding="utf-8")
    start = real.index("\n  cli-product-tests:\n")
    following = re.compile(r"\n  [a-z0-9-]+:\n").search(real, start + 5)
    block = real[start:following.start() if following else len(real)]
    scripts = set(re.findall(r"(scripts/[A-Za-z0-9_./-]+\.(?:py|sh))", block))
    assert "scripts/ci/restore-app-host-test-product.sh" in scripts
    # And what the restore script runs in turn.
    scripts |= {"scripts/ci/app_host_test_products.py", "scripts/ci/canonical-build-root.sh"}
    for script in sorted(scripts):
        assert module.classify_files([script]).cli, script
    for action in set(re.findall(r"uses: \./(\.github/actions/[A-Za-z0-9_-]+)", block)):
        assert module.classify_files([f"{action}/action.yml"]).cli, action


def test_workflow_routes_macos_shard_edit_without_release_build() -> None:
    real = MACOS_WORKFLOW.read_text(encoding="utf-8")
    path = ".github/workflows/ci-macos.yml"
    shard = edit_macos_job(real, "app-host-unit-tests")
    release = edit_macos_job(real, "release-build")
    # The normal router, and the trusted base router a policy edit selects.
    for policy_change in ([], ["scripts/ci/detect_ci_change_areas.py"]):
        for head, release_build in ((shard, "false"), (release, "true")):
            _, outputs = run_detect_step_for_paths(
                [path, *policy_change],
                head_files={
                    path: head,
                    **{p: HELPER.read_text(encoding="utf-8") + "\n# policy edit\n" for p in policy_change},
                },
            )
            assert "macos=true" in outputs, (policy_change, outputs)
            assert f"release_build={release_build}" in outputs, (policy_change, outputs)
            assert "web=false" in outputs, (policy_change, outputs)


def run_detect_step_for_ci_workflow_edit(base: str, head: str) -> tuple[subprocess.CompletedProcess[str], list[str]]:
    script = detect_step_script()
    with tempfile.TemporaryDirectory() as temp_dir:
        repo = Path(temp_dir)
        runner_temp = Path(temp_dir) / "runner-temp"
        subprocess.run(["git", "init", "-q"], cwd=repo, check=True)
        subprocess.run(["git", "config", "user.email", "ci@example.test"], cwd=repo, check=True)
        subprocess.run(["git", "config", "user.name", "CI Test"], cwd=repo, check=True)
        helper_copy = repo / "scripts" / "ci" / "detect_ci_change_areas.py"
        helper_copy.parent.mkdir(parents=True, exist_ok=True)
        helper_copy.write_text(HELPER.read_text(encoding="utf-8"), encoding="utf-8")
        workflow = repo / ".github" / "workflows" / "ci.yml"
        workflow.parent.mkdir(parents=True, exist_ok=True)
        workflow.write_text(base, encoding="utf-8")
        subprocess.run(["git", "add", "."], cwd=repo, check=True)
        subprocess.run(["git", "commit", "-q", "-m", "base"], cwd=repo, check=True)
        base_sha = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip()
        workflow.write_text(head, encoding="utf-8")
        subprocess.run(["git", "commit", "-q", "-am", "head"], cwd=repo, check=True)
        head_sha = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip()
        output_path = repo / "github-output.txt"
        env = {
            **os.environ,
            "EVENT_NAME": "pull_request",
            "BASE_SHA": base_sha,
            "HEAD_SHA": head_sha,
            "MERGE_SHA": head_sha,
            "GITHUB_OUTPUT": str(output_path),
            # The trusted base router lays its checkout out under $RUNNER_TEMP,
            # and the step runs under `set -u`. GitHub sets it; a local run
            # does not, so without this the suite only passes inside CI.
            "RUNNER_TEMP": os.environ.get("RUNNER_TEMP") or str(runner_temp),
        }
        result = subprocess.run(
            ["bash", "-c", isolate_ci_tmp(script, repo)], cwd=repo, env=env, text=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True,
        )
        return result, output_path.read_text(encoding="utf-8").splitlines()


def test_workflow_routes_linux_only_ci_workflow_edit_away_from_macos() -> None:
    _, outputs = run_detect_step_for_ci_workflow_edit(
        CI_DIFF_BASE, CI_DIFF_BASE.replace("- run: guard", "- run: guard\n      - run: more")
    )
    assert outputs == [
        "macos=false",
        "web=false",
        "agent_session_web=false",
        "cli=false",
        "swift_packages=false",
        "release_build=false",
    ]


def test_workflow_routes_top_level_macos_job_edit_as_control_plane_only() -> None:
    _, outputs = run_detect_step_for_ci_workflow_edit(
        CI_DIFF_BASE, CI_DIFF_BASE.replace("- run: compile", "- run: compile --faster")
    )
    assert outputs == [
        "macos=false",
        "web=false",
        "agent_session_web=false",
        "cli=false",
        "swift_packages=false",
        "release_build=false",
    ]


def test_indirect_guard_profile_references_follow_invoking_runner() -> None:
    indirect = frozenset({"tests/test_guard_profile_owned.py"})

    linux_workflow = (
        "name: Guards\njobs:\n  guard:\n"
        "    runs-on: ${{ vars.LINUX_RUNNER || 'blacksmith-4vcpu-ubuntu-2404' }}\n"
        "    steps:\n"
        "      - run: python3 scripts/ci/cmux_workload_profile.py run cmux.ci.guard\n"
    )
    references = module.macos_job_test_references(linux_workflow, indirect)
    assert module.is_guard_only_test("tests/test_guard_profile_owned.py", references)

    macos_workflow = linux_workflow.replace(
        "${{ vars.LINUX_RUNNER || 'blacksmith-4vcpu-ubuntu-2404' }}",
        "${{ vars.MACOS_RUNNER_15 || 'blacksmith-6vcpu-macos-15' }}",
    )
    references = module.macos_job_test_references(macos_workflow, indirect)
    assert not module.is_guard_only_test("tests/test_guard_profile_owned.py", references)


def test_macos_test_references_fail_open_without_ci_workflow() -> None:
    assert module.macos_job_test_references("jobs:\n") is None
    assert module.macos_job_test_references("not a workflow") is None


def test_ci_router_runs_on_every_pr_and_merge_group() -> None:
    workflow = CI_WORKFLOW.read_text(encoding="utf-8")
    assert "  pull_request:\n    types: [opened, synchronize, reopened, labeled, unlabeled]\n  merge_group:" in workflow
    assert "    paths:" not in workflow


def test_ci_label_only_reruns_preserve_inflight_compile() -> None:
    workflow = CI_WORKFLOW.read_text(encoding="utf-8")
    expected = (
        "cancel-in-progress: ${{ github.event_name == 'pull_request' "
        "&& github.event.action != 'labeled' && github.event.action != 'unlabeled' }}"
    )
    assert expected in workflow

    fallback = CI_STATUS_FALLBACK_WORKFLOW.read_text(encoding="utf-8")
    assert "  workflow_dispatch: {}" in fallback
    assert "  pull_request:" not in fallback


def detect_step_script(workflow_path: Path = CI_WORKFLOW) -> str:
    lines = workflow_path.read_text(encoding="utf-8").splitlines()
    for index, line in enumerate(lines):
        if line == "      - name: Detect CI change areas":
            for run_index in range(index + 1, len(lines)):
                if lines[run_index] == "        run: |":
                    body: list[str] = []
                    for body_line in lines[run_index + 1 :]:
                        if body_line.startswith("          "):
                            body.append(body_line[10:])
                            continue
                        if not body_line.strip():
                            body.append("")
                            continue
                        break
                    return "\n".join(body)
            break
    raise AssertionError("Detect CI change areas run block not found")


def workflow_job_block(job_name: str, workflow_path: Path = CI_WORKFLOW) -> str:
    lines = workflow_path.read_text(encoding="utf-8").splitlines()
    marker = f"  {job_name}:"
    for index, line in enumerate(lines):
        if line == marker:
            body = [line]
            for body_line in lines[index + 1 :]:
                if body_line.startswith("  ") and not body_line.startswith("    ") and body_line.strip():
                    break
                body.append(body_line)
            return "\n".join(body)
    raise AssertionError(f"{job_name} job not found")


def isolate_ci_tmp(script: str, directory: Path) -> str:
    """Point a workflow step's fixed /tmp/cmux-* files into `directory`.

    On a runner each job has its own /tmp. Locally, two suites on one host (a
    parallel guard sweep, or another checkout) would share and overwrite
    those files: one run then reads another's changed-file list, sees an empty
    diff, and routes nothing.
    """
    return script.replace("/tmp/cmux-", f"{directory}/cmux-")


def workflow_job_step_script(job_name: str, step_name: str, workflow_path: Path = CI_WORKFLOW) -> str:
    lines = workflow_path.read_text(encoding="utf-8").splitlines()
    job_marker = f"  {job_name}:"
    step_marker = f"      - name: {step_name}"
    in_job = False
    for index, line in enumerate(lines):
        if line == job_marker:
            in_job = True
            continue
        if in_job and line.startswith("  ") and not line.startswith("    ") and line.strip():
            break
        if in_job and line == step_marker:
            for run_index in range(index + 1, len(lines)):
                if lines[run_index] == "        run: |":
                    body: list[str] = []
                    for body_line in lines[run_index + 1 :]:
                        if body_line.startswith("          "):
                            body.append(body_line[10:])
                            continue
                        if not body_line.strip():
                            body.append("")
                            continue
                        break
                    return "\n".join(body)
            break
    raise AssertionError(f"{step_name} run block not found in {job_name}")


def run_linux_preflight(needs: dict[str, object]) -> subprocess.CompletedProcess[str]:
    script = workflow_job_step_script("linux-preflight", "Check routed Linux results")
    env = {**os.environ, "PREFLIGHT_NEEDS": json.dumps(needs)}
    return subprocess.run(
        ["bash", "-c", script],
        cwd=ROOT,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )


def run_app_host_unit_test_step(
    shard_mode: str = "selectors",
    *,
    known_failure: bool = False,
) -> tuple[subprocess.CompletedProcess[str], bool]:
    steps = yaml.safe_load(MACOS_WORKFLOW.read_text(encoding="utf-8"))["jobs"]["app-host-unit-tests"]["steps"]
    assert next(step["run"] for step in steps if step.get("name") == "Run unit tests") == \
        "scripts/ci/run-app-host-unit-batches.sh"
    script = (ROOT / "scripts/ci/run-app-host-unit-batches.sh").read_text(encoding="utf-8")

    with tempfile.TemporaryDirectory() as temp_dir:
        root = Path(temp_dir)
        runner_temp = root / "runner"
        fake_bin = root / "bin"
        ci_scripts = root / "scripts" / "ci"
        runner_temp.mkdir()
        fake_bin.mkdir()
        ci_scripts.mkdir(parents=True)
        shutil.copy2(
            ROOT / "scripts/ci/classify-app-host-test-output.py",
            ci_scripts / "classify-app-host-test-output.py",
        )
        shutil.copy2(
            ROOT / "scripts/ci/app_host_result_accounting.py",
            ci_scripts / "app_host_result_accounting.py",
        )
        known_catalog = ci_scripts / "app-host-known-failures.json"
        shutil.copy2(
            ROOT / "scripts/ci/app-host-known-failures.json",
            known_catalog,
        )
        if known_failure:
            known_catalog.write_text(
                json.dumps({
                    "bootstrap_main_sha": "1" * 40,
                    "version": 1,
                    "tests": {
                        "FakeTests/testOne()": {
                            "classification": "test bug",
                            "issue": 13095,
                        }
                    },
                }),
                encoding="utf-8",
            )
        inventory = runner_temp / "cmux-app-host-test-inventory.json"
        inventory.write_text(
            json.dumps({
                "version": 1,
                "tests": [
                    "FakeTests/testOne()",
                    "FakeTests/testTwo()",
                ],
            }),
            encoding="utf-8",
        )

        shard_helper = ci_scripts / "cmux_unit_test_shard.py"
        shard_helper.write_text(
            """
import os
import sys
from pathlib import Path

mode = os.environ.get("CMUX_TEST_SHARD_MODE", "selectors")
if mode == "fail":
    raise SystemExit(23)
output = Path(sys.argv[sys.argv.index("--output") + 1])
output.parent.mkdir(parents=True, exist_ok=True)
selectors = "" if mode == "empty" else "-only-testing:cmuxTests/FakeTests\\n"
output.write_text(selectors, encoding="utf-8")
""".lstrip(),
            encoding="utf-8",
        )

        console_runner = ci_scripts / "run-in-console-session.sh"
        console_runner.write_text(
            """
#!/bin/bash
set -euo pipefail
counter="${CMUX_TEST_BATCH_COUNTER:?}"
printf 'invoked\n' > "${CMUX_TEST_RUNNER_MARKER:?}"
iteration=0
if [ -f "$counter" ]; then
  iteration="$(cat "$counter")"
fi
iteration=$((iteration + 1))
printf '%s\n' "$iteration" > "$counter"
result_root="${CMUX_APP_HOST_RESULT_BUNDLE_ROOT:-$RUNNER_TEMP/cmux-app-host-xcresults}"
mkdir -p "$result_root"
if [ "${CMUX_TEST_KNOWN_FAILURE_MODE:-0}" = "1" ]; then
  cat >"$result_root/cmux-app-host-xcodebuild-${CMUX_TAG}-pid-${iteration}.tests.json" <<'JSON'
{"testNodes":[{"nodeType":"Test Suite","children":[{"nodeType":"Test Case","nodeIdentifier":"FakeTests/testOne()","result":"Failed"},{"nodeType":"Test Case","nodeIdentifier":"FakeTests/testTwo()","result":"Passed"}]}]}
JSON
  echo "Executed 2 tests, with 1 failure (0 unexpected)"
  echo "** TEST FAILED **"
  exit 65
fi
if [ "$iteration" -eq 1 ]; then
  cat >"$result_root/cmux-app-host-xcodebuild-${CMUX_TAG}-pid-1.tests.json" <<'JSON'
{"testNodes":[{"nodeType":"Test Suite","children":[{"nodeType":"Test Case","nodeIdentifier":"FakeTests/testOne()","result":"Failed"},{"nodeType":"Test Case","nodeIdentifier":"FakeTests/testTwo()","result":"Failed"}]}]}
JSON
  echo "Executed 2 tests, with 2 failures (0 unexpected)"
  echo "** TEST FAILED **"
  exit 65
fi
echo "simulated app-host crash before test summary" >&2
exit 9
""".lstrip(),
            encoding="utf-8",
        )
        console_runner.chmod(0o755)

        fake_sleep = fake_bin / "sleep"
        fake_sleep.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        fake_sleep.chmod(0o755)

        runner_marker = root / "runner-invoked"
        result = subprocess.run(
            ["bash", "-c", script],
            cwd=root,
            env={
                **os.environ,
                "PATH": f"{fake_bin}:{os.environ['PATH']}",
                "RUNNER_TEMP": str(runner_temp),
                "CMUX_APP_HOST_XCTESTRUN": str(root / "cmux-unit.xctestrun"),
                "CMUX_NUMERIC_LOCALE_XCTESTRUN": str(root / "numeric.xctestrun"),
                "CMUX_DERIVED_DATA_PATH": str(root / "derived-data"),
                "CMUX_TEST_BATCH_COUNTER": str(root / "batch-counter"),
                "CMUX_TEST_RUNNER_MARKER": str(runner_marker),
                "CMUX_TEST_SHARD_MODE": shard_mode,
                "CMUX_TEST_KNOWN_FAILURE_MODE": "1" if known_failure else "0",
                "CMUX_APP_HOST_TEST_INVENTORY": str(inventory),
                "CMUX_APP_HOST_SHARD": "1",
            },
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        return result, runner_marker.exists()

def linux_preflight_needs(
    *,
    outputs: dict[str, str] | None = None,
    results: dict[str, str] | None = None,
) -> dict[str, object]:
    route_outputs = {
        "linux_guard_tests": "true",
        "linux_guard_history": "true",
        "linux_guard_cli": "true",
        "linux_guard_source": "true",
        "ghosttykit_release": "true",
        "macos": "true",
        "web": "true",
        "agent_session_web": "true",
    }
    if outputs:
        route_outputs.update(outputs)
    job_results = {
        "changes": "success",
        "static-preflight": "success",
        "guards": "success",
        "ghosttykit-release-check": "success",
        "web": "success",
    }
    if results:
        job_results.update(results)
    return {
        name: {"result": result, "outputs": route_outputs if name == "changes" else {}}
        for name, result in job_results.items()
    }


def run_guard_status(
    *,
    inputs: dict[str, str] | None = None,
    results: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    route_inputs = dict.fromkeys(GUARD_ROUTE_JOBS, "true") if inputs is None else dict(inputs)
    job_results = dict.fromkeys(GUARD_ROUTE_JOBS.values(), "success")
    if results:
        job_results.update(results)
    script = workflow_job_step_script(
        "guard-status", "Check routed guard jobs", GUARD_WORKFLOW
    )
    env = {
        **os.environ,
        "GUARD_INPUTS": json.dumps(route_inputs),
        "GUARD_NEEDS": json.dumps(
            {name: {"result": result} for name, result in job_results.items()}
        ),
    }
    return subprocess.run(
        ["bash", "-c", script],
        cwd=ROOT,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )


def run_web_status(
    *,
    inputs: dict[str, str] | None = None,
    results: dict[str, str] | None = None,
    subareas: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    route_inputs = {
        "web": "true",
        "macos": "true",
        "agent_session_web": "true",
    } if inputs is None else dict(inputs)
    job_results = dict.fromkeys(WEB_JOBS, "success")
    if results:
        job_results.update(results)
    if subareas is None:
        scope_required = route_inputs["web"] == "true" or route_inputs["macos"] == "true"
        selected_subareas = {
            "db": "true",
            "diff_sidecar": "true",
            "instant": "true",
            "production_build": "true",
            "react_apps": "true",
            "typecheck": "true",
            "unit_tests": "true",
        } if scope_required else {
            "db": "false",
            "diff_sidecar": "false",
            "instant": "false",
            "production_build": "false",
            "react_apps": "false",
            "typecheck": "false",
            "unit_tests": "false",
        }
    else:
        selected_subareas = dict(subareas)
    needs = {name: {"result": result} for name, result in job_results.items()}
    needs["web-subarea-scope"]["outputs"] = selected_subareas
    script = workflow_job_step_script(
        "web-status", "Check routed web jobs", WEB_WORKFLOW
    )
    env = {
        **os.environ,
        "WEB_INPUTS": json.dumps(route_inputs),
        "WEB_NEEDS": json.dumps(needs),
    }
    return subprocess.run(
        ["bash", "-c", script],
        cwd=ROOT,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )



def run_macos_status(
    *,
    inputs: dict[str, str] | None = None,
    results: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    route_inputs = {
        "macos": "true",
        "full_suite": "true",
        "compile_admitted": "false",
        "release_build": "true",
        "source_parent1": "parent",
    } if inputs is None else dict(inputs)
    job_results = dict.fromkeys(MACOS_JOBS, "success")
    if results:
        job_results.update(results)
    script = workflow_job_step_script(
        "macos-status", "Check routed macOS jobs", MACOS_WORKFLOW
    )
    env = {
        **os.environ,
        "MACOS_INPUTS": json.dumps(route_inputs),
        "MACOS_NEEDS": json.dumps(
            {name: {"result": result} for name, result in job_results.items()}
        ),
    }
    return subprocess.run(
        ["bash", "-c", script],
        cwd=ROOT,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )


def run_detect_step_for_paths(
    paths: list[str],
    workflow_path: Path = CI_WORKFLOW,
    *,
    base_files: dict[str, str] | None = None,
    head_files: dict[str, str] | None = None,
    standalone: bool = False,
) -> tuple[subprocess.CompletedProcess[str], list[str]]:
    """Run the changes job's detect step; with `standalone`, then its standalone route."""
    script = detect_step_script(workflow_path)
    route = (
        workflow_job_step_script("changes", "Route standalone project workflows", workflow_path)
        if standalone else ""
    )
    with tempfile.TemporaryDirectory() as temp_dir:
        repo = Path(temp_dir)
        git_env = os.environ.copy()
        for name in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE"):
            git_env.pop(name, None)
        # Parallel local checkouts must not share the workflow's fixed /tmp files.
        script = isolate_ci_tmp(script, repo)
        route = isolate_ci_tmp(route, repo)
        subprocess.run(["git", "init", "-q"], cwd=repo, env=git_env, check=True)
        subprocess.run(["git", "config", "user.email", "ci@example.test"], cwd=repo, env=git_env, check=True)
        subprocess.run(["git", "config", "user.name", "CI Test"], cwd=repo, env=git_env, check=True)
        helper_copy = repo / "scripts" / "ci" / "detect_ci_change_areas.py"
        helper_copy.parent.mkdir(parents=True, exist_ok=True)
        helper_copy.write_text(HELPER.read_text(encoding="utf-8"), encoding="utf-8")
        for support in (
            CI_WORKFLOW,
            GUARD_WORKFLOW,
            WEB_WORKFLOW,
            MACOS_WORKFLOW,
            ROOT / "scripts" / "ci" / "workloads" / "ci-guard.sh",
            # The package-test lane's own inputs, which the router reads to
            # decide whether that lane is worth a macOS runner.
            ROOT / "scripts" / "ci" / "select_package_tests.py",
            # The trusted base router reads the cmux-cli target from these.
            ROOT / "cmux.xcodeproj" / "project.pbxproj",
            *sorted(ROOT.glob("Packages/*/*/Package.swift")),
        ):
            relative = support.relative_to(ROOT)
            target = repo / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(support.read_text(encoding="utf-8"), encoding="utf-8")
        for path, content in (base_files or {}).items():
            target = repo / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(content, encoding="utf-8")
        (repo / "base.txt").write_text("base\n", encoding="utf-8")
        subprocess.run(["git", "add", "."], cwd=repo, env=git_env, check=True)
        subprocess.run(["git", "commit", "-q", "-m", "base"], cwd=repo, env=git_env, check=True)
        base_sha = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, env=git_env, text=True).strip()

        if paths:
            for path in paths:
                target = repo / path
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text((head_files or {}).get(path, "changed\n"), encoding="utf-8")
            subprocess.run(["git", "add", "."], cwd=repo, env=git_env, check=True)
            subprocess.run(["git", "commit", "-q", "-m", "head"], cwd=repo, env=git_env, check=True)
            head_sha = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, env=git_env, text=True).strip()
        else:
            head_sha = base_sha

        output_path = repo / "github-output.txt"
        env = {
            **git_env,
            "EVENT_NAME": "pull_request",
            "BASE_SHA": base_sha,
            "HEAD_SHA": head_sha,
            "MERGE_SHA": head_sha,
            "GITHUB_OUTPUT": str(output_path),
            "GITHUB_WORKSPACE": str(repo),
            "RUNNER_TEMP": str(repo),
        }
        result = subprocess.run(
            ["bash", "-c", script],
            cwd=repo,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
        )
        if standalone:
            # The job's next step, reading what the detect step left behind.
            subprocess.run(["bash", "-c", route], cwd=repo, env=env, text=True,
                           capture_output=True, check=True)
        return result, output_path.read_text(encoding="utf-8").splitlines()


def test_detect_step_ignores_inherited_git_location() -> None:
    # Each Git location override must be ignored, including the custom index
    # that otherwise silently redirects writes outside the fixture repository.
    with tempfile.TemporaryDirectory() as foreign_dir:
        foreign = Path(foreign_dir)
        for variable, value in {
            "GIT_DIR": str(foreign / "not-a-repository"),
            "GIT_WORK_TREE": str(foreign / "missing-worktree"),
            "GIT_INDEX_FILE": str(foreign / "foreign-index"),
        }.items():
            with patch.dict(os.environ, {variable: value}):
                result, outputs = run_detect_step_for_paths(["Sources/AppDelegate.swift"])
            assert result.returncode == 0, result.stderr
            assert "macos=true" in outputs, outputs
            assert not Path(value).exists(), f"fixture wrote through {variable}"


def test_workflow_registry_diff_reaches_normal_and_trusted_router() -> None:
    registry = "tests/test-execution.toml"
    base = 'version = 1\n[[test]]\npath = "tests/native.py"\nlane = "macos-shell"\n'
    guard = '\n[[test]]\npath = "tests/guard.py"\nlane = "linux-guard"\n'
    for policy_change in ([], ["scripts/ci/detect_ci_change_areas.py"]):
        for candidate, expected in ((base + guard, "false"),
                                    (base.replace("native.py", "other.py"), "true")):
            result, outputs = run_detect_step_for_paths(
                [registry, *policy_change],
                base_files={registry: base}, head_files={registry: candidate},
            )
            assert f"macos={expected}" in outputs, (result.stdout, result.stderr)
            assert f"release_build={expected}" in outputs, outputs


def test_workflow_pbxproj_diff_reaches_normal_and_trusted_router() -> None:
    project = (ROOT / XCODE_PROJECT).read_text(encoding="utf-8")
    cases = [(head, "false") for head in cli_neutral_project_edits(project).values()]
    cases.append((cli_relevant_project_edits(project)["cli setting"], "true"))
    for policy_change in ([], ["scripts/ci/detect_ci_change_areas.py"]):
        for head, expected in cases:
            result, outputs = run_detect_step_for_paths(
                [XCODE_PROJECT, *policy_change],
                base_files={XCODE_PROJECT: project}, head_files={XCODE_PROJECT: head},
            )
            assert f"cli={expected}" in outputs, (policy_change, result.stdout, result.stderr)
            # The app still builds from the project either way.
            assert "macos=true" in outputs, outputs


def test_workflow_self_change_guard_runs_before_detector_imports() -> None:
    result, outputs = run_detect_step_for_paths(["scripts/ci/subprocess.py"])

    assert "Could not load trusted base router" not in result.stderr
    assert outputs == [
        "macos=true",
        "web=true",
        "agent_session_web=true",
        "cli=true",
        # The package lane is the exception to fail-open: selecting it for an
        # unrecognized path means all 33 packages, which is the sweep this
        # routing exists to avoid. Main still runs it on the merged commit.
        "swift_packages=false",
        "release_build=true",
    ]


def test_router_policy_only_change_skips_product_areas_with_trusted_base() -> None:
    result, outputs = run_detect_step_for_paths([
        "scripts/ci/detect_ci_change_areas.py",
        "tests/test_ci_change_areas.py",
    ])

    assert "CI routing-policy-only PR; skipping product-area CI." in result.stdout
    assert outputs == [
        "macos=false",
        "web=false",
        "agent_session_web=false",
        "cli=false",
        "swift_packages=false",
        "release_build=false",
    ]


def test_router_change_with_app_source_uses_trusted_base_product_routing() -> None:
    result, outputs = run_detect_step_for_paths([
        "scripts/ci/detect_ci_change_areas.py",
        "Sources/AppDelegate.swift",
    ])

    assert "classifying product inputs with the trusted base router" in result.stdout
    assert outputs == ["macos=true", "web=false", "agent_session_web=false", "cli=false", "swift_packages=false", "release_build=true"]


def test_owned_control_plane_helper_reaches_detector_instead_of_fail_open_guard() -> None:
    result, outputs = run_detect_step_for_paths(["scripts/ci/download-run-artifact.py"])

    assert "CI router changed; running all CI areas." not in result.stdout
    assert outputs == [
        "macos=false",
        "web=false",
        "agent_session_web=false",
        "cli=false",
        "swift_packages=false",
        "release_build=false",
    ]

    for path in (
        "scripts/ci/build_input_fingerprint.py",
        "scripts/ci/find_admitted_build.py",
        "scripts/ci/app_host_test_products.py",
        "scripts/ci/product_input_identity.py",
        "scripts/ci/reuse_app_host_products.py",
    ):
        result, outputs = run_detect_step_for_paths([path])
        assert "CI router changed; running all CI areas." not in result.stdout, path
        # cli-product-tests restores its product through app_host_test_products.py.
        cli = "true" if path == "scripts/ci/app_host_test_products.py" else "false"
        assert outputs == [
            "macos=true",
            "web=false",
            "agent_session_web=false",
            f"cli={cli}",
            "swift_packages=false",
            "release_build=false",
        ], path


def _helper_repo(files: dict[str, str]) -> Path:
    repo = Path(tempfile.mkdtemp())
    env = {k: v for k, v in os.environ.items() if k not in {"GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE"}}
    for relative, text in files.items():
        target = repo / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text, encoding="utf-8")
    subprocess.run(["git", "init", "-q"], cwd=repo, env=env, check=True)
    subprocess.run(["git", "add", "-A"], cwd=repo, env=env, check=True)
    return repo


ROUTED_TREE = {
    ".github/workflows/ci.yml": "jobs:\n  guards:\n    uses: ./.github/workflows/ci-guards.yml\n",
    ".github/workflows/ci-guards.yml": "jobs:\n  guard:\n    runs-on: ubuntu-latest\n    steps:\n      - run: python3 tests/test_helper.py\n",
    "scripts/ci/helper.py": "print('helper')\n",
    "tests/test_helper.py": "import helper\n",
}
GUARD_ONLY_REFERENCES = (frozenset(), frozenset({"tests/test_helper.py"}))


def helper_areas(files: dict[str, str], *, base: Optional[dict[str, str]] = None, references=GUARD_ONLY_REFERENCES):
    head = _helper_repo({**ROUTED_TREE, **files})
    base_root = _helper_repo(base) if base is not None else None
    return module.ci_helper_areas("scripts/ci/helper.py", head, references, base_root=base_root)


def test_helper_run_only_outside_the_routed_workflow_tree_reaches_no_lane() -> None:
    dispatch = {".github/workflows/dispatch.yml": "on: workflow_dispatch\njobs:\n  run:\n    runs-on: macos-15\n    steps:\n      - run: python3 scripts/ci/helper.py\n"}
    assert helper_areas(dispatch) == areas()
    # Its own Linux guard naming it as `test_helper` does not make it routed.
    assert helper_areas({}) == areas()


def test_helper_a_routed_linux_job_runs_selects_only_the_areas_gating_it() -> None:
    # The guards route themselves; running a helper there needs no product area.
    guard = ROUTED_TREE[".github/workflows/ci-guards.yml"] + "      - run: python3 scripts/ci/helper.py\n"
    assert helper_areas({".github/workflows/ci-guards.yml": guard}) == areas()
    # A Linux ci.yml job behind an area selects that area.
    gated = ROUTED_TREE[".github/workflows/ci.yml"] + (
        "  lint:\n    if: ${{ needs.changes.outputs.web == 'true' }}\n    runs-on: ubuntu-latest\n"
        "    steps:\n      - run: python3 scripts/ci/helper.py\n"
    )
    assert helper_areas({".github/workflows/ci.yml": gated}) == areas(web=True)


def test_helper_a_routed_mac_or_routing_job_runs_still_fails_open() -> None:
    mac_job = "  mac:\n    runs-on: macos-15\n    steps:\n      - run: scripts/ci/wrapper.sh\n"
    # Through a script a routed Mac job runs.
    assert helper_areas({
        "scripts/ci/wrapper.sh": "python3 \"$(dirname \"$0\")/helper.py\"\n",
        ".github/workflows/ci.yml": ROUTED_TREE[".github/workflows/ci.yml"] + mac_job,
    }) is None
    # Through a composite action a routed Mac job uses.
    assert helper_areas({
        ".github/actions/run-helper/action.yml": "runs:\n  using: composite\n  steps:\n    - run: python3 scripts/ci/helper.py\n      shell: bash\n",
        ".github/workflows/ci.yml": ROUTED_TREE[".github/workflows/ci.yml"] + "  mac:\n    runs-on: macos-15\n    steps:\n      - uses: ./.github/actions/run-helper\n",
    }) is None
    # The routing job decides every lane.
    assert helper_areas({
        ".github/workflows/ci.yml": ROUTED_TREE[".github/workflows/ci.yml"] + "  changes:\n    runs-on: ubuntu-latest\n    steps:\n      - run: python3 scripts/ci/helper.py\n",
    }) is None


def test_helper_ci_macos_runs_selects_the_lanes_of_its_jobs() -> None:
    macos = {
        ".github/workflows/ci.yml": ROUTED_TREE[".github/workflows/ci.yml"] + "  macos:\n    uses: ./.github/workflows/ci-macos.yml\n",
        ".github/workflows/ci-macos.yml": (
            "on: workflow_call\njobs:\n"
            "  macos-compile-admission:\n    runs-on: macos-15\n    steps:\n      - run: echo\n"
            "  app-host-unit-tests:\n    runs-on: macos-15\n    steps:\n      - run: python3 scripts/ci/helper.py\n"
            "  release-build:\n    if: ${{ inputs.release_build == 'true' }}\n    runs-on: macos-15\n    steps:\n      - run: echo\n"
        ),
    }
    assert helper_areas(macos) == areas(macos=True)
    released = dict(macos)
    released[".github/workflows/ci-macos.yml"] = macos[".github/workflows/ci-macos.yml"].replace(
        "      - run: echo\n", "      - run: echo\n      - run: python3 scripts/ci/helper.py\n",
    )
    assert helper_areas(released) == areas(macos=True, cli=True, release_build=True)


def test_helper_named_only_in_comments_docstrings_or_routing_tables_is_not_run() -> None:
    mac_job = "  mac:\n    runs-on: macos-15\n    steps:\n      - run: python3 scripts/ci/caller.py\n"
    ci = ROUTED_TREE[".github/workflows/ci.yml"] + mac_job
    for caller in (
        '"""Pairs with helper.py."""\nprint(1)\n',
        "# helper.py does the rest\nprint(1)\n",
    ):
        assert helper_areas({".github/workflows/ci.yml": ci, "scripts/ci/caller.py": caller}) == areas(), caller
    # An import, or a path it runs, is a real call.
    for caller in ("import helper\n", 'import subprocess\nsubprocess.run(["python3", "scripts/ci/helper.py"])\n'):
        assert helper_areas({".github/workflows/ci.yml": ci, "scripts/ci/caller.py": caller}) is None, caller
    # A comment in a routed Mac job names nothing either.
    commented = ROUTED_TREE[".github/workflows/ci.yml"] + "  mac:\n    runs-on: macos-15\n    steps:\n      # helper.py later\n      - run: echo\n"
    assert helper_areas({".github/workflows/ci.yml": commented}) == areas()
    # The router lists helpers as data.
    table = ROUTED_TREE[".github/workflows/ci.yml"] + "  changes:\n    runs-on: ubuntu-latest\n    steps:\n      - run: python3 scripts/ci/detect_ci_change_areas.py\n"
    assert helper_areas({
        ".github/workflows/ci.yml": table,
        "scripts/ci/detect_ci_change_areas.py": 'OWNED = {"scripts/ci/helper.py"}\n',
    }) == areas()


def test_helper_in_a_linux_job_gated_beyond_its_if_fails_open() -> None:
    ci = ROUTED_TREE[".github/workflows/ci.yml"]
    step = "    steps:\n      - run: python3 scripts/ci/helper.py\n"
    # Waits on another job, which an area may skip.
    assert helper_areas({".github/workflows/ci.yml": ci + "  late:\n    needs: [changes, linux-preflight]\n    runs-on: ubuntu-latest\n" + step}) is None
    assert helper_areas({".github/workflows/ci.yml": ci + "  late:\n    needs:\n      - changes\n      - linux-preflight\n    runs-on: ubuntu-latest\n" + step}) is None
    # A folded condition is read whole.
    folded = "  lint:\n    if: >-\n      needs.changes.outputs.web == 'true'\n    runs-on: ubuntu-latest\n" + step
    assert helper_areas({".github/workflows/ci.yml": ci + folded}) == areas(web=True)
    # A step condition counts, and so does an output derived from macOS.
    stepped = "  lint:\n    runs-on: ubuntu-latest\n    steps:\n      - if: ${{ needs.changes.outputs.web == 'true' }}\n        run: python3 scripts/ci/helper.py\n"
    assert helper_areas({".github/workflows/ci.yml": ci + stepped}) == areas(web=True)
    derived = "  pin:\n    if: ${{ needs.changes.outputs.ghosttykit_release == 'true' }}\n    runs-on: ubuntu-latest\n" + step
    assert helper_areas({".github/workflows/ci.yml": ci + derived}) == areas(macos=True)
    # An output this cannot place runs every area.
    unknown = "  other:\n    if: ${{ needs.changes.outputs.browser == 'true' }}\n    runs-on: ubuntu-latest\n" + step
    assert helper_areas({".github/workflows/ci.yml": ci + unknown}) is None


def test_helper_the_swift_package_lane_runs_fails_open() -> None:
    macos = {
        ".github/workflows/ci.yml": ROUTED_TREE[".github/workflows/ci.yml"] + "  macos:\n    uses: ./.github/workflows/ci-macos.yml\n",
        ".github/workflows/ci-macos.yml": "on: workflow_call\njobs:\n  swift-package-tests:\n    runs-on: macos-15\n    steps:\n      - run: python3 scripts/ci/helper.py\n",
    }
    assert helper_areas(macos) is None


def test_routing_tables_still_run_what_they_import() -> None:
    table = ROUTED_TREE[".github/workflows/ci.yml"] + "  mac:\n    runs-on: macos-15\n    steps:\n      - run: python3 scripts/ci/workflow_guard_groups.py\n"
    listed = {".github/workflows/ci.yml": table, "scripts/ci/workflow_guard_groups.py": 'GROUPS = {"scripts/ci/helper.py": "ci"}\n'}
    assert helper_areas(listed) == areas()
    imported = {".github/workflows/ci.yml": table, "scripts/ci/workflow_guard_groups.py": "import helper\n"}
    assert helper_areas(imported) is None


def test_a_shebang_in_a_script_is_not_a_comment() -> None:
    assert module._names("#!/usr/bin/env helper\n", "helper")
    assert not module._names("# helper later\n", "helper")
    assert module._FULL_LINE_COMMENT_RE.sub("", "#!/bin/sh\n# note\n") == "#!/bin/sh\n"


def test_a_pull_request_cannot_unroute_a_workflow_by_editing_ci_yml() -> None:
    mac_helper = {
        ".github/workflows/ci.yml": ROUTED_TREE[".github/workflows/ci.yml"] + "  mac:\n    uses: './.github/workflows/mac.yml'\n",
        ".github/workflows/mac.yml": "on: workflow_call\njobs:\n  build:\n    runs-on: macos-15\n    steps:\n      - run: python3 scripts/ci/helper.py\n",
    }
    # A quoted call is still a call.
    assert helper_areas(mac_helper) is None
    # The head drops the call; the base still has it.
    head_only = {".github/workflows/mac.yml": mac_helper[".github/workflows/mac.yml"]}
    assert helper_areas(head_only) == areas()
    assert helper_areas(head_only, base={**ROUTED_TREE, **mac_helper}) is None


def test_helper_named_by_product_source_or_a_native_test_fails_open() -> None:
    assert helper_areas({"Sources/Build.swift": "// scripts/ci/helper.py\n"}) is None
    native = (frozenset({"tests/test_helper.py"}), frozenset({"tests/test_helper.py"}))
    assert helper_areas({}, references=native) is None


def test_helper_nothing_names_is_unknown_and_fails_open() -> None:
    tree = {k: v for k, v in ROUTED_TREE.items() if not k.startswith("tests/")}
    why: list[str] = []
    assert module.ci_helper_areas("scripts/ci/helper.py", _helper_repo(tree), GUARD_ONLY_REFERENCES, why=why) is None
    assert why == ["nothing names helper"]


def test_repository_helpers_route_by_where_they_run() -> None:
    references = module.load_macos_job_test_references(ROOT)

    def route(path: str):
        return module.ci_helper_areas(path, ROOT, references, base_root=ROOT)

    # Runs only in the dispatch-only E2E lane.
    assert route("scripts/ci/preflight-e2e-screen-capture.py") == areas()
    # Runs only in its own workflow_run workflow; pr_runner_pool.py names it
    # in a docstring, which is not a call.
    assert route("scripts/ci/owned_pool_rescue.py") == areas()
    # compile admission runs it (and seed_derived_data.py, which imports
    # e2e_warm_derived_data.py): macOS, and the CLI lane that product feeds.
    assert route("scripts/ci/owned_build_state.py") == areas(macos=True, cli=True)
    assert route("scripts/ci/e2e_warm_derived_data.py") == areas(macos=True, cli=True)
    # Only the Release lane runs it.
    assert route("scripts/ci/reuse_release_product.py") == areas(macos=True, release_build=True)
    # run_python_test_lane.py imports it, and ci.yml's routing job runs that.
    assert route("scripts/ci/test_execution_registry.py") is None


def test_workflow_diff_failure_runs_all_areas() -> None:
    script = detect_step_script()
    with tempfile.TemporaryDirectory() as temp_dir:
        repo = Path(temp_dir)
        runner_temp = Path(temp_dir) / "runner-temp"
        output_path = repo / "github-output.txt"
        env = {
            **os.environ,
            "EVENT_NAME": "pull_request",
            "BASE_SHA": "missing-base",
            "HEAD_SHA": "missing-head",
            "MERGE_SHA": "missing-merge",
            "GITHUB_OUTPUT": str(output_path),
            # The trusted base router lays its checkout out under $RUNNER_TEMP,
            # and the step runs under `set -u`. GitHub sets it; a local run
            # does not, so without this the suite only passes inside CI.
            "RUNNER_TEMP": os.environ.get("RUNNER_TEMP") or str(runner_temp),
        }
        result = subprocess.run(
            ["bash", "-c", isolate_ci_tmp(script, repo)],
            cwd=repo,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
        )

        assert "Could not compute PR diff; running all CI areas." in result.stderr
        assert output_path.read_text(encoding="utf-8").splitlines() == [
            "macos=true",
            "web=true",
            "agent_session_web=true",
            "cli=true",
            "swift_packages=true",
            "release_build=true",
        ]


def run_detect_step_on_shallow_synthetic_merge(*, stale_event_base: bool) -> tuple[subprocess.CompletedProcess[str], list[str]]:
    script = detect_step_script()
    with tempfile.TemporaryDirectory() as temp_dir:
        root = Path(temp_dir)
        runner_temp = Path(temp_dir) / "runner-temp"
        source = root / "source"
        shallow = root / "shallow"
        source.mkdir()
        subprocess.run(["git", "init", "-q", "-b", "main"], cwd=source, check=True)
        subprocess.run(["git", "config", "user.email", "ci@example.test"], cwd=source, check=True)
        subprocess.run(["git", "config", "user.name", "CI Test"], cwd=source, check=True)

        helper_copy = source / "scripts" / "ci" / "detect_ci_change_areas.py"
        helper_copy.parent.mkdir(parents=True)
        helper_copy.write_text(HELPER.read_text(encoding="utf-8"), encoding="utf-8")
        (source / "common.txt").write_text("common\n", encoding="utf-8")
        subprocess.run(["git", "add", "."], cwd=source, check=True)
        subprocess.run(["git", "commit", "-q", "-m", "common"], cwd=source, check=True)
        common_sha = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=source, text=True).strip()
        subprocess.run(["git", "branch", "feature"], cwd=source, check=True)

        (source / "base-only.txt").write_text("base\n", encoding="utf-8")
        subprocess.run(["git", "add", "."], cwd=source, check=True)
        subprocess.run(["git", "commit", "-q", "-m", "base"], cwd=source, check=True)
        base_sha = subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=source, text=True
        ).strip()

        subprocess.run(["git", "checkout", "-q", "feature"], cwd=source, check=True)
        web_file = source / "web" / "app" / "page.tsx"
        web_file.parent.mkdir(parents=True)
        web_file.write_text("changed\n", encoding="utf-8")
        subprocess.run(["git", "add", "."], cwd=source, check=True)
        subprocess.run(["git", "commit", "-q", "-m", "feature"], cwd=source, check=True)
        head_sha = subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=source, text=True
        ).strip()

        subprocess.run(["git", "checkout", "-q", "main"], cwd=source, check=True)
        subprocess.run(
            ["git", "merge", "-q", "--no-ff", "feature", "-m", "synthetic merge"],
            cwd=source,
            check=True,
        )
        merge_sha = subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=source, text=True
        ).strip()

        subprocess.run(
            ["git", "clone", "-q", "--depth", "2", source.resolve().as_uri(), str(shallow)],
            check=True,
        )
        assert subprocess.run(
            ["git", "merge-base", base_sha, head_sha],
            cwd=shallow,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        ).returncode != 0

        output_path = shallow / "github-output.txt"
        result = subprocess.run(
            ["bash", "-c", isolate_ci_tmp(script, root)],
            cwd=shallow,
            env={
                **os.environ,
                "EVENT_NAME": "pull_request",
                # The event payload keeps the base the pull request was last
                # synced against. Once main moves on, that commit is outside
                # the depth-2 checkout of the synthetic merge.
                "BASE_SHA": common_sha if stale_event_base else base_sha,
                "HEAD_SHA": head_sha,
                "MERGE_SHA": merge_sha,
                "GITHUB_OUTPUT": str(output_path),
                # The trusted base router lays its checkout out under $RUNNER_TEMP,
                # and the step runs under `set -u`. GitHub sets it; a local run
                # does not, so without this the suite only passes inside CI.
                "RUNNER_TEMP": os.environ.get("RUNNER_TEMP") or str(runner_temp),
            },
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
        )
        return result, output_path.read_text(encoding="utf-8").splitlines()


def test_workflow_routes_from_shallow_synthetic_merge() -> None:
    result, outputs = run_detect_step_on_shallow_synthetic_merge(stale_event_base=False)

    assert "Could not compute PR diff" not in result.stderr
    assert outputs == ["macos=false", "web=true", "agent_session_web=false", "cli=false", "swift_packages=false", "release_build=false"]


def test_workflow_routes_when_main_moved_past_the_event_base() -> None:
    result, outputs = run_detect_step_on_shallow_synthetic_merge(stale_event_base=True)

    assert "Could not compute PR diff" not in result.stderr
    # base-only.txt landed on main after the event base. It is not part of the
    # pull request and must not route macOS.
    assert outputs == ["macos=false", "web=true", "agent_session_web=false", "cli=false", "swift_packages=false", "release_build=false"]


def test_workflow_empty_diff_skips_product_areas() -> None:
    result, outputs = run_detect_step_for_paths([])

    assert "PR diff is empty; skipping product-area CI." in result.stdout
    assert outputs == [
        "macos=false",
        "web=false",
        "agent_session_web=false",
        "cli=false",
        "swift_packages=false",
        "release_build=false",
    ]


def test_router_changes_run_everything() -> None:
    assert_areas(
        ["scripts/ci/detect_ci_change_areas.py"],
        macos=True,
        web=True,
        agent_session_web=True,
    )
    assert_areas(
        ["scripts/ci/subprocess.py"],
        macos=True,
        web=True,
        agent_session_web=True,
    )
    assert_areas(
        ["tests/test_ci_change_areas.py"],
        macos=False,
        web=False,
        agent_session_web=False,
    )


def test_ghosttykit_checksum_pin_runs_macos() -> None:
    assert_areas(["scripts/ghosttykit-checksums.txt"], macos=True, web=False)


def test_ghosttykit_checksum_pr_uses_release_guard_only() -> None:
    # The classifier remains macOS-aware for manual/full CI routing above, but
    # a checksum-only pull request takes the dedicated release-check path before
    # invoking the classifier so it cannot be hidden by a build cache.
    result, outputs = run_detect_step_for_paths(["scripts/ghosttykit-checksums.txt"])

    assert "GhosttyKit provenance-only PR; running the release guard." in result.stdout
    assert outputs == [
        "macos=false",
        "web=false",
        "agent_session_web=false",
        "cli=false",
        "swift_packages=false",
        "release_build=false",
    ]


def test_ghosttykit_guard_wiring_pr_stays_on_release_guard() -> None:
    result, outputs = run_detect_step_for_paths(
        [
            "ghostty",
            "scripts/download-prebuilt-ghosttykit.sh",
            "scripts/validate-xcframework-archive.py",
            "scripts/ghosttykit-checksums.txt",
            "tests/test_ci_ghosttykit_release_check.sh",
            "tests/test_ci_change_areas.py",
            ".github/workflows/ci.yml",
        ]
    )

    assert "GhosttyKit provenance-only PR; running the release guard." in result.stdout
    assert outputs == [
        "macos=false",
        "web=false",
        "agent_session_web=false",
        "cli=false",
        "swift_packages=false",
        "release_build=false",
    ]


def test_workflow_only_pr_uses_trusted_base_without_product_work() -> None:
    result, outputs = run_detect_step_for_paths([".github/workflows/ci.yml"])

    assert "CI routing-policy-only PR; skipping product-area CI." in result.stdout
    # This fixture replaces ci.yml with unreadable content, so the CLI lane's
    # call site cannot be compared and the lane stays routed.
    assert outputs == [
        "macos=false",
        "web=false",
        "agent_session_web=false",
        "cli=true",
        "swift_packages=false",
        "release_build=false",
    ]


# PR #14141's diff: the detector, its tests, and the detect step of ci.yml's
# `changes` job. Run 35956687867 queued `Claude wrapper regressions` and
# `remote-daemon-macos-tests` on the Mac pool for it.
ROUTING_POLICY_PATHS = [
    ".github/workflows/ci.yml",
    "scripts/ci/detect_ci_change_areas.py",
    "tests/test_ci_change_areas.py",
]
MAC_STANDALONE_OUTPUTS = ("claude_wrapper", "remote_daemon", "remote_daemon_native", "cli")


def route_ci_workflow_edit(
    head_workflow: str, extra_paths: tuple[str, ...] = (),
) -> dict[str, str]:
    """Every `changes` output for a diff that edits ci.yml to `head_workflow`."""
    head_files = {
        ".github/workflows/ci.yml": head_workflow,
        "scripts/ci/detect_ci_change_areas.py": HELPER.read_text(encoding="utf-8") + "# edited\n",
        "tests/test_ci_change_areas.py": "# edited\n",
    }
    _, outputs = run_detect_step_for_paths(
        [*ROUTING_POLICY_PATHS, *extra_paths], head_files=head_files, standalone=True,
    )
    values = dict(line.split("=", 1) for line in outputs)
    assert set(MAC_STANDALONE_OUTPUTS) <= values.keys(), outputs
    return values


def test_routing_policy_edits_skip_the_mac_standalone_lanes() -> None:
    real = CI_WORKFLOW.read_text(encoding="utf-8")
    for job in ("changes", "ci-status", "guards", "tests", "linux-preflight", "macos-admission-gate"):
        values = route_ci_workflow_edit(edit_job(real, job))
        for name in MAC_STANDALONE_OUTPUTS:
            assert values[name] == "false", (job, name, values)
        # The Linux-only browser lane keeps running for every ci.yml edit.
        assert values["browser"] == "true", (job, values)
        assert values["macos"] == "false", (job, values)


def test_ci_workflow_edits_to_a_mac_lane_caller_still_select_it() -> None:
    real = CI_WORKFLOW.read_text(encoding="utf-8")
    wrapper = route_ci_workflow_edit(edit_job(real, "claude-wrapper"))
    assert wrapper["claude_wrapper"] == "true", wrapper
    assert wrapper["remote_daemon"] == "false", wrapper

    daemon = route_ci_workflow_edit(edit_job(real, "remote-daemon"))
    assert daemon["remote_daemon"] == "true", daemon
    assert daemon["remote_daemon_native"] == "true", daemon
    assert daemon["claude_wrapper"] == "false", daemon

    cli = route_ci_workflow_edit(edit_job(real, "cli"))
    assert cli["cli"] == "true", cli
    assert cli["claude_wrapper"] == "false", cli

    # Triggers, env, permissions and concurrency reach every job.
    preamble = route_ci_workflow_edit(real.replace("\njobs:\n", "\n# edited\njobs:\n", 1))
    for name in MAC_STANDALONE_OUTPUTS:
        assert preamble[name] == "true", (name, preamble)


def test_mac_standalone_lane_inputs_still_select_their_lanes_beside_routing_edits() -> None:
    real = CI_WORKFLOW.read_text(encoding="utf-8")
    edited = edit_job(real, "changes")
    wrapper = route_ci_workflow_edit(edited, ("Resources/bin/cmux-claude-wrapper",))
    assert wrapper["claude_wrapper"] == "true", wrapper
    daemon = route_ci_workflow_edit(edited, (".github/workflows/remote-daemon.yml",))
    assert daemon["remote_daemon"] == "true", daemon
    assert daemon["remote_daemon_native"] == "true", daemon


def test_standalone_route_fails_open_without_a_readable_ci_workflow_base() -> None:
    script = workflow_job_step_script("changes", "Route standalone project workflows")
    real = CI_WORKFLOW.read_text(encoding="utf-8")
    for base in (None, "not a workflow\n"):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            routed = isolate_ci_tmp(script, root)
            (root / "cmux-ci-changed-files.txt").write_text(".github/workflows/ci.yml\n")
            if base is not None:
                (root / "cmux-ci-base-workflow.yml").write_text(base)
            workflow = root / ".github" / "workflows" / "ci.yml"
            workflow.parent.mkdir(parents=True)
            workflow.write_text(edit_job(real, "changes"))
            output = root / "output.txt"
            subprocess.run(["bash", "-c", routed], cwd=root, check=True, capture_output=True,
                           env={**os.environ, "GITHUB_OUTPUT": str(output)})
            assert output.read_text().splitlines() == [
                "claude_wrapper=true", "browser=true", "remote_daemon=true", "remote_daemon_native=true",
            ], base


CI_DIFF_BASE_WITH_CLI_LANE = """name: CI
on:
  pull_request:
env:
  FOO: "1"
jobs:
  changes:
    runs-on: ${{ vars.LINUX_RUNNER || 'blacksmith-4vcpu-ubuntu-2404' }}
    steps:
      - run: route
  workflow-guard-tests:
    runs-on: ${{ vars.LINUX_RUNNER || 'blacksmith-4vcpu-ubuntu-2404' }}
    steps:
      - run: guard
  cli:
    needs: [changes]
    if: ${{ needs.changes.outputs.cli == 'true' }}
    uses: ./.github/workflows/cli-pipe-regressions.yml
  ci-status:
    runs-on: ${{ vars.LINUX_RUNNER || 'blacksmith-4vcpu-ubuntu-2404' }}
    steps:
      - run: gate
"""


def test_ci_workflow_edit_to_the_cli_call_site_runs_the_cli_lane() -> None:
    # The router strips ci.yml before the trusted base classifies the diff, so
    # the detect step compares the `cli` job itself.
    for head in (
        CI_DIFF_BASE_WITH_CLI_LANE.replace(
            "uses: ./.github/workflows/cli-pipe-regressions.yml",
            "uses: ./.github/workflows/cli-pipe-regressions.yml\n    secrets: inherit",
        ),
        # Triggers and permissions before `jobs:` reach every called workflow.
        CI_DIFF_BASE_WITH_CLI_LANE.replace(
            "  pull_request:", "  pull_request:\n  merge_group:"
        ),
    ):
        result, outputs = run_detect_step_for_ci_workflow_edit(
            CI_DIFF_BASE_WITH_CLI_LANE, head
        )
        assert "CLI lane call site changed" in result.stdout, result.stdout
        assert outputs == [
            "macos=false",
            "web=false",
            "agent_session_web=false",
            "cli=true",
            "swift_packages=false",
            "release_build=false",
        ], outputs


def test_ci_workflow_edit_elsewhere_leaves_the_cli_lane_skipped() -> None:
    _, outputs = run_detect_step_for_ci_workflow_edit(
        CI_DIFF_BASE_WITH_CLI_LANE,
        CI_DIFF_BASE_WITH_CLI_LANE.replace("- run: guard", "- run: guard\n      - run: more"),
    )
    assert outputs == [
        "macos=false",
        "web=false",
        "agent_session_web=false",
        "cli=false",
        "swift_packages=false",
        "release_build=false",
    ]


def test_swift_warning_budget_runs_macos() -> None:
    assert_areas([".github/swift-warning-budget.tsv"], macos=True, web=False)


def test_cli_writes_github_outputs() -> None:
    with tempfile.TemporaryDirectory() as temp_dir:
        files_path = Path(temp_dir) / "files.txt"
        output_path = Path(temp_dir) / "github-output.txt"
        files_path.write_text("web/app/page.tsx\n", encoding="utf-8")

        result = subprocess.run(
            [
                sys.executable,
                str(HELPER),
                "--event-name",
                "pull_request",
                "--files-from",
                str(files_path),
                "--github-output",
                str(output_path),
            ],
            check=True,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

        assert "Resolved areas: macos=false web=true" in result.stdout
        assert output_path.read_text(encoding="utf-8").splitlines() == [
            "macos=false",
            "web=true",
            "agent_session_web=false",
            "cli=false",
            "swift_packages=false",
            "release_build=false",
        ]


def test_cli_empty_diff_runs_all_areas() -> None:
    with tempfile.TemporaryDirectory() as temp_dir:
        files_path = Path(temp_dir) / "files.txt"
        output_path = Path(temp_dir) / "github-output.txt"
        files_path.write_text("", encoding="utf-8")

        result = subprocess.run(
            [
                sys.executable,
                str(HELPER),
                "--event-name",
                "pull_request",
                "--files-from",
                str(files_path),
                "--github-output",
                str(output_path),
            ],
            check=True,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

        assert "PR diff is empty; running all CI areas." in result.stdout
        assert "Resolved areas: macos=true web=true agent_session_web=true" in result.stdout
        assert output_path.read_text(encoding="utf-8").splitlines() == [
            "macos=true",
            "web=true",
            "agent_session_web=true",
            "cli=true",
            "swift_packages=true",
            "release_build=true",
        ]


def test_non_pr_events_run_all_areas() -> None:
    result = subprocess.run(
        [sys.executable, str(HELPER), "--event-name", "workflow_dispatch"],
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )

    assert "Resolved areas: macos=true web=true agent_session_web=true" in result.stdout


def test_ci_status_job_accepts_skipped_routed_jobs() -> None:
    block = workflow_job_block("ci-status")

    for job_name in [
        "changes",
        "static-preflight",
        "guards",
        "browser",
        "remote-daemon",
        "cli",
        "web",
        "linux-preflight",
        "macos",
        "tests",
    ]:
        assert f"      - {job_name}" in block
    for job_name in MACOS_JOBS:
        assert f"      - {job_name}" not in block

    assert "if: ${{ always() }}" in block
    assert 'allowed = {"success", "skipped"}' in block


def test_required_tests_status_waits_for_platform_workflows() -> None:
    block = workflow_job_block("tests")

    assert "name: tests" in block
    for job_name in ("changes", "linux-preflight", "macos", "web"):
        assert f"      - {job_name}" in block
    for job_name in MACOS_JOBS:
        assert f"      - {job_name}" not in block
    assert "if: ${{ always() }}" in block
    assert 'macos_route not in {"true", "false"}' in block
    assert 'macos_result != "success"' in block
    assert 'web_result not in {"success", "skipped"}' in block



def test_web_workflow_pins_every_bun_setup_version() -> None:
    workflow = WEB_WORKFLOW.read_text(encoding="utf-8")
    action = "uses: oven-sh/setup-bun@0c5077e51419868618aeaa5fe8019c62421857d6"
    blocks = workflow.split(action)
    assert len(blocks) > 1
    for suffix in blocks[1:]:
        setup_tail = suffix.split("\n      - name: ", 1)[0]
        assert '          bun-version: "1.3.14"' in setup_tail


def test_every_setup_bun_step_declares_a_version() -> None:
    workflows = ROOT / ".github" / "workflows"
    action = "oven-sh/setup-bun@"
    found = 0

    for workflow_path in sorted(workflows.glob("*.yml")):
        lines = workflow_path.read_text(encoding="utf-8").splitlines()
        for index, line in enumerate(lines):
            if action not in line:
                continue
            found += 1
            tail = lines[index + 1:index + 7]
            assert any("bun-version:" in candidate for candidate in tail), (
                workflow_path.relative_to(ROOT),
                index + 1,
                "setup-bun must declare an explicit bun-version",
            )

    assert found >= 20, "setup-bun inventory unexpectedly disappeared"


def test_web_typecheck_retries_native_tsgo_abort() -> None:
    script = workflow_job_step_script("web-typecheck", "Typecheck", WEB_WORKFLOW)

    assert "bun run typecheck 2>&1 | tee \"$log\"" in script
    assert "grep -Fq 'Aborted (core dumped)' \"$log\"" in script
    assert "retrying once" in script
    assert "bun run test:instant" not in script


def test_ci_instant_navigation_owns_typecheck_once() -> None:
    config = (ROOT / "web/playwright.instant.config.ts").read_text()
    typecheck = workflow_job_block("web-typecheck", WEB_WORKFLOW)
    instant = workflow_job_block("web-instant-navigation", WEB_WORKFLOW)
    web_validation = workflow_job_block("tests", WEB_VALIDATION_WORKFLOW)
    assert "CMUX_INSTANT_SKIP_TYPECHECK" in config
    assert "process.env.CMUX_INSTANT_SKIP_TYPECHECK === \"1\"" in config
    package_json = (ROOT / "web/package.json").read_text()
    assert '"test:instant": "playwright test -c playwright.instant.config.ts"' in package_json
    assert '"test:instant:checked"' not in package_json

    # The only second invocation is the bounded retry owned by the independent
    # Typecheck job. The browser job must never own a typecheck.
    assert typecheck.count("bun run typecheck") == 2
    assert "bun run typecheck" not in instant
    assert "CMUX_INSTANT_CHECK_TYPECHECK" not in instant
    assert '          CMUX_INSTANT_SKIP_TYPECHECK: "1"' in instant
    assert "        run: bun run test:instant" in instant

    validation_typecheck = web_validation.index("      - run: bun run typecheck")
    validation_instant = web_validation.index("      - run: bun run test:instant")
    assert validation_typecheck < validation_instant
    assert web_validation[validation_typecheck:validation_instant].count("bun run typecheck") == 1
    validation_instant_step = web_validation[validation_instant:]
    assert "CMUX_INSTANT_CHECK_TYPECHECK" not in validation_instant_step
    assert '        env:\n          CMUX_INSTANT_SKIP_TYPECHECK: "1"' in validation_instant_step


def test_early_cli_smoke_checks_propagate_failure_and_require_this_build() -> None:
    block = workflow_job_block("macos-compile-admission", MACOS_WORKFLOW)
    early = block.index("      - name: Run early CLI binary smoke checks")
    package = block.index("      - name: Package compiled app-host test product")
    upload = block.index("      - name: Upload compiled app-host test product")
    assert early < package < upload

    script = workflow_job_step_script("macos-compile-admission", "Run early CLI binary smoke checks", MACOS_WORKFLOW)
    for failed_probe in ("version", "help", "config-doctor", None, "missing-binary"):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            derived = root / "derived with spaces"
            cli = derived / "Build/Products/Debug/cmux"
            cli.parent.mkdir(parents=True)
            if failed_probe != "missing-binary":
                cli.write_text("#!/bin/sh\nexit 0\n")
                cli.chmod(0o755)
            (root / "tests").mkdir()
            trace = root / "probes.txt"
            for probe, filename in (("version", "test_cli_version_memory_guard.py"),
                                    ("help", "test_cli_contract_help.py"),
                                    ("config-doctor", "test_cli_config_doctor.py")):
                (root / "tests" / filename).write_text(
                    "import os,pathlib\n"
                    + "assert os.environ['CMUX_CLI_BIN'] == " + repr(str(cli)) + "\n"
                    + "with open(" + repr(str(trace)) + ", 'a') as out: out.write(" + repr(probe + "\n") + ")\n"
                    + "raise SystemExit(" + ("23" if probe == failed_probe else "0") + ")\n"
                )
            result = subprocess.run(["bash", "-e", "-o", "pipefail", "-c", script], cwd=root,
                env={**os.environ, "CMUX_COMPILE_ADMISSION_DERIVED_DATA": str(derived)},
                capture_output=True, text=True)
            invoked = trace.read_text().splitlines() if trace.exists() else []
            if failed_probe == "missing-binary":
                assert result.returncode != 0 and not invoked
            elif failed_probe == "version":
                assert result.returncode == 23 and invoked == ["version"]
            elif failed_probe == "help":
                assert result.returncode == 23 and invoked == ["version", "help"]
            elif failed_probe == "config-doctor":
                assert result.returncode == 23 and invoked == ["version", "help", "config-doctor"]
            else:
                assert result.returncode == 0 and invoked == ["version", "help", "config-doctor"]


def test_macos_workflow_call_starts_after_cheap_static_gate() -> None:
    caller = workflow_job_block("macos")

    assert "      - changes" in caller
    assert "      - static-preflight" in caller
    assert "      - linux-preflight" not in caller
    assert "uses: ./.github/workflows/ci-macos.yml" in caller
    assert "needs.changes.outputs.macos != 'false'" in caller
    assert (
        "needs.changes.outputs.full_suite == 'true' "
        "|| needs.changes.outputs.unit_suite == 'true' "
        "|| needs.changes.outputs.cli == 'true' "
        "|| needs.changes.outputs.compile_admitted != 'true'"
    ) in caller
    for route in (
        "macos",
        "cli",
        "full_suite",
        "unit_suite",
        "compile_admitted",
        "release_build",
        "source_parent1",
    ):
        assert f"      {route}: ${{{{ needs.changes.outputs.{route} }}}}" in caller
    assert "      actions: read" in caller
    assert "      contents: read" in caller
    assert "      pull-requests: read" in caller

    assert "needs.static-preflight.result == 'success'" in caller
    assert "needs.linux-preflight.result" not in caller

    admission = workflow_job_block("macos-compile-admission", MACOS_WORKFLOW)
    assert "needs.changes" not in admission
    assert "needs.linux-preflight" not in admission
    assert "inputs.source_parent1" in admission


def _ci_jobs() -> dict:
    return yaml.safe_load(CI_WORKFLOW.read_text(encoding="utf-8"))["jobs"]


def _job_needs(jobs: dict, key: str) -> list[str]:
    needs = jobs[key].get("needs", [])
    return [needs] if isinstance(needs, str) else list(needs)


def _job_runs_only_on_linux(job: dict) -> bool:
    uses = job.get("uses")
    if uses:
        called = yaml.safe_load((ROOT / uses.removeprefix("./")).read_text(encoding="utf-8"))
        return all(_job_runs_only_on_linux(inner) for inner in called["jobs"].values())
    runs_on = str(job.get("runs-on", ""))
    return "macos" not in runs_on.lower() and ("ubuntu" in runs_on or "LINUX_RUNNER" in runs_on)


def test_macos_admission_gate_needs_every_fast_linux_only_job() -> None:
    jobs = _ci_jobs()
    entry = {"changes", "static-preflight"}
    # The gate is derived, not hand-picked: every job that starts right after
    # the entry jobs and runs only on Linux. A job with any Mac runner is
    # already billed and slow, so waiting on it would save nothing.
    expected = entry | {
        key
        for key in jobs
        if key not in entry | {"macos-admission-gate"}
        and set(_job_needs(jobs, key)) <= entry
        and _job_runs_only_on_linux(jobs[key])
    }
    assert set(_job_needs(jobs, "macos-admission-gate")) == expected
    assert {"guards", "web", "suite-coverage"} <= expected
    assert not {"claude-wrapper", "remote-daemon", "cli", "linux-preflight"} & expected

    def depends_on_macos(key: str) -> bool:
        return any(need == "macos" or depends_on_macos(need) for need in _job_needs(jobs, key))

    assert not any(depends_on_macos(need) for need in expected)


def test_only_mac_work_waits_for_static_preflight() -> None:
    jobs = _ci_jobs()
    # Linux-only jobs start beside the static stage instead of queueing behind
    # it: waiting added its whole duration to every pull request's critical
    # path to save a few Linux minutes on a lint failure.
    for key in ("guards", "ghosttykit-release-check", "browser", "web"):
        assert _job_runs_only_on_linux(jobs[key]), key
        assert _job_needs(jobs, key) == ["changes"], key
    # Every job with a Mac runner still waits, so a lint failure bills no
    # Mac minutes.
    mac_jobs = {key for key in jobs if not _job_runs_only_on_linux(jobs[key])}
    assert {"claude-wrapper", "remote-daemon", "cli", "macos"} <= mac_jobs
    for key in mac_jobs:
        assert "static-preflight" in _job_needs(jobs, key), key
    # A red static stage still fails the run's verdicts and declines macOS.
    for key in ("macos-admission-gate", "linux-preflight", "ci-status"):
        assert "static-preflight" in _job_needs(jobs, key), key


def test_macos_admission_gate_uses_job_results_not_polling() -> None:
    gate = workflow_job_block("macos-admission-gate")
    assert "!cancelled()" in gate
    assert "github.event_name == 'pull_request'" in gate
    assert "needs.changes.result == 'success'" in gate
    # A red static check already skips `macos`; the gate must not add a
    # second red job for it.
    assert "needs.static-preflight.result == 'success'" in gate
    assert "needs.changes.outputs.macos != 'false'" in gate
    assert "macos" not in gate.split("runs-on:", 1)[1].split("\n", 1)[0]
    # No API budget: GITHUB_TOKEN requests are shared by every workflow.
    assert "    permissions: {}" in gate
    step = workflow_job_step_script("macos-admission-gate", "Decline macOS after a failed Linux gate")
    for polling in ("gh api", "sleep", "curl"):
        assert polling not in step
    workflow_text = CI_WORKFLOW.read_text(encoding="utf-8")
    assert "CI_MACOS_ADMISSION_DEBOUNCE_SECONDS" not in workflow_text
    assert "macos-debounce" not in workflow_text

    caller = workflow_job_block("macos")
    # Compile admission is the run's longest path, so it starts beside the
    # fast Linux jobs; the gate holds back the product's consumers instead.
    assert "      - macos-admission-gate" not in caller
    assert "needs.macos-admission-gate" not in caller
    # `macos` keeps its own static gate: a failed static check skips the gate
    # and must still skip macOS.
    assert "needs.static-preflight.result == 'success'" in caller
    # macOS waits for no Linux verdict beyond the static stage.
    assert "needs.linux-preflight" not in caller
    assert "      - macos-admission-gate" in workflow_job_block("ci-status")


CONSUMER_GATE_STEP = "Hold consumers behind the fast Linux gate"


def test_compile_admission_holds_every_product_consumer_behind_the_gate() -> None:
    admission = workflow_job_block("macos-compile-admission", MACOS_WORKFLOW)
    step = workflow_step_block_in(MACOS_WORKFLOW, "macos-compile-admission", CONSUMER_GATE_STEP)
    # It reads the job the caller names, once: no loop and no sleep.
    assert 'GATE_JOB: "macOS admission gate"' in step
    assert "name: macOS admission gate" in workflow_job_block("macos-admission-gate")
    script = workflow_job_step_script("macos-compile-admission", CONSUMER_GATE_STEP, MACOS_WORKFLOW)
    for polling in ("sleep", "while ", "for attempt", "range("):
        assert polling not in script
    # The gate only judges a pull request's first attempt; a re-run is asking
    # for the Mac results.
    assert "github.event_name == 'pull_request' && github.run_attempt == 1" in step
    # The product is published and a changed-suites run has tested it before
    # the decision, so a declined job proves what a passed one does and the
    # reuse lookups can accept it.
    order = [line.removeprefix("      - name: ") for line in admission.splitlines() if line.startswith("      - name: ")]
    gate_at = order.index(CONSUMER_GATE_STEP)
    assert order.index("Seed node-local compiled product cache") < gate_at
    assert order.index("Run changed app-host suites") < gate_at
    # No status function: the implicit success() is what makes a failure
    # here mean every earlier step passed.
    assert "always()" not in step and "failure()" not in step
    # A decline is not a test failure: it collects no app-host diagnostics.
    for name in ("Collect app-host failure diagnostics", "Upload app-host failure diagnostics"):
        diagnostics = workflow_step_block_in(MACOS_WORKFLOW, "macos-compile-admission", name)
        assert "steps.consumer-gate.outcome != 'failure'" in diagnostics, name
    # Every Mac job that runs the product needs admission, so a decline
    # skips it.
    jobs = yaml.safe_load(MACOS_WORKFLOW.read_text(encoding="utf-8"))["jobs"]
    for key in ("app-host-unit-tests", "cli-product-tests", "tests-build-and-lag", "release-admission", "release-build"):
        assert "macos-compile-admission" in _job_needs(jobs, key), key
        assert "needs.macos-compile-admission.result == 'success'" in jobs[key]["if"], key


def workflow_step_block_in(workflow_path: Path, job_name: str, step_name: str) -> str:
    lines = workflow_job_block(job_name, workflow_path).splitlines()
    start = lines.index(f"      - name: {step_name}")
    body = [lines[start]]
    for line in lines[start + 1 :]:
        if line.startswith("      - ") or (line.strip() and not line.startswith("        ")):
            break
        body.append(line)
    return "\n".join(body)


def run_consumer_gate(jobs: object, *, status: int = 200) -> subprocess.CompletedProcess:
    import http.server
    import threading

    body = json.dumps(jobs).encode()
    requests: list[str] = []

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self) -> None:  # noqa: N802
            requests.append(self.path)
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args: object) -> None:
            pass

    server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        script = workflow_job_step_script("macos-compile-admission", CONSUMER_GATE_STEP, MACOS_WORKFLOW)
        result = subprocess.run(
            ["bash", "-c", script],
            env={
                **os.environ,
                "API_URL": f"http://127.0.0.1:{server.server_port}",
                "GH_TOKEN": "token",
                "REPOSITORY": "manaflow-ai/cmux",
                "RUN_ID": "42",
                "GATE_JOB": "macOS admission gate",
            },
            capture_output=True,
            text=True,
            check=False,
        )
    finally:
        server.shutdown()
        server.server_close()
    assert requests == ["/repos/manaflow-ai/cmux/actions/runs/42/jobs?filter=latest&per_page=100"]
    return result


def _gate_job(status: str, conclusion: object) -> dict:
    return {"jobs": [
        {"name": "changes", "status": "completed", "conclusion": "success"},
        {"name": "macOS admission gate", "status": status, "conclusion": conclusion},
    ]}


def test_consumer_gate_fails_admission_when_the_gate_declined() -> None:
    result = run_consumer_gate(_gate_job("completed", "failure"))
    assert result.returncode == 1
    assert "Not admitting macOS consumers" in result.stdout


def test_consumer_gate_admits_whenever_it_cannot_prove_a_decline() -> None:
    for label, jobs, status in (
        ("passed", _gate_job("completed", "success"), 200),
        ("skipped", _gate_job("completed", "skipped"), 200),
        # Still deciding: ci-status fails the run on a failed Linux job anyway.
        ("in progress", _gate_job("in_progress", None), 200),
        ("absent", {"jobs": [{"name": "changes", "status": "completed", "conclusion": "success"}]}, 200),
        ("unreadable", {"message": "Server Error"}, 500),
    ):
        result = run_consumer_gate(jobs, status=status)
        assert result.returncode == 0, f"{label}: {result.stdout}{result.stderr}"
        assert "Not admitting" not in result.stdout, label


def run_macos_admission_gate(needs: dict, *, attempt: str = "1") -> subprocess.CompletedProcess:
    script = workflow_job_step_script("macos-admission-gate", "Decline macOS after a failed Linux gate")
    return subprocess.run(
        ["bash", "-c", script],
        env={**os.environ, "GITHUB_RUN_ATTEMPT": attempt, "GATE_NEEDS": json.dumps(needs)},
        capture_output=True,
        text=True,
        check=False,
    )


def _gate_needs(**overrides: str) -> dict:
    results = {
        "changes": "success",
        "static-preflight": "success",
        "suite-coverage": "skipped",
        "ghosttykit-release-check": "success",
        "browser": "skipped",
        "guards": "success",
        "web": "success",
    }
    results.update(overrides)
    return {name: {"result": result, "outputs": {}} for name, result in results.items()}


def test_macos_admission_gate_declines_a_failed_linux_job() -> None:
    declined = run_macos_admission_gate(_gate_needs(guards="failure"))
    # Declining by failing is load-bearing: "Re-run failed jobs" then re-runs
    # the gate and compile admission, and a re-run attempt admits macOS.
    assert declined.returncode == 1
    assert "guards already failed" in declined.stdout + declined.stderr


def test_macos_admission_gate_admits_whenever_it_cannot_prove_a_failure() -> None:
    for label, needs, attempt in (
        ("all passed or skipped", _gate_needs(), "1"),
        # A cancelled job means the run is going away; it is not a verdict.
        ("cancelled only", _gate_needs(web="cancelled"), "1"),
        # A re-run is asking for the results this would withhold.
        ("re-run attempt", _gate_needs(guards="failure"), "2"),
    ):
        result = run_macos_admission_gate(needs, attempt=attempt)
        assert result.returncode == 0, f"{label}: {result.stdout}{result.stderr}"
        assert "already failed" not in result.stdout + result.stderr, label


def run_tests_gate(needs: dict) -> subprocess.CompletedProcess:
    script = workflow_job_step_script("tests", "Check platform workflow routing")
    body = script.split("python3 - <<'PY'\n", 1)[1].rsplit("\nPY", 1)[0]
    return subprocess.run(
        [sys.executable, "-c", textwrap.dedent(body)],
        env={**os.environ, "TESTS_NEEDS": json.dumps(needs)},
        capture_output=True,
        text=True,
        check=False,
    )


def tests_gate_needs(
    macos: str = "true",
    macos_result: str = "success",
    web_result: str = "skipped",
    full_suite: str = "true",
    compile_admitted: str = "false",
) -> dict:
    return {
        "changes": {
            "result": "success",
            "outputs": {
                "macos": macos,
                "full_suite": full_suite,
                "compile_admitted": compile_admitted,
            },
        },
        "linux-preflight": {"result": "success"},
        "macos": {"result": macos_result},
        "web": {"result": web_result},
    }


def test_platform_workflow_results_gate_tests_status() -> None:
    assert run_tests_gate(tests_gate_needs()).returncode == 0
    assert run_tests_gate(tests_gate_needs(macos_result="failure")).returncode == 1
    assert run_tests_gate(tests_gate_needs(macos_result="skipped")).returncode == 1
    assert run_tests_gate(tests_gate_needs(macos="false", macos_result="skipped")).returncode == 0
    assert run_tests_gate(
        tests_gate_needs(
            macos_result="skipped",
            full_suite="false",
            compile_admitted="true",
        )
    ).returncode == 0
    assert run_tests_gate(tests_gate_needs(web_result="failure")).returncode == 1


def test_linux_failure_still_blocks_tests_after_macos_succeeds() -> None:
    for outcome in ("failure", "cancelled", "skipped"):
        needs = tests_gate_needs(macos_result="success")
        needs["linux-preflight"]["result"] = outcome
        result = run_tests_gate(needs)
        assert result.returncode != 0, outcome
        assert f"linux preflight did not pass: {outcome}" in result.stderr


def test_macos_status_accepts_compile_only_prior_admission_skip() -> None:
    inputs = {
        "macos": "true",
        "full_suite": "false",
        "compile_admitted": "true",
        "release_build": "false",
        "source_parent1": "parent",
    }
    skipped = dict.fromkeys(MACOS_JOBS, "skipped")
    assert run_macos_status(inputs=inputs, results=skipped).returncode == 0

    inputs["compile_admitted"] = "false"
    assert run_macos_status(inputs=inputs, results=skipped).returncode != 0


def test_build_input_fingerprint_tracks_product_identity_not_ci_orchestration() -> None:
    sys.path.insert(0, str(ROOT / "scripts/ci"))
    from build_input_fingerprint import fingerprint
    import product_input_identity as product_inputs

    workflow = MACOS_WORKFLOW.read_text(encoding="utf-8")
    admission = product_inputs._job_block(
        workflow,
        product_inputs.MACOS_ADMISSION_JOB,
    )

    def tree(**files: str) -> list[str]:
        return [
            f"100644 blob {object_id}\t{path}"
            for path, object_id in files.items()
        ]

    base_tree = tree(
        **{
            "Sources/App.swift": "1" * 40,
            "scripts/ci/compile-app-host-test-product.sh": "2" * 40,
            "scripts/ci/pr_runner_pool.py": "3" * 40,
            ".github/workflows/ci.yml": "4" * 40,
            "tests/test_x.py": "5" * 40,
        }
    )
    base = fingerprint(base_tree, workflow, ["xcode=/Applications/Xcode.app"])

    # Changing CI orchestration still exercises CI, but it does not make the
    # already-compiled app-host product stale.
    orchestration_workflow = workflow
    metrics_admission = admission.replace(
        "      - name: Record compiled-product reuse metrics\n",
        "      - name: Record compiled-product reuse metrics\n"
        "        # metrics-only edit\n",
        1,
    )
    assert metrics_admission != admission
    orchestration_workflow = orchestration_workflow.replace(
        admission,
        metrics_admission,
        1,
    )
    orchestration_tree = tree(
        **{
            "Sources/App.swift": "1" * 40,
            "scripts/ci/compile-app-host-test-product.sh": "2" * 40,
            "scripts/ci/pr_runner_pool.py": "6" * 40,
            ".github/workflows/ci.yml": "7" * 40,
            "tests/test_x.py": "8" * 40,
        }
    )
    assert (
        fingerprint(
            orchestration_tree,
            orchestration_workflow,
            ["xcode=/Applications/Xcode.app"],
        )
        == base
    )

    changed_source = list(base_tree)
    changed_source[0] = (
        f"100644 blob {'9' * 40}\tSources/App.swift"
    )
    assert (
        fingerprint(
            changed_source,
            workflow,
            ["xcode=/Applications/Xcode.app"],
        )
        != base
    )

    changed_helper = list(base_tree)
    changed_helper[1] = (
        f"100644 blob {'a' * 40}\t"
        "scripts/ci/compile-app-host-test-product.sh"
    )
    assert (
        fingerprint(
            changed_helper,
            workflow,
            ["xcode=/Applications/Xcode.app"],
        )
        != base
    )

    changed_admission = admission.replace(
        '      CMUX_SKIP_ZIG_BUILD: "1"\n',
        '      CMUX_SKIP_ZIG_BUILD: "0"\n',
        1,
    )
    assert changed_admission != admission
    changed_recipe = workflow.replace(
        admission,
        changed_admission,
        1,
    )
    assert changed_recipe != workflow
    assert (
        fingerprint(
            base_tree,
            changed_recipe,
            ["xcode=/Applications/Xcode.app"],
        )
        != base
    )

    assert (
        fingerprint(
            base_tree,
            workflow,
            ["xcode=/Applications/Xcode_2.app"],
        )
        != base
    )


def admission_api(runs: list[dict], artifacts: dict[int, list[str]], jobs: dict[int, list[dict]], branch: str = "feature"):
    """Fake GitHub API: `artifacts` lists the artifact names each run holds."""
    from urllib.parse import parse_qs, urlsplit

    def api(path: str) -> dict:
        url = urlsplit(path)
        query = parse_qs(url.query, strict_parsing=True)
        if url.path.endswith("/workflows/ci.yml/runs"):
            assert query["event"] == ["pull_request"] and query["branch"] == [branch], path
            return {"workflow_runs": runs}
        run_id = int(url.path.split("/runs/")[1].split("/")[0])
        if url.path.endswith("/artifacts"):
            (name,) = query["name"]
            return {"total_count": artifacts.get(run_id, []).count(name)}
        assert query["filter"] == ["all"], path
        page = int(query.get("page", ["1"])[0])
        per_page = int(query["per_page"][0])
        run_jobs = jobs.get(run_id, [])
        return {"jobs": run_jobs[(page - 1) * per_page:page * per_page]}

    return api


def admission_run(run_id: int, owner: str = "manaflow-ai/cmux") -> dict:
    return {"id": run_id, "head_repository": {"full_name": owner}, "html_url": f"https://example/{run_id}"}


# ci.yml reaches the admission job through ci-macos.yml, so GitHub reports it
# as "<caller job> / <job name>". The fixture must use the composed name the
# API actually returns; using the bare name hid a regression in which both
# reuse lookups silently matched nothing.
ADMISSION_JOB_API_NAME = "macos / macOS compile admission"


def admission_job(conclusion: str, run_attempt: int = 1) -> dict:
    return {"name": ADMISSION_JOB_API_NAME, "conclusion": conclusion, "run_attempt": run_attempt}


def test_only_an_in_org_run_with_a_passed_admission_counts_as_admitted() -> None:
    sys.path.insert(0, str(ROOT / "scripts/ci"))
    from find_admitted_build import admitted_run, artifact_name

    repo = "manaflow-ai/cmux"
    api_for, run = admission_api, admission_run
    inputs = [artifact_name("abc", 1)]
    passed = [admission_job("success")]
    failed = [admission_job("failure")]

    def find(api) -> str | None:
        return admitted_run(api, repo, "feature", "abc", current_run_id=9)

    assert find(api_for([run(9), run(8)], {8: inputs, 9: inputs}, {8: passed, 9: passed})) == "https://example/8"
    assert find(api_for([run(9)], {9: inputs}, {9: passed})) is None, "the current run cannot admit itself"
    assert find(api_for([run(8)], {8: [artifact_name("other", 1)]}, {8: passed})) is None, "different build inputs"
    assert find(api_for([run(8)], {8: inputs}, {8: failed})) is None, "admission did not pass"
    assert find(api_for([run(8)], {8: inputs}, {8: []})) is None, "admission was skipped or never ran"
    assert find(api_for([run(8, owner="someone/cmux")], {8: inputs}, {8: passed})) is None, "a fork's run is not trusted"

    def broken(_path: str) -> dict:
        raise subprocess.CalledProcessError(1, "gh")

    assert find(broken) is None, "an API failure means compile"
    assert find(lambda _path: []) is None, "an unexpected payload means compile"


def test_admission_counts_only_for_the_inputs_fingerprinted_in_the_same_attempt() -> None:
    sys.path.insert(0, str(ROOT / "scripts/ci"))
    from find_admitted_build import admitted_run, artifact_name

    def find(fingerprint: str, artifacts: list[str], jobs: list[dict]) -> str | None:
        api = admission_api([admission_run(8)], {8: artifacts}, {8: jobs})
        return admitted_run(api, "manaflow-ai/cmux", "feature", fingerprint, current_run_id=9)

    # Attempt 1 compiled "old" and passed. The rerun fingerprinted "new" (the
    # selected Xcode moved) and failed, so nothing ever compiled "new".
    artifacts = [artifact_name("old", 1), artifact_name("new", 2)]
    jobs = [admission_job("success", run_attempt=1), admission_job("failure", run_attempt=2)]
    assert find("new", artifacts, jobs) is None
    assert find("old", artifacts, jobs) == "https://example/8"

    # The reverse: only the rerun passed, so only its inputs are admitted.
    jobs = [admission_job("failure", run_attempt=1), admission_job("success", run_attempt=2)]
    assert find("old", artifacts, jobs) is None
    assert find("new", artifacts, jobs) == "https://example/8"

    # A rerun of failed jobs alone reuses the first attempt's fingerprint, which
    # no longer pins the toolchain the rerun compiled with.
    assert find("old", [artifact_name("old", 1)], jobs) is None


def test_a_gate_declined_admission_still_admits_its_inputs() -> None:
    sys.path.insert(0, str(ROOT / "scripts/ci"))
    import find_admitted_build
    import reuse_app_host_products
    from find_admitted_build import admitted_run, artifact_name

    # The fast Linux gate failed compile admission after it published, so the
    # push that fixes the Linux job reuses the product instead of compiling.
    assert find_admitted_build.GATE_DECLINE_STEP == reuse_app_host_products.GATE_DECLINE_STEP
    declined = {
        **admission_job("failure"),
        "steps": [
            {"name": "Compile app-host test product", "conclusion": "success"},
            {"name": find_admitted_build.GATE_DECLINE_STEP, "conclusion": "failure"},
        ],
    }
    api = admission_api([admission_run(8)], {8: [artifact_name("abc", 1)]}, {8: [declined]})
    assert admitted_run(api, "manaflow-ai/cmux", "feature", "abc", current_run_id=9) == "https://example/8"
    compile_failed = {**declined, "steps": [{"name": "Compile app-host test product", "conclusion": "failure"}]}
    api = admission_api([admission_run(8)], {8: [artifact_name("abc", 1)]}, {8: [compile_failed]})
    assert admitted_run(api, "manaflow-ai/cmux", "feature", "abc", current_run_id=9) is None


def test_admission_lookup_finds_matching_attempt_beyond_the_first_jobs_page() -> None:
    original_path = sys.path.copy()
    try:
        sys.path.insert(0, str(ROOT / "scripts/ci"))
        from find_admitted_build import admitted_run, artifact_name
    finally:
        sys.path[:] = original_path

    # An earlier attempt's fan-out fills the first page. Only the later
    # attempt compiled the desired inputs successfully.
    earlier_jobs = [admission_job("failure")] * 100
    jobs = earlier_jobs + [admission_job("success", run_attempt=2)]
    for fingerprint, expected in (("new", "https://example/8"), ("old", None)):
        api = admission_api(
            [admission_run(8)],
            {8: [artifact_name("old", 1), artifact_name("new", 2)]},
            {8: jobs},
        )
        assert admitted_run(api, "manaflow-ai/cmux", "feature", fingerprint, current_run_id=9) == expected


def test_admission_lookup_falls_back_when_a_later_jobs_page_fails() -> None:
    original_path = sys.path.copy()
    try:
        sys.path.insert(0, str(ROOT / "scripts/ci"))
        from find_admitted_build import admitted_run, artifact_name
        from urllib.parse import parse_qs, urlsplit
    finally:
        sys.path[:] = original_path

    base_api = admission_api(
        [admission_run(8)], {8: [artifact_name("abc", 2)]},
        {8: [admission_job("failure")] * 100 + [admission_job("success", run_attempt=2)]},
    )
    pages = []

    def api(path: str) -> dict:
        url = urlsplit(path)
        if url.path.endswith("/jobs"):
            page = int(parse_qs(url.query).get("page", ["1"])[0])
            pages.append(page)
            if page == 2:
                raise subprocess.CalledProcessError(1, "gh")
        return base_api(path)

    assert admitted_run(api, "manaflow-ai/cmux", "feature", "abc", current_run_id=9) is None
    assert pages == [1, 2], "the lookup must reach the failed page before falling back"


def test_admission_lookup_bounds_job_pages_and_stops_after_a_match() -> None:
    original_path = sys.path.copy()
    try:
        sys.path.insert(0, str(ROOT / "scripts/ci"))
        from find_admitted_build import admitted_run, artifact_name
        from urllib.parse import parse_qs, urlsplit
    finally:
        sys.path[:] = original_path

    # Cap lookup work even when a run has many attempts. Missing an old
    # admission is safe: this candidate compiles normally instead.
    for jobs, expected, expected_pages in (
        ([admission_job("failure")] * 1000, None, [1, 2, 3]),
        ([admission_job("success")] * 100, "https://example/8", [1]),
        ([], None, [1]),
    ):
        base_api = admission_api([admission_run(8)], {8: [artifact_name("abc", 1)]}, {8: jobs})
        pages = []

        def api(path: str) -> dict:
            url = urlsplit(path)
            if url.path.endswith("/jobs"):
                pages.append(int(parse_qs(url.query).get("page", ["1"])[0]))
            return base_api(path)

        assert admitted_run(api, "manaflow-ai/cmux", "feature", "abc", current_run_id=9) == expected
        assert pages == expected_pages


def test_admission_lookup_sends_reserved_branch_characters_literally() -> None:
    sys.path.insert(0, str(ROOT / "scripts/ci"))
    from find_admitted_build import admitted_run, artifact_name

    for branch in ("feature/c++", "fix/a&b", "fix/a=b#c d", "wip/100%"):
        api = admission_api([admission_run(8)], {8: [artifact_name("abc", 1)]}, {8: [admission_job("success")]}, branch=branch)
        assert admitted_run(api, "manaflow-ai/cmux", branch, "abc", current_run_id=9) == "https://example/8", branch


def admission_helper():
    original_path = sys.path.copy()
    try:
        sys.path.insert(0, str(ROOT / "scripts/ci"))
        return importlib.import_module("find_admitted_build")
    finally:
        sys.path[:] = original_path


def test_admission_api_limits_each_request_to_the_remaining_budget() -> None:
    from unittest.mock import patch
    admission = admission_helper()

    for remaining, expected in ((30, 10), (3, 3)):
        with patch.object(admission.time, "monotonic", return_value=100), \
                patch.object(admission.subprocess, "check_output", return_value="{}") as request:
            assert admission.gh_api("example", deadline=100 + remaining) == {}
            assert request.call_args.kwargs["timeout"] == expected


def test_admission_api_never_starts_after_the_overall_deadline() -> None:
    from unittest.mock import patch
    admission = admission_helper()

    with patch.object(admission.time, "monotonic", return_value=100), \
            patch.object(admission.subprocess, "check_output") as request:
        try:
            admission.gh_api("example", deadline=100)
        except TimeoutError:
            pass
        else:
            raise AssertionError("an expired lookup must stop before starting gh")
        request.assert_not_called()


def test_admission_api_discards_a_response_arriving_after_the_deadline() -> None:
    from unittest.mock import patch
    admission = admission_helper()

    with patch.object(admission.time, "monotonic", side_effect=[100, 130]), \
            patch.object(admission.subprocess, "check_output", return_value="{}"):
        try:
            admission.gh_api("example", deadline=130)
        except TimeoutError:
            pass
        else:
            raise AssertionError("a late response must not admit a compile")


def test_admission_lookup_timeout_or_missing_cli_falls_back_to_compiling() -> None:
    from unittest.mock import patch
    admission = admission_helper()

    for error in (subprocess.TimeoutExpired(["gh", "api"], 10), FileNotFoundError("gh")):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "output"
            with patch.object(admission.subprocess, "check_output", side_effect=error):
                result = admission.main([
                    "--repository", "manaflow-ai/cmux", "--branch", "feature",
                    "--fingerprint", "abc", "--current-run-id", "9",
                    "--github-output", str(output),
                ])
            assert result == 0
            assert output.read_text() == "compile_admitted=false\n"


def test_admission_lookup_shares_one_deadline_across_successive_requests() -> None:
    from unittest.mock import patch
    admission = admission_helper()

    base_api = admission_api(
        [admission_run(8)], {8: [admission.artifact_name("abc", 2)]},
        {8: [admission_job("failure")] * 100 + [admission_job("success", run_attempt=2)]},
    )
    clock = [100.0]
    budgets = []

    def request(command, *, text, timeout):
        budgets.append(timeout)
        if timeout < 9:
            clock[0] += timeout
            raise subprocess.TimeoutExpired(command, timeout)
        clock[0] += 9
        return json.dumps(base_api(command[2]))

    with tempfile.TemporaryDirectory() as temporary:
        output = Path(temporary) / "output"
        with patch.object(admission.time, "monotonic", side_effect=lambda: clock[0]), \
                patch.object(admission.subprocess, "check_output", side_effect=request):
            assert admission.main([
                "--repository", "manaflow-ai/cmux", "--branch", "feature",
                "--fingerprint", "abc", "--current-run-id", "9",
                "--github-output", str(output),
            ]) == 0
        assert budgets == [10, 10, 10, 3], budgets
        assert clock[0] == 130
        assert output.read_text() == "compile_admitted=false\n"


def workflow_step_block(job_name: str, step_name: str) -> str:
    lines = workflow_job_block(job_name).splitlines()
    start = lines.index(f"      - name: {step_name}")
    body = [lines[start]]
    for line in lines[start + 1 :]:
        if line.startswith("      - ") or (line.strip() and not line.startswith("        ")):
            break
        body.append(line)
    return "\n".join(body)


def test_build_input_reuse_steps_never_fail_the_changes_job() -> None:
    # Reuse is an optimization. A step that breaks leaves compile_admitted unset,
    # which compiles; it must not take routing down with it.
    for step in (
        "Fingerprint the build inputs",
        "Skip compile when build inputs are unchanged",
        "Publish the build-input fingerprint",
        "Look for an earlier run that compiled these inputs",
    ):
        assert "        continue-on-error: true" in workflow_step_block("changes", step).splitlines(), step


def test_unchanged_build_inputs_skip_mac_compile_before_runner_allocation() -> None:
    changes = workflow_job_block("changes")
    assert (
        "compile_admitted: ${{ steps.unchanged_inputs.outputs.compile_admitted == 'true' && 'true' || steps.admitted.outputs.compile_admitted }}"
        in changes
    )
    assert (
        "ghosttykit_release: ${{ steps.unchanged_inputs.outputs.compile_admitted == 'true' && 'false' || steps.linux_guards.outputs.ghosttykit_release }}"
        in changes
    )

    unchanged = workflow_step_block("changes", "Skip compile when build inputs are unchanged")
    assert "--revision 'HEAD^1'" in unchanged
    assert 'echo "compile_admitted=true" >> "$GITHUB_OUTPUT"' in unchanged
    assert "build_input_fingerprint\\.py|product_input_identity\\.py" in unchanged

    lookup = workflow_step_block("changes", "Look for an earlier run that compiled these inputs")
    assert "steps.unchanged_inputs.outputs.compile_admitted != 'true'" in lookup


def test_published_fingerprint_artifact_is_the_one_the_lookup_reads() -> None:
    sys.path.insert(0, str(ROOT / "scripts/ci"))
    from find_admitted_build import artifact_name

    block = workflow_step_block("changes", "Publish the build-input fingerprint")
    (name,) = [line.split("name: ", 1)[1] for line in block.splitlines() if line.startswith("          name: ")]
    published = name.replace("${{ steps.inputs.outputs.fingerprint }}", "abc").replace("${{ github.run_attempt }}", "2")
    assert published == artifact_name("abc", 2)


def test_full_suite_runs_still_require_the_suite() -> None:
    assert run_tests_gate(tests_gate_needs("true", macos_result="success")).returncode == 0
    assert run_tests_gate(tests_gate_needs("true", macos_result="skipped")).returncode == 1
    # A missing route output must never relax the aggregate platform gate.
    assert run_tests_gate(tests_gate_needs(None, macos_result="skipped")).returncode == 1


def test_only_pull_requests_under_the_compile_only_policy_skip_the_suite() -> None:
    sys.path.insert(0, str(ROOT / "scripts/ci"))
    from choose_ci_suite import wants_full_suite

    assert wants_full_suite("pull_request", "compile-only", []) is False
    assert wants_full_suite("pull_request", "compile-only", ["bug", "full-ci"]) is True
    assert wants_full_suite("pull_request", "compile-only", None) is True
    assert wants_full_suite("pull_request", "", []) is True
    assert wants_full_suite("pull_request", "full", []) is True
    for event in ("merge_group", "workflow_dispatch", "push"):
        assert wants_full_suite(event, "compile-only", []) is True


def test_a_skipped_suite_is_refused_when_only_the_suite_could_judge_the_diff() -> None:
    sys.path.insert(0, str(ROOT / "scripts/ci"))
    from choose_ci_suite import coverage_gap

    tests_diff = ["cmuxTests/WorkspaceUnitTests.swift"]

    # Compile admission builds the bundle and stops, so a test-only change is
    # unobserved when the suite is skipped.
    assert coverage_gap("pull_request", False, tests_diff, []) is True
    assert coverage_gap("pull_request", False, ["cmuxUITests/A.swift"], []) is True
    # Running the suite is the whole point; there is nothing to refuse.
    assert coverage_gap("pull_request", True, tests_diff, []) is False
    # Product sources still compile, which is what the policy claims to check.
    assert coverage_gap("pull_request", False, ["Sources/A.swift"], []) is False
    assert coverage_gap("pull_request", False, ["web/app/page.tsx"], []) is False
    # The skip may be deliberate, but it has to be recorded on the pull request.
    assert coverage_gap("pull_request", False, tests_diff, ["no-full-ci"]) is False
    # An unreadable diff must not be the reason a change goes unobserved.
    assert coverage_gap("pull_request", False, None, []) is True
    # Only pull requests take the cheap path at all.
    for event in ("merge_group", "workflow_dispatch", "push"):
        assert coverage_gap(event, False, tests_diff, []) is False


def test_unit_ci_asks_for_the_unit_tests_without_the_expensive_lanes() -> None:
    sys.path.insert(0, str(ROOT / "scripts/ci"))
    from choose_ci_suite import wants_unit_suite

    # The full suite already runs them, so it implies the cheaper tier.
    assert wants_unit_suite("pull_request", "compile-only", ["full-ci"]) is True
    assert wants_unit_suite("pull_request", "compile-only", ["unit-ci"]) is True
    assert wants_unit_suite("pull_request", "compile-only", []) is False
    # Unreadable labels keep the full suite, which includes the unit tests.
    assert wants_unit_suite("pull_request", "compile-only", None) is True
    for event in ("merge_group", "workflow_dispatch", "push"):
        assert wants_unit_suite(event, "compile-only", []) is True



def test_a_cmux_tests_diff_selects_the_unit_tests_without_a_label() -> None:
    sys.path.insert(0, str(ROOT / "scripts/ci"))
    from choose_ci_suite import coverage_gap, wants_unit_suite

    tests_diff = ["cmuxTests/WorkspaceUnitTests.swift", "Sources/Workspace.swift"]
    # The diff already says which job can judge it; no label is needed.
    assert wants_unit_suite("pull_request", "compile-only", [], tests_diff) is True
    assert (
        coverage_gap(
            "pull_request",
            False,
            tests_diff,
            [],
            unit_suite=wants_unit_suite("pull_request", "compile-only", [], tests_diff),
        )
        is False
    )
    # A diff outside cmuxTests/ keeps the cheap path.
    assert wants_unit_suite("pull_request", "compile-only", [], ["Sources/Workspace.swift"]) is False
    # cmuxUITests/ is not run by this job, so it does not select it, and the
    # gap it leaves is still refused.
    ui_diff = ["cmuxUITests/LaunchUITests.swift"]
    assert wants_unit_suite("pull_request", "compile-only", [], ui_diff) is False
    assert coverage_gap("pull_request", False, ui_diff, [], unit_suite=False) is True
    # An unreadable diff runs the unit tests rather than guessing.
    assert wants_unit_suite("pull_request", "compile-only", [], None) is True

def test_a_diff_that_edits_a_few_suites_runs_only_those_suites() -> None:
    sys.path.insert(0, str(ROOT / "scripts/ci"))
    from choose_ci_suite import changed_unit_selectors, strict_steps
    from test_impact import affected_suites

    def hunk(path: str, line: int, count: int = 1) -> str:
        return f"--- a/{path}\n+++ b/{path}\n@@ -{line},{count} +{line},{count} @@\n"

    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        tests = root / "cmuxTests"
        tests.mkdir()
        (root / ".github/workflows").mkdir(parents=True)
        (root / ".github/workflows/ci-macos.yml").write_text(MACOS_WORKFLOW.read_text(encoding="utf-8"))
        files = {
            # 1 import, 2 class, 3 helper, 4 body, 5 test, 6 body, 7-8 @Test lines, 9 test
            "AlphaTests.swift": (
                "import XCTest\n"
                "final class AlphaTests: XCTestCase {\n"
                "    static func makeModel() -> Int {\n"
                "        1\n"
                "    }\n"
                "    func testA() { _ = sharedHelper() }\n"
                "    @Test(\n"
                "        arguments: [1])\n"
                "    func modernName(value: Int) {}\n"
                "}\n"
            ),
            "BetaTests.swift": (
                "import XCTest\n"
                "final class BetaTests: XCTestCase {\n"
                "    func testB() { _ = AlphaTests.makeModel() }\n"
                "}\n"
            ),
            "GammaTests.swift": (
                "import XCTest\n"
                "final class GammaTests: XCTestCase {\n"
                "    func testG() { _ = makeModel() }\n"
                "    func makeModel() -> Int { 2 }\n"
                "}\n"
            ),
            "Helper.swift": "func sharedHelper() -> Int {\n    wrapped()\n}\nfunc wrapped() -> Int { 0 }\n",
            "UsesHelperTests.swift": (
                "import XCTest\n"
                "final class UsesHelperTests: XCTestCase {\n"
                "    func testU() { _ = sharedHelper() }\n"
                "}\n"
            ),
            "StringExtras.swift": "extension String {\n    var shouted: String { uppercased() }\n}\n",
            "ShoutTests.swift": (
                "import XCTest\n"
                "final class ShoutTests: XCTestCase {\n"
                "    func testS() { _ = \"a\".shouted }\n"
                "}\n"
            ),
            "Conformances.swift": "extension Int: @retroactive Identifiable {\n    public var id: Int { self }\n}\n",
            "FeedCoordinatorTests.swift": (
                "import Testing\n@Suite struct FeedCoordinatorTests {\n    @Test func testF() {}\n}\n"
            ),
            "Fixture.json": "{}\n",
            # 1 class, 2 member, 3 body, 4 close, 5 close, 6 factory
            "Recorder.swift": (
                "final class Recorder: IntentRecording {\n"
                "    func record(_ intent: Int) {\n"
                "        intents.append(intent)\n"
                "    }\n"
                "}\n"
                "func makeRecorder() -> Recorder { Recorder() }\n"
            ),
            "BuildsRecorderTests.swift": (
                "import XCTest\n"
                "final class BuildsRecorderTests: XCTestCase {\n"
                "    func testR() { _ = Recorder() }\n"
                "}\n"
            ),
            "FactoryTests.swift": (
                "import XCTest\n"
                "final class FactoryTests: XCTestCase {\n"
                "    func testF() { makeRecorder().record(1) }\n"
                "}\n"
            ),
            # 1 struct, 2 tearDown, 3 body, 4 close, 5 close
            "Harness.swift": (
                "struct Harness {\n"
                "    func tearDown() {\n"
                "        stop()\n"
                "    }\n"
                "}\n"
            ),
            "HarnessTests.swift": (
                "import XCTest\n"
                "final class HarnessTests: XCTestCase {\n"
                "    func testH() { Harness().tearDown() }\n"
                "}\n"
            ),
            # 1 func, 2 close, 3 attribute, 4 func, 5 close
            "Plain.swift": "func first() -> Int {\n}\n@MainActor\nfunc plain() {\n}\n",
            "PlainTests.swift": (
                "import XCTest\n"
                "final class PlainTests: XCTestCase {\n"
                "    func testP() { plain() }\n"
                "}\n"
            ),
            "Container.swift": (
                "enum SettingsSuites {}\n"
                "extension SettingsSuites {\n"
                "    @Suite struct ChromeTests {\n"
                "        @Test func chrome() {}\n"
                "    }\n"
                "}\n"
            ),
        }
        for name, text in files.items():
            (tests / name).write_text(text)

        def affected(path: str, line: int | None = None) -> list[str] | None:
            full = f"cmuxTests/{path}"
            return affected_suites(root, [full], None if line is None else hunk(full, line))

        # A test method's edit runs its suite and nothing else, including a
        # Swift Testing method whose @Test sits above a multi-line argument.
        assert affected("AlphaTests.swift", 6) == ["cmuxTests/AlphaTests"]
        assert affected("AlphaTests.swift", 9) == ["cmuxTests/AlphaTests"]
        # A suite's helper reaches the suites that name the suite, not every
        # file with a method of the same name.
        assert affected("AlphaTests.swift", 4) == ["cmuxTests/AlphaTests", "cmuxTests/BetaTests"]
        # A top-level helper is traced through the helpers that call it.
        assert affected("Helper.swift", 4) == ["cmuxTests/AlphaTests", "cmuxTests/UsesHelperTests"]
        # Members added to another type are traced by their names.
        assert affected("StringExtras.swift", 2) == ["cmuxTests/ShoutTests"]
        # A conformance has no name to search for.
        assert affected("Conformances.swift", 2) is None
        # A helper type's member traces the type: a suite that only builds
        # the mock for app code to call runs, and so does one that reaches it
        # through a factory without naming it.
        assert affected("Recorder.swift", 3) == ["cmuxTests/BuildsRecorderTests", "cmuxTests/FactoryTests"]
        # A helper's `tearDown()` is a helper, not a hook only XCTest calls.
        assert affected("Harness.swift", 3) == ["cmuxTests/HarnessTests"]
        # An attribute line belongs to the declaration below it.
        assert affected("Plain.swift", 3) == ["cmuxTests/PlainTests"]
        # Suites nested in a container are named nowhere here: run everything.
        assert affected("Container.swift", 4) is None
        # An import is a change to the whole file.
        assert affected("AlphaTests.swift", 1) == ["cmuxTests/AlphaTests", "cmuxTests/BetaTests"]
        # Without line information every line of the file counts.
        assert affected("AlphaTests.swift") == ["cmuxTests/AlphaTests", "cmuxTests/BetaTests"]
        # Non-Swift inputs run everything; a deleted file leaves nothing.
        assert affected_suites(root, ["cmuxTests/Fixture.json"], None) is None
        assert affected_suites(root, ["cmuxTests/GoneTests.swift"], None) == []
        assert changed_unit_selectors(root, None) == []
        assert changed_unit_selectors(root, ["cmuxTests/GoneTests.swift"]) == []
        # A suite a strict step owns runs through that step, on the same worker.
        feed = ["cmuxTests/FeedCoordinatorTests.swift"]
        assert changed_unit_selectors(root, feed) == ["cmuxTests/FeedCoordinatorTests"]
        workflow = MACOS_WORKFLOW.read_text(encoding="utf-8")
        assert strict_steps(workflow, ["cmuxTests/FeedCoordinatorTests"]) == ["Run Pi Feed ownership regressions"]
        assert strict_steps(workflow, ["cmuxTests/AlphaTests"]) == []


def app_host_product_consumers(workflow: dict) -> dict[str, dict]:
    """Jobs in ci-macos.yml that download compile admission's app-host product."""
    return {
        name: job
        for name, job in workflow["jobs"].items()
        if "needs.macos-compile-admission.outputs.artifact_id" in yaml.safe_dump(job, width=10**6)
    }


# On a run the picker put on an owned pool, a consumer it did not place there
# (every GUI job), and any re-run of failed jobs, takes the Blacksmith pool it
# named on the lane's Xcode, which is the Xcode the owned label names
# (pr_runner_pool.py). Each consumer tests its own owned_jobs key. Attempt 2
# of a consumer the fleet refused takes the owned label once more, which
# names the same Xcode.
PRODUCT_RUNNER_KEYS = {
    "app-host-unit-tests": "format(' shard-{0} ', matrix.shard)",
    "cli-product-tests": "' cli-product '",
}


def product_runner_output(key: str) -> str:
    return ("${{ github.run_attempt == 2 && github.triggering_actor == 'github-actions[bot]' && contains(inputs.pr_owned_jobs, " + key + ") "
            "&& inputs.pr_refused_retry_runner "
            "|| (github.run_attempt > 1 || !contains(inputs.pr_owned_jobs, " + key + ")) "
            "&& inputs.pr_retry_runner || needs.macos-compile-admission.outputs.runner }}")


PRODUCT_RUNNER_OUTPUT = product_runner_output(PRODUCT_RUNNER_KEYS["app-host-unit-tests"])
PRODUCT_XCODE_OUTPUT = "${{ needs.macos-compile-admission.outputs.xcode_app }}"


def product_consumer_route_violations(workflow: dict) -> list[str]:
    """Consumers of the admission product whose pool or Xcode can differ from it.

    A consumer either reads the admission's `runner` / `xcode_app` outputs, or
    (tests-build-and-lag, whose display overflow lane has its own guards)
    restates the admission's exact expressions, differing only by paid
    overflow's MACOS_RUNNER_DISPLAY in place of MACOS_RUNNER_15.
    """
    producer = workflow["jobs"]["macos-compile-admission"]
    violations = []
    if producer["env"].get("CMUX_PRODUCT_RUNNER") != producer["runs-on"]:
        violations.append("macos-compile-admission: CMUX_PRODUCT_RUNNER does not restate runs-on")
    outputs = producer.get("outputs", {})
    if outputs.get("runner") != "${{ env.CMUX_PRODUCT_RUNNER }}":
        violations.append("macos-compile-admission: missing runner output")
    if outputs.get("xcode_app") != "${{ env.CMUX_CI_XCODE_APP }}":
        violations.append("macos-compile-admission: missing xcode_app output")
    for name, job in app_host_product_consumers(workflow).items():
        runs_on = job.get("runs-on", "")
        xcode = (job.get("env") or {}).get("CMUX_CI_XCODE_APP")
        if name in PRODUCT_RUNNER_KEYS and runs_on == product_runner_output(PRODUCT_RUNNER_KEYS[name]) \
                and xcode == PRODUCT_XCODE_OUTPUT:
            continue
        if (
            name == "tests-build-and-lag"
            # Its own owned_jobs key, so it never follows admission's placement.
            and "' lag '" in runs_on
            and runs_on.replace("vars.MACOS_RUNNER_DISPLAY", "vars.MACOS_RUNNER_15").replace(
                "' lag '", "' admission '") == producer["runs-on"]
            and xcode == producer["env"]["CMUX_CI_XCODE_APP"]
        ):
            continue
        violations.append(f"{name}: runs-on {runs_on}; CMUX_CI_XCODE_APP {xcode}")
    return violations


def test_app_host_product_consumers_run_on_the_producers_pool_and_xcode() -> None:
    # An app-host test bundle only loads under the Xcode that linked it: a
    # product compiled with Xcode 26.6 references Testing.framework symbols
    # that Xcode 26.3 does not ship, so a consumer on another pool dies in
    # dlopen ("Symbol not found ... Expected in: Xcode_26.3.app/.../Testing")
    # before running one test (run 35958884147, job 107508090815). Compile
    # admission is the single source of the pool and Xcode.
    workflow = yaml.safe_load(MACOS_WORKFLOW.read_text(encoding="utf-8"))
    consumers = app_host_product_consumers(workflow)
    assert {"app-host-unit-tests", "tests-build-and-lag"} <= set(consumers), sorted(consumers)
    assert product_consumer_route_violations(workflow) == []
    # The app-host shards read the outputs, so a route added to the admission
    # moves them without an edit here.
    shards = workflow["jobs"]["app-host-unit-tests"]
    assert shards["runs-on"] == PRODUCT_RUNNER_OUTPUT
    assert shards["env"]["CMUX_CI_XCODE_APP"] == PRODUCT_XCODE_OUTPUT


def test_product_consumer_guard_follows_a_new_admission_route() -> None:
    # Give the admission a new route, as sending merge groups to the
    # pull-request pool and Xcode would. Consumers that read the outputs stay
    # compliant; one that restates the old expression is reported.
    workflow = yaml.safe_load(MACOS_WORKFLOW.read_text(encoding="utf-8"))
    producer = workflow["jobs"]["macos-compile-admission"]
    pull_request = "github.event_name == 'pull_request'"
    new_route = "(github.event_name == 'pull_request' || github.event_name == 'merge_group')"
    for key in ("CMUX_PRODUCT_RUNNER", "CMUX_CI_XCODE_APP"):
        assert pull_request in producer["env"][key], key
        producer["env"][key] = producer["env"][key].replace(pull_request, new_route, 1)
    producer["runs-on"] = producer["env"]["CMUX_PRODUCT_RUNNER"]
    violations = product_consumer_route_violations(workflow)
    assert [line.split(":", 1)[0] for line in violations] == ["tests-build-and-lag"], violations


def test_app_host_rerun_runs_on_the_products_pool() -> None:
    # The rerun rebuilds cmuxTests against downloaded products with the
    # products' own Xcode, which only the pool that built them carries.
    rerun_workflow = ROOT / ".github" / "workflows" / "app-host-test-rerun.yml"
    workflow = yaml.safe_load(rerun_workflow.read_text(encoding="utf-8"))
    assert "runner" in workflow["jobs"]["plan"]["outputs"]
    assert "needs.plan.outputs.runner" in workflow["jobs"]["rerun"]["runs-on"]


def test_changed_suites_run_on_one_worker_and_labels_still_run_everything() -> None:
    workflow = yaml.safe_load(MACOS_WORKFLOW.read_text(encoding="utf-8"))
    job = workflow["jobs"]["app-host-unit-tests"]
    # The include expression picks one JSON row set: shard 8 alone for a
    # changed-suites run, the seven numbered consumers otherwise.
    include = job["strategy"]["matrix"]["include"]
    assert include.startswith("${{ fromJSON(inputs.unit_selectors != '' && '["), include
    changed_rows, numbered_rows = (
        json.loads(literal) for literal in re.findall(r"'(\[.*?\])'", include)
    )
    assert [row["shard"] for row in changed_rows] == [8], changed_rows
    assert [row["shard"] for row in numbered_rows] == [1, 2, 3, 4, 5, 6, 7], numbered_rows
    # No row names a pool: every consumer runs where compile admission ran.
    assert all(set(row) == {"shard"} for row in changed_rows + numbered_rows), (changed_rows, numbered_rows)
    assert job["env"]["CMUX_APP_HOST_UNIT_SELECTORS"] == "${{ inputs.unit_selectors }}"
    # Shard 8 must own none of the strict steps the numbered shards run.
    owners = {key: value for key, value in job["env"].items() if key.endswith("_SHARD")}
    assert "8" not in owners.values(), owners
    # Every strict suite has a step, and each such step runs when selected.
    from choose_ci_suite import strict_steps
    from cmux_unit_test_shard import FOCUSED_GATE_SELECTORS

    text = MACOS_WORKFLOW.read_text(encoding="utf-8")
    owners = strict_steps(text, sorted(FOCUSED_GATE_SELECTORS))
    assert owners, "a strict suite has no step that runs it"
    for step in job["steps"]:
        if step.get("name") in owners:
            assert f"contains(inputs.unit_strict_steps, '|{step['name']}|')" in step["if"], step["name"]
    assert yaml.safe_load(CI_WORKFLOW.read_text(encoding="utf-8"))["jobs"]["macos"]["with"]["unit_strict_steps"] == "${{ needs.changes.outputs.unit_strict_steps }}"
    ci = yaml.safe_load(CI_WORKFLOW.read_text(encoding="utf-8"))
    assert ci["jobs"]["macos"]["with"]["unit_selectors"] == "${{ needs.changes.outputs.unit_selectors }}"

    script = ROOT / "scripts/ci/choose_ci_suite.py"
    with tempfile.TemporaryDirectory() as directory:
        changed = Path(directory) / "changed.txt"
        changed.write_text("cmuxTests/TerminalTabIconRegressionTests.swift\n")
        labels = Path(directory) / "labels.txt"

        def selectors(label: str) -> str:
            labels.write_text(label)
            run = subprocess.run(
                [sys.executable, str(script), "--event-name", "pull_request",
                 "--pull-request-policy", "compile-only", "--labels-file", str(labels),
                 "--files-from", str(changed), "--root", str(ROOT)],
                capture_output=True, text=True, check=True,
            )
            return next(line for line in run.stdout.splitlines() if line.startswith("unit_selectors="))

        assert selectors("") == "unit_selectors=cmuxTests/TerminalTabIconRegressionTests"
        # An explicit request for every suite is honored.
        assert selectors("unit-ci\n") == "unit_selectors="
        assert selectors("full-ci\n") == "unit_selectors="


def test_compile_admission_runs_changed_suites_that_need_no_worker() -> None:
    """A few changed suites run on the runner that compiled them.

    A separate changed-suites worker queued, checked out, selected Xcode and
    downloaded the product, about two minutes of setup, to run about twenty
    seconds of tests. Compile admission runs them itself unless a strict step
    owns one of them or the diff edits the consumer path that worker proves.
    """
    script = ROOT / "scripts/ci/choose_ci_suite.py"
    with tempfile.TemporaryDirectory() as directory:
        changed = Path(directory) / "changed.txt"
        labels = Path(directory) / "labels.txt"

        def outputs(paths: list[str], label: str = "") -> dict[str, str]:
            changed.write_text("".join(f"{path}\n" for path in paths))
            labels.write_text(label)
            run = subprocess.run(
                [sys.executable, str(script), "--event-name", "pull_request",
                 "--pull-request-policy", "compile-only", "--labels-file", str(labels),
                 "--files-from", str(changed), "--root", str(ROOT)],
                capture_output=True, text=True, check=True,
            )
            return dict(line.split("=", 1) for line in run.stdout.splitlines())

        plain = ["cmuxTests/TerminalTabIconRegressionTests.swift"]
        assert outputs(plain)["unit_in_admission"] == "true"
        # A strict step's suite needs that step's own app host: the worker.
        strict = outputs(["cmuxTests/FeedCoordinatorTests.swift"])
        assert strict["unit_strict_steps"], strict
        assert strict["unit_in_admission"] == "false", strict
        # A consumer edit still has to be proven on the worker, canary or not.
        consumer = "scripts/ci/app_host_test_products.py"
        assert outputs(plain + [consumer])["unit_in_admission"] == "false"
        assert outputs([consumer])["unit_in_admission"] == "false"
        # Every suite, or none, stays on the numbered shards.
        assert outputs(plain, "unit-ci\n")["unit_in_admission"] == "false"
        assert outputs(plain, "full-ci\n")["unit_in_admission"] == "false"
        assert outputs(["Sources/Workspace.swift"])["unit_in_admission"] == "false"

    ci = yaml.safe_load(CI_WORKFLOW.read_text(encoding="utf-8"))
    # A compile admission on an owned Mac holds glaeda's compile token, not the
    # gui token, so a persistent pick moves the changed suites to shard 8.
    assert ci["jobs"]["changes"]["outputs"]["unit_in_admission"] == (
        "${{ steps.macos-pool.outputs.persistent != 'true' && steps.suite.outputs.unit_in_admission || 'false' }}")
    assert ci["jobs"]["macos"]["with"]["unit_in_admission"] == "${{ needs.changes.outputs.unit_in_admission }}"

    workflow = yaml.safe_load(MACOS_WORKFLOW.read_text(encoding="utf-8"))
    call_inputs = workflow[True]["workflow_call"]["inputs"]
    assert call_inputs["unit_in_admission"]["default"] == "", call_inputs["unit_in_admission"]
    admission = workflow["jobs"]["macos-compile-admission"]
    shards = workflow["jobs"]["app-host-unit-tests"]
    assert shards["if"].endswith("&& inputs.unit_in_admission != 'true' }}"), shards["if"]
    assert admission["outputs"]["changed_suites"] == "${{ steps.run-changed-suites.outcome }}"

    names = [step.get("name") for step in admission["steps"]]
    by_name = {step.get("name"): step for step in admission["steps"]}
    shard_steps = {step.get("name"): step for step in shards["steps"]}
    first_test = names.index("Prepare isolated DerivedData")
    # The product is packaged, uploaded and seeded before any test can fail.
    for producer in ("Package compiled app-host test product", "Upload compiled app-host test product",
                     "Seed node-local compiled product cache"):
        assert names.index(producer) < first_test, producer
    for name in names[first_test:]:
        condition = str(by_name[name].get("if", ""))
        assert "inputs.unit_in_admission == 'true'" in condition or "steps.test-derived-data.outcome" in condition \
            or "steps.run-changed-suites.outcome" in condition \
            or name in {"Report evidence collection outcomes", "Hold consumers behind the fast Linux gate"}, name
    # Admission runs the worker's own scripts, not copies of them.
    shared = {
        "Enumerate built app-host tests": "Enumerate built app-host tests",
        "Enable XCTest automation mode": "Enable XCTest automation mode",
        "Run changed app-host suites": "Run unit tests",
        "Collect app-host failure diagnostics": "Collect app-host failure diagnostics",
        "Prepare isolated app-host home": "Prepare isolated app-host home",
    }
    for mine, theirs in shared.items():
        assert by_name[mine]["run"] == shard_steps[theirs]["run"], mine
        assert by_name[mine]["run"].startswith("scripts/ci/"), mine
    assert "scripts/ci/restore-app-host-test-product.sh" in by_name["Restore compiled app-host test product"]["run"]
    assert by_name["Upload built app-host test inventory"]["with"] == shard_steps["Upload built app-host test inventory"]["with"]
    assert by_name["Upload app-host failure diagnostics"]["with"] == shard_steps["Upload app-host failure diagnostics"]["with"]
    # The tests see what the worker's changed-suites run sees, as shard 8.
    for key in ("CMUX_CI_APP_HOST_ISOLATION_REQUIRED", "CMUX_APP_HOST_UNIT_SELECTORS",
                "CMUX_APP_HOST_CAPTURE_XCRESULTS", "CMUX_UNIT_TEST_TIMEOUT_SECONDS",
                "CMUX_XCODEBUILD_NONINTERACTIVE_IDLE_TIMEOUT_SECONDS",
                "CMUX_XCODEBUILD_NONINTERACTIVE_RESTART_BUDGET", "SWIFT_BACKTRACE",
                "CMUX_XCODEBUILD_NONINTERACTIVE_POST_TEST_TIMEOUT_SECONDS"):
        assert admission["env"][key] == shards["env"][key], key
    assert admission["env"]["CMUX_APP_HOST_SHARD"] == "8"

    # macOS status takes admission's success as the tests' and names a test
    # failure apart from a compile failure.
    status = workflow_job_step_script("macos-status", "Check routed macOS jobs", MACOS_WORKFLOW)
    route = {"macos": "true", "full_suite": "false", "unit_suite": "true", "compile_admitted": "",
             "release_build": "false", "unit_selectors": "cmuxTests/AlphaTests"}

    def macos_status(in_admission: str, admission: str, shards: str, suites: str) -> subprocess.CompletedProcess[str]:
        needs = {name: {"result": "skipped", "outputs": {}} for name in MACOS_JOBS}
        needs["macos-compile-admission"] = {"result": admission, "outputs": {"changed_suites": suites}}
        needs["app-host-unit-tests"]["result"] = shards
        env = {**os.environ, "MACOS_INPUTS": json.dumps({**route, "unit_in_admission": in_admission}),
               "MACOS_NEEDS": json.dumps(needs)}
        return subprocess.run(["bash", "-c", status], cwd=ROOT, env=env, text=True, capture_output=True)

    assert macos_status("true", "success", "skipped", "success").returncode == 0
    failed = macos_status("true", "failure", "skipped", "failure")
    assert failed.returncode != 0
    assert "the changed suites failed" in failed.stderr, failed.stderr
    compile_failed = macos_status("true", "failure", "skipped", "skipped")
    assert "before the changed suites ran" in compile_failed.stderr, compile_failed.stderr
    # Without admission running them, the worker is still required.
    assert macos_status("", "success", "skipped", "").returncode != 0
    assert macos_status("", "success", "success", "").returncode == 0


def test_an_app_host_consumer_edit_runs_a_canary_after_the_compile() -> None:
    """Compile-only builds the product and never restores or runs it.

    A pull request that edits how the app-host shards restore and run that
    product (#14163) paid for the compile and executed none of its change.
    """
    sys.path.insert(0, str(ROOT / "scripts/ci"))
    from choose_ci_suite import (
        APP_HOST_CONSUMER_PATHS,
        CONSUMER_CANARY_SELECTOR,
        consumer_canary_selectors,
    )
    from cmux_unit_test_shard import FOCUSED_GATE_SELECTORS, discover_selectors

    workflow_path = ".github/workflows/ci-macos.yml"
    lines = MACOS_WORKFLOW.read_text(encoding="utf-8").splitlines()
    job_start = lines.index("  app-host-unit-tests:") + 1
    job_end = next(
        number
        for number, line in enumerate(lines, start=1)
        if number > job_start and re.match(r"^  [A-Za-z0-9_-]+:$", line)
    ) - 1
    compile_line = lines.index("  macos-compile-admission:") + 2

    def hunk(line: int, count: int = 1) -> str:
        return f"--- a/{workflow_path}\n+++ b/{workflow_path}\n@@ -{line},{count} +{line},{count} @@\n"

    canary = [CONSUMER_CANARY_SELECTOR]
    # A script only the shards run is a consumer edit.
    for path in ("scripts/ci/app_host_test_products.py", "scripts/ci/cmux_unit_test_shard.py"):
        assert consumer_canary_selectors(ROOT, [path], None) == canary, path
    # So is a ci-macos.yml hunk inside the shards' job, first line to last.
    for line in (job_start, job_start + 20, job_end):
        assert consumer_canary_selectors(ROOT, [workflow_path], hunk(line)) == canary, line
    # Compile admission's outputs, and the route and Xcode env they carry,
    # decide where the shards run and which Xcode loads the product (#14163).
    admission_start = lines.index("  macos-compile-admission:")
    admission_steps = lines.index("    steps:", admission_start)
    for key in ("    outputs:", "      runner: ", "      CMUX_PRODUCT_RUNNER: ", "      CMUX_CI_XCODE_APP: "):
        line = next(number for number, text in enumerate(lines[admission_start:admission_steps],
                                                       start=admission_start + 1) if text.startswith(key))
        assert consumer_canary_selectors(ROOT, [workflow_path], hunk(line)) == canary, key
    # A ci-macos.yml hunk elsewhere is judged by the job it sits in.
    assert consumer_canary_selectors(ROOT, [workflow_path], hunk(compile_line)) == []
    assert consumer_canary_selectors(ROOT, [workflow_path], hunk(admission_steps + 3)) == []
    assert consumer_canary_selectors(ROOT, [workflow_path], hunk(job_end + 5)) == []
    # A pure deletion at the job's last line still sits inside it.
    assert consumer_canary_selectors(ROOT, [workflow_path], hunk(job_end, 0)) == canary
    # Without hunks for ci-macos.yml nothing can place the edit, so it runs.
    assert consumer_canary_selectors(ROOT, [workflow_path], None) == canary
    assert consumer_canary_selectors(ROOT, [workflow_path], "") == canary
    # Product sources are judged by the compile, as before.
    assert consumer_canary_selectors(ROOT, ["Sources/Workspace.swift"], None) == []
    assert consumer_canary_selectors(ROOT, None, None) == []

    # Every listed path exists and the shards' job reaches it, directly or
    # through another listed script, so the list cannot silently rot.
    assert workflow_path in APP_HOST_CONSUMER_PATHS
    scripts = [path for path in APP_HOST_CONSUMER_PATHS if path != workflow_path]
    job = "\n".join(lines[job_start - 1 : job_end])
    reached = {path for path in scripts if Path(path).name in job}
    for _ in scripts:
        for path in sorted(reached):
            if path.endswith((".py", ".sh")):
                text = (ROOT / path).read_text(encoding="utf-8")
                reached |= {other for other in scripts if Path(other).name in text}
    for path in scripts:
        assert (ROOT / path).is_file(), path
        assert path in reached, f"{path} is not reached from app-host-unit-tests"

    # The canary is an existing XCTest suite the shared batch can run: not a
    # strict step's suite, and not a known failure.
    discovered = {selector.identifier.split("/")[1] for selector in discover_selectors(ROOT)}
    assert CONSUMER_CANARY_SELECTOR.split("/")[1] in discovered
    assert CONSUMER_CANARY_SELECTOR not in FOCUSED_GATE_SELECTORS
    known = (ROOT / "scripts/ci/app-host-known-failures.json").read_text(encoding="utf-8")
    assert CONSUMER_CANARY_SELECTOR.split("/")[1] not in known

    # The tests diff ci.yml hands the chooser carries ci-macos.yml's hunks.
    ci_text = CI_WORKFLOW.read_text(encoding="utf-8")
    assert f'"$MERGE_SHA" -- cmuxTests {workflow_path} \\\n' in ci_text

    script = ROOT / "scripts/ci/choose_ci_suite.py"
    with tempfile.TemporaryDirectory() as directory:
        changed = Path(directory) / "changed.txt"
        labels = Path(directory) / "labels.txt"

        def outputs(paths: list[str], label: str = "") -> dict[str, str]:
            changed.write_text("".join(f"{path}\n" for path in paths))
            labels.write_text(label)
            run = subprocess.run(
                [sys.executable, str(script), "--event-name", "pull_request",
                 "--pull-request-policy", "compile-only", "--labels-file", str(labels),
                 "--files-from", str(changed), "--root", str(ROOT)],
                capture_output=True, text=True, check=True,
            )
            return dict(line.split("=", 1) for line in run.stdout.splitlines())

        consumer = ["scripts/ci/app_host_test_products.py", "Sources/Workspace.swift"]
        result = outputs(consumer)
        assert result["full_suite"] == "false", result
        assert result["unit_suite"] == "true", result
        assert result["unit_selectors"] == CONSUMER_CANARY_SELECTOR, result
        assert result["unit_strict_steps"] == "", result
        assert result["coverage_gap"] == "false", result
        # Edited suites already run through the consumer; they replace the canary.
        suites = outputs(consumer + ["cmuxTests/TerminalTabIconRegressionTests.swift"])
        assert suites["unit_selectors"] == "cmuxTests/TerminalTabIconRegressionTests", suites
        # Labels asking for every suite still get every suite.
        assert outputs(consumer, "unit-ci\n")["unit_selectors"] == ""
        full = outputs(consumer, "full-ci\n")
        assert (full["full_suite"], full["unit_selectors"]) == ("true", ""), full
        # A diff with no consumer edit keeps the compile-only path.
        assert outputs(["Sources/Workspace.swift"])["unit_suite"] == "false"
        assert result["unit_canary"] == "true", result
        assert suites["unit_canary"] == "false", suites
        assert outputs(["Sources/Workspace.swift"])["unit_canary"] == "false"

    # The canary rides on a compile the pull request pays for anyway. A diff
    # whose build inputs were already compiled (a known-failures edit, say)
    # keeps skipping the Mac: both reuse checks still run for a canary, and
    # either one finding a compile drops it from the job's outputs.
    changes = yaml.safe_load(ci_text)["jobs"]["changes"]
    by_id = {step.get("id"): step for step in changes["steps"] if step.get("id")}
    for step_id in ("unchanged_inputs", "admitted"):
        condition = by_id[step_id]["if"]
        assert "(steps.suite.outputs.unit_suite != 'true' || steps.suite.outputs.unit_canary == 'true')" \
            in condition, (step_id, condition)
    reused = ("(steps.unchanged_inputs.outputs.compile_admitted == 'true' || "
              "steps.admitted.outputs.compile_admitted == 'true')")
    dropped = f"steps.suite.outputs.unit_canary == 'true' && {reused}"
    assert changes["outputs"]["unit_suite"] == \
        f"${{{{ {dropped} && 'false' || steps.suite.outputs.unit_suite }}}}", changes["outputs"]["unit_suite"]
    assert changes["outputs"]["unit_selectors"] == \
        f"${{{{ !({dropped}) && steps.suite.outputs.unit_selectors || '' }}}}", changes["outputs"]["unit_selectors"]


def test_the_unit_tier_closes_only_the_gap_its_job_can_judge() -> None:
    sys.path.insert(0, str(ROOT / "scripts/ci"))
    from choose_ci_suite import coverage_gap

    tests_diff = ["cmuxTests/WorkspaceUnitTests.swift"]
    ui_diff = ["cmuxUITests/LaunchUITests.swift"]

    # `app-host unit tests` executes cmuxTests/, so asking for it observes
    # the diff and there is nothing left to refuse.
    assert coverage_gap("pull_request", False, tests_diff, ["unit-ci"], unit_suite=True) is False
    # No pull request job runs cmuxUITests/, so the cheap tier cannot clear it.
    assert coverage_gap("pull_request", False, ui_diff, ["unit-ci"], unit_suite=True) is True
    assert (
        coverage_gap("pull_request", False, tests_diff + ui_diff, ["unit-ci"], unit_suite=True)
        is True
    )
    # An unreadable diff is never cleared by the cheap tier either.
    assert coverage_gap("pull_request", False, None, ["unit-ci"], unit_suite=True) is True
    # Default stays exactly as before for every caller that does not pass it.
    assert coverage_gap("pull_request", False, tests_diff, []) is True


def test_the_unit_tier_is_routed_end_to_end() -> None:
    caller = CI_WORKFLOW.read_text(encoding="utf-8")
    # The changes job forwards the chooser's unit tier (less a consumer canary
    # dropped for a reused compile; see the canary test for the full form).
    assert "|| steps.suite.outputs.unit_suite }}" in yaml.safe_load(caller)["jobs"]["changes"]["outputs"]["unit_suite"]
    assert "      unit_suite: ${{ needs.changes.outputs.unit_suite }}" in caller

    # The macOS workflow must be reachable for a unit-ci run whose compile was
    # already admitted, or the label would route nothing.
    macos_call = workflow_job_block("macos")
    assert "needs.changes.outputs.unit_suite == 'true'" in macos_call

    called = MACOS_WORKFLOW.read_text(encoding="utf-8")
    assert "      unit_suite:" in called

    # The cheap tier runs the unit tests and nothing else.
    unit_gate = workflow_job_block("app-host-unit-tests", MACOS_WORKFLOW)
    assert "inputs.unit_suite == 'true'" in unit_gate
    for job in ("tests-build-and-lag", "release-admission", "release-build"):
        assert "inputs.unit_suite" not in workflow_job_block(job, MACOS_WORKFLOW), job


def test_a_unit_ci_run_still_requires_the_macos_workflow_to_pass() -> None:
    # The tests job restates the macos `if:` as a result contract; a routed
    # unit-ci run that skipped macOS must not read as legitimately unrouted.
    gate = workflow_job_block("tests")
    assert 'unit_suite = outputs.get("unit_suite") == "true"' in gate
    assert "unit_suite" in gate.split("macos_work_required")[1].split(")")[0]


def test_a_unit_ci_run_cannot_pass_with_the_unit_tests_skipped() -> None:
    # unit-ci clears suite-coverage, so the app-host tests it asked for are the
    # only thing that judges the diff. Reusing an earlier run's compile skips
    # compile admission, and app-host hangs off admission succeeding -- the
    # usual label-after-first-push run would go green having run nothing.
    for step in (
        "Skip compile when build inputs are unchanged",
        "Look for an earlier run that compiled these inputs",
    ):
        condition = workflow_step_block("changes", step)
        assert "steps.suite.outputs.unit_suite != 'true'" in condition, step

    # And the status fails closed if the job the label asked for still skipped.
    inputs = {
        "macos": "true",
        "full_suite": "false",
        "unit_suite": "true",
        "compile_admitted": "true",
        "release_build": "false",
        "source_parent1": "parent",
    }
    skipped = dict.fromkeys(MACOS_JOBS, "skipped")
    assert run_macos_status(inputs=inputs, results=skipped).returncode != 0
    ran = {**skipped, "app-host-unit-tests": "success"}
    assert run_macos_status(inputs=inputs, results=ran).returncode == 0


def test_ci_status_requires_the_suite_coverage_gate() -> None:
    block = workflow_job_block("ci-status")
    assert "      - suite-coverage" in block

    gate = workflow_job_block("suite-coverage")
    assert "needs.changes.outputs.coverage_gap == 'true'" in gate
    # A Linux job, so refusing a run never costs a macOS runner.
    assert "vars.LINUX_RUNNER" in gate
    assert "exit 1" in gate


def test_suite_labels_are_read_from_the_run_event_snapshot() -> None:
    sys.path.insert(0, str(ROOT / "scripts/ci"))
    from choose_ci_suite import labels_from_event

    with tempfile.TemporaryDirectory() as tmp:
        event_path = Path(tmp) / "event.json"
        event_path.write_text(
            json.dumps(
                {
                    "pull_request": {
                        "labels": [
                            {"name": "bug"},
                            {"name": "full-ci"},
                        ]
                    }
                }
            ),
            encoding="utf-8",
        )
        assert labels_from_event(event_path) == ["bug", "full-ci"]

        event_path.write_text(
            json.dumps({"pull_request": {"labels": []}}),
            encoding="utf-8",
        )
        assert labels_from_event(event_path) == []

        event_path.write_text("{}", encoding="utf-8")
        assert labels_from_event(event_path) is None


def test_full_ci_label_changes_start_a_fresh_run_instead_of_mutating_a_rerun() -> None:
    workflow = CI_WORKFLOW.read_text(encoding="utf-8")
    assert "  pull_request:\n    types: [opened, synchronize, reopened, labeled, unlabeled]" in workflow

    suite = workflow_step_block("changes", "Choose the macOS suite for this run")
    assert "gh api" not in suite
    assert "github.event.pull_request.number" not in suite
    assert '--event-path "$GITHUB_EVENT_PATH"' in suite


def test_merge_groups_stop_at_the_first_failure() -> None:
    shards = workflow_job_block("app-host-unit-tests", MACOS_WORKFLOW)
    assert "fail-fast: ${{ github.event_name == 'merge_group' }}" in shards
    # The privileged watcher is started by a merge-group-only workflow, so an
    # ordinary pull request never creates a skipped fail-fast run. It still runs
    # from the default branch and executes no repository code.
    watcher = (ROOT / ".github/workflows/merge-group-fail-fast.yml").read_text(encoding="utf-8")
    assert "  workflow_run:\n    workflows: [Merge-group policy checks]\n    types: [in_progress]" in watcher
    assert "workflows: [CI]" not in watcher
    assert "head_sha=$HEAD_SHA" in watcher
    assert "event=merge_group" in watcher
    assert '.conclusion != null and .conclusion != "success" and .conclusion != "skipped"' in watcher
    assert "permissions: {}" in watcher and "actions: write" in watcher
    assert "uses:" not in watcher
    assert "actions: write" not in CI_WORKFLOW.read_text(encoding="utf-8")


def test_macos_compile_admission_precedes_expensive_shards() -> None:
    workflow = MACOS_WORKFLOW.read_text(encoding="utf-8")
    caller = workflow_job_block("macos")
    admission = workflow_job_block("macos-compile-admission", MACOS_WORKFLOW)

    assert "name: macOS compile admission" in admission
    assert "      - changes" in caller
    assert "      - static-preflight" in caller
    assert "      - linux-preflight" not in caller
    assert "inputs.macos == 'true'" in admission
    # The compile lives in one script so the nightly cache seeder runs the same
    # invocation; see tests/test_ci_test_compilation_cache_seed.sh.
    assert "scripts/ci/compile-app-host-test-product.sh canonical-build" in admission
    compile_script = (ROOT / "scripts/ci/compile-app-host-test-product.sh").read_text(encoding="utf-8")
    assert "build-for-testing" in compile_script
    import product_input_identity as identity

    # The scheme list moved into PRODUCT_PROFILES so the build and the product
    # identity cannot drift; assert the real invariant rather than the literal
    # loop. A partial build under a full product's key is the failure this
    # guards against.
    assert 'product_input_identity.py" schemes' in compile_script
    assert 'for scheme in "${schemes[@]}"' in compile_script
    assert identity.PRODUCT_PROFILES["app-host"] == (
        "cmux",
        "cmux-unit",
        "cmux-numeric-locale",
        "cmux-cli-tests",
    )
    assert identity.PRODUCT_PROFILES["cli"] == ("cmux-cli-tests",)
    # Every profile must be distinguishable in the identity, or one profile's
    # product answers another profile's cache lookup.
    seen = {
        name: identity.identity_from_tree_lines([], workflow, profile=name)
        for name in identity.PRODUCT_PROFILES
    }
    assert len({json.dumps(v, sort_keys=True) for v in seen.values()}) == len(seen)
    assert "actions/cache@27d5ce7" in admission or "uses: ./.github/actions/cache-restore" in admission
    assert "steps.upload-products.outputs.artifact-id" in admission
    assert "steps.upload-products.outputs.artifact-digest" in admission
    assert "product_contract: ${{ steps.product-key.outputs.key }}" in admission
    assert "node_product_cache.py seed" in admission
    assert "app_host_test_products.py stamp" in admission
    assert "framework_root=\"$(dirname \"$framework_source\")\"" in admission
    assert "rsync -aL \"$framework_root/\" \"$products/PackageFrameworks/\"" in admission

    app_host = workflow_job_block("app-host-unit-tests", MACOS_WORKFLOW)
    assert "      - macos-compile-admission" in app_host
    assert "test-without-building" in app_host
    assert "needs.macos-compile-admission.outputs.artifact_id" in app_host
    assert "needs.macos-compile-admission.outputs.artifact_digest" in app_host
    assert "node_product_cache.py acquire" in app_host
    assert "node_product_cache.py finalize" in app_host
    assert "steps.node-products.outputs.hit != 'true'" in app_host
    assert "restore-app-host-test-product.sh" in app_host
    assert os.access(ROOT / "scripts/ci/restore-app-host-test-product.sh", os.X_OK)
    assert "EXPECTED_SHA256" in app_host
    assert "-xctestrun" in app_host

    # The focused shard and the logical unit-test batches must both reuse the
    # admission-produced product. A later test invocation that silently changes
    # back to `test` would reintroduce six redundant compiles.
    app_host_commands = [line.strip() for line in app_host.splitlines()]
    assert all(
        command != "test"
        for command in app_host_commands
        if command in {"test", "test-without-building"}
    )


def test_static_preflight_rejects_stale_embedded_schema_before_native_work() -> None:
    steps = yaml.safe_load(CI_WORKFLOW.read_text())["jobs"]["static-preflight"]["steps"]
    scripts = [step["run"] for step in steps if "run" in step]
    with tempfile.TemporaryDirectory(prefix="cmux-schema-preflight-") as tmp:
        repo = Path(tmp)
        # Run the actual CI wrapper while isolating the schema checker from
        # unrelated validators. Read its declared recipe without importing it.
        import ast
        recipe_tree = ast.parse((ROOT / "scripts/verify-local.py").read_text())
        checks = next(ast.literal_eval(node.value) for node in recipe_tree.body
                      if isinstance(node, ast.Assign)
                      and any(isinstance(target, ast.Name) and target.id == "CHECKS"
                              for target in node.targets))
        for _name, category, _description, argv in checks:
            target = repo / argv[1]
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text("#!/usr/bin/env bash\nexit 0\n" if target.suffix == ".sh"
                              else 'print("Ran 1 test in 0.001s\\nOK")\n' if category == "tests"
                              else "pass\n")
            target.chmod(0o755)
        for name in ("verify-local.py", "verification_receipt.py"):
            shutil.copy2(ROOT / "scripts" / name, repo / "scripts" / name)
        generator = repo / "scripts/generate-cmux-config-schema.py"
        generator.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / "scripts/generate-cmux-config-schema.py", generator)
        schema = repo / "web/data/cmux.schema.json"
        schema.parent.mkdir(parents=True)
        schema.write_text('{"type":"object"}\n')
        generated = repo / "Packages/macOS/CmuxFoundation/Sources/CmuxFoundation/ConfigValidation"
        generated.mkdir(parents=True)
        subprocess.run([sys.executable, str(generator)], cwd=repo, check=True)
        subprocess.run(["git", "init", "-q", str(repo)], check=True)
        subprocess.run(["git", "add", "."], cwd=repo, check=True)
        subprocess.run(["git", "-c", "user.name=fixture", "-c",
                        "user.email=fixture@example.invalid", "commit", "-qm", "fixture"],
                       cwd=repo, check=True)
        def run_gate():
            return subprocess.run(["bash", "-e", "-c", "\n".join(scripts)], cwd=repo,
                                  capture_output=True, text=True, env={**os.environ, "CI": "true"})
        result = run_gate()
        assert result.returncode == 0, result.stdout + result.stderr
        schema.write_text('{"type":"object","title":"changed"}\n')
        stale = run_gate()
        assert stale.returncode != 0, "stale schema reached native admission"
        assert "is stale" in stale.stdout
        subprocess.run([sys.executable, str(generator)], cwd=repo, check=True)
        result = run_gate()
        assert result.returncode == 0, result.stdout + result.stderr


def test_guard_workflow_call_preserves_routes_and_starts_beside_static_checks() -> None:
    block = workflow_job_block("guards")

    # Guards are the last job macos-admission-gate waits for. Starting them
    # beside Fast static checks, not after, lets it decide ~25 s sooner; the
    # gate and `macos` both still require static-preflight, so macOS never
    # starts on a diff those checks reject.
    assert "    needs: [changes]" in block
    assert "static-preflight" in workflow_job_block("macos-admission-gate")
    assert "    uses: ./.github/workflows/ci-guards.yml" in block
    for route in GUARD_ROUTE_JOBS:
        assert f"      {route}: ${{{{ needs.changes.outputs.{route} }}}}" in block
        assert f"needs.changes.outputs.{route} != 'false'" in block
    assert (
        "      linux_guard_test_groups: "
        "${{ needs.changes.outputs.linux_guard_test_groups }}"
    ) in block


def test_app_host_failures_preserve_attempt_and_crash_diagnostics() -> None:
    app_host = workflow_job_block("app-host-unit-tests", MACOS_WORKFLOW)
    console_runner = (ROOT / "scripts/ci/run-in-console-session.sh").read_text(encoding="utf-8")

    assert 'CMUX_APP_HOST_CAPTURE_XCRESULTS: "1"' in app_host
    assert "CMUX_APP_HOST_CAPTURE_XCRESULTS" in console_runner
    assert "CMUX_APP_HOST_RESULT_BUNDLE_ROOT" in console_runner
    assert "- name: Collect app-host failure diagnostics" in app_host
    assert "- name: Upload app-host failure diagnostics" in app_host
    assert "run: scripts/ci/collect-app-host-diagnostics.sh" in app_host
    app_host += (ROOT / "scripts/ci/collect-app-host-diagnostics.sh").read_text(encoding="utf-8")
    assert "cmux-app-host-xcodebuild-*.meta" in app_host
    assert "cmux-app-host-xcresults" in app_host
    assert ".local/state/cmux/crash" in app_host
    assert "Library/Logs/DiagnosticReports" in app_host
    assert "if: ${{ failure() || cancelled() }}" in app_host


def test_linux_aggregate_preserves_all_routed_results() -> None:
    block = workflow_job_block("linux-preflight")

    assert "name: linux-preflight" in block
    assert "      - changes" in block
    assert "      - static-preflight" in block
    assert "      - guards" in block
    for guard_job in GUARD_JOBS:
        assert f"      - {guard_job}" not in block
    assert "      - ghosttykit-release-check" in block
    assert "      - web" in block
    for web_job in WEB_JOBS:
        assert f"      - {web_job}" not in block
    assert "if: ${{ always() }}" in block
    assert 'guard_routes = (' in block
    assert 'bad[f"guards.{route}"]' in block
    assert 'bad["guards"] = f"{guard_result} (one or more guard routes=true)"' in block
    assert 'web_routes = ("web", "agent_session_web")' in block
    assert 'bad[f"web.{route}"]' in block
    assert 'bad["web"] = f"{web_result} (one or more web routes=true)"' in block
    assert 'allowed_routed = {' in block
    assert 'routed_outputs = {' in block
    assert 'bad[name] = f"{result} (route {route}=true)"' in block


def test_linux_preflight_requires_guard_aggregate_when_any_guard_is_routed() -> None:
    assert run_linux_preflight(linux_preflight_needs()).returncode == 0

    for outcome in ("failure", "cancelled", "skipped"):
        result = run_linux_preflight(linux_preflight_needs(results={"guards": outcome}))

        assert result.returncode != 0, outcome
        assert f"guards: {outcome} (one or more guard routes=true)" in result.stderr


def test_linux_preflight_allows_skipped_guard_call_when_all_guard_routes_are_false() -> None:
    result = run_linux_preflight(
        linux_preflight_needs(
            outputs=dict.fromkeys(GUARD_ROUTE_JOBS, "false"),
            results={"guards": "skipped"},
        )
    )

    assert result.returncode == 0, result.stderr


def test_history_guard_uses_shallow_synthetic_merge_parent() -> None:
    block = workflow_job_block("workflow-guard-history", GUARD_WORKFLOW)
    assert "github.event_name == 'workflow_dispatch' && '0' || '2'" in block
    assert "fetch-depth: 0" not in block
    assert "Bind package policy to synthetic merge base" in block
    assert "github.event_name == 'pull_request'" in block
    assert "github.event_name == 'merge_group'" in block
    for guard_job in GUARD_JOBS:
        assert "fetch-depth: 0" not in workflow_job_block(guard_job, GUARD_WORKFLOW)

    script = workflow_job_step_script(
        "workflow-guard-history",
        "Bind package policy to synthetic merge base",
        GUARD_WORKFLOW,
    )
    with tempfile.TemporaryDirectory() as directory:
        repo = Path(directory)
        subprocess.run(["git", "init", "-q", "-b", "main"], cwd=repo, check=True)
        subprocess.run(["git", "config", "user.email", "ci@example.test"], cwd=repo, check=True)
        subprocess.run(["git", "config", "user.name", "CI Test"], cwd=repo, check=True)
        (repo / "base.txt").write_text("base\n", encoding="utf-8")
        subprocess.run(["git", "add", "."], cwd=repo, check=True)
        subprocess.run(["git", "commit", "-qm", "base"], cwd=repo, check=True)
        subprocess.run(["git", "branch", "feature"], cwd=repo, check=True)

        (repo / "main.txt").write_text("main\n", encoding="utf-8")
        subprocess.run(["git", "add", "."], cwd=repo, check=True)
        subprocess.run(["git", "commit", "-qm", "main moves"], cwd=repo, check=True)
        expected_base = subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=repo, text=True
        ).strip()

        subprocess.run(["git", "checkout", "-q", "feature"], cwd=repo, check=True)
        (repo / "feature.txt").write_text("feature\n", encoding="utf-8")
        subprocess.run(["git", "add", "."], cwd=repo, check=True)
        subprocess.run(["git", "commit", "-qm", "feature"], cwd=repo, check=True)
        subprocess.run(["git", "checkout", "-q", "main"], cwd=repo, check=True)
        subprocess.run(
            ["git", "merge", "-q", "--no-ff", "feature", "-m", "synthetic merge"],
            cwd=repo,
            check=True,
        )
        merge_sha = subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=repo, text=True
        ).strip()
        output = repo / "github-env.txt"
        result = subprocess.run(
            ["bash", "-c", script],
            cwd=repo,
            env={
                **os.environ,
                "CHECKED_OUT_SHA": merge_sha,
                "GITHUB_ENV": str(output),
            },
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        assert result.returncode == 0, result.stdout + result.stderr
        assert output.read_text(encoding="utf-8").splitlines() == [
            f"PACKAGE_RESOLVED_POLICY_BASE_REF={expected_base}"
        ]


def test_web_workflow_call_preserves_routes_and_starts_beside_static_checks() -> None:
    block = workflow_job_block("web")
    assert "needs.changes.outputs.macos != 'false'" not in block

    # On web pull requests, web finishes after the guards; see the guards test.
    assert "    needs: [changes]" in block
    assert "    uses: ./.github/workflows/ci-web.yml" in block
    for route in ("web", "macos", "agent_session_web"):
        assert f"      {route}: ${{{{ needs.changes.outputs.{route} }}}}" in block
    for route in ("web", "agent_session_web"):
        assert f"needs.changes.outputs.{route} != 'false'" in block


def test_web_workflow_parallelizes_typecheck_tests_and_browser_checks() -> None:
    typecheck = workflow_job_block("web-typecheck", WEB_WORKFLOW)
    production = workflow_job_block("web-production-build", WEB_WORKFLOW)
    tests = workflow_job_block("web-tests", WEB_WORKFLOW)
    instant = workflow_job_block("web-instant-navigation", WEB_WORKFLOW)

    assert "bun run typecheck" in typecheck
    assert "bun run test" not in typecheck
    assert "playwright" not in typecheck
    assert "bun run vercel-build" in production

    assert 'shard: ["1/4", "2/4", "3/4", "4/4"]' in tests
    assert './scripts/run-tests.sh --shard "${{ matrix.shard }}"' in tests

    assert "actions/cache@27d5ce7f107fe9357f9df03efb73ab90386fccae" in instant
    assert "bunx playwright install --with-deps chromium" in instant
    assert "CMUX_INSTANT_SKIP_TYPECHECK" in instant


def test_web_subarea_router_keeps_expensive_lanes_narrow() -> None:
    cases = (
        (["web/messages/fr.json"], (False, False, True, True, False, True, True)),
        (["web/app/[locale]/page.tsx"], (False, False, True, True, False, True, True)),
        (["web/services/vms/workflows.ts"], (True, False, False, True, False, True, True)),
        (["web/app/api/account/route.ts"], (True, False, True, True, False, True, True)),
        (["webviews/src/App.tsx"], (False, False, False, False, True, False, False)),
        (["webviews/src/diff/App.tsx"], (False, True, False, False, True, False, False)),
        (["Native/DiffSidecar/src/server.rs"], (False, True, False, False, False, False, False)),
        (["Sources/Panels/DiffSidecarBridge.swift"], (False, True, False, False, False, False, False)),
        (["Resources/markdown-viewer/webviews-app/main.mjs"], (False, False, False, False, True, False, False)),
        (["web/public/logo.png"], (False, False, False, True, False, False, True)),
        (["web/tests/account-route.test.ts"], (False, False, False, False, False, True, True)),
        (["web/tests/notifications-push-route.test.ts"], (True, False, False, False, False, True, True)),
        (["web/e2e/instant/locale-navigation.instant.ts"], (False, False, True, False, False, True, False)),
        (["web/playwright.instant.config.ts"], (False, False, True, False, False, True, True)),
        (["scripts/ci/web_validation.py"], (False, False, False, False, False, False, False)),
        ([".github/workflows/ci-web.yml"], (True, True, True, True, True, True, True)),
        (["scripts/ci/web_subareas.py"], (True, True, True, True, True, True, True)),
    )
    for paths, expected in cases:
        actual = web_subareas.classify_paths(paths)
        assert (
            actual.db,
            actual.diff_sidecar,
            actual.instant,
            actual.production_build,
            actual.react_apps,
            actual.typecheck,
            actual.unit_tests,
        ) == expected, (paths, actual)


def test_web_status_allows_unselected_subarea_jobs_to_skip() -> None:
    result = run_web_status(
        results={
            "web-typecheck": "skipped",
            "web-production-build": "skipped",
            "web-tests": "skipped",
            "web-instant-navigation": "skipped",
            "react-apps-check": "skipped",
            "diff-sidecar-check": "skipped",
            "web-db-migrations": "skipped",
        },
        subareas={
            "db": "false",
            "diff_sidecar": "false",
            "instant": "false",
            "production_build": "false",
            "react_apps": "false",
            "typecheck": "false",
            "unit_tests": "false",
        },
    )
    assert result.returncode == 0, result.stderr


def test_web_status_rejects_selected_skip_failure_or_cancellation() -> None:
    for web_job in WEB_JOBS:
        for outcome in ("skipped", "failure", "cancelled"):
            result = run_web_status(results={web_job: outcome})
            assert result.returncode != 0, (web_job, outcome)


def test_web_status_allows_unrouted_skips() -> None:
    result = run_web_status(
        inputs={"web": "false", "macos": "false", "agent_session_web": "false"},
        results=dict.fromkeys(WEB_JOBS, "skipped"),
    )
    assert result.returncode == 0, result.stderr


def test_linux_preflight_fails_when_routed_web_workflow_skips() -> None:
    result = run_linux_preflight(linux_preflight_needs(results={"web": "skipped"}))

    assert result.returncode != 0
    assert "web: skipped (one or more web routes=true)" in result.stderr


def test_linux_preflight_allows_unrouted_web_workflow_skip() -> None:
    result = run_linux_preflight(
        linux_preflight_needs(
            outputs={"web": "false", "macos": "false", "agent_session_web": "false"},
            results={"web": "skipped"},
        )
    )

    assert result.returncode == 0, result.stderr
    assert "web: skipped" in result.stdout


def test_macos_status_rejects_required_skip_failure_or_cancellation() -> None:
    for job in MACOS_JOBS:
        for outcome in ("skipped", "failure", "cancelled"):
            result = run_macos_status(results={job: outcome})
            assert result.returncode != 0, (job, outcome)


def test_macos_status_allows_unrouted_skips() -> None:
    result = run_macos_status(
        inputs={
            "macos": "false",
            "full_suite": "false",
            "compile_admitted": "false",
            "release_build": "false",
            "source_parent1": "",
        },
        results=dict.fromkeys(MACOS_JOBS, "skipped"),
    )
    assert result.returncode == 0, result.stderr


def test_package_lane_runs_on_a_routed_pull_request_without_the_full_suite() -> None:
    # The whole point: under CI_PULL_REQUEST_SUITE=compile-only the lane must
    # still run for a pull request the router attributed to a Swift package.
    block = workflow_job_block("swift-package-tests", MACOS_WORKFLOW)
    condition = next(line for line in block.splitlines() if line.strip().startswith("if:"))
    assert "inputs.swift_packages == 'true'" in condition, condition
    assert "inputs.full_suite == 'true'" in condition, condition

    # The caller has to supply the route and has to be willing to call the
    # reusable workflow for it, including when compile admission alone would
    # otherwise have skipped the macOS call entirely.
    macos_call = workflow_job_block("macos")
    assert "swift_packages: ${{ needs.changes.outputs.swift_packages }}" in macos_call
    call_condition = next(
        line for line in macos_call.splitlines() if line.strip().startswith("if:")
    )
    assert "needs.changes.outputs.swift_packages == 'true'" in call_condition, call_condition

    # And the reusable workflow has to accept it.
    macos_workflow = yaml.safe_load(MACOS_WORKFLOW.read_text(encoding="utf-8"))
    assert "swift_packages" in macos_workflow[True]["workflow_call"]["inputs"]


def test_package_lane_routing_leaves_the_full_suite_jobs_alone() -> None:
    # Leo cut how often the 30-minute suite runs on purpose. Path routing adds
    # one narrow lane; it must not become a second way to ask for the rest.
    # This also keeps the remaining full_suite-only lanes visible: a new one
    # that should be routed has to be added here deliberately.
    full_suite_only = {
        "app-host-unit-tests",
        "tests-build-and-lag",
        "release-admission",
        "release-build",
    }
    for job in full_suite_only:
        block = workflow_job_block(job, MACOS_WORKFLOW)
        condition = next(line for line in block.splitlines() if line.strip().startswith("if:"))
        assert "inputs.full_suite == 'true'" in condition, (job, condition)
        assert "swift_packages" not in condition, (job, condition)

    workflow = MACOS_WORKFLOW.read_text(encoding="utf-8")
    gated_jobs = {
        job
        for job in yaml.safe_load(workflow)["jobs"]
        if "inputs.full_suite == 'true'" in workflow_job_block(job, MACOS_WORKFLOW)
    }
    assert gated_jobs == full_suite_only | {
        "swift-package-tests", "macos-compile-admission", "cli-product-tests"
    }, gated_jobs
    # Package routing must not independently request the targeted CLI lane.
    cli_condition = next(
        line for line in workflow_job_block("cli-product-tests", MACOS_WORKFLOW).splitlines()
        if line.strip().startswith("if:")
    )
    assert "swift_packages" not in cli_condition, cli_condition


def test_routed_package_lane_skips_the_release_helper_build() -> None:
    # release-admission and release-build only run under the full suite, so a
    # routed-only pull request must not pay for zig plus the Ghostty CLI
    # helper to produce an artifact nothing will consume.
    block = workflow_job_block("swift-package-tests", MACOS_WORKFLOW)
    for line in block.splitlines():
        stripped = line.strip()
        if stripped.startswith("if:") and "inputs.release_build == 'true'" in stripped:
            assert "inputs.full_suite == 'true'" in stripped, stripped


def test_package_test_crashes_preserve_a_diagnosable_report() -> None:
    # A signalled test runner prints one SwiftPM line and no frames, so the
    # only evidence a crash leaves behind is the operating system's report.
    # Without this the next one is diagnosed by guessing at the signal number.
    block = workflow_job_block("swift-package-tests", MACOS_WORKFLOW)
    assert "Collect test runner crash reports" in block
    assert "DiagnosticReports" in block
    assert "upload-artifact" in block.split("Collect test runner crash reports", 1)[1]

    # And the retry guard still refuses to retry a crash that had already
    # produced test output, for any signal. Widening it would hide exactly the
    # crash the report above exists to explain.
    # Both retry guards (bonsplit and the package loop) still name only the
    # startup-crash signals. Widening the list is how a genuine crash gets
    # retried into a green check.
    guards = re.findall(r"Exited with unexpected signal code (\[[^']*)'", block)
    assert guards == ["[56]([^0-9]|$)", "[56]([^0-9]|$)"], guards

def test_macos_status_requires_the_lane_the_router_selected() -> None:
    routed = {
        "macos": "true",
        "full_suite": "false",
        "swift_packages": "true",
        "compile_admitted": "true",
        "release_build": "false",
        "source_parent1": "parent",
    }
    results = dict.fromkeys(MACOS_JOBS, "skipped")

    # The routed lane must actually have run.
    assert run_macos_status(inputs=routed, results=results).returncode != 0
    for outcome in ("failure", "cancelled"):
        assert run_macos_status(
            inputs=routed, results={**results, "swift-package-tests": outcome}
        ).returncode != 0, outcome
    assert run_macos_status(
        inputs=routed, results={**results, "swift-package-tests": "success"}
    ).returncode == 0

    # Everything else stays allowed to skip: routing one lane does not quietly
    # require the suite it was carved out of.
    unrouted = {**routed, "swift_packages": "false"}
    assert run_macos_status(inputs=unrouted, results=results).returncode == 0


def test_macos_status_reads_a_missing_package_route_as_unrouted() -> None:
    # A caller from before this input (including the trusted base router on the
    # pull request that introduces it) supplies nothing.
    inputs = {
        "macos": "false",
        "full_suite": "false",
        "compile_admitted": "false",
        "release_build": "false",
        "source_parent1": "",
    }
    for value in ({}, {"swift_packages": ""}):
        result = run_macos_status(
            inputs={**inputs, **value}, results=dict.fromkeys(MACOS_JOBS, "skipped")
        )
        assert result.returncode == 0, (value, result.stderr)


def test_compiled_product_cache_is_opt_in_on_persistent_macos_lanes() -> None:
    for job_name in [
        "app-host-unit-tests",
        "macos-compile-admission",
        "tests-build-and-lag",
    ]:
        block = workflow_job_block(job_name, MACOS_WORKFLOW)
        assert "CMUX_NODE_PRODUCT_CACHE_ROOT: ${{ vars.CMUX_NODE_PRODUCT_CACHE_ROOT }}" in block
        assert "CMUX_NODE_PRODUCT_CACHE_MAX_BYTES: ${{ vars.CMUX_NODE_PRODUCT_CACHE_MAX_BYTES }}" in block
        assert "CMUX_NODE_PRODUCT_CACHE_WAIT_SECONDS: ${{ vars.CMUX_NODE_PRODUCT_CACHE_WAIT_SECONDS }}" in block
        assert "CMUX_ARTIFACT_PEER_URLS: ${{ vars.CMUX_ARTIFACT_PEER_URLS }}" in block
        assert "CMUX_ARTIFACT_PEER_TOKEN_FILE: ${{ vars.CMUX_ARTIFACT_PEER_TOKEN_FILE }}" in block


def test_product_restore_receipt_binds_immutable_product_identity() -> None:
    required_env = (
        "ARTIFACT_ID: ${{ needs.macos-compile-admission.outputs.artifact_id }}",
        "ARTIFACT_PROVIDER_DIGEST: ${{ needs.macos-compile-admission.outputs.artifact_digest }}",
        "EXPECTED_SHA256: ${{ needs.macos-compile-admission.outputs.sha256 }}",
        "CMUX_PRODUCT_CONTRACT: ${{ needs.macos-compile-admission.outputs.product_contract }}",
        "CMUX_PRODUCT_SOURCE_REVISION: ${{ needs.macos-compile-admission.outputs.source_revision }}",
        "CMUX_PRODUCT_PRODUCER_RUN_ID: ${{ needs.macos-compile-admission.outputs.producer_run_id }}",
        "CMUX_PRODUCT_PRODUCER_RUN_ATTEMPT: ${{ needs.macos-compile-admission.outputs.producer_run_attempt }}",
    )
    for job_name in ("app-host-unit-tests", "tests-build-and-lag"):
        block = workflow_job_block(job_name, MACOS_WORKFLOW)
        restore = block[block.index("      - name: Restore compiled app-host test product"):]
        restore = restore[:restore.index("\n      - name:", 1)]
        for binding in required_env:
            assert binding in restore, (job_name, binding)

    script = (ROOT / "scripts/ci/restore-app-host-test-product.sh").read_text(encoding="utf-8")
    for field in (
        '"repository": os.environ["GITHUB_REPOSITORY"]',
        '"artifact_id": int(os.environ["ARTIFACT_ID"])',
        '"provider_digest": os.environ["ARTIFACT_PROVIDER_DIGEST"]',
        '"archive_sha256": os.environ["EXPECTED_SHA256"]',
        '"product_contract": os.environ["CMUX_PRODUCT_CONTRACT"]',
        '"source_revision": os.environ["CMUX_PRODUCT_SOURCE_REVISION"]',
        '"producer_run_id": int(os.environ["CMUX_PRODUCT_PRODUCER_RUN_ID"])',
        '"producer_run_attempt": int(os.environ["CMUX_PRODUCT_PRODUCER_RUN_ATTEMPT"])',
    ):
        assert field in script


def test_compiled_product_source_order_is_local_peer_r2_parallel_github() -> None:
    for job_name in ("app-host-unit-tests", "tests-build-and-lag"):
        block = workflow_job_block(job_name, MACOS_WORKFLOW)
        assert block.index("Try node-local compiled product cache") < block.index("Try trusted fleet peer artifact source")
        assert block.index("Try trusted fleet peer artifact source") < block.index("Try shared R2 artifact transport")
        assert block.index("Try shared R2 artifact transport") < block.index("Try parallel GitHub artifact transport")
        assert block.index("Try parallel GitHub artifact transport") < block.index("Download compiled app-host test product")
        download = block[block.index("      - name: Download compiled app-host test product"):]
        download = download[:download.index("\n      - name:", 1)]
        assert "steps.parallel-products.outputs.hit != 'true'" in download, job_name


def test_r2_transport_is_an_explicit_optional_remote_broker() -> None:
    expected_condition = (
        "if: steps.node-products.outputs.hit != 'true' && "
        "steps.peer-products.outputs.hit != 'true' && "
        "steps.restore-layers.outputs.hit != 'true' && "
        "vars.CI_ARTIFACT_R2_URL != ''"
    )
    for job_name in ("app-host-unit-tests", "tests-build-and-lag"):
        block = workflow_job_block(job_name, MACOS_WORKFLOW)
        start = block.index("      - name: Try shared R2 artifact transport")
        step = block[start:]
        next_step = step.index("\n      - name:", 1)
        r2_step = step[:next_step]
        assert expected_condition in r2_step, job_name
        assert "CI_ARTIFACT_R2_URL: ${{ vars.CI_ARTIFACT_R2_URL }}" in r2_step


PR_LANE_XCODE_PIN = (
    "${{ github.event_name == 'pull_request' "
    "&& (inputs.pr_xcode_app || github.event.pull_request.head.repo.full_name == github.repository "
    "&& vars.CMUX_CI_XCODE_APP_PR || vars.CMUX_CI_XCODE_APP_MACOS_15) "
    "|| vars.CMUX_CI_XCODE_APP_MACOS_15 }}"
)


def test_macos_jobs_use_lane_specific_xcode_pin_vars() -> None:
    # A pull-request job picks its pool through MACOS_RUNNER_PR, and the two
    # macOS images carry different Xcodes: macos-15 ships CMUX_CI_XCODE_APP_MACOS_15
    # and macos-26 ships CMUX_CI_XCODE_APP_MACOS_26. scripts/select-ci-xcode.sh
    # exits non-zero on a pinned path that is not installed, so a pin that does
    # not follow the same lane turns a routing change into a failed job rather
    # than a queued one. Require the pin to resolve through the pull-request
    # escape hatch exactly as runs-on does, with the macos-15 pin as the default
    # on both branches so an unset variable keeps today's behavior.
    # Compile admission, and tests-build-and-lag which restates its route,
    # also send main's full-suite dispatch down the pull-request lane, where
    # seed-derived-data.yml builds the seed admission adopts
    # (tests/test_seed_derived_data.py evaluates both against the seeder).
    admission_pin = PR_LANE_XCODE_PIN.replace(
        "github.event_name == 'pull_request'",
        "(github.event_name == 'pull_request' || github.event_name == 'workflow_dispatch' && github.ref == 'refs/heads/main')",
        1,
    ).replace(
        # A fork pull request leaves the lane's pin; main's dispatch keeps it.
        "github.event.pull_request.head.repo.full_name == github.repository",
        "(github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name == github.repository)",
        1,
    )
    for job_name, pin in [
        ("macos-compile-admission", admission_pin),
        ("tests-build-and-lag", admission_pin),
    ]:
        block = workflow_job_block(job_name, MACOS_WORKFLOW)
        assert f"CMUX_CI_XCODE_APP: {pin}" in block, job_name
        assert "vars.CMUX_CI_XCODE_APP_MACOS_26" not in block, job_name
        assert 'CMUX_CI_REQUIRED_MACOS_SDK_MAJOR: "26"' in block

    # swift-package-tests links the Release Ghostty CLI helper with Zig, which
    # Zig 0.15.2 cannot do on macOS 26, so it stays on the macos-15 pool on
    # every event and keeps the unconditional macos-15 pins. Moving it onto the
    # pull-request lane would hand MACOS_RUNNER_PR a job it must not move.
    package_block = workflow_job_block("swift-package-tests", MACOS_WORKFLOW)
    assert "vars.MACOS_RUNNER_PR" not in package_block
    assert "CMUX_CI_XCODE_APP: ${{ vars.CMUX_CI_XCODE_APP_MACOS_15 }}" in package_block
    assert (
        "CMUX_CI_HELPER_XCODE_APP: ${{ vars.CMUX_CI_HELPER_XCODE_APP_MACOS_15 }}"
        in package_block
    )
    assert 'CMUX_CI_REQUIRED_MACOS_SDK_MAJOR: "26"' in package_block

    release_block = workflow_job_block("release-build", MACOS_WORKFLOW)
    assert "CMUX_CI_XCODE_APP: ${{ vars.CMUX_CI_XCODE_APP_MACOS_26 }}" in release_block
    assert 'CMUX_CI_REQUIRED_MACOS_SDK_MAJOR: "26"' in release_block


def test_required_macos_topology_collapses_display_and_release_helper_jobs() -> None:
    workflow = MACOS_WORKFLOW.read_text(encoding="utf-8")
    runtime_block = workflow_job_block("tests-build-and-lag", MACOS_WORKFLOW)
    package_block = workflow_job_block("swift-package-tests", MACOS_WORKFLOW)
    release_block = workflow_job_block("release-build", MACOS_WORKFLOW)

    assert "vars.MACOS_RUNNER_DUAL_XCODE" in package_block
    assert "\n  ui-regressions:" not in workflow
    assert "\n  release-ghostty-cli-helper:" not in workflow
    assert "restore-app-host-test-product.sh" in runtime_block
    assert "Run display UI regressions" in runtime_block
    assert "scripts/ci/run-display-ui-regressions.sh" in runtime_block
    assert runtime_block.index("Run display UI regressions") < runtime_block.index("Create virtual display")
    assert 'kill -9 "$VDISPLAY_PID"' in runtime_block
    assert "scripts/ci/virtual-display-lock.sh reap-strays" in runtime_block
    assert runtime_block.rfind("scripts/ci/virtual-display-lock.sh reap-strays") < runtime_block.rfind("scripts/ci/virtual-display-lock.sh release")
    assert "timeout-minutes: 40" in package_block
    assert "CMUX_CI_HELPER_XCODE_APP" in package_block
    assert "/Applications/Xcode_16.4.app" not in package_block
    assert "Select helper Xcode" in package_block
    assert "CMUX_CI_REQUIRED_MACOS_SDK_MAJOR=15" in package_block
    assert "Build Release Ghostty CLI helper" in package_block
    assert '[[ "$HELPER_SDK_VERSION" == 15.* ]]' in package_block
    assert "actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a" in package_block
    assert package_block.index("Select helper Xcode") < package_block.index("Build Release Ghostty CLI helper")
    assert package_block.index("Build Release Ghostty CLI helper") < package_block.index("Select Xcode")
    assert package_block.index("Upload Release Ghostty CLI helper") < package_block.index("Select Xcode")
    assert "      - swift-package-tests" in release_block
    assert "Download Release Ghostty CLI helper" in release_block
    assert "actions/download-artifact@37930b1c2abaa49bbe596cd826c3c89aef350131" in release_block
    assert "Install Release helpers" in release_block


def test_swift_package_selection_precedes_optional_tool_setup() -> None:
    block = workflow_job_block("swift-package-tests", MACOS_WORKFLOW)

    select_index = block.index("      - name: Select package tests")
    ghostty_index = block.index("      - name: Capture Ghostty revision")
    rust_index = block.index("      - name: Install Rust")
    unit_index = block.index("      - name: Run Swift package unit tests")

    assert select_index < ghostty_index < unit_index
    assert select_index < rust_index < unit_index
    assert "needs_ghosttykit=true" in block
    assert "needs_rust=true" in block
    assert "if: ${{ steps.select.outputs.needs_ghosttykit == 'true' }}" in block
    assert "if: ${{ steps.select.outputs.needs_rust == 'true' }}" in block
    assert "SELECTED_PACKAGES: ${{ steps.select.outputs.selected_packages }}" in block
    assert 'done < "$selected"' in block
    assert block.count("python3 scripts/ci/select_package_tests.py") == 1

    app_host = workflow_job_block("app-host-unit-tests", MACOS_WORKFLOW)
    assert "steps.select.outputs.needs_ghosttykit" not in app_host
    assert "steps.select.outputs.needs_rust" not in app_host


def test_remote_tmux_layout_identity_uses_a_nontolerant_focused_gate() -> None:
    block = workflow_job_block("app-host-unit-tests", MACOS_WORKFLOW)
    step = "Run remote tmux mirror layout identity regression"
    selector = "-only-testing:cmuxTests/RemoteTmuxMirrorLayoutIdentityTests"

    assert step in block
    assert selector in block
    assert block.index(step) < block.index("- name: Run unit tests")


def test_settings_store_noop_persistence_uses_a_nontolerant_focused_gate() -> None:
    block = workflow_job_block("app-host-unit-tests", MACOS_WORKFLOW)
    step = "Run settings file-store no-op persistence regression"
    selector = "-only-testing:cmuxTests/KeyboardShortcutSettingsFileStoreNoOpPersistenceTests"

    assert step in block
    assert selector in block
    assert block.index(step) < block.index("- name: Run unit tests")


def test_determinism_workflow_runs_self_test_before_strict_scan() -> None:
    script = workflow_job_step_script(
        "workflow-guard-tests", "Validate test determinism gate", GUARD_WORKFLOW
    )

    assert "scripts/check-test-determinism.py --self-test" in script
    assert "scripts/check-test-determinism.py --strict" in script
    assert script.index("--self-test") < script.index("--strict")


def test_app_host_multi_batch_failure_cannot_reuse_prior_expected_summary() -> None:
    result, runner_invoked = run_app_host_unit_test_step()

    assert runner_invoked
    assert result.returncode != 0, result.stdout
    assert result.stdout.count("simulated app-host crash before test summary") == 1


def test_app_host_catalogued_failure_is_tolerated_with_red_xcode_status() -> None:
    result, runner_invoked = run_app_host_unit_test_step(known_failure=True)

    assert runner_invoked
    assert result.returncode == 0, result.stdout + result.stderr
    assert "RATCHET_KNOWN_FAILURE FakeTests/testOne()" in result.stdout


def test_app_host_ratchet_uses_built_inventory_and_typed_results() -> None:
    app_host = workflow_job_block("app-host-unit-tests", MACOS_WORKFLOW)
    assert "- name: Enumerate built app-host tests" in app_host
    assert "run: scripts/ci/run-app-host-unit-batches.sh" in app_host
    app_host += (ROOT / "scripts/ci/enumerate-app-host-tests.sh").read_text(encoding="utf-8")
    run_script = (ROOT / "scripts/ci/run-app-host-unit-batches.sh").read_text(encoding="utf-8")

    assert "-enumerate-tests" in app_host
    assert "CMUX_APP_HOST_TEST_INVENTORY" in app_host
    assert "app_host_result_accounting.py inventory" in app_host
    assert "app_host_result_accounting.py check-run" in run_script
    assert "--tests-json" in run_script
    assert "app-host-known-failures.json" in run_script


def run_focused_app_host_step(
    outcomes: list[str],
    step_name: str = "Run remote tmux mirror detach and placement regressions",
) -> tuple[subprocess.CompletedProcess[str], int]:
    """Run a focused app-host gate against a fake console runner.

    ``outcomes`` lists what each xcodebuild invocation reports, in order:
    ``pass``; ``crash`` (xcodebuild restarted the app host, exit 65); or
    ``fail`` (an assertion failure with the host alive, exit 65). Returns the
    step result and how many times the runner was invoked.
    """
    script = workflow_job_step_script("app-host-unit-tests", step_name, MACOS_WORKFLOW)

    with tempfile.TemporaryDirectory() as temp_dir:
        root = Path(temp_dir)
        runner_temp = root / "runner"
        ci_scripts = root / "scripts" / "ci"
        runner_temp.mkdir()
        ci_scripts.mkdir(parents=True)
        shutil.copy2(
            ROOT / "scripts/ci/require_selected_test_execution.sh",
            ci_scripts / "require_selected_test_execution.sh",
        )
        shutil.copy2(
            ROOT / "scripts/ci/run-and-capture.sh",
            ci_scripts / "run-and-capture.sh",
        )
        outcomes_file = root / "outcomes"
        outcomes_file.write_text("\n".join(outcomes) + "\n", encoding="utf-8")
        counter = root / "invocations"

        console_runner = ci_scripts / "run-in-console-session.sh"
        console_runner.write_text(
            """
#!/bin/bash
set -euo pipefail
counter="${CMUX_TEST_INVOCATION_COUNTER:?}"
iteration=0
if [ -f "$counter" ]; then
  iteration="$(cat "$counter")"
fi
iteration=$((iteration + 1))
printf '%s\\n' "$iteration" > "$counter"
outcome="$(sed -n "${iteration}p" "${CMUX_TEST_OUTCOMES:?}")"
printf 'invocation %s: %s\\n' "$iteration" "$*"
case "$outcome" in
  empty)
    echo "Executed 0 tests, with 0 failures (0 unexpected)"
    exit 0
    ;;
  pass)
    echo "Executed 7 tests, with 0 failures (0 unexpected)"
    exit 0
    ;;
  crash)
    echo "Restarting after unexpected exit, crash, or test timeout; summary will include totals from previous launches."
    echo "Executed 7 tests, with 1 failure (1 unexpected)"
    exit 65
    ;;
  fail)
    echo "Executed 7 tests, with 1 failure (0 unexpected)"
    exit 65
    ;;
  *)
    echo "unexpected extra invocation ${iteration}" >&2
    exit 97
    ;;
esac
""".lstrip(),
            encoding="utf-8",
        )
        console_runner.chmod(0o755)

        result = subprocess.run(
            ["bash", "-c", script],
            cwd=root,
            env={
                **os.environ,
                "RUNNER_TEMP": str(runner_temp),
                "CMUX_APP_HOST_XCTESTRUN": str(root / "cmux-unit.xctestrun"),
                "CMUX_NUMERIC_LOCALE_XCTESTRUN": str(root / "numeric.xctestrun"),
                "CMUX_DERIVED_DATA_PATH": str(root / "derived-data"),
                "CMUX_TEST_INVOCATION_COUNTER": str(counter),
                "CMUX_TEST_OUTCOMES": str(outcomes_file),
            },
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        invocations = int(counter.read_text(encoding="utf-8").strip()) if counter.exists() else 0
        return result, invocations


def test_remote_tmux_mirror_gate_keeps_a_crash_red_without_rerunning() -> None:
    result, invocations = run_focused_app_host_step(["crash", "pass", "pass"])

    assert result.returncode == 65, result.stdout + result.stderr
    assert invocations == 1, result.stdout
    assert "rerunning the suite once" not in result.stdout


def test_remote_tmux_mirror_gate_keeps_an_assertion_failure_red() -> None:
    result, invocations = run_focused_app_host_step(["fail", "pass", "pass"])

    assert result.returncode == 65, result.stdout + result.stderr
    assert invocations == 1, result.stdout
    assert "rerunning the suite once" not in result.stdout


def test_remote_tmux_mirror_gate_runs_each_suite_once_on_success() -> None:
    result, invocations = run_focused_app_host_step(["pass", "pass", "pass"])

    assert result.returncode == 0, result.stdout + result.stderr
    assert invocations == 3, result.stdout
    assert result.stdout.count("-only-testing:cmuxTests/RemoteTmuxMirrorCloseDetachTests") == 1
    assert result.stdout.count("-only-testing:cmuxTests/RemoteTmuxMirrorFocusPolicyTests") == 1
    assert result.stdout.count("-only-testing:cmuxTests/RemoteTmuxMirrorDedicatedPlacementTests") == 1


def test_devices_gate_propagates_assertion_failures_and_crashes() -> None:
    for outcome in ("fail", "crash"):
        result, invocations = run_focused_app_host_step(
            [outcome, "pass"], "Run My Devices regressions"
        )
        assert result.returncode == 65, result.stdout + result.stderr
        assert invocations == 1, result.stdout


def test_devices_gate_accepts_successful_execution() -> None:
    result, invocations = run_focused_app_host_step(["pass"], "Run My Devices regressions")
    assert result.returncode == 0, result.stdout + result.stderr
    assert invocations == 1, result.stdout


def test_global_search_gate_requires_nonempty_successful_execution() -> None:
    for outcome, expected_status in (("pass", 0), ("fail", 65), ("empty", 1)):
        result, invocations = run_focused_app_host_step(
            [outcome], step_name="Run global search shortcut regressions"
        )
        assert result.returncode == expected_status, result.stdout + result.stderr
        assert invocations == 1, result.stdout
        assert "-only-testing:cmuxTests/GlobalSearchShortcutBehaviorTests" in result.stdout
        # The compile admission job supplies the build products, so focused
        # gates must use test-without-building just like the sharded batches.
        assert "test-without-building" in result.stdout


def test_app_host_rejects_failed_or_empty_shard_generation() -> None:
    for shard_mode in ("fail", "empty"):
        result, runner_invoked = run_app_host_unit_test_step(shard_mode)

        assert result.returncode != 0, (shard_mode, result.stdout)
        assert not runner_invoked, (shard_mode, result.stdout)


def test_agent_session_web_resources_runs_only_for_agent_session_web_area() -> None:
    block = workflow_job_block("agent-session-web-resources", WEB_WORKFLOW)

    assert "if: ${{ inputs.agent_session_web == 'true' }}" in block


def test_perf_activation_runs_for_its_own_workflow_and_not_for_others() -> None:
    _, outputs = run_detect_step_for_paths([".github/workflows/relay-tls.yml"], PERF_ACTIVATION_WORKFLOW)
    assert outputs == [
        "macos=false",
        "web=false",
        "agent_session_web=false",
        "cli=false",
        "swift_packages=false",
        "release_build=false",
    ]

    for path in (".github/workflows/perf-activation.yml", "scripts/ci/subprocess.py"):
        result, outputs = run_detect_step_for_paths([path], PERF_ACTIVATION_WORKFLOW)
        assert "CI router changed; running activation benchmark." in result.stdout, path
        assert outputs[0] == "macos=true", (path, outputs)


def test_perf_activation_workflow_keeps_required_status_while_gating_benchmark() -> None:
    result, outputs = run_detect_step_for_paths(["docs/ci-runners.md"], PERF_ACTIVATION_WORKFLOW)

    assert "Resolved areas: macos=false web=false" in result.stdout
    assert outputs == [
        "macos=false",
        "web=false",
        "agent_session_web=false",
        "cli=false",
        "swift_packages=false",
        "release_build=false",
    ]

    benchmark = workflow_job_block("activation-session-benchmark", PERF_ACTIVATION_WORKFLOW)
    sentinel = workflow_job_block("activation-session", PERF_ACTIVATION_WORKFLOW)

    assert "needs: activation_changes" in benchmark
    assert "if: ${{ needs.activation_changes.outputs.macos == 'true' }}" in benchmark
    # The benchmark routes through MACOS_RUNNER_15 (Blacksmith) for all events,
    # including PRs. Manual runner overrides stay outside required CI.
    assert "vars.MACOS_RUNNER_15" in benchmark

    assert "      - activation_changes" in sentinel
    assert "      - activation-session-benchmark" in sentinel
    assert "if: ${{ always() }}" in sentinel
    assert 'macos == "true" and benchmark["result"] != "success"' in sentinel
    assert 'benchmark["result"] not in {"success", "skipped"}' in sentinel


def test_guard_bun_setup_runs_only_for_owned_groups() -> None:
    block = workflow_job_block("workflow-guard-tests", GUARD_WORKFLOW)
    setup = block.index("      - name: Set up Bun for guard tests")
    next_step = block.index("      - name: Run agent-chat unit tests", setup)
    setup_block = block[setup:next_step]
    assert "if: ${{ matrix.group == 'preflight' || matrix.group == 'release-ios' }}" in setup_block
    assert block.count("setup-bun@") == 1


def test_guard_python_setup_is_scoped_to_owning_groups() -> None:
    block = workflow_job_block("workflow-guard-tests", GUARD_WORKFLOW)
    setup = block.index("      - name: Set up Python 3.9 for nightly prune compatibility")
    prepare = block.index("      - name: Prepare workflow guard Python dependencies", setup)
    setup_block = block[setup:prepare]
    assert "if: ${{ matrix.group == 'release-tooling' }}" in setup_block
    prepare_block = block[
        prepare:block.index("      - name: Validate Blacksmith Testbox broker trust boundary", prepare)
    ]
    # release-notary joined when test_release_homebrew_gate.py was wired there:
    # it imports yaml, and that was the one group running Python guards without
    # the venv.
    # preflight needs YAML traversal for the macOS runner identity guard.
    assert (
        "if: ${{ matrix.group == 'preflight' || matrix.group == 'ci' || matrix.group == 'app-host-execution' || "
        "matrix.group == 'app-host-process' || matrix.group == 'app-host-cache' || "
        "matrix.group == 'release-notary' || matrix.group == 'release-tooling' }}"
    ) in prepare_block
    assert "python3 -m venv" in prepare_block
    assert "packages=(PyYAML==6.0.3)" in prepare_block
    assert 'if [[ "${{ matrix.group }}" == "release-tooling" ]]; then' in prepare_block
    assert "packages+=(bashlex==0.18)" in prepare_block
    assert '"${packages[@]}"' in prepare_block
    assert block.count("actions/setup-python@") == 1


def test_pipe_safe_capture_guard_runs_once_in_app_host_execution_group() -> None:
    block = workflow_job_block("workflow-guard-tests", GUARD_WORKFLOW)
    start = block.index("      - name: Validate pipe-safe CI capture")
    end = block.index("      - name: Validate focused test launcher", start)
    step = block[start:end]
    assert "if: ${{ matrix.group == 'app-host-execution' }}" in step
    assert block.count("Validate pipe-safe CI capture") == 1


def test_reuse_lookups_match_the_job_name_github_actually_reports() -> None:
    """The producer lookups must survive ci.yml reaching admission indirectly.

    `.github/workflows/ci.yml` calls `ci-macos.yml`, so the admission job is
    reported as "<caller job key> / <job name>", not by its bare name. Both
    reuse paths previously compared the whole string and therefore stopped
    finding any producer the moment that indirection was introduced, with no
    failing test and no CI signal. Derive the composed name from the workflows
    themselves so a future move breaks this test instead of reuse.
    """
    import yaml

    ci = yaml.safe_load((ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8"))
    caller = next(
        (key for key, job in ci["jobs"].items()
         if str(job.get("uses", "")).endswith("/ci-macos.yml")),
        None,
    )
    assert caller, "no ci.yml job calls ci-macos.yml"

    macos = yaml.safe_load((ROOT / ".github/workflows/ci-macos.yml").read_text(encoding="utf-8"))
    inner = macos["jobs"]["macos-compile-admission"]["name"]
    composed = f"{caller} / {inner}"

    sys.path.insert(0, str(ROOT / "scripts/ci"))
    from find_admitted_build import ADMISSION_JOB, admission_job_name

    assert inner == ADMISSION_JOB, f"ci-macos.yml job name {inner!r} != ADMISSION_JOB {ADMISSION_JOB!r}"
    assert admission_job_name(composed), f"find_admitted_build does not match {composed!r}"
    assert admission_job_name(inner), "the bare name must still match for inlined callers"
    assert not admission_job_name("macos / some other job")
    assert not admission_job_name(None)

    # Each trusted producer workflow names the job that has to have compiled.
    sys.path.insert(0, str(ROOT / "scripts/ci"))
    import reuse_app_host_products

    # Match the final segment of the job name, and a matrix job's
    # "<name> (<values>)", as seed-derived-data.yml's "seed (<pool>)".
    names = reuse_app_host_products.names_compile_job
    assert names(composed, ADMISSION_JOB), "reuse_app_host_products.py must match the final segment of the job name"
    assert names(inner, ADMISSION_JOB)
    assert names("seed (blacksmith-12vcpu-macos-26)", "seed")
    assert not names("macos / some other job", ADMISSION_JOB)
    assert not names("seeder", "seed")
    assert not names(None, "seed")

    assert reuse_app_host_products.COMPILE_JOBS[".github/workflows/ci.yml"][0] == ADMISSION_JOB, (
        "reuse_app_host_products.py must look for ci.yml's admission job by its real name"
    )
    # A run reports its caller as `path`, so ci.yml's producer job is defined
    # in the reusable workflow it calls rather than in ci.yml itself.
    definitions = {
        ".github/workflows/ci.yml": ".github/workflows/ci-macos.yml",
        ".github/workflows/test-e2e.yml": ".github/workflows/test-e2e.yml",
        ".github/workflows/seed-derived-data.yml": ".github/workflows/seed-derived-data.yml",
    }
    for path, (job_name, step_name) in reuse_app_host_products.COMPILE_JOBS.items():
        workflow = yaml.safe_load((ROOT / definitions[path]).read_text(encoding="utf-8"))
        producer = next(
            (job for job in workflow["jobs"].values()
             if job.get("name", "") == job_name), None,
        ) or workflow["jobs"].get(job_name)
        assert producer is not None, f"{path} has no job named {job_name!r}"
        assert any(step.get("name") == step_name for step in producer["steps"]), (
            f"{path} job {job_name!r} has no step named {step_name!r}"
        )



def test_trusted_router_reads_new_guard_tests_from_the_pr_head() -> None:
    # A routing-policy PR is classified by the base router, whose workflows
    # have never named a guard test the PR adds. Merging the head's references
    # keeps that test Linux-only; a head macOS job naming it still counts.
    def write_root(root: Path, guards_block: str, macos_block: str) -> None:
        (root / "scripts/ci/workloads").mkdir(parents=True)
        (root / "scripts/ci/workloads/ci-guard.sh").write_text(
            "python3 tests/test_existing_guard.py\n", encoding="utf-8"
        )
        (root / ".github/workflows").mkdir(parents=True)
        linux = "name: fixture\njobs:\n  guard:\n    runs-on: ubuntu-24.04\n    steps:\n      - run: python3 tests/test_existing_guard.py\n"
        for name in ("ci.yml", "ci-web.yml"):
            (root / ".github/workflows" / name).write_text(linux, encoding="utf-8")
        (root / ".github/workflows/ci-guards.yml").write_text(linux + guards_block, encoding="utf-8")
        (root / ".github/workflows/ci-macos.yml").write_text(
            "name: fixture\njobs:\n  mac:\n    runs-on: macos-15\n    steps:\n      - run: echo mac\n" + macos_block,
            encoding="utf-8",
        )

    with tempfile.TemporaryDirectory() as base_dir, tempfile.TemporaryDirectory() as head_dir:
        base, head = Path(base_dir), Path(head_dir)
        write_root(base, "", "")
        write_root(head, "      - run: python3 tests/test_new_guard.py\n", "")
        previous = os.environ.pop(module.HEAD_TEST_REFERENCE_ROOT_ENV, None)
        try:
            base_only = module.load_macos_job_test_references(base)
            assert not module.is_guard_only_test("tests/test_new_guard.py", base_only)

            os.environ[module.HEAD_TEST_REFERENCE_ROOT_ENV] = str(head)
            merged = module.load_macos_job_test_references(base)
            assert module.is_guard_only_test("tests/test_new_guard.py", merged)

            shutil.rmtree(head)
            head.mkdir()
            write_root(head, "", "      - run: python3 tests/test_new_guard.py\n")
            macos_named = module.load_macos_job_test_references(base)
            assert not module.is_guard_only_test("tests/test_new_guard.py", macos_named)
        finally:
            os.environ.pop(module.HEAD_TEST_REFERENCE_ROOT_ENV, None)
            if previous is not None:
                os.environ[module.HEAD_TEST_REFERENCE_ROOT_ENV] = previous


def test_claude_wrapper_inputs_use_standalone_lane_without_native_compile() -> None:
    for paths in (["Resources/bin/cmux-claude-wrapper"],
                  ["tests/test_claude_wrapper_hooks.py"],
                  ["Resources/bin/cmux-claude-wrapper", "tests/test_claude_wrapper_hooks.py"]):
        areas = module.classify_files(paths)
        assert not areas.macos and not areas.cli and not areas.release_build and not areas.swift_packages, (paths, areas)
        assert module.classify_files([*paths, "Sources/AppDelegate.swift"]).macos
    assert module.classify_files(["Resources/bin/cmux-unknown-wrapper"]).macos


def test_claude_wrapper_scope_executes_workflow_shell() -> None:
    workflow = yaml.safe_load(CI_WORKFLOW.read_text(encoding="utf-8"))
    script = next(step["run"] for step in workflow["jobs"]["changes"]["steps"] if step.get("id") == "standalone")
    for paths, expected in (
        (["Resources/bin/cmux-claude-wrapper"], "true"),
        (["tests/test_claude_wrapper_hooks.py"], "true"),
        (["tests/node_runtime.py"], "true"),
        (["scripts/ci/run_python_test_lane.py"], "true"),
        (["scripts/ci/test_execution_registry.py"], "true"),
        # Every new test registers here, so this path alone must not wake a
        # Mac for the wrapper suite. The wrapper's own registration is pinned
        # on Linux by test_claude_wrapper_has_one_independent_registry_execution.
        (["tests/test-execution.toml"], "false"),
        (["tests/test-execution.toml", "tests/test_claude_wrapper_hooks.py"], "true"),
        ([".github/workflows/ci.yml"], "true"),
        (["Resources/bin/cmux-claude-wrapper", "Sources/AppDelegate.swift"], "true"),
        (["Sources/AppDelegate.swift"], "false"),
        (["docs/example.md"], "false"),
        ([], "false"),
        (None, "true"),
    ):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            changed = root / "changed.txt"
            if paths is not None:
                changed.write_text("\n".join(paths) + "\n")
            output = root / "output.txt"
            run = subprocess.run(["bash", "-c", isolate_ci_tmp(script.replace("/tmp/cmux-ci-changed-files.txt", str(changed)), root)],
                                 env={**os.environ, "GITHUB_OUTPUT": str(output)}, capture_output=True, text=True)
            assert run.returncode == 0, run.stderr
            assert f"claude_wrapper={expected}" in output.read_text().splitlines(), (paths, output.read_text())


def test_claude_wrapper_job_runs_without_full_suite_or_app_compile() -> None:
    workflow = yaml.safe_load(CI_WORKFLOW.read_text(encoding="utf-8"))
    condition = workflow["jobs"]["claude-wrapper"]["if"].strip()[3:-2].strip()
    for wrapper, macos, full_suite, expected in (
        ("true", "false", "false", True),
        ("true", "true", "false", True),
        ("false", "true", "true", True),
        ("false", "true", "false", False),
        ("false", "false", "true", False),
    ):
        outputs = {"claude_wrapper": wrapper, "macos": macos, "full_suite": full_suite}
        expression = re.sub(r"needs\.changes\.outputs\.([a-z_]+)", lambda m: repr(outputs[m.group(1)]), condition)
        expression = re.sub(r"needs\.[a-z-]+\.result", repr("success"), expression)
        expression = expression.replace("!cancelled()", "True").replace("&&", " and ").replace("||", " or ")
        assert eval(expression, {"__builtins__": {}}, {}) is expected, (outputs, condition)


def test_ci_status_requires_successful_claude_wrapper_execution_when_routed() -> None:
    workflow = yaml.safe_load(CI_WORKFLOW.read_text(encoding="utf-8"))
    job = workflow["jobs"]["ci-status"]
    script = next(step["run"] for step in job["steps"] if step.get("name") == "Check routed CI jobs")
    for route in ({"claude_wrapper": "true", "macos": "false", "full_suite": "false"},
                  {"claude_wrapper": "false", "macos": "true", "full_suite": "true"}):
        for result in ("success", "failure", "skipped", "cancelled", "missing"):
            needs = {name: {"result": "skipped"} for name in job["needs"]}
            needs["changes"] = {"result": "success", "outputs": route}
            if "claude-wrapper" in needs:
                if result == "missing":
                    needs.pop("claude-wrapper")
                else:
                    needs["claude-wrapper"]["result"] = result
            run = subprocess.run(["bash", "-c", script], env={**os.environ, "CI_NEEDS": json.dumps(needs)},
                                 capture_output=True, text=True)
            assert (run.returncode == 0) == (result == "success"), (route, result, run.stdout, run.stderr)
    needs = {name: {"result": "skipped"} for name in job["needs"]}
    needs["changes"] = {"result": "success", "outputs": {"claude_wrapper": "false", "macos": "false", "full_suite": "false"}}
    run = subprocess.run(["bash", "-c", script], env={**os.environ, "CI_NEEDS": json.dumps(needs)}, capture_output=True, text=True)
    assert run.returncode == 0, run.stderr


def test_claude_wrapper_has_one_independent_registry_execution() -> None:
    runner = ROOT / "scripts/ci/run_python_test_lane.py"
    dedicated = subprocess.run([sys.executable, str(runner), "--lane", "macos-claude-wrapper", "--list"], capture_output=True, text=True)
    assert dedicated.returncode == 0, dedicated.stderr
    assert dedicated.stdout.splitlines() == ["tests/test_claude_wrapper_hooks.py"]
    app_host = subprocess.run([sys.executable, str(runner), "--lane", "macos-cli-no-socket", "--list"], capture_output=True, text=True)
    assert app_host.returncode == 0, app_host.stderr
    assert "tests/test_claude_wrapper_hooks.py" not in app_host.stdout.splitlines()


def test_claude_wrapper_job_rejects_missing_node_before_legacy_skip() -> None:
    workflow = yaml.safe_load(CI_WORKFLOW.read_text(encoding="utf-8"))
    job = workflow["jobs"]["claude-wrapper"]
    script = next(step["run"] for step in job["steps"] if step.get("name") == "Run standalone Claude wrapper regressions")
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        marker = root / "python-ran"
        python = root / "python3"
        python.write_text("#!/bin/sh\n: > \"$MARKER\"\nexit 0\n")
        python.chmod(0o755)
        run = subprocess.run(["/bin/bash", "-c", script], env={"PATH": str(root), "MARKER": str(marker)}, capture_output=True, text=True)
        assert run.returncode != 0, run.stdout
        assert not marker.exists(), "Node preflight must fail before the legacy test could report SKIP"


def _run_named_test(name: str) -> tuple[str, str | None]:
    import traceback

    try:
        globals()[name]()
    except BaseException:
        return name, traceback.format_exc()
    return name, None


def _main() -> int:
    names = sorted(name for name, value in globals().items() if name.startswith("test_") and callable(value))
    # Most of these tests wait on git and the router in subprocesses, so they
    # overlap well. Each runs in its own forked worker: a test that patches
    # module state or the environment cannot leak into the next one.
    # CMUX_TEST_WORKERS=1 runs them in order in this process, as before.
    requested = os.environ.get("CMUX_TEST_WORKERS", "")
    if requested and not requested.isdigit():
        print(f"CMUX_TEST_WORKERS must be a whole number, got {requested!r}", file=sys.stderr)
        return 2
    workers = int(requested) if requested else len(os.sched_getaffinity(0)) if hasattr(os, "sched_getaffinity") else 1
    if workers <= 1 or sys.platform != "linux":
        for name in names:
            globals()[name]()
        return 0
    import multiprocessing

    failures = []
    with multiprocessing.get_context("fork").Pool(workers, maxtasksperchild=1) as pool:
        results = pool.imap_unordered(_run_named_test, names)
        pending = set(names)
        while pending:
            try:
                # A worker that dies outright (a signal, os._exit) never
                # returns its test, and Pool would wait forever.
                name, error = results.next(timeout=600)
            except multiprocessing.TimeoutError:
                failures.extend(
                    (name, "no result within 600 s: the test hung or its worker died\n")
                    for name in sorted(pending)
                )
                pool.terminate()
                break
            pending.discard(name)
            if error:
                failures.append((name, error))
    for name, error in sorted(failures):
        print(f"FAIL: {name}\n{error}", file=sys.stderr)
    if failures:
        print(f"{len(failures)} of {len(names)} tests failed", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    if _main() == 0:
        print("PASS: CI change area filter")
    else:
        sys.exit(1)
