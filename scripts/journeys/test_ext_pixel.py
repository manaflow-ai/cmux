#!/usr/bin/env python3
"""ext_pixel.py's steps against a fake app socket (no fleet, no app), and the pixel cases' journey files.

    python3 scripts/journeys/test_ext_pixel.py

px_springs: every motion.spring.* response set to its default / speed, damping kept, read back; Reduce Motion; the
reset. px_record_start: scan rows and columns at 0.3 and 0.7 of every pane (device px, inside the recorder's frame and
its scan budget) and the judge's note (pane ids, kinds, fills, the declared spring after the scale). px_page: the
openBrowser action with the fixture URL and the page's own report. px_agent_css: theme.css beside the settings file.
gen_pixel.py: every journey validates (run.py), stays in one lease and names each recording once.
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


class FakeApp:
    """The control socket of a DEBUG build with two panes (p0 terminal, p1 page) in one 1200 x 800 pt window at 2x."""

    def __init__(self, active=True):
        self.active, self.overrides, self.calls, self.motion = active, {}, [], {}
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
                return {"available": True, "active": self.active}
            key = params.get("key", "")
            if action == "reset":
                self.overrides.clear()
                return {"active": self.active}
            if key.startswith("motion.spring."):
                r, d = self.default(key.split(".")[-1])
                default = {"response": r, "dampingFraction": d}
                if action == "set":
                    value = params.get("value")
                    if value is None or value == default:
                        self.overrides.pop(key, None)
                    else:
                        self.overrides[key] = value
                return {"key": key, "value": self.overrides.get(key, default), "default": default, "changed": key in self.overrides}
            if key == "browserResize.pageBackdrop":
                if action == "set":
                    self.overrides[key] = params.get("value")
                return {"key": key, "value": self.overrides.get(key, True) if self.overrides.get(key) is not None else True,
                        "default": True, "changed": key in self.overrides}
            return {"error": "unknown key"}
        if method == "debug.motion":
            self.motion[params.get("action")] = params.get("value")
            return {"reduce_motion": bool(self.motion.get("reduce")), "speed": self.motion.get("speed", "fast")}
        if method == "debug.pane_chrome":
            return {"windows": [{"id": "w1", "scale": 2.0, "panes": [
                {"pane": "pane-a", "cell": [0, 40, 600, 760], "border": [4, 70, 592, 726]},
                {"pane": "pane-b", "cell": [601, 40, 599, 760], "border": [605, 70, 591, 726]}]}]}
        if method == "debug.layers":
            return {"windows": [{"frame": [100, 50, 1200, 800], "screen_frame": [0, 0, 1512, 982]}]}
        if method == "debug.surfaces":
            return {"windows": [{"window": 1, "panes": [
                {"pane": "pane-a", "focused": False, "kind": "terminal"},
                {"pane": "pane-b", "focused": True, "kind": "browser", "selected_tab": "tab-b",
                 "url": "file:///private/tmp/jr-pixel-page.html?bg=00FF00&label=p1"}]}]}
        if method == "action.run":
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

    def config_file(self):
        return os.path.join(self.config_dir, "cmux-next.json")


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

    def test_springs_not_run_without_the_tunable_store(self):
        self.app.active = False
        with self.assertRaises(D.NotRun):
            X.step_px_springs(self.j, {"speed": 2})

    def test_record_start_lines_and_note(self):
        X.step_px_springs(self.j, {"speed": 0.5})
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
        # Rows at 0.3 and 0.7 of the panes' height (both panes share them), columns at 0.3 and 0.7 of each one's width.
        self.assertEqual(started["rows"], [576, 1156])
        self.assertEqual(started["columns"], [363, 837, 1565, 2037])
        self.assertEqual(started["require_hz"], 120)
        note = self.j.video["notes"]["pixel"]
        self.assertEqual(note["panes"], {"pane-a": {"kind": "tui", "agent": False, "fill": "#FFFF00", "label": "p0"},
                                         "pane-b": {"kind": "page", "agent": False, "fill": "#00FF00", "label": "p1"}})
        self.assertEqual(note["spring"], {"token": "split", "response": 0.46, "damping": 0.95})
        self.assertEqual(note["speed"], 0.5)
        # The recorder's frame: from the window's top-left (132 pt below the screen's top) to the screen's right and bottom.
        self.assertEqual(note["frame"], [2824, 1700])
        self.assertEqual(out["dropped_lines"], 0)

    def test_scan_budget_drops_lines(self):
        rects = [[0, 0, 300, 400], [300, 0, 300, 400], [600, 0, 300, 400]]
        rows, cols, dropped, used = X.scan_lines(rects, 2.0, 3024, 1964, 60.0)
        self.assertLessEqual(used, X.SCAN_BUDGET)
        self.assertGreater(dropped, 0)
        self.assertTrue(rows, "the first fraction's row comes first")

    def test_page_opens_the_fixture(self):
        out = X.step_px_page(self.j, {"pane": "p1", "bg": "#00FF00", "label": "p1", "timeout": 5})
        run = next(p for m, p in self.app.calls if m == "action.run")
        self.assertEqual(run["action"], "openBrowser")
        self.assertEqual(run["args"]["url"], "file:///tmp/jr-pixel-page.html?bg=00FF00&label=p1")
        self.assertEqual(run["args"]["engine"], "cef")
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
            self.assertGreaterEqual(len(specs), 14)
            names = [n for s in specs for n in s["recordings"]]
            self.assertEqual(len(names), len(set(names)))
            labels = {n.rsplit("-", 1)[1] for n in names}
            self.assertEqual(labels, {"s025", "s05", "s1", "s2", "s4", "reduce"})
            for s in specs:
                self.assertLessEqual(s["budget_seconds"], 250, s["id"])
                starts = [st for st in s["steps"] if st["do"] == "px_record_start"]
                self.assertEqual([st["name"] for st in starts], s["recordings"])
                self.assertTrue(all(st["require_hz"] == 120 for st in starts))
                last = [st for st in s["steps"] if st["do"] == "expect"][-1]
                kinds = {D.KIND[next(iter(c))] for c in last["all"]}
                self.assertEqual(kinds, {"app", "daemon", "frame"}, s["id"])
                self.assertEqual([st["do"] for st in s["finally"]], ["px_springs", "px_tunable", "px_agent_css", "settings_file"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
