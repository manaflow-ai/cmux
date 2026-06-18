#!/usr/bin/env python3
"""Behavioral guard for restored Xcode SourcePackages cache sanitation."""

from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "scripts" / "ci" / "sanitize-xcode-source-packages-cache.py"


def run_helper(cache_dir: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(HELPER), str(cache_dir)],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )


def test_removes_workspace_state_and_keeps_downloaded_cache() -> None:
    with tempfile.TemporaryDirectory() as temp_dir:
        cache_dir = Path(temp_dir) / ".ci-source-packages"
        artifact = cache_dir / "artifacts" / "sparkle" / "Sparkle" / "Sparkle.xcframework"
        checkout = cache_dir / "checkouts" / "swift-crypto" / "Package.swift"
        package_state = cache_dir / "checkouts" / "swift-crypto" / "workspace-state.json"
        state = cache_dir / "workspace-state.json"

        artifact.mkdir(parents=True)
        checkout.parent.mkdir(parents=True)
        checkout.write_text("// package fixture\n")
        package_state.write_text('{"package":"owned"}\n')
        state.write_text(
            '{"artifacts":["/Users/ec2-user/actions-runner-cmux/_work/cmux/cmux/'
            '.ci-source-packages/artifacts/sparkle/Sparkle/Sparkle.xcframework"]}\n'
        )

        result = run_helper(cache_dir)

        assert result.returncode == 0, result.stderr
        assert not state.exists()
        assert artifact.exists()
        assert checkout.exists()
        assert package_state.exists()
        assert "removed stale Xcode SourcePackages state" in result.stdout


def test_missing_cache_is_noop() -> None:
    with tempfile.TemporaryDirectory() as temp_dir:
        cache_dir = Path(temp_dir) / "missing-source-packages"

        result = run_helper(cache_dir)

        assert result.returncode == 0, result.stderr
        assert not cache_dir.exists()
        assert "no Xcode SourcePackages workspace-state.json files found" in result.stdout


def main() -> int:
    test_removes_workspace_state_and_keeps_downloaded_cache()
    test_missing_cache_is_noop()
    print("PASS: Xcode SourcePackages cache sanitizer preserves cache contents")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
