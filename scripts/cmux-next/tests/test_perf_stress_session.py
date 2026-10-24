#!/usr/bin/env python3
"""perf-stress-session.py against a fake app socket (no app): the builder's background Chromium load, the
measured grid when focus does not follow a new workspace, and the shape check (even grid, Chromium
running, window on its screen, the virtual display really main).
Run: python3 -I scripts/cmux-next/tests/test_perf_stress_session.py"""
import importlib.util, os, sys, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("perf_stress_session", os.path.join(HERE, "..", "perf-stress-session.py"))
stress = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stress)

AREA = (1600.0, 1000.0)  # the fake layout area, window points
VISIBLE = [0, 0, 1920, 1050]  # the fake screen's visible frame


class FakeClock:
    """Stands in for the module's `time`: a sleep advances the clock, so a bounded wait that never
    succeeds ends at once instead of spinning for its real seconds."""

    def __init__(self):
        self.now = 0.0

    def monotonic(self):
        return self.now

    def sleep(self, seconds):
        self.now += max(seconds, 0.01)


class FakeApp:
    """Enough of the control socket for both halves, with the app's rules that matter here:

    * `takes_focus`: a new workspace takes the focus and shows (False: a loaded mini where it does
      not, the fleet's 'No pane is focused.' refusals).
    * A pane target resolves in any workspace (AppActionContext.daemonPane), but the actions that go
      through the pane's controller (newTab.page, palette.newAgentChat, equalizeSplits) are refused for
      a workspace no window shows, and a split there gets no even sizing (no content controller, so
      `splitSizingChanges` is skipped: the split halves only its own pane).
    * openBrowser.* on a hidden workspace's pane opens offscreen; `browsers` records whether the
      workspace was shown.

    Each workspace is columns side by side, each column rows stacked: {"width": f, "rows": [[pane, f]]}."""

    def __init__(self, takes_focus=True, cef=None, window_frame=None):
        self.takes_focus = takes_focus
        self.workspaces, self.layout = [], {}
        self.shown = None
        self.focus = {"workspace": None, "pane": None}
        self.next = 0
        self.log = []  # (action, workspace of its target, that workspace shown)
        self.browsers = []  # (pane, shown)
        self.cef = {"state": "ready", "unavailable": None, "fallback": None} if cef is None else cef
        self.window_frame = window_frame or [80, 40, 1600, 1000]

    def ident(self, prefix):
        self.next += 1
        return f"{prefix}_{self.next}"

    def tab(self, kind, **fields):
        return {"id": self.ident("tab"), "kind": kind, **fields}

    def panes_of(self, workspace):
        return workspace["screens"][0]["panes"]

    def pane_by_id(self, pane_id):
        return next((p for w in self.workspaces for p in self.panes_of(w) if p["id"] == pane_id), None)

    def owner(self, pane_id):
        return next((w for w in self.workspaces for p in self.panes_of(w) if p["id"] == pane_id), None)

    def add(self, pane, tab):
        for other in pane["tabs"]:
            other["selected"] = False
        tab["selected"] = True
        pane["tabs"].append(tab)

    def new_pane(self, workspace):
        pane = {"id": self.ident("pane"), "tabs": []}
        self.add(pane, self.tab("terminal"))
        self.panes_of(workspace).append(pane)
        return pane

    def split(self, workspace, pane_id, verb):
        columns = self.layout[workspace["id"]]
        index = next(i for i, c in enumerate(columns) if any(r[0] == pane_id for r in c["rows"]))
        column, pane = columns[index], self.new_pane(workspace)
        even = workspace["id"] == self.shown
        if verb == "splitRight":
            assert len(column["rows"]) == 1, "the builder splits columns right before it splits rows"
            column["width"] /= 2
            columns.insert(index + 1, {"width": column["width"], "rows": [[pane["id"], 1.0]]})
            if even:
                for c in columns:
                    c["width"] = 1 / len(columns)
        else:
            row = next(i for i, r in enumerate(column["rows"]) if r[0] == pane_id)
            column["rows"][row][1] /= 2
            column["rows"].insert(row + 1, [pane["id"], column["rows"][row][1]])
            if even:
                for r in column["rows"]:
                    r[1] = 1 / len(column["rows"])

    def equalize(self, workspace):
        for column in self.layout[workspace["id"]]:
            column["width"] = 1 / len(self.layout[workspace["id"]])
            for r in column["rows"]:
                r[1] = 1 / len(column["rows"])

    def layers(self):
        columns = self.layout.get(self.shown) or []
        rings, dividers, x = [], [], 0.0
        for index, column in enumerate(columns):
            width = column["width"] * AREA[0]
            if index:
                dividers.append([x - 2, 0, 4, AREA[1]])
            y = 0.0
            for pane, share in column["rows"]:
                rings.append({"pane": pane, "frame_in_window": [x, y, width, share * AREA[1]]})
                y += share * AREA[1]
            x += width
        return {"windows": [{"id": "win_1", "frame": list(self.window_frame), "screen_visible_frame": VISIBLE,
                             "divider_areas_in_window": dividers, "planes": [{"rings": rings}], "browsers": []}]}

    def rpc(self, method, params=None, timeout=60):
        params = params or {}
        if method == "snapshot.get":
            return {"topology": {"workspaces": self.workspaces, "focus": dict(self.focus),
                                 "windows": [{"key": "win_1", "workspace": self.shown}]}}
        if method == "debug.layers":
            return self.layers()
        if method == "debug.cef":
            return dict(self.cef)
        if method == "debug.window_frame":
            return {"frame": list(self.window_frame), "screen": "fake", "visible_frame": VISIBLE}
        if method != "action.run":
            return {}
        action, target = params.get("action"), params.get("target") or ""
        pane = self.pane_by_id(target[len("pane:"):]) if target.startswith("pane:") else self.pane_by_id(self.focus["pane"])
        workspace = self.owner(pane["id"]) if pane else None
        self.log.append((action, workspace and workspace["id"], bool(workspace) and workspace["id"] == self.shown))
        if action == "workspace.newAtBottom":
            workspace = {"id": self.ident("ws"), "screens": [{"panes": []}]}
            self.workspaces.append(workspace)
            first = self.new_pane(workspace)
            self.layout[workspace["id"]] = [{"width": 1.0, "rows": [[first["id"], 1.0]]}]
            if self.takes_focus:
                self.shown = workspace["id"]
                self.focus = {"workspace": workspace["id"], "pane": first["id"]}
            return {}
        if action == "goToWorkspace":
            self.shown = params["args"]["workspace"]
            self.focus = {"workspace": self.shown, "pane": None}  # shown, but no pane takes focus
            return {}
        if pane is None:
            return {"error": {"code": "unavailable", "data": {"reason": "No pane is focused."}}}
        hidden = workspace["id"] != self.shown
        if action in ("newTab.page", "palette.newAgentChat", "equalizeSplits") and hidden:
            return {"error": {"code": "not_found", "data": {"reason": f"{target} is not shown in any window."}}}
        if action == "pane.focus":
            self.focus = {"workspace": workspace["id"], "pane": pane["id"]}
        elif action in ("splitRight", "splitDown"):
            self.split(workspace, pane["id"], action)
        elif action == "equalizeSplits":
            self.equalize(workspace)
        elif action == "newSurface":
            self.add(pane, self.tab("terminal"))
        elif action in ("openBrowser.chromium", "openBrowser.webkit"):
            self.browsers.append((pane["id"], not hidden))
            self.add(pane, self.tab("browser"))
        elif action == "palette.newAgentChat":
            self.add(pane, self.tab("conversation"))
        elif action == "newTab.page":
            self.add(pane, self.tab("page", page="new-tab"))
        return {}


def builder(app, **options):
    stress.time = FakeClock()  # the fake answers at once; a wait that never succeeds ends at once too
    # No web-dev.json: the developer's own file on this Mac must not decide the test.
    return stress.Stress(app.rpc, log=lambda line: None, settle=0, web_dev_config=os.path.join(HERE, "no-such-web-dev.json"), **options)


class BackgroundChromiumTests(unittest.TestCase):
    def test_each_background_workspace_gets_its_chromium_pages_when_focus_stays_elsewhere(self):
        app = FakeApp(takes_focus=False)
        made = builder(app).build_background(count=3, chromium=2)
        pages = [sum(1 for t in app.pane_by_id(w["screens"][0]["panes"][0]["id"])["tabs"] if t["kind"] == "browser")
                 for w in app.workspaces if w["id"] in made[:2]]
        self.assertEqual(pages, [stress.CHROMIUM_PER_WORKSPACE] * 2,
                         "background Chromium pages went to no pane (openBrowser.chromium followed the focus)")
        self.assertEqual(len(app.browsers), 2 * stress.CHROMIUM_PER_WORKSPACE)
        self.assertTrue(all(shown for _, shown in app.browsers),
                        "a background page opened offscreen (its workspace was not shown), not live in its pane")

    def test_the_summary_counts_real_background_pages(self):
        app = FakeApp(takes_focus=True)
        session = builder(app)
        session.build_background(count=2, chromium=2)
        app.workspaces[0]["screens"][0]["panes"][0]["tabs"] = app.workspaces[0]["screens"][0]["panes"][0]["tabs"][:1]
        summary = session.summary()
        self.assertEqual(summary["chromium_workspaces"], 1, "the summary counted workspaces made, not pages")
        self.assertEqual(summary["background_chromium"], [0, 2])


class MeasuredGridTests(unittest.TestCase):
    def build(self, takes_focus):
        app = FakeApp(takes_focus=takes_focus)
        session = builder(app)
        measured = session.build_measured()
        return app, session, measured, session.summary()

    def test_the_measured_workspace_shows_before_its_first_split_when_focus_stays_elsewhere(self):
        app, session, measured, summary = self.build(takes_focus=False)
        shown = [i for i, (action, _, _) in enumerate(app.log) if action == "goToWorkspace"]
        first_split = next(i for i, (action, _, _) in enumerate(app.log) if action.startswith("split"))
        self.assertTrue(shown and shown[0] < first_split, "the grid was split before its workspace showed")
        self.assertTrue(all(on for action, workspace, on in app.log if workspace == measured),
                        "an action ran on the measured workspace while it was hidden")
        self.assertEqual(summary["layout_refusals"], [], "equalizeSplits or a split was refused")
        self.assertEqual(summary["grid_problems"], [], "the grid is not even")
        self.assertEqual(summary["pane_problems"], [], "a pane lacks its 6 tabs of the kinds asked")
        self.assertEqual(summary["shown_columns"], stress.COLUMNS)
        self.assertEqual(summary["chat_fallbacks"], 0, "a chat fell back because its workspace was hidden")

    def test_a_grid_built_when_focus_follows_is_the_same(self):
        _, _, _, summary = self.build(takes_focus=True)
        self.assertEqual((summary["layout_refusals"], summary["grid_problems"], summary["pane_problems"]), ([], [], []))


class ShapeCheckTests(unittest.TestCase):
    def test_uneven_rows_are_a_wrong_shape(self):
        # A grid split while hidden: rows 1/2, 1/4, 1/4 (and 1/2, 1/4, 1/8, 1/8 in the nested columns).
        def column(x, shares):
            y, rings = 0.0, []
            for index, share in enumerate(shares):
                rings.append({"pane": f"p{x}-{index}", "frame_in_window": [x, y, 400, share * 1000]})
                y += share * 1000
            return rings
        rings = (column(0, [.5, .25, .25]) + column(400, [.5, .25, .125, .125]) + column(800, [.5, .25, .25])
                 + column(1200, [.5, .25, .125, .125]))
        problems = stress.grid_problems({"planes": [{"rings": rings}]})
        self.assertEqual(len(problems), 4, problems)
        even = (column(0, [1 / 3] * 3) + column(400, [.25] * 4) + column(800, [1 / 3] * 3) + column(1200, [.25] * 4))
        self.assertEqual(stress.grid_problems({"planes": [{"rings": even}]}), [])

    def test_webkit_fallbacks_and_a_chromium_that_is_not_ready_are_not_stress(self):
        for cef, word in (({"state": "ready", "fallback": {"count": 3, "reason": None, "source": "tab"}}, "fallback"),
                          ({"state": "loading", "fallback": None}, "loading"),
                          ({"state": "failed", "unavailable": {"code": "startFailed"}}, "startFailed")):
            app = FakeApp(cef=cef)
            session = builder(app)
            session.build_measured()
            summary = session.summary()
            self.assertTrue(any(word in problem for problem in summary["chromium_unavailable"]), (cef, summary["chromium_unavailable"]))
        app = FakeApp()
        session = builder(app)
        session.build_measured()
        self.assertEqual(session.summary()["chromium_unavailable"], [])

    def test_a_tab_of_another_kind_than_asked_is_a_pane_problem(self):
        app = FakeApp()
        session = builder(app)
        session.build_measured()
        pane = session.panes(session.workspace(session.measured))[0]
        chat = next(tab for kind, tab, _ in session.made[pane["id"]] if kind == "chat")
        next(t for t in pane["tabs"] if t["id"] == chat)["kind"] = "browser"
        self.assertTrue(any("chat tab" in problem for problem in session.summary()["pane_problems"]))

    def test_a_window_past_its_screen_or_resized_after_the_build_is_not_stress(self):
        self.assertIsNone(stress.window_problem({"frame": [80, 40, 1600, 1000], "visible_frame": VISIBLE}))
        self.assertIn("past", stress.window_problem({"frame": [800, 40, 1600, 1000], "visible_frame": VISIBLE}))
        self.assertIn("not", stress.window_problem({"frame": [80, 40, 1600, 675], "visible_frame": VISIBLE}))
        self.assertIn("visible frame", stress.window_problem({"frame": [80, 40, 1600, 1000]}))
        app = FakeApp()
        session = builder(app)
        session.build_measured()
        self.assertIsNone(session.summary()["window_problem"])
        app.window_frame = [80, 40, 1600, 675]  # the screen made the window smaller after size_window
        summary = session.summary()
        self.assertIn("not [1600, 1000]", summary["window_problem"] or "")
        with self.assertRaisesRegex(stress.StressShapeError, "not \\[1600, 1000\\]"):
            session.check(summary)

    def test_the_virtual_display_must_be_main(self):
        self.assertIsNone(stress.vdisplay_problem("ready 7 8.33 main=7\n"))
        self.assertIn("main display is 1", stress.vdisplay_problem("ready 7 8.33 main=1\n"))
        self.assertIsNotNone(stress.vdisplay_problem("error: CGVirtualDisplay unavailable\n"))
        self.assertIsNotNone(stress.vdisplay_problem(None))


if __name__ == "__main__":
    unittest.main()
