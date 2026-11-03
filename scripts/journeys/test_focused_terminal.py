#!/usr/bin/env python3
"""`focused_terminal` adopts the daemon's terminal of the tab a key just created, resolved by the creation's
terminal key, never the stand-in's id and never a guess. No fleet, no app.

    python3 -I scripts/journeys/test_focused_terminal.py

A key that makes a terminal (Ctrl-`, Cmd-D, Home's Open a terminal) shows a stand-in tab in the key's turn
(`pending_tab_...`, ProvisionalTab) whose `terminal` is the terminal host id the app chose for the create (32 hex
digits, no `term_`). The daemon's tab takes the stand-in's place about 0.3 s later; it carries the same host id as
its `terminal_key` and the daemon's public id (`term_...`) as its `terminal`. The daemon resolves only the public
id. The view (debug.surfaces) names the host id as its `terminal_id`, so the creation is known by that key from the
first read. The step adopted the selected tab's `terminal` at its first read, so a read inside the stand-in's 0.3 s
adopted an id the daemon never knows and waited 20 s on it: close-then-type on build 14323feb (STATUS 9672,
2026-11-03), r3-new-tab-panel on v2.2.11-opt (2026-10-31, #29179 fixed it only in the kits).

The rule: adopt the tab of the focused pane whose `terminal_key` is the view's `terminal_id`, once that tab is the
daemon's (its id is not `pending_tab_...` and its `terminal` is a `term_` id). No screen read decides it, and no
other tab is taken in its place (not the old selected tab, not a stand-in, not a pane's selected tab on a topology
without `terminal_key`: that build cannot name the creation, and the step says so).
"""
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path[:0] = [str(HERE), str(HERE.parent / "cmux-next")]
import driver as D  # noqa: E402

PANE = "pane_ctrl"
HOST_ID = "aa35449555bb47fa833b7f98874bf048"  # the create's caller-chosen terminal host id (the stand-in's)
PUBLIC_ID = "term_a1a7ec6d99a75b33abe8c1a84737a72c"  # the daemon's public id of the same terminal
STANDIN = "pending_tab_e05df098-4241-484a-9ac6-3d6567e68f33"
DAEMON_TAB = "tab_afaf3d427ec4d32fe27c5e230125d48b"


class KeyMadeTerminalApp:
    """An app right after a key made a terminal: for `old_tab_reads` topology reads the pane still selects its old
    tab, then for `standin_reads` reads the stand-in is selected, then the daemon's tab replaces it. With
    `daemon_tab_without_public_id_reads`, the daemon's tab first carries the host id as its `terminal` (its public
    id not yet known). The daemon knows only public ids: a screen read of the host id is selector.not_found."""

    def __init__(self, standin_reads, old_tab_reads=0, keys=True, daemon_tab_without_public_id_reads=0):
        self.standin_reads, self.old_tab_reads, self.keys = standin_reads, old_tab_reads, keys
        self.no_public_reads = daemon_tab_without_public_id_reads
        self.reads, self.screen_reads = 0, []

    def panes(self):
        # The view keeps the stand-in's terminal id: the daemon's tab adopts the stand-in's view.
        return [{"pane": PANE, "focused": True, "kind": "terminal", "terminal_id": HOST_ID, "host_pid": 4242}]

    def rpc(self, method, params=None, timeout=None):
        assert method == "snapshot.get", method
        self.reads += 1
        first = {"id": "tab_first", "terminal": "term_first", "terminal_key": "first-key"}
        n = self.reads
        if n <= self.old_tab_reads:  # the pane still selects the old tab; the view is the new one's
            tab, selected = None, first
        elif n <= self.old_tab_reads + self.standin_reads:
            tab = {"id": STANDIN, "terminal": HOST_ID, "terminal_key": HOST_ID}
            selected = tab
        elif n <= self.old_tab_reads + self.standin_reads + self.no_public_reads:
            tab = {"id": DAEMON_TAB, "terminal": HOST_ID, "terminal_key": HOST_ID}
            selected = tab
        else:
            tab = {"id": DAEMON_TAB, "terminal": PUBLIC_ID, "terminal_key": HOST_ID}
            selected = tab
        if not self.keys:
            for each in (first, tab):
                if each:
                    each.pop("terminal_key", None)
        pane = {"id": PANE, "selected_tab": selected["id"], "tabs": [first] + ([tab] if tab else [])}
        return {"topology": {"workspaces": [{"name": "jr-tab", "screens": [{"panes": [pane]}]}]}}

    def screen(self, term):
        self.screen_reads.append(term)
        if term not in (PUBLIC_ID, "term_first"):
            raise D.StepError(f'cmux terminal {term} screen read: exit 1: {{"code":"selector.not_found",'
                              f'"details":{{"scope":"terminal","selector":"{term}"}}}}')
        return {"text": "J> "}


class FocusedTerminalTests(unittest.TestCase):
    def play(self, app, timeout=3):
        with tempfile.TemporaryDirectory() as out:
            journey = D.Journey({"id": "focused-terminal", "steps": []}, app, out, D.now() + 60, 1.0)
            journey.known_views = {"term_first-view"}
            result = journey.step_focused_terminal({"timeout": timeout})
            return journey, result

    def test_a_read_inside_the_standin_adopts_the_daemons_terminal(self):
        app = KeyMadeTerminalApp(standin_reads=1)
        journey, result = self.play(app)
        self.assertEqual(journey.term, PUBLIC_ID)
        self.assertEqual(result["terminal"], PUBLIC_ID)
        self.assertEqual(result["pane"], PANE)
        self.assertIn(HOST_ID, journey.known_views)

    def test_the_standin_id_is_never_read_as_a_terminal(self):
        app = KeyMadeTerminalApp(standin_reads=3)
        self.play(app)
        self.assertNotIn(HOST_ID, app.screen_reads)

    def test_a_read_while_the_pane_still_selects_the_old_tab_never_adopts_the_old_terminal(self):
        app = KeyMadeTerminalApp(standin_reads=0, old_tab_reads=2)
        journey, _ = self.play(app)
        self.assertEqual(journey.term, PUBLIC_ID)
        self.assertNotIn("term_first", app.screen_reads)

    def test_the_daemons_tab_before_its_public_id_is_waited_out(self):
        app = KeyMadeTerminalApp(standin_reads=1, daemon_tab_without_public_id_reads=2)
        journey, _ = self.play(app)
        self.assertEqual(journey.term, PUBLIC_ID)
        self.assertNotIn(HOST_ID, app.screen_reads)

    def test_no_standin_adopts_at_once(self):
        app = KeyMadeTerminalApp(standin_reads=0)
        journey, _ = self.play(app)
        self.assertEqual(journey.term, PUBLIC_ID)
        self.assertEqual(app.reads, 1)

    def test_a_topology_without_terminal_key_is_refused_by_name_not_guessed(self):
        app = KeyMadeTerminalApp(standin_reads=0, keys=False)
        with self.assertRaises(D.StepError) as caught:
            self.play(app, timeout=1)
        self.assertIn("terminal_key", str(caught.exception))
        self.assertNotIn("term_first", app.screen_reads)

    def test_a_creation_the_daemon_never_completes_fails_naming_the_standin(self):
        app = KeyMadeTerminalApp(standin_reads=10 ** 6)
        with self.assertRaises(D.StepError) as caught:
            self.play(app, timeout=1)
        self.assertIn(STANDIN, str(caught.exception))
        self.assertIn("stand-in", str(caught.exception))


class PaneRowResolutionTests(unittest.TestCase):
    """ext_window's adopt_pane reads the terminal of a pane row the same way (one shared resolver): a stand-in or a
    workspace's only other terminal is never taken for it."""

    def journey(self, app):
        out = tempfile.mkdtemp(prefix="focused-terminal-")
        return D.Journey({"id": "adopt-pane", "steps": []}, app, out, D.now() + 60, 1.0)

    def row(self):
        return {"pane": PANE, "focused": True, "kind": "terminal", "terminal_id": HOST_ID, "workspace": "ws"}

    def test_a_pane_row_inside_the_standin_has_no_terminal_yet(self):
        import ext_window
        app = KeyMadeTerminalApp(standin_reads=1)
        with self.assertRaises(D.StepError) as caught:
            ext_window.daemon_terminal_of(self.journey(app), self.row())
        self.assertIn("stand-in", str(caught.exception))

    def test_a_pane_row_after_the_daemons_tab_resolves_to_its_public_id(self):
        import ext_window
        app = KeyMadeTerminalApp(standin_reads=0)
        self.assertEqual(ext_window.daemon_terminal_of(self.journey(app), self.row()), PUBLIC_ID)

    def test_the_old_selected_tab_is_not_the_pane_rows_terminal(self):
        import ext_window
        app = KeyMadeTerminalApp(standin_reads=0, old_tab_reads=1)
        with self.assertRaises(D.StepError):
            ext_window.daemon_terminal_of(self.journey(app), self.row())


if __name__ == "__main__":
    unittest.main()
