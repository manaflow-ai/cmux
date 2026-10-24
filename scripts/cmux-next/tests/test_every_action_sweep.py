#!/usr/bin/env python3
"""every-action-sweep.py's own harness (deep review bench-small, 2026-10-23), against an in-memory app socket.

1. A row that closed panes gets exactly those panes back. The sweep reopens by id (`history.reopen`) the
   closed-history entries the measured input made, never the newest entry of the history (Cmd-Shift-T): the
   sweep's own cleanup closes fill that history, and a reopen lands in the store after its reply. The layout must
   then equal the base (per pane: its column and the multiset of its tab kinds), not only reach its counts.
2. A session that fails fails the run: main() exits FAILED_SESSION_EXIT, every-action.md names the failed session,
   and --merge keeps a shard's failure (and exits the same way) instead of reading its missing rows as covered.
3. STRESS has one shape or the session fails (P12): a build of another layout raises StressShapeError, and a
   mid-session rebuild or tab restore of another layout raises SessionShapeError, instead of being measured as
   `stress`; a rebuild replaces the damaged measured workspace; a lost tab comes back as the kind the builder made
   (WebKit stays WebKit). A builder step that only timed out in a restore (focus never reached a pane) is a harness
   row of that action, not a failed session, in light and STRESS alike.
4. An unreadable closed history before the input reopens nothing (older cleanup groups never come back), and an
   app that does not come back at a relaunch (LaunchError) is a failed session in the report, not a lost report.

No app, GUI or build: the module's socket helper is replaced by a model of the topology, focus and closed history.
Run: python3 -I scripts/cmux-next/tests/test_every_action_sweep.py
"""
import copy, importlib.util, itertools, json, os, shutil, sys, tempfile, unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.dirname(HERE)
OUT = tempfile.mkdtemp(prefix="every-action-test-")


def load_sweep():
    argv = sys.argv
    sys.argv = ["every-action-sweep.py", "--app", "-", "--tag", "unit-test", "--out", OUT, "--repeat", "1", "--settle", "0"]
    try:
        spec = importlib.util.spec_from_file_location("every_action_sweep", os.path.join(SCRIPTS, "every-action-sweep.py"))
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
    finally:
        sys.argv = argv
    return module


sweep_mod = load_sweep()
stress_mod = sweep_mod.load("perf_stress_session", "perf-stress-session.py")


class NoProcess:
    """The sweep's App as restore() reads it: no child process to have exited."""
    process = None


class FakeApp:
    """One window's workspaces, focus and closed history, as snapshot.get, action.run and history.list show them.
    A reopen lands `lag` snapshots after its reply (the store applies the daemon's reply later). A reopened pane
    or tab gets new ids; its terminal keeps its process (the reopen attaches inside the reap grace)."""

    def __init__(self, lag=0):
        self.ids = itertools.count(100)
        self.lag = lag
        self.pending = []  # [snapshots left, apply]
        self.closed = []  # newest first
        self.workspaces = []
        self.focus = {"window": "win_1"}
        self.elsewhere = None  # the pane `test.closeElsewhere` closes
        self.doomed_tab = None  # the tab `test.closeDoomedTab` closes
        self.history_errors = 0  # the next N history.list reads fail (a socket timeout under load)
        self.reopened = []  # closed ids history.reopen brought back, in order
        self.engines = {}  # tab id -> webkit or chromium (the app knows; snapshot.get says `browser` for both)

    def new_id(self, prefix):
        return f"{prefix}_{next(self.ids)}"

    def pane(self, column, kinds):
        tabs = []
        for kind in kinds:
            tab = {"id": self.new_id("tab"), "kind": kind, "selected": False}
            if kind == "terminal":
                tab["terminal"] = self.new_id("term")
            tabs.append(tab)
        tabs[-1]["selected"] = True
        return {"id": self.new_id("pane"), "column": column, "tabs": tabs}

    def workspace(self, panes):
        workspace = {"id": self.new_id("ws"), "screens": [{"id": self.new_id("screen"), "panes": panes}]}
        self.workspaces.append(workspace)
        return workspace

    def focus_on(self, workspace, pane):
        self.focus.update(workspace=workspace["id"], pane=pane["id"],
                          tab=next(t["id"] for t in pane["tabs"] if t["selected"]))

    def find_pane(self, pane_id):
        for workspace in self.workspaces:
            for screen in workspace["screens"]:
                for index, pane in enumerate(screen["panes"]):
                    if pane["id"] == pane_id:
                        return workspace, screen, index
        return None

    def record(self, item):
        item["id"] = "daemon:" + self.new_id("closed")
        self.closed.insert(0, item)

    def close_pane(self, pane_id):
        workspace, screen, index = self.find_pane(pane_id)
        pane = screen["panes"].pop(index)
        self.record({"kind": "pane", "workspace": workspace["id"], "screen": screen["id"], "index": index, "pane": pane})

    def close_tab(self, tab_id):
        for workspace in self.workspaces:
            for screen in workspace["screens"]:
                for pane in screen["panes"]:
                    for index, tab in enumerate(pane["tabs"]):
                        if tab["id"] == tab_id:
                            pane["tabs"].pop(index)
                            self.record({"kind": "tab", "pane": pane["id"], "index": index, "tab": tab})
                            return

    def close_workspace(self, workspace_id):
        workspace = next(w for w in self.workspaces if w["id"] == workspace_id)
        self.workspaces.remove(workspace)
        self.record({"kind": "workspace", "workspace": workspace})

    def add_tab(self, pane_id, kind, engine=None, url=None):
        workspace, screen, index = self.find_pane(pane_id)
        tabs = screen["panes"][index]["tabs"]
        tab = {"id": self.new_id("tab"), "kind": kind, "selected": True}
        if kind == "terminal":
            tab["terminal"] = self.new_id("term")
        if url:
            tab["url"] = url
        if engine:
            self.engines[tab["id"]] = engine
        for other in tabs:
            other["selected"] = False
        tabs.append(tab)

    def reopen(self, item):
        def apply():
            if item["kind"] == "pane":
                pane = copy.deepcopy(item["pane"])
                pane["id"] = self.new_id("pane")
                for tab in pane["tabs"]:
                    old, tab["id"] = tab["id"], self.new_id("tab")
                    if old in self.engines:
                        self.engines[tab["id"]] = self.engines.pop(old)
                workspace = next(w for w in self.workspaces if w["id"] == item["workspace"])
                screen = next(s for s in workspace["screens"] if s["id"] == item["screen"])
                screen["panes"].insert(item["index"], pane)
            elif item["kind"] == "tab":
                found = self.find_pane(item["pane"])
                if found:
                    workspace, screen, index = found
                    tab = dict(item["tab"], id=self.new_id("tab"))
                    if item["tab"]["id"] in self.engines:
                        self.engines[tab["id"]] = self.engines.pop(item["tab"]["id"])
                    screen["panes"][index]["tabs"].insert(item["index"], tab)
            else:
                workspace = copy.deepcopy(item["workspace"])
                workspace["id"] = self.new_id("ws")
                self.workspaces.append(workspace)
        self.pending.append([self.lag, apply])

    def topology(self):
        return {"windows": [{"id": "win_1"}], "workspaces": copy.deepcopy(self.workspaces), "focus": dict(self.focus)}

    def rpc(self, method, params=None, timeout=60):
        params = params or {}
        if method == "snapshot.get":
            for entry in list(self.pending):
                entry[0] -= 1
                if entry[0] <= 0:
                    self.pending.remove(entry)
                    entry[1]()
            return {"topology": self.topology()}
        if method == "history.list":
            if self.history_errors:
                self.history_errors -= 1
                return {"error": {"code": "timeout", "message": "history.list missed its deadline"}}
            return {"entries": [{"id": "closed:" + c["id"], "kind": "closed", "closed_id": c["id"]} for c in self.closed]}
        if method == "settings.get":
            return {"value": {}}
        if method == "action.describe":
            return {"action": {"available": True}}
        if method == "system.ping":
            return {"pong": True}
        if method != "action.run":
            return {}
        action, args = params.get("action"), params.get("args") or {}
        target = (params.get("target") or "").partition(":")[2]
        if action == "closePane":
            self.close_pane(target or self.focus["pane"])
        elif action == "closeTab":
            self.close_tab(target)
        elif action == "closeWorkspace":
            self.close_workspace(target)
        elif action == "test.closeElsewhere":
            self.close_pane(self.elsewhere)
        elif action == "test.closeDoomedTab":
            self.close_tab(self.doomed_tab)
        elif action == "newSurface":
            self.add_tab(target, "terminal")
        elif action in ("openBrowser.chromium", "openBrowser.webkit"):
            self.add_tab(target, "browser", engine=action.partition(".")[2], url=args.get("url"))
        elif action == "palette.newAgentChat":
            self.add_tab(target, "conversation")
        elif action == "newTab.page":
            self.add_tab(target, "page")
        elif action == "reopenClosedBrowserPanel":
            if self.closed:
                self.reopen(self.closed.pop(0))
        elif action == "history.reopen":
            item = next((c for c in self.closed if c["id"] == args.get("id")), None)
            if item is None:
                return {"error": {"code": "not_found", "message": "the entry is gone"}}
            self.closed.remove(item)
            self.reopened.append(item["id"])
            self.reopen(item)
        elif action == "pane.focus":
            found = self.find_pane(target)
            if found:
                self.focus.update(workspace=found[0]["id"], pane=target)
        elif action == "tab.focus":
            self.focus["tab"] = target
        elif action == "goToWorkspace":
            self.focus["workspace"] = args.get("workspace")
        return {}


def layout(fake, workspace_id):
    """Per pane of `workspace_id`, in order: its column and its sorted tab kinds."""
    workspace = next((w for w in fake.workspaces if w["id"] == workspace_id), None)
    assert workspace is not None, f"workspace {workspace_id} is gone"
    return [(p["column"], sorted(t["kind"] for t in p["tabs"])) for s in workspace["screens"] for p in s["panes"]]


class ReopenTests(unittest.TestCase):
    def sweep(self, fake, base):
        sweep = sweep_mod.Sweep(NoProcess(), "light", stress_mod)
        sweep.builder = stress_mod.Stress(fake.rpc, log=lambda line: None)
        sweep.snapshot_base(base["id"])
        return sweep

    def test_a_closed_pane_comes_back_once_by_id_when_the_reopen_lands_late(self):
        fake = FakeApp(lag=2)
        other = fake.workspace([fake.pane(None, ["terminal"])])
        measured = fake.pane(0, ["browser", "browser", "browser", "conversation", "terminal", "terminal"])
        base = fake.workspace([measured, fake.pane(1, ["terminal"])])
        # An earlier row's cleanup closed a pane of the base workspace: it sits lower in the closed history.
        leftover = fake.pane(2, ["terminal", "browser"])
        base["screens"][0]["panes"].append(leftover)
        fake.close_pane(leftover["id"])
        fake.focus_on(base, measured)
        with mock.patch.object(sweep_mod, "rpc", fake.rpc):
            sweep = self.sweep(fake, base)
            want = layout(fake, base["id"])
            row = sweep.run_action({"id": "closePane", "title": "Close Pane"})
            # Anything still landing lands now: the base must stay what it was, not grow by the older entry.
            for _ in range(4):
                fake.rpc("snapshot.get")
        self.assertEqual(row.get("check"), "ok", row)
        self.assertEqual(layout(fake, base["id"]), want)
        self.assertEqual([w["id"] for w in fake.workspaces], [other["id"], base["id"]])
        # The base pane is the reopened pane at the base pane's place, and it has the focus.
        panes = next(w for w in fake.workspaces if w["id"] == base["id"])["screens"][0]["panes"]
        self.assertEqual(sweep.base["pane"], panes[0]["id"])
        self.assertEqual(fake.focus["pane"], panes[0]["id"])

    def test_an_unreadable_history_before_the_input_reopens_nothing_older(self):
        fake = FakeApp()
        measured = fake.pane(0, ["terminal", "browser", "terminal"])
        base = fake.workspace([measured, fake.pane(1, ["terminal"])])
        # An earlier row's cleanup closed a pane of the base workspace: an older entry of the closed history.
        leftover = fake.pane(2, ["terminal", "browser"])
        base["screens"][0]["panes"].append(leftover)
        fake.close_pane(leftover["id"])
        older = fake.closed[0]["id"]
        fake.focus_on(base, measured)
        fake.doomed_tab = measured["tabs"][0]["id"]
        with mock.patch.object(sweep_mod, "rpc", fake.rpc):
            sweep = self.sweep(fake, base)
            want = layout(fake, base["id"])
            # history.list misses its deadline once: at the mark just before the measured input.
            fake.history_errors = 1
            row = sweep.run_action({"id": "test.closeDoomedTab", "title": "Close one tab"})
        self.assertNotIn(older, fake.reopened)
        self.assertEqual(fake.reopened, [])
        self.assertEqual(layout(fake, base["id"]), want)
        self.assertTrue(any("closed history unread" in d for d in row["drift"]), row["drift"])

    def test_a_pane_closed_in_another_workspace_comes_back_there(self):
        fake = FakeApp()
        measured = fake.pane(0, ["terminal", "browser"])
        base = fake.workspace([measured])
        gone = fake.pane(1, ["terminal"])
        other = fake.workspace([fake.pane(0, ["browser"]), gone])
        fake.elsewhere = gone["id"]
        fake.focus_on(base, measured)
        with mock.patch.object(sweep_mod, "rpc", fake.rpc):
            sweep = self.sweep(fake, base)
            want_base, want_other = layout(fake, base["id"]), layout(fake, other["id"])
            sweep.run_action({"id": "test.closeElsewhere", "title": "Close a pane elsewhere"})
        self.assertEqual(layout(fake, other["id"]), want_other)
        self.assertEqual(layout(fake, base["id"]), want_base)
        self.assertEqual(sweep.base["pane"], measured["id"])
        self.assertEqual(fake.focus["pane"], measured["id"])


def session(name, rows, failures=None):
    out = {"name": name, "summary": {}, "validity": {"chromium_ok": True, "cef_flags": []}, "idle": {"frames": {}},
           "rows": rows, "interactions": []}
    if failures:
        out["failed"] = failures
    return out


ENV = {"host": "cmux-test", "macos": "26.1", "sha": "a" * 40}


class FailedSessionTests(unittest.TestCase):
    def test_a_session_that_fails_fails_the_run_and_the_report_says_so(self):
        class App:
            process = None

            def launch(self):
                pass

            def relaunch(self):
                pass

            def stop(self):
                pass

        class Failing(sweep_mod.Sweep):
            def run(self, actions):
                raise RuntimeError("socket timeout while the light session was built")

        def rpc(method, params=None, timeout=60):
            return {"actions": []} if method == "action.list" else {}

        signposts = sweep_mod.SIGNPOSTS
        with mock.patch.object(sweep_mod, "App", App), mock.patch.object(sweep_mod, "Sweep", Failing), \
                mock.patch.object(sweep_mod, "rpc", rpc), mock.patch.object(signposts, "live", False), \
                mock.patch.object(signposts, "start", lambda module: setattr(signposts, "live", True)), \
                mock.patch.object(sweep_mod.opts, "sessions", "light"), mock.patch.object(sweep_mod.opts, "keep", True), \
                mock.patch.dict(os.environ, {"CMUX_CI_SHA": "b" * 40}):
            with self.assertRaises(SystemExit) as raised:
                sweep_mod.main()
        self.assertEqual(raised.exception.code, sweep_mod.FAILED_SESSION_EXIT)
        self.assertNotEqual(sweep_mod.FAILED_SESSION_EXIT, 0)
        with open(os.path.join(OUT, "every-action.json")) as f:
            report = json.load(f)
        self.assertEqual([f["name"] for f in report["failed_sessions"]], ["light"])
        with open(os.path.join(OUT, "every-action.md")) as f:
            md = f.read()
        self.assertIn("light", md)
        self.assertIn("socket timeout while the light session was built", md)

    def run_main(self, sessions, sweep_class, relaunch=None):
        """main() over `sessions` with `sweep_class` as Sweep and an app whose relaunch calls `relaunch`; returns
        the SystemExit code, the report and the markdown."""
        class App:
            process = None

            def launch(self):
                pass

            def relaunch(self):
                if relaunch:
                    relaunch()

            def stop(self):
                pass

        def rpc(method, params=None, timeout=60):
            return {"actions": []} if method == "action.list" else {}

        signposts = sweep_mod.SIGNPOSTS
        with mock.patch.object(sweep_mod, "App", App), mock.patch.object(sweep_mod, "Sweep", sweep_class), \
                mock.patch.object(sweep_mod, "rpc", rpc), mock.patch.object(signposts, "live", False), \
                mock.patch.object(signposts, "start", lambda module: setattr(signposts, "live", True)), \
                mock.patch.object(sweep_mod.opts, "sessions", sessions), mock.patch.object(sweep_mod.opts, "keep", True), \
                mock.patch.dict(os.environ, {"CMUX_CI_SHA": "b" * 40}):
            with self.assertRaises(SystemExit) as raised:
                sweep_mod.main()
        with open(os.path.join(OUT, "every-action.json")) as f:
            report = json.load(f)
        with open(os.path.join(OUT, "every-action.md")) as f:
            md = f.read()
        return raised.exception.code, report, md

    def test_an_app_that_does_not_come_back_mid_session_is_a_failed_session_in_the_report(self):
        class Sweep(sweep_mod.Sweep):
            def run(self, actions):
                self.validity, self.idle, self.summary = {"chromium_ok": True}, {"frames": {}}, {}
                if self.session == "light":
                    # Sweep.run relaunched after the app stopped answering, and the app crashed at launch.
                    self.rows.append({"session": "light", "kind": "action", "id": "closePane",
                                      "errors": ["the app stopped answering"], "frames": {"missed": None}, "check": "n/a"})
                    raise sweep_mod.LaunchError("crash", {"detail": "EXC_BAD_ACCESS (SIGSEGV) at launch", "log_tail": ""})
                return self

        code, report, md = self.run_main("light,stress", Sweep)
        self.assertEqual(code, sweep_mod.FAILED_SESSION_EXIT)
        self.assertEqual([(f["name"], f["rows"]) for f in report["failed_sessions"]], [("light", 1)])
        # The light rows before the crash are kept, and the next session still ran on a fresh launch.
        self.assertEqual([s["name"] for s in report["sessions"]], ["light", "stress"])
        self.assertEqual([r["id"] for r in report["sessions"][0]["rows"]], ["closePane"])
        self.assertIn("FAILED", md)
        self.assertIn("EXC_BAD_ACCESS (SIGSEGV) at launch", md)

    def test_an_app_that_does_not_come_back_between_sessions_is_a_failed_session_in_the_report(self):
        class Sweep(sweep_mod.Sweep):
            def run(self, actions):
                self.validity, self.idle, self.summary = {"chromium_ok": True}, {"frames": {}}, {}
                return self

        def relaunch():
            raise sweep_mod.LaunchError("crash", {"detail": "the app exited at launch (code -11)", "log_tail": ""})

        code, report, md = self.run_main("light,stress", Sweep, relaunch=relaunch)
        self.assertEqual(code, sweep_mod.FAILED_SESSION_EXIT)
        self.assertEqual([f["name"] for f in report["failed_sessions"]], ["stress"])
        self.assertEqual([s["name"] for s in report["sessions"]], ["light"])
        self.assertIn("FAILED", md)
        self.assertIn("the app exited at launch (code -11)", md)

    def test_a_session_that_failed_partway_is_marked_in_the_markdown(self):
        failure = {"name": "stress", "error": "RuntimeError('the app exited (code -11)')", "rows": 1}
        report = {"env": ENV, "sessions": [session("stress", [{"id": "closePane"}], [failure])], "failed_sessions": [failure]}
        md = sweep_mod.markdown(report)
        stress = md[md.index("## stress"):]
        self.assertIn("the app exited (code -11)", stress)

    def test_merge_keeps_a_shards_failure(self):
        folder = tempfile.mkdtemp(prefix="every-action-merge-", dir=OUT)
        failure = {"name": "stress", "error": "RuntimeError('the app exited (code -11)')", "rows": 1}
        shards = [{"env": dict(ENV, shard="1/2"), "sessions": [session("stress", [{"id": "a"}])]},
                  {"env": dict(ENV, shard="2/2"), "sessions": [session("stress", [{"id": "b"}], [failure])],
                   "failed_sessions": [failure]}]
        paths = []
        for index, shard in enumerate(shards):
            paths.append(os.path.join(folder, f"shard{index}.json"))
            with open(paths[-1], "w") as f:
                json.dump(shard, f)
        out = os.path.join(folder, "every-action.json")
        with self.assertRaises(SystemExit) as raised:
            sweep_mod.merge(out, paths)
        self.assertEqual(raised.exception.code, sweep_mod.FAILED_SESSION_EXIT)
        with open(out) as f:
            merged = json.load(f)
        self.assertEqual([(f["name"], f.get("shard")) for f in merged["failed_sessions"]], [("stress", "2/2")])
        self.assertTrue(merged["sessions"][0].get("failed"))
        with open(os.path.join(folder, "every-action.md")) as f:
            self.assertIn("the app exited (code -11)", f.read())


# What perf-stress-session's summary() gives for the STRESS shape (Stress.check accepts it).
STRESS_OK = {"workspaces": 60, "shown_columns": 4, "window": [80, 40, 1600, 1000], "measured_panes": 14,
             "measured_tabs": {"terminal": 28, "browser": 42, "conversation": 14}, "refusals": [],
             "busy_terminals": stress_mod.BUSY_TERMINALS, "pane_problems": [], "chromium_unavailable": [],
             "background_chromium": [stress_mod.CHROMIUM_PER_WORKSPACE] * stress_mod.CHROMIUM_WORKSPACES}
# What a host where only three columns fit builds.
STRESS_NARROW = dict(STRESS_OK, shown_columns=3, measured_panes=11, measured_tabs={"terminal": 22, "browser": 33, "conversation": 11})


class StressShapeTests(unittest.TestCase):
    def stress_app(self):
        fake = FakeApp()
        measured = fake.pane(0, ["terminal", "browser"])
        base = fake.workspace([measured])
        fake.workspace([fake.pane(0, ["terminal"])])
        fake.focus_on(base, measured)
        return fake, base

    def patched(self, fake, summary):
        def build_measured(builder):
            pane = fake.pane(0, ["terminal", "browser"])
            workspace = fake.workspace([pane])
            fake.focus_on(workspace, pane)
            builder.measured = workspace["id"]
            return workspace["id"]
        return [mock.patch.object(sweep_mod, "rpc", fake.rpc),
                mock.patch.object(stress_mod.Stress, "build_background", lambda builder, *a, **k: []),
                mock.patch.object(stress_mod.Stress, "build_measured", build_measured),
                mock.patch.object(stress_mod.Stress, "summary", lambda builder: dict(summary)),
                # The window is STRESS's size: the build gets to its shape check.
                mock.patch.object(stress_mod.Stress, "size_window", lambda builder: {"frame": list(stress_mod.WINDOW)}),
                mock.patch("time.sleep")]

    def run_patched(self, patches, body):
        for patch in patches:
            patch.start()
        try:
            return body()
        finally:
            for patch in reversed(patches):
                patch.stop()

    def test_a_stress_build_of_another_shape_fails_the_session(self):
        fake, _ = self.stress_app()
        sweep = sweep_mod.Sweep(NoProcess(), "stress", stress_mod)
        with self.assertRaises(stress_mod.StressShapeError):
            self.run_patched(self.patched(fake, STRESS_NARROW), sweep.build)

    def test_a_stress_rebuild_of_another_shape_fails_the_session(self):
        fake, base = self.stress_app()
        sweep = sweep_mod.Sweep(NoProcess(), "stress", stress_mod)

        def body():
            sweep.builder = stress_mod.Stress(fake.rpc, log=lambda line: None)
            sweep.snapshot_base(base["id"])
            sweep.rebuild({"workspaces": 1})
        with self.assertRaises(sweep_mod.SessionShapeError):
            self.run_patched(self.patched(fake, STRESS_NARROW), body)

    def webkit_pane(self, fake):
        """A STRESS-like measured pane the builder made in `fake` (terminal, then Chromium, Chromium, WebKit, chat,
        terminal) and the sweep's base on it; returns the sweep and the pane id. Runs inside ``patched(fake, ...)``."""
        pane = fake.pane(0, ["terminal"])
        base = fake.workspace([pane])
        fake.workspace([fake.pane(0, ["terminal"])])
        fake.focus_on(base, pane)
        sweep = sweep_mod.Sweep(NoProcess(), "stress", stress_mod)
        sweep.builder = stress_mod.Stress(fake.rpc, log=lambda line: None)
        for kind in ["chromium", "chromium", "webkit", "chat", "terminal"]:
            sweep.builder.add_tab(base["id"], pane["id"], kind)
        sweep.builder.measured = base["id"]
        sweep.snapshot_base(base["id"])
        return sweep, pane["id"]

    def engines(self, fake, pane_id):
        _, screen, index = fake.find_pane(pane_id)
        return sorted(fake.engines.get(t["id"], t["kind"]) for t in screen["panes"][index]["tabs"])

    def test_a_lost_webkit_tab_comes_back_as_webkit_and_the_tab_path_checks_the_shape(self):
        fake = FakeApp()
        checked = []
        patches = self.patched(fake, STRESS_OK) + [
            mock.patch.object(stress_mod.Stress, "check", staticmethod(lambda summary: checked.append(summary)))]

        def body():
            sweep, pane = self.webkit_pane(fake)
            want = self.engines(fake, pane)
            webkit = next(tab for kind, tab in sweep.builder.made[pane] if kind == "webkit")
            # The tab is gone with no closed entry of the input's own (moved out, or its entry came too late):
            # the tab path runs.
            fake.close_tab(webkit)
            sweep.rebuild({"tabs": 1})
            return sweep, pane, want
        sweep, pane, want = self.run_patched(patches, body)
        self.assertEqual(self.engines(fake, pane), want)
        self.assertEqual(sorted(kind for kind, _ in sweep.builder.made[pane]),
                         ["chat", "chromium", "chromium", "terminal", "webkit"])
        self.assertEqual(len(checked), 1)

    def test_a_tab_restore_of_another_shape_fails_the_session(self):
        fake = FakeApp()
        wrong = dict(STRESS_OK, pane_problems=["pane pane_1: 6 tabs, made {'terminal': 2, 'chromium': 3, 'webkit': 0, 'chat': 1}"])

        def body():
            sweep, pane = self.webkit_pane(fake)
            fake.close_tab(next(tab for kind, tab in sweep.builder.made[pane] if kind == "webkit"))
            sweep.rebuild({"tabs": 1})
        with self.assertRaises(sweep_mod.SessionShapeError):
            self.run_patched(self.patched(fake, wrong), body)

    def test_a_reopened_pane_keeps_the_kind_the_builder_made_each_tab(self):
        fake = FakeApp()

        def body():
            sweep, pane = self.webkit_pane(fake)
            asked = sorted(kind for kind, _ in sweep.builder.made[pane])
            row = sweep.run_action({"id": "closePane", "title": "Close Pane"})
            return sweep, pane, asked, row
        sweep, pane, asked, row = self.run_patched(self.patched(fake, STRESS_OK), body)
        self.assertEqual(row["check"], "ok", row)
        new = fake.topology()["workspaces"][0]["screens"][0]["panes"][0]
        self.assertNotEqual(new["id"], pane)
        self.assertNotIn(pane, sweep.builder.made)
        made = sweep.builder.made[new["id"]]
        self.assertEqual(sorted(kind for kind, _ in made), asked)
        ids = {t["id"] for t in new["tabs"]}
        self.assertTrue(all(tab in ids for _, tab in made), made)
        # Each page entry points at the reopened tab of its own engine.
        for kind, tab in made:
            if kind in ("webkit", "chromium"):
                self.assertEqual(fake.engines.get(tab), kind)

    def test_a_stress_rebuild_replaces_the_damaged_measured_workspace(self):
        fake, base = self.stress_app()
        sweep = sweep_mod.Sweep(NoProcess(), "stress", stress_mod)
        before = len(fake.workspaces)

        def body():
            sweep.builder = stress_mod.Stress(fake.rpc, log=lambda line: None)
            sweep.snapshot_base(base["id"])
            sweep.rebuild({"panes": 1})
        self.run_patched(self.patched(fake, STRESS_OK), body)
        self.assertNotIn(base["id"], [w["id"] for w in fake.workspaces])
        self.assertEqual(len(fake.workspaces), before)
        self.assertEqual(sweep.base["workspace"], fake.workspaces[-1]["id"])

    def test_a_row_whose_restore_rebuilt_another_shape_fails_the_session(self):
        # A row's restore() rebuilt the measured workspace into another layout: the session fails there. It is not
        # a harness row of that action followed by a relaunch and more rows under `stress`.
        relaunches = []

        class App:
            process = None

            def relaunch(self):
                relaunches.append(1)

        sweep = sweep_mod.Sweep(App(), "stress", stress_mod)

        def run_action(action):
            raise sweep_mod.SessionShapeError("STRESS session has the wrong shape: 11 panes, not 14")

        def rpc(method, params=None, timeout=60):
            return {"pong": True} if method == "system.ping" else {}

        with mock.patch.object(sweep, "build", lambda: None), mock.patch.object(sweep, "check_validity", lambda: {}), \
                mock.patch.object(sweep, "frames_during", lambda body, settle=0.4: {"frames": {}}), \
                mock.patch.object(sweep, "run_action", run_action), mock.patch.object(sweep_mod, "rpc", rpc), \
                mock.patch.object(sweep_mod.opts, "no_interactions", True):
            with self.assertRaises(sweep_mod.SessionShapeError):
                sweep.run([{"id": "closePane"}, {"id": "splitRight"}])
        self.assertEqual(relaunches, [])
        self.assertEqual(sweep.rows, [])

    def focus_timeout_session(self, session):
        """A `session` sweep over [a tab close, a no-op] whose restore of the first row times out on focus
        (perf-stress-session's focus_pane raises StressShapeError for that); returns the sweep and its relaunches."""
        fake = FakeApp()
        measured = fake.pane(0, ["terminal", "browser", "terminal"])
        base = fake.workspace([measured, fake.pane(1, ["terminal"])])
        fake.focus_on(base, measured)
        fake.doomed_tab = measured["tabs"][0]["id"]
        relaunches = []

        class App:
            process = None

            def relaunch(self):
                relaunches.append(1)

        sweep = sweep_mod.Sweep(App(), session, stress_mod)

        def build():
            sweep.builder = stress_mod.Stress(fake.rpc, log=lambda line: None)
            sweep.snapshot_base(base["id"])

        def focus_pane(builder, pane_id):
            raise stress_mod.StressShapeError(f"focus never reached pane {pane_id}")

        with mock.patch.object(sweep_mod, "rpc", fake.rpc), mock.patch.object(sweep, "build", build), \
                mock.patch.object(sweep, "check_validity", lambda: {}), \
                mock.patch.object(sweep, "frames_during", lambda body, settle=0.4: {"frames": {}}), \
                mock.patch.object(stress_mod.Stress, "focus_pane", focus_pane), \
                mock.patch.object(sweep_mod.opts, "no_interactions", True):
            sweep.run([{"id": "test.closeDoomedTab", "title": "Close one tab"}, {"id": "test.noop", "title": "Nothing"}])
        return sweep, relaunches

    def test_a_focus_timeout_in_a_light_restore_is_a_harness_row_and_the_session_goes_on(self):
        sweep, relaunches = self.focus_timeout_session("light")
        self.assertEqual([r["id"] for r in sweep.rows], ["test.closeDoomedTab", "test.noop"])
        self.assertTrue(sweep.rows[0]["errors"][0].startswith("harness:"), sweep.rows[0])
        self.assertIn("focus never reached pane", sweep.rows[0]["errors"][0])
        self.assertEqual(relaunches, [1])

    def test_a_focus_timeout_in_a_stress_restore_is_a_harness_row_and_the_session_goes_on(self):
        sweep, relaunches = self.focus_timeout_session("stress")
        self.assertEqual([r["id"] for r in sweep.rows], ["test.closeDoomedTab", "test.noop"])
        self.assertIn("focus never reached pane", sweep.rows[0]["errors"][0])
        self.assertEqual(relaunches, [1])

    def test_an_interaction_whose_restore_times_out_on_focus_keeps_the_error_and_goes_on(self):
        sweep = sweep_mod.Sweep(NoProcess(), "stress", stress_mod)

        def restore(action_id, toggled):
            raise stress_mod.StressShapeError("focus never reached pane pane_7")
        with mock.patch.object(sweep_mod, "rpc", lambda method, params=None, timeout=60: {"entries": []}), \
                mock.patch.object(sweep, "restore", restore):
            sweep.interaction("click.pane", lambda: {"commit_ms": 4.0})
        self.assertIn("focus never reached pane", sweep.interactions[0]["restore_error"])

    def test_an_interaction_whose_restore_rebuilt_another_shape_fails_the_session(self):
        sweep = sweep_mod.Sweep(NoProcess(), "stress", stress_mod)

        def restore(action_id, toggled):
            raise sweep_mod.SessionShapeError("STRESS session has the wrong shape: 11 panes, not 14")
        with mock.patch.object(sweep_mod, "rpc", lambda method, params=None, timeout=60: {"entries": []}), \
                mock.patch.object(sweep, "restore", restore):
            with self.assertRaises(sweep_mod.SessionShapeError):
                sweep.interaction("click.pane", lambda: {"commit_ms": 4.0})


if __name__ == "__main__":
    try:
        unittest.main()
    finally:
        shutil.rmtree(OUT, ignore_errors=True)
        shutil.rmtree(sweep_mod.SCRATCH, ignore_errors=True)
