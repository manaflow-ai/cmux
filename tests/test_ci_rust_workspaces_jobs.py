#!/usr/bin/env python3
"""rust-workspaces.py run caps CARGO_BUILD_JOBS by memory, so 122 test binaries linking at once with GNU ld
no longer lose `ld terminated with signal 9 [Killed]` (post-merge batch run 46181076635, 2026-11-28)."""
from __future__ import annotations

import importlib.util
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("rust_workspaces", ROOT / ".github/scripts/rust-workspaces.py")
rw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rw)
GIB = rw.GIB


class CargoJobs(unittest.TestCase):
    def test_memory_caps_cores(self) -> None:
        self.assertEqual(rw.cargo_jobs(16, 14 * GIB, 60 * GIB), 7)

    def test_mem_available_caps_when_smaller(self) -> None:
        self.assertEqual(rw.cargo_jobs(16, None, 9 * GIB), 4)

    def test_cores_cap_when_memory_is_plenty(self) -> None:
        self.assertEqual(rw.cargo_jobs(4, 64 * GIB, 64 * GIB), 4)

    def test_never_below_one(self) -> None:
        self.assertEqual(rw.cargo_jobs(8, GIB, None), 1)

    def test_no_reading_keeps_cores(self) -> None:
        self.assertEqual(rw.cargo_jobs(8, None, None), 8)


class Readers(unittest.TestCase):
    def test_cgroup_takes_smallest_limit_on_path(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "a" / "b").mkdir(parents=True)
            (root / "memory.max").write_text("max\n")
            (root / "a" / "memory.max").write_text(f"{20 * GIB}\n")
            (root / "a" / "b" / "memory.max").write_text(f"{14 * GIB}\n")
            cg = root / "self-cgroup"
            cg.write_text("0::/a/b\n")
            self.assertEqual(rw.cgroup_mem_bytes(cg, root), 14 * GIB)

    def test_cgroup_without_limit_is_none(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            cg = root / "self-cgroup"
            cg.write_text("0::/\n")
            (root / "memory.max").write_text("max\n")
            self.assertIsNone(rw.cgroup_mem_bytes(cg, root))

    def test_mem_available(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            m = Path(tmp) / "meminfo"
            m.write_text("MemTotal:       32000000 kB\nMemAvailable:    8388608 kB\n")
            self.assertEqual(rw.mem_available_bytes(m), 8 * GIB)


if __name__ == "__main__":
    unittest.main()
