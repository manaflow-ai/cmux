#!/usr/bin/env python3
"""holder-dogfood.py's close, reopen and paste steps against a fake app and daemon (no app): each step runs the
app action it names by exact id, Cmd-W waits for the shell past the daemon's reap grace, and the paste answers
the app's paste confirmation.
Run: python3 -I scripts/cmux-next/tests/test_holder_dogfood.py"""
import importlib.util, os, sys, tempfile, types, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
spec = importlib.util.spec_from_file_location("holder_dogfood", os.path.join(HERE, "..", "holder-dogfood.py"))
dogfood = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dogfood)

# The app's action ids around these steps, sorted as `action.list` gives them to Dogfood.launch (a subset).
ACTIONS = sorted(["closeOtherTabsInPane", "closeTab", "closeTabsToLeft", "closeTabsToRight", "history.reopen",
                  "pasteLastScreenshot", "reopenClosedBrowserPanel", "reopenClosedWorkspace", "tab.focus",
                  "terminalPaste"])


class FakeClock:
    """Stands in for the module's `time`: a sleep advances the clock."""

    def __init__(self):
        self.now = 0.0

    def monotonic(self):
        return self.now

    def sleep(self, seconds):
        self.now += max(seconds, 0.01)


class FakeDaemon:
    def __init__(self, clock):
        self.clock, self.screens, self.next = clock, {}, 0

    def call(self, cmd, **params):
        if cmd == "run":
            self.next += 1
            text = "close-me-marker" if "close-me-marker" in " ".join(params["argv"]) else "paste-ready"
            self.screens[self.next] = text
            return {"surface": self.next}
        raise AssertionError(f"unexpected daemon call {cmd}")

    def surfaces(self):
        return sorted(self.screens)

    def screen(self, surface):
        return self.screens.get(surface, "")

    def shells(self, surfaces):
        return {s: 1000 + s for s in surfaces}


class FakeApp:
    """The app's socket for these steps: snapshot.get names each daemon workspace's tab, action.run records
    runs, Close Tab detaches the terminal (the daemon ends it `reap_after` s later), Reopen brings it back as a
    new surface, Paste asks first (debug.dialog) and delivers the bytes once Allow is pressed."""

    def __init__(self, daemon, clock, reap_after=dogfood.REAP_GRACE_S + 1):
        self.daemon, self.clock, self.reap_after = daemon, clock, reap_after
        self.runs, self.dialogs, self.ended = [], [], {}
        self.pasted = ""  # what pbcopy put on the pasteboard
        self.quit_origin, self.quit_refused = None, False

    def rpc(self, method, params=None, timeout=60):
        params = params or {}
        if method == "snapshot.get":
            workspaces = [{"name": name, "screens": [{"panes": [{"id": f"pane_{name}", "tabs": [{"id": f"tab_{name}"}]}]}]}
                          for name in ("dogfood-close", "dogfood-paste")]
            return {"topology": {"workspaces": workspaces}}
        if method == "debug.dialog":
            if params.get("press") == "allow":
                for dialog in self.dialogs:
                    if dialog["id"] == params.get("id"):
                        dialog["visible"] = False
                        # A canonical tty hands `head -c` whole lines: it ends (and wc prints) only when
                        # the pasted bytes up to the last newline reach PASTE_BYTES.
                        delivered = self.pasted.rfind("\n") + 1
                        if delivered >= dogfood.PASTE_BYTES:
                            self.daemon.screens[dialog["surface"]] += f"\n{dogfood.PASTE_BYTES}"
                        return {"pressed": True, "dialogs": []}
                return {"pressed": False, "dialogs": []}
            return {"dialogs": [d for d in self.dialogs if d["visible"]]}
        if method != "action.run":
            return {}
        action = params["action"]
        self.runs.append(action)
        if action == "closeTab":
            self.ended[1000 + 1] = self.clock.now + self.reap_after  # the close terminal's shell
        elif action == "quitKeepSessions":
            self.quit_origin = params.get("origin")
            if self.quit_refused:
                return {"error": {"code": "refused", "message": "a quit is already asking"}}
        elif action == "closeOtherTabsInPane":
            return {"error": {"code": "refused", "message": "No other tabs to close"}}
        elif action == "history.reopen" and self.ended:
            self.daemon.next += 1
            self.daemon.screens[self.daemon.next] = "close-me-marker"
        elif action == "terminalPaste":
            if not str(params.get("target", "pane:")).startswith("pane:"):
                # ControlRouter+Validation: terminalPaste takes a target of kind pane only.
                return {"error": {"code": "invalid_params", "message": "terminalPaste takes a target of kind pane"}}
            self.dialogs.append({"id": len(self.dialogs) + 1, "identifier": dogfood.PASTE_DIALOG, "visible": True,
                                 "surface": max(s for s, text in self.daemon.screens.items() if text == "paste-ready")})
        return {}


def make(reap_after=dogfood.REAP_GRACE_S + 1):
    clock = FakeClock()
    dogfood.time = clock
    opts = types.SimpleNamespace(out=tempfile.mkdtemp(prefix="holder-dogfood-test-"), model="holder", app="/nowhere")
    run = dogfood.Dogfood(opts)
    run.daemon = FakeDaemon(clock)
    run.app = FakeApp(run.daemon, clock, reap_after)

    def pbcopy(argv, input=None, **_):  # no pasteboard here: the fake app keeps what would be pasted
        run.app.pasted = input.decode()
    dogfood.subprocess = types.SimpleNamespace(run=pbcopy)
    run.actions = ACTIONS
    run.alive = lambda pid: clock.now < run.app.ended.get(pid, float("inf"))
    records = []
    dogfood.emit = lambda kind, record: records.append(record)
    return run, records


class ActionTests(unittest.TestCase):
    def test_each_step_runs_the_action_it_names_not_the_first_fuzzy_match(self):
        # Fleet holder-dogfood (e13f253fa4c): DOGFOOD-ACTIONS {"close": "closeOtherTabsInPane",
        # "paste": "pasteLastScreenshot"}: the first sorted ids holding "close"+"tab" and "paste".
        run, _ = make()
        self.assertEqual(run.action(dogfood.CLOSE_TAB), "closeTab")
        self.assertEqual(run.action(dogfood.REOPEN_CLOSED), "history.reopen")
        self.assertEqual(run.action(dogfood.TERMINAL_PASTE), "terminalPaste")
        self.assertIsNone(run.action("noSuchAction"))


class CloseReopenTests(unittest.TestCase):
    def test_cmd_w_waits_for_the_shell_past_the_reap_grace_and_reopen_brings_the_screen_back(self):
        run, records = make()
        run.close_and_reopen()
        steps = {r["step"]: r for r in records}
        self.assertIn("closeTab", run.app.runs)
        self.assertNotIn("closeOtherTabsInPane", run.app.runs)
        self.assertTrue(steps["cmd-w"]["ok"], steps["cmd-w"])
        self.assertGreater(steps["cmd-w"]["ended_after_s"], 20, "the shell ends only after the reap grace")
        self.assertTrue(steps["reopen-closed"]["ok"], steps["reopen-closed"])

    def test_a_shell_that_outlives_the_grace_by_far_fails_cmd_w(self):
        run, records = make(reap_after=dogfood.SHELL_END_S + 30)
        run.close_and_reopen()
        self.assertFalse(next(r for r in records if r["step"] == "cmd-w")["ok"])


class PasteTests(unittest.TestCase):
    def test_the_paste_runs_terminal_paste_and_answers_its_confirmation(self):
        run, records = make()
        run.paste()
        step = next(r for r in records if r["step"] == "paste-256k")
        self.assertEqual(step["action"], "terminalPaste")
        self.assertIsNone(step["reply"], "terminalPaste was refused (a tab target)")
        self.assertTrue(step["confirmed"], step)
        self.assertTrue(step["ok"], step)


    def test_the_payload_is_its_size_and_ends_with_a_newline(self):
        data = dogfood.paste_payload()
        self.assertEqual(len(data.encode()), dogfood.PASTE_BYTES)
        self.assertTrue(data.endswith("\n"), "bytes after the last newline wait in a canonical tty")


class LaunchTests(unittest.TestCase):
    def test_the_host_model_goes_to_the_app_under_its_cmux_next_knob(self):
        # The app unsets an inherited CMUX_TUI_TERMINAL_HOST_MODEL (LaunchIdentity.inheritedKeys): every fleet
        # "holder" run measured hosts ("holder_processes": 0, holder-kill "no holder process").
        env = dogfood.launch_env("holder", "/state")
        self.assertEqual(env.get("CMUX_NEXT_TUI_TERMINAL_HOST_MODEL"), "holder")
        self.assertNotIn("CMUX_TUI_TERMINAL_HOST_MODEL", env)

    def relaunch(self, refused=False, new_daemon=False, exits=True, dropped=False, status=0):
        run, records = make()
        app = run.app
        app.quit_refused = refused
        if dropped:  # the app quit before it answered: the socket closed (bench_launch.rpc_at)
            rpc = app.rpc
            app.rpc = lambda m, p=None, timeout=60: ({"error": "Expecting value", "unreachable": True}
                                                     if (p or {}).get("action") == "quitKeepSessions" else rpc(m, p, timeout))

        state = {"running": not exits}

        def wait(seconds):  # subprocess.Popen.wait: times out while the app runs, else its exit status
            if state["running"]:
                raise TimeoutError("the app ran on")
            return status

        def terminate():
            state["running"] = False
        app.process = types.SimpleNamespace(wait=wait, terminate=terminate)
        run.daemon.pid = 7
        launches = []

        def launch(fresh=True):
            launches.append(fresh)
            run.app = app  # the relaunched app answers on the same fake socket
            if new_daemon:
                run.daemon.pid = 8
        run.launch = launch
        run.relaunch([])
        return run, app, launches, next(r for r in records if r["step"] == "quit-relaunch")

    def test_relaunch_quits_keeping_sessions_and_relaunches_on_them(self):
        # Fleet: `debug.quit {}` only reports, the app ran on, and the relaunch stopped at tag-in-use.
        run, app, launches, step = self.relaunch()
        self.assertIn(dogfood.QUIT_KEEPING_SESSIONS, app.runs)
        self.assertEqual(app.quit_origin, "script")
        self.assertEqual(launches, [False], "the relaunch moved the saved session aside")
        self.assertTrue(step["ok"], step)

    def test_a_refused_quit_or_a_new_daemon_fails_the_relaunch(self):
        _, _, _, step = self.relaunch(refused=True)
        self.assertFalse(step["ok"], "a refused quit passed")
        self.assertIsNotNone(step["quit_reply"])
        _, _, _, step = self.relaunch(new_daemon=True)
        self.assertFalse(step["ok"], "a relaunch on a new daemon (sessions not kept) passed")
        _, _, _, step = self.relaunch(exits=False)
        self.assertFalse(step["ok"], "an app that never quit (terminated by the script) passed")

    def test_an_app_that_crashes_while_it_quits_fails_the_relaunch(self):
        # A crash drops the reply too (no refusal), and the daemon runs on: only the exit status tells.
        _, _, _, step = self.relaunch(dropped=True, status=-11)
        self.assertFalse(step["ok"], "a crash (SIGSEGV) while quitting passed")
        self.assertEqual(step["quit_status"], -11)

    def test_a_quit_that_closes_the_socket_before_its_reply_is_no_refusal(self):
        _, _, _, step = self.relaunch(dropped=True)
        self.assertTrue(step["ok"], step)


if __name__ == "__main__":
    unittest.main()
