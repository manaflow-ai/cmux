#!/usr/bin/env python3
"""Behavioral tests for iOS UI test selector normalization."""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
NORMALIZER = ROOT / "scripts" / "ci" / "normalize_ios_ui_test_selector.py"


def normalize(selector: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(NORMALIZER), selector],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )


def test_normalizes_the_previously_documented_class_method_form() -> None:
    result = normalize("cmuxUITests/testMockHostInstanceTagFollowsTargetBuildScope")

    assert result.returncode == 0
    assert (
        result.stdout.strip()
        == "cmuxUITests/cmuxUITests/testMockHostInstanceTagFollowsTargetBuildScope"
    )


def test_normalizes_another_ui_test_class_and_method() -> None:
    result = normalize("SnapshotUITests/testCaptureAppStoreScreenshots")

    assert result.returncode == 0
    assert (
        result.stdout.strip()
        == "cmuxUITests/SnapshotUITests/testCaptureAppStoreScreenshots"
    )


def test_preserves_full_target_class_and_method_selector() -> None:
    selector = "cmuxUITests/TerminalThemeParityUITests/testChromeRepaintsForLiveThemes"
    result = normalize(selector)

    assert result.returncode == 0
    assert result.stdout.strip() == selector


def test_preserves_full_target_and_class_selector() -> None:
    selector = "cmuxUITests/SnapshotUITests"
    result = normalize(selector)

    assert result.returncode == 0
    assert result.stdout.strip() == selector


def test_rejects_empty_selector_components() -> None:
    result = normalize("cmuxUITests//testSomething")

    assert result.returncode == 2
    assert "invalid iOS UI test selector" in result.stderr


if __name__ == "__main__":
    for name, value in sorted(globals().items()):
        if name.startswith("test_") and callable(value):
            value()
    print("PASS: iOS UI test selector normalization")
