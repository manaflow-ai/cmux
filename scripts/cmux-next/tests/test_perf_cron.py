#!/usr/bin/env python3
"""The perf cron's decisions (scripts/cmux-next/perf-cron.py): what a tick runs, when it yields to the fleet,
what counts as a regression, and when the one issue opens, comments and closes. Pure functions only (no
network, no git). Run: python3 -I scripts/cmux-next/tests/test_perf_cron.py (not a CI job, Lawrence 2026-10-23)."""
import datetime, importlib.util, os, unittest

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
        state["regressions"] = [{"name": "sidebar.400.scroll.frame"}, {"name": "panes.close.stress.frame"}]
        d = cron.decide(state, T0, None, "c" * 40, lambda sha: ALL, None)
        self.assertEqual(state["current"]["kind"], "bisect")
        self.assertEqual(state["current"]["parts_todo"], ["build", "stress", "sidebar"])
        self.assertEqual((d["part"], d["linux_part"]), ("build", ""))

    def test_bisect_midpoint_takes_the_measurable_commit_nearest_the_middle(self):
        commits = ["c1", "c2", "c3", "c4", "c5"]
        self.assertEqual(cron.bisect_midpoint(commits, lambda c: True), "c3")
        self.assertEqual(cron.bisect_midpoint(commits, lambda c: c in ("c1", "c4")), "c4")
        self.assertIsNone(cron.bisect_midpoint(commits, lambda c: False))
        self.assertIsNone(cron.bisect_midpoint([], lambda c: True))


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

    def test_first_regressed_still_recovered(self):
        state = cron.empty_state(T0)
        self.assertEqual(self.measured(state, "a" * 40, {"t.e2e": row(5.0)}, 0), "first")
        self.assertEqual(self.measured(state, "b" * 40, {"t.e2e": row(9.0)}, 1), "regressed")
        self.assertEqual(state["range"], {"good": "a" * 40, "bad": "b" * 40})
        self.assertEqual(self.measured(state, "c" * 40, {"t.e2e": row(9.1)}, 2), "still")
        self.assertEqual(state["first_bad"]["sha"], "b" * 40, "the first bad commit stays the earliest")
        self.assertEqual(self.measured(state, "d" * 40, {"t.e2e": row(5.1)}, 3), "recovered")
        self.assertEqual(state["last_good"]["sha"], "d" * 40)
        self.assertIsNone(state["range"])

    def test_bisect_narrows_the_range(self):
        state = cron.empty_state(T0)
        self.measured(state, "a" * 40, {"t.e2e": row(5.0)}, 0)
        self.measured(state, "e" * 40, {"t.e2e": row(9.0)}, 1)
        state["current"] = cron.new_measurement("c" * 40, "bisect", [], at(2))
        state["current"]["parts"] = {"motion": {"state": "done"}}
        self.assertEqual(cron.finish_measurement(state, {"t.e2e": row(5.2)}, 16.67, "bench", "r", at(2), budgets_mod), "narrowed")
        self.assertEqual(state["range"], {"good": "c" * 40, "bad": "e" * 40})
        state["current"] = cron.new_measurement("d" * 40, "bisect", [], at(3))
        state["current"]["parts"] = {"motion": {"state": "done"}}
        cron.finish_measurement(state, {"t.e2e": row(9.2)}, 16.67, "bench", "r", at(3), budgets_mod)
        self.assertEqual(state["range"], {"good": "c" * 40, "bad": "d" * 40})
        self.assertEqual(state["last"]["sha"], "e" * 40, "a bisect step is not the last tip measurement")


class PartTests(unittest.TestCase):
    def test_a_yielded_part_stays_to_do_up_to_the_limit(self):
        cur = cron.new_measurement("a" * 40, "tip", ["motion", "sidebar"], T0)
        for i in range(cron.MAX_YIELDS - 1):
            self.assertEqual(cron.record_part(cur, "motion", {"state": "yielded"}, "r")["state"], "yielded")
            self.assertIn("motion", cur["parts_todo"])
        self.assertEqual(cron.record_part(cur, "motion", {"state": "yielded"}, "r")["state"], "failed")
        self.assertEqual(cur["parts_todo"], ["sidebar"])

    def test_a_failed_build_ends_the_fleet_parts_but_not_the_linux_part(self):
        cur = cron.new_measurement("a" * 40, "tip", ["build", "motion", "sidebar", "diff-viewer"], T0)
        cron.record_part(cur, "build", {"state": "failed", "tail": ["split-spring: the tagged reload printed no app path"]}, "r")
        self.assertEqual(cur["parts_todo"], ["diff-viewer"])
        self.assertEqual(cur["parts"]["sidebar"]["state"], "build_failed")
        cur = cron.new_measurement("a" * 40, "tip", ["motion", "sidebar"], T0)
        cron.record_part(cur, "motion", {"state": "failed", "tail": ["split-spring: the tagged reload printed no app path"]}, "r")
        self.assertEqual(cur["parts_todo"], [], "a part that had to build and failed ends the rest too")


class DisplayTests(unittest.TestCase):
    def test_a_frame_row_on_another_refresh_is_not_compared(self):
        now = {"p.frame": {**row(16.7), "refresh_ms": 16.67}, "p.missed": {**row(6, "frames"), "refresh_ms": 16.67},
               "t.e2e": {**row(14.0), "refresh_ms": 16.67}}
        base = {"p.frame": {**row(8.4), "refresh_ms": 8.33}, "p.missed": {**row(0, "frames"), "refresh_ms": 8.33},
                "t.e2e": {**row(9.0), "refresh_ms": 8.33}}
        regs = cron.find_regressions(now, base, 16.67, 8.33, budgets_mod)
        self.assertEqual([r["name"] for r in regs], ["t.e2e"], "latency compares across refresh rates, frames do not")

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


class DiffTests(unittest.TestCase):
    def test_diff_viewer_rows_and_their_budgets(self):
        report = {"sidecar": {"manifest_decode_p95_micros": 400, "sequential_read_mib_per_second": 1024.0},
                  "stream": {"p95Ms": 120.5}}
        rows = cron.rows_of_part(cron.PART_BY_NAME["diff-viewer"], report, budgets_mod, {"rows": {}})
        self.assertEqual(rows["diff.sidecar.read_ms_per_gib"]["p95"], 1000.0)
        self.assertEqual(cron.target_of("diff.stream.p95", rows["diff.stream.p95"], 16.67), 250.0)
        self.assertFalse(cron.over_target("diff.sidecar.manifest_decode_p95", rows["diff.sidecar.manifest_decode_p95"], None))
        self.assertEqual(cron.part_for_row("diff.stream.p95"), "diff-viewer")

    def test_the_last_json_object_a_bench_printed(self):
        self.assertEqual(cron.last_json_object('Compiling\n{\n "a": 1\n}\nnoise\n{\n "b": 2\n}\n'), {"b": 2})
        self.assertIsNone(cron.last_json_object("no json here"))


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
        self.assertFalse(cron.mac_job_waiting({"status": "waiting", "labels": ["glaeda-mini"]}), "an approval gate is not load")
        self.assertFalse(cron.mac_job_waiting({"status": "in_progress", "labels": ["glaeda-mini"]}))

    def test_a_foreground_bench_job_makes_the_part_yield(self):
        q = {"queue": [{"id": "mine", "labels": ["bench"]}, {"id": "o" * 24, "labels": ["bench", "measure"], "priority_class": "agent"}]}
        self.assertEqual(cron.wanted_by_other(q, {"mine"})["id"], "o" * 24)
        self.assertIsNone(cron.wanted_by_other({"queue": [{"id": "mine", "labels": ["bench"]}]}, {"mine"}))


if __name__ == "__main__":
    unittest.main()
