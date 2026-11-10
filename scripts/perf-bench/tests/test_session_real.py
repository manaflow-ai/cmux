#!/usr/bin/env python3
"""session_real.py never leaves a tag's state wrong, removes only a folder that it made itself in this run, and gives
a non-zero exit when its result has failures. Each test fails on the file before its fix (7aba9c3c61b4).
Run: python3 -I scripts/perf-bench/tests/test_session_real.py
The same tests on another copy of the tool: SESSION_REAL_FILE=<path> python3 -I scripts/perf-bench/tests/test_session_real.py"""
import argparse, importlib.util, json, os, shutil, signal, sys, tempfile, types, unittest, warnings

warnings.simplefilter("ignore", ResourceWarning)

HERE = os.path.dirname(os.path.abspath(__file__))
FILE = os.environ.get("SESSION_REAL_FILE") or os.path.join(HERE, "..", "session_real.py")
spec = importlib.util.spec_from_file_location("session_real", FILE)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

START = "Tue Nov 10 10:00:00 2026"
TAG = "chrome-parity-v2"
APP = "/Users/me/perf-lead/apps/cmux DEV chrome-parity-v2.app"
ID = "com.cmuxterm.app.debug.chrome-parity-v2"


def table(*rows):
    """{pid: (ppid, start, command)} from (pid, ppid, command) or (pid, ppid, command, start) rows."""
    return {row[0]: (row[1], row[3] if len(row) > 3 else START, row[2]) for row in rows}


def write(path, text="x"):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(text)


class Home(unittest.TestCase):
    """A temp account home with a saved session of TAG; no process of the tag runs; the copy is a plain copy."""

    def setUp(self):
        self.home = tempfile.mkdtemp(prefix="session-real-test-")
        self.addCleanup(shutil.rmtree, self.home)
        self.saved = os.path.join(self.home, "saved")
        write(os.path.join(self.saved, "state", "tui", "registry.json"), "saved")
        write(os.path.join(self.saved, "session-real.json"), json.dumps({"tag": TAG, "asked": {"workspaces": 3}}))
        self.target = os.path.join(m.state_root(self.home), TAG)
        self.kept = self.target + ".before-session-real"
        self.patch("running_with_tag", lambda tag, app=None: [])
        self.patch("copy_tree", lambda source, target: shutil.copytree(source, target))
        self.patch("host_facts", lambda: {})
        self.patch("ptys_in_use", lambda: 0)

    def patch(self, name, value):
        before = getattr(m, name, None)
        setattr(m, name, value)
        self.addCleanup(setattr, m, name, before)

    def args(self, **more):
        return argparse.Namespace(saved=self.saved, tag=TAG, home=self.home, **more)

    def beside(self):
        return sorted(os.listdir(os.path.dirname(self.target)))


class RemoveOnlyOwnFolders(Home):
    def test_a_folder_of_this_run_is_removed_and_one_made_in_its_place_is_not(self):
        folder = m.OwnFolder(os.path.join(self.home, "work"), "test")
        self.assertTrue(folder.is_mine())
        # Another process replaces the folder (same name, its own files, and even a copy of the mark's name).
        mark = open(os.path.join(folder.path, m.OWN_MARK), encoding="utf-8").read()
        os.rename(folder.path, folder.path + ".moved")
        write(os.path.join(folder.path, "theirs.txt"))
        write(os.path.join(folder.path, m.OWN_MARK), json.dumps({"token": "another run", "inode": 1}))
        self.assertFalse(folder.remove())
        self.assertTrue(os.path.exists(os.path.join(folder.path, "theirs.txt")))
        # The mark copied into a folder with another inode is not proof either.
        write(os.path.join(folder.path, m.OWN_MARK), mark)
        self.assertFalse(folder.remove())
        self.assertTrue(os.path.exists(os.path.join(folder.path, "theirs.txt")))

    def test_a_folder_that_exists_is_never_taken_over(self):
        write(os.path.join(self.home, "there", "theirs.txt"))
        with self.assertRaises(SystemExit):
            m.OwnFolder(os.path.join(self.home, "there"), "test")
        self.assertTrue(os.path.exists(os.path.join(self.home, "there", "theirs.txt")))

    def test_a_failed_install_never_removes_a_folder_another_process_made_at_the_tags_place(self):
        def copy_fails(source, target):
            write(os.path.join(self.target, "theirs.txt"))  # another process makes the tag's state in this moment
            raise OSError("disk full")
        self.patch("copy_tree", copy_fails)
        with self.assertRaises(OSError):
            m.install(self.args())
        self.assertTrue(os.path.exists(os.path.join(self.target, "theirs.txt")))
        self.assertEqual(self.beside(), [TAG])  # and the stage of this run is gone

    def test_the_tags_state_does_not_change_while_the_copy_runs(self):
        """A SIGTERM or a kill in the copy (the long part of an install) leaves the tag as it was: the old state is
        still in its place, not aside."""
        write(os.path.join(self.target, "old.txt"), "old")
        seen = {}

        def copy(source, target):
            seen["old_in_place"] = os.path.exists(os.path.join(self.target, "old.txt"))
            seen["aside"] = os.path.exists(self.kept)
            raise SystemExit(128 + signal.SIGTERM)
        self.patch("copy_tree", copy)
        with self.assertRaises(SystemExit):
            m.install(self.args())
        self.assertEqual(seen, {"old_in_place": True, "aside": False})
        self.assertEqual(self.beside(), [TAG])
        self.assertEqual(open(os.path.join(self.target, "old.txt")).read(), "old")

    def test_install_refuses_when_a_kept_state_is_there_and_changes_nothing(self):
        write(os.path.join(self.target, "new.txt"), "new")
        write(os.path.join(self.kept, "old.txt"), "old")
        with self.assertRaises(SystemExit):
            m.install(self.args())
        self.assertEqual(self.beside(), [TAG, TAG + ".before-session-real"])  # no dated rename, no stage
        self.assertTrue(os.path.exists(os.path.join(self.target, "new.txt")))
        self.assertTrue(os.path.exists(os.path.join(self.kept, "old.txt")))

    def test_install_then_uninstall_in_one_run_puts_the_old_state_back_and_leaves_nothing(self):
        write(os.path.join(self.target, "old.txt"), "old")
        m.install(self.args())
        self.assertEqual(open(os.path.join(self.target, "tui", "registry.json")).read(), "saved")
        self.assertTrue(os.path.exists(os.path.join(self.kept, "old.txt")))
        m.uninstall(self.args())
        self.assertEqual(self.beside(), [TAG])
        self.assertEqual(open(os.path.join(self.target, "old.txt")).read(), "old")

    def test_uninstall_does_not_delete_an_installed_copy_this_run_did_not_make(self):
        """An install of an earlier run or of another owner (also one of the tool before this fix: a mark with only
        `from` and `at`) is moved out of the tag's place, not deleted; the old state comes back."""
        write(os.path.join(self.target, "tui", "registry.json"), "theirs")
        write(os.path.join(self.target, m.INSTALL_MARK), json.dumps({"from": self.saved, "at": "2026-11-10T10:00:00Z"}))
        write(os.path.join(self.kept, "old.txt"), "old")
        m.uninstall(self.args())
        self.assertEqual(open(os.path.join(self.target, "old.txt")).read(), "old")
        away = [name for name in self.beside() if name.startswith(TAG + ".session-real-removed-")]
        self.assertEqual(len(away), 1, self.beside())
        self.assertEqual(open(os.path.join(os.path.dirname(self.target), away[0], "tui", "registry.json")).read(), "theirs")

    def test_uninstall_puts_the_old_state_back_when_a_killed_run_left_it_aside(self):
        write(os.path.join(self.kept, "old.txt"), "old")
        m.uninstall(self.args())
        self.assertEqual(self.beside(), [TAG])
        self.assertEqual(open(os.path.join(self.target, "old.txt")).read(), "old")


class LaunchEnd(Home):
    """`launch --saved` takes its installed session away also when the quit of the app fails."""

    def launch(self, stop, steps="", install=None, made_in_this_run=None):
        calls = []

        class Process:
            pid = 4242

            def poll(self):
                return 0

        class BenchApp:
            def __init__(self, app, out, fresh_state, socket_only, env=None):
                self.process, self.socket, self.ready_seconds, self.launched_at = None, "/tmp/none.sock", 1.0, None
                calls.append(("app environment", env))

            def launch(self, timeout):
                import time
                self.process, self.launched_at = Process(), time.time()

            def stop(self, quit_timeout):
                calls.append("stop")
                stop()

        class Teardown:
            def __init__(self, app):
                pass

            def end(self):
                calls.append("second teardown")

            _table = staticmethod(lambda: {})
            _lineage = staticmethod(lambda rows, pid: set())

        fake = types.ModuleType("bench_launch")
        fake.BenchApp = BenchApp
        sys.modules["bench_launch"] = fake
        self.addCleanup(sys.modules.pop, "bench_launch", None)
        self.patch("teardown_module", lambda: types.SimpleNamespace(TagTeardown=Teardown))
        self.patch("state_root", lambda home=None: os.path.join(self.home, "Library/Application Support/cmux-next/tags"))
        self.patch("app_counts", lambda sock: {"loaded": True, "workspaces": 3})
        self.patch("app_rpc", lambda *a, **k: {})
        self.patch("install", lambda a: (calls.append("install"), install and install()))
        if made_in_this_run is not None:
            self.patch("made_in_this_run", made_in_this_run)
        self.patch("uninstall", lambda a: calls.append("uninstall"))
        out = os.path.join(self.home, "out")
        args = argparse.Namespace(app=APP, out=out, socket_only=True, saved=self.saved, timeout=5, quit_timeout=1,
                                  restore_timeout=0, steps=steps, keep_installed=False)
        before = {number: signal.getsignal(number) for number in (signal.SIGTERM, signal.SIGHUP)}
        try:
            with self.assertRaises(SystemExit) as raised:
                m.launch(args)
        finally:
            for number, handler in before.items():
                signal.signal(number, handler)
        with open(os.path.join(out, "launch.json"), encoding="utf-8") as handle:
            return calls, raised.exception, json.load(handle)

    def test_an_exception_from_the_quit_does_not_skip_the_uninstall(self):
        def stop():
            raise RuntimeError("the teardown failed")
        calls, error, result = self.launch(stop)
        self.assertEqual(calls, [("app environment", {"CMUX_MOCK_KEYCHAIN": "1"}),  # no keychain dialog over the window
                                 "install", "stop", "second teardown", "uninstall"])
        self.assertIn("the teardown failed", str(error))
        self.assertTrue(any("the quit of the app" in line for line in result["failures"]))

    def test_a_signal_exit_in_the_quit_does_not_skip_the_uninstall(self):
        def stop():
            raise SystemExit(128 + signal.SIGTERM)
        calls, _, _ = self.launch(stop)
        self.assertEqual(calls[-1], "uninstall")

    def test_a_signal_at_the_end_of_the_install_does_not_skip_the_uninstall(self):
        """SIGTERM is held for the two renames of `install` and comes right after them: `install` does not return,
        but the installed copy has the mark of this run, so the end of `launch` takes it away."""
        def install():
            raise SystemExit(128 + signal.SIGTERM)
        calls, error, _ = self.launch(lambda: None, install=install, made_in_this_run=lambda folder: True)
        self.assertEqual(calls[-1], "uninstall")
        self.assertEqual(error.code, 128 + signal.SIGTERM)
        calls, _, _ = self.launch(lambda: None, install=install, made_in_this_run=lambda folder: False)
        self.assertNotIn("uninstall", calls)  # nothing of this run is installed: nothing is taken away

    def test_a_step_that_is_in_the_list_two_times_keeps_both_results(self):
        steps = {}
        for step in ("counts", "counts", "map:--runs 2", "counts"):
            steps[m.step_key(steps, step)] = True
        self.assertEqual(list(steps), ["counts", "counts#2", "map:--runs 2", "counts#3"])


class ExitCodes(unittest.TestCase):
    def row(self, name, runs=20, errors=0, timed=None, first_error=None):
        return {"row": name, "runs": runs, "errors": errors, "first_error": first_error,
                "commit_ms": {"n": runs - errors if timed is None else timed}}

    def test_faults_end_a_command_with_exit_3_and_no_faults_do_not(self):
        m.end_with("map", [])
        with self.assertRaises(SystemExit) as raised:
            m.end_with("map", ["row split: failed"])
        self.assertEqual(raised.exception.code, 3)

    def test_a_good_map_has_no_faults(self):
        asked = ["tab_switch", "split"]
        self.assertEqual(m.map_faults(asked, [self.row("tab_switch"), self.row("split")], 20, [], [], []), [])

    def test_a_failed_a_skipped_a_short_and_an_untimed_row_are_faults(self):
        asked = ["workspace_switch_warm", "tab_switch", "new_tab", "split", "workspace_switch_cold"]
        rows = [self.row("workspace_switch_warm", errors=2, first_error="timeout"), self.row("tab_switch", timed=5),
                self.row("workspace_switch_cold", runs=7)]
        faults = m.map_faults(asked, rows, 20, [("new_tab", "RuntimeError: no pane")], ["split"], [{"action": "closeTab", "error": "x"}])
        text = "\n".join(faults)
        for part in ("workspace_switch_warm: 2 of 20 runs failed", "tab_switch: 5 of 20 good runs have a commit time",
                     "new_tab: failed", "split: not run", "workspace_switch_cold: 7 runs, 20 were asked for", "1 set-up or clean-up"):
            self.assertIn(part, text)
        self.assertEqual(len(faults), 6, faults)

    def test_an_agent_start_that_is_not_complete_is_a_fault(self):
        self.assertEqual(m.agents_faults(170, 170, 170, 0, []), [])
        self.assertEqual(len(m.agents_faults(170, 170, 170, 0, [{"terminal": "real-0003", "error": "no pty"}])), 1)
        self.assertEqual(len(m.agents_faults(170, 170, 170, 4, [])), 1)
        self.assertEqual(len(m.agents_faults(170, 166, 170, 0, [])), 1)
        self.assertEqual(len(m.agents_faults(170, 170, 113, 0, [])), 1)

    def test_a_client_count_that_is_not_the_one_asked_for_is_a_fault(self):
        self.assertEqual(m.clients_faults(13, 13, 12, 10, []), [])
        self.assertEqual(len(m.clients_faults(13, 11, 12, 9, [])), 1)
        self.assertEqual(len(m.clients_faults(0, 5, 12, 11, [])), 1)
        self.assertEqual(len(m.clients_faults(13, 13, 12, 10, [(4, 31.5, 9000)])), 1)

    def test_a_park_count_that_is_not_the_one_asked_for_is_a_fault(self):
        self.assertEqual(m.park_faults(598, 598, 598, 598), [])
        self.assertTrue(m.park_faults(598, 590, 598, 590))


class Counts(unittest.TestCase):
    def test_the_steady_clients_are_the_named_and_the_old_ones_never_the_asking_one(self):
        listed = [{"client": 1, "name": "cmux-next", "connected_seconds": 300},
                  {"client": 2, "name": "cmux-next-terminal", "connected_seconds": 300},
                  {"client": 3, "name": None, "connected_seconds": 120},            # an unnamed connection of the app
                  {"client": 4, "name": None, "connected_seconds": 0.3},            # a hook call of an agent
                  {"client": 5, "name": "", "connected_seconds": 2.0},              # one more
                  {"client": 6, "name": "session-real-client-1", "connected_seconds": 0.1},
                  {"client": 7, "name": "session-real", "connected_seconds": 0.0, "self": True}]
        self.assertEqual([client["client"] for client in m.steady_clients(listed)], [1, 2, 3, 6])

    def test_the_cold_switch_shows_each_workspace_one_time(self):
        real = [f"real-{n:04d}" for n in range(826)]
        targets = m.cold_targets(real, 20)
        self.assertEqual(len(set(targets)), 20)
        self.assertNotIn(real[0], targets)
        small = [f"real-{n:04d}" for n in range(8)]
        for runs in (3, 6, 7, 20):
            targets = m.cold_targets(small, runs)
            self.assertEqual(len(targets), len(set(targets)), (runs, targets))
            self.assertNotIn(small[0], targets)
            self.assertEqual(len(targets), min(runs, 7), (runs, targets))

    def test_the_agent_programs_are_the_ones_of_this_daemons_terminals_only(self):
        zsh = "/bin/zsh -f /kit/session_real_agent.zsh waiting "
        rows = table((10, 1, zsh + "real-0003"), (9, 1, "-/bin/zsh"), (11, 9, zsh + "real-0008"), (12, 1, zsh + "real-0003"),   # 12: another tag's
                     (13, 1, "/bin/zsh -l"), (14, 1, zsh + "real-0012"), (15, 1, zsh + "real-0021"))
        tabs = [(3, {"surface": 30}), (8, {"surface": 80}), (12, {"surface": 120}), (20, {"surface": 200}), (21, {"surface": 210})]

        class Daemon:
            def call(self, cmd, **params):
                assert cmd == "terminal-resources" and params["surfaces"] == [30, 80, 120, 200, 210]
                return {"ok": True, "data": {"terminals": [
                    {"surface": 30, "pid": 10, "processes": [{"pid": 10}]},
                    {"surface": 80, "pid": 9, "processes": [{"pid": 9}, {"pid": 11}]},   # the program is below the shell
                    {"surface": 120, "pid": 13, "processes": [{"pid": 13}]},              # a shell with no program
                    {"surface": 210, "pid": 10, "processes": []}], "missing": [200]}}    # another terminal's program

        self.assertEqual(m.agent_programs(Daemon(), tabs, rows), {"real-0003": 10, "real-0008": 11})

        class Failing:
            def call(self, cmd, **params):
                return {"ok": False, "error": "bad request: no"}

        with self.assertRaises(SystemExit) as raised:   # an error is never "0 programs" and never "not judged"
            m.agent_programs(Failing(), tabs, rows)
        self.assertNotIn(raised.exception.code, (0, None))
        self.assertTrue(m.has_terminal_resources({"capabilities": ["clear-history-v1", "terminal-resources-v1"]}))
        self.assertFalse(m.has_terminal_resources({"capabilities": ["clear-history-v1"]}))
        self.assertFalse(m.has_terminal_resources({}))
        # A daemon without the command: the count is not judged, the other faults stay.
        self.assertEqual(m.agents_faults(170, None, 170, 0, []), [])
        self.assertEqual(len(m.agents_faults(170, None, 170, 3, [])), 1)

    def test_the_socket_fallback_counts_only_programs_that_name_this_daemons_socket(self):
        zsh = "/bin/zsh /kit/session_real_agent.zsh waiting "
        rows = table((10, 1, zsh + "real-0003"), (11, 1, zsh + "real-0008"), (12, 1, zsh + "real-0003"),
                     (13, 1, "/bin/zsh -l"), (14, 1, zsh + "real-0012"))
        env = {10: "/tmp/mine.sock", 11: "/tmp/mine.sock", 12: "/tmp/other-tag.sock", 13: "/tmp/mine.sock"}
        read = lambda pid: ([], {"CMUX_TUI_SOCKET": env[pid]}) if pid in env else None
        self.assertEqual(m.agent_programs_by_socket("/tmp/mine.sock", rows, read), {"real-0003": 10, "real-0008": 11})

    def test_a_tags_processes_are_found_by_whole_words_and_also_after_the_daemon(self):
        rows = table(
            (1, 0, "/sbin/launchd"),
            (20, 1, "/Users/me/x/cmux DEV Chrome Parity v2.app/Contents/MacOS/cmux DEV"),       # the bundle name is not the slug
            (21, 1, f"/Users/me/Library/Application Support/cmux-next/terminal-host/abc/cmux-tui __terminal-host --owner {ID}:{TAG}@999"),
            (22, 1, f"/elsewhere/cmux-tui --headless --session cmux-app-{TAG} --socket /tmp/s.sock"),
            (30, 1, "/Users/me/x/cmux DEV chrome-parity-v22.app/Contents/MacOS/cmux DEV"),      # another tag with this one as a prefix
            (31, 1, f"/elsewhere/cmux-tui --headless --session cmux-app-{TAG}-b --socket /tmp/b.sock"),
            (32, 1, f"/bin/zsh -c echo cmux-app-{TAG} "),                                        # the words in another command
            (33, 1, f"/x/cmux-tui __terminal-host --owner com.cmuxterm.app.debug.other:other@999"))
        self.assertEqual(sorted(m.tag_processes(TAG, rows)), [20, 21, 22])
        self.assertEqual(sorted(m.tag_processes(TAG, rows, exclude={20})), [21, 22])

    def test_a_dev_bundle_id_is_one_with_a_tag_not_one_with_the_letters_debug(self):
        self.assertTrue(m.tagged_dev_bundle("com.cmuxterm.app.debug.chrome-parity-v2"))
        for other in ("com.cmuxterm.app", "com.cmuxterm.app.debug", "com.acme.debugger", "com.acme.debug.", None):
            self.assertFalse(m.tagged_dev_bundle(other), other)

    def test_the_measured_processes_have_the_webkit_pages_and_the_hosts_that_outlived_the_tree(self):
        bundle = "/Users/me/perf lead/cmux DEV x.app"
        rows = {
            100: (1, 0, 0.0, bundle + "/Contents/MacOS/cmux DEV"),
            101: (100, 0, 0.0, bundle + "/Contents/Frameworks/Helper.app/Contents/MacOS/Helper"),
            200: (1, 0, 0.0, bundle + "/Contents/Resources/bin/cmux-tui --headless --session cmux-app-x"),
            300: (1, 0, 0.0, "/System/Library/Frameworks/WebKit.framework/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent"),
            301: (1, 0, 0.0, "/System/Library/Frameworks/WebKit.framework/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent"),
            400: (1, 0, 0.0, "/Users/me/Library/Application Support/cmux-next/terminal-host/abc/cmux-tui __terminal-host --owner com.x:x@200"),
            401: (400, 0, 0.0, "/bin/zsh -l"),
            402: (1, 0, 0.0, "/Users/me/Library/Application Support/cmux-next/terminal-host/abc/cmux-tui __terminal-host --owner com.y:y@777"),
            500: (1, 0, 0.0, bundle + "/Contents/Resources/bin/acpmux daemon run"),
        }
        responsible = {300: 100, 301: 9999}.get
        role = m.groups(rows, 100, 200, bundle, responsible)
        self.assertEqual(role.get(300), "webkit_xpc")
        self.assertNotIn(301, role)      # a page of another app
        self.assertEqual(role.get(400), "terminal_hosts")
        self.assertIn(401, role)         # the shell of that host
        self.assertNotIn(402, role)      # a host of another daemon
        self.assertEqual(role.get(500), "bundle_other")  # a bundle path with a space is compared whole


class RestoredAgents(unittest.TestCase):
    """After a restore, the product's "Resume Agents After Restart" starts the real `claude --resume session-real-<name>`
    in an agent terminal. `agents` ends that CLI by its exact PID (from the daemon's own terminal list), types the
    start line when the shell is back, and never types into or signals another program."""

    STUB = "/bin/zsh -f /kit/session_real_agent.zsh idle "
    CLI = "/Users/x/.local/bin/claude --settings /Users/x/.local/share/cmux-tui/claude-settings/11cb.json --resume session-real-"

    def world(self):
        rows = table(
            (100, 1, "cmux-tui __terminal-host --owner a:b@1"), (101, 100, "/bin/zsh"),
            (102, 101, self.CLI + "real-0001"), (103, 102, "node /x/helper.js"),                       # 1: resumed, with a child
            (110, 1, "login -flp x /bin/bash --noprofile --norc -c exec -l /bin/zsh"), (111, 110, "-/bin/zsh"),   # 2: shells only
            (121, 1, self.STUB + "real-0003"),                                                             # 3: the bench program
            (131, 1, "/bin/zsh -l"), (132, 131, "vim notes.txt"),                                          # 4: another program
            (141, 1, "/bin/zsh"), (142, 141, self.CLI + "real-0009"),                                      # 5: another terminal's id
            (151, 1, "/bin/zsh"), (152, 151, "/Users/x/.local/bin/claude --resume 6f2c1a52-0d1e-4c8e-9d3b-0a4d5a7e9b11"),  # 6: a real session
            (181, 1, "/bin/zsh"), (182, 181, self.CLI + "real-0008"), (183, 181, "sleep 100"),             # 8: the CLI and a program beside it
            (191, 1, "/bin/zsh"),                                                                          # 9: the daemon cut its list
            (201, 1, "/bin/sh /shim/claude --resume session-real-real-0010"),                              # 10: the product's shim, for a moment
            (211, 1, self.STUB + "real-0003"),                                                             # 11: a program with another name
            (221, 1, "/bin/zsh"), (222, 1, self.CLI + "real-0012"),                                        # 12: a listed PID that is not below the terminal's process
            (241, 1, "/bin/zsh"))                                                                          # 13, 14: no live process named
        terminals = [
            {"surface": 10, "pid": 101, "processes": [{"pid": 101}, {"pid": 102}, {"pid": 103}]},
            {"surface": 20, "pid": 110, "processes": [{"pid": 110}, {"pid": 111}]},
            {"surface": 30, "pid": 121, "processes": [{"pid": 121}]},
            {"surface": 40, "pid": 131, "processes": [{"pid": 131}, {"pid": 132}]},
            {"surface": 50, "pid": 141, "processes": [{"pid": 141}, {"pid": 142}]},
            {"surface": 60, "pid": 151, "processes": [{"pid": 151}, {"pid": 152}]},
            {"surface": 80, "pid": 181, "processes": [{"pid": 181}, {"pid": 182}, {"pid": 183}]},
            {"surface": 90, "pid": 191, "processes": [{"pid": 191}], "truncated": True},
            {"surface": 100, "pid": 201, "processes": [{"pid": 201}]},
            {"surface": 110, "pid": 211, "processes": [{"pid": 211}]},
            {"surface": 120, "pid": 221, "processes": [{"pid": 221}, {"pid": 222}]},
            {"surface": 130, "pid": None, "processes": []},
            {"surface": 140, "pid": 4242, "processes": [{"pid": 241}]}]
        tabs = [(n, {"surface": n * 10}) for n in range(1, 15)]

        class Daemon:
            def call(self, cmd, **params):
                assert cmd == "terminal-resources"
                return {"ok": True, "data": {"terminals": terminals, "missing": [70]}}

        return Daemon(), tabs, rows

    def test_each_agent_terminal_has_one_state_from_the_daemons_own_list(self):
        daemon, tabs, rows = self.world()
        states = m.agent_terminal_states(daemon, tabs, rows)
        self.assertEqual(states["real-0001"], ("resumed", {102: START, 103: START}))
        self.assertEqual(states["real-0002"][0], "shell")
        self.assertGreater(states["real-0002"][1], 3600)                  # the age of its newest shell, in seconds
        young = dict(rows)
        young[111] = (110, "Tue Nov 10 10:00:20 2026", "-/bin/zsh")
        at = m.time.mktime(m.time.strptime("Tue Nov 10 10:00:25 2026", "%a %b %d %H:%M:%S %Y"))
        self.assertEqual(m.agent_terminal_states(daemon, tabs, young, now=at)["real-0002"], ("shell", 5.0))
        self.assertEqual(states["real-0003"], ("program", 121))
        self.assertEqual(states["real-0007"], ("none", None))
        for name in ("real-0004", "real-0005", "real-0006", "real-0008", "real-0009", "real-0010", "real-0011",
                     "real-0012", "real-0013", "real-0014"):
            self.assertEqual(states[name][0], "other", (name, states[name]))   # never typed into, never signalled
        self.assertIn("pid 222", states["real-0012"][1])                   # the CLI's PID is not in that terminal's tree: no signal
        self.assertIn("no live process", states["real-0013"][1])           # nothing proves a shell: no start line
        self.assertEqual(m.agent_programs(daemon, tabs, rows), {"real-0003": 121})

    def test_a_signal_goes_only_to_the_same_process(self):
        rows = table((102, 101, self.CLI + "real-0001"), (103, 102, "node /x/helper.js", "Tue Nov 10 19:00:00 2026"))
        sent = []
        done = m.end_resumed({102: START, 103: START, 104: START}, signal.SIGTERM, rows, kill=lambda pid, sig: sent.append((pid, sig)))
        self.assertEqual(done, [102])                       # 103 has another start time (a new process), 104 is gone
        self.assertEqual(sent, [(102, signal.SIGTERM)])

    def test_the_agents_command_ends_the_cli_types_into_the_shell_and_gives_exit_0(self):
        """The whole `agents` command against a stub daemon and a stub process table: the wiring of the states, the
        signal, the start line and the exit code."""
        rows = table((101, 1, "/bin/zsh"), (102, 101, self.CLI + "real-0001"), (121, 1, self.STUB + "real-0002"),
                     (131, 1, "/bin/zsh"), (132, 131, self.CLI + "real-0001"))        # 132: the same id in a terminal of another daemon
        sent, typed = [], []

        class Daemon:
            def must(self, cmd, **params):
                if cmd == "identify":
                    return {"capabilities": ["terminal-resources-v1"]}
                assert cmd == "list-workspaces", cmd
                return {"workspaces": [{"name": "real-0001"}, {"name": "real-0002"}]}

            def call(self, cmd, **params):
                if cmd == "terminal-resources":
                    return {"ok": True, "data": {"terminals": [
                        {"surface": 10, "pid": 101, "processes": [{"pid": pid} for pid in (101, 102, 103) if pid in rows]},
                        {"surface": 20, "pid": 121, "processes": [{"pid": 121}]}]}}
                if cmd == "send":
                    typed.append((params["surface"], params["text"], sorted(rows)))
                    rows[103] = (101, START, "/bin/zsh -f /kit/session_real_agent.zsh working real-0001")
                    return {"ok": True}
                raise AssertionError(cmd)

        def kill(pid, sig):
            sent.append((pid, sig))
            del rows[pid]

        saved = (m.sockets, m.Conn, m.agent_tabs, m.process_rows, m.counts, m.settle_agents, os.kill)
        m.sockets, m.Conn = (lambda args: ("/tmp/daemon.sock", None)), (lambda sock: Daemon())
        m.agent_tabs = lambda tree, mix: [(1, {"surface": 10}), (2, {"surface": 20})]
        m.process_rows, m.counts, m.settle_agents = (lambda: dict(rows)), (lambda conn: {"agents": 2}), (lambda *a: None)
        os.kill = kill
        try:
            m.agents(argparse.Namespace(workspaces=2, terminals=2, agents=2, tabs=2, panes=2, browser_tabs=0, settle=30,
                                        force=False, agents_working=1, agents_blocked=0, socket="/tmp/daemon.sock", app_socket=None))
        finally:
            m.sockets, m.Conn, m.agent_tabs, m.process_rows, m.counts, m.settle_agents, os.kill = saved
        self.assertEqual(sent, [(102, signal.SIGTERM)])                 # the CLI of this daemon's terminal, not pid 132
        self.assertEqual(len(typed), 1)
        self.assertEqual(typed[0][0], 10)
        self.assertRegex(typed[0][1], r"session_real_agent\.zsh'? working real-0001\n$")
        self.assertNotIn(102, typed[0][2])                              # typed after the CLI ended, not into it

    def run_agents(self, states, settle=60, stays=(), deaf=(), new_shell=("shell", None), on_read=None):
        """A terminal world for `start_agents`: `end` makes a resumed terminal a shell (not one in `stays`), `send`
        makes a shell the program (not one in `deaf`), `restart` gives a dead tab a shell. `on_read(round, states)`
        changes the world before a read. `log["order"]` has each step in the order it came."""
        log, now, reads = {"end": [], "send": [], "restart": [], "order": []}, [1000.0], [0]
        tabs = [(int(name[5:]), {"surface": int(name[5:]) * 10}) for name in sorted(states)]

        def end(pids, sig):
            name = next(name for name, state in states.items() if state == ("resumed", pids))
            log["end"].append((name, sorted(pids), sig))
            log["order"].append("end")
            if name not in stays:
                states[name] = ("shell", None)
            return sorted(pids)

        def send(number, tab, state):
            name = f"real-{number:04d}"
            log["send"].append((name, states[name][0], state))
            log["order"].append("send")
            if name not in deaf and states[name][0] == "shell":
                states[name] = ("program", 9000 + number)
            return True

        def restart(tab):
            name = f"real-{tab['surface'] // 10:04d}"
            log["restart"].append(name)
            log["order"].append("restart")
            states[name] = new_shell
            return None

        def sleep(seconds):
            now[0] += seconds

        def read():
            reads[0] += 1
            if on_read:
                on_read(reads[0], states)
            log["order"].append("read")
            return dict(states)

        result = m.start_agents(tabs, read, send, restart, end, lambda rank: "working" if rank < 1 else "idle",
                                settle, clock=lambda: now[0], sleep=sleep)
        return result, log

    def test_a_resumed_cli_is_ended_by_its_pids_and_then_the_program_starts(self):
        states = {"real-0001": ("resumed", {102: START, 103: START}), "real-0002": ("shell", None), "real-0003": ("program", 121),
                  "real-0004": ("other", "vim notes.txt"), "real-0007": ("none", None)}
        result, log = self.run_agents(states)
        self.assertEqual(log["end"], [("real-0001", [102, 103], signal.SIGTERM)])        # one signal, the exact PIDs
        self.assertEqual(log["restart"], ["real-0007"])
        typed_into = {(name, kind) for name, kind, _ in log["send"]}
        self.assertEqual(typed_into, {("real-0001", "shell"), ("real-0002", "shell"), ("real-0007", "shell")})   # never into the CLI or vim
        self.assertEqual(log["send"][0], ("real-0002", "shell", "idle"))                 # rank 1; real-0001 (rank 0) works
        self.assertIn(("real-0001", "shell", "working"), log["send"])
        self.assertEqual({name: state[0] for name, state in result["states"].items()},
                         {"real-0001": "program", "real-0002": "program", "real-0003": "program", "real-0004": "other",
                          "real-0007": "program"})
        self.assertEqual((result["started"], result["already_running"], result["restarted_shells"]), (3, 1, 1))
        self.assertEqual(result["ended_resumed"], {"real-0001": [102, 103]})
        self.assertEqual(result["not_typed"], [])

    def test_a_cli_that_stays_gets_sigkill_one_time_and_is_a_fault(self):
        states = {"real-0001": ("resumed", {102: START})}
        result, log = self.run_agents(states, settle=30, stays=("real-0001",))
        self.assertEqual([sig for _, _, sig in log["end"]], [signal.SIGTERM, signal.SIGKILL])
        self.assertEqual(log["send"], [])                                                 # nothing typed into it
        self.assertEqual(result["states"]["real-0001"][0], "resumed")
        faults = m.agents_faults(1, 0, 1, 0, [], {}, ["real-0001"])
        self.assertTrue(any("still run the real CLI" in fault for fault in faults), faults)

    def test_a_start_line_that_started_nothing_is_typed_again_after_a_wait(self):
        states = {"real-0002": ("shell", None)}
        result, log = self.run_agents(states, settle=20, deaf=("real-0002",))
        self.assertGreaterEqual(len(log["send"]), 2)
        self.assertLessEqual(len(log["send"]), 3)                                         # every RETYPE_SECONDS, not every round
        self.assertEqual(result["started"], 1)

    def test_a_new_shell_gets_no_start_line_before_the_products_resume_time_is_over(self):
        states = {"real-0002": ("shell", 2.0), "real-0005": ("shell", 400.0)}
        result, log = self.run_agents(states, settle=5)
        self.assertEqual([name for name, _, _ in log["send"]], ["real-0005"])           # the young shell: not yet
        self.assertEqual(result["not_typed"], ["real-0002"])
        faults = m.agents_faults(2, 1, 2, len(result["not_typed"]), [])
        self.assertTrue(faults)                                                          # and that is never exit 0

    def test_a_restarted_tab_is_read_again_before_a_start_line(self):
        states = {"real-0007": ("none", None)}
        result, log = self.run_agents(states, settle=5, new_shell=("shell", 1.0))      # its shell is new: the product may type
        self.assertEqual((log["restart"], log["send"]), (["real-0007"], []))
        self.assertEqual(result["not_typed"], ["real-0007"])
        states = {"real-0007": ("none", None)}
        result, log = self.run_agents(states, settle=5, new_shell=("resumed", {300: START}))   # the product resumed its CLI
        self.assertEqual(log["end"], [("real-0007", [300], signal.SIGTERM)])
        self.assertEqual(log["send"], [("real-0007", "shell", "working")])
        self.assertEqual(result["restarted_shells"], 1)

    def test_the_start_lines_of_a_round_come_right_after_its_read(self):
        """A signal or a restart takes time (a process table each), and a shell can become the product's CLI in that
        time: no start line comes after one of them without a new read between."""
        states = {f"real-{n:04d}": ("resumed", {100 + n: START}) for n in range(1, 4)}
        states.update({"real-0004": ("shell", None), "real-0005": ("none", None), "real-0006": ("shell", None)})
        result, log = self.run_agents(states)
        self.assertEqual(len(log["send"]), 6)
        last = "read"
        for step in log["order"]:
            if step == "send":
                self.assertIn(last, ("read", "send"), log["order"])
            last = step
        self.assertTrue(all(kind == "shell" for _, kind, _ in log["send"]), log["send"])   # what the terminal was at the send

    def test_a_shell_that_became_the_cli_gets_no_line_and_the_cli_is_ended(self):
        def on_read(round, states):
            if round == 2:
                states["real-0002"] = ("resumed", {300: START})          # the product typed its resume command late
        states = {"real-0002": ("shell", 3.0)}
        result, log = self.run_agents(states, on_read=on_read)
        self.assertEqual(log["end"], [("real-0002", [300], signal.SIGTERM)])
        self.assertEqual(log["send"], [("real-0002", "shell", "working")])                # one line, after the CLI ended
        self.assertEqual(log["order"].index("end") < log["order"].index("send"), True)

    def test_a_dead_tab_with_no_terminal_after_the_restart_never_gets_a_line(self):
        states = {"real-0007": ("none", None)}
        result, log = self.run_agents(states, settle=5, new_shell=("none", None))
        self.assertEqual((log["restart"], log["send"]), (["real-0007"], []))
        self.assertEqual(result["not_typed"], ["real-0007"])
        self.assertTrue(m.agents_faults(1, 0, 1, 1, []))

    def test_a_second_line_also_waits_for_a_young_shell(self):
        def on_read(round, states):
            if round == 2:
                states["real-0002"] = ("shell", 1.0)                      # the tab has a new shell (the first line started nothing)
        states = {"real-0002": ("shell", 400.0)}
        result, log = self.run_agents(states, settle=20, deaf=("real-0002",), on_read=on_read)
        self.assertEqual(len(log["send"]), 1)                             # not again into the young shell after RETYPE_SECONDS

    def test_a_running_bench_program_never_gets_a_line(self):
        states = {"real-0003": ("program", 121)}
        result, log = self.run_agents(states)
        self.assertEqual(log["order"], ["read"])
        self.assertEqual((result["already_running"], result["started"]), (1, 0))

    def test_a_young_shell_at_the_end_of_the_time_is_a_fault_that_says_so(self):
        states = {"real-0002": ("shell", 2.0), "real-0009": ("none", None)}
        result, log = self.run_agents(states, settle=5, new_shell=("none", None))
        self.assertEqual((result["not_typed"], result["held_back"]), (["real-0002", "real-0009"], ["real-0002"]))
        faults = m.agents_faults(2, 0, 2, 2, [], {}, [], 1, 5)
        self.assertTrue(any("younger than 25 s" in fault and "--settle 5" in fault for fault in faults), faults)
        self.assertTrue(any(fault.startswith("1 agent terminals took no input") for fault in faults), faults)

    def test_with_no_time_nothing_is_typed_and_nothing_is_ended(self):
        states = {"real-0001": ("resumed", {102: START}), "real-0002": ("shell", None)}
        result, log = self.run_agents(states, settle=0)
        log.pop("order")
        self.assertEqual(log, {"end": [], "send": [], "restart": []})
        self.assertEqual(result["not_typed"], ["real-0002"])

    def test_another_program_is_a_fault_and_is_not_waited_for_long(self):
        states = {"real-0004": ("other", "vim notes.txt"), "real-0003": ("program", 121)}
        result, log = self.run_agents(states, settle=600)
        log.pop("order")
        self.assertEqual(log, {"end": [], "send": [], "restart": []})
        self.assertLess(result["rounds"], 40)                                             # OTHER_SECONDS, not the 600 s
        faults = m.agents_faults(2, 1, 2, 0, [], {"real-0004": "vim notes.txt"}, [])
        self.assertTrue(any("another program" in fault and "vim notes.txt" in fault for fault in faults), faults)

    def test_a_daemon_that_cannot_say_gets_the_start_line_one_time(self):
        states = {"real-0001": ("unknown", None), "real-0003": ("program", 121)}
        result, log = self.run_agents(states)
        self.assertEqual(log["send"], [("real-0001", "unknown", "working")])
        self.assertEqual(log["end"], [])


class BuildFailure(unittest.TestCase):
    """After a failed `build`, the daemon is asked to end its terminals first; then only exact PIDs get a signal."""

    class Daemon:
        pid = 200

        def __init__(self, ends_when_asked):
            self.alive, self.ends_when_asked, self.signals = True, ends_when_asked, []

        def poll(self):
            return None if self.alive else 0

        def wait(self, timeout=None):
            if self.alive:
                import subprocess
                raise subprocess.TimeoutExpired("daemon", timeout)
            return 0

        def terminate(self):
            self.signals.append("TERM")
            self.alive = False

        def kill(self):
            self.signals.append("KILL")
            self.alive = False

    def run_end(self, ends_when_asked, after):
        daemon, asked, killed = self.Daemon(ends_when_asked), [], []
        host = "/Users/me/Library/Application Support/cmux-next/terminal-host/abc/cmux-tui __terminal-host --owner com.x:x@200"
        before = table((200, 1, "/b/cmux-tui --headless"), (400, 1, host), (401, 1, host), (402, 1, host.replace("@200", "@777")))
        tables = [before, after(before)]

        class Connection:
            def must(self, cmd, **params):
                asked.append((cmd, params.get("end_terminals")))
                if cmd == "shutdown-daemon" and ends_when_asked:
                    daemon.alive = False
                return {"pid": 200, "generation": 1}

            def close(self):
                pass

        did = m.end_build_daemon(daemon, "/tmp/none.sock", rows=lambda: tables.pop(0), connect=Connection,
                                 kill=lambda pid, number: killed.append((pid, number)), wait=0)
        return daemon, asked, killed, did

    def test_the_daemon_is_asked_to_end_its_terminals_before_any_signal(self):
        daemon, asked, killed, did = self.run_end(True, lambda before: {200: before[200]})
        self.assertEqual(asked, [("identify", None), ("shutdown-daemon", True)])
        self.assertEqual((daemon.signals, killed), ([], []))
        self.assertEqual(did["hosts_before"], [400, 401])

    def test_a_host_that_stays_gets_a_signal_by_its_pid_and_a_reused_pid_does_not(self):
        def after(before):
            # 400 is still the same host; the pid 401 now belongs to another process (another start time).
            return {400: before[400], 401: (1, "Tue Nov 10 11:11:11 2026", before[401][2]), 402: before[402]}
        daemon, asked, killed, did = self.run_end(False, after)
        self.assertEqual(daemon.signals, ["TERM"])
        self.assertEqual(killed, [(400, signal.SIGTERM)])



class LiveForm(unittest.TestCase):
    """The form `real-live` (the person's LIVE size): the same mix rule as `real`, 59 terminals run (58 agent programs + 1
    plain shell), 739 are parked records, 214 agents are listed (58 in a terminal + 156 records of a closed terminal),
    1598 tabs. `real` (the stress form) does not change."""

    SIZE = dict(workspaces=826, terminals=798, panes=858)
    FORM_KEYS = ("agents", "agents_live", "live_shells", "tabs", "browser_tabs", "agents_working", "agents_gone", "gone_working", "gone_blocked")

    def args(self, form, **given):
        return m.apply_form(argparse.Namespace(form=form, **{**self.SIZE, **dict.fromkeys(self.FORM_KEYS), **given}))

    def form(self, args):
        mix = m.mix_of(args)
        return m.form_counts(mix, *m.live_split(args, mix), m.gone_of(args))

    def test_the_form_real_live_is_59_running_739_parked_214_listed_and_58_processes(self):
        args = self.args("real-live")
        self.assertEqual(self.form(args), {"terminals": 798, "terminals_running": 59, "terminals_exited": 739,
                                           "agents_listed": 214, "agent_processes": 58})
        self.assertEqual((args.agents, args.agents_gone, args.agents_working, args.gone_working, args.gone_blocked), (58, 156, 3, 23, 1))
        self.assertEqual([m.gone_state(rank, args) for rank in (0, 22, 23, 24, 155)], ["working", "working", "blocked", "idle", "idle"])

    def test_the_form_real_live_has_his_tab_kinds(self):
        got = m.mix_of(self.args("real-live")).summary()
        self.assertEqual((got["tabs"], got["terminals"], got["agent_chats"], got["chromium_pages"] + got["webkit_pages"]), (1598, 798, 614, 186))
        real = m.mix_of(self.args("real")).summary()
        self.assertEqual((real["tabs"], real["terminals"], real["chromium_pages"] + real["webkit_pages"]), (1600, 798, 516))

    def test_the_form_real_stays_the_stress_form(self):
        args = self.args("real")
        self.assertEqual(self.form(args), {"terminals": 798, "terminals_running": 200, "terminals_exited": 598,
                                           "agents_listed": 170, "agent_processes": 170})
        self.assertFalse(args.restart_live_shells)
        # An old caller that has no form (a Namespace of its own) reads as `real`.
        old = argparse.Namespace(**self.SIZE, tabs=1600, browser_tabs=516, agents=170, live_shells=30)
        self.assertEqual(self.form(old)["terminals_running"], 200)

    def test_a_count_from_the_command_line_wins_over_the_form(self):
        args = self.args("real-live", agents_live=20, live_shells=0)
        self.assertEqual((args.agents, args.agents_live, args.live_shells), (58, 20, 0))
        self.assertEqual(self.form(args)["terminals_running"], 20)
        with self.assertRaises(SystemExit):
            self.form(self.args("real-live", agents_live=59))

    def test_make_and_agents_pick_the_same_live_terminals(self):
        mix = m.mix_of(self.args("real-live", agents=214))
        agents, plain = m.first_kind_numbers(mix, "agent"), m.first_kind_numbers(mix, "terminal")
        self.assertEqual((len(agents), len(plain)), (214, 584))
        self.assertEqual(len(m.first_kind_numbers(m.mix_of(self.args("real-live")), "agent")), 58)
        live = m.live_numbers(mix, "agent", 58)
        self.assertEqual(len(live), 58)
        self.assertTrue(live <= set(agents))
        self.assertEqual(live, m.live_numbers(mix, "agent", 58))
        self.assertEqual(len(m.live_numbers(mix, "terminal", 1)), 1)
        self.assertEqual(m.live_numbers(mix, "agent", None), set(agents))

    def test_a_count_that_is_not_the_forms_or_is_not_known_is_a_fault(self):
        want = self.form(self.args("real-live"))
        self.assertEqual(m.form_faults(want, dict(want)), [])
        self.assertEqual(len(m.form_faults(want, dict(want, terminals_running=214, terminals_exited=584))), 2)
        self.assertEqual(len(m.form_faults(want, dict(want, agent_processes=None))), 1)
        self.assertEqual(len(m.form_faults(want, dict(want, agents_listed=50))), 1)

    def test_a_listed_agent_with_no_process_reports_a_session_that_is_not_resumed(self):
        line = m.agent_command(7, m.STALE)
        self.assertTrue(line.endswith(" idle real-0007 stale\n"), line)
        self.assertTrue(m.agent_command(7, "working").endswith(" working real-0007\n"))
        self.assertEqual(m.AGENT_COMMAND.search("/bin/zsh -f /kit/session_real_agent.zsh idle real-0007 stale").group(1), "real-0007")
        with open(m.AGENT_PROGRAM, encoding="utf-8") as handle:
            program = handle.read()
        # The id the program reports for `stale` is not one the daemon keeps for a resume ([A-Za-z0-9._-] only).
        self.assertIn('[[ ${3:-} == stale ]] && session="session-real+stale+$name"', program)

    def test_agent_records_of_closed_terminals_report_first_and_then_their_terminal_is_closed(self):
        calls, world = [], {"terminals": 0, "workspaces": 0, "rows": 5, "lost": 0, "refuse": False}

        class Daemon:
            def must(self, cmd, **params):
                calls.append((cmd, params))
                if cmd == "create-workspace":
                    world["workspaces"] += 1
                    return {"workspace": 70 + world["workspaces"]}
                if cmd == "create-terminal":
                    world["terminals"] += 1
                    return {"surface": 900 + world["terminals"], "terminal_id": f"t{world['terminals']}"}
                assert cmd == "send", cmd
                world["rows"] += 0 if world["lost"] and params["surface"] == 901 else 1   # the program reported: one more row
                return {}

            def call(self, cmd, **params):
                calls.append((cmd, params))
                assert cmd in ("close-terminal", "close-workspace"), cmd
                if world["refuse"] and cmd == "close-terminal":
                    return {"ok": False, "error": "no", "error_code": "x"}
                return {"ok": True}

            def v2(self, operation, **params):
                calls.append((operation, params))
                return [{}] * world["rows"]

        args = argparse.Namespace(cwd="/private/tmp", settle=0, gone_working=2, gone_blocked=1)
        saved = (m.GONE_BATCH, m.LISTED_ONLY_REPORT_SECONDS, m.ptys_in_use)
        m.GONE_BATCH, m.LISTED_ONLY_REPORT_SECONDS, m.ptys_in_use = 3, 0, lambda: 0
        try:
            made, parts, failed = m.make_gone_agents(Daemon(), args, 7)
            self.assertEqual((made, [part["terminals"] for part in parts], failed), (7, [3, 3, 1], []))   # the 5 rows before are not counted
            sends = [params["text"] for cmd, params in calls if cmd == "send"]
            self.assertEqual([text.split()[-2] for text in sends], ["working", "working", "blocked", "idle", "idle", "idle", "idle"])
            self.assertTrue(sends[0].endswith(" working gone-0001\n"), sends[0])
            order = [cmd for cmd, _ in calls if cmd in ("send", "close-terminal")]
            self.assertEqual(order, ["send"] * 3 + ["close-terminal"] * 3 + ["send"] * 3 + ["close-terminal"] * 3 + ["send", "close-terminal"])
            self.assertEqual([params["terminal_id"] for cmd, params in calls if cmd == "close-terminal"], [f"t{n}" for n in range(1, 8)])
            made_workspaces = [params["workspace"] for cmd, params in calls if cmd == "create-terminal"]
            self.assertEqual(len(set(made_workspaces)), 7)                                     # one workspace each, as `make` makes them
            closed = [params for cmd, params in calls if cmd == "close-workspace"]
            self.assertEqual([params["workspace"] for params in closed], made_workspaces)      # and each one is closed again
            self.assertTrue(all(params["end_terminals"] for params in closed))
            calls.clear()
            world.update(terminals=0, workspaces=0, rows=5, lost=1)
            self.assertEqual(m.make_gone_agents(Daemon(), args, 7)[0], 6)                      # a program that did not report is not a record
            world.update(terminals=0, workspaces=0, rows=5, lost=0, refuse=True)
            self.assertEqual(len(m.make_gone_agents(Daemon(), args, 7)[2]), 7)                 # a close the daemon refused is told, not raised
        finally:
            m.GONE_BATCH, m.LISTED_ONLY_REPORT_SECONDS, m.ptys_in_use = saved

    def test_a_daemon_with_no_agent_list_read_can_not_make_the_records(self):
        class Daemon:
            def must(self, cmd, **params):
                return {"workspace": 1}

            def v2(self, operation, **params):
                raise RuntimeError("unknown operation")

        with self.assertRaises(SystemExit) as stop:
            m.make_gone_agents(Daemon(), argparse.Namespace(cwd="/private/tmp", settle=0), 2)
        self.assertIn("agent.list", str(stop.exception.code))
        self.assertIsNone(m.durable_agents(object()))

    def run_make(self, wrong_live=0, **given):
        """`make` of a small session against a stub daemon. (the calls, the result or the SystemExit code)."""
        size = dict(form="real-live", workspaces=12, terminals=12, tabs=12, panes=12, browser_tabs=0, agents=6, agents_live=2, live_shells=2)
        args = argparse.Namespace(**{**size, **given}, agents_working=1, agents_blocked=0, settle=1, batch=5,
                                  cwd="/private/tmp", browser_url="about:blank", no_agents=False, out=None, socket="/tmp/d.sock", app_socket=None)
        calls, world = [], {"terminals": 0, "parked": 0, "listed": 0, "workspaces": 0, "gone": 0}
        lost_gone = given.pop("lost_gone", 0)

        class Daemon:
            def must(self, cmd, **params):
                calls.append((cmd, params))
                if cmd == "create-workspace":
                    world["workspaces"] += 1
                    return {"workspace": world["workspaces"]}
                if cmd == "create-terminal":
                    world["terminals"] += 1
                    return {"surface": 100 + world["terminals"], "pane": world["terminals"], "terminal_id": f"t{world['terminals']}"}
                if cmd == "park-tabs":
                    world["parked"] += len(params["surfaces"])
                    return {"parked": list(params["surfaces"])}
                if cmd == "send":
                    if " gone-" in params["text"]:
                        world["gone"] += 0 if lost_gone and params["text"].endswith(" gone-0001\n") else 1
                    else:
                        world["listed"] += 1
                    return {}
                raise AssertionError(cmd)

            def v2(self, operation, **params):
                assert operation == "agent.list", operation
                return [{}] * (world["listed"] + world["gone"])

            def call(self, cmd, **params):
                calls.append((cmd, params))
                if cmd == "close-terminal":      # the terminal and its tab go; its agent record stays
                    world["terminals"] -= 1
                    return {"ok": True}
                if cmd == "close-workspace":
                    world["workspaces"] -= 1
                    return {"ok": True}
                assert cmd == "list-agents", cmd
                return {"ok": True, "data": {"agents": [{}] * world["listed"]}}

        def counts(conn, app_socket=None):
            return {"workspaces": world["workspaces"], "panes": world["terminals"], "tabs": world["terminals"], "terminals": world["terminals"],
                    "terminals_live": world["terminals"] - world["parked"] + (wrong_live if world["terminals"] else 0), "terminals_parked": world["parked"],
                    "terminals_dead_other": 0, "tab_kinds": {}, "agents": world["listed"], "agents_listed": world["listed"] + world["gone"]}

        saved = (m.sockets, m.Conn, m.counts, m.pty_budget, m.host_facts, m.LISTED_ONLY_REPORT_SECONDS)
        m.sockets, m.Conn, m.counts = (lambda args: ("/tmp/d.sock", None)), (lambda sock: Daemon()), counts
        m.pty_budget, m.host_facts, m.LISTED_ONLY_REPORT_SECONDS = (lambda *a: "limit"), (lambda: {}), 0
        try:
            m.make(args)
            code = 0
        except SystemExit as stop:
            code = stop.code
        finally:
            m.sockets, m.Conn, m.counts, m.pty_budget, m.host_facts, m.LISTED_ONLY_REPORT_SECONDS = saved
        return calls, code

    def test_make_starts_each_listed_agent_and_parks_the_ones_with_no_process_after_their_report(self):
        calls, code = self.run_make()
        self.assertEqual(code, 0)
        sends = [params["text"] for cmd, params in calls if cmd == "send"]
        self.assertEqual(len(sends), 6)                                            # each of the 6 agents reports: all are listed
        self.assertEqual(sum(1 for text in sends if text.endswith(" stale\n")), 4)   # 4 of them never get a process again
        parks = [(index, len(params["surfaces"])) for index, (cmd, params) in enumerate(calls) if cmd == "park-tabs"]
        self.assertEqual(sum(count for _, count in parks), 4 + 4)                  # 4 plain (6 - 2 live) + the 4 listed agents
        last_send = max(index for index, (cmd, _) in enumerate(calls) if cmd == "send")
        listed = [index for index, (cmd, _) in enumerate(calls) if cmd == "list-agents"]
        self.assertEqual(parks[-1][1], 4)
        self.assertGreater(parks[-1][0], last_send)                                # the agents' terminals end after every report
        self.assertTrue(any(last_send < index < parks[-1][0] for index in listed))  # and the list is read before the park
        stale = {params["surface"] for cmd, params in calls if cmd == "send" and params["text"].endswith(" stale\n")}
        self.assertEqual(set(calls[parks[-1][0]][1]["surfaces"]), stale)           # only the terminals of the stale agents

    def test_make_adds_the_agent_records_of_closed_terminals_after_the_session_and_counts_them(self):
        calls, code = self.run_make(agents=2, agents_live=None, agents_gone=3, gone_working=1, gone_blocked=0)
        self.assertEqual(code, 0)
        names = [cmd for cmd, _ in calls]
        self.assertEqual(names.count("close-terminal"), 3)
        self.assertGreater(names.index("close-terminal"), max(index for index, name in enumerate(names) if name == "park-tabs"))
        self.assertEqual((names.count("close-workspace"), names[-1]), (3, "close-workspace"))   # the count read comes after (a stub function)
        gone = [params["text"] for cmd, params in calls if cmd == "send" and " gone-" in params["text"]]
        self.assertEqual([text.split()[-2] for text in gone], ["working", "idle", "idle"])
        # One program that never reported: 2 records, the form has 3: exit 3.
        self.assertEqual(self.run_make(agents=2, agents_live=None, agents_gone=3, gone_working=1, gone_blocked=0, lost_gone=1)[1], m.EXIT_FAULTS)

    def test_make_with_another_count_of_running_terminals_is_a_fault(self):
        self.assertEqual(self.run_make(wrong_live=3)[1], m.EXIT_FAULTS)

    def test_make_of_the_form_real_parks_no_agent_terminal(self):
        calls, code = self.run_make(form="real", agents_live=None)
        self.assertEqual(code, 0)
        self.assertEqual(sum(len(params["surfaces"]) for cmd, params in calls if cmd == "park-tabs"), 4)
        self.assertFalse(any(params["text"].endswith(" stale\n") for cmd, params in calls if cmd == "send"))

    def test_listed_agents_with_no_process_need_the_agent_programs(self):
        with self.assertRaises(SystemExit) as stop:
            saved = (m.sockets, m.pty_budget)
            m.sockets, m.pty_budget = (lambda args: ("/tmp/d.sock", None)), (lambda *a: "limit")
            try:
                m.make(argparse.Namespace(form="real-live", workspaces=12, terminals=12, tabs=12, panes=12, browser_tabs=0, agents=6,
                                          agents_live=2, live_shells=2, no_agents=True))
            finally:
                m.sockets, m.pty_budget = saved
        self.assertIn("--no-agents", str(stop.exception.code))

    def tree(self, mix, dead):
        """A `list-workspaces` tree of a made session: one terminal first in each workspace; `dead` says which are."""
        return {"workspaces": [{"name": f"real-{number:04d}", "screens": [{"panes": [{"tabs": [
            {"kind": "pty", "surface": 100 + number, "dead": number in dead}]}]}]} for number in range(1, mix.workspaces + 1)]}

    def test_after_a_restore_the_plain_live_shells_start_again_and_no_other_terminal(self):
        args = argparse.Namespace(workspaces=12, terminals=12, tabs=12, panes=12, browser_tabs=0, agents=6, agents_live=2, live_shells=2)
        mix = m.mix_of(args)
        keep = m.live_numbers(mix, "terminal", 2)
        asked = []

        class Daemon:
            def call(self, cmd, **params):
                assert cmd == "restart-tab", cmd
                asked.append(params["surface"])
                return {"ok": True} if params["surface"] != 100 + max(keep) else {"ok": False, "error": "no pty", "error_code": "x"}

        did = m.restart_live_shells(Daemon(), self.tree(mix, dead=set(range(1, 13))), mix, 2)
        self.assertEqual(sorted(asked), sorted(100 + number for number in keep))   # never an agent terminal, never a parked plain one
        self.assertEqual((did["asked"], did["restarted"], len(did["failed"])), (2, 1, 1))
        asked.clear()
        self.assertEqual(m.restart_live_shells(Daemon(), self.tree(mix, dead=set()), mix, 2)["asked"], 0)   # a shell that runs gets no restart
        self.assertEqual(asked, [])

    def test_the_check_reads_running_exited_listed_and_the_agent_processes(self):
        args = argparse.Namespace(workspaces=12, terminals=12, tabs=12, panes=12, browser_tabs=0, agents=6, agents_live=2, live_shells=2)
        mix = m.mix_of(args)
        live = sorted(m.live_numbers(mix, "agent", 2))
        rows = table((500 + live[0], 1, f"/bin/zsh -f /kit/session_real_agent.zsh idle real-{live[0]:04d}"),
                     (500 + live[1], 1, f"/Users/x/.local/bin/claude --resume session-real-real-{live[1]:04d}"))

        class Daemon:
            def must(self, cmd, **params):
                if cmd == "identify":
                    return {"capabilities": ["terminal-resources-v1"]}
                assert cmd == "list-workspaces", cmd
                return LiveForm.tree(self, mix, dead=set())

            def call(self, cmd, **params):
                assert cmd == "terminal-resources", cmd
                return {"ok": True, "data": {"terminals": [{"surface": 100 + number, "pid": 500 + number, "processes": [{"pid": 500 + number}]}
                                                           for number in live]}}

        saved = (m.counts, m.process_rows)
        m.counts = lambda conn: {"terminals": 12, "terminals_live": 4, "terminals_parked": 8, "terminals_dead_other": 0, "agents": 6}
        m.process_rows = lambda: dict(rows)
        try:
            got, detail = m.check_read(Daemon(), mix)
        finally:
            m.counts, m.process_rows = saved
        self.assertEqual(got, {"terminals": 12, "terminals_running": 4, "terminals_exited": 8, "agents_listed": 6, "agent_processes": 2})
        # A form with records of closed terminals counts the agents of the read `agent.list`; no answer is a fault, not a pass.
        saved = (m.counts, m.process_rows)
        m.counts = lambda conn: {"terminals": 12, "terminals_live": 4, "terminals_parked": 8, "terminals_dead_other": 0, "agents": 6, "agents_listed": 9}
        m.process_rows = lambda: dict(rows)
        try:
            self.assertEqual(m.check_read(Daemon(), mix, True)[0]["agents_listed"], 9)
            self.assertEqual(m.form_faults(m.form_counts(mix, 2, 2, 3), m.check_read(Daemon(), mix, True)[0]), [])
            m.counts = lambda conn: {"terminals": 12, "terminals_live": 4, "terminals_parked": 8, "terminals_dead_other": 0, "agents": 6}
            self.assertEqual(len(m.form_faults(m.form_counts(mix, 2, 2, 3), m.check_read(Daemon(), mix, True)[0])), 1)
        finally:
            m.counts, m.process_rows = saved
        self.assertEqual(m.form_faults(m.form_counts(mix, 2, 2), got), [])
        self.assertEqual(detail["agent_terminal_states"], {"program": 1, "resumed": 1, "none": 4})


if __name__ == "__main__":
    unittest.main(verbosity=1)
