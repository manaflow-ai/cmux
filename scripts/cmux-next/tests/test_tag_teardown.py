#!/usr/bin/env python3
"""TagTeardown finds the tag's processes by the tag (bundle path, a host's --owner, CMUX_BUNDLE_ID in a shell's
environment and that shell's holder), never by name or by ancestry: terminal hosts and holders run from a
content-addressed copy outside the bundle, and the daemons detach. Run: python3 -I scripts/cmux-next/tests/test_tag_teardown.py"""
import importlib.util, os, sys, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("tag_teardown", os.path.join(HERE, "..", "tag_teardown.py"))
tag_teardown = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tag_teardown)

APP = "/Users/me/Library/Developer/Xcode/DerivedData/cmux-sweep/Build/Products/Debug/cmux DEV sweep.app"
BUNDLE = "com.cmuxterm.app.debug.sweep"
COPY = tag_teardown.HOST_EXE_ROOT + "ab12/"


class MatchTests(unittest.TestCase):
    def matched(self, rows):
        teardown = tag_teardown.TagTeardown.__new__(tag_teardown.TagTeardown)
        teardown.app = APP
        return [pid for pid, _ in teardown.matches(rows, BUNDLE)]

    def test_the_tags_processes_and_only_them(self):
        rows = [
            (10, 1, f"{APP}/Contents/MacOS/cmux DEV", f"{APP}/Contents/MacOS/cmux DEV"),  # the app
            (11, 1, f"{APP}/Contents/Resources/bin/cmux-tui --headless --session s", "..."),  # its daemon
            (20, 1, f"{COPY}cmux-tui-host __terminal-host --bootstrap-stdio --owner {BUNDLE}:sweep@11", "..."),  # a host
            (30, 1, f"{COPY}cmux-holder", f"{COPY}cmux-holder HOME=/Users/me"),  # a holder (no owner flag)
            (31, 30, "-zsh", f"-zsh CMUX_BUNDLE_ID={BUNDLE} CMUX_TAG=sweep"),  # its shell
            (40, 1, f"{COPY}cmux-holder", f"{COPY}cmux-holder"),  # another tag's holder
            (41, 40, "-zsh", "-zsh CMUX_BUNDLE_ID=com.cmuxterm.app.debug.other"),
            (50, 1, f"{COPY}cmux-tui-host __terminal-host --owner com.cmuxterm.app.debug.other:other@9", "..."),
            (60, 1, "/usr/bin/vim sweep.txt", "/usr/bin/vim sweep.txt"),  # a name that only looks like the tag
        ]
        self.assertEqual(self.matched(rows), [10, 11, 20, 30, 31])

    def test_a_shells_parent_outside_the_host_copies_is_not_taken(self):
        # A person's shell inside cmux that runs a script: its parent is not a holder copy.
        rows = [(70, 1, "/bin/bash script.sh", "/bin/bash script.sh"),
                (71, 70, "-zsh", f"-zsh CMUX_BUNDLE_ID={BUNDLE}")]
        self.assertEqual(self.matched(rows), [71])


if __name__ == "__main__":
    unittest.main()
