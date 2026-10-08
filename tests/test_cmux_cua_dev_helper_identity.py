#!/usr/bin/env python3
"""A tagged dev build never carries or launches an ad-hoc cmux Computer Use helper.

The TCC rows for com.cmuxterm.cua hold the Developer ID requirement of the
release helper. An ad-hoc copy can never satisfy them, and a grant to one
replaces the row. So a dev build bundles no helper app, drops a stale ad-hoc
one, and the bench refuses to launch an ad-hoc helper.
"""

from __future__ import annotations

import os
import platform
import plistlib
import shutil
import stat
import subprocess
import tempfile
from pathlib import Path

import test_cmux_cua_build_cache_safety as build_fixture


ROOT = Path(__file__).resolve().parents[1]
BUILD_SCRIPT = ROOT / "scripts" / "build-cmux-cua.sh"
TRUST_SCRIPT = ROOT / "scripts" / "cmux-cua-helper-trust.sh"
BENCH_HELPER = ROOT / "tests" / "automation-bench" / "cua" / "helper.sh"
HELPER_ID = "com.cmuxterm.cua"


def ad_hoc_helper(app: Path) -> Path:
    """A helper with the real bundle id, signed ad hoc the way a dev build signs it."""
    macos = app / "Contents" / "MacOS"
    macos.mkdir(parents=True)
    shutil.copy("/usr/bin/true", macos / "cmux-cua")
    with (app / "Contents" / "Info.plist").open("wb") as handle:
        plistlib.dump(
            {"CFBundleIdentifier": HELPER_ID, "CFBundleExecutable": "cmux-cua", "CFBundlePackageType": "APPL"},
            handle,
        )
    subprocess.run(
        ["/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none", "--identifier", HELPER_ID,
         "--requirements", f'=designated => identifier "{HELPER_ID}"', str(app)],
        check=True,
        capture_output=True,
    )
    return app


def build_dev_app(root: Path, extra: list[str]) -> tuple[subprocess.CompletedProcess[str], Path]:
    sha = build_fixture.pinned_sha()
    contents = root / "cmux DEV test.app" / "Contents"
    output = contents / "Resources" / "bin" / "cmux-cua"
    arch = "arm64" if platform.machine() in {"arm64", "aarch64"} else "x86_64"
    result = subprocess.run(
        [str(BUILD_SCRIPT), "--output", str(output), "--archs", arch, "--cache-dir", str(root / "cache"), *extra],
        env=build_fixture.successful_build_environment(root, sha),
        capture_output=True,
        text=True,
    )
    return result, contents / "Library" / "cmux Computer Use.app"


def test_dev_build_bundles_no_helper_app() -> None:
    with tempfile.TemporaryDirectory(prefix="cmux-cua-dev-helper-") as tmp:
        result, helper = build_dev_app(Path(tmp), [])
        assert result.returncode == 0, result.stderr
        assert not helper.exists(), "a dev build assembled an ad-hoc cmux Computer Use.app"


def test_release_packaging_still_assembles_on_request() -> None:
    with tempfile.TemporaryDirectory(prefix="cmux-cua-release-helper-") as tmp:
        result, helper = build_dev_app(Path(tmp), ["--helper-app"])
        assert result.returncode == 0, result.stderr
        assert (helper / "Contents" / "MacOS" / "cmux-cua").exists(), result.stdout


def test_ad_hoc_helper_fails_the_trust_check() -> None:
    with tempfile.TemporaryDirectory(prefix="cmux-cua-trust-") as tmp:
        helper = ad_hoc_helper(Path(tmp) / "cmux Computer Use.app")
        check = subprocess.run([str(TRUST_SCRIPT), "check", str(helper)], capture_output=True, text=True)
        assert check.returncode == 1, (check.returncode, check.stderr)
        missing = subprocess.run([str(TRUST_SCRIPT), "check", str(Path(tmp) / "none.app")], capture_output=True)
        assert missing.returncode == 1


def test_same_team_non_developer_id_signatures_fail_the_trust_check() -> None:
    # Apple Development and Apple Distribution signatures of team 7WLXT3NR37
    # (tests/fixtures/cua-helper-signatures) are not the release helper's
    # designated requirement; a grant to either replaces the release row.
    for kind in ("apple-development", "apple-distribution"):
        helper = ROOT / "tests" / "fixtures" / "cua-helper-signatures" / kind / "cmux Computer Use.app"
        assert (helper / "Contents" / "MacOS" / "cmux-cua").exists(), helper
        check = subprocess.run([str(TRUST_SCRIPT), "check", str(helper)], capture_output=True, text=True)
        assert check.returncode == 1, (kind, check.returncode, check.stderr)


def test_stale_ad_hoc_nested_helper_is_dropped() -> None:
    with tempfile.TemporaryDirectory(prefix="cmux-cua-drop-") as tmp:
        host = Path(tmp) / "cmux DEV test.app"
        helper = ad_hoc_helper(host / "Contents" / "Library" / "cmux Computer Use.app")
        sibling = host / "Contents" / "Library" / "LaunchAgents"
        sibling.mkdir(parents=True)
        result = subprocess.run([str(TRUST_SCRIPT), "drop-unsigned", str(host)], capture_output=True, text=True)
        assert result.returncode == 0, result.stderr
        assert not helper.exists(), "the stale ad-hoc helper is still in the dev app"
        assert sibling.exists(), "dropping the helper removed something else"


def test_bench_refuses_an_ad_hoc_helper() -> None:
    with tempfile.TemporaryDirectory(prefix="cmux-cua-bench-") as tmp:
        root = Path(tmp)
        helper = ad_hoc_helper(root / "cmux Computer Use.app")
        bin_dir = root / "bin"
        bin_dir.mkdir()
        marker = root / "open-called"
        fake_open = bin_dir / "open"
        fake_open.write_text(f'#!/bin/bash\ntouch "{marker}"\nexit 1\n')
        fake_open.chmod(fake_open.stat().st_mode | stat.S_IXUSR)
        environment = os.environ.copy()
        environment.update({"PATH": f"{bin_dir}:{environment['PATH']}", "HOME": str(root),
                            "CMUX_BENCH_HELPER": str(helper)})
        result = subprocess.run([str(BENCH_HELPER), "start", "identity-test", "--glide-ms", "0"], env=environment,
                                capture_output=True, text=True, timeout=60)
        assert result.returncode != 0
        assert not marker.exists(), "the bench launched an ad-hoc helper"


def main() -> int:
    test_dev_build_bundles_no_helper_app()
    test_release_packaging_still_assembles_on_request()
    test_ad_hoc_helper_fails_the_trust_check()
    test_same_team_non_developer_id_signatures_fail_the_trust_check()
    test_stale_ad_hoc_nested_helper_is_dropped()
    test_bench_refuses_an_ad_hoc_helper()
    print("PASS: dev builds carry and launch no ad-hoc cmux Computer Use helper")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
