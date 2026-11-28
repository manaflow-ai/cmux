"""Detector `git-low-speed-floor`: a git transfer's low-speed floor is 1 B/s, never higher.

While GitHub builds a pack for a fetch it sends only keepalives, far below 1 KB/s, for as long as the
build takes (tens of seconds for a merge sha of this repo). A floor above 1 B/s (`http.lowSpeedLimit`,
`GIT_HTTP_LOW_SPEED_LIMIT`) kills that working fetch, and the job goes red until someone reruns it:
hq#29032 found 67 pool fetches killed at exactly 20 s by a 10240 B/s floor. A real stall sends no byte,
so a 1 B/s floor still ends it at `lowSpeedTime`. curl downloads of files keep their own floor.

Handbook: cmuxterm-hq docs/handbook/patterns/fetch-shape-stalls-before-the-first-byte.md.
"""
from __future__ import annotations

import re
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCANNED = (".github", "scripts")
FLOOR = re.compile(r"""(?:http\.lowSpeedLimit=|GIT_HTTP_LOW_SPEED_LIMIT(?:["']?\s*[=:]\s*|=\$\{GIT_HTTP_LOW_SPEED_LIMIT:-|:-))["']?(\d+)""")
# path: why its floor above 1 is deliberate.
ALLOWED: dict[str, str] = {}


def violations(text: str) -> list[str]:
    return [m.group(0) for m in FLOOR.finditer(text) if int(m.group(1)) > 1]


class GitLowSpeedFloor(unittest.TestCase):
    def test_the_detector_catches_each_spelling(self) -> None:
        for bad in ('git -c http.lowSpeedLimit=1000 fetch', 'GIT_HTTP_LOW_SPEED_LIMIT: "1024"',
                    'export GIT_HTTP_LOW_SPEED_LIMIT="${GIT_HTTP_LOW_SPEED_LIMIT:-1000}"',
                    'GIT_HTTP_LOW_SPEED_LIMIT=10240 git clone', 'GIT_HTTP_LOW_SPEED_LIMIT = "1000"'):
            self.assertTrue(violations(bad), bad)
        for good in ('git -c http.lowSpeedLimit=1 fetch', 'GIT_HTTP_LOW_SPEED_LIMIT: "1"',
                     'GIT_HTTP_LOW_SPEED_LIMIT="${GIT_HTTP_LOW_SPEED_LIMIT:-1}"', 'http.lowSpeedLimit=0'):
            self.assertFalse(violations(good), good)

    def test_no_git_transfer_has_a_floor_above_one_byte_per_second(self) -> None:
        files = subprocess.run(["git", "-C", str(ROOT), "ls-files", "-z", "--", *SCANNED], check=True,
                               capture_output=True).stdout.decode().split("\0")
        found = []
        for name in filter(None, files):
            path = ROOT / name
            if name in ALLOWED or not path.is_file():
                continue
            try:
                text = path.read_text()
            except (UnicodeDecodeError, OSError):
                continue
            found += [f"{name}: {hit}" for hit in violations(text)]
        self.assertEqual(found, [], "a git low-speed floor above 1 B/s kills a fetch while GitHub builds its pack "
                                     "(keepalives only); use 1, or add the path to ALLOWED with its reason")


if __name__ == "__main__":
    unittest.main()
