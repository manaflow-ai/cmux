#!/usr/bin/env python3
"""Every workflow downloads artifacts with an actions/download-artifact that fails a stalled download.

Classic nightly runs 45538633457 and 45552004558 (2026-11-25): in every prepare-nightly-variant leg the
fallback "Download unsigned nightly app" (actions/download-artifact v4.3.0) logged "Starting download", went
quiet for 2 to 13 minutes and ended green with no "completed" line; "Restore unsigned nightly products" then
failed on `truncated gzip input`. In v4.3.0 a blob chunk that stops for 30 s only destroys the response
stream: the promise never settles, Node's event loop empties, and the step exits 0 with a partial archive.
v7.0.0 rejects on that timeout, so the step fails where the download failed. Pins below v7 are refused here.
"""
from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"
USES = re.compile(r"uses:\s*actions/download-artifact@([0-9a-f]{40}|v[0-9][^\s#]*)\s*(?:#\s*(\S+))?")
# v7.0.0 (37930b1), the pin every other download uses.
STALL_SAFE = {"37930b1c2abaa49bbe596cd826c3c89aef350131"}


class DownloadArtifactStallTests(unittest.TestCase):
    def test_every_download_artifact_pin_fails_a_stalled_download(self) -> None:
        bad = []
        for path in sorted(WORKFLOWS.glob("*.y*ml")):
            for number, line in enumerate(path.read_text().splitlines(), 1):
                match = USES.search(line)
                if match and match.group(1) not in STALL_SAFE:
                    bad.append(f"{path.name}:{number}: {match.group(1)} {match.group(2) or ''}".rstrip())
        self.assertEqual(bad, [], "actions/download-artifact below v7 ends a stalled download green with a "
                         "partial file; pin 37930b1c2abaa49bbe596cd826c3c89aef350131 # v7.0.0")

    def test_the_pattern_sees_a_pin(self) -> None:
        line = "        uses: actions/download-artifact@d3f86a106a0bac45b974a628896c90dbdf5c8093 # v4.3.0"
        self.assertEqual(USES.search(line).group(1), "d3f86a106a0bac45b974a628896c90dbdf5c8093")


if __name__ == "__main__":
    unittest.main()
