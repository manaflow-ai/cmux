#!/usr/bin/env python3
"""TagTeardown finds the tag's processes by this bundle path (its executables, a host whose --owner names this bundle
id and a running daemon of this path or a host record of the tag, a holder of the tag's host roots, the direct children
of those, and the shells of its hosts and holders), never by name, bundle id alone, environment or launcher ancestry.
Another copy of the tag at another path, a tag that sanitizes to the same bundle id, a reused pid and this script's own
ancestors never match. Run: python3 -I scripts/cmux-next/tests/test_tag_teardown.py"""
import importlib.util, json, os, subprocess, sys, tempfile, time, unittest

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


START = "Sat Oct 24 10:00:00 2026"


def table(*rows):
    """{pid: (ppid, start, command)} from (pid, ppid, command) or (pid, ppid, command, start) rows."""
    return {row[0]: (row[1], row[3] if len(row) > 3 else START, row[2]) for row in rows}


class MatchTests(unittest.TestCase):
    def teardown(self):
        teardown = tag_teardown.TagTeardown.__new__(tag_teardown.TagTeardown)
        teardown.app = APP
        teardown.seen = {}
        teardown.state_roots = set()
        teardown.daemons_read = set()
        return teardown

    def matched(self, rows, teardown=None, exclude=(), bundle=BUNDLE, records=None):
        return [pid for pid, _ in (teardown or self.teardown()).matches(rows, bundle, exclude=exclude, records=records)]

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

    def test_a_reused_pid_with_the_same_command_is_another_process(self):
        # A shell of the tag exits; another login shell (the person's cmux, another agent's build) gets its pid.
        teardown = self.teardown()
        self.assertEqual(self.matched(table((11, 1, f"{APP}{TUI}"), (30, 11, HOLDER), (31, 30, "-zsh")), teardown),
                         [11, 30, 31])
        reused = table((31, 1, "-zsh", "Sat Oct 24 10:05:00 2026"))
        self.assertEqual(self.matched(reused, teardown), [])

    def test_an_exited_daemons_pid_is_no_anchor(self):
        # The daemon 11 was seen, then exited; a host naming @11 that was never seen and is in no record of the tag
        # (pid 11 may now be another bundle's daemon) is not the tag's.
        teardown = self.teardown()
        self.assertEqual(self.matched(table((11, 1, f"{APP}{TUI}")), teardown), [11])
        later = table((81, 1, f"cmux-tui __terminal-host --owner {BUNDLE}:sweep@11"))
        self.assertEqual(self.matched(later, teardown), [])

    def test_a_dead_daemons_hosts_and_holder_are_found_by_the_tags_host_roots(self):
        # A new process (tag_teardown.py <app>, or a daemon crash mid-session): the daemon that spawned the host and
        # the holder is gone, both run under launchd with no record of them in this process.
        rows = table((12, 1, f"{APP}{TUI}"),  # the daemon the app started since (same state root)
                     (20, 1, f"cmux-tui __terminal-host --bootstrap-stdio --owner {BUNDLE}:sweep@11"),
                     (21, 20, "-zsh"),
                     (30, 1, HOLDER), (31, 30, "-zsh"),
                     (40, 1, "cmux-holder --socket /tmp/cmux-hd-501/cd.sock"), (41, 40, "-zsh"),  # another root's
                     (50, 1, f"cmux-tui __terminal-host --owner com.cmuxterm.app.debug.other:other@11"))  # other id
        records = tag_teardown.Records(host_pids={20, 50}, holder_sockets={"/tmp/cmux-hd-501/ab.sock"})
        self.assertEqual(self.matched(rows, records=records), [12, 20, 21, 30, 31])
        self.assertEqual(self.matched(rows), [12])

    def test_the_host_roots_name_their_hosts_and_holder_socket(self):
        # unix terminal_host_root: <state root>/terminal-hosts-<token>; the holder's socket is fnv1a of that path.
        with tempfile.TemporaryDirectory() as state:
            host_root = os.path.join(state, "terminal-hosts-abc")
            os.makedirs(host_root)
            with open(os.path.join(host_root, "t1.json"), "w") as f:
                json.dump({"host_pid": 4242, "record_version": 4}, f)
            with open(os.path.join(host_root, "bad.json"), "w") as f:
                f.write("{")
            os.makedirs(os.path.join(state, "other"))
            records = tag_teardown.host_records([state], uid=501)
            expected = f"/tmp/cmux-hd-501/{tag_teardown.fnv1a(os.fsencode(host_root)):016x}.sock"
            self.assertEqual(records.host_pids, {4242})
            self.assertEqual(records.holder_sockets, {expected})

    def test_fnv1a_matches_the_daemons_hash(self):
        self.assertEqual(tag_teardown.fnv1a(b""), 0xcbf29ce484222325)
        self.assertEqual(tag_teardown.fnv1a(b"a"), 0xaf63dc4c8601ec8c)
        self.assertEqual(tag_teardown.holder_socket("/x", uid=7), f"/tmp/cmux-hd-7/{tag_teardown.fnv1a(b'/x'):016x}.sock")

    def test_the_state_root_is_read_once_per_daemon_and_kept_after_it_exits(self):
        teardown = self.teardown()
        reads = []
        def read(pid):
            reads.append(pid)
            return ([], {"CMUX_TUI_STATE_DIR": f"/Users/me/Library/Application Support/cmux/tags/sweep{pid}/tui"})
        rows = table((10, 1, f"{APP}/Contents/MacOS/cmux DEV"), (11, 1, f"{APP}{TUI}"), (70, 1, f"{OTHER}{TUI}"))
        teardown.learn_state_roots(rows, read)
        teardown.learn_state_roots(rows, read)
        self.assertEqual(reads, [11])
        teardown.learn_state_roots(table((12, 1, f"{APP}{TUI}")), read)
        self.assertEqual(teardown.state_roots, {"/Users/me/Library/Application Support/cmux/tags/sweep11/tui",
                                                "/Users/me/Library/Application Support/cmux/tags/sweep12/tui"})

    def test_procargs_reads_an_environment_value_with_spaces(self):
        child = subprocess.Popen([sys.executable, "-I", "-c", "import sys; print('ready', flush=True); sys.stdin.read()"],
                                 stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True,
                                 env={"CMUX_TUI_STATE_DIR": "/Users/me/Library/Application Support/cmux/tui"})
        try:
            self.assertEqual(child.stdout.readline().strip(), "ready")  # its exec is done
            found = tag_teardown.procargs(child.pid)
            self.assertEqual(found[1].get("CMUX_TUI_STATE_DIR"), "/Users/me/Library/Application Support/cmux/tui")
        finally:
            child.stdin.close()
            child.wait()

    def test_remember_arms_end_again(self):
        teardown = self.teardown()
        teardown.done = True
        teardown.processes = lambda: []
        teardown.remember()
        self.assertFalse(teardown.done)

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
