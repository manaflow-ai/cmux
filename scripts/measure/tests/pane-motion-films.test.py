#!/usr/bin/env python3
"""scripts/measure/pane-motion-films.py: what makes the app active, and what makes a zoom, in each case.

The launcher starts the app's binary directly, and on a display Mac that process did not become the active app:
the `activate` launch form had no key window, and the zoom key changed nothing in the `one-key` form. The script now
asks LaunchServices one time (`open BUNDLE`), says what made the app active in a `PREFLIGHT activate:` line, ends the
run (with one SIGTERM to the new instance only) if that open started a second instance, and makes a zoom by
`action.run` when the zoom key changes nothing, with those words in the film's row.

No app, no socket, no build: `main()` runs with the launcher (`BenchApp`), the session helper (`Stress`) and
`subprocess`, `os.kill` and the clock replaced by fakes with a small model of tabs, panes, zoom and the app's active
state (no signal goes to a process, and no test reads a real clock). The fake's key window, its refusals, its
animation speed and its span record are a model from a read of the app's code. So this proves the
script's own logic (names, flow, rows, exit codes), NOT the app and NOT what LaunchServices does on a Mac.
The fake's dialogs, overlays, messages and refusal list (`debug.dialog`, `debug.focus`, `debug.toast`) are such a model
too: no test here says what the app shows over its window, or when it asks before a close.
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
NO_PAGE_WINDOW = "page: no Chromium page window for pane"  # a refused `page` word, as a row and a PREFLIGHT line say it
# The end of a PREFLIGHT line of a key that had 3 sends: `page` refused 2 times, then the shell window.
THIRD_TRY = f"; the third try, in the shell window, after the app refused the word 2 times ({NO_PAGE_WINDOW}; {NO_PAGE_WINDOW})"
# Each field that only the row of a film with a speed has.
SPEED_KEYS = ("speed", "speed_before", "speed_after", "speed_at_stop", "speed_fault", "spans", "spans_total", "spans_cut", "source_ms",
              "reduce_motion", "animations_enabled", "pane_animations", "disabled_categories")
# The key sequences of a preflight that passes: a new tab, its close, a split, the zoom in, the zoom out. A fault
# `...-in-a-film` starts after them.
PREFLIGHT_KEYS = 5
NO_ROOM = "Not enough room to split this column"  # the app's refusal of a split, by a read of its source (RefusalStrings.swift)
ASKED = 'Close "/sbin/ping -i 0.2 127.0.0.1"?: Still running: ping.'  # the title and the line of the fake's close question


class Clock:
    """The script's `time`: a counter (1 ms for each read) and no sleep. No test reads a real clock."""
    ticks = itertools.count()
    monotonic = time = staticmethod(lambda: next(Clock.ticks) / 1000)

    @staticmethod
    def sleep(seconds):
        pass


BOUNDS = []
WAITING = []  # not empty while the fake `wait` makes its reads


def wait(test, seconds, step=0.25):
    """The session helper's `wait` for a fake that changes in the call itself: 3 reads, no sleep. It keeps the bound
    that the script gave it. As the helper's own `wait` (perf-stress-session.py), a read that raises is `no value`."""
    BOUNDS.append(seconds)
    WAITING.append(seconds)
    try:
        for _ in range(3):
            try:
                value = test()
            except Exception:  # noqa: BLE001  the helper's `wait` takes each fault of a read as `no value yet`
                value = None
            if value:
                return value
        return None
    finally:
        WAITING.pop()


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
        # Each `debug.motion` call for the speed or the span record, by its action; if the span record runs.
        self.motion, self.tracing = [], False
        # After a Cmd-T the app moves the keys to the new page, and that takes time (FocusEffectApplier.swift). `held`
        # (fault `keys-move-late`): the next focus read still says `shell`, and the page takes the keys after it.
        # `unplaced` (faults `page-window-late`, `page-window-never`): the page has the focus, and its window is not
        # yet in its place over the pane, so the app finds no page window for the next `page` sequence.
        self.held, self.unplaced = False, False
        self.targets = []  # the `target` of each call of the one-key form
        # What is over the app's window, as the app's 3 debug reads give it (DebugDialog.swift, DebugFocus.swift,
        # DebugToast.swift): the dialogs, the overlays of the window's focus model, the messages on the screen, and
        # each refusal message so far. `dismissals`: each `dismiss` call of `debug.dialog`. A message goes by itself:
        # the fake shows it in 2 replies of `debug.toast` (with the fault `message-stays`: in each reply).
        self.dialogs = [{"id": 1, "title": "A question", "lines": ["of another act"], "visible": True}] if "dialog-open" in faults else []
        self.overlays, self.toasts, self.refusals, self.dismissals = ["palette"] if "overlay-open" in faults else [], [], [], []
        # `layout-dead-from-the-take`: each layout read fails from the end of the check before a take (its last read
        # is `debug.toast`).
        self.layout_dead = False

    def film(self, state):
        """If the recorder of a FILM (not of the preflight) is in `state` now: `capturing` or `written`."""
        return bool(self.record and self.record.get("film") and self.record[state])

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

    def moved(self, ms):
        """One pane motion in the app's span record: one span with the name `layout`."""
        if "no-layout-spans" not in self.faults:
            self.spans.append({"name": "layout", "ms": ms, "at_ms": len(self.spans) + 1, "more": "not for the row"})

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

    def zoom(self, pane, turned=False):
        """The app's span record by a read of its code (DisplayLinkDriver.swift, MotionTrace.swift): each pane motion
        is one span with the name `layout`, and a motion that is turned before its rest stays ONE span."""
        space = self.spaces[self.shown]
        space["zoomed"] = None if space["zoomed"] else pane
        self.zoom_states.append(space["zoomed"])
        if not (turned and self.spans):
            self.moved(M.ZOOM_MS[self.speed])
        self.changed()

    def key(self, name, turned=False):
        space = self.spaces[self.shown]
        pane = next(p for p in space["panes"] if p["id"] == self.focus)
        if name in "tw" and "tab-keys-dead-in-a-film" in self.faults and self.sequences > PREFLIGHT_KEYS:
            pass  # the app takes the key of a film, and no tab is made or closed
        elif name == "t":
            pane["tabs"].append({"id": self.ident("tab"), "kind": "newtab"})
            self.held = "keys-move-late" in self.faults
            self.unplaced = bool(self.faults & {"page-window-late", "page-window-never"}) or (
                "page-window-never-in-a-film" in self.faults and self.sequences > PREFLIGHT_KEYS)
        elif name == "w":
            program = pane["tabs"][-1].get("program")
            if program:  # the app asks before it closes a terminal with a foreground program, and closes nothing (TabCloseGuard.swift)
                self.dialogs.append({"id": len(self.dialogs) + 1, "title": f'Close "{program}"?', "visible": True,
                                     "lines": [f"Still running: {os.path.basename(program.split()[0])}."]})
                self.changed()  # the question shows: the fake's recorder has frames only for a change of the screen
                return True
            pane["tabs"].pop()
            if not pane["tabs"] and len(space["panes"]) > 1:  # the close of a pane's last tab closes the pane
                at = space["panes"].index(pane)
                space["panes"].remove(pane)
                self.focus = space["panes"][max(at - 1, 0)]["id"]
                self.moved(75)
        elif name == "d":
            if "room-for-3" in self.faults and len(space["panes"]) >= 3:  # no room: the app refuses the split with a message
                self.refusals.append(NO_ROOM)
                self.toasts.append({"id": "refusal", "message": NO_ROOM, "replies_left": 2})
                self.changed()  # the message shows
                return True
            space["panes"].append(self.pane())
            self.moved(101)
            if "split-keeps-focus" not in self.faults:  # the fault: the focus stays in the pane that had it
                self.focus = space["panes"][-1]["id"]
            if self.faults & {"split-settles-late", "split-never-settles"}:  # the app's stand-in for the new tab
                tab = space["panes"][-1]["tabs"][0]
                tab["id"], self.pending = "pending_tab_" + tab["id"], 4
        elif name == "p":  # for a test: a key that opens the app's palette, an overlay of the window
            self.overlays.append("palette")
        elif name == "return":
            self.zoom_keys_at_a_pending_tab.append(any(tab["id"].startswith("pending_tab_") for p in space["panes"] for tab in p["tabs"]))
            if "zoom-key-dead" in self.faults:
                return False
            if "zoom-key-refused" in self.faults:
                return "refused"
            if "zoom-dead-in-a-film" in self.faults and self.sequences > PREFLIGHT_KEYS:
                self.changed()  # the programs of the panes draw
                return True  # the app takes the key of a film, and no pane is zoomed
            if "second-zoom-key-dead" in self.faults and self.sequences > PREFLIGHT_KEYS and space["zoomed"]:
                self.changed()
                return True  # the app takes the second zoom key of a film, and the pane stays zoomed
            return self.zoom(self.focus, turned) or True
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
        # `focus-read-fails`: the read before the preflight's close of a tab, and each read while a film with a speed runs.
        if method == "debug.focus" and "focus-read-fails" in world.faults and (world.tracing or world.sequences == 1):
            return {"error": "a fake fault of the focus read"}  # as the socket call gives a read that failed
        if method == "debug.focus":
            page = None if world.held else world.page()  # `held`: this read is before the page takes the keys
            world.held = False
            said = {"app_active": world.active, "key_window": ("CefNSWindow" if page else "ShellWindow") if world.active else None}
            window = {"id": "window1", "model": {"overlays": list(world.overlays)}}
            if "page-takes-keys" in world.faults:  # the part of the app's reply that says which window has the keys
                window.update(is_key=world.active and not page, appkit={"child_window_page": page})
            return {**said, "windows": [window]}
        if method == "debug.dialog":
            if "no-overlay-reads" in world.faults:  # an older app: the command gives no list
                return {}
            if "dialog-read-fails-after-the-acts" in world.faults and world.film("written"):
                return {"error": "a fake fault of the dialog read"}  # as the socket call gives a read that failed
            said = {}
            if params.get("dismiss"):  # the app's Cancel of the dialog `id`
                world.dismissals.append(params.get("id"))
                found = next((d for d in world.dialogs if d["id"] == params.get("id") and d["visible"]), None)
                said["dismissed"] = bool(found) and "dismiss-fails" not in world.faults
                if said["dismissed"]:
                    found["visible"] = False
            return {**said, "dialogs": [dict(dialog) for dialog in world.dialogs]}
        if method == "debug.toast":
            if "message-read-fails-in-the-wait" in world.faults and WAITING:
                return {"error": "a fake fault of the message read"}
            world.layout_dead = "layout-dead-from-the-take" in world.faults
            shown = [{"id": toast["id"], "message": toast["message"]} for toast in world.toasts]
            for toast in world.toasts:
                toast["replies_left"] -= "message-stays" not in world.faults
            world.toasts[:] = [toast for toast in world.toasts if toast["replies_left"] > 0]
            return {"windows": [{"window": "window1", "toasts": shown}], "refusals": list(world.refusals)}
        if method == "debug.frames":
            return {} if params.get("action") == "start" else {"frames": 120, "p50_ms": 8.33, "refresh_ms": 8.33}
        if method == "debug.window_frame":
            return {"frame": params.get("frame") or [100, 100, 1100, 720], "visible_frame": [0, 0, 1920, 1175], "screen_frame": [0, 0, 1920, 1200]}
        if method == "debug.motion" and params.get("action") in ("speed", "read", "start", "stop"):
            action = params["action"]
            world.motion.append(action)
            if action == "start" and "start-raises" in world.faults:
                raise RuntimeError("a fake fault of the start call")
            if action == "speed":
                world.speeds.append((params.get("value"), len(world.spaces)))
                # The faults: an app that keeps its speed; an app that does not go back from `normal`.
                if "speed-ignored" not in world.faults and not ("speed-stays-normal" in world.faults and world.speed == "normal"):
                    world.speed = params.get("value")
            if action == "start":  # `many-spans`: 75 spans of another animator are in the record too
                world.spans = [{"name": "tabstrip", "ms": 90.0, "at_ms": 0.5} for _ in range(75 if "many-spans" in world.faults else 0)]
            world.tracing = action == "start" or (world.tracing and action != "stop")
            said = {"recording": world.tracing, "speed": world.speed, "reduce_motion": "reduce-motion" in world.faults,
                    "animations_enabled": "animations-off" not in world.faults, "pane_animations": "pane-animations-off" not in world.faults,
                    "disabled_categories": ["panes"] if "panes-category-off" in world.faults else [], "spans": list(world.spans)}
            if "older-app" in world.faults:  # an app whose reply does not say if a pane motion animates
                for name in ("reduce_motion", "animations_enabled", "pane_animations", "disabled_categories"):
                    del said[name]
            if action == "read" and "speed-not-read" in world.faults:  # the fault: a reply with no speed word
                del said["speed"]
            if action == "stop" and "no-span-list" in world.faults:  # the fault: a span record with no list
                del said["spans"]
            return said
        if method == "debug.motion":
            if params.get("action") == "record_start":
                path = params.get("path") or ""
                world.record = {"capturing": True, "written": False, "complete": 0, "frames": 0, "path": path,
                                "film": not path.endswith("preflight.mov")}
                return {"width": 1880, "height": 1135}
            if params.get("action") == "record_stop" and world.record:
                world.record.update(capturing=False, written=True, frames=world.record["complete"], first_t=1.0, last_t=6.0, movie_status="completed")
                # The recorder's 2 files, as the app writes them: the movie, and the frame file beside it.
                for name in filter(None, (world.record["path"], world.record["path"] and world.record["path"] + ".frames.json")):
                    with open(name, "w") as f:
                        f.write("{}")
            return dict(world.record or {})
        if method == "debug.key" and "sequence" in params:
            wanted, page = params.get("key_window"), world.page()
            if world.active:
                world.words.append((wanted, "page" if page else "shell"))
            if "film-key-refused" in world.faults and world.tracing:  # the fault: a refusal of each key of a film with a speed
                return {"error": "a fake refusal of a key in the film"}
            # The app's own words for a window that cannot become key: no window of an app that is not active, and
            # not the shell window while a page has the keys (the app gives them back to the page).
            # `page-with-no-window`: the focus says a page, the app finds no page window for it at each call (a tab
            # that is no Chromium child window), and the shell window keeps the keys.
            no_window = "page-with-no-window" in world.faults
            if not world.active or (wanted == "shell" and page and not no_window):
                return {"error": f"the {wanted} window did not become key"}
            if wanted == "page" and "page-takes-keys" in world.faults and (not page or world.unplaced or no_window):
                # `page-window-late`: the window is in its place after this call
                world.unplaced = bool(world.faults & {"page-window-never", "page-window-never-in-a-film"})
                return {"error": "no Chromium page window for pane"}
            world.sequences += 1
            world.played.append(params["sequence"])
            at, zoom_at = 0, None
            for step in params["sequence"]:
                at += step.get("after_ms", 0)
                name = CODE[step["key_code"]]
                if step["down"] and name not in M.MODIFIERS:
                    # A second zoom key before the visible end of the first one turns that motion.
                    turned = name == "return" and zoom_at is not None and at - zoom_at < M.ZOOM_MS[world.speed]
                    zoom_at = at if name == "return" else zoom_at
                    world.key(name, turned)
            if wanted == "page" and "page-send-times-out" in world.faults and world.sequences > PREFLIGHT_KEYS:
                return {"error": "timed out"}  # the app TOOK the keys of a film; the reply did not come (the socket call's words)
            return {"base_s": 12.5, "duration_ms": 30, "scheduled": len(params["sequence"]), "key_window": params.get("key_window")}
        if method == "debug.key" and params.get("dry_run"):
            world.dry_runs += 1
            return {"decision": f"run(fake.{params['key']})", "action": "fake." + params["key"], "focus": "terminal"}
        if method == "debug.key":
            world.one_keys += 1
            world.targets.append(params.get("target"))
            if params.get("target") == "page" and "page-refuses-one-key" in world.faults:
                return {"error": "no Chromium page window for pane"}  # the app's refusal, before a dispatch of the key
            took = world.key(params["key"])
            if params.get("target") == "page" and "page-send-times-out" in world.faults:
                return {"error": "timed out"}  # the app TOOK the key; the reply did not come
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
        world = self.world
        if (world.layout_dead or ("layout-read-fails-in-the-take" in world.faults and world.film("capturing"))
                or ("layout-read-fails-after-the-acts" in world.faults and world.film("written"))):
            return None  # as the helper gives a layout read that failed
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
        if "tab-read-fails-after-the-acts" in self.world.faults and self.world.film("written"):
            return []  # as the helper gives a tab read that failed
        return next(p["tabs"] for p in self.world.spaces[workspace]["panes"] if p["id"] == pane)

    settled_tabs = tabs

    def send(self, tab, text):
        for found in (t for space in self.world.spaces.values() for pane in space["panes"] for t in pane["tabs"] if t["id"] == tab):
            found["program"] = text.strip()  # the terminal now has a foreground program
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
        self.out = out  # the folder of the run's files, for a test of their names
        self.addCleanup(shutil.rmtree, out, True)
        argv = ["pane-motion-films.py", "--app", BUNDLE, "--out", out, "--workspaces", "0", "--settle", "0", "--dock", "0", *args]
        with mock.patch.object(sys, "argv", argv), contextlib.redirect_stdout(said), contextlib.redirect_stderr(said):
            code = M.main()
        with open(os.path.join(out, "films.json")) as f:
            report = json.load(f)
        self.printed = said.getvalue().splitlines()  # each line of the run, for a test of a line that is no PREFLIGHT line
        return code, report, [line for line in self.printed if line.startswith("PREFLIGHT")], list(FakeApp.made)

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
        self.assertIn('PREFLIGHT activate: debug.focus = {"app_active": false, "key_window": null, "windows": [{"id": "window1", '
                      '"model": {"overlays": []}}]}', lines)  # the whole reply
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
        self.assertEqual(row["spans"], [{"name": "layout", "ms": 294, "at_ms": 1}, {"name": "layout", "ms": 294, "at_ms": 2}])
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
        # A row of 2: in a run on a Mac, a row of 3 with the docked column took no fourth pane.
        self.assertEqual((code, row["status"], row["panes"], row["panes_before"], row["panes_after"]), (0, "made", ["redraw", "stream"], 2, 2))
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

    def test_a_film_with_no_speed_sends_no_speed_call_and_its_row_has_no_field_of_a_speed(self):
        code, report, lines, launches = self.run_films({"launch-activates"}, "--films", "kinds,P06")
        self.assertEqual((code, [row["status"] for row in report["films"]], self.forms(launches)), (0, ["made"] * 10, ["activate", "activate"]))
        self.assertEqual([app.world.speeds for app in launches], [[], []])
        self.assertEqual([app.world.motion for app in launches], [[], []])
        self.assertFalse([key for row in report["films"] for key in SPEED_KEYS if key in row])
        held = next(row for row in report["films"] if row["id"] == "P06")["acts"][0]
        self.assertEqual((held["label"], held["key_window"], "key_down_ms" in held), ("Cmd-T held 3 s", "shell", False))

    def test_a_key_window_word_that_the_app_refuses_gets_one_new_read_and_one_more_send(self):
        # Directly after a Cmd-T the app moves the keys to the new page. The read and the key are 2 calls, so:
        # (1) the read still says `shell`, and the page then takes the keys; (2) the read says `page`, and the page's
        # window is not yet in its place. In each case: ONE new read and ONE more send, with the first refusal kept.
        cases = (("keys-move-late", "shell", "shell: the shell window did not become key"),
                 ("page-window-late", "page", "page: no Chromium page window for pane"))
        for fault, first, refusal in cases:
            code, report, lines, launches = self.run_films({"open-activates", "page-takes-keys", fault}, "--films", "P07")
            failed = [line for line in lines if " FAILED: " in line]
            self.assertEqual((code, self.forms(launches), failed), (0, ["activate"], []), fault)
            calm, again = [("shell", "shell")], [(first, "page"), ("page", "page")]  # again: the refused send, then the ONE more
            # The preflight: a new tab, its close, a split, the zoom in and out. P07: a held Cmd-T, then the closes.
            self.assertEqual(launches[0].world.words, calm + again + calm * 4 + again, fault)
            passed = next(line for line in lines if line.startswith("PREFLIGHT close-tab ok: "))
            self.assertIn("key_window = page", passed, fault)
            self.assertTrue(passed.endswith(f"; the second try, after the app refused the first one ({refusal})"), passed)
            close = report["films"][0]["acts"][1]
            self.assertEqual((report["films"][0]["status"], close["label"], close.get("refused_as"), close.get("key_window"), "error" in close),
                             ("made", "Cmd-W x5", [refusal], "page", False), fault)
            self.assertEqual(launches[0].world.one_keys, 0, fault)  # no key by the one-key call

    def test_a_page_word_that_the_app_refuses_2_times_gets_one_last_send_in_the_shell_window_and_no_fourth(self):
        code, report, lines, launches = self.run_films({"open-activates", "page-takes-keys", "page-window-never"}, "--films", "T-D")
        self.assertEqual((code, self.forms(launches)), (0, ["activate", "one-key"]))
        # The new tab; then the close: `page` refused 2 times, ONE last send in the shell window (refused: the page
        # has the keys), and the launch ends.
        self.assertEqual(launches[0].world.words, [("shell", "shell"), ("page", "page"), ("page", "page"), ("shell", "page")])
        failed = next(line for line in lines if line.startswith("PREFLIGHT close-tab FAILED: "))
        self.assertTrue(failed.startswith("PREFLIGHT close-tab FAILED: the shell window did not become key; "), failed)
        self.assertIn(THIRD_TRY, failed)

    def test_a_tab_whose_page_window_the_app_does_not_find_gets_its_keys_in_the_shell_window(self):
        # The focus says a page; the app finds no page window for it (a tab that is no Chromium child window), and
        # the shell window keeps the keys. `page` is refused 2 times; the ONE last send, as `shell`, is taken.
        code, report, lines, launches = self.run_films({"open-activates", "page-takes-keys", "page-with-no-window"}, "--films", "P07")
        self.assertEqual((code, self.forms(launches), [line for line in lines if " FAILED: " in line]), (0, ["activate"], []))
        third = ["page", "page", "shell"]
        # The preflight: a new tab, its close, a split, the zoom in and out. P07: a held Cmd-T, then the closes.
        self.assertEqual([word for word, _ in launches[0].world.words], ["shell"] + third + ["shell"] * 4 + third)
        passed = next(line for line in lines if line.startswith("PREFLIGHT close-tab ok: "))
        self.assertTrue(passed.endswith(THIRD_TRY), passed)
        close = report["films"][0]["acts"][1]
        self.assertEqual((report["films"][0]["status"], close["label"], close.get("refused_as"), close.get("key_window"), "error" in close),
                         ("made", "Cmd-W x5", [NO_PAGE_WINDOW] * 2, "shell", False))

    def test_an_act_of_a_film_that_the_app_refuses_at_each_send_has_3_sends_and_the_film_is_not_run(self):
        code, report, lines, launches = self.run_films({"open-activates", "page-takes-keys", "page-window-never-in-a-film"}, "--films", "P07")
        row, world = report["films"][0], launches[0].world
        self.assertEqual((self.forms(launches), [line for line in lines if " FAILED: " in line]), (["activate"], []))
        # After the preflight's 5 sends: the held Cmd-T, then the closes: `page`, `page`, `shell`, and no fourth send.
        self.assertEqual(world.words[PREFLIGHT_KEYS:], [("shell", "shell"), ("page", "page"), ("page", "page"), ("shell", "page")])
        self.assertEqual((code, row["status"], row["reason"]), (1, "not_run", "the app refused Cmd-W x5: the shell window did not become key"))
        self.assertEqual(row["acts"][1].get("refused_as"), [NO_PAGE_WINDOW] * 2)

    def test_a_send_that_timed_out_is_never_sent_again(self):
        # The app TOOK the keys and the reply did not come. A second send would do the act 2 times.
        code, report, lines, launches = self.run_films({"open-activates", "page-takes-keys", "page-send-times-out"}, "--films", "P07")
        row, world = report["films"][0], launches[0].world
        self.assertEqual(self.forms(launches), ["activate"])
        self.assertEqual(world.words[PREFLIGHT_KEYS:], [("shell", "shell"), ("page", "page")])  # the held Cmd-T; the closes, ONE time
        self.assertEqual((code, row["status"], row["reason"]), (1, "not_run", "the app refused Cmd-W x5: timed out"))
        self.assertNotIn("refused_as", row["acts"][1])

    def test_the_one_key_form_sends_a_page_key_again_only_after_a_refusal_of_the_key_window_before_a_key_went(self):
        code, report, lines, launches = self.run_films({"page-send-times-out"}, "--films", "B-Z", "--launch-form", "one-key")
        row = report["films"][0]
        world = next(app.world for app in launches if "page" in app.world.targets)
        # Each of the film's 2 zoom keys went to the page ONE time and timed out: no key in the shell window after it.
        self.assertEqual(world.targets[world.targets.index("page"):], ["page", "page"])
        self.assertEqual((code, row["status"], row["reason"]), (1, "not_run", "the app refused Cmd-Shift-Enter: timed out"))
        refusal = "no Chromium page window for pane"
        self.assertEqual([M.shell_try(word, said) for word, said in (
            ("page", {"error": refusal, "key_down_ms": [0.0]}),          # the window was refused before a key went
            ("page", {"error": refusal, "key_down_ms": [0.0, 250.0]}),   # the first key went: no second send of both
            ("page", {"error": "timed out", "key_down_ms": [0.0]}),      # no refusal of the window
            ("shell", {"error": refusal, "key_down_ms": [0.0]}),         # the shell window is the last one
            ("page", {"key_down_ms": [0.0]}))],                          # the app took the key
            [True, False, False, False, False])

    def test_the_one_key_form_sends_a_page_key_that_the_app_refuses_before_its_dispatch_in_the_shell_window(self):
        code, report, lines, launches = self.run_films({"page-refuses-one-key"}, "--films", "B-Z", "--launch-form", "one-key")
        row = report["films"][0]
        world = next(app.world for app in launches if "page" in app.world.targets)
        self.assertEqual(world.targets[world.targets.index("page"):], ["page", None] * 2)  # the 2 zoom keys of the film
        self.assertEqual((code, row["status"], [(act.get("refused_as"), act.get("key_window"), len(act.get("key_down_ms", ()))) for act in row["acts"]]),
                         (0, "made", [([NO_PAGE_WINDOW], "shell", 1)] * 2))

    def test_the_row_of_a_film_with_a_speed_says_if_the_app_animates_and_the_speed_before_and_at_the_stop(self):
        code, report, lines, launches = self.run_films({"launch-activates"}, "--films", "T-Z.N")
        row = report["films"][0]
        self.assertEqual((code, row["status"]), (0, "made"))
        self.assertEqual({key: row.get(key) for key in SPEED_KEYS if key not in ("spans", "source_ms")},
                         {"speed_before": "fast", "speed": "normal", "speed_at_stop": "normal", "speed_after": "fast", "speed_fault": None,
                          "reduce_motion": False, "animations_enabled": True, "pane_animations": True, "disabled_categories": [],
                          "spans_total": 2, "spans_cut": 0})
        self.assertEqual(launches[0].world.motion, ["read", "speed", "start", "stop", "speed"])

    def test_an_app_that_animates_no_pane_motion_gets_no_film_at_a_speed(self):
        for fault, said in (("reduce-motion", "reduce_motion = true, animations_enabled = true, pane_animations = true"),
                            ("pane-animations-off", "reduce_motion = false, animations_enabled = true, pane_animations = false")):
            code, report, lines, launches = self.run_films({"launch-activates", fault}, "--films", "T-Z.N")
            row = report["films"][0]
            self.assertEqual((code, row["status"]), (1, "not_run"), fault)
            self.assertEqual(row.get("reason"), "the app animates no pane motion now, so a film at a speed would show none: " + said, fault)
            self.assertEqual((row.get("reduce_motion"), row.get("pane_animations")), (fault == "reduce-motion", fault != "pane-animations-off"), fault)
            self.assertEqual(launches[0].world.speeds, [("normal", 0), ("fast", 0)], fault)  # no workspace was made for the film

    def test_an_app_with_the_category_of_the_pane_motions_off_gets_no_film_at_a_speed(self):
        code, report, lines, launches = self.run_films({"launch-activates", "panes-category-off"}, "--films", "T-Z.N")
        row = report["films"][0]
        self.assertEqual((code, row["status"], row.get("disabled_categories")), (1, "not_run", ["panes"]))
        self.assertEqual(row.get("reason"), "the app animates no pane motion now, so a film at a speed would show none: reduce_motion = false, "
                                            "animations_enabled = true, pane_animations = true, disabled_categories = [\"panes\"]")
        self.assertEqual(launches[0].world.speeds, [("normal", 0), ("fast", 0)])  # no workspace was made for the film

    def test_the_master_switch_off_gets_no_film_and_an_app_that_does_not_say_if_it_animates_gets_its_film(self):
        code, report, lines, launches = self.run_films({"launch-activates", "animations-off"}, "--films", "T-Z.N")
        row = report["films"][0]
        self.assertEqual((code, row["status"], row.get("animations_enabled")), (1, "not_run", False))
        self.assertEqual(row.get("reason"), "the app animates no pane motion now, so a film at a speed would show none: reduce_motion = false, "
                                            "animations_enabled = false, pane_animations = true")
        # An older app: its reply has none of the fields. The tool cannot know, so the film is made and the row says `null`.
        code, report, lines, launches = self.run_films({"launch-activates", "older-app"}, "--films", "T-Z.N")
        row = report["films"][0]
        self.assertEqual((code, row["status"], [row.get(name, "no field") for name in ("reduce_motion", "animations_enabled", "pane_animations")]),
                         (0, "made", [None, None, None]))

    def test_a_row_has_60_spans_at_most_keeps_each_layout_span_and_says_how_many_are_cut(self):
        code, report, lines, launches = self.run_films({"launch-activates", "many-spans"}, "--films", "T-Z.N")
        row = report["films"][0]
        names = [span["name"] for span in row["spans"]]
        # 75 spans of another animator, then the 2 of the zoom: the row keeps the 2, in the app's order.
        self.assertEqual((code, row.get("spans_total"), row.get("spans_cut"), names), (0, 77, 17, ["tabstrip"] * 58 + ["layout"] * 2))

    def span_cut(self, names):
        """What `motion_spans` keeps of a reply with these span names, each span at its place in the app's list."""
        row = M.motion_spans({"spans": [{"name": name, "ms": 1.0, "at_ms": place} for place, name in enumerate(names)], "speed": 1})
        return [(span["name"], span["at_ms"]) for span in row["spans"]], row["spans_total"], row["spans_cut"]

    def test_the_span_cut_keeps_the_first_60_layout_spans_and_no_other_span_when_the_app_gives_more_than_60(self):
        # 61 `layout` spans with 5 other spans between them: 5 groups of 12 and one other span, then the 61st.
        names = (["layout"] * 12 + ["tabstrip"]) * 5 + ["layout"]
        first_60 = [(name, place) for place, name in enumerate(names) if name == "layout"][:60]
        self.assertEqual(self.span_cut(names), (first_60, 66, 6))

    def test_the_span_cut_keeps_a_layout_span_between_other_spans_and_behind_them_in_the_order_of_the_app(self):
        # 40 other spans, a `layout` span, 40 other spans, a `layout` span: the 2 and the first 58 others, in the app's order.
        names = ["tabstrip"] * 40 + ["layout"] + ["tabstrip"] * 40 + ["layout"]
        kept = [("tabstrip", place) for place in range(40)] + [("layout", 40)] + [("tabstrip", place) for place in range(41, 59)] + [("layout", 81)]
        self.assertEqual(self.span_cut(names), (kept, 82, 22))

    def test_a_focus_read_that_fails_is_said_in_the_preflight_line_and_in_the_row_of_the_act(self):
        # The tool then sends `shell`: a reader of the line or of the row must know that no read gave that word.
        code, report, lines, launches = self.run_films({"launch-activates", "focus-read-fails"}, "--films", "T-Z.N")
        row, unread = report["films"][0], "debug.focus: a fake fault of the focus read"
        self.assertEqual((code, row["status"]), (0, "made"))
        passed = next(line for line in lines if line.startswith("PREFLIGHT close-tab ok: "))
        self.assertTrue(passed.endswith(f"; the focus was not read ({unread}), so the word `shell` was sent"), passed)
        self.assertEqual([line for line in lines if "the focus was not read" in line], [passed])  # no other key of the preflight
        self.assertEqual([(act.get("key_window"), act.get("focus_not_read")) for act in row["acts"]], [("shell", unread)] * 2)

    def test_the_turned_zoom_says_its_gap_as_the_gap_that_was_asked_and_is_one_span(self):
        code, report, lines, launches = self.run_films({"launch-activates"}, "--films", "T-ZT,T-ZT.N")
        self.assertEqual([(row["title"], row["acts"][0].get("gap_asked_ms")) for row in report["films"]],
                         [("Zoom turned back at its half (118 ms asked from key to key), speed fast", 118),
                          ("Zoom turned back at its half (147 ms asked from key to key), speed normal", 147)])
        self.assertEqual([(row.get("spans_total"), [span["name"] for span in row["spans"]]) for row in report["films"]],
                         [(1, ["layout"]), (1, ["layout"])])

    def test_the_split_and_close_film_says_if_the_close_takes_the_new_pane_and_if_its_tab_is_a_stand_in(self):
        for faults, new_pane, provisional in ((set(), True, False), ({"split-never-settles"}, True, True)):
            code, report, lines, launches = self.run_films(faults, "--films", "T-C", "--launch-form", "one-key")
            row = report["films"][0]
            read = row["acts"][1]
            self.assertEqual((code, row["status"], read.get("new_pane"), read.get("provisional"), read["tab_kinds"]),
                             (0, "made", new_pane, provisional, ["terminal"]), faults)

    def test_a_close_that_would_take_a_pane_of_the_set_up_is_not_sent_and_the_film_is_not_made(self):
        # The split leaves the focus in the pane that had it (a terminal with a program): the app would ask before
        # that close, and its question would stay over the window.
        code, report, lines, launches = self.run_films({"split-keeps-focus"}, "--films", "T-C", "--launch-form", "one-key")
        row = report["films"][0]
        self.assertEqual((code, row["status"], [act["label"] for act in row["acts"]]), (1, "not_made", ["Cmd-D", "read: the tabs of the pane with the focus"]))
        self.assertEqual((row["acts"][1].get("new_pane"), launches[-1].world.dialogs), (False, []))
        self.assertIn("the split made no pane (the pane with the focus is not a new pane), so the close was not sent", row.get("reason", ""))

    def test_a_split_that_the_app_refuses_is_not_made_with_the_app_s_message_and_its_close_is_not_sent(self):
        # A row of 5 panes with no room for a sixth: the app refuses the split with a message and makes no pane.
        code, report, lines, launches = self.run_films({"launch-activates", "room-for-3"}, "--films", "P13")
        row, world = report["films"][0], launches[0].world
        self.assertEqual((code, row["status"], row["panes_before"], row["panes_after"]), (1, "not_made", 5, 5))
        self.assertEqual([act["label"] for act in row["acts"]], ["Cmd-D", "read: the tabs of the pane with the focus"])  # no Cmd-W
        self.assertIn(f"the app refused in the film: {NO_ROOM}", row.get("reason", ""))
        self.assertIn("so the close was not sent", row.get("reason", ""))
        self.assertEqual((world.dialogs, row.get("take_file"), "file" in row), ([], "P13.not-made.mov", False))
        self.assertIn(f"PANE-FILMS not made: P13: {row.get('reason')}", self.printed)

    def test_a_close_that_the_app_asks_about_is_not_made_and_the_tool_sends_cancel(self):
        # No film of the list closes a pane with a program. Here one does: the pane with `ping` has the focus.
        with mock.patch.dict(next(spec for spec in M.FILMS if spec["id"] == "P03"), {"focus": 1}):
            code, report, lines, launches = self.run_films({"launch-activates"}, "--films", "P03,T-D")
        rows, world = {row["id"]: row for row in report["films"]}, launches[0].world
        self.assertEqual((code, rows["P03"]["status"], rows["P03"]["panes_before"], rows["P03"]["panes_after"]), (2, "not_made", 5, 5))
        self.assertIn(f"the app asked in the film: {ASKED}", rows["P03"].get("reason", ""))
        self.assertIn("the pane count went from 5 to 5: the film's acts make a change of -1", rows["P03"].get("reason", ""))
        self.assertEqual(rows["P03"].get("dialog"), f"the tool sent Cancel: {ASKED}")
        # ONE Cancel, and the question is not over the next film: that film is made, with no dialog in its row.
        self.assertEqual((world.dismissals, [dialog["visible"] for dialog in world.dialogs]), ([1], [False]))
        self.assertEqual((rows["T-D"]["status"], "dialog" in rows["T-D"]), ("made", False))

    def test_a_cancel_that_the_app_does_not_take_stops_the_launch(self):
        with mock.patch.dict(next(spec for spec in M.FILMS if spec["id"] == "P03"), {"focus": 1}):
            code, report, lines, launches = self.run_films({"launch-activates", "dismiss-fails"}, "--films", "P03,T-D,T-Z")
        rows = {row["id"]: row for row in report["films"]}
        stop = f"the launch stopped after the film P03: the app did not take the Cancel of its dialog ({ASKED})"
        self.assertEqual((code, [rows[i]["status"] for i in ("P03", "T-D", "T-Z")]), (1, ["not_made", "not_run", "not_run"]))
        self.assertEqual((rows["T-D"].get("reason"), rows["T-Z"].get("reason"), rows["T-D"].get("launch_form")), (stop, stop, "activate"))
        self.assertEqual((launches[0].world.dismissals, report["failures"]), ([1], [f"page mock off: {stop}"]))

    def test_a_dialog_or_an_overlay_that_is_open_before_a_take_is_not_made_and_stops_the_launch(self):
        for fault, open_thing in (("dialog-open", "a dialog was open: A question: of another act"), ("overlay-open", "an overlay was open: palette")):
            code, report, lines, launches = self.run_films({"launch-activates", fault}, "--films", "T-D,T-Z")
            rows = {row["id"]: row for row in report["films"]}
            self.assertEqual((code, rows["T-D"]["status"], rows["T-Z"]["status"]), (1, "not_made", "not_run"), fault)
            self.assertEqual(rows["T-D"].get("reason"), f"before the take: {open_thing}", fault)
            self.assertEqual(rows["T-Z"].get("reason"), f"the launch stopped after the film T-D: before the take: {open_thing}", fault)
            self.assertNotIn("panes_before", rows["T-D"], fault)  # no take: the recorder did not start for this film

    def test_a_message_on_the_screen_before_a_take_gets_the_time_to_go_and_no_film_is_made_under_it(self):
        # P13: the app refuses its split with a message, and that message is still on the screen at the next film.
        code, report, lines, launches = self.run_films({"launch-activates", "room-for-3"}, "--films", "P13,T-D")
        rows = {row["id"]: row for row in report["films"]}
        self.assertEqual((code, rows["P13"]["status"], rows["T-D"]["status"]), (2, "not_made", "made"))
        self.assertEqual((rows["T-D"].get("message_waited"), launches[0].world.toasts, "message_waited" in rows["P13"]), ([NO_ROOM], [], False))
        self.assertIn(M.OVERLAY_S, BOUNDS)  # the reads for the message have this bound
        # A message that stays: no film with it over the window, and the launch goes on (the tool closes no message).
        code, report, lines, launches = self.run_films({"launch-activates", "room-for-3", "message-stays"}, "--films", "P13,T-D,T-SD")
        rows = {row["id"]: row for row in report["films"]}
        self.assertEqual((code, [rows[i]["status"] for i in ("P13", "T-D", "T-SD")]), (1, ["not_made"] * 3))
        self.assertEqual(rows["T-SD"].get("reason"), f"before the take: a message stayed on the screen for {M.OVERLAY_S} s: {NO_ROOM}")
        self.assertNotIn("panes_before", rows["T-SD"])

    def test_an_overlay_that_a_film_opens_is_not_made_and_the_next_film_stops_the_launch(self):
        with mock.patch.dict(next(spec for spec in M.FILMS if spec["id"] == "T-Z"), {"acts": [M.K("cmd+p")]}):
            code, report, lines, launches = self.run_films({"launch-activates"}, "--films", "T-Z,T-D,T-SD")
        rows = {row["id"]: row for row in report["films"]}
        self.assertEqual((code, [rows[i]["status"] for i in ("T-Z", "T-D", "T-SD")]), (1, ["not_made", "not_made", "not_run"]))
        self.assertEqual(rows["T-Z"].get("reason"), "the app showed an overlay in the film: palette")
        self.assertEqual(rows["T-D"].get("reason"), "before the take: an overlay was open: palette")  # the tool closes no overlay

    def test_an_app_whose_reply_has_no_list_of_its_dialogs_gets_no_film(self):
        code, report, lines, launches = self.run_films({"launch-activates", "no-overlay-reads"}, "--films", "T-D,T-Z")
        rows = {row["id"]: row for row in report["films"]}
        self.assertEqual((code, rows["T-D"]["status"], rows["T-Z"]["status"]), (1, "not_made", "not_made"))  # the tool does not know: no stop
        self.assertEqual(rows["T-D"].get("reason"), "before the take: the tool does not know what is over the window: debug.dialog `dialogs`: {}")

    def test_a_zoom_film_is_made_only_when_a_pane_was_zoomed_between_its_2_keys(self):
        # The pane count of a zoom film is the same with and without the zoom: the count of zoomed panes is its check.
        code, report, lines, launches = self.run_films({"launch-activates", "zoom-dead-in-a-film"}, "--films", "T-Z")
        row = report["films"][0]
        self.assertEqual((code, row["status"], row["panes_before"], row["panes_after"], row["acts"][0].get("zoomed_after")), (1, "not_made", 2, 2, 0))
        self.assertEqual(row.get("reason"), "0 zoomed panes after the act `Cmd-Shift-Enter`, not 1")
        code, report, lines, launches = self.run_films({"launch-activates"}, "--films", "T-Z")
        row = report["films"][0]
        self.assertEqual((code, row["status"], row["acts"][0].get("zoomed_after"), row.get("zoomed_end")), (0, "made", 1, 0))

    def test_a_film_with_a_speed_is_made_only_with_the_layout_spans_of_its_acts(self):
        code, report, lines, launches = self.run_films({"launch-activates", "no-layout-spans"}, "--films", "T-Z.N,T-ZT,T-C")
        self.assertEqual((code, [(row["id"], row["status"], row.get("layout_spans")) for row in report["films"]]),
                         (1, [("T-Z.N", "not_made", 0), ("T-ZT", "not_made", 0), ("T-C", "not_made", 0)]))
        self.assertEqual([row.get("reason") for row in report["films"]],
                         ["0 `layout` spans in the span record: the film's acts make 2", "0 `layout` spans in the span record: the film's acts make 1 or 2",
                          "0 `layout` spans in the span record: the film's acts make 2"])
        code, report, lines, launches = self.run_films({"launch-activates"}, "--films", "T-Z.N,T-ZT,T-C,T-D")
        self.assertEqual((code, [(row["id"], row["status"], row.get("layout_spans")) for row in report["films"]]),
                         (0, [("T-Z.N", "made", 2), ("T-ZT", "made", 1), ("T-C", "made", 2), ("T-D", "made", "not recorded")]))

    def test_the_row_says_which_checks_of_the_act_were_made(self):
        code, report, lines, launches = self.run_films({"launch-activates"}, "--films", "T-D,T-Z,T-Z.2,T-C,P03,P04,P05,P06")
        base = "act check: the refusal list, the dialogs, the pane count"
        self.assertEqual((code, {row["id"]: (row["status"], row.get("act_check")) for row in report["films"]}), (0, {
            "T-D": ("made", base + " (+1)"), "T-Z": ("made", base + ", the zoomed panes"),
            "T-Z.2": ("made", base + ", the zoomed panes, the `layout` spans"),
            "T-C": ("made", base + ", the new pane before the close, the `layout` spans"),
            "P03": ("made", base + " (-1)"), "P04": ("made", base + ", the tab count (-1)"), "P05": ("made", base + ", the tab count (+1)"),
            "P06": ("made", "act check: the refusal list, the dialogs and the pane count only")}))
        rows = {row["id"]: row for row in report["films"]}
        self.assertEqual([(rows[i]["tabs_before"], rows[i]["tabs_after"]) for i in ("P04", "P05")], [(4, 3), (1, 2)])

    def test_a_pane_count_that_does_not_fit_the_acts_is_not_made(self):
        # The film says a split (+1) and the app makes no pane, with no refusal message: only the count says it.
        with mock.patch.dict(next(spec for spec in M.FILMS if spec["id"] == "T-D"), {"acts": [M.K("cmd+b")]}):
            code, report, lines, launches = self.run_films({"launch-activates"}, "--films", "T-D")
        row = report["films"][0]
        self.assertEqual((code, row["status"], row.get("reason")), (1, "not_made", "the pane count went from 2 to 2: the film's acts make a change of +1"))

    def test_no_film_closes_a_pane_of_its_set_up_that_has_a_program_and_each_split_then_close_reads_the_pane_first(self):
        keys = lambda spec: [act for act in spec["acts"] if act[0] == "keys"]
        for spec in M.FILMS:
            kinds = M.SETUPS[spec["setup"]][1]
            if keys(spec) and keys(spec)[0][1] == "cmd+w" and not spec.get("tabs") and not spec.get("pre"):
                # The first key closes a pane of the set-up: the app asks before the close of a terminal with a program.
                self.assertEqual(kinds[spec.get("focus", 0)], "shell", spec["id"])
            chords = [act[1] if act[0] == "keys" else act[0] for act in spec["acts"] if act[0] != "wait"]
            if "cmd+d" in chords and "cmd+w" in chords:
                self.assertEqual(chords, ["cmd+d", "tabs", "cmd+w"], spec["id"])  # the read of the pane that the close takes
        rows = {spec["id"]: spec for spec in M.FILMS}
        # A row of 2: in a run on a Mac, a row of 3 with the docked column took no fourth pane.
        self.assertEqual([(rows[i]["setup"], rows[i].get("focus", 0), rows[i].get("layout")) for i in ("T-C", "T-C.N")], [("T", 0, (2, 2))] * 2)
        self.assertEqual({i: rows[i].get("change", 0) for i in ("T-D", "B-SD", "M-D", "P03", "P13", "X01", "T-Z")},
                         {"T-D": 1, "B-SD": 1, "M-D": 1, "P03": -1, "P13": 0, "X01": 1, "T-Z": 0})

    def test_the_new_refusals_are_the_entries_that_the_app_added_also_when_its_list_is_full(self):
        self.assertEqual(M.new_refusals(["a"], ["a", "b", "c"]), ["b", "c"])
        self.assertEqual(M.new_refusals(["a", "b"], ["a", "b"]), [])
        self.assertEqual(M.new_refusals(["a", "b", "c"], ["b", "c", "d"]), ["d"])  # the app keeps 100: the oldest entry left
        self.assertEqual(M.new_refusals([], ["a"]), ["a"])

    def test_a_layout_read_that_fails_before_a_take_is_not_made_and_is_no_pane_count(self):
        # Each layout read fails from the take on: 0 panes before and 0 after would fit a film whose acts change no count.
        code, report, lines, launches = self.run_films({"launch-activates", "layout-dead-from-the-take"}, "--films", "P06")
        row = report["films"][0]
        self.assertEqual((code, row["status"], row.get("reason")), (1, "not_made", "before the take: the layout read gave no workspace"))
        self.assertNotIn("panes_before", row)  # a read that failed is no count

    def test_a_layout_read_that_fails_after_the_acts_is_not_made_and_is_no_count_of_zoomed_panes(self):
        # The pane stays zoomed and the read after the acts fails: 0 zoomed panes is the value that the check wants.
        faults = {"launch-activates", "second-zoom-key-dead", "layout-read-fails-after-the-acts"}
        code, report, lines, launches = self.run_films(faults, "--films", "T-Z")
        row = report["films"][0]
        self.assertEqual((code, row["status"], row.get("panes_after"), row.get("zoomed_end")), (1, "not_made", "not read", "not read"))
        self.assertEqual(row.get("reason"), "the pane count after the acts was not read; the zoomed panes at the film's end were not read")

    def test_a_layout_read_that_fails_between_the_zoom_keys_is_not_read_and_not_0(self):
        code, report, lines, launches = self.run_films({"launch-activates", "layout-read-fails-in-the-take"}, "--films", "T-Z")
        row = report["films"][0]
        self.assertEqual((code, row["status"], row["acts"][0].get("zoomed_after")), (1, "not_made", "not read"))
        self.assertEqual(row.get("reason"), "the zoomed panes after the act `Cmd-Shift-Enter` were not read")

    def test_a_zoom_that_does_not_go_back_is_not_made(self):
        code, report, lines, launches = self.run_films({"launch-activates", "second-zoom-key-dead"}, "--films", "T-Z")
        row = report["films"][0]
        self.assertEqual((code, row["status"], row["acts"][0].get("zoomed_after"), row.get("zoomed_end")), (1, "not_made", 1, 1))
        self.assertEqual(row.get("reason"), "1 zoomed panes at the film's end, not 0")

    def test_a_tab_count_that_does_not_fit_the_act_is_not_made(self):
        code, report, lines, launches = self.run_films({"launch-activates", "tab-keys-dead-in-a-film"}, "--films", "P04,P05")
        rows = {row["id"]: row for row in report["films"]}
        self.assertEqual((code, rows["P04"]["status"], rows["P05"]["status"]), (1, "not_made", "not_made"))
        self.assertEqual(rows["P04"].get("reason"), "the tab count of the pane went from 4 to 4: the film's acts make a change of -1")
        self.assertEqual(rows["P05"].get("reason"), "the tab count of the pane went from 1 to 1: the film's acts make a change of +1")

    def test_a_tab_read_that_gives_no_tab_is_not_made_and_is_no_tab_count(self):
        # A pane has 1 tab or more: a read with no tab is a read that failed (or the pane is gone), not a count of 0.
        code, report, lines, launches = self.run_films({"launch-activates", "tab-read-fails-after-the-acts"}, "--films", "P04")
        row = report["films"][0]
        self.assertEqual((code, row["status"], row.get("tabs_before"), row.get("tabs_after")), (1, "not_made", 4, "not read"))
        self.assertEqual(row.get("reason"), "the tab count of the pane after the acts was not read")

    def test_a_span_record_with_no_list_is_not_made(self):
        code, report, lines, launches = self.run_films({"launch-activates", "no-span-list"}, "--films", "T-Z.2")
        row = report["films"][0]
        self.assertEqual((code, row["status"], row.get("layout_spans")), (1, "not_made", "not read"))
        self.assertEqual(row.get("reason"), "not read `layout` spans in the span record: the film's acts make 2")

    def test_a_read_of_the_window_that_fails_after_the_acts_is_not_made(self):
        code, report, lines, launches = self.run_films({"launch-activates", "dialog-read-fails-after-the-acts"}, "--films", "T-D")
        row = report["films"][0]
        self.assertEqual((code, row["status"]), (1, "not_made"))
        self.assertEqual(row.get("reason"), "after the acts the tool does not know what is over the window: debug.dialog `dialogs`: "
                                            "{'error': 'a fake fault of the dialog read'}")

    @staticmethod
    def over(**replies):
        """`over_window` on the 3 replies of an app with nothing over its window, with the replies of the case in their place."""
        said = {"debug.dialog": {"dialogs": []}, "debug.focus": {"windows": [{"id": "window1", "model": {"overlays": []}}]},
                "debug.toast": {"windows": [{"window": "window1", "toasts": []}], "refusals": []}}
        said.update({"debug." + name: reply for name, reply in replies.items()})
        return M.over_window(lambda method, params=None: said[method])

    def test_a_read_of_the_window_that_failed_or_has_no_list_is_not_known(self):
        self.assertEqual(self.over(), ([], [], [], []))
        dialog = {"id": 1, "title": "A question", "lines": [], "visible": True}
        self.assertEqual(self.over(dialog={"dialogs": [dialog, {**dialog, "id": 2, "visible": False}]})[0], [dialog])
        for name, reply in (("dialog", {"error": "a fault", "dialogs": []}), ("focus", {"error": "a fault"}),
                            ("focus", {"windows": [{"id": "window1", "model": {}}]}), ("toast", {"error": "a fault"}),
                            ("toast", {"windows": [{"window": "window1", "toasts": []}]})):
            with self.subTest(read=name, reply=reply), self.assertRaises(M.NotKnown):
                self.over(**{name: reply})

    def test_a_reply_that_does_not_say_each_dialog_window_and_message_is_not_known_and_not_clear(self):
        # A dialog with no `visible` word, no window, a window with no list of its messages: the tool cannot say that
        # nothing is over the window.
        window = {"window": "window1"}
        for name, reply in (("dialog", {"dialogs": [{"id": 1, "title": "A question", "lines": []}]}), ("dialog", {"dialogs": ["a question"]}),
                            ("focus", {"windows": []}), ("toast", {"windows": [], "refusals": []}),
                            ("toast", {"windows": [window], "refusals": []}), ("toast", {"windows": ["window1"], "refusals": []}),
                            ("toast", {"windows": [{**window, "toasts": ["a message"]}], "refusals": []})):
            with self.subTest(read=name, reply=reply), self.assertRaises(M.NotKnown):
                self.over(**{name: reply})

    def test_a_message_read_that_fails_in_the_wait_is_not_known_and_is_no_message_that_stayed(self):
        # P13's refused split leaves a message. At the next film the reads for it fail: the helper's `wait` takes a
        # read that raises as `no value`, and that is not `the message stayed`.
        code, report, lines, launches = self.run_films({"launch-activates", "room-for-3", "message-read-fails-in-the-wait"}, "--films", "P13,T-D")
        rows = {row["id"]: row for row in report["films"]}
        self.assertEqual((code, rows["P13"]["status"], rows["T-D"]["status"]), (1, "not_made", "not_made"))
        self.assertEqual(rows["T-D"].get("reason"), "before the take: the tool does not know what is over the window (a read failed in the wait "
                                                    "for a message): debug.toast `windows`: {'error': 'a fake fault of the message read'}")

    def test_the_wait_for_a_message_is_longer_than_the_app_shows_a_message_of_a_film_s_act(self):
        # By a read of the app's source, with its default tuning: a refusal shows for 8 s, the undo message of a
        # close for 12 s, a refusal with a sign-in offer for 16 s.
        self.assertGreater(M.OVERLAY_S, 16)

    def test_the_movie_of_a_film_that_is_not_made_has_a_name_that_says_so(self):
        # The step's artifact has each movie of the out folder: a person who opens it has no films.json beside it.
        code, report, lines, launches = self.run_films({"launch-activates", "room-for-3"}, "--films", "P13,T-D")
        rows = {row["id"]: row for row in report["films"]}
        self.assertEqual((rows["P13"]["status"], rows["P13"].get("take_file"), rows["T-D"]["status"], rows["T-D"].get("file")),
                         ("not_made", "P13.not-made.mov", "made", "T-D.mov"))
        self.assertEqual(sorted(name for name in os.listdir(self.out) if name.startswith(("P13", "T-D"))),
                         ["P13.not-made.mov", "P13.not-made.mov.frames.json", "T-D.mov", "T-D.mov.frames.json"])
        # A film that the app refused a key of, after its recorder started: `not_run`, and its movie has that name too.
        code, report, lines, launches = self.run_films({"launch-activates", "film-key-refused"}, "--films", "T-Z.N")
        row = report["films"][0]
        self.assertEqual((row["status"], row.get("take_file"), "file" in row), ("not_run", "T-Z.N.not-made.mov", False))
        self.assertEqual(sorted(name for name in os.listdir(self.out) if name.startswith("T-Z.N")), ["T-Z.N.not-made.mov", "T-Z.N.not-made.mov.frames.json"])

    def test_a_film_that_fails_after_its_speed_is_set_stops_the_span_record_and_gives_the_speed_back(self):
        code, report, lines, launches = self.run_films({"launch-activates", "film-key-refused"}, "--films", "T-Z.N")
        row, world = report["films"][0], launches[0].world
        self.assertEqual((code, row["status"], row["reason"]), (1, "not_run", "the app refused Cmd-Shift-Enter: a fake refusal of a key in the film"))
        self.assertEqual((world.motion, world.speeds), (["read", "speed", "start", "stop", "speed"], [("normal", 0), ("fast", 1)]))
        self.assertEqual((row["speed"], row["speed_after"], row["spans"]), ("normal", "fast", []))

    def test_a_span_record_whose_start_call_fails_still_gets_its_stop(self):
        code, report, lines, launches = self.run_films({"launch-activates", "start-raises"}, "--films", "T-Z.N")
        row, world = report["films"][0], launches[0].world
        self.assertEqual((code, row["status"]), (1, "not_run"))
        self.assertIn("a fake fault of the start call", row["reason"])
        self.assertEqual(world.motion, ["read", "speed", "start", "stop", "speed"])

    def test_a_speed_that_cannot_be_read_before_the_film_is_said_in_the_row(self):
        code, report, lines, launches = self.run_films({"launch-activates", "speed-not-read"}, "--films", "T-Z.N")
        row = report["films"][0]
        self.assertEqual((code, row["status"], row.get("speed_before"), row["speed_after"]),
                         (0, "made", "not read: `fast`, the app's default, is set at the film's end", "fast"))
        self.assertEqual(launches[0].world.speeds, [("normal", 0), ("fast", 1)])

    def test_a_speed_that_does_not_go_back_is_said_in_the_row_of_that_film_and_of_each_film_after_it(self):
        code, report, lines, launches = self.run_films({"launch-activates", "speed-stays-normal"}, "--films", "T-Z.N,T-D")
        rows = {row["id"]: row for row in report["films"]}
        fault = "the animation speed did not go back to `fast` after the film T-Z.N: the app says `normal`"
        self.assertEqual((code, rows["T-Z.N"]["status"], rows["T-Z.N"]["speed_after"], rows["T-D"]["status"]), (0, "made", "normal", "made"))
        self.assertEqual((rows["T-Z.N"].get("speed_fault"), rows["T-D"].get("speed_fault")), (fault, fault))
        # The exit code does not say it: ONE printed line does, with each film that has no speed of its own after it.
        self.assertEqual([line for line in self.printed if line.startswith("PANE-FILMS speed fault: ")],
                         [f"PANE-FILMS speed fault: {fault}; made after it with no speed call of its own: T-D"])

    def test_each_key_row_of_the_one_key_form_has_the_time_of_its_key_down_and_a_film_of_kinds_gets_no_speed_call(self):
        code, report, lines, launches = self.run_films(set(), "--films", "kinds", "--launch-form", "one-key")
        self.assertEqual((code, [row["status"] for row in report["films"]], self.forms(launches)), (0, ["made"] * 9, ["one-key", "one-key"]))
        self.assertEqual([app.world.motion for app in launches], [[], []])
        self.assertEqual({len(act.get("key_down_ms", ())) for row in report["films"] for act in row["acts"]}, {1})
        self.assertFalse([key for row in report["films"] for key in SPEED_KEYS if key in row])

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
