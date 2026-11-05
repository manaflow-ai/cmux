#!/usr/bin/env python3
"""Scripts read the one nightly-next feed (#36287), not the retired nightly-next/next/ feed.

#36287 put every nightly-next build on files-next.cmux.com/nightly-next/appcast-arm64.xml, signed as cmux NIGHTLY,
and retired nightly-next/next/. A script that still reads the retired feed measures or checks a build that no longer
moves. The two left below install the cmux NEXT identity itself, which no longer ships; they need their own rework.
"""
from __future__ import annotations

import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RETIRED = "files-next.cmux.com/nightly-next/next/appcast"
# They install and drive com.cmuxterm.app.nightly.cmux-next, an identity the one feed does not carry.
CMUX_NEXT_IDENTITY = {"scripts/cmux-next/update-e2e.py", "scripts/fuzz/macos-matrix/onboarding/nightly.py"}


class OneFeedReaders(unittest.TestCase):
    def test_no_script_reads_the_retired_feed(self):
        found = subprocess.run(["git", "-C", str(ROOT), "grep", "-l", "-F", RETIRED, "--", "scripts"],
                               capture_output=True, text=True, check=False).stdout.split()
        self.assertEqual(sorted(set(found) - CMUX_NEXT_IDENTITY), [])

    def test_the_signed_host_check_reads_the_one_feed_as_cmux_nightly(self):
        text = (ROOT / "scripts/ci/cua_signed_host_check.py").read_text()
        self.assertIn('default="https://files-next.cmux.com/nightly-next/appcast-arm64.xml"', text)
        self.assertIn('("nightly", "com.cmuxterm.app.nightly", args.feed)', text)
        self.assertNotIn('name == "next"', text)  # the retired NEXT artifact is no longer what passes the check


if __name__ == "__main__":
    unittest.main()
