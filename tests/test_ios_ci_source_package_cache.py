#!/usr/bin/env python3
"""Guard the source-only Swift package cache used by iOS CI and releases."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CACHE_ACTION = "actions/cache@27d5ce7f107fe9357f9df03efb73ab90386fccae"
LOCKFILE = "ios/cmuxPackage/Package.resolved"


def require_workflow_cache(path: str, *, consumer: str) -> None:
    text = (ROOT / path).read_text()
    cache = text.index("- name: Cache Swift package repositories")
    use = text.index(consumer, cache)

    block = text[cache:use]
    assert CACHE_ACTION in block
    assert "path: .spm-cache/repositories" in block
    assert "key: spm-repositories-${{" in block
    assert f"hashFiles('{LOCKFILE}')" in block
    assert "path: .spm-cache\n" not in block
    assert "Sanitize Swift package cache" not in block


def main() -> None:
    require_workflow_cache(
        ".github/workflows/ios-testflight.yml",
        consumer="- name: Archive, export, and upload to TestFlight",
    )
    require_workflow_cache(
        ".github/workflows/ios-app-store.yml",
        consumer="- name: Archive, export, and upload production build",
    )
    require_workflow_cache(
        ".github/workflows/test-ios.yml",
        consumer="- name: Run iOS simulator tests",
    )

    test_workflow = (ROOT / ".github/workflows/test-ios.yml").read_text()
    assert test_workflow.count(
        '-clonedSourcePackagesDirPath "$IOS_SOURCE_PACKAGES_DIR"'
    ) == 1
    assert "-resolvePackageDependencies" not in test_workflow

    upload_script = (ROOT / "ios/scripts/upload-testflight.sh").read_text()
    assert "CMUX_XCODE_SOURCE_PACKAGES_DIR" in upload_script
    assert upload_script.count('"${XCODE_SOURCE_PACKAGE_ARGS[@]}"') == 2
    assert upload_script.index("XCODE_SOURCE_PACKAGE_ARGS=()") < upload_script.index(
        "xcodebuild archive"
    )

    for workflow in (
        ".github/workflows/ios-testflight.yml",
        ".github/workflows/ios-app-store.yml",
    ):
        text = (ROOT / workflow).read_text()
        assert (
            "CMUX_XCODE_SOURCE_PACKAGES_DIR: "
            "${{ github.workspace }}/.spm-cache"
        ) in text

    print("PASS: iOS CI and release lanes cache only Swift package repositories")


if __name__ == "__main__":
    main()
