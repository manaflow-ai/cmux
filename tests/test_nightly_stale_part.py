#!/usr/bin/env python3
"""scripts/ci/nightly_stale_part.py: a failed iPhone host or Screen Sharing helper build never stops the nightly.

Run 45551813915 (2026-11-25): a cmux-mobile-link compile error failed the mobile-host join, and with it the whole
NEXT nightly. Now the part's last good copy (or none) is bundled and the part is reported stale.
"""
from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("nightly_stale_part", ROOT / "scripts/ci/nightly_stale_part.py")
part = importlib.util.module_from_spec(spec)
sys.modules["nightly_stale_part"] = part
spec.loader.exec_module(part)


class BundleTests(unittest.TestCase):
    def setUp(self):
        self.temp = Path(tempfile.mkdtemp())
        self.store, self.report, self.built = self.temp / "store", self.temp / "parts.json", self.temp / "host"
        self.calls: list[dict] = []

    def go(self, *, joined: bool, bundles=lambda env: True) -> tuple[int, str]:
        def fake_run(cmd, env):
            if "join" in cmd:
                return 0 if joined else 1
            self.calls.append({"bin": env.get("BIN"), "require": env.get("REQ")})
            return 0 if bundles(env) else 1
        argv = ["bundle", "--state", "s", "--job", "mobile-host", "--name", "cmux-mobile-host", "--built",
                str(self.built), "--report", str(self.report), "--bin-env", "BIN", "--require-env", "REQ",
                "--", "bundle.sh"]
        with mock.patch.object(part, "run", fake_run), mock.patch.dict(os.environ, {"CMUX_NIGHTLY_LAST_GOOD": str(self.store)}), \
                contextlib.redirect_stdout(io.StringIO()) as out:
            return part.main(argv), out.getvalue()

    def stale(self) -> list[str]:
        return [f["check"] for f in json.loads(self.report.read_text())["failed"]]

    def test_a_good_build_bundles_and_becomes_the_last_good_copy(self):
        self.built.write_bytes(b"new")
        Path(f"{self.built}.ref").write_text("abc123\n")
        code, out = self.go(joined=True)
        self.assertEqual(code, 0)
        self.assertEqual(self.calls, [{"bin": str(self.built), "require": "1"}])
        self.assertEqual((self.store / "cmux-mobile-host").read_bytes(), b"new")
        self.assertEqual((self.store / "cmux-mobile-host.ref").read_text(), "abc123\n")
        self.assertFalse(self.report.exists())
        self.assertNotIn("::warning", out)

    def test_a_failed_build_bundles_the_last_good_copy_and_reports_it(self):
        self.store.mkdir()
        (self.store / "cmux-mobile-host").write_bytes(b"old")
        (self.store / "cmux-mobile-host.ref").write_text("def456")
        code, out = self.go(joined=False)
        self.assertEqual(code, 0)
        self.assertEqual(self.calls, [{"bin": str(self.store / "cmux-mobile-host"), "require": "1"}])
        self.assertEqual(self.stale(), ["stale part: cmux-mobile-host"])
        self.assertIn("def456", self.report.read_text())
        self.assertIn("::warning title=nightly stale part", out)

    def test_with_no_last_good_copy_the_app_ships_without_the_part(self):
        code, _ = self.go(joined=False)
        self.assertEqual(code, 0)
        self.assertEqual(self.calls, [{"bin": None, "require": ""}])
        self.assertIn("ships without cmux-mobile-host", self.report.read_text())

    def test_a_part_that_built_but_did_not_bundle_falls_back(self):
        self.built.write_bytes(b"bad")
        code, _ = self.go(joined=True, bundles=lambda env: env.get("BIN") is None)
        self.assertEqual(code, 0)
        self.assertEqual([c["bin"] for c in self.calls], [str(self.built), None])
        self.assertIn("did not bundle", self.report.read_text())
        self.assertFalse((self.store / "cmux-mobile-host").exists())

    def test_bundling_with_no_part_at_all_failing_fails_the_step(self):
        code, out = self.go(joined=False, bundles=lambda env: False)
        self.assertEqual(code, 1)
        self.assertIn("::error", out)

    def test_the_report_keeps_other_entries_and_one_per_part(self):
        self.report.write_text(json.dumps({"failed": [{"check": "stale part: cmux-screen-sharing", "findings": ["x"]}]}))
        self.go(joined=False)
        self.go(joined=False)
        self.assertEqual(self.stale(), ["stale part: cmux-screen-sharing", "stale part: cmux-mobile-host"])

    def test_the_bundle_step_calls_it_for_both_parts(self):
        step = (ROOT / "scripts/ci/nightly-steps/app-bundle-chief-and-mobile-host.sh").read_text()
        for job in ("--job mobile-host", "--job screen-sharing-helper"):
            self.assertIn(f"nightly_stale_part.py bundle --state \"$state\" {job}", step)
        workflow = (ROOT / ".github/workflows/nightly.yml").read_text()
        self.assertIn('--report "$RUNNER_TEMP/nightly-stale-parts.json"', workflow)


if __name__ == "__main__":
    unittest.main()
