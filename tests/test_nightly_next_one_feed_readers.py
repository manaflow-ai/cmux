#!/usr/bin/env python3
"""Scripts read the one nightly-next feed (#36287), not the retired nightly-next/next/ feed.

#36287 put every nightly-next build on files-next.cmux.com/nightly-next/appcast-arm64.xml, signed as cmux NIGHTLY,
and retired nightly-next/next/. A script that still reads the retired feed measures or checks a build that no longer
moves. The ones left below install or check the cmux NEXT identity itself, which no longer ships; each needs its own
rework (the signed-host check's move to cmux NIGHTLY is its own PR: on the live build it does not pass).
"""
from __future__ import annotations

import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RETIRED = "files-next.cmux.com/nightly-next/next/appcast"
# They install and drive com.cmuxterm.app.nightly.cmux-next, an identity the one feed does not carry.
CMUX_NEXT_IDENTITY = {"scripts/cmux-next/update-e2e.py", "scripts/fuzz/macos-matrix/onboarding/nightly.py",
                      "scripts/ci/cua_signed_host_check.py"}


class OneFeedReaders(unittest.TestCase):
    def test_no_script_reads_the_retired_feed(self):
        found = subprocess.run(["git", "-C", str(ROOT), "grep", "-l", "-F", RETIRED, "--", "scripts"],
                               capture_output=True, text=True, check=False).stdout.split()
        self.assertEqual(sorted(set(found) - CMUX_NEXT_IDENTITY), [])


if __name__ == "__main__":
    unittest.main()
