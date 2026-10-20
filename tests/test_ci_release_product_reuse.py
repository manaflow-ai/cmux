#!/usr/bin/env python3
"""Guard the exact Release product producer/consumer boundary in CI."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
MACOS = (ROOT / ".github/workflows/ci-macos.yml").read_text()
GUARDS = (ROOT / ".github/workflows/ci-guards.yml").read_text()


def job(name: str, workflow: str = MACOS) -> str:
    match = re.search(rf"(?ms)^  {re.escape(name)}:\n(.*?)(?=^  [A-Za-z0-9_-]+:\n|\Z)", workflow)
    assert match, f"missing job {name}"
    return match.group(0)


def step(block: str, name: str) -> str:
    match = re.search(rf"(?ms)^      - name: {re.escape(name)}\n(.*?)(?=^      - name: |\Z)", block)
    assert match, f"missing step {name}"
    return match.group(0)


release = job("release-build")
package = job("swift-package-tests")
admission = job("macos-compile-admission")
guards = job("workflow-guard-tests", GUARDS)

assert "python3 scripts/ci/reuse_release_product.py restore build-universal" in release
assert release.index("Restore exact unsigned Release product") < release.index("Build app (Release)")
assert release.index("Build app (Release)") < release.index("Validate Release artifact slices")
assert release.index("Validate Release artifact slices") < release.index("Seal exact unsigned Release product")
assert release.index("Seal exact unsigned Release product") < release.index("Upload exact unsigned Release product")
assert "release-products-v1-${{ steps.release-product-key.outputs.key }}-${{ github.run_attempt }}" in release
assert "app-host-products-v1" not in release
assert "release-products-v1" not in admission

for name in (
    "Compute Xcode compilation cache key",
    "Capture Ghostty revision",
    "Cache GhosttyKit.xcframework",
    "Download pre-built GhosttyKit.xcframework",
    "Cache Xcode compilation results",
    "Cache Swift packages",
    "Sanitize Swift package cache",
    "Build app (Release)",
    "Download Release Ghostty CLI helper",
    "Install Release helpers",
):
    assert "if: steps.restore-release-product.outputs.hit != 'true'" in step(release, name), name

validator = step(release, "Validate Release artifact slices")
assert "\n        if:" not in validator
for needle in (
    './scripts/ci/verify-binary-archs.sh "$RELEASE_ARCHS" "$APP_BINARY" "$CLI_BINARY" "$CMUX_CUA_BINARY" "$HELPER_BINARY" "$TUI_CLIENT"',
    'codesign --verify --strict --verbose=4 "$CMUX_CUA_BINARY"',
    './scripts/verify-diff-sidecar-artifact.sh "$DIFF_SIDECAR" --archs "$RELEASE_ARCHS"',
    '[[ "$SDK_VERSION" == 26.* ]]',
    'shasum -a 256 "$HELPER_BINARY"',
):
    assert needle in validator, needle

assert "ghostty_helper_sha256:" in package
assert "ghostty_helper_toolchain_sha256:" in package
assert "ghostty_helper_sdk:" in package
assert "Record Release Ghostty helper identity" in package
assert "Resolve Release cmux-tui producer identity" in release
assert '--expected-commit "$CMUX_TUI_COMMIT"' in release
assert "CMUX_RELEASE_TUI_MANIFEST_SHA256" in release
assert "CMUX_RELEASE_GHOSTTY_HELPER_SHA256" in release

receipt = step(release, "Emit Release product reuse receipt")
for event in ("fresh_compile", "exact_restore", "restore_miss", "fallback_rebuild"):
    assert event in receipt, event
assert "restore_seconds" in receipt
assert "compile" in receipt
assert "validation" in receipt

assert "python3 tests/test_reuse_release_product.py" in guards
assert "python3 tests/test_ci_release_product_reuse.py" in guards

print("PASS: CI reuses only exact assembled Release products and revalidates every consumer")
