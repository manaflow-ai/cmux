#!/usr/bin/env python3
"""anim-perf-terminal.py's tab cases make tabs in workspace A's pane, so the timed moves have a neighbor.

Run: python3 -I scripts/cmux-next/tests/test_anim_perf_tab_actions.py
No app is needed: the bench's own setup and tab cases (make_a, at_a, anims) run against a small
model of the app's action semantics. The catalog's `newTab` is New Workspace (Cmd-N,
WorkspaceActionCatalog); Cmd-T's New Tab is `newTab.default` and New Terminal Tab is `newSurface`.
With `newTab` every "new tab" was a new one-pane, one-tab workspace, so Move Tab Left and Right were
both "the tab is already at the edge" and the pane moves had no pane beside them (4 FAILs on every
host since 2026-11-03 at least: aws-m4pro-8 step 32dae793, cmux12s step 9cfead9f).
"""
import ast
import itertools
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
BENCH = ROOT / "anim-perf-terminal.py"
NAMES = {"action", "error_of", "topology", "shown_workspace", "workspace_ids", "panes_of", "make_a", "at_a", "go",
         "TAB", "OPPOSITE", "either", "undo", "anims"}


def definitions(path, names):
    """Load selected definitions without executing the bench's app launch."""
    tree = ast.parse(path.read_text(), filename=str(path))
    nodes = [node for node in tree.body
             if (isinstance(node, ast.FunctionDef) and node.name in names)
             or (isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id in names for t in node.targets))]
    return compile(ast.Module(body=nodes, type_ignores=[]), str(path), "exec")


class App:
    """The actions the tab cases use, as the app runs them: a workspace of screens of panes of tabs."""

    WORKSPACE_ACTIONS = {"newTab", "workspace.newAtBottom", "workspace.newBelow", "workspace.newInNewGroup"}
    TAB_ACTIONS = {"newTab.default", "newSurface", "newTab.page"}

    def __init__(self):
        self.ids = itertools.count(1)
        self.workspaces = {}  # id -> [pane, ...] in left-to-right order; a pane is {"id", "tabs", "selected"}
        self.focus = None  # (workspace, pane index)
        self.calls = []

    def new_id(self, kind):
        return f"{kind}-{next(self.ids)}"

    def new_workspace(self):
        workspace, tab = self.new_id("ws"), self.new_id("tab")
        self.workspaces[workspace] = [{"id": self.new_id("pane"), "tabs": [tab], "selected": tab}]
        self.focus = (workspace, 0)

    def pane(self):
        workspace, index = self.focus
        return self.workspaces[workspace][index]

    def refuse(self, name, reason):
        return {"error": {"code": "unavailable", "data": {"action": name, "not_run": True, "reason": reason}}}

    def run(self, name, args):
        self.calls.append(name)
        if name in self.WORKSPACE_ACTIONS:
            self.new_workspace()
        elif name in self.TAB_ACTIONS:
            pane, tab = self.pane(), self.new_id("tab")
            pane["tabs"].insert(pane["tabs"].index(pane["selected"]) + 1, tab)
            pane["selected"] = tab
        elif name == "closeTab":
            pane = self.pane()
            index = pane["tabs"].index(pane["selected"])
            pane["tabs"].pop(index)
            if not pane["tabs"]:
                return self.run("closePane", {})
            pane["selected"] = pane["tabs"][max(0, index - 1)]
        elif name in ("moveSurfaceLeft", "moveSurfaceRight"):
            pane = self.pane()
            index = pane["tabs"].index(pane["selected"])
            target = index + (1 if name == "moveSurfaceRight" else -1)
            if not 0 <= target < len(pane["tabs"]):
                return self.refuse(name, "the tab is already at the edge")
            pane["tabs"].insert(target, pane["tabs"].pop(index))
        elif name in ("moveSurfaceToPaneLeft", "moveSurfaceToPaneRight"):
            workspace, index = self.focus
            target = index + (1 if name == "moveSurfaceToPaneRight" else -1)
            panes = self.workspaces[workspace]
            if not 0 <= target < len(panes):
                return self.refuse(name, f"no pane {'right' if name.endswith('Right') else 'left'} of the tab")
            source = panes[index]
            tab = source["selected"]
            source["tabs"].remove(tab)
            panes[target]["tabs"].append(tab)
            panes[target]["selected"] = tab
            destination = panes[target]
            if source["tabs"]:
                source["selected"] = source["tabs"][-1]
            else:
                panes.remove(source)
            self.focus = (workspace, panes.index(destination))  # the moved tab keeps the focus
        elif name == "splitRight":
            workspace, index = self.focus
            tab = self.new_id("tab")
            self.workspaces[workspace].insert(index + 1, {"id": self.new_id("pane"), "tabs": [tab], "selected": tab})
            self.focus = (workspace, index + 1)
        elif name in ("focusLeft", "focusRight"):
            workspace, index = self.focus
            step = 1 if name == "focusRight" else -1
            self.focus = (workspace, min(max(index + step, 0), len(self.workspaces[workspace]) - 1))
        elif name == "closePane":
            workspace, index = self.focus
            panes = self.workspaces[workspace]
            panes.pop(index)
            if not panes:
                del self.workspaces[workspace]
                self.focus = (next(iter(self.workspaces)), 0)
            else:
                self.focus = (workspace, max(0, index - 1))
        elif name == "goToWorkspace":
            self.focus = (args["workspace"], 0)
        elif name != "terminal.sendText":
            raise AssertionError(f"the model has no action {name}")
        return {"ok": True}

    def rpc(self, method, params=None, timeout=30):
        if method == "action.run":
            return self.run(params["action"], params.get("args") or {})
        if method == "snapshot.get":
            return {"topology": {
                "focus": {"workspace": self.focus[0] if self.focus else None},
                "workspaces": [{"id": w, "screens": [{"panes": [{"id": p["id"], "tabs": [{"id": t} for t in p["tabs"]]}
                                                                  for p in panes]}]}
                               for w, panes in self.workspaces.items()]}}
        raise AssertionError(f"the model has no method {method}")


class Clock:
    @staticmethod
    def sleep(_seconds):
        pass

    @staticmethod
    def time():
        return 0.0


def bench():
    app = App()
    app.new_workspace()  # the launch's own workspace
    scope = {"rpc": app.rpc, "state": {}, "time": Clock}
    exec(definitions(BENCH, NAMES), scope)
    return app, scope


class TabCases(unittest.TestCase):
    def run_cases(self, names):
        app, scope = bench()
        scope["make_a"]()
        scope["state"]["a"] = scope["shown_workspace"]()
        cases = {name: (prepare, perform) for name, prepare, perform in scope["anims"]()}
        errors = {}
        for _round in range(3):
            for name in names:
                prepare, perform = cases[name]
                if prepare:
                    prepare()
                errors.setdefault(name, []).append(perform())
        return app, scope, errors

    def test_workspace_a_is_one_pane_with_three_tabs(self):
        app, scope = bench()
        scope["make_a"]()
        a = scope["shown_workspace"]()
        self.assertEqual([count for _pane, count in scope["panes_of"](a)], [3])
        self.assertEqual(len(app.workspaces), 2, "make_a makes one workspace (A), next to the launch's own")

    def test_tab_moves_run_in_workspace_a(self):
        app, scope, errors = self.run_cases(["tab-new", "tab-close", "tab-move", "tab-move-back", "tab-to-pane", "tab-back"])
        self.assertEqual(errors, {name: [None] * 3 for name in errors})
        self.assertEqual(scope["shown_workspace"](), scope["state"]["a"], "the tab cases stay in workspace A")
        self.assertEqual(len(app.workspaces), 2, "no tab case makes a workspace")

    def test_tab_new_is_cmd_t(self):
        _app, scope = bench()
        names = {}
        scope["action"] = lambda name, args=None, settle=0.0, timeout=60: names.setdefault("verb", name) and {"ok": True}
        dict((n, f) for n, _p, f in scope["anims"]())["tab-new"]()
        self.assertEqual(names["verb"], "newTab.default")


if __name__ == "__main__":
    unittest.main()
