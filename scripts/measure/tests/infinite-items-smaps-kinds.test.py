#!/usr/bin/env python3
"""smaps_kinds files a thread's stack as thread-stack and an allocator's segment above its reserved tail as anon."""
import builtins
import importlib.util
import io
from pathlib import Path
import unittest
from unittest.mock import patch


BENCH = Path(__file__).resolve().parents[1] / "infinite-items.py"


def load():
    spec = importlib.util.spec_from_file_location("infinite_items", BENCH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def mapping(start, end, perms, pss_kb, path=""):
    return f"{start:x}-{end:x} {perms} 00000000 00:00 0 {path}\nPss: {pss_kb} kB\n"


MB = 1 << 20
SMAPS = "".join([
    # A mimalloc segment: a 1664 KiB reserved tail, then the next segment's writable pages.
    mapping(0x3d6f2e60000, 0x3d6f3000000, "---p", 0),
    mapping(0x3d6f3000000, 0x3d6f3000000 + 96 * MB, "rw-p", 17944),
    # A glibc arena: its writable start on a 64 MB boundary.
    mapping(0x7f3800000000, 0x7f3800000000 + 4 * MB, "rw-p", 3000),
    # A thread's 2 MiB stack above an 8 KiB guard.
    mapping(0x7f39c9ca0000, 0x7f39c9ca2000, "---p", 0),
    mapping(0x7f39c9ca2000, 0x7f39c9ea3000, "rw-p", 12),
    # A cached (exited) thread's stack: no thread's pointer in it, still above a page guard.
    mapping(0x7f39d0010000 - 0x2000, 0x7f39d0010000, "---p", 0),
    mapping(0x7f39d0010000, 0x7f39d0211000, "rw-p", 8),
])


class SmapsKinds(unittest.TestCase):
    def kinds(self, sps):
        bench = load()
        real_open = builtins.open

        def fake_open(path, *a, **k):
            if str(path).endswith("/smaps"):
                return io.StringIO(SMAPS)
            return real_open(path, *a, **k)

        with patch.object(builtins, "open", fake_open), patch.object(bench.os.path, "realpath", return_value="/bin/x"), \
                patch.object(bench, "thread_stack_pointers", return_value=sps):
            return bench.smaps_kinds(1)

    def test_allocator_segment_above_a_large_tail_is_anon(self):
        kinds = self.kinds([])
        self.assertEqual(kinds.get("anon"), 17944)
        self.assertEqual(kinds.get("arena"), 3000)
        self.assertEqual(kinds.get("thread-stack"), 20)

    def test_a_mapping_holding_a_stack_pointer_is_a_stack(self):
        kinds = self.kinds([0x3d6f3000000 + 10 * MB])
        self.assertEqual(kinds.get("thread-stack"), 17944 + 20)
        self.assertEqual(kinds.get("anon"), 0)


if __name__ == "__main__":
    unittest.main()
