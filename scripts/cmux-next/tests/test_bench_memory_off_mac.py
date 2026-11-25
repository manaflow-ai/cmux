#!/usr/bin/env python3
"""bench_memory off a Mac: it imports (so `--help` of idle_cpu.py and the other benches that import it answers on
a Linux lane, and their pure helpers' tests need no ctypes mock), and a process-table read says it needs a Mac.
Run: python3 -I scripts/cmux-next/tests/test_bench_memory_off_mac.py (not a CI job)."""
import os, subprocess, sys, unittest

HERE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")


@unittest.skipIf(sys.platform == "darwin", "the macOS libraries load on a Mac")
class OffMac(unittest.TestCase):
    def test_import_works_and_a_read_names_the_mac(self):
        sys.path.insert(0, HERE)
        import bench_memory
        with self.assertRaisesRegex(OSError, "macOS"):
            bench_memory.usage(os.getpid())

    def test_idle_cpu_help_answers(self):
        run = subprocess.run([sys.executable, "-I", os.path.join(HERE, "idle_cpu.py"), "--help"],
                             capture_output=True, text=True, timeout=60)
        self.assertEqual(run.returncode, 0, run.stderr[-2000:])
        self.assertIn("usage", run.stdout)


if __name__ == "__main__":
    unittest.main()
