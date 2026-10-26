#!/usr/bin/env python3
"""leakcheck.parse on `leaks` output in its list and tree formats, and on its errors.

python3 -I scripts/fuzz/macos-matrix/test_leakcheck.py (no Mac needed).
"""

import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import leakcheck  # noqa: E402

HEADER = """Process:         cmux DEV [4242]
Path:            /Applications/cmux DEV.app/Contents/MacOS/cmux DEV
leaks Report Version: 4.0
Process 4242: 812345 nodes malloced for 98765 KB
"""

LIST = HEADER + """Process 4242: 4 leaks for 240 total leaked bytes.

Leak: 0x600001e74000  size=128  zone: DefaultMallocZone_0x104a1c000   __NSDictionaryM  ObjC  CoreFoundation
Leak: 0x600001e74100  size=48  zone: DefaultMallocZone_0x104a1c000   __NSArrayM  ObjC  CoreFoundation
Leak: 0x600001e74200  size=48  zone: DefaultMallocZone_0x104a1c000   __NSArrayM  ObjC  CoreFoundation
Leak: 0x600001e74300  size=16  zone: DefaultMallocZone_0x104a1c000
"""

TREE = HEADER + """Process 4242: 3 leaks for 192 total leaked bytes.

    3 (192 bytes) << TOTAL >>

      2 (176 bytes) ROOT CYCLE: <CmuxNext.TabModel 0x600002f0c000> [160]
         1 (16 bytes) 0x600000c04010 [16]
            CYCLE BACK TO <CmuxNext.TabModel 0x600002f0c000> [160]

      1 (16 bytes) ROOT LEAK: <malloc in foo 0x600000c04020> [16]
"""

NONE = HEADER + "Process 4242: 0 leaks for 0 total leaked bytes.\n"


class ParseTest(unittest.TestCase):
    def test_list_format_counts_types_by_bytes(self):
        row = leakcheck.parse(LIST, 1)
        self.assertEqual((row["leaks"], row["bytes"], row["blocks_read"]), (4, 240, 4))
        self.assertEqual(row["top_types"], [
            {"type": "__NSDictionaryM", "count": 1, "bytes": 128},
            {"type": "__NSArrayM", "count": 2, "bytes": 96},
            {"type": "malloc", "count": 1, "bytes": 16},
        ])

    def test_tree_format_skips_cycle_back_lines(self):
        row = leakcheck.parse(TREE, 1)
        self.assertEqual((row["leaks"], row["bytes"], row["blocks_read"]), (3, 192, 3))
        self.assertEqual([(t["type"], t["count"], t["bytes"]) for t in row["top_types"]],
                         [("CmuxNext.TabModel", 1, 160), ("malloc", 1, 16), ("malloc in foo", 1, 16)])

    def test_no_leaks(self):
        self.assertEqual(leakcheck.parse(NONE, 0), {"leaks": 0, "bytes": 0, "blocks_read": 0, "top_types": []})

    def test_error_status_is_an_error_row(self):
        row = leakcheck.parse("leaks[99]: [fatal] unable to get task for pid 4242\n", 2)
        self.assertIn("leaks exit 2", row["error"])
        self.assertIn("task for pid", row["error"])
        self.assertTrue(leakcheck.summary_line(row).startswith("leaks: not measured"))

    def test_output_without_summary_is_an_error_row(self):
        self.assertIn("error", leakcheck.parse("", 124))

    @unittest.skipIf(os.path.exists("/usr/bin/leaks"), "this Mac has leaks; the case needs a host without it")
    def test_run_local_without_leaks_writes_the_output_and_an_error_row(self):
        with tempfile.TemporaryDirectory() as scratch:
            out = os.path.join(scratch, "leaks.txt")
            row = leakcheck.run_local(4242, out)
            self.assertEqual(row["pid"], 4242)
            self.assertIn("leaks exit 127", row["error"])
            with open(out) as written:
                self.assertTrue(written.read())

    def test_summary_line(self):
        line = leakcheck.summary_line(leakcheck.parse(LIST, 1))
        self.assertEqual(line, "leaks: 4 blocks, 240 bytes; top __NSDictionaryM 1x 128 B, __NSArrayM 2x 96 B, malloc 1x 16 B")


if __name__ == "__main__":
    unittest.main()
