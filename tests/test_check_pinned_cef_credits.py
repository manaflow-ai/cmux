#!/usr/bin/env python3
# Copyright 2026 Manaflow, Inc.
# SPDX-License-Identifier: GPL-3.0-or-later
"""Hermetic pin-promotion tests: verify CEF credits before a signed nightly.

Only synthetic CEF distributions are used; no controller, R2, GitHub or Mac
runtime access.  The production credit installer and validator run unchanged.
"""

from __future__ import annotations

import gzip
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "scripts/cmux-next"
PIN_CHECK = SCRIPTS / "check-pinned-assets.sh"
CREDITS = "Chromium Embedded Framework.framework/Resources/CREDITS.html"
CHROMIUM = "999.0.0.0"  # Disallows an accidental repository stock-credit fallback.


class CEFManifestCreditsTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="cef-pin-credits-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        self.tools = self.root / "tools"
        self.tools.mkdir()
        self.cef = self.root / "cef"
        self.log = self.root / "ensure-arches.txt"
        for arch in ("arm64", "x86_64"):
            credits = self.cef / arch / CREDITS
            credits.parent.mkdir(parents=True)
            credits.write_text("Chromium credits fixture\n" + "A" * 101_000)
        for tool in ("install-cef-credits.sh", "check-cef-credits.sh"):
            (self.tools / tool).symlink_to(SCRIPTS / tool)
        ensure = self.tools / "ensure-cef.sh"
        ensure.write_text(
            "#!/usr/bin/env bash\n"
            "set -euo pipefail\n"
            '[[ "$1" == --arch && $# == 2 ]] || exit 3\n'
            '[[ "${CMUX_CEF_NO_STORE:-}" == 1 && "${CMUX_CEF_NO_GITHUB:-}" == 1 ]] || exit 4\n'
            'printf "%s\\n" "$2" >> "$CMUX_FAKE_ENSURE_LOG"\n'
            'printf "%s\\n" "$CMUX_FAKE_CEF_ROOT/$2"\n'
        )
        ensure.chmod(0o755)
        self.manifest = self.repo / "scripts/cmux-next/cef-manifest.json"
        self.manifest.parent.mkdir(parents=True)
        self.git("init", "-q")
        self.git("config", "user.name", "fixture")
        self.git("config", "user.email", "fixture@example.invalid")
        self.write_manifest("old")
        self.git("add", ".")
        self.git("commit", "-qm", "old manifest")
        self.write_manifest("new")
        self.git("add", ".")
        self.git("commit", "-qm", "new CEF pin")

    def git(self, *args: str) -> None:
        subprocess.run(["git", *args], cwd=self.repo, check=True, capture_output=True)

    def write_manifest(self, version: str, *, universal: bool = True) -> None:
        data = {"version": version, "chromium": CHROMIUM}
        if universal:
            data["x86_64"] = {"asset": "synthetic-x86_64.tar.xz"}
        self.manifest.write_text(json.dumps(data, indent=2) + "\n")

    def run_check(self) -> subprocess.CompletedProcess[str]:
        self.log.unlink(missing_ok=True)
        env = {
            **os.environ,
            "PIN_ASSET_REPO_ROOT": str(self.repo),
            "PIN_ASSET_SCRIPT_DIR": str(self.tools),
            "CMUX_FAKE_ENSURE_LOG": str(self.log),
            "CMUX_FAKE_CEF_ROOT": str(self.cef),
            "RUNNER_TEMP": str(self.root),
        }
        return subprocess.run(
            ["bash", str(PIN_CHECK), "HEAD^1"],
            cwd=self.repo,
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )

    def assert_arches(self, *arches: str) -> None:
        self.assertEqual(self.log.read_text().splitlines(), list(arches))

    def test_valid_credits_are_checked_for_both_architectures(self) -> None:
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout.count("Chromium credits:"), 2)
        self.assert_arches("arm64", "x86_64")

    def test_missing_credits_fail_before_nightly_signing(self) -> None:
        (self.cef / "arm64" / CREDITS).unlink()
        result = self.run_check()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("no CREDITS.html and no stock credits", result.stderr)
        self.assert_arches("arm64")

    def test_second_architecture_must_have_credits_too(self) -> None:
        (self.cef / "x86_64" / CREDITS).unlink()
        result = self.run_check()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("no CREDITS.html and no stock credits", result.stderr)
        self.assert_arches("arm64", "x86_64")

    def test_placeholder_and_truncated_credits_are_rejected(self) -> None:
        path = self.cef / "arm64" / CREDITS
        for content, expected in (
            ("sample credits\n" + "A" * 101_000, "sample credits placeholder"),
            ("short\n", "too small"),
        ):
            with self.subTest(expected=expected):
                path.write_text(content)
                result = self.run_check()
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn(expected, result.stderr)
                self.assert_arches("arm64")

    def test_distributions_with_root_level_credits_pass(self) -> None:
        original = self.cef / "arm64" / CREDITS
        original.rename(self.cef / "arm64/CREDITS.html")
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assert_arches("arm64", "x86_64")

    def test_single_arch_manifest_skips_x86(self) -> None:
        self.write_manifest("third", universal=False)
        self.git("add", ".")
        self.git("commit", "-qm", "single arch pin")
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assert_arches("arm64")

    def test_matching_version_stock_credits_can_fill_missing_artifact(self) -> None:
        (self.cef / "arm64" / CREDITS).unlink()
        stock = self.tools / "chromium-credits" / f"{CHROMIUM}.html.gz"
        stock.parent.mkdir()
        with gzip.open(stock, "wb") as handle:
            handle.write(b"Chromium credits stock fixture\n" + b"B" * 101_000)
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("INTERIM stock CEF credits", result.stdout)
        self.assert_arches("arm64", "x86_64")


if __name__ == "__main__":
    unittest.main()
