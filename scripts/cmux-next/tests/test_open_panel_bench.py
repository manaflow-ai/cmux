#!/usr/bin/env python3
"""open-panel-bench.py keeps the first open after a launch or a STRESS build out of its percentiles (fix review of
deep-fleet-gui).

The fixed 3 s settle sleep after the launch went away with no readiness signal in its place, so the first open of a
session can run during launch work (session restore, first page loads) or right after the STRESS build. That open went
into the session's p50/p95/max (with the default 5 rounds p95 is the max), and the row was compared with earlier runs
that had the settle. The bench reports it on its own row (`first_open`) and leaves it out of the percentiles.

Drives the real measure step with a stand-in app (no app, build or GUI session). Repo rule: run on the fleet.

    python3 scripts/cmux-next/tests/test_open_panel_bench.py
"""

from __future__ import annotations

import argparse
import importlib.util
import io
import unittest
from contextlib import redirect_stdout
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "open-panel-bench.py"


def load_bench():
    spec = importlib.util.spec_from_file_location("open_panel_bench", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class StandInApp:
    """Answers `debug.open_panel_bench` as the app does; the first open it answers ran during launch work."""

    def __init__(self, first_ms=900.0, later_ms=5.0):
        self.first_ms = first_ms
        self.later_ms = later_ms
        self.opens = 0

    def rpc(self, method, params=None, timeout=60):
        assert method == "debug.open_panel_bench", method
        ms = self.first_ms if self.opens == 0 else self.later_ms
        self.opens += 1
        return {"mode": params["mode"], "made_ahead_before": True, "init_ms": ms, "begin_ms": 1.0, "sync_ms": ms + 1.0,
                "visible_ms": ms + 40.0, "frames": {"max_ms": ms + 16.7, "missed": 0, "refresh_ms": 16.7}}


class FirstReplyApp(StandInApp):
    """Gives `first` as the answer to the session's first open, then answers as ``StandInApp``."""

    def __init__(self, first):
        super().__init__()
        self.first = first

    def rpc(self, method, params=None, timeout=60):
        if self.opens:
            return super().rpc(method, params, timeout)
        self.opens += 1
        return {"mode": params["mode"], **self.first}


# What `debug.open_panel_bench` (DebugOpenPanelBench.swift) answers for a panel that came back dead: no times, no frames.
DEAD_REPLY = {"error": "the panel came back dead (no prompt)"}
# A live first open whose panel was not made ahead (the warm-up had not run): times, and made_ahead_before false.
NOT_MADE_AHEAD_REPLY = {"made_ahead_before": False, "prompt_nil": False, "init_ms": 310.0, "begin_ms": 280.0,
                        "sync_ms": 590.0, "visible_ms": 640.0, "frames": {"max_ms": 330.0, "missed": 18, "refresh_ms": 16.7}}


class FirstOpenTests(unittest.TestCase):
    def setUp(self):
        self.bench = load_bench()
        self.opts = argparse.Namespace(modes="made,fresh", rounds=5)

    def measure(self, app, session, report):
        with redirect_stdout(io.StringIO()):
            self.bench.measure(app, session, report, self.opts)

    def test_the_first_open_of_a_session_is_reported_on_its_own_and_left_out_of_the_percentiles(self):
        report = {"runs": [], "summary": []}
        self.measure(StandInApp(), "light", report)

        first = [run for run in report["runs"] if run.get("first_open")]
        self.assertEqual([(run["mode"], run["round"], run["init_ms"]) for run in first], [("made", 0, 900.0)],
                         "the first open after the launch is not marked as the session's first open")
        made = next(row for row in report["summary"] if row["mode"] == "made")
        self.assertEqual(made["init_ms"]["max"], 5.0, "the first open's launch work went into the made p95/max")
        self.assertEqual(made["n"], 4, "the made row does not say it summarizes the 4 later opens")
        fresh = next(row for row in report["summary"] if row["mode"] == "fresh")
        self.assertEqual(fresh["n"], 5, "a later mode lost an open that was not the session's first")
        self.assertEqual([row["init_ms"] for row in report["first_opens"]], [900.0],
                         "the first open has no row of its own")

    def test_each_session_has_its_own_first_open(self):
        report = {"runs": [], "summary": []}
        self.measure(StandInApp(), "light", report)
        self.measure(StandInApp(first_ms=700.0), "stress", report)  # the first open after the STRESS build
        self.assertEqual([(row["session"], row["init_ms"]) for row in report["first_opens"]],
                         [("light", 900.0), ("stress", 700.0)])
        self.assertTrue(all(row["init_ms"]["max"] == 5.0 for row in report["summary"]),
                        "a first open went into a session's percentiles")

    def test_a_first_open_that_failed_or_was_not_made_ahead_says_so_on_its_own_row(self):
        """The first open is outside every OPEN-PANEL row, so its own row is the only place a failed one shows
        (fix review of deep-fleet-gui): the row copied only the times, so a dead or not-made-ahead first open after a
        launch or the STRESS build printed nulls or large times with no cause while the made row looked healthy."""
        report = {"runs": [], "summary": []}
        self.measure(FirstReplyApp(DEAD_REPLY), "light", report)
        self.measure(FirstReplyApp(NOT_MADE_AHEAD_REPLY), "stress", report)
        dead, cold = report["first_opens"]
        self.assertEqual(dead.get("error"), DEAD_REPLY["error"], f"the dead first open's error is missing: {dead}")
        self.assertIs(cold.get("made_ahead_before"), False, f"the first open does not say it was not made ahead: {cold}")
        self.assertIs(cold.get("prompt_nil"), False, f"the first open does not carry its prompt read: {cold}")
        self.assertEqual(cold.get("missed"), 18, f"the first open does not carry its missed frames: {cold}")

if __name__ == "__main__":
    unittest.main()
