#!/usr/bin/env python3
"""scripts/measure/held-new-tab.py: what a row says of the tab order, of a slow key, of its own restore and artifact.

The order row knew a new tab only by its place in the pane's list, read the list from the focus model, and did not
say at which key the app left the rule. A row's restore closed what the row made and did not give back a tab of the
start that the row closed, so each later row started with one tab less, and at the end the rows' pane was gone. The
script now reads the store's list (each tab's id and kind), checks each Cmd-W by the id that the app closed, names
the first difference by its key, id and kind, gives a lost tab back, fails the run for a restore that leaves a
difference, does not run a take whose pane is gone or did not get the focus, says where a slow key's time went, and
packs one file for the step to bring back.

No app, no socket, no build: `run()` and `take()` run with the session helper (`Stress`), `subprocess` and the
signpost reader replaced by fakes with a small model of one pane's tabs and of what each key does to them. So this
proves the script's own logic (the model, the rows, the failures), NOT the app and NOT what a Mac's keys do.
Run: python3 -I scripts/measure/tests/held-new-tab.test.py"""
import argparse, contextlib, importlib.util, io, itertools, json, os, shutil, tarfile, tempfile, unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
SPEC = importlib.util.spec_from_file_location("held_new_tab_under_test", os.path.join(HERE, "..", "held-new-tab.py"))
M = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(M)
ACTION = {"t": "newTab.default", "w": "closeTab"}
WIDE = ["action", "stall", "stalls", "tab-switch"]


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
        self.tabs.insert(len(self.tabs) if at is None else at + 1, new)
        self.select(new)
        return new

    def close(self, tab):
        """`tab` goes; when it was the selected one: its opener, else the next tab, else the previous one."""
        at = self.tabs.index(tab)
        self.tabs.remove(tab)
        if tab["selected"] and self.tabs:
            opener = next((other for other in self.tabs if other["id"] == tab.get("opener")), None)
            self.select(opener or self.tabs[min(at, len(self.tabs) - 1)])

    def key(self, letter, at):
        self.keys += 1
        if letter == "t":
            self.add("newtab")
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
            return {"windows": [{"topology": [{"pane": self.pane, "tabs": tabs, "selected": chosen}],
                                 "model": {"resolved_tab": chosen}, "consistent": True, "mismatches": []}]}
        if method == "debug.journal":
            return {"stats": {"lastSeq": 0}, "entries": []}
        if method == "debug.burst":
            if params.get("action") == "start":
                return {"key_repeat_delay_s": 0.02, "key_repeat_interval_s": 0.02}
            if params.get("action") == "status":
                return {"recording": True, "sequence_playing": False, "pending_intents": 0, "resize_idle": True,
                        "terminals_awaiting_echo": 0}
            return {"events": list(self.marks), "dropped": 0}
        if method == "debug.key":
            at = self.base
            for step in params.get("sequence") or []:
                at += (step.get("after_ms") or 0) / 1000
                letter = {17: "t", 13: "w"}.get(step["key_code"])
                if step["down"] and letter:
                    self.key(letter, at)
            return {"base_s": self.base, "duration_ms": (at - self.base) * 1000 + 50}
        if method == "debug.new_tab":
            return {"openings": list(self.openings)}
        return {}

    # The take of a row, as the child process of the signpost recorder makes it: the keys, then the 2 files.

    def take(self, name, out, categories, keep, film):
        self.takes.append({"row": name, "categories": categories, "film": film, "tabs_at_start": len(self.tabs)})
        letters = {"mixed": ["t", "t", "w", "t", "t", "w"], "hold": ["t"] * 4}.get(name) or ["w"] * (len(self.tabs) - keep)
        self.base += 10.0
        times = [self.base + 0.1 * index for index in range(len(letters))]
        before, self.marks, intervals = self.order(), [], []
        count = {"tabs": len(self.tabs), "panes": 1}
        for index, (letter, at) in enumerate(zip(letters, times)):
            self.key(letter, at)
            age, commit = self.slow.get((len(self.takes), index), (4.0, 3.0))
            user = {"id": ACTION[letter], "origin": "user"}
            intervals.append(self.interval("action.perform", "action", at + 0.002, 1.0, {**user, "input_age_ms": "2.0"}))
            intervals.append(self.interval("action.commit", "action", at + age / 1000, commit, {**user, "input_age_ms": str(age)}))
            if age > 200:
                # What ran on the main thread between this slow key and its commit: the app's own names.
                intervals.append(self.interval("stall.main_task", "stall", at + 0.02, 180.0,
                                               {"class": "background", "owner": "NewTabSparePool.warm"}))
                intervals.append(self.interval("stall.main_task", "stall", at + 0.001, 270.0,
                                               {"class": "control", "owner": "debug.key"}))
                intervals.append(self.interval("switch", "tab-switch", at + 0.21, 20.0, {}))
        record = {"scenario": name, "errors": [], "invalid": [], "unit": "tabs", "key_window": "none", "presses": len(letters),
                  "before": count, "after": {"tabs": len(self.tabs), "panes": 1}, "press_letters": letters,
                  "press_times_s": times, "trace": {"events": list(self.marks), "dropped": 0}, "frames": {}, "settled_ms": 1,
                  "tabs_after": [tab["id"] for tab in self.tabs], "order": {"before": before, "after": self.order()},
                  "shows": [], "take": {"key_form": "one-key"}}
        with open(os.path.join(out, "scenario.json"), "w") as f:
            json.dump(record, f)
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


class Recorder:
    """`subprocess` for `run()`: the one child of a take is the signpost recorder with the take's own command."""
    DEVNULL = -3

    def __init__(self, world):
        self.world = world

    def run(self, command, **options):
        value = lambda flag: command[command.index(flag) + 1]
        categories = [command[i + 1] for i, part in enumerate(command) if part == "--category"]
        self.world.records += 1
        self.world.take(value("--row"), value("--out"), categories, int(value("--keep")), "--film" in command)
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

    def record(self, world, row="hold", form="activate", film=None):
        """`take()` on the fake app: the record that it wrote."""
        Builder(world).new_workspace()
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
        self.assertEqual((wide["round"], wide["scenario"]), ("wide", "hold, wider recording"))
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
                                       {"what": "tab-switch.switch", "ms": 20.0, "count": 1}]}])


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


if __name__ == "__main__":
    unittest.main(verbosity=2)
