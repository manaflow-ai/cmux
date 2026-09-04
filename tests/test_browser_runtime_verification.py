#!/usr/bin/env python3
"""Regression tests for the exact-SHA browser runtime verification contract."""

from __future__ import annotations

import importlib.util
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "scripts" / "ci" / "verify_browser_runtime_artifact.py"
CI_WORKFLOW = ROOT / ".github" / "workflows" / "ci.yml"
E2E_WORKFLOW = ROOT / ".github" / "workflows" / "test-e2e.yml"

spec = importlib.util.spec_from_file_location("verify_browser_runtime_artifact", HELPER)
assert spec and spec.loader
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)


def make_app(root: Path, *, cef: bool) -> Path:
    app = root / "cmux.app"
    frameworks = app / "Contents" / "Frameworks"
    frameworks.mkdir(parents=True)
    (app / "Contents" / "MacOS" / "cmux").parent.mkdir(parents=True)
    (app / "Contents" / "MacOS" / "cmux").write_text("binary\n", encoding="utf-8")
    if cef:
        framework = frameworks / "Chromium Embedded Framework.framework" / "Versions" / "Current"
        (framework / "Resources").mkdir(parents=True)
        (framework / "Resources" / "Info.plist").write_text("plist\n", encoding="utf-8")
        (framework / "Chromium Embedded Framework").write_text("framework\n", encoding="utf-8")
        for suffix in ("", " (GPU)", " (Renderer)", " (Plugin)", " (Alerts)"):
            helper = frameworks / f"cmux CEF Helper{suffix}.app" / "Contents" / "MacOS"
            helper.mkdir(parents=True)
            (helper / f"cmux CEF Helper{suffix}").write_text("helper\n", encoding="utf-8")
    return app


def test_fallback_artifact_is_explicitly_accepted_without_cef_source() -> None:
    with tempfile.TemporaryDirectory() as temp_dir:
        root = Path(temp_dir)
        app = make_app(root, cef=False)
        result = module.verify_artifact(app=app, source_root=root, expected_sha=None)
        assert result.runtime_mode == "fallback"


def test_cef_source_fails_closed_when_framework_is_not_embedded() -> None:
    with tempfile.TemporaryDirectory() as temp_dir:
        root = Path(temp_dir)
        (root / "Packages" / "macOS" / "CmuxCEF").mkdir(parents=True)
        app = make_app(root, cef=False)
        try:
            module.verify_artifact(app=app, source_root=root, expected_sha=None)
        except module.VerificationError as error:
            assert "CEF" in str(error)
        else:
            raise AssertionError("a CEF source tree without an embedded framework must fail")


def test_cef_artifact_requires_framework_and_all_helpers() -> None:
    with tempfile.TemporaryDirectory() as temp_dir:
        root = Path(temp_dir)
        (root / "Packages" / "macOS" / "CmuxCEF").mkdir(parents=True)
        app = make_app(root, cef=True)
        result = module.verify_artifact(app=app, source_root=root, expected_sha=None)
        assert result.runtime_mode == "native-cef"
        assert result.helper_count == 5


def test_stale_cef_bundle_without_cef_source_is_rejected() -> None:
    with tempfile.TemporaryDirectory() as temp_dir:
        root = Path(temp_dir)
        app = make_app(root, cef=True)
        try:
            module.verify_artifact(app=app, source_root=root, expected_sha=None)
        except module.VerificationError as error:
            assert "source" in str(error).lower()
        else:
            raise AssertionError("a stale CEF bundle must not pass a fallback build")


def test_browser_paths_route_to_the_mandatory_runtime_gate() -> None:
    browser_paths = [
        "Packages/macOS/CmuxBrowser/Sources/CmuxBrowser/BrowserModel.swift",
        "Packages/macOS/CmuxCEF/Sources/CmuxCEF/CEFRuntime.swift",
        "Sources/Panels/BrowserPanel.swift",
        "Sources/TerminalController+ChromiumBrowserAutomation.swift",
        "cmuxUITests/BrowserFixtureInteractionUITests.swift",
        "scripts/embed-cef.sh",
    ]
    assert all(module.is_browser_engine_path(path) for path in browser_paths)
    assert not module.is_browser_engine_path("Sources/TerminalController.swift")
    assert not module.is_browser_engine_path("docs/browser.md")


def test_ci_workflow_runs_for_every_pull_request() -> None:
    workflow = CI_WORKFLOW.read_text(encoding="utf-8")
    trigger = workflow.split("\njobs:\n", 1)[0]
    assert "\n  pull_request:\n" in trigger
    assert "\n    paths:" not in trigger
    assert "\n    paths-ignore:" not in trigger


def test_ci_status_requires_browser_gate_when_router_marks_browser_change() -> None:
    workflow = CI_WORKFLOW.read_text(encoding="utf-8")
    status = workflow.split("\n  ci-status:\n", 1)[1]
    status = status.split("\n  ", 1)[0]
    assert "browser-engine-e2e" in status
    assert "browser_engine" in status
    assert 'browser_result != "success"' in status


def test_browser_gate_uses_exact_head_and_nonzero_test_contract() -> None:
    workflow = E2E_WORKFLOW.read_text(encoding="utf-8")
    assert "workflow_call:" in workflow
    assert "verify_browser_runtime" in workflow
    assert "Could not determine executed test count" in workflow
    assert "executed 0 tests" in workflow
    assert "EXPECTED_SHA" in workflow or "expected_sha" in workflow


if __name__ == "__main__":
    for name, value in sorted(globals().items()):
        if name.startswith("test_") and callable(value):
            value()
    print("PASS: browser runtime verification contract")
