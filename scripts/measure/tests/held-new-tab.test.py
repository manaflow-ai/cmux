#!/usr/bin/env python3
"""scripts/measure/held-new-tab.py: what a row says of the tab order, of a slow key, of its own restore and artifact.

The order row knew a new tab only by its place in the pane's list, read the list from the focus model, and did not
say at which key the app left the rule. A row's restore closed what the row made and did not give back a tab of the
start that the row closed, so each later row started with one tab less, and at the end the rows' pane was gone. The
script now reads the store's list (each tab's id and kind), checks each Cmd-W by the id that the app closed, names
the first difference by its key, id and kind, gives a lost tab back, fails the run for a restore that leaves a
difference, does not run a take whose pane is gone or did not get the focus, says where a slow key's time went, and
packs one file for the step to bring back.

The `activate` form asked for the shell window as the key window at each sequence. The app shows a Chromium page in a
window of its own that has the keys while the pane shows the page, and it refuses the shell window then: the
preflight's Cmd-W, on the new tab page that its own Cmd-T made, failed, and each run went on in the `one-key` form.
The script now asks for the window that has the keys, by a read of the app's focus (`KeyWindow`). A take sends its
word with no key before its frames start, so a refusal of a stale word is outside the frames; a take that still
gets a refusal after the frames started is INVALID.

No app, no socket, no build: `run()` and `take()` run with the session helper (`Stress`), `subprocess` and the
signpost reader replaced by fakes with a small model of one pane's tabs and of what each key does to them; `main()`
runs to its first row with the launcher (`BenchApp`), `open`, `ps`, `lsappinfo` and `os.kill` replaced (no process
starts, no signal goes to one). So this proves the script's own logic (the model, the rows, the failures, the launch
forms), NOT the app, NOT what a Mac's keys do and NOT what LaunchServices does.
Run: python3 -I scripts/measure/tests/held-new-tab.test.py"""
import argparse, contextlib, importlib.util, io, itertools, json, os, shutil, signal, subprocess, sys, tarfile, tempfile, unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
SPEC = importlib.util.spec_from_file_location("held_new_tab_under_test", os.path.join(HERE, "..", "held-new-tab.py"))
M = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(M)
ACTION = {"t": "newTab.default", "w": "closeTab"}
IN_TURN = "each_call_ended_with_its_reply_before_the_next_began"  # the field of `key_calls`
EARLY = "key_window_refusals_before_the_frames"  # the field of a take: each refusal of its sequence with no key
HIDDEN = "not_for_a_person"  # the key of a row that holds each number of a row with no proof of the order of its keys
WIDE = ["action", "stall", "stalls", "tab-switch"]
BUNDLE = "/fake/cmux DEV fake.app"
BINARY = BUNDLE + "/Contents/MacOS/cmux DEV fake"
CEF_READY = {"state": "ready", "default_engine": "chromium", "unavailable": None, "fallback": None}  # the app's `debug.cef`


def wait(test, seconds, step=0.25):
    """The session helper's `wait` for a fake that changes in the call itself: 3 reads, no sleep."""
    for _ in range(3):
        value = test()
        if value:
            return value
    return None


class ShapeError(RuntimeError):
    pass


class World:
    """The fake app: one workspace with one pane of tabs, what each key does to them, and the faults of the case."""

    def __init__(self, **faults):
        self.faults, self.count, self.tabs, self.pane, self.space = faults, 0, [], "pane1", None
        self.marks, self.keys, self.calls, self.takes, self.openings, self.records = [], 0, [], [], [], 0
        self.closes, self.given, self.slow, self.base, self.now = 0, 0, {}, 100.0, 100.0
        self.fewest, self.kills, self.children = float("inf"), [], []  # the smallest tab count after a close; the group kills; each child
        self.sent = []  # the `one-key` form: (the letter, the event's time, the app's clock at the call's start) of each call
        # `chromium_pages`: a new tab page that the pane shows has the keys in a window of its own, as a Chromium page of
        # the app has. `asked` has the `key_window` word of each sequence; `stale` is the count of `debug.focus` reads
        # that still say the shell window after a Cmd-T (the fault `page_gets_the_keys_late`).
        self.asked, self.stale = [], 0

    def tab(self, kind, selected=False):
        self.count += 1
        return {"id": f"tab{self.count}", "kind": kind, "selected": selected}

    def selected(self):
        return next((i for i, tab in enumerate(self.tabs) if tab["selected"]), None)

    def select(self, tab):
        for other in self.tabs:
            other["selected"] = other is tab

    def add(self, kind):
        """A new tab directly right of the selected one, selected, with the selected one as its opener."""
        at = self.selected()
        new = self.tab(kind)
        new["opener"] = self.tabs[at]["id"] if at is not None else None
        # The fault of the case: in that take (a count from 1) the app puts each new tab first in the list.
        wrong = kind == "newtab" and len(self.takes) == self.faults.get("new_tab_first_in_take")
        self.tabs.insert(0 if wrong else len(self.tabs) if at is None else at + 1, new)
        self.select(new)
        return new

    def close(self, tab):
        """`tab` goes; when it was the selected one: its opener, else the next tab, else the previous one."""
        at = self.tabs.index(tab)
        self.tabs.remove(tab)
        self.fewest = min(self.fewest, len(self.tabs))
        if tab["selected"] and self.tabs:
            opener = next((other for other in self.tabs if other["id"] == tab.get("opener")), None)
            self.select(opener or self.tabs[min(at, len(self.tabs) - 1)])

    def page_has_the_keys(self):
        """The fake app with Chromium pages: the pane shows a new tab page, so the page's own window has the keys."""
        at = self.selected()
        # The fault of the case: the page gets the keys only when the take's frames start (after the take's read).
        if self.faults.get("page_takes_the_keys_at_the_frames") and ("debug.frames", "start") not in self.calls:
            return False
        return bool(self.faults.get("chromium_pages")) and at is not None and self.tabs[at]["kind"] == "newtab"

    def key(self, letter, at):
        self.keys += 1
        if letter == "t":
            self.add("newtab")
            self.stale = 1 if self.faults.get("page_gets_the_keys_late") else 0
            self.openings.append({"spare": len(self.openings) % 2 == 0, "cross_window": False, "refit": False,
                                  "ms": 3.0 if len(self.openings) % 2 == 0 else 120.0 + len(self.openings)})
            return
        self.closes += 1
        tab = self.tabs[self.selected()]
        if self.closes == self.faults.get("close_another_tab_at"):
            # The fault of the case: this Cmd-W closes the first tab of the start (not the selected tab).
            tab = self.tabs[0]
        self.close(tab)
        self.marks.append({"kind": "closed", "event_s": at, "tabs": [tab["id"]], "empties_pane": False})

    # The store's list, as `snapshot.get` gives it through the session helper.

    def listed(self):
        return [{"id": tab["id"], "kind": tab["kind"], "selected": tab["selected"]} for tab in self.tabs]

    def workspaces(self):
        panes = [] if self.faults.get("pane_gone") == "now" else [{"id": self.pane, "tabs": self.listed()}]
        return [{"id": "ws0", "screens": []}] + ([{"id": self.space, "screens": [{"panes": panes}]}] if self.space else [])

    def rpc(self, method, params=None, timeout=60):
        params = params or {}
        self.calls.append((method, params.get("action") or ("sequence" if "sequence" in params else None)))
        if method == "debug.focus":
            cut = self.faults.get("focus_list_cut", 0)
            tabs = [f"{tab['id']}:{tab['kind']}" for tab in self.tabs][:len(self.tabs) - cut]
            chosen = next((tab["id"] for tab in self.tabs if tab["selected"]), None)
            window = {"topology": [{"pane": self.pane, "tabs": tabs, "selected": chosen}],
                      "model": {"resolved_tab": chosen}, "consistent": True, "mismatches": []}
            if not self.faults.get("chromium_pages"):
                return {"windows": [window]}
            # The app's own words: the shell window is not key while a page's window has the keys.
            page, self.stale = self.page_has_the_keys() and not self.stale, max(0, self.stale - 1)
            window.update({"is_key": not page, "appkit": {"child_window_page": chosen if page else None}})
            return {"app_active": True, "key_window": "CefNSWindow" if page else "ShellWindow", "windows": [window]}
        if method == "debug.journal":
            return {"stats": {"lastSeq": 0}, "entries": []}
        if method == "debug.burst":
            if params.get("action") == "start":
                return {"key_repeat_delay_s": 0.02, "key_repeat_interval_s": 0.02}
            if params.get("action") == "status":
                return {"recording": True, "sequence_playing": False, "pending_intents": 0, "resize_idle": True,
                        "terminals_awaiting_echo": 0}
            return {"events": list(self.marks), "dropped": 0}
        if method == "debug.key" and "key" in params:
            # The `one-key` form: one key-down a call, with the event's time. The fault of the case: each call takes
            # `call_s` of the app's clock (the app's main thread is busy), which can be longer than the gap of 2 keys.
            self.sent.append((params["key"], params["timestamp"], self.now))
            self.key(params["key"], params["timestamp"])
            self.now += self.faults.get("call_s", 0.0)
            return {}
        if method == "debug.key":
            if self.faults.get("chromium_pages"):
                # The app's 2 refusals of a `key_window` word; it refuses before it posts a key of that call.
                word, page = params.get("key_window"), self.page_has_the_keys()
                self.asked.append(word)
                if word == "shell" and page:
                    return {"error": "the shell window did not become key"}
                if word == "page" and not page:
                    return {"error": "no Chromium page window for pane"}
            at = self.base
            for step in params.get("sequence") or []:
                at += (step.get("after_ms") or 0) / 1000
                letter = {17: "t", 13: "w"}.get(step["key_code"])
                if step["down"] and letter:
                    self.key(letter, at)
            return {"base_s": self.base, "duration_ms": (at - self.base) * 1000 + 50}
        if method == "debug.new_tab":
            return {"openings": ["no record"] if self.faults.get("opens_are_no_records") else list(self.openings)}
        return {}

    # The take of a row, as the child process of the signpost recorder makes it: the keys, then the 2 files.

    def take(self, name, out, categories, keep, film, form="one-key"):
        self.takes.append({"row": name, "categories": categories, "film": film, "tabs_at_start": len(self.tabs)})
        letters = {"mixed": ["t", "t", "w", "t", "t", "w"], "hold": ["t"] * 4}.get(name) or ["w"] * (len(self.tabs) - keep)
        self.base += 10.0
        times = [self.base + 0.1 * index for index in range(len(letters))]
        before, self.marks, intervals = self.order(), [], []
        count = {"tabs": len(self.tabs), "panes": 1}
        # The fault of the case: in that take (a count from 1) the app gets 2 keys in the other order (the keys' own
        # times stay: each action and each mark names its key by the key's time).
        acts, late = list(range(len(letters))), 0.0
        swap = (self.faults.get("keys_change_places") or {}).get(len(self.takes))
        if swap:
            acts[swap[0]], acts[swap[1]] = acts[swap[1]], acts[swap[0]]
        # The calls of the keys, as the tool's one thread makes them ([the planned time, the start, the end], ms after the
        # base): a call starts at its key's time and ends 3 ms later, after its action started (2 ms after the key). The
        # faults of the case, each for one key of that take (a count from 1): the call of the key had not ended when the
        # next call started (`calls_overlap`); the call ended with an error and no reply (`call_with_no_reply`); the
        # call ended with the client's error in the form of a reply (`call_with_an_error_reply`: the real client gives
        # its own time-out, a lost connection and a refusal of the app as a dict with `error`, and the take then has
        # the error `keys: key N: ...` in its record).
        calls, replies = [[100.0 * index, 100.0 * index, 100.0 * index + 3.0] for index in range(len(letters))], [{} for _ in letters]
        long = (self.faults.get("calls_overlap") or {}).get(len(self.takes))
        if long is not None:
            calls[long][2] = calls[long + 1][1] + 50.0
        lost = (self.faults.get("call_with_no_reply") or {}).get(len(self.takes))
        if lost is not None:
            replies[lost] = "OSError('no socket')"
        failed = (self.faults.get("call_with_an_error_reply") or {}).get(len(self.takes))
        if failed is not None:
            replies[failed] = {"error": "timed out"}
        # 3 more faults, each for one take (a count from 1): the take's record has an error of its own (`record_error`:
        # the words) or an entry of `invalid` (`record_invalid`: the words); the recorder made no signpost stream
        # (`no_stream`).
        errors = [f"keys: key {failed}: timed out"] if failed is not None else []
        errors += [why for why in [(self.faults.get("record_error") or {}).get(len(self.takes))] if why]
        invalid = [why for why in [(self.faults.get("record_invalid") or {}).get(len(self.takes))] if why]
        said = M.key_calls({"sends": calls, "replies": replies}, form)
        for index in acts:
            letter, at = letters[index], times[index]
            self.key(letter, at)
            age, commit = self.slow.get((len(self.takes), index), (4.0, 3.0))
            user = {"id": ACTION[letter], "origin": "user"}
            if swap:
                # An action runs after the action before it, and not before its own key's time.
                late = max(at, late) + 0.002
                intervals.append(self.interval("action.perform", "action", late, 1.0, {**user, "input_age_ms": str((late - at) * 1000)}))
                intervals.append(self.interval("action.commit", "action", late + 0.002, commit,
                                               {**user, "input_age_ms": str((late + 0.002 - at) * 1000)}))
                continue
            intervals.append(self.interval("action.perform", "action", at + 0.002, 1.0, {**user, "input_age_ms": "2.0"}))
            intervals.append(self.interval("action.commit", "action", at + age / 1000, commit, {**user, "input_age_ms": str(age)}))
            if age > 200:
                # What ran on the main thread between this slow key and its commit: the app's own names.
                intervals.append(self.interval("stall.main_task", "stall", at + 0.02, 180.0,
                                               {"class": "background", "owner": "NewTabSparePool.warm"}))
                intervals.append(self.interval("stall.main_task", "stall", at + 0.001, 270.0,
                                               {"class": "control", "owner": "debug.key"}))
                intervals.append(self.interval("switch", "tab-switch", at + 0.21, 20.0, {}))
        record = {"scenario": name, "errors": errors, "invalid": invalid, "unit": "tabs", "key_window": "none", "presses": len(letters),
                  "before": count, "after": {"tabs": len(self.tabs), "panes": 1}, "press_letters": letters,
                  "press_times_s": times, "trace": {"events": list(self.marks), "dropped": 0}, "frames": {}, "settled_ms": 1,
                  "tabs_after": [tab["id"] for tab in self.tabs], "order": {"before": before, "after": self.order()},
                  "shows": [], "key_calls": said,
                  "take": {"key_form": form, "key_calls": {key: value for key, value in said.items() if key != "calls"}}}
        with open(os.path.join(out, "scenario.json"), "w") as f:
            json.dump(record, f)
        if self.faults.get("no_stream") != len(self.takes):
            with open(os.path.join(out, "run.ndjson"), "w") as f:
                f.write("".join(json.dumps(i) + "\n" for i in intervals if i["category"] in categories))
        if self.faults.get("pane_gone") == f"after {name}":
            self.faults["pane_gone"] = "now"

    def order(self):
        chosen = next((tab["id"] for tab in self.tabs if tab["selected"]), None)
        ids = [tab["id"] for tab in self.tabs]
        return {"tabs": ids, "kinds": [tab["kind"] for tab in self.tabs], "selected": chosen, "provisional": 0,
                "focus_tab": chosen, "consistent": True, "mismatches": [], "focus_tabs": ids}

    @staticmethod
    def interval(name, category, at, ms, fields):
        return {"name": name, "category": category, "ms": ms, "at_s": at, "fields": fields, "end_fields": {},
                "missed": False, "nested_loop": False}


class Builder:
    """perf-stress-session.py's `Stress` on the fake app."""

    def __init__(self, world):
        self.world, self.measured, self.made = world, None, {}

    def workspaces(self):
        return self.world.workspaces()

    def workspace(self, ident):
        return next((w for w in self.workspaces() if w["id"] == ident), None)

    @staticmethod
    def panes(workspace):
        return [pane for screen in (workspace or {}).get("screens") or [] for pane in screen.get("panes") or []]

    def new_workspace(self):
        self.world.space, self.world.tabs = "ws1", [self.world.tab("terminal", selected=True)]
        return "ws1"

    def show(self, workspace):
        pass

    def focus_pane(self, pane):
        if self.world.faults.get("no_focus"):
            raise ShapeError(f"focus never reached pane {pane}")

    def tabs(self, workspace, pane):
        return next((p["tabs"] for p in self.panes(self.workspace(workspace)) if p["id"] == pane), [])

    def settled_tabs(self, workspace, pane, seconds=20):
        return self.tabs(workspace, pane)

    def add_tab(self, workspace, pane, kind):
        if self.world.faults.get("add_tab_raises") and self.world.records:
            # The session helper's own exception class and words for a tab that did not come.
            raise RuntimeError(f"{kind} tab did not appear in {pane} in 20 s")
        if not self.world.faults.get("no_tab_comes_back") or self.world.records == 0:
            self.world.add(kind)
        self.world.given += 1

    def action(self, name, args=None, target=None, focus=True, timeout=120, settle=0.0):
        if name == "closeTab":
            self.world.close(next(tab for tab in self.world.tabs if f"tab:{tab['id']}" == target))
        return {}


class Stress:
    """The module perf-stress-session.py, as the script uses it."""
    StressShapeError, wait = ShapeError, staticmethod(wait)

    def __init__(self, world):
        self.world = world

    def socket_rpc(self, path):
        return self.world.rpc

    def Stress(self, rpc, log=None):
        return Builder(self.world)


class Child:
    """A take's child process. One that `hangs` does not end in a bound: it ends by the kill of its group."""
    pid = 4242

    def __init__(self, world, command, hangs):
        self.world, self.command, self.hangs = world, command, hangs

    def wait(self, timeout=None):
        if self.hangs and not self.world.kills:
            raise subprocess.TimeoutExpired(self.command, timeout)
        return -9 if self.hangs else 0


class Recorder:
    """`subprocess` for `run()`: the one child of a take is the signpost recorder with the take's own command. The
    fault `take_never_ends` names the take (a count from 1) whose child hangs: it makes no record."""
    DEVNULL = -3
    SubprocessError, TimeoutExpired = subprocess.SubprocessError, subprocess.TimeoutExpired

    def __init__(self, world):
        self.world = world

    def take(self, command):
        value = lambda flag: command[command.index(flag) + 1]
        categories = [command[i + 1] for i, part in enumerate(command) if part == "--category"]
        self.world.take(value("--row"), value("--out"), categories, int(value("--keep")), "--film" in command, value("--launch-form"))

    def Popen(self, command, **options):
        self.world.records += 1
        hangs = self.world.records == self.world.faults.get("take_never_ends")
        self.world.children.append({"new_session": options.get("start_new_session"), "hangs": hangs})
        if not hangs:
            self.take(command)
        return Child(self.world, command, hangs)

    def run(self, command, **options):
        """A caller that gives its child no bound waits to the child's end."""
        self.world.records += 1
        self.take(command)
        return argparse.Namespace(returncode=0)


class Signposts:
    """perf-signposts.py for a stream that the fake take wrote: one interval a line."""

    @staticmethod
    def local_timebase():
        return None

    @staticmethod
    def parse(lines, timebase):
        return {"intervals": [json.loads(line) for line in lines], "lost": 0, "unpaired": 0}


TICKS = itertools.count()


class Clock:
    """The script's `time`: a counter (1 ms a read) and no sleep, so no test reads a real clock; the uptime clock is
    the fake app's."""
    monotonic = time = staticmethod(lambda: next(TICKS) / 1000)
    CLOCK_UPTIME_RAW, world = 8, None

    @staticmethod
    def sleep(seconds):
        pass

    @classmethod
    def clock_gettime(cls, which):
        return cls.world.now


class Inline:
    """`threading.Thread` for a test: `start()` runs the target to its end in the caller's thread, so the test has no
    second thread. `made` has each thread that the script asked for."""
    made = []

    def __init__(self, target=None, args=(), daemon=None):
        self.target, self.args = target, args
        Inline.made.append(self)

    def start(self):
        self.target(*self.args)

    def join(self, timeout=None):
        pass


@contextlib.contextmanager
def one_thread_and_a_clock_that_moves(world):
    """The `one-key` form with no second thread and no real clock: a thread runs in its caller (`Inline`), and a sleep
    moves the fake app's clock by its own length (a call moves it by the fault `call_s`)."""
    Inline.made = []

    def sleep(seconds):
        world.now += seconds

    with mock.patch.object(Clock, "sleep", staticmethod(sleep)), mock.patch.object(M, "threading", argparse.Namespace(Thread=Inline)):
        yield


class Case(unittest.TestCase):
    def setUp(self):
        self.out = tempfile.mkdtemp(prefix="held-new-tab-test-")
        self.addCleanup(shutil.rmtree, self.out, ignore_errors=True)

    @contextlib.contextmanager
    def fakes(self, world):
        Clock.world = world
        with contextlib.ExitStack() as stack:
            for name, fake in (("STRESS", Stress(world)), ("subprocess", Recorder(world)), ("daemon_of", lambda app: ("/fake.sock", [])),
                               ("seed", lambda *args: ({}, 0, 0, [])), ("stats", lambda path: {}),
                               ("slow_records", lambda roots, start, end: []), ("bluetoothd", lambda: ["1"]),
                               ("bluetoothd_starts", lambda start, end: 0), ("time", Clock)):
                stack.enter_context(mock.patch.object(M, name, fake))
            # No signal goes to a process: the fake app keeps each kill of a process group.
            stack.enter_context(mock.patch.object(M.os, "killpg", lambda group, sent: world.kills.append((group, sent))))
            stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
            yield

    def rows(self, world, rounds=1, form="one-key", film=None):
        """`run()` on the fake app: the report."""
        opts = argparse.Namespace(workspaces=3, live_shells=0, page_url="http://127.0.0.1:9/", seed_deadline=1.0, out=self.out,
                                  neighbours=2, rounds=rounds, film=film, keys="app-queue", hold_ms=3000.0, every_ms=500.0,
                                  repeat_delay_ms=0.0, repeat_ms=0.0, deadline=1.0)
        app = argparse.Namespace(rpc=world.rpc, socket="/fake-app.sock", process=argparse.Namespace(pid=1))
        report = {"rows": [], "failures": []}
        with self.fakes(world):
            M.run(opts, app, Signposts, report, form)
        return report

    def rows_or_fail(self, world, **options):
        """`rows`, and a failure of the test (not an error) when a fault of the fake app leaves `run()`."""
        try:
            return self.rows(world, **options)
        except Exception as error:  # noqa: BLE001  each class: the row that was measured is lost with it
            self.fail(f"run() stopped and the measured row is lost: {error!r}")

    def record(self, world, row="hold", form="activate", film=None, more=()):
        """`take()` on the fake app: the record that it wrote. `more`: the kinds of the tabs that the pane has after
        its first tab (a terminal) when the take starts; the last one is the selected tab."""
        Builder(world).new_workspace()
        for kind in more:
            world.add(kind)
        opts = argparse.Namespace(socket="/fake-app.sock", workspace="ws1", pane="pane1", row=row, launch_form=form, out=self.out,
                                  keys="app-queue", hold_ms=100.0, every_ms=500.0, repeat_delay_ms=20.0, repeat_ms=20.0, keep=1,
                                  film=film, deadline=1.0)
        with self.fakes(world):
            M.take(opts)
        with open(os.path.join(self.out, "scenario.json")) as f:
            return json.load(f)


def order(tabs, kinds, selected):
    return {"tabs": list(tabs), "kinds": list(kinds), "selected": selected, "provisional": sum(t.startswith("pending_tab_") for t in tabs),
            "focus_tab": selected, "consistent": True, "mismatches": [], "focus_tabs": list(tabs)}


def keys(letters, before, after, closed=()):
    """A take's record for `order_row`: the keys 0.1 s apart, and the tab that each Cmd-W closed by the app's own mark."""
    times = [100.0 + 0.1 * index for index in range(len(letters))]
    close_times = [at for letter, at in zip(letters, times) if letter == "w"]
    marks = [{"kind": "closed", "event_s": at, "tabs": [tab], "empties_pane": False} for at, tab in zip(close_times, closed)]
    fates = ["created" if letter == "t" else "closed" for letter in letters]
    return {"press_letters": list(letters), "press_times_s": times, "trace": {"events": marks}, "order": {"before": before, "after": after}}, fates


class OrderRow(unittest.TestCase):
    """`order_row`: the model against the app, tab by tab and key by key, by the ids."""
    OLD = {"kind": "terminal", "from": "before the row"}
    HELD = order(["o1", "o2", "n1", "n2", "n3", "o3"], ["terminal", "terminal", "newtab", "newtab", "newtab", "terminal"], "n3")
    OPENERS = {"n1": "o2", "n2": "n1", "n3": "n2"}

    def test_a_close_of_another_tab_is_named_by_its_key_and_by_the_ids(self):
        record, fates = keys("www", self.HELD, order(["o1", "n1", "o3"], ["terminal", "newtab", "terminal"], "n1"), closed=["n3", "n2", "o2"])
        row, openers = M.order_row(record, fates, dict(self.OPENERS))
        self.assertIs(row["equal"], False)
        self.assertEqual(row.get("first_difference"),
                         {"where": "key", "key": 2, "letter": "w", "expected": {"tab": "n1", "kind": "newtab", "from": "before the row"},
                          "got": [{"tab": "o2", **self.OLD}]})
        self.assertIsNone(openers)

    def test_closes_that_follow_the_rule_are_equal_by_identity(self):
        record, fates = keys("www", self.HELD, order(["o1", "o2", "o3"], ["terminal"] * 3, "o2"), closed=["n3", "n2", "n1"])
        row, openers = M.order_row(record, fates, dict(self.OPENERS))
        self.assertIs(row["equal"], True)
        self.assertEqual((row.get("order_by"), row.get("first_difference", "no such field"), openers), ("identity", None, {}))

    def test_a_new_tab_gets_its_id_from_the_close_that_names_it(self):
        record, fates = keys("ttwtw", order(["a"], ["terminal"], "a"), order(["a", "x1"], ["terminal", "newtab"], "x1"), closed=["x2", "x3"])
        row, openers = M.order_row(record, fates, {})
        self.assertIs(row["equal"], True)
        self.assertEqual(row.get("new_tabs"), {"made": 3, "named_by_a_close": 2, "known_by_place": 1})
        self.assertEqual(openers, {"x1": "a"})

    def test_a_close_of_an_old_tab_is_not_the_close_of_the_new_tab_that_the_model_has(self):
        record, fates = keys("tw", order(["a", "b"], ["terminal"] * 2, "a"), order(["a", "x1"], ["terminal", "newtab"], "x1"), closed=["b"])
        row, _ = M.order_row(record, fates, {})
        self.assertIs(row["equal"], False)
        self.assertEqual(row.get("first_difference"),
                         {"where": "key", "key": 1, "letter": "w", "expected": {"tab": None, "kind": None, "from": "key 0 of the row"},
                          "got": [{"tab": "b", **self.OLD}]})

    def test_the_list_at_the_end_names_the_first_tab_that_differs(self):
        after = order(["a", "x1", "b", "x2"], ["terminal", "newtab", "terminal", "newtab"], "x2")
        record, fates = keys("tt", order(["a", "b"], ["terminal"] * 2, "a"), after)
        row, _ = M.order_row(record, fates, {})
        self.assertIs(row["equal"], False)
        self.assertEqual(row.get("first_difference"),
                         {"where": "list", "place": 2, "expected": {"tab": None, "kind": None, "from": "key 1 of the row"},
                          "got": {"tab": "b", **self.OLD}})

    def test_the_selected_tab_is_compared_by_its_id(self):
        record, fates = keys("t", order(["a", "b"], ["terminal"] * 2, "a"), order(["a", "x1", "b"], ["terminal", "newtab", "terminal"], "a"))
        row, _ = M.order_row(record, fates, {})
        self.assertIs(row["equal"], False)
        self.assertEqual(row.get("first_difference"),
                         {"where": "selected", "expected": {"tab": "x1", "kind": "newtab", "from": "key 0 of the row"},
                          "got": {"tab": "a", **self.OLD}})

    def test_a_row_with_no_openers_from_the_row_before_has_no_verdict(self):
        record, fates = keys("www", self.HELD, order(["o1", "o2", "o3"], ["terminal"] * 3, "o2"), closed=["n3", "n2", "n1"])
        row, openers = M.order_row(record, fates, None)
        self.assertIsNone(row["equal"])
        self.assertIn("openers", row["why"])
        self.assertIsNone(openers)

    def test_a_list_with_a_stand_in_tab_gives_the_next_row_no_openers(self):
        record, fates = keys("t", order(["a"], ["terminal"], "a"), order(["a", "pending_tab_1"], ["terminal", "newtab"], "pending_tab_1"))
        row, openers = M.order_row(record, fates, {})
        self.assertEqual((row.get("provisional_after"), openers), (1, None))

    def test_a_list_with_a_stand_in_tab_has_no_verdict(self):
        record, fates = keys("t", order(["a"], ["terminal"], "a"), order(["a", "pending_tab_1"], ["terminal", "newtab"], "pending_tab_1"))
        row, _ = M.order_row(record, fates, {})
        self.assertEqual((row["equal"], row.get("provisional_after")), (None, 1))
        self.assertIn("stand-in", row.get("why", ""))

    def test_a_close_of_a_new_tab_names_that_tab_and_is_not_counted_as_checked(self):
        """The app closes the FIRST new tab and not the selected one: the tool cannot see it (the close gives the
        model's tab its id), so the row must not say that it checked this close by identity."""
        record, fates = keys("ttw", order(["a"], ["terminal"], "a"), order(["a", "x2"], ["terminal", "newtab"], "x2"), closed=["x1"])
        row, _ = M.order_row(record, fates, {})
        self.assertIs(row["equal"], True)
        self.assertEqual((row.get("closes_checked_by_id"), row.get("new_tabs"), row.get("order_by")),
                         (0, {"made": 2, "named_by_a_close": 1, "known_by_place": 1}, "identity and place"))
        self.assertIn("not checked for which new tab it closed", row["limit"])

    def test_a_close_of_a_tab_that_had_its_id_is_counted_as_checked(self):
        record, fates = keys("www", self.HELD, order(["o1", "o2", "o3"], ["terminal"] * 3, "o2"), closed=["n3", "n2", "n1"])
        row, _ = M.order_row(record, fates, dict(self.OPENERS))
        self.assertEqual((row.get("closes_checked_by_id"), row.get("order_by")), (3, "identity"))

    def test_the_row_says_how_the_tabs_were_checked_and_its_word_for_equal_by_place_says_so(self):
        """`equal` alone says too much for a row that checked no close by a tab's id: the row has one field for how the
        tabs were checked and one word for a reader to print."""
        record, fates = keys("ttw", order(["a"], ["terminal"], "a"), order(["a", "x2"], ["terminal", "newtab"], "x2"), closed=["x1"])
        row, _ = M.order_row(record, fates, {})
        self.assertEqual((row["equal"], row.get("closes_checked_by_id"), row.get("tabs_checked"), row.get("verdict")),
                         (True, 0, "by place only", "equal, by place only"))
        record, fates = keys("www", self.HELD, order(["o1", "o2", "o3"], ["terminal"] * 3, "o2"), closed=["n3", "n2", "n1"])
        row, _ = M.order_row(record, fates, dict(self.OPENERS))
        self.assertEqual((row["equal"], row.get("tabs_checked"), row.get("verdict")), (True, "by id", "equal"))
        record, fates = keys("www", self.HELD, order(["o1", "n1", "o3"], ["terminal", "newtab", "terminal"], "n1"), closed=["n3", "n2", "o2"])
        row, _ = M.order_row(record, fates, dict(self.OPENERS))
        self.assertEqual((row["equal"], row.get("verdict")), (False, "not equal"))
        row, _ = M.order_row(record, fates, None)
        self.assertEqual((row["equal"], row.get("verdict")), (None, "no verdict"))

    def test_a_key_with_no_record_of_what_it_did_gives_no_verdict(self):
        """The recording lost a record of one key (a `closed` mark: `no_outcome`; the action's run: `missing`). The
        app did the right thing in both cases, so `not equal` would blame it for the recording's loss."""
        cases = {"no_outcome": ("tw", order(["a", "b"], ["terminal"] * 2, "a"), order(["a", "b"], ["terminal"] * 2, "a")),
                 "missing": ("tt", order(["a"], ["terminal"], "a"), order(["a", "x1", "x2"], ["terminal", "newtab", "newtab"], "x2"))}
        for fate, (letters, before, after) in cases.items():
            record, fates = keys(letters, before, after)
            fates[1] = fate
            row, openers = M.order_row(record, fates, {})
            self.assertEqual((row["equal"], openers), (None, None), fate)
            self.assertIn(f"key 1 has the fate {fate}", row.get("why", ""))

    def test_no_verdict_says_which_cause_it_has(self):
        before, after = order(["a"], ["terminal"], "a"), order(["a", "x1"], ["terminal", "newtab"], "x1")
        record, fates = keys("t", before, after)
        whys = {}
        for cause, (orders, given) in {"before": ({"after": after}, fates), "after": ({"before": before}, fates),
                                       "fates": ({"before": before, "after": after}, [])}.items():
            row, openers = M.order_row({**record, "order": orders}, given, {})
            self.assertEqual((row["equal"], openers), (None, None), cause)
            whys[cause] = row["why"]
        self.assertEqual(len(set(whys.values())), 3, whys)
        self.assertIn("before the keys", whys["before"])
        self.assertIn("after the keys", whys["after"])
        self.assertIn("fate", whys["fates"])

    def test_a_start_with_no_known_selected_tab_has_no_verdict(self):
        after = order(["a", "b", "x1"], ["terminal", "terminal", "newtab"], "x1")
        record, fates = keys("t", order(["a", "b"], ["terminal"] * 2, None), after)
        row, openers = M.order_row(record, fates, {})
        self.assertEqual((row["equal"], openers), (None, None))
        self.assertIn("selected", row.get("why", ""))

    def test_the_rule_of_a_close_is_the_one_that_it_was(self):
        """A pin: this change does not touch the rule (a tab it opened, a tab of the same opener, its opener, the next,
        the previous)."""
        tabs, selected, openers = M.oracle(["a", "b", "c"], "b", {"c": "b"}, "w")
        self.assertEqual((tabs, selected), (["a", "c"], "c"))
        tabs, selected, openers = M.oracle(["a", "b", "c"], "c", {}, "wt")
        self.assertEqual((tabs, selected, openers), (["a", "b", ("new", 1)], ("new", 1), {("new", 1): "b"}))


class Rows(Case):
    """`run()`: the rows of a run on the fake app."""

    def test_a_row_names_the_launch_form_as_its_key_source(self):
        report = self.rows(World())
        self.assertEqual([row.get("key_source") for row in report["rows"][:3]], ["one-key"] * 3)

    def test_a_tab_of_the_start_that_a_row_closed_comes_back(self):
        world = World(close_another_tab_at=5)  # `mixed` has 2 Cmd-W, `close` has 4: the third one of `close`
        report = self.rows(world, rounds=2)
        close = next(row for row in report["rows"] if row["scenario"] == "close")
        self.assertEqual((close.get("tabs_given_back"), close.get("not_restored")), (1, []))
        self.assertEqual([take["tabs_at_start"] for take in world.takes if take["row"] == "mixed"], [3, 3])
        self.assertIs(close["order"]["equal"], False)
        self.assertEqual(close["order"]["first_difference"]["got"], [{"tab": "tab1", "kind": "terminal", "from": "before the row"}])

    def test_a_restore_that_leaves_a_difference_is_a_failure_of_the_run(self):
        report = self.rows(World(close_another_tab_at=5, no_tab_comes_back=True))
        self.assertTrue([why for why in report["failures"] if "not restored" in why], report["failures"])

    def test_a_tab_that_does_not_come_back_by_the_helpers_exception_keeps_the_row(self):
        report = self.rows_or_fail(World(close_another_tab_at=5, add_tab_raises=True))
        self.assertEqual([row["scenario"] for row in report["rows"]], ["mixed", "hold", "close", "hold-wide"])
        close = report["rows"][2]
        self.assertEqual((close.get("tabs_given_back"), len(close.get("not_restored") or [])), (0, 1))
        self.assertIn("did not come back: terminal tab did not appear in pane1 in 20 s", close["not_restored"][0])
        self.assertTrue([why for why in report["failures"] if "not restored" in why], report["failures"])

    def test_a_fault_of_the_read_of_the_opens_keeps_the_row(self):
        report = self.rows_or_fail(World(opens_are_no_records=True))
        self.assertEqual(len(report["rows"]), 4)
        self.assertIn("AttributeError", report["rows"][0].get("opens_error", ""))

    def test_a_take_that_does_not_end_is_killed_with_its_group_and_has_its_row(self):
        world = World(take_never_ends=2)  # the second take: `hold`
        report = self.rows(world)
        self.assertEqual([(row["scenario"], bool(row.get("errors"))) for row in report["rows"]], [("mixed", False), ("hold", True)])
        self.assertIn("did not end", report["rows"][1]["errors"][0])
        self.assertEqual(world.kills, [(Child.pid, signal.SIGKILL)])  # ONE kill, of the child's own group
        self.assertEqual([child["new_session"] for child in world.children], [True, True])  # so the group is the child's
        self.assertEqual([take["row"] for take in world.takes], ["mixed"])  # the run ends there: no key for an app that does not answer
        self.assertTrue([why for why in report["failures"] if "did not end" in why], report["failures"])

    def test_a_right_app_is_equal_in_each_row_and_each_close_of_close_is_checked_by_its_id(self):
        report = self.rows(World())
        self.assertEqual([row["order"]["equal"] for row in report["rows"]], [True] * 4)
        close = report["rows"][2]["order"]
        self.assertEqual((close.get("closes_checked_by_id"), close.get("order_by"), close.get("openers_at_start")), (4, "identity", 4))

    def test_each_row_has_the_proof_that_the_app_got_the_keys_in_the_order_of_the_tool(self):
        report = self.rows(World())
        for row in report["rows"]:
            proof = row.get("input_order") or {}
            self.assertEqual((proof.get("in_key_order"), proof.get("acts"), proof.get("acts_after_a_later_key"), row.get("invalid")),
                             (True, row["keys_posted"], 0, []), row["scenario"])
            self.assertEqual((row.get("state"), (row.get("key_calls") or {}).get(IN_TURN), "finding" in row, HIDDEN in row),
                             ("valid", True, False, False), row["scenario"])
        self.assertEqual(M.exit_code(report, 1), 0)

    def test_two_keys_that_the_app_got_in_the_other_order_make_the_row_invalid_and_not_equal(self):
        """`mixed` is T T W T T W. The call of key 2 (the W) had not ended when the call of key 3 (a T) started, so the app
        can get key 3 first: the W then closes the tab of key 3, and the end list has the same count and the same kinds
        as a run in key order. A model that walks the keys by their number says `equal` for it."""
        report = self.rows(World(keys_change_places={1: (2, 3)}, calls_overlap={1: 2}))
        mixed = report["rows"][0]
        proof, order = mixed.get("input_order") or {}, mixed["order"]
        self.assertEqual((proof.get("in_key_order"), proof.get("acts"), proof.get("acts_after_a_later_key"), proof.get("first")),
                         (False, 6, 1, {"key": 2, "ran_after_key": 3}))
        self.assertEqual((mixed.get("state"), (mixed.get("key_calls") or {}).get(IN_TURN), "finding" in mixed), ("INVALID", False, False))
        self.assertTrue([why for why in mixed.get("invalid") or [] if "another order" in why and "the tool has no proof" in why],
                        mixed.get("invalid"))
        self.assertEqual((order["equal"], order.get("verdict")), (None, "INVALID"))
        self.assertIn("another order", order.get("why", ""))
        self.assertTrue([why for why in report["failures"] if why.startswith("0 mixed: ") and "another order" in why], report["failures"])
        # The model follows the acts, so it can still say if the app kept the rule for the order that it ran. That word
        # is no verdict of the row: it has a name of its own, below the key that says the state of the row.
        self.assertNotIn("by_the_acts", order)
        model = (mixed.get(HIDDEN) or {}).get("order_by_the_acts") or {}
        self.assertEqual((model.get("model_by_the_acts_matches"), model.get("first_difference"), "equal" in model, "verdict" in model),
                         (True, None, False, False))
        self.assertEqual([(row.get("invalid"), row.get("state")) for row in report["rows"][1:]], [([], "valid")] * 3)
        self.assertEqual(M.exit_code(report, 1), 2)

    def test_two_closes_that_the_app_got_in_the_other_order_do_not_blame_the_app(self):
        """`close` is W W W W on the 4 tabs of `hold`. The call of key 0 had not ended when the call of key 1 started. The
        app gets key 1 before key 0 and closes the right tab at each: a model that walks the keys by their number says
        that key 0 closed another tab than the selected one."""
        report = self.rows(World(keys_change_places={3: (0, 1)}, calls_overlap={3: 0}))
        close = report["rows"][2]
        order = close["order"]
        self.assertEqual(((close.get("input_order") or {}).get("first"), order["equal"], order.get("verdict"), close.get("state")),
                         ({"key": 0, "ran_after_key": 1}, None, "INVALID", "INVALID"))
        model = (close.get(HIDDEN) or {}).get("order_by_the_acts") or {}
        self.assertEqual((model.get("model_by_the_acts_matches"), model.get("first_difference"), model.get("closes_checked_by_id")),
                         (True, None, 4))

    def test_acts_in_another_order_are_invalid_when_one_call_of_the_row_has_no_reply_or_the_app_plays_the_keys(self):
        """The proof that the tool sent the keys in order must be true for the whole row. A call of another key than the 2
        (key 5) that ended with no reply, and the `activate` form (the app plays the sequence: the tool makes no call
        for each key), leave it open: the row is INVALID, not a finding."""
        for said, world, form in ((False, World(keys_change_places={1: (2, 3)}, call_with_no_reply={1: 5}), "one-key"),
                                  (None, World(keys_change_places={1: (2, 3)}), "activate")):
            with self.subTest(form=form):
                mixed = self.rows(world, form=form)["rows"][0]
                self.assertEqual((mixed.get("state"), (mixed.get("key_calls") or {}).get(IN_TURN, "no such field"), "finding" in mixed,
                                  mixed["order"].get("verdict")), ("INVALID", said, False, "INVALID"))
                self.assertTrue([why for why in mixed.get("invalid") or [] if "the tool has no proof" in why], mixed.get("invalid"))

    def test_acts_in_another_order_are_invalid_when_one_call_ended_with_an_error_in_the_form_of_a_reply(self):
        """The call of key 5 ended with the client's own error (a time-out), which the client gives in the form of a
        reply. The tool does not know if the app got that key, so it has no proof of its send for the row: 2 acts in
        another order make the row INVALID, and the row does not put the order on the app."""
        report = self.rows(World(keys_change_places={1: (2, 3)}, call_with_an_error_reply={1: 5}))
        mixed = report["rows"][0]
        self.assertEqual((mixed.get("state"), (mixed.get("key_calls") or {}).get(IN_TURN, "no such field"), "finding" in mixed,
                          mixed["order"].get("verdict")), ("INVALID", False, False, "INVALID"))
        self.assertTrue([why for why in mixed.get("invalid") or [] if "the tool has no proof" in why], mixed.get("invalid"))
        self.assertEqual(mixed.get("errors"), ["keys: key 5: timed out"])
        self.assertFalse([why for why in report["failures"] if "THE APP RAN" in why], report["failures"])

    def test_a_row_with_an_error_and_no_other_cause_has_an_entry_of_invalid_and_its_state(self):
        """A reader that knows only `invalid` (the bench) takes each number of a row with no entry there. A row with an
        error of its take and a true proof of the order gets ONE entry that says so; its fields stay where they are,
        and the run's failures name the error one time."""
        report = self.rows(World(record_error={1: "a fake error of the take"}))
        mixed = report["rows"][0]
        self.assertEqual(((mixed.get("input_order") or {}).get("in_key_order"), mixed.get("state"), mixed.get("errors")),
                         (True, "INVALID", ["a fake error of the take"]))
        self.assertEqual(len(mixed.get("invalid") or []), 1, mixed.get("invalid"))
        self.assertIn("no number of this row is for a person", mixed["invalid"][0])
        self.assertEqual((HIDDEN in mixed, "tabs_made" in mixed), (False, True))
        self.assertEqual([why for why in report["failures"] if why.startswith("0 mixed: ")], ["0 mixed: a fake error of the take"])
        self.assertEqual([(row.get("invalid"), row.get("state")) for row in report["rows"][1:]], [([], "valid")] * 3)
        self.assertEqual(M.exit_code(report, 1), 2)

    def test_a_take_whose_record_has_an_entry_of_invalid_is_an_invalid_row_and_a_failure_of_the_run(self):
        why = "the app refused a key window word after the frames started"
        report = self.rows(World(record_invalid={2: why}))
        row = report["rows"][1]
        self.assertEqual((row["scenario"], row["state"], row["invalid"], M.valid(row)), ("hold", "INVALID", [why], False))
        self.assertIn(f"0 hold: {why}", report["failures"])

    def test_a_row_with_no_signpost_stream_is_invalid_and_has_no_number_outside_the_key_that_says_so(self):
        """The recorder made no stream: the row has no fate of a key and so no proof of the order of its keys. A count of
        0 made tabs is then the recorder's fault, not a measure: the row is INVALID for each reader, and its numbers
        are below the key that says that they are not for a person."""
        report = self.rows(World(no_stream=1))
        mixed = report["rows"][0]
        self.assertEqual((mixed.get("state"), mixed.get("errors")), ("INVALID", ["no signpost stream"]))
        self.assertEqual(len(mixed.get("invalid") or []), 1, mixed.get("invalid"))
        self.assertIn("no number of this row is for a person", mixed["invalid"][0])
        numbers = {"tabs_made", "tabs_closed", "keys_without_effect", "daemon_requests", "daemon_slow"}
        hidden = mixed.get(HIDDEN) or {}
        self.assertEqual((numbers & set(mixed), numbers - set(hidden)), (set(), set()))
        self.assertIn("not for a person", hidden.get("why", ""))
        self.assertNotIn("order_by_the_acts", hidden)
        self.assertEqual((mixed["order"]["equal"], "input_order" in mixed), (None, False))
        self.assertEqual([why for why in report["failures"] if why.startswith("0 mixed: ")], ["0 mixed: no signpost stream"])

    def test_a_row_with_no_fate_of_its_keys_is_not_valid(self):
        """`valid` needs the proof of the order. A row with no fate of each key has none, with or without an error."""
        real = M.BENCH.summarize

        def no_fates(*args, **more):
            return {key: value for key, value in real(*args, **more).items() if key != "press_fates"}

        with mock.patch.object(M.BENCH, "summarize", no_fates):
            report = self.rows(World())
        mixed = report["rows"][0]
        self.assertEqual((mixed.get("state"), mixed.get("errors") or [], "input_order" in mixed), ("INVALID", [], False))
        self.assertTrue([why for why in mixed.get("invalid") or [] if why.startswith("no proof of the order of the keys")],
                        mixed.get("invalid"))
        self.assertEqual(({"tabs_made", "frames", "input_to_next_commit_ms"} & set(mixed), HIDDEN in mixed), (set(), True))

    def test_the_row_of_a_killed_take_and_a_row_that_was_not_run_have_their_state_and_an_entry_of_invalid(self):
        killed = self.rows(World(take_never_ends=2))["rows"][1]
        self.assertEqual((killed.get("state"), len(killed.get("errors") or []), len(killed.get("invalid") or [])), ("INVALID", 1, 1))
        self.assertIn("no number of this row is for a person", killed["invalid"][0])
        report = self.rows(World(pane_gone="after mixed"))
        not_run = report["rows"][1]
        self.assertEqual((not_run.get("state"), len(not_run.get("invalid") or [])), ("INVALID", 1))
        self.assertTrue(not_run["invalid"][0].startswith("not run: "), not_run["invalid"])

    def test_acts_in_another_order_with_each_call_ended_before_the_next_are_a_finding_row(self):
        """`mixed` is T T W T T W. Each call ended with its reply before the next call started, so the app got the keys in
        the tool's order, and it ran the action of key 3 (a T) before the action of key 2 (the W). That is not a fault of
        the tool: the row is a finding. It names the 2 keys and the 2 acts, the run has a failure for it, and the tool's
        exit is not 0."""
        report = self.rows(World(keys_change_places={1: (2, 3)}))
        mixed = report["rows"][0]
        proof, found = mixed.get("input_order") or {}, mixed.get("finding") or {}
        self.assertEqual((proof.get("in_key_order"), proof.get("first"), (mixed.get("key_calls") or {}).get(IN_TURN)),
                         (False, {"key": 2, "ran_after_key": 3}, True))
        self.assertEqual((mixed.get("state"), found.get("word")), ("finding", "THE APP RAN THE ACTIONS IN ANOTHER ORDER THAN THE KEYS"))
        self.assertEqual([(key.get("key"), key.get("letter"), key.get("action"), key.get("act")) for key in found.get("keys") or []],
                         [(2, "w", ACTION["w"], 4), (3, "t", ACTION["t"], 3)])
        self.assertEqual((found.get("acts"), found.get("acts_after_a_later_key")), (6, 1))
        self.assertEqual((mixed["order"]["equal"], mixed["order"].get("verdict")), (None, "finding"))
        # A reader that knows only `invalid` (the bench) takes no number of the row and prints the finding's word.
        self.assertEqual(len(mixed.get("invalid") or []), 1, mixed.get("invalid"))
        self.assertTrue(mixed["invalid"][0].startswith(found["word"] + ": key 2 (Cmd-W, closeTab) ran after key 3 (Cmd-T, newTab.default)"),
                        mixed["invalid"])
        self.assertNotIn("the tool has no proof", mixed["invalid"][0])
        self.assertTrue([why for why in report["failures"] if why.startswith("0 mixed: " + found["word"])], report["failures"])
        self.assertEqual([(row.get("invalid"), row.get("state")) for row in report["rows"][1:]], [([], "valid")] * 3)
        self.assertEqual(M.exit_code(report, 1), 2)

    def test_a_finding_row_says_of_each_of_its_2_keys_if_its_reply_came_before_its_action_started(self):
        """The fake app's reply to a key comes 3 ms after the key. It ran the action of key 3 after 2 ms (before the reply),
        and the action of key 2 after 104 ms: the reply to key 2 came before its action started, so the app kept that
        key and ran its action later. That is the path that the finding names."""
        found = self.rows(World(keys_change_places={1: (2, 3)}))["rows"][0].get("finding") or {}
        self.assertEqual([(key.get("key"), key.get("reply_ms_after_the_key"), key.get("action_started_ms_after_the_key"),
                           key.get("reply_before_the_action_start")) for key in found.get("keys") or []],
                         [(2, 3.0, 104.0, True), (3, 3.0, 2.0, False)])
        self.assertIn("planned time", found.get("times_from", ""))
        self.assertIn("the reply to key 2 came before its action started", found.get("path", ""))
        self.assertNotIn("key 3", found.get("path", ""))

    def test_a_finding_row_with_no_time_of_a_call_does_not_name_a_path(self):
        record = {"press_times_s": [100.0, 100.1], "press_letters": ["t", "t"], "key_calls": {}}
        runs = {0: {"perform": {"at_s": 100.3}}, 1: {"perform": {"at_s": 100.2}}}
        found = M.finding({"acts": 2, "acts_after_a_later_key": 1, "first": {"key": 0, "ran_after_key": 1}}, [1, 0], runs, record, "one-key")
        self.assertEqual([key.get("reply_before_the_action_start", "no such field") for key in found["keys"]], [None, None])
        self.assertIn("not known", found["path"])

    def test_a_key_with_no_record_of_its_action_makes_the_row_invalid_with_no_verdict(self):
        """Key 1 of each row did something and has no record of when its action ran: the order of the keys has no proof."""
        real = M.key_runs

        def less_one(intervals, record):
            runs = real(intervals, record)
            runs.pop(1, None)
            return runs

        with mock.patch.object(M, "key_runs", less_one):
            report = self.rows(World())
        for row in report["rows"]:
            proof = row.get("input_order") or {}
            self.assertEqual((proof.get("in_key_order", "no such field"), proof.get("keys_with_no_act_record"), row.get("state"),
                              row["order"]["equal"], row["order"].get("verdict")), (None, 1, "INVALID", None, "no verdict"), row["scenario"])
            self.assertTrue([why for why in row.get("invalid") or [] if why.startswith("no proof of the order of the keys: 1 keys")],
                            row.get("invalid"))
            self.assertNotIn("finding", row)
        self.assertTrue([why for why in report["failures"] if why.startswith("0 mixed: no proof of the order")], report["failures"])
        self.assertEqual(M.exit_code(report, 1), 1)  # the round has no valid row

    def test_a_row_with_no_proof_of_the_keys_order_has_no_number_outside_the_key_that_says_so(self):
        """The full set of keys of a `mixed` row in each state that is not `valid` for the order of its keys: INVALID
        (acts in another order, the calls overlapped), no proof (a key with no record of its action, a fault of the proof)
        and a finding. Each number of the row and the model's word are below ONE key whose name says that they are not
        for a person; no field of the row has the name `equal` but the row's own verdict, which is null."""
        real = M.key_runs

        def less_one(intervals, record):
            runs = real(intervals, record)
            runs.pop(1, None)
            return runs

        kept = {"scenario", "round", "state", "key_source", "key_form", "key_calls", "keys_posted", "errors", "invalid", "input_order",
                "order", "not_restored", "tabs_given_back", HIDDEN}
        numbers = {"frames", "input_to_next_commit_ms", "fates", "first_frame", "slow_keys", "tabs_made", "tabs_closed",
                   "keys_without_effect", "daemon_requests", "daemon_slow", "opens", "settled_ms", "order_by_the_acts", "why"}
        cases = (("INVALID", World(keys_change_places={1: (2, 3)}, calls_overlap={1: 2}), None, set()),
                 ("no proof", World(), mock.patch.object(M, "key_runs", less_one), set()),
                 ("a fault of the proof", World(), mock.patch.object(M, "input_order", side_effect=ValueError("a fake fault")), set()),
                 ("finding", World(keys_change_places={1: (2, 3)}), None, {"finding"}))
        for name, world, fault, more in cases:
            with self.subTest(state=name), fault or contextlib.nullcontext():
                mixed = self.rows(world)["rows"][0]
                self.assertEqual(set(mixed) - {"press_fates"}, kept | more)
                self.assertEqual(set(mixed["order"]), {"equal", "verdict", "why", "openers_at_start"})
                self.assertIsNone(mixed["order"]["equal"])
                hidden = mixed[HIDDEN]
                self.assertEqual(numbers - set(hidden), set())
                self.assertIn("not for a person", hidden["why"])
                self.assertEqual({key for key in hidden["order_by_the_acts"] if key in ("equal", "verdict", "by_the_acts")}, set())
                self.assertNotEqual(mixed.get("state"), "valid")
        # A row that is valid keeps each field where it was.
        valid = self.rows(World())["rows"][0]
        self.assertEqual((HIDDEN in valid, numbers - {"order_by_the_acts", "why"} - set(valid), valid["order"]["equal"]), (False, set(), True))

    def test_the_printed_row_of_a_finding_has_no_fate_list(self):
        out = io.StringIO()
        with mock.patch.object(M, "print", lambda *args, **kwargs: out.write(" ".join(map(str, args)) + "\n"), create=True):
            self.rows(World(keys_change_places={1: (2, 3)}))
        line = next(line for line in out.getvalue().splitlines() if line.startswith("HELD-NEW-TAB-ROW 0 mixed: "))
        printed = json.loads(line.split(": ", 1)[1])
        self.assertEqual((printed.get("state"), "press_fates" in printed, "press_fates" in printed.get(HIDDEN, {})), ("finding", False, False))

    def test_a_fault_of_the_order_is_no_verdict_with_its_words_and_the_first_frame_stays(self):
        with mock.patch.object(M, "order_row", side_effect=ValueError("a fake fault")):
            report = self.rows(World())
        for row in report["rows"]:
            order = row.get("order") or {}
            self.assertEqual((order.get("equal", "no such field"), "ValueError" in order.get("why", "")), (None, True), row["scenario"])
            self.assertIn("first_frame", row)

    def test_a_fault_of_the_first_frame_does_not_take_the_verdict_from_close(self):
        with mock.patch.object(M, "first_frame", side_effect=ValueError("a fake fault")):
            report = self.rows(World())
        close = report["rows"][2]
        self.assertEqual((close["order"]["equal"], close["order"].get("openers_at_start")), (True, 4))
        self.assertIn("ValueError", close.get("first_frame_error", ""))

    def test_close_with_no_openers_says_what_the_row_before_did(self):
        report = self.rows(World(new_tab_first_in_take=2))  # the second take: `hold` puts each new tab first
        hold, close = report["rows"][1]["order"], report["rows"][2]["order"]
        self.assertIs(hold["equal"], False)
        self.assertIsNone(close["equal"])
        self.assertIn("openers", close["why"])
        self.assertIn("not equal", close["why"])
        self.assertNotIn("stand-in", close["why"])  # that is another cause, and it is not the one of this run

    def test_a_take_whose_pane_is_gone_is_not_run(self):
        world = World(pane_gone="after mixed")
        report = self.rows(world)
        self.assertEqual([take["row"] for take in world.takes], ["mixed"])
        self.assertIn("pane", report["rows"][1].get("not_run") or "")
        self.assertTrue([why for why in report["failures"] if "not run" in why], report["failures"])

    def test_the_opens_of_a_row_have_their_main_thread_time(self):
        report = self.rows(World())
        hold = next(row for row in report["rows"] if row["scenario"] == "hold")
        # `hold` made 4 tabs after the 4 of `mixed`: the opens 4 to 7 of the fake app (2 from the ready page, 2 not).
        self.assertEqual((hold["opens"]["warm"], hold["opens"]["cold"]), (2, 2))
        self.assertEqual(hold["opens"].get("main_ms"),
                         {"warm": {"n": 2, "p50": 3.0, "p95": 3.0, "p99": 3.0, "max": 3.0, "sum": 6.0},
                          "cold": {"n": 2, "p50": 127.0, "p95": 127.0, "p99": 127.0, "max": 127.0, "sum": 252.0}})

    def test_a_slow_key_says_its_wait_and_its_commit_time(self):
        world = World()
        world.slow[(2, 1)] = (250.0, 30.0)  # the second take (`hold`), its key 1
        hold = next(row for row in self.rows(world)["rows"] if row["scenario"] == "hold")
        self.assertEqual(hold.get("slow_keys"),
                         {"over_ms": 200.0, "count": 1,
                          "keys": [{"key": 1, "letter": "t", "fate": "created", "key_to_commit_ms": 280.0, "age_at_action_start_ms": 2.0,
                                    "action_ms": 1.0, "age_at_commit_start_ms": 250.0, "commit_ms": 30.0}]})

    def test_the_wider_recording_is_one_more_take_after_the_rounds(self):
        world = World()
        report = self.rows(world, rounds=1)
        self.assertEqual([(take["row"], take["categories"]) for take in world.takes],
                         [("mixed", ["action"]), ("hold", ["action"]), ("close", ["action"]), ("hold", WIDE)])
        wide = report["rows"][-1]
        self.assertEqual((wide["round"], wide["scenario"]), ("wide", "hold-wide"))
        self.assertNotIn(",", M.WIDE_NAME)  # a reader that joins a row's labels with a comma gets one label
        self.assertEqual(wide.get("not_restored"), [])
        self.assertEqual(len(world.tabs), 3)

    def test_the_wider_recording_names_what_ran_between_a_slow_key_and_its_commit(self):
        world = World()
        world.slow[(4, 2)] = (250.0, 30.0)  # the fourth take (the wider recording), its key 2
        rows = self.rows(world)["rows"]
        self.assertEqual(len(rows), 4)
        found = rows[-1]["wider_recording"]
        self.assertEqual((found["categories"], found["key_form"], found["own_call_tasks_left_out"]), (WIDE, "one-key", 1))
        self.assertEqual(found["slow_keys"],
                         [{"key": 2, "key_to_commit_ms": 280.0,
                           "between": [{"what": "stall.main_task class=background owner=NewTabSparePool.warm", "ms": 180.0, "count": 1},
                                       {"what": "tab-switch.switch", "ms": 20.0, "count": 1}],
                           "own_call_tasks_left_out": {"count": 1, "ms": 270.0}}])


class FirstFrame(Case):
    """`first_frame`: which key a `show` record of the pane belongs to."""

    def test_a_show_belongs_to_the_key_whose_action_ran_last_before_it_and_not_to_the_key_with_the_highest_number(self):
        """Key 0 is at 100.0 s and key 1 at 100.1 s; the app ran key 1 first: its commit is 100.20 s to 100.21 s, and
        the commit of key 0 is 100.30 s to 100.31 s. Each tab was shown inside its own commit."""
        commit = lambda at, age: World.interval("action.commit", "action", at, 10.0,
                                                {"id": "newTab.default", "origin": "user", "input_age_ms": str(age)})
        ndjson = os.path.join(self.out, "run.ndjson")
        with open(ndjson, "w") as f:
            f.write("".join(json.dumps(interval) + "\n" for interval in (commit(100.2, 100.0), commit(100.3, 300.0))))
        record = {"press_letters": ["t", "t"], "press_times_s": [100.0, 100.1], "shows": [[100.205, "x1"], [100.305, "x0"]]}
        found = M.first_frame(Signposts, ndjson, record, ["created", "created"])
        self.assertEqual(found["by_key"]["t"], {"keys": 2, "shown": 2, "superseded": 0, "not_shown": 0})
        self.assertIn("by the act", found.get("paired", ""))
        self.assertIn("the tab that a show names is not compared", found.get("paired", ""))  # the limit of the pairing


class KeyCalls(Case):
    """The `one-key` form: who sends the calls, in which order, and what the record says of a call that takes long."""

    def test_one_thread_sends_the_keys_in_key_order_and_a_call_ends_before_the_next_one_starts(self):
        """4 keys, 20 ms apart (at 10, 30, 50 and 70 ms); each call takes 50 ms of the app's clock."""
        world = World(call_s=0.05)
        Builder(world).new_workspace()
        steps, offsets = M.BENCH.sequence(["t"] * 4, 0, (20.0, 20.0))
        with self.fakes(world), one_thread_and_a_clock_that_moves(world):
            sent = M.post_keys("app-queue", world.rpc, steps, "pane1", "one-key")
        self.assertEqual(len(Inline.made), 1, "each key has a thread of its own: 2 calls can reach the app in the other order")
        base = sent["base_s"]
        ms = lambda at: round((at - base) * 1000, 2)
        # No key is dropped, each event has its planned time, and a call starts when the call before it ended.
        self.assertEqual(([letter for letter, _, _ in world.sent], [ms(at) for _, at, _ in world.sent], [ms(start) for _, _, start in world.sent]),
                         (["t"] * 4, offsets, [10.0, 60.0, 110.0, 160.0]))
        self.assertEqual(sent.get("sends"), [[10.0, 10.0, 60.0], [30.0, 60.0, 110.0], [50.0, 110.0, 160.0], [70.0, 160.0, 210.0]])

    def test_the_record_of_a_take_has_the_real_time_of_each_call_against_its_planned_time(self):
        """`hold` of 6 keys 20 ms apart; each call takes 50 ms. No key is dropped, and the record says how late the
        calls started and which clock a number from a key's time starts at."""
        world = World(call_s=0.05)
        with one_thread_and_a_clock_that_moves(world):
            record = self.record(world, row="hold", form="one-key")
        calls = record.get("key_calls") or {}
        self.assertEqual((world.keys, len(Inline.made), len(record["press_times_s"])), (6, 1, 6))
        self.assertEqual(calls.get("calls"), [[10.0, 10.0, 60.0], [30.0, 60.0, 110.0], [50.0, 110.0, 160.0], [70.0, 160.0, 210.0],
                                              [90.0, 210.0, 260.0], [110.0, 260.0, 310.0]])
        said = (record.get("take") or {}).get("key_calls") or {}
        self.assertEqual((said.get("late"), said.get("max_late_ms"), said.get("longer_than_the_gap"), said.get("max_call_ms")),
                         (5, 150.0, 5, 50.0))
        self.assertIn("one thread", said.get("sent_by", ""))
        self.assertIn("planned time", said.get("key_time", ""))
        self.assertNotIn("calls", said)  # the list is in the record, not in the printed row
        # Each call was late and each ended with its reply before the next one started: the app got the keys in order.
        self.assertEqual((calls.get(IN_TURN), said.get(IN_TURN)), (True, True))

    def test_the_record_says_if_each_call_ended_with_its_reply_before_the_next_one_began(self):
        """True only with the proof for each call of the take: a reply of the app to each key, and no call that started
        before the call before it ended."""
        turn = lambda sends, replies: M.key_calls({"sends": sends, "replies": replies}, "one-key").get(IN_TURN, "no such field")
        self.assertIs(turn([[0.0, 0.0, 5.0], [10.0, 10.0, 12.0], [20.0, 12.0, 30.0]], [{}, {"refused_action": "closeTab"}, {}]), True)
        # A reply with `error` is no reply: the client gives its own time-out and a lost connection in that form, the
        # same form as a refusal of the app, so the tool cannot tell if the app got that key.
        self.assertIs(turn([[0.0, 0.0, 5.0], [10.0, 10.0, 12.0], [20.0, 12.0, 30.0]], [{}, {"error": "timed out"}, {}]), False)
        self.assertIs(turn([[0.0, 0.0, 5.0], [10.0, 4.99, 12.0]], [{}, {}]), False)  # the second call started before the first ended
        self.assertIs(turn([[0.0, 0.0, 5.0], [10.0, 10.0, 12.0]], [{}, "OSError('no socket')"]), False)  # a call that raised: no reply
        self.assertIs(turn([[0.0, 0.0, 5.0]], [{}, None]), False)  # the sender did not end: a key has no call and no reply
        self.assertIs(turn([], []), False)  # no call: nothing that the field can say
        # The app plays a sequence by itself: the tool makes no call for each key and has no such proof.
        self.assertIsNone(M.key_calls({"base_s": 1.0, "duration_ms": 5.0}, "activate").get(IN_TURN, "no such field"))

    def test_a_call_that_raises_leaves_the_record_with_no_proof_that_the_calls_were_in_turn(self):
        world, broke = World(), []
        Builder(world).new_workspace()

        def rpc(method, params=None, timeout=60):
            if method == "debug.key" and len(world.sent) == 1 and not broke:
                broke.append(True)
                raise OSError("no socket")
            return world.rpc(method, params, timeout)

        steps, _ = M.BENCH.sequence(["t"] * 4, 0, (20.0, 20.0))
        with self.fakes(world), one_thread_and_a_clock_that_moves(world):
            sent = M.post_keys("app-queue", rpc, steps, "pane1", "one-key")
        self.assertIs(M.key_calls(sent, "one-key").get(IN_TURN, "no such field"), False)

    def test_a_call_that_raises_is_the_reply_of_its_key_and_the_next_key_still_goes(self):
        world, broke = World(), []
        Builder(world).new_workspace()

        def rpc(method, params=None, timeout=60):
            if method == "debug.key" and len(world.sent) == 1 and not broke:
                broke.append(True)
                raise OSError("no socket")
            return world.rpc(method, params, timeout)

        steps, _ = M.BENCH.sequence(["t"] * 4, 0, (20.0, 20.0))
        with self.fakes(world), one_thread_and_a_clock_that_moves(world):
            sent = M.post_keys("app-queue", rpc, steps, "pane1", "one-key")
            why = M.refused(sent, 1.0)
        self.assertEqual((sent["replies"], world.keys, len(sent["sends"])), ([{}, "OSError('no socket')", {}, {}], 3, 4))
        self.assertEqual(why, "key 1: debug.key: OSError('no socket')")

    def test_the_sequence_of_the_activate_form_says_that_the_app_plays_it(self):
        record = self.record(World(), row="hold", form="activate")
        said = (record.get("take") or {}).get("key_calls") or {}
        self.assertIn("the app plays", said.get("sent_by", ""))
        self.assertIn("the app's own clock", said.get("key_time", ""))


class KeyWindow(Case):
    """The `activate` form with Chromium pages: the app shows a new tab page in a window of its own, and that window
    has the keys while the pane shows the page. The app then refuses a sequence that asks for the shell window as the
    key window (`the shell window did not become key`), and it refuses the page's window when the pane shows no page."""

    def preflight(self, world):
        """`preflight()` in the `activate` form on the fake app: the printed lines. A preflight that fails is a failure
        of the test with the tool's own words."""
        frames = {"frames": 120, "p50_ms": 8.33}
        rpc = lambda method, params=None, timeout=60: frames if method == "debug.frames" else world.rpc(method, params, timeout)
        said = io.StringIO()
        with self.fakes(world), contextlib.redirect_stdout(said):
            try:
                M.preflight(argparse.Namespace(rpc=rpc), Builder(world), self.out, None, "activate", "ready")
            except M.PreflightFailed as error:
                self.fail(f"the preflight of the activate form failed: {error}; the key windows that it asked for: {world.asked}")
        return said.getvalue().splitlines()

    def test_a_take_that_starts_on_a_new_tab_page_asks_for_the_window_of_the_page(self):
        """`close` after 2 new tab pages: the pane shows the second page, so the page's window has the keys."""
        world = World(chromium_pages=True)
        record = self.record(world, row="close", form="activate", more=("newtab", "newtab"))
        # 2 sequences: the one with no key before the frames, then the keys.
        self.assertEqual((record["errors"], record["invalid"], world.asked), ([], [], ["page", "page"]))
        self.assertEqual((record.get("key_window"), [tab["kind"] for tab in world.tabs]), ("page", ["terminal"]))
        self.assertNotIn("key_window_refusals", record)
        self.assertEqual(record["take"].get(EARLY), [])
        self.assertEqual(self.in_the_frames(world), [("debug.key", "sequence")])

    def in_the_frames(self, world):
        """Each `debug.focus` and `debug.key` call of the take from the start of its frames to their end."""
        started, stopped = world.calls.index(("debug.frames", "start")), world.calls.index(("debug.frames", "stop"))
        return [call for call in world.calls[started:stopped] if call[0] in ("debug.focus", "debug.key")]

    def test_a_take_takes_the_refusal_of_a_stale_word_before_its_frames_start(self):
        """The take's read of the word still says the shell window, and the page has the keys. The app refuses the
        word at the take's sequence with no key, which is before the frames: the frames have the keys' send only."""
        world = World(chromium_pages=True)
        world.stale = 2  # the take's 2 reads of the focus before its frames: the tab list, then the word
        record = self.record(world, row="close", form="activate", more=("newtab", "newtab"))
        self.assertEqual((record["errors"], record["invalid"], world.asked), ([], [], ["shell", "page", "page"]))
        self.assertEqual((record.get("key_window"), record["take"].get(EARLY), [tab["kind"] for tab in world.tabs]),
                         ("page", ["shell: the shell window did not become key"], ["terminal"]))
        self.assertNotIn("key_window_refusals", record)
        self.assertEqual(self.in_the_frames(world), [("debug.key", "sequence")])

    def test_a_take_whose_word_the_app_refuses_after_its_frames_started_is_invalid_and_names_the_refusal(self):
        """The page gets the keys after the app took the take's word: the refused send and the tool's new read of the
        focus are inside the frames, so no frame number of that take is valid."""
        world = World(chromium_pages=True, page_takes_the_keys_at_the_frames=True)
        record = self.record(world, row="close", form="activate", more=("newtab", "newtab"))
        self.assertEqual(self.in_the_frames(world), [("debug.key", "sequence"), ("debug.focus", None), ("debug.key", "sequence")])
        self.assertEqual(record.get("key_window_refusals"), ["shell: the shell window did not become key"])
        self.assertEqual(record["invalid"],
                         ["the app refused a key window word after the frames started (shell: the shell window did not become key): "
                          "the frames have one read of the focus and one refused send of this tool"])
        self.assertEqual((M.valid(record), record["errors"], record.get("key_window")), (False, [], "page"))
        self.assertEqual((world.asked, record["take"].get(EARLY), [tab["kind"] for tab in world.tabs]),
                         (["shell", "shell", "page"], [], ["terminal"]))

    def test_a_take_whose_word_the_app_refuses_at_each_send_gets_no_key_and_is_not_valid(self):
        """The focus says a page and the app finds no page window for it: 2 sends of the sequence with no key, 2 of
        the keys, and no other one."""
        world = World(chromium_pages=True)
        world.page_has_the_keys = lambda: False  # the app refuses `page`
        focus = world.rpc

        def rpc(method, params=None, timeout=60):
            reply = focus(method, params, timeout)
            if method == "debug.focus":  # the focus read still names a page
                reply["windows"][0].update({"is_key": False, "appkit": {"child_window_page": "tab9"}})
            return reply

        world.rpc = rpc
        record = self.record(world, row="hold", form="activate")
        refusal = "page: no Chromium page window for pane"
        self.assertEqual((world.asked, world.keys, M.valid(record)), (["page"] * 4, 0, False))
        self.assertEqual((record["take"].get(EARLY), record.get("key_window_refusals")), ([refusal] * 2, [refusal]))
        self.assertEqual(len(record["errors"]), 1)
        self.assertIn("keys: {'error': 'no Chromium page window for pane'", record["errors"][0])

    def test_a_take_that_starts_on_a_terminal_asks_for_the_shell_window(self):
        world = World(chromium_pages=True)
        record = self.record(world, row="hold", form="activate")
        self.assertEqual((record["errors"], record["invalid"], world.asked, record.get("key_window")), ([], [], ["shell", "shell"], "shell"))

    def test_the_preflight_closes_the_new_tab_page_that_its_own_key_made(self):
        """The preflight's Cmd-T makes a new tab page, which takes the keys; its Cmd-W goes to the page's window."""
        world = World(chromium_pages=True)
        lines = self.preflight(world)
        self.assertEqual((world.asked, [tab["kind"] for tab in world.tabs]), (["shell", "page"], ["terminal"]))
        self.assertIn("PREFLIGHT new-tab ok: tabs 1 -> 2, key_window = shell", lines)
        self.assertIn("PREFLIGHT close-tab ok: tabs 2 -> 1, key_window = page", lines)

    def test_the_preflight_reads_the_focus_again_when_the_page_took_the_keys_after_its_read(self):
        """The read of the focus and the keys are 2 calls. Directly after a Cmd-T the first read can still say the
        shell window; the app then refuses that word before it posts a key: ONE new read and ONE more send."""
        world = World(chromium_pages=True, page_gets_the_keys_late=True)
        lines = self.preflight(world)
        self.assertEqual((world.asked, [tab["kind"] for tab in world.tabs]), (["shell", "shell", "page"], ["terminal"]))
        self.assertIn("PREFLIGHT close-tab ok: tabs 2 -> 1, key_window = page (the app refused shell: the shell window did not become key)", lines)

    def test_the_word_follows_the_window_that_is_key(self):
        """The app's `debug.focus` has one entry for each cmux window. While a page's window has the keys, no cmux window
        is key, and the window of the page names it (`appkit.child_window_page`)."""
        window = lambda key, page: {"is_key": key, "appkit": {"child_window_page": page}}
        cases = (("page", {"windows": [window(False, "page1")]}),  # the page's own window is key
                 ("shell", {"windows": [window(True, None)]}),
                 # A cmux window is key and still names a page (a new page whose window cannot take the keys yet): the
                 # window that has the keys is the shell window, and the app takes that word.
                 ("shell", {"windows": [window(True, "page1")]}),
                 # 2 cmux windows: the one that is key shows a terminal, the other one keeps the word of its page.
                 ("shell", {"windows": [window(True, None), window(False, "page1")]}),
                 ("page", {"windows": [window(False, None), window(False, "page1")]}),
                 ("shell", {"windows": []}), ("shell", {"error": "unknown method"}), ("shell", None))
        for want, reply in cases:
            self.assertEqual(M.key_window_word(lambda method, params=None, timeout=60: reply), want, reply)

    def test_a_refusal_that_a_new_read_does_not_mend_fails_the_preflight_after_2_sends(self):
        """The focus says a page and the app finds no page window for it at each send: no third send."""
        world = World(chromium_pages=True)
        world.page_has_the_keys = lambda: False  # the app refuses `page`, and the focus read below still names a page
        focus = world.rpc
        seen = {"app_active": True, "key_window": "CefNSWindow", "windows": [{"is_key": False, "appkit": {"child_window_page": "tab9"}}]}
        world.rpc = lambda method, params=None, timeout=60: seen if method == "debug.focus" else focus(method, params, timeout)
        with self.assertRaises(AssertionError) as failed:
            self.preflight(world)
        self.assertEqual(world.asked, ["page", "page"])
        self.assertIn("new-tab: no Chromium page window for pane", str(failed.exception))
        # The failed line has the word that the tool asked and the refusal before the last send.
        self.assertIn("no Chromium page window for pane, key_window = page (the app refused page: no Chromium page window for pane)",
                      str(failed.exception))


class InputOrder(unittest.TestCase):
    """`input_order`: the proof that the app got the keys in the order of the tool."""
    RUN = staticmethod(lambda at: {"perform": {"at_s": at}})

    def test_a_key_that_did_something_with_no_record_of_its_action_leaves_the_proof_open_and_the_model_has_no_verdict(self):
        proof, acts = M.input_order({0: self.RUN(100.0), 2: self.RUN(100.2)}, ["created"] * 3)
        self.assertEqual((proof["in_key_order"], proof["keys_with_no_act_record"], acts), (None, 1, [0, 2]))
        after = order(["a", "x1", "x2", "x3"], ["terminal"] + ["newtab"] * 3, "x3")
        record, fates = keys("ttt", order(["a"], ["terminal"], "a"), after)
        row, openers = M.order_row(record, fates, {}, acts=acts)
        self.assertEqual((row["equal"], row.get("verdict"), openers), (None, "no verdict", None))
        self.assertIn("key 1 has no record of when its action ran", row["why"])

    def test_a_key_whose_action_did_not_run_is_no_gap_of_the_proof(self):
        proof, acts = M.input_order({0: self.RUN(100.0), 2: self.RUN(100.2)}, ["created", "missing", "created"])
        self.assertEqual((proof["in_key_order"], proof["acts"], proof["keys_with_no_act_record"], proof["first"], acts),
                         (True, 2, 0, None, [0, 2]))

    def test_a_row_where_the_app_ran_no_action_has_no_proof(self):
        proof, acts = M.input_order({}, ["missing"] * 3)
        self.assertEqual((proof["in_key_order"], proof["acts"], proof["keys_with_no_act_record"], acts), (None, 0, 0, []))

    def test_each_action_that_ran_after_the_action_of_a_later_key_is_counted(self):
        """The acts ran in the order of the keys 1, 0, 3, 2, 4."""
        runs = {key: self.RUN(100.0 + at) for key, at in ((1, 0.1), (0, 0.2), (3, 0.3), (2, 0.4), (4, 0.5))}
        proof, acts = M.input_order(runs, ["created"] * 5)
        self.assertEqual((proof["in_key_order"], proof["acts_after_a_later_key"], proof["first"], acts),
                         (False, 2, {"key": 0, "ran_after_key": 1}, [1, 0, 3, 2, 4]))


class Between(unittest.TestCase):
    """`between`: what the wider recording says of one slow key."""

    def test_an_interval_counts_only_inside_the_key_to_commit_window_and_3_names_are_kept(self):
        commit = World.interval("action.commit", "action", 100.25, 50.0, {"input_age_ms": "250.0"})
        task = lambda owner, at, ms: World.interval("stall.main_task", "stall", at, ms, {"class": "work", "owner": owner})
        # The window is 100.0 s to 100.3 s. A starts before it, B ends after it, C is 2 intervals, D is the fourth
        # name, E is after the window.
        intervals = [task("A", 99.9, 150.0), task("B", 100.28, 100.0), task("C", 100.1, 100.0), task("C", 100.21, 30.0),
                     task("D", 100.1, 10.0), task("E", 101.0, 500.0)]
        record = {"press_letters": ["t"], "press_times_s": [100.0]}
        found, own = M.between(intervals, {0: {"commit": commit}}, record, ["created"], "activate")
        self.assertEqual([(part["what"].split("owner=")[1], part["ms"], part["count"]) for part in found[0]["between"]],
                         [("C", 130.0, 2), ("A", 50.0, 1), ("B", 20.0, 1)])
        self.assertEqual((found[0].get("own_call_tasks_left_out"), own), ({"count": 0, "ms": 0.0}, 0))
        self.assertIn("3 names by summed time", M.WIDE_LIMIT)


class Restore(Case):
    """`restore`: the start's shape again after a row."""

    def test_the_tabs_of_the_start_come_back_before_the_tabs_of_the_row_close(self):
        world = World()
        builder = Builder(world)
        builder.new_workspace()
        state = M.BENCH.start_state(builder, "ws1")
        for _ in range(2):
            world.add("newtab")
        world.close(world.tabs[0])  # the row closed each tab of the start: the pane has the row's 2 tabs only
        world.fewest = len(world.tabs)
        with self.fakes(world):
            new, left, back = M.restore(builder, "ws1", "pane1", state)
        self.assertGreaterEqual(world.fewest, 1, "the restore closed each tab of the pane before it gave one back")
        self.assertEqual((left, back, [tab["kind"] for tab in world.tabs]), ([], 1, ["terminal"]))
        self.assertEqual(new, {"pane1": {world.tabs[0]["id"]}})


class Take(Case):
    """`take()`: one take on the fake app."""

    def test_a_take_whose_pane_does_not_get_the_focus_is_not_run(self):
        world = World(no_focus=True)
        record = self.record(world, row="mixed", film=os.path.join(self.out, "film"))
        self.assertIn("focus never reached pane pane1", record.get("not_run") or "")
        self.assertEqual((world.keys, [call for call in world.calls if call[0] in ("debug.key", "debug.window_record")]), (0, []))

    def test_the_list_is_the_stores_list_with_each_kind(self):
        world = World(focus_list_cut=2)
        after = self.record(world)["order"]["after"]
        ids = [tab["id"] for tab in world.tabs]
        self.assertGreater(len(ids), 3)
        self.assertEqual((after["tabs"], after.get("kinds"), after.get("focus_tabs")),
                         (ids, ["terminal"] + ["newtab"] * (len(ids) - 1), ids[:-2]))

    def test_the_record_says_how_long_after_the_last_key_the_list_was_read(self):
        world = World()
        world.now = world.base + 0.75
        record = self.record(world)
        last = record["press_times_s"][-1]
        self.assertAlmostEqual(record["take"].get("list_read_after_last_key_ms") or 0.0, (world.now - last) * 1000, places=3)


class Artifact(Case):
    def test_one_file_brings_back_the_report_each_take_and_the_film(self):
        film = os.path.join(self.out, "film", "frames")
        for folder in (os.path.join(self.out, "0-mixed"), film):
            os.makedirs(folder)
        for path in ("report.json", "0-mixed/scenario.json", "0-mixed/run.ndjson", "film/frames/frames.json",
                     "film/frames/frame-00005.jpg", "film/frames/frame-00006.jpg", "film/frames/frame-00010.jpg"):
            with open(os.path.join(self.out, path), "w") as f:
                f.write("{}")
        target = os.path.join(self.out, "back.tgz")
        names = M.pack(self.out, os.path.join(self.out, "film"), target)
        with tarfile.open(target) as tar:
            self.assertEqual(sorted(tar.getnames()), sorted(names))
        self.assertEqual(sorted(names), ["0-mixed/run.ndjson", "0-mixed/scenario.json", "film/frame-00005.jpg", "film/frame-00010.jpg",
                                         "film/frames.json", "report.json"])

    def test_the_entry_script_names_one_artifact_for_a_step(self):
        with open(os.path.join(HERE, "..", "held-new-tab.sh")) as f:
            text = f.read()
        usage = text.split("set -euo pipefail")[0]
        self.assertNotIn("--artifact held-new-tab.json [--artifact", usage)
        self.assertIn("ONE --artifact", usage)
        self.assertIn('--artifact "$PWD/held-new-tab.tgz"', text)
        self.assertIn('cp "$out/measure/report.json" "$PWD/held-new-tab.json"', text)  # the report alone, for a reader that asks for it

    def test_the_entry_script_requires_the_page_engine_in_its_build(self):
        with open(os.path.join(HERE, "..", "held-new-tab.sh")) as f:
            text = f.read()
        self.assertIn('CMUX_NEXT_REQUIRE_CEF="$require_cef"', text)
        self.assertIn("--allow-no-chromium) require_cef=0 ;;", text)
        self.assertIn("require_cef=1", text)


class App:
    """bench_launch.py's `BenchApp` with no process: the app's active state, its engine word, the faults of the case."""
    made, faults, engine = [], set(), [CEF_READY]

    def __init__(self, app, out=None, env=None):
        self.app, self.binary, self.window, self.socket, self.extra = app, BINARY, (40, 40, 1440, 900), "/fake.sock", env or {}
        self.process, self.teardown, self.ready_seconds, self.limits, self.stopped = mock.Mock(pid=100), None, 1.0, {}, False
        # pid: its parent. 100 = the launch's own process.
        self.opens, self.signals, self.pids, self.engine_reads = [], [], {100: 50}, 0

    def launch(self):
        env = {"CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_AGENT_PANE_MOCK": "1", **self.extra}
        self.launched_env = {key: value for key, value in env.items() if value is not None}
        self.active = "launch-activates" in App.faults and "CMUX_NEXT_NO_ACTIVATE" not in self.launched_env
        App.made.append(self)
        return self

    def stop(self):
        self.stopped = True

    def rpc(self, method, params=None, timeout=60):
        if method == "debug.focus":
            return {"app_active": self.active, "key_window": "ShellWindow" if self.active else None}
        if method == "debug.cef":
            self.engine_reads += 1
            return App.engine[min(self.engine_reads, len(App.engine)) - 1]
        return {}


class LaunchServices:
    """`subprocess` for a launch: `open`, `ps` and `lsappinfo` of the newest fake launch; no process starts."""
    SubprocessError, TimeoutExpired = subprocess.SubprocessError, subprocess.TimeoutExpired

    @staticmethod
    def run(command, **_):
        app, said = App.made[-1], ""
        if command[0] == "/usr/bin/open":
            app.opens.append(command[1:])
            app.active = "open-activates" in App.faults
            if "open-second-instance" in App.faults:
                app.pids[200] = 1  # a new instance, under launchd
        elif command[0] == "/bin/ps":
            # 101: a process that the app started with its own binary (no instance).
            said = "".join(f"{pid} {parent} {BINARY}\n" for pid, parent in app.pids.items()) + f"101 100 {BINARY} --helper\n"
        elif command[:2] == ["/usr/bin/lsappinfo", "front"]:
            said = "ASN:0x0-0x1b01b:\n"
        elif command[0] == "/usr/bin/lsappinfo":
            said = '"LSDisplayName"="Finder"\n' if "name" in command else '"pid"=77\n'
        return subprocess.CompletedProcess(command, 0, said, "")


class Launch(unittest.TestCase):
    """`main()` to its first row: the launch forms, what makes the app active, and the engine's word. The preflight,
    the window's placement, the session and the rows are not in it (`preflight`, `place` and `run` are stubs)."""

    def main(self, faults, *args, engine=(CEF_READY,)):
        """`main()` with `faults`: (exit code, the report, the printed lines, each fake launch)."""
        App.made, App.faults, App.engine = [], set(faults), list(engine)
        out, said = tempfile.mkdtemp(prefix="held-new-tab-test-"), io.StringIO()
        self.addCleanup(shutil.rmtree, out, True)

        def rows(opts, app, signposts, report, form):
            report["rows"].append({"scenario": "mixed", "round": 0, "key_source": form, "errors": [], "invalid": []})

        fakes = ((M, "hid_grant", lambda: True), (M, "subprocess", LaunchServices), (M, "STRESS", Stress(World())),
                 (M, "preflight", lambda *given: {"frames": 120, "p50_ms": 8.33, "refresh_ms": 8.33}),
                 (M, "place", lambda app: [40, 40, 1440, 900]), (M, "run", rows),
                 (M.BENCH, "load", lambda name, file: argparse.Namespace(host_facts=lambda: {"os": "fake"})),
                 (M.bench_launch, "BenchApp", App), (M.os, "kill", lambda pid, sent: App.made[-1].signals.append((pid, sent))),
                 (sys, "argv", ["held-new-tab.py", "--app", BUNDLE, "--out", out, "--rounds", "1", *args]))
        with contextlib.ExitStack() as stack:
            stack.enter_context(mock.patch.dict(os.environ))  # the script sets 2 variables of the launcher
            for target, name, fake in fakes:
                stack.enter_context(mock.patch.object(target, name, fake))
            stack.enter_context(contextlib.redirect_stdout(said))
            stack.enter_context(contextlib.redirect_stderr(said))
            code = M.main()
        with open(os.path.join(out, "report.json")) as f:
            report = json.load(f)
        return code, report, said.getvalue().splitlines(), list(App.made)

    def test_one_open_makes_the_app_active_and_the_report_has_the_line(self):
        code, report, lines, launches = self.main({"open-activates"})
        line = ("PREFLIGHT activate: by=open app_active=true key_window=ShellWindow front=Finder (pid 77) instances=1 "
                "(pids [100]; before the open: [100])")
        self.assertEqual((code, len(launches), report.get("launch_form")), (0, 1, "activate"))
        self.assertEqual((launches[0].opens, report["launch"].get("activate")), ([[BUNDLE]], line))
        self.assertIn(line, lines)

    def test_an_open_that_does_not_make_the_app_active_goes_on_in_the_one_key_form(self):
        code, report, lines, launches = self.main(set())
        self.assertEqual((code, [len(app.opens) for app in launches], report.get("launch_form")), (0, [1, 0], "one-key"))
        self.assertTrue(launches[0].stopped)  # the app of the failed form is ended before the next launch
        start = "PREFLIGHT next form: one-key (the activate form failed: PREFLIGHT activate: by=none app_active=false"
        self.assertTrue([line for line in lines if line.startswith(start)], lines)
        self.assertTrue(report["launch"].get("activate", "").startswith("PREFLIGHT activate: by=not asked"), report["launch"])

    def test_an_open_that_starts_a_second_instance_ends_the_run_with_one_sigterm_and_no_other_form(self):
        code, report, lines, launches = self.main({"open-activates", "open-second-instance"})
        self.assertEqual((code, len(launches)), (1, 1))  # no launch in the `one-key` form
        # ONE signal, a SIGTERM, to the pid that was not there before the open; none to the launch's own process.
        self.assertEqual(launches[0].signals, [(200, signal.SIGTERM)])
        self.assertIn("a second instance of the app runs after the open", report.get("preflight_failed", ""))
        self.assertEqual((launches[0].stopped, report["rows"]), (True, []))

    def test_the_report_has_the_page_engine_at_the_launch_and_after_the_rows(self):
        fell = {**CEF_READY, "fallback": {"count": 2, "reason": None, "source": None, "notified": False}}
        code, report, lines, launches = self.main({"launch-activates"}, engine=(CEF_READY, fell))
        found = report.get("page_engine") or {}
        self.assertEqual((found.get("engine"), (found.get("at_launch") or {}).get("engine"), (found.get("after_the_rows") or {}).get("webkit_fallbacks")),
                         ("mixed", "chromium", 2))
        self.assertEqual([line for line in lines if line.startswith("PREFLIGHT page engine:")],
                         ["PREFLIGHT page engine: engine=chromium default_engine=chromium chromium_state=ready unavailable=none webkit_fallbacks=0"])
        self.assertEqual(code, 0)


class Engine(unittest.TestCase):
    """`page_engine`: the app's own word on its page engine (`debug.cef`), in each case."""

    def test_each_case_of_the_apps_word(self):
        read = getattr(M, "page_engine", None)
        self.assertIsNotNone(read, "the tool has no read of the page engine")
        gone = {"code": "notBundled", "detail": None}
        cases = (("chromium", CEF_READY), ("webkit", {**CEF_READY, "state": "unavailable", "unavailable": gone}),
                 ("webkit", {**CEF_READY, "default_engine": "webkit"}), ("mixed", {**CEF_READY, "fallback": {"count": 3}}),
                 ("chromium not ready", {**CEF_READY, "state": "idle"}), ("not read", {"error": "unknown method"}), ("not read", None))
        for want, reply in cases:
            self.assertEqual(read(lambda method, params=None, timeout=60: reply)["engine"], want, reply)

        def broken(method, params=None, timeout=60):
            raise OSError("no socket")

        self.assertEqual(read(broken)["engine"], "not read")


if __name__ == "__main__":
    unittest.main(verbosity=2)
