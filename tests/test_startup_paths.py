#!/usr/bin/env python3
"""scripts/ci/startup_paths.py: the fresh-install round's first-launch prompt, with every input route mocked.

The 2d0ebd4bf7e5 baselines failed all ten fresh-install rounds: the Gatekeeper prompt stayed up because the round
looked for the computer-use driver only in ~/.local/bin (the fleet's is /Applications/CuaDriver.app), then asked
System Events, which timed out after 20 s on every look, and the rounds blamed the app ("no first window frame").
These check that the fleet's driver is found and presses Open, that a failed System Events is not asked again,
that the row keeps the route and the prompt's wait, and that a prompt nothing could press fails the round as the
harness's failure and ends it early. Nothing here starts a process: Popen, the routes, the log and the process
list are fakes, and os.kill / os.killpg raise if anything reaches them.
"""
from __future__ import annotations

import json
import os
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts" / "ci"))
import startup_paths as startup  # noqa: E402

FAKE_PID = 4_000_001  # never signalled: os.kill and os.killpg are patched to raise


def refuse_signal(*args, **kwargs):
    raise AssertionError(f"a test reached a signal call: {args}")


class FakeRunText:
    """startup.run_text: pgrep finds CoreServicesUIAgent; cua-driver and osascript answer from scripts."""

    def __init__(self, cua=None, osascript=None):
        self.cua = cua or {}
        self.osascript = list(osascript or [])
        self.calls: list[list[str]] = []

    def __call__(self, args, timeout=120):
        self.calls.append(list(args))
        if args[0] == "pgrep":
            return 0, "321"
        if args[0] == "osascript":
            return self.osascript.pop(0) if self.osascript else (1, "no more answers")
        if len(args) >= 3 and args[1] == "call":
            answer = self.cua.get(args[2])
            if answer is None:
                return 1, f"no fake for {args[2]}"
            return 0, json.dumps(answer(json.loads(args[3])) if callable(answer) else answer)
        return 1, f"unexpected {args}"

    def tool_calls(self, name):
        return [c for c in self.calls if len(c) >= 3 and c[1] == "call" and c[2] == name]


PROMPT_WINDOWS = {"windows": [{"window_id": 77, "is_on_screen": True, "title": ""}]}
PROMPT_TREE = {"elements": [{"role": "AXStaticText", "label": "“cmux NIGHTLY” is an app downloaded from the Internet."},
                            {"role": "AXButton", "title": "Cancel", "element_token": "t-cancel"},
                            {"role": "AXButton", "title": "Open", "element_token": "t-open",
                             "frame": {"x": 10, "y": 20, "width": 80, "height": 30}}]}


class DriverDiscoveryTests(unittest.TestCase):
    def test_the_fleet_driver_is_found_when_the_lane_has_none(self):
        with tempfile.TemporaryDirectory() as tmp:
            fleet = Path(tmp) / "CuaDriver.app" / "Contents" / "MacOS" / "cua-driver"
            fleet.parent.mkdir(parents=True)
            fleet.write_text("#!/bin/sh\n")
            fleet.chmod(0o755)
            with mock.patch.object(startup, "CUA_PATHS", (Path(tmp) / "absent" / "cua-driver", fleet)), \
                    mock.patch.object(startup.shutil, "which", return_value=None):
                self.assertEqual(startup.cua_driver(), fleet)

    def test_no_driver_anywhere_is_none(self):
        with tempfile.TemporaryDirectory() as tmp:
            with mock.patch.object(startup, "CUA_PATHS", (Path(tmp) / "a",)), \
                    mock.patch.object(startup.shutil, "which", return_value=None):
                self.assertIsNone(startup.cua_driver())


class PromptRouteTests(unittest.TestCase):
    def setUp(self):
        startup.PromptRoutes.system_events_broken = False

    def test_the_driver_presses_open_by_its_element_token_and_system_events_is_never_asked(self):
        fake = FakeRunText(cua={"list_windows": PROMPT_WINDOWS, "get_window_state": PROMPT_TREE, "click": {"ok": True}})
        with mock.patch.object(startup, "run_text", fake):
            got = startup.PromptRoutes(Path("/fake/cua-driver")).answer()
        self.assertEqual(got["route"], "cua-driver")
        self.assertTrue(got["click"])
        clicks = fake.tool_calls("click")
        self.assertEqual(len(clicks), 1)
        self.assertEqual(json.loads(clicks[0][3])["element_token"], "t-open")
        self.assertFalse([c for c in fake.calls if c[0] == "osascript"])

    def test_no_prompt_window_is_none(self):
        fake = FakeRunText(cua={"list_windows": {"windows": []}})
        with mock.patch.object(startup, "run_text", fake):
            routes = startup.PromptRoutes(Path("/fake/cua-driver"))
            self.assertIsNone(routes.answer())
        self.assertTrue(routes.looked)

    def test_a_failed_system_events_is_asked_once_for_the_run(self):
        timeout = (-1, "error: Command '['osascript', ...]' timed out after 20 seconds")
        fake = FakeRunText(osascript=[timeout, (0, "clicked")])
        with mock.patch.object(startup, "run_text", fake):
            routes = startup.PromptRoutes(None)
            first = routes.answer()
            second = routes.answer()
            with mock.patch.object(startup, "cua_driver", return_value=None):
                later_round = startup.PromptRoutes.for_host()
        self.assertFalse(first["shown"])
        self.assertIn("timed out", routes.errors["system-events"])
        self.assertIn("no cua-driver", routes.errors["cua-driver"])
        self.assertEqual(second["error"], "no route left")
        self.assertEqual(len([c for c in fake.calls if c[0] == "osascript"]), 1)
        self.assertFalse(routes.left())
        self.assertFalse(later_round.left())
        self.assertFalse(routes.looked)

    def test_system_events_answers_when_it_works(self):
        fake = FakeRunText(osascript=[(0, "clicked")])
        with mock.patch.object(startup, "run_text", fake):
            got = startup.PromptRoutes(None).answer()
        self.assertEqual(got["route"], "system-events")


class FakeSmoke:
    FIRST_RUN_MARK = "first_run"

    class CannotRun(Exception):
        pass

    def fresh_env(self, root, sock, fd):
        return {"HOME": str(root / "h")}

    def alive(self, pid):
        return True

    def snapshot(self, sock, timeout=2.0):
        return {"home": True}

    def home_rendered(self, snap, marks):
        return True

    def own_pids(self, root):
        return []

    def user_processes(self):
        return []

    def stop(self, pids):
        self.stopped = pids


class FakeOpener:
    pid = FAKE_PID
    stderr = None

    def wait(self, timeout=None):
        return 0

    def kill(self):
        raise AssertionError("the opener is never killed in these tests")


class ScriptedRoutes:
    """A PromptRoutes stand-in: each answer() pops the next scripted answer (and may write launch marks)."""

    def __init__(self, answers, left=True, looked=True, errors=None, fifo=None, marks_on_click=None):
        self.answers, self._left, self.looked = list(answers), left, looked
        self.errors = dict(errors or {})
        self.fifo, self.marks_on_click = fifo, marks_on_click

    def left(self):
        return self._left

    def answer(self):
        got = self.answers.pop(0) if self.answers else None
        if got and got.get("click") and self.marks_on_click:
            fd = os.open(self.fifo(), os.O_WRONLY | os.O_NONBLOCK)
            os.write(fd, self.marks_on_click.encode())
            os.close(fd)
        return got

    def summary(self):
        return "; ".join(f"{k}: {v}" for k, v in self.errors.items())


class OpenLaunchTests(unittest.TestCase):
    def launch(self, routes_for):
        root = Path(tempfile.mkdtemp(prefix="startup-paths-test-"))
        self.addCleanup(lambda: __import__("shutil").rmtree(root, ignore_errors=True))
        routes = routes_for(lambda: str(root / "marks.fifo"))
        with mock.patch.object(startup.subprocess, "Popen", return_value=FakeOpener()), \
                mock.patch.object(startup, "own_executables", return_value=[]), \
                mock.patch.object(startup, "app_pid", return_value=(FAKE_PID, "/x/AppTranslocation/y/cmux NIGHTLY.app/Contents/MacOS/cmux")), \
                mock.patch.object(startup, "gate_log", return_value={}), \
                mock.patch.object(startup, "NO_ROUTE_S", 0.3), mock.patch.object(startup, "STARTUP_S", 2.0), \
                mock.patch.object(os, "kill", refuse_signal), mock.patch.object(os, "killpg", refuse_signal):
            started = time.monotonic()
            out = startup.open_launch(FakeSmoke(), root, root / "cmux NIGHTLY.app", "cmux", "com.example.app", 0.0,
                                      None, routes=routes)
        row = {"path": "fresh-install", "failures": [], **out}
        row["failures"] += startup.launch_failures(row)
        return row, time.monotonic() - started

    def test_a_pressed_prompt_keeps_its_route_shown_time_and_wait(self):
        marks = ("main_start 40\nfirst_window_frame_committed 900\nreveal.sidebar 950\nreveal.tabs 960\n"
                 "reveal.home 1000\n")
        row, _ = self.launch(lambda fifo: ScriptedRoutes(
            [{"route": "cua-driver", "shown": True, "error": "click: busy"},
             {"route": "cua-driver", "shown": True, "click": {"ok": True}}], fifo=fifo, marks_on_click=marks))
        self.assertEqual(row["prompt_route"], "cua-driver")
        self.assertIsNotNone(row["prompt_shown_ms"])
        self.assertGreaterEqual(row["prompt_wait_ms"], 400)  # the second look, 0.5 s after the first
        self.assertEqual(row["first_window_ms"], 900)
        self.assertIsNone(row["prompt_unanswered"])
        self.assertEqual(row["failures"], [])
        self.assertNotIn("harness_failure", row)

    def test_no_route_fails_the_round_as_the_harness_and_ends_it_early(self):
        errors = {"cua-driver": "no cua-driver", "system-events": "timed out after 20 seconds"}
        row, took = self.launch(lambda fifo: ScriptedRoutes(
            [{"route": None, "shown": False, "error": "no route left"}] * 50, left=False, looked=False, errors=errors))
        want = "prompt could not be answered: cua-driver: no cua-driver; system-events: timed out after 20 seconds"
        self.assertEqual(row["failures"], [want])
        self.assertEqual(row["harness_failure"], want)
        self.assertLess(took, 5.0)  # NO_ROUTE_S, not STARTUP_S

    def test_a_prompt_seen_but_not_pressed_is_the_harness_failure(self):
        row, _ = self.launch(lambda fifo: ScriptedRoutes(
            [{"route": "cua-driver", "shown": True, "error": "no Open button in 1 window(s)"}] * 400,
            errors={"cua-driver": "no Open button in 1 window(s)"}))
        self.assertTrue(row["harness_failure"].startswith("prompt could not be answered: cua-driver: no Open button"))

    def test_no_prompt_seen_and_no_start_is_the_apps_failure(self):
        row, _ = self.launch(lambda fifo: ScriptedRoutes([None] * 400))
        self.assertNotIn("harness_failure", row)
        self.assertIn("no first window frame", row["failures"])


if __name__ == "__main__":
    unittest.main()
