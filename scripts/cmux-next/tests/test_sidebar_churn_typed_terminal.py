#!/usr/bin/env python3
"""sidebar-churn-typing.py's typed terminal in the STRESS session (no app): the measured workspace's last pane can
show its agent chat, which opens late and takes the selection after the pane's terminal was added (fleet job
52cb2a00728943743154aa7b, 2026-11-02: "the measured workspace's last pane ... shows no terminal", the bench ended
before it typed). The bench then selects the pane's last terminal and types into it; it still stops when the pane
has no terminal, or does not show the terminal it selected.
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


def tab(tab_id, kind, selected=False):
    return {"id": tab_id, "kind": kind, "selected": selected}


class FakeBuilder:
    """The two Stress calls typed_terminal makes: `action` (tab.focus selects the tab when `honors` is true) and
    `tabs` (the pane's tabs as the app lists them now)."""

    def __init__(self, tabs, honors=True):
        self._tabs, self.honors, self.actions = tabs, honors, []

    def action(self, name, args=None, target=None, focus=True, **_):
        self.actions.append((name, target, focus))
        if name == "tab.focus" and self.honors:
            wanted = target.split(":", 1)[1]
            for t in self._tabs:
                t["selected"] = t["id"] == wanted
        return {"ok": True}

    def tabs(self, workspace_id, pane_id):
        return [dict(t) for t in self._tabs]


class TypedTerminalTests(unittest.TestCase):
    def setUp(self):
        churn.wait = lambda predicate, seconds, step=0.25: predicate()  # one look: the fake app answers at once

    def test_a_selected_terminal_is_typed_into_without_any_action(self):
        tabs = [tab("t1", "terminal"), tab("c1", "conversation"), tab("t2", "terminal", selected=True)]
        builder = FakeBuilder(tabs)
        self.assertEqual(churn.typed_terminal(builder, "ws", {"id": "p", "tabs": tabs})["id"], "t2")
        self.assertEqual(builder.actions, [])

    def test_a_late_chat_that_took_the_selection_gives_way_to_the_last_terminal(self):
        tabs = [tab("t1", "terminal"), tab("b1", "browser"), tab("c1", "conversation", selected=True), tab("t2", "terminal")]
        builder = FakeBuilder(tabs)
        with redirect_stdout(io.StringIO()):
            terminal = churn.typed_terminal(builder, "ws", {"id": "p", "tabs": [dict(t) for t in tabs]})
        self.assertEqual(terminal["id"], "t2")
        self.assertEqual(builder.actions, [("tab.focus", "tab:t2", False)])
        self.assertIn("selecting terminal t2", churn.results["log"][-1])

    def test_a_pane_with_no_terminal_still_stops_the_bench(self):
        tabs = [tab("c1", "conversation", selected=True), tab("b1", "browser")]
        with self.assertRaises(SystemExit) as stop:
            churn.typed_terminal(FakeBuilder(tabs), "ws", {"id": "p", "tabs": tabs})
        self.assertIn("has no terminal", str(stop.exception))

    def test_a_terminal_the_app_does_not_show_still_stops_the_bench(self):
        tabs = [tab("t1", "terminal"), tab("c1", "conversation", selected=True)]
        with redirect_stdout(io.StringIO()), self.assertRaises(SystemExit) as stop:
            churn.typed_terminal(FakeBuilder(tabs, honors=False), "ws", {"id": "p", "tabs": [dict(t) for t in tabs]})
        self.assertIn("does not show terminal t1", str(stop.exception))


if __name__ == "__main__":
    unittest.main()
