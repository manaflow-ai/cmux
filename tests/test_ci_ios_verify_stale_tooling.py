#!/usr/bin/env python3
"""ios_verify refuses a --no-merge-base run whose head predates a base fix to the simulator tooling (cmux#62242 at
964d43e3 lacked cmux#65147 and spent a 71 min Mac build before pair-e2e failed), and runs once the head has it."""
import sys
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts" / "ci"))
import ios_verify  # noqa: E402

PAIR = "scripts/ci/cmux_next_pair_e2e.py"


def fake_git(blobs_head: dict, blobs_base: dict, changed: list, fork: str = "f" * 40):
    def git(*args, check=True):
        if args[0] == "merge-base":
            return fork
        if args[0] == "diff":
            return "\n".join(changed)
        if args[0] == "rev-parse":
            rev, path = args[-1].split(":", 1)
            return (blobs_base if rev.startswith("origin/") else blobs_head).get(path, "")
        raise AssertionError(args)
    return git


class StaleTooling(unittest.TestCase):
    def test_base_fix_the_head_lacks_is_stale(self):
        git = fake_git({PAIR: "old"}, {PAIR: "new"}, [PAIR])
        with mock.patch.object(ios_verify, "git", git):
            self.assertEqual(ios_verify.stale_tooling("a" * 40, "origin/feat-cmux-next"), [PAIR])

    def test_head_already_carrying_the_fix_is_not(self):
        git = fake_git({PAIR: "new"}, {PAIR: "new"}, [PAIR])
        with mock.patch.object(ios_verify, "git", git):
            self.assertEqual(ios_verify.stale_tooling("a" * 40, "origin/feat-cmux-next"), [])

    def test_no_fork_point_is_not(self):
        git = fake_git({}, {}, [PAIR], fork="")
        with mock.patch.object(ios_verify, "git", git):
            self.assertEqual(ios_verify.stale_tooling("a" * 40, "origin/feat-cmux-next"), [])

    def test_tooling_lists_the_sim_script_and_pair_harness(self):
        self.assertIn(ios_verify.SIM_SCRIPT, ios_verify.SIM_TOOLING)
        self.assertIn(PAIR, ios_verify.SIM_TOOLING)
        root = Path(__file__).resolve().parents[1]
        for f in ios_verify.SIM_TOOLING:
            self.assertTrue((root / f).is_file(), f)

    def test_exit_code_is_distinct(self):
        self.assertNotIn(ios_verify.STALE_TOOLING_EXIT, (0, 1, ios_verify.UNSIGNED_EXIT))


if __name__ == "__main__":
    unittest.main()
