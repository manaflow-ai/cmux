#!/usr/bin/env python3
"""The perf cron's decisions (scripts/cmux-next/perf-cron.py): what a tick runs, when it yields to the fleet,
what counts as a regression, and when the one issue opens, comments and closes. Pure functions only (no
network, no git). Run: python3 -I scripts/cmux-next/tests/test_perf_cron.py (not a CI job, Lawrence 2026-10-23)."""
import argparse, contextlib, datetime, importlib.util, io, json, os, tempfile, unittest, urllib.error, urllib.request
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("perf_cron", os.path.join(HERE, "..", "perf-cron.py"))
cron = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cron)
budgets_mod = cron.load_budgets_module()

T0 = datetime.datetime(2026, 10, 23, 12, 0, tzinfo=datetime.timezone.utc)
ALL = [p["name"] for p in cron.PARTS]


def at(hours):
    return T0 + datetime.timedelta(hours=hours)


def row(p95, unit="ms", floor=1.0, budget=None):
    return {"p50": p95, "p95": p95, "unit": unit, "floor": floor, "budget": budget}


LINUX_PARTS = ["diff-viewer", "web-ui"]
FLEET = [n for n in ALL if n not in ("build", *LINUX_PARTS)]


def confirm_all(state, regs, cur, run_url, t, regression):
    """confirm_regressions without the confirmation rule: every candidate regresses at once. For the tests of ranges,
    bisect, refresh and issue logic, which build a regression in one measurement (ConfirmTests test the rule)."""
    return [{**r, "confirmed": True} for r in regs], [], set()


class OneRunRule(unittest.TestCase):
    """One run opens a regression and one run closes it (RECOVER_RUNS 1): ConfirmTests test both rules."""

    def setUp(self):
        for patcher in (mock.patch.object(cron, "confirm_regressions", confirm_all), mock.patch.object(cron, "RECOVER_RUNS", 1)):
            patcher.start()
            self.addCleanup(patcher.stop)


class DecideTests(unittest.TestCase):
    def test_a_new_tip_builds_once_then_measures_the_parts_the_commit_has(self):
        state = cron.empty_state(T0)
        d = cron.decide(state, T0, "a" * 40, None, lambda sha: ["motion", "sidebar"], None)
        self.assertEqual((d["action"], d["part"], d["linux_part"]), ("part", "build", ""))
        self.assertEqual(state["current"]["parts_todo"], ["build", "motion", "sidebar"])

    def test_the_linux_part_runs_beside_the_build_and_needs_no_build_alone(self):
        state = cron.empty_state(T0)
        d = cron.decide(state, T0, "a" * 40, None, lambda sha: ALL, None)
        self.assertEqual((d["part"], d["linux_part"]), ("build", "diff-viewer"))
        state = cron.empty_state(T0)
        cron.decide(state, T0, "a" * 40, None, lambda sha: ["diff-viewer"], None)
        self.assertEqual(state["current"]["parts_todo"], ["diff-viewer"], "no Mac build for a Linux-only measurement")

    def test_nothing_new_runs_nothing(self):
        d = cron.decide(cron.empty_state(T0), T0, None, None, lambda sha: ALL, None)
        self.assertEqual(d["action"], "none")

    def test_a_busy_github_fleet_holds_the_mac_parts_but_not_the_linux_part(self):
        state = cron.empty_state(T0)
        d = cron.decide(state, T0, "a" * 40, None, lambda sha: FLEET, "nightly.yml waits for a runner")
        self.assertEqual(d["action"], "none")
        self.assertTrue(d["yielded"])
        self.assertIsNotNone(state["current"])
        state = cron.empty_state(T0)
        d = cron.decide(state, T0, "a" * 40, None, lambda sha: ALL, "nightly.yml waits for a runner")
        self.assertEqual((d["action"], d["part"], d["linux_part"]), ("part", "", "diff-viewer"))

    def test_the_measurement_in_flight_goes_on_before_a_newer_tip(self):
        state = cron.empty_state(T0)
        cron.decide(state, T0, "a" * 40, None, lambda sha: ["motion", "sidebar"], None)
        state["current"]["parts_todo"].remove("build")
        state["current"]["parts_todo"].remove("motion")
        d = cron.decide(state, at(1), "b" * 40, None, lambda sha: ALL, None)
        self.assertEqual((d["sha"], d["part"]), ("a" * 40, "sidebar"))

    def test_a_dead_measurement_is_dropped_before_the_new_commit_search(self):
        state = cron.empty_state(T0)
        cron.decide(state, T0, "a" * 40, None, lambda sha: ["motion"], None)
        self.assertEqual(cron.drop_dead_measurement(state, at(1), lambda sha: sha != "a" * 40), "unmeasurable")
        self.assertIsNone(state["current"])
        self.assertIsNone(cron.drop_dead_measurement(state, at(1), lambda sha: False), "nothing in flight")

    def test_a_measurement_the_fleet_no_longer_runs_is_dropped(self):
        state = cron.empty_state(T0)
        cron.decide(state, T0, "a" * 40, None, lambda sha: ["motion"], None)
        d = cron.decide(state, at(1), "b" * 40, None, lambda sha: ["motion"], None, measurable=lambda sha: sha != "a" * 40)
        self.assertEqual(d["sha"], "b" * 40)
        self.assertEqual(state["history"][-1]["status"], "unmeasurable")

    def test_an_old_measurement_is_abandoned(self):
        state = cron.empty_state(T0)
        cron.decide(state, T0, "a" * 40, None, lambda sha: ["motion"], None)
        d = cron.decide(state, at(cron.ABANDON_HOURS + 1), "b" * 40, None, lambda sha: ["motion"], None)
        self.assertEqual(d["sha"], "b" * 40)
        self.assertEqual(state["history"][-1]["status"], "abandoned")

    def test_bisect_runs_only_the_parts_of_the_regressed_rows(self):
        state = cron.empty_state(T0)
        rng = {"good": "a" * 40, "bad": "e" * 40, "skip": [], "steps": 0}
        state["regressions"] = [{"name": "sidebar.400.scroll.frame", "range": rng}, {"name": "panes.close.stress.frame", "range": rng},
                                {"name": "tab_switch.x.e2e", "range": {"good": "b" * 40, "bad": "e" * 40}}]
        group = cron.bisect_groups(state)[0]
        self.assertEqual(group["rows"], ["sidebar.400.scroll.frame", "panes.close.stress.frame"])
        d = cron.decide(state, T0, None, {"sha": "c" * 40, **group}, lambda sha: ALL, None)
        self.assertEqual(state["current"]["kind"], "bisect")
        self.assertEqual(state["current"]["parts_todo"], ["build", "stress", "sidebar"], "only the group's rows' parts")
        self.assertEqual(state["current"]["bisect_range"], {"good": "a" * 40, "bad": "e" * 40})
        self.assertEqual((d["part"], d["linux_part"]), ("build", ""))

    def test_bisect_midpoint_takes_the_measurable_commit_nearest_the_middle(self):
        commits = ["c1", "c2", "c3", "c4", "c5"]
        self.assertEqual(cron.bisect_midpoint(commits, lambda c: True), "c3")
        self.assertEqual(cron.bisect_midpoint(commits, lambda c: c in ("c1", "c4")), "c4")
        self.assertIsNone(cron.bisect_midpoint(commits, lambda c: False))
        self.assertIsNone(cron.bisect_midpoint([], lambda c: True))
        self.assertNotEqual(cron.bisect_midpoint(commits, lambda c: True, skip=["c3"]), "c3", "a skipped commit is not picked again")
        self.assertIsNone(cron.bisect_midpoint(commits, lambda c: True, skip=commits))


class RegressionTests(unittest.TestCase):
    def test_worse_by_ten_percent_and_the_floor_regresses(self):
        regs = cron.find_regressions({"tab_switch.terminal.10.e2e": row(14.0)}, {"tab_switch.terminal.10.e2e": row(12.0)},
                                     16.67, 16.67, budgets_mod)
        self.assertEqual([r["name"] for r in regs], ["tab_switch.terminal.10.e2e"])

    def test_noise_under_the_floor_does_not(self):
        regs = cron.find_regressions({"x.input_to_commit": row(5.6)}, {"x.input_to_commit": row(5.0)}, 16.67, 16.67, budgets_mod)
        self.assertEqual(regs, [])

    def test_newly_over_target_regresses_under_ten_percent(self):
        # A frame row's target at 60 Hz is 20.8 ms: 20.0 -> 21.5 is +7.5 % but crosses it by more than the floor.
        regs = cron.find_regressions({"p.frame": row(21.5)}, {"p.frame": row(20.0)}, 16.67, 16.67, budgets_mod)
        self.assertEqual([(r["name"], r["why"]) for r in regs], [("p.frame", "newly over target")])
        # Crossing the 10 ms latency target by less than the floor is noise.
        self.assertEqual(cron.find_regressions({"a.e2e": row(10.4)}, {"a.e2e": row(9.5)}, 16.67, 16.67, budgets_mod), [])
        regs = cron.find_regressions({"a.e2e": row(19.5)}, {"a.e2e": row(18.0)}, 16.67, 16.67, budgets_mod)
        self.assertEqual(regs, [], "already over target and within 10 %: not a regression")

    def test_a_frame_row_target_is_one_display_refresh(self):
        self.assertFalse(cron.over_target("panes.split.4x2.frame", row(16.67), 16.67))
        self.assertTrue(cron.over_target("panes.split.4x2.frame", row(33.3), 16.67))
        self.assertTrue(cron.over_target("panes.split.4x2.frame", row(16.67), 8.33))
        self.assertTrue(cron.over_target("cmd_t.idle.key_to_visible", row(12.0), 16.67))
        self.assertTrue(cron.over_target("perf_gate.tabs.failed_checks", row(1, "checks"), 16.67))
        self.assertIsNone(cron.target_of("anim.tab.over_8_33", row(3.0), 16.67))

    def test_a_new_perf_gate_failure_regresses(self):
        regs = cron.find_regressions({"perf_gate.tabs.failed_checks": row(1, "checks", 0.5)},
                                     {"perf_gate.tabs.failed_checks": row(0, "checks", 0.5)}, None, None, budgets_mod)
        self.assertEqual(len(regs), 1)

    def test_no_baseline_no_regression(self):
        self.assertEqual(cron.find_regressions({"a": row(9.0)}, {}, None, None, budgets_mod), [])
        self.assertEqual([r["base"] for r in cron.find_regressions({"a": row(99.0)}, {}, None, None, budgets_mod)], [None],
                         "over target with no reference: listed with no base, not compared")


class RowsTests(unittest.TestCase):
    def test_perf_gate_checks_become_failed_check_rows(self):
        report = {"checks": [{"scenario": "tabs", "ok": True}, {"scenario": "tabs", "ok": False}, {"scenario": "split", "ok": True}]}
        rows = cron.rows_of_part(cron.PART_BY_NAME["perf-gate"], report, budgets_mod, {"rows": {}})
        self.assertEqual(rows["perf_gate.tabs.failed_checks"]["p95"], 1)
        self.assertEqual(rows["perf_gate.split.failed_checks"]["p95"], 0)

    def test_launch_rows_keep_the_old_ci_budgets_as_targets(self):
        report = {"split-spring": {"warm": [{"first_window_frame_committed": v, "did_finish_launching_end": v / 2} for v in (200, 220, 260)]}}
        rows = cron.rows_of_part(cron.PART_BY_NAME["launch"], report, budgets_mod, {"rows": {}})
        self.assertEqual(rows["launch.warm.first_window_frame_committed"]["p50"], 220)
        self.assertEqual(cron.target_of("launch.warm.first_window_frame_committed", rows["launch.warm.first_window_frame_committed"], 16.67), 1000)
        self.assertEqual(cron.part_for_row("launch.warm.sidebar_rows_shown"), "launch")

    def test_stress_pane_summary_rows(self):
        report = {"summary": [{"action": "close", "layout": "stress", "frames_p50_ms": 16.6, "frames_p95_ms": 33.3}],
                  "runs": [{"refresh_ms": 16.67}]}
        budgets = {"rows": {r"panes\..*\.frame": {"p95": 8.33, "unit": "ms", "floor": 1.0}}, "_animations": {}}
        rows = cron.rows_of_part(cron.PART_BY_NAME["stress"], report, budgets_mod, budgets)
        self.assertEqual(rows["panes.close.stress.frame"]["p95"], 33.3)
        self.assertEqual(cron.refresh_ms_of(report), 16.67)
        self.assertEqual(cron.part_for_row("panes.close.stress.frame"), "stress")
        self.assertEqual(cron.part_for_row("panes.close.4x2.frame"), "motion")


class FinishTests(OneRunRule):
    def measured(self, state, sha, rows, hours):
        state["current"] = cron.new_measurement(sha, "tip", [], at(hours))
        state["current"]["parts"] = {"motion": {"state": "done"}}
        return cron.finish_measurement(state, rows, 16.67, "bench", f"run-{sha[:1]}", at(hours), budgets_mod)

    def bisected(self, state, sha, rows, hours, parts=None):
        rng = cron.bisect_groups(state)[0]["range"]
        state["current"] = cron.new_measurement(sha, "bisect", [], at(hours), rng)
        state["current"]["parts"] = parts or {"motion": {"state": "done"}}
        return cron.finish_measurement(state, rows, 16.67, "bench", "r", at(hours), budgets_mod)

    def rng(self, state, name):
        r = next(r for r in state["regressions"] if r["name"] == name)["range"]
        return (r["good"], r["bad"])

    def test_first_regressed_still_recovered(self):
        state = cron.empty_state(T0)
        self.assertEqual(self.measured(state, "a" * 40, {"t.e2e": row(5.0)}, 0), "first")
        self.assertEqual(self.measured(state, "b" * 40, {"t.e2e": row(9.0)}, 1), "regressed")
        self.assertEqual(self.rng(state, "t.e2e"), ("a" * 40, "b" * 40))
        self.assertEqual(self.measured(state, "c" * 40, {"t.e2e": row(9.1)}, 2), "still")
        self.assertEqual(state["regressions"][0]["first_bad"]["sha"], "b" * 40, "the first bad commit stays the earliest")
        self.assertEqual(self.rng(state, "t.e2e"), ("a" * 40, "b" * 40))
        self.assertEqual(self.measured(state, "d" * 40, {"t.e2e": row(5.1)}, 3), "recovered")
        self.assertEqual(state["last_good"]["sha"], "d" * 40)
        self.assertEqual(state["regressions"], [])

    def test_bisect_narrows_the_range(self):
        state = cron.empty_state(T0)
        self.measured(state, "a" * 40, {"t.e2e": row(5.0)}, 0)
        self.measured(state, "e" * 40, {"t.e2e": row(9.0)}, 1)
        self.assertEqual(self.bisected(state, "c" * 40, {"t.e2e": row(5.2)}, 2), "narrowed")
        self.assertEqual(self.rng(state, "t.e2e"), ("c" * 40, "e" * 40))
        self.bisected(state, "d" * 40, {"t.e2e": row(9.2)}, 3)
        self.assertEqual(self.rng(state, "t.e2e"), ("c" * 40, "d" * 40))
        self.assertEqual(state["last"]["sha"], "e" * 40, "a bisect step is not the last tip measurement")

    def test_a_bisect_step_with_no_rows_is_skipped_not_good(self):
        state = cron.empty_state(T0)
        self.measured(state, "a" * 40, {"t.e2e": row(5.0)}, 0)
        self.measured(state, "e" * 40, {"t.e2e": row(9.0)}, 1)
        self.assertEqual(self.bisected(state, "c" * 40, {}, 2, {"build": {"state": "failed"}}), "skipped")
        self.assertEqual(self.rng(state, "t.e2e"), ("a" * 40, "e" * 40), "the range is unchanged")
        self.assertEqual(state["regressions"][0]["range"]["skip"], ["c" * 40])
        self.assertEqual(state["history"][-1]["status"], "skip")
        self.assertNotEqual(cron.bisect_midpoint(["b" * 40, "c" * 40, "d" * 40], lambda c: True,
                                                 state["regressions"][0]["range"]["skip"]), "c" * 40)

    def test_a_bisect_step_that_measured_only_some_regressed_rows_is_skipped(self):
        state = cron.empty_state(T0)
        self.measured(state, "a" * 40, {"panes.close.stress.frame": row(10.0), "panes.split.4x2.frame": row(10.0)}, 0)
        self.measured(state, "e" * 40, {"panes.close.stress.frame": row(30.0), "panes.split.4x2.frame": row(10.0)}, 1)
        # The stress part failed, motion passed: no regressed row measured, so the commit is not good.
        verdict = self.bisected(state, "c" * 40, {"panes.split.4x2.frame": row(10.0)}, 2,
                                {"stress": {"state": "failed"}, "motion": {"state": "done"}})
        self.assertEqual(verdict, "skipped")
        self.assertEqual(self.rng(state, "panes.close.stress.frame"), ("a" * 40, "e" * 40))

    def test_a_tip_that_misses_a_regressed_row_stays_regressed(self):
        state = cron.empty_state(T0)
        self.measured(state, "a" * 40, {"t.e2e": row(5.0), "panes.close.stress.frame": row(10.0)}, 0)
        self.measured(state, "b" * 40, {"t.e2e": row(5.0), "panes.close.stress.frame": row(30.0)}, 1)
        # The stress part failed at c: its row is not back within its threshold, it is unknown.
        self.assertEqual(self.measured(state, "c" * 40, {"t.e2e": row(5.0)}, 2), "still")
        self.assertEqual([r["name"] for r in state["regressions"]], ["panes.close.stress.frame"])
        self.assertEqual(state["regressions"][0]["unmeasured_at"], "c" * 40)
        self.assertEqual(state["last_good"]["sha"], "a" * 40, "last good does not move to an incomplete measurement")
        self.assertEqual(state["last"]["sha"], "b" * 40, "the stale clock is not reset")
        self.assertEqual(state["last_tried"]["sha"], "c" * 40, "the new-commit search does not retry c")
        self.assertEqual(state["history"][-1]["status"], "incomplete")
        self.assertEqual(self.measured(state, "d" * 40, {"t.e2e": row(5.0), "panes.close.stress.frame": row(10.2)}, 3), "recovered")

    def test_an_empty_tip_measurement_moves_nothing_but_the_search(self):
        state = cron.empty_state(T0)
        self.measured(state, "a" * 40, {"t.e2e": row(5.0)}, 0)
        self.assertEqual(self.measured(state, "b" * 40, {}, 1), "empty")
        self.assertEqual((state["last"]["sha"], state["last_good"]["sha"]), ("a" * 40, "a" * 40))
        self.assertEqual(state["last_tried"]["sha"], "b" * 40, "a commit that does not build is not rebuilt every tick")
        self.assertEqual(cron.stale_basis(state), cron.iso(at(0)))

    def test_a_row_that_regresses_later_gets_its_own_range(self):
        state = cron.empty_state(T0)
        self.measured(state, "a" * 40, {"x.e2e": row(5.0), "y.e2e": row(5.0)}, 0)
        self.assertEqual(self.measured(state, "b" * 40, {"x.e2e": row(9.0), "y.e2e": row(5.0)}, 1), "regressed")
        self.assertEqual(self.measured(state, "c" * 40, {"x.e2e": row(9.0), "y.e2e": row(5.1)}, 2), "still")
        self.assertEqual(self.measured(state, "d" * 40, {"x.e2e": row(5.0), "y.e2e": row(9.0)}, 3), "still")
        self.assertEqual([r["name"] for r in state["regressions"]], ["y.e2e"], "x recovered, y regressed")
        self.assertEqual(self.rng(state, "y.e2e"), ("c" * 40, "d" * 40), "from the last tip where y was fine")
        self.assertEqual(state["regressions"][0]["first_bad"]["sha"], "d" * 40)
        self.assertEqual([g["rows"] for g in cron.bisect_groups(state)], [["y.e2e"]])

    def test_an_old_state_keeps_its_one_range_on_each_row(self):
        old = {"schema": cron.SCHEMA, "range": {"good": "a" * 40, "bad": "b" * 40}, "first_bad": {"sha": "b" * 40},
               "regressions": [{"name": "t.e2e"}],
               "row_history": {"t.e2e": [{"at": cron.iso(at(-h)), "p95": 9.0} for h in (3, 2, 1)]}}
        state = cron.migrate_state(old)
        self.assertEqual(state["regressions"][0]["range"]["good"], "a" * 40)
        self.assertEqual(state["regressions"][0]["first_bad"]["sha"], "b" * 40)
        self.assertNotIn("range", state)


class PartTests(unittest.TestCase):
    def test_parts_on_the_virtual_display_hold_it_no_longer_than_they_run(self):
        stress = cron.PART_BY_NAME["stress"]
        self.assertEqual(stress["run_seconds"], 1500, "STRESS keeps its 25-minute cap until it is timed")
        self.assertEqual(cron.part_args(stress, 1500)[-1], "--vdisplay-hold=1500")
        self.assertNotIn("--vdisplay-hold=1200", " ".join(cron.part_args(cron.PART_BY_NAME["build"], 1200)))

    def test_a_yielded_part_stays_to_do_up_to_the_limit(self):
        cur = cron.new_measurement("a" * 40, "tip", ["motion", "sidebar"], T0)
        for i in range(cron.MAX_YIELDS - 1):
            self.assertEqual(cron.record_part(cur, "motion", {"state": "yielded"}, "r")["state"], "yielded")
            self.assertIn("motion", cur["parts_todo"])
        self.assertEqual(cron.record_part(cur, "motion", {"state": "yielded"}, "r")["state"], "yielded_out")
        self.assertEqual(cur["parts_todo"], ["sidebar"])

    def test_a_build_part_pre_empted_too_often_is_no_build_failure(self):
        cur = cron.new_measurement("a" * 40, "tip", ["build", "motion", "sidebar", "diff-viewer"], T0)
        for _ in range(cron.MAX_YIELDS):
            cron.record_part(cur, "build", {"state": "yielded", "yielded_to": "j" * 24}, "r")
        self.assertEqual(cur["parts"]["build"]["state"], "yielded_out")
        self.assertEqual(cur["parts_todo"], ["motion", "sidebar", "diff-viewer"], "the other parts still run (and build)")
        cur = cron.new_measurement("a" * 40, "tip", ["build", "motion"], T0)
        cron.record_part(cur, "build", {"state": "failed", "tail": ["cmux-ci: lost the worker"]}, "r")
        self.assertEqual(cur["parts_todo"], ["motion"], "a build part that failed without the build-failed mark ends nothing")

    def test_a_failed_build_ends_the_fleet_parts_but_not_the_linux_part(self):
        cur = cron.new_measurement("a" * 40, "tip", ["build", "motion", "sidebar", "diff-viewer"], T0)
        cron.record_part(cur, "build", {"state": "failed", "tail": ["split-spring: the tagged reload printed no app path"]}, "r")
        self.assertEqual(cur["parts_todo"], ["diff-viewer"])
        self.assertEqual(cur["parts"]["sidebar"]["state"], "build_failed")
        cur = cron.new_measurement("a" * 40, "tip", ["motion", "sidebar"], T0)
        cron.record_part(cur, "motion", {"state": "failed", "tail": ["error: 60 compiler lines"], "build_failed": True}, "r")
        self.assertEqual(cur["parts_todo"], [], "a part that had to build and failed ends the rest too, whatever its tail")


class DisplayTests(OneRunRule):
    def test_a_frame_row_on_another_refresh_is_not_compared(self):
        now = {"p.frame": {**row(16.7), "refresh_ms": 16.67}, "p.missed": {**row(6, "frames"), "refresh_ms": 16.67},
               "t.e2e": {**row(14.0), "refresh_ms": 16.67}}
        base = {"p.frame": {**row(8.4), "refresh_ms": 8.33}, "p.missed": {**row(0, "frames"), "refresh_ms": 8.33},
                "t.e2e": {**row(9.0), "refresh_ms": 8.33}}
        regs = cron.find_regressions(now, base, 16.67, 8.33, budgets_mod)
        self.assertEqual([r["name"] for r in regs], ["p.missed", "t.e2e"],
                         "latency and dropped frames compare across refresh rates, frame intervals do not")

    def test_a_known_refresh_against_an_unknown_one_is_not_compared(self):
        now = {"p.frame": {**row(33.3), "refresh_ms": 16.67}}
        self.assertEqual(cron.find_regressions(now, {"p.frame": row(16.7)}, 16.67, None, budgets_mod), [])
        self.assertEqual(cron.refresh_skipped(now, {"p.frame": row(16.7)}, 16.67, None), ["p.frame"])
        both_unknown = cron.find_regressions({"p.frame": row(33.3)}, {"p.frame": row(16.7)}, None, None, budgets_mod)
        self.assertEqual(both_unknown, [], "an unknown display is never compared, not even with another unknown one")
        latency = cron.find_regressions({"t.e2e": row(14.0)}, {"t.e2e": row(5.0)}, None, None, budgets_mod)
        self.assertEqual([r["name"] for r in latency], ["t.e2e"], "latency rows do not depend on the display")

    def test_a_frame_row_of_unknown_refresh_has_no_target(self):
        self.assertIsNone(cron.target_of("panes.split.4x2.frame", row(20.0), None), "no 60 Hz guess")
        self.assertIsNone(cron.target_of("p.frame", {**row(20.0), "refresh_ms": None}, 8.33),
                          "a row whose part saw no refresh does not take the measurement's")
        self.assertFalse(cron.over_target("p.frame", row(20.0), None))
        self.assertEqual(cron.target_of("p.frame", row(9.0), 8.33), 10.41)

    def test_the_refresh_comes_from_the_benches_else_the_display_split_spring_records(self):
        self.assertEqual(cron.refresh_ms_of({"rows": [], "display": {"vdisplay": True, "refresh_ms": 8.34}}), 8.34)
        self.assertIsNone(cron.refresh_ms_of({"rows": [], "display": {"vdisplay": False, "refresh_ms": None,
                                                                      "line": "ready 3 16.67 main=1"}}), "VDISPLAY-FALLBACK")
        self.assertIsNone(cron.refresh_ms_of({"rows": [], "display": None}))
        self.assertEqual(cron.refresh_ms_of({"a": {"refresh_ms": 16.67}, "display": {"refresh_ms": 8.34}}), 16.67,
                         "the display the app was on wins over the one asked for")

    def report_tick(self, d, parts, last_good_rows, result=None, host=None):
        """cmd_report finishing a tip measurement of `parts` ({name: report}) against last_good_rows. result: each
        part's result.json (default: done on the bench host); host: the measurement's host before the tick."""
        state = cron.empty_state(T0)
        state["persisted"] = True
        state["last_good"] = state["last"] = {"sha": "a" * 40, "measured_at": cron.iso(T0), "rows": last_good_rows,
                                              "refresh_ms": 8.33}
        state["current"] = cron.new_measurement("b" * 40, "tip", list(parts), T0)
        if host:
            state["current"]["host"] = host
        with open(os.path.join(d, "state.json"), "w") as f:
            json.dump(state, f)
        results = []
        for name, report in parts.items():
            part_dir = os.path.join(d, name)
            os.makedirs(part_dir)
            for file, value in (("result.json", result or {"state": "done", "worker": cron.BENCH_WORKER}), ("report.json", report)):
                with open(os.path.join(part_dir, file), "w") as f:
                    json.dump(value, f)
            results.append(f"{name}={part_dir}")
        with mock.patch.object(cron, "now_utc", lambda: at(1)):
            cron.cmd_report(argparse.Namespace(repo="o/r", dir=d, result=results, run_url="u", finish=False, issues=False,
                                               output=os.path.join(d, "report.out")))
        with open(os.path.join(d, "state.json")) as f:
            return json.load(f)

    def test_each_part_keeps_its_own_refresh(self):
        stress = {"refresh_ms": 8.33, "summary": [{"action": "close", "layout": "stress", "frames_p50_ms": 8.3,
                                                   "frames_p95_ms": 8.4, "missed": 0}]}
        B = "@" + cron.BENCH_WORKER  # the default result ran on the bench host
        base = {"panes.split.4x2.frame" + B: {**row(8.4), "refresh_ms": 8.33}, "panes.close.stress.frame" + B: {**row(8.4), "refresh_ms": 8.33}}
        fallback = {"rows": [{"name": "panes.split.4x2.frame", "p50": 16.7, "p95": 17.0, "unit": "ms"}],
                    "display": {"requested_hz": 120, "vdisplay": False, "refresh_ms": None, "line": "error: x"}}
        with tempfile.TemporaryDirectory() as d:
            state = self.report_tick(d, {"stress": stress, "motion": fallback}, base)
            self.assertEqual(state["regressions"], [], "a fallback part's frame rows are not compared with the 120 Hz stress part's rate")
            self.assertIsNone(state["last"]["rows"]["panes.split.4x2.frame" + B]["refresh_ms"])
            self.assertEqual(state["last_good"]["rows"]["panes.split.4x2.frame" + B]["p95"], 8.4, "the 120 Hz baseline stays")
        on_vdisplay = {**fallback, "display": {"requested_hz": 120, "vdisplay": True, "refresh_ms": 8.34, "line": "ready"}}
        with tempfile.TemporaryDirectory() as d:
            state = self.report_tick(d, {"stress": stress, "motion": on_vdisplay}, base)
            self.assertEqual([r["name"] for r in state["regressions"]], ["panes.split.4x2.frame" + B],
                             "a budgets part on the virtual display is compared at its refresh")

    def test_an_incomplete_budget_report_does_not_become_a_done_part(self):
        report = {"rows": [{"name": "panes.split.4x2.frame", "p95": 8.4}],
                  "incomplete": [{"name": "panes.close.4x2.frame", "reason": "missing current p95"}]}
        with tempfile.TemporaryDirectory() as d:
            state = self.report_tick(d, {"motion": report}, {})
            self.assertEqual(state["history"][-1]["failed_parts"], ["motion"])
            self.assertEqual(state["history"][-1]["status"], "incomplete")
            self.assertEqual(state["last_good"]["sha"], "a" * 40, "partial budgets never establish a baseline")

    def test_the_issue_says_which_frame_rows_were_not_compared(self):
        state = cron.empty_state(T0)
        state["current"] = cron.new_measurement("a" * 40, "tip", [], T0)
        state["current"]["parts"] = {"stress": {"state": "done"}}
        cron.finish_measurement(state, {"p.frame": {**row(8.4), "refresh_ms": 8.33}}, 8.33, "bench", "r", T0, budgets_mod)
        state["current"] = cron.new_measurement("b" * 40, "tip", [], at(1))
        state["current"]["parts"] = {"stress": {"state": "done"}}
        event = cron.finish_measurement(state, {"p.frame": {**row(16.7), "refresh_ms": 16.67}}, 16.67, "bench", "r", at(1), budgets_mod)
        self.assertEqual(event, "good", "a 60 Hz fallback run opens no issue")
        self.assertIn("Not compared: 1 frame row(s)", cron.issue_body(state, "o/r", at(1)))
        self.assertEqual(state["last_good"]["rows"]["p.frame"]["refresh_ms"], 8.33, "a 60 Hz fallback keeps the 120 Hz baseline")
        state["current"] = cron.new_measurement("c" * 40, "tip", [], at(2))
        state["current"]["parts"] = {"stress": {"state": "done"}}
        cron.finish_measurement(state, {"p.frame": {**row(9.9), "refresh_ms": 8.33}}, 8.33, "bench", "r", at(2), budgets_mod)
        self.assertEqual([r["name"] for r in state["regressions"]], ["p.frame"], "back at 120 Hz it compares again")

    def test_dropped_frames_are_judged_in_frames(self):
        report = {"summary": [{"action": "close", "layout": "stress", "frames_p50_ms": 8.3, "frames_p95_ms": 8.4, "missed": 2}]}
        rows = cron.rows_of_part(cron.PART_BY_NAME["stress"], report, budgets_mod, {"rows": {}, "_animations": {}})
        self.assertEqual(rows["panes.close.stress.missed"]["p95"], 2)
        self.assertTrue(cron.over_target("panes.close.stress.missed", rows["panes.close.stress.missed"], 8.33))
        self.assertEqual(cron.target_of("p.frame", {**row(9.0), "refresh_ms": 8.33}, 16.67), 10.41, "the row's own refresh")

    def test_the_issue_table_names_the_refresh(self):
        state = cron.empty_state(T0)
        state["last_good"] = {"sha": "a" * 40, "rows": {}, "run_url": "g"}
        state["first_bad"] = {"sha": "b" * 40, "run_url": "b"}
        state["regressions"] = [{"name": "p.frame", "p95": 30.0, "base": 16.7, "unit": "ms", "target": 20.8,
                                 "refresh_ms": 16.67, "why": "worse than last good"}]
        state["last"] = {"sha": "b" * 40, "measured_at": cron.iso(T0), "rows": {"p.frame": {**row(30.0), "refresh_ms": 16.67}},
                         "refresh_ms": 16.67}
        body = cron.issue_body(state, "o/r", T0)
        self.assertIn("| 60 Hz | worse than last good |", body)
        self.assertIn("display 60 Hz", body)


FIXTURES = os.path.join(HERE, "fixtures")


class DiffTests(unittest.TestCase):
    def test_the_recorded_linux_part_report_gives_all_three_rows(self):
        with open(os.path.join(FIXTURES, "perf-cron-diff-report-2026-10-23.json")) as f:
            report = json.load(f)
        rows = cron.rows_of_part(cron.PART_BY_NAME["diff-viewer"], report, budgets_mod, {"rows": {}})
        self.assertEqual(sorted(rows), ["diff.sidecar.manifest_decode_p95", "diff.sidecar.read_ms_per_gib", "diff.stream.p95"])
        self.assertEqual(rows["diff.sidecar.manifest_decode_p95"]["p95"], 4)
        self.assertEqual(rows["diff.sidecar.read_ms_per_gib"]["p95"], 46.65, "21951 MiB/s")
        self.assertEqual(rows["diff.stream.p95"]["p95"], 22.22)

    def test_diff_viewer_rows_and_their_budgets(self):
        report = {"sidecar": {"manifestDecodeP95Micros": 400, "sequentialReadMibPerSecond": 1024.0},
                  "stream": {"p95Ms": 120.5}}
        rows = cron.rows_of_part(cron.PART_BY_NAME["diff-viewer"], report, budgets_mod, {"rows": {}})
        self.assertEqual(rows["diff.sidecar.read_ms_per_gib"]["p95"], 1000.0)
        self.assertEqual(cron.target_of("diff.stream.p95", rows["diff.stream.p95"], 16.67), 250.0)
        self.assertFalse(cron.over_target("diff.sidecar.manifest_decode_p95", rows["diff.sidecar.manifest_decode_p95"], None))
        self.assertEqual(cron.part_for_row("diff.stream.p95"), "diff-viewer")

    def test_the_last_json_object_a_bench_printed(self):
        self.assertEqual(cron.last_json_object('Compiling\n{\n "a": 1\n}\nnoise\n{\n "b": 2\n}\n'), {"b": 2})
        self.assertIsNone(cron.last_json_object("no json here"))


class WebUiTests(unittest.TestCase):
    """The web-ui part: webviews/bench/web-ui-suite.ts's report, its rows and the run on Linux."""
    REPORT = {"rows": [{"name": "chat_switch.unread.latest", "p50": 80, "p95": 140, "unit": "ms", "target": 100},
                       {"name": "edit_turns.full.20000", "p95": 0.44},
                       {"name": "chat_open.compact.latest", "p95": 600, "target": 1000, "version": 2, "floor": 25},
                       {"name": "Bad Name", "p95": 1}, {"name": "no_p95"}],
              "failed": []}

    def test_rows_carry_target_floor_and_version(self):
        rows = cron.rows_of_part(cron.PART_BY_NAME["web-ui"], self.REPORT, budgets_mod, {"rows": {}})
        self.assertEqual(sorted(rows), ["webui.chat_open.compact.latest", "webui.chat_switch.unread.latest",
                                        "webui.edit_turns.full.20000"], "a malformed row is dropped")
        switch, edit, load = (rows[f"webui.{n}"] for n in ("chat_switch.unread.latest", "edit_turns.full.20000",
                                                           "chat_open.compact.latest"))
        self.assertEqual((switch["p50"], switch["p95"], switch["budget"], switch["floor"]), (80, 140, 100, 14.0))
        self.assertEqual((edit["p50"], edit["budget"], edit["measure_version"]), (0.44, None, cron.DIFF_LEGACY_VERSION))
        self.assertEqual((load["floor"], load["measure_version"]), (25, 2))
        self.assertEqual(cron.target_of("webui.chat_switch.unread.latest", switch, None), 100)
        self.assertIsNone(cron.target_of("webui.edit_turns.full.20000", edit, None), "no target, not the 10 ms default")
        self.assertTrue(cron.over_target("webui.chat_switch.unread.latest", switch, None))
        self.assertFalse(any(cron.frame_sensitive(n, r) for n, r in rows.items()), "judged without a display refresh")

    def test_the_part_is_linux_and_owns_the_webui_rows(self):
        self.assertTrue(cron.is_linux_part("web-ui"))
        self.assertEqual(cron.part_for_row("webui.chat_open.compact.latest@blacksmith-4vcpu-ubuntu-2404"), "web-ui")
        self.assertTrue(cron.linux_row("webui.chat_open.compact.latest@blacksmith-4vcpu-ubuntu-2404"))
        self.assertIsNone(cron.mac_host("webui.chat_open.compact.latest@blacksmith-4vcpu-ubuntu-2404"))
        self.assertEqual(cron.part_config("diff-viewer"), "9c9749c7fe76", "the diff-viewer rows are not rebased")
        self.assertNotEqual(cron.part_config("web-ui"), cron.part_config("diff-viewer"))

    def test_a_regression_of_a_webui_row(self):
        name = "webui.chat_switch.unread.latest@linux"
        base = {name: {**row(80.0, floor=8.0), "budget": 100}}
        regs = cron.find_regressions({name: {**row(95.0, floor=9.5), "budget": 100}}, base, None, None, budgets_mod)
        self.assertEqual([r["name"] for r in regs], [name])
        self.assertEqual(cron.find_regressions({name: {**row(86.0, floor=8.6), "budget": 100}}, base, None, None,
                                               budgets_mod), [], "within 10 %")

    def test_a_failed_bench_makes_the_report_incomplete(self):
        part = cron.PART_BY_NAME["web-ui"]
        self.assertFalse(cron.report_is_incomplete(part, self.REPORT))
        self.assertTrue(cron.report_is_incomplete(part, {**self.REPORT, "incomplete": ["chat-open: exit 1"]}))

    def test_the_summary_is_slowest_first_relative_to_target(self):
        lines = cron.webui_summary({**self.REPORT, "failed": [{"bench": "chat-open", "why": "exit 1"}]})
        names = [line.split(" | ")[0].lstrip("| ") for line in lines[2:] if line.startswith("|")]
        self.assertEqual(names[:3], ["webui.chat_switch.unread.latest", "webui.chat_open.compact.latest",
                                     "webui.edit_turns.full.20000"])
        self.assertIn("| webui.chat_switch.unread.latest | 140 ms | 100 ms | 140 % |", lines)
        self.assertEqual(lines[-1], "failed: chat-open (exit 1)")

    def run_part(self, printed):
        script = f"import json; print('noise'); print(json.dumps({printed!r}))"
        with tempfile.TemporaryDirectory() as out, \
                mock.patch.object(cron, "linux_bench_runs", lambda root, part: {"suite": (["python3", "-c", script], out, {})}), \
                contextlib.redirect_stdout(io.StringIO()) as printed_out:
            cron.cmd_run_linux_part(argparse.Namespace(part="web-ui", out=out, runner_class="ubuntu-24.04"))
            result, report = (json.load(open(os.path.join(out, n))) for n in ("result.json", "report.json"))
        return result, report, printed_out.getvalue()

    def test_run_linux_part_records_failed_benches(self):
        result, report, printed = self.run_part({**self.REPORT, "failed": [{"bench": "chat-open", "why": "exit 1"}]})
        self.assertEqual((result["state"], result["worker"]), ("done", "ubuntu-24.04"))
        self.assertEqual(report["incomplete"], ["chat-open: exit 1"])
        self.assertIn("chat-open: exit 1", result["tail"])
        self.assertIn("perf-cron web-ui: failed: chat-open (exit 1)", printed)
        self.assertNotIn("bench_versions", report)
        result, report, _ = self.run_part({"rows": [], "failed": [{"bench": "chat-open", "why": "exit 1"}]})
        self.assertEqual(result["state"], "failed", "no row at all is no measurement")


class IncompleteTests(OneRunRule):
    def finish(self, state, sha, parts, rows, hours):
        state["current"] = cron.new_measurement(sha, "tip", [], at(hours))
        state["current"]["parts"] = parts
        return cron.finish_measurement(state, rows, 8.33, "bench", "r", at(hours), budgets_mod)

    def test_a_build_failure_with_a_regression_open_is_no_recovery(self):
        state = cron.empty_state(T0)
        ok = {p: {"state": "done"} for p in ("build", "stress", "diff-viewer")}
        self.finish(state, "a" * 40, ok, {"panes.close.stress.frame": row(8.4), "diff.stream.p95": row(20.0)}, 0)
        self.finish(state, "b" * 40, ok, {"panes.close.stress.frame": row(30.0), "diff.stream.p95": row(20.0)}, 1)
        failed = {"build": {"state": "failed"}, "stress": {"state": "build_failed"}, "diff-viewer": {"state": "done"}}
        self.assertEqual(self.finish(state, "c" * 40, failed, {"diff.stream.p95": row(20.0)}, 2), "still")
        self.assertEqual([r["name"] for r in state["regressions"]], ["panes.close.stress.frame"])
        self.assertEqual((state["last"]["sha"], state["last_good"]["sha"]), ("b" * 40, "a" * 40))
        self.assertEqual(cron.stale_basis(state), cron.iso(at(1)), "the Linux rows alone do not reset the stale clock")

    def test_a_build_failure_with_nothing_open_is_partial(self):
        state = cron.empty_state(T0)
        ok = {p: {"state": "done"} for p in ("build", "stress", "diff-viewer")}
        self.finish(state, "a" * 40, ok, {"panes.close.stress.frame": row(8.4), "diff.stream.p95": row(20.0)}, 0)
        failed = {"build": {"state": "failed"}, "stress": {"state": "build_failed"}, "diff-viewer": {"state": "done"}}
        self.assertEqual(self.finish(state, "b" * 40, failed, {"diff.stream.p95": row(20.0)}, 30), "partial")
        self.assertEqual((state["last"]["sha"], state["last_good"]["sha"]), ("a" * 40, "a" * 40))
        self.assertGreater(cron.stale_hours(state, at(30)), cron.STALE_HOURS, "the Mac parts failing for a day is stale")
        self.assertEqual(state["history"][-1]["status"], "incomplete")

    def test_a_regressed_row_measured_again_clears_even_when_another_part_failed(self):
        state = cron.empty_state(T0)
        ok = {p: {"state": "done"} for p in ("stress", "motion")}
        self.finish(state, "a" * 40, ok, {"panes.close.stress.frame": row(8.4), "t.e2e": row(5.0)}, 0)
        self.finish(state, "b" * 40, ok, {"panes.close.stress.frame": row(8.4), "t.e2e": row(9.0)}, 1)
        part = {"stress": {"state": "failed"}, "motion": {"state": "done"}}
        self.assertEqual(self.finish(state, "c" * 40, part, {"t.e2e": row(5.0)}, 2), "recovered")
        self.assertEqual(state["last"]["sha"], "b" * 40)


class MissingResultTests(unittest.TestCase):
    def report(self, d, state, part_dir):
        with open(os.path.join(d, "state.json"), "w") as f:
            json.dump(state, f)
        with mock.patch.object(cron, "now_utc", lambda: at(1)):
            cron.cmd_report(argparse.Namespace(repo="o/r", dir=d, result=[f"motion={part_dir}"], run_url="u", finish=False,
                                               issues=False, output=os.path.join(d, "report.out")))
        with open(os.path.join(d, "state.json")) as f:
            return json.load(f)

    def test_a_job_that_left_no_result_is_one_attempt(self):
        with tempfile.TemporaryDirectory() as d:
            state = cron.empty_state(T0)
            state["persisted"] = True
            state["current"] = cron.new_measurement("b" * 40, "tip", ["motion", "sidebar"], T0)
            gone = os.path.join(d, "no-artifact")  # the job died before it uploaded anything
            for i in range(1, cron.MAX_YIELDS):
                state = self.report(d, state, gone)
                self.assertEqual(state["current"]["parts"]["motion"]["yields"], i)
                self.assertIn("motion", state["current"]["parts_todo"])
            state = self.report(d, state, gone)
            self.assertEqual(state["current"]["parts"]["motion"]["state"], "yielded_out", "not retried forever")
            self.assertEqual(state["current"]["parts_todo"], ["sidebar"])

    def test_a_fleet_check_that_said_no_is_no_attempt(self):
        with tempfile.TemporaryDirectory() as d:
            state = cron.empty_state(T0)
            state["persisted"] = True
            state["current"] = cron.new_measurement("b" * 40, "tip", ["motion"], T0)
            part_dir = os.path.join(d, "part")
            os.makedirs(part_dir)
            open(os.path.join(part_dir, cron.NOT_STARTED), "w").close()
            state = self.report(d, state, part_dir)
            self.assertEqual(state["current"]["parts"], {})
            self.assertEqual(state["current"]["parts_todo"], ["motion"])

    def test_cleanup_cancels_the_step_left_running_and_writes_the_attempt(self):
        with tempfile.TemporaryDirectory() as d:
            with open(os.path.join(d, "step.log"), "w") as f:
                f.write("cmux-ci: step 0123456789abcdef01234567 queued\n")
            client = os.path.join(d, "cmux-ci")
            open(client, "w").close()
            calls = []
            with mock.patch.object(cron, "run_capture", lambda argv, timeout=120: calls.append(argv) or
                                   argparse.Namespace(returncode=0, stdout="", stderr="")):
                cron.cmd_part_cleanup(argparse.Namespace(out=d, client=client, why="run step cancelled"))
            self.assertEqual(calls[0][:3], [client, "cancel", "0123456789abcdef01234567"])
            with open(os.path.join(d, "result.json")) as f:
                self.assertEqual(json.load(f)["state"], "yielded")
            calls.clear()
            cron.cmd_part_cleanup(argparse.Namespace(out=d, client=client, why="again"))
            self.assertEqual(calls, [], "a result already there is left alone")


class FinishEmptyTests(unittest.TestCase):
    def test_a_measurement_with_no_rows_is_no_baseline(self):
        state = cron.empty_state(T0)
        state["current"] = cron.new_measurement("a" * 40, "tip", [], T0)
        state["current"]["parts"] = {"build": {"state": "failed"}}
        self.assertEqual(cron.finish_measurement(state, {}, None, "bench", "r", T0, budgets_mod), "empty")
        self.assertIsNone(state["last_good"])
        self.assertIsNone(state["last"])


class IssueTests(unittest.TestCase):
    def test_open_comment_close(self):
        state = cron.empty_state(T0)
        state["last"] = {"sha": "a" * 40, "measured_at": cron.iso(T0)}
        state["regressions"] = [{"name": "x"}]
        self.assertEqual(cron.issue_plan(state, "regressed", T0, False, False, True), {"open": True, "comment": None})
        self.assertEqual(cron.issue_plan(state, "regressed", T0, True, True, True), {"open": True, "comment": "summary"})
        self.assertEqual(cron.issue_plan(state, "still", T0, True, True, False), {"open": True, "comment": None})
        self.assertEqual(cron.issue_plan(state, "still", T0, False, True, False), {"open": True, "comment": "summary"},
                         "a closed issue reopens with a comment")
        state["regressions"] = []
        self.assertEqual(cron.issue_plan(state, "recovered", T0, True, True, True), {"open": False, "comment": "recovered"})
        self.assertEqual(cron.issue_plan(state, "good", T0, False, True, False), {"open": False, "comment": None})

    def test_stale_opens_once(self):
        state = cron.empty_state(T0)
        later = at(cron.STALE_HOURS + 1)
        self.assertEqual(cron.issue_plan(state, None, later, True, True, False), {"open": True, "comment": "stale"})
        state["stale_noted_for"] = cron.stale_basis(state)
        self.assertEqual(cron.issue_plan(state, None, later, True, True, False), {"open": True, "comment": None})
        self.assertIn("Stale", cron.issue_body(state, "o/r", later))


class RecordedFleetTests(unittest.TestCase):
    """fleet_verdict on `cmux-ci workers` and /v1/status as the controller sent them (2026-10-23T14:01Z)."""

    def setUp(self):
        with open(os.path.join(FIXTURES, "perf-cron-fleet-2026-10-23.json")) as f:
            self.rec = json.load(f)
        seen = cron.parse_iso(self.rec["workers"]["cmux20-bench"]["last_seen"][:19] + "Z")
        patcher = mock.patch.object(cron, "now_utc", lambda: seen + datetime.timedelta(seconds=30))
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_the_busy_bench_host_sends_no_fits_and_the_part_waits(self):
        why = cron.fleet_verdict({"queue": []}, self.rec["workers"], [], "cmux20-bench", "queued")
        self.assertIn("offers no exclusive slot", why)

    def test_the_queued_foreground_bench_jobs_come_first(self):
        why = cron.fleet_verdict(self.rec["status"], self.rec["workers"], [], "cmux20-bench", "queued")
        self.assertIn("foreground job 6ff77b010a92", why)

    def test_an_idle_worker_offers_the_exclusive_class(self):
        self.assertEqual(self.rec["workers"]["cmuxs-Mac-mini.local"]["fits"], ["exclusive"])
        idle = {"cmuxs-Mac-mini.local": self.rec["workers"]["cmuxs-Mac-mini.local"]}
        seen = cron.parse_iso(idle["cmuxs-Mac-mini.local"]["last_seen"][:19] + "Z")
        with mock.patch.object(cron, "now_utc", lambda: seen + datetime.timedelta(seconds=30)):
            self.assertIsNone(cron.fleet_verdict({"queue": []}, idle, [], "cmuxs-Mac-mini.local", "queued"))


class FleetTests(unittest.TestCase):
    def workers(self, **over):
        w = {"healthy": True, "last_seen": cron.iso(cron.now_utc()), "claim_paused": None, "fits": ["exclusive"]}
        w.update(over)
        return {cron.BENCH_WORKER: w}

    def test_idle_bench_host_runs(self):
        self.assertIsNone(cron.fleet_verdict({"queue": []}, self.workers(), [], cron.BENCH_WORKER, "queued"))

    def test_yields(self):
        b = cron.BENCH_WORKER
        self.assertIn("takes no work", cron.fleet_verdict({}, self.workers(claim_paused="disk"), [], b, "queued"))
        self.assertIn("busy or wanted", cron.fleet_verdict({}, self.workers(), [{"id": "j" * 24, "state": "running", "worker": b}], b, "queued"))
        self.assertIn("busy or wanted", cron.fleet_verdict({}, self.workers(), [{"id": "j" * 24, "state": "queued", "labels": ["bench"]}], b, "queued"))
        self.assertIn("dev build waits", cron.fleet_verdict({"queue": [{"id": "k" * 24, "kind": "cmux"}]}, self.workers(), [], b, "queued"))
        running = {"queue": [], "workers": [{"name": "m", "running": [{"id": "r" * 24, "kind": "cmux"}]}]}
        self.assertIsNone(cron.fleet_verdict(running, self.workers(), [], b, "queued"))
        self.assertIn("dev build runs", cron.fleet_verdict(running, self.workers(), [], b, "running"))

    def test_only_a_job_queued_for_a_mac_runner_counts_as_waiting(self):
        self.assertTrue(cron.mac_job_waiting({"status": "queued", "labels": ["glaeda-side-std-xcode-26.6"]}))
        self.assertTrue(cron.mac_job_waiting({"status": "queued", "labels": []}))
        self.assertFalse(cron.mac_job_waiting({"status": "queued", "labels": ["blacksmith-4vcpu-ubuntu-2404"]}))
        self.assertFalse(cron.mac_job_waiting({"status": "queued", "labels": ["blacksmith-12vcpu-macos-26"]}),
                         "a rented Blacksmith Mac is not a fleet Mac")
        self.assertTrue(cron.mac_job_waiting({"status": "queued", "labels": ["glaeda-trusted-std-xcode-26.6"]}))
        self.assertFalse(cron.mac_job_waiting({"status": "queued", "labels": ["macos-26"]}), "a GitHub-hosted Mac is not the fleet")
        self.assertFalse(cron.mac_job_waiting({"status": "queued", "labels": ["macos-15-xlarge"]}))
        self.assertTrue(cron.mac_job_waiting({"status": "queued", "labels": ["self-hosted", "macOS"]}))
        for rented in (["depot-macos-15"], ["namespace-profile-macos-arm64"], ["warp-macos-15-arm64-6x"]):
            self.assertFalse(cron.mac_job_waiting({"status": "queued", "labels": rented}), f"{rented} is not a fleet Mac")
        self.assertFalse(cron.mac_job_waiting({"status": "queued", "labels": ["self-hosted", "linux"]}))
        self.assertFalse(cron.mac_job_waiting({"status": "waiting", "labels": ["glaeda-mini"]}), "an approval gate is not load")
        self.assertFalse(cron.mac_job_waiting({"status": "in_progress", "labels": ["glaeda-mini"]}))

    def test_a_foreground_bench_job_makes_the_part_yield(self):
        q = {"queue": [{"id": "mine", "labels": ["bench"]}, {"id": "o" * 24, "labels": ["bench", "measure"], "priority_class": "agent"}]}
        self.assertEqual(cron.wanted_by_other(q, {"mine"})["id"], "o" * 24)
        self.assertIsNone(cron.wanted_by_other({"queue": [{"id": "mine", "labels": ["bench"]}]}, {"mine"}))

    def test_any_foreground_job_the_bench_host_could_run_makes_the_part_yield(self):
        b = cron.BENCH_WORKER
        workers = [{"name": b, "labels": ["measure", "gui", "bench"]}, {"name": "cmux7s", "labels": ["cmux"]}]
        measure_only = {"queue": [{"id": "m" * 24, "labels": ["measure"]}], "workers": workers}
        self.assertEqual(cron.wanted_by_other(measure_only, {"mine"}, None, b)["id"], "m" * 24, "--label measure only")
        named = {"queue": [{"id": "n" * 24, "labels": ["x"], "placement_wait": f"{b} runs a step"}], "workers": workers}
        self.assertEqual(cron.wanted_by_other(named, {"mine"}, None, b)["id"], "n" * 24)
        jobs = [{"id": "t" * 24, "state": "queued", "target_worker": b, "labels": []}]
        self.assertEqual(cron.wanted_by_other({"queue": [], "workers": workers}, {"mine"}, jobs, b)["id"], "t" * 24, "--target-worker")
        background = {"queue": [{"id": "g" * 24, "labels": ["bench"], "background": True, "priority_class": "agent"}]}
        self.assertIsNone(cron.wanted_by_other(background, {"mine"}, None, b), "background jobs wait like the cron")
        build = {"queue": [{"id": "c" * 24, "labels": ["cmux"]}], "workers": workers}
        self.assertIsNone(cron.wanted_by_other(build, {"mine"}, None, b), "a build the bench host cannot take")
        self.assertIsNone(cron.wanted_by_other({"queue": []}, {"mine"}, [{"id": "t" * 24, "state": "running", "target_worker": b}], b))

    def test_fleet_exit_codes_yield_and_a_timeout_fails(self):
        self.assertEqual(cron.part_state(0, None), "done")
        for code in (69, 75, 76):
            self.assertEqual(cron.part_state(code, None), "yielded", code)
        self.assertEqual(cron.part_state(124, None), "failed")
        self.assertEqual(cron.part_state(1, None), "failed")
        self.assertEqual(cron.part_state(1, "j" * 24), "yielded", "cancelled by the cron for another job")
        cur = cron.new_measurement("a" * 40, "tip", ["motion"], T0)
        self.assertTrue(cron.record_part(cur, "motion", {"state": "failed", "timed_out": True}, "r")["timed_out"])


class LaunchTests(unittest.TestCase):
    def test_a_mark_that_never_arrives_is_a_row(self):
        report = {"split-spring": {"warm": [{"did_finish_launching_end": 300, "first_window_frame_committed": 500},
                                            {"did_finish_launching_end": 310}, {}]}}
        rows = cron.rows_of_part(cron.PART_BY_NAME["launch"], report, budgets_mod, {"rows": {}})
        self.assertEqual(rows["launch.warm.sidebar_rows_shown.missing_runs"]["p95"], 3, "never arrived: still a row")
        self.assertEqual(rows["launch.warm.first_window_frame_committed.missing_runs"]["p95"], 2)
        self.assertEqual(rows["launch.warm.did_finish_launching_end.missing_runs"]["p95"], 1, "a run with no marks misses each")
        self.assertNotIn("launch.warm.sidebar_rows_shown", rows)
        self.assertTrue(cron.over_target("launch.warm.sidebar_rows_shown.missing_runs", rows["launch.warm.sidebar_rows_shown.missing_runs"], None))
        base = {"launch.warm.sidebar_rows_shown.missing_runs": row(0, "runs", 0.5, 0)}
        regs = cron.find_regressions({"launch.warm.sidebar_rows_shown.missing_runs": rows["launch.warm.sidebar_rows_shown.missing_runs"]},
                                     base, None, None, budgets_mod)
        self.assertEqual(len(regs), 1, "a launch that starts hanging regresses")


class StateTrustTests(unittest.TestCase):
    REPO = 42

    def artifact(self, **wr):
        return {"id": 1, "workflow_run": {"id": 7, "repository_id": self.REPO, "head_repository_id": self.REPO,
                                          "head_branch": "feat-cmux-next", **wr}}

    def run_of(self, **over):
        run = {"path": cron.STATE_WORKFLOW, "event": "workflow_dispatch", "head_branch": "feat-cmux-next",
               "head_repository": {"id": self.REPO}, **over}
        return lambda run_id: run

    def test_only_this_workflow_on_the_branch_of_this_repository_writes_the_state(self):
        self.assertIsNone(cron.untrusted_state_artifact(self.artifact(), self.REPO, self.run_of()))
        self.assertIn("another repository", cron.untrusted_state_artifact(self.artifact(head_repository_id=9), self.REPO, self.run_of()))
        self.assertIn("is on", cron.untrusted_state_artifact(self.artifact(head_branch="evil"), self.REPO, self.run_of()))
        self.assertIn("not .github", cron.untrusted_state_artifact(self.artifact(), self.REPO, self.run_of(path=".github/workflows/x.yml")))
        self.assertIn("pull_request", cron.untrusted_state_artifact(self.artifact(), self.REPO, self.run_of(event="pull_request")))
        self.assertIsNotNone(cron.untrusted_state_artifact(self.artifact(), self.REPO, lambda run_id: None))
        self.assertIsNotNone(cron.untrusted_state_artifact(self.artifact(), None, self.run_of()))

    def test_a_state_sha_off_the_branch_is_dropped(self):
        good, evil = "a" * 40, "f" * 40
        ok = lambda sha: sha == good  # noqa: E731
        state = cron.empty_state(T0)
        state["current"] = cron.new_measurement(evil, "tip", ["build", "motion", "nope"], T0)
        state["last"] = {"sha": "--upload-pack=x"}
        state["last_good"] = {"sha": good, "rows": {}}
        state["regressions"] = [{"name": "a", "range": {"good": good, "bad": evil}}, {"name": "b", "range": {"good": good, "bad": good}}]
        state["row_ok"] = {"a": good, "b": evil}
        state["issue"] = "1; rm"
        dropped = cron.sanitize_state(state, ok)
        self.assertIsNone(state["current"])
        self.assertIsNone(state["last"])
        self.assertEqual(state["last_good"]["sha"], good)
        self.assertEqual([r["name"] for r in state["regressions"]], ["b"])
        self.assertEqual(state["row_ok"], {"a": good})
        self.assertIsNone(state["issue"])
        self.assertIn("current", dropped)
        state["current"] = cron.new_measurement(good, "tip", ["build", "motion", "nope"], T0)
        cron.sanitize_state(state, ok)
        self.assertEqual(state["current"]["parts_todo"], ["build", "motion"], "unknown parts go")
        state["current"] = cron.new_measurement(good, "bisect", ["motion"], T0, {"good": good, "bad": evil})
        cron.sanitize_state(state, ok)
        self.assertIsNone(state["current"], "a bisect step of a range off the branch goes")
        self.assertFalse(cron.is_sha("A" * 40))


class PlanReportTests(unittest.TestCase):
    """cmd_plan then cmd_report across ticks, with git, GitHub and the fleet faked."""

    def tick(self, d, now, tip):
        out = os.path.join(d, "plan.out")
        commits = [tip]

        def git(*args, check=True):
            if args[0] == "rev-parse":
                return tip
            if args[0] == "rev-list":
                return "\n".join(commits)
            raise AssertionError(args)
        with mock.patch.object(cron, "now_utc", lambda: now), mock.patch.object(cron, "git", git), \
                mock.patch.object(cron, "measure_version", lambda sha: 2), \
                mock.patch.object(cron, "commit_on_branch", lambda repo, t, known=(): cron.is_sha), \
                mock.patch.object(cron, "tree_published", lambda sha: True), \
                mock.patch.object(cron, "github_busy", lambda *a: None), \
                mock.patch.object(cron, "frame_pacing_runs", lambda repo: []), \
                mock.patch.object(cron, "is_ancestor", lambda a, b: False), \
                mock.patch.object(cron, "supported_parts_at", lambda sha: ["motion"]):
            cron.cmd_plan(argparse.Namespace(repo="o/r", dir=d, tip="HEAD", yield_mode="queued", no_mac=False, output=out))
            rep = os.path.join(d, "report.out")
            cron.cmd_report(argparse.Namespace(repo="o/r", dir=d, result=[], run_url="u", finish=False, issues=False, output=rep))
        with open(out) as f:
            plan = dict(line.split("=", 1) for line in f.read().splitlines())
        with open(rep) as f:
            report = dict(line.split("=", 1) for line in f.read().splitlines())
        os.remove(out)
        os.remove(rep)
        return plan, report

    def test_an_abandoned_measurement_is_saved_and_replaced_in_the_same_tick(self):
        with tempfile.TemporaryDirectory() as d:
            state = cron.empty_state(T0)
            state["persisted"] = True
            state["last"] = {"sha": "a" * 40, "measured_at": cron.iso(T0), "rows": {}}
            state["current"] = cron.new_measurement("b" * 40, "tip", ["build", "motion"], T0)
            with open(os.path.join(d, "state.json"), "w") as f:
                json.dump(state, f)
            plan, report = self.tick(d, at(cron.ABANDON_HOURS + 1), "c" * 40)
            self.assertEqual((plan["action"], plan["sha"], plan["part"]), ("part", "c" * 40, "build"))
            self.assertEqual(report["changed"], "true", "the drop is saved")
            with open(os.path.join(d, "state.json")) as f:
                saved = json.load(f)
            self.assertEqual(saved["history"][-1]["status"], "abandoned")
            self.assertNotIn("dirty", saved)

    def test_an_abandoned_measurement_with_nothing_new_is_still_saved(self):
        with tempfile.TemporaryDirectory() as d:
            state = cron.empty_state(T0)
            state["persisted"] = True
            state["last"] = {"sha": "c" * 40, "measured_at": cron.iso(T0), "rows": {}}
            state["current"] = cron.new_measurement("b" * 40, "tip", ["build", "motion"], T0)
            with open(os.path.join(d, "state.json"), "w") as f:
                json.dump(state, f)
            plan, report = self.tick(d, at(cron.ABANDON_HOURS + 1), "c" * 40)
            self.assertEqual(plan["action"], "none")
            self.assertEqual(report["changed"], "true")
            plan, report = self.tick(d, at(cron.ABANDON_HOURS + 2), "c" * 40)
            self.assertEqual(report["changed"], "false", "an idle tick does not save the state again")

    def test_a_forged_current_sha_never_reaches_the_fleet(self):
        with tempfile.TemporaryDirectory() as d:
            state = cron.empty_state(T0)
            state["persisted"] = True
            state["current"] = cron.new_measurement("refs/pull/1/head", "tip", ["motion"], T0)
            with open(os.path.join(d, "state.json"), "w") as f:
                json.dump(state, f)
            plan, _ = self.tick(d, at(1), "c" * 40)
            self.assertEqual(plan["sha"], "c" * 40)


class Review2Tests(OneRunRule):
    """Review 2 of pl-perf-cron: leftover part files, rows left out for refresh, Mac parts disabled, the bench host
    missing, and yielding that does not count against ABANDON_HOURS."""

    def report(self, d, state, results, now=None):
        with open(os.path.join(d, "state.json"), "w") as f:
            json.dump(state, f)
        with mock.patch.object(cron, "now_utc", lambda: now or at(1)):
            cron.cmd_report(argparse.Namespace(repo="o/r", dir=d, result=results, run_url="u", finish=False, issues=False,
                                               output=os.path.join(d, "report.out")))
        with open(os.path.join(d, "state.json")) as f:
            return json.load(f)

    def part_dir(self, d, name, result, report=None):
        part = os.path.join(d, f"in-{name}-{len(os.listdir(d))}")
        os.makedirs(part)
        with open(os.path.join(part, "result.json"), "w") as f:
            json.dump(result, f)
        if report is not None:
            with open(os.path.join(part, "report.json"), "w") as f:
                json.dump(report, f)
        return f"{name}={part}"

    STRESS = {"refresh_ms": 8.33, "summary": [{"action": "close", "layout": "stress", "frames_p50_ms": 8.3,
                                               "frames_p95_ms": 30.0, "missed": 0}]}

    def test_a_dropped_measurement_leaves_no_rows_to_the_next(self):
        with tempfile.TemporaryDirectory() as d:
            state = cron.empty_state(T0)
            state["persisted"] = True
            state["last"] = state["last_good"] = {"sha": "0" * 40, "measured_at": cron.iso(T0), "rows": {}, "refresh_ms": 8.33}
            state["current"] = cron.new_measurement("a" * 40, "tip", ["stress", "motion"], T0)
            # A's stress part finishes; its report is kept in parts/.
            state = self.report(d, state, [self.part_dir(d, "stress", {"state": "done", "worker": cron.BENCH_WORKER},
                                                         self.STRESS)])
            self.assertTrue(os.listdir(os.path.join(d, "parts")))
            # A is abandoned; the plan starts B and deletes A's part files.
            plan = PlanReportTests()
            with open(os.path.join(d, "state.json"), "w") as f:
                json.dump(state, f)
            plan.tick(d, at(cron.ABANDON_HOURS + 2), "b" * 40)
            self.assertEqual(os.listdir(os.path.join(d, "parts")), [], "A's part files go with A")
            with open(os.path.join(d, "state.json")) as f:
                state = json.load(f)
            self.assertEqual(state["current"]["sha"], "b" * 40)
            # Even a file left behind is never read: it names A, not B. B's stress part fails, its build part ran.
            with open(os.path.join(d, "parts", "stress.json"), "w") as f:
                json.dump({"measurement": "tip:" + "a" * 40 + ":x", "report": self.STRESS}, f)
            state["current"] = {**state["current"], "parts_todo": ["stress"], "parts": {"build": {"state": "done"}}}
            state = self.report(d, state, [self.part_dir(d, "stress", {"state": "failed"})], at(cron.ABANDON_HOURS + 3))
            self.assertIsNone(state["current"])
            self.assertEqual(state["history"][-1]["status"], "empty", "no rows of A reported under B")
            self.assertEqual(state["regressions"], [])

    def test_a_part_file_without_this_measurement_id_is_not_read(self):
        with tempfile.TemporaryDirectory() as d:
            os.makedirs(os.path.join(d, "parts"))
            with open(os.path.join(d, "parts", "stress.json"), "w") as f:
                json.dump(self.STRESS, f)  # the old format: no measurement id
            state = cron.empty_state(T0)
            state["persisted"] = True
            state["current"] = cron.new_measurement("b" * 40, "tip", ["motion"], T0)
            state["current"]["parts"] = {"stress": {"state": "done"}}
            state = self.report(d, state, [self.part_dir(d, "motion", {"state": "failed"})])
            self.assertEqual(state["history"][-1]["status"], "empty")

    def finish(self, state, sha, rows, refresh, hours, kind="tip"):
        rng = cron.bisect_groups(state)[0]["range"] if kind == "bisect" else None
        state["current"] = cron.new_measurement(sha, kind, [], at(hours), rng)
        state["current"]["parts"] = {"stress": {"state": "done"}}
        return cron.finish_measurement(state, rows, refresh, "bench", "r", at(hours), budgets_mod)

    def test_a_regressed_frame_row_on_another_refresh_stays_open(self):
        state = cron.empty_state(T0)
        name = "panes.close.stress.frame"
        self.finish(state, "a" * 40, {name: {**row(8.4), "refresh_ms": 8.33}}, 8.33, 0)
        self.assertEqual(self.finish(state, "b" * 40, {name: {**row(30.0), "refresh_ms": 8.33}}, 8.33, 1), "regressed")
        # c ran on the 60 Hz panel (VDISPLAY-FALLBACK): its frame row was measured but cannot be compared.
        self.assertEqual(self.finish(state, "c" * 40, {name: {**row(16.7), "refresh_ms": 16.67}}, 16.67, 2), "still")
        self.assertEqual([r["name"] for r in state["regressions"]], [name], "no false recovery")
        self.assertEqual(state["regressions"][0]["unmeasured_at"], "c" * 40)
        self.assertNotEqual(state["row_ok"].get(name), "c" * 40, "a row not compared is not good")
        self.assertEqual(state["last"]["sha"], "b" * 40, "the stale clock keeps running")
        self.assertIn("on another display refresh", state["history"][-1]["note"])

    def test_a_bisect_step_on_another_refresh_is_skipped(self):
        state = cron.empty_state(T0)
        name = "panes.close.stress.frame"
        self.finish(state, "a" * 40, {name: {**row(8.4), "refresh_ms": 8.33}}, 8.33, 0)
        self.finish(state, "e" * 40, {name: {**row(30.0), "refresh_ms": 8.33}}, 8.33, 1)
        verdict = self.finish(state, "c" * 40, {name: {**row(16.7), "refresh_ms": 16.67}}, 16.67, 2, "bisect")
        self.assertEqual(verdict, "skipped", "not 'good': the row was not judged")
        rng = state["regressions"][0]["range"]
        self.assertEqual((rng["good"], rng["bad"], rng["skip"]), ("a" * 40, "e" * 40, ["c" * 40]))

    def test_mac_parts_disabled_are_recorded_as_not_run(self):
        state = cron.empty_state(T0)
        why = "no gateway runner label"
        d = cron.decide(state, T0, "a" * 40, None, lambda sha: ALL, None, mac_disabled=why)
        self.assertEqual((d["part"], d["linux_part"]), ("", "diff-viewer"))
        cur = state["current"]
        self.assertEqual(cur["parts_todo"], LINUX_PARTS)
        self.assertEqual(cur["parts"]["stress"], {"state": "disabled", "reason": why})
        cur["parts_todo"] = []
        cur["parts"]["diff-viewer"] = cur["parts"]["web-ui"] = {"state": "done"}
        event = cron.finish_measurement(state, {"diff.stream.p95": row(20.0)}, None, "linux", "r", T0, budgets_mod)
        self.assertEqual(event, "first")
        self.assertIsNone(state["last"], "a Linux-only measurement does not reset the stale clock")
        self.assertIn("stress", state["history"][-1]["failed_parts"])
        state["mac_off"] = why
        self.assertIn(f"**Mac parts disabled:** {why}", cron.issue_body(state, "o/r", at(cron.STALE_HOURS + 1)))
        self.assertIn("**Stale:**", cron.issue_body(state, "o/r", at(cron.STALE_HOURS + 1)))

    def test_a_bisect_with_mac_parts_disabled_measures_only_linux_rows(self):
        state = cron.empty_state(T0)
        rng = {"good": "a" * 40, "bad": "e" * 40, "skip": [], "steps": 0}
        state["regressions"] = [{"name": "panes.close.stress.frame", "range": rng}]
        bisect = {"sha": "c" * 40, **cron.bisect_groups(state)[0]}
        d = cron.decide(state, T0, None, bisect, lambda sha: ALL, None, mac_disabled="off")
        self.assertIsNone(state["current"], "no bisect step that could only skip")
        self.assertEqual(d["action"], "none")

    def test_the_issue_says_when_the_bench_host_is_gone(self):
        with tempfile.TemporaryDirectory() as d:
            state = cron.empty_state(T0)
            state["persisted"] = True
            state["current"] = cron.new_measurement("b" * 40, "tip", ["motion"], T0)
            part = os.path.join(d, "part")
            os.makedirs(part)
            with open(os.path.join(part, cron.NOT_STARTED), "w") as f:
                json.dump({"reason": f"{cron.BENCH_WORKER} is not a controller worker now"}, f)
            state = self.report(d, state, [f"motion={part}"])
            self.assertEqual(state["current"]["parts_todo"], ["motion"], "no attempt")
            self.assertEqual(state["bench_missing"]["since"], cron.iso(at(1)))
            self.assertEqual(state["current"]["yield_since"], cron.iso(at(1)))
            self.assertIn("**Bench host missing:**", cron.issue_body(state, "o/r", at(1)))
            state = self.report(d, state, [self.part_dir(d, "motion", {"state": "yielded"})], at(2))
            self.assertNotIn("bench_missing", state)
            self.assertEqual(state["current"]["yield_hours"], 1.0)

    def test_fleet_check_writes_its_reason(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "part", cron.NOT_STARTED)
            with mock.patch.object(cron, "http_json", lambda url: {"queue": []}), \
                    mock.patch.object(cron, "run_capture", lambda argv, timeout=120: argparse.Namespace(
                        returncode=0, stdout="{}" if argv[1] == "workers" else "[]", stderr="")), \
                    mock.patch("sys.stdout", new=__import__("io").StringIO()):
                cron.cmd_fleet_check(argparse.Namespace(client="c", worker=cron.BENCH_WORKER, yield_mode="queued",
                                                        output=os.path.join(d, "out"), not_started=path))
            with open(path) as f:
                self.assertIn("is not a controller worker", json.load(f)["reason"])

    def test_dropped_frames_compare_on_a_slower_display_only(self):
        drop = "panes.close.stress.missed"
        at60 = {drop: {**row(1, "frames"), "refresh_ms": 16.67}}
        at120 = {drop: {**row(0, "frames"), "refresh_ms": 8.33}}
        self.assertEqual([r["name"] for r in cron.find_regressions(at60, at120, 16.67, 8.33, budgets_mod)], [drop],
                         "one new drop on a 60 Hz fallback run against a 120 Hz reference is real")
        faster = {drop: {**row(3, "frames"), "refresh_ms": 8.33}}
        self.assertEqual(cron.find_regressions(faster, {drop: {**row(0, "frames"), "refresh_ms": 16.67}}, 8.33, 16.67,
                                               budgets_mod), [], "the first 120 Hz run after a 60 Hz baseline opens nothing")
        self.assertEqual(cron.refresh_skipped(faster, {drop: {**row(0, "frames"), "refresh_ms": None}}, 8.33, None), [drop])

    def test_a_fallback_report_carries_the_real_display_refresh(self):
        report = {"rows": [], "display": {"requested_hz": 120, "vdisplay": False, "refresh_ms": 16.67,
                                          "host_display": "main 1 16.67", "line": "error: x"}}
        self.assertEqual(cron.refresh_ms_of(report), 16.67)

    def test_yielding_does_not_count_against_abandon_hours(self):
        state = cron.empty_state(T0)
        cron.decide(state, T0, "a" * 40, None, lambda sha: ["motion"], None)
        cron.decide(state, at(1), None, None, lambda sha: ["motion"], "nightly.yml waits")
        self.assertEqual(state["current"]["yield_since"], cron.iso(at(1)))
        d = cron.decide(state, at(cron.ABANDON_HOURS + 6), "b" * 40, None, lambda sha: ["motion"], "nightly.yml waits")
        self.assertEqual(state["current"]["sha"], "a" * 40, "17 h old, but only 1 h of it active")
        self.assertTrue(d["yielded"])
        cron.record_part(state["current"], "build", {"state": "done"}, "r", at(cron.ABANDON_HOURS + 7))
        self.assertAlmostEqual(state["current"]["yield_hours"], cron.ABANDON_HOURS + 6)
        cron.decide(state, at(cron.ABANDON_WALL_HOURS + 1), "b" * 40, None, lambda sha: ["motion"], "nightly.yml waits")
        self.assertEqual(state["current"]["sha"], "b" * 40, "the wall-clock cap still ends it")
        self.assertEqual(state["history"][-1]["status"], "abandoned")


class RefreshRebaseTests(OneRunRule):
    """A frame row regressed at one refresh, then measured only at another (the 120 Hz virtual display starts to
    work, or falls back to the panel)."""

    def setUp(self):
        super().setUp()
        self.state = cron.empty_state(T0)

    def measured(self, sha, frame, refresh, hours):
        rows = {"panes.x.frame": {**row(frame), "refresh_ms": refresh}, "t.e2e": {**row(5.0), "refresh_ms": refresh}}
        self.state["current"] = cron.new_measurement(sha, "tip", [], at(hours))
        self.state["current"]["parts"] = {"motion": {"state": "done"}}
        return cron.finish_measurement(self.state, rows, refresh, "bench", "u", at(hours), budgets_mod)

    def test_a_faster_refresh_rebases_a_regressed_frame_row_instead_of_holding_it_open_forever(self):
        self.assertEqual(self.measured("a" * 40, 16.7, 16.67, 0), "first")
        self.assertEqual(self.measured("b" * 40, 30.0, 16.67, 1), "regressed")
        self.assertEqual(self.measured("c" * 40, 8.4, 8.33, 2), "recovered")
        self.assertEqual(self.state["regressions"], [])
        self.assertEqual(self.state["last"]["sha"], "c" * 40, "the stale clock resets")
        self.assertIn("panes.x.frame", self.state["history"][-1]["rebased_note"])
        self.assertEqual(self.state["last_good"]["rows"]["panes.x.frame"]["p95"], 8.4)
        self.assertEqual(self.measured("d" * 40, 8.4, 8.33, 3), "good")
        self.assertEqual(self.measured("e" * 40, 12.0, 8.33, 4), "regressed", "a regression at the new refresh opens")

    def test_a_slower_fallback_refresh_keeps_the_regression_open_and_rebases_nothing(self):
        self.assertEqual(self.measured("a" * 40, 8.4, 8.33, 0), "first")
        self.assertEqual(self.measured("b" * 40, 12.0, 8.33, 1), "regressed")
        self.assertEqual(self.measured("c" * 40, 16.7, 16.67, 2), "still")
        self.assertEqual([r["name"] for r in self.state["regressions"]], ["panes.x.frame"])
        self.assertEqual(self.state["last_good"]["rows"]["panes.x.frame"]["p95"], 8.4)
        self.assertEqual(self.measured("d" * 40, 8.4, 8.33, 3), "recovered")


class FramePacingTests(unittest.TestCase):
    def test_it_starts_only_on_an_idle_fleet_once_a_day(self):
        old = {"id": 1, "status": "completed", "created_at": cron.iso(at(-30))}
        self.assertTrue(cron.frame_pacing_due([old], T0, None)[0])
        self.assertTrue(cron.frame_pacing_due([], T0, None)[0])
        self.assertFalse(cron.frame_pacing_due([old], T0, "nightly.yml waits for a Mac")[0])
        recent = {"id": 2, "status": "completed", "created_at": cron.iso(at(-3))}
        self.assertFalse(cron.frame_pacing_due([recent, old], T0, None)[0])
        running = {"id": 3, "status": "in_progress", "created_at": cron.iso(at(-30))}
        self.assertFalse(cron.frame_pacing_due([running], T0, None)[0])


class ControllerRouteTests(unittest.TestCase):
    SHA = "c" * 40

    def result(self, **over):
        value = {"run": 5, "attempt": 1, "sha": self.SHA, "part": "motion", "step_id": "s1", "state": "done",
                 "artifact_url": "https://store.example/a"}
        value.update(over)
        return json.dumps(value)

    def state_with(self, parts):
        state = cron.empty_state(T0)
        state["current"] = cron.new_measurement(self.SHA, "tip", parts, T0)
        return state

    def plan(self, state, raw):
        d = tempfile.mkdtemp()
        with open(os.path.join(d, "state.json"), "w") as f:
            json.dump(state, f)
        out = os.path.join(d, "plan.out")
        cron.result_plan(argparse.Namespace(dir=d, output=out, perf_result=raw), state, T0)
        with open(out) as f:
            return dict(line.split("=", 1) for line in f.read().splitlines())

    def test_a_result_for_the_part_in_flight_is_planned_for_the_report(self):
        plan = self.plan(self.state_with(["build", "motion"]), self.result())
        self.assertEqual((plan["action"], plan["part"], plan["sha"]), ("result", "motion", self.SHA))
        self.assertEqual(plan["frame_pacing"], "false", "a result run starts nothing else")

    def test_a_stale_or_bad_result_is_dropped(self):
        self.assertEqual(self.plan(self.state_with(["build"]), self.result())["action"], "none", "a part not to do")
        other = self.state_with(["motion"])
        other["current"]["sha"] = "d" * 40
        self.assertEqual(self.plan(other, self.result())["action"], "none", "another measurement")
        for raw in ("", "{", json.dumps([1]), self.result(part="diff-viewer"), self.result(part="nope"),
                    self.result(state="maybe"), self.result(sha="short")):
            self.assertIsNone(cron.controller_result(raw), raw)

    def test_a_repeated_result_is_dropped(self):
        state = self.state_with(["motion"])
        state["current"]["parts"]["motion"] = {"state": "yielded", "step_id": "s1", "yields": 1}
        self.assertEqual(self.plan(state, self.result())["action"], "none", "step s1 was stored already")
        self.assertEqual(self.plan(state, self.result(step_id="s2"))["action"], "result", "a new step of the same part")

    def test_result_files_for_record_part(self):
        failed_build = cron.result_files(json.loads(self.result(part="build", state="failed", error="no app")))
        self.assertTrue(failed_build["build_failed"])
        self.assertEqual(failed_build["tail"], ["no app"])
        timed = cron.result_files(json.loads(self.result(part="build", state="failed", timed_out=True)))
        self.assertFalse(timed["build_failed"], "a build past its cap is no build failure")
        self.assertTrue(timed["timed_out"])
        yielded = cron.result_files(json.loads(self.result(state="yielded", preempted_by="fg1")))
        self.assertEqual((yielded["state"], yielded["yielded_to"]), ("yielded", "fg1"))
        cur = cron.new_measurement(self.SHA, "tip", ["build", "motion", "diff-viewer"], T0)
        cron.record_part(cur, "build", failed_build, "r")
        self.assertEqual(cur["parts_todo"], ["diff-viewer"], "a failed build ends the Mac parts")

    def test_fetch_result_reads_the_signed_artifact(self):
        out = tempfile.mkdtemp()

        class Answer(io.BytesIO):
            def __enter__(self):
                return self

            def __exit__(self, *a):
                return False
        with mock.patch.object(cron.urllib.request, "urlopen", lambda req, timeout=0: Answer(b'{"rows": []}')):
            cron.cmd_fetch_result(argparse.Namespace(result=self.result(), out=out))
        with open(os.path.join(out, "result.json")) as f:
            self.assertEqual(json.load(f)["state"], "done")
        with open(os.path.join(out, "report.json")) as f:
            self.assertEqual(json.load(f), {"rows": []})

    def test_fetch_result_without_a_readable_artifact_is_a_failed_part(self):
        out = tempfile.mkdtemp()
        cron.cmd_fetch_result(argparse.Namespace(result=self.result(artifact_url="http://plain.example/a"), out=out))
        with open(os.path.join(out, "result.json")) as f:
            result = json.load(f)
        self.assertEqual(result["state"], "failed")
        self.assertFalse(os.path.exists(os.path.join(out, "report.json")))



class HostTests(OneRunRule):
    """Lead decision 2026-10-24: a part runs on any idle measure worker; every part of one measurement on one host;
    rows compare only with values of the same host; each row and the issue name the host and its macOS."""
    report_tick = DisplayTests.report_tick

    def test_the_build_host_is_kept_and_later_parts_are_asked_for_on_it(self):
        state = cron.empty_state(T0)
        d = cron.decide(state, T0, "a" * 40, None, lambda sha: ["motion"], None)
        self.assertEqual((d["part"], d["worker"]), ("build", ""), "the build goes to any idle measure worker")
        cur = state["current"]
        cron.record_part(cur, "build", {"state": "done", "worker": "aws-m4pro-9"}, "u", T0)
        cur.setdefault("host", "aws-m4pro-9")
        d = cron.decide(state, at(1), None, None, lambda sha: ["motion"], None)
        self.assertEqual((d["part"], d["worker"]), ("motion", "aws-m4pro-9"))

    def test_mac_rows_carry_their_host_and_never_compare_across_hosts(self):
        motion = {"rows": [{"name": "cmd_d.e2e", "p50": 30.0, "p95": 30.0, "unit": "ms"}], "macos": "26.4.1"}
        base = {"cmd_d.e2e@cmux20-bench": row(10.0)}
        with tempfile.TemporaryDirectory() as d:
            state = self.report_tick(d, {"motion": motion}, base, result={"state": "done", "worker": "aws-m4pro-9"})
        self.assertEqual(state["regressions"], [], "a slower host is not a regression of the bench host's rows")
        self.assertEqual([(u["name"], u["base"], u["why"]) for u in state["unconfirmed"]],
                         [("cmd_d.e2e@aws-m4pro-9", None, cron.NO_REFERENCE)],
                         "30 ms is three times the 10 ms target: reported, not compared with cmux20-bench's 10 ms")
        self.assertEqual(state["last"]["rows"]["cmd_d.e2e@aws-m4pro-9"]["p95"], 30.0)
        self.assertEqual((state["last"]["host"], state["last"]["macos"]), ("aws-m4pro-9", "26.4.1"))
        self.assertEqual(state["hosts"]["aws-m4pro-9"]["macos"], "26.4.1")
        body = cron.issue_body(state, "o/r", at(1))
        self.assertIn("on aws-m4pro-9 (macOS 26.4.1)", body)
        self.assertIn("aws-m4pro-9 (macOS 26.4.1, last part ", body.split("Coverage:")[1])
        with tempfile.TemporaryDirectory() as d:
            state = self.report_tick(d, {"motion": motion}, base, host="cmux20-bench",
                                     result={"state": "done", "worker": "cmux20-bench"})
        self.assertEqual([r["name"] for r in state["regressions"]], ["cmd_d.e2e@cmux20-bench"], "the same host compares")

    def test_a_bisect_step_runs_on_the_host_of_its_rows(self):
        state = cron.empty_state(T0)
        rng = {"good": "a" * 40, "bad": "c" * 40}
        bisect = {"sha": "b" * 40, "range": rng, "rows": ["cmd_d.e2e@aws-m4pro-9"]}
        d = cron.decide(state, T0, None, bisect, lambda sha: ["motion"], None)
        self.assertEqual((d["part"], state["current"]["host"], d["worker"]), ("build", "aws-m4pro-9", "aws-m4pro-9"))
        state = cron.empty_state(T0)
        cron.decide(state, T0, None, {**bisect, "rows": ["diff.stream.p95"]}, lambda sha: ["diff-viewer"], None)
        self.assertNotIn("host", state["current"], "a Linux row pins no Mac")

    def test_row_rules_read_the_name_without_its_host(self):
        self.assertEqual(cron.part_for_row("panes.close.stress.frame@cmux21"), "stress")
        self.assertTrue(cron.frame_sensitive("p.frame@cmux21", row(9.0)))
        self.assertTrue(cron.count_row("panes.close.stress.missed@cmux21", row(1, unit="count")))
        self.assertEqual(cron.target_of("p.frame@cmux21", {**row(9.0), "refresh_ms": 8.33}, None), 10.41)
        self.assertEqual(cron.target_of("cmd_d.e2e@cmux21", row(9.0), None), cron.LATENCY_TARGET_MS)

    def test_a_bad_host_name_never_reaches_a_job_name(self):
        state = cron.empty_state(T0)
        state["current"] = cron.new_measurement("a" * 40, "tip", ["motion"], T0)
        state["current"]["host"] = "x on y; rm"
        cron.sanitize_state(state, cron.is_sha)
        self.assertNotIn("host", state["current"])
        motion = {"rows": [{"name": "cmd_d.e2e", "p50": 9.0, "p95": 9.0, "unit": "ms"}]}
        with tempfile.TemporaryDirectory() as d:
            state = self.report_tick(d, {"motion": motion}, {}, result={"state": "done", "worker": "a b"})
        self.assertEqual(state["history"][-1]["status"], "empty", "a worker name the controller would refuse names no row")
        self.assertEqual(state["history"][-1]["failed_parts"], ["motion"])


class IssueRefreshTests(unittest.TestCase):
    def test_a_tick_that_finishes_nothing_rewrites_a_stale_body(self):
        state = cron.empty_state(T0)
        state["issue"] = 9
        state["regressions"] = [{"name": "diff.stream.p95", "p95": 32.9, "base": 19.5, "range": {"good": "a" * 40, "bad": "b" * 40}}]
        old = cron.ISSUE_MARK + "\n**Mac parts disabled:** no route"
        issue = {"number": 9, "title": cron.ISSUE_TITLE, "user": {"login": cron.ISSUE_AUTHOR}, "body": old, "state": "open"}
        calls = []

        def gh(path, method="GET", body=None, **k):
            calls.append((method, path, body))
            return issue
        with mock.patch.object(cron, "gh_request", gh):
            line = cron.refresh_issue_body("o/r", state, at(1))
        self.assertEqual(line, "rewrote the body of issue #9")
        patch = [b for m, _, b in calls if m == "PATCH"]
        self.assertEqual(len(patch), 1)
        self.assertNotIn("Mac parts disabled", patch[0]["body"])
        issue["body"] = patch[0]["body"]
        calls.clear()
        with mock.patch.object(cron, "gh_request", gh):
            self.assertEqual(cron.refresh_issue_body("o/r", state, at(1)), "")
        self.assertFalse([c for c in calls if c[0] != "GET"], "an unchanged body is not written again")
        issue["state"] = "closed"
        with mock.patch.object(cron, "gh_request", gh):
            self.assertEqual(cron.refresh_issue_body("o/r", state, at(1)), "", "a closed issue is left alone")

    def test_an_open_issue_with_no_confirmed_regression_closes_when_not_stale(self):
        state = cron.empty_state(T0)
        state["issue"] = 9
        state["unconfirmed"] = [{"name": "diff.stream.p95", "p95": 32.9, "samples": 1, "why": "x"}]
        issue = {"number": 9, "title": cron.ISSUE_TITLE, "user": {"login": cron.ISSUE_AUTHOR}, "body": cron.ISSUE_MARK, "state": "open"}
        calls = []

        def gh(path, method="GET", body=None, **k):
            calls.append((method, path, body))
            return issue
        stale = json.loads(json.dumps(state))
        with mock.patch.object(cron, "gh_request", gh):
            self.assertEqual(cron.refresh_issue_body("o/r", state, at(1)), "closed issue #9 (no confirmed regression)")
        writes = [(m, b) for m, _, b in calls if m != "GET"]
        self.assertEqual([m for m, _ in writes], ["PATCH", "POST"], "the body and the close in one PATCH, then the comment")
        self.assertEqual((writes[0][1]["state"], writes[0][1]["state_reason"]), ("closed", "completed"))
        self.assertIn("unconfirmed", writes[1][1]["body"])
        calls.clear()
        with mock.patch.object(cron, "gh_request", gh):
            self.assertEqual(cron.refresh_issue_body("o/r", state, at(1)), "", "a person reopened it: left open")
        self.assertFalse([c for c in calls if c[0] != "GET"])
        state["unconfirmed"].append({"name": "x.e2e", "p95": 1, "samples": 1, "why": "y"})
        calls.clear()
        with mock.patch.object(cron, "gh_request", gh):
            cron.refresh_issue_body("o/r", state, at(1))
        self.assertEqual([b.keys() for m, _, b in calls if m == "PATCH"], [{"body": 1}.keys()], "only its body is kept")
        calls.clear()
        with mock.patch.object(cron, "gh_request", gh):
            cron.refresh_issue_body("o/r", stale, at(30))
        self.assertFalse(any((b or {}).get("state") == "closed" for m, _, b in calls if m == "PATCH"),
                         "a stale cron keeps the issue open")


class ConfirmTests(unittest.TestCase):
    """Lead 2026-10-24: a row raises a regression only with CONFIRM_SAMPLES baseline values and outside their spread in
    2 consecutive tip measurements; otherwise it is unconfirmed in the issue (no confirm_all stub here)."""

    def setUp(self):
        self.state = cron.empty_state(T0)
        self.n = 0

    NAME = "diff.stream.p95"
    KEYED = "diff.stream.p95@" + cron.LEGACY_LINUX_CLASS  # the name migrate_state gives a row stored before host keys

    def measured(self, value, name="diff.stream.p95", the_row=None, parts=None):
        self.n += 1
        sha = format(self.n, "x") * 40
        self.state["current"] = cron.new_measurement(sha[:40], "tip", [], at(self.n))
        self.state["current"]["parts"] = parts or {cron.part_for_row(name): {"state": "done"}}
        rows = {} if value is None else {name: the_row or row(value, floor=10.0, budget=250.0)}
        return cron.finish_measurement(self.state, rows, None, "runner", f"u{self.n}", at(self.n), budgets_mod)

    def values(self, name="diff.stream.p95"):
        return [e["p95"] for e in self.state["row_history"][name]]

    def test_one_outlier_in_the_baseline_does_not_absorb_a_step(self):
        # Review 1 of the confirm rule, finding 2: with the max of the baseline as its spread, one noisy 34 in the last
        # good values let a step to 33 in as "within the spread", and the median followed it. A candidate never enters
        # the baseline, so the median stays; 33 is under the baseline's max, which no noise-free shift needs to pass
        # (review 2 of 8af6ea46de5, finding 1), so REF_RUNS candidates in a row confirm it, from the first of them.
        self.measured(19.5)
        self.state["row_history"][self.NAME] = [{"at": cron.iso(at(-h)), "p95": v, "sha": c * 40} for h, v, c in
                                                ((5, 19.5, "a"), (4, 20.0, "b"), (3, 34.0, "c"), (2, 20.5, "d"), (1, 19.8, "e"))]
        ok = self.state["row_ok"][self.NAME]
        self.assertEqual(self.measured(33.0), "good")
        first = self.state["history"][-1]["sha"]
        for _ in range(cron.REF_RUNS - 2):
            self.assertEqual(self.measured(33.0), "good")
        self.assertEqual(self.measured(33.0), "regressed")
        reg = self.state["regressions"][0]
        self.assertEqual((reg["range"]["good"], reg["first_bad"]["sha"]), (ok, first))
        self.assertEqual(self.values(), [19.5, 20.0, 34.0, 20.5, 19.8], "the step never entered the baseline")

    def test_an_outlier_in_a_short_baseline_holds_a_step_until_ref_runs_candidates(self):
        # Under REF_RUNS values the spread top is the max (34): 33 is inside it and never above it, so neither the
        # spread rule nor CONFIRM_SAMPLES values above the max confirm it; REF_RUNS candidates in a row do, from the
        # first of them (held forever otherwise: a held value never enters the baseline, so the 34 never leaves it).
        self.measured(19.5)
        self.state["row_history"][self.NAME] = [{"at": cron.iso(at(-h)), "p95": v, "sha": c * 40}
                                                for h, v, c in ((3, 19.5, "a"), (2, 20.0, "b"), (1, 34.0, "c"))]
        ok = self.state["row_ok"][self.NAME]
        self.assertEqual(self.measured(33.0), "good")
        first = self.state["history"][-1]["sha"]
        for _ in range(cron.REF_RUNS - 2):
            self.assertEqual(self.measured(33.0), "good")
        self.assertEqual(self.measured(33.0), "regressed")
        reg = self.state["regressions"][0]
        self.assertEqual((reg["range"]["good"], reg["first_bad"]["sha"]), (ok, first))
        self.assertIn(f"{cron.REF_RUNS} tip measurements in a row", reg["why"])

    def test_three_values_inside_a_noisy_baseline_do_not_open_a_regression(self):
        # Review 2 of 8af6ea46de5, finding 1: baseline [19, 20, 20.5, 22, 23] (median 20.5, floor 1.0) makes any value
        # over 22.55 a candidate; 22.7, 23.0, 22.8 are each at or under the baseline's max, which its own noise
        # reached, so they show no shift. They are held, not confirmed, and the baseline is not restarted.
        name = "cmd_d.e2e@cmux21"
        motion = {"motion": {"state": "done"}}
        self.measured(20.0, name, row(20.0, floor=1.0), parts=motion)
        self.state["row_history"][name] = [{"at": cron.iso(at(-h)), "p95": v, "sha": c * 40} for h, v, c in
                                           ((5, 19.0, "a"), (4, 20.0, "b"), (3, 20.5, "c"), (2, 22.0, "d"), (1, 23.0, "e"))]
        for v in (22.7, 23.0, 22.8):
            self.assertEqual(self.measured(v, name, row(v, floor=1.0), parts=motion), "good")
        self.assertEqual(self.names("regressions"), [])
        self.assertEqual(len(self.state["pending"][name]["values"]), 3)
        self.assertEqual(self.state.get("baseline_restarts") or [], [])
        self.assertTrue(self.state["unconfirmed"][0]["why"].startswith("within the baseline's values"))
        self.assertEqual(self.measured(21.0, name, row(21.0, floor=1.0), parts=motion), "good", "noise again")
        self.assertNotIn(name, self.state["pending"])

    def test_a_count_row_with_one_dropped_frame_in_its_baseline_needs_more_than_two_ones(self):
        # Review 2 of 8af6ea46de5, finding 1: baseline [0, 0, 1, 0, 0] has spread top 0, so two runs with one dropped
        # frame opened a regression although the baseline holds a 1. They are no shift; REF_RUNS in a row are.
        name = "panes.split.4x2.missed@" + cron.BENCH_WORKER

        def missed(n):
            return {**row(n, "frames", floor=cron.COUNT_FLOOR, budget=0), "refresh_ms": 8.33}
        self.measured(0, name, missed(0), parts={"motion": {"state": "done"}})
        self.state["row_history"][name] = [{"at": cron.iso(at(-h)), "p95": v, "sha": c * 40}
                                           for h, v, c in ((5, 0, "a"), (4, 0, "b"), (3, 1, "c"), (2, 0, "d"), (1, 0, "e"))]
        for _ in range(cron.REF_RUNS - 1):
            self.assertEqual(self.measured(1, name, missed(1), parts={"motion": {"state": "done"}}), "good")
        self.assertEqual(self.measured(1, name, missed(1), parts={"motion": {"state": "done"}}), "regressed")
        self.assertEqual(self.measured(2, name, missed(2), parts={"motion": {"state": "done"}}), "still")

    def test_a_short_baseline_with_one_noisy_value_is_not_confirmed_by_two_runs_inside_it(self):
        # Review 1 of 8af6ea46de5, finding 6: with 3 values the second-highest is the median, so 2 candidates confirmed
        # with no spread margin. 22.4 (+12 %) is the max of the baseline; 22.2 (+11 %) twice is inside it.
        name = "cmd_d.e2e@cmux21"

        def r(v):
            return row(v, floor=1.0)
        self.measured(20.0, name, r(20.0), parts={"motion": {"state": "done"}})
        self.state["row_history"][name] = [{"at": cron.iso(at(-h)), "p95": v, "sha": c * 40}
                                           for h, v, c in ((3, 20.0, "a"), (2, 20.0, "b"), (1, 22.4, "c"))]
        for _ in range(2):
            self.assertEqual(self.measured(22.2, name, r(22.2), parts={"motion": {"state": "done"}}), "good")
        self.assertEqual(self.names("regressions"), [])
        self.assertIn(name, self.state["pending"])

    def test_a_candidate_never_moves_row_ok_or_the_baseline(self):
        # Review 1, finding 4: row_ok moved with every unconfirmed value, so a later confirmation blamed a newer commit.
        for v in (20.0, 21.0, 30.0, 31.0):
            self.measured(v)
        ok = self.state["row_ok"][self.NAME]
        self.measured(36.0)  # within the spread: unconfirmed
        self.assertEqual((self.state["row_ok"][self.NAME], len(self.values())), (ok, 4))

    def test_a_count_row_regresses_from_zero_at_one(self):
        # Review 1, finding 1: 0 -> 1 dropped frame (count floor 0.5) must leave the spread (a Mac row, row@host).
        name = "panes.split.4x2.missed@" + cron.BENCH_WORKER

        def missed(n):
            return {**row(n, "frames", floor=cron.COUNT_FLOOR, budget=0), "refresh_ms": 8.33}
        for _ in range(3):
            self.measured(0, name, missed(0))
        self.assertEqual(self.measured(1, name, missed(1)), "good")
        self.assertEqual(self.measured(1, name, missed(1)), "regressed")
        self.assertEqual(self.values(name), [0, 0, 0])

    def test_a_sustained_step_inside_the_spread_confirms_on_the_third_run(self):
        # diff.stream.p95's floor is 10 ms: 35.5 is a candidate against the median 25 (+42 %, 10.5 ms) but only 9.5 ms
        # over the spread's top (26), so twice is no regression; a third time in a row against a full baseline is
        # (review 1 of 8af6ea46de5, finding 1: it restarted the baseline from the step and opened nothing).
        for v in (20.0, 20.0, 25.0, 26.0, 30.0):
            self.measured(v)
        ok = self.state["row_ok"][self.NAME]
        self.assertEqual(self.values(), [20.0, 20.0, 25.0, 26.0, 30.0])
        self.measured(35.5)
        first = self.state["history"][-1]["sha"]
        self.assertEqual(self.measured(35.5), "good")
        self.assertEqual(self.names("regressions"), [])
        self.assertEqual(self.measured(35.5), "regressed")
        reg = self.state["regressions"][0]
        self.assertEqual((reg["range"]["good"], reg["range"]["bad"], reg["first_bad"]["sha"]), (ok, first, first))
        self.assertEqual(self.values(), [20.0, 20.0, 25.0, 26.0, 30.0], "the step never entered the baseline")
        self.assertEqual(self.state.get("baseline_restarts") or [], [])

    def test_one_run_within_the_threshold_does_not_close_a_regression_or_move_its_range_start(self):
        # Review 1 of 8af6ea46de5, finding 5: one lucky run closed the regression and moved row_ok to itself, so the
        # next confirmation's range started after the culprit (and the issue closed and reopened).
        for v in (19.5, 20.0, 21.0):
            self.measured(v)
        ok = self.state["row_ok"][self.NAME]
        self.measured(45.0)
        first = self.state["history"][-1]["sha"]
        self.assertEqual(self.measured(46.0), "regressed")
        self.assertEqual(self.measured(20.0), "still", "one run within the threshold leaves it open")
        self.assertEqual((self.state["row_ok"][self.NAME], self.values()), (ok, [19.5, 20.0, 21.0]))
        self.assertIn("1 of the 2 runs", cron.issue_body(self.state, "o/r", at(self.n)))
        self.assertEqual(self.measured(46.0), "still")
        reg = self.state["regressions"][0]
        self.assertEqual((reg["range"]["good"], reg["first_bad"]["sha"]), (ok, first), "the range still starts before it")
        self.assertNotIn("recovering", reg, "worse again ends the recovery")
        self.assertEqual(self.measured(20.0), "still")
        self.assertEqual(self.measured(20.5), "recovered", "the second run in a row within the threshold closes it")
        self.assertEqual(self.values(), [19.5, 20.0, 21.0, 20.0, 20.5], "both recovery runs are good values")
        self.assertEqual(self.state["row_ok"][self.NAME], self.state["history"][-1]["sha"])

    def test_two_candidates_on_one_host_30_hours_apart_still_confirm(self):
        # Review 2 of 8af6ea46de5, finding 3: a 24 h wall-clock limit reset the streak of every row of a busy host
        # whose tip runs finish more than a day apart (a measurement may take ABANDON_WALL_HOURS; bisect steps run
        # between tips), so a real step there never confirmed. Consecutive runs on the host are the streak, whatever
        # their gap; the range from row_ok to the first of them holds the culprit.
        for v in (19.5, 20.0, 21.0):
            self.measured(v)
        ok = self.state["row_ok"][self.NAME]
        self.measured(45.0)
        first = self.state["history"][-1]["sha"]
        self.n += 30
        self.assertEqual(self.measured(46.0), "regressed")
        reg = self.state["regressions"][0]
        self.assertEqual((reg["range"]["good"], reg["first_bad"]["sha"]), (ok, first))

    def names(self, key):
        return [r["name"] for r in self.state.get(key) or []]

    def test_one_baseline_value_is_unconfirmed_not_a_regression(self):
        self.assertEqual(self.measured(19.5), "first")
        self.assertEqual(self.measured(32.9), "good", "the 2026-10-23 diff.stream.p95 case")
        self.assertEqual(self.names("regressions"), [])
        self.assertEqual(self.names("unconfirmed"), ["diff.stream.p95"])
        self.assertIn("1 of 3 values", self.state["unconfirmed"][0]["why"])
        # Review 2 of 8af6ea46de5, finding 5: the rule cannot judge a value against fewer than CONFIRM_SAMPLES, so a
        # building baseline takes it (holding it restarted the baseline later, a false alarm for a person).
        self.assertEqual(self.values(), [19.5, 32.9])
        self.assertEqual(self.state["pending"], {})

    def test_a_value_within_the_baseline_spread_is_unconfirmed(self):
        for v in (20.0, 21.0, 30.0, 31.0):  # each within the 10 ms floor of its reference then: baseline values
            self.measured(v)
        self.assertEqual(self.measured(36.0), "good", "above the median (25.5) by 10 % and the floor, under the spread top (30) + floor")
        self.assertEqual(self.names("regressions"), [])
        self.assertTrue(self.state["unconfirmed"][0]["why"].startswith("within the baseline's values (its max 31)"))
        self.assertEqual(len(self.state["row_history"]["diff.stream.p95"]), 4, "a candidate is never a baseline value")

    def test_outside_the_spread_once_waits_and_twice_regresses_from_the_first(self):
        for v in (19.5, 20.0, 21.0):
            self.measured(v)
        ok_sha = self.state["row_ok"]["diff.stream.p95"]
        self.assertEqual(self.measured(45.0), "good")
        first = self.state["history"][-1]["sha"]
        self.assertEqual(self.names("regressions"), [])
        self.assertIn("diff.stream.p95", self.state["pending"])
        self.assertEqual(len(self.state["row_history"]["diff.stream.p95"]), 3, "the pending value is not a good value")
        self.assertEqual(self.state["row_ok"]["diff.stream.p95"], ok_sha)
        self.assertEqual(self.measured(46.0), "regressed")
        reg = self.state["regressions"][0]
        self.assertTrue(reg["confirmed"])
        self.assertEqual((reg["range"]["good"], reg["range"]["bad"], reg["first_bad"]["sha"]), (ok_sha, first, first))
        self.assertEqual(self.state["pending"], {})

    def test_outside_the_spread_once_then_back_clears_it(self):
        for v in (19.5, 20.0, 21.0):
            self.measured(v)
        self.measured(45.0)
        self.assertEqual(self.measured(20.5), "good")
        self.assertEqual(self.state["pending"], {})
        self.assertEqual(self.names("regressions"), [])
        self.assertEqual(self.measured(45.0), "good", "a later spike starts again from one")

    def test_a_regression_from_before_the_rule_stays_open_with_its_range_when_the_next_run_misses_its_row(self):
        # Review 1 of 8af6ea46de5, finding 3: the migration made it a pending value dated at its first_bad; the first
        # tip run that did not judge the row (its part failed, another part on the host was done) or a day without
        # one dropped it with its range, bisect steps and open issue.
        x, p = "cmd_d.e2e@cmux21", "palette.open.e2e@cmux21"
        rng = {"good": "a" * 40, "bad": "b" * 40, "skip": ["c" * 40], "steps": 2}
        state = {"schema": cron.SCHEMA, "last_good": {"sha": "a" * 40, "measured_at": cron.iso(at(-72)), "rows": {x: row(19.5), p: row(5.0)}},
                 "row_history": {x: [{"at": cron.iso(at(-h)), "p95": v} for h, v in ((73, 19.4), (72, 19.5), (71, 19.6))],
                                 p: [{"at": cron.iso(at(-h)), "p95": 5.0} for h in (73, 72, 71)]},
                 "row_ok": {x: "a" * 40, p: "a" * 40},
                 "regressions": [{"name": x, "p95": 45.0, "base": 19.5, "unit": "ms", "range": dict(rng),
                                  "first_bad": {"sha": "b" * 40, "measured_at": cron.iso(at(-70))}}]}
        self.state = cron.migrate_state(state)
        self.assertEqual([(r["name"], r["confirmed"], r["range"]) for r in self.state["regressions"]], [(x, True, rng)])
        self.assertEqual(self.state["pending"], {})
        self.assertTrue(cron.issue_plan(self.state, None, T0, True, True, False)["open"])
        self.n = 5
        both = {"motion": {"state": "failed"}, "switch": {"state": "done"}}
        self.assertEqual(self.measured(5.0, p, row(5.0, floor=1.0), parts=both), "still")
        self.assertEqual([(r["name"], r["range"]) for r in self.state["regressions"]], [(x, rng)])
        self.n += 30
        self.assertEqual(self.measured(46.0, x, row(46.0, floor=1.0), parts={"motion": {"state": "done"}}), "still")
        reg = self.state["regressions"][0]
        self.assertEqual((reg["range"], reg["first_bad"]["sha"]), (rng, "b" * 40))
        for v, event in ((19.6, "still"), (19.7, "recovered")):
            self.assertEqual(self.measured(v, x, row(v, floor=1.0), parts={"motion": {"state": "done"}}), event,
                             "a noisy one closes by the normal rule")

    def test_an_old_single_value_pending_entry_becomes_a_streak_and_bad_shas_are_dropped(self):
        state = {"schema": cron.SCHEMA, "pending": {self.KEYED: {"sha": "b" * 40, "p95": 40.0, "at": cron.iso(T0)},
                                                    "x.e2e": {"values": [{"sha": "not-a-sha", "p95": 1.0}]}}}
        state = cron.migrate_state(state)
        self.assertEqual(state["pending"][self.KEYED]["values"][0]["p95"], 40.0)
        dropped = cron.sanitize_state(state, cron.is_sha)
        self.assertNotIn("x.e2e", state["pending"])
        self.assertIn("1 pending entries", dropped)

    def test_a_history_commit_off_the_branch_loses_its_sha_and_cannot_start_a_creep_range(self):
        # Review 2 of 8af6ea46de5, finding 9: creep_range_good takes range.good from the history shas; one not on the
        # branch stored a regression that the next load's sanitize_state dropped whole (the issue could close).
        state = {"schema": cron.SCHEMA, "row_history": {self.KEYED: [{"at": cron.iso(T0), "p95": 20.0, "sha": "c" * 40},
                                                                     {"at": cron.iso(T0), "p95": 20.5, "sha": "d" * 40}]}}
        dropped = cron.sanitize_state(state, lambda s: s == "d" * 40)
        self.assertEqual([e.get("sha") for e in state["row_history"][self.KEYED]], [None, "d" * 40])
        self.assertEqual([e["p95"] for e in state["row_history"][self.KEYED]], [20.0, 20.5], "the values stay")
        self.assertIn("1 row_history commits", dropped)

    def test_an_open_regression_from_before_the_rule_with_one_value_stays_open_under_its_new_name(self):
        state = {"schema": cron.SCHEMA, "last_good": {"sha": "a" * 40, "rows": {"diff.stream.p95": row(19.5)}},
                 "row_history": {"diff.stream.p95": [{"at": cron.iso(T0), "p95": 19.5}]},
                 "regressions": [{"name": "diff.stream.p95", "p95": 32.87, "base": 19.5, "unit": "ms",
                                  "range": {"good": "a" * 40, "bad": "b" * 40}, "first_bad": {"sha": "b" * 40}}]}
        state = cron.migrate_state(state)
        self.assertEqual([r["name"] for r in state["regressions"]], [self.KEYED], "renamed to its runner class first")
        self.assertEqual(cron.issue_plan(state, None, T0, True, True, False), {"open": True, "comment": None})


class MeasureVersionTests(unittest.TestCase):
    SCRIPT = "#!/bin/bash\nset -euo pipefail\nSPLIT_SPRING_MEASURE_VERSION=2\necho hi\n"

    def test_a_comment_or_log_edit_keeps_the_version_a_bump_changes_it(self):
        self.assertEqual(cron.measure_version_of("x", self.SCRIPT), 2)
        self.assertEqual(cron.measure_version_of("y", self.SCRIPT.replace("echo hi", "# why\necho hello")), 2)
        self.assertEqual(cron.measure_version_of("z", self.SCRIPT.replace("=2", "=3")), 3)
        # 5d4878cf9dd's form: a trailing comment (it read as no version, and the cron measured nothing for hours).
        self.assertEqual(cron.measure_version_of("c", self.SCRIPT.replace("=2", "=3  # 3: the display is 1920x1200")), 3)
        for line in ('export SPLIT_SPRING_MEASURE_VERSION="4"', "readonly SPLIT_SPRING_MEASURE_VERSION='4' # x",
                     "declare -r SPLIT_SPRING_MEASURE_VERSION=4"):
            self.assertEqual(cron.measure_version_of("d", "#!/bin/bash\n" + line + "\n"), 4, line)
        self.assertIsNone(cron.measure_version_of("0" * 40, "#!/bin/bash\nSPLIT_SPRING_MEASURE_VERSION=$X\n"))

    def test_an_old_blob_has_a_version_only_when_known(self):
        self.assertEqual(cron.measure_version_of("07ed24bb2427ca2681f2762221a579d6185feeda", "#!/bin/bash\n"), 2)
        self.assertIsNone(cron.measure_version_of("0" * 40, "#!/bin/bash\n"))

    def test_the_cron_measures_only_the_tip_version(self):
        versions = {"a": 2, "b": 2, "c": 1, "d": None}
        with mock.patch.object(cron, "measure_version", versions.get):
            self.assertEqual([c for c in "abcd" if cron.fleet_runs(c, 2)], ["a", "b"])
            self.assertFalse(cron.fleet_runs("d", None), "a tip with no version measures nothing")



class RateLimitTests(unittest.TestCase):
    """Lead 2026-10-24: a tick refused for GitHub's rate limit backs off to the next tick (no error, no state change)."""

    @staticmethod
    def limited(*a, **k):
        import email.message
        headers = email.message.Message()
        headers["x-ratelimit-remaining"] = "0"
        raise urllib.error.HTTPError("https://api.github.com/x", 403, "Forbidden", headers, io.BytesIO(b"{}"))

    def test_a_rate_limited_state_read_leaves_a_mark_and_the_plan_and_report_do_nothing(self):
        with tempfile.TemporaryDirectory() as d, mock.patch.dict(os.environ, {"GH_TOKEN": "t"}), \
                mock.patch.object(urllib.request, "urlopen", self.limited):
            cron.cmd_fetch_state(argparse.Namespace(repo="o/r", dir=d))
            self.assertTrue(os.path.exists(os.path.join(d, cron.RATE_LIMITED)))
            self.assertFalse(os.path.exists(os.path.join(d, "state.json")))
            out = os.path.join(d, "plan.out")
            cron.cmd_plan(argparse.Namespace(repo="o/r", dir=d, tip="HEAD", yield_mode="queued", no_mac=False,
                                             perf_result="", output=out))
            with open(out) as f:
                plan = dict(line.split("=", 1) for line in f.read().splitlines())
            self.assertEqual((plan["action"], plan["rate_limited"]), ("none", "true"))
            rep = os.path.join(d, "report.out")
            cron.cmd_report(argparse.Namespace(repo="o/r", dir=d, result=[], run_url="u", finish=False, issues=True, output=rep))
            with open(rep) as f:
                report = dict(line.split("=", 1) for line in f.read().splitlines())
            self.assertEqual(report["changed"], "false", "nothing is saved over the last trusted state")
            self.assertFalse(os.path.exists(os.path.join(d, "state.json")))

    def test_any_other_403_is_still_an_error(self):
        def forbidden(*a, **k):
            import email.message
            raise urllib.error.HTTPError("https://api.github.com/x", 403, "Forbidden", email.message.Message(),
                                         io.BytesIO(b'{"message": "Resource not accessible by integration"}'))
        with mock.patch.dict(os.environ, {"GH_TOKEN": "t"}), mock.patch.object(urllib.request, "urlopen", forbidden):
            with self.assertRaises(urllib.error.HTTPError) as ctx:
                cron.gh_request("/repos/o/r")
            self.assertNotIsInstance(ctx.exception, cron.RateLimited)

    def test_a_refused_issue_update_is_made_by_the_next_tick(self):
        state = cron.empty_state(T0)
        state["persisted"] = True
        state["issue"] = 9
        state["last"] = {"sha": "a" * 40, "measured_at": cron.iso(T0), "rows": {}}
        state["regressions"] = [{"name": "r.e2e", "p95": 30.0, "base": 20.0, "confirmed": True,
                                 "range": {"good": "a" * 40, "bad": "b" * 40}}]
        state["issue_retry"] = {"event": "regressed", "summary": "b: 1 row(s) regressed: r.e2e", "set_changed": True}
        own = {"number": 9, "title": cron.ISSUE_TITLE, "user": {"login": cron.ISSUE_AUTHOR}, "body": cron.ISSUE_MARK, "state": "open"}
        calls = []

        def gh(path, method="GET", body=None, **k):
            calls.append((method, path))
            return own
        with tempfile.TemporaryDirectory() as d:
            with open(os.path.join(d, "state.json"), "w") as f:
                json.dump(state, f)
            with mock.patch.object(cron, "gh_request", gh), mock.patch.object(cron, "now_utc", lambda: at(1)):
                cron.cmd_report(argparse.Namespace(repo="o/r", dir=d, result=[], run_url="u", finish=False, issues=True,
                                                   output=os.path.join(d, "r.out")))
            with open(os.path.join(d, "state.json")) as f:
                after = json.load(f)
        self.assertIn(("POST", "/repos/o/r/issues/9/comments"), calls, "the kept summary comment is posted")
        self.assertNotIn("issue_retry", after)

    def test_a_tick_with_nothing_new_makes_no_issue_call(self):
        state = cron.empty_state(T0)
        state["issue"] = 9
        state["regressions"] = [{"name": "r.e2e", "p95": 30.0, "base": 20.0, "range": {"good": "a" * 40, "bad": "b" * 40}}]
        own = {"number": 9, "title": cron.ISSUE_TITLE, "user": {"login": cron.ISSUE_AUTHOR},
               "body": cron.ISSUE_MARK + " old", "state": "open"}
        calls = []

        def gh(path, method="GET", body=None, **k):
            calls.append(method)
            return own
        with mock.patch.object(cron, "gh_request", gh):
            self.assertEqual(cron.refresh_issue_body("o/r", state, at(1)), "rewrote the body of issue #9")
            n = len(calls)
            self.assertEqual(cron.refresh_issue_body("o/r", state, at(1)), "")
        self.assertEqual(len(calls), n, "the body this cron wrote last is not read again")

    def test_a_verified_commit_is_not_asked_of_github_again(self):
        asked = []
        with mock.patch.object(cron, "gh_request", lambda p, *a, **k: asked.append(p) or {"status": "ahead"}), \
                mock.patch.object(cron.subprocess, "run", lambda *a, **k: mock.Mock(returncode=1)):
            ok = cron.commit_on_branch("o/r", "f" * 40)
            self.assertTrue(ok("a" * 40))
            self.assertEqual(len(asked), 1)
            ok2 = cron.commit_on_branch("o/r", "f" * 40, ok.verified())
            self.assertTrue(ok2("a" * 40))
        self.assertEqual(len(asked), 1, "the state's verified commits need no compare call")

    def test_a_rate_limited_compare_is_raised_not_read_as_off_the_branch(self):
        with mock.patch.object(cron, "gh_request", mock.Mock(side_effect=cron.RateLimited("x"))), \
                mock.patch.object(cron.subprocess, "run", lambda *a, **k: mock.Mock(returncode=1)):
            with self.assertRaises(cron.RateLimited):
                cron.commit_on_branch("o/r", "f" * 40)("a" * 40)


LINUX = "blacksmith-32vcpu-ubuntu-2404"
BENCH = cron.BENCH_WORKER


class HostReviewTests(unittest.TestCase):
    """Review 1 of 3c2bfd8efbb (rows keyed by host): Mac rows get a baseline while another row is regressed, a
    Linux-only range bisects whatever split-spring.sh says, a part run on another host is not labeled with the
    measurement's host, a host's regressions pin the tip to it, a macOS change rebases, a row over target with no
    reference is reported, Linux rows carry their runner class, and a closed issue is not read every tick."""

    def setUp(self):
        self.state = cron.empty_state(T0)
        self.n = 0

    def tip(self, rows, parts=None, hours=None):
        self.n += 1
        sha = format(self.n, "x")[-1] * 40
        when = at(hours if hours is not None else self.n)
        self.state["current"] = cron.new_measurement(sha, "tip", [], when)
        self.state["current"]["parts"] = parts or {"motion": {"state": "done"}, "diff-viewer": {"state": "done"}}
        return cron.finish_measurement(self.state, rows, 8.33, BENCH, f"u{self.n}", when, budgets_mod)

    def mac(self, value, macos="27.0"):
        return {f"cmd_d.e2e@{BENCH}": {**row(value, floor=0.5), "refresh_ms": 8.33, "macos": macos}}

    def open_diff_regression(self):
        """last_good holds Linux rows only and diff.stream.p95 is a confirmed open regression (the live state of
        2026-10-24, with enough values that the confirmation rule keeps it)."""
        name = f"diff.stream.p95@{LINUX}"
        for v in (19.5, 20.0, 21.0):
            self.tip({name: row(v, floor=10.0, budget=250.0)})
        self.tip({name: row(45.0, floor=10.0, budget=250.0)})
        self.assertEqual(self.tip({name: row(46.0, floor=10.0, budget=250.0)}), "regressed")
        return name

    def test_mac_rows_get_a_baseline_while_a_linux_row_is_regressed(self):
        diff = self.open_diff_regression()
        slow = {diff: row(46.0, floor=10.0, budget=250.0)}
        self.assertEqual(self.tip({**slow, **self.mac(5.0)}), "still")
        self.assertIn(f"cmd_d.e2e@{BENCH}", self.state["last_good"]["rows"], "a row with no reference is a baseline")
        self.tip({**slow, **self.mac(5.1)})
        self.tip({**slow, **self.mac(5.0)})
        self.assertEqual(len(self.state["row_history"][f"cmd_d.e2e@{BENCH}"]), 3)
        self.tip({**slow, **self.mac(6.0)})
        self.tip({**slow, **self.mac(6.0)})
        self.assertIn(f"cmd_d.e2e@{BENCH}", [r["name"] for r in self.state["regressions"]],
                      "20 % slower twice opens a regression although diff.stream.p95 stayed open")

    def test_mac_rows_get_a_baseline_when_a_part_failed(self):
        self.tip({f"diff.stream.p95@{LINUX}": row(20.0, floor=10.0)})
        self.tip(self.mac(5.0), parts={"motion": {"state": "done"}, "stress": {"state": "failed"}})
        self.assertEqual(self.state["last_good"]["rows"][f"cmd_d.e2e@{BENCH}"]["p95"], 5.0)
        self.assertEqual(self.state["last_good"]["sha"], "1" * 40, "the incomplete measurement is not the last good run")

    def test_a_linux_only_range_bisects_whatever_the_mac_script_says(self):
        rows = [f"diff.stream.p95@{LINUX}"]
        ok = cron.bisect_measurable(rows, lambda c: False, lambda c: ["diff-viewer"])
        self.assertEqual(cron.bisect_midpoint(["a" * 40, "b" * 40, "c" * 40], ok), "b" * 40)
        no_diff = cron.bisect_measurable(rows, lambda c: True, lambda c: ["motion"])
        self.assertIsNone(cron.bisect_midpoint(["a" * 40, "b" * 40], no_diff), "a commit without the bench is not measurable")
        mac = cron.bisect_measurable([f"cmd_d.e2e@{BENCH}"], lambda c: c != "b" * 40, lambda c: ["motion"])
        self.assertEqual(cron.bisect_midpoint(["a" * 40, "b" * 40, "c" * 40], mac), "a" * 40)
        # A Linux-only bisect step in flight is not dropped when the Mac script's version differs.
        rng = {"good": "a" * 40, "bad": "c" * 40, "skip": [], "steps": 0}
        state = cron.empty_state(T0)
        state["regressions"] = [{"name": rows[0], "range": rng}]
        state["current"] = cron.new_measurement("b" * 40, "bisect", ["diff-viewer"], T0, rng)
        cron.decide(state, at(1), None, None, lambda sha: ["diff-viewer"], None, measurable=lambda sha: False)
        self.assertEqual(state["current"]["sha"], "b" * 40)

    def report_tick(self, d, parts, host=None, base=None):
        state = cron.empty_state(T0)
        state["persisted"] = True
        state["last_good"] = state["last"] = {"sha": "a" * 40, "measured_at": cron.iso(T0), "rows": base or {},
                                              "refresh_ms": 8.33}
        state["current"] = cron.new_measurement("b" * 40, "tip", list(parts), T0)
        if host:
            state["current"]["host"] = host
        with open(os.path.join(d, "state.json"), "w") as f:
            json.dump(state, f)
        results = []
        for name, (result, report) in parts.items():
            part_dir = os.path.join(d, name)
            os.makedirs(part_dir)
            for file, value in (("result.json", result), ("report.json", report)):
                with open(os.path.join(part_dir, file), "w") as f:
                    json.dump(value, f)
            results.append(f"{name}={part_dir}")
        with mock.patch.object(cron, "now_utc", lambda: at(1)):
            cron.cmd_report(argparse.Namespace(repo="o/r", dir=d, result=results, run_url="u", finish=False, issues=False,
                                               output=os.path.join(d, "report.out")))
        with open(os.path.join(d, "state.json")) as f:
            return json.load(f)

    MOTION = {"rows": [{"name": "cmd_d.e2e", "p50": 5.0, "p95": 5.0, "unit": "ms"}], "macos": "27.0.1"}

    def test_a_part_that_ran_on_another_host_is_failed_not_relabeled(self):
        with tempfile.TemporaryDirectory() as d:
            state = self.report_tick(d, {"motion": ({"state": "done", "worker": "cmux20-bench"}, self.MOTION)},
                                     host="aws-m4pro-9")
        self.assertEqual(state["history"][-1]["status"], "empty", "no motion row compared")
        self.assertNotIn("cmd_d.e2e@aws-m4pro-9", (state["last_good"] or {}).get("rows") or {})
        self.assertEqual(state["history"][-1]["failed_parts"], ["motion"])
        with tempfile.TemporaryDirectory() as d:
            state = self.report_tick(d, {"motion": ({"state": "done"}, self.MOTION)})
        self.assertEqual(state["history"][-1]["failed_parts"], ["motion"], "no worker in the result: not the bench host")
        with tempfile.TemporaryDirectory() as d:
            state = self.report_tick(d, {"motion": ({"state": "done", "worker": "aws-m4pro-9"}, self.MOTION)},
                                     host="aws-m4pro-9")
        self.assertEqual(state["last"]["rows"]["cmd_d.e2e@aws-m4pro-9"]["macos"], "27.0")

    def test_the_gateway_part_takes_the_worker_the_step_ran_on(self):
        log = "cmux-ci: step 0123456789abcdef (exclusive, key k)\ncmux-ci: step 0123456789abcdef done on aws-m4pro-9\n"
        self.assertEqual(cron.step_worker(log), "aws-m4pro-9")
        self.assertIsNone(cron.step_worker("cmux-ci: step 0123456789abcdef cancelled on no worker\n"))

    def test_a_hosts_open_regression_pins_the_tip_to_it(self):
        rng = {"good": "a" * 40, "bad": "b" * 40, "skip": [], "steps": 0}
        self.state["regressions"] = [{"name": "cmd_d.e2e@aws-m4pro-9", "range": rng,
                                      "first_bad": {"sha": "b" * 40, "measured_at": cron.iso(T0)}}]
        d = cron.decide(self.state, at(1), "c" * 40, None, lambda sha: ["motion"], None)
        self.assertEqual((d["part"], d["worker"]), ("build", "aws-m4pro-9"))
        # A host the fleet check reported offline is not asked again for HOST_RETRY_HOURS (review 2: only an offline
        # report marks a host, never a measurement that waited).
        cron.note_host_offline(self.state, "aws-m4pro-9", "aws-m4pro-9 is not a controller worker now", at(2))
        self.assertTrue(cron.host_unreachable(self.state, "aws-m4pro-9", at(2)))
        d = cron.decide(self.state, at(3), None, None, lambda sha: ["motion"], None)
        self.assertEqual(d["worker"], "", "the tip in flight gives the offline host up at once")
        self.state["current"] = None
        d = cron.decide(self.state, at(4), "d" * 40, None, lambda sha: ["motion"], None)
        self.assertEqual(d["worker"], "", "the next tip goes to any idle measure host")
        self.assertFalse(cron.host_unreachable(self.state, "aws-m4pro-9", at(3 + cron.HOST_RETRY_HOURS)))

    def test_an_abandoned_bisect_step_is_skipped_next_time_only_when_a_part_failed_on_it(self):
        rng = {"good": "a" * 40, "bad": "e" * 40, "skip": [], "steps": 0}
        self.state["regressions"] = [{"name": f"cmd_d.e2e@{BENCH}", "range": rng}]
        self.state["current"] = cron.new_measurement("c" * 40, "bisect", ["build", "motion", "switch"], T0, rng)
        cron.decide(self.state, at(cron.ABANDON_HOURS + 1), None, None, lambda sha: ["motion"], None)
        self.assertEqual(self.state["regressions"][0]["range"]["skip"], [], "it waited for the fleet: still measurable")
        self.state["current"] = cron.new_measurement("c" * 40, "bisect", ["build", "motion", "switch"], T0, rng)
        cron.record_part(self.state["current"], "build", {"state": "done", "worker": BENCH}, "r")
        cron.record_part(self.state["current"], "motion", {"state": "failed"}, "r")
        cron.decide(self.state, at(cron.ABANDON_HOURS + 1), None, None, lambda sha: ["motion"], None)
        self.assertEqual(self.state["regressions"][0]["range"]["skip"], ["c" * 40], "a part failed on the commit")

    def test_another_hosts_regression_does_not_make_the_tip_incomplete(self):
        rng = {"good": "a" * 40, "bad": "b" * 40, "skip": [], "steps": 0}
        self.tip(self.mac(5.0))
        self.state["regressions"] = [{"name": "cmd_d.e2e@aws-m4pro-9", "p95": 30.0, "base": 10.0, "range": rng}]
        self.tip(self.mac(5.0))
        self.assertEqual(self.state["last"]["sha"], "2" * 40, "the stale clock resets")
        self.assertNotEqual(self.state["history"][-1]["status"], "incomplete")
        self.assertEqual([r["name"] for r in self.state["regressions"]], ["cmd_d.e2e@aws-m4pro-9"], "it stays open")

    def test_a_macos_change_rebases_and_closes_the_old_os_regression(self):
        with mock.patch.object(cron, "confirm_regressions", confirm_all):
            self.tip(self.mac(10.0, "26.4"))
            self.assertEqual(self.tip(self.mac(13.0, "26.4")), "regressed", "the same macOS compares")
            self.assertEqual(self.tip(self.mac(13.0, "27.0")), "recovered")
        self.assertEqual(self.state["regressions"], [])
        self.assertEqual(self.state["last_good"]["rows"][f"cmd_d.e2e@{BENCH}"]["p95"], 13.0)
        self.assertEqual(self.state["row_history"][f"cmd_d.e2e@{BENCH}"], [{"at": cron.iso(at(3)), "p95": 13.0}])
        self.assertIn("macOS", self.state["history"][-1]["rebased_note"])
        self.assertIn("macOS changed", cron.issue_body(self.state, "o/r", at(3)))
        self.assertEqual(self.tip(self.mac(13.1, "27.0.1")), "good", "a patch update is the same macOS")

    def test_a_row_over_target_with_no_reference_is_reported(self):
        found = cron.find_regressions({"a.e2e@h": row(30.0)}, {}, None, None, budgets_mod)
        self.assertEqual([(r["name"], r["base"], r["why"]) for r in found],
                         [("a.e2e@h", None, "over target, no reference on this host")])
        self.tip({f"diff.stream.p95@{LINUX}": row(20.0, floor=10.0)})
        self.tip({f"cmd_d.e2e@{BENCH}": {**row(30.0), "refresh_ms": 8.33}})
        self.assertEqual(self.state["regressions"], [])
        self.assertEqual([(u["name"], u["why"]) for u in self.state["unconfirmed"]],
                         [(f"cmd_d.e2e@{BENCH}", "over target, no reference on this host")])

    def test_linux_rows_carry_their_runner_class(self):
        report = {"stream": {"p95Ms": 20.0}}
        with tempfile.TemporaryDirectory() as d:
            state = self.report_tick(d, {"diff-viewer": ({"state": "done", "worker": LINUX}, report)})
        self.assertIn(f"diff.stream.p95@{LINUX}", state["last"]["rows"])
        with tempfile.TemporaryDirectory() as d:
            state = self.report_tick(d, {"diff-viewer": ({"state": "done"}, report)})
        self.assertEqual(state["history"][-1]["failed_parts"], ["diff-viewer"], "a Linux part with no runner class")

    def test_rows_from_before_host_keys_are_renamed(self):
        old = {"schema": cron.SCHEMA, "last_good": {"sha": "a" * 40, "rows": {"diff.stream.p95": row(19.5),
                                                                               "cmd_d.e2e": row(5.0)}},
               "row_history": {"diff.stream.p95": [{"at": cron.iso(T0), "p95": 19.5}]},
               "row_ok": {"cmd_d.e2e": "a" * 40, "cmd_t.e2e@aws-m4pro-9": "a" * 40}, "regressions": []}
        state = cron.migrate_state(old)
        self.assertEqual(sorted(state["last_good"]["rows"]), [f"cmd_d.e2e@{BENCH}", f"diff.stream.p95@{LINUX}"])
        self.assertEqual(list(state["row_history"]), [f"diff.stream.p95@{LINUX}"])
        self.assertEqual(sorted(state["row_ok"]), [f"cmd_d.e2e@{BENCH}", "cmd_t.e2e@aws-m4pro-9"])

    def test_a_closed_issue_is_forgotten(self):
        self.state["issue"] = 9
        issue = {"number": 9, "title": cron.ISSUE_TITLE, "user": {"login": cron.ISSUE_AUTHOR}, "body": cron.ISSUE_MARK,
                 "state": "closed"}
        with mock.patch.object(cron, "gh_request", lambda path, method="GET", body=None, **k: issue):
            cron.refresh_issue_body("o/r", self.state, at(1))
        self.assertIsNone(self.state["issue"], "no GET of a closed issue every tick")


X = "aws-m4pro-9"


class HostWaitTests(unittest.TestCase):
    """Review 2 of f4cb4f817ba: a pinned host that stays busy stalls nothing (the controller route's wait is a
    yield; a pinned measurement gives the host up after HOST_WAIT_HOURS); an abandon caused by the queue blames no
    commit and no host; a host gone from the fleet has its regressions closed; gateway labels follow the worker; parts
    stored before the host key keep their rows."""

    def setUp(self):
        self.state = cron.empty_state(T0)

    def regression_on(self, host):
        rng = {"good": "a" * 40, "bad": "b" * 40, "skip": [], "steps": 0}
        self.state["regressions"] = [{"name": f"cmd_d.e2e@{host}", "p95": 30.0, "base": 10.0, "range": rng,
                                      "first_bad": {"sha": "b" * 40, "measured_at": cron.iso(T0)}}]
        return rng

    def test_the_controller_routes_wait_for_a_result_is_a_yield(self):
        d = cron.decide(self.state, T0, "c" * 40, None, lambda sha: ["motion"], None, controller_route=True)
        self.assertEqual(d["part"], "build")
        self.assertEqual(self.state["current"]["yield_since"], cron.iso(T0), "no answer until the result run")
        cron.decide(self.state, at(cron.ABANDON_HOURS + 1), None, None, lambda sha: ["motion"], None, controller_route=True)
        self.assertEqual(self.state["current"]["sha"], "c" * 40, "the wait for the controller is not active time")
        cron.record_part(self.state["current"], "build", {"state": "done", "worker": BENCH}, "r", at(cron.ABANDON_HOURS + 2))
        self.assertNotIn("yield_since", self.state["current"])
        cron.decide(self.state, at(cron.ABANDON_WALL_HOURS + 1), None, None, lambda sha: ["motion"], None,
                    controller_route=True)
        self.assertIsNone(self.state["current"], "the wall-clock cap still ends it")

    def test_a_pinned_tip_gives_up_a_host_that_takes_no_part(self):
        self.regression_on(X)
        d = cron.decide(self.state, T0, "c" * 40, None, lambda sha: ["motion"], None, controller_route=True)
        self.assertEqual(d["worker"], X)
        d = cron.decide(self.state, at(cron.HOST_WAIT_HOURS - 0.5), None, None, lambda sha: ["motion"], None,
                        controller_route=True)
        self.assertEqual(d["worker"], X, "a host between two parts is not given up")
        d = cron.decide(self.state, at(cron.HOST_WAIT_HOURS + 0.5), None, None, lambda sha: ["motion"], None,
                        controller_route=True)
        self.assertEqual((d["action"], d["part"], d["worker"]), ("part", "build", ""), "any idle measure host now")
        self.assertEqual(self.state["current"]["sha"], "c" * 40, "the measurement goes on")
        self.assertFalse(cron.host_unreachable(self.state, X, at(cron.HOST_WAIT_HOURS + 0.5)), "busy is not offline")
        # A part done on another host pins the rest to it; its rows carry that host.
        cron.record_part(self.state["current"], "build", {"state": "done", "worker": BENCH}, "r", at(3))
        self.state["current"].setdefault("host", BENCH)
        self.assertIsNone(cron.part_host_refusal(self.state["current"], "motion", {"state": "done", "worker": BENCH}))
        # The host given up is not pinned again for HOST_WAIT_HOURS, then it is.
        self.state["current"] = None
        self.assertIsNone(cron.tip_pin_host(self.state, at(3)))
        self.assertEqual(cron.tip_pin_host(self.state, at(cron.HOST_WAIT_HOURS + 1 + cron.HOST_WAIT_HOURS)), X)

    def test_a_pin_from_the_build_is_given_up_too_and_a_result_resets_the_wait(self):
        cron.decide(self.state, T0, "c" * 40, None, lambda sha: ["motion", "switch"], None)
        cron.record_part(self.state["current"], "build", {"state": "done", "worker": X}, "r", at(0.5))
        self.state["current"]["host"] = X
        d = cron.decide(self.state, at(1), None, None, lambda sha: [], None)
        self.assertEqual((d["part"], d["worker"]), ("motion", X))
        cron.record_part(self.state["current"], "motion", {"state": "done", "worker": X}, "r", at(1 + cron.HOST_WAIT_HOURS))
        d = cron.decide(self.state, at(1.5 + cron.HOST_WAIT_HOURS), None, None, lambda sha: [], None)
        self.assertEqual((d["part"], d["worker"]), ("switch", X), "the host answered: its wait starts again")
        d = cron.decide(self.state, at(2 + 2 * cron.HOST_WAIT_HOURS), None, None, lambda sha: [], None)
        self.assertEqual((d["part"], d["worker"]), ("switch", ""))

    def test_a_bisect_step_waiting_for_its_host_ends_without_blame(self):
        rng = self.regression_on(X)
        self.state["current"] = cron.new_measurement("c" * 40, "bisect", ["build", "motion"], T0, rng)
        self.state["current"]["host"] = X
        self.assertEqual(cron.decide(self.state, T0, None, None, lambda sha: [], None)["worker"], X)
        cron.decide(self.state, at(cron.HOST_WAIT_HOURS + 1), None, None, lambda sha: [], None)
        self.assertIsNone(self.state["current"])
        self.assertEqual(self.state["history"][-1]["status"], "waited")
        self.assertEqual(rng["skip"], [], "the commit is still measurable")
        self.assertFalse(cron.host_unreachable(self.state, X, at(cron.HOST_WAIT_HOURS + 1)))
        self.assertTrue(cron.host_avoided(self.state, X, at(cron.HOST_WAIT_HOURS + 1)), "its ranges wait a while")
        self.assertFalse(cron.host_avoided(self.state, X, at(2 * cron.HOST_WAIT_HOURS + 2)))

    def test_an_abandoned_tip_marks_no_host(self):
        self.regression_on(X)
        cron.decide(self.state, T0, "c" * 40, None, lambda sha: ["motion"], None)
        self.state["current"].pop("host_asked_since", None)
        cron.decide(self.state, at(cron.ABANDON_HOURS + 1), None, None, lambda sha: ["motion"], None)
        self.assertEqual(self.state["history"][-1]["status"], "abandoned")
        self.assertFalse(cron.host_unreachable(self.state, X, at(cron.ABANDON_HOURS + 1)))

    def test_only_an_offline_report_marks_a_host_unreachable(self):
        cron.note_host_offline(self.state, X, f"{X} is busy or wanted: job 0123 (build, queued)", T0)
        cron.note_host_offline(self.state, X, f"{X} offers no exclusive slot now (a step runs there)", T0)
        self.assertFalse(cron.host_unreachable(self.state, X, T0))
        for reason in (f"{X} is not a controller worker now", f"{X} is not healthy",
                       f"{X} has not been seen for over 3 minutes"):
            state = cron.empty_state(T0)
            cron.note_host_offline(state, X, reason, T0)
            self.assertTrue(cron.host_unreachable(state, X, T0), reason)

    def test_the_report_marks_the_host_the_fleet_check_found_offline(self):
        with tempfile.TemporaryDirectory() as d:
            state = cron.empty_state(T0)
            state["persisted"] = True
            state["current"] = cron.new_measurement("b" * 40, "tip", ["motion"], T0)
            state["current"]["host"] = X
            part = os.path.join(d, "part")
            os.makedirs(part)
            with open(os.path.join(part, cron.NOT_STARTED), "w") as f:
                json.dump({"reason": f"{X} is not healthy", "worker": X}, f)
            with open(os.path.join(d, "state.json"), "w") as f:
                json.dump(state, f)
            with mock.patch.object(cron, "now_utc", lambda: at(1)):
                cron.cmd_report(argparse.Namespace(repo="o/r", dir=d, result=[f"motion={part}"], run_url="u",
                                                   finish=False, issues=False, output=os.path.join(d, "r.out")))
            with open(os.path.join(d, "state.json")) as f:
                state = json.load(f)
        self.assertTrue(cron.host_unreachable(state, X, at(1)))

    def tip(self, rows, when, sha):
        self.state["current"] = cron.new_measurement(sha, "tip", [], when)
        self.state["current"]["parts"] = {"motion": {"state": "done"}}
        return cron.finish_measurement(self.state, rows, 8.33, BENCH, "u", when, budgets_mod)

    def test_a_host_gone_from_the_fleet_has_its_regressions_closed(self):
        here = {f"cmd_t.e2e@{BENCH}": {**row(5.0), "refresh_ms": 8.33}}
        self.state["last_good"] = {"sha": "a" * 40, "measured_at": cron.iso(T0), "rows": dict(here), "refresh_ms": 8.33}
        self.regression_on(X)
        self.state["hosts"] = {X: {"macos": "26.4", "last_part_at": cron.iso(T0)}}
        self.tip(here, at(10), "c" * 40)
        self.assertEqual([r["name"] for r in self.state["regressions"]], [f"cmd_d.e2e@{X}"], "busy a while: open")
        self.assertEqual(cron.tip_pin_host(self.state, at(10)), X)
        self.assertEqual(self.tip(here, at(cron.HOST_GONE_HOURS + 1), "d" * 40), "recovered")
        self.assertEqual(self.state["regressions"], [])
        self.assertIn("host gone", self.state["history"][-1]["rebased_note"])
        self.assertIsNone(cron.tip_pin_host(self.state, at(cron.HOST_GONE_HOURS + 1)))

    def test_a_host_with_no_record_starts_its_gone_clock(self):
        here = {f"cmd_t.e2e@{BENCH}": {**row(5.0), "refresh_ms": 8.33}}
        self.state["last_good"] = {"sha": "a" * 40, "measured_at": cron.iso(T0), "rows": dict(here), "refresh_ms": 8.33}
        self.regression_on(X)
        self.tip(here, at(1), "c" * 40)
        self.tip(here, at(cron.HOST_GONE_HOURS), "d" * 40)
        self.assertEqual(len(self.state["regressions"]), 1, "72 h since the cron first missed it, not since T0")
        self.tip(here, at(cron.HOST_GONE_HOURS + 2), "e" * 40)
        self.assertEqual(self.state["regressions"], [])

    def test_a_linux_only_measurement_retires_no_mac_host(self):
        diff = {f"diff.stream.p95@{LINUX}": row(20.0, floor=10.0)}
        self.state["last_good"] = {"sha": "a" * 40, "measured_at": cron.iso(T0), "rows": dict(diff)}
        self.regression_on(X)
        self.state["hosts"] = {X: {"last_part_at": cron.iso(T0)}}
        self.tip(diff, at(cron.HOST_GONE_HOURS + 1), "c" * 40)
        self.assertEqual(len(self.state["regressions"]), 1, "no Mac part ran anywhere: the Mac route is down")

    def test_gateway_step_labels_follow_the_worker(self):
        status = {"workers": [{"name": BENCH, "labels": ["bench", "measure", "macos-27"]},
                              {"name": X, "labels": ["measure", "macos-26"]}]}
        self.assertEqual(cron.step_labels(status, BENCH), ["bench", "measure"])
        self.assertEqual(cron.step_labels(status, X), ["measure"])
        self.assertIsNone(cron.step_labels(status, "gone"))
        with tempfile.TemporaryDirectory() as d:
            argvs = []

            class Proc:
                returncode = 0

                def __init__(self, argv, **k):
                    argvs.append(argv)

                def poll(self):
                    return 0
            o = argparse.Namespace(sha="c" * 40, args="[]", artifact="a.json", key="k", run_seconds=60, out=d,
                                   worker=X, client="cmux-ci")
            with mock.patch.object(cron, "http_json", lambda url, timeout=30: status), \
                    mock.patch.object(cron.subprocess, "Popen", Proc), mock.patch("sys.stdout", new=io.StringIO()):
                cron.cmd_run_part(o)
            argv = argvs[0]
            labels = [argv[i + 1] for i, a in enumerate(argv) if a == "--label"]
            self.assertEqual(labels, ["measure"], "a non-bench host's step does not ask for the bench label")
        with tempfile.TemporaryDirectory() as d:
            o = argparse.Namespace(sha="c" * 40, args="[]", artifact="a.json", key="k", run_seconds=60, out=d,
                                   worker="gone", client="cmux-ci")
            with mock.patch.object(cron, "http_json", lambda url, timeout=30: status), \
                    mock.patch.object(cron.subprocess, "Popen", mock.Mock(side_effect=AssertionError("no step"))), \
                    mock.patch("sys.stdout", new=io.StringIO()):
                cron.cmd_run_part(o)
            self.assertTrue(os.path.exists(os.path.join(d, cron.NOT_STARTED)), "no step: not an attempt")

    def test_parts_done_before_the_host_key_keep_their_rows(self):
        old = {"schema": cron.SCHEMA, "regressions": [], "current": {
            "sha": "c" * 40, "kind": "tip", "started_at": cron.iso(T0), "parts_todo": ["switch"],
            "parts": {"build": {"state": "done"}, "motion": {"state": "done"}, "diff-viewer": {"state": "done"},
                      "stress": {"state": "failed"}}}}
        cur = cron.migrate_state(old)["current"]
        self.assertEqual(cur["parts"]["motion"]["worker"], BENCH)
        self.assertEqual(cur["parts"]["diff-viewer"]["worker"], LINUX)
        self.assertNotIn("worker", cur["parts"]["stress"])
        self.assertEqual(cur["host"], BENCH, "the later parts run where the app was built")
        fresh = {"schema": cron.SCHEMA, "regressions": [], "current": {
            "sha": "c" * 40, "kind": "tip", "started_at": cron.iso(T0), "parts_todo": [], "host": X,
            "parts": {"motion": {"state": "done", "worker": X}}}}
        self.assertEqual(cron.migrate_state(fresh)["current"]["parts"]["motion"]["worker"], X)



class PendingAndBuildingTests(unittest.TestCase):
    """Review 2 of the host-keyed rows: a pending value is confirmed only by the next tip measurement on its own host,
    which the tip pin steers there; a baseline still building takes no regressed value."""

    def setUp(self):
        self.state = cron.empty_state(T0)
        self.n = 0

    def measured(self, rows, hours=None, parts=None):
        self.n += 1
        t = at(hours if hours is not None else self.n)
        self.state["current"] = cron.new_measurement((format(self.n, "x") * 40)[:40], "tip", [], t)
        self.state["current"]["parts"] = parts or {"motion": {"state": "done"}}
        rows = {k: row(v, floor=1.0) for k, v in rows.items()}
        return cron.finish_measurement(self.state, rows, None, "h", f"u{self.n}", t, budgets_mod)

    X, Y = "cmd_d.e2e@cmux21", "cmd_d.e2e@aws-m4pro-9"

    def baseline(self):
        for v in (20.0, 20.5, 21.0):
            self.measured({self.X: v, self.Y: v})

    def test_a_pending_value_waits_for_its_own_host_and_is_not_confirmed_on_another(self):
        self.baseline()
        self.measured({self.X: 40.0})
        self.assertIn(self.X, self.state["pending"])
        self.assertEqual(cron.tip_pin_host(self.state, at(self.n)), "cmux21", "the confirming run goes to the pending host")
        self.measured({self.Y: 20.0})
        self.assertIn(self.X, self.state["pending"], "a run on another host leaves it")
        self.assertEqual(self.measured({self.X: 41.0}), "regressed")

    def test_a_pending_value_expires_when_its_host_does_not_judge_it_again(self):
        self.baseline()
        self.measured({self.X: 40.0})
        self.measured({"palette.open.e2e@cmux21": 5.0})
        self.assertNotIn(self.X, self.state["pending"], "the next run on its host did not judge the row")
        self.assertEqual(self.measured({self.X: 41.0}), "good", "one value outside the spread again, not two in a row")
        self.assertIn(self.X, self.state["pending"])

    def test_a_failed_part_between_two_candidates_still_confirms(self):
        # Review 2 of the confirm rule, finding 2: on a busy host a part alternates between done and failed. A tip
        # whose other part on the row's host was done but whose own part failed did not judge the row: that keeps it
        # held, so done-failed-done confirms (review 1 of 8af6ea46de5, finding 4: the old test's failed tip measured
        # no row and returned before the expiry, so it passed without the rule).
        self.baseline()
        self.measured({self.X: 40.0})
        first = self.state["history"][-1]["sha"]
        self.measured({"palette.open.e2e@cmux21": 5.0}, parts={"motion": {"state": "failed"}, "switch": {"state": "done"}})
        self.assertIn(self.X, self.state["pending"], "its own part failed: not judged, still held")
        self.assertEqual(self.measured({self.X: 41.0}), "regressed")
        self.assertEqual(self.state["regressions"][0]["first_bad"]["sha"], first)

    def test_a_pending_value_waits_30_hours_for_its_host_and_still_confirms(self):
        # Review 2 of 8af6ea46de5, finding 3: no run on the pending host for 30 h (runs on another host meanwhile)
        # does not end the streak; the next run there confirms it.
        self.baseline()
        self.measured({self.X: 40.0}, hours=10)
        first = self.state["history"][-1]["sha"]
        self.measured({self.Y: 20.0}, hours=25)
        self.assertEqual(self.measured({self.X: 41.0}, hours=40), "regressed")
        self.assertEqual(self.state["regressions"][0]["first_bad"]["sha"], first)

    def test_a_pending_value_of_a_gone_host_is_dropped(self):
        self.baseline()
        self.measured({self.X: 40.0}, hours=10)
        cron.mark_host(self.state, "cmux21", gone_at=cron.iso(at(11)))
        self.measured({self.Y: 20.0}, hours=12)
        self.assertNotIn(self.X, self.state["pending"], "a gone host never judges its row again")

    def test_a_building_baseline_takes_every_value_and_never_restarts(self):
        # Review 2 of 8af6ea46de5, finding 5: the first CONFIRM_SAMPLES values cannot be judged by the rule, so they all
        # are baseline values. Holding them made a low first value (after every rebase) hold the normal values that
        # followed, and restart the baseline after 3: a false alarm that kept the issue open for a person.
        self.measured({self.X: 15.0})
        for v in (20.0, 20.5, 20.2):
            self.assertEqual(self.measured({self.X: v}), "good")
        self.assertEqual([e["p95"] for e in self.state["row_history"][self.X]], [15.0, 20.0, 20.5, 20.2])
        self.assertEqual((self.state["pending"], self.state.get("baseline_restarts") or []), ({}, []))
        self.assertEqual(cron.issue_plan(self.state, "good", at(self.n), False, False, False), {"open": False, "comment": None})
        self.assertEqual(self.measured({self.X: 30.0}), "good", "a full baseline holds a candidate")
        self.assertIn(self.X, self.state["pending"])

    def test_a_low_first_value_after_a_version_rebase_is_no_false_alarm(self):
        self.baseline()
        cron.rebase_rows(self.state, {self.X: row(15.0)}, [self.X], at(self.n))
        for v in (20.0, 20.5, 20.2, 20.4):
            self.assertEqual(self.measured({self.X: v}), "good")
        self.assertEqual(self.state.get("baseline_restarts") or [], [])
        self.assertEqual(self.state["regressions"], [])


class LegacyRestartTests(unittest.TestCase):
    """Review 2 of 8af6ea46de5, findings 7 and 8: 8af6ea46de5's restarts (no 'seen' key) open the issue once for a
    person, a comment names them, and a rate-limited tick keeps the basis on which a person's close acknowledges them."""

    def legacy(self):
        state = {"schema": cron.SCHEMA, "baseline_restarts": [
            {"name": "cmd_d.e2e@cmux21", "at": cron.iso(at(-5)), "before": [20.0, 20.5, 21.0], "after": [30.0, 31.0, 30.5]}]}
        return cron.migrate_state(state)

    def test_a_restart_from_before_the_seen_key_opens_the_issue_once_with_a_restart_comment(self):
        state = self.legacy()
        self.assertEqual([x["seen"] for x in state["baseline_restarts"]], [False])
        self.assertEqual(cron.issue_plan(state, None, T0, False, True, False), {"open": True, "comment": "restart"},
                         "a cron-closed issue reopens with a comment that names the restart, not 'no row regressed'")
        self.assertEqual(cron.issue_plan(state, "good", T0, True, True, False), {"open": True, "comment": "restart"},
                         "an open issue gets the notice too (a body edit notifies nobody)")
        self.assertIn("**(not seen yet)**", cron.issue_body(state, "o/r", T0))
        state["baseline_restarts"][0]["noted"] = True
        self.assertEqual(cron.issue_plan(state, "good", T0, True, True, False), {"open": True, "comment": None})
        self.assertEqual(cron.migrate_state(state)["baseline_restarts"][0]["seen"], False, "migration runs once a key")

    def test_manage_issue_posts_the_restart_comment_once(self):
        state = self.legacy()
        state["issue"] = 9
        own = {"number": 9, "title": cron.ISSUE_TITLE, "user": {"login": cron.ISSUE_AUTHOR}, "body": cron.ISSUE_MARK,
               "state": "closed"}
        posts = []

        def gh(path, method="GET", body=None, **k):
            if method == "POST":
                posts.append(body["body"])
            return own
        with mock.patch.object(cron, "gh_request", gh):
            self.assertEqual(cron.manage_issue("o/r", state, None, T0, "u", "abc: no row regressed (3 rows)", False),
                             "reopened issue #9")
        self.assertEqual(len(posts), 1)
        self.assertIn("1 baseline restart(s) to check by hand", posts[0])
        self.assertNotIn("no row regressed", posts[0])
        self.assertTrue(state["baseline_restarts"][0]["noted"])

    def test_a_rate_limited_tick_keeps_the_basis_of_a_persons_close(self):
        state = self.legacy()
        state.update(persisted=True, issue=9, issue_seen={"hash": "x", "open": True},
                     last={"sha": "a" * 40, "measured_at": cron.iso(T0), "rows": {}})
        own = {"number": 9, "title": cron.ISSUE_TITLE, "user": {"login": cron.ISSUE_AUTHOR}, "body": cron.ISSUE_MARK,
               "state": "open"}

        def gh(path, method="GET", body=None, **k):
            if method != "GET":
                raise cron.RateLimited("PATCH")
            return own
        with tempfile.TemporaryDirectory() as d:
            with open(os.path.join(d, "state.json"), "w") as f:
                json.dump(state, f)
            with mock.patch.object(cron, "gh_request", gh), mock.patch.object(cron, "now_utc", lambda: at(1)), \
                    mock.patch("sys.stdout", io.StringIO()):
                cron.cmd_report(argparse.Namespace(repo="o/r", dir=d, result=[], run_url="u", finish=False, issues=True,
                                                   output=os.path.join(d, "r.out")))
            with open(os.path.join(d, "state.json")) as f:
                after = json.load(f)
        self.assertEqual(after["issue_seen"], {"hash": None, "open": True})
        cron.acknowledge_restarts(after, {"state": "closed", "closed_at": cron.iso(at(2))})
        self.assertEqual(cron.unseen_restarts(after), [], "the person's close after the limited tick counts")


class MeasureVersionGateTests(OneRunRule):
    """Review 1 of the confirm rule, finding 4: the measurement version gated which commits run, not the baseline;
    a Mac row is now compared only with values of its own version, and a bump rebases it."""
    NAME = "cmd_d.e2e@" + cron.BENCH_WORKER

    def setUp(self):
        super().setUp()
        self.state = cron.empty_state(T0)
        self.n = 0

    def measured(self, value, version, config=None):
        self.n += 1
        self.state["current"] = cron.new_measurement((format(self.n, "x") * 40)[:40], "tip", [], at(self.n))
        self.state["current"]["parts"] = {"motion": {"state": "done"}}
        rows = {self.NAME: {**row(value), "measure_version": version, **({"part_config": config} if config else {})}}
        return cron.finish_measurement(self.state, rows, None, cron.BENCH_WORKER, f"u{self.n}", at(self.n), budgets_mod)

    def test_a_version_bump_rebases_the_row_and_closes_its_regression(self):
        for _ in range(3):
            self.measured(20.0, 2)
        self.assertEqual(self.measured(30.0, 2), "regressed")
        self.assertEqual(self.measured(40.0, 3), "recovered", "the old version's regression closes, not judged")
        self.assertIn("measurement version", self.state["history"][-1].get("rebased_note") or "")
        self.assertEqual([e["p95"] for e in self.state["row_history"][self.NAME]], [40.0], "the baseline restarts")
        # Review 2 of 8af6ea46de5, finding 6: a version rebase is not a macOS change in the issue.
        self.assertEqual((self.state["last"].get("version_rebased"), self.state["last"].get("os_rebased")), ([self.NAME], None))
        body = cron.issue_body(self.state, "o/r", at(self.n))
        self.assertIn("Measured another way", body)
        self.assertNotIn("macOS changed", body)
        self.assertEqual(self.measured(41.0, 3), "good", "the new version compares with its own values")

    def test_a_change_of_the_parts_args_rebases_the_row(self):
        # Review 2 of 8af6ea46de5, finding 10: the version gate saw only split-spring.sh; a change of this file's args
        # for the part (rounds, actions, flags) compared two configurations.
        self.measured(20.0, 2)
        self.measured(20.0, 2, config="c1")
        self.assertNotIn("rebased", self.state["history"][-1], "a reference with no config is not known to differ")
        self.measured(20.0, 2, config="c1")
        self.assertNotIn("rebased", self.state["history"][-1])
        self.measured(30.0, 2, config="c2")
        self.assertEqual(self.state["history"][-1].get("rebased"), [self.NAME])
        self.assertEqual(self.state["last"].get("version_rebased"), [self.NAME])

    def test_part_config_names_the_args_and_the_report_stamps_the_requested_config(self):
        self.assertNotEqual(cron.part_config("motion"), cron.part_config("switch"))
        self.assertEqual(cron.part_config("diff-viewer"), cron.part_config("diff-viewer"))
        with mock.patch.dict(cron.PART_BY_NAME, {"motion": {**cron.PART_BY_NAME["motion"], "args": ["--rounds=2"]}}):
            self.assertNotEqual(cron.part_config("motion"), cron.part_config("switch"))
            changed = cron.part_config("motion")
        self.assertNotEqual(changed, cron.part_config("motion"))
        report = {"rows": [{"name": "cmd_d.e2e", "p50": 20.0, "p95": 20.0, "unit": "ms"}],
                  "display": {"requested_hz": 120, "vdisplay": True, "refresh_ms": 8.33, "line": "ready"}}
        with tempfile.TemporaryDirectory() as d:
            state = cron.empty_state(T0)
            state["persisted"] = True
            state["current"] = cron.new_measurement("b" * 40, "tip", ["motion"], T0)
            state["current"]["configs"] = {"motion": "requested1"}
            with open(os.path.join(d, "state.json"), "w") as f:
                json.dump(state, f)
            part_dir = os.path.join(d, "motion")
            os.makedirs(part_dir)
            for file, value in (("result.json", {"state": "done", "worker": cron.BENCH_WORKER}), ("report.json", report)):
                with open(os.path.join(part_dir, file), "w") as f:
                    json.dump(value, f)
            with mock.patch.object(cron, "now_utc", lambda: at(1)), mock.patch("sys.stdout", io.StringIO()):
                cron.cmd_report(argparse.Namespace(repo="o/r", dir=d, result=[f"motion={part_dir}"], run_url="u",
                                                   finish=False, issues=False, output=os.path.join(d, "report.out")))
            with open(os.path.join(d, "state.json")) as f:
                rows = json.load(f)["last"]["rows"]
        self.assertEqual({r.get("part_config") for r in rows.values()}, {"requested1"})

    def test_a_row_stored_before_versions_counts_as_the_legacy_version(self):
        self.measured(20.0, 2)
        del self.state["last_good"]["rows"][self.NAME]["measure_version"]
        self.measured(20.0, cron.LEGACY_MEASURE_VERSION)
        self.assertNotIn("rebased", self.state["history"][-1])
        self.measured(20.0, cron.LEGACY_MEASURE_VERSION + 1)
        self.assertEqual(self.state["history"][-1].get("rebased"), [self.NAME])

    def test_the_626c77ac_blob_measures_as_version_2(self):
        self.assertEqual(cron.measure_version_of("626c77accc2f511146571fbb9314b1af95d2d7c9", "#!/bin/bash\n"), 2)



class HostGoneSignalTests(unittest.TestCase):
    """The controller sends host_gone when a request named a worker it does not have (hq perf_cron.go goneLocked):
    the cron retires that host at once, its open regressions close at the next Mac measurement elsewhere."""
    report_tick = DisplayTests.report_tick

    def test_a_host_gone_result_retires_the_host_and_drops_the_pin(self):
        with tempfile.TemporaryDirectory() as d:
            state = self.report_tick(d, {"motion": {}}, {}, host="cmux21",
                                     result={"state": "yielded", "worker": "cmux21", "host_gone": True, "tail": ["cmux21 is not a worker"]})
        self.assertIn("gone_at", state["hosts"]["cmux21"])
        self.assertNotIn("host", state["current"], "the pin to the gone host is dropped")
        self.assertIn("motion", state["current"]["parts_todo"], "the part is asked for again, no yield counted")
        self.assertNotIn("motion", state["current"]["parts"])
        self.assertTrue(cron.host_gone(state, "cmux21", at(1)))
        self.assertIsNone(cron.tip_pin_host({**state, "regressions": [{"name": "cmd_d.e2e@cmux21"}]}, at(1)))

    def test_a_host_that_runs_a_part_after_gone_is_back(self):
        state = cron.empty_state(T0)
        cron.mark_host(state, "cmux21", gone_at=cron.iso(at(1)))
        self.assertTrue(cron.host_gone(state, "cmux21", at(2)))
        cron.mark_host(state, "cmux21", last_part_at=cron.iso(at(3)))
        self.assertFalse(cron.host_gone(state, "cmux21", at(4)))

    def test_fetch_result_keeps_the_flag(self):
        value = {"sha": "a" * 40, "part": "motion", "state": "yielded", "worker": "cmux21", "host_gone": True}
        self.assertTrue(cron.result_files(value)["host_gone"])



class BisectGoneHostTests(unittest.TestCase):
    """Review of hq #3854, finding 4: a bisect step for a gone host's rows would get host_gone back on every step."""
    tick = PlanReportTests.tick

    def test_no_bisect_step_for_the_rows_of_a_gone_host(self):
        good, bad = "a" * 40, "c" * 40
        for gone in (False, True):
            with tempfile.TemporaryDirectory() as d:
                state = cron.empty_state(T0)
                state["persisted"] = True
                state["last_tried"] = {"sha": "f" * 40, "at": cron.iso(at(0))}
                state["regressions"] = [{"name": "cmd_d.e2e@cmux21", "p95": 30.0, "base": 20.0, "confirmed": True,
                                         "range": {"good": good, "bad": bad, "skip": [], "steps": 0}}]
                if gone:
                    cron.mark_host(state, "cmux21", gone_at=cron.iso(at(0)))
                with open(os.path.join(d, "state.json"), "w") as f:
                    json.dump(state, f)
                with mock.patch.object(cron, "range_commits", lambda g, b: ["b" * 40]), \
                        mock.patch.object(cron, "tip_due", lambda state, t: False):
                    plan, _ = self.tick(d, at(1), "f" * 40)
                if gone:
                    self.assertEqual(plan["action"], "none", "no bisect step for a gone host's rows")
                else:
                    self.assertEqual((plan["action"], plan["sha"], plan["worker"]), ("part", "b" * 40, "cmux21"))



class DiffBenchVersionTests(unittest.TestCase):
    """Lead 2026-10-24: a change to the diff benches at the measured commit is version-gated like split-spring.sh."""

    def test_the_constants_are_read_from_both_benches_and_absent_means_legacy(self):
        with tempfile.TemporaryDirectory() as d:
            self.assertEqual(cron.diff_bench_versions(d), {"sidecar": 1, "stream": 1})
            os.makedirs(os.path.join(d, "Native/DiffSidecar/src"))
            os.makedirs(os.path.join(d, "webviews/bench"))
            with open(os.path.join(d, "Native/DiffSidecar/src/benchmark.rs"), "w") as f:
                f.write("pub const DIFF_BENCH_VERSION: u32 = 2;\n")
            with open(os.path.join(d, "webviews/bench/diff-stream.bench.ts"), "w") as f:
                f.write("export const DIFF_BENCH_VERSION = 3;\n")
            self.assertEqual(cron.diff_bench_versions(d), {"sidecar": 2, "stream": 3})

    def test_a_bench_version_bump_rebases_only_that_bench_s_rows(self):
        part = cron.PART_BY_NAME["diff-viewer"]

        def rows(stream_version):
            report = {"sidecar": {"manifestDecodeP95Micros": 3, "sequentialReadMibPerSecond": 20000.0},
                      "stream": {"p95Ms": 19.0}, "bench_versions": {"sidecar": 1, "stream": stream_version}}
            return cron.rows_of_part(part, report, budgets_mod, {"rows": {}, "_animations": {}})
        base = rows(1)
        self.assertEqual(base["diff.stream.p95"]["measure_version"], 1)
        legacy = {n: {k: v for k, v in r.items() if k != "measure_version"} for n, r in base.items()}
        self.assertEqual(cron.version_changed(rows(1), legacy), [], "a reference stored before versions is version 1")
        self.assertEqual(cron.version_changed(rows(2), base), ["diff.stream.p95"])



class RebaseListTests(OneRunRule):
    """Lead 2026-10-24: every version rebase shows in the issue body, also one of an incomplete measurement."""
    NAME = "cmd_d.e2e@" + cron.BENCH_WORKER

    def setUp(self):
        super().setUp()
        self.state = cron.empty_state(T0)
        self.n = 0

    def measured(self, value, version, failed=False):
        self.n += 1
        self.state["current"] = cron.new_measurement((format(self.n, "x") * 40)[:40], "tip", [], at(self.n))
        self.state["current"]["parts"] = {"motion": {"state": "done"}, **({"switch": {"state": "failed"}} if failed else {})}
        rows = {self.NAME: {**row(value), "measure_version": version}}
        return cron.finish_measurement(self.state, rows, None, cron.BENCH_WORKER, f"u{self.n}", at(self.n), budgets_mod)

    def test_a_version_rebase_of_an_incomplete_measurement_is_listed(self):
        for _ in range(3):
            self.measured(20.0, 2)
        self.measured(30.0, 3, failed=True)
        body = cron.issue_body(self.state, "o/r", at(9))
        self.assertIn("Rebases", body)
        self.assertIn("measurement version or part args changed, 1 row(s) (" + self.NAME, body)



class NotMeasuringTests(unittest.TestCase):
    """Lead 2026-10-24: a refusal of the cron's own making (here an unreadable measurement version) says NOT MEASURING
    in the issue's first line at once and fails the tick; a busy fleet stays a quiet wait."""

    def tick(self, d, version, gh):
        out, rep = os.path.join(d, "plan.out"), os.path.join(d, "report.out")
        tip = "f" * 40

        def git(*args, check=True):
            return tip if args[0] == "rev-parse" else tip

        with mock.patch.object(cron, "now_utc", lambda: at(1)), mock.patch.object(cron, "git", git), \
                mock.patch.object(cron, "measure_version", lambda sha: version), \
                mock.patch.object(cron, "commit_on_branch", lambda repo, t, known=(): cron.is_sha), \
                mock.patch.object(cron, "tree_published", lambda sha: True), \
                mock.patch.object(cron, "github_busy", lambda *a: None), \
                mock.patch.object(cron, "frame_pacing_runs", lambda repo: []), \
                mock.patch.object(cron, "is_ancestor", lambda a, b: False), \
                mock.patch.object(cron, "supported_parts_at", lambda sha: ["motion"]), \
                mock.patch.object(cron, "gh_request", gh):
            cron.cmd_plan(argparse.Namespace(repo="o/r", dir=d, tip="HEAD", yield_mode="queued", no_mac=False, output=out))
            cron.cmd_report(argparse.Namespace(repo="o/r", dir=d, result=[], run_url="u", finish=False, issues=True, output=rep))
        read = lambda p: dict(line.split("=", 1) for line in open(p).read().splitlines())
        plan, report = read(out), read(rep)
        os.remove(out)
        os.remove(rep)
        return plan, report

    def test_an_unreadable_version_reopens_the_issue_with_not_measuring_first_and_fails_the_tick(self):
        issue = {"number": 9, "title": cron.ISSUE_TITLE, "user": {"login": cron.ISSUE_AUTHOR}, "body": cron.ISSUE_MARK,
                 "state": "closed"}
        calls = []

        def gh(path, method="GET", body=None, **k):
            calls.append((method, path, body))
            if method == "PATCH" and body and "body" in body:
                issue["body"] = body["body"]
            if method == "PATCH" and body and body.get("state"):
                issue["state"] = body["state"]
            return issue if method == "GET" and "/search/" not in path else ({"items": [issue]} if "/search/" in path else {})
        with tempfile.TemporaryDirectory() as d:
            state = cron.empty_state(T0)
            state["issue"] = 9
            with open(os.path.join(d, "state.json"), "w") as f:
                json.dump(state, f)
            plan, report = self.tick(d, None, gh)
            self.assertEqual(plan["action"], "none")
            self.assertIn("SPLIT_SPRING_MEASURE_VERSION", plan["not_measuring"])
            self.assertIn("SPLIT_SPRING_MEASURE_VERSION", report["not_measuring"], "the workflow fails the tick on it")
            first = [line for line in issue["body"].split("\n") if line.strip() and line != cron.ISSUE_MARK][0]
            self.assertTrue(first.startswith("**NOT MEASURING:**"), first)
            self.assertEqual(issue["state"], "open")
            comments = [b for m, p, b in calls if m == "POST" and p.endswith("/comments")]
            self.assertEqual(len(comments), 1)
            self.assertIn("NOT MEASURING", comments[0]["body"])
            calls.clear()
            self.tick(d, None, gh)
            self.assertFalse([c for c in calls if c[0] == "POST"], "said once, not every tick")
            plan, report = self.tick(d, 3, gh)
            self.assertEqual(report["not_measuring"], "", "a readable version clears it")
            self.assertNotIn("NOT MEASURING", issue["body"])

    def test_a_busy_fleet_is_not_a_refusal(self):
        self.assertIsNone(cron.not_measuring_reason("f" * 40, 3))


if __name__ == "__main__":
    unittest.main()
