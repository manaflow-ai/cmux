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
        # Every launch is judged against the priming launch's Home: run1's tab fails, run2's Home passes.
        self.assertEqual(result["head"]["failed"], ["run1"])
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

    def test_unreadable_prime_front_leaves_a_kept_arm_not_judged(self):
        # Comparing with the launch before instead would be the blind spot the prime anchor closes.
        rows = [row("head", "prime", {"error": "no reply"}), row("head", "run1", TAB, TAB_MARKS, "tabs"),
                row("head", "run2", TAB, TAB_MARKS, "tabs")]
        result, lines = run(rows)
        self.assertFalse(result["head"]["judged"])
        self.assertIn("LR-REOPENED head not-judged: prime front unreadable: no reply case=kept", lines)
        self.assertIn("LR-SAME-FRONT invalid: head not judged", lines)
        self.assertFalse(any(l.startswith("LR-SKIP") for l in lines))

    def test_unreadable_seed_front_leaves_the_arm_not_judged(self):
        rows = [row("head", "prime", TAB), row("head", "seed", {"error": "quit by the seed"}),
                row("head", "run1", TAB, TAB_MARKS, "tabs")]
        result, lines = run(rows)
        self.assertFalse(result["head"]["judged"])
        self.assertIn("LR-REOPENED head not-judged: seed front unreadable: quit by the seed case=kept", lines)

    def test_case_update_keeps_the_skip_for_an_unreadable_launch_before(self):
        rows = [row("head", "prime", TAB), row("head", "old1", {"error": "no reply"}),
                row("head", "run1", TAB, TAB_MARKS, "tabs")]
        result, lines = run(rows, "update")
        self.assertEqual(result["head"]["failed"], [])
        self.assertIn("LR-REOPENED head 0/0 (1 skipped) case=update", lines)
        self.assertTrue(any(l.startswith("LR-SKIP head run1 old1 left no readable front: no reply") for l in lines))

    def test_same_front_ok_only_when_every_arm_is_judged_and_clean(self):
        clean = [row("base", "prime", TAB), row("base", "run1", TAB, TAB_MARKS, "tabs"),
                 row("head", "prime", TAB), row("head", "run1", TAB, TAB_MARKS, "tabs")]
        _, lines = run(clean)
        self.assertIn("LR-SAME-FRONT ok: base, head", lines)
        moved = clean[:2] + [row("head", "prime", TAB), row("head", "full1", OTHER_TAB),
                             row("head", "run1", TAB, TAB_MARKS, "tabs")]
        _, lines = run(moved)
        self.assertIn("LR-SAME-FRONT invalid: head failed full1", lines)

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


class PrimeAnchorTests(unittest.TestCase):
    """Every launch after the priming one is judged against the priming launch's front, the preruns included."""

    def test_recorded_front_change_at_the_first_prerun_fails_every_launch(self):
        # cmux#44491's drop-one, head arm (launch-ready on cmux17, 2026-11-18): the prime left Home in workspace
        # 1b6a8f6d tab 1644489e; the first relaunch (full1) opened a new workspace a30987fb tab 78f29802 and every
        # launch after reopened that one. Compared with the launch before, it read "LR-REOPENED head 5/5".
        prime = {"workspace": "1b6a8f6d", "tab": "1644489e", "page": "home-dock", "home": True, "top_page": None,
                 "windows": 1}
        moved = {"workspace": "a30987fb", "tab": "78f29802", "page": "agent-newtab", "home": False, "top_page": None,
                 "windows": 1}
        rows = [row("head", "prime", prime, HOME_MARKS, "home")]
        for i in range(1, 6):
            rows += [row("head", f"full{i}", moved, TAB_MARKS, "tabs"), row("head", f"run{i}", moved, TAB_MARKS, "tabs")]
        result, lines = run(rows)
        self.assertEqual(result["head"]["failed"], ["run1", "run2", "run3", "run4", "run5"] +
                         ["full1", "full2", "full3", "full4", "full5"])
        self.assertIn("LR-REOPENED head 0/5 (front changed at full1,full2,full3,full4,full5) case=kept", lines)
        self.assertTrue(any(l.startswith("LR-FAIL head full1 landed on workspace=a30987fb tab=78f29802") for l in lines))

    def test_a_prerun_that_changes_the_front_and_back_fails_the_arm(self):
        rows = [row("head", "prime", TAB), row("head", "full1", TAB), row("head", "run1", TAB, TAB_MARKS, "tabs"),
                row("head", "full2", OTHER_TAB), row("head", "run2", TAB, TAB_MARKS, "tabs")]
        result, lines = run(rows)
        self.assertEqual(result["head"]["failed"], ["full2"])
        self.assertIn("LR-REOPENED head 2/2 (front changed at full2) case=kept", lines)

    def test_home_in_front_without_homes_page_fails_when_the_prime_drew_it(self):
        rows = [row("head", "prime", HOME, HOME_MARKS, "home"), row("head", "run1", HOME, {"reveal.tabs": 1.0}, "tabs")]
        result, lines = run(rows)
        self.assertEqual(result["head"]["failed"], ["run1"])
        self.assertTrue(any("Home's page did not draw" in l for l in lines))

    def test_the_stress3_seed_moves_the_anchor(self):
        rows = [row("head", "prime", HOME, HOME_MARKS, "home"), row("head", "seed", TAB),
                row("head", "full1", TAB), row("head", "run1", TAB, TAB_MARKS, "tabs")]
        result, _ = run(rows)
        self.assertEqual(result["head"]["failed"], [])

    def test_case_update_still_compares_with_the_launch_before(self):
        rows = [row("head", "prime", HOME), row("head", "old1", TAB), row("head", "run1", TAB, TAB_MARKS, "tabs")]
        result, _ = run(rows, "update")
        self.assertEqual(result["head"]["failed"], [])


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


if __name__ == "__main__":
    unittest.main()
