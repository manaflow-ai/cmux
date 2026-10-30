#!/usr/bin/env python3
"""The nightly-next canary's mode toggle and its one-week auto flip
(scripts/ci/nightly_next_canary_mode.py), and that both canaries use it."""
from __future__ import annotations

import datetime as dt
import importlib.util
from pathlib import Path
import re
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/nightly_next_canary_mode.py"
spec = importlib.util.spec_from_file_location("canary_mode", SCRIPT)
mode = importlib.util.module_from_spec(spec)
sys.modules["canary_mode"] = mode
spec.loader.exec_module(mode)

UTC = dt.timezone.utc
AFTER = "2026-10-27T16:00:00Z"
FLIP = dt.datetime(2026, 10, 27, 16, tzinfo=UTC)


def at(days: float) -> dt.datetime:
    return FLIP + dt.timedelta(days=days)


def never_read(_since):
    raise AssertionError("the report week must not be read")


def entries(*items):
    return lambda _since: list(items)


class ToggleTests(unittest.TestCase):
    def test_explicit_values_win_and_read_nothing(self):
        for value in ("report", "enforce", "off", " Enforce "):
            got, why = mode.resolve(value, AFTER, at(30), never_read)
            self.assertEqual(got, value.strip().lower())
            self.assertIn("NIGHTLY_NEXT_CANARY=", why)

    def test_unknown_value_is_refused(self):
        with self.assertRaises(mode.BadValue):
            mode.resolve("enfroce", AFTER, at(1), never_read)

    def test_never_keeps_report(self):
        self.assertEqual(mode.resolve("", "never", at(100), never_read)[0], "report")


class AutoFlipTests(unittest.TestCase):
    def test_before_the_date_reports(self):
        for value in ("", "auto"):
            got, why = mode.resolve(value, AFTER, at(-0.01), never_read)
            self.assertEqual(got, "report")
            self.assertIn("until 2026-10-27T16:00Z", why)

    def test_after_a_clean_week_enforces(self):
        older = (at(-8), "cmux NEXT build 1 failed the canary twice: run")  # before the week
        later = (at(1), "cmux NEXT build 3 failed the canary twice: run")   # after the flip
        chatter = (at(-2), "looked at it, flake")                            # not a failure entry
        got, why = mode.resolve("", AFTER, at(2), entries(older, later, chatter))
        self.assertEqual(got, "enforce", why)

    def test_a_failure_in_the_report_week_holds_report(self):
        bad = (at(-3), "cmux NEXT build 3947430561301 failed the canary twice: https://x")
        got, why = mode.resolve("auto", AFTER, at(5), entries(bad))
        self.assertEqual(got, "report")
        self.assertIn("1 build(s)", why)
        self.assertIn("set NIGHTLY_NEXT_CANARY=enforce", why)

    def test_the_decision_does_not_flap_later(self):
        bad = (at(-3), "cmux NEXT build 9 failed the canary twice")
        for later in (1, 10, 100):
            self.assertEqual(mode.resolve("", AFTER, at(later), entries(bad))[0], "report")

    def test_a_read_failure_stays_in_report(self):
        def broken(_since):
            raise OSError("HTTP 502")
        got, why = mode.resolve("", AFTER, at(1), broken)
        self.assertEqual(got, "report")
        self.assertIn("HTTP 502", why)

    def test_default_date_is_used_when_empty(self):
        default = mode.parse_when("")
        self.assertEqual(default, mode.parse_when(mode.DEFAULT_ENFORCE_AFTER))
        self.assertEqual(mode.resolve("", "", default - dt.timedelta(minutes=1), never_read)[0], "report")

    def test_date_only_values_are_utc_midnight(self):
        self.assertEqual(mode.parse_when("2026-11-01"), dt.datetime(2026, 11, 1, tzinfo=UTC))
        with self.assertRaises(mode.BadValue):
            mode.parse_when("next week")


class CliTests(unittest.TestCase):
    def run_cli(self, *args):
        return subprocess.run([sys.executable, str(SCRIPT), "resolve", *args],
                              capture_output=True, text=True, env={"PATH": "/usr/bin:/bin"})

    def test_prints_github_outputs(self):
        out = self.run_cli("--value", "", "--enforce-after", AFTER, "--now", "2026-10-21T00:00:00Z")
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertRegex(out.stdout, r"(?m)^mode=report$")
        self.assertRegex(out.stdout, r"(?m)^why=auto: report until ")

    def test_typo_exits_2(self):
        self.assertEqual(self.run_cli("--value", "on").returncode, 2)


class WiringTests(unittest.TestCase):
    canary = (ROOT / ".github/workflows/nightly-next-canary.yml").read_text()
    nightly = (ROOT / ".github/workflows/nightly.yml").read_text()

    def test_post_publication_verifier_uses_the_compatibility_mode(self):
        self.assertIn("scripts/ci/nightly_next_canary_mode.py resolve", self.canary)
        self.assertIn("NIGHTLY_NEXT_CANARY_ENFORCE_AFTER: ${{ vars.NIGHTLY_NEXT_CANARY_ENFORCE_AFTER }}", self.canary)
        self.assertNotIn("smoke-signed-app-cli.sh", self.canary)
        self.assertNotIn("nightly-next-rollback.yml", self.canary)

    def test_pre_publication_runtime_canary_is_removed(self):
        block = self.nightly[self.nightly.index("  verify-signed-nightly:"):]
        block = block[:block.index("\n  verify-final-dmg-nightly:")] if "\n  verify-final-dmg-nightly:" in block else block
        self.assertNotIn("nightly_next_canary_mode.py resolve", block)
        self.assertNotIn("smoke-signed-app-cli.sh", block)
        self.assertNotIn("smoke-launch-macos-app.sh", block)
        self.assertNotIn("issues: read", block)
        self.assertIn("verify-diff-sidecar-artifact.sh", block)


if __name__ == "__main__":
    unittest.main()
