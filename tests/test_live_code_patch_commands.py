#!/usr/bin/env python3
"""scripts/live-code/patch.py's command lookup: the last frontend line of a module in xcodebuild.log, kept in
LOG.commands.json until the log changes, so a live mode save does not read the whole log again.

  python3 tests/test_live_code_patch_commands.py
"""
import importlib.util
import json
import os
import tempfile
import unittest

ROOT = os.path.realpath(os.path.join(os.path.dirname(__file__), ".."))
spec = importlib.util.spec_from_file_location("patch", os.path.join(ROOT, "scripts", "live-code", "patch.py"))
patch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(patch)


def frontend_line(module, marker):
    return (f"    /tc/usr/bin/swift-frontend -frontend -c -filelist /b/{module}.list -primary-file /s/{marker}.swift "
            f"-module-name {module} -Onone -enable-testing -D {marker} -o /b/{marker}.o\n")


class CommandLookupTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.log = os.path.join(tmp.name, "xcodebuild.log")
        self.write([
            "builtin-SwiftDriver -- swiftc -module-name CmuxNextApp @/b/early.SwiftFileList\n",
            frontend_line("CmuxNextApp", "FIRST"),
            frontend_line("CmuxNextCore", "CORE"),
            "builtin-SwiftDriver -- swiftc -module-name CmuxNextApp @/b/CmuxNextApp.SwiftFileList\n",
            frontend_line("CmuxNextApp", "LAST"),
            "    /tc/usr/bin/swift-frontend -frontend -c 'unbalanced -module-name CmuxNextApp \n",
        ])

    def write(self, lines, mtime_ns=None):
        with open(self.log, "w") as f:
            f.writelines(lines)
        if mtime_ns:
            os.utime(self.log, ns=(mtime_ns, mtime_ns))

    def test_the_last_parsable_frontend_and_driver_lines_win(self):
        frontend, filelist = patch.scan_commands(self.log, "CmuxNextApp")
        self.assertEqual(frontend[0], "/tc/usr/bin/swift-frontend")
        self.assertIn("LAST", frontend)
        self.assertEqual(filelist, "/b/CmuxNextApp.SwiftFileList")
        self.assertIn("CORE", patch.scan_commands(self.log, "CmuxNextCore")[0])

    def test_a_module_with_no_driver_line_uses_its_frontend_filelist(self):
        self.assertEqual(patch.scan_commands(self.log, "CmuxNextCore")[1], "/b/CmuxNextCore.list")

    def test_the_cache_answers_until_the_log_changes(self):
        first = patch.module_commands(self.log, "CmuxNextApp")
        with open(patch.commands_cache(self.log)) as f:
            self.assertIn("CmuxNextApp", json.load(f)["modules"])
        original = patch.scan_commands
        patch.scan_commands = lambda *a: self.fail("read the log again while it had not changed")
        try:
            self.assertEqual(patch.module_commands(self.log, "CmuxNextApp"), first)
        finally:
            patch.scan_commands = original
        # A new build writes a new log: the cache is read again from it.
        self.write([frontend_line("CmuxNextApp", "REBUILT")], mtime_ns=os.stat(self.log).st_mtime_ns + 10**9)
        self.assertIn("REBUILT", patch.module_commands(self.log, "CmuxNextApp")[0])

    def test_an_unwritable_cache_still_answers(self):
        os.makedirs(patch.commands_cache(self.log))  # a folder where the cache file would go: the write fails
        self.assertIn("LAST", patch.module_commands(self.log, "CmuxNextApp")[0])

    def test_a_missing_log_answers_nothing(self):
        self.assertEqual(patch.module_commands(self.log + ".gone", "CmuxNextApp"), (None, None))


if __name__ == "__main__":
    unittest.main()
