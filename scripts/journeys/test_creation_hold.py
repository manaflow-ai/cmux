#!/usr/bin/env python3
"""The driver's wait for the app's creation hold before the next key (driver.CREATION_HOLD_SECONDS),
no fleet, no app.

    python3 scripts/journeys/test_creation_hold.py

A capture slot's window is never key, so keys the app holds for a terminal still being made are
lost when it replays them (README, "A capture slot's window is never the key window"). The app
also holds the Ctrl-` presses typed while a tab is being made and replays them one creation at a
time, so after a burst the last tab's hold starts when that tab is made, not at the last key:
app-life-many-tabs on v2.2.1 (job 6edf74856e2251c0e7765b00) pressed Ctrl-` 19 times in 2.8 s, the
20th tab came 16 s later, the driver typed 0.3 s after it (it counted 2.5 s from the last press),
and every key went into that hold (handled_by app, empty trace) and was lost, in 2 of 3 runs.
"""
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
# driver.py imports build_names.py, which run.py sends beside it; in the repo it is in scripts/cmux-next.
sys.path[:0] = [str(HERE), str(HERE.parent / "cmux-next")]
import driver as D  # noqa: E402


class FakeApp:
    """The one focused terminal pane a burst of Ctrl-` ends on."""

    def panes(self):
        return [{"pane": "pane_1", "focused": True, "kind": "terminal", "terminal_id": "term_20", "host_pid": 7}]


def journey_after_burst(seconds_since_last_key):
    j = D.Journey.__new__(D.Journey)
    j.app, j.known_views, j.term, j.pane, j.host_pid = FakeApp(), set(), None, None, None
    j.last_key_at = D.now() - seconds_since_last_key
    topo = {"workspaces": []}
    j.topology = lambda: topo
    j.places = lambda _topo: [({"name": "jr-many"}, {"id": "pane_1", "selected_tab": "tab_20"}, {"id": "tab_20"}, "term_20")]
    j.wait_screen = lambda _end: None
    return j


class CreationHoldTests(unittest.TestCase):
    def setUp(self):
        self.slept = []
        self.real_sleep = D.time.sleep
        D.time.sleep = self.slept.append

    def tearDown(self):
        D.time.sleep = self.real_sleep

    def test_keys_after_a_late_terminal_wait_out_its_hold(self):
        # The 20th tab of a burst is focused 16 s after the last Ctrl-` (run1 of v2.2.1): its hold is
        # only starting, so the next key waits about CREATION_HOLD_SECONDS from now, not from that press.
        j = journey_after_burst(16.0)
        j.step_focused_terminal({"do": "focused_terminal"})
        waited = j.before_keys()
        self.assertIsNotNone(waited)
        self.assertGreater(waited, D.CREATION_HOLD_SECONDS - 0.5)
        self.assertEqual(len(self.slept), 1)

    def test_keys_after_a_prompt_terminal_wait_at_most_the_hold(self):
        # A single Ctrl-` whose terminal is focused at once: the wait is still bounded by the hold.
        j = journey_after_burst(0.0)
        j.step_focused_terminal({"do": "focused_terminal"})
        waited = j.before_keys()
        self.assertLessEqual(waited, D.CREATION_HOLD_SECONDS)

    def test_only_the_next_key_waits(self):
        j = journey_after_burst(16.0)
        j.step_focused_terminal({"do": "focused_terminal"})
        j.before_keys()
        self.assertIsNone(j.before_keys())


if __name__ == "__main__":
    unittest.main()
