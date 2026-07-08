#!/usr/bin/env python3
"""Behavioral tests for the CI path filter."""

from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "scripts" / "ci" / "detect_ci_change_areas.py"
CI_WORKFLOW = ROOT / ".github" / "workflows" / "ci.yml"
PERF_ACTIVATION_WORKFLOW = ROOT / ".github" / "workflows" / "perf-activation.yml"

spec = importlib.util.spec_from_file_location("detect_ci_change_areas", HELPER)
assert spec and spec.loader
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)


def assert_areas(
    paths: list[str],
    *,
    macos: bool,
    web: bool,
    go: bool,
    agent_session_web: bool = False,
) -> None:
    actual = module.classify_files(paths)
    assert actual.macos is macos, (paths, actual)
    assert actual.web is web, (paths, actual)
    assert actual.go is go, (paths, actual)
    assert actual.agent_session_web is agent_session_web, (paths, actual)


def test_docs_only_skips_expensive_areas() -> None:
    assert_areas(["docs/ci.md", "README.md"], macos=False, web=False, go=False)


def test_cli_contract_doc_runs_macos_contract_tests() -> None:
    assert_areas(["docs/cli-contract.md"], macos=True, web=False, go=False)


def test_changelog_runs_web_validation() -> None:
    assert_areas(["CHANGELOG.md"], macos=True, web=True, go=False)


def test_web_only_runs_web_without_macos() -> None:
    assert_areas(["web/app/page.tsx", "webviews/src/diff/App.tsx"], macos=False, web=True, go=False)


def test_website_only_does_not_run_agent_session_resource_check() -> None:
    assert_areas(["web/app/page.tsx"], macos=False, web=True, go=False, agent_session_web=False)


def test_agent_session_webview_sources_run_bundled_asset_check() -> None:
    assert_areas(
        ["webviews/src/agent-session/shared/message.test.ts"],
        macos=True,
        web=True,
        go=False,
        agent_session_web=True,
    )


def test_markdown_viewer_resources_run_webviews_asset_guard() -> None:
    assert_areas(
        ["Resources/markdown-viewer/webviews-app/index.js", "Resources/markdown-viewer/marked.min.js"],
        macos=True,
        web=True,
        go=False,
        agent_session_web=True,
    )


def test_markdown_viewer_webview_app_does_not_run_agent_session_resource_check() -> None:
    assert_areas(
        ["Resources/markdown-viewer/webviews-app/index.js"],
        macos=True,
        web=True,
        go=False,
        agent_session_web=False,
    )


def test_root_agent_web_dependencies_run_web_and_macos() -> None:
    assert_areas(
        ["package.json", "bun.lock"],
        macos=True,
        web=True,
        go=False,
        agent_session_web=True,
    )


def test_agent_session_resources_run_web_and_macos() -> None:
    assert_areas(
        ["Resources/agent-session-react/index.js"],
        macos=True,
        web=True,
        go=False,
        agent_session_web=True,
    )
    assert_areas(
        ["Resources/agent-session-solid/index.js"],
        macos=True,
        web=True,
        go=False,
        agent_session_web=True,
    )
    assert_areas(["Resources/agent-session-backup/index.js"], macos=True, web=False, go=False)


def test_ios_only_skips_main_macos_ci() -> None:
    assert_areas(["ios/cmux/ContentView.swift"], macos=False, web=False, go=False)


def test_remote_daemon_runs_go_only() -> None:
    assert_areas(["daemon/remote/main.go"], macos=False, web=False, go=True)


def test_remote_daemon_asset_builder_runs_go_validation() -> None:
    assert_areas(["scripts/build_remote_daemon_release_assets.sh"], macos=True, web=False, go=True)


def test_app_source_runs_macos() -> None:
    assert_areas(["Sources/AppDelegate.swift"], macos=True, web=False, go=False)


def test_workflow_changes_run_everything() -> None:
    assert_areas(
        [".github/workflows/ci.yml"],
        macos=True,
        web=True,
        go=True,
        agent_session_web=True,
    )


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


def linux_preflight_needs(
    *,
    outputs: dict[str, str] | None = None,
    results: dict[str, str] | None = None,
) -> dict[str, object]:
    route_outputs = {
        "macos": "true",
        "web": "true",
        "go": "true",
        "agent_session_web": "true",
    }
    if outputs:
        route_outputs.update(outputs)
    job_results = {
        "changes": "success",
        "workflow-guard-tests": "success",
        "remote-daemon-tests": "success",
        "web-typecheck": "success",
        "react-apps-check": "success",
        "web-db-migrations": "success",
        "agent-session-web-resources": "success",
    }
    if results:
        job_results.update(results)
    return {
        name: {"result": result, "outputs": route_outputs if name == "changes" else {}}
        for name, result in job_results.items()
    }


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
    result, outputs = run_detect_step_for_paths(["scripts/ci/subprocess.py"])

    assert "CI router changed; running all CI areas." in result.stdout
    assert outputs == ["macos=true", "web=true", "go=true", "agent_session_web=true"]


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
            "go=true",
            "agent_session_web=true",
        ]


def test_workflow_empty_diff_runs_all_areas() -> None:
    result, outputs = run_detect_step_for_paths([])

    assert "PR diff is empty; running all CI areas." in result.stdout
    assert outputs == ["macos=true", "web=true", "go=true", "agent_session_web=true"]


def test_router_changes_run_everything() -> None:
    assert_areas(
        ["scripts/ci/detect_ci_change_areas.py"],
        macos=True,
        web=True,
        go=True,
        agent_session_web=True,
    )
    assert_areas(
        ["scripts/ci/subprocess.py"],
        macos=True,
        web=True,
        go=True,
        agent_session_web=True,
    )
    assert_areas(
        ["tests/test_ci_change_areas.py"],
        macos=True,
        web=True,
        go=True,
        agent_session_web=True,
    )


def test_ghosttykit_checksum_pin_runs_macos() -> None:
    assert_areas(["scripts/ghosttykit-checksums.txt"], macos=True, web=False, go=False)


def test_app_bundled_markdown_runs_macos() -> None:
    assert_areas(["THIRD_PARTY_LICENSES.md"], macos=True, web=False, go=False)


def test_swift_warning_budget_runs_macos() -> None:
    assert_areas([".github/swift-warning-budget.tsv"], macos=True, web=False, go=False)


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

        assert "Resolved areas: macos=false web=true go=false" in result.stdout
        assert output_path.read_text(encoding="utf-8").splitlines() == [
            "macos=false",
            "web=true",
            "go=false",
            "agent_session_web=false",
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
        assert "Resolved areas: macos=true web=true go=true agent_session_web=true" in result.stdout
        assert output_path.read_text(encoding="utf-8").splitlines() == [
            "macos=true",
            "web=true",
            "go=true",
            "agent_session_web=true",
        ]


def test_non_pr_events_run_all_areas() -> None:
    result = subprocess.run(
        [sys.executable, str(HELPER), "--event-name", "workflow_dispatch"],
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )

    assert "Resolved areas: macos=true web=true go=true agent_session_web=true" in result.stdout


def test_ci_status_job_accepts_skipped_routed_jobs() -> None:
    block = workflow_job_block("ci-status")

    for job_name in [
        "changes",
        "workflow-guard-tests",
        "remote-daemon-tests",
        "web-typecheck",
        "react-apps-check",
        "web-db-migrations",
        "linux-preflight",
        "app-host-unit-tests",
        "tests",
        "tests-build-and-lag",
        "release-build",
    ]:
        assert f"      - {job_name}" in block

    assert "if: ${{ always() }}" in block
    assert 'allowed = {"success", "skipped"}' in block


def test_required_tests_status_waits_for_app_host_matrix() -> None:
    block = workflow_job_block("tests")

    assert "name: tests" in block
    assert "      - changes" in block
    assert "      - linux-preflight" in block
    assert "      - app-host-unit-tests" in block
    assert "if: ${{ always() }}" in block
    assert 'preflight["result"] != "success"' in block
    assert 'macos == "true" and tests["result"] != "success"' in block
    assert 'tests["result"] not in {"success", "skipped"}' in block


def test_macos_jobs_wait_for_linux_preflight() -> None:
    macos_preflight_if = "if: ${{ !cancelled() && needs.changes.outputs.macos == 'true' && needs.linux-preflight.result == 'success' }}"
    for job_name in [
        "app-host-unit-tests",
        "swift-package-tests",
        "tests-build-and-lag",
    ]:
        block = workflow_job_block(job_name)
        assert "      - changes" in block
        assert "      - linux-preflight" in block
        assert "!cancelled()" in block
        assert macos_preflight_if in block

    block = workflow_job_block("release-build")
    assert "      - changes" in block
    assert "      - linux-preflight" in block
    assert "      - swift-package-tests" in block
    assert "!cancelled()" in block
    assert "if: ${{ !cancelled() && needs.changes.outputs.macos == 'true' && needs.linux-preflight.result == 'success' && needs.swift-package-tests.result == 'success' }}" in block


def test_linux_preflight_blocks_macos_on_cheap_layer_failure() -> None:
    block = workflow_job_block("linux-preflight")

    assert "name: linux-preflight" in block
    assert "      - changes" in block
    assert "      - workflow-guard-tests" in block
    assert "      - remote-daemon-tests" in block
    assert "      - web-typecheck" in block
    assert "      - react-apps-check" in block
    assert "      - web-db-migrations" in block
    assert "      - agent-session-web-resources" in block
    assert "if: ${{ always() }}" in block
    assert 'required = ("changes", "workflow-guard-tests")' in block
    assert 'allowed_routed = {' in block
    assert 'routed_outputs = {' in block
    assert 'bad[name] = f"{result} (route {route}=true)"' in block


def test_linux_preflight_fails_when_routed_job_skips() -> None:
    result = run_linux_preflight(
        linux_preflight_needs(results={"remote-daemon-tests": "skipped"})
    )

    assert result.returncode != 0
    assert "remote-daemon-tests: skipped (route go=true)" in result.stderr


def test_linux_preflight_allows_unrouted_job_skip() -> None:
    result = run_linux_preflight(
        linux_preflight_needs(
            outputs={"go": "false"},
            results={"remote-daemon-tests": "skipped"},
        )
    )

    assert result.returncode == 0, result.stderr
    assert "remote-daemon-tests: skipped" in result.stdout


def test_macos_jobs_use_lane_specific_xcode_pin_vars() -> None:
    for job_name in [
        "app-host-unit-tests",
        "swift-package-tests",
        "tests-build-and-lag",
    ]:
        block = workflow_job_block(job_name)
        assert "CMUX_CI_XCODE_APP: ${{ vars.CMUX_CI_XCODE_APP_MACOS_15 }}" in block
        assert 'CMUX_CI_REQUIRED_MACOS_SDK_MAJOR: "26"' in block

    release_block = workflow_job_block("release-build")
    assert "CMUX_CI_XCODE_APP: ${{ vars.CMUX_CI_XCODE_APP_MACOS_26 }}" in release_block
    assert 'CMUX_CI_REQUIRED_MACOS_SDK_MAJOR: "26"' in release_block


def test_required_macos_topology_collapses_display_and_release_helper_jobs() -> None:
    workflow = CI_WORKFLOW.read_text(encoding="utf-8")
    runtime_block = workflow_job_block("tests-build-and-lag")
    package_block = workflow_job_block("swift-package-tests")
    release_block = workflow_job_block("release-build")

    assert "\n  ui-regressions:" not in workflow
    assert "\n  release-ghostty-cli-helper:" not in workflow
    assert "build-for-testing" in runtime_block
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
    assert "Build universal Ghostty CLI helper" in package_block
    assert "./scripts/build-ghostty-cli-helper.sh --universal --output ghostty-cli-helper/ghostty" in package_block
    assert '[[ "$HELPER_SDK_VERSION" == 15.* ]]' in package_block
    assert "actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a" in package_block
    assert package_block.index("Select helper Xcode") < package_block.index("Build universal Ghostty CLI helper")
    assert package_block.index("Build universal Ghostty CLI helper") < package_block.index("Select Xcode")
    assert package_block.index("Upload universal Ghostty CLI helper") < package_block.index("Select Xcode")
    assert "      - swift-package-tests" in release_block
    assert "Download universal Ghostty CLI helper" in release_block
    assert "actions/download-artifact@37930b1c2abaa49bbe596cd826c3c89aef350131" in release_block
    assert "Install universal Ghostty CLI helper" in release_block
    assert "./scripts/build-ghostty-cli-helper.sh --universal --output ghostty-cli-helper/ghostty" not in release_block


def test_agent_session_web_resources_runs_only_for_agent_session_web_area() -> None:
    block = workflow_job_block("agent-session-web-resources")

    assert "if: ${{ needs.changes.outputs.agent_session_web == 'true' }}" in block


def test_perf_activation_workflow_keeps_required_status_while_gating_benchmark() -> None:
    result, outputs = run_detect_step_for_paths(["docs/ci-runners.md"], PERF_ACTIVATION_WORKFLOW)

    assert "Resolved areas: macos=false web=false go=false" in result.stdout
    assert outputs == ["macos=false", "web=false", "go=false", "agent_session_web=false"]

    benchmark = workflow_job_block("activation-session-benchmark", PERF_ACTIVATION_WORKFLOW)
    sentinel = workflow_job_block("activation-session", PERF_ACTIVATION_WORKFLOW)

    assert "needs: activation_changes" in benchmark
    assert "if: ${{ needs.activation_changes.outputs.macos == 'true' }}" in benchmark
    # The benchmark routes through MACOS_RUNNER_15 (Blacksmith) for all events,
    # including PRs. Depot remains only as a manual workflow_dispatch override.
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
