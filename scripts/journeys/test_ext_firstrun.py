#!/usr/bin/env python3
"""ext_firstrun.py's skip_first_run_history against a fake app socket (no fleet, no app), and the generators that add it.

    python3 scripts/journeys/test_ext_firstrun.py

Builds with #33215 (feat 51fad067074, 2026-11-03) open the first-run "Bring your history" page (page cmux.import-history)
on top of a fresh profile's first window (OnboardingService.showHistoryAtFirstRun): every journey's first new_terminal
then found no focused terminal pane (STATUS 10288). The step leaves the page as a person does: the footer's Skip button
pressed by a trusted Chromium click at its center (debug.page hover gives it in CSS px, debug.page press native: true),
because the page's finish checks a user gesture (a socket `call` cannot skip it). It waits until no import-history page is
left. With no such page within APPEAR_S it does nothing. A page that does not close fails the step with its record.
"""
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path[:0] = [str(HERE), str(HERE.parent / "cmux-next")]
import driver as D  # noqa: E402  (loads ext_*.py: ext_firstrun installs with it)
import ext_firstrun as F  # noqa: E402

PAGE = "cmux.import-history"
SKIP = "footer.history-footer > button.history-button"


class FakeClock:
    def __init__(self):
        self.t = 1000.0

    def monotonic(self):
        return self.t

    def sleep(self, seconds):
        self.t += max(0.0, float(seconds))


class HistoryApp:
    """The control socket. `appears_at`: when the page opens (None: never); `closes`: whether the trusted press closes
    it; `hit`: whether hover finds the Skip button at its center; `no_method`: a build without debug.page."""

    def __init__(self, clock, appears_at=1000.0, closes=True, hit=True, no_method=False, parked=False):
        self.clock, self.appears_at, self.closes, self.hit, self.no_method, self.parked = clock, appears_at, closes, hit, no_method, parked
        self.calls, self.closed = [], False

    def live(self):
        return self.appears_at is not None and self.clock.t >= self.appears_at and not self.closed

    def rpc(self, method, params=None, timeout=None):
        params = params or {}
        self.calls.append((method, dict(params)))
        if method != "debug.page" or self.no_method:
            raise D.StepError(f"{method}: {{'code': 'method_not_found', 'message': 'unknown method {method}'}}")
        action = params.get("action")
        if action == "list":
            pages = [{"page": PAGE, "instance": 1, "parked": False, "window_number": 7}] if self.live() else []
            if self.parked:
                pages.append({"page": PAGE, "instance": 2, "parked": True, "window_number": None})
            return {"pages": pages}
        if not self.live():
            return {"error": f"no live page {PAGE}"}
        if action == "wait":
            return {"found": True, "selector": params.get("selector")}
        if action == "hover":
            return {"hovered": True, "native": True, "x": 212.5, "y": 611.0} if self.hit else \
                {"hovered": False, "error": "another element is at its center"}
        if action == "press":
            if self.closes:
                self.closed = True
            return {"pressed": True}
        if action == "click":
            return {"clicked": True}
        raise AssertionError(f"unexpected debug.page {params}")


class FakeJourney:
    def __init__(self, app):
        self.app = app


class SkipFirstRunHistoryTests(unittest.TestCase):
    def setUp(self):
        self.clock = FakeClock()
        self.saved = (F.D.now, F.time)
        F.D.now, F.time = self.clock.monotonic, self.clock

    def tearDown(self):
        F.D.now, F.time = self.saved

    def presses(self, app):
        return [p for m, p in app.calls if m == "debug.page" and p.get("action") == "press"]

    def test_presses_skip_with_a_trusted_click_and_waits_until_the_page_is_gone(self):
        app = HistoryApp(self.clock, appears_at=1001.0)
        out = F.step_skip_first_run_history(FakeJourney(app), {})
        self.assertEqual(self.presses(app), [{"page": PAGE, "action": "press", "x": 212.5, "y": 611.0, "native": True}])
        waits = [p for m, p in app.calls if p.get("action") == "wait"]
        self.assertEqual(waits[0]["selector"], SKIP)
        hovers = [p for m, p in app.calls if p.get("action") == "hover"]
        self.assertEqual(hovers[0]["selector"], SKIP)
        self.assertTrue(out["skipped"])
        self.assertEqual(out["pages_before"], 1)
        self.assertFalse([p for m, p in app.calls if p.get("action") in ("click", "call")])  # never the untrusted paths

    def test_a_launch_without_the_page_does_nothing(self):
        app = HistoryApp(self.clock, appears_at=None)
        out = F.step_skip_first_run_history(FakeJourney(app), {})
        self.assertFalse(out["skipped"])
        self.assertEqual(self.presses(app), [])
        self.assertGreaterEqual(self.clock.t - 1000.0, F.APPEAR_S)  # it looked for the page for APPEAR_S
        self.assertLess(self.clock.t - 1000.0, F.APPEAR_S + 1)

    def test_a_parked_spare_is_not_the_page(self):
        app = HistoryApp(self.clock, appears_at=None, parked=True)
        out = F.step_skip_first_run_history(FakeJourney(app), {})
        self.assertFalse(out["skipped"])
        self.assertEqual(self.presses(app), [])

    def test_a_build_without_debug_page_does_nothing(self):
        app = HistoryApp(self.clock, no_method=True)
        out = F.step_skip_first_run_history(FakeJourney(app), {})
        self.assertFalse(out["skipped"])
        self.assertIn("debug.page", out["why"])

    def test_a_page_that_does_not_close_fails_with_its_record(self):
        app = HistoryApp(self.clock, closes=False)
        with self.assertRaises(D.StepError) as caught:
            F.step_skip_first_run_history(FakeJourney(app), {})
        text = str(caught.exception)
        self.assertIn("did not close", text)
        self.assertIn('"pressed": true', text)
        self.assertIn(PAGE, text)

    def test_a_skip_button_it_cannot_hit_fails_without_a_press(self):
        app = HistoryApp(self.clock, hit=False)
        with self.assertRaises(D.StepError) as caught:
            F.step_skip_first_run_history(FakeJourney(app), {})
        self.assertEqual(self.presses(app), [])
        self.assertIn("another element is at its center", str(caught.exception))


class GeneratorTests(unittest.TestCase):
    """Every generator whose journeys start with smoke_make_key adds the step right after the first smoke_make_key (the
    launch's), once: never after a relaunch's own smoke_make_key, so a relaunch keeps the profile that saw the page."""

    def check(self, specs):
        self.assertTrue(specs)
        for s in specs:
            dos = [st["do"] for st in s["steps"]]
            if "smoke_make_key" not in dos:
                continue
            first = dos.index("smoke_make_key")
            self.assertEqual(dos[first + 1], "skip_first_run_history", s["id"])
            self.assertEqual(dos.count("skip_first_run_history"), 1, s["id"])

    def run_gen(self, script, *args):
        out = tempfile.mkdtemp(prefix="gen-firstrun-")
        done = subprocess.run([sys.executable, str(HERE / script), *[a.format(out=out) for a in args]],
                              capture_output=True, text=True, timeout=180)
        self.assertEqual(done.returncode, 0, done.stderr[-2000:])
        return [json.loads(p.read_text()) for p in sorted(Path(out).glob("*.json"))]

    def test_gen_pixel(self):
        self.check(self.run_gen("video-cases/gen_pixel.py", "--out", "{out}"))

    def test_gen_cases(self):
        self.check(self.run_gen("video-cases/gen_cases.py", "--out", "{out}"))

    def test_gen_load(self):
        specs = self.run_gen("typing/gen_load.py", "--out", "{out}")
        self.check(specs)
        # The typing round relaunches (probe_relaunch) and makes the new window key again: that one stays as it was.
        l6 = next(s for s in specs if s["id"] == "typing-load-l6")
        dos = [st["do"] for st in l6["steps"]]
        self.assertEqual(dos.count("smoke_make_key"), 2)
        second = dos.index("smoke_make_key", dos.index("smoke_make_key") + 1)
        self.assertNotEqual(dos[second + 1], "skip_first_run_history")

    def test_every_journey_in_the_kit(self):
        """The checked-in journeys: every one whose steps have smoke_make_key has the step right after the first."""
        files = sorted((HERE / "journeys").rglob("*.json"))
        missing = []
        for path in files:
            spec = json.loads(path.read_text())
            dos = [st.get("do") for st in spec.get("steps") or []]
            if "smoke_make_key" in dos and dos[dos.index("smoke_make_key") + 1:][:1] != ["skip_first_run_history"]:
                missing.append(str(path.relative_to(HERE)))
        self.assertEqual(missing, [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
