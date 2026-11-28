#!/usr/bin/env python3
"""Checks that scripts/release_whats_new_gate.py stops a bad release candidate.

    python3 tests/test_release_whats_new_gate.py

Each case builds a throwaway release checkout (CHANGELOG.md, a project file and,
for the structured cases, a stub scripts/whats-new/validate.py) and runs the gate
the way release.yml runs it on a tag push.
"""

from __future__ import annotations

from pathlib import Path
import os
import subprocess
import sys
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[1]
GATE = ROOT / "scripts/release_whats_new_gate.py"

GOOD = """# Changelog

## Unreleased

## [1.2.3] - 2026-11-20

### Added
- Splits open where you click ([#1](https://github.com/manaflow-ai/cmux/pull/1))

### Thanks to 1 contributor!
- [@someone](https://github.com/someone)

## [1.2.2] - 2026-11-01

### Fixed
- An older fix
"""


class ReleaseWhatsNewGateTest(unittest.TestCase):
    def checkout(self, changelog: str | None, validator: str | None = None,
                 marketing: str = "1.2.3") -> Path:
        root = Path(tempfile.mkdtemp(prefix="whats-new-gate-"))
        self.addCleanup(subprocess.run, ["rm", "-rf", str(root)])
        if changelog is not None:
            (root / "CHANGELOG.md").write_text(changelog, encoding="utf-8")
        (root / "cmux.xcodeproj").mkdir()
        (root / "cmux.xcodeproj/project.pbxproj").write_text(
            f"\t\t\t\tMARKETING_VERSION = {marketing};\n", encoding="utf-8")
        if validator is not None:
            (root / "scripts/whats-new").mkdir(parents=True)
            (root / "scripts/whats-new/validate.py").write_text(textwrap.dedent(validator), encoding="utf-8")
        return root

    def gate(self, root: Path, ref: str | None = "v1.2.3", mode: str | None = None,
             *args: str) -> subprocess.CompletedProcess[str]:
        env = {k: v for k, v in os.environ.items()
               if k not in ("GITHUB_REF_NAME", "GITHUB_REF_TYPE", "CMUX_WHATS_NEW_GATE_MODE")}
        if ref is not None:
            env.update(GITHUB_REF_NAME=ref, GITHUB_REF_TYPE="tag")
        if mode is not None:
            env["CMUX_WHATS_NEW_GATE_MODE"] = mode
        return subprocess.run([sys.executable, str(GATE), "--root", str(root), *args],
                              capture_output=True, text=True, env=env)

    def assertRefused(self, result: subprocess.CompletedProcess[str], needle: str) -> None:
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("REFUSED", result.stderr)
        self.assertIn(needle, result.stderr)

    def test_good_release_passes(self) -> None:
        result = self.gate(self.checkout(GOOD))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("ok for v1.2.3", result.stdout)

    def test_missing_section_is_refused(self) -> None:
        self.assertRefused(self.gate(self.checkout(GOOD), ref="v1.2.4"), "no '## [1.2.4] - YYYY-MM-DD' section")

    def test_empty_section_is_refused(self) -> None:
        changelog = "# Changelog\n\n## [1.2.3] - 2026-11-20\n\n## [1.2.2] - 2026-11-01\n\n### Fixed\n- x\n"
        self.assertRefused(self.gate(self.checkout(changelog)), "would be empty")

    def test_thanks_only_section_is_refused(self) -> None:
        changelog = "## [1.2.3] - 2026-11-20\n\n### Thanks to 1 contributor!\n- [@a](https://github.com/a)\n"
        self.assertRefused(self.gate(self.checkout(changelog)), "would be empty")

    def test_heading_without_items_is_refused(self) -> None:
        changelog = GOOD.replace("### Added\n", "### Changed\n\n### Added\n")
        self.assertRefused(self.gate(self.checkout(changelog)), "'### Changed' has no items")

    def test_placeholder_is_refused(self) -> None:
        changelog = GOOD.replace("Splits open where you click", "TODO describe the split change")
        self.assertRefused(self.gate(self.checkout(changelog)), "placeholder text")

    def test_unparseable_heading_is_refused(self) -> None:
        changelog = GOOD.replace("## [1.2.3] - 2026-11-20", "## 1.2.3")
        self.assertRefused(self.gate(self.checkout(changelog)), "not the page's heading form")

    def test_bad_date_is_refused(self) -> None:
        changelog = GOOD.replace("2026-11-20", "Nov 20")
        self.assertRefused(self.gate(self.checkout(changelog)), "is not YYYY-MM-DD")

    def test_missing_changelog_is_refused(self) -> None:
        self.assertRefused(self.gate(self.checkout(None)), "CHANGELOG.md is missing")

    def test_declared_no_user_facing_changes_passes(self) -> None:
        changelog = "## [1.2.3] - 2026-11-20\n\n_No user-facing changes._\n"
        self.assertEqual(self.gate(self.checkout(changelog)).returncode, 0)

    def test_rc_checks_its_stable_notes(self) -> None:
        self.assertEqual(self.gate(self.checkout(GOOD), ref="v1.2.3-rc.2").returncode, 0)
        self.assertRefused(self.gate(self.checkout(GOOD), ref="v1.3.0-rc.1"), "[1.3.0]")

    def test_nightly_is_skipped(self) -> None:
        self.assertEqual(self.gate(self.checkout(None), ref="v1.2.3-nightly.5").returncode, 0)

    def test_dispatch_uses_marketing_version(self) -> None:
        result = self.gate(self.checkout(GOOD, marketing="1.2.4"), ref=None)
        self.assertRefused(result, "[1.2.4]")

    def test_warn_mode_reports_without_failing(self) -> None:
        result = self.gate(self.checkout(GOOD), ref="v9.9.9", mode="warn")
        self.assertEqual(result.returncode, 0)
        self.assertIn("WARNING", result.stderr)
        self.assertIn("[9.9.9]", result.stderr)

    def test_unknown_mode_fails(self) -> None:
        self.assertEqual(self.gate(self.checkout(GOOD), mode="off").returncode, 1)

    def test_structured_validator_failure_is_refused(self) -> None:
        validator = """
            import sys
            print("whats-new/1.2.3.json is missing")
            sys.exit(1)
        """
        self.assertRefused(self.gate(self.checkout(GOOD, validator)), "whats-new/1.2.3.json is missing")

    def test_structured_validator_gets_the_release_arguments(self) -> None:
        validator = """
            import sys
            sys.exit(0 if sys.argv[1:3] == ["--root", sys.argv[2]] and sys.argv[2].endswith("/whats-new")
                     and sys.argv[3:] == ["--require-version", "1.2.3"] else 1)
        """
        self.assertEqual(self.gate(self.checkout(GOOD, validator), ref="v1.2.3-rc.1").returncode, 0)

    # Opt-in so this repo's CHANGELOG.md never fails a PR's CI: CMUX_WHATS_NEW_GATE_HISTORY=1.
    @unittest.skipUnless(os.environ.get("CMUX_WHATS_NEW_GATE_HISTORY") == "1", "history check is opt-in")
    def test_every_published_release_in_this_repo_passes(self) -> None:
        # The changelog rules only: no published release may be refused after the fact.
        import re
        changelog = (ROOT / "CHANGELOG.md").read_text(encoding="utf-8")
        versions = re.findall(r"^## \[([0-9.]+)\] - ", changelog, re.M)
        self.assertTrue(versions)
        root = self.checkout(changelog)
        for version in versions:
            result = self.gate(root, ref=f"v{version}")
            self.assertEqual(result.returncode, 0, f"{version}: {result.stderr}")


if __name__ == "__main__":
    unittest.main()
