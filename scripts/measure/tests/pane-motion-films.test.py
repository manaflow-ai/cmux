#!/usr/bin/env python3
"""scripts/measure/pane-motion-films.py: what makes the app active, and what makes a zoom, in each case.

The launcher starts the app's binary directly, and on a display Mac that process did not become the active app:
the `activate` launch form had no key window, and the zoom key changed nothing in the `one-key` form. The script now
asks LaunchServices one time (`open BUNDLE`), says what made the app active in a `PREFLIGHT activate:` line, ends the
run (with one SIGTERM to the new instance only) if that open started a second instance, and makes a zoom by
`action.run` when the zoom key changes nothing, with those words in the film's row.

No app, no socket, no build: `main()` runs with the launcher (`BenchApp`), the session helper (`Stress`) and
`subprocess`, `os.kill` and the clock replaced by fakes with a small model of tabs, panes, zoom and the app's active
state (no signal goes to a process, and no test reads a real clock). So this proves the
script's own logic (names, flow, rows, exit codes), NOT the app and NOT what LaunchServices does on a Mac.
Run: python3 -I scripts/measure/tests/pane-motion-films.test.py"""
import contextlib, importlib.util, io, itertools, json, os, shutil, signal, subprocess, sys, tempfile, unittest
from unittest import mock

sys.dont_write_bytecode = True  # the script's imports leave no cache folder in the checkout
HERE = os.path.dirname(os.path.abspath(__file__))
SPEC = importlib.util.spec_from_file_location("pane_motion_films_under_test", os.path.join(HERE, "..", "pane-motion-films.py"))
M = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(M)
CODE = {code: name for name, code in M.KEY.items()}
BUNDLE = "/fake/cmux DEV fake.app"
BINARY = BUNDLE + "/Contents/MacOS/cmux DEV fake"
INSTANCE_100 = f"PREFLIGHT activate: instance pid 100: parent 50, command {BINARY}"
PAGES = ("newtab", "chromium", "chat")  # the tab kinds that the app shows as a Chromium page in a child window


class Clock:
    """The script's `time`: a counter (1 ms for each read) and no sleep. No test reads a real clock."""
    ticks = itertools.count()
    monotonic = time = staticmethod(lambda: next(Clock.ticks) / 1000)

    @staticmethod
    def sleep(seconds):
        pass


BOUNDS = []


def wait(test, seconds, step=0.25):
    """The session helper's `wait` for a fake that changes in the call itself: 3 reads, no sleep. It keeps the bound
    that the script gave it."""
    BOUNDS.append(seconds)
    for _ in range(3):
        value = test()
        if value:
            return value
    return None


class World:
    """One fake launch: the app's state, and the faults of the case."""

    def __init__(self, env, faults, index):
        self.no_activate, self.faults, self.index = env.get("CMUX_NEXT_NO_ACTIVATE") == "1", faults, index
        self.active = "launch-activates" in faults and not self.no_activate
        self.spaces, self.shown, self.focus, self.count, self.record = {}, None, None, 0, None
        self.opens, self.sequences, self.one_keys, self.dry_runs, self.actions, self.signals = [], 0, 0, 0, [], []
        # pid: its parent. 100 = the launch's own process; 150 = an instance that launchd started before this run.
        self.pids = {100: 50, **({150: 1} if "other-instance-before" in faults else {})}
        self.ps_calls, self.pending, self.zoom_keys_at_a_pending_tab = 0, 0, []
        self.words = []  # for each key sequence to the active app: (the `key_window` word of the call, the window that had the keys)
        # The animation speed and each call that set it (the word, the workspaces at that time); the spans of the
        # motion record; the steps of each key sequence; the zoomed pane after each zoom.
        self.speed, self.speeds, self.spans, self.played, self.zoom_states = "fast", [], [], [], []

    def page(self):
        """With the fault `page-takes-keys`, the app's design by a read of its code (ChildPageFocus.swift,
        FocusEffectApplier.swift): a Chromium page shows in a child window, and that window has the keys while its
        page has focus. Returns the id of that page (the last tab of the focused pane, when it is a page and the app
        is active), else None: the shell window has the keys. A model of the app, not the app."""
        pane = next((p for p in self.spaces.get(self.shown, {}).get("panes", []) if p["id"] == self.focus), None)
        if "page-takes-keys" not in self.faults or not self.active or not pane or not pane["tabs"]:
            return None
        return pane["tabs"][-1]["id"] if pane["tabs"][-1]["kind"] in PAGES else None

    def ident(self, kind):
        self.count += 1
        return f"{kind}{self.count}"

    def pane(self):
        return {"id": self.ident("pane"), "tabs": [{"id": self.ident("tab"), "kind": "terminal"}]}

    def changed(self):
        if self.record and self.record["capturing"]:
            self.record["complete"] += 3

    def read(self):
        """One read of the layout by the script. With `split-settles-late` the 4th read after a split is the first
        that has the new pane's tab as the daemon knows it; with `split-never-settles` no read has it."""
        if self.pending and "split-settles-late" in self.faults:
            self.pending -= 1
            if not self.pending:
                for tab in (tab for space in self.spaces.values() for pane in space["panes"] for tab in pane["tabs"]):
                    tab["id"] = tab["id"].removeprefix("pending_tab_")

    def zoom(self, pane):
        space = self.spaces[self.shown]
        space["zoomed"] = None if space["zoomed"] else pane
        self.zoom_states.append(space["zoomed"])
        self.spans.append({"name": "fake.zoom", "ms": M.ZOOM_MS[self.speed], "at_ms": len(self.spans) + 1, "more": "not for the row"})
        self.changed()

    def key(self, name):
        space = self.spaces[self.shown]
        pane = next(p for p in space["panes"] if p["id"] == self.focus)
        if name == "t":
            pane["tabs"].append({"id": self.ident("tab"), "kind": "newtab"})
        elif name == "w":
            pane["tabs"].pop()
            if not pane["tabs"] and len(space["panes"]) > 1:  # the close of a pane's last tab closes the pane
                at = space["panes"].index(pane)
                space["panes"].remove(pane)
                self.focus = space["panes"][max(at - 1, 0)]["id"]
        elif name == "d":
            space["panes"].append(self.pane())
            self.focus = space["panes"][-1]["id"]
            if self.faults & {"split-settles-late", "split-never-settles"}:  # the app's stand-in for the new tab
                tab = space["panes"][-1]["tabs"][0]
                tab["id"], self.pending = "pending_tab_" + tab["id"], 4
        elif name == "return":
            self.zoom_keys_at_a_pending_tab.append(any(tab["id"].startswith("pending_tab_") for p in space["panes"] for tab in p["tabs"]))
            if "zoom-key-dead" in self.faults:
                return False
            if "zoom-key-refused" in self.faults:
                return "refused"
            return self.zoom(self.focus) or True
        self.changed()
        return True


class FakeApp:
    made, faults = [], set()

    def __init__(self, app, out=None, env=None, log_name=None):
        self.app, self.binary, self.window, self.socket, self.extra = app, BINARY, (40, 40, 1440, 900), "/fake.sock", env or {}
        # The process that the launcher started; with the fault, a pid that the fake `ps` does not list.
        self.process = mock.Mock(pid=999 if "launched-pid-not-listed" in FakeApp.faults else 100)

    def launch(self):
        env = {"CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_AGENT_PANE_MOCK": "1", "ACPMUX_AGENT_LAUNCH": "deny", **self.extra}
        self.launched_env = {k: v for k, v in env.items() if v is not None}
        self.world = World(self.launched_env, FakeApp.faults, len(FakeApp.made))
        FakeApp.made.append(self)
        return self

    def stop(self):
        self.stopped = True

    def rpc(self, method, params=None, timeout=60):
        world, params = self.world, params or {}
        if method == "debug.focus":
            page = world.page()
            said = {"app_active": world.active, "key_window": ("CefNSWindow" if page else "ShellWindow") if world.active else None}
            if "page-takes-keys" in world.faults:  # the part of the app's reply that says which window has the keys
                said["windows"] = [{"id": "window1", "is_key": world.active and not page, "appkit": {"child_window_page": page}}]
            return said
        if method == "debug.frames":
            return {} if params.get("action") == "start" else {"frames": 120, "p50_ms": 8.33, "refresh_ms": 8.33}
        if method == "debug.window_frame":
            return {"frame": params.get("frame") or [100, 100, 1100, 720], "visible_frame": [0, 0, 1920, 1175], "screen_frame": [0, 0, 1920, 1200]}
        if method == "debug.motion" and params.get("action") in ("speed", "read", "start", "stop"):
            if params["action"] == "speed":
                world.speeds.append((params.get("value"), len(world.spaces)))
                if "speed-ignored" not in world.faults:  # the fault: an app that keeps its speed
                    world.speed = params.get("value")
            if params["action"] == "start":
                world.spans = []
            return {"recording": params["action"] == "start", "speed": world.speed, "spans": list(world.spans)}
        if method == "debug.motion":
            if params.get("action") == "record_start":
                world.record = {"capturing": True, "written": False, "complete": 0, "frames": 0}
                return {"width": 1880, "height": 1135}
            if params.get("action") == "record_stop" and world.record:
                world.record.update(capturing=False, written=True, frames=world.record["complete"], first_t=1.0, last_t=6.0, movie_status="completed")
            return dict(world.record or {})
        if method == "debug.key" and "sequence" in params:
            wanted, page = params.get("key_window"), world.page()
            if world.active:
                world.words.append((wanted, "page" if page else "shell"))
            # The app's own words for a window that cannot become key: no window of an app that is not active, and
            # not the shell window while a page has the keys (the app gives them back to the page).
            if not world.active or (wanted == "shell" and page):
                return {"error": f"the {wanted} window did not become key"}
            if wanted == "page" and "page-takes-keys" in world.faults and not page:
                return {"error": "no Chromium page window for pane"}
            world.sequences += 1
            world.played.append(params["sequence"])
            for name in (CODE[step["key_code"]] for step in params["sequence"] if step["down"]):
                if name not in M.MODIFIERS:
                    world.key(name)
            return {"base_s": 12.5, "duration_ms": 30, "scheduled": len(params["sequence"]), "key_window": params.get("key_window")}
        if method == "debug.key" and params.get("dry_run"):
            world.dry_runs += 1
            return {"decision": f"run(fake.{params['key']})", "action": "fake." + params["key"], "focus": "terminal"}
        if method == "debug.key":
            world.one_keys += 1
            took = world.key(params["key"])
            if took == "refused":  # the app took the key for an action and the action did not run
                return {"handled_by": "app", "action": "toggleSplitZoom", "refused_action": "toggleSplitZoom",
                        "trace": ["KeyRouter: the action is not available"]}
            return {"handled_by": "app" if took else "window", "action": "fake." + params["key"] if took else None,
                    "trace": [] if took else ["TerminalKeyEquivalent: the terminal took the key"]}
        return {"ready": True} if method == "debug.agent_pane" else {}


class FakeStress:
    """The session helper's calls that the films script makes, on the fake app's model."""

    def __init__(self, rpc):
        self.world, self.made, self.refusals, self.chat_fallbacks = rpc.__self__.world, {}, [], 0

    def topology(self):
        return {"windows": [{"id": "window1"}]}

    def workspaces(self):
        return [{"id": ident} for ident in self.world.spaces]

    def workspace(self, ident):
        self.world.read()
        space = self.world.spaces.get(ident)
        return space and {"id": ident, "screens": [{"zoomed_pane": space["zoomed"], "panes": space["panes"]}]}

    def panes(self, space):
        return [pane for screen in (space or {}).get("screens", []) for pane in screen["panes"]]

    def window_showing(self, workspace):
        return {"focused_pane": self.world.focus} if self.world.shown == workspace else None

    def new_workspace(self):
        ident = self.world.ident("workspace")
        self.world.spaces[ident] = {"panes": [self.world.pane()], "zoomed": None}
        return ident

    def show(self, ident):
        self.world.shown = ident

    def focus_pane(self, pane):
        self.world.focus = pane

    def tabs(self, workspace, pane):
        return next(p["tabs"] for p in self.world.spaces[workspace]["panes"] if p["id"] == pane)

    settled_tabs = tabs

    def send(self, tab, text):
        self.world.changed()

    def split(self, workspace, pane, verb):
        self.world.spaces[workspace]["panes"].append(self.world.pane())
        return self.world.spaces[workspace]["panes"][-1]["id"]

    def add_tab(self, workspace, pane, kind):
        tab = {"id": self.world.ident("tab"), "kind": kind}
        self.tabs(workspace, pane).append(tab)
        self.made.setdefault(pane, []).append((kind, tab["id"], False))

    def action(self, name, params=None, target=None, focus=True):
        ident = (target or ":").split(":")[1]
        self.world.actions.append((name, target))
        if name == "toggleSplitZoom":
            if "zoom-action-dead" in self.world.faults:
                return {"error": "a fake refusal of the zoom action"}
            if "zoom-action-ignored" in self.world.faults:
                return {"ok": True}
            self.world.zoom(ident)
        elif name == "closeWorkspace":
            self.world.spaces.pop(ident, None)
        elif name == "newTab.page":
            next(p for s in self.world.spaces.values() for p in s["panes"] if p["id"] == ident)["tabs"].append({"id": self.world.ident("tab"), "kind": "newtab"})
        elif name == "closeTab":
            for space in self.world.spaces.values():
                for pane in space["panes"]:
                    pane["tabs"][:] = [tab for tab in pane["tabs"] if tab["id"] != ident]
        return {}


class FakeSubprocess:
    """`open`, `ps` and `lsappinfo` of the newest fake launch; no process starts."""
    SubprocessError, TimeoutExpired = subprocess.SubprocessError, subprocess.TimeoutExpired

    @staticmethod
    def run(command, **_):
        world, said = FakeApp.made[-1].world, ""
        if command[0] == "/usr/bin/open":
            world.opens.append(command[1:])
            if "open-timeout" in world.faults:
                raise subprocess.TimeoutExpired(command, 30)
            world.active = "open-activates" in world.faults and not ("second-launch-open-dead" in world.faults and world.index)
            if "open-second-instance" in world.faults:  # a new instance: under launchd, or under another process
                world.pids[200] = 77 if "second-instance-not-of-launchd" in world.faults else 1
        elif command[0] == "/bin/ps":
            world.ps_calls += 1
            if "ps-timeout" in world.faults:
                raise subprocess.TimeoutExpired(command, 10)
            if "ps-fails-first" in world.faults and world.ps_calls == 1:
                return subprocess.CompletedProcess(command, 1, "", "ps: a fake fault")
            # 101: a process that the app started with its own binary (no instance); 300: another app.
            said = "".join(f"{pid} {parent} {BINARY}\n" for pid, parent in world.pids.items()) + f"101 100 {BINARY} --helper\n300 1 /Applications/Other.app/Contents/MacOS/Other\n"
        elif command[:2] == ["/usr/bin/lsappinfo", "front"]:
            said = "ASN:0x0-0x1b01b:\n"
        elif command[0] == "/usr/bin/lsappinfo":
            said = '"LSDisplayName"="Finder"\n' if "name" in command else '"pid"=77\n'
        return subprocess.CompletedProcess(command, 0, said, "")


def kill(pid, sent):
    """The script's `os.kill`: no signal goes to a process; the newest fake launch keeps the call."""
    FakeApp.made[-1].world.signals.append((pid, sent))


class FilmsCase(unittest.TestCase):
    def setUp(self):
        Clock.ticks = itertools.count()
        environment = mock.patch.dict(os.environ)  # the script sets 2 variables of the launcher
        environment.start()
        self.addCleanup(environment.stop)
        for target, name, fake in ((M, "time", Clock), (M, "subprocess", FakeSubprocess), (M.STRESS, "Stress", FakeStress), (M.STRESS, "wait", wait),
                                   (M.bench_launch, "BenchApp", FakeApp), (M.os, "kill", kill)):
            patch = mock.patch.object(target, name, fake)
            patch.start()
            self.addCleanup(patch.stop)

    def run_films(self, faults, *args):
        """`main()` with `faults`: (exit code, films.json, the PREFLIGHT lines, each fake launch)."""
        FakeApp.made, FakeApp.faults = [], set(faults)
        BOUNDS.clear()
        out, said = tempfile.mkdtemp(prefix="pane-films-test-"), io.StringIO()
        self.addCleanup(shutil.rmtree, out, True)
        argv = ["pane-motion-films.py", "--app", BUNDLE, "--out", out, "--workspaces", "0", "--settle", "0", "--dock", "0", *args]
        with mock.patch.object(sys, "argv", argv), contextlib.redirect_stdout(said), contextlib.redirect_stderr(said):
            code = M.main()
        with open(os.path.join(out, "films.json")) as f:
            report = json.load(f)
        return code, report, [line for line in said.getvalue().splitlines() if line.startswith("PREFLIGHT")], list(FakeApp.made)

    @staticmethod
    def forms(launches):
        return ["one-key" if app.launched_env.get("CMUX_NEXT_NO_ACTIVATE") == "1" else "activate" for app in launches]

    def test_an_app_that_its_launch_made_active_gets_no_open(self):
        code, report, lines, launches = self.run_films({"launch-activates"}, "--films", "T-D")
        self.assertEqual((code, self.forms(launches), launches[0].world.opens), (0, ["activate"], []))
        line = "PREFLIGHT activate: by=launch app_active=true key_window=ShellWindow front=Finder (pid 77) instances=1 (pids [100])"
        self.assertIn(line, lines)
        self.assertIn(INSTANCE_100, lines)  # each instance with its parent and its command, in each case
        self.assertEqual(report["launches"][0]["activate"], line)
        self.assertNotIn("forms_not_run", report)
        hosts = [line for line in lines if line.startswith("PREFLIGHT host: macOS ")]
        self.assertEqual(hosts, ["PREFLIGHT host: " + report["host"]])
        self.assertIn(", python ", hosts[0])

    def test_a_host_that_cannot_be_read_is_a_note_and_the_films_are_made(self):
        with mock.patch.object(M.platform, "mac_ver", side_effect=OSError("a fake fault")):
            try:
                code, report, lines, launches = self.run_films({"launch-activates"}, "--films", "T-D")
            except OSError as error:
                self.fail(f"the read of the host ended the run: {error!r}")
        hosts = [line for line in lines if line.startswith("PREFLIGHT host: ")]
        self.assertEqual((code, hosts), (0, ["PREFLIGHT host: " + report["host"]]))
        self.assertTrue(report["host"].startswith("not read"), report["host"])

    def test_one_open_makes_the_app_active_and_the_films_are_of_the_activate_form(self):
        code, report, lines, launches = self.run_films({"open-activates"}, "--films", "T-D,T-Z")
        self.assertEqual((code, self.forms(launches), launches[0].world.opens), (0, ["activate"], [[BUNDLE]]))
        self.assertIn("PREFLIGHT activate: by=open app_active=true key_window=ShellWindow front=Finder (pid 77) instances=1 "
                      "(pids [100]; before the open: [100])", lines)
        self.assertEqual({row["id"]: (row["status"], row["launch_form"]) for row in report["films"]}, {"T-D": ("made", "activate"), "T-Z": ("made", "activate")})
        self.assertEqual((launches[0].world.one_keys, next(row for row in report["films"] if row["id"] == "T-Z")["zoom"]), (0, "key"))
        self.assertEqual((BOUNDS[0], 15 in BOUNDS), (10, True))  # 10 s for the app after the open; 15 s for the split to settle

    def test_the_key_window_word_of_each_key_sequence_is_the_window_that_has_the_keys(self):
        # The fake has the app's design here: after a new tab its page has the keys in its own window, and the app
        # then refuses `shell` (`the shell window did not become key`); it refuses `page` when no page has them.
        code, report, lines, launches = self.run_films({"open-activates", "page-takes-keys"}, "--films", "T-D,P07")
        failed = [line for line in lines if " FAILED: " in line]
        self.assertEqual((code, self.forms(launches), failed), (0, ["activate"], []))
        words = launches[0].world.words
        self.assertEqual([word for word, _ in words], [has for _, has in words])
        # The preflight: a new tab, its close (the page has the keys), a split, the zoom in and out. T-D: Cmd-D.
        # P07: a held Cmd-T, then the closes (a page has the keys).
        self.assertEqual([word for word, _ in words], ["shell", "page", "shell", "shell", "shell", "shell", "shell", "page"])
        self.assertTrue(any(line.startswith("PREFLIGHT close-tab ok: ") and "key_window = page" in line for line in lines))
        rows = {row["id"]: row for row in report["films"]}
        self.assertEqual({ident: (row["status"], row["launch_form"]) for ident, row in rows.items()},
                         {"T-D": ("made", "activate"), "P07": ("made", "activate")})
        self.assertEqual([act.get("key_window") for act in rows["P07"]["acts"]], ["shell", "page"])
        self.assertFalse(any("refused_as" in act for row in rows.values() for act in row["acts"]))
        self.assertEqual(launches[0].world.one_keys, 0)  # no key by the one-key call

    def test_an_open_that_does_not_make_the_app_active_goes_on_in_the_one_key_form(self):
        code, report, lines, launches = self.run_films(set(), "--films", "T-D")
        line = "PREFLIGHT activate: by=none app_active=false key_window=none front=Finder (pid 77) instances=1 (pids [100]; before the open: [100])"
        self.assertEqual((code, self.forms(launches)), (0, ["activate", "one-key"]))
        self.assertEqual([len(app.world.opens) for app in launches], [1, 0])  # ONE open, and none in the one-key form
        self.assertEqual(launches[0].world.sequences, 0)  # no key went to the app that was not active
        self.assertTrue(launches[0].stopped)  # the app of the failed form is ended before the next launch
        self.assertIn(line, lines)
        self.assertIn('PREFLIGHT activate: debug.focus = {"app_active": false, "key_window": null}', lines)  # the whole reply
        self.assertIn(f"PREFLIGHT next form: one-key (the activate form failed: {line})", lines)
        self.assertIn("PREFLIGHT activate: by=not asked app_active=false key_window=none front=Finder (pid 77) instances=1 (pids [100])", lines)
        self.assertEqual(report["forms_not_run"], {"activate": line})
        self.assertEqual([(row["status"], row["launch_form"], row["forms_not_run"]) for row in report["films"]], [("made", "one-key", {"activate": line})])

    def test_the_activate_form_alone_ends_with_exit_1_when_the_open_does_not_make_the_app_active(self):
        code, report, lines, launches = self.run_films(set(), "--films", "T-D", "--launch-form", "activate")
        self.assertEqual((code, self.forms(launches)), (1, ["activate"]))
        self.assertIn("by=none", report["films"][0]["reason"])

    def test_an_open_that_starts_a_second_instance_ends_the_run_with_one_sigterm_to_the_new_instance_only(self):
        code, report, lines, launches = self.run_films({"open-activates", "open-second-instance"}, "--films", "T-D,A-D")
        self.assertEqual((code, self.forms(launches)), (1, ["activate"]))  # no one-key launch, no launch for the other films
        self.assertIn("PREFLIGHT activate: by=open app_active=true key_window=ShellWindow front=Finder (pid 77) instances=2 "
                      "(pids [100, 200]; before the open: [100])", lines)
        self.assertIn(INSTANCE_100, lines)
        self.assertIn(f"PREFLIGHT activate: instance pid 200: parent 1, command {BINARY}", lines)
        sent = f"pid 200 (parent 1, command {BINARY}): SIGTERM sent"
        self.assertIn(f"PREFLIGHT activate: a second instance of the app runs after the open; one SIGTERM to each one that launchd started: {sent}; "
                      "the run ends here", lines)
        self.assertEqual([row["status"] for row in report["films"]], ["not_run", "not_run"])
        for row in report["films"]:
            self.assertIn("instances=2", row["reason"])
            self.assertIn(f"a second instance of the app runs after the open; one SIGTERM to each one that launchd started: {sent}", row["reason"])
        # ONE signal, a SIGTERM, to the pid that was not there before the open; none to the launch's own process.
        self.assertEqual(launches[0].world.signals, [(200, signal.SIGTERM)])
        self.assertTrue(launches[0].stopped)

    def test_no_signal_goes_to_a_process_when_the_open_starts_no_second_instance(self):
        for faults in ({"open-activates"}, set(), {"launch-activates"}):
            code, report, lines, launches = self.run_films(faults, "--films", "T-D")
            self.assertEqual([app.world.signals for app in launches], [[] for _ in launches], faults)

    def test_an_instance_that_ran_before_the_open_gets_no_signal(self):
        faults = {"open-activates", "open-second-instance", "other-instance-before"}
        code, report, lines, launches = self.run_films(faults, "--films", "T-D")
        self.assertEqual((code, self.forms(launches)), (1, ["activate"]))
        self.assertIn("PREFLIGHT activate: by=open app_active=true key_window=ShellWindow front=Finder (pid 77) instances=3 "
                      "(pids [100, 150, 200]; before the open: [100, 150])", lines)
        # 150 has launchd as its parent too, and is not the launch's own process: only the list before the open keeps it.
        self.assertEqual(launches[0].world.signals, [(200, signal.SIGTERM)])

    def test_a_new_instance_that_launchd_did_not_start_ends_the_run_and_gets_no_signal(self):
        faults = {"open-activates", "open-second-instance", "second-instance-not-of-launchd"}
        code, report, lines, launches = self.run_films(faults, "--films", "T-D")
        self.assertEqual((code, launches[0].world.signals), (1, []))
        self.assertTrue(any(f"pid 200 (parent 77, command {BINARY}): SIGTERM not sent (its parent is pid 77, not pid 1)" in line for line in lines))

    def test_no_signal_goes_when_the_list_before_the_open_is_not_proven(self):
        for fault, why, before in (("launched-pid-not-listed", "the launched pid 999 was not in the list before the open", "[100]"),
                                   ("ps-fails-first", "the list before the open was not read", "not read")):
            code, report, lines, launches = self.run_films({"open-activates", "open-second-instance", fault}, "--films", "T-D")
            self.assertEqual((code, launches[0].world.signals), (1, []), fault)
            self.assertTrue(any(f"instances=2 (pids [100, 200]; before the open: {before})" in line for line in lines), fault)
            self.assertTrue(any(f"pid 200 (parent 1, command {BINARY}): SIGTERM not sent ({why})" in line for line in lines), fault)
        self.assertIn("PREFLIGHT activate: ps gave no list of the app's instances: exit 1: ps: a fake fault", lines)

    def test_a_ps_that_gives_no_answer_costs_no_film_in_the_one_key_form(self):
        code, report, lines, launches = self.run_films({"ps-timeout"}, "--films", "T-D", "--launch-form", "one-key")
        self.assertEqual((code, [row["status"] for row in report["films"]]), (0, ["made"]))
        self.assertIn("PREFLIGHT activate: by=not asked app_active=false key_window=none front=Finder (pid 77) instances=not read", lines)
        self.assertTrue(any(line.startswith("PREFLIGHT activate: ps gave no list of the app's instances: ") and "timed out" in line for line in lines))

    def test_a_ps_that_gives_no_answer_ends_no_form_and_sends_no_signal_in_the_activate_form(self):
        code, report, lines, launches = self.run_films({"ps-timeout", "open-activates", "open-second-instance"}, "--films", "T-D")
        self.assertEqual((code, self.forms(launches), launches[0].world.opens), (0, ["activate"], [[BUNDLE]]))
        self.assertIn("PREFLIGHT activate: by=open app_active=true key_window=ShellWindow front=Finder (pid 77) instances=not read "
                      "(before the open: not read)", lines)
        self.assertEqual((launches[0].world.signals, report["films"][0]["launch_form"]), ([], "activate"))

    def test_an_open_that_does_not_run_prints_its_fault_and_the_run_goes_on_in_the_one_key_form(self):
        code, report, lines, launches = self.run_films({"open-timeout", "open-activates"}, "--films", "T-D")
        self.assertEqual((code, self.forms(launches), [row["status"] for row in report["films"]]), (0, ["activate", "one-key"], ["made"]))
        self.assertTrue(any(line.startswith("PREFLIGHT activate: open did not run: ") and "timed out after 30 seconds" in line for line in lines))
        self.assertTrue(any(line.startswith("PREFLIGHT activate: by=none ") for line in lines))

    def test_a_zoom_key_that_changes_nothing_makes_the_zoom_films_by_the_action_and_says_so(self):
        code, report, lines, launches = self.run_films({"zoom-key-dead"}, "--films", "T-D,T-Z", "--launch-form", "one-key")
        rows = {row["id"]: row for row in report["films"]}
        self.assertEqual((code, rows["T-D"]["status"], rows["T-Z"]["status"]), (0, "made", "made"))
        failed = next(line for line in lines if line.startswith("PREFLIGHT zoom FAILED"))
        for words in ("zoomed panes 0 -> 0 in 10 s, not 1", "['window: None']", "TerminalKeyEquivalent: the terminal took the key"):
            self.assertIn(words, failed)
        self.assertEqual(sum(line.startswith("PREFLIGHT zoom ok: zoomed panes") and line.endswith(M.BY_ACTION) for line in lines), 2)
        self.assertTrue(any(line.startswith("PREFLIGHT settle ok: 2 panes") for line in lines))
        self.assertEqual((rows["T-Z"]["zoom"], report["launches"][0]["zoom"]), (M.BY_ACTION, M.BY_ACTION))
        self.assertEqual(rows["T-Z"]["keys"], f"action toggleSplitZoom ({M.BY_ACTION}), action toggleSplitZoom ({M.BY_ACTION})")
        self.assertEqual([act["zoom"] for act in rows["T-Z"]["acts"]], [M.BY_ACTION, M.BY_ACTION])
        self.assertNotIn("zoom", rows["T-D"])
        self.assertEqual(rows["T-D"]["keys"], "Cmd-D")
        zooms = [target for name, target in launches[0].world.actions if name == M.ZOOM_ACTION]
        self.assertEqual(len(zooms), 4)  # 2 of the preflight, 2 of the film, each on a pane by its id
        self.assertTrue(all(target and target.startswith("pane:pane") for target in zooms))
        self.assertEqual(launches[0].world.dry_runs, 0)  # the one-key form has the app's reply to the key itself

    def test_a_key_sequence_that_changes_nothing_gets_one_dry_run_of_the_key(self):
        code, report, lines, launches = self.run_films({"launch-activates", "zoom-key-dead"}, "--films", "T-Z")
        failed = next(line for line in lines if line.startswith("PREFLIGHT zoom FAILED"))
        self.assertIn("a key sequence, scheduled = ", failed)
        self.assertIn('a dry run of the key (the key router\'s decision; nothing runs) = {"decision": "run(fake.return)", "action": "fake.return", '
                      '"focus": "terminal"}', failed)
        self.assertEqual((launches[0].world.dry_runs, launches[0].world.one_keys), (1, 0))  # one read, and no key by the one-key call
        row = report["films"][0]
        self.assertEqual((code, row["status"], row["launch_form"], row["zoom"]), (0, "made", "activate", M.BY_ACTION))

    def test_a_key_that_the_app_refuses_keeps_what_the_app_said_of_it(self):
        code, report, lines, launches = self.run_films({"zoom-key-refused"}, "--films", "T-Z", "--launch-form", "one-key")
        failed = next(line for line in lines if line.startswith("PREFLIGHT zoom FAILED"))
        for words in ("the app did not run toggleSplitZoom", "['app: toggleSplitZoom']", "KeyRouter: the action is not available"):
            self.assertIn(words, failed)
        self.assertEqual((code, report["films"][0]["status"], report["films"][0]["zoom"]), (0, "made", M.BY_ACTION))

    def test_a_zoom_that_no_path_makes_leaves_only_the_zoom_films_not_run(self):
        code, report, lines, launches = self.run_films({"zoom-key-dead", "zoom-action-dead"}, "--films", "T-D,T-SD,T-Z", "--launch-form", "one-key")
        rows = {row["id"]: row for row in report["films"]}
        self.assertEqual((code, [rows[i]["status"] for i in ("T-D", "T-SD", "T-Z")]), (2, ["made", "made", "not_run"]))
        self.assertIn("by the key and by action.run", rows["T-Z"]["reason"])
        self.assertIn("a fake refusal of the zoom action", rows["T-Z"]["reason"])
        self.assertTrue(rows["T-Z"]["zoom"].startswith("none: zoom: by action.run also"))
        self.assertTrue(any(line.startswith("PREFLIGHT passed:") and "zoom = none" in line for line in lines))

    def test_a_zoom_action_that_changes_nothing_with_no_error_says_its_reply(self):
        code, report, lines, launches = self.run_films({"zoom-key-dead", "zoom-action-ignored"}, "--films", "T-D,T-Z", "--launch-form", "one-key")
        rows = {row["id"]: row for row in report["films"]}
        self.assertEqual((code, rows["T-D"]["status"], rows["T-Z"]["status"]), (2, "made", "not_run"))
        self.assertIn('by action.run also: zoomed panes 0 -> 0 in 10 s, not 1; the action\'s reply = {"ok": true}', rows["T-Z"]["reason"])

    def test_a_zoom_key_that_works_stays_the_key(self):
        code, report, lines, launches = self.run_films(set(), "--films", "T-Z", "--launch-form", "one-key")
        row = report["films"][0]
        self.assertEqual((code, row["status"], row["zoom"], row["keys"]), (0, "made", "key", "Cmd-Shift-Enter, Cmd-Shift-Enter"))
        self.assertEqual([name for name, _ in launches[0].world.actions if name == M.ZOOM_ACTION], [])
        self.assertTrue(any(line.startswith("PREFLIGHT zoom ok: zoomed panes 0 -> 1; the app's reply to each key") for line in lines))

    def test_the_zoom_key_goes_only_after_the_split_is_settled(self):
        code, report, lines, launches = self.run_films({"split-settles-late"}, "--films", "T-Z", "--launch-form", "one-key")
        self.assertEqual((code, report["films"][0]["status"]), (0, "made"))
        # The fake has the new pane's tab as a stand-in for the first reads after the split: no zoom key went then.
        self.assertEqual(launches[0].world.zoom_keys_at_a_pending_tab, [False, False, False, False])  # 2 of the preflight, 2 of the film
        settle = next(index for index, line in enumerate(lines) if line.startswith("PREFLIGHT settle ok: 2 panes"))
        self.assertLess(settle, next(index for index, line in enumerate(lines) if line.startswith("PREFLIGHT zoom")))

    def test_a_split_that_does_not_settle_says_the_panes_and_their_tabs_and_ends_nothing(self):
        code, report, lines, launches = self.run_films({"split-never-settles"}, "--films", "T-Z", "--launch-form", "one-key")
        late = next(line for line in lines if line.startswith("PREFLIGHT settle not reached in 15 s (the zoom key is sent now): 2 panes"))
        self.assertIn("the panes and their tabs = [('pane2', ['tab3']), ('pane5', ['pending_tab_tab6'])]", late)
        self.assertEqual((code, report["films"][0]["status"], report["films"][0]["zoom"]), (0, "made", "key"))

    def test_a_film_of_the_activate_form_does_not_say_that_the_form_was_not_run(self):
        # 2 launches (the page mock off, then on): the open makes the first one active, and not the second one.
        code, report, lines, launches = self.run_films({"open-activates", "second-launch-open-dead"}, "--films", "T-D,A-D")
        rows = {row["id"]: row for row in report["films"]}
        self.assertEqual((code, self.forms(launches)), (0, ["activate", "activate", "one-key"]))
        self.assertEqual((rows["T-D"]["launch_form"], rows["A-D"]["launch_form"]), ("activate", "one-key"))
        self.assertNotIn("forms_not_run", rows["T-D"])
        self.assertEqual(list(rows["A-D"]["forms_not_run"]), ["activate"])

    def test_a_film_with_a_speed_sets_it_before_its_set_up_and_its_row_has_the_app_s_word_and_spans(self):
        code, report, lines, launches = self.run_films({"launch-activates"}, "--films", "T-Z.N")
        row, world = report["films"][0], launches[0].world
        self.assertEqual((code, row["status"], row["speed"], row["speed_after"]), (0, "made", "normal", "fast"))
        # The speed call when no workspace of the film is there yet; the speed of before while its workspace still is.
        self.assertEqual(world.speeds, [("normal", 0), ("fast", 1)])
        # The 2 spans that the fake app recorded between `start` and `stop` (not those of the preflight's zooms).
        self.assertEqual(row["spans"], [{"name": "fake.zoom", "ms": 294, "at_ms": 1}, {"name": "fake.zoom", "ms": 294, "at_ms": 2}])
        self.assertEqual(row["source_ms"], {"zoom": "294 ms", "unzoom": "about 266 ms (by arithmetic: the source gives no number)"})

    def test_an_app_that_gives_back_another_speed_gets_no_film_at_that_speed(self):
        code, report, lines, launches = self.run_films({"launch-activates", "speed-ignored"}, "--films", "T-Z.2,T-Z.N")
        rows = {row["id"]: row for row in report["films"]}
        self.assertEqual((code, rows["T-Z.2"]["status"], rows["T-Z.2"]["speed"], rows["T-Z.N"]["status"]), (2, "made", "fast", "not_run"))
        self.assertEqual(rows["T-Z.N"]["reason"], "the app did not take the animation speed `normal`: its reply says `fast`")
        self.assertNotIn("spans", rows["T-Z.N"])
        self.assertEqual(launches[0].world.speeds[-2:], [("normal", 0), ("fast", 0)])  # no workspace was made for that film

    def test_the_turned_zoom_is_one_sequence_of_2_zoom_keys_with_the_gap_of_its_speed(self):
        code, report, lines, launches = self.run_films({"launch-activates"}, "--films", "T-ZT,T-ZT.N")
        world, gaps = launches[0].world, []
        for steps in world.played:
            at, downs = 0, []
            for step in steps:
                at += step.get("after_ms", 0)
                if step["down"] and CODE[step["key_code"]] == "return":
                    downs.append(at)
            if len(downs) == 2:
                gaps.append(downs[1] - downs[0])
        self.assertEqual((code, gaps), (0, [118, 147]))  # the half of 235 ms and of 294 ms, from key-down to key-down
        self.assertEqual([bool(pane) for pane in world.zoom_states[-4:]], [True, False, True, False])  # no pane stays zoomed
        self.assertEqual([(row["id"], row["status"], row["launch_form"], row["zoom"], row["keys"], len(row["acts"]), row["speed"]) for row in report["films"]],
                         [("T-ZT", "made", "activate", "key", "Cmd-Shift-Enter x2", 1, "fast"),
                          ("T-ZT.N", "made", "activate", "key", "Cmd-Shift-Enter x2", 1, "normal")])
        self.assertEqual(world.speeds, [("fast", 0), ("fast", 1), ("normal", 0), ("fast", 1)])

    def test_the_turned_zoom_of_the_one_key_form_says_the_time_of_each_key_down(self):
        code, report, lines, launches = self.run_films(set(), "--films", "T-ZT", "--launch-form", "one-key")
        row = report["films"][0]
        times = row["acts"][0]["key_down_ms"]
        self.assertEqual((code, row["status"], row["launch_form"], len(times), times == sorted(times)), (0, "made", "one-key", 2, True))
        self.assertEqual([bool(pane) for pane in launches[0].world.zoom_states[-2:]], [True, False])

    def test_the_turned_zoom_is_not_run_when_the_zoom_is_made_by_the_action(self):
        code, report, lines, launches = self.run_films({"zoom-key-dead"}, "--films", "T-Z.2,T-ZT", "--launch-form", "one-key")
        rows = {row["id"]: row for row in report["films"]}
        self.assertEqual((code, rows["T-Z.2"]["status"], rows["T-Z.2"]["zoom"], rows["T-ZT"]["status"]), (2, "made", M.BY_ACTION, "not_run"))
        self.assertIn("the turned zoom is 2 zoom keys with a gap, and this launch makes a zoom by the action, not by a key", rows["T-ZT"]["reason"])
        self.assertNotIn("speed", rows["T-ZT"])  # no speed call for a film that is not run for its zoom

    def test_the_split_and_close_film_says_the_tab_kinds_of_the_pane_that_the_close_takes(self):
        code, report, lines, launches = self.run_films({"launch-activates"}, "--films", "T-C")
        row = report["films"][0]
        self.assertEqual((code, row["status"], row["panes"], row["panes_before"], row["panes_after"]), (0, "made", ["redraw", "stream", "shell"], 3, 3))
        self.assertEqual((row["keys"], [act["label"] for act in row["acts"]]), ("Cmd-D, Cmd-W", ["Cmd-D", "read: the tabs of the pane with the focus", "Cmd-W"]))
        self.assertEqual(row["acts"][1]["tab_kinds"], ["terminal"])  # the fake's new pane has a terminal; the app's own word is in a real row
        self.assertEqual((row["speed"], row["source_ms"]), ("fast", {"split": "101 ms", "paneClose": "75 ms"}))

    def test_the_group_cap_is_the_6_films_with_a_speed_and_the_group_kinds_stays_the_9(self):
        ids = [spec["id"] for spec in M.FILMS]
        self.assertEqual([i for i in ids if M.GROUPS["cap"](i)], ["T-C", "T-Z.2", "T-ZT", "T-C.N", "T-Z.N", "T-ZT.N"])
        self.assertEqual({spec["id"]: spec["speed"] for spec in M.FILMS if spec.get("speed")},
                         {"T-C": "fast", "T-Z.2": "fast", "T-ZT": "fast", "T-C.N": "normal", "T-Z.N": "normal", "T-ZT.N": "normal"})
        self.assertEqual([i for i in ids if M.GROUPS["kinds"](i)], [f"{kind}-{act}" for kind in "TBA" for act in ("D", "SD", "Z")])
        self.assertEqual(len(ids), len(set(ids)))
        said = io.StringIO()
        with mock.patch.object(sys, "argv", ["pane-motion-films.py", "--films", "list"]), contextlib.redirect_stdout(said):
            self.assertEqual(M.main(), 0)
        listed = {line.split("\t")[0]: line.split("\t")[2] for line in said.getvalue().splitlines()}
        self.assertEqual((listed["T-C.N"], listed["T-Z.2"], listed["T-ZT.N"]), ("Cmd-D, Cmd-W", "Cmd-Shift-Enter, Cmd-Shift-Enter", "Cmd-Shift-Enter x2"))

    def test_a_film_with_no_speed_sends_no_speed_call_and_its_row_is_as_it_was(self):
        code, report, lines, launches = self.run_films({"launch-activates"}, "--films", "kinds,P06")
        self.assertEqual((code, [row["status"] for row in report["films"]], self.forms(launches)), (0, ["made"] * 10, ["activate", "activate"]))
        self.assertEqual([app.world.speeds for app in launches], [[], []])
        self.assertFalse([key for row in report["films"] for key in ("speed", "speed_after", "spans", "source_ms") if key in row])
        held = next(row for row in report["films"] if row["id"] == "P06")["acts"][0]
        self.assertEqual((held["label"], held["key_window"], "key_down_ms" in held), ("Cmd-T held 3 s", "shell", False))

    def test_the_instances_are_the_processes_of_the_binary_that_no_other_one_started(self):
        FakeApp.made, FakeApp.faults = [], set()
        world = FakeApp(BUNDLE).launch().world
        self.assertEqual(M.instances(BINARY), {100: (50, BINARY)})  # not 101 (a child of 100), not 300 (another app)
        world.pids[200] = 1
        self.assertEqual(M.instances(BINARY), {100: (50, BINARY), 200: (1, BINARY)})

    def test_the_label_of_a_zoom_act_says_what_makes_it(self):
        act = M.K(M.ZOOM_CHORD)
        self.assertEqual((M.label(act), M.label(act, "key")), ("Cmd-Shift-Enter", "Cmd-Shift-Enter"))
        self.assertEqual(M.label(act, M.BY_ACTION), "action toggleSplitZoom (zoom by action.run, not by a key)")
        self.assertEqual(M.label(M.K("cmd+d"), M.BY_ACTION), "Cmd-D")


if __name__ == "__main__":
    unittest.main()
