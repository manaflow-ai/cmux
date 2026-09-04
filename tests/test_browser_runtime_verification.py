#!/usr/bin/env python3
"""Regression tests for the exact-SHA browser runtime verification contract."""

from __future__ import annotations

import importlib.util
import plistlib
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "scripts" / "ci" / "verify_browser_runtime_artifact.py"
CI_WORKFLOW = ROOT / ".github" / "workflows" / "ci.yml"
E2E_WORKFLOW = ROOT / ".github" / "workflows" / "test-e2e.yml"
RELOAD_WORKFLOW = ROOT / ".github" / "workflows" / "reload-build.yml"

spec = importlib.util.spec_from_file_location("verify_browser_runtime_artifact", HELPER)
assert spec and spec.loader
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)


def make_app(
    root: Path,
    *,
    cef: bool,
    build_sha: str | None = None,
    executable_name: str = "cmux",
) -> Path:
    app = root / "cmux.app"
    frameworks = app / "Contents" / "Frameworks"
    frameworks.mkdir(parents=True)
    (app / "Contents" / "MacOS" / "cmux").parent.mkdir(parents=True)
    executable = app / "Contents" / "MacOS" / executable_name
    executable.write_text("binary\n", encoding="utf-8")
    executable.chmod(0o755)
    info = {
        "CFBundleIdentifier": "com.cmuxterm.test",
        "CFBundleExecutable": executable_name,
    }
    if build_sha is not None:
        info["CMUXBuildSourceSHA"] = build_sha
    with (app / "Contents" / "Info.plist").open("wb") as handle:
        plistlib.dump(info, handle)
    if cef:
        framework = frameworks / "Chromium Embedded Framework.framework" / "Versions" / "Current"
        (framework / "Resources").mkdir(parents=True)
        (framework / "Resources" / "Info.plist").write_text("plist\n", encoding="utf-8")
        framework_binary = framework / "Chromium Embedded Framework"
        framework_binary.write_text("framework\n", encoding="utf-8")
        framework_binary.chmod(0o755)
        for suffix in ("", " (GPU)", " (Renderer)", " (Plugin)", " (Alerts)"):
            helper = frameworks / f"cmux CEF Helper{suffix}.app" / "Contents" / "MacOS"
            helper.mkdir(parents=True)
            helper_binary = helper / f"cmux CEF Helper{suffix}"
            helper_binary.write_text("helper\n", encoding="utf-8")
            helper_binary.chmod(0o755)
    return app


def test_fallback_artifact_is_explicitly_accepted_without_cef_source() -> None:
    with tempfile.TemporaryDirectory() as temp_dir:
        root = Path(temp_dir)
        app = make_app(root, cef=False)
        result = module.verify_artifact(app=app, source_root=root, expected_sha=None)
        assert result.runtime_mode == "fallback"


def test_tagged_app_executable_name_is_read_from_bundle_metadata() -> None:
    with tempfile.TemporaryDirectory() as temp_dir:
        root = Path(temp_dir)
        app = make_app(root, cef=False, executable_name="cmux DEV issue-11967")
        result = module.verify_artifact(app=app, source_root=root, expected_sha=None)
        assert result.runtime_mode == "fallback"


def test_invalid_bundle_executable_name_is_rejected() -> None:
    with tempfile.TemporaryDirectory() as temp_dir:
        root = Path(temp_dir)
        app = make_app(root, cef=False)
        plist_path = app / "Contents" / "Info.plist"
        with plist_path.open("rb") as handle:
            info = plistlib.load(handle)
        info["CFBundleExecutable"] = "../escape"
        with plist_path.open("wb") as handle:
            plistlib.dump(info, handle)
        try:
            module.verify_artifact(app=app, source_root=root, expected_sha=None)
        except module.VerificationError as error:
            assert "CFBundleExecutable" in str(error)
        else:
            raise AssertionError("path-like executable names must fail verification")


def test_cef_source_fails_closed_when_framework_is_not_embedded() -> None:
    with tempfile.TemporaryDirectory() as temp_dir:
        root = Path(temp_dir)
        cef_source = root / "Packages" / "macOS" / "CmuxCEF"
        cef_source.mkdir(parents=True)
        (cef_source / "Package.swift").write_text("// CEF package\n", encoding="utf-8")
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
        cef_source = root / "Packages" / "macOS" / "CmuxCEF"
        cef_source.mkdir(parents=True)
        (cef_source / "Package.swift").write_text("// CEF package\n", encoding="utf-8")
        app = make_app(root, cef=True)
        result = module.verify_artifact(app=app, source_root=root, expected_sha=None)
        assert result.runtime_mode == "native-cef"
        assert result.helper_count == 5


def test_each_missing_cef_helper_is_rejected() -> None:
    helper_suffixes = ("", " (GPU)", " (Renderer)", " (Plugin)", " (Alerts)")
    for suffix in helper_suffixes:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            cef_source = root / "Packages" / "macOS" / "CmuxCEF"
            cef_source.mkdir(parents=True)
            (cef_source / "Package.swift").write_text("// CEF package\n", encoding="utf-8")
            app = make_app(root, cef=True)
            shutil.rmtree(
                app / "Contents" / "Frameworks" / f"cmux CEF Helper{suffix}.app"
            )
            try:
                module.verify_artifact(app=app, source_root=root, expected_sha=None)
            except module.VerificationError as error:
                assert "CEF helper" in str(error)
            else:
                raise AssertionError(f"missing helper {suffix!r} must fail verification")


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


def test_bundle_provenance_sha_mismatch_is_rejected() -> None:
    expected = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    wrong = "0" * 40 if expected != "0" * 40 else "1" * 40
    with tempfile.TemporaryDirectory() as temp_dir:
        root = Path(temp_dir)
        app = make_app(root, cef=False, build_sha=wrong)
        try:
            module.verify_artifact(app=app, source_root=ROOT, expected_sha=expected)
        except module.VerificationError as error:
            assert "app bundle source SHA mismatch" in str(error)
        else:
            raise AssertionError("an app with mismatched provenance metadata must fail")


def test_bundle_provenance_sha_match_is_accepted() -> None:
    expected = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    with tempfile.TemporaryDirectory() as temp_dir:
        root = Path(temp_dir)
        app = make_app(root, cef=False, build_sha=expected)
        result = module.verify_artifact(app=app, source_root=ROOT, expected_sha=expected)
        assert result.runtime_mode == "fallback"


def test_browser_paths_route_to_the_mandatory_runtime_gate() -> None:
    browser_paths = [
        "Packages/macOS/CmuxBrowser/Sources/CmuxBrowser/BrowserModel.swift",
        "Packages/macOS/CmuxCEF/Sources/CmuxCEF/CEFRuntime.swift",
        "Sources/Panels/BrowserPanel.swift",
        "Sources/TerminalController+ChromiumBrowserAutomation.swift",
        "Sources/TerminalController.swift",
        "Sources/BrowserActionDispatcher.swift",
        "cmux.xcodeproj/project.pbxproj",
        "Packages/macOS/CmuxControlSocket/Sources/CmuxControlSocket/Coordinator/Browser/ControlBrowserEngineStrings.swift",
        "cmuxUITests/BrowserFixtureInteractionUITests.swift",
        "scripts/embed-cef.sh",
    ]
    assert all(module.is_browser_engine_path(path) for path in browser_paths)
    assert not module.is_browser_engine_path("docs/browser.md")
    assert not module.is_browser_engine_path("web/messages/en.json")


def test_unknown_macos_app_and_guard_paths_fail_closed() -> None:
    assert module.is_browser_engine_path("Sources/UnfamiliarHostIntegration.swift")
    assert module.is_browser_engine_path("Packages/macOS/CmuxTerminal/Sources/Host.swift")
    assert module.is_browser_engine_path("Packages/Shared/CmuxAuthRuntime/Sources/Auth.swift")
    assert module.is_browser_engine_path("scripts/build-cmux-cua.sh")
    assert module.is_browser_engine_path("ghostty")
    assert module.is_browser_engine_path("vendor/bonsplit")
    assert module.is_browser_engine_path("cmuxTests/UnfamiliarBrowserHostTests.swift")
    assert module.is_browser_engine_path(".github/workflows/ci.yml")
    assert module.is_browser_engine_path(".github/workflows/ci-status-fallback.yml")
    assert module.is_browser_engine_path("scripts/ci/verify_browser_runtime_artifact.py")
    assert not module.is_browser_engine_path("Packages/iOS/CmuxMobileBrowser/Sources/Mobile.swift")
    assert not module.is_browser_engine_path("web/app/page.tsx")


def test_renamed_browser_path_is_classified_when_both_names_are_supplied() -> None:
    with tempfile.TemporaryDirectory() as temp_dir:
        files = Path(temp_dir) / "files.txt"
        output = Path(temp_dir) / "github-output.txt"
        files.write_text(
            "docs/browser-architecture.md\n"
            "Packages/macOS/CmuxBrowser/Sources/CmuxBrowser/Old.swift\n",
            encoding="utf-8",
        )
        subprocess.run(
            [
                sys.executable,
                str(ROOT / "scripts" / "ci" / "detect_browser_engine_changes.py"),
                "--event-name",
                "pull_request",
                "--files-from",
                str(files),
                "--github-output",
                str(output),
            ],
            cwd=ROOT,
            check=True,
        )
        assert output.read_text(encoding="utf-8").splitlines() == ["browser_engine=true"]


def test_browser_change_detector_fails_open_when_diff_is_unknown() -> None:
    with tempfile.TemporaryDirectory() as temp_dir:
        output = Path(temp_dir) / "github-output.txt"
        result = subprocess.run(
            [
                sys.executable,
                str(ROOT / "scripts" / "ci" / "detect_browser_engine_changes.py"),
                "--event-name",
                "pull_request",
                "--base-sha",
                "missing-base",
                "--head-sha",
                "missing-head",
                "--github-output",
                str(output),
            ],
            cwd=ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        assert result.returncode == 0
        assert output.read_text(encoding="utf-8").splitlines() == ["browser_engine=true"]


def test_browser_change_detector_routes_guard_implementation_edits() -> None:
    with tempfile.TemporaryDirectory() as temp_dir:
        files = Path(temp_dir) / "files.txt"
        output = Path(temp_dir) / "github-output.txt"
        for path in (
            "scripts/ci/detect_browser_engine_changes.py",
            "scripts/ci/verify_browser_runtime_artifact.py",
        ):
            files.write_text(f"{path}\n", encoding="utf-8")
            output.unlink(missing_ok=True)
            subprocess.run(
                [
                    sys.executable,
                    str(ROOT / "scripts" / "ci" / "detect_browser_engine_changes.py"),
                    "--event-name",
                    "pull_request",
                    "--files-from",
                    str(files),
                    "--github-output",
                    str(output),
                ],
                cwd=ROOT,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=True,
            )
            # The detector is executed only from the base-controlled required-ci
            # workflow, so a pull request cannot replace its classification logic.
            # Changing either guard implementation must still trigger the lane.
            assert output.read_text(encoding="utf-8").splitlines() == ["browser_engine=true"]
        required_ci = (ROOT / ".github" / "workflows" / "required-ci.yml").read_text(encoding="utf-8")
        assert "Checkout trusted verifier" in required_ci
        assert "trusted/scripts/ci/detect_browser_engine_changes.py" in required_ci


def test_ci_workflow_runs_for_every_pull_request() -> None:
    workflow = CI_WORKFLOW.read_text(encoding="utf-8")
    trigger = workflow.split("\njobs:\n", 1)[0]
    assert "\n  pull_request:\n" in trigger
    assert "\n    paths:" not in trigger
    assert "\n    paths-ignore:" not in trigger


def test_no_fallback_workflow_can_publish_the_required_ci_status_context() -> None:
    fallback = ROOT / ".github" / "workflows" / "ci-status-fallback.yml"
    assert not fallback.exists()


def test_ci_status_remains_the_compile_aggregate_and_trusted_watcher_owns_browser_gate() -> None:
    workflow = CI_WORKFLOW.read_text(encoding="utf-8")
    status = workflow.split("\n  ci-status:\n", 1)[1]
    assert "browser-engine-e2e" not in status
    required_ci = (ROOT / ".github" / "workflows" / "required-ci.yml").read_text(encoding="utf-8")
    assert "required-browser-runtime" in required_ci
    assert "required CI verification failed" in required_ci


def test_browser_gate_uses_exact_head_and_nonzero_test_contract() -> None:
    workflow = E2E_WORKFLOW.read_text(encoding="utf-8")
    assert "workflow_call:" in workflow
    assert "verify_browser_runtime" in workflow
    assert "Could not determine executed test count" in workflow
    assert "executed 0 tests" in workflow
    assert "EXPECTED_SHA" in workflow or "expected_sha" in workflow
    assert "repository: ${{ github.event.pull_request.head.repo.full_name || github.repository }}" in workflow
    assert "Checkout trusted browser verifier" in workflow
    assert "path: trusted-browser-verifier" in workflow
    assert "inputs.trusted_ref || github.workflow_sha" in workflow
    assert "trusted_ref:" in workflow
    assert "Resolve source Ghostty revision with trusted API access" in workflow
    assert "Download GhosttyKit with trusted tooling" in workflow
    assert "Install and bind GhosttyKit" in workflow
    assert "SOURCE_REPOSITORY" in workflow
    assert "GHOSTTYKIT_OUTPUT_DIR" in workflow
    assert "GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}" not in workflow
    trusted_download = workflow.index("Download GhosttyKit with trusted tooling")
    source_checkout = workflow.index("      - name: Checkout\n", trusted_download)
    assert trusted_download < source_checkout
    assert "Stage trusted browser verifier and build tooling" in workflow
    assert '"$RUNNER_TEMP/cmux-trusted-browser-verifier/scripts/download-prebuilt-ghosttykit.sh"' in workflow
    assert 'verifier="$RUNNER_TEMP/cmux-trusted-browser-verifier/scripts/ci/verify_browser_runtime_artifact.py"' in workflow
    assert workflow.count("verify_browser_runtime:") == 2
    assert "Require immutable browser verification ref" in workflow
    assert "workflow_call/browser runtime verification requires a full 40-character commit SHA" in workflow
    assert "inputs.trusted_ref != ''" in workflow
    required_ci = (ROOT / ".github" / "workflows" / "required-ci.yml").read_text(encoding="utf-8")
    assert "BrowserReliabilityRegressionUITests/testBrowserEngineSmokeRendersEvaluatesScreenshotsAndReopens" in required_ci
    assert "Validate required browser runner identity" in workflow
    assert "inputs.verify_browser_runtime && (vars.MACOS_RUNNER_15" in workflow
    assert "if: ${{ inputs.verify_browser_runtime == true }}" in workflow
    assert "blacksmith-*|warp-*|depot-*" in workflow
    assert "Required browser runner identity verified" in workflow
    assert "requires an approved runner" in workflow
    assert "CMUX_UI_TEST_BROWSER_ENGINE=${CMUX_UI_TEST_BROWSER_ENGINE:-}" in workflow
    assert "Verify browser helper cleanup" in workflow
    assert "pgrep -af '[c]mux CEF Helper'" in workflow


def test_all_mac_build_lanes_run_the_fail_closed_artifact_guard() -> None:
    ci = CI_WORKFLOW.read_text(encoding="utf-8")
    e2e = E2E_WORKFLOW.read_text(encoding="utf-8")
    reload_build = RELOAD_WORKFLOW.read_text(encoding="utf-8")
    for workflow in (ci, e2e):
        assert "verify_browser_runtime_artifact.py" in workflow
        assert "CMUX_CEF_ALLOW_DOWNLOAD" in workflow
        assert "INFOPLIST_KEY_CMUXBuildSourceSHA" in workflow
    assert "trusted-browser-verifier" in reload_build
    assert "github.workflow_sha" in reload_build
    assert 'verifier="$GITHUB_WORKSPACE/trusted-browser-verifier/scripts/ci/verify_browser_runtime_artifact.py"' in reload_build
    assert "trusted-browser-verifier" in ci
    assert "github.event.pull_request.base.sha || github.workflow_sha" in ci
    assert "CMUX_BUILD_SOURCE_SHA" in reload_build
    assert "INFOPLIST_KEY_CMUXBuildSourceSHA" in (ROOT / "scripts" / "reload.sh").read_text(encoding="utf-8")


if __name__ == "__main__":
    for name, value in sorted(globals().items()):
        if name.startswith("test_") and callable(value):
            value()
    print("PASS: browser runtime verification contract")
