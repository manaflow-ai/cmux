#!/usr/bin/env python3
"""sidebar-stress-bench.py's workspace switch matrix against an app that answers as the real one (no app).

`cmux workspace create --name N` prints the made workspace as a record (rows of `key value`, the CLI's human
printer), never a bare id. The bench took the whole record as the workspace's id (2026-10-21 to 2026-11-13), so
each `goToWorkspace` and each `palette.moveWorkspaceToTop` it sent answered `not_found`, the bench did not read
the answer, both pages opened in the workspace that was selected then, and each cell of the matrix started from
the selection the cell before left: the rows had the names of cells the bench never measured (a run on a bench
Mac, 2026-11-13: 9 of 9 such calls `not_found`, the key cells' selection check wrong 10 of 10 times).

The fake below answers as the app does: the record for a create, `{"code": "not_found", "data": {"id": ...}}` for
an id that names no workspace, and it counts what it refused. The tests assert counts, never a time.
Run: python3 -I scripts/cmux-next/tests/test_sidebar_stress_switch_refs.py"""
import importlib.util, io, json, os, subprocess, sys, tempfile, types, unittest
from contextlib import redirect_stdout
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = tempfile.mkdtemp(prefix="sbstress-test-")
SWITCHES = 8
_argv, _modules = sys.argv, {name: sys.modules.get(name) for name in ("bench_idle", "bench_launch")}
sys.argv = ["sidebar-stress-bench.py", "--app", "/nonexistent/cmux.app", "--tag", "unit", "--out", OUT,
            "--switches", str(SWITCHES), "--no-trace"]
# The bench's two helper modules read macOS (libproc, the app launch); the tests launch nothing.
sys.modules["bench_idle"] = types.SimpleNamespace(usage=lambda pid: (0, 0, 0))
sys.modules["bench_launch"] = types.SimpleNamespace(launch_app=None)
try:
    spec = importlib.util.spec_from_file_location("sidebar_stress_bench", os.path.join(HERE, "..", "sidebar-stress-bench.py"))
    bench = importlib.util.module_from_spec(spec)
    # The script's last line runs main() (it launches the app): the tests load everything above it.
    source, last = open(spec.origin).read().rstrip(), "sys.exit(0 if main() else 1)"
    assert source.endswith(last), "the bench's last line is not its main() call"
    exec(compile(source[: -len(last)], spec.origin, "exec"), bench.__dict__)
finally:
    sys.argv = _argv
    for name, module in _modules.items():
        if module is None:
            sys.modules.pop(name, None)
        else:
            sys.modules[name] = module

TARGETS = ["sw chromium a", "sw chromium b", "sw term a", "sw term b"]
CELLS = [f"{kind}.{how}" for kind in ("chromium", "terminal") for how in ("click", "cmd_digit", "next_prev")]


class FakeApp:
    """The app's socket and its CLI, as far as the switch matrix uses them. A workspace is a sidebar row with a
    name, an id and a page count; a new one goes below the others, so only a move that works puts it at the top."""

    def __init__(self, refuse=(), record=True, lists=True, dead=(), deaf=(), top=0, items=True):
        self.rows = []
        self.selected = None
        self.refuse = set(refuse)   # actions that this app refuses whatever they name
        self.record = record        # False: `workspace create` answers a text with no id
        self.lists = lists          # False: the app's snapshot never lists a workspace that the CLI made
        self.dead = set(dead)       # "click": the app takes each click and switches nothing (the click hits no row)
        self.deaf = set(deaf)       # the inputs, counted from 1 over the run, that the app takes and that switch nothing
        self.top = top              # the shown top items (Home, the App Store): Cmd-1.. counts them before the workspaces
        self.items = items          # False: the app's sidebar report lists no layout item
        self.snapshots = 0          # snapshot.get calls
        self.refused = []           # (action, the id it named) of each error answer
        self.inputs = 0             # clicks and keys
        self.recording, self.samples = False, []
        self.create("bench start")

    # -- the model
    def create(self, name):
        row = {"id": f"ws_{len(self.rows) + 1:032x}", "name": name, "pages": 0}
        self.rows.append(row)
        if self.selected is None:
            self.selected = row["id"]
        return row

    def named(self, name):
        return next(r for r in self.rows if r["name"] == name)

    def find(self, ref):
        return next((r for r in self.rows if r["id"] == ref), None)

    def select(self, row):
        if row is None or row["id"] == self.selected:
            return
        if self.recording:
            self.samples.append({"commit_ms": 5.0, "input_ms": 1.0, "from": self.selected, "to": row["id"], "pages": row["pages"]})
        self.selected = row["id"]

    def numbered(self, number):
        """What Cmd-number selects: the shown top items first, then the workspaces (the app's default numbering)."""
        if number <= self.top:
            return {"id": f"top item {number}", "pages": 0}
        return self.rows[number - self.top - 1] if number - self.top <= len(self.rows) else None

    def not_found(self, action, ref):
        self.refused.append((action, ref))
        return {"error": {"code": "not_found", "data": {"id": ref}}}

    # -- the CLI (`bench.cli`)
    def cli(self, *args, quiet=True):
        out = ""
        if args[:2] == ("workspace", "create"):
            row = self.create(args[args.index("--name") + 1])
            out = "made\n"
            if self.record:
                out = ("generation          6bb23239-bcb6-4f7c-b635-3c4adc97d70f\n"
                       "replayed            false\n"
                       f"revision            {20 + len(self.rows)}\n"
                       "value.kind          terminal\n"
                       f"value.pane_id       pane_{len(self.rows):032x}\n"
                       f"value.workspace_id  {row['id']}\n")
        return subprocess.CompletedProcess(args, 0, out, "")

    # -- the socket (`bench.rpc`: the result, or {"error": ...})
    def rpc(self, method, params=None, timeout=60):
        p = params or {}
        if method == "action.run":
            name, args, target = p.get("action"), p.get("args") or {}, p.get("target")
            if name == "goToWorkspace":
                row = self.find(args.get("workspace"))
                if row is None or name in self.refuse:
                    return self.not_found(name, args.get("workspace"))
                self.select(row)
            elif name == "palette.moveWorkspaceToTop":
                row = self.find(target.get("id"))
                if row is None or name in self.refuse:
                    return self.not_found(name, target.get("id"))
                self.rows.remove(row)
                self.rows.insert(0, row)
            elif name == "openBrowser.chromium":
                if name in self.refuse:
                    self.refused.append((name, None))
                    return {"error": {"code": "unavailable", "message": "Chromium is not in this build"}}
                self.find(self.selected)["pages"] += 1
            return {"action": name, "ran": True}
        if method == "debug.sidebar_rows":
            window = {"rows": [{"key": f"workspace({r['id']})", "title": r["name"], "selected": r["id"] == self.selected,
                                "window_frame": {"x": 10, "y": 100 + 30 * i, "width": 200, "height": 28}}
                               for i, r in enumerate(self.rows)]}
            if self.items:
                # As the app: each layout item of the shown sections; one that is not drawn has no frame.
                frame = {"x": 10, "y": 40, "width": 200, "height": 28}
                window["items"] = ([{"id": f"itm_top_{n}", "region": "top", "window_frame": frame} for n in range(self.top)]
                                   + [{"id": "itm_not_drawn", "region": "top", "window_frame": None},
                                      {"id": "itm_account", "region": "bottom", "window_frame": frame}])
            return {"windows": [window]}
        if method == "snapshot.get":
            self.snapshots += 1
            return {"topology": {"workspaces": [{"id": r["id"], "name": r["name"]} for r in self.rows[: None if self.lists else 1]]}}
        if method == "debug.mouse":
            if p.get("action") == "click":
                self.inputs += 1
                index = int((p["y"] - 100) // 30)
                hit = 0 <= index < len(self.rows) and "click" not in self.dead and self.inputs not in self.deaf
                self.select(self.rows[index] if hit else None)
            return {}
        if method == "debug.key":
            self.inputs += 1
            key, at = p.get("key"), next((i for i, r in enumerate(self.rows) if r["id"] == self.selected), 0)
            if self.inputs in self.deaf:
                return {}
            if key.isdigit():
                self.select(self.numbered(int(key)))
            else:
                self.select(self.rows[(at + (1 if key == "]" else -1)) % len(self.rows)])
            return {}
        if method == "debug.workspace_switch":
            if p.get("action") == "start":
                self.recording, self.samples = True, []
                return {"recording": True}
            samples, self.recording, self.samples = self.samples, False, []
            return {"recording": False, "switches": samples}
        if method == "debug.frames":
            return {"max_ms": 8.33, "intervals_ms": [8.33] * 30, "refresh_ms": 8.33, "running": True, "frames": 30}
        return {}  # scroll and drag events, hover, hangs: the fake has no scroll position and no drag


class SwitchMatrixRefTests(unittest.TestCase):
    def run_with(self, app):
        bench.made.pop("switch_targets", None)
        bench.rpc, bench.cli = app.rpc, app.cli
        bench.wait = lambda predicate, seconds, step=0.25: predicate()  # one look: the fake app answers at once
        with mock.patch.object(bench.time, "sleep", lambda seconds: None), redirect_stdout(io.StringIO()):
            return bench.scenario_switch_matrix(1, 0)

    def test_no_call_of_the_matrix_is_refused_and_each_cell_switches_its_own_pair(self):
        app = FakeApp()
        out = self.run_with(app)
        self.assertEqual(len(app.refused), 0, f"the app refused {len(app.refused)} calls of the switch matrix as not_found "
                         f"({sorted({a for a, _ in app.refused})}); the id each named: {str(app.refused[0][1])[:60]!r}..." if app.refused else "")
        self.assertEqual(out["top_rows"], TARGETS)
        self.assertEqual({r["name"]: r["pages"] for r in app.rows},
                         {"sw chromium a": 1, "sw chromium b": 1, "sw term a": 0, "sw term b": 0, "bench start": 0})
        for cell in CELLS:
            entry, kind = out[cell], cell.split(".")[0]
            pair = {app.named(f"sw {'chromium' if kind == 'chromium' else 'term'} {x}")["id"] for x in "ab"}
            samples = entry["app_samples"]
            outside = [s for s in samples if s["from"] not in pair or s["to"] not in pair]
            self.assertEqual(len(outside), 0, f"{cell}: {len(outside)} of {len(samples)} switches left its pair of workspaces")
            self.assertEqual(len(samples), SWITCHES, f"{cell}: the app saw {len(samples)} switches for {SWITCHES} inputs")
            self.assertEqual(entry["wrong_selection_checks"], 0, cell)
            self.assertEqual({s["pages"] for s in samples}, {1 if kind == "chromium" else 0}, f"{cell}: the pages of the workspaces it showed")
        self.assertEqual(app.inputs, len(CELLS) * SWITCHES)

    def test_a_refused_setup_call_stops_the_run_with_the_answer_and_sends_no_input(self):
        for action, text in (("goToWorkspace", "not_found"), ("openBrowser.chromium", "Chromium is not in this build"),
                             ("palette.moveWorkspaceToTop", "not_found")):
            with self.subTest(action=action):
                app = FakeApp(refuse={action})
                with self.assertRaises(bench.SwitchStop) as stop:
                    self.run_with(app)
                self.assertIn(action, str(stop.exception))
                self.assertIn(text, str(stop.exception))
                self.assertEqual(len(app.refused), 1, "the run went on after the first refused call")
                self.assertEqual(app.inputs, 0, "a click or a key was sent after a refused setup call")

    def test_a_workspace_that_left_stops_the_run_at_its_cell(self):
        app = FakeApp()
        self.run_with(app)
        app.inputs = 0
        app.rows.remove(app.named("sw term a"))
        bench.rpc, bench.cli = app.rpc, app.cli
        with mock.patch.object(bench.time, "sleep", lambda seconds: None), redirect_stdout(io.StringIO()):
            with self.assertRaises(bench.SwitchStop) as stop:
                bench.scenario_switch_matrix(1, 0)  # the targets are made once: the second run uses the kept ids
        self.assertIn("goToWorkspace sw term a", str(stop.exception))
        self.assertEqual(sorted(stop.exception.cells), ["app_timer", "chromium.click", "chromium.cmd_digit", "chromium.next_prev", "tickers", "top_rows"])
        self.assertEqual(app.inputs, 3 * SWITCHES, "only the 3 cells of the page pair send inputs before the stop")

    def test_a_create_answer_with_no_workspace_id_stops_the_run(self):
        app = FakeApp(record=False)
        with self.assertRaises(bench.SwitchStop) as stop:
            self.run_with(app)
        self.assertIn("value.workspace_id", str(stop.exception))
        self.assertEqual(app.inputs, 0)

    def test_a_made_workspace_that_the_app_never_lists_stops_the_run_with_its_id(self):
        app = FakeApp(lists=False)
        with self.assertRaises(bench.SwitchStop) as stop:
            self.run_with(app)
        made = app.rows[1]  # the first target; the run made no second one
        self.assertEqual(len(app.rows), 2, "the run went on after a workspace the app did not list")
        self.assertIn(made["id"], str(stop.exception))
        self.assertIn(made["name"], str(stop.exception))
        self.assertEqual((app.snapshots, len(app.refused), app.inputs), (1, 0, 0))


class DeadCellTests(unittest.TestCase):
    """A cell whose inputs switch nothing is a fact of the run, not a row: the app's switch timer counted fewer
    switches than the cell sent inputs (a bench Mac, 2026-11-13, 400 workspaces: 40 clicks, 0 switches, and the cell
    gave numbers with wrong_selection_checks 0, because the tool looks at the selection only after each 4th input,
    which goes back to the workspace the cell started from)."""

    def run_with(self, app):
        return SwitchMatrixRefTests.run_with(self, app)

    def gate_rows(self, out):
        """The rows that perf-budgets.py (the Stable gate's mapper) makes from this matrix."""
        spec = importlib.util.spec_from_file_location("perf_budgets", os.path.join(HERE, "..", "perf-budgets.py"))
        budgets = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(budgets)
        rows = budgets.rows_sidebar({"sizes": {"0": {"switch_matrix": out}}}, 0)
        return sorted(name for name in rows if name.startswith("workspace_switch."))

    def test_clicks_that_switch_nothing_mark_their_cells_and_give_no_row_to_the_gate(self):
        app = FakeApp(dead={"click"})
        out = self.run_with(app)
        for cell in ("chromium.click", "terminal.click"):
            self.assertEqual(out[cell].get("invalid"), f"invalid: 0 of {SWITCHES} inputs switched", cell)
            self.assertEqual((out[cell]["switches"], out[cell]["app_switches"]), (SWITCHES, 0), cell)
            self.assertNotIn("input_to_idle_ms", out[cell], cell)
        rows = self.gate_rows(out)
        self.assertEqual(len([r for r in rows if ".click." in r]), 0, "the gate got rows from cells whose clicks switched nothing")
        self.assertEqual(len(rows), 4 * 3)  # the 4 key cells: idle, commit, longest frame
        for cell in CELLS:
            if not cell.endswith(".click"):
                self.assertNotIn("invalid", out[cell], cell)
        self.assertEqual(app.inputs, len(CELLS) * SWITCHES)  # the run goes on: each cell sent its inputs

    def test_one_input_that_switches_nothing_marks_its_cell_only(self):
        # Input 10 is the 2nd key of chromium.cmd_digit (Cmd-1, back to the cell's first workspace): the selection
        # stays, so the next key (Cmd-2, to the one that is selected) switches nothing too. The selection checks pass.
        app = FakeApp(deaf={SWITCHES + 2})
        out = self.run_with(app)
        self.assertEqual(out["chromium.cmd_digit"].get("invalid"), f"invalid: {SWITCHES - 2} of {SWITCHES} inputs switched")
        self.assertEqual([cell for cell in CELLS if "invalid" in out[cell]], ["chromium.cmd_digit"])
        self.assertEqual(len(self.gate_rows(out)), 5 * 3)

    def test_a_cell_with_a_switch_for_each_input_has_no_mark(self):
        out = self.run_with(FakeApp())
        self.assertEqual([cell for cell in CELLS if "invalid" in out[cell]], [])
        self.assertEqual([out[cell]["app_switches"] for cell in CELLS], [SWITCHES] * len(CELLS))
        self.assertEqual(len(self.gate_rows(out)), 6 * 3)


class CmdDigitNumberingTests(unittest.TestCase):
    """Cmd-1.. counts the shown top items (Home, the App Store) before the workspaces, the app's default. The tool
    sent Cmd-1/2 for the page pair and Cmd-3/4 for the terminal pair whatever the sidebar showed, so with top items
    its cmd_digit cells switched another pair: each input switched, only the selection check saw it, and the check
    was no part of the cell's mark (a bench Mac, 2026-11-13: terminal.cmd_digit, 10 of 10 checks wrong, 3 rows)."""

    def run_with(self, app):
        return SwitchMatrixRefTests.run_with(self, app)

    def gate_rows(self, out):
        return DeadCellTests.gate_rows(self, out)

    def test_the_digit_of_a_workspace_counts_the_shown_top_items_before_it(self):
        for top in (1, 2):
            with self.subTest(top=top):
                app = FakeApp(top=top)
                out = self.run_with(app)
                self.assertEqual([cell for cell in CELLS if "invalid" in out[cell]], [])
                for cell in ("chromium.cmd_digit", "terminal.cmd_digit"):
                    pair = {app.named(f"sw {'chromium' if cell.startswith('chromium') else 'term'} {x}")["id"] for x in "ab"}
                    samples = out[cell]["app_samples"]
                    outside = [s for s in samples if s["from"] not in pair or s["to"] not in pair]
                    self.assertEqual((len(samples), len(outside)), (SWITCHES, 0), f"{cell}: switches, and those that left its pair")
                self.assertEqual(len(self.gate_rows(out)), 6 * 3)
                self.assertEqual(out.get("top_digits"), [top + 1, top + 2, top + 3, top + 4])

    def test_a_cell_whose_selection_checks_fail_is_marked_and_gives_no_row_to_the_gate(self):
        # The report lists no item, so the tool's digits are 2 too low: each key switches (the count rule passes)
        # and each selection check finds a workspace that the cell does not name.
        app = FakeApp(top=2, items=False)
        out = self.run_with(app)
        checks = SWITCHES // 4
        for cell in ("chromium.cmd_digit", "terminal.cmd_digit"):
            self.assertEqual(out[cell].get("invalid"), f"invalid: {checks} of {checks} selection checks found another workspace", cell)
            self.assertEqual((out[cell]["switches"], out[cell]["app_switches"], out[cell]["wrong_selection_checks"]), (SWITCHES, SWITCHES, checks), cell)
            self.assertNotIn("input_to_idle_ms", out[cell], cell)
        rows = self.gate_rows(out)
        self.assertEqual(len([r for r in rows if ".cmd_digit." in r]), 0, "the gate got rows from cells that switched another pair")
        self.assertEqual(len(rows), 4 * 3)
        self.assertEqual([cell for cell in CELLS if "invalid" in out[cell]], ["chromium.cmd_digit", "terminal.cmd_digit"])

    def test_a_workspace_with_no_digit_marks_its_cell_and_sends_no_key(self):
        # 6 top items: the page pair is Cmd-7 and Cmd-8; the terminal pair has no digit (Cmd-9 can be "the last").
        app = FakeApp(top=6)
        out = self.run_with(app)
        self.assertEqual(app.inputs, 5 * SWITCHES, "keys were sent for a pair that has no digit")
        self.assertEqual(out["terminal.cmd_digit"].get("invalid"), f"invalid: 0 of {SWITCHES} inputs switched")
        self.assertEqual([cell for cell in CELLS if "invalid" in out[cell]], ["terminal.cmd_digit"])
        self.assertEqual(out.get("top_digits"), [7, 8, None, None])
        self.assertEqual(len(self.gate_rows(out)), 5 * 3)


class StoppedRunKeepsItsRowsTests(unittest.TestCase):
    """A stop of the switch matrix is the end of the run (exit 1), not the loss of the rows the run measured: the
    size's entry holds the scenarios before the matrix and after it, and no switch row."""

    def run_main(self, app, scenarios):
        bench.results["sizes"], bench.results["log"] = {}, []
        bench.made.clear()
        bench.made.update({"workspaces": [], "tickers": [], "groups": [], "pinned": []})
        bench.rpc, bench.cli = app.rpc, app.cli
        bench.wait = lambda predicate, seconds, step=0.25: predicate()
        bench.launch_app = lambda *a, **k: (types.SimpleNamespace(pid=1), "/nonexistent/app.sock")
        bench.opts.sizes, bench.opts.scenarios, bench.opts.stop = "0", scenarios, False
        stop = None
        with mock.patch.object(bench.time, "sleep", lambda seconds: None), redirect_stdout(io.StringIO()):
            try:
                bench.main()
            except SystemExit as error:
                stop = error
        return stop, json.load(open(os.path.join(OUT, "results.json")))

    def test_a_refused_move_after_the_scroll_keeps_the_scroll_and_drag_rows_and_exits_1(self):
        app = FakeApp(refuse={"palette.moveWorkspaceToTop"})
        stop, results = self.run_main(app, "scroll,switch_matrix,drag")
        self.assertEqual(len(results["sizes"]), 1, "the stop of the switch matrix lost the size's entry (the scroll rows of this run)")
        entry = results["sizes"]["0"]
        self.assertEqual(entry["scroll"]["events"], 600)
        self.assertEqual(entry["drag"]["moves"], 180, "the scenario after the switch matrix did not run")
        self.assertEqual([k for k, v in entry["switch_matrix"].items() if isinstance(v, dict)], [], "a stopped matrix gave switch rows")
        self.assertIn("palette.moveWorkspaceToTop", entry["switch_matrix"]["error"])
        self.assertIsNotNone(stop, "the run did not exit after a refused move")
        self.assertIsInstance(stop.code, str)  # exit status 1, the text on stderr
        self.assertIn("not_found", stop.code)
        self.assertIs(results["measurement_complete"], False)
        self.assertEqual(app.inputs, 0)

    def test_a_stop_at_a_later_cell_keeps_the_cells_that_ended(self):
        app = FakeApp()
        real = app.rpc

        def rpc(method, params=None, timeout=60):
            # The terminal pair's first workspace leaves when the page pair's 3 cells have ended.
            if app.inputs == 3 * SWITCHES and any(r["name"] == "sw term a" for r in app.rows):
                app.rows.remove(app.named("sw term a"))
            return real(method, params, timeout)

        app.rpc = rpc
        stop, results = self.run_main(app, "switch_matrix")
        matrix = results["sizes"]["0"]["switch_matrix"]
        self.assertEqual(sorted(k for k, v in matrix.items() if isinstance(v, dict)),
                         ["chromium.click", "chromium.cmd_digit", "chromium.next_prev"])
        self.assertIn("goToWorkspace sw term a", matrix["error"])
        self.assertIsNotNone(stop)
        self.assertEqual(app.inputs, 3 * SWITCHES)

    def test_a_run_with_an_invalid_cell_runs_to_its_end_and_is_not_complete(self):
        stop, results = self.run_main(FakeApp(dead={"click"}), "switch_matrix,drag")
        self.assertIsNone(stop, "an invalid cell is a fact of the run, not a stop")
        entry = results["sizes"]["0"]
        self.assertEqual(entry["drag"]["moves"], 180, "the scenario after the switch matrix did not run")
        self.assertEqual(len([k for k, v in entry["switch_matrix"].items() if isinstance(v, dict) and "invalid" in v]), 2)
        self.assertEqual((entry["measurement_complete"], results["measurement_complete"]), (False, False),
                         "a run with 2 invalid cells said that its measurement is complete")

    def test_a_run_with_no_stop_ends_as_before(self):
        stop, results = self.run_main(FakeApp(), "scroll,switch_matrix,drag")
        self.assertIsNone(stop)
        entry = results["sizes"]["0"]
        self.assertEqual(sorted(k for k, v in entry["switch_matrix"].items() if isinstance(v, dict) and "input_to_idle_ms" in v), sorted(CELLS))
        self.assertNotIn("error", entry["switch_matrix"])
        self.assertIs(results["measurement_complete"], True)


if __name__ == "__main__":
    unittest.main()
