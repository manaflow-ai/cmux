#!/usr/bin/env python3
"""The bench tools find the workspace that `workspace.newAtBottom` made in both answers of `action.run`: with the
ws_ id in `created` (an app before 650fd32b59b9) and with only the tab and the terminal there (an app from
650fd32b59b9, where one `create-terminal` makes the workspace too). Each test of the second answer fails on the
tools before this file's fix: they said "made no workspace" and ran no row.
Run: python3 -I scripts/perf-bench/tests/test_made_workspace.py"""
import os, sys, types, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
sys.path.insert(0, HERE)
# procs.py loads /usr/lib/libproc.dylib at import (macOS only). No test here reads a process, so an empty module
# stands in for it when the real one does not load, and the tools import on Linux too. The stub is for these
# imports only (the form of scripts/cmux-next/tests/test_perf_completeness.py): left in sys.modules, a later test's
# `import procs` gets it in place of the real module (the module load scan of the manual lane, the file
# test_script_module_loads in tests/, names a stub that is left). That scan's path is not written here on purpose:
# the CI routing walk reads the path of a test in a file under scripts/ as a run of that test.
_PROCS_STUB = None
try:
    import procs  # noqa: F401
except OSError:
    _PROCS_STUB = sys.modules["procs"] = types.ModuleType("procs")
try:
    import chrome_parity as cp  # noqa: E402
    import parity_appclock as pa  # noqa: E402
    from made_workspace import made_workspace  # noqa: E402
finally:
    if _PROCS_STUB is not None and sys.modules.get("procs") is _PROCS_STUB:
        del sys.modules["procs"]
# session_real.py: the one module object that test_session_real.py loads by path (its line 12). `import session_real`
# here made a second object of that file, and a second load by path makes one too.
# The known cost: this file imports the other test file (its import-time code runs here too), and with
# SESSION_REAL_FILE set both files read that copy. Do not change this back to a load of its own in this file.
from test_session_real import m as sr  # noqa: E402

# The answer of a Release app of feat 3ee124bd63c2 on aws-m4pro-8 (2026-11-12), as the tool printed it: the tool
# cuts an answer at 200 characters, so the end of the idempotency key and the fields after it are not here.
NEW = {"action": "workspace.newAtBottom", "args": {},
       "created": ["tab_17fc15a4ca49bcfd8b859d41089760b8", "term_f67fd027dc919f91da5dc0ba24ffaa69"],
       "idempotency_key": "mutation_9b53c2ceef5843dbba33a2865bf32"}
# The answer of an app before 650fd32b59b9 (`create-workspace`, then `create-terminal`), written by hand from the
# code of that time: no raw answer of such an app was kept.
OLD = dict(NEW, created=["ws_5d0c8a1f0b7e4c2f9a3b6d1e2f4a7c90"] + NEW["created"])
MADE = "ws_0a1b2c3d4e5f60718293a4b5c6d7e8f9"


def tab(tab_id, terminal):
    return {"id": tab_id, "surface": "s", "kind": "terminal", "terminal": terminal}


def workspace(ws_id, *tabs):
    return {"id": ws_id, "key": "k-" + ws_id, "screens": [{"id": "screen_1", "panes": [{"id": "pane_1", "tabs": list(tabs)}]}]}


def topology(*workspaces):
    """`snapshot.get`'s topology, written from ControlTopology+JSON.swift (the run of NEW kept no snapshot)."""
    return {"loaded": True, "workspaces": list(workspaces)}


OPEN = workspace("ws_open", tab("tab_before", "term_before"))
NEW_TOPOLOGY = topology(OPEN, workspace(MADE, tab(NEW["created"][0], NEW["created"][1])))


class Reads:
    """A topology read that counts its calls."""

    def __init__(self, value):
        self.value, self.calls = value, 0

    def __call__(self):
        self.calls += 1
        return self.value


class MadeWorkspace(unittest.TestCase):
    def test_a_ws_id_in_created_is_the_workspace_and_no_read_is_made(self):
        reads = Reads(NEW_TOPOLOGY)
        self.assertEqual(made_workspace(OLD, reads), OLD["created"][0])
        self.assertEqual(reads.calls, 0)

    def test_with_only_the_tab_and_the_terminal_the_workspace_that_holds_the_tab_is_it(self):
        reads = Reads(NEW_TOPOLOGY)
        self.assertEqual(made_workspace(NEW, reads), MADE)
        self.assertEqual(reads.calls, 1)

    def test_a_tab_put_in_a_workspace_that_was_there_before_is_no_new_workspace(self):
        both = workspace("ws_open", tab("tab_before", "term_before"), tab(NEW["created"][0], NEW["created"][1]))
        self.assertIsNone(made_workspace(NEW, Reads(topology(both))))

    def test_a_tab_that_no_workspace_shows_is_no_workspace(self):
        self.assertIsNone(made_workspace(NEW, Reads(topology(OPEN))))

    def test_an_answer_with_no_tab_makes_no_read(self):
        for reply in ({}, None, {"created": []}, {"created": ["term_1"]}, {"error": "refused"}):
            reads = Reads(NEW_TOPOLOGY)
            self.assertIsNone(made_workspace(reply, reads))
            self.assertEqual(reads.calls, 0)

    def test_a_read_that_gives_nothing_is_no_workspace(self):
        for value in (None, {}, {"workspaces": None}):
            self.assertIsNone(made_workspace(NEW, Reads(value)))


class Socket:
    """The app's socket for one tool: `action.run` answers `reply`, `snapshot.get` answers `shown`."""

    def __init__(self, reply, shown):
        self.reply, self.shown, self.sent = reply, shown, []

    def answer(self, method, params):
        self.sent.append((method, params))
        if method == "snapshot.get":
            return {"topology": self.shown}
        return self.reply if params["action"] == "workspace.newAtBottom" else {}

    def went_to(self):
        return [p["args"].get("workspace") for m, p in self.sent if m == "action.run" and p["action"] == "goToWorkspace"]

    def reads(self):
        return sum(1 for m, _ in self.sent if m == "snapshot.get")


def chrome_parity_arm(socket):
    arm = object.__new__(cp.CmuxArm)
    app = types.SimpleNamespace(call=lambda method, params=None, timeout=120: socket.answer(method, params))
    arm.b = types.SimpleNamespace(app=app, act=lambda action, **args: socket.answer("action.run", {"action": action, "args": args}))
    return arm


def appclock_arm(socket):
    arm = object.__new__(pa.Cmux)
    arm.app = types.SimpleNamespace(rpc=lambda method, params, timeout: socket.answer(method, params))
    return arm


def session_real_driver(socket):
    driver = object.__new__(sr.AppDriver)
    driver.rpc = lambda method, params=None, timeout=60: socket.answer(method, params)
    return driver


class ToolsMakeAWorkspace(unittest.TestCase):
    """`workspace()` of both parity tools, and the workspace that session_real.py's map makes for its rows."""

    def test_both_parity_tools_go_to_the_workspace_of_each_answer(self):
        for make in (chrome_parity_arm, appclock_arm):
            for reply, want, reads in ((OLD, OLD["created"][0], 0), (NEW, MADE, 1)):
                socket = Socket(reply, NEW_TOPOLOGY)
                self.assertEqual(make(socket).workspace(), want, make.__name__)
                self.assertEqual(socket.went_to(), [want], make.__name__)
                self.assertEqual(socket.reads(), reads, make.__name__)

    def test_both_parity_tools_run_no_row_when_the_app_made_no_workspace(self):
        for make, not_run in ((chrome_parity_arm, cp.NotRun), (appclock_arm, pa.NotRun)):
            socket = Socket(NEW, topology(OPEN))
            with self.assertRaises(not_run, msg=make.__name__):
                make(socket).workspace()
            self.assertEqual(socket.went_to(), [], make.__name__)

    def test_session_real_map_takes_its_workspace_from_each_answer(self):
        for reply, want, reads in ((OLD, OLD["created"][0], 0), (NEW, MADE, 1)):
            socket = Socket(reply, NEW_TOPOLOGY)
            self.assertEqual(sr.bench_workspace(session_real_driver(socket)), want)
            self.assertEqual(socket.reads(), reads)

    def test_session_real_map_stops_when_the_app_made_no_workspace(self):
        socket = Socket(NEW, topology(OPEN))
        with self.assertRaises(SystemExit) as stop:
            sr.bench_workspace(session_real_driver(socket))
        self.assertIn("made no workspace", str(stop.exception))


if __name__ == "__main__":
    unittest.main()
