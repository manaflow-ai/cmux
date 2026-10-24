#!/usr/bin/env python3
"""The perf cron's decisions (scripts/cmux-next/perf-cron.py): what a tick runs, when it yields to the fleet,
what counts as a regression, and when the one issue opens, comments and closes. Pure functions only (no
network, no git). Run: python3 -I scripts/cmux-next/tests/test_perf_cron.py (not a CI job, Lawrence 2026-10-23)."""
import argparse, datetime, importlib.util, io, json, os, tempfile, unittest
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


FLEET = [n for n in ALL if n not in ("build", "diff-viewer")]


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
        self.assertEqual(cron.find_regressions({"a": row(99.0)}, {}, None, None, budgets_mod), [])


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


class FinishTests(unittest.TestCase):
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
               "regressions": [{"name": "t.e2e"}]}
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


class DisplayTests(unittest.TestCase):
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

    def report_tick(self, d, parts, last_good_rows):
        """cmd_report finishing a tip measurement of `parts` ({name: report}) against last_good_rows."""
        state = cron.empty_state(T0)
        state["persisted"] = True
        state["last_good"] = state["last"] = {"sha": "a" * 40, "measured_at": cron.iso(T0), "rows": last_good_rows,
                                              "refresh_ms": 8.33}
        state["current"] = cron.new_measurement("b" * 40, "tip", list(parts), T0)
        with open(os.path.join(d, "state.json"), "w") as f:
            json.dump(state, f)
        results = []
        for name, report in parts.items():
            part_dir = os.path.join(d, name)
            os.makedirs(part_dir)
            for file, value in (("result.json", {"state": "done"}), ("report.json", report)):
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
        base = {"panes.split.4x2.frame": {**row(8.4), "refresh_ms": 8.33}, "panes.close.stress.frame": {**row(8.4), "refresh_ms": 8.33}}
        fallback = {"rows": [{"name": "panes.split.4x2.frame", "p50": 16.7, "p95": 17.0, "unit": "ms"}],
                    "display": {"requested_hz": 120, "vdisplay": False, "refresh_ms": None, "line": "error: x"}}
        with tempfile.TemporaryDirectory() as d:
            state = self.report_tick(d, {"stress": stress, "motion": fallback}, base)
            self.assertEqual(state["regressions"], [], "a fallback part's frame rows are not compared with the 120 Hz stress part's rate")
            self.assertIsNone(state["last"]["rows"]["panes.split.4x2.frame"]["refresh_ms"])
            self.assertEqual(state["last_good"]["rows"]["panes.split.4x2.frame"]["p95"], 8.4, "the 120 Hz baseline stays")
        on_vdisplay = {**fallback, "display": {"requested_hz": 120, "vdisplay": True, "refresh_ms": 8.34, "line": "ready"}}
        with tempfile.TemporaryDirectory() as d:
            state = self.report_tick(d, {"stress": stress, "motion": on_vdisplay}, base)
            self.assertEqual([r["name"] for r in state["regressions"]], ["panes.split.4x2.frame"],
                             "a budgets part on the virtual display is compared at its refresh")

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


class IncompleteTests(unittest.TestCase):
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
                mock.patch.object(cron, "script_blob", lambda sha: "blob"), \
                mock.patch.object(cron, "commit_on_branch", lambda repo, t: cron.is_sha), \
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


class Review2Tests(unittest.TestCase):
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
            state = self.report(d, state, [self.part_dir(d, "stress", {"state": "done"}, self.STRESS)])
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
        self.assertEqual(cur["parts_todo"], ["diff-viewer"])
        self.assertEqual(cur["parts"]["stress"], {"state": "disabled", "reason": why})
        cur["parts_todo"] = []
        cur["parts"]["diff-viewer"] = {"state": "done"}
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


class RefreshRebaseTests(unittest.TestCase):
    """A frame row regressed at one refresh, then measured only at another (the 120 Hz virtual display starts to
    work, or falls back to the panel)."""

    def setUp(self):
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


if __name__ == "__main__":
    unittest.main()
