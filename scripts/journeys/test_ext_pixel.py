#!/usr/bin/env python3
"""ext_pixel.py's steps against a fake app socket (no fleet, no app), and the pixel cases' journey files.

    python3 scripts/journeys/test_ext_pixel.py

px_film / px_springs: every motion.spring.* response set to its default / speed, damping kept, read back; Reduce Motion;
the reset. With the tunable store inactive (a Release build with bench hooks, cmux22 2026-11-03): `debug.tunables
activate` when the build has it; else the x1 and Reduce Motion films play and every other speed is one "not run" line,
the journey goes on. px_tunable records a value that did not take (the page backdrop stays on). px_record_start: a scan
row through every tab strip first, then rows and columns at 0.3 and 0.7 of every pane (device px, inside the recorder's
frame and its scan budget), and the judge's note. px_page: the openBrowser action takes url and engine only (the app
refuses any other argument: "openBrowser has no argument 'focus'", cmux22 2026-11-03) and the page's own report.
px_agent_css: theme.css beside the settings file. gen_pixel.py: every journey validates (run.py), stays in one lease,
names each film once; the x1 + Reduce Motion journeys fit three to a lease.
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
import driver as D  # noqa: E402  (loads ext_*.py: ext_pixel installs with it)
import ext_pixel as X  # noqa: E402

DEFAULTS = {"move": (0.15, 1.0), "split": (0.23, 0.95), "scroll": (0.2, 0.9), "pinDrag": (0.215, 0.8385254915624211)}
OPEN_BROWSER_ARGS = ("url", "engine", "profile")


class FakeApp:
    """The control socket of a bench build with two panes (p0 terminal, p1 page) in one 1200 x 800 pt window at 2x.
    active: the tunable store takes overrides; activate: the build has `debug.tunables activate`."""

    def __init__(self, active=True, activate=False):
        self.active, self.can_activate, self.overrides, self.calls, self.motion = active, activate, {}, [], {}
        self.page_reads = 0
        self.pid = 4242

    def default(self, token):
        return DEFAULTS.get(token, (0.2, 0.9))

    def rpc(self, method, params=None, timeout=None):
        params = params or {}
        self.calls.append((method, params))
        if method == "debug.tunables":
            action = params.get("action")
            if action == "state":
                return {"available": self.active, "active": self.active}
            if action == "activate":
                if not self.can_activate:
                    raise D.StepError("debug.tunables: unknown action")  # App.rpc raises on a result's error
                self.active = True
                return {"available": True, "active": True}
            key = params.get("key", "")
            if action == "reset":
                self.overrides.clear()
                return {"active": self.active}
            if key.startswith("motion.spring."):
                r, d = self.default(key.split(".")[-1])
                default = {"response": r, "dampingFraction": d}
                if action == "set" and self.active:
                    value = params.get("value")
                    if value is None or value == default:
                        self.overrides.pop(key, None)
                    else:
                        self.overrides[key] = value
                return {"key": key, "value": self.overrides.get(key, default), "default": default, "changed": key in self.overrides}
            if key == "browserResize.pageBackdrop":
                if action == "set" and self.active:
                    if params.get("value") is None:
                        self.overrides.pop(key, None)
                    else:
                        self.overrides[key] = params["value"]
                return {"key": key, "value": self.overrides.get(key, True), "default": True, "changed": key in self.overrides}
            raise D.StepError("debug.tunables: unknown key")
        if method == "debug.motion":
            self.motion[params.get("action")] = params.get("value")
            return {"reduce_motion": bool(self.motion.get("reduce")), "speed": self.motion.get("speed", "fast")}
        if method == "debug.pane_chrome":
            return {"windows": [{"id": "w1", "scale": 2.0, "panes": [
                {"pane": "pane-a", "cell": [0, 40, 600, 760], "border": [4, 70, 592, 726], "strip": [4, 40, 592, 28],
                 "pill": [10, 44, 200, 20], "strip_hidden": False},
                {"pane": "pane-b", "cell": [601, 40, 599, 760], "border": [605, 70, 591, 726], "strip": [605, 40, 591, 28],
                 "pill": [611, 44, 200, 20], "strip_hidden": False}]}]}
        if method == "debug.layers":
            return {"windows": [{"frame": [100, 50, 1200, 800], "screen_frame": [0, 0, 1512, 982]}]}
        if method == "debug.surfaces":
            return {"windows": [{"window": 1, "panes": [
                {"pane": "pane-a", "focused": False, "kind": "terminal"},
                {"pane": "pane-b", "focused": True, "kind": "browser", "selected_tab": "tab-b",
                 "url": "file:///private/tmp/jr-pixel-page.html?bg=00FF00&label=p1"}]}]}
        if method == "action.run":
            unknown = sorted(set(params.get("args") or {}) - set(OPEN_BROWSER_ARGS)) if params.get("action") == "openBrowser" else []
            if unknown:
                raise D.StepError("action.run: {'code': 'invalid_params', 'data': {'not_run': True, 'valid': ['url', 'engine', "
                                  f"'profile']}}, 'message': \"openBrowser has no argument '{unknown[0]}'\"}}")
            return {"ok": True}
        if method == "browser.page.eval":
            self.page_reads += 1
            return {"value": {"w": 591, "h": 696, "dpr": 2, "raf": 10 * self.page_reads, "bg": "#00FF00"}}
        raise AssertionError(f"unexpected rpc {method} {params}")

    def cmux(self, *args):
        self.calls.append(("cmux", args))
        return {"ok": True}


class FakeJourney:
    def __init__(self, app, config_dir):
        self.app, self.marks, self.config_dir = app, {}, config_dir
        self.ext_panes = {"p0": {"pane": "pane-a", "term": "t-a", "host_pid": 1, "window": "w1"},
                          "p1": {"pane": "pane-b", "term": "t-b", "host_pid": 1, "window": "w1"}}
        self.video = None
        self.played = []

    def config_file(self):
        return os.path.join(self.config_dir, "cmux-next.json")

    def step_wait(self, step):  # the sub-steps a px_film plays (the driver's own handlers in a journey)
        self.played.append(step.get("title"))
        return {}


def film(name, speed=None, reduce=False):
    step = {"do": "px_film", "name": name, "steps": [{"do": "wait", "seconds": 0, "title": f"{name} play"}],
            "after": [{"do": "wait", "seconds": 0, "title": f"{name} rebuild"}]}
    step.update({"reduce": True} if reduce else {"speed": speed})
    return step


class ExtPixelTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="ext-pixel-")
        self.app = FakeApp()
        self.j = FakeJourney(self.app, self.tmp)

    def test_springs_scale_every_response(self):
        out = X.step_px_springs(self.j, {"speed": 0.25})
        self.assertEqual(len(out["keys"]), 16)
        self.assertEqual(self.app.overrides["motion.spring.move"], {"response": 0.6, "dampingFraction": 1.0})
        self.assertEqual(self.app.overrides["motion.spring.split"], {"response": 0.92, "dampingFraction": 0.95})
        self.assertEqual(self.app.overrides["motion.spring.pinDrag"]["dampingFraction"], 0.8385254915624211)
        self.assertEqual(self.app.motion["speed"], "fast")
        self.assertIs(self.app.motion["reduce"], False)
        self.assertEqual(self.j.px["springs"]["move"]["damping"], 1.0)
        X.step_px_springs(self.j, {"speed": 4})
        self.assertAlmostEqual(self.app.overrides["motion.spring.split"]["response"], 0.0575)
        X.step_px_springs(self.j, {"speed": 1})
        self.assertEqual(self.app.overrides, {})  # a value equal to the default resets the key
        X.step_px_springs(self.j, {"reduce": True})
        self.assertIs(self.app.motion["reduce"], True)
        self.assertEqual(self.j.px["reduce"], True)
        X.step_px_springs(self.j, {"reset": True})
        self.assertIsNone(self.app.motion["reduce"])

    def test_films_with_the_store_active(self):
        out = [X.step_px_film(self.j, film("f-s025", 0.25)), X.step_px_film(self.j, film("f-reduce", reduce=True))]
        self.assertEqual([o["status"] for o in out], ["recorded", "recorded"])
        self.assertEqual(self.j.played, ["f-s025 play", "f-s025 rebuild", "f-reduce play", "f-reduce rebuild"])
        self.assertEqual([f["film"] for f in self.j.px["films"]], ["f-s025", "f-reduce"])
        self.assertEqual(self.j.px["springs_source"], "defaults")

    def test_store_inactive_plays_x1_and_reduce_only(self):
        self.app.active = False
        out = {s: X.step_px_film(self.j, film(f"f-{s}", speed)) for s, speed in (("s025", 0.25), ("s1", 1.0), ("s4", 4.0))}
        out["reduce"] = X.step_px_film(self.j, film("f-reduce", reduce=True))
        self.assertEqual({k: v["status"] for k, v in out.items()},
                         {"s025": "not run", "s1": "recorded", "s4": "not run", "reduce": "recorded"})
        self.assertTrue(out["s025"]["reason"].startswith("not run: tunable store inactive"), out["s025"]["reason"])
        self.assertEqual(self.j.played, ["f-s1 play", "f-s1 rebuild", "f-reduce play", "f-reduce rebuild"])
        self.assertEqual(self.app.overrides, {})
        self.assertIs(self.app.motion["reduce"], True)
        self.assertEqual(sum(1 for m, p in self.app.calls if m == "debug.tunables" and p.get("action") == "activate"), 1)
        with self.assertRaises(D.NotRun):
            X.step_px_springs(self.j, {"speed": 2})

    def test_activate_turns_the_store_on(self):
        self.app = FakeApp(active=False, activate=True)
        self.j = FakeJourney(self.app, self.tmp)
        out = X.step_px_film(self.j, film("f-s05", 0.5))
        self.assertEqual(out["status"], "recorded")
        self.assertTrue(self.j.px["store"]["activated"])
        self.assertEqual(self.app.overrides["motion.spring.move"], {"response": 0.3, "dampingFraction": 1.0})

    def test_backdrop_that_did_not_take_is_recorded(self):
        self.app.active = False
        out = X.step_px_tunable(self.j, {"key": "browserResize.pageBackdrop", "value": False})
        self.assertFalse(out["applied"])
        self.assertIs(out["value"], True)
        self.assertIn("tunable store inactive", out["why"])
        self.app.active = True
        self.j = FakeJourney(self.app, self.tmp)
        out = X.step_px_tunable(self.j, {"key": "browserResize.pageBackdrop", "value": False})
        self.assertTrue(out["applied"])
        self.assertTrue(X.step_px_tunable(self.j, {"key": "browserResize.pageBackdrop", "value": None})["applied"])

    def test_record_start_lines_and_note(self):
        X.step_px_springs(self.j, {"speed": 0.5})
        self.app.overrides["browserResize.pageBackdrop"] = False
        started = {}

        def fake_start(j, step):
            started.update(step)
            j.video = {"notes": {}}
            return {"refresh_ms": 8.33}

        real, X.V.step_video_start = X.V.step_video_start, fake_start
        try:
            out = X.step_px_record_start(self.j, {"name": "px-x-s05", "seconds": 8, "require_hz": 120, "spring": "split",
                                                   "input": "keys", "fixture": {"p0": {"kind": "tui", "fill": "#FFFF00"},
                                                                                "p1": {"kind": "page", "fill": "#00FF00"}}})
        finally:
            X.V.step_video_start = real
        # The strip row (both strips: y 40 + 28 / 2 = 54 pt), then rows at 0.3 and 0.7 of the panes' height (shared), and
        # columns at 0.3 and 0.7 of each one's width.
        self.assertEqual(started["rows"], [108, 576, 1156])
        self.assertEqual(started["columns"], [363, 837, 1565, 2037])
        self.assertEqual(out["strip_rows"], {"pane-a": 108, "pane-b": 108})
        self.assertEqual(started["require_hz"], 120)
        note = self.j.video["notes"]["pixel"]
        self.assertEqual(note["panes"], {"pane-a": {"kind": "tui", "agent": False, "fill": "#FFFF00", "label": "p0"},
                                         "pane-b": {"kind": "page", "agent": False, "fill": "#00FF00", "label": "p1"}})
        self.assertEqual({k: note["spring"][k] for k in ("token", "response", "damping")},
                         {"token": "split", "response": 0.46, "damping": 0.95})
        self.assertEqual(note["speed"], 0.5)
        self.assertIs(note["page_backdrop"], False)
        self.assertEqual(note["lines"]["strip_rows"], {"pane-a": 108, "pane-b": 108})
        self.assertEqual(note["chrome"][1]["pill"], [611, 44, 200, 20])
        self.assertEqual(note["window_frame"], [100.0, 50.0, 1200.0, 800.0])
        # The recorder's frame: from the window's top-left (132 pt below the screen's top) to the screen's right and bottom.
        self.assertEqual(note["frame"], [2824, 1700])
        self.assertEqual(out["dropped_lines"], 0)

    def test_record_start_spring_default_when_the_store_is_inactive(self):
        self.app.active = False
        X.step_px_film(self.j, film("f-s1", 1.0))

        def fake_start(j, step):
            j.video = {"notes": {}}
            return {}

        real, X.V.step_video_start = X.V.step_video_start, fake_start
        try:
            X.step_px_record_start(self.j, {"name": "n", "seconds": 4, "spring": "move", "spring_default": {"response": 0.15, "damping": 1.0},
                                            "fixture": {"p0": {"kind": "tui", "fill": "#FFFF00"}}})
        finally:
            X.V.step_video_start = real
        note = self.j.video["notes"]["pixel"]
        self.assertEqual(note["springs_source"], "defaults (tunable store inactive)")
        self.assertEqual((note["spring"]["response"], note["spring"]["damping"]), (0.15, 1.0))
        self.assertIs(note["page_backdrop"], True)
        self.assertFalse(note["store"]["active"])

    def test_scan_budget_drops_lines(self):
        rects = [[0, 0, 300, 400], [300, 0, 300, 400], [600, 0, 300, 400]]
        rows, cols, strips, dropped, used = X.scan_lines(rects, 2.0, 3024, 1964, 60.0, strips=[[0, 0, 300, 20]])
        self.assertLessEqual(used, X.SCAN_BUDGET)
        self.assertGreater(dropped, 0)
        self.assertEqual(strips, {0: 20})
        self.assertIn(20, rows, "the strip row comes first")

    def test_page_opens_the_fixture(self):
        out = X.step_px_page(self.j, {"pane": "p1", "bg": "#00FF00", "label": "p1", "timeout": 5})
        run = next(p for m, p in self.app.calls if m == "action.run")
        self.assertEqual(run["action"], "openBrowser")
        self.assertEqual(run["args"], {"url": "file:///tmp/jr-pixel-page.html?bg=00FF00&label=p1", "engine": "cef"})
        self.assertIs(run["focus"], True)  # the run's own focus selects the new tab
        self.assertIsNone(out["navigated"])  # /private/tmp is the same page
        self.assertEqual(out["page"]["dpr"], 2)

    def test_agent_css(self):
        out = X.step_px_agent_css(self.j, {"fill": "#0000FF"})
        text = Path(out["path"]).read_text()
        self.assertEqual(out["path"], os.path.join(self.tmp, "agent-pane", "theme.css"))
        self.assertIn("background: #0000FF !important", text)
        self.assertIn("border: 1px solid #FF0000", text)
        X.step_px_agent_css(self.j, {"remove": True})
        self.assertFalse(Path(out["path"]).exists())


class PixelCasesTests(unittest.TestCase):
    def test_generated_journeys(self):
        with tempfile.TemporaryDirectory() as out:
            done = subprocess.run([sys.executable, str(HERE / "video-cases" / "gen_pixel.py"), "--out", out], capture_output=True,
                                  text=True, timeout=120)
            self.assertEqual(done.returncode, 0, done.stderr)
            import run as R
            specs = [json.loads(p.read_text()) for p in sorted(Path(out).glob("*.json"))]
            self.assertEqual({s["id"]: R.validate(s) for s in specs}, {s["id"]: [] for s in specs})
            self.assertGreaterEqual(len(specs), 22)
            names = [n for s in specs for n in s["recordings"]]
            self.assertEqual(len(names), len(set(names)))
            labels = {n.rsplit("-", 1)[1] for n in names}
            self.assertEqual(labels, {"s025", "s05", "s1", "s2", "s4", "reduce"})
            for s in specs:
                self.assertLessEqual(s["budget_seconds"], 250, s["id"])
                films = [st for st in s["steps"] if st["do"] == "px_film"]
                self.assertEqual([f["name"] for f in films], s["recordings"])
                for f in films:
                    starts = [st for st in f["steps"] if st["do"] == "px_record_start"]
                    self.assertEqual([st["name"] for st in starts], [f["name"]])
                    self.assertEqual(starts[0]["require_hz"], 120)
                    self.assertEqual(f["steps"][-1], {"do": "video_stop", "name": f["name"], "tail": 0.4,
                                                      "title": f"the motion ends; stop the recording ({f['name']})"})
                    self.assertTrue(("speed" in f) != ("reduce" in f), f)
                self.assertEqual(films[-1]["after"], [], "the last film needs no pane back")
                last = [st for st in s["steps"] if st["do"] == "expect"][-1]
                kinds = {D.KIND[next(iter(c))] for c in last["all"]}
                self.assertEqual(kinds, {"app", "daemon", "frame"}, s["id"])
                self.assertEqual([st["do"] for st in s["finally"]], ["px_springs", "px_tunable", "px_agent_css", "settings_file"])
                self.assertEqual(s["steps"][0]["set"]["appearance"]["surfaces"]["tabBar"], {"color": "#000000", "opacity": 1})
            s1r = {s["id"]: s for s in specs if s["id"].endswith("-s1r")}
            self.assertEqual(len(s1r), 11)
            self.assertTrue(all([n.rsplit("-", 1)[1] for n in s["recordings"]] == ["s1", "reduce"] for s in s1r.values()))
            for trio in (("px-keys-single-3k-s1r", "px-col-drag-2-s1r", "px-close-pane-3-s1r"),
                         ("px-window-resize-4-s1r", "px-row-drag-3r-s1r", "px-close-column-c3-s1r")):
                self.assertLessEqual(sum(s1r[i]["budget_seconds"] for i in trio), 260, trio)


if __name__ == "__main__":
    unittest.main(verbosity=2)
