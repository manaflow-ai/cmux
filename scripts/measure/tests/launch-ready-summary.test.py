#!/usr/bin/env python3
"""launch-ready-summary.py judges each restore case against its expectation, prints LR-SURFACE per side and
LR-SURFACE-DIFF when an A/B's arms first showed different surfaces.

    python3 scripts/measure/tests/launch-ready-summary.test.py
"""

import contextlib
import importlib.util
import io
from pathlib import Path
import unittest

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("launch_ready_summary", HERE.parent / "launch-ready-summary.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

TAB = {"workspace": "wk-1", "tab": "tab_a", "page": "terminal", "home": False, "top_page": None, "windows": 1}
OTHER_TAB = dict(TAB, tab="tab_b")
HOME = {"workspace": "wk-1", "tab": "tab_h", "page": "home-dock", "home": True, "top_page": None, "windows": 1}
HOME_MARKS = {"home.first_page": 300.0, "reveal.home": 290.0, "window_usable": 400.0}
TAB_MARKS = {"reveal.tabs": 200.0, "reveal.pane": 210.0, "launch_snapshot_shown": 150.0}


def row(side, label, front=None, marks=None, first=None, **extra):
    r = {"side": side, "label": label, "window_on_screen": 100.0, "finished_launching": 90.0, "marks": dict(marks or {}),
         "first_reveal": first}
    if front is not None:
        r["front"] = front
    r.update(extra)
    return r


def run(rows, case="kept", seeded=""):
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        result = module.summarize(rows, case, seeded)
    return result, out.getvalue().splitlines()


class CaseNameTests(unittest.TestCase):
    def test_names(self):
        self.assertEqual(module.case_name("bare"), "fresh")
        self.assertEqual(module.case_name("fresh"), "fresh")
        self.assertEqual(module.case_name("kept"), "kept")
        self.assertEqual(module.case_name("kept", case="update"), "update")
        self.assertEqual(module.case_name("kept", daemon="cold"), "cold")
        self.assertEqual(module.case_name("kept", daemon="cold", snapshot="unknown"), "unknown")
        self.assertEqual(module.case_name("kept", snapshot="foreign"), "foreign")

    def test_expectations_in_one_table(self):
        self.assertEqual(module.EXPECT, {"fresh": "home", "kept": "last", "update": "last", "cold": "last",
                                         "foreign": "own", "unknown": "home"})


class ReopenTests(unittest.TestCase):
    def test_state_kept_reopens_the_last_workspace_and_tab(self):
        result, lines = run([row("head", "prime", TAB), row("head", "run1", TAB, TAB_MARKS, "tabs"),
                             row("head", "run2", TAB, TAB_MARKS, "tabs")])
        self.assertEqual(result["head"]["failed"], [])
        self.assertIn("LR-REOPENED head 2/2 case=kept", lines)

    def test_home_when_last_front_was_a_tab_fails(self):
        result, lines = run([row("head", "prime", TAB), row("head", "run1", HOME, HOME_MARKS, "home")])
        self.assertEqual(result["head"]["failed"], ["run1"])
        self.assertTrue(any("landed on Home, last front was workspace=wk-1 tab=tab_a" in l for l in lines))

    def test_other_tab_fails(self):
        result, _ = run([row("head", "prime", TAB), row("head", "run1", OTHER_TAB, TAB_MARKS, "tabs")])
        self.assertEqual(result["head"]["failed"], ["run1"])

    def test_tab_when_last_front_was_home_fails_and_home_passes(self):
        result, lines = run([row("head", "prime", HOME), row("head", "run1", TAB, TAB_MARKS, "tabs"),
                             row("head", "run2", HOME, HOME_MARKS, "home")])
        # run2's last front is run1's tab: Home there fails too (the launch reopens exactly where it was).
        self.assertEqual(result["head"]["failed"], ["run1", "run2"])
        self.assertTrue(any("last front was Home" in l for l in lines))
        result, _ = run([row("head", "prime", HOME), row("head", "run1", HOME, HOME_MARKS, "home")])
        self.assertEqual(result["head"]["failed"], [])

    def test_top_page_home_counts_as_home(self):
        legacy = {"workspace": "wk-1", "tab": "tab_x", "top_page": "home", "windows": 1}
        result, _ = run([row("head", "prime", legacy), row("head", "run1", dict(legacy, tab="tab_y"), HOME_MARKS, "home")])
        self.assertEqual(result["head"]["failed"], [])

    def test_state_kept_front_home_reopens_home(self):
        rows = [row("head", "prime", HOME), row("head", "run1", TAB, TAB_MARKS, "tabs"),
                row("head", "run2", HOME, HOME_MARKS, "home")]
        result, _ = run(rows, "kept", "home")
        self.assertEqual(result["head"]["failed"], ["run1"])  # run2 is judged against the seeded Home, not run1

    def test_seed_that_did_not_take_fails_prime(self):
        result, lines = run([row("head", "prime", TAB), row("head", "run1", TAB, TAB_MARKS, "tabs")], "kept", "home")
        self.assertIn("prime", result["head"]["failed"])
        self.assertTrue(any("front=home not seeded" in l for l in lines))
        self.assertIn("LR-REOPENED head 1/1 case=kept", lines)

    def test_state_kept_case_update_reopens_the_last_workspace_and_tab(self):
        rows = [row("head", "prime", HOME), row("head", "old1", TAB), row("head", "run1", TAB, TAB_MARKS, "tabs"),
                row("head", "old2", TAB), row("head", "run2", HOME, HOME_MARKS, "home")]
        result, _ = run(rows, "update")
        self.assertEqual(result["head"]["failed"], ["run2"])

    def test_state_kept_daemon_cold_reopens_the_last_workspace_and_tab(self):
        result, _ = run([row("head", "prime", TAB), row("head", "run1", HOME, HOME_MARKS, "home")], "cold")
        self.assertEqual(result["head"]["failed"], ["run1"])

    def test_state_kept_snapshot_unknown_lands_on_home(self):
        result, _ = run([row("head", "prime", TAB), row("head", "run1", HOME, HOME_MARKS, "home"),
                         row("head", "run2", TAB, TAB_MARKS, "tabs")], "unknown")
        self.assertEqual(result["head"]["failed"], ["run2"])

    def test_state_kept_snapshot_foreign_draws_no_foreign_windows_then_reopens_its_own(self):
        rows = [row("head", "prime", TAB), row("foreign-head", "prime", OTHER_TAB),
                row("head", "run1", TAB, {"reveal.tabs": 1.0}, "tabs"),
                row("head", "run2", TAB, TAB_MARKS, "tabs")]
        result, lines = run(rows, "foreign")
        self.assertNotIn("foreign-head", result)
        self.assertEqual(result["head"]["failed"], ["run2"])
        self.assertTrue(any("foreign launch snapshot" in l for l in lines))

    def test_state_fresh_lands_on_home(self):
        rows = [row("head", "prime"), row("head", "run1", TAB, HOME_MARKS, "home"),
                row("head", "run2", TAB, dict(HOME_MARKS, **TAB_MARKS), "tabs"), row("head", "run3", None, {}, None)]
        result, lines = run(rows, "fresh")
        # run1's front is the terminal the probe opens after Home takes keys: not a failure.
        self.assertEqual(result["head"]["failed"], ["run2", "run3"])
        self.assertTrue(any("on a tab with no saved state" in l for l in lines))

    def test_cross_arm_fails(self):
        result, _ = run([row("head", "prime", TAB), row("head", "run1", TAB, TAB_MARKS, "tabs", cross_arm={"x": 1})])
        self.assertEqual(result["head"]["failed"], ["run1"])

    def test_no_readable_front_before_is_a_skip_outside_n_of_m(self):
        rows = [row("head", "prime", {"error": "no reply"}), row("head", "run1", TAB, TAB_MARKS, "tabs"),
                row("head", "run2", TAB, TAB_MARKS, "tabs")]
        result, lines = run(rows)
        self.assertEqual(result["head"]["failed"], [])
        self.assertIn("LR-REOPENED head 1/1 (1 skipped) case=kept", lines)
        self.assertTrue(any(l.startswith("LR-SKIP head run1 prime left no readable front: no reply") for l in lines))

    def test_the_stress3_seeds_own_front_file_fills_its_row(self):
        import json
        import tempfile
        with tempfile.TemporaryDirectory() as out:
            Path(out, "seed-head.front.json").write_text(json.dumps(TAB))
            rows = [row("head", "seed", {"error": "quit by the seed"}), row("head", "run1", TAB, TAB_MARKS, "tabs")]
            module.fill_seed_fronts(rows, out)
        self.assertEqual(rows[0]["front"], TAB)
        result, lines = run(rows)
        self.assertEqual(result["head"]["failed"], [])
        self.assertIn("LR-REOPENED head 1/1 case=kept", lines)


class SurfaceTests(unittest.TestCase):
    def test_surface_line_and_diff(self):
        rows = [row("base", "prime", HOME), row("head", "prime", HOME)]
        for i in range(1, 11):
            rows.append(row("base", f"run{i}", HOME, HOME_MARKS, "home"))
            rows.append(row("head", f"run{i}", TAB, TAB_MARKS if i > 1 else HOME_MARKS, "tabs" if i > 1 else "home"))
        result, lines = run(rows)
        self.assertIn("LR-SURFACE base first=home home_page_drawn=10/10 mix=home:10", lines)
        self.assertIn("LR-SURFACE head first=tabs home_page_drawn=1/10 mix=home:1,tabs:9", lines)
        self.assertIn("LR-SURFACE-DIFF base first=home head first=tabs: not like for like", lines)
        self.assertEqual(result["head"]["surface"], "tabs")

    def test_like_for_like_prints_no_diff(self):
        rows = [row("base", "prime", HOME), row("head", "prime", HOME), row("base", "run1", HOME, HOME_MARKS, "home"),
                row("head", "run1", HOME, HOME_MARKS, "home")]
        _, lines = run(rows)
        self.assertFalse(any(l.startswith("LR-SURFACE-DIFF") for l in lines))

    def test_first_surface_without_reveal(self):
        self.assertEqual(module.first_surface({"marks": {"launch_snapshot_shown": 1}}), "tabs")
        self.assertEqual(module.first_surface({"marks": {"home.first_page": 1}}), "home")
        self.assertEqual(module.first_surface({"marks": {}}), "none")


def layout(window_moved, window_changes, sidebar_moved=None, sidebar_changes=0):
    def part(moved, changes):
        if moved is None:
            return {"first": None, "last": None, "moved_pt": 0.0, "changes": 0}
        return {"first": [0.0], "last": [moved], "moved_pt": moved, "changes": changes}
    return {"window": part(window_moved, window_changes), "sidebar": part(sidebar_moved, sidebar_changes),
            "samples": 60, "complete": True}


class FramesTests(unittest.TestCase):
    def test_layout_rows_print_lr_frames_per_side(self):
        rows = [row("head", "prime", TAB, layout=layout(50.0, 1, 60.0, 1)),
                row("head", "run1", TAB, TAB_MARKS, "tabs", layout=layout(0.0, 0, 60.0, 2)),
                row("head", "run2", TAB, TAB_MARKS, "tabs", layout=layout(120.0, 3, 0.0, 0))]
        _, lines = run(rows)
        frames = [l for l in lines if l.startswith("LR-FRAMES head ")]
        self.assertEqual(len(frames), 1)
        data = module.json.loads(frames[0].split(" ", 2)[2])
        self.assertEqual(data["n"], 2)  # the priming launch is not measured
        self.assertEqual(data["window"]["moved_pt"], [0.0, 120.0])
        self.assertEqual(data["window"]["max_moved_pt"], 120.0)
        self.assertEqual(data["window"]["median_changes"], 1.5)
        self.assertEqual(data["window"]["launches_that_moved"], "1/2")
        self.assertEqual(data["sidebar"]["median_moved_pt"], 30.0)

    def test_a_release_build_has_no_sidebar_reading(self):
        _, lines = run([row("head", "prime", TAB), row("head", "run1", TAB, TAB_MARKS, "tabs", layout=layout(0.0, 0))])
        data = module.json.loads(next(l for l in lines if l.startswith("LR-FRAMES")).split(" ", 2)[2])
        self.assertEqual(data["sidebar"], {"n": 0, "moved_pt": [], "changes": [], "median_moved_pt": None,
                                           "max_moved_pt": None, "median_changes": None, "launches_that_moved": "0/0"})

    def test_no_layout_no_line(self):
        _, lines = run([row("head", "prime", TAB), row("head", "run1", TAB, TAB_MARKS, "tabs")])
        self.assertFalse(any(l.startswith("LR-FRAMES") for l in lines))


if __name__ == "__main__":
    unittest.main()
