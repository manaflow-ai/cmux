#!/usr/bin/env python3
"""`focused_terminal` adopts the daemon's terminal of a Ctrl-` tab, never its stand-in's id. No fleet, no app.

    python3 scripts/journeys/test_focused_terminal.py

Ctrl-` shows a stand-in tab in the key's turn (`pending_tab_...`, ProvisionalTab) under the terminal host id the
app chose for the create (32 hex digits, no `term_`). The control topology lists that id as the tab's `terminal`
until the daemon's tab takes the stand-in's place, about 0.3 s later, with its public id (`term_...`). The daemon
resolves only that public id: `cmux terminal <host id> screen read` is selector.not_found for good. The step
adopted whatever the topology showed at its first read, so a read inside the stand-in's 0.3 s adopted an id the
daemon never knows and waited 20 s on it (r3-new-tab-panel on v2.2.11-opt, 2026-10-31: 3 of 3 rounds with
paneHoldsContentInMotion off on cmux23, reported as "the daemon never knows the Ctrl-` terminal"). A probe
of the same build (ctrlbt-new-tab-daemon) saw the daemon's tab replace the stand-in after 0.26-0.30 s with the
switch on and off, and the typed line reached that terminal each time.
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


class CtrlBacktickApp:
    """An app right after Ctrl-`: the stand-in is the pane's selected tab for `standin_reads` topology reads,
    then the daemon's tab replaces it. The daemon knows only the public id."""

    def __init__(self, standin_reads):
        self.standin_reads, self.reads = standin_reads, 0
        self.screen_reads = []

    def panes(self):
        # The view keeps the stand-in's id: the daemon's tab adopts the stand-in's view (TabContentCache.adoptStandIn).
        return [{"pane": PANE, "focused": True, "kind": "terminal", "terminal_id": HOST_ID, "host_pid": 4242}]

    def rpc(self, method, params=None, timeout=None):
        assert method == "snapshot.get", method
        self.reads += 1
        if self.reads <= self.standin_reads:
            tab = {"id": "pending_tab_e05df098-4241-484a-9ac6-3d6567e68f33", "terminal": HOST_ID}
        else:
            tab = {"id": "tab_afaf3d427ec4d32fe27c5e230125d48b", "terminal": PUBLIC_ID, "terminal_key": HOST_ID}
        pane = {"id": PANE, "selected_tab": tab["id"], "tabs": [{"id": "tab_first", "terminal": "term_first"}, tab]}
        return {"topology": {"workspaces": [{"name": "jr-r3-tab", "screens": [{"panes": [pane]}]}]}}

    def screen(self, term):
        self.screen_reads.append(term)
        if term != PUBLIC_ID:
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
        app = CtrlBacktickApp(standin_reads=1)
        journey, result = self.play(app)
        self.assertEqual(journey.term, PUBLIC_ID)
        self.assertEqual(result["terminal"], PUBLIC_ID)
        self.assertEqual(result["pane"], PANE)
        self.assertIn(HOST_ID, journey.known_views)

    def test_no_standin_adopts_at_once(self):
        app = CtrlBacktickApp(standin_reads=0)
        journey, _ = self.play(app)
        self.assertEqual(journey.term, PUBLIC_ID)
        self.assertEqual(app.reads, 1)

    def test_a_terminal_the_daemon_never_knows_still_fails(self):
        app = CtrlBacktickApp(standin_reads=10 ** 6)
        with self.assertRaises(D.StepError) as caught:
            self.play(app, timeout=1)
        self.assertIn(HOST_ID, str(caught.exception))
        self.assertIn("stand-in", str(caught.exception))


if __name__ == "__main__":
    unittest.main()
