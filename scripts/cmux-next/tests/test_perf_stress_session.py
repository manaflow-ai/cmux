#!/usr/bin/env python3
"""perf-stress-session.py against a fake app socket (no app): the builder's background Chromium load and
its focus handling. Run: python3 -I scripts/cmux-next/tests/test_perf_stress_session.py"""
import importlib.util, os, sys, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("perf_stress_session", os.path.join(HERE, "..", "perf-stress-session.py"))
stress = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stress)


class FakeApp:
    """Enough of the control socket for the background half: workspaces with one pane, tabs, focus.
    `takes_focus`: a new workspace takes the focus (False: a loaded mini where it does not, the
    fleet's 'No pane is focused.' refusals)."""

    def __init__(self, takes_focus=True):
        self.takes_focus = takes_focus
        self.workspaces = []
        self.focus = {"workspace": None, "pane": None}
        self.next = 0

    def ident(self, prefix):
        self.next += 1
        return f"{prefix}_{self.next}"

    def tab(self, kind):
        return {"id": self.ident("tab"), "kind": kind}

    def pane_by_id(self, pane_id):
        return next((p for w in self.workspaces for p in w["screens"][0]["panes"] if p["id"] == pane_id), None)

    def rpc(self, method, params=None, timeout=60):
        params = params or {}
        if method == "snapshot.get":
            return {"topology": {"workspaces": self.workspaces, "focus": dict(self.focus), "windows": []}}
        if method != "action.run":
            return {}
        action, target = params.get("action"), params.get("target") or ""
        if action == "workspace.newAtBottom":
            pane = {"id": self.ident("pane"), "tabs": [self.tab("terminal")]}
            workspace = {"id": self.ident("ws"), "screens": [{"panes": [pane]}]}
            self.workspaces.append(workspace)
            if self.takes_focus:
                self.focus = {"workspace": workspace["id"], "pane": pane["id"]}
            return {}
        if action == "pane.focus" and target.startswith("pane:"):
            pane_id = target[len("pane:"):]
            owner = next(w for w in self.workspaces for p in w["screens"][0]["panes"] if p["id"] == pane_id)
            self.focus = {"workspace": owner["id"], "pane": pane_id}
            return {}
        if action in ("openBrowser.chromium", "openBrowser.webkit", "newSurface"):
            pane = self.pane_by_id(target[len("pane:"):]) if target.startswith("pane:") else self.pane_by_id(self.focus["pane"])
            if pane is None:
                return {"error": {"code": "unavailable", "data": {"reason": "No pane is focused."}}}
            pane["tabs"].append(self.tab("terminal" if action == "newSurface" else "browser"))
            return {}
        return {}


def builder(app):
    stress.time.sleep = lambda seconds: None  # the fake answers at once
    return stress.Stress(app.rpc, log=lambda line: None, settle=0)


class BackgroundChromiumTests(unittest.TestCase):
    def test_each_background_workspace_gets_its_chromium_pages_when_focus_stays_elsewhere(self):
        app = FakeApp(takes_focus=False)
        made = builder(app).build_background(count=3, chromium=2)
        pages = [sum(1 for t in app.pane_by_id(w["screens"][0]["panes"][0]["id"])["tabs"] if t["kind"] == "browser")
                 for w in app.workspaces if w["id"] in made[:2]]
        self.assertEqual(pages, [stress.CHROMIUM_PER_WORKSPACE] * 2,
                         "background Chromium pages went to no pane (openBrowser.chromium followed the focus)")

    def test_the_summary_counts_real_background_pages(self):
        app = FakeApp(takes_focus=True)
        session = builder(app)
        session.build_background(count=2, chromium=2)
        app.workspaces[0]["screens"][0]["panes"][0]["tabs"] = app.workspaces[0]["screens"][0]["panes"][0]["tabs"][:1]
        summary = session.summary()
        self.assertEqual(summary["chromium_workspaces"], 1, "the summary counted workspaces made, not pages")
        self.assertEqual(summary["background_chromium"], [0, 2])


if __name__ == "__main__":
    unittest.main()
