#!/usr/bin/env python3
"""tests/unittest_shard.py: `--shard I/N` splits a unittest file's tests into N disjoint parts that cover it.

Manual lane (kept manual under the 2026-10-23 no-new-CI rule, since lifted): run it when unittest_shard.py changes,
`python3 -I tests/test_unittest_shard.py`; it needs only python3.
"""
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class UnittestShardsCoverTheFile(unittest.TestCase):
    """tests/unittest_shard.py: the N parts of a file run every test exactly once, and no flag runs them all."""

    def test_parts_are_disjoint_and_cover_every_test(self):
        with tempfile.TemporaryDirectory() as folder:
            target = Path(folder) / "test_seven.py"
            cases = "".join(f"    def test_{n}(self):\n        pass\n" for n in range(7))
            target.write_text(
                "import importlib.util, sys, unittest\n"
                f"spec = importlib.util.spec_from_file_location('unittest_shard', {str(ROOT / 'tests/unittest_shard.py')!r})\n"
                "shard = importlib.util.module_from_spec(spec); spec.loader.exec_module(shard)\n"
                f"class A(unittest.TestCase):\n{cases}class B(unittest.TestCase):\n{cases}"
                "if __name__ == '__main__':\n    shard.main()\n", encoding="utf-8")

            def ran(*args):
                done = subprocess.run([sys.executable, "-I", str(target), "-v", *args], capture_output=True,
                                      text=True, timeout=60)
                self.assertEqual(done.returncode, 0, done.stderr)
                return [line.split(" ...")[0] for line in done.stderr.splitlines() if " ... ok" in line]

            whole = ran()
            self.assertEqual(len(whole), 14)
            parts = [ran("--shard", f"{i}/3") for i in range(1, 4)]
            self.assertEqual(sorted(sum(parts, [])), sorted(whole))
            self.assertTrue(all(4 <= len(part) <= 5 for part in parts), parts)
            self.assertEqual(ran("--shard=2/3"), parts[1])
            for bad in ("0/3", "4/3", "x", "1/0"):
                done = subprocess.run([sys.executable, "-I", str(target), "--shard", bad], capture_output=True,
                                      text=True, timeout=60)
                self.assertEqual(done.returncode, 2, bad)


if __name__ == "__main__":
    unittest.main()
