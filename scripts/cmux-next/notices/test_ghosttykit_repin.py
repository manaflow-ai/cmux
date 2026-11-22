#!/usr/bin/env python3
"""ghosttykit_repin.py: the one command a GhosttyNextKit pin author runs."""

from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path

# tests/known_red.py: a skip against an issue that fails once its checked-in date passes.
_known_red_spec = importlib.util.spec_from_file_location(
    "known_red", Path(__file__).resolve().parents[3] / "tests" / "known_red.py")
_known_red = importlib.util.module_from_spec(_known_red_spec)
_known_red_spec.loader.exec_module(_known_red)
known_red = _known_red.known_red

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("ghosttykit_repin", HERE / "ghosttykit_repin.py")
assert SPEC and SPEC.loader
repin = importlib.util.module_from_spec(SPEC)
sys.modules["ghosttykit_repin"] = repin
SPEC.loader.exec_module(repin)

PIN = {"url": "u", "sha256": "1" * 64, "ghostty_revision": "a" * 40}


class RepinTests(unittest.TestCase):
    def test_the_gitlink_must_name_the_pinned_revision(self) -> None:
        repin.check_pin_matches_gitlink(PIN, "a" * 40)
        with self.assertRaisesRegex(repin.RepinError, "same commit"):
            repin.check_pin_matches_gitlink(PIN, "b" * 40)

    def test_a_tree_for_another_revision_is_refused(self) -> None:
        self.assertIsNone(repin.tree_revision_error({"ghostty_revision": "a" * 40}, PIN, "7"))
        self.assertIn("run 7", repin.tree_revision_error({"ghostty_revision": "b" * 40}, PIN, "7"))

    @known_red(41322, "2026-12-02", "red on feat-cmux-next, line 33: notices/ios/link-set.json does not match the GhosttyKit pin")
    def test_the_repository_state_passes_check_repo(self) -> None:
        # The command ends with check-repo; the committed files are its output for today's pin.
        self.assertEqual(repin.ios.check_repo(), [])


if __name__ == "__main__":
    unittest.main()
