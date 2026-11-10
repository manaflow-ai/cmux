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
        rows = table((10, 1, zsh + "real-0003"), (11, 9, zsh + "real-0008"), (12, 1, zsh + "real-0003"),   # 12: another tag's
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


if __name__ == "__main__":
    unittest.main(verbosity=1)
