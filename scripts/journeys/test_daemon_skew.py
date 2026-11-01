#!/usr/bin/env python3
"""A round is only evidence for the build under test when its daemons are that build (lead 01:2xZ, cmux-ad 01:25Z).

The cmux-tui owner and the acpmux daemon outlive the app: a new app can attach to an older daemon (#27829). The
driver records, per journey, each daemon's pid, the executable it runs and its build id, next to the app's own
build (its bundle's bin/cmux, which is also bin/acpmux), and a pass or a fail whose daemons are another build, or
cannot be verified, is "not run".

    python3 scripts/journeys/test_daemon_skew.py
"""
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))


class DaemonSkew(unittest.TestCase):
    def setUp(self):
        import driver
        self.d = driver
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.bundle = root / "cmux DEV x.app"
        bin_dir = self.bundle / "Contents" / "Resources" / "bin"
        bin_dir.mkdir(parents=True)
        (bin_dir / "cmux").write_text("binary")
        os.symlink("cmux", bin_dir / "acpmux")
        self.old = root / "old.app" / "Contents" / "Resources" / "bin"
        self.old.mkdir(parents=True)
        (self.old / "cmux").write_text("old binary")

    def tearDown(self):
        self.tmp.cleanup()

    def facts(self, tui_exe=None, tui_build="abc123", acp_exe=None, acp_build="abc123 2026-10-31", expected="abc123"):
        own = self.bundle / "Contents" / "Resources" / "bin"
        return {"expected_build": expected,
                "cmux_tui": {"pid": 11, "exe": str(tui_exe or own / "cmux"), "build_id": tui_build},
                "acpmux": None if acp_exe is False else {"pid": 12, "exe": str(acp_exe or own / "acpmux"),
                                                         "build": acp_build}}

    def test_daemons_of_the_bundle_under_test_are_valid(self):
        verdict = self.d.daemon_skew(self.facts(), str(self.bundle))
        self.assertIsNone(verdict)

    def test_an_older_cmux_tui_owner_makes_the_round_not_run(self):
        verdict = self.d.daemon_skew(self.facts(tui_exe=self.old / "cmux", tui_build="0ld999"), str(self.bundle))
        self.assertIn("cmux-tui", verdict)
        self.assertIn("0ld999", verdict)

    def test_a_build_id_that_differs_with_the_same_path_is_skew_too(self):
        self.assertIn("cmux-tui", self.d.daemon_skew(self.facts(tui_build="other"), str(self.bundle)))

    def test_an_acpmux_from_another_bundle_is_skew(self):
        verdict = self.d.daemon_skew(self.facts(acp_exe=self.old / "cmux"), str(self.bundle))
        self.assertIn("acpmux", verdict)

    def test_an_acpmux_whose_build_names_another_commit_is_skew(self):
        verdict = self.d.daemon_skew(self.facts(acp_build="fedcba9 2026-10-30"), str(self.bundle))
        self.assertIn("acpmux", verdict)

    def test_no_acpmux_running_is_valid_but_an_unverified_cmux_tui_owner_is_not(self):
        self.assertIsNone(self.d.daemon_skew(self.facts(acp_exe=False), str(self.bundle)))
        facts = self.facts()
        facts["cmux_tui"] = None
        self.assertIn("not verified", self.d.daemon_skew(facts, str(self.bundle)))
        facts = self.facts(expected=None)
        self.assertIn("not verified", self.d.daemon_skew(facts, str(self.bundle)))

    def test_the_verdict_turns_a_pass_or_a_fail_into_not_run_and_keeps_not_run(self):
        skew = "cmux-tui owner pid 11 runs build 0ld999"
        for status in ("pass", "fail"):
            got = self.d.apply_daemon_skew(status, "a check failed", skew)
            self.assertEqual(got[0], "not run")
            self.assertIn("daemon build", got[1])
            self.assertIn(status, got[1])
        self.assertEqual(self.d.apply_daemon_skew("not run", "no lease", skew)[0], "not run")
        self.assertEqual(self.d.apply_daemon_skew("pass", "", None), ("pass", ""))


if __name__ == "__main__":
    unittest.main()
