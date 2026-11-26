#!/usr/bin/env python3
"""scripts/ci/check_huge_files.py: no Swift or Rust source file crosses 100,000 bytes, and none over it grows.

NOW's code_shape.huge_files went 41 -> 18 after splits, then regrew to 25 as work landed in the old parents.
The fast gates hold the line per pull request against the base it merges into.
"""
from __future__ import annotations

import importlib.util
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/check_huge_files.py"
_spec = importlib.util.spec_from_file_location("check_huge_files", SCRIPT)
huge = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(huge)

ENV = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.com", "GIT_COMMITTER_NAME": "t",
       "GIT_COMMITTER_EMAIL": "t@example.com", "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_SYSTEM": os.devnull}
BIG = "cmux-tui/crates/acpmux/src/big.rs"
SMALL = "Packages/macOS/CmuxNext/Sources/CmuxNext/Small.swift"


def body(size: int, seed: str = "x") -> str:
    """SIZE bytes of distinct lines, so a rename is detected by content."""
    line = f"// {seed} " + "a" * 60 + "\n"
    lines = [f"{i:06d}{line}" for i in range(size // (len(line) + 6) + 1)]
    return "".join(lines)[:size]


class Scope(unittest.TestCase):
    def test_now_scope(self):
        for path in (BIG, SMALL, "Packages/Shared/CmuxIrxTransport/Sources/X/Y.swift",
                     "cmux-tui/crates/cmux-rd-host/src/linux_host/mod.rs"):
            self.assertTrue(huge.in_scope(path), path)
        for path in ("cmux-tui/crates/acpmux/tests/x.rs", "cmux-tui/crates/acpmux/src/hub/turns_tests.rs",
                     "cmux-tui/crates/acpmux/src/tests.rs", "cmux-tui/vendor/x/src/lib.rs",
                     "cmux-tui/crates/coord-sim/src/lib.rs", "cmux-tui/crates/x/examples/demo.rs",
                     "Packages/macOS/CmuxNext/Tests/CmuxNextTests/X.swift", "Packages/iOS/X/Sources/X/Y.swift",
                     "Packages/macOS/X/Sources/X/IconName+Members.swift", "acpmux/src/lib.rs",
                     "webviews/src/big.ts"):
            self.assertFalse(huge.in_scope(path), path)

    def test_the_fast_gates_run_check_against_the_merge(self):
        gates = (ROOT / "scripts/ci/cmux_next_fast_gates.py").read_text(encoding="utf-8")
        self.assertIn('"scripts/ci/check_huge_files.py", "check", "--base", base, "--head", merge', gates)


class Check(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.repo = Path(self.tmp.name)
        self.git("init", "-q", "-b", "main")
        self.write(BIG, body(120_000, "big"))
        self.write(SMALL, body(90_000, "small"))
        self.base = self.commit("base")

    def git(self, *args: str) -> str:
        return subprocess.run(["git", "-C", str(self.repo), *args], env=ENV, text=True, capture_output=True,
                              check=True).stdout.strip()

    def write(self, path: str, text: str) -> None:
        (self.repo / path).parent.mkdir(parents=True, exist_ok=True)
        (self.repo / path).write_text(text, encoding="utf-8")

    def commit(self, message: str) -> str:
        self.git("add", "-A")
        self.git("commit", "-q", "-m", message)
        return self.git("rev-parse", "HEAD")

    def run_check(self) -> subprocess.CompletedProcess:
        return subprocess.run(["python3", "-I", str(SCRIPT), "check", "--repo", str(self.repo), "--base", self.base,
                               "--head", "HEAD"], env=ENV, text=True, capture_output=True)

    def test_growing_a_file_already_over_the_limit_fails_with_both_sizes_and_the_split_advice(self):
        self.write(BIG, body(120_000, "big") + "// one more line\n")
        self.commit("grow")
        result = self.run_check()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn(f"::error title=Huge files::{BIG}: 120,000 -> 120,017 bytes", result.stdout)
        self.assertIn("already over", result.stdout)
        self.assertIn("_tests.rs", result.stdout)

    def test_shrinking_a_file_over_the_limit_passes(self):
        self.write(BIG, body(110_000, "big"))
        self.commit("shrink")
        self.assertEqual(self.run_check().returncode, 0)

    def test_crossing_the_limit_fails(self):
        self.write(SMALL, body(100_001, "small"))
        self.commit("cross")
        result = self.run_check()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn(f"{SMALL}: 90,000 -> 100,001 bytes", result.stdout)
        self.assertIn("now over", result.stdout)

    def test_growing_up_to_the_limit_passes(self):
        self.write(SMALL, body(100_000, "small"))
        self.commit("grow to the limit")
        self.assertEqual(self.run_check().returncode, 0)

    def test_a_new_file_over_the_limit_fails(self):
        path = "cmux-tui/crates/acpmux/src/new_one.rs"
        self.write(path, body(101_000, "new"))
        self.commit("new")
        result = self.run_check()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn(f"{path}: new file is 101,000 bytes", result.stdout)

    def test_a_new_file_out_of_scope_passes(self):
        self.write("cmux-tui/crates/acpmux/src/hub/big_tests.rs", body(150_000, "tests"))
        self.write("Packages/macOS/CmuxNext/Tests/CmuxNextTests/Big.swift", body(150_000, "swifttests"))
        self.commit("tests")
        self.assertEqual(self.run_check().returncode, 0)

    def test_a_pure_move_of_a_file_over_the_limit_passes_and_a_move_that_grows_fails(self):
        moved = "cmux-tui/crates/acpmux/src/hub/big.rs"
        (self.repo / moved).parent.mkdir(parents=True)
        self.git("mv", BIG, moved)
        self.commit("move")
        self.assertEqual(self.run_check().returncode, 0, self.run_check().stdout)
        self.write(moved, body(120_000, "big") + "// more\n")
        self.commit("grow after move")
        result = self.run_check()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn(f"(moved from {BIG})", result.stdout)

    def test_list_names_offenders_largest_first(self):
        self.write("cmux-tui/crates/x/src/bigger.rs", body(130_000, "bigger"))
        self.write("cmux-tui/crates/x/tests/huge.rs", body(300_000, "t"))
        self.commit("more")
        out = subprocess.run(["python3", "-I", str(SCRIPT), "list", "--repo", str(self.repo)], env=ENV, text=True,
                             capture_output=True, check=True).stdout.splitlines()
        self.assertEqual([line.split()[-1] for line in out], ["cmux-tui/crates/x/src/bigger.rs", BIG])
        self.assertEqual(out[0].split()[0], "130,000")


if __name__ == "__main__":
    unittest.main()
