#!/usr/bin/env python3
"""launch-ready-profile.py reads the main thread's stacks from the time-profile export the fleet Macs write.

    python3 scripts/measure/tests/launch-ready-profile.test.py
"""

import importlib.util
from pathlib import Path
import unittest

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("launch_ready_profile", HERE.parent / "launch-ready-profile.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class TaggedBacktraceTests(unittest.TestCase):
    def setUp(self):
        self.samples, self.others = module.parse((HERE / "fixtures" / "launch-ready-profile-tagged.xml").read_bytes(), 11153)

    def test_main_thread_samples_from_tagged_backtraces(self):
        # Three main-thread rows: one written out, one referring to it, one with its own stack. Before the fix all
        # three were dropped and the profile printed "no main-thread samples".
        self.assertEqual(len(self.samples), 3)
        self.assertEqual([s[0] for s in self.samples], [1300000000, 1301000000, 1302000000])
        self.assertEqual(self.samples[0][2][0], ("CGFontGetDescriptor", "CoreGraphics"))
        self.assertEqual(self.samples[0][2][-1], ("0x10245f24c", "cmux"))
        self.assertEqual(self.samples[1][2], self.samples[0][2])
        self.assertEqual(self.samples[2][2], [("objc_msgSend", "libobjcMsgSend.dylib"), ("0x10245f24c", "cmux")])
        self.assertTrue(all(w == 1000000 for _, w, _ in self.samples))

    def test_other_processes_kept_apart(self):
        self.assertEqual(self.others, [(250592458, 1000000, "simdiskimaged (478)")])


if __name__ == "__main__":
    unittest.main()
