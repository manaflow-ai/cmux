#!/usr/bin/env python3
"""ext_firstrun.py's skip_first_run_history against a fake app socket (no fleet, no app), and the generators that add it.

    python3 scripts/journeys/test_ext_firstrun.py

Builds with #33215 (feat 51fad067074, 2026-11-03) open the first-run "Bring your history" page (page cmux.import-history)
on top of a fresh profile's first window (OnboardingService.showHistoryAtFirstRun): every journey's first new_terminal
then found no focused terminal pane (STATUS 10288). The step leaves the page as a person does: the footer's Skip button
pressed by a trusted Chromium click at its center (debug.page hover gives it in CSS px, debug.page press native: true),
because the page's finish checks a user gesture (a socket `call` cannot skip it). It waits until no import-history page is
left. With no such page within APPEAR_S it does nothing. A page that does not close fails the step with its record.

The lead's rule (STATUS 10405, 10562, 10641): the first-run page eating Ctrl-` is itself a product P0 (P0 FIRST-RUN KEYS,
#34547), so only resize films (px-, rk-, rv-, rkd-: their subject is not the first window) skip it, and never an open P0
journey (handoff/open-p0-journeys.txt; a fixed copy of its ids below).
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


# The lead's rule (STATUS 10405, 10562, 10641): the first-run page eating Ctrl-` is a product P0 (P0 FIRST-RUN KEYS, fix
# #34547), so the skip may never hide it. It is allowed ONLY in resize films (their subject is not the first window), and
# never in an open P0 journey.
FILM_PREFIXES = ("px-", "rk-", "rv-", "rkd-")
OPEN_P0_FILE = Path("/Users/lawrence/fun/wt/handoff/open-p0-journeys.txt")
# The open P0 journeys of that file on 2026-11-04 (cmux-ad 12:35Z), so the test runs without it.
OPEN_P0 = frozenset({"r3-new-tab-panel", "tipred-1193-stand-in", "focus-corner-drag", "r3-after-switch", "close-then-type",
                     "ctrlbt-real-palette", "r3-e2-reattach", "quit-reopen-restore", "typing-load-l6", "resize-keyboard"})


def open_p0_ids():
    """OPEN_P0 and, where the handoff file is, its ids: the first field of each non-comment line (a|b: any of them)."""
    ids = set(OPEN_P0)
    if OPEN_P0_FILE.is_file():
        for line in OPEN_P0_FILE.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#"):
                ids.update(i for i in line.split()[0].split("|") if i)
    return ids


def skips(spec):
    return "skip_first_run_history" in [st.get("do") for st in spec.get("steps") or []]


def kit_journeys():
    return [(path, json.loads(path.read_text())) for path in sorted((HERE / "journeys").rglob("*.json"))]


class FirstRunRuleTests(unittest.TestCase):
    """The checked-in journeys follow the lead's rule: the skip only in resize films (px-, rk-, rv-, rkd-), right after
    the launch's smoke_make_key, never in an open P0 journey; and every resize film that launches has it."""

    def test_no_open_p0_journey_skips_the_page(self):
        ids = open_p0_ids()
        found = [spec["id"] for _, spec in kit_journeys() if spec["id"] in ids and skips(spec)]
        self.assertEqual(found, [])

    def test_only_resize_films_skip_the_page(self):
        found = [str(path.relative_to(HERE)) for path, spec in kit_journeys() if skips(spec) and not spec["id"].startswith(FILM_PREFIXES)]
        self.assertEqual(found, [])

    def test_every_resize_film_skips_it_after_the_launch(self):
        ids = open_p0_ids()
        missing = []
        for path, spec in kit_journeys():
            dos = [st.get("do") for st in spec.get("steps") or []]
            if not spec["id"].startswith(FILM_PREFIXES) or spec["id"] in ids or "smoke_make_key" not in dos:
                continue
            if dos[dos.index("smoke_make_key") + 1:][:1] != ["skip_first_run_history"] or dos.count("skip_first_run_history") != 1:
                missing.append(str(path.relative_to(HERE)))
        self.assertEqual(missing, [])

    def test_the_fixed_list_matches_the_handoff_file(self):
        if not OPEN_P0_FILE.is_file():
            self.skipTest("no handoff/open-p0-journeys.txt on this host")
        self.assertTrue(OPEN_P0 <= open_p0_ids())


class GeneratorTests(unittest.TestCase):
    """Each generator applies the rule itself: the resize-film generators (gen_pixel px-, gen_cases rv-, gen_keys rk- and
    rkd-) put the step right after the launch's smoke_make_key, except in an open P0 journey (gen_keys' resize-keyboard);
    typing/gen.py, typing/gen_load.py and routing/gen.py never do."""

    def check(self, specs):
        self.assertTrue(specs)
        ids = open_p0_ids()
        for s in specs:
            dos = [st["do"] for st in s["steps"]]
            if s["id"].startswith(FILM_PREFIXES) and s["id"] not in ids and "smoke_make_key" in dos:
                self.assertEqual(dos[dos.index("smoke_make_key") + 1], "skip_first_run_history", s["id"])
                self.assertEqual(dos.count("skip_first_run_history"), 1, s["id"])
            else:
                self.assertNotIn("skip_first_run_history", dos, s["id"])

    def run_gen(self, script, *args):
        out = tempfile.mkdtemp(prefix="gen-firstrun-")
        done = subprocess.run([sys.executable, str(HERE / script), *[a.format(out=out) for a in args]],
                              capture_output=True, text=True, timeout=180)
        self.assertEqual(done.returncode, 0, done.stderr[-2000:])
        return [json.loads(p.read_text()) for p in sorted(Path(out).glob("*.json"))]

    def checked(self, script):
        """A generator that writes the kit's own folder: its --check proves those files are its output."""
        done = subprocess.run([sys.executable, str(HERE / script), "--check"], capture_output=True, text=True, timeout=180)
        self.assertEqual(done.returncode, 0, done.stdout[-2000:] + done.stderr[-2000:])

    def test_gen_pixel(self):
        specs = self.run_gen("video-cases/gen_pixel.py", "--out", "{out}")
        self.check(specs)
        self.assertTrue(all(skips(s) for s in specs))

    def test_gen_cases(self):
        specs = self.run_gen("video-cases/gen_cases.py", "--out", "{out}")
        self.check(specs)
        self.assertTrue(all(s["id"].startswith("rv-") and skips(s) for s in specs))

    def test_gen_keys(self):
        out = tempfile.mkdtemp(prefix="gen-firstrun-keys-")
        for script in ("video-cases/gen_cases.py", "video-cases/gen_keys.py"):  # gen_keys derives rkd- from gen_cases' rv-
            done = subprocess.run([sys.executable, str(HERE / script), "--out", out], capture_output=True, text=True, timeout=180)
            self.assertEqual(done.returncode, 0, done.stderr[-2000:])
        specs = [json.loads(p.read_text()) for p in sorted(Path(out).glob("*.json")) if not p.name.startswith("rv-")]
        self.check(specs)
        by_id = {s["id"]: s for s in specs}
        self.assertFalse(skips(by_id["resize-keyboard"]))  # an open P0: it meets the page as a person does
        self.assertTrue(any(i.startswith("rkd-") for i in by_id))

    def test_gen_load(self):
        self.checked("typing/gen_load.py")
        specs = [json.loads(p.read_text()) for p in sorted((HERE / "journeys" / "video").glob("typing-load-l[0-9]*.json"))]
        self.check(specs)
        self.assertFalse([s["id"] for s in specs if skips(s)])

    def test_typing_and_routing(self):
        for script in ("typing/gen.py", "routing/gen.py"):
            self.checked(script)
        specs = [spec for _, spec in kit_journeys() if spec.get("id", "").startswith(("typing-", "routing-"))]
        self.assertTrue(specs)
        self.check(specs)


if __name__ == "__main__":
    unittest.main(verbosity=2)
