"""The restore journey's update to another build (rj_update.py): build B is installed at the running
copy's path with the copy's identity, so the state build A saved under its names is what B restores.

  python3 -I scripts/cmux-next/tests/test_rj_update.py
"""
import os, plistlib, sys, tempfile, unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import build_names  # noqa: E402
import rj_update  # noqa: E402

A_COMMIT = "a" * 40
B_COMMIT = "b" * 40
SLOT_ID = "com.cmuxterm.app.debug.rjtag.capslot2"


def make_app(path, info, files=None):
    os.makedirs(os.path.join(path, "Contents", "MacOS"))
    with open(os.path.join(path, "Contents", "Info.plist"), "wb") as f:
        plistlib.dump(info, f)
    for name, text in (files or {}).items():
        with open(os.path.join(path, "Contents", "MacOS", name), "w") as f:
            f.write(text)
    return path


def read_info(app):
    with open(os.path.join(app, "Contents", "Info.plist"), "rb") as f:
        return plistlib.load(f)


class Install(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()
        stage = os.path.join(self.root, "stage")
        # Build A and build B as restore-journey-slot.sh stages them: each its own folder, the commit beside it.
        self.a = make_app(os.path.join(stage, "A", "cmux DEV rjtag.app"),
                          {"CFBundleIdentifier": "com.cmuxterm.app.debug.rjtag", "CFBundleShortVersionString": "0.1.0",
                           "CFBundleVersion": "100", "LSEnvironment": {"CMUX_TAG": "rjtag"}},
                          {"cmux": "build A"})
        self.b = make_app(os.path.join(stage, "B", "cmux DEV rjtag.app"),
                          {"CFBundleIdentifier": "com.cmuxterm.app.debug.rjtag", "CFBundleShortVersionString": "0.1.0",
                           "CFBundleVersion": "101", "CMUXCommit": B_COMMIT, "LSEnvironment": {"CMUX_TAG": "rjtag", "B_ONLY": "1"}},
                          {"cmux": "build B"})
        for app, commit in ((self.a, A_COMMIT), (self.b, B_COMMIT)):
            with open(os.path.join(os.path.dirname(app), "capture-commit"), "w") as f:
                f.write(commit + "\n")
        # The slot's copy of A, as capture-host launch leaves it: its own id and the lease folders in LSEnvironment.
        self.copy = make_app(os.path.join(self.root, "lease", "app", "cmux DEV rjtag.app"),
                             {"CFBundleIdentifier": SLOT_ID, "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "100",
                              "LSEnvironment": {"CMUX_TAG": "rjtag", "CMUX_NEXT_CONFIG_FILE": "/lease/home/.config/cmux/cmux-next.json",
                                                "CFFIXED_USER_HOME": "/lease/home"}},
                             {"cmux": "build A"})
        self.signed = os.path.join(self.root, "signed.log")
        self.codesign = os.path.join(self.root, "codesign")
        with open(self.codesign, "w") as f:
            f.write(f"#!/bin/sh\nprintf '%s\\n' \"$*\" >> '{self.signed}'\n")
        os.chmod(self.codesign, 0o755)

    def test_b_takes_the_copys_place_and_identity(self):
        before = build_names.of_app(self.copy)
        report = rj_update.install(self.copy, self.b, self.a, codesign=self.codesign)
        with open(os.path.join(self.copy, "Contents", "MacOS", "cmux")) as f:
            self.assertEqual(f.read(), "build B")
        info = read_info(self.copy)
        self.assertEqual(info["CFBundleIdentifier"], SLOT_ID)
        self.assertEqual(info["CFBundleVersion"], "101")
        env = info["LSEnvironment"]
        self.assertEqual(env["CFFIXED_USER_HOME"], "/lease/home")  # the lease's environment stays
        self.assertEqual(env["CMUX_NEXT_CONFIG_FILE"], "/lease/home/.config/cmux/cmux-next.json")
        self.assertEqual(env["B_ONLY"], "1")  # B's own environment comes with it
        self.assertEqual(env["CMUX_TAG"], "rjtag")
        self.assertEqual(build_names.of_app(self.copy), before)  # A's socket, session and acpmux home
        self.assertEqual(report["names_before"], report["names_after"])
        self.assertEqual((report["from_commit"], report["to_commit"]), (A_COMMIT, B_COMMIT))
        self.assertEqual(report["to_version"], ["0.1.0", "101"])
        self.assertEqual(report["notes"], [])
        # Signed once, staged beside the copy; nothing left there but the copy.
        with open(self.signed) as f:
            self.assertIn(self.copy + ".rj-update", f.read())
        self.assertEqual(sorted(os.listdir(os.path.dirname(self.copy))), ["cmux DEV rjtag.app"])

    def test_a_b_that_ships_another_tag_keeps_the_copys_tag(self):
        info = read_info(self.b)
        info["LSEnvironment"]["CMUX_TAG"] = "other"
        with open(os.path.join(self.b, "Contents", "Info.plist"), "wb") as f:
            plistlib.dump(info, f)
        before = build_names.of_app(self.copy)
        report = rj_update.install(self.copy, self.b, self.a, codesign=self.codesign)
        self.assertEqual(read_info(self.copy)["LSEnvironment"]["CMUX_TAG"], "rjtag")
        self.assertEqual(build_names.of_app(self.copy), before)
        self.assertTrue(any("tag 'other' -> 'rjtag'" in n for n in report["notes"]), report["notes"])

    def test_a_failed_signature_leaves_the_copy_as_it_was(self):
        with open(self.codesign, "w") as f:
            f.write("#!/bin/sh\necho 'detritus not allowed' >&2\nexit 1\n")
        with self.assertRaisesRegex(RuntimeError, "detritus"):
            rj_update.install(self.copy, self.b, self.a, codesign=self.codesign)
        with open(os.path.join(self.copy, "Contents", "MacOS", "cmux")) as f:
            self.assertEqual(f.read(), "build A")
        self.assertEqual(read_info(self.copy)["CFBundleIdentifier"], SLOT_ID)
        self.assertEqual(sorted(os.listdir(os.path.dirname(self.copy))), ["cmux DEV rjtag.app"])

    def test_an_interrupt_between_the_renames_puts_the_copy_back(self):
        # The journey's --max-seconds and signal handlers raise SystemExit; it may land between the two renames.
        real, calls = os.rename, []

        def rename(src, dst):
            calls.append((src, dst))
            if len(calls) == 2:
                raise SystemExit("restore-journey: stopped")
            return real(src, dst)

        rj_update.os.rename = rename
        try:
            with self.assertRaises(SystemExit):
                rj_update.install(self.copy, self.b, self.a, codesign=self.codesign)
        finally:
            rj_update.os.rename = real
        with open(os.path.join(self.copy, "Contents", "MacOS", "cmux")) as f:
            self.assertEqual(f.read(), "build A")
        self.assertEqual(sorted(os.listdir(os.path.dirname(self.copy))), ["cmux DEV rjtag.app"])

    def test_a_copy_gone_after_the_update_comes_back_as_b_with_the_same_identity(self):
        info = read_info(self.b)
        info["LSEnvironment"]["CMUX_TAG"] = "other"  # names would change if the plain B were cloned
        with open(os.path.join(self.b, "Contents", "Info.plist"), "wb") as f:
            plistlib.dump(info, f)
        report = rj_update.install(self.copy, self.b, self.a, codesign=self.codesign)
        names = build_names.of_app(self.copy)
        import shutil
        shutil.rmtree(self.copy)
        self.assertEqual(rj_update.reinstall(self.copy, self.b, self.a, report["identity"], codesign=self.codesign), names)
        again = read_info(self.copy)
        self.assertEqual(again["CFBundleIdentifier"], SLOT_ID)
        self.assertEqual(again["LSEnvironment"]["CFFIXED_USER_HOME"], "/lease/home")
        self.assertEqual(again["LSEnvironment"]["CMUX_TAG"], "rjtag")
        with open(os.path.join(self.copy, "Contents", "MacOS", "cmux")) as f:
            self.assertEqual(f.read(), "build B")

    def test_no_build_b_is_refused(self):
        with self.assertRaisesRegex(RuntimeError, "no build to update to"):
            rj_update.install(self.copy, os.path.join(self.root, "missing.app"), self.a, codesign=self.codesign)


class Commit(unittest.TestCase):
    def test_different_builds_needs_two_known_distinct_commits(self):
        self.assertTrue(rj_update.different_builds(A_COMMIT, B_COMMIT))
        self.assertFalse(rj_update.different_builds(A_COMMIT, A_COMMIT[:9]))  # a short and a full hash of one commit
        self.assertFalse(rj_update.different_builds(None, B_COMMIT))
        self.assertFalse(rj_update.different_builds(A_COMMIT, ""))

    def test_info_plist_first_then_the_staged_marker(self):
        root = tempfile.mkdtemp()
        app = make_app(os.path.join(root, "x", "cmux DEV t.app"), {"CFBundleIdentifier": "com.cmuxterm.app.debug.t"})
        self.assertIsNone(rj_update.commit_of(app))
        with open(os.path.join(root, "x", "capture-commit"), "w") as f:
            f.write(A_COMMIT + "\n")
        self.assertEqual(rj_update.commit_of(app), A_COMMIT)
        info = read_info(app)
        info["CMUXCommit"] = "$(CMUX_COMMIT)"  # an unexpanded build setting is no commit
        with open(os.path.join(app, "Contents", "Info.plist"), "wb") as f:
            plistlib.dump(info, f)
        self.assertEqual(rj_update.commit_of(app), A_COMMIT)
        info["CMUXCommit"] = B_COMMIT
        with open(os.path.join(app, "Contents", "Info.plist"), "wb") as f:
            plistlib.dump(info, f)
        self.assertEqual(rj_update.commit_of(app), B_COMMIT)


if __name__ == "__main__":
    unittest.main()
