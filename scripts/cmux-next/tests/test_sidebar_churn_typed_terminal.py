#!/usr/bin/env python3
"""sidebar-churn-typing.py's typed terminal in the STRESS session (no app). The app's snapshot.get names the tab a
pane shows in the pane's `selected_tab` (ControlTopology+JSON.swift: ControlPaneInfo.json); a terminal, browser or
chat tab carries no `selected` key (ControlTabInfo.json; only a page tab does). The bench looked for a tab with
`selected` true, which no terminal has, so every STRESS run stopped before its first key (fleet job
52cb2a00728943743154aa7b, 2026-11-02: "the measured workspace's last pane ... shows no terminal").
The fake pane below has the real shape: `selected_tab` on the pane, no `selected` on its tabs.
Run: python3 -I scripts/cmux-next/tests/test_sidebar_churn_typed_terminal.py"""
import importlib.util, io, os, sys, tempfile, unittest
from contextlib import redirect_stdout

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = tempfile.mkdtemp(prefix="churn-test-")
_argv = sys.argv
sys.argv = ["sidebar-churn-typing.py", "--app", "/nonexistent/cmux.app", "--tag", "unit", "--out", OUT]
try:
    spec = importlib.util.spec_from_file_location("sidebar_churn_typing", os.path.join(HERE, "..", "sidebar-churn-typing.py"))
    churn = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(churn)  # main() runs only as a script
finally:
    sys.argv = _argv


def tab(tab_id, kind):
    """A tab as snapshot.get lists it: no `selected` key (ControlTabInfo.json)."""
    return {"id": tab_id, "kind": kind, "title": tab_id}


class FakeBuilder:
    """perf-stress-session's StressBuilder calls the bench can make: `action` (tab.focus makes the tab the pane's
    `selected_tab` when `honors` and the run asks for focus, as ActionInvocation.allowsViewChange), `workspace`,
    `panes` and `tabs` (the pane as snapshot.get lists it now)."""

    def __init__(self, pane, honors=True):
        self.pane, self.honors, self.actions = pane, honors, []

    def action(self, name, args=None, target=None, focus=True, **_):
        self.actions.append((name, target, focus))
        if name == "tab.focus" and self.honors and focus:  # a script run changes the selection only with focus
            self.pane["selected_tab"] = target.split(":", 1)[1]
        return {"ok": True}

    def workspace(self, workspace_id):
        return {"id": workspace_id, "screens": [{"panes": [dict(self.pane, tabs=list(self.pane["tabs"]))]}]}

    @staticmethod
    def panes(workspace):
        return [p for s in (workspace or {}).get("screens") or [] for p in s.get("panes") or [] if not p.get("dock")]

    def tabs(self, workspace_id, pane_id):
        pane = next((p for p in self.panes(self.workspace(workspace_id)) if p.get("id") == pane_id), None)
        return (pane or {}).get("tabs") or []


def pane(selected, *tabs):
    return {"id": "p", "selected_tab": selected, "tabs": list(tabs)}


class TypedTerminalTests(unittest.TestCase):
    def setUp(self):
        churn.wait = lambda predicate, seconds, step=0.25: predicate()  # one look: the fake app answers at once

    def test_the_terminal_the_pane_shows_is_typed_into_without_any_action(self):
        shown = pane("t2", tab("t1", "terminal"), tab("c1", "conversation"), tab("t2", "terminal"))
        builder = FakeBuilder(shown)
        self.assertEqual(churn.typed_terminal(builder, "ws", builder.panes(builder.workspace("ws"))[-1])["id"], "t2")
        self.assertEqual(builder.actions, [])

    def test_a_pane_that_shows_another_tab_gets_its_last_terminal_selected(self):
        shown = pane("c1", tab("t1", "terminal"), tab("b1", "browser"), tab("c1", "conversation"), tab("t2", "terminal"))
        builder = FakeBuilder(shown)
        with redirect_stdout(io.StringIO()):
            terminal = churn.typed_terminal(builder, "ws", builder.panes(builder.workspace("ws"))[-1])
        self.assertEqual(terminal["id"], "t2")
        self.assertEqual(builder.actions, [("tab.focus", "tab:t2", True)])
        self.assertIn("selecting terminal t2", churn.results["log"][-1])

    def test_a_pane_with_no_terminal_still_stops_the_bench(self):
        shown = pane("c1", tab("c1", "conversation"), tab("b1", "browser"))
        builder = FakeBuilder(shown)
        with self.assertRaises(SystemExit) as stop:
            churn.typed_terminal(builder, "ws", builder.panes(builder.workspace("ws"))[-1])
        self.assertIn("has no terminal", str(stop.exception))

    def test_a_terminal_the_app_does_not_show_still_stops_the_bench(self):
        shown = pane("c1", tab("t1", "terminal"), tab("c1", "conversation"))
        builder = FakeBuilder(shown, honors=False)
        with redirect_stdout(io.StringIO()), self.assertRaises(SystemExit) as stop:
            churn.typed_terminal(builder, "ws", builder.panes(builder.workspace("ws"))[-1])
        self.assertIn("does not show terminal t1", str(stop.exception))


if __name__ == "__main__":
    unittest.main()
