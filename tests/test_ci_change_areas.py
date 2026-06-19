#!/usr/bin/env python3
"""Behavioral tests for the CI path filter."""

from __future__ import annotations

import importlib.util
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "scripts" / "ci" / "detect_ci_change_areas.py"
CI_WORKFLOW = ROOT / ".github" / "workflows" / "ci.yml"

spec = importlib.util.spec_from_file_location("detect_ci_change_areas", HELPER)
assert spec and spec.loader
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)


def assert_areas(paths: list[str], *, macos: bool, web: bool, go: bool) -> None:
    actual = module.classify_files(paths)
    assert actual.macos is macos, (paths, actual)
    assert actual.web is web, (paths, actual)
    assert actual.go is go, (paths, actual)


def test_docs_only_skips_expensive_areas() -> None:
    assert_areas(["docs/ci.md", "README.md"], macos=False, web=False, go=False)


def test_cli_contract_doc_runs_macos_contract_tests() -> None:
    assert_areas(["docs/cli-contract.md"], macos=True, web=False, go=False)


def test_changelog_runs_web_validation() -> None:
    assert_areas(["CHANGELOG.md"], macos=True, web=True, go=False)


def test_web_only_runs_web_without_macos() -> None:
    assert_areas(["web/app/page.tsx", "webviews/src/diff/App.tsx"], macos=False, web=True, go=False)


def test_agent_session_webview_sources_run_bundled_asset_check() -> None:
    assert_areas(["webviews/src/agent-session/shared/message.test.ts"], macos=True, web=True, go=False)


def test_markdown_viewer_resources_run_webviews_asset_guard() -> None:
    assert_areas(
        ["Resources/markdown-viewer/webviews-app/index.js", "Resources/markdown-viewer/marked.min.js"],
        macos=True,
        web=True,
        go=False,
    )


def test_root_agent_web_dependencies_run_web_and_macos() -> None:
    assert_areas(["package.json", "bun.lock"], macos=True, web=True, go=False)


def test_agent_session_resources_run_web_and_macos() -> None:
    assert_areas(["Resources/agent-session-react/index.js"], macos=True, web=True, go=False)


def test_ios_only_skips_main_macos_ci() -> None:
    assert_areas(["ios/cmux/ContentView.swift"], macos=False, web=False, go=False)


def test_remote_daemon_runs_go_only() -> None:
    assert_areas(["daemon/remote/main.go"], macos=False, web=False, go=True)


def test_remote_daemon_asset_builder_runs_go_validation() -> None:
    assert_areas(["scripts/build_remote_daemon_release_assets.sh"], macos=True, web=False, go=True)


def test_app_source_runs_macos() -> None:
    assert_areas(["Sources/AppDelegate.swift"], macos=True, web=False, go=False)


def test_workflow_changes_run_everything() -> None:
    assert_areas([".github/workflows/ci.yml"], macos=True, web=True, go=True)


def test_workflow_has_trusted_self_change_guard() -> None:
    workflow = CI_WORKFLOW.read_text(encoding="utf-8")
    assert "CI router changed; running all CI areas." in workflow
    assert "--files-from /tmp/cmux-ci-changed-files.txt" in workflow
    assert r"\.github/workflows/ci\.yml" in workflow
    assert r"scripts/ci/[^/]+\.py" in workflow
    assert r"tests/test_ci_change_areas\.py" in workflow


def test_router_changes_run_everything() -> None:
    assert_areas(["scripts/ci/detect_ci_change_areas.py"], macos=True, web=True, go=True)
    assert_areas(["scripts/ci/subprocess.py"], macos=True, web=True, go=True)
    assert_areas(["tests/test_ci_change_areas.py"], macos=True, web=True, go=True)


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
        ]


def test_non_pr_events_run_all_areas() -> None:
    result = subprocess.run(
        [sys.executable, str(HELPER), "--event-name", "workflow_dispatch"],
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )

    assert "Resolved areas: macos=true web=true go=true" in result.stdout


if __name__ == "__main__":
    for name, value in sorted(globals().items()):
        if name.startswith("test_") and callable(value):
            value()
    print("PASS: CI change area filter")
