# Keep CI change-area routing exercised when guard policy files change.
#!/usr/bin/env python3
"""Behavioral tests for the CI path filter."""

from __future__ import annotations

import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import textwrap
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "scripts" / "ci" / "detect_ci_change_areas.py"
AREA_TABLE = ROOT / ".github" / "ci-areas.yml"
CI_WORKFLOW = ROOT / ".github" / "workflows" / "ci.yml"
GUARD_WORKFLOW = ROOT / ".github" / "workflows" / "ci-guards.yml"
WEB_WORKFLOW = ROOT / ".github" / "workflows" / "ci-web.yml"
MACOS_WORKFLOW = ROOT / ".github" / "workflows" / "ci-macos.yml"
WEB_VALIDATION_WORKFLOW = ROOT / ".github" / "workflows" / "web-validation.yml"
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
    "swift-package-tests",
    "tests-build-and-lag",
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


def test_anything_the_app_can_build_from_runs_the_release_build() -> None:
    for path in (
        "Sources/AppDelegate.swift",
        "CLI/cmux.swift",
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


def test_release_build_follows_the_other_areas_when_macos_is_skipped_or_forced() -> None:
    assert module.classify_files(["docs/ci.md"]).release_build is False
    assert module.classify_files([".github/workflows/ci.yml"]).release_build is True
    assert module.classify_files([".github/workflows/ci-guards.yml"]).release_build is False
    assert module.ChangeAreas.all().release_build is True


def test_test_only_pull_request_routes_macos_without_the_release_build() -> None:
    result, outputs = run_detect_step_for_paths(["cmuxTests/GhosttyConfigTests.swift"])

    assert result.returncode == 0, result.stderr
    assert outputs == ["macos=true", "web=false", "agent_session_web=false", "release_build=false"]


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


def test_app_source_runs_macos() -> None:
    assert_areas(["Sources/AppDelegate.swift"], macos=True, web=False)


def test_workflow_changes_run_everything() -> None:
    assert_areas(
        [".github/workflows/ci.yml"],
        macos=True,
        web=True,
        agent_session_web=True,
    )


def test_macos_test_product_ci_helpers_run_admission_without_web_or_release() -> None:
    for path in (
        "scripts/ci/app_host_test_products.py",
        "scripts/ci/compile-app-host-test-product.sh",
        "scripts/ci/product_input_identity.py",
        "scripts/ci/restore-app-host-test-product.sh",
        "scripts/ci/reuse_app_host_products.py",
        "scripts/ci/sanitize-xcode-source-packages-cache.py",
    ):
        actual = module.classify_files([path])
        assert actual.macos is True, (path, actual)
        assert actual.web is False, (path, actual)
        assert actual.agent_session_web is False, (path, actual)
        assert actual.release_build is False, (path, actual)


def test_unknown_ci_helper_still_fails_open_to_every_area() -> None:
    assert module.classify_files(["scripts/ci/future_unknown_helper.py"]) == module.ChangeAreas.all()


def test_guard_workflow_and_persistent_router_skip_product_areas() -> None:
    for path in (
        ".github/workflows/ci-guards.yml",
        "scripts/ci/persistent_mac_route.py",
        "tests/test_ci_persistent_mac_compile.py",
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


def test_guard_only_tests_skip_macos() -> None:
    for path in (
        "tests/test_ci_self_hosted_guard.sh",
        "tests/test_ci_persistent_mac_compile.py",
        "tests/test_ci_app_host_pipe_capture.py",
        "tests/test_ci_run_and_capture.sh",
        "tests/test_ci_workload_profiles.py",
    ):
        assert_areas([path], macos=False, web=False)
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


def test_area_table_defaults_unknown_paths_to_macos_and_release() -> None:
    table = module.load_area_table()
    assert table["macos"].default is True
    assert table["web"].default is False
    assert table["agent_session_web"].default is False

    actual = module.classify_files(["some-new-top-level-dir/file.txt"])
    assert actual.macos is True
    assert actual.release_build is True
    assert actual.web is False
    assert actual.agent_session_web is False


def test_area_table_is_the_only_path_ownership_source() -> None:
    source = HELPER.read_text(encoding="utf-8")
    for deleted_name in (
        "split_workflow_jobs",
        "job_is_plainly_linux",
        "ci_workflow_change_is_linux_only",
        "macos_job_test_references",
        "is_guard_only_test",
        "--ci-workflow-base",
    ):
        assert deleted_name not in source
    assert AREA_TABLE.is_file()
    assert module.AREA_TABLE_PATH == AREA_TABLE


def test_area_table_preserves_current_control_plane_ownership() -> None:
    table = module.load_area_table()
    for path in ("scripts/ci/persistent_mac_route.py", "scripts/ci/web_validation.py"):
        assert module._force_all(table, path) is False

    persistent = module.classify_files(["scripts/ci/persistent_mac_route.py"])
    assert persistent == module.ChangeAreas(
        macos=False, web=False, agent_session_web=False, release_build=False
    )

    web_control = module.classify_files(["scripts/ci/web_validation.py"])
    assert web_control == module.ChangeAreas(
        macos=False, web=True, agent_session_web=False, release_build=False
    )

    for path in (
        "scripts/ci/app_host_test_products.py",
        "scripts/ci/compile-app-host-test-product.sh",
        "scripts/ci/product_input_identity.py",
        "scripts/ci/restore-app-host-test-product.sh",
        "scripts/ci/reuse_app_host_products.py",
        "scripts/ci/sanitize-xcode-source-packages-cache.py",
    ):
        actual = module.classify_files([path])
        assert actual == module.ChangeAreas(
            macos=True, web=False, agent_session_web=False, release_build=False
        ), path

    assert module.classify_files(["scripts/ci/future_unknown_helper.py"]) == module.ChangeAreas.all()


def test_ci_router_runs_on_every_pr_and_merge_group() -> None:
    workflow = CI_WORKFLOW.read_text(encoding="utf-8")
    assert "  pull_request:\n  merge_group:" in workflow
    assert "    paths:" not in workflow

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
    script = workflow_job_step_script("linux-preflight", "Check cheap CI layer before macOS runners")
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
) -> tuple[subprocess.CompletedProcess[str], bool]:
    script = workflow_job_step_script("app-host-unit-tests", "Run unit tests", MACOS_WORKFLOW)
    script = script.replace("${{ matrix.shard }}", "1")

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
if [ "$iteration" -eq 1 ]; then
  echo "Executed 2 tests, with 2 failures (0 unexpected)"
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
        selected_subareas = {
            "db": "true",
            "instant": "true",
            "react_apps": "true",
        } if route_inputs["web"] == "true" else {
            "db": "false",
            "instant": "false",
            "react_apps": "false",
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
        "source_identity_valid": "true",
        "source_tree": "tree",
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
) -> tuple[subprocess.CompletedProcess[str], list[str]]:
    script = detect_step_script(workflow_path)
    with tempfile.TemporaryDirectory() as temp_dir:
        repo = Path(temp_dir)
        subprocess.run(["git", "init", "-q"], cwd=repo, check=True)
        subprocess.run(["git", "config", "user.email", "ci@example.test"], cwd=repo, check=True)
        subprocess.run(["git", "config", "user.name", "CI Test"], cwd=repo, check=True)
        helper_copy = repo / "scripts" / "ci" / "detect_ci_change_areas.py"
        helper_copy.parent.mkdir(parents=True, exist_ok=True)
        helper_copy.write_text(HELPER.read_text(encoding="utf-8"), encoding="utf-8")
        table_copy = repo / ".github" / "ci-areas.yml"
        table_copy.parent.mkdir(parents=True, exist_ok=True)
        table_copy.write_text(AREA_TABLE.read_text(encoding="utf-8"), encoding="utf-8")
        (repo / "base.txt").write_text("base\n", encoding="utf-8")
        subprocess.run(["git", "add", "."], cwd=repo, check=True)
        subprocess.run(["git", "commit", "-q", "-m", "base"], cwd=repo, check=True)
        base_sha = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip()

        if paths:
            for path in paths:
                target = repo / path
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text("changed\n", encoding="utf-8")
            subprocess.run(["git", "add", "."], cwd=repo, check=True)
            subprocess.run(["git", "commit", "-q", "-m", "head"], cwd=repo, check=True)
            head_sha = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip()
        else:
            head_sha = base_sha

        output_path = repo / "github-output.txt"
        env = {
            **os.environ,
            "EVENT_NAME": "pull_request",
            "BASE_SHA": base_sha,
            "HEAD_SHA": head_sha,
            "MERGE_SHA": head_sha,
            "GITHUB_OUTPUT": str(output_path),
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
        return result, output_path.read_text(encoding="utf-8").splitlines()


def test_workflow_self_change_guard_runs_before_detector_imports() -> None:
    for path in (
        "scripts/ci/subprocess.py",
        ".github/ci-areas.yml",
        "tests/test_ci_change_areas.py",
    ):
        result, outputs = run_detect_step_for_paths([path])
        assert "CI router changed; running all CI areas." in result.stdout, path
        assert outputs == [
            "macos=true",
            "web=true",
            "agent_session_web=true",
            "release_build=true",
        ], path


def test_owned_control_plane_helper_reaches_detector_instead_of_fail_open_guard() -> None:
    result, outputs = run_detect_step_for_paths(["scripts/ci/persistent_mac_route.py"])
    assert "CI router changed; running all CI areas." not in result.stdout
    assert outputs == ["macos=false", "web=false", "agent_session_web=false", "release_build=false"]

    result, outputs = run_detect_step_for_paths(["scripts/ci/web_validation.py"])
    assert "CI router changed; running all CI areas." not in result.stdout
    assert outputs == ["macos=false", "web=true", "agent_session_web=false", "release_build=false"]

    for path in (
        "scripts/ci/app_host_test_products.py",
        "scripts/ci/compile-app-host-test-product.sh",
        "scripts/ci/product_input_identity.py",
        "scripts/ci/restore-app-host-test-product.sh",
        "scripts/ci/reuse_app_host_products.py",
        "scripts/ci/sanitize-xcode-source-packages-cache.py",
    ):
        result, outputs = run_detect_step_for_paths([path])
        assert "CI router changed; running all CI areas." not in result.stdout, path
        assert outputs == [
            "macos=true",
            "web=false",
            "agent_session_web=false",
            "release_build=false",
        ], path


def test_workflow_diff_failure_runs_all_areas() -> None:
    script = detect_step_script()
    with tempfile.TemporaryDirectory() as temp_dir:
        repo = Path(temp_dir)
        output_path = repo / "github-output.txt"
        env = {
            **os.environ,
            "EVENT_NAME": "pull_request",
            "BASE_SHA": "missing-base",
            "HEAD_SHA": "missing-head",
            "MERGE_SHA": "missing-merge",
            "GITHUB_OUTPUT": str(output_path),
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

        assert "Could not compute PR diff; running all CI areas." in result.stderr
        assert output_path.read_text(encoding="utf-8").splitlines() == [
            "macos=true",
            "web=true",
            "agent_session_web=true",
            "release_build=true",
        ]


def run_detect_step_on_shallow_synthetic_merge(*, stale_event_base: bool) -> tuple[subprocess.CompletedProcess[str], list[str]]:
    script = detect_step_script()
    with tempfile.TemporaryDirectory() as temp_dir:
        root = Path(temp_dir)
        source = root / "source"
        shallow = root / "shallow"
        source.mkdir()
        subprocess.run(["git", "init", "-q", "-b", "main"], cwd=source, check=True)
        subprocess.run(["git", "config", "user.email", "ci@example.test"], cwd=source, check=True)
        subprocess.run(["git", "config", "user.name", "CI Test"], cwd=source, check=True)

        helper_copy = source / "scripts" / "ci" / "detect_ci_change_areas.py"
        helper_copy.parent.mkdir(parents=True)
        helper_copy.write_text(HELPER.read_text(encoding="utf-8"), encoding="utf-8")
        table_copy = source / ".github" / "ci-areas.yml"
        table_copy.parent.mkdir(parents=True, exist_ok=True)
        table_copy.write_text(AREA_TABLE.read_text(encoding="utf-8"), encoding="utf-8")
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
            ["bash", "-c", script],
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
    assert outputs == ["macos=false", "web=true", "agent_session_web=false", "release_build=false"]


def test_workflow_routes_when_main_moved_past_the_event_base() -> None:
    result, outputs = run_detect_step_on_shallow_synthetic_merge(stale_event_base=True)

    assert "Could not compute PR diff" not in result.stderr
    # base-only.txt landed on main after the event base. It is not part of the
    # pull request and must not route macOS.
    assert outputs == ["macos=false", "web=true", "agent_session_web=false", "release_build=false"]


def test_workflow_empty_diff_runs_all_areas() -> None:
    result, outputs = run_detect_step_for_paths([])

    assert "PR diff is empty; running all CI areas." in result.stdout
    assert outputs == ["macos=true", "web=true", "agent_session_web=true", "release_build=true"]


def test_router_changes_run_everything() -> None:
    for path in (
        "scripts/ci/detect_ci_change_areas.py",
        "scripts/ci/subprocess.py",
        "tests/test_ci_change_areas.py",
        ".github/ci-areas.yml",
        ".github/workflows/ci.yml",
    ):
        assert module.classify_files([path]) == module.ChangeAreas.all(), path


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
        "release_build=false",
    ]


def test_router_policy_change_overrides_ghosttykit_release_only_shortcut() -> None:
    result, outputs = run_detect_step_for_paths(
        [
            "ghostty",
            "scripts/ghosttykit-checksums.txt",
            ".github/ci-areas.yml",
        ]
    )

    assert "CI router changed; running all CI areas." in result.stdout
    assert outputs == [
        "macos=true",
        "web=true",
        "agent_session_web=true",
        "release_build=true",
    ]


def test_workflow_only_pr_keeps_fail_open_routing() -> None:
    # The base has no ci.yml to compare against.
    result, outputs = run_detect_step_for_paths([".github/workflows/ci.yml"])

    assert "running all CI areas" in result.stdout + result.stderr
    assert outputs == [
        "macos=true",
        "web=true",
        "agent_session_web=true",
        "release_build=true",
    ]


def test_app_bundled_markdown_runs_macos() -> None:
    assert_areas(["THIRD_PARTY_LICENSES.md"], macos=True, web=False)


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


def test_macos_workflow_call_preserves_routes_and_linux_gate() -> None:
    caller = workflow_job_block("macos")

    assert "      - changes" in caller
    assert "      - linux-preflight" in caller
    assert "uses: ./.github/workflows/ci-macos.yml" in caller
    assert "needs.changes.outputs.macos != 'false'" in caller
    for route in (
        "macos",
        "full_suite",
        "compile_admitted",
        "release_build",
        "source_identity_valid",
        "source_tree",
        "source_parent1",
    ):
        assert f"      {route}: ${{{{ needs.changes.outputs.{route} }}}}" in caller
    assert "      actions: read" in caller
    assert "      contents: read" in caller
    assert "      pull-requests: read" in caller

    admission = workflow_job_block("macos-compile-admission", MACOS_WORKFLOW)
    assert "needs.changes" not in admission
    assert "needs.linux-preflight" not in admission
    assert "inputs.source_identity_valid" in admission
    assert "inputs.source_tree" in admission
    assert "inputs.source_parent1" in admission


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
) -> dict:
    return {
        "changes": {"result": "success", "outputs": {"macos": macos, "full_suite": "true"}},
        "linux-preflight": {"result": "success"},
        "macos": {"result": macos_result},
        "web": {"result": web_result},
    }


def test_platform_workflow_results_gate_tests_status() -> None:
    assert run_tests_gate(tests_gate_needs()).returncode == 0
    assert run_tests_gate(tests_gate_needs(macos_result="failure")).returncode == 1
    assert run_tests_gate(tests_gate_needs(macos_result="skipped")).returncode == 1
    assert run_tests_gate(tests_gate_needs(macos="false", macos_result="skipped")).returncode == 0
    assert run_tests_gate(tests_gate_needs(web_result="failure")).returncode == 1


def test_macos_status_accepts_compile_only_prior_admission_skip() -> None:
    inputs = {
        "macos": "true",
        "full_suite": "false",
        "compile_admitted": "true",
        "release_build": "false",
        "source_identity_valid": "true",
        "source_tree": "tree",
        "source_parent1": "parent",
    }
    skipped = dict.fromkeys(MACOS_JOBS, "skipped")
    assert run_macos_status(inputs=inputs, results=skipped).returncode == 0

    inputs["compile_admitted"] = "false"
    assert run_macos_status(inputs=inputs, results=skipped).returncode != 0


def test_build_input_fingerprint_ignores_only_what_the_build_cannot_read() -> None:
    sys.path.insert(0, str(ROOT / "scripts/ci"))
    from build_input_fingerprint import fingerprint, reaches_the_build

    def tree(**files: str) -> list[str]:
        return [f"100644 blob {object_id}\t{path}" for path, object_id in files.items()]

    base = tree(**{"Sources/App.swift": "a1", "tests/test_x.py": "b1", "docs/x.md": "c1", ".github/workflows/nightly.yml": "d1"})
    same_build = tree(**{"Sources/App.swift": "a1", "tests/test_x.py": "b2", "docs/x.md": "c2", ".github/workflows/nightly.yml": "d2", "web/app/page.tsx": "e1"})
    assert fingerprint(base, ["xcode=1"]) == fingerprint(same_build, ["xcode=1"])
    assert fingerprint(base, ["xcode=1"]) != fingerprint(base, ["xcode=2"])
    for path in ("Sources/App.swift", "Packages/macOS/CmuxCore/Package.swift", "cmuxTests/T.swift", "cmux.xcodeproj/project.pbxproj",
                 "scripts/build-ghostty-cli-helper.sh", "ghostty", ".github/workflows/ci.yml", ".xcode-version", "unknown/new-dir/file"):
        assert reaches_the_build(path), path
        assert fingerprint(base, []) != fingerprint(base + tree(**{path: "z9"}), []), path
    for path in ("tests/test_ci_change_areas.py", ".github/workflows/nightly.yml", "docs/a.md", "web/app/page.tsx", "README.md", "CLAUDE.md"):
        assert not reaches_the_build(path), path


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


def admission_job(conclusion: str, run_attempt: int = 1) -> dict:
    return {"name": "macOS compile admission", "conclusion": conclusion, "run_attempt": run_attempt}


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
        "Publish the build-input fingerprint",
        "Look for an earlier run that compiled these inputs",
    ):
        assert "        continue-on-error: true" in workflow_step_block("changes", step).splitlines(), step


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


def test_merge_groups_stop_at_the_first_failure() -> None:
    shards = workflow_job_block("app-host-unit-tests", MACOS_WORKFLOW)
    assert "fail-fast: ${{ github.event_name == 'merge_group' }}" in shards
    # The job that may cancel runs must come from the default branch, where a
    # queued pull request cannot edit it, and must not run repository code.
    watcher = (ROOT / ".github/workflows/merge-group-fail-fast.yml").read_text(encoding="utf-8")
    assert "  workflow_run:\n    workflows: [CI]\n    types: [requested, in_progress]" in watcher
    assert "  group: merge-group-fail-fast-${{ github.event.workflow_run.id }}" in watcher
    assert "  cancel-in-progress: true" in watcher
    assert "if: ${{ github.event.workflow_run.event == 'merge_group' }}" in watcher
    assert "permissions: {}" in watcher and "actions: write" in watcher
    assert "uses:" not in watcher
    assert "actions: write" not in CI_WORKFLOW.read_text(encoding="utf-8")


def test_macos_compile_admission_precedes_expensive_shards() -> None:
    workflow = MACOS_WORKFLOW.read_text(encoding="utf-8")
    caller = workflow_job_block("macos")
    admission = workflow_job_block("macos-compile-admission", MACOS_WORKFLOW)

    assert "name: macOS compile admission" in admission
    assert "      - changes" in caller
    assert "      - linux-preflight" in caller
    assert "inputs.macos == 'true'" in admission
    # The compile lives in one script so the nightly cache seeder runs the same
    # invocation; see tests/test_ci_test_compilation_cache_seed.sh.
    assert "scripts/ci/compile-app-host-test-product.sh build" in admission
    compile_script = (ROOT / "scripts/ci/compile-app-host-test-product.sh").read_text(encoding="utf-8")
    assert "build-for-testing" in compile_script
    assert "for scheme in cmux cmux-unit cmux-numeric-locale; do" in compile_script
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


def test_guard_workflow_call_preserves_routes_and_static_gate() -> None:
    block = workflow_job_block("guards")

    assert "    needs: [changes, static-preflight]" in block
    assert "    uses: ./.github/workflows/ci-guards.yml" in block
    for route in GUARD_ROUTE_JOBS:
        assert f"      {route}: ${{{{ needs.changes.outputs.{route} }}}}" in block
        assert f"needs.changes.outputs.{route} != 'false'" in block


def test_app_host_failures_preserve_attempt_and_crash_diagnostics() -> None:
    app_host = workflow_job_block("app-host-unit-tests", MACOS_WORKFLOW)
    console_runner = (ROOT / "scripts/ci/run-in-console-session.sh").read_text(encoding="utf-8")

    assert 'CMUX_APP_HOST_CAPTURE_XCRESULTS: "1"' in app_host
    assert "CMUX_APP_HOST_CAPTURE_XCRESULTS" in console_runner
    assert "CMUX_APP_HOST_RESULT_BUNDLE_ROOT" in console_runner
    assert "- name: Collect app-host failure diagnostics" in app_host
    assert "- name: Upload app-host failure diagnostics" in app_host
    assert "cmux-app-host-xcodebuild-*.meta" in app_host
    assert "cmux-app-host-xcresults" in app_host
    assert ".local/state/cmux/crash" in app_host
    assert "Library/Logs/DiagnosticReports" in app_host
    assert "if: ${{ failure() || cancelled() }}" in app_host


def test_linux_preflight_blocks_macos_on_cheap_layer_failure() -> None:
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
    assert 'web_routes = ("web", "macos", "agent_session_web")' in block
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


def test_only_the_history_guard_job_fetches_full_history() -> None:
    for guard_job in GUARD_JOBS:
        fetches_history = "fetch-depth: 0" in workflow_job_block(guard_job, GUARD_WORKFLOW)
        assert fetches_history == (guard_job == "workflow-guard-history"), guard_job


def test_web_workflow_call_preserves_routes_and_static_gate() -> None:
    block = workflow_job_block("web")

    assert "    needs: [changes, static-preflight]" in block
    assert "    uses: ./.github/workflows/ci-web.yml" in block
    for route in ("web", "macos", "agent_session_web"):
        assert f"      {route}: ${{{{ needs.changes.outputs.{route} }}}}" in block
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
        (["web/messages/fr.json"], (False, True, False)),
        (["web/app/[locale]/page.tsx"], (False, True, False)),
        (["web/services/vms/workflows.ts"], (True, False, False)),
        (["web/app/api/account/route.ts"], (True, True, False)),
        (["webviews/src/App.tsx"], (False, False, True)),
        (["Resources/markdown-viewer/webviews-app/main.mjs"], (False, False, True)),
        (["web/public/logo.png"], (False, False, False)),
        (["web/e2e/other.spec.ts"], (False, False, False)),
        ([".github/workflows/ci-web.yml"], (True, True, True)),
        (["scripts/ci/web_subareas.py"], (True, True, True)),
    )
    for paths, expected in cases:
        actual = web_subareas.classify_paths(paths)
        assert (actual.db, actual.instant, actual.react_apps) == expected, (paths, actual)


def test_web_status_allows_unselected_subarea_jobs_to_skip() -> None:
    result = run_web_status(
        results={
            "web-instant-navigation": "skipped",
            "react-apps-check": "skipped",
            "web-db-migrations": "skipped",
        },
        subareas={"db": "false", "instant": "false", "react_apps": "false"},
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
            "source_identity_valid": "false",
            "source_tree": "",
            "source_parent1": "",
        },
        results=dict.fromkeys(MACOS_JOBS, "skipped"),
    )
    assert result.returncode == 0, result.stderr


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


def test_macos_jobs_use_lane_specific_xcode_pin_vars() -> None:
    for job_name in [
        "app-host-unit-tests",
        "macos-compile-admission",
        "swift-package-tests",
        "tests-build-and-lag",
    ]:
        block = workflow_job_block(job_name, MACOS_WORKFLOW)
        assert "CMUX_CI_XCODE_APP: ${{ vars.CMUX_CI_XCODE_APP_MACOS_15 }}" in block
        assert 'CMUX_CI_REQUIRED_MACOS_SDK_MAJOR: "26"' in block

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
    assert "simulated app-host crash before test summary" in result.stdout


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
    assert outputs == ["macos=false", "web=false", "agent_session_web=false", "release_build=false"]

    for path in (".github/workflows/perf-activation.yml", "scripts/ci/subprocess.py"):
        result, outputs = run_detect_step_for_paths([path], PERF_ACTIVATION_WORKFLOW)
        assert "CI router changed; running activation benchmark." in result.stdout, path
        assert outputs[0] == "macos=true", (path, outputs)


def test_perf_activation_workflow_keeps_required_status_while_gating_benchmark() -> None:
    result, outputs = run_detect_step_for_paths(["docs/ci-runners.md"], PERF_ACTIVATION_WORKFLOW)

    assert "Resolved areas: macos=false web=false" in result.stdout
    assert outputs == ["macos=false", "web=false", "agent_session_web=false", "release_build=false"]

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


if __name__ == "__main__":
    for name, value in sorted(globals().items()):
        if name.startswith("test_") and callable(value):
            value()
    print("PASS: CI change area filter")
