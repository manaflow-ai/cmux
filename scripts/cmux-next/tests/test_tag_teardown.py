#!/usr/bin/env python3
"""TagTeardown finds the tag's processes by this bundle path (its executables, a host whose --owner names this bundle
id and a daemon of this path, the direct children of those, and the shells of its hosts and holders), never by name,
bundle id alone, environment or launcher ancestry. Another copy of the tag at another path, a tag that sanitizes to
the same bundle id, and this script's own ancestors never match. Run: python3 -I scripts/cmux-next/tests/test_tag_teardown.py"""
import importlib.util, os, sys, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("tag_teardown", os.path.join(HERE, "..", "tag_teardown.py"))
tag_teardown = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tag_teardown)

APP = "/Users/me/Library/Developer/Xcode/DerivedData/cmux-sweep/Build/Products/Debug/cmux DEV sweep.app"
# The same tag built at another path (another worktree, a second fleet job dir, the other half of an A/B pair).
OTHER = "/Users/me/fleet/job-2/DerivedData/cmux-sweep/Build/Products/Debug/cmux DEV sweep.app"
BUNDLE = "com.cmuxterm.app.debug.sweep"
TUI = "/Contents/Resources/bin/cmux-tui --headless --session s --socket /tmp/s.sock"
HOLDER = "cmux-holder --socket /tmp/cmux-hd-501/ab.sock"


def table(*rows):
    return {pid: (ppid, command) for pid, ppid, command in rows}


class MatchTests(unittest.TestCase):
    def teardown(self):
        teardown = tag_teardown.TagTeardown.__new__(tag_teardown.TagTeardown)
        teardown.app = APP
        teardown.seen = {}
        return teardown

    def matched(self, rows, teardown=None, exclude=(), bundle=BUNDLE):
        return [pid for pid, _ in (teardown or self.teardown()).matches(rows, bundle, exclude=exclude)]

    def test_the_tags_processes_and_only_them(self):
        rows = table(
            (10, 1, f"{APP}/Contents/MacOS/cmux DEV"),  # the app
            (11, 1, f"{APP}{TUI}"),  # its daemon
            (20, 11, f"cmux-tui __terminal-host --bootstrap-stdio --owner {BUNDLE}:sweep@11"),  # a host (argv0, no path)
            (21, 20, "-zsh"),  # the host's shell
            (30, 11, HOLDER),  # the daemon's holder (no owner flag)
            (31, 30, "-zsh"),  # a holder shell
            (32, 31, "/bin/sleep 1000"),  # a shell's child: ends with its PTY, never matched here
            (50, 1, "cmux-tui __terminal-host --owner com.cmuxterm.app.debug.other:other@9"),
            (60, 1, "/usr/bin/vim sweep.txt"),  # a name that only looks like the tag
        )
        self.assertEqual(self.matched(rows), [10, 11, 20, 21, 30, 31])

    def test_the_same_bundle_id_at_another_path_is_not_the_tags(self):
        # Another copy of this tag at another path: its daemon, host, holder, shells and an orphaned host of it.
        rows = table(
            (11, 1, f"{APP}{TUI}"),
            (70, 1, f"{OTHER}{TUI}"),
            (71, 70, f"cmux-tui __terminal-host --bootstrap-stdio --owner {BUNDLE}:sweep@70"),
            (72, 71, "-zsh"),
            (73, 70, "cmux-holder --socket /tmp/cmux-hd-501/cd.sock"),
            (74, 73, "-zsh"),
            (75, 1, f"cmux-tui __terminal-host --owner {BUNDLE}:sweep@70"),
        )
        self.assertEqual(self.matched(rows), [11])

    def test_a_tag_that_sanitizes_to_the_same_bundle_id_is_not_the_tags(self):
        # reload.sh gives split-spring and split.spring one id (com.cmuxterm.app.debug.split.spring): the other tag's
        # app at its own path, with its own daemon pid, is not this one's.
        bundle = "com.cmuxterm.app.debug.split.spring"
        other = "/Users/me/DerivedData/cmux-split.spring/Build/Products/Debug/cmux DEV split.spring.app"
        rows = table((11, 1, f"{APP}{TUI}"), (70, 1, f"{other}{TUI}"),
                     (71, 70, f"cmux-tui __terminal-host --owner {bundle}:split.spring@70"), (72, 71, "-zsh"))
        self.assertEqual(self.matched(rows, bundle=bundle), [11])

    def test_a_host_whose_owner_names_another_daemon_pid_is_not_the_tags(self):
        rows = table((11, 1, f"{APP}{TUI}"),
                     (80, 1, f"cmux-tui __terminal-host --owner {BUNDLE}:sweep@4242"))
        self.assertEqual(self.matched(rows), [11])

    def test_a_host_and_holder_stay_found_after_their_daemon_exits(self):
        teardown = self.teardown()
        host = f"cmux-tui __terminal-host --owner {BUNDLE}:sweep@11"
        before = table((11, 1, f"{APP}{TUI}"), (20, 11, host), (30, 11, HOLDER), (31, 30, "-zsh"))
        self.assertEqual(self.matched(before, teardown), [11, 20, 30, 31])
        # The shutdown ended the daemon: its host and holder now run under launchd, its pid is gone.
        after = table((20, 1, host), (30, 1, HOLDER), (31, 30, "-zsh"), (33, 30, "-zsh"))
        self.assertEqual(self.matched(after, teardown), [20, 30, 31, 33])
        # A pid reused by another program is not the old process.
        reused = table((30, 1, "/usr/bin/python3 other.py"))
        self.assertEqual(self.matched(reused, teardown), [])

    def test_this_script_and_its_ancestors_never_match(self):
        # The script runs in a shell of the tag's own terminal: that shell, its holder and the daemon stay.
        rows = table((10, 1, f"{APP}/Contents/MacOS/cmux DEV"), (11, 1, f"{APP}{TUI}"), (30, 11, HOLDER),
                     (31, 30, "-zsh"), (34, 30, "-zsh"), (90, 31, "/usr/bin/python3 every-action-sweep.py"))
        teardown = self.teardown()
        lineage = teardown._lineage(rows, 90)
        self.assertEqual(lineage, {90, 31, 30, 11})
        self.assertEqual(self.matched(rows, teardown, exclude=lineage), [10, 34])

    def test_the_default_exclusion_is_this_process_and_its_ancestors(self):
        me, parent = os.getpid(), os.getppid()
        rows = table((11, 1, f"{APP}{TUI}"), (parent, 11, "-zsh"), (me, parent, "/usr/bin/python3 x.py"))
        teardown = self.teardown()
        self.assertEqual([pid for pid, _ in teardown.matches(rows, BUNDLE)], [])

    def test_a_shell_that_only_inherited_the_bundle_id_is_not_the_tags(self):
        rows = table((70, 1, "/bin/bash script.sh"), (71, 70, "-zsh"))
        self.assertEqual(self.matched(rows), [])

    def test_the_log_shows_a_command_outside_the_bundle_whole(self):
        teardown = self.teardown()
        self.assertEqual(teardown.shown(f"{APP}/Contents/MacOS/cmux DEV"), "/Contents/MacOS/cmux DEV")
        self.assertEqual(teardown.shown(HOLDER), HOLDER)


if __name__ == "__main__":
    unittest.main()
