#!/usr/bin/env python3
"""launch-ready-profile.py reads the main thread's stacks from the time-profile export the fleet Macs write, keeps
them beside the trace, and names a stripped app's frames from its dSYM.

    python3 scripts/measure/tests/launch-ready-profile.test.py
"""

import contextlib
import importlib.util
import io
import os
from pathlib import Path
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("launch_ready_profile", HERE.parent / "launch-ready-profile.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

APP = "/Applications/cmux NIGHTLY.app/Contents/MacOS/cmux"


class TaggedBacktraceTests(unittest.TestCase):
    def setUp(self):
        xml = (HERE / "fixtures" / "launch-ready-profile-tagged.xml").read_bytes()
        self.samples, self.others, self.images = module.parse(xml, 11153)

    def test_main_thread_samples_from_tagged_backtraces(self):
        # Three main-thread rows: one written out, one referring to it, one with its own stack. Before the fix all
        # three were dropped and the profile printed "no main-thread samples".
        self.assertEqual(len(self.samples), 3)
        self.assertEqual([s[0] for s in self.samples], [1300000000, 1301000000, 1302000000])
        self.assertEqual(self.samples[0][2][0], ("CGFontGetDescriptor", "CoreGraphics", "0x1a0000010"))
        self.assertEqual(self.samples[0][2][-1], ("0x10245f24c", "cmux", "0x10245f24c"))
        self.assertEqual(self.samples[1][2], self.samples[0][2])
        self.assertEqual(self.samples[2][2], [("objc_msgSend", "libobjcMsgSend.dylib", "0x19a000000"),
                                              ("0x10245f24c", "cmux", "0x10245f24c")])
        self.assertTrue(all(w == 1000000 for _, w, _ in self.samples))

    def test_other_processes_kept_apart(self):
        self.assertEqual(self.others, [(250592458, 1000000, "simdiskimaged (478)")])

    def test_images_with_their_load_address(self):
        self.assertEqual(self.images, {"cmux": {"load": "0x102300000", "uuid": "D61F3064-FA02-36DF-8B91-B1D69F7DC881"}})


class SavedSamplesTests(unittest.TestCase):
    """The samples file round-trips, and --samples prints the spans, the busy stretch and the dSYM's names."""

    def setUp(self):
        xml = (HERE / "fixtures" / "launch-ready-profile-tagged.xml").read_bytes()
        samples, _, images = module.parse(xml, 11153)
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = os.path.join(self.tmp.name, "head-run1.samples.json.gz")
        # Process start 1290 ms on the trace's clock: the three samples land at 10, 11 and 12 ms.
        run = {"pid": 11153, "window_on_screen": 11.5, "marks": {"main_start": 9.0, "first_window_frame_committed": 12.5}}
        module.save(self.path, samples, 1_290_000_000, 12.5 + 600, images, run, "head")

    def output(self, dsym=None):
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            module.from_samples(self.path, dsym)
        return buf.getvalue().splitlines()

    def test_spans_and_busy_stretch(self):
        lines = self.output()
        self.assertIn("LR-PROFILE head phase main_start..window_on_screen 2.0 ms of 2 ms wall", lines)
        self.assertIn("LR-PROFILE head busy 10.0..12.0 ms, 2 ms wall, 3.0 ms sampled, ends 0.5 ms before the frame; "
                      "spans (ms): main_start..window_on_screen 2, window_on_screen..first_window_frame_committed 0", lines)
        self.assertIn("LR-PROFILE head self     2.0 ms CGFontGetDescriptor", lines)

    def test_names_from_the_dsym_symbol_table(self):
        # 0x10245f24c is the call's return address: 0x10015f24b at the link address, inside the first symbol.
        nm = os.path.join(self.tmp.name, "llvm-nm")
        Path(nm).write_text("#!/bin/sh\nprintf '%s\\n' '0000000100150000 T _$s4cmux11AppDelegateC6launchyyF' "
                            "'000000010015f24c t _next' '0000000100160000 T _end'\n")
        os.chmod(nm, 0o755)
        which = module.shutil.which
        module.shutil.which = lambda name: None  # the nm path, also on a Mac where atos is found
        os.environ["LLVM_NM"] = nm
        try:
            lines = self.output(os.path.join(self.tmp.name, "cmux.app.dSYM"))
        finally:
            module.shutil.which = which
            del os.environ["LLVM_NM"]
        self.assertIn("LR-PROFILE head cmux image D61F3064-FA02-36DF-8B91-B1D69F7DC881 at 0x102300000", lines)
        self.assertIn("LR-PROFILE head incl     3.0 ms $s4cmux11AppDelegateC6launchyyF", lines)


class FrameworkImageTests(unittest.TestCase):
    """Since cmux#44204 the app's code is CmuxNextApp.framework behind a stub executable: its frames are named from
    its own dSYM, found in a folder of dSYMs (a nightly's nightly-next-dsyms artifact), linked at 0, not 0x100000000."""

    def test_framework_frames_named_from_a_folder_of_dsyms(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name)
        for bundle, image in (("cmux.app.dSYM", "cmux"), ("CmuxNextApp.framework.dSYM", "CmuxNextApp")):
            dwarf = root / "dsyms" / "Release" / bundle / "Contents" / "Resources" / "DWARF"
            dwarf.mkdir(parents=True)
            (dwarf / image).write_text("")
        nm = root / "llvm-nm"
        # The framework's table starts at 0 (a dylib's link address); the stub's at 0x100000000.
        nm.write_text("#!/bin/sh\ncase \"$3\" in\n"
                      "*CmuxNextApp) printf '%s\\n' '0000000000001000 T _$s11CmuxNextApp12LaunchWarmupO5startyyFZ' "
                      "'0000000000002000 T _end' ;;\n"
                      "*) printf '%s\\n' '0000000100000000 T _main' '0000000100001000 T _end' ;;\nesac\n")
        nm.chmod(0o755)
        images = {"cmux": {"load": "0x102000000", "uuid": "A"}, "CmuxNextApp": {"load": "0x108000000", "uuid": "B"},
                  "dyld": {"load": "0x18d306000", "uuid": "C"}}
        # The leaf at 0x108001010 (framework offset 0x1010), its caller in the stub at 0x102000010.
        samples = [(0, 1000000, [("0x108001010", "?", "0x108001010"), ("0x102000010", "cmux", "0x102000010")])]
        which = module.shutil.which
        module.shutil.which = lambda name: None
        os.environ["LLVM_NM"] = str(nm)
        try:
            named = module.symbolicate(samples, images, str(root / "dsyms"))
        finally:
            module.shutil.which = which
            del os.environ["LLVM_NM"]
        frames = named[0][2]
        self.assertEqual(frames[0][:2], ("$s11CmuxNextApp12LaunchWarmupO5startyyFZ", "CmuxNextApp"))
        self.assertEqual(frames[1][:2], ("main", "cmux"))

    def test_no_dsym_for_an_image_leaves_its_frames(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.assertIsNone(module.dwarf_for(tmp.name, "CmuxNextApp"))


if __name__ == "__main__":
    unittest.main()
