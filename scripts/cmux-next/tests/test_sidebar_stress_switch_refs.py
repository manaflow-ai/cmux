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
import importlib.util, io, os, subprocess, sys, tempfile, types, unittest
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

    def __init__(self, refuse=(), record=True):
        self.rows = []
        self.selected = None
        self.refuse = set(refuse)   # actions that this app refuses whatever they name
        self.record = record        # False: `workspace create` answers a text with no id
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
            return {"windows": [{"rows": [{"key": f"workspace({r['id']})", "title": r["name"], "selected": r["id"] == self.selected,
                                           "window_frame": {"x": 10, "y": 100 + 30 * i, "width": 200, "height": 28}}
                                          for i, r in enumerate(self.rows)]}]}
        if method == "snapshot.get":
            return {"topology": {"workspaces": [{"id": r["id"], "name": r["name"]} for r in self.rows]}}
        if method == "debug.mouse":
            if p.get("action") == "click":
                self.inputs += 1
                index = int((p["y"] - 100) // 30)
                self.select(self.rows[index] if 0 <= index < len(self.rows) else None)
            return {}
        if method == "debug.key":
            self.inputs += 1
            key, at = p.get("key"), next(i for i, r in enumerate(self.rows) if r["id"] == self.selected)
            if key.isdigit():
                self.select(self.rows[int(key) - 1] if int(key) <= len(self.rows) else None)
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
        return {}


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
                with self.assertRaises(SystemExit) as stop:
                    self.run_with(app)
                self.assertIsInstance(stop.exception.code, str)  # a text: the exit status is 1 and the text is printed
                self.assertIn(action, stop.exception.code)
                self.assertIn(text, stop.exception.code)
                self.assertEqual(len(app.refused), 1, "the run went on after the first refused call")
                self.assertEqual(app.inputs, 0, "a click or a key was sent after a refused setup call")

    def test_a_workspace_that_left_stops_the_run_at_its_cell(self):
        app = FakeApp()
        self.run_with(app)
        app.inputs = 0
        app.rows.remove(app.named("sw term a"))
        bench.rpc, bench.cli = app.rpc, app.cli
        with mock.patch.object(bench.time, "sleep", lambda seconds: None), redirect_stdout(io.StringIO()):
            with self.assertRaises(SystemExit) as stop:
                bench.scenario_switch_matrix(1, 0)  # the targets are made once: the second run uses the kept ids
        self.assertIn("goToWorkspace", stop.exception.code)
        self.assertIn("sw term a", stop.exception.code)
        self.assertEqual(app.inputs, 3 * SWITCHES, "only the 3 cells of the page pair send inputs before the stop")

    def test_a_create_answer_with_no_workspace_id_stops_the_run(self):
        app = FakeApp(record=False)
        with self.assertRaises(SystemExit) as stop:
            self.run_with(app)
        self.assertIn("value.workspace_id", stop.exception.code)
        self.assertEqual(app.inputs, 0)


if __name__ == "__main__":
    unittest.main()
