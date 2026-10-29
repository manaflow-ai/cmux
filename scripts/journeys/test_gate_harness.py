#!/usr/bin/env python3
"""The journey harness fixes from the v2.2.4-opt dogfood gate triage (handoff/v224-gate-triage.md), no fleet, no app.

    python3 scripts/journeys/test_gate_harness.py

1. Frame checks bring an occluded window to the front (debug.window.focus) before they read it, and keep each
   visible pane's surface pause in the evidence; a window still covered is `not run` (15 journeys failed on
   empty panes that AppKit had occluded on the shared capture host).
2. A terminal the topology names by the app's provisional id is read again from the topology when the daemon
   answers selector.not_found (mw-new-window-entrypoints, restart-restore).
3. A `last_in_lease` journey ends its lease (arrows-history and bracketed-paste ran after
   scripted-newtab-keeps-person-keys and its composer kept the keyboard).
4. The sidebar's Home is ('app', 'cmux/home') as well as ('built_in', 'home') (mw-home-click-each-window).
5. Browser journeys load the driver's own fixture page, never example.com.
"""
import importlib.util
import sys
import unittest
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path[:0] = [str(HERE), str(HERE.parent / "cmux-next")]
import driver as D  # noqa: E402

if "pane_frame_text" not in D.EXT_CONDITIONS:
    D.load_extensions(D)
import ext_multiwindow as MW  # noqa: E402  (the module load_extensions installed)
import ext_frametime as FT  # noqa: E402
import ext_home as EH  # noqa: E402

_spec = importlib.util.spec_from_file_location("journeys_run", HERE / "run.py")
RUN = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(RUN)


class CoveredApp:
    """One window whose single pane is occluded until debug.window.focus brings the window to the front
    (`stays_covered`: another app keeps it covered)."""

    def __init__(self, stays_covered=False, family=False):
        self.covered, self.stays_covered, self.calls, self.family = True, stays_covered, [], family
        self.snapshot_window = None

    def rpc(self, method, params=None, timeout=None):
        self.calls.append((method, params))
        if method == "debug.window.focus":
            self.covered = self.stays_covered
            return {"front": params["window"]}
        if method == "debug.windows":
            return {"windows": [{"id": "w-1", "family_occluded": self.family}]}
        if method == "debug.surfaces":
            pane = {"pane": "pane_1", "visible": True, "grid": {"window": "w-1"}, "window_occluded": self.covered,
                    "surface": {"paused": "window_occluded" if self.covered else None, "drawing": not self.covered}}
            return {"windows": [{"window": "26853", "panes": [pane]}]}
        raise AssertionError(f"unexpected rpc {method}")


def bare_journey(app, covers=None):
    j = D.Journey.__new__(D.Journey)
    j.app, j.pane, j.term = app, "pane_1", None
    app.pid = 100
    # The window server's covers of our window (another slot's app by default).
    j.covers_of = lambda number: [{"pid": 200, "owner": "cmux DEV other slot", "number": 9}] if covers is None else covers
    return j


class FramesReadASeenWindow(unittest.TestCase):
    def test_an_occluded_window_is_brought_to_the_front_before_the_read(self):
        app = CoveredApp()
        seen = bare_journey(app).ensure_seen()
        self.assertIn(("debug.window.focus", {"window": "w-1"}), app.calls)
        self.assertTrue(seen["brought_front"])
        self.assertEqual(seen["panes"], [{"pane": "pane_1", "occluded": False, "paused": None, "drawing": True}])

    def test_a_window_on_screen_is_left_alone(self):
        app = CoveredApp()
        app.covered = False
        seen = bare_journey(app).ensure_seen()
        self.assertNotIn("debug.window.focus", [m for m, _ in app.calls])
        self.assertFalse(seen["brought_front"])

    def test_a_window_that_stays_covered_is_not_run_never_a_fail(self):
        with self.assertRaises(D.NotRun):
            bare_journey(CoveredApp(stays_covered=True)).ensure_seen()

    def test_a_cover_by_the_apps_own_window_is_left_for_the_check_to_judge(self):
        app = CoveredApp()
        seen = bare_journey(app, covers=[{"pid": 100, "owner": "cmux DEV", "number": 7}]).ensure_seen()
        self.assertNotIn("debug.window.focus", [m for m, _ in app.calls])
        self.assertEqual(seen["panes"][0]["paused"], "window_occluded")

    def test_a_window_not_on_screen_is_left_as_it_is(self):
        app = CoveredApp()
        j = bare_journey(app)
        j.covers_of = lambda number: None
        j.ensure_seen()
        self.assertNotIn("debug.window.focus", [m for m, _ in app.calls])

    def test_an_unjudged_frame_never_hides_a_real_failure(self):
        j = bare_journey(CoveredApp(stays_covered=True))
        j.marks, j.evidence = {}, []

        def evaluate(name, want, cache):
            return (False, {"tail": []}) if name == "daemon_line" else (False, {})
        j.evaluate = evaluate
        with self.assertRaises(D.StepError) as failed:
            j.step_expect({"timeout": 0.2, "all": [{"daemon_line": "x"}, {"frame_text": "x"}]})
        self.assertIn("daemon_line", str(failed.exception))
        with self.assertRaises(D.NotRun):
            j.step_expect({"timeout": 0.2, "all": [{"frame_text": "x"}]})


class FrameEvidence(unittest.TestCase):
    """v2.2.6-opt gate: an empty pane paused window_occluded with AppKit's occluded false could not be explained, because
    the app's own cover judgment and its window state were not saved."""

    def test_seen_carries_the_apps_own_cover_judgment(self):
        app = CoveredApp(family=True)
        app.covered = False
        seen = bare_journey(app).ensure_seen()
        self.assertIs(seen["family_occluded"], True)

    def test_a_failed_frame_check_saves_the_apps_surfaces_and_windows(self):
        import tempfile, json as _json
        app = CoveredApp()
        app.covered = False
        j = bare_journey(app)
        j.out = Path(tempfile.mkdtemp())
        j.marks, j.evidence = {}, []
        j.evaluate = lambda name, want, cache: (False, {})
        with self.assertRaises(D.StepError):
            j.step_expect({"timeout": 0.1, "all": [{"frame_text": "x"}]})
        dump = _json.loads((j.out / "diag-framefail.json").read_text())
        self.assertIn("surfaces", dump)
        self.assertEqual(dump["windows"]["windows"][0]["id"], "w-1")


class ProvisionalTerminalID(unittest.TestCase):
    def test_the_topology_is_read_again_when_the_daemon_does_not_know_the_id(self):
        j = D.Journey.__new__(D.Journey)
        j.pane, j.term, j.host_pid = "pane_2", "8cabe8fb69a449a9987cc3d651b428df", None
        j.view_of_pane = lambda pane: {"pane": pane, "host_pid": 42}
        names = iter(["term_real"])
        j.selected_terminal = lambda pane: next(names, "term_real")

        class App:
            def screen(self, term):
                if term != "term_real":
                    raise D.StepError(f'cmux terminal {term} screen read: exit 1: {{"code":"selector.not_found"}}')
                return {"text": "J> "}

        j.app = App()
        j.wait_screen(D.now() + 2)
        self.assertEqual((j.term, j.host_pid), ("term_real", 42))

    def test_the_terminal_adopted_before_is_never_taken_again(self):
        j = D.Journey.__new__(D.Journey)
        j.pane, j.term, j.host_pid = "pane_2", "8cabe8fb69a449a9987cc3d651b428df", None
        j.adopted_terms = {"term_old"}
        j.selected_terminal = lambda pane: "term_old"
        j.view_of_pane = lambda pane: None

        class App:
            def screen(self, term):
                if term == "term_old":
                    return {"text": "J> "}
                raise D.StepError(f'cmux terminal {term} screen read: exit 1: {{"code":"selector.not_found"}}')

        j.app = App()
        with self.assertRaises(D.StepError):
            j.wait_screen(D.now() + 0.5)
        self.assertNotEqual(j.term, "term_old")


class LeaseBatches(unittest.TestCase):
    def spec(self, name, **extra):
        return dict({"id": name, "budget_seconds": 30}, **extra)

    def test_nothing_runs_after_a_last_in_lease_journey_in_its_lease(self):
        specs = [self.spec("keeps-keys", first_in_app=True, last_in_lease=True), self.spec("arrows"),
                 self.spec("paste"), self.spec("middle", last_in_lease=True), self.spec("after")]
        got = [[s["id"] for s in batch] for batch in RUN.batches(specs)]
        self.assertEqual(got, [["keeps-keys"], ["arrows", "paste", "middle"], ["after"]])

    def test_without_the_flag_journeys_share_leases_as_before(self):
        got = [[s["id"] for s in batch] for batch in RUN.batches([self.spec("a"), self.spec("b")])]
        self.assertEqual(got, [["a", "b"]])


class SidebarHome(unittest.TestCase):
    def test_the_app_item_cmux_home_is_home(self):
        frame = [0, 0, 10, 10]
        report = {"windows": [{"window": "w-1", "items": [
            {"ref_kind": "app", "ref": "cmux/home", "window_frame": frame},
            {"ref_kind": "app", "ref": "cmux/app-store", "window_frame": frame}]}]}

        class App:
            def rpc(self, method, params=None):
                return report

        j = bare_journey(App())
        item, name = MW.sidebar_target(j, "w-1", {"home": True})
        self.assertEqual((item["ref"], name), ("cmux/home", "home"))


class FixturePage(unittest.TestCase):
    def test_the_fixture_page_serves_its_heading_on_loopback(self):
        url = D.fixture_url()
        self.assertTrue(url.startswith("http://127.0.0.1:"))
        with urllib.request.urlopen(url, timeout=5) as answer:
            self.assertIn(D.FIXTURE_HEADING, answer.read().decode())

    def test_no_p0_journey_loads_an_external_page(self):
        for path in sorted((HERE / "journeys").rglob("*.json")):
            text = path.read_text()
            self.assertNotIn('"text": "example.com"', text, path.name)
            self.assertNotIn('"Example Domain"', text, path.name)


class ShownDrawsWithin(unittest.TestCase):
    """window-uncover-draws times the first frame after the unpause: from the app's own show record when the
    app has one, else from 4 ms samples, as bounds."""

    def journey(self, samples, mark=10.0, show=None):
        j = D.Journey.__new__(D.Journey)
        j.marks = {"uncover": mark}
        j.frame_watches = {"w": {"pane": "pane_1", "samples": samples, "interval_ms": 4}}
        surface = {"show": show} if show is not None else {}

        class App:
            def rpc(self, method, params=None):
                return {"windows": [{"panes": [{"pane": "pane_1", "surface": surface}]}]}
        j.app = App()
        return j

    def test_the_apps_show_record_judges_when_present(self):
        show = {"unpaused_ns": 10.020e9, "first_frame_ns": 10.026e9, "unpause_to_frame_ms": 6.0}
        ok, detail = FT.cond_shown_draws_within(self.journey([], show=show), {"watch": "w", "since": "uncover"}, {})
        self.assertTrue(ok, detail)
        self.assertEqual((detail["source"], detail["key_to_unpause_ms"]), ("app", 20.0))
        late = dict(show, unpause_to_frame_ms=40.0)
        ok, _ = FT.cond_shown_draws_within(self.journey([], show=late), {"watch": "w", "since": "uncover"}, {})
        self.assertFalse(ok)

    def test_an_unpause_from_before_the_mark_is_not_this_show(self):
        show = {"unpaused_ns": 9.0e9, "first_frame_ns": 9.001e9, "unpause_to_frame_ms": 1.0}
        ok, detail = FT.cond_shown_draws_within(self.journey([], show=show), {"watch": "w", "since": "uncover"}, {})
        self.assertFalse(ok)
        self.assertIn("waiting", detail)

    @staticmethod
    def s(t, paused, frames):
        return {"t0": t, "t1": t + 0.001, "paused": paused, "occluded": False, "frames": frames}

    def test_a_draw_one_sample_after_the_unpause_holds_and_reports_bounds(self):
        samples = [self.s(10.000, "window_occluded", 54), self.s(10.004, "window_occluded", 54),
                   self.s(10.008, None, 54), self.s(10.012, None, 55)]
        ok, detail = FT.cond_shown_draws_within(self.journey(samples), {"watch": "w", "since": "uncover"}, {})
        self.assertTrue(ok, detail)
        self.assertEqual(detail["frames"], [54, 55])
        self.assertEqual(detail["unpause_to_frame_ms"], [0.0, 9.0])

    def test_a_draw_two_frames_late_fails(self):
        samples = [self.s(10.000, "window_occluded", 54), self.s(10.004, None, 54), self.s(10.040, None, 55)]
        ok, detail = FT.cond_shown_draws_within(self.journey(samples), {"watch": "w", "since": "uncover"}, {})
        self.assertFalse(ok)
        self.assertGreater(detail["unpause_to_frame_ms"][1], 16.7)

    def test_a_pane_never_paused_after_the_mark_measures_nothing(self):
        ok, detail = FT.cond_shown_draws_within(self.journey([self.s(10.0, None, 54), self.s(10.004, None, 55)]),
                                                {"watch": "w", "since": "uncover"}, {})
        self.assertFalse(ok)
        self.assertIn("error", detail)


class ComposerText(unittest.TestCase):
    """scripted-newtab-keeps-person-keys reads the composer's text from the app, not from OCR."""

    def journey(self, answer):
        class App:
            def rpc(self, method, params=None):
                assert (method, params) == ("debug.home.drive", {"action": "field"})
                if isinstance(answer, Exception):
                    raise answer
                return answer
        j = D.Journey.__new__(D.Journey)
        j.app = App()
        return j

    def test_the_app_read_judges_the_text(self):
        ok, detail = EH.cond_composer_text(self.journey({"ok": True, "text": "keep-1-more-1", "focused": True}), "keep-1-more-1", {})
        self.assertTrue(ok)
        ok, _ = EH.cond_composer_text(self.journey({"ok": True, "text": "keep-1", "focused": True}), "keep-1-more-1", {})
        self.assertFalse(ok)

    def test_an_app_without_the_read_falls_back_to_the_frame_and_says_so(self):
        j = self.journey(D.StepError("debug.home.drive: action must be focus, type, send"))
        j.evaluate = lambda name, want, cache: (name == "frame_text", {"image": "check-01.png"})
        ok, detail = EH.cond_composer_text(j, "keep-1-more-1", {})
        self.assertTrue(ok)
        self.assertIn("fallback", detail)


if __name__ == "__main__":
    unittest.main()
