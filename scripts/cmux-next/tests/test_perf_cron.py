#!/usr/bin/env python3
"""The perf cron's decisions (scripts/cmux-next/perf-cron.py): what a tick runs, when it yields to the fleet,
what counts as a regression, and when the one issue opens, comments and closes. Pure functions only (no
network, no git). Run: python3 -I scripts/cmux-next/tests/test_perf_cron.py (not a CI job, Lawrence 2026-10-23,
since lifted)."""
import argparse, contextlib, datetime, hashlib, importlib.util, io, json, os, tempfile, time, unittest, urllib.error, urllib.request
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


LINUX_PARTS = ["diff-viewer", "web-ui", "web-ui-scale", "web-ui-growth", "web-ui-god", "infinite-items", "web-ui-million", "web-ui-memory", "web-ui-flat", "web-ui-scroll-up", "web-ui-flat-grown", "web-ui-ladder", "web-ui-fidelity", "web-ui-typing", "web-ui-scroll", "web-ui-orchestrator", "web-ui-power-user", "web-ui-settled", "chat-disk", "cloud-claim", "terminal-scroll", "daemon-restart", "coord-sim", "chat-search"]
FLEET = [n for n in ALL if n not in ("build", *LINUX_PARTS)]
# A fresh state's order (part_order): a part with no row anywhere goes before a goal's part, so the goal's parts go last.
LINUX_FRESH_ORDER = [n for n in LINUX_PARTS if not cron.PART_BY_NAME[n].get("goal")] + \
    [n for n in LINUX_PARTS if cron.PART_BY_NAME[n].get("goal")]


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


_claim_spec = importlib.util.spec_from_file_location("cloud_claim_rows", os.path.join(HERE, "..", "cloud-claim-rows.py"))
claim_mod = importlib.util.module_from_spec(_claim_spec)
_claim_spec.loader.exec_module(claim_mod)


class CloudClaimRowsTests(unittest.TestCase):
    """scripts/cmux-next/cloud-claim-rows.py: production journey probe rows to the cloud-claim part's rows."""

    @staticmethod
    def probe(ready=None, spare=False, error=None, backend="prod", name="cloud-chat-replies-production"):
        p = {"probe": name, "at": "2026-11-19T01:41:52Z", "backend": backend, "claimed_spare": spare,
             "outcome": "fail" if error else "ok"}
        if ready is not None:
            p["ready_ms"] = ready
        if error:
            p["error"] = error
        return p

    def test_a_probe_row_is_a_ready_claim_a_claim_that_failed_before_ready_or_nothing(self):
        self.assertEqual(claim_mod.claim_of(self.probe(46701)), {"ready_ms": 46701.0, "spare": False,
                                                                 "at": "2026-11-19T01:41:52Z"})
        self.assertTrue(claim_mod.claim_of(self.probe(9000, spare=True))["spare"])
        self.assertEqual(claim_mod.claim_of(self.probe(error="create machine: failed after 34 s"))["failed"],
                         "create machine")
        self.assertEqual(claim_mod.claim_of(self.probe(error="start agent (claude): exit 1"))["failed"], "start agent")
        # A failure after ready keeps its ready_ms; one that names no ready step, another backend or probe says nothing.
        self.assertEqual(claim_mod.claim_of(self.probe(30000, error="reply: timeout"))["ready_ms"], 30000.0)
        self.assertIsNone(claim_mod.claim_of(self.probe(error="reply: timeout")))
        self.assertIsNone(claim_mod.claim_of(self.probe(error="no reply step ran")))
        self.assertIsNone(claim_mod.claim_of(self.probe(9000, backend="staging")))
        self.assertIsNone(claim_mod.claim_of(self.probe(9000, name="machine-ready-after-create")))

    def test_rows_are_p50_and_p95_over_the_newest_claims_against_the_plan_targets(self):
        claims = [{"ready_ms": float(v), "spare": v < 5000} for v in (40000, 3000, 50000, 45000, 4000, 60000)]
        claims.insert(2, {"failed": "create machine"})
        rows = {r["name"]: r for r in claim_mod.claim_rows(claims, samples=5)}
        # The newest 5 ready claims (40, 3, 50, 45, 4 s) and the one failure among them; the sixth is past the sample.
        self.assertEqual((rows["claim_to_ready"]["p50"], rows["claim_to_ready"]["p95"]), (40000.0, 50000.0))
        self.assertEqual(rows["claim_to_ready"]["target"], 15000)
        self.assertEqual((rows["claim_to_ready.p50"]["p95"], rows["claim_to_ready.p50"]["target"]), (40000.0, 8000))
        self.assertEqual(rows["claim_to_ready.failed_claims"]["p95"], 1)
        self.assertEqual((rows["claim_to_ready.spare"]["p95"], rows["claim_to_ready.spare"]["samples"],
                          rows["claim_to_ready.spare"]["target"]), (4000.0, 2, 1000))
        # Every row parses as a cloud-claim row.
        parsed = cron.rows_of_part(cron.PART_BY_NAME["cloud-claim"], {"rows": list(rows.values())}, budgets_mod, {"rows": {}})
        self.assertEqual(sorted(parsed), sorted(f"cloud.{n}" for n in rows))

    def test_reading_stops_at_the_deadline_and_counts_unread_artifacts(self):
        arts = {"artifacts": [{"id": i, "name": "cloud-journey-prod-stub", "created_at": "2026-11-19T0%d:00:00Z" % i,
                               "expired": False} for i in range(1, 4)]}
        ticks = iter([0, 1, 2, 999])
        with mock.patch.object(claim_mod, "gh_json", lambda path: arts if "name=cloud-journey-prod-stub" in path else {}), \
                mock.patch.object(claim_mod, "gh_bytes", side_effect=RuntimeError("refused")), \
                contextlib.redirect_stderr(io.StringIO()):
            claims, unread = claim_mod.fetch_claims("o/r", datetime.datetime(2026, 11, 18, tzinfo=datetime.timezone.utc), 24,
                                                    deadline_s=10, clock=lambda: next(ticks))
        self.assertEqual((claims, unread), ([], 2))  # newest first; the third waits past the deadline

    def test_too_few_ready_claims_make_no_rows_and_no_spare_row_without_a_spare(self):
        few = [{"ready_ms": 40000.0, "spare": False}] * (claim_mod.MIN_SAMPLES - 1) + [{"failed": "create machine"}]
        self.assertEqual(claim_mod.claim_rows(few), [])
        enough = [{"ready_ms": 40000.0, "spare": False}] * claim_mod.MIN_SAMPLES
        self.assertNotIn("claim_to_ready.spare", [r["name"] for r in claim_mod.claim_rows(enough)])


class DecideTests(unittest.TestCase):
    def test_a_new_tip_builds_once_then_measures_the_parts_the_commit_has(self):
        state = cron.empty_state(T0)
        d = cron.decide(state, T0, "a" * 40, None, lambda sha: ["motion", "sidebar"], None)
        self.assertEqual((d["action"], d["part"], d["linux_parts"]), ("part", "build", []))
        self.assertEqual(state["current"]["parts_todo"], ["build", "motion", "sidebar"])

    def test_the_linux_part_runs_beside_the_build_and_needs_no_build_alone(self):
        state = cron.empty_state(T0)
        d = cron.decide(state, T0, "a" * 40, None, lambda sha: ALL, None)
        self.assertEqual((d["part"], d["linux_parts"]), ("build", LINUX_FRESH_ORDER))
        state = cron.empty_state(T0)
        cron.decide(state, T0, "a" * 40, None, lambda sha: ["diff-viewer"], None)
        self.assertEqual(state["current"]["parts_todo"], ["diff-viewer"], "no Mac build for a Linux-only measurement")

    def test_nothing_new_runs_nothing(self):
        d = cron.decide(cron.empty_state(T0), T0, None, None, lambda sha: ALL, None)
        self.assertEqual(d["action"], "none")

    def test_a_busy_github_fleet_holds_the_mac_parts_of_a_runner_host_but_not_the_linux_part(self):
        busy = "nightly.yml waits for a runner"
        state = cron.empty_state(T0)
        cron.decide(state, T0, "a" * 40, None, lambda sha: FLEET, None)
        state["current"]["host"] = "aws-m4pro-9"  # a host that also runs CI jobs built the app
        d = cron.decide(state, at(1), None, None, lambda sha: FLEET, busy)
        self.assertEqual(d["action"], "none")
        self.assertTrue(d["yielded"])
        self.assertIsNotNone(state["current"])
        state["current"]["parts_todo"].append("diff-viewer")
        d = cron.decide(state, at(1), None, None, lambda sha: ALL, busy)
        self.assertEqual((d["action"], d["part"], d["linux_parts"]), ("part", "", ["diff-viewer"]))

    def test_a_measurement_held_by_a_busy_fleet_gives_its_runner_host_up_for_the_bench_host(self):
        # Nightly runs start about every 25 minutes, so a job of one is queued at most ticks: a pinned measurement
        # that only waited would never run a Mac part again.
        busy = "nightly.yml waits for a runner"
        state = cron.empty_state(T0)
        cron.decide(state, T0, "a" * 40, None, lambda sha: FLEET, None)
        state["current"]["host"] = "aws-m4pro-9"
        d = cron.decide(state, at(1), None, None, lambda sha: FLEET, busy)
        self.assertEqual(d["action"], "none")
        d = cron.decide(state, at(1 + cron.HOST_WAIT_HOURS + 0.1), None, None, lambda sha: FLEET, busy)
        self.assertEqual((d["action"], d.get("worker")), ("part", cron.BENCH_WORKER))
        self.assertNotIn("host", state["current"])
        self.assertEqual(state["current"]["gave_up"][0]["host"], "aws-m4pro-9")

    def test_a_busy_github_fleet_sends_the_mac_parts_to_the_bench_host(self):
        # 2026-11-13 16:43Z to 11-14 02:29Z: no Mac part ran. Every tick found a nightly job queued for a signing
        # runner and measured nothing, while cmux20-bench, which runs no CI job, could have taken the part.
        busy = "nightly.yml waits for a runner"
        state = cron.empty_state(T0)
        d = cron.decide(state, T0, "a" * 40, None, lambda sha: FLEET, busy)
        self.assertEqual((d["action"], d.get("part"), d.get("worker")), ("part", "build", cron.BENCH_WORKER))
        self.assertIn(busy, d["reason"])
        self.assertNotIn("host", state["current"], "the part's result pins the measurement, not the request")
        state["current"]["host"] = cron.BENCH_WORKER
        d = cron.decide(state, at(1), None, None, lambda sha: FLEET, busy)
        self.assertEqual((d["action"], d["worker"]), ("part", cron.BENCH_WORKER))

    def test_a_measurement_that_gave_the_bench_host_up_still_asks_it_while_github_is_busy(self):
        # 2026-11-15 00:54Z: the measurement gave cmux20-bench up after 2 h without a part (two results were lost to
        # the rate limit and the host ran other steps). The give-up kept the bench host from the "only on the bench
        # host" rule for 2 h, a dev build waited for a Mac at every tick, and so no Mac part was asked for at all
        # (01:13Z plan: "none"). Giving a host up is for trying another host; while only the bench host may be
        # asked, it is asked.
        busy = "cmux-next.yml waits for a Mac runner"
        state = cron.empty_state(T0)
        cron.decide(state, T0, "a" * 40, None, lambda sha: FLEET, busy)
        state["current"]["host"] = cron.BENCH_WORKER
        d = cron.decide(state, at(1), None, None, lambda sha: FLEET, busy)
        self.assertEqual((d["action"], d["worker"]), ("part", cron.BENCH_WORKER))
        late = at(1 + cron.HOST_WAIT_HOURS + 0.1)
        d = cron.decide(state, late, None, None, lambda sha: FLEET, busy)
        self.assertEqual(state["current"]["gave_up"][0]["host"], cron.BENCH_WORKER)
        self.assertEqual((d["action"], d.get("part"), d.get("worker")), ("part", "build", cron.BENCH_WORKER))
        # Without a waiting build the measurement goes to any idle measure host, as before.
        d = cron.decide(state, late, None, None, lambda sha: FLEET, None)
        self.assertEqual((d["action"], d.get("worker")), ("part", ""))
        # A bench host the fleet check reported offline is not asked.
        cron.mark_host(state, cron.BENCH_WORKER, unreachable_since=cron.iso(late))
        d = cron.decide(state, late, None, None, lambda sha: FLEET, busy)
        self.assertEqual(d["action"], "none")

    def test_a_bench_host_silent_past_host_gone_hours_is_still_asked_while_github_is_busy(self):
        # 2026-11-18 to 11-21: cmux20-bench refused every claim (not isolated), so it ran no part for 3.5 days. Once
        # repaired, host_gone read it as gone by silence, the "only on the bench host" rule skipped it, and every tick
        # a nightly waited for a Mac held the Mac parts back. Only the controller's word retires the bench host here.
        busy = "nightly.yml waits for a Mac runner"
        state = cron.empty_state(T0)
        cron.mark_host(state, cron.BENCH_WORKER, last_part_at=cron.iso(T0))
        late = at(cron.HOST_GONE_HOURS + 1)
        self.assertTrue(cron.host_gone(state, cron.BENCH_WORKER, late))
        d = cron.decide(state, late, "a" * 40, None, lambda sha: FLEET, busy)
        self.assertEqual((d["action"], d.get("part"), d.get("worker")), ("part", "build", cron.BENCH_WORKER))
        # The controller saying it has no such worker still retires it.
        cron.mark_host(state, cron.BENCH_WORKER, gone_at=cron.iso(late))
        d = cron.decide(state, late, None, None, lambda sha: FLEET, busy)
        self.assertEqual(d["action"], "none")

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

    def test_a_tip_at_its_bound_with_a_part_done_finishes_with_what_it_has(self):
        state = cron.empty_state(T0)
        cron.decide(state, T0, "a" * 40, None, lambda sha: ["motion", "stress"], None)
        cron.record_part(state["current"], "build", {"state": "done"}, "r", at(1))
        cron.record_part(state["current"], "motion", {"state": "done"}, "r", at(2))
        d = cron.decide(state, at(cron.ABANDON_HOURS + 1), "b" * 40, None, lambda sha: ["motion", "stress"], None)
        self.assertEqual((d["action"], d["sha"]), ("finish", "a" * 40), "not abandoned: its rows get judged")
        self.assertEqual(state["current"]["parts"]["stress"]["state"], "not_run")
        self.assertIn("bound", state["current"]["parts"]["stress"]["reason"])
        self.assertEqual(state["current"]["parts_todo"], [])
        self.assertFalse(any(e.get("status") == "abandoned" for e in state.get("history", [])))
        cron.finish_measurement(state, {}, 8.33, None, "r", at(cron.ABANDON_HOURS + 1), None)
        self.assertEqual(state["history"][-1]["failed_parts"], ["stress"])
        self.assertIn("bound", state["history"][-1]["failed_why"]["stress"])

    def test_a_closed_tip_that_never_finishes_is_abandoned_after_the_grace(self):
        state = cron.empty_state(T0)
        cron.decide(state, T0, "a" * 40, None, lambda sha: ["motion", "stress"], None)
        cron.record_part(state["current"], "build", {"state": "done"}, "r", at(1))
        cron.decide(state, at(cron.ABANDON_HOURS + 1), None, None, lambda sha: ["motion", "stress"], None)
        self.assertEqual(state["current"]["sha"], "a" * 40)
        d = cron.decide(state, at(cron.ABANDON_HOURS + 2 + cron.CLOSE_GRACE_HOURS), "b" * 40, None,
                        lambda sha: ["motion", "stress"], None)
        self.assertEqual(d["sha"], "b" * 40)
        self.assertEqual(state["history"][-1]["status"], "abandoned")

    def test_a_bisect_step_at_its_bound_is_still_abandoned(self):
        state = cron.empty_state(T0)
        rng = {"good": "a" * 40, "bad": "e" * 40, "skip": [], "steps": 0}
        rows = ["sidebar.400.scroll.frame"]
        cron.decide(state, T0, None, {"sha": "c" * 40, "range": rng, "rows": rows}, lambda sha: ALL, None)
        self.assertEqual(state["current"]["kind"], "bisect")
        cron.record_part(state["current"], "build", {"state": "done"}, "r", at(1))
        cron.decide(state, at(cron.ABANDON_HOURS + 1), None, None, lambda sha: ALL, None)
        self.assertIsNone(state["current"])
        self.assertEqual(state["history"][-1]["status"], "abandoned")

    def test_a_part_with_no_stored_rows_goes_before_the_stale_ones(self):
        state = cron.empty_state(T0)
        state["part_stored"] = {"motion": {"at": cron.iso(T0)}, "stress": {"at": cron.iso(at(1))}}
        t = at(cron.PART_STALE_HOURS + 2)
        self.assertEqual(cron.part_order(state, ["build", "motion", "stress", "fresh"], t),
                         ["build", "fresh", "motion", "stress"])

    def test_a_due_part_with_a_goal_goes_before_the_other_due_parts(self):
        state = cron.empty_state(T0)
        state["part_stored"] = {"chat-anim": {"at": cron.iso(at(1))}, "motion": {"at": cron.iso(T0)}}
        t = at(cron.PART_STALE_HOURS + 2)
        self.assertEqual(cron.PART_BY_NAME["chat-anim"].get("goal"), "typing-latency")
        self.assertEqual(cron.PART_BY_NAME["web-ui-god"].get("goal"), "god-chat-ratios")
        state["last"] = {"rows": {"sidebar.400.scroll.frame@host": {"p95": 1}}}  # sidebar: no stored rows, a row read
        self.assertEqual(cron.part_order(state, ["build", "motion", "sidebar", "fresh", "chat-anim"], t),
                         ["build", "fresh", "chat-anim", "sidebar", "motion"],
                         "only a part with no row anywhere goes before the goal's part")

    def test_memory_agents_goes_right_after_the_build_once_due(self):
        # memory-per-chat: the part feeds NOW's chat_memory_vs_empty_ratio; without a goal it sat behind every stale
        # Mac part and tips were given up before it ran (2026-11-23..26).
        self.assertEqual(cron.PART_BY_NAME["memory-agents"].get("goal"), "memory-per-chat")
        state = cron.empty_state(T0)
        state["part_stored"] = {"memory-agents": {"at": cron.iso(at(1))}, "motion": {"at": cron.iso(T0)},
                                "stress": {"at": cron.iso(T0)}}
        t = at(cron.PART_STALE_HOURS + 2)
        self.assertEqual(cron.part_order(state, ["build", "motion", "stress", "memory-agents"], t),
                         ["build", "memory-agents", "motion", "stress"])

    def test_a_part_with_a_goal_that_is_not_due_keeps_its_place(self):
        state = cron.empty_state(T0)
        t = at(1)
        state["part_stored"] = {"chat-anim": {"at": cron.iso(t)}, "motion": {"at": cron.iso(t)}}
        self.assertEqual(cron.part_order(state, ["build", "motion", "chat-anim"], t), ["build", "motion", "chat-anim"])

    def test_a_part_with_no_stored_rows_that_failed_last_time_goes_after_the_stale_ones(self):
        state = cron.empty_state(T0)
        state["part_stored"] = {"web-ui-god": {"at": cron.iso(T0)}}
        state["history"] = [{"sha": "a" * 40, "kind": "tip", "failed_parts": ["coord-sim", "web-ui-flat", "web-ui"],
                             "ran_failed": ["coord-sim", "web-ui-flat"]}]
        t = at(cron.PART_STALE_HOURS + 2)
        self.assertEqual(cron.part_order(state, ["build", "coord-sim", "web-ui-flat", "fresh", "web-ui-god"], t),
                         ["build", "fresh", "web-ui-god", "coord-sim", "web-ui-flat"])

    def test_a_goal_part_whose_store_lacked_its_goal_rows_stays_due(self):
        # 2026-11-26: web-ui-god stored 58 rows at 17:22Z but no webui.god_ratio.transcript_replay.long row
        # (transcript-replay-god timed out after 420 s); it read fresh and sat sixth of the next tip's Linux parts.
        state = cron.empty_state(T0)
        t = at(2)
        stored_at = cron.iso(at(1))
        state["part_stored"] = {"web-ui-god": {"at": stored_at, "incomplete": "transcript-replay-god: timed out"},
                                "web-ui": {"at": stored_at}, "diff-viewer": {"at": stored_at}}
        state["part_rows"] = {"webui.god_ratio.chat_open.compact.latest@h": {"p95": 1, "at": stored_at},
                              "webui.god_ratio.transcript_replay.long.token_ms@h": {"p95": 1.5, "at": cron.iso(T0)}}
        todo = ["diff-viewer", "web-ui", "web-ui-god"]
        self.assertEqual(cron.part_order(state, todo, t), ["web-ui-god", "diff-viewer", "web-ui"])
        # Once a run stores the goal's rows the part is fresh again and keeps its place.
        state["part_rows"]["webui.god_ratio.transcript_replay.long.token_ms@h"]["at"] = stored_at
        self.assertEqual(cron.part_order(state, todo, t), todo)

    def test_a_part_without_goal_rows_is_never_due_for_them(self):
        state = cron.empty_state(T0)
        self.assertFalse(cron.goal_rows_missing(state, "web-ui", {"at": cron.iso(T0)}))
        self.assertFalse(cron.goal_rows_missing(state, "chat-anim", {"at": cron.iso(T0)}))

    def test_the_sim_parts_that_failed_last_time_still_go_first_for_their_goal(self):
        # Tip c2b1760e0a63 (2026-11-26): both sim parts failed at b4a3f5019f7f and stored no row, so they sat behind the
        # stale Linux parts while NOW's sim_ladder_marginal_ratio_max and sim_fidelity_divergence_max kept one value.
        for name in ("web-ui-ladder", "web-ui-fidelity"):
            self.assertEqual(cron.PART_BY_NAME[name].get("goal"), "sim-fidelity-flat-ladder")
        state = cron.empty_state(T0)
        state["part_stored"] = {"web-ui-scale": {"at": cron.iso(T0)}, "daemon-restart": {"at": cron.iso(T0)}}
        state["last"] = {"rows": {"webui.chat_search.x@host": {"p95": 1}}}
        state["history"] = [{"sha": "a" * 40, "kind": "tip", "failed_parts": ["web-ui-ladder", "web-ui-fidelity"],
                             "ran_failed": ["web-ui-ladder", "web-ui-fidelity"]}]
        t = at(cron.PART_STALE_HOURS + 2)
        order = cron.part_order(state, ["build", "web-ui-scale", "daemon-restart", "web-ui-ladder", "web-ui-fidelity"], t)
        self.assertEqual(order, ["build", "web-ui-ladder", "web-ui-fidelity", "web-ui-scale", "daemon-restart"])

    def test_an_older_history_entry_names_its_failed_runs_by_their_reason(self):
        state = cron.empty_state(T0)
        state["history"] = [{"sha": "a" * 40, "kind": "tip", "failed_parts": ["coord-sim", "web-ui", "web-ui-god", "build"],
                             "failed_why": {
                                 "coord-sim": "coord-sim gen: /w/shapes/default.json: No such file or directory (os error 2)",
                                 "web-ui": "chat-open: timed out after 105 s; chat-switch: exit 1",
                                 "web-ui-god": "not run: the measurement reached its bound (12 h active or 48 h in all)",
                                 "build": "no published cmux-tui tree of 2322b92a504d for 2 h"}},
                            {"sha": "b" * 40, "kind": "bisect", "failed_parts": ["web-ui-god"], "ran_failed": ["web-ui-god"]}]
        self.assertEqual(cron.ran_failed(state), {"coord-sim", "web-ui"})

    def test_a_part_with_no_row_anywhere_goes_before_one_with_old_rows(self):
        state = cron.empty_state(T0)
        state["part_stored"] = {}
        state["last"] = {"rows": {"sidebar.400.scroll.frame@cmux20-bench": {"p95": 1}}}
        self.assertEqual(cron.part_for_row("sidebar.400.scroll.frame"), "sidebar")
        self.assertEqual(cron.part_order(state, ["build", "sidebar", "fresh"], at(1)), ["build", "fresh", "sidebar"])

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
        self.assertEqual((d["part"], d["linux_parts"]), ("build", []))

    def test_bisect_midpoint_takes_the_measurable_commit_nearest_the_middle(self):
        commits = ["c1", "c2", "c3", "c4", "c5"]
        self.assertEqual(cron.bisect_midpoint(commits, lambda c: True), "c3")
        self.assertEqual(cron.bisect_midpoint(commits, lambda c: c in ("c1", "c4")), "c4")
        self.assertIsNone(cron.bisect_midpoint(commits, lambda c: False))
        self.assertIsNone(cron.bisect_midpoint([], lambda c: True))
        self.assertNotEqual(cron.bisect_midpoint(commits, lambda c: True, skip=["c3"]), "c3", "a skipped commit is not picked again")
        self.assertIsNone(cron.bisect_midpoint(commits, lambda c: True, skip=commits))

    def test_bisect_next_judges_at_most_its_budget_and_goes_on_from_its_place(self):
        commits = [f"c{i}" for i in range(1, 10)]  # nearest the middle first: c5 c4 c6 c3 c7 c2 c8 c1 c9
        judged = []

        def only_c1(c):
            judged.append(c)
            return c == "c1"
        self.assertEqual(cron.bisect_next(commits, only_c1, budget=3), (None, 3))
        self.assertEqual(judged, ["c5", "c4", "c6"])
        self.assertEqual(cron.bisect_next(commits, only_c1, skip=["c7"], start=3, budget=2), (None, 6),
                         "a skipped commit costs nothing")
        self.assertEqual(judged[3:], ["c3", "c2"])
        self.assertEqual(cron.bisect_next(commits, only_c1, start=6, budget=3), ("c1", 7))
        self.assertEqual(cron.bisect_next(commits, only_c1, start=9, budget=3), (None, 9), "every commit judged")
        self.assertEqual(cron.bisect_next(commits, lambda c: c == "c2"), ("c2", 5), "no budget: no bound")


class RegressionTests(unittest.TestCase):
    def test_worse_by_ten_percent_and_the_floor_regresses(self):
        regs = cron.find_regressions({"tab_switch.terminal.10.e2e": row(14.0)}, {"tab_switch.terminal.10.e2e": row(12.0)},
                                     16.67, 16.67, budgets_mod)
        self.assertEqual([r["name"] for r in regs], ["tab_switch.terminal.10.e2e"])

    def test_noise_under_the_floor_does_not(self):
        regs = cron.find_regressions({"x.input_to_commit": row(5.6)}, {"x.input_to_commit": row(5.0)}, 16.67, 16.67, budgets_mod)
        self.assertEqual(regs, [])

    def test_terminal_throughput_rows_are_stored_never_judged(self):
        # MB/s and the NEXT/Ghostty ratio are higher-is-better: a faster run must not read as a regression, and the
        # rows stay reporting only (the CMUX-571 goal reads terminal.throughput.ratio).
        now = {"terminal.throughput.next_mb_s@cmux20-bench": row(400.0, unit="MB/s", floor=40.0),
               "terminal.throughput.ratio@cmux20-bench": row(2.0, unit="x", floor=0.1)}
        base = {"terminal.throughput.next_mb_s@cmux20-bench": row(100.0, unit="MB/s", floor=10.0),
                "terminal.throughput.ratio@cmux20-bench": row(0.5, unit="x", floor=0.1)}
        self.assertEqual(cron.find_regressions(now, base, 8.33, 8.33, budgets_mod), [])
        self.assertEqual(cron.part_for_row("terminal.throughput.ratio@cmux20-bench"), "throughput")
        report = {"rows": [{"name": "terminal.throughput.ratio", "p50": 0.8, "p95": 0.8, "unit": "x", "budget": None,
                            "floor": 0.1}]}
        rows = cron.rows_of_part(cron.PART_BY_NAME["throughput"], report, budgets_mod, {})
        self.assertEqual(rows["terminal.throughput.ratio"]["p95"], 0.8)

    def test_terminal_key_to_echo_rows_pool_rounds_with_the_perf_lead_target(self):
        # typing-frame-bench.py's terminal runs: every round's keys pooled per phase into one row, p50 and p95 of key to
        # echoed frame, judged against perf-lead.md's 8 ms (not the generic 10 ms). Other surfaces give no row here.
        keys = lambda base: [base + i / 10 for i in range(20)]  # base .. base+1.9
        report = {"runs": [
            {"session": "light", "surface": "terminal", "phase": "idle", "key_to_frame_values": keys(3.0)},
            {"session": "light", "surface": "terminal", "phase": "idle", "key_to_frame_values": keys(4.0)},
            {"session": "light", "surface": "terminal", "phase": "load", "key_to_frame_values": keys(9.0)},
            {"session": "stress", "surface": "terminal", "phase": "idle", "key_to_frame_values": keys(5.0)},
            {"session": "light", "surface": "home", "phase": "idle", "key_to_frame_values": keys(1.0)},
            {"session": "light", "surface": "terminal", "phase": "idle", "key_to_frame_ms": {"p95": 99.0}},
        ]}
        part = cron.PART_BY_NAME["typing"]
        rows = cron.rows_of_part(part, report, budgets_mod, {})
        self.assertEqual(sorted(rows), ["terminal.key_to_echo.idle", "terminal.key_to_echo.load",
                                        "terminal.key_to_echo.stress.idle"])
        idle = rows["terminal.key_to_echo.idle"]
        self.assertEqual(idle["n"], 40)
        self.assertEqual(idle["p50"], round(budgets_mod.pct(keys(3.0) + keys(4.0), 0.5), 2))
        self.assertEqual(idle["p95"], round(budgets_mod.pct(keys(3.0) + keys(4.0), 0.95), 2))
        self.assertEqual((idle["unit"], idle["budget"]), ("ms", cron.TYPING_KEY_TO_ECHO_MS))
        self.assertEqual(cron.TYPING_KEY_TO_ECHO_MS, 8.0)
        self.assertEqual(cron.target_of("terminal.key_to_echo.idle@cmux21", idle, 8.33), 8.0)
        self.assertFalse(cron.over_target("terminal.key_to_echo.idle@cmux21", idle, 8.33))
        self.assertTrue(cron.over_target("terminal.key_to_echo.load@cmux21", rows["terminal.key_to_echo.load"], 8.33))
        self.assertEqual(cron.part_for_row("terminal.key_to_echo.load@cmux21"), "typing")
        self.assertEqual(cron.part_for_row("terminal.throughput.ratio@cmux21"), "throughput")
        self.assertEqual(cron.rows_of_part(part, {"runs": [{"surface": "terminal", "phase": "idle"}]}, budgets_mod, {}), {})
        # 9 ms is over 8 ms but under the generic 10: only the row's own target catches it.
        regs = cron.find_regressions({"terminal.key_to_echo.idle@cmux21": row(9.0, budget=8.0)},
                                     {"terminal.key_to_echo.idle@cmux21": row(7.5, budget=8.0)}, 8.33, 8.33, budgets_mod)
        self.assertEqual([(r["name"], r["target"]) for r in regs], [("terminal.key_to_echo.idle@cmux21", 8.0)])

    def test_typing_part_types_into_the_terminal_on_the_bench_build(self):
        args = cron.PART_BY_NAME["typing"]["args"]
        self.assertIn("--suite=typing-frame", args)
        self.assertIn("--surfaces=terminal", args)
        self.assertIn("--phases=idle", args, "the load phase measured no key on cmux23 (focus stayed on an agent chat)")
        self.assertIn("--app-cache", args)
        self.assertEqual([a for a in args if a.startswith("--config=")],
                         [a for a in cron.PART_BY_NAME["throughput"]["args"] if a.startswith("--config=")],
                         "one bench build serves typing and throughput")
        self.assertFalse(cron.is_linux_part("typing"))

    def test_typing_stage_rows_are_stored_never_judged(self):
        # CMUX-571 typing-latency: to_listener and to_work say where acp.<engine>.typing.to_frame's time goes; they are
        # stored and shown (measurement only), while to_frame itself stays judged.
        now = {"acp.chromium.typing.to_work@cmux20-bench": row(12.0), "acp.own.typing.to_listener@cmux20-bench": row(9.0),
               "acp.chromium.typing.to_frame@cmux20-bench": row(14.0)}
        base = {"acp.chromium.typing.to_work@cmux20-bench": row(3.0), "acp.own.typing.to_listener@cmux20-bench": row(1.0),
                "acp.chromium.typing.to_frame@cmux20-bench": row(10.0)}
        regs = cron.find_regressions(now, base, 8.33, 8.33, budgets_mod)
        self.assertEqual([r["name"] for r in regs], ["acp.chromium.typing.to_frame@cmux20-bench"])
        self.assertEqual(cron.part_for_row("acp.chromium.typing.to_work@cmux20-bench"), "chat-anim")
        report = {"rows": [{"name": "acp.chromium.typing.to_work", "p50": 3.1, "p95": 6.0, "unit": "ms", "budget": None,
                            "floor": 1.0}]}
        rows = cron.rows_of_part(cron.PART_BY_NAME["chat-anim"], report, budgets_mod, {})
        self.assertEqual(rows["acp.chromium.typing.to_work"]["p95"], 6.0)

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
        self.assertIsNone(cron.target_of("workspace_scaling.type.1000", row(99.0), 16.67),
                          "workspace scaling is advisory ratio-only")

    def test_a_new_perf_gate_failure_regresses(self):
        regs = cron.find_regressions({"perf_gate.tabs.failed_checks": row(1, "checks", 0.5)},
                                     {"perf_gate.tabs.failed_checks": row(0, "checks", 0.5)}, None, None, budgets_mod)
        self.assertEqual(len(regs), 1)

    def test_a_wakeup_row_regresses_by_the_timer_that_woke_it(self):
        """shadow-leo on goal idle-cpu-wakeups: "make a new idle timer fail the PR that adds it" by name. The bench's
        rest_wakeups row carries its sources (perfRow.ts); the regression and the issue cell name them."""
        named = ["3x timeouts: armRequestCheck < noteRequest @ 10,2010,4010 ms", "1x frames: frameTally | x"]
        rows = cron.webui_rows([{"name": "chat_switch.god.unread.rest_wakeups", "p95": 4, "unit": "count",
                                 "target": 0, "floor": 0.5, "sources": named + [7, ""]}])
        now = rows["webui.chat_switch.god.unread.rest_wakeups"]
        self.assertEqual(now["sources"], named, "strings only, busiest first")
        regs = cron.find_regressions(rows, {"webui.chat_switch.god.unread.rest_wakeups": {**now, "p95": 1}},
                                     None, None, budgets_mod)
        self.assertEqual(regs[0]["sources"], named)
        cell = cron.sources_note(regs[0])
        self.assertIn("woken by: 3x timeouts: armRequestCheck", cell)
        self.assertIn("frameTally \\| x", cell, "a pipe is escaped: it never splits the issue table")
        self.assertEqual(cron.sources_note({"name": "a"}), "", "a row with no sources keeps its cell")
        self.assertNotIn("sources", cron.webui_rows([{"name": "a.b", "p95": 1}])["webui.a.b"])

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

    def test_dock_launch_over_one_bounce_is_flagged(self):
        """CMUX-631: a Dock launch whose applicationDidFinishLaunching starts after 250 ms (more than one bounce) is a
        row over its target, so the cron lists it; under 250 ms it passes."""
        part = cron.PART_BY_NAME["launch-dock"]
        self.assertIn("--activation", part["args"])
        self.assertEqual(part["args"][part["args"].index("--activation") + 1], "active")
        slow = {"split-spring": {"warm": [{"did_finish_launching_start": v, "first_window_frame_committed": v + 300}
                                          for v in (1290, 1306, 1330)]}}
        rows = cron.rows_of_part(part, slow, budgets_mod, {"rows": {}})
        name = "launch.dock.warm.did_finish_launching_start"
        self.assertEqual(cron.target_of(name, rows[name], 16.67), 250)
        self.assertTrue(cron.over_target(name, rows[name], 16.67))
        self.assertEqual(cron.part_for_row(name), "launch-dock")
        regs = cron.find_regressions({name: rows[name]}, {}, 16.67, 16.67, budgets_mod)
        self.assertEqual([r["name"] for r in regs], [name], "over one bounce with no reference is still listed")
        fast = {"split-spring": {"warm": [{"did_finish_launching_start": v, "first_window_frame_committed": v + 100}
                                          for v in (118, 123, 131)]}}
        rows = cron.rows_of_part(part, fast, budgets_mod, {"rows": {}})
        self.assertFalse(cron.over_target(name, rows[name], 16.67))
        self.assertNotIn("launch.warm.did_finish_launching_start", rows, "the Dock part's rows never mix with the direct exec's")

    def test_dock_relaunch_time_before_main_is_a_row(self):
        """The code-sign clone's rescan before main on a Dock relaunch (about 600 ms) shows as launch.dock.warm.main_start
        over its 166 ms budget."""
        part = cron.PART_BY_NAME["launch-dock"]
        rows = cron.rows_of_part(part, {"split-spring": {"warm": [{"main_start": v} for v in (598, 616, 640)]}},
                                 budgets_mod, {"rows": {}})
        name = "launch.dock.warm.main_start"
        self.assertEqual(cron.target_of(name, rows[name], 16.67), 166)
        self.assertTrue(cron.over_target(name, rows[name], 16.67))

    def test_cold_launch_rows_judge_home_against_600_ms(self):
        """A cold launch (no daemon, empty home, a fresh copy of the bundle each run) stores launch.cold.<mark> rows: Home
        on screen against 600 ms (goals/next-launch-instant.md) and the first frame against 300 ms (launch-shell-first.md);
        a run that never showed Home is a missing_runs row, not a dropped value."""
        part = cron.PART_BY_NAME["launch-cold"]
        args = part["args"]
        for word in ("--mode=cold", "--fresh-copy", "--ready-mark=reveal.home", "--activation=active",
                     "--window-placement=restore"):
            self.assertIn(word, args)
        self.assertLessEqual(len(args) + 1, 16, "the controller's step takes at most 16 args (with --vdisplay-hold)")
        slow = {"split-spring": {"cold": [{"main_start": 1500, "first_window_frame_committed": v, "reveal.home": v + 150}
                                          for v in (2790, 2800, 2950)] + [{"main_start": 1490, "first_window_frame_committed": 2810}]},
                "not_run": []}
        rows = cron.rows_of_part(part, slow, budgets_mod, {"rows": {}})
        home, frame = "launch.cold.reveal.home", "launch.cold.first_window_frame_committed"
        self.assertEqual(rows[home]["p50"], 2950)
        self.assertEqual(cron.target_of(home, rows[home], 16.67), 600)
        self.assertEqual(cron.target_of(frame, rows[frame], 16.67), 300)
        self.assertTrue(cron.over_target(home, rows[home], 16.67))
        self.assertEqual(rows[home + ".missing_runs"]["p95"], 1, "the run that never showed Home")
        self.assertEqual(rows[frame + ".missing_runs"]["p95"], 0)
        for name in (home, frame, home + ".missing_runs"):
            self.assertEqual(cron.part_for_row(name), "launch-cold")
        self.assertEqual(cron.part_for_row("launch.warm.reveal.home"), "launch")
        self.assertNotIn("launch.cold.sidebar_rows_shown", rows, "only the cold budget's marks are rows")
        regs = cron.find_regressions({home: rows[home]}, {}, 16.67, 16.67, budgets_mod)
        self.assertEqual([r["name"] for r in regs], [home], "over 600 ms with no reference is still listed")
        fast = {"split-spring": {"cold": [{"first_window_frame_committed": v, "reveal.home": v + 200} for v in (240, 260, 280)]}}
        rows = cron.rows_of_part(part, fast, budgets_mod, {"rows": {}})
        self.assertFalse(cron.over_target(home, rows[home], 16.67))
        self.assertFalse(cron.over_target(frame, rows[frame], 16.67))

    def test_stress_pane_summary_rows(self):
        report = {"summary": [{"action": "close", "layout": "stress", "frames_p50_ms": 16.6, "frames_p95_ms": 33.3}],
                  "runs": [{"refresh_ms": 16.67}]}
        budgets = {"rows": {r"panes\..*\.frame": {"p95": 8.33, "unit": "ms", "floor": 1.0}}, "_animations": {}}
        rows = cron.rows_of_part(cron.PART_BY_NAME["stress"], report, budgets_mod, budgets)
        self.assertEqual(rows["panes.close.stress.frame"]["p95"], 33.3)
        self.assertEqual(cron.refresh_ms_of(report), 16.67)
        self.assertEqual(cron.part_for_row("panes.close.stress.frame"), "stress")
        self.assertEqual(cron.part_for_row("panes.close.4x2.frame"), "motion")
        # Tabs and terminals at scale are their own part; one tab or workspace stays where it was.
        self.assertEqual(cron.part_for_row("cmd_t.idle_30ws.key_to_visible@cmux20-bench"), "tabs")
        self.assertEqual(cron.part_for_row("tab_switch.terminal.30.e2e@cmux20-bench"), "tabs")
        self.assertEqual(cron.part_for_row("tab_close.chat.burst.input_to_commit"), "tabs")
        self.assertEqual(cron.part_for_row("cmd_t.idle.key_to_visible"), "motion")
        self.assertEqual(cron.part_for_row("tab_switch.terminal.10.e2e"), "switch")


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
        # A commit is decided by BISECT_RUNS agreeing runs (test_perf_bisect.py tests the rule): the first two run again.
        for i in range(cron.BISECT_RUNS - 1):
            self.assertEqual(self.bisected(state, "c" * 40, {"t.e2e": row(5.2)}, 2 + i * 0.1), "skipped")
        self.assertEqual(self.bisected(state, "c" * 40, {"t.e2e": row(5.2)}, 2.5), "narrowed")
        self.assertEqual(self.rng(state, "t.e2e"), ("c" * 40, "e" * 40))
        for i in range(cron.BISECT_RUNS):
            self.bisected(state, "d" * 40, {"t.e2e": row(9.2)}, 3 + i * 0.1)
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


    def test_a_build_the_fleet_failed_runs_again_at_the_same_tip(self):
        # 2026-11-15 to 11-26 no measurement finished: 8 tips in turn lost every Mac part, chat-anim among them, to a
        # build the fleet failed (HTTP 403 checkout, a 503 reviewed-tip fetch, no published cmux-tui tree).
        causes = ["checkout: GitHub refused the fetch (HTTP 403)",
                  "ci-step reviewed check: no reviewed tip could be fetched: http://h/v1/git/x returned error: 503",
                  "no published cmux-tui tree for a0b1c2d3 for 2 h"]
        for why in causes:
            cur = cron.new_measurement("a" * 40, "tip", ["build", "chat-anim", "sidebar"], T0)
            for n in range(cron.BUILD_INFRA_RETRIES):
                cron.record_part(cur, "build", {"state": "failed", "tail": [why], "build_failed": True}, "r")
                self.assertEqual(cur["parts_todo"], ["build", "chat-anim", "sidebar"], why)
                self.assertEqual(cur["parts"]["build"]["infra_retries"], n + 1)
                self.assertFalse(cron.commit_failed(cur), "the fleet's failure is not the commit's")
                self.assertTrue(cron.build_failed_tip(cur), "a newer tip may take the retry (supersede_for_unread)")
                self.assertTrue(cron.build_never_ran(cur), "and the base is not judged broken")
            cron.record_part(cur, "build", {"state": "failed", "tail": [why], "build_failed": True}, "r")
            self.assertEqual(cur["parts_todo"], [], "past BUILD_INFRA_RETRIES the Mac parts end as before")
            self.assertEqual(cur["parts"]["chat-anim"]["state"], "build_failed")

    def test_a_retried_build_that_then_builds_measures_the_parts(self):
        cur = cron.new_measurement("a" * 40, "tip", ["build", "chat-anim"], T0)
        cron.record_part(cur, "build", {"state": "failed", "tail": ["GitHub refused the fetch"], "build_failed": True}, "r")
        cron.record_part(cur, "build", {"state": "done"}, "r")
        self.assertEqual(cur["parts_todo"], ["chat-anim"])
        self.assertNotIn("infra_retried", cur["parts"]["build"])
        cur = cron.new_measurement("a" * 40, "tip", ["build", "chat-anim"], T0)
        cron.record_part(cur, "build", {"state": "failed", "tail": ["GitHub refused the fetch"], "build_failed": True}, "r")
        cron.record_part(cur, "build", {"state": "failed", "tail": ["error: no member 'x'"], "build_failed": True}, "r")
        self.assertEqual(cur["parts"]["chat-anim"]["state"], "build_failed", "the retry's own compile error ends it")
        self.assertFalse(cron.build_never_ran(cur))
        self.assertTrue(cron.commit_failed(cur))

    def test_a_compile_error_still_fails_the_tip_at_once(self):
        for tail in (["error: cannot find 'Foo' in scope", "** BUILD FAILED **"], ["build: step exited 65"]):
            cur = cron.new_measurement("a" * 40, "tip", ["build", "chat-anim", "sidebar"], T0)
            cron.record_part(cur, "build", {"state": "failed", "tail": tail, "build_failed": True}, "r")
            self.assertEqual(cur["parts_todo"], [], tail)
            self.assertEqual(cur["parts"]["chat-anim"]["state"], "build_failed")
            self.assertTrue(cron.commit_failed(cur))

    def test_a_timed_out_build_is_not_retried_as_the_fleet_s(self):
        cur = cron.new_measurement("a" * 40, "tip", ["build", "chat-anim"], T0)
        cron.record_part(cur, "build", {"state": "failed", "timed_out": True, "tail": ["returned error: 503"]}, "r")
        self.assertNotIn("infra_retries", cur["parts"]["build"])

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
            # 2026-11-11..13: four tip measurements in a row ended incomplete on the same five parts, and the issue
            # said only "no finished measurement", guessing a busy fleet.
            why = "panes.close.4x2.frame: missing current p95"
            self.assertEqual(state["history"][-1]["failed_why"], {"motion": why})
            self.assertEqual(state["last_tried"]["failed_why"], {"motion": why})
            body = cron.issue_body(state, "o/r", at(cron.STALE_HOURS + 1))
            self.assertIn(f"is not the last measurement: 1 part(s) did not finish: motion (`{why}`).", body)
            self.assertIn("the last 1 tip measurement(s) each ran and ended incomplete, every one without motion", body)
            self.assertNotIn("no measure host had idle time", body)

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


    def test_the_issue_carries_each_ranges_stage_as_json(self):
        a, b, c, d = "a" * 40, "b" * 40, "c" * 40, "d" * 40
        state = cron.empty_state(T0)
        state["last_good"] = {"sha": a, "rows": {}, "run_url": "g"}
        reg = {"p95": 30.0, "base": 16.7, "unit": "ms", "target": 20.8, "why": "worse than last good"}
        state["regressions"] = [
            {**reg, "name": "p.one", "range": {"good": a, "bad": b, "skip": [], "steps": 2},
             "first_bad": {"sha": b, "measured_at": cron.iso(at(2))}},
            {**reg, "name": "p.two", "range": {"good": a, "bad": b, "skip": [], "steps": 2},
             "first_bad": {"sha": b, "measured_at": cron.iso(at(1))}},
            {**reg, "name": "p.three", "range": {"good": c, "bad": d, "skip": [], "steps": 5, "culprit": d},
             "first_bad": {"sha": d, "measured_at": cron.iso(at(3))}},
            {**reg, "name": "p.four", "range": {"good": a, "bad": d, "skip": [], "steps": 0},
             "first_bad": {"sha": d}, "recovering": [{"sha": d, "p95": 16.0}]},
        ]
        state["culprits"] = [{"sha": d, "pr": 123}]
        body = cron.issue_body(state, "o/r", at(4))
        self.assertIn(cron.TASK_MARK, body)
        block = body.split(cron.TASK_MARK, 1)[1].split("```json\n", 1)[1].split("\n```", 1)[0]
        tasks = {t["id"]: t for t in json.loads(block)["tasks"]}
        open_range = tasks[f"{a[:11]}..{b[:11]}"]
        self.assertEqual(open_range["stage"], "needs investigation")
        self.assertEqual(open_range["rows"], ["p.one", "p.two"])
        self.assertEqual(open_range["opened_at"], cron.iso(at(1)), "the group opened with its earliest row")
        named = tasks[f"{c[:11]}..{d[:11]}"]
        self.assertEqual((named["stage"], named["culprit"], named["pr"]), ("culprit named", d, 123))
        self.assertIn("disprove", named["next"])
        self.assertEqual(tasks[f"{a[:11]}..{d[:11]}"]["stage"], "recovering")
        self.assertIsNone(tasks[f"{a[:11]}..{d[:11]}"]["opened_at"])

    def test_no_regression_writes_no_task_block(self):
        self.assertNotIn(cron.TASK_MARK, cron.issue_body(cron.empty_state(T0), "o/r", T0))


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

    def test_a_busy_runner_divides_the_stream_row_by_its_bench_contention(self):
        report = {"sidecar": {"manifestDecodeP95Micros": 400, "sequentialReadMibPerSecond": 1024.0},
                  "stream": {"p95Ms": 120.0}, "load": {"sidecar": 1.0, "stream": 2.0}}
        rows = cron.rows_of_part(cron.PART_BY_NAME["diff-viewer"], report, budgets_mod, {"rows": {}})
        self.assertEqual(rows["diff.stream.p95"]["p95"], 60.0)
        self.assertEqual(rows["diff.stream.p95"]["raw_p95"], 120.0)
        self.assertEqual(rows["diff.stream.p95"]["load"], 2.0)
        self.assertEqual(rows["diff.sidecar.manifest_decode_p95"]["p95"], 400, "a factor of 1 leaves the row as measured")
        self.assertNotIn("load", rows["diff.sidecar.manifest_decode_p95"])

    def test_the_sidecar_medians_of_short_reads_are_never_scaled(self):
        """#39309 F1: a busy run's 89.22 ms/GiB divided by 4 would make the next idle 74.03 a regression."""
        report = {"sidecar": {"manifestDecodeP95Micros": 400, "sequentialReadMibPerSecond": 1024 * 1000 / 89.22},
                  "stream": {"p95Ms": 120.0}, "load": {"sidecar": 4.0, "stream": 1.0}}
        rows = cron.rows_of_part(cron.PART_BY_NAME["diff-viewer"], report, budgets_mod, {"rows": {}})
        self.assertEqual(rows["diff.sidecar.read_ms_per_gib"]["p95"], 89.22)
        self.assertEqual(rows["diff.sidecar.read_ms_per_gib"]["load"], 4.0)
        self.assertNotIn("raw_p95", rows["diff.sidecar.read_ms_per_gib"])
        self.assertEqual(rows["diff.sidecar.manifest_decode_p95"]["p95"], 400)

    def test_the_contention_factor_is_the_median_clamped(self):
        self.assertEqual(cron.contention_factor([1.01, 0.97, 1.0]), 1.0)
        self.assertEqual(cron.contention_factor([2.1, 1.9, 2.0, 30]), 2.05)
        self.assertEqual(cron.contention_factor([50, 60]), cron.CONTENTION_MAX)
        self.assertEqual(cron.contention_factor([]), 1.0)
        self.assertGreater(cron.spin_ratio(0.005), 0.5)

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

    def test_the_memory_agents_part_owns_its_rows_and_reads_its_suites_report(self):
        """CMUX-571: goals ram-baseline and memory-per-chat read these rows (memory-agents-cron.py)."""
        self.assertIn("memory-agents", FLEET, "a Mac part on the measure host")
        self.assertEqual(cron.part_for_row("memory.app_agents.empty.total_footprint_mb@cmux20-bench"), "memory-agents")
        self.assertEqual(cron.part_for_row("memory.app_agents.ratio_vs_empty@cmux20-bench"), "memory-agents")
        self.assertEqual(cron.part_for_row("idle.terminals.app_cpu_pct@cmux20-bench"), "home-idle")
        spec2 = importlib.util.spec_from_file_location("memory_agents", os.path.join(HERE, "..", "memory-agents-cron.py"))
        mem = importlib.util.module_from_spec(spec2)
        spec2.loader.exec_module(mem)
        bench = {"samples": [
            {"label": "idle-launch", "workspaces": 1, "total_footprint_mb": 904.2, "pane_failures": 0},
            {"label": "idle-10", "workspaces": 10, "total_footprint_mb": 1500.0, "pane_failures": 0},
            {"label": "idle-20", "workspaces": 17, "total_footprint_mb": 1900.0, "pane_failures": 0}]}  # partial
        report = {"rows": mem.rows_from(bench)}
        part = cron.PART_BY_NAME["memory-agents"]
        rows = cron.rows_of_part(part, report, budgets_mod, {})
        self.assertEqual(rows["memory.app_agents.empty.total_footprint_mb"]["p95"], 904.2)
        self.assertEqual(rows["memory.app_agents.10.total_footprint_mb"]["unit"], "MB")
        self.assertNotIn("memory.app_agents.20.total_footprint_mb", rows, "a count whose chats did not all open")
        self.assertEqual(rows["memory.app_agents.ratio_vs_empty"]["p95"], round(1500.0 / 904.2, 3),
                         "the highest complete count over the empty app, from one run")
        self.assertEqual(mem.rows_from({"samples": [{"label": "idle-10", "workspaces": 10, "total_footprint_mb": 1}]}), [],
                         "no empty sample: no ratio either")
        self.assertTrue(cron.report_is_incomplete(part, {"rows": [], "incomplete": ["no empty-app sample"]}))

    def test_the_cef_resize_part_owns_its_rows_and_judges_late_frames(self):
        """Live resize beside a Chromium page (cef-layer-hosting-DESIGN.md "Live resize"): every frame on time (0
        missed) and the frame's commit under half a display frame, from pane-perf-terminal.py --browser's summary."""
        self.assertIn("cef-resize", FLEET, "a Mac part on the measure host")
        self.assertIn("--config=bench", cron.PART_BY_NAME["cef-resize"]["args"])
        self.assertEqual(cron.part_for_row("cef_resize.drag.4x2.missed@cmux20-bench"), "cef-resize")
        self.assertEqual(cron.part_for_row("cef_resize.window-zoom.1x2.commit_p95_ms@cmux20-bench"), "cef-resize")
        spec2 = importlib.util.spec_from_file_location("cef_resize_cron", os.path.join(HERE, "..", "cef-resize-cron.py"))
        cr = importlib.util.module_from_spec(spec2)
        spec2.loader.exec_module(cr)
        # The shape step 5574ba49fb74 gave on 2026-11-19: a window that was not key names its layouts "-inactive".
        summary = {"summary": [
            {"layout": "4x2-inactive", "action": "drag", "missed": 2, "commit_p95_ms": 3.1, "commit_max_ms": 7.0,
             "refresh_ms": 8.33},
            {"layout": "1x2", "action": "window-zoom", "missed": 0, "commit_p95_ms": 5.0, "refresh_ms": 16.67},
            {"layout": "1x2", "action": "window-unzoom", "missed": None, "commit_p95_ms": None, "refresh_ms": 8.33}]}
        bench_rows = cr.rows_from(summary)
        self.assertEqual(cr.missing_from(bench_rows), ["window-unzoom 1x2: no rows", "window-zoom 4x2: no rows",
                                                       "window-unzoom 4x2: no rows"],
                         "each layout and action the bench gives with no number; 1x2 has no divider to drag")
        self.assertIn("--browser", cr.bench_cmd(argparse.Namespace(app="A", tag="T", rounds=3), "/o"),
                      "a Chromium page in the measured layout")
        part = cron.PART_BY_NAME["cef-resize"]
        rows = cron.rows_of_part(part, {"rows": bench_rows}, budgets_mod, {})
        self.assertEqual(sorted(rows), ["cef_resize.drag.4x2.commit_p95_ms", "cef_resize.drag.4x2.missed",
                                        "cef_resize.window-zoom.1x2.commit_p95_ms", "cef_resize.window-zoom.1x2.missed"],
                         "a layout the bench left no number for gets no row; an inactive window keeps the row name")
        self.assertTrue(next(r for r in bench_rows if r["name"] == "cef_resize.drag.4x2.missed")["window_inactive"])
        self.assertEqual(rows["cef_resize.drag.4x2.missed"]["unit"], "frames")
        self.assertEqual(cron.target_of("cef_resize.drag.4x2.missed@cmux20-bench", rows["cef_resize.drag.4x2.missed"], 8.33), 0)
        self.assertTrue(cron.over_target("cef_resize.drag.4x2.missed", rows["cef_resize.drag.4x2.missed"], 8.33))
        self.assertEqual(cron.target_of("cef_resize.drag.4x2.commit_p95_ms", rows["cef_resize.drag.4x2.commit_p95_ms"], 8.33),
                         4.17, "half a 120 Hz frame, not the 10 ms action latency")
        z = rows["cef_resize.window-zoom.1x2.commit_p95_ms"]
        self.assertEqual(z["budget"], 8.34, "half the frame it ran at")
        self.assertFalse(cron.over_target("cef_resize.window-zoom.1x2.commit_p95_ms", z, 16.67))
        self.assertTrue(cron.frame_sensitive("cef_resize.drag.4x2.missed", rows["cef_resize.drag.4x2.missed"]))
        self.assertFalse(cron.REPORT_ONLY_ROW_RE.match("cef_resize.drag.4x2.missed"), "judged, not report-only")
        self.assertEqual(len(cr.missing_from(cr.rows_from({}))), 5, "no report: every layout and action is missing")
        self.assertTrue(cron.report_is_incomplete(part, {"rows": [], "incomplete": cr.missing_from([])}))
    def test_the_idle_budget_part_judges_chromiums_idle_wakeups_per_kind(self):
        """Chromium's GPU, renderer and utility processes at idle get judged rows (idle-budget.py's light session,
        idle-budget.json: each <= 1 wakeup/s, plans/cmux-next/idle-wakeups.md section 7); every kind's wakeups/s is
        stored. Before this part no cron row had a Chromium process's wakeups, and their budgets were null."""
        self.assertIn("idle-budget", FLEET, "a Mac part on the measure host")
        part = cron.PART_BY_NAME["idle-budget"]
        self.assertIn("--suite=idle-budget", part["args"])
        self.assertIn("--sessions=light", part["args"])
        self.assertEqual(cron.part_for_row("idle_budget.light.cef-gpu.wakeups_per_s@cmux20-bench"), "idle-budget")
        self.assertEqual(cron.part_for_row("idle.terminals.app_cpu_pct@cmux20-bench"), "home-idle")
        spec2 = importlib.util.spec_from_file_location("idle_budget", os.path.join(HERE, "..", "idle-budget.py"))
        ib = importlib.util.module_from_spec(spec2)
        # Its pure parts only: off macOS there is no libproc to load (test_idle_budget.py does the same).
        with mock.patch("ctypes.CDLL") if os.uname().sysname != "Darwin" else contextlib.nullcontext():
            spec2.loader.exec_module(ib)
        with open(os.path.join(HERE, "..", "idle-budget.json")) as f:
            budget = json.load(f)
        for name in ("cef-gpu", "cef-renderer", "cef-utility"):
            self.assertEqual(budget["kinds"][name]["wakeups_max"], 1.0, f"{name} is judged, not null")

        def kind(wake, wmax, n=1):
            return {"n": n, "threads": 20, "threads_max": 20, "wakeups_per_s": wake, "wakeups_max": wmax,
                    "csw_per_s": 1.0, "cpu_pct": 0.1, "threads_ran": 1}
        report = {"sessions": {"light": {"exit": 0, "kinds": {
            "app": {**kind(0.4, 0.4), "main_wakes_per_s": 0}, "cef-gpu": kind(86.0, 86.0),
            "cef-renderer": kind(3.0, 2.2, n=2), "cef-utility": kind(0.2, 0.2), "other:zsh": kind(5.0, 5.0)}}}}
        out = ib.cron_report(report, budget)
        self.assertNotIn("incomplete", out)
        rows = cron.rows_of_part(part, out, budgets_mod, {})
        gpu = rows["idle_budget.light.cef-gpu.wakeups_max"]
        self.assertEqual((gpu["p95"], gpu["unit"], gpu["budget"]), (86.0, "/s", 1.0))
        self.assertEqual(rows["idle_budget.light.cef-gpu.wakeups_per_s"]["p95"], 86.0, "per-kind wakeups are stored")
        self.assertEqual(rows["idle_budget.light.cef-renderer.wakeups_max"]["p95"], 2.2, "judged per process")
        self.assertEqual(rows["idle_budget.light.cef-renderer.wakeups_per_s"]["p95"], 3.0, "the kind's sum")
        self.assertFalse(any(n.startswith("idle_budget.light.other:") for n in rows), "a shell is not the app's")
        found = cron.find_regressions({"idle_budget.light.cef-gpu.wakeups_max": gpu}, {}, 8.33, 8.33, budgets_mod)
        self.assertEqual([(f["name"], f["target"], f["why"]) for f in found],
                         [("idle_budget.light.cef-gpu.wakeups_max", 1.0, cron.NO_REFERENCE)],
                         "a first value over its budget is listed, not a silent pass")
        under = {**gpu, "p50": 0.6, "p95": 0.6}
        self.assertEqual(cron.find_regressions({"idle_budget.light.cef-gpu.wakeups_max": under}, {}, 8.33, 8.33, budgets_mod), [])
        # A run with no Chromium process, or a session that failed, is not done (no silent drop of judged rows).
        no_cef = {"sessions": {"light": {"exit": 0, "kinds": {"app": kind(0.4, 0.4)}}}}
        self.assertTrue(cron.report_is_incomplete(part, ib.cron_report(no_cef, budget)))
        failed = {"sessions": {"light": {"exit": 1, "error": "RuntimeError: launch"}}}
        self.assertIn("launch", ib.cron_report(failed, budget)["incomplete"][0])

    def test_the_power_user_native_part_runs_the_native_bursts_and_judges_their_rows(self):
        """Leo, 2026-11-22: "you guys also need to be testing flicks of extremely fast input for scrolling and
        resizing/mouse movement and typing/pasting/switching workspaces around. we need to test like power users more
        often." The native half of the harness runs on the measure host every measured tip; its rows (frame p95/p99,
        blank frames, flashes, lost switches, bursts a hang left unmeasured) are this part's and judged on budgets."""
        self.assertIn("power-user-native", FLEET, "a Mac part on the measure host")
        part = cron.PART_BY_NAME["power-user-native"]
        self.assertIn("--suite=power-user", part["args"])
        self.assertIn("--report-only", part["args"], "a breach still stores its rows")
        self.assertEqual(part["kind"], "budgets")
        for name in ("power_user.native.workspace.p95", "power_user.native.resize.lost",
                     "power_user.native.mixed.not_measured"):
            self.assertEqual(cron.part_for_row(name + "@cmux20-bench"), "power-user-native")
        self.assertEqual(cron.part_for_row("power.idle.tab1.total_mw@cmux20-bench"), "power")
        spec2 = importlib.util.spec_from_file_location(
            "power_user_native", os.path.join(HERE, "..", "..", "perf-bench", "power_user_native.py"))
        native = importlib.util.module_from_spec(spec2)
        spec2.loader.exec_module(native)
        report = {"budgets": native.BUDGETS, "bursts": [
            {"class": "workspace", "index": 0, "refresh_ms": 8.333, "p95_ms": 9.0, "p99_ms": 30.0, "long": 0,
             "blank_frames": 2, "flashes": 1, "shift_frames": 0, "lost": 0, "lag_run": 0, "missed": 1},
            {"class": "workspace", "index": 1, "error": "app stopped answering"}]}
        report["rows"] = native.cron_rows(report)
        rows = cron.rows_of_part(part, report, budgets_mod, {})
        self.assertEqual(rows["power_user.native.workspace.p95"]["budget"], 12.5)
        self.assertEqual(rows["power_user.native.workspace.p99"]["p95"], 30.0)
        self.assertEqual((rows["power_user.native.workspace.blank_frames"]["p95"],
                          rows["power_user.native.workspace.blank_frames"]["budget"]), (2, 0))
        self.assertEqual(rows["power_user.native.workspace.not_measured"]["p95"], 1, "a hang is a row")
        self.assertTrue(native.incomplete(report), "a cut run is not a new last good")
        self.assertTrue(cron.report_is_incomplete(part, {**report, "incomplete": native.incomplete(report)}))

    def test_the_power_part_owns_its_rows_and_judges_them_against_their_budgets(self):
        """Leo, 2026-11-19: "having those measurements in so that we're aware of things". power-cron.py stores the
        app's mW idle with a terminal (budget: standalone Ghostty idle in the same run), with one page and scrolling
        (budgets: the best other browser in the xbench baseline); the Ghostty number and the ratio are shown only."""
        self.assertIn("power", FLEET, "a Mac part on the measure host")
        part = cron.PART_BY_NAME["power"]
        self.assertIn("--suite=power", part["args"])
        self.assertIn("--config=bench", part["args"], "the optimized app, the build throughput and memory use")
        for name in ("power.idle.terminal.total_mw", "power.idle.tab1.total_mw", "power.active.scroll.total_mw",
                     "power.idle.terminal.ghostty_mw"):
            self.assertEqual(cron.part_for_row(name + "@cmux20-bench"), "power")
        spec2 = importlib.util.spec_from_file_location("power_cron", os.path.join(HERE, "..", "power-cron.py"))
        power = importlib.util.module_from_spec(spec2)
        spec2.loader.exec_module(power)
        bench = {"results": [{"label": "terminal", "total": {"mw": 3.21}}, {"label": "tab1", "total": {"mw": 5.0}},
                             {"label": "scroll", "total": {"mw": 1.5}}]}
        report = {"rows": power.rows_from(bench, 0.5)}
        rows = cron.rows_of_part(part, report, budgets_mod, {})
        terminal = rows["power.idle.terminal.total_mw"]
        self.assertEqual((terminal["p95"], terminal["unit"], terminal["budget"]), (3.21, "mW", 0.5),
                         "the terminal row's budget is Ghostty's idle mW from the same run")
        self.assertEqual(rows["power.idle.tab1.total_mw"]["budget"], 0.4)
        self.assertEqual(rows["power.active.scroll.total_mw"]["budget"], 7.7)
        self.assertEqual(rows["power.idle.terminal.vs_ghostty"]["p95"], 6.42)
        for name, row_ in rows.items():
            if not cron.REPORT_ONLY_ROW_RE.match(name):
                self.assertIsNotNone(cron.target_of(name, row_, 8.33), f"{name} is judged against a real budget")
        self.assertTrue(cron.REPORT_ONLY_ROW_RE.match("power.idle.terminal.ghostty_mw"))
        self.assertTrue(cron.REPORT_ONLY_ROW_RE.match("power.idle.terminal.vs_ghostty"))
        self.assertFalse(cron.REPORT_ONLY_ROW_RE.match("power.idle.terminal.total_mw"))
        # Over its budget with no reference: listed, not a silent pass.
        found = cron.find_regressions({"power.idle.tab1.total_mw@cmux20-bench": rows["power.idle.tab1.total_mw"]}, {},
                                      8.33, 8.33, budgets_mod)
        self.assertEqual([(r["name"], r["target"], r["why"]) for r in found],
                         [("power.idle.tab1.total_mw@cmux20-bench", 0.4, cron.NO_REFERENCE)])
        # A run with no Ghostty keeps the app's row, judged against the fallback.
        no_ghostty = {r["name"]: r for r in power.rows_from(bench, None)}
        self.assertEqual(no_ghostty["power.idle.terminal.total_mw"]["budget"], power.GHOSTTY_FALLBACK_MW)
        self.assertNotIn("power.idle.terminal.ghostty_mw", no_ghostty)
        self.assertEqual(power.missing_scenarios(power.rows_from(bench, None)), [])
        partial = power.rows_from({"results": [{"label": "terminal", "total": {"mw": 1.0}}]}, 0.5)
        self.assertEqual(power.missing_scenarios(partial), ["tab1: no power sample", "scroll: no power sample"])

    @staticmethod
    def relaunch_wake():
        spec2 = importlib.util.spec_from_file_location("relaunch_wake", os.path.join(HERE, "..", "relaunch-wake-cron.py"))
        mod = importlib.util.module_from_spec(spec2)
        spec2.loader.exec_module(mod)
        return mod

    def test_the_relaunch_part_owns_its_rows_and_judges_them_on_their_budgets(self):
        """Leo 2026-11-19 ("having those measurements in"): quit and reopen with the session restored, as rows."""
        rw = self.relaunch_wake()
        self.assertIn("relaunch", FLEET, "a Mac part on the measure host")
        self.assertEqual(cron.part_for_row("launch.relaunch.warm.chat_live_ms@cmux20-bench"), "relaunch")
        self.assertEqual(cron.part_for_row("launch.relaunch.session.terminal_live_ms@cmux21"), "relaunch")
        self.assertEqual(cron.part_for_row("launch.warm.first_window_frame_committed@cmux21"), "launch",
                         "the launch rows keep their part")
        reconnect = {"rounds": [
            {"mode": "warm", "phases": {"first window frame": 450.0, "pane painted": 1400.0, "first live event": 1500.0}},
            {"mode": "warm", "phases": {"first window frame": 470.0, "pane painted": 1450.0, "first live event": None}},
            {"mode": "update", "phases": {"first window frame": 900.0, "pane painted": 2600.0, "first live event": 2700.0}}]}
        report = {"rows": rw.reconnect_rows(reconnect)}
        part = cron.PART_BY_NAME["relaunch"]
        rows = cron.rows_of_part(part, report, budgets_mod, {})
        self.assertEqual(rows["launch.relaunch.warm.first_window_frame_ms"]["p50"], 460.0)
        self.assertEqual(rows["launch.relaunch.warm.chat_live_ms"]["p95"], 1500.0, "a round with no live event has no value")
        self.assertEqual(rows["launch.relaunch.warm.chat_missing_runs"]["p95"], 1, "it is counted instead")
        self.assertEqual(rows["launch.relaunch.update.chat_missing_runs"]["p95"], 0)
        # The targets are each row's own budget (relaunch-wake-cron.py names the sources), not the 10 ms latency one.
        self.assertEqual(cron.target_of("launch.relaunch.warm.chat_live_ms@cmux20-bench", rows["launch.relaunch.warm.chat_live_ms"], 8.33), 600)
        self.assertTrue(cron.over_target("launch.relaunch.warm.chat_live_ms@h", rows["launch.relaunch.warm.chat_live_ms"], 8.33))
        self.assertFalse(cron.over_target("launch.relaunch.warm.first_window_frame_ms@h", rows["launch.relaunch.warm.first_window_frame_ms"], 8.33))
        self.assertEqual(rw.missing_rows(report["rows"], rw.RELAUNCH_EXPECTED), [])
        self.assertEqual(rw.missing_rows([], rw.RELAUNCH_EXPECTED),
                         ["no launch.relaunch.warm.chat_live_ms", "no launch.relaunch.update.chat_live_ms"],
                         "a chat bench that gave nothing marks the report incomplete")
        self.assertTrue(cron.report_is_incomplete(part, {"rows": [], "incomplete": ["no launch.relaunch.warm.chat_live_ms"]}))

    def test_the_relaunch_part_times_the_chat_seen_from_the_first_frame(self):
        """Leo 2026-11-24, Restart to Update: "the agent pane blanked". The chat's transcript (its saved picture or its
        rows) is on screen in the window's first frame, or the row is over its budget."""
        rw = self.relaunch_wake()
        reconnect = {"rounds": [
            {"mode": "update", "phases": {"first window frame": 900.0}, "seen": {"(c) chat rows": 8.0}},
            {"mode": "update", "phases": {"first window frame": 900.0}, "seen": {"(c) chat rows": 1700.0}},
            {"mode": "warm", "phases": {"first window frame": 450.0}, "seen": {"(c) chat rows": None}}]}
        rows = {r["name"]: r for r in rw.reconnect_rows(reconnect)}
        self.assertEqual(rows["launch.relaunch.update.chat_seen_ms"]["p95"], 1700.0)
        self.assertEqual(rows["launch.relaunch.update.chat_seen_ms"]["budget"], 50)
        self.assertNotIn("launch.relaunch.warm.chat_seen_ms", rows, "no value, no row")
        self.assertTrue(cron.over_target("launch.relaunch.update.chat_seen_ms@h", rows["launch.relaunch.update.chat_seen_ms"], 8.33))

    def test_the_wake_part_owns_its_proxy_rows(self):
        """A measure Mac can't sleep in a step: the wake rows are a freeze proxy and say so in their name."""
        rw = self.relaunch_wake()
        self.assertIn("wake", FLEET)
        self.assertEqual(cron.part_for_row("launch.wake_proxy.terminal_echo_ms@cmux21"), "wake")
        bench = {"sleep_s": 30, "rounds": [
            {"app_answer_ms": 40.0, "terminal_echo_ms": 180.0, "awake_echo_ms": 60.0},
            {"app_answer_ms": 50.0, "terminal_echo_ms": 1300.0, "awake_echo_ms": 70.0},
            {"app_answer_ms": 45.0, "terminal_echo_ms": None, "awake_echo_ms": 65.0}]}
        rows = cron.rows_of_part(cron.PART_BY_NAME["wake"], {"rows": rw.wake_rows(bench)}, budgets_mod, {})
        self.assertEqual(rows["launch.wake_proxy.app_answer_ms"]["p50"], 45.0)
        self.assertEqual(rows["launch.wake_proxy.terminal_echo_ms"]["p95"], 1300.0)
        self.assertEqual(rows["launch.wake_proxy.missed_rounds"]["p95"], 1)
        self.assertEqual(cron.target_of("launch.wake_proxy.terminal_echo_ms@h", rows["launch.wake_proxy.terminal_echo_ms"], 8.33),
                         1000, "plans/cmux-next/transport.md: wake to first byte within 1 s")
        self.assertTrue(cron.over_target("launch.wake_proxy.terminal_echo_ms@h", rows["launch.wake_proxy.terminal_echo_ms"], 8.33))
        self.assertTrue(cron.REPORT_ONLY_ROW_RE.match("launch.wake_proxy.awake_echo_ms"), "the awake floor is shown only")
        self.assertFalse(cron.REPORT_ONLY_ROW_RE.match("launch.wake_proxy.terminal_echo_ms"))
        self.assertEqual(rw.wake_rows({"rounds": []}), [])
        self.assertEqual(rw.missing_rows([], rw.WAKE_EXPECTED), ["no launch.wake_proxy.app_answer_ms"],
                         "an app that never answered marks the report incomplete")
        no_term = {"sleep_s": 30, "rounds": [{"app_answer_ms": 40.0, "terminal_echo_ms": None, "awake_echo_ms": None}]}
        self.assertEqual(rw.missing_rows(rw.wake_rows(no_term), rw.WAKE_EXPECTED), [],
                         "with no terminal echo the app's answer is still a done part")
        self.assertEqual({r["name"]: r["p95"] for r in rw.wake_rows(no_term)}["launch.wake_proxy.missed_rounds"], 1,
                         "and the rounds with no echo count against missed_rounds' budget of 0")

    def test_the_wake_bench_freezes_the_whole_process_tree(self):
        spec2 = importlib.util.spec_from_file_location("wake_proxy", os.path.join(HERE, "..", "wake-proxy-bench.py"))
        wake = importlib.util.module_from_spec(spec2)
        with mock.patch.dict("sys.modules", {"bench_memory": mock.MagicMock()}):
            spec2.loader.exec_module(wake)
        table = [(10, 1, "app"), (11, 10, "helper"), (20, 1, "daemon"), (21, 20, "host"), (22, 21, "zsh"), (30, 1, "other")]
        self.assertEqual(wake.descendants({10, 20}, table), {10, 11, 20, 21, 22}, "the shells under the terminal hosts too")
        # This build's CLI answers `workspace create --json` with nested ids; the old `new-workspace` answered nothing.
        made = {"ok": True, "result": {"workspace_id": "ws_1", "panes": [{"pane_id": "pane_1", "terminal_id": "term_9"}]}}
        self.assertEqual(wake.find_key(made, "terminal_id"), "term_9")
        self.assertEqual(wake.find_key(made, "workspace_id"), "ws_1")
        self.assertIsNone(wake.find_key({}, "terminal_id"))
        term = wake.Terminal(mock.MagicMock(cli_path="/b/cmux", socket="/s.sock"))
        self.assertEqual(term.argv("x")[:3], ["/b/cmux", "--app-socket", "/s.sock"], "the app socket, not the daemon's")
        # The views of its own workspace, else the focused terminal; never another workspace's text.
        panes = [{"kind": "terminal", "workspace": "ws_other", "text": "old"},
                 {"kind": "terminal", "workspace": "ws_1", "text": "wake-3"}, {"kind": "browser", "workspace": "ws_1"}]
        term.app.call.return_value = {"windows": [{"panes": panes}]}
        term.workspace = "ws_1"
        self.assertEqual(term.view_text(), "wake-3")
        term.workspace = "ws_none"
        panes[0]["focused"] = True
        self.assertEqual(term.view_text(), "old")

    def test_the_memory_agents_part_measures_the_optimized_app(self):
        """CMUX-571 ram-baseline compares the app with other apps' release builds and with the 2026-11-08 Release
        baseline (app process 243-285 MB). The part measured the Debug build (app process 323.3 MB at 8c515cc5), so
        the goal read a build difference as growth. It measures the bench configuration, the build throughput uses,
        and the change rebases the stored Debug rows instead of comparing the two builds."""
        args = cron.PART_BY_NAME["memory-agents"]["args"]
        self.assertIn("--config=bench", args, "the memory rows come from the optimized (Release) app, not Debug")
        self.assertIn("--app-cache", args, "it reuses the measurement's bench build (throughput's) when there is one")
        self.assertEqual([a for a in args if a.startswith("--config=")],
                         [a for a in cron.PART_BY_NAME["throughput"]["args"] if a.startswith("--config=")],
                         "one bench build serves both parts")
        name = "memory.app_agents.empty.total_footprint_mb@cmux20-bench"
        debug_cfg = hashlib.sha256(json.dumps([*cron.MEASURE, "--suite=memory-agents", "--agents=10"],
                                              sort_keys=True).encode()).hexdigest()[:12]
        self.assertNotEqual(cron.part_config("memory-agents"), debug_cfg)
        now = {name: {"p95": 930.0, "part_config": cron.part_config("memory-agents")}}
        base = {name: {"p95": 980.6, "part_config": debug_cfg}}
        self.assertEqual(cron.version_changed(now, base), [name], "a Debug reference is rebased, never compared")

    def test_the_update_one_rows_have_their_own_part(self):
        self.assertTrue(cron.is_linux_part("web-ui-scale"))
        self.assertEqual(cron.part_for_row("webui.update_one.home.status.n3000@linux"), "web-ui-scale")
        self.assertEqual(cron.part_for_row("webui.update_one.chat.title.growth@linux"), "web-ui-scale")
        self.assertEqual(cron.part_for_row("webui.chat_open.compact.latest@linux"), "web-ui")
        argv, cwd, _ = cron.linux_bench_runs("/r", "web-ui-scale")["suite"]
        self.assertEqual(argv, ["bun", "bench/web-ui-suite.ts", "--only", "update-one"])
        self.assertEqual(cwd, "/r/webviews")

    def test_the_state_growth_rows_have_their_own_part_god_rows_too(self):
        self.assertTrue(cron.is_linux_part("web-ui-growth"))
        self.assertEqual(cron.part_for_row("webui.state_growth.session_churn.entries_per_op@linux"), "web-ui-growth")
        self.assertEqual(cron.part_for_row("webui.state_growth.god.chat_reopen.heap_bytes_per_op@linux"), "web-ui-growth")
        argv, cwd, _ = cron.linux_bench_runs("/r", "web-ui-growth")["suite"]
        self.assertEqual(argv, ["bun", "bench/web-ui-suite.ts", "--only", "state-growth"])
        self.assertEqual(cwd, "/r/webviews")

    def test_the_infinite_items_rows_have_their_own_linux_part(self):
        self.assertTrue(cron.is_linux_part("infinite-items"))
        self.assertEqual(cron.part_for_row("webui.infinite_items.n1000.memory_vs_empty@linux"), "infinite-items")
        self.assertEqual(cron.part_for_row("webui.infinite_items.n10.mb_per_day@linux"), "infinite-items")
        runs = cron.linux_bench_runs("/r", "infinite-items")
        self.assertEqual(list(runs), ["build", "suite"])  # the build runs first, under its own cap
        self.assertEqual(runs["build"][0], ["bash", "/r/scripts/measure/infinite-items-linux.sh", "build-only"])
        argv, cwd, _ = runs["suite"]
        self.assertEqual(argv[:2], ["bash", "/r/scripts/measure/infinite-items-linux.sh"])
        self.assertIn("pages=0", argv)
        self.assertEqual(cwd, "/r")
        rows = cron.rows_of_part(cron.PART_BY_NAME["infinite-items"], {"rows": [
            {"name": "infinite_items.n1000.memory_vs_empty", "p50": 1.4, "p95": 1.4, "unit": "x", "floor": 0.1}]},
            budgets_mod, {"rows": {}})
        self.assertEqual(rows["webui.infinite_items.n1000.memory_vs_empty"]["p95"], 1.4)

    def test_the_linux_job_cap_covers_every_run_of_the_part(self):
        # 2026-11-17: the fixed 40-minute job cap cancelled infinite-items' build-only run three ticks running, so its
        # job left no result and the part ended yielded_out.
        self.assertEqual(cron.linux_job_minutes("infinite-items"), 70)
        self.assertEqual(cron.linux_job_minutes("chat-disk"), 70)
        self.assertEqual(cron.linux_job_minutes("web-ui"), 60)  # the suite\'s shared builds, then its benches
        # web-ui-god's paired rounds build the pane once, stop starting at GOD_PAIRED_DEADLINE_S, the last may run one
        # round more, and the suite runs after them under its own cap.
        self.assertGreaterEqual(cron.linux_job_minutes("web-ui-god") * 60,
                                cron.GOD_PAIRED_PANE_BUILD_S + cron.GOD_PAIRED_DEADLINE_S
                                + cron.GOD_PAIRED_ROUND_TIMEOUT_S + cron.linux_run_seconds("web-ui-god"))

    def test_the_paired_god_rounds_run_first_and_fit_their_minimum(self):
        # 2026-11-21..25: the suite ran first and the paired rounds' deadline left room for one 600 s round, cut at
        # 600 s, so no run reached GOD_PAIRED_MIN_ROUNDS and god_chat_replay_ratio_max read nothing.
        self.assertEqual(list(cron.linux_bench_runs("/r", "web-ui-god")), ["paired", "suite"])
        self.assertGreaterEqual(cron.GOD_PAIRED_DEADLINE_S,
                                (cron.GOD_PAIRED_MIN_ROUNDS - 1) * cron.GOD_PAIRED_ROUND_TIMEOUT_S * 3 // 4,
                                "MIN rounds of three quarters of the cut each start before the deadline")

    def test_the_paired_rounds_share_one_pane_build(self):
        with tempfile.TemporaryDirectory() as out:
            def built(argv, **kw):
                open(os.path.join(argv[-1], ".shared-build-done"), "w").close()
                return mock.Mock(returncode=0)
            env, line = cron.paired_pane_build("/r", {}, out, run=built)
            self.assertEqual(env, {"CMUX_BENCH_PANE_DIR": out})
            self.assertIn("paired pane build", line)
        env, line = cron.paired_pane_build("/r", {}, "/nonexistent", run=lambda argv, **kw: mock.Mock(returncode=1))
        self.assertEqual(env, {}, "a failed build leaves each round to build its own")
        self.assertIn("each round builds its own", line)

    def test_every_web_ui_bench_times_out_inside_its_part_run_cap(self):
        # chat-100k-flat's suite timeout (1200 s) killed it in long_x20, and the grown run timed out at 1770 s against a
        # 1800 s run cap: web-ui-flat stored no row after 2026-11-17. A suite timeout must leave the bench time to finish
        # and sit under the part's run cap, so the suite (not the cap) records which bench ran long.
        suite = open(os.path.join(cron.ROOT, "webviews/bench/web-ui-suite.ts")).read()
        timeouts = {m.group(1): int(m.group(2).replace("_", "")) for m in cron.re.finditer(
            r'name: "([^"]+)",(?:(?!\bname: ).)*?timeoutMs: ([\d_]+)', suite, cron.re.S)}
        self.assertEqual(timeouts["chat-100k-flat"], 2_400_000)
        self.assertEqual(timeouts["chat-100k-flat-grown"], 3_000_000)
        checked = 0
        for part in cron.PARTS:
            if part.get("where") != "linux" or not part["name"].startswith("web-ui"):
                continue
            for argv, _, _ in cron.linux_bench_runs("/r", part["name"]).values():
                if "--only" not in argv:
                    continue
                for bench in argv[argv.index("--only") + 1].split(","):
                    if bench in timeouts:
                        checked += 1
                        self.assertLess(timeouts[bench] / 1000, cron.linux_run_seconds(part["name"]), (part["name"], bench))
        self.assertGreater(checked, 5)
        # The default suite's timeouts and shared builds sum to SUITE_CAP_MS (web-ui-suite-order.test.ts), which must sit
        # inside the web-ui part's run cap.
        cap = int(cron.re.search(r"export const SUITE_CAP_MS = ([\d_]+);", suite).group(1).replace("_", ""))
        self.assertLess(cap / 1000, cron.linux_run_seconds("web-ui"))
        self.assertEqual(cron.linux_job_minutes("web-ui-flat"), 55)
        self.assertEqual(cron.linux_job_minutes("web-ui-flat-grown"), 65)

    def test_a_run_past_its_cap_is_killed_with_its_children(self):
        # subprocess.run's timeout killed only bash: its cargo went on building, and the suite's own cargo build then
        # waited on that build's lock.
        started = time.monotonic()
        out, _, code = cron.run_capped(["bash", "-c", "sleep 30 & echo \"child $!\"; wait"], ".", dict(os.environ), 1)
        self.assertIsNone(code)
        self.assertLess(time.monotonic() - started, 10)
        child = int(out.split("child ", 1)[1].split()[0])
        for _ in range(50):
            try:
                os.kill(child, 0)
            except ProcessLookupError:
                break
            time.sleep(0.1)
        else:
            self.fail(f"the run's child {child} outlived its cap")
        out, _, code = cron.run_capped(["bash", "-c", "echo '{\"rows\": []}'; exit 3"], ".", dict(os.environ), 10)
        self.assertEqual((code, cron.last_json_object(out)), (3, {"rows": []}))

    def test_the_chat_100k_flat_rows_have_their_own_part(self):
        self.assertTrue(cron.is_linux_part("web-ui-flat"))
        self.assertEqual(cron.part_for_row("webui.sim_ladder.ratio_max@linux"), "web-ui-ladder")
        self.assertEqual(cron.linux_bench_runs("/r", "web-ui-ladder")["suite"][0][-1], "sim-ladder")
        self.assertEqual(cron.part_for_row("webui.sim_fidelity.divergence_max@linux"), "web-ui-fidelity")
        self.assertEqual(cron.linux_bench_runs("/r", "web-ui-fidelity")["suite"][0][-1], "sim-fidelity")
        self.assertEqual(cron.part_for_row("webui.chat_100k_flat.ratio_max@linux"), "web-ui-flat")
        self.assertEqual(cron.part_for_row("webui.chat_100k_flat.long_x20.renderer_mb@linux"), "web-ui-flat")
        self.assertEqual(cron.part_for_row("webui.chat_100k_flat.grown_many.ratio_max@linux"), "web-ui-flat-grown")
        self.assertEqual(cron.part_for_row("webui.chat_100k_flat.grown_many.empty_x20.renderer_mb@linux"), "web-ui-flat-grown")
        argv, _, _ = cron.linux_bench_runs("/r", "web-ui-flat-grown")["suite"]
        self.assertEqual(argv, ["bun", "bench/web-ui-suite.ts", "--only", "chat-100k-flat-grown"])
        argv, cwd, _ = cron.linux_bench_runs("/r", "web-ui-flat")["suite"]
        self.assertEqual(argv, ["bun", "bench/web-ui-suite.ts", "--only", "chat-100k-flat"])
        self.assertEqual(cwd, "/r/webviews")

    def test_the_settled_page_rows_have_their_own_part(self):
        # NOW's settled_page_score_max read unknown while the suite's ownPart bench had no part to run it.
        self.assertTrue(cron.is_linux_part("web-ui-settled"))
        self.assertEqual(cron.part_for_row("webui.settled_page.score_max@linux"), "web-ui-settled")
        argv, cwd, _ = cron.linux_bench_runs("/r", "web-ui-settled")["suite"]
        self.assertEqual(argv, ["bun", "bench/web-ui-suite.ts", "--only", "settled-page"])
        self.assertEqual(cwd, "/r/webviews")
        suite = open(os.path.join(cron.ROOT, "webviews/bench/web-ui-suite.ts"), encoding="utf-8").read()
        self.assertRegex(suite, r'name: "settled-page",\s*file: "settled-page\.bench\.ts"')

    def test_the_power_user_rows_have_their_own_part(self):
        self.assertTrue(cron.is_linux_part("web-ui-power-user"))
        self.assertEqual(cron.part_for_row("webui.power_user.flick.webkit.frame_p95@linux"), "web-ui-power-user")
        argv, cwd, _ = cron.linux_bench_runs("/r", "web-ui-power-user")["suite"]
        self.assertEqual(argv, ["bun", "bench/web-ui-suite.ts", "--only", "power-user-bursts"])
        self.assertEqual(cwd, "/r/webviews")
        suite = open(os.path.join(cron.ROOT, "webviews/bench/web-ui-suite.ts"), encoding="utf-8").read()
        self.assertRegex(suite, r'name: "power-user-bursts",\s*file: "power-user-bursts\.bench\.ts"')

    def test_the_composer_typing_rows_have_their_own_part(self):
        self.assertTrue(cron.is_linux_part("web-ui-typing"))
        self.assertEqual(cron.part_for_row("webui.composer_typing.l1.webkit.rows60.to_paint@linux"), "web-ui-typing")
        self.assertEqual(cron.part_for_row("webui.composer_typing.l3.chromium.rows60.invalid@linux"), "web-ui-typing")
        argv, cwd, _ = cron.linux_bench_runs("/r", "web-ui-typing")["suite"]
        self.assertEqual(argv, ["bun", "bench/web-ui-suite.ts", "--only", "composer-typing"])
        self.assertEqual(cwd, "/r/webviews")
        # The suite names the bench the part asks for (web-ui-suite.ts), as its own part outside the suite's cap.
        suite = open(os.path.join(cron.ROOT, "webviews/bench/web-ui-suite.ts"), encoding="utf-8").read()
        self.assertRegex(suite, r'name: "composer-typing",\s*file: "composer-typing\.bench\.ts"')

    def test_the_chat_fast_scroll_rows_have_their_own_part(self):
        self.assertTrue(cron.is_linux_part("web-ui-scroll"))
        self.assertEqual(cron.part_for_row("webui.chat_fast_scroll.fling_interval.n200@linux"), "web-ui-scroll")
        argv, cwd, _ = cron.linux_bench_runs("/r", "web-ui-scroll")["suite"]
        self.assertEqual(cron.part_for_row("webui.sidebar_chats_fling.n1000.late.fling1500.work@linux"), "web-ui-scroll")
        self.assertEqual(argv, ["bun", "bench/web-ui-suite.ts", "--only", "chat-fast-scroll,sidebar-chats-fling"])
        self.assertEqual(cwd, "/r/webviews")
        suite = open(os.path.join(cron.ROOT, "webviews/bench/web-ui-suite.ts"), encoding="utf-8").read()
        self.assertRegex(suite, r'name: "chat-fast-scroll",\s*file: "chat-fast-scroll\.bench\.ts"')
        self.assertRegex(suite, r'name: "sidebar-chats-fling",\s*file: "sidebar-chats-fling\.bench\.ts"')

    def test_the_chat_disk_rows_have_their_own_linux_part(self):
        self.assertTrue(cron.is_linux_part("chat-disk"))
        self.assertEqual(cron.part_for_row("webui.chat_disk.growth_ratio@linux"), "chat-disk")
        self.assertEqual(cron.part_for_row("webui.chat_disk.long_mb_per_hour@linux"), "chat-disk")
        runs = cron.linux_bench_runs("/r", "chat-disk")
        self.assertEqual(list(runs), ["build", "suite"])  # the build runs first, under its own cap
        self.assertEqual(runs["build"][0], ["bash", "/r/scripts/measure/chat-disk-growth-linux.sh", "build-only"])
        self.assertEqual(runs["suite"][0], ["bash", "/r/scripts/measure/chat-disk-growth-linux.sh"])
        rows = cron.rows_of_part(cron.PART_BY_NAME["chat-disk"], {"rows": [
            {"name": "chat_disk.growth_ratio", "p50": 374.0, "p95": 374.0, "unit": "x", "target": 1.2}]},
            budgets_mod, {"rows": {}})
        self.assertEqual(rows["webui.chat_disk.growth_ratio"]["p95"], 374.0)

    def test_the_cloud_claim_rows_have_their_own_linux_part_judged_against_their_targets_only(self):
        self.assertTrue(cron.is_linux_part("cloud-claim"))
        self.assertEqual(cron.part_for_row("cloud.claim_to_ready@linux"), "cloud-claim")
        self.assertEqual(cron.part_for_row("cloud.claim_to_ready.spare@linux"), "cloud-claim")
        self.assertEqual(cron.linux_bench_runs("/r", "cloud-claim")["suite"][0],
                         ["python3", "/r/scripts/cmux-next/cloud-claim-rows.py"])
        report = {"rows": [
            {"name": "claim_to_ready", "p50": 41000, "p95": 63000, "unit": "ms", "target": 15000, "version": 1},
            {"name": "claim_to_ready.p50", "p50": 41000, "p95": 41000, "unit": "ms", "target": 8000, "version": 1},
            {"name": "claim_to_ready.failed_claims", "p50": 1, "p95": 1, "unit": "claims", "target": 0, "floor": 0.5}]}
        rows = cron.rows_of_part(cron.PART_BY_NAME["cloud-claim"], report, budgets_mod, {"rows": {}})
        self.assertEqual(sorted(rows), ["cloud.claim_to_ready", "cloud.claim_to_ready.failed_claims",
                                        "cloud.claim_to_ready.p50"])
        self.assertEqual((rows["cloud.claim_to_ready"]["p50"], rows["cloud.claim_to_ready"]["p95"]), (41000, 63000))
        # The plan's targets, not the 10 ms latency default, and marked over target.
        self.assertEqual(cron.target_of("cloud.claim_to_ready@linux", rows["cloud.claim_to_ready"], None), 15000)
        self.assertEqual(cron.target_of("cloud.claim_to_ready.p50@linux", rows["cloud.claim_to_ready.p50"], None), 8000)
        self.assertTrue(cron.over_target("cloud.claim_to_ready@linux", rows["cloud.claim_to_ready"], None))
        # Report-only: the deployed Cloud's number, never a regression a cmux bisect would chase.
        keyed = {f"{n}@linux": r for n, r in rows.items()}
        self.assertEqual(cron.find_regressions(keyed, {}, None, None, budgets_mod), [])
        self.assertIn("| cloud.claim_to_ready | 63000 ms | 15000 ms | 420 % |", cron.webui_summary(report, "cloud"))

    def test_the_terminal_scroll_rows_keep_their_names_and_are_judged_against_zero(self):
        self.assertTrue(cron.is_linux_part("terminal-scroll"))
        self.assertEqual(cron.part_for_row("terminal.scroll.local.mirror.jumps@linux"), "terminal-scroll")
        self.assertEqual(cron.part_for_row("terminal.scroll.ssh.bad@linux"), "terminal-scroll")
        self.assertEqual(cron.part_for_row("terminal.throughput.ratio"), "throughput")
        runs = cron.linux_bench_runs("/r", "terminal-scroll")
        self.assertEqual(list(runs), ["build", "suite"])
        self.assertEqual(runs["build"][0], ["bash", "/r/scripts/measure/terminal-scroll-stress-linux.sh", "build-only"])
        self.assertEqual(runs["suite"][0], ["bash", "/r/scripts/measure/terminal-scroll-stress-linux.sh"])
        rows = cron.rows_of_part(cron.PART_BY_NAME["terminal-scroll"], {"rows": [
            {"name": "terminal.scroll.local.mirror.blank_rows", "p50": 0, "p95": 0, "unit": "rows", "target": 0,
             "floor": 0.5},
            {"name": "terminal.scroll.local.daemon.jumps", "p50": 1, "p95": 2, "unit": "rows", "target": 0,
             "floor": 0.5}]}, budgets_mod, {"rows": {}})
        self.assertEqual(sorted(rows), ["terminal.scroll.local.daemon.jumps", "terminal.scroll.local.mirror.blank_rows"])
        self.assertFalse(cron.REPORT_ONLY_ROW_RE.match("terminal.scroll.local.daemon.jumps"))
        name = "terminal.scroll.local.daemon.jumps"
        self.assertEqual(cron.target_of(name, rows[name], None), 0)
        self.assertTrue(cron.over_target(name, rows[name], None))
        clean = "terminal.scroll.local.mirror.blank_rows"
        self.assertFalse(cron.over_target(clean, rows[clean], None))

    def test_the_daemon_restart_rows_have_their_own_linux_part(self):
        self.assertTrue(cron.is_linux_part("daemon-restart"))
        self.assertEqual(cron.part_for_row("webui.daemon_restart.god_home.chat_attach_ms@linux"), "daemon-restart")
        self.assertEqual(cron.part_for_row("webui.daemon_restart.small_home.chat_attach_ms@linux"), "daemon-restart")
        runs = cron.linux_bench_runs("/r", "daemon-restart")
        self.assertEqual(list(runs), ["build", "suite"])  # the build runs first, under its own cap
        self.assertEqual(runs["build"][0], ["bash", "/r/scripts/measure/daemon-restart-linux.sh", "build-only"])
        self.assertEqual(runs["suite"][0], ["bash", "/r/scripts/measure/daemon-restart-linux.sh"])
        rows = cron.rows_of_part(cron.PART_BY_NAME["daemon-restart"], {"rows": [
            {"name": "daemon_restart.god_home.chat_attach_ms", "p50": 212.0, "p95": 212.0, "unit": "ms",
             "floor": 40.0, "version": 1, "runs": 3, "values": [180.0, 212.0, 220.0]}]},
            budgets_mod, {"rows": {}})
        self.assertEqual(rows["webui.daemon_restart.god_home.chat_attach_ms"]["p95"], 212.0)
        self.assertEqual(rows["webui.daemon_restart.god_home.chat_attach_ms"]["floor"], 40.0)
        # Not a god row: no god_ratio twin is made of the god home's reading.
        self.assertFalse(any("god_ratio" in name for name in rows))

    def test_every_linux_part_that_builds_rust_gets_the_pinned_toolchain(self):
        # coord-sim's `build: exit 101` (run 45419179993): the linux job installed Rust only for diff-viewer, so every
        # other part that runs cargo built with the runner's Cargo 1.75, which refuses edition 2024.
        import re
        root = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
        wf = open(os.path.join(root, ".github", "workflows", "cmux-next-perf-budgets.yml")).read()
        cond = re.search(r"- name: Install Rust\n\s+if: \$\{\{ (.+?) \}\}", wf)
        self.assertTrue(cond)
        self.assertEqual(cond.group(1), "!startsWith(matrix.part, 'web-ui')")
        for p in cron.PARTS:
            if p.get("where") != "linux" or not p["name"].startswith("web-ui"):
                continue
            for argv, _cwd, _env in cron.linux_bench_runs(root, p["name"]).values():
                self.assertNotIn("cargo", " ".join(argv), p["name"])

    def test_the_coord_sim_script_names_shape_files_that_exist(self):
        # cmux#47315 renamed shapes/default.json; the script kept the old path and every coord-sim part failed at gen
        # ("No such file or directory") for days. Each repo path it names under the crate must exist.
        import re
        root = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
        text = open(os.path.join(root, "scripts", "measure", "coord-sim-linux.sh")).read()
        named = re.findall(r"\$crate/(shapes/[\w.-]+\.json)", text)
        self.assertTrue(named)
        for rel in named:
            self.assertTrue(os.path.isfile(os.path.join(root, "cmux-tui", "crates", "coord-sim", rel)), rel)

    def test_the_coord_sim_rows_have_their_own_linux_part(self):
        self.assertTrue(cron.is_linux_part("coord-sim"))
        self.assertEqual(cron.part_for_row("webui.coord_sim.delivery_ms@linux"), "coord-sim")
        self.assertEqual(cron.part_for_row("webui.coord_sim.daemon.rss_slope_mb_per_min@linux"), "coord-sim")
        runs = cron.linux_bench_runs("/r", "coord-sim")
        self.assertEqual(list(runs), ["build", "suite"])  # the build runs first, under its own cap
        self.assertEqual(runs["build"][0], ["bash", "/r/scripts/measure/coord-sim-linux.sh", "build-only"])
        self.assertEqual(runs["suite"][0], ["bash", "/r/scripts/measure/coord-sim-linux.sh", "coordinators=3", "rate=10",
                                            "seconds=300", "fanin=50,200", "fanin_window=60"])
        self.assertEqual(cron.part_for_row("webui.coord_sim.fanin.n200.controller_rss_mb_per_session@linux"), "coord-sim")
        # The report's last line, as `coord-sim report RUN_DIR --rows` prints it.
        rows = cron.rows_of_part(cron.PART_BY_NAME["coord-sim"], {"rows": [
            {"name": "coord_sim.delivery_ms", "p50": 4.1, "p95": 18.5, "unit": "ms", "target": 100, "version": 1},
            {"name": "coord_sim.events.lost", "p50": 0, "p95": 0, "unit": "events", "target": 0, "floor": 0.5, "version": 1},
            {"name": "coord_sim.daemon.rss_slope_mb_per_min", "p50": 2.5, "p95": 2.5, "unit": "MB/min", "floor": 1.0,
             "version": 1}]}, budgets_mod, {"rows": {}})
        self.assertEqual(rows["webui.coord_sim.delivery_ms"]["p95"], 18.5)
        self.assertEqual(rows["webui.coord_sim.delivery_ms"]["budget"], 100)
        self.assertEqual(rows["webui.coord_sim.events.lost"]["floor"], 0.5)
        self.assertEqual(rows["webui.coord_sim.daemon.rss_slope_mb_per_min"]["unit"], "MB/min")
        self.assertFalse(cron.REPORT_ONLY_ROW_RE.match("webui.coord_sim.delivery_ms"))

    def test_coord_sim_runs_only_once_its_driver_is_built(self):
        self.assertFalse(cron.coord_sim_ready(False, "pub fn run() {}"))
        self.assertFalse(cron.coord_sim_ready(True, None))
        self.assertFalse(cron.coord_sim_ready(True, 'pub fn run(_a: &[String]) -> Result<(), String> { Err("not built yet".into()) }'))
        self.assertTrue(cron.coord_sim_ready(True, "pub fn run(args: &[String]) -> Result<(), String> { drive(args) }"))

    def test_the_chat_search_rows_have_their_own_linux_part_and_only_the_keystroke_is_judged(self):
        self.assertTrue(cron.is_linux_part("chat-search"))
        self.assertEqual(cron.part_for_row("webui.chat_search.keystroke@linux"), "chat-search")
        runs = cron.linux_bench_runs("/r", "chat-search")
        self.assertEqual(list(runs), ["build", "suite"])  # the release build runs first, under its own cap
        self.assertEqual(runs["build"][0], ["bash", "/r/scripts/measure/chat-search-linux.sh", "build-only"])
        self.assertEqual(runs["suite"][0], ["bash", "/r/scripts/measure/chat-search-linux.sh"])
        rows = cron.rows_of_part(cron.PART_BY_NAME["chat-search"], {"rows": [
            {"name": "chat_search.keystroke", "p50": 23.7, "p95": 75.1, "unit": "ms", "target": 150}]},
            budgets_mod, {"rows": {}})
        self.assertEqual(rows["webui.chat_search.keystroke"]["p95"], 75.1)
        self.assertFalse(cron.REPORT_ONLY_ROW_RE.match("webui.chat_search.keystroke"))
        self.assertTrue(cron.REPORT_ONLY_ROW_RE.match("webui.chat_search.fill"))
        self.assertTrue(cron.REPORT_ONLY_ROW_RE.match("webui.chat_search.scan_keystroke"))

    def test_the_million_event_chat_rows_have_their_own_part(self):
        self.assertTrue(cron.is_linux_part("web-ui-million"))
        self.assertEqual(cron.part_for_row("webui.million_event_chat.long.older_page@linux"), "web-ui-million")
        self.assertEqual(cron.part_for_row("webui.million_event_chat.short.heap_mb@linux"), "web-ui-million")
        argv, cwd, _ = cron.linux_bench_runs("/r", "web-ui-million")["suite"]
        self.assertEqual(argv, ["bun", "bench/web-ui-suite.ts", "--only", "million-event-chat,million-event-chat-short"])
        self.assertEqual(cwd, "/r/webviews")

    def test_the_scroll_up_scale_rows_have_their_own_part(self):
        self.assertTrue(cron.is_linux_part("web-ui-scroll-up"))
        self.assertEqual(cron.part_for_row("webui.transcript_scroll_up_scale.chromium.wheel.100k.older_page_drawn@linux"),
                         "web-ui-scroll-up")
        self.assertEqual(cron.part_for_row("webui.transcript_scroll_up_scale.chromium.wheel.older_page_drawn_scale@linux"),
                         "web-ui-scroll-up")
        self.assertEqual(cron.part_for_row("webui.transcript_scroll_up.chromium.interval@linux"), "web-ui")
        argv, cwd, _ = cron.linux_bench_runs("/r", "web-ui-scroll-up")["suite"]
        self.assertEqual(argv, ["bun", "bench/web-ui-suite.ts", "--only", "transcript-scroll-up-scale"])
        self.assertEqual(cwd, "/r/webviews")

    def test_the_chat_pages_memory_rows_have_their_own_part(self):
        self.assertTrue(cron.is_linux_part("web-ui-memory"))
        self.assertEqual(cron.part_for_row("webui.chat_pages_memory.n10.ratio_vs_empty@linux"), "web-ui-memory")
        argv, cwd, _ = cron.linux_bench_runs("/r", "web-ui-memory")["suite"]
        self.assertEqual(argv, ["bun", "bench/web-ui-suite.ts", "--only", "chat-pages-memory"])
        self.assertEqual(cwd, "/r/webviews")

    def test_the_god_part_runs_both_fixtures_and_owns_the_god_rows(self):
        self.assertTrue(cron.is_linux_part("web-ui-god"))
        argv, cwd, _ = cron.linux_bench_runs("/r", "web-ui-god")["suite"]
        self.assertEqual(argv, ["bun", "bench/web-ui-suite.ts", "--only",
                                "chat-switch,transcript-replay,chat-open-god,chat-switch-god,transcript-replay-god"])
        self.assertEqual(cron.part_for_row("webui.chat_open.god.compact.latest@linux"), "web-ui-god")
        self.assertEqual(cron.part_for_row("webui.god_ratio.chat_open.compact.latest@linux"), "web-ui-god")
        self.assertEqual(cron.part_for_row("webui.chat_switch.god.churn.heap_kb_per_switch@linux"), "web-ui-god")
        self.assertEqual(cron.part_for_row("webui.chat_switch.churn.heap_kb_per_switch@linux"), "web-ui")
        self.assertEqual(cron.part_for_row("webui.chat_open.compact.latest@linux"), "web-ui")

    GOD_REPORT = {"rows": [
        {"name": "chat_switch.unread.latest", "p95": 63, "target": 100},
        {"name": "chat_switch.god.unread.latest", "p95": 160, "target": 100},
        {"name": "chat_open.compact.latest", "p95": 500, "target": 1000},
        {"name": "chat_open.god.compact.latest", "p95": 550, "target": 1000},
        {"name": "transcript_replay.live.cls", "p95": 0.38, "unit": "score", "target": 0.01, "floor": 0.001},
        {"name": "transcript_replay.god.live.cls", "p95": 6.17, "unit": "score", "target": 0.01, "floor": 0.001},
        {"name": "transcript_replay.long.token_slope_ms_per_krow", "p95": 0.9, "target": 0.1},
        {"name": "transcript_replay.god.long.token_slope_ms_per_krow", "p95": 0.08, "target": 0.1},
        {"name": "chat_switch.unread.idle_wakeups", "p95": 5, "unit": "count", "target": 0},
        {"name": "chat_switch.god.unread.idle_wakeups", "p95": 6, "unit": "count", "target": 0},
        {"name": "chat_switch.unread.long_ms", "p95": 0, "floor": 1},
        {"name": "chat_switch.god.unread.long_ms", "p95": 84},
        {"name": "chat_switch.read_ahead.long_ms", "p95": 2},
        {"name": "chat_switch.god.read_ahead.long_ms", "p95": 84},
        {"name": "chat_switch.god.churn.heap_kb_per_switch", "p95": 12, "unit": "KB", "target": 0, "floor": 4},
        {"name": "transcript_replay.long.idle_ms_per_s", "p95": 1.43, "target": 1, "floor": 0.1},
        {"name": "transcript_replay.god.long.idle_ms_per_s", "p95": 2.99, "target": 1, "floor": 0.1},
        {"name": "chat_switch.churn.heap_kb_per_switch", "p95": 0, "unit": "KB", "target": 0, "floor": 4},
    ], "failed": []}

    def test_god_rows_get_a_ratio_to_their_twin_and_the_twins_stay_with_web_ui(self):
        rows = cron.rows_of_part(cron.PART_BY_NAME["web-ui-god"], self.GOD_REPORT, budgets_mod, {"rows": {}})
        self.assertFalse([n for n in rows if ".god." not in n and not n.startswith("webui.god_ratio.")],
                         "the ordinary twins are the web-ui part's rows")
        ratios = {n: r["p95"] for n, r in rows.items() if n.startswith("webui.god_ratio.")}
        self.assertEqual(ratios, {"webui.god_ratio.chat_switch.unread.latest": 2.54,
                                  "webui.god_ratio.chat_open.compact.latest": 1.1,
                                  "webui.god_ratio.transcript_replay.live.cls": 16.237,
                                  "webui.god_ratio.transcript_replay.long.idle_ms_per_s": 2.091},
                         "no ratio for a count, a slope, a per-operation row, or a twin at its floor or under GOD_RATIO_MIN")
        bad, good = rows["webui.god_ratio.chat_switch.unread.latest"], rows["webui.god_ratio.chat_open.compact.latest"]
        self.assertEqual((bad["unit"], bad["budget"], bad["god_p95"], bad["small_p95"]), ("x", 1.2, 160, 63))
        self.assertTrue(cron.over_target("webui.god_ratio.chat_switch.unread.latest", bad, None))
        self.assertFalse(cron.over_target("webui.god_ratio.chat_open.compact.latest", good, None))
        growth = rows["webui.chat_switch.god.churn.heap_kb_per_switch"]
        self.assertTrue(cron.over_target("webui.chat_switch.god.churn.heap_kb_per_switch", growth, None),
                        "any growth per switch is over its target of 0")
        listed = cron.find_regressions(rows, {}, None, None, budgets_mod)
        self.assertIn("webui.god_ratio.chat_switch.unread.latest", {r["name"] for r in listed},
                      "a god row past 1.2x its twin is listed in the issue even before it has a reference")

    def test_the_god_part_keeps_its_runner_calibration_and_per_calibration_rows_without_a_ratio(self):
        # chat-open-god PAIRED=1 (webviews/bench/runnerCalibration.ts): the calibration under the god prefix, and each
        # chat's attach_to_latest over it (unit x). The god part keeps the god ones; a quotient gets no god_ratio.
        report = {"rows": [
            {"name": "chat_open.compact.attach_to_latest", "p95": 30.0},
            {"name": "chat_open.god.compact.attach_to_latest", "p95": 150.0},
            {"name": "chat_open.god.calibration_ms", "p95": 40.0, "version": 1},
            {"name": "chat_open.compact.attach_to_latest_per_calibration", "p95": 0.75, "unit": "x", "version": 1},
            {"name": "chat_open.god.compact.attach_to_latest_per_calibration", "p95": 3.75, "unit": "x", "version": 1},
        ], "failed": []}
        rows = cron.rows_of_part(cron.PART_BY_NAME["web-ui-god"], report, budgets_mod, {"rows": {}})
        self.assertEqual(sorted(rows), ["webui.chat_open.god.calibration_ms",
                                        "webui.chat_open.god.compact.attach_to_latest",
                                        "webui.chat_open.god.compact.attach_to_latest_per_calibration",
                                        "webui.god_ratio.chat_open.compact.attach_to_latest"])
        per = rows["webui.chat_open.god.compact.attach_to_latest_per_calibration"]
        self.assertEqual((per["unit"], per["p95"], per["floor"], per["measure_version"]), ("x", 3.75, 0.375, 1))

    def test_the_god_part_keeps_both_chats_paired_attach_rows_and_judges_only_their_dcl_ratio(self):
        # chat-open-god PAIRED=1: each chat's chat_open_paired.<rail>.attach_to_latest (ms) and attach_per_dcl (x, the
        # rounds' median of attach_to_latest over the load's own DOMContentLoaded), read by cmuxterm-hq's
        # chat_attach_p95_ms. The small chat's paired rows stay with the god part, and no god_ratio duplicates
        # god_ratio.chat_open.compact.attach_to_latest.
        report = {"rows": [
            {"name": "chat_open.compact.attach_to_latest", "p95": 30.0},
            {"name": "chat_open.god.compact.attach_to_latest", "p95": 150.0},
            {"name": "chat_open_paired.compact.attach_to_latest", "p95": 111.7, "version": 3},
            {"name": "chat_open_paired.compact.attach_per_dcl", "p95": 6.35, "unit": "x"},
            {"name": "chat_open_paired.god.compact.attach_to_latest", "p95": 89.1, "version": 3},
            {"name": "chat_open_paired.god.compact.attach_per_dcl", "p95": 5.1, "unit": "x"},
        ], "failed": []}
        rows = cron.rows_of_part(cron.PART_BY_NAME["web-ui-god"], report, budgets_mod, {"rows": {}})
        self.assertEqual(sorted(rows), ["webui.chat_open.god.compact.attach_to_latest",
                                        "webui.chat_open_paired.compact.attach_per_dcl",
                                        "webui.chat_open_paired.compact.attach_to_latest",
                                        "webui.chat_open_paired.god.compact.attach_per_dcl",
                                        "webui.chat_open_paired.god.compact.attach_to_latest",
                                        "webui.god_ratio.chat_open.compact.attach_to_latest"])
        self.assertEqual(cron.part_for_row("webui.chat_open_paired.compact.attach_per_dcl@linux"), "web-ui-god")
        # The same code on a slower runner (goal chat-attach-p95, 2026-11-16: 111.7 then 184.5 ms, the ratio 6.35 then
        # 6.23): the ms rows are shown, never judged, and the ratio is within its rule, so nothing regressed.
        base = {"webui.chat_open_paired.compact.attach_to_latest": {"p95": 111.7, "unit": "ms"},
                "webui.chat_open_paired.compact.attach_per_dcl": {"p95": 6.35, "unit": "x"}}
        slow = {"webui.chat_open_paired.compact.attach_to_latest": {"p95": 184.5, "unit": "ms"},
                "webui.chat_open_paired.compact.attach_per_dcl": {"p95": 6.23, "unit": "x"}}
        self.assertEqual(cron.find_regressions(slow, base, 16.67, 16.67, budgets_mod), [])
        # More work on the same runner moves the ratio: that is the regression.
        worse = {**slow, "webui.chat_open_paired.compact.attach_per_dcl": {"p95": 7.6, "unit": "x"}}
        self.assertEqual([r["name"] for r in cron.find_regressions(worse, base, 16.67, 16.67, budgets_mod)],
                         ["webui.chat_open_paired.compact.attach_per_dcl"])

    @staticmethod
    def paired_round(thought, token=1.0, heap=1.0):
        """One paired round's PERF_ROW objects: the small chat's rows and the god chat's at the given ratios."""
        small = {"thought_ms": 10.0, "token_ms": 8.0, "heap_mb": 40.0}
        ratio = {"thought_ms": thought, "token_ms": token, "heap_mb": heap}
        rows = []
        for kind, v in small.items():
            unit = "MB" if kind == "heap_mb" else "ms"
            rows.append({"name": f"transcript_replay.long.{kind}", "p95": v, "unit": unit, "target": 10})
            rows.append({"name": f"transcript_replay.god.long.{kind}", "p95": round(v * ratio[kind], 4), "unit": unit,
                         "target": 10})
        return rows

    def test_the_god_part_plays_paired_rounds(self):
        argv, cwd, env = cron.linux_bench_runs("/r", "web-ui-god")["paired"]
        self.assertEqual(argv, ["bun", "bench/transcript-replay.bench.ts", "--turns", "600", "--only", "long"])
        self.assertEqual((cwd, env["PAIRED"]), ("/r/webviews", "1"), "god and small played at once (cmux#43874)")

    def test_the_board_ratio_is_the_median_of_the_paired_rounds(self):
        # The one-run ratio says 1.356; five paired rounds say 1.10..1.15 with one noisy round at 1.9.
        report = {"rows": [
            {"name": "transcript_replay.long.thought_ms", "p95": 10.0, "target": 10},
            {"name": "transcript_replay.god.long.thought_ms", "p95": 13.56, "target": 10},
        ], "failed": [], "paired": {"rounds": [{"rows": self.paired_round(t), "seconds": 200, "exit": 0}
                                               for t in (1.10, 1.9, 1.12, 1.15, 1.11)], "stopped": "settled"}}
        rows = cron.rows_of_part(cron.PART_BY_NAME["web-ui-god"], report, budgets_mod, {"rows": {}})
        thought = rows["webui.god_ratio.transcript_replay.long.thought_ms"]
        self.assertEqual(thought["p95"], 1.12, "the median of the rounds' ratios, not the one-run 1.356")
        self.assertEqual((thought["rounds"], thought["paired"], thought["unit"], thought["budget"]), (5, True, "x", 1.2))
        self.assertLessEqual(thought["ci_lo"], 1.12)
        self.assertGreaterEqual(thought["ci_hi"], 1.12)
        self.assertEqual(thought["round_ratios"], [1.1, 1.9, 1.12, 1.15, 1.11])
        self.assertEqual(rows["webui.god_ratio.transcript_replay.long.token_ms"]["p95"], 1.0)
        self.assertEqual(rows["webui.transcript_replay.god.long.thought_ms"]["p95"], 13.56, "the god row itself stays")
        few = {**report, "paired": {"rounds": report["paired"]["rounds"][:4]}}
        rows = cron.rows_of_part(cron.PART_BY_NAME["web-ui-god"], few, budgets_mod, {"rows": {}})
        self.assertEqual(rows["webui.god_ratio.transcript_replay.long.thought_ms"]["p95"], 1.356,
                         "under GOD_PAIRED_MIN_ROUNDS rounds the paired median is not published")

    def test_one_fast_paired_round_keeps_the_paired_median(self):
        # Perf cron run 43797713590 at 83b6f50f: five paired rounds, the fifth on a fast runner (small token 3.588 ms,
        # thought 4.433 ms, under GOD_RATIO_MIN's 5 ms). Cut per round, token and thought had four rounds, no paired
        # median, and the board read the one-run ratio 1.578 in place of the paired 1.384.
        pairs = [((8.274, 5.978), (10.998, 6.427)), ((9.01, 5.843), (7.834, 7.512)), ((8.461, 5.99), (10.653, 7.696)),
                 ((5.411, 5.61), (9.014, 6.459)), ((4.445, 3.588), (4.33, 4.433))]
        rounds = []
        for (god_token, small_token), (god_thought, small_thought) in pairs:
            rows = [{"name": "transcript_replay.long.heap_mb", "p95": 30.0, "unit": "MB", "floor": 4},
                    {"name": "transcript_replay.god.long.heap_mb", "p95": 36.0, "unit": "MB", "floor": 4}]
            for kind, god, small in (("token_ms", god_token, small_token), ("thought_ms", god_thought, small_thought)):
                rows.append({"name": f"transcript_replay.long.{kind}", "p95": small, "floor": 0.5, "target": 10})
                rows.append({"name": f"transcript_replay.god.long.{kind}", "p95": god, "floor": 0.5, "target": 10})
            rounds.append({"rows": rows, "seconds": 190, "exit": 0})
        report = {"rows": [
            {"name": "transcript_replay.long.token_ms", "p95": 5.506, "floor": 0.5, "target": 10},
            {"name": "transcript_replay.god.long.token_ms", "p95": 8.689, "floor": 0.5, "target": 10},
        ], "failed": [], "paired": {"rounds": rounds, "stopped": "settled"}}
        rows = cron.rows_of_part(cron.PART_BY_NAME["web-ui-god"], report, budgets_mod, {"rows": {}})
        token = rows["webui.god_ratio.transcript_replay.long.token_ms"]
        self.assertEqual((token["p95"], token["rounds"], token.get("paired")), (1.384, 5, True),
                         "the paired median over all five rounds, not the one-run 1.578")
        self.assertNotIn("least", token)
        self.assertEqual(rows["webui.god_ratio.transcript_replay.long.thought_ms"]["rounds"], 5)
        self.assertFalse(cron.paired_settled(rounds),
                         "token's interval is wider than 0.1, so the rounds go on, not stop at heap's narrow one")
        tiny = [{"rows": [{"name": "transcript_replay.long.token_ms", "p95": 2.0, "floor": 0.5},
                          {"name": "transcript_replay.god.long.token_ms", "p95": 4.0, "floor": 0.5}]}] * 5
        self.assertEqual(cron.paired_ratio_rows(tiny), {}, "a small chat under 5 ms on the median still gets no ratio")

    def test_paired_rounds_run_until_the_board_interval_is_narrow_or_the_deadline(self):
        now = [0.0]

        def clock():
            return now[0]

        def run_with(ratios, seconds):
            calls = []

            def run(argv, **kw):
                calls.append(kw["env"]["PAIRED"])
                now[0] += seconds
                rows = self.paired_round(ratios[len(calls) - 1])
                return mock.Mock(stdout="noise\n" + "".join(f"PERF_ROW {json.dumps(r)}\n" for r in rows), returncode=0)
            return run, calls

        run, calls = run_with([1.10, 1.12, 1.11, 1.13, 1.12] + [1.12] * 20, 200)
        with contextlib.redirect_stdout(io.StringIO()):
            got = cron.run_paired_rounds(["bun"], "/r", {"PAIRED": "1"}, 0.0, clock=clock, run=run)
        self.assertEqual((len(got["rounds"]), got["stopped"]), (cron.GOD_PAIRED_MIN_ROUNDS, "settled"))
        self.assertEqual(len(got["rounds"][0]["rows"]), 6)
        now[0] = 0.0
        run, calls = run_with([1.0, 1.5, 0.9, 1.6, 1.0, 1.4, 0.8, 1.7, 1.1, 1.3, 0.9, 1.6], 600)
        with contextlib.redirect_stdout(io.StringIO()):
            got = cron.run_paired_rounds(["bun"], "/r", {"PAIRED": "1"}, 0.0, clock=clock, run=run)
        self.assertEqual(got["stopped"], "deadline", "a noisy run stops at the deadline, inside the job's cap")
        self.assertLessEqual(600 * len(got["rounds"]), cron.GOD_PAIRED_DEADLINE_S)
        self.assertGreaterEqual(len(got["rounds"]), cron.GOD_PAIRED_MIN_ROUNDS, "600 s rounds still reach MIN")

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

    def test_the_wakeup_lines_name_what_woke_an_idle_page(self):
        stdout = ("web-ui-suite: chat-switch\n"
                  "  chat-switch|   at rest for 5 s: 0 wakeups (0 timeouts, 0 intervals, 0 frames)\n"
                  "  chat-switch|   left alone for 10 s: 1 wakeups (1 timeouts, 0 intervals); setTimeout at a.ts:3\n"
                  "PERF_ROW {\"name\": \"chat_switch.unread.rest_wakeups\"}\n")
        self.assertEqual(cron.webui_wakeup_lines(stdout), [
            "chat-switch|   at rest for 5 s: 0 wakeups (0 timeouts, 0 intervals, 0 frames)",
            "chat-switch|   left alone for 10 s: 1 wakeups (1 timeouts, 0 intervals); setTimeout at a.ts:3"])
        self.assertEqual(cron.webui_wakeup_lines(None), [])

    def test_the_ladder_lines_carry_each_rung_value(self):
        stdout = ("web-ui-suite: sim-ladder\n"
                  "  sim-ladder| SIM-LADDER chats x50 {\"cpu_ms_per_s\":55} renderers 56\n"
                  "  sim-ladder| SIM-LADDER chats cpu_window_ms_per_s 105 / 126 / 97 | per item 0.53 then -0.58 | ratio -1.1\n"
                  "  sim-ladder| SIM-LADDER-SUMMARY tabs x100 cpu_window 106 cpu 78 pss 1825 heap 300 load_collection 2010 ms\n"
                  "PERF_ROW {\"name\": \"sim_ladder.ratio_max\"}\n")
        self.assertEqual(cron.webui_ladder_lines(stdout), [
            "sim-ladder| SIM-LADDER chats cpu_window_ms_per_s 105 / 126 / 97 | per item 0.53 then -0.58 | ratio -1.1",
            "sim-ladder| SIM-LADDER-SUMMARY tabs x100 cpu_window 106 cpu 78 pss 1825 heap 300 load_collection 2010 ms"])
        self.assertEqual(cron.webui_ladder_lines(None), [])

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


    def test_run_linux_part_keeps_the_paired_rounds_that_ran_before_the_suite(self):
        # web-ui-god plays its paired rounds first, then the suite (cmux#57939); the suite's report must not replace
        # them (perf cron run 45853686955 printed a 6-round paired token 1.163 and stored no paired row).
        script = f"import json; print(json.dumps({self.REPORT!r}))"
        rounds = {"rounds": [{"rows": [], "seconds": 1, "exit": 0}], "stopped": "deadline"}
        runs = {"paired": (["true"], "/", {}), "suite": (["python3", "-c", script], "/", {})}
        with tempfile.TemporaryDirectory() as out, \
                mock.patch.object(cron, "linux_bench_runs", lambda root, part: runs), \
                mock.patch.object(cron, "paired_pane_build", lambda cwd, env, pane: ({}, "paired pane build: 0 s")), \
                mock.patch.object(cron, "run_paired_rounds", lambda *a, **k: rounds), \
                contextlib.redirect_stdout(io.StringIO()):
            cron.cmd_run_linux_part(argparse.Namespace(part="web-ui-god", out=out, runner_class="ubuntu-24.04"))
            report = json.load(open(os.path.join(out, "report.json")))
        self.assertEqual(report["paired"], rounds)
        self.assertEqual(report["rows"], self.REPORT["rows"])

    def test_terminal_scroll_prepares_ghostty_and_zig_from_the_tip(self):
        """A measured commit whose script predates #50961 has an empty ghostty-next and no Zig: the tip prepares both."""
        with tempfile.TemporaryDirectory() as root:
            os.makedirs(os.path.join(root, "scripts"))
            open(os.path.join(root, "scripts", "install-zig-ci.sh"), "w").close()
            calls = []

            def run(argv, cwd, env, timeout):
                calls.append(argv)
                if argv[0] == "bash":
                    with open(env["GITHUB_ENV"], "a") as f:
                        f.write("CMUX_ZIG=/opt/zig/zig\n")
                return "", "", 0
            env, tail = cron.prepare_ghostty(root, {"PATH": ""}, run=run)
            self.assertEqual(calls[0][:4], ["git", "submodule", "update", "--init"])
            self.assertEqual(calls[1], ["bash", os.path.join(root, "scripts", "install-zig-ci.sh")])
            self.assertEqual(env["CMUX_ZIG"], "/opt/zig/zig")
            self.assertEqual(tail, ["ghostty-next checkout: exit 0", "zig install: exit 0"])
            os.makedirs(os.path.join(root, "ghostty-next"))
            open(os.path.join(root, "ghostty-next", "build.zig"), "w").close()
            calls.clear()
            env, tail = cron.prepare_ghostty(root, {"PATH": "", "CMUX_ZIG": "/z"}, run=run)
            self.assertEqual((calls, tail), ([], []), "a checked-out engine and a Zig need nothing")
            env, tail = cron.prepare_ghostty(root, {"PATH": ""}, run=lambda *a: ("", "no network", 1))
            self.assertEqual(tail, ["zig install: exit 1", "no network"])
            self.assertNotIn("CMUX_ZIG", env, "a failed install is recorded and the part still runs")

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

    def test_a_failed_parts_reason_reaches_the_issue(self):
        # 2026-10-23..11-10: every Mac part exited 0 and failed on a refused artifact read; the issue guessed a busy fleet.
        state = cron.empty_state(T0)
        cur = {"sha": "a" * 40, "kind": "tip", "parts_todo": ["switch", "launch"], "parts": {}}
        state["current"] = cur
        entry = cron.record_part(cur, "switch", {"state": "failed", "tail": [
            "perf-cron fetch-result", "artifact not read: <HTTPError 403: 'Forbidden'>", ""]}, "r")
        self.assertEqual(entry["why"], "artifact not read: <HTTPError 403: 'Forbidden'>")
        self.assertNotIn("why", cron.record_part(cur, "launch", {"state": "done", "tail": ["ok"]}, "r"))
        self.assertIn("Failed parts of the measurement in flight: switch: `artifact not read: <HTTPError 403: 'Forbidden'>`",
                      cron.issue_body(state, "o/r", T0))

    def test_an_incomplete_reports_reason_is_short_and_names_the_row(self):
        self.assertEqual(cron.incomplete_why({"incomplete": [
            {"name": "sidebar\\.\\d+\\.workspace_switch\\.click_to_idle", "reason": "manifest row not measured"}]}),
            "sidebar.\\d+.workspace_switch.click_to_idle: manifest row not measured")
        scaling = [{"workspaces": 1, "probe": "instant", "exit": 1, "report": "/Users/x/report.json"},
                   {"workspaces": 1, "probe": "typing", "exit": 2},
                   {"workspaces": 1, "probe": "instant", "command": "new_workspace", "incomplete": "missing_summary"},
                   {"workspaces": 100, "probe": "instant", "exit": 1}]
        self.assertEqual(cron.incomplete_why({"incomplete": scaling}),
                         "workspaces 1 probe instant exit 1; workspaces 1 probe typing exit 2; "
                         "workspaces 1 probe instant command new_workspace incomplete missing_summary; and 1 more")
        self.assertEqual(cron.incomplete_why({"incomplete": ["ui-stability: exit 1"]}), "ui-stability: exit 1")
        self.assertEqual(cron.incomplete_why({}), "")

    def test_the_stale_line_names_the_parts_every_incomplete_measurement_lacked(self):
        state = cron.empty_state(T0)
        tip = {"kind": "tip", "status": "incomplete"}
        state["history"] = [
            {**tip, "status": "good", "failed_parts": []},
            {**tip, "failed_parts": ["sidebar", "web-ui", "launch"]},
            {"kind": "bisect", "status": "good"},
            {**tip, "status": "abandoned"},
            {**tip, "failed_parts": ["sidebar", "web-ui"]}]
        self.assertEqual(len(cron.incomplete_streak(state)), 2)
        body = cron.issue_body(state, "o/r", at(cron.STALE_HOURS + 1))
        self.assertIn("the last 2 tip measurement(s) each ran and ended incomplete, every one without sidebar, web-ui (", body)
        state["history"].append({**tip, "status": "good", "failed_parts": []})
        self.assertIn("no measure host had idle time", cron.issue_body(state, "o/r", at(cron.STALE_HOURS + 1)),
                      "no streak: the cause is not a part")

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

    def test_disk_starved_host_is_unhealthy_so_the_tip_unpins(self):
        """2026-11-16: cmux20-bench idle, 10.9 GB free, nothing evictable: the controller leased it nothing."""
        b = cron.BENCH_WORKER
        full = self.workers(free_bytes=10941784064, disk={"evictable_bytes": 0})
        why = cron.fleet_verdict({"queue": []}, full, [], b, "queued")
        self.assertIn(f"{b} is not healthy", why)
        self.assertTrue(any(f"{b} {r}" in why for r in cron.OFFLINE_REASONS))
        state = {}
        cron.note_host_offline(state, b, why, cron.now_utc())
        self.assertTrue(cron.host_unreachable(state, b, cron.now_utc()))
        roomy = self.workers(free_bytes=110105374720, disk={"evictable_bytes": 0})
        self.assertIsNone(cron.fleet_verdict({"queue": []}, roomy, [], b, "queued"))
        evict = self.workers(free_bytes=10941784064, disk={"evictable_bytes": 30 * 10**9})
        self.assertIsNone(cron.fleet_verdict({"queue": []}, evict, [], b, "queued"))

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
                mock.patch.object(cron, "tree_published", lambda sha, deadline=None: True), \
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
            # A's stress part counts as failed, so A has no part done and is abandoned at its bound (close_at_bound
            # finishes only a measurement with a part done); the plan starts B and deletes A's part files.
            state["current"]["parts"]["stress"]["state"] = "failed"
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
        self.assertEqual((d["part"], d["linux_parts"]), ("", LINUX_FRESH_ORDER))
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
        state["current"]["host"] = "aws-m4pro-9"  # a host that also runs CI jobs: its parts wait for the build
        cron.decide(state, at(1), None, None, lambda sha: ["motion"], "nightly.yml waits")
        self.assertEqual(state["current"]["yield_since"], cron.iso(at(1)))
        d = cron.decide(state, at(cron.ABANDON_HOURS + 6), "b" * 40, None, lambda sha: ["motion"], "nightly.yml waits")
        self.assertEqual(state["current"]["sha"], "a" * 40, "17 h old, but only 1 h of it active")
        # The runner host was given up after HOST_WAIT_HOURS; the wait stays a yield until a part answers.
        self.assertEqual(d["worker"], cron.BENCH_WORKER)
        cron.record_part(state["current"], "build", {"state": "done"}, "r", at(cron.ABANDON_HOURS + 7))
        self.assertAlmostEqual(state["current"]["yield_hours"], cron.ABANDON_HOURS + 6)
        d = cron.decide(state, at(cron.ABANDON_WALL_HOURS + 1), "b" * 40, None, lambda sha: ["motion"], "nightly.yml waits")
        self.assertEqual((d["action"], d["sha"]), ("finish", "a" * 40), "the wall-clock cap still ends it")
        self.assertEqual(state["current"]["parts"]["motion"]["state"], "not_run")


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
        for raw in ("", "{", json.dumps([1]), self.result(part="nope"),
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

    def test_a_step_that_never_started_is_a_yield_not_a_build_failure(self):
        # Tip c2b1760e on 2026-11-26: GitHub refused cmux20-bench's checkout fetch (HTTP 403), and the build part's
        # failure ended every Mac part, tabs among them, as build_failed.
        error = ("step checkout: GitHub refused the fetch (HTTP 403) (exit status 128) "
                 "(source download failed 3 times, before the job started)")
        refused = cron.result_files(json.loads(self.result(part="build", state="failed", error=error)))
        self.assertEqual(refused["state"], "yielded")
        self.assertFalse(refused["build_failed"], "no build ran")
        cur = cron.new_measurement(self.SHA, "tip", ["build", "motion", "diff-viewer"], T0)
        entry = cron.record_part(cur, "build", refused, "r")
        self.assertEqual((entry["state"], entry["yields"]), ("yielded", 1))
        self.assertEqual(cur["parts_todo"], ["build", "motion", "diff-viewer"], "every part still to do")
        for _ in range(cron.MAX_YIELDS - 1):
            entry = cron.record_part(cur, "build", refused, "r")
        self.assertEqual(entry["state"], "yielded_out", "bounded: a fleet that keeps refusing ends it")
        self.assertIn("motion", cur["parts_todo"], "a yielded-out build is no build failure: the next part builds")

    def test_a_reviewed_check_refusal_is_a_yield_not_a_build_failure(self):
        # Tip 60a23ed3 on 2026-11-26: the controller restarted and its reviewed-script check, which runs before the
        # step, could not fetch main; the build part's failure ended motion, switch and tabs as build_failed.
        error = ("ci-step reviewed check: no reviewed tip could be fetched for scripts/measure/split-spring.sh at "
                 "60a23ed343cf (main: not fetched (git: unable to access "
                 "'http://controller.invalid/v1/git/manaflow-ai/c")  # the state's why, cut at 200 characters
        refused = cron.result_files(json.loads(self.result(part="build", state="failed", error=error)))
        self.assertEqual(refused["state"], "yielded")
        self.assertFalse(refused["build_failed"], "the check ran before the step: no build ran")
        cur = cron.new_measurement(self.SHA, "tip", ["build", "motion", "switch", "tabs"], T0)
        cron.record_part(cur, "build", refused, "r")
        self.assertEqual(cur["parts_todo"], ["build", "motion", "switch", "tabs"], "every Mac part still to do")
        # A build that ran and printed the words in its own log is still a build failure: only the controller's
        # error line, at its start, is the check's.
        ran = cron.result_files(json.loads(self.result(part="build", state="failed",
                                                          error="step exited 65: see ci-step reviewed check: notes")))
        self.assertTrue(ran["build_failed"])

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

    def test_an_open_regression_keeps_its_newest_reading(self):
        # The probe and NOW read last_p95 and last_at: a later run's value, not the one the regression was detected at.
        for v in (19.5, 20.0, 21.0):
            self.measured(v)
        self.measured(45.0)
        self.assertEqual(self.measured(46.0), "regressed")
        reg = self.state["regressions"][0]
        self.assertEqual((reg["last_p95"], reg["last_at"]), (46.0, self.state["history"][-1]["at"]))
        self.assertEqual(self.measured(52.0), "still")
        reg = self.state["regressions"][0]
        self.assertEqual((reg["last_p95"], reg["last_at"]), (52.0, self.state["history"][-1]["at"]), "still worse")
        self.assertEqual(self.measured(20.0), "still")
        reg = self.state["regressions"][0]
        self.assertEqual((reg["last_p95"], reg["last_at"]), (20.0, self.state["history"][-1]["at"]), "recovering")

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

    def test_a_result_run_waits_out_the_rate_limit_and_reads_the_state(self):
        # A result run carries the controller's result of a part that ran: doing nothing drops it.
        refused = cron.RateLimited("GET /repos/N/actions/artifacts: HTTP 403")
        refused.wait = 240
        slept = []
        with tempfile.TemporaryDirectory() as d, \
                mock.patch.object(cron, "fetch_state", mock.Mock(side_effect=[refused, True])) as fetch, \
                mock.patch.object(cron.time, "sleep", slept.append):
            cron.cmd_fetch_state(argparse.Namespace(repo="o/r", dir=d, wait_limit=2700))
            self.assertEqual(fetch.call_count, 2, "the state is read again after the wait")
            self.assertFalse(os.path.exists(os.path.join(d, cron.RATE_LIMITED)))
        self.assertEqual(len(slept), 1)
        self.assertGreaterEqual(slept[0], 240)

    def test_a_wait_past_the_limit_or_on_a_plain_tick_still_does_nothing(self):
        for wait, limit in ((3000, 2700), (240, 0), (None, 2700)):
            refused = cron.RateLimited("x")
            refused.wait = wait
            with tempfile.TemporaryDirectory() as d, \
                    mock.patch.object(cron, "fetch_state", mock.Mock(side_effect=[refused, True])) as fetch, \
                    mock.patch.object(cron.time, "sleep", mock.Mock(side_effect=AssertionError("no wait"))):
                cron.cmd_fetch_state(argparse.Namespace(repo="o/r", dir=d, wait_limit=limit))
                self.assertEqual(fetch.call_count, 1)
                self.assertTrue(os.path.exists(os.path.join(d, cron.RATE_LIMITED)))

    def test_a_refusal_says_how_long_until_github_takes_calls_again(self):
        import email.message
        for name, value, want in (("retry-after", "90", 90), ("x-ratelimit-reset", str(int(cron.time.time()) + 600), 600)):
            headers = email.message.Message()
            headers["x-ratelimit-remaining"] = "0"
            headers[name] = value

            def limited(*a, headers=headers, **k):
                raise urllib.error.HTTPError("https://api.github.com/x", 403, "Forbidden", headers, io.BytesIO(b"{}"))
            with mock.patch.dict(os.environ, {"GH_TOKEN": "t"}), mock.patch.object(urllib.request, "urlopen", limited):
                with self.assertRaises(cron.RateLimited) as ctx:
                    cron.gh_request("/repos/o/r")
            self.assertAlmostEqual(ctx.exception.wait, want, delta=5)

    def test_the_workflow_calls_only_subcommands_the_cron_has(self):
        # A lost space ("plan--repo") makes argparse exit 2 and the plan step fail on every tick.
        import re
        root = os.path.join(HERE, "..", "..", "..")
        source = open(os.path.join(HERE, "..", "perf-cron.py")).read()
        known = set(re.findall(r'add_parser\("([a-z-]+)"', source))
        workflow = open(os.path.join(root, ".github", "workflows", "cmux-next-perf-budgets.yml")).read()
        # Interpreter flags may sit between (the plan runs `python3 -I -u -X faulthandler`).
        called = re.findall(r"python3 -I(?: -[A-Za-z](?: \w+)?)* scripts/cmux-next/perf-cron\.py (\S+)", workflow)
        self.assertIn("plan", called)
        self.assertEqual([c for c in called if c not in known], [])

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

    def test_a_commit_the_shallow_checkout_cannot_place_is_asked_of_github(self):
        # The partial clone fetched the commit alone (cat-file finds it), with no path to the tip.
        asked = []
        with mock.patch.object(cron, "gh_request", lambda p, *a, **k: asked.append(p) or {"status": "ahead"}), \
                mock.patch.object(cron.subprocess, "run", lambda *a, **k: mock.Mock(returncode=0)), \
                mock.patch.object(cron, "is_ancestor", lambda a, b: False):
            ok = cron.commit_on_branch("o/r", "f" * 40)
            self.assertTrue(ok("a" * 40), "a bisect step older than the checkout's depth stays in the state")
            self.assertEqual(ok.verified(), ["a" * 40])
        self.assertEqual(len(asked), 1)

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
        # Hosts answered other parts meanwhile (a silent fleet ends the Mac parts as no_host: NoHostTipTests).
        self.state["current"].pop("host_asked_since")
        cron.decide(self.state, at(cron.ABANDON_HOURS + 1), None, None, lambda sha: ["motion"], None, controller_route=True)
        self.assertEqual(self.state["current"]["sha"], "c" * 40, "the wait for the controller is not active time")
        cron.record_part(self.state["current"], "build", {"state": "done", "worker": BENCH}, "r", at(cron.ABANDON_HOURS + 2))
        self.assertNotIn("yield_since", self.state["current"])
        d = cron.decide(self.state, at(cron.ABANDON_WALL_HOURS + 1), None, None, lambda sha: ["motion"], None,
                        controller_route=True)
        self.assertEqual(d["action"], "finish", "the wall-clock cap still ends it, with the build it has")
        self.assertEqual(self.state["current"]["parts"]["motion"]["state"], "not_run")

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


class NoHostTipTests(OneRunRule):
    """2026-11-16 00:59Z: tip 83b6f50f waited on cmux20-bench (reserved, given up twice) for memory-agents and
    throughput, and no newer tip could start before the 48 h cap: the Linux parts that failed on it (web-ui-flat, no
    browser) were never run again, and every row went stale. A tip's Mac parts that no host takes for HOST_WAIT_HOURS
    after a give-up end as no_host; the tip finishes with what ran, and a newer tip starts."""

    PARTS = ["build", "motion", "memory-agents", "web-ui-flat"]
    OLD, NEW = "a" * 40, "b" * 40

    def stuck_tip(self):
        state = cron.empty_state(T0)
        d = cron.decide(state, T0, self.OLD, None, lambda sha: self.PARTS, None, controller_route=True)
        self.assertEqual((d["part"], d["linux_parts"]), ("build", ["web-ui-flat"]))
        cur = state["current"]
        cron.record_part(cur, "web-ui-flat", {"state": "failed", "worker": LINUX,
                                              "tail": ["chat-100k-flat: exit 1"]}, "r", at(0.2))
        cron.record_part(cur, "build", {"state": "done", "worker": BENCH}, "r", at(0.3))
        cur["parts"]["build"]["worker"] = cur["host"] = BENCH
        # The bench host goes silent past the bound: given up once, as on 83b6f50f at 03:18Z.
        cron.decide(state, at(0.5), None, None, lambda sha: [], None, controller_route=True)
        d = cron.decide(state, at(0.6 + cron.HOST_WAIT_HOURS), None, None, lambda sha: [], None, controller_route=True)
        self.assertEqual((d["part"], d["worker"]), ("motion", ""), "a first silence tries any idle host")
        self.assertEqual([g["host"] for g in cur["gave_up"]], [BENCH])
        # It comes back for one part, then is reserved again with memory-agents asked.
        t = at(1 + cron.HOST_WAIT_HOURS)
        cron.record_part(cur, "motion", {"state": "done", "worker": BENCH}, "r", t)
        cur["parts"]["motion"]["worker"] = cur["host"] = BENCH
        d = cron.decide(state, t, "c" * 40, None, lambda sha: [], None, controller_route=True)
        self.assertEqual((d["part"], d["worker"]), ("memory-agents", BENCH))
        return state

    def test_a_stuck_tip_with_a_no_host_part_is_superseded_after_the_bound(self):
        state = self.stuck_tip()
        before = at(0.9 + 2 * cron.HOST_WAIT_HOURS)
        d = cron.decide(state, before, self.NEW, None, lambda sha: self.PARTS, None, controller_route=True)
        self.assertEqual((d["sha"], d["part"]), (self.OLD, "memory-agents"), "within the bound it still waits")
        late = at(1.1 + 2 * cron.HOST_WAIT_HOURS)
        d = cron.decide(state, late, self.NEW, None, lambda sha: self.PARTS, None, controller_route=True)
        self.assertEqual((d["action"], d["sha"]), ("finish", self.OLD), d["reason"])
        cur = state["current"]
        self.assertEqual(cur["parts"]["memory-agents"]["state"], "no_host")
        self.assertIn("no measure host", cur["parts"]["memory-agents"]["reason"])
        self.assertNotIn("yield_since", cur, "the wait ended")
        # The parts that ran are stored as usual; the no_host part's row keeps its last value and ages honestly.
        mem, tab = f"memory.app_agents.idle_mb@{BENCH}", f"cmd_t.e2e@{BENCH}"
        state["last_good"] = {"sha": "9" * 40, "measured_at": cron.iso(T0), "refresh_ms": 8.33,
                              "rows": {mem: {**row(100.0, "MB"), "refresh_ms": 8.33}, tab: {**row(5.0), "refresh_ms": 8.33}}}
        event = cron.finish_measurement(state, {tab: {**row(5.0), "refresh_ms": 8.33}}, 8.33, BENCH, "u", late, budgets_mod)
        self.assertEqual(event, "partial")
        self.assertEqual(state["last_good"]["rows"][mem]["p95"], 100.0, "never faked")
        self.assertIsNone(state.get("last"), "incomplete: the stale clock keeps running")
        self.assertIn("no measure host", state["history"][-1]["failed_why"]["memory-agents"])
        self.assertEqual(state["history"][-1]["failed_parts"], ["memory-agents", "web-ui-flat"])
        # A newer tip starts, and its Linux part (failed on the old tip) runs beside its build.
        d = cron.decide(state, late, self.NEW, None, lambda sha: self.PARTS, None, controller_route=True)
        self.assertEqual((d["action"], d["sha"], d["part"], d["linux_parts"]), ("part", self.NEW, "build", ["web-ui-flat"]))
        self.assertEqual(state["current"]["parts_todo"], ["build", "motion", "memory-agents", "web-ui-flat"])

    def test_an_unpinned_tip_no_host_takes_ends_its_mac_parts(self):
        state = cron.empty_state(T0)
        cron.decide(state, T0, self.OLD, None, lambda sha: ["motion", "diff-viewer"], None, controller_route=True)
        d = cron.decide(state, at(cron.HOST_WAIT_HOURS + 0.1), None, None, lambda sha: [], None, controller_route=True)
        self.assertEqual((d["action"], d["part"], d["linux_parts"]), ("part", "", ["diff-viewer"]))
        self.assertEqual(state["current"]["parts"]["build"]["state"], "no_host")
        self.assertNotIn("motion", state["current"]["parts_todo"])

    def test_a_pinned_tip_gives_its_host_up_before_no_host(self):
        state = cron.empty_state(T0)
        state["current"] = cron.new_measurement(self.OLD, "tip", ["build", "motion"], T0)
        state["current"]["host"] = X
        cron.decide(state, T0, None, None, lambda sha: [], None)
        d = cron.decide(state, at(cron.HOST_WAIT_HOURS + 0.1), None, None, lambda sha: [], None)
        self.assertEqual((d["action"], d["part"], d["worker"]), ("part", "build", ""))

    def test_a_bisect_step_is_never_no_host(self):
        state = cron.empty_state(T0)
        rng = {"good": "9" * 40, "bad": "8" * 40}
        state["current"] = cron.new_measurement(self.OLD, "bisect", ["build", "motion"], T0, rng)
        cron.decide(state, T0, None, None, lambda sha: [], None)
        cron.decide(state, at(cron.HOST_WAIT_HOURS + 0.1), None, None, lambda sha: [], None)
        self.assertNotIn("build", state["current"]["parts"])

    def test_a_tip_with_no_cmux_tui_tree_runs_its_linux_parts_and_its_mac_parts_wait_for_the_tree(self):
        """2026-11-17 07:13Z: no commit since the last tip had a published tree, so no tip started, and the web-ui
        rows (Linux, no tree needed) of cmux#44534 waited hours. Only the Mac parts wait for the tree."""
        state = cron.empty_state(T0)
        no_tree = lambda sha: False  # noqa: E731
        d = cron.decide(state, T0, self.NEW, None, lambda sha: ["motion", "web-ui"], None, tree_ready=no_tree)
        self.assertEqual((d["action"], d["sha"], d["part"], d["linux_parts"]), ("part", self.NEW, "", ["web-ui"]))
        self.assertIn("cmux-tui tree", d["reason"])
        cur = state["current"]
        self.assertEqual(cur["parts_todo"], ["build", "motion", "web-ui"])
        self.assertNotIn("host_asked_since", cur, "a missing tree is no host's silence")
        cur["parts_todo"].remove("web-ui")
        cur["parts"]["web-ui"] = {"state": "done"}
        d = cron.decide(state, at(1), None, None, lambda sha: [], None, tree_ready=no_tree)
        self.assertEqual(d["action"], "none")
        self.assertIn("cmux-tui tree", d["reason"])
        d = cron.decide(state, at(1.5), None, None, lambda sha: [], None, tree_ready=lambda sha: True)
        self.assertEqual((d["action"], d["part"]), ("part", "build"), "the tree came: the Mac parts run")
        self.assertNotIn("tree_wait_since", state["current"])

    def test_a_tip_whose_tree_never_comes_finishes_with_its_linux_rows(self):
        state = cron.empty_state(T0)
        no_tree = lambda sha: False  # noqa: E731
        cron.decide(state, T0, self.NEW, None, lambda sha: ["motion", "web-ui"], None, tree_ready=no_tree)
        cur = state["current"]
        cur["parts_todo"].remove("web-ui")
        cur["parts"]["web-ui"] = {"state": "done"}
        d = cron.decide(state, at(cron.TREE_WAIT_HOURS - 0.1), None, None, lambda sha: [], None, tree_ready=no_tree)
        self.assertEqual(d["action"], "none", "within the bound it waits")
        d = cron.decide(state, at(cron.TREE_WAIT_HOURS + 0.1), None, None, lambda sha: [], None, tree_ready=no_tree)
        self.assertEqual((d["action"], d["sha"]), ("finish", self.NEW), d["reason"])
        self.assertEqual({n: p["state"] for n, p in cur["parts"].items()},
                         {"web-ui": "done", "build": "no_tree", "motion": "no_tree"})
        self.assertIn("no published cmux-tui tree", cur["parts"]["motion"]["reason"])

    def test_a_tip_whose_tree_never_comes_gives_its_linux_parts_a_bound(self):
        """2026-11-23: tip 2322b92a's Mac parts ended no_tree at 19:14Z, and its 16 Linux parts still to do held the
        next tip (tree published, tabs never read) back past 22:30Z."""
        state = cron.empty_state(T0)
        no_tree = lambda sha: False  # noqa: E731
        cron.decide(state, T0, self.NEW, None, lambda sha: ["motion", "web-ui", "coord-sim"], None, tree_ready=no_tree)
        cur = state["current"]
        t = cron.TREE_WAIT_HOURS + 0.1
        d = cron.decide(state, at(t), None, None, lambda sha: [], None, tree_ready=no_tree)
        self.assertEqual(d["action"], "part", "the Linux parts may still run")
        self.assertEqual(sorted(d["linux_parts"]), ["coord-sim", "web-ui"])
        d = cron.decide(state, at(t + cron.SUPERSEDED_LINUX_HOURS / 2), None, None, lambda sha: [], None,
                        tree_ready=no_tree)
        self.assertNotEqual(d["action"], "finish", "inside its bound it keeps the Linux parts")
        d = cron.decide(state, at(t + cron.SUPERSEDED_LINUX_HOURS + 0.1), None, None, lambda sha: [], None,
                        tree_ready=no_tree)
        self.assertEqual((d["action"], d["sha"]), ("finish", self.NEW), d["reason"])
        self.assertEqual(cur["parts"]["motion"]["state"], "no_tree")
        self.assertEqual(cur["parts"]["coord-sim"]["state"], "superseded")

    def test_a_no_tree_tip_from_before_the_bound_ends_its_linux_parts_at_once(self):
        state = cron.empty_state(T0)
        no_tree = lambda sha: False  # noqa: E731
        cron.decide(state, T0, self.NEW, None, lambda sha: ["motion", "web-ui"], None, tree_ready=no_tree)
        cur = state["current"]
        for name in [n for n in cur["parts_todo"] if not cron.is_linux_part(n)]:
            cur["parts"][name] = {"state": "no_tree", "reason": "no published cmux-tui tree of x for 2 h"}
            cur["parts_todo"].remove(name)
        d = cron.decide(state, at(9), None, None, lambda sha: [], None, tree_ready=no_tree)
        self.assertEqual((d["action"], d["sha"]), ("finish", self.NEW), d["reason"])

    def test_a_bisect_step_never_waits_for_a_tree(self):
        state = cron.empty_state(T0)
        state["current"] = cron.new_measurement(self.OLD, "bisect", ["build", "motion"], T0, {"good": "9" * 40, "bad": "8" * 40})
        d = cron.decide(state, T0, None, None, lambda sha: [], None, tree_ready=lambda sha: False)
        self.assertEqual(d["part"], "build", "its commit was picked for a published tree (bisect_measurable)")

    def test_the_plan_picks_the_newest_commit_when_none_since_the_last_tip_has_a_tree(self):
        commits = ["c" * 40, "d" * 40, "e" * 40]

        def git(*args, check=True):
            return "\n".join(commits) if args[0] == "rev-list" else commits[0]
        with tempfile.TemporaryDirectory() as d:
            out = os.path.join(d, "plan.out")
            with mock.patch.object(cron, "now_utc", lambda: at(1)), mock.patch.object(cron, "git", git), \
                    mock.patch.object(cron, "measure_version", lambda sha: 3), \
                    mock.patch.object(cron, "commit_on_branch", lambda repo, t, known=(): cron.is_sha), \
                    mock.patch.object(cron, "tree_published", lambda sha, deadline=None: False), \
                    mock.patch.object(cron, "github_busy", lambda *a: None), \
                    mock.patch.object(cron, "frame_pacing_runs", lambda repo: []), \
                    mock.patch.object(cron, "is_ancestor", lambda a, b: False), \
                    mock.patch.object(cron, "supported_parts_at", lambda sha: ["motion", "web-ui"]), \
                    mock.patch.object(cron, "gh_request", lambda *a, **k: {}), \
                    contextlib.redirect_stdout(io.StringIO()):
                cron.cmd_plan(argparse.Namespace(repo="o/r", dir=d, tip="HEAD", yield_mode="queued", no_mac=False,
                                                 output=out))
            plan = dict(line.split("=", 1) for line in open(out).read().splitlines())
            state = json.load(open(os.path.join(d, "state.json")))
        self.assertEqual((plan["action"], plan["sha"], plan["part"], json.loads(plan["linux_matrix"])),
                         ("part", commits[0], "", [{"part": "web-ui", "minutes": cron.linux_job_minutes("web-ui")}]),
                         plan["reason"])
        self.assertEqual(state["current"]["kind"], "tip")

    def test_a_linux_part_that_failed_for_its_setup_runs_once_more(self):
        cur = cron.new_measurement(self.NEW, "tip", ["web-ui-flat", "web-ui-flat-grown"], T0)
        no_browser = {"state": "failed", "worker": LINUX, "tail": [
            "browserType.launchServer: Executable doesn't exist at /home/runner/.cache/ms-playwright/chromium_headless_"
            "shell-1200/chrome-headless-shell", "chat-100k-flat: exit 1"]}
        cron.record_part(cur, "web-ui-flat", no_browser, "r")
        self.assertIn("web-ui-flat", cur["parts_todo"], "retried once")
        self.assertIn("Executable doesn't exist", cur["parts"]["web-ui-flat"]["setup_retried"])
        cron.record_part(cur, "web-ui-flat", no_browser, "r")
        self.assertNotIn("web-ui-flat", cur["parts_todo"], "a second setup failure ends it")
        self.assertEqual(cur["parts"]["web-ui-flat"]["state"], "failed")
        cron.record_part(cur, "web-ui-flat-grown", {"state": "failed", "worker": LINUX, "tail": ["bench: exit 1"]}, "r")
        self.assertEqual(cur["parts_todo"], [], "a failure of the bench itself is not retried")

    def test_a_sim_chrome_devtools_setup_failure_runs_once_more(self):
        cur = cron.new_measurement(self.NEW, "tip", ["web-ui-ladder", "web-ui-fidelity"], T0)
        no_devtools = {"state": "failed", "worker": LINUX, "tail": [
            "sim-ladder: Chrome printed no DevTools endpoint: unprivileged user namespaces with AppArmor"
        ]}
        cron.record_part(cur, "web-ui-ladder", no_devtools, "r")
        self.assertIn("web-ui-ladder", cur["parts_todo"], "a Chrome setup failure is retried once")
        self.assertIn("Chrome printed no DevTools endpoint", cur["parts"]["web-ui-ladder"]["setup_retried"])
        cron.record_part(cur, "web-ui-ladder", no_devtools, "r")
        self.assertNotIn("web-ui-ladder", cur["parts_todo"], "a second Chrome setup failure ends it")


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

    def test_a_tip_pins_only_to_a_host_the_controller_calls_idle(self):
        """cmuxterm-hq#19352: every Mac row was @cmux20-bench, so every tip pinned to it while it was leased."""
        state = cron.empty_state(T0)
        state["pending"] = {"x.e2e@cmux20-bench": {"at": cron.iso(T0)}}
        self.assertEqual(cron.tip_pin_host(state, at(1)), "cmux20-bench", "feed not read: pinned as before")
        self.assertIsNone(cron.tip_pin_host(state, at(1), {"cmux21"}), "busy: any idle measure host")
        self.assertIsNone(cron.tip_pin_host(state, at(1), set()), "no host idle: not pinned either")
        self.assertEqual(cron.tip_pin_host(state, at(1), {"cmux20-bench"}), "cmux20-bench")
        self.assertEqual(cron.idle_hosts_from({"hosts": {"cmux20-bench": {"idle": False, "why": "leased"},
                                                         "cmux21": {"idle": True, "why": ""}, "bad": "x"}}), {"cmux21"})
        self.assertIsNone(cron.idle_hosts_from({"error": "not found"}))
        self.assertIsNone(cron.idle_hosts_from([]))
        with mock.patch.object(cron, "http_json", side_effect=urllib.error.URLError("404")):
            self.assertIsNone(cron.controller_idle_hosts(), "no route yet: nothing changes")

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


class StaleTipFirstTests(unittest.TestCase):
    """2026-11-21 (run 44846739082): the rows were 136.8 h old, a tip measurement that waited for the fleet was just
    abandoned, and that abandon made the next tick start a bisect step. Only a tip stores rows, so while the rows are
    stale (no complete tip within STALE_HOURS) the tip goes before any bisect step."""

    def state(self, measured_h, tried_h):
        state = cron.empty_state(T0)
        state["last"] = {"sha": "e" * 40, "measured_at": cron.iso(at(measured_h))}
        state["last_tried"] = {"sha": "f" * 40, "at": cron.iso(at(tried_h))}
        return state

    def test_a_tip_tried_lately_still_waits_while_the_rows_are_fresh(self):
        self.assertFalse(cron.tip_due(self.state(measured_h=20, tried_h=29), at(30)))

    def test_stale_rows_make_the_tip_due_even_right_after_a_tip_was_tried(self):
        self.assertTrue(cron.tip_due(self.state(measured_h=0, tried_h=29), at(30)))

    def test_an_abandoned_tip_in_the_history_does_not_hold_a_stale_tip_back(self):
        state = self.state(measured_h=0, tried_h=0)
        state["history"] = [{"sha": "d" * 40, "kind": "tip", "status": "abandoned", "at": cron.iso(at(29.9))}]
        self.assertTrue(cron.tip_due(state, at(30)))

    def test_decide_starts_the_tip_not_the_bisect_when_the_rows_are_stale(self):
        tip, step = "a" * 40, "b" * 40
        for measured_h, kind, sha in ((20, "bisect", step), (0, "tip", tip)):
            state = self.state(measured_h=measured_h, tried_h=29)
            bisect = {"sha": step, "range": {"good": "c" * 40, "bad": "d" * 40}, "rows": ["tab_switch.e2e@cmux21"]}
            cron.decide(state, at(30), tip, bisect, lambda sha: [p["name"] for p in cron.PARTS], None)
            self.assertEqual((state["current"]["kind"], state["current"]["sha"]), (kind, sha), measured_h)


class BisectBudgetTests(unittest.TestCase):
    """2026-11-19: the bisect judged every commit of 16 ranges of 300 to 1,900 commits, none measurable, each tick,
    and the plan job hit its 75 min timeout every tick."""

    def tick(self, d, commits, judged, lookup_seconds=0):
        tip = "f" * 40
        clock = [1000.0]

        def git(*args, check=True):
            return tip if args[0] in ("rev-parse", "rev-list") else ""

        def tree_published(sha, deadline=None):
            judged.append(sha)
            clock[0] += lookup_seconds
            return False
        out = os.path.join(d, "plan.out")
        with mock.patch.object(cron, "now_utc", lambda: at(1)), mock.patch.object(cron, "git", git), \
                mock.patch.object(cron, "measure_version", lambda sha: 2), \
                mock.patch.object(cron, "commit_on_branch", lambda repo, t, known=(): cron.is_sha), \
                mock.patch.object(cron, "tree_published", tree_published), \
                mock.patch.object(cron, "range_commits", lambda g, b: commits[(g, b)]), \
                mock.patch.object(cron, "tip_due", lambda state, t: False), \
                mock.patch.object(cron, "github_busy", lambda *a: None), \
                mock.patch.object(cron, "frame_pacing_runs", lambda repo: []), \
                mock.patch.object(cron, "is_ancestor", lambda a, b: False), \
                mock.patch.object(cron, "supported_parts_at", lambda sha: ["motion"]), \
                mock.patch.object(cron.time, "monotonic", lambda: clock[0]), \
                contextlib.redirect_stdout(io.StringIO()) as said:
            cron.cmd_plan(argparse.Namespace(repo="o/r", dir=d, tip="HEAD", yield_mode="queued", no_mac=False,
                                             output=out))
        with open(out) as f:
            return dict(line.split("=", 1) for line in f.read().splitlines()), said.getvalue()

    def test_a_tick_judges_at_most_its_budget_and_the_next_goes_on_where_it_stopped(self):
        ranges = [(f"{n:x}" * 40, f"{n + 1:x}" * 40) for n in (1, 3)]
        commits = {rng: [f"{n:02x}{i:038x}" for i in range(500)] for n, rng in enumerate(ranges)}
        with tempfile.TemporaryDirectory() as d:
            state = cron.empty_state(T0)
            state["persisted"] = True
            state["last_tried"] = {"sha": "f" * 40, "at": cron.iso(at(0))}
            state["regressions"] = [{"name": f"cmd_d.e2e@cmux2{n}", "p95": 30.0, "base": 20.0, "confirmed": True,
                                     "range": {"good": g, "bad": b, "skip": [], "steps": 0}}
                                    for n, (g, b) in enumerate(ranges)]
            with open(os.path.join(d, "state.json"), "w") as f:
                json.dump(state, f)
            first, second = [], []
            plan, said = self.tick(d, commits, first)
            self.assertEqual(plan["action"], "none", plan.get("reason"))
            self.assertEqual(len(first), cron.BISECT_JUDGED_PER_TICK, "two ranges of 500 commits, none measurable")
            self.assertIn("the rest wait for the next tick", said)
            self.tick(d, commits, second)
            self.assertEqual(len(second), cron.BISECT_JUDGED_PER_TICK)
            self.assertFalse(set(first) & set(second), "the next tick judges the commits after the first's")
            with open(os.path.join(d, "state.json")) as f:
                looked = json.load(f)["regressions"][0]["range"]["looked"]
            self.assertEqual(looked["place"], 2 * cron.BISECT_JUDGED_PER_TICK)


    def test_slow_tree_lookups_stop_at_the_plan_s_budget_and_the_plan_still_answers(self):
        """Run 45536170489 (2026-11-25): tree lookups slow enough that the plan step's `timeout 600` killed the plan,
        so no tick planned. They share TREE_LOOKUP_SECONDS; past it a commit reads as unpublished and the plan goes on."""
        ranges = [("1" * 40, "2" * 40)]
        commits = {ranges[0]: [f"{i:040x}" for i in range(500)]}
        with tempfile.TemporaryDirectory() as d:
            state = cron.empty_state(T0)
            state["persisted"] = True
            state["last_tried"] = {"sha": "f" * 40, "at": cron.iso(at(0))}
            state["regressions"] = [{"name": "cmd_d.e2e@cmux20", "p95": 30.0, "base": 20.0, "confirmed": True,
                                     "range": {"good": ranges[0][0], "bad": ranges[0][1], "skip": [], "steps": 0}}]
            with open(os.path.join(d, "state.json"), "w") as f:
                json.dump(state, f)
            judged = []
            plan, said = self.tick(d, commits, judged, lookup_seconds=200)
            self.assertEqual(plan["action"], "none", plan.get("reason"))
            self.assertEqual(len(judged), -(-cron.TREE_LOOKUP_SECONDS // 200), "lookups stop once the budget is spent")
            self.assertIn(f"tree lookups used this plan's {cron.TREE_LOOKUP_SECONDS} s", said)
            self.assertIn("took 200 s", said)


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
        self.assertEqual(base["diff.stream.p95"]["measure_version"], 1 + 100 * cron.DIFF_LOAD_VERSION)
        self.assertEqual(cron.version_changed(rows(1), base), [])
        self.assertEqual(cron.version_changed(rows(2), base), ["diff.stream.p95"])

    def test_a_change_of_load_normalization_rebases_every_diff_row(self):
        """#39353 F1: a sidecar reference scaled by #39309 (22.3 ms/GiB at factor 4) is not compared with a raw 74."""
        part = cron.PART_BY_NAME["diff-viewer"]
        report = {"sidecar": {"manifestDecodeP95Micros": 3, "sequentialReadMibPerSecond": 1024 * 1000 / 74.03},
                  "stream": {"p95Ms": 19.0}, "bench_versions": {"sidecar": 1, "stream": 1}}
        now = cron.rows_of_part(part, report, budgets_mod, {"rows": {}, "_animations": {}})
        scaled = {n: {**r, "measure_version": 101} for n, r in now.items()}
        scaled["diff.sidecar.read_ms_per_gib"]["p95"] = 22.305
        legacy = {n: {k: v for k, v in r.items() if k != "measure_version"} for n, r in now.items()}
        every = sorted(now)
        self.assertEqual(cron.version_changed(now, scaled), every)
        self.assertEqual(cron.version_changed(now, legacy), every, "a reference stored before versions is unscaled v1")


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
                mock.patch.object(cron, "tree_published", lambda sha, deadline=None: True), \
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


class PartRowsStoredAtOnceTests(unittest.TestCase):
    """Each finished tip part's rows are stored when the part finishes (state['part_rows'], tagged with the tip's SHA),
    not only when the whole measurement ends: a failed part leaves the other parts' rows, a measurement still running
    shows its finished parts, and staleness counts per part. The measurement's own finish and comparison are unchanged
    (test_a_dropped_measurement_leaves_no_rows_to_the_next, ReferenceTests)."""

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

    def state_with(self, parts_todo):
        state = cron.empty_state(T0)
        state["persisted"] = True
        state["last"] = state["last_good"] = {"sha": "0" * 40, "measured_at": cron.iso(T0), "rows": {}, "refresh_ms": 8.33}
        state["current"] = cron.new_measurement("a" * 40, "tip", parts_todo, T0)
        return state

    def test_a_failed_part_leaves_the_finished_parts_rows(self):
        with tempfile.TemporaryDirectory() as d:
            state = self.state_with(["stress", "motion"])
            results = [self.part_dir(d, "stress", {"state": "done", "worker": cron.BENCH_WORKER}, self.STRESS),
                       self.part_dir(d, "motion", {"state": "failed"})]
            state = self.report(d, state, results)
            rows = state.get("part_rows") or {}
            self.assertTrue(rows, "the finished part's rows are stored although another part failed")
            for name, value in rows.items():
                self.assertTrue(name.endswith("@" + cron.BENCH_WORKER), name)
                self.assertEqual(value["sha"], "a" * 40, "tagged with the tip SHA")
                self.assertEqual(value["part"], "stress")
            self.assertEqual(state["part_stored"]["stress"]["sha"], "a" * 40)
            self.assertNotIn("motion", state["part_stored"])

    def test_an_incomplete_part_keeps_its_finished_benches_rows(self):
        # web-ui-god on 2026-11-24: transcript-replay-god timed out, the other benches measured (rest wakeups 0).
        report = {"rows": [{"name": "chat_switch.god.read_ahead.rest_wakeups", "p50": 0, "p95": 0, "unit": "count",
                            "target": 0, "floor": 0.5}],
                  "failed": ["transcript-replay-god: timed out after 420 s"],
                  "incomplete": [{"bench": "transcript-replay-god", "why": "timed out after 420 s"}]}
        with tempfile.TemporaryDirectory() as d:
            state = self.state_with(["web-ui-god", "motion"])
            state = self.report(d, state, [self.part_dir(d, "web-ui-god",
                                                         {"state": "done", "worker": cron.LINUX_FLEET_CLASS}, report)])
            rows = state.get("part_rows") or {}
            name = "webui.chat_switch.god.read_ahead.rest_wakeups@" + cron.LINUX_FLEET_CLASS
            self.assertIn(name, rows, "a finished bench's row is stored although another bench of the part timed out")
            self.assertEqual((rows[name]["p95"], rows[name]["sha"]), (0, "a" * 40))
            stored = state["part_stored"]["web-ui-god"]
            self.assertIn("transcript-replay-god", stored["incomplete"], "the store says which bench was missing")
            self.assertFalse(state.get("row_history"), "an incomplete part is still judged only at the finish")

    def test_a_measurement_still_running_shows_its_finished_parts(self):
        with tempfile.TemporaryDirectory() as d:
            state = self.state_with(["stress", "motion"])
            state = self.report(d, state, [self.part_dir(d, "stress", {"state": "done", "worker": cron.BENCH_WORKER},
                                                         self.STRESS)])
            self.assertIsNotNone(state["current"], "the measurement is still in flight")
            self.assertTrue(state.get("part_rows"))
            self.assertFalse(state.get("row_history"), "the baseline and comparison are untouched until the finish")

    def test_staleness_counts_per_part(self):
        with tempfile.TemporaryDirectory() as d:
            state = self.state_with(["stress", "motion"])
            state = self.report(d, state, [self.part_dir(d, "stress", {"state": "done", "worker": cron.BENCH_WORKER},
                                                         self.STRESS)])
            self.assertEqual(cron.stale_parts(state, at(2)), [])
            self.assertEqual(cron.stale_parts(state, at(2 + cron.STALE_HOURS)), ["stress"])


class LinuxMatrixTests(unittest.TestCase):
    """2026-11-18: a measurement's ten Linux parts ran one per tick, and each tick waited for a Linux runner (plan, the
    part, the report: 0.5 to 8 h each), so 7c697af8's first five Linux parts took 14 h. Every Linux part still to do
    now runs in one tick, one runner each."""

    def test_one_tick_asks_for_every_linux_part_and_the_next_asks_for_none(self):
        state = cron.empty_state(T0)
        d = cron.decide(state, T0, "a" * 40, None, lambda sha: ALL, None, controller_route=True)
        self.assertEqual((d["part"], d["linux_parts"]), ("build", LINUX_FRESH_ORDER))
        cur = state["current"]
        for name in LINUX_PARTS:
            cron.record_part(cur, name, {"state": "done", "worker": LINUX}, "r", at(1))
        cron.record_part(cur, "build", {"state": "done", "worker": BENCH}, "r", at(1))
        d = cron.decide(state, at(1), None, None, lambda sha: ALL, None, controller_route=True)
        self.assertEqual(d["linux_parts"], [])
        self.assertNotEqual(d["part"], "")

    def test_a_linux_part_that_failed_for_its_setup_is_asked_for_again_with_the_others(self):
        state = cron.empty_state(T0)
        cron.decide(state, T0, "a" * 40, None, lambda sha: ["web-ui", "web-ui-flat"], None)
        cur = state["current"]
        cron.record_part(cur, "web-ui", {"state": "done", "worker": LINUX}, "r", at(1))
        cron.record_part(cur, "web-ui-flat", {"state": "failed", "worker": LINUX,
                                              "tail": ["browserType.launchServer: Executable doesn't exist"]}, "r", at(1))
        d = cron.decide(state, at(1), None, None, lambda sha: [], None)
        self.assertEqual(d["linux_parts"], ["web-ui-flat"])

    def test_each_linux_job_outlives_its_benches(self):
        """infinite-items runs a release build and a suite, each capped at 30 minutes: the flat 40-minute job killed
        it, which left no result (2026-11-17: infinite-items yielded_out)."""
        for name in LINUX_PARTS:
            runs = cron.linux_bench_runs("", name)
            minutes = cron.linux_job_minutes(name)
            plain = sum(cron.linux_run_seconds(name) for n in runs if n != "paired") / 60
            self.assertGreaterEqual(minutes, cron.LINUX_SETUP_MINUTES + plain, name)
            if "paired" in runs:
                self.assertGreaterEqual(minutes * 60, cron.GOD_PAIRED_DEADLINE_S + cron.GOD_PAIRED_ROUND_TIMEOUT_S, name)
            self.assertLessEqual(minutes, 360, f"{name}: GitHub's job cap")
        self.assertGreater(cron.linux_job_minutes("infinite-items"), 60)

    def test_flat_grown_has_headroom_over_its_28_minutes(self):
        """2026-11-17: chat-100k-flat-grown (about 28 minutes) timed out against its 1770 s bench cap."""
        self.assertGreaterEqual(cron.linux_run_seconds("web-ui-flat-grown"), 2700)
        self.assertGreaterEqual(cron.linux_job_minutes("web-ui-flat-grown"), 55)
        self.assertEqual(cron.linux_run_seconds("web-ui-scale"), cron.LINUX_RUN_TIMEOUT_S)  # a part without run_seconds

    def test_the_matrix_output_is_one_line_of_json_with_a_timeout_per_part(self):
        out = cron.linux_matrix(["web-ui", "infinite-items"])
        self.assertNotIn("\n", out)
        self.assertEqual(json.loads(out), [
            {"part": "web-ui", "minutes": cron.linux_job_minutes("web-ui")},
            {"part": "infinite-items", "minutes": cron.linux_job_minutes("infinite-items")}])
        self.assertEqual(cron.linux_matrix([]), "[]")

    def test_every_leg_runs_on_the_plans_one_linux_label(self):
        """Every leg runs on, and its rows carry as host, the plan's linux_runner (the one cmux-linux label)."""
        wf = open(os.path.join(HERE, "..", "..", "..", ".github", "workflows", "cmux-next-perf-budgets.yml")).read()
        self.assertFalse(any(p.get("runner") for p in cron.PARTS))
        self.assertEqual(wf.count("needs.plan.outputs.linux_runner }}"), 2, "runs-on and RUNNER_CLASS")

    def test_linux_class_changed_is_per_part(self):
        old, new = "blacksmith-4vcpu-ubuntu-2404", "blacksmith-16vcpu-ubuntu-2404"
        classes = cron.linux_part_classes({f"webui.infinite_items.x@{new}": 1, f"webui.chat_open.y@{old}": 1})
        self.assertTrue(cron.linux_class_changed(f"webui.infinite_items.x@{old}", classes))
        self.assertFalse(cron.linux_class_changed(f"webui.chat_open.z@{old}", classes))
        self.assertFalse(cron.linux_class_changed(f"webui.chat_disk.z@{old}", classes), "chat-disk did not run")
        self.assertFalse(cron.linux_class_changed("panes.close.stress.frame@cmux20-bench", classes))

    def report(self, d, linux_job):
        """A report of a tick whose linux matrix ran web-ui-flat (failed), web-ui-flat-grown (no result.json) and
        chat-disk (no artifact at all)."""
        state = cron.empty_state(T0)
        state["persisted"] = True
        state["current"] = cron.new_measurement("b" * 40, "tip", ["build", "motion", "web-ui-flat", "web-ui-flat-grown",
                                                                  "chat-disk"], T0)
        with open(os.path.join(d, "state.json"), "w") as f:
            json.dump(state, f)
        flat, grown = os.path.join(d, "flat"), os.path.join(d, "grown")
        os.makedirs(flat)
        os.makedirs(grown)
        with open(os.path.join(flat, "result.json"), "w") as f:
            json.dump({"state": "failed", "worker": LINUX, "tail": ["chat-100k-flat: exit 1"]}, f)
        results = [f"web-ui-flat={flat}", f"web-ui-flat-grown={grown}", f"chat-disk={os.path.join(d, 'none')}"]
        with mock.patch.object(cron, "now_utc", lambda: at(1)), contextlib.redirect_stdout(io.StringIO()):
            cron.cmd_report(argparse.Namespace(repo="o/r", dir=d, result=results, run_url="u", finish=False,
                                               issues=False, linux_job=linux_job, output=os.path.join(d, "report.out")))
        with open(os.path.join(d, "state.json")) as f:
            return json.load(f)["current"]

    def test_the_report_stores_every_linux_part_and_a_missing_one_fails_with_why(self):
        with tempfile.TemporaryDirectory() as d:
            cur = self.report(d, "failure")
        self.assertEqual(cur["parts_todo"], ["build", "motion", "web-ui-flat-grown", "chat-disk"],
                         "a missing result runs once more (the setup retry)")
        self.assertEqual(cur["parts"]["web-ui-flat"]["why"], "chat-100k-flat: exit 1")
        for name in ("web-ui-flat-grown", "chat-disk"):
            self.assertEqual(cur["parts"][name]["state"], "failed", name)
            self.assertIn(f"the {name} runner left no result (the linux job ended failure", cur["parts"][name]["why"])
            self.assertIn(f"{cron.linux_job_minutes(name)}-minute timeout", cur["parts"][name]["why"])
            self.assertIn("runner left no result", cur["parts"][name]["setup_retried"])
        result = cron.missing_result(os.path.join("/nonexistent", "x"), "chat-disk", "failure")
        cron.record_part(cur, "chat-disk", result, "r")
        self.assertNotIn("chat-disk", cur["parts_todo"], "a second missing result ends it as failed")
        self.assertEqual(cur["parts"]["chat-disk"]["state"], "failed")

    def test_a_failed_download_counts_one_attempt_not_a_failure(self):
        result = cron.missing_result("/nonexistent", "chat-disk", "success", "failure")
        self.assertEqual((result["state"], result.get("no_result")), ("yielded", True))
        self.assertEqual(cron.missing_result("/nonexistent", "chat-disk", "success", "success")["state"], "failed")

    def test_a_cancelled_run_counts_a_missing_linux_part_as_one_attempt(self):
        with tempfile.TemporaryDirectory() as d:
            cur = self.report(d, "cancelled")
        self.assertEqual(cur["parts_todo"], ["build", "motion", "web-ui-flat-grown", "chat-disk"])
        self.assertEqual((cur["parts"]["chat-disk"]["state"], cur["parts"]["chat-disk"]["yields"]), ("yielded", 1))


class LinuxClassMoveTests(OneRunRule):
    def test_a_part_moved_to_its_own_runner_class_closes_only_its_old_rows(self):
        """infinite-items moved to another runner class while the other Linux parts stay on linux_4: its old-class regression
        closes (never measured there again) and its new rows start their baseline; a web-ui regression on linux_4 is
        still judged, not closed because another part changed class."""
        old, new = "blacksmith-4vcpu-ubuntu-2404", "blacksmith-16vcpu-ubuntu-2404"
        items, chat = "webui.infinite_items.idle_cpu_pct.n1000", "webui.chat_open.compact.latest"
        rows = {f"{items}@{old}": row(10.0), f"{chat}@{old}": row(10.0)}
        state = cron.empty_state(T0)
        parts = {"infinite-items": {"state": "done"}, "web-ui": {"state": "done"}}
        for i, (a, b) in enumerate([(10.0, 10.0), (30.0, 30.0)]):
            state["current"] = cron.new_measurement(f"{i + 1}" * 40, "tip", [], at(i))
            state["current"]["parts"] = dict(parts)
            cron.finish_measurement(state, {f"{items}@{old}": row(a), f"{chat}@{old}": row(b)}, None, "x", "r", at(i),
                                    budgets_mod)
        self.assertEqual(sorted(r["name"] for r in state["regressions"]), sorted(rows))
        state["current"] = cron.new_measurement("4" * 40, "tip", [], at(2))
        state["current"]["parts"] = dict(parts)
        cron.finish_measurement(state, {f"{items}@{new}": row(10.0), f"{chat}@{old}": row(31.0)}, None, "x", "r",
                                at(2), budgets_mod)
        self.assertEqual([r["name"] for r in state["regressions"]], [f"{chat}@{old}"])
        self.assertIn(f"the Linux runner class is now {new}", state["history"][-1].get("rebased_note") or "")


class ReplayControllerResultsTests(unittest.TestCase):
    """A reader's copy of the state (synthetic-probes.yml perf-tabs, after fetch-state) stores the controller's done
    results (GET /perf-cron/results.json) with the cron's own report, at the time each step ended: on 2026-11-19 each
    result run waited ~16 h for a runner and the probe tabs-keep-speed read no Mac row for 2 days while the bench had
    measured them."""

    class Answer(io.BytesIO):
        def __enter__(self):
            return self

        def __exit__(self, *a):
            return False

    def replay(self, d, results, gone=()):
        path = os.path.join(d, "results.json")
        with open(path, "w") as f:
            json.dump({"results": results}, f)
        report = json.dumps(PartRowsStoredAtOnceTests.STRESS).encode()

        def urlopen(req, timeout=0):
            if req.full_url in gone:
                raise OSError("artifact expired")
            return self.Answer(report)
        with mock.patch.object(cron.urllib.request, "urlopen", urlopen), \
                mock.patch.object(cron, "now_utc", lambda: at(30)):
            cron.cmd_replay_results(argparse.Namespace(dir=d, url="", file=path))
        with open(os.path.join(d, "state.json")) as f:
            return json.load(f)

    def result(self, **kw):
        return {"run": 7, "attempt": 1, "sha": "a" * 40, "part": "stress", "step_id": "s1", "state": "done",
                "worker": cron.BENCH_WORKER, "artifact_url": "https://store.example/x",
                "ended_at": cron.iso(at(2)).replace("Z", ".123456789Z"), **kw}

    def test_a_done_result_is_stored_at_its_end_and_only_once(self):
        with tempfile.TemporaryDirectory() as d:
            state = PartRowsStoredAtOnceTests().state_with(["stress", "motion"])
            with open(os.path.join(d, "state.json"), "w") as f:
                json.dump(state, f)
            results = [self.result(), self.result(sha="b" * 40, step_id="s0"), self.result(part="motion", state="failed",
                                                                                           step_id="s2")]
            state = self.replay(d, results)
            rows = state.get("part_rows") or {}
            self.assertTrue(rows, "the controller's done part is stored with no result run")
            for name, row in rows.items():
                self.assertTrue(name.endswith("@" + cron.BENCH_WORKER), name)
                self.assertEqual((row["sha"], row["part"], row["at"]), ("a" * 40, "stress", cron.iso(at(2))),
                                 "at the time the step ended, not the time of the read")
            self.assertEqual(state["current"]["parts_todo"], ["motion"], "the failed part is the cron's to judge")
            self.assertEqual(state["current"]["parts"]["stress"]["step_id"], "s1")
            again = self.replay(d, results)
            self.assertEqual(again["part_stored"], state["part_stored"], "a step stored already is not stored again")

    def test_an_unreadable_list_leaves_the_state_as_fetched(self):
        with tempfile.TemporaryDirectory() as d:
            state = PartRowsStoredAtOnceTests().state_with(["stress"])
            with open(os.path.join(d, "state.json"), "w") as f:
                json.dump(state, f)
            cron.cmd_replay_results(argparse.Namespace(dir=d, url="", file=os.path.join(d, "missing.json")))
            with open(os.path.join(d, "state.json")) as f:
                self.assertEqual(json.load(f), state)

    def test_a_result_without_its_end_time_is_not_stored(self):
        with tempfile.TemporaryDirectory() as d:
            state = PartRowsStoredAtOnceTests().state_with(["stress"])
            with open(os.path.join(d, "state.json"), "w") as f:
                json.dump(state, f)
            state = self.replay(d, [self.result(ended_at="")])
            self.assertFalse(state.get("part_rows"), "a row is never dated by its read")

    def test_a_step_id_never_names_a_path_outside_the_copy(self):
        # review of cmux#47673 (F1): the feed's step_id named the part's directory, so "../x" or "/abs" wrote
        # result.json and report.json outside --dir.
        for bad in ("../../escaped", "ABSOLUTE"):
            with tempfile.TemporaryDirectory() as outer:
                d = os.path.join(outer, "copy")
                os.mkdir(d)
                state = PartRowsStoredAtOnceTests().state_with(["stress"])
                with open(os.path.join(d, "state.json"), "w") as f:
                    json.dump(state, f)
                step_id = os.path.join(outer, "escaped") if bad == "ABSOLUTE" else bad
                state = self.replay(d, [self.result(step_id=step_id)])
                self.assertTrue(state.get("part_rows"), "the part is still stored")
                self.assertEqual(sorted(os.listdir(outer)), ["copy"], f"nothing is written outside the copy ({bad})")

    def test_a_malformed_feed_or_entry_stores_the_rest(self):
        # review of cmux#47673 (F4): a non-list results, or an entry whose ended_at is not a real time, aborted the
        # replay before the valid results.
        with tempfile.TemporaryDirectory() as d:
            state = PartRowsStoredAtOnceTests().state_with(["stress"])
            with open(os.path.join(d, "state.json"), "w") as f:
                json.dump(state, f)
            path = os.path.join(d, "results.json")
            with open(path, "w") as f:
                json.dump({"results": {"not": "a list"}}, f)
            cron.cmd_replay_results(argparse.Namespace(dir=d, url="", file=path))
            with open(os.path.join(d, "state.json")) as f:
                self.assertEqual(json.load(f), state, "a non-list results is no result")
            state = self.replay(d, [self.result(step_id="bad", ended_at="2026-13-45T99:99:99.1Z"), self.result()])
            self.assertTrue(state.get("part_rows"), "the valid result after a bad one is stored")

    def fresh(self, d, started_at=T0):
        # Two parts, so the measurement stays in flight after stress is stored.
        state = PartRowsStoredAtOnceTests().state_with(["stress", "motion"])
        state["current"]["started_at"] = cron.iso(started_at)
        with open(os.path.join(d, "state.json"), "w") as f:
            json.dump(state, f)

    def test_a_result_that_ended_before_the_measurement_started_is_not_stored(self):
        # review of cmux#47673 at 79330ccf (F1): a new measurement of the same SHA took the old step's result.
        with tempfile.TemporaryDirectory() as d:
            self.fresh(d, started_at=at(3))
            state = self.replay(d, [self.result()])
            self.assertFalse(state.get("part_rows"), "the old step's rows are not the new measurement's")
            self.assertEqual(state["current"]["parts_todo"], ["stress", "motion"], "the part is still to do")

    def test_an_unreadable_artifact_leaves_the_part_pending(self):
        # review of cmux#47673 at 79330ccf (F2): a download failure was stored as a failed part, so a later readable
        # result of the same part was dropped.
        with tempfile.TemporaryDirectory() as d:
            self.fresh(d)
            later = cron.iso(at(4)).replace("Z", ".5Z")
            state = self.replay(d, [self.result(artifact_url="https://store.example/gone"),
                                    self.result(step_id="s2", ended_at=later)], gone=("https://store.example/gone",))
            self.assertEqual(state["current"]["parts"]["stress"]["step_id"], "s2", "the readable result is stored")
            self.assertTrue(state.get("part_rows"))

    def test_an_entry_with_a_wrong_field_type_stores_the_rest(self):
        # review of cmux#47673 at 79330ccf (F3): "part": [] raised TypeError and aborted the entries after it.
        with tempfile.TemporaryDirectory() as d:
            self.fresh(d)
            state = self.replay(d, [self.result(step_id="p", part=[]), self.result(step_id="s", state={}),
                                    self.result(step_id=[]), self.result()])
            self.assertEqual(state["current"]["parts"]["stress"]["step_id"], "s1", "the valid result is stored")

    def test_results_go_in_the_order_their_steps_ended(self):
        # review of cmux#47673 at 79330ccf (F4): ended_at sorted as text put .11Z (later) before .1Z.
        with tempfile.TemporaryDirectory() as d:
            self.fresh(d)
            base = cron.iso(at(2))
            state = self.replay(d, [self.result(step_id="later", ended_at=base.replace("Z", ".11Z")),
                                    self.result(step_id="earlier", ended_at=base.replace("Z", ".1Z"))])
            self.assertEqual(state["current"]["parts"]["stress"]["step_id"], "earlier", "the earlier step goes first")


class StalePartFirstTests(unittest.TestCase):
    """A part whose newest stored rows (part_stored) are older than PART_STALE_HOURS runs ahead of the PARTS order, so
    every row the cron feeds gets a pass within 24 h (2026-11-19: throughput, the last Mac part, went 38 h without one
    while earlier parts yielded and retried, and goal terminal-throughput reads its row)."""

    def mid_measurement(self, stored_hours_ago):
        state = cron.empty_state(T0)
        cron.decide(state, T0, "a" * 40, None, lambda sha: ALL, None)
        cur = state["current"]
        cron.record_part(cur, "build", {"state": "done", "worker": cron.BENCH_WORKER}, "u", T0)
        cron.record_part(cur, "stress", {"state": "yielded", "worker": cron.BENCH_WORKER}, "u", T0)
        self.assertIn("stress", cur["parts_todo"], "stress is mid-yield: still to do")
        now = at(1)
        state["part_stored"] = {
            name: {"sha": "0" * 40, "at": cron.iso(now - datetime.timedelta(hours=stored_hours_ago.get(name, 2))), "rows": 1}
            for name in ALL if name != "build"}
        # Each stored part carried its goal's rows (goal_rows_missing), so only the stored date makes one due.
        state["part_rows"] = {"webui.god_ratio.transcript_replay.long.token_ms@h": dict(state["part_stored"]["web-ui-god"])}
        return state, now

    def test_a_part_past_the_bound_runs_before_a_yielding_one(self):
        state, now = self.mid_measurement({"throughput": 30, "chat-disk": 25})
        d = cron.decide(state, now, None, None, lambda sha: ALL, None)
        self.assertEqual((d["action"], d["part"]), ("part", "throughput"))
        self.assertEqual(d["linux_parts"][0], "chat-disk", "a stale Linux part goes first among the Linux parts too")

    def test_the_oldest_stale_part_goes_first(self):
        state, now = self.mid_measurement({"throughput": 30, "sidebar": 40})
        d = cron.decide(state, now, None, None, lambda sha: ALL, None)
        self.assertEqual(d["part"], "sidebar")

    def test_nothing_stale_keeps_the_parts_order(self):
        state, now = self.mid_measurement({})
        todo = list(state["current"]["parts_todo"])
        d = cron.decide(state, now, None, None, lambda sha: ALL, None)
        self.assertEqual((d["part"], d["linux_parts"][0]), ("stress", "diff-viewer"))
        self.assertEqual(state["current"]["parts_todo"], todo)

    def test_the_build_stays_first_when_a_part_is_stale(self):
        state = cron.empty_state(T0)
        state["part_stored"] = {"throughput": {"sha": "0" * 40, "at": cron.iso(at(-30)), "rows": 1}}
        d = cron.decide(state, T0, "a" * 40, None, lambda sha: ALL, None)
        self.assertEqual(d["part"], "build")


def typing_run(mode, p50, p95, p99, **more):
    """One typing-frame-bench.py --modes run, in the shape step 3b72dd7b stored on cmux20-bench (2026-11-20)."""
    return {"mode": mode, "surface": "agentpane", "phase": "idle" if mode == "L0" else "load", "complete": True,
            "text_exact": True, "key_order_ok": True, "expected_keys": 200, "observed_keys": 200, "mode_missing": [],
            "dispatch_to_after_frame_p50_ms": p50, "dispatch_to_after_frame_p95_ms": p95,
            "dispatch_to_after_frame_p99_ms": p99, **more}


class TypingLoadPartTests(unittest.TestCase):
    REPORT = {"runs": [
        typing_run("L0", 10.43, 16.17, 18.25),
        typing_run("L2", 10.98, 18.33, 24.37, complete=False),
        typing_run("L3", 3.12, 10.98, 13.59, mode_missing=["the 100k-row chat transcript"]),
        typing_run("L4", 10.66, 24.89, 29.43),
        typing_run("L4", 9.0, 30.6, 35.8),
        typing_run("L1", 3.26, 9.96, 13.19, text_exact=False, observed_keys=199),
    ]}

    def test_a_complete_fully_loaded_mode_is_a_row_set_and_its_worst_round_wins(self):
        rows = cron.rows_of_part(cron.PART_BY_NAME["typing-load"], self.REPORT, None, {})
        self.assertEqual(rows["typing.agentpane.L0.after_frame"],
                         {"p50": 10.43, "p95": 16.17, "unit": "ms", "budget": 16.0, "floor": 2.0})
        self.assertEqual(rows["typing.agentpane.L0.after_frame_p99"]["p95"], 18.25)
        self.assertEqual(rows["typing.agentpane.L0.after_frame_p99"]["budget"], 33.0)
        self.assertEqual(rows["typing.agentpane.L0.lost_keys"]["p95"], 0)
        self.assertEqual(rows["typing.agentpane.L4.after_frame"]["p95"], 30.6)
        self.assertEqual(rows["typing.agentpane.L4.after_frame_p99"]["p95"], 35.8)
        self.assertEqual(rows["typing.agentpane.L1.lost_keys"]["p95"], 1, "a key lost or out of order is a count")

    def test_an_incomplete_or_partly_loaded_mode_gives_no_row(self):
        rows = cron.rows_of_part(cron.PART_BY_NAME["typing-load"], self.REPORT, None, {})
        self.assertFalse([n for n in rows if ".L2." in n or ".L3." in n])

    def test_its_rows_route_to_the_part(self):
        self.assertEqual(cron.part_for_row("typing.agentpane.L4.after_frame"), "typing-load")

    def test_the_part_runs_only_where_the_bench_has_the_load_modes(self):
        def git(args, **_kw):
            if args[3] == "show" and args[4].endswith("typing-frame-bench.py"):
                return mock.Mock(returncode=0, stdout="--modes agentpane" if args[4].startswith("new") else "--phases")
            return mock.Mock(returncode=0, stdout="--suite=launch --suite=wake \"--activation\"")
        with mock.patch.object(cron.subprocess, "run", git):
            self.assertIn("typing-load", cron.supported_parts_at("new"))
            self.assertNotIn("typing-load", cron.supported_parts_at("old"))


class BoundedPathCheckTests(unittest.TestCase):
    """A plan's path checks end: a git that never answers (a lazy fetch in the partial clone) counts as absent after
    PATH_CHECK_TIMEOUT_S instead of holding the plan to its job cap (run 44731310755, 74 minutes with no output)."""

    def test_a_check_past_its_bound_is_absent_and_logged(self):
        seen = {}

        def hung(argv, **kw):
            seen.update(kw)
            raise cron.subprocess.TimeoutExpired(argv, kw.get("timeout"))

        out = io.StringIO()
        with mock.patch.object(cron.subprocess, "run", hung), contextlib.redirect_stdout(out):
            self.assertFalse(cron.has_path("a" * 40, "webviews/bench/chat-100k-flat.bench.ts"))
        self.assertEqual(seen["timeout"], cron.PATH_CHECK_TIMEOUT_S)
        self.assertEqual(seen["env"]["GIT_TERMINAL_PROMPT"], "0")
        self.assertIn("counted as absent", out.getvalue())

    def test_git_answers_decide(self):
        for code, want in ((0, True), (128, False)):
            done = cron.subprocess.CompletedProcess([], code)
            with mock.patch.object(cron.subprocess, "run", lambda argv, **kw: done):
                self.assertIs(cron.has_path("a" * 40, "x"), want)

    def test_every_part_check_goes_through_the_bound(self):
        calls = []

        def run(argv, **kw):
            calls.append(kw.get("timeout"))
            return cron.subprocess.CompletedProcess(argv, 0, stdout="--suite=launch \"--activation\" --suite=x")

        with mock.patch.object(cron.subprocess, "run", run):
            cron.supported_parts_at("a" * 40)
        self.assertTrue(calls)
        self.assertNotIn(None, calls)


class UnreadPartFirstTests(unittest.TestCase):
    """A Mac part that never produced a reading measures first, at the newest commit that has it, instead of after the
    tip in flight's rotation (2026-11-22: chat-size, merged after tip 9a55953f, never ran while that tip took days)."""
    OLD, NEW = "a" * 40, "b" * 40

    def supported(self, sha):
        return ALL if sha == self.NEW else [n for n in ALL if n != "chat-size"]

    def mid_tip(self, stored=None):
        state = cron.empty_state(T0)
        cron.decide(state, T0, self.OLD, None, self.supported, None)
        cur = state["current"]
        for name in [n for n in cur["parts_todo"] if n not in ("wake", "power", "coord-sim")]:
            cron.record_part(cur, name, {"state": "done", "worker": cron.BENCH_WORKER}, "u", T0)
        state["part_stored"] = {n: {"sha": self.OLD, "at": cron.iso(T0), "rows": 1}
                                for n in ALL if n != "build" and n not in (["chat-size"] if stored is None else stored)}
        return state

    def test_a_tip_that_predates_an_unread_part_gives_its_mac_parts_up(self):
        state = self.mid_tip()
        self.assertEqual(cron.unread_parts(state), ["chat-size"])
        cron.decide(state, at(1), None, None, self.supported, None, newest=self.NEW)
        self.assertEqual(sorted(state["current"]["parts_todo"][:2]), ["power", "wake"],
                         "a measurement under SUPERSEDE_AFTER_HOURS old keeps its Mac parts")
        state["current"]["yield_hours"] = cron.SUPERSEDE_AFTER_HOURS  # the day went to nightlies, as on 2026-11-22
        state["current"].pop("host_asked_since", None)  # and its host still takes parts
        d = cron.decide(state, at(cron.SUPERSEDE_AFTER_HOURS + 1), None, None, self.supported, None, newest=self.NEW)
        cur = state["current"]
        self.assertEqual((d["part"], d["linux_parts"]), ("", ["coord-sim"]), "the Linux parts still run")
        self.assertEqual({cur["parts"][n]["state"] for n in ("wake", "power")}, {"superseded"})
        cron.record_part(cur, "coord-sim", {"state": "done", "worker": cron.LEGACY_LINUX_CLASS}, "u", at(26))
        d = cron.decide(state, at(26.5), None, None, self.supported, None, newest=self.NEW)
        self.assertEqual(d["action"], "finish")
        state["current"] = None
        cron.decide(state, at(27), self.NEW, None, self.supported, None)
        order = cron.part_order(state, state["current"]["parts_todo"], at(27))
        self.assertEqual(order[:2], ["build", "chat-size"], "the unread part goes right after the build")

    def test_a_tip_with_no_mac_part_done_gives_way_at_once(self):
        # 2026-11-24: tip b76703549055 had run only Linux parts (its one Mac part yielded) 23 h in, so the hold kept
        # nothing, while the unread web-ui-orchestrator waited for it.
        state = cron.empty_state(T0)
        cron.decide(state, T0, self.OLD, None, self.supported, None)
        cur = state["current"]
        cron.record_part(cur, "build", {"state": "done", "worker": cron.BENCH_WORKER}, "u", T0)
        state["part_stored"] = {n: {"sha": self.OLD, "at": cron.iso(T0), "rows": 1}
                                for n in ALL if n not in ("build", "chat-size")}
        cron.decide(state, at(1), None, None, self.supported, None, newest=self.NEW)
        cur = state["current"]
        self.assertIn("superseded", cur, "no Mac part done: the hold keeps nothing")
        self.assertFalse([n for n in cur["parts_todo"] if not cron.is_linux_part(n)], "its Mac parts gave way")

    def test_a_superseded_tip_stops_waiting_for_an_unanswered_linux_part(self):
        # 2026-11-23: tip 12aa19c2 gave its Mac parts up, then its web-ui-growth request went unanswered 23 h, and the
        # newer tip with chat-size waited for ABANDON_WALL_HOURS.
        state = self.mid_tip()
        state["current"]["yield_hours"] = cron.SUPERSEDE_AFTER_HOURS
        state["current"].pop("host_asked_since", None)
        t = cron.SUPERSEDE_AFTER_HOURS + 1
        d = cron.decide(state, at(t), None, None, self.supported, None, newest=self.NEW)
        self.assertIn("coord-sim", d["linux_parts"], "the Linux part may still run")
        d = cron.decide(state, at(t + cron.SUPERSEDED_LINUX_HOURS / 2), None, None, self.supported, None, newest=self.NEW)
        self.assertNotEqual(d["action"], "finish", "inside its bound it keeps the Linux part")
        d = cron.decide(state, at(t + cron.SUPERSEDED_LINUX_HOURS + 0.1), None, None, self.supported, None, newest=self.NEW)
        self.assertEqual(d["action"], "finish")
        self.assertEqual(state["current"]["parts"]["coord-sim"]["state"], "superseded")

    def test_a_superseded_record_from_before_the_bound_ends_at_once(self):
        state = self.mid_tip()
        cur = state["current"]
        for name in [n for n in cur["parts_todo"] if not cron.is_linux_part(n)]:
            cur["parts"][name] = {"state": "superseded", "reason": "x"}
            cur["parts_todo"].remove(name)
        cur["superseded"] = {"by": self.NEW, "why": "chat-size never produced a reading"}
        d = cron.decide(state, at(30), None, None, self.supported, None, newest=self.NEW)
        self.assertEqual(d["action"], "finish")

    def test_a_stale_linux_part_runs_again_while_the_tip_waits_on_mac_parts(self):
        # 2026-11-25: tip b76703549055 ran web-ui-god once, stored nothing, then waited two days on Mac parts, and
        # NOW's idle_chat_rest_wakeups_per_s stayed stale behind it.
        state = self.mid_tip(stored=[])
        cur = state["current"]
        cur["yield_hours"] = 3 * cron.PART_STALE_HOURS  # the days went to nightlies: under the active bound
        cron.record_part(cur, "coord-sim", {"state": "done", "worker": cron.LEGACY_LINUX_CLASS}, "u", T0)
        d = cron.decide(state, at(1), None, None, self.supported, None)
        self.assertEqual(d["linux_parts"], [], "rows under PART_STALE_HOURS old: nothing runs again")
        t = cron.PART_STALE_HOURS + 1
        for name, e in state["part_stored"].items():
            if name != "coord-sim":
                e["at"] = cron.iso(at(t - 1))  # the others stored rows since: only coord-sim's are stale
        cur.pop("host_asked_since", None)  # its host still takes parts
        d = cron.decide(state, at(t), None, None, self.supported, None)
        self.assertEqual(d["linux_parts"], ["coord-sim"], "its rows went stale while wake and power wait")
        self.assertIn("wake", cur["parts_todo"])
        cron.record_part(cur, "coord-sim", {"state": "failed", "worker": cron.LEGACY_LINUX_CLASS}, "u", at(t))
        cur.pop("host_asked_since", None)
        d = cron.decide(state, at(t + 1), None, None, self.supported, None)
        self.assertEqual(d["linux_parts"], [], "at most once per PART_STALE_HOURS, even when it stored nothing")
        cur.pop("host_asked_since", None)
        for name, e in state["part_stored"].items():
            if name != "coord-sim":
                e["at"] = cron.iso(at(t + cron.PART_STALE_HOURS))
        d = cron.decide(state, at(t + cron.PART_STALE_HOURS + 1), None, None, self.supported, None)
        self.assertEqual(d["linux_parts"], ["coord-sim"])

    def test_no_linux_part_runs_again_once_the_mac_parts_are_done(self):
        state = self.mid_tip(stored=[])
        cur = state["current"]
        cur["yield_hours"] = 3 * cron.PART_STALE_HOURS
        for name in ("wake", "power", "coord-sim"):
            cron.record_part(cur, name, {"state": "done", "worker": cron.BENCH_WORKER}, "u", T0)
        d = cron.decide(state, at(cron.PART_STALE_HOURS + 5), None, None, self.supported, None)
        self.assertEqual(d["action"], "finish", "the next tip measures every part anyway")

    def test_a_tip_whose_build_failed_frees_the_mac_at_once(self):
        # 2026-11-25: tip 6c8931ce22be's app build failed at 10:32Z (exit 65), and its Linux parts held the Mac pass of
        # the next tip, b4a3f501, until 19:51Z: terminal_throughput_vs_ghostty_ratio went stale.
        state = cron.empty_state(T0)
        state["part_stored"] = {n: {"sha": self.OLD, "at": cron.iso(T0), "rows": 1} for n in ALL if n != "build"}
        cron.decide(state, T0, self.OLD, None, self.supported, None)
        cur = state["current"]
        cron.record_part(cur, "build", {"state": "failed", "build_failed": True, "worker": cron.BENCH_WORKER}, "u", T0)
        cron.record_part(cur, "coord-sim", {"state": "done"}, "u", T0)  # a Linux part that ran with the build
        d = cron.decide(state, at(0.3), None, None, self.supported, None, newest=None)
        self.assertNotIn("superseded", state["current"], "no newer commit: it keeps going")
        self.assertIn("diff-viewer", d["linux_parts"])
        d = cron.decide(state, at(0.6), None, None, self.supported, None, newest=self.NEW)
        self.assertEqual(d["action"], "finish", "the next tip claims the Mac at this tick")
        self.assertIn("build failed", d["reason"])
        parts = state["current"]["parts"]
        self.assertEqual(parts["coord-sim"]["state"], "done", "a Linux part that finished keeps its rows")
        self.assertEqual(parts["diff-viewer"]["state"], "superseded")
        self.assertEqual(parts["throughput"]["state"], "build_failed", "the build failure is still reported")
        self.assertEqual(parts["build"]["state"], "failed")
        cron.finish_measurement(state, {}, 8.33, None, "u", at(0.6), budgets_mod)
        self.assertTrue(state["history"][-1]["build_failed"])
        self.assertEqual(state["history"][-1]["failed_why"]["throughput"], "build_failed")
        self.assertTrue(cron.last_tip_build_failed(state))
        cron.decide(state, at(0.6), self.NEW, None, self.supported, None)
        self.assertEqual(state["current"]["sha"], self.NEW)
        self.assertEqual(state["current"]["parts_todo"][0], "build", "its Mac pass starts at the same tick")

    def test_a_tip_whose_build_failed_after_another_gives_way_after_its_linux_bound(self):
        # A second tip in a row whose build failed: the base is likely broken, so its Linux parts keep their bound
        # (SUPERSEDED_LINUX_HOURS) rather than every tip ending before any Linux part finished.
        state = cron.empty_state(T0)
        state["part_stored"] = {n: {"sha": self.OLD, "at": cron.iso(T0), "rows": 1} for n in ALL if n != "build"}
        state["history"] = [{"sha": "e" * 40, "kind": "tip", "build_failed": True}]
        cron.decide(state, T0, self.OLD, None, self.supported, None)
        cur = state["current"]
        cron.record_part(cur, "build", {"state": "failed", "build_failed": True, "worker": cron.BENCH_WORKER}, "u", T0)
        self.assertTrue(cron.build_failed_tip(cur))
        d = cron.decide(state, at(1), None, None, self.supported, None, newest=None)
        self.assertNotIn("superseded", state["current"], "no newer commit: it keeps going")
        d = cron.decide(state, at(1), None, None, self.supported, None, newest=self.NEW)
        self.assertEqual(state["current"]["superseded"]["by"], self.NEW)
        self.assertIn("coord-sim", d["linux_parts"], "its Linux parts still run inside the bound")
        d = cron.decide(state, at(1 + cron.SUPERSEDED_LINUX_HOURS + 0.1), None, None, self.supported, None, newest=self.NEW)
        self.assertEqual(d["action"], "finish")
        self.assertIn("build failed", d["reason"])

    def test_a_build_that_never_ran_is_no_broken_base(self):
        # 2026-11-26: tip c2b1760e's checkout was refused (HTTP 403, source download failed 3 times, before the job
        # started) and ended build_failed; the next tip 60a23ed3's source fetch got 503 from the controller's git
        # proxy, and it held the Mac behind 21 Linux parts as if the base were broken (tabs, chat-snappy, typing and
        # the launch rows stayed stale).
        why = ("step checkout: GitHub refused the fetch (HTTP 403) (exit status 128) "
               "(source download failed 3 times, before the job started)")
        state = cron.empty_state(T0)
        state["history"] = [{"sha": "e" * 40, "kind": "tip", "build_failed": True,
                             "failed_why": {"build": why, "tabs": "build_failed"}}]
        self.assertFalse(cron.last_tip_build_failed(state))
        state["history"][0]["failed_why"]["build"] = "step exited 65"
        self.assertTrue(cron.last_tip_build_failed(state), "a build that ran and failed still counts")

    def test_a_tip_whose_build_never_ran_frees_the_mac_after_another_failed(self):
        state = cron.empty_state(T0)
        state["part_stored"] = {n: {"sha": self.OLD, "at": cron.iso(T0), "rows": 1} for n in ALL if n != "build"}
        state["history"] = [{"sha": "e" * 40, "kind": "tip", "build_failed": True}]
        cron.decide(state, T0, self.OLD, None, self.supported, None)
        cur = state["current"]
        tail = ["ci-step reviewed check: no reviewed tip could be fetched for scripts/measure/split-spring.sh at "
                "60a23ed343cf (main: not fetched (git: unable to access 'http://controller/v1/git/manaflow-ai/cmux.git/': "
                "The requested URL returned error: 503)"]
        cron.record_part(cur, "build", {"state": "failed", "build_failed": True, "worker": cron.BENCH_WORKER,
                                        "tail": tail}, "u", T0)
        d = cron.decide(state, at(1), None, None, self.supported, None, newest=self.NEW)
        self.assertEqual(d["action"], "finish", "its build never ran: the base is not judged broken")

    def test_a_held_superseded_tip_ends_once_its_base_is_not_judged_broken(self):
        # The state written before this fix: tip 60a23ed3 superseded, its Linux parts held for the bound.
        state = cron.empty_state(T0)
        state["part_stored"] = {n: {"sha": self.OLD, "at": cron.iso(T0), "rows": 1} for n in ALL if n != "build"}
        state["history"] = [{"sha": "e" * 40, "kind": "tip", "build_failed": True,
                             "failed_why": {"build": "step checkout: GitHub refused the fetch (HTTP 403)"}}]
        cron.decide(state, T0, self.OLD, None, self.supported, None)
        cur = state["current"]
        cron.record_part(cur, "build", {"state": "failed", "build_failed": True, "worker": cron.BENCH_WORKER,
                                        "tail": ["step exited 65"]}, "u", T0)
        cur["superseded"] = {"by": self.NEW, "why": f"its app build failed; {self.NEW[:12]} is newer", "at": cron.iso(at(1))}
        self.assertTrue(cur["parts_todo"])
        d = cron.decide(state, at(1.2), None, None, self.supported, None, newest=self.NEW)
        self.assertEqual(d["action"], "finish")

    def test_a_bisect_step_whose_build_failed_is_not_superseded(self):
        cur = {"kind": "bisect", "sha": self.OLD, "parts": {"wake": {"state": "build_failed"}}}
        self.assertFalse(cron.build_failed_tip(cur), "a bisect step skips the commit when it ends (drop_dead_measurement)")

    def test_an_unread_part_goes_ahead_of_a_stale_one(self):
        state = self.mid_tip()
        state["part_stored"]["wake"]["at"] = cron.iso(at(-40))
        todo = ["build", "wake", "power", "chat-size"]
        self.assertEqual(cron.part_order(state, todo, at(1)), ["build", "chat-size", "wake", "power"])

    def test_once_read_or_not_yet_in_any_tree_the_rotation_is_unchanged(self):
        state = self.mid_tip(stored=[])  # chat-size has a reading
        cron.decide(state, at(1), None, None, self.supported, None, newest=self.NEW)
        self.assertEqual(sorted(state["current"]["parts_todo"][:2]), ["power", "wake"])
        state = self.mid_tip()
        state["part_rows"] = {"chat_size.ratio.max@" + cron.BENCH_WORKER: {"p95": 1.0}}
        self.assertEqual(cron.unread_parts(state), [], "a stored row counts as a reading")
        state = self.mid_tip()
        cron.decide(state, at(1), None, None, self.supported, None, newest=None)
        self.assertEqual(sorted(state["current"]["parts_todo"][:2]), ["power", "wake"], "no newer commit has it: no change")
        cron.decide(state, at(1), None, None, self.supported, None, newest=self.OLD)
        self.assertEqual(sorted(state["current"]["parts_todo"][:2]), ["power", "wake"], "the newest commit lacks it too")

    def test_an_unread_linux_part_gives_the_tip_in_flight_up_too(self):
        # 2026-11-24: web-ui-orchestrator (cmux#54205) merged after tip b76703549055, 13 of 45 parts in 229 h; as a
        # Linux part it never counted as unread, so it could not run until that tip ended.
        linux = "web-ui-orchestrator"
        self.assertTrue(cron.is_linux_part(linux))
        supported = lambda sha: ALL if sha == self.NEW else [n for n in ALL if n != linux]
        state = cron.empty_state(T0)
        cron.decide(state, T0, self.OLD, None, supported, None)
        cur = state["current"]
        for name in [n for n in cur["parts_todo"] if n not in ("wake", "power")]:
            cron.record_part(cur, name, {"state": "done", "worker": cron.BENCH_WORKER}, "u", T0)
        state["part_stored"] = {n: {"sha": self.OLD, "at": cron.iso(T0), "rows": 1}
                                for n in ALL if n not in ("build", linux)}
        self.assertEqual(cron.unread_parts(state), [linux])
        cur["yield_hours"] = cron.SUPERSEDE_AFTER_HOURS
        cur.pop("host_asked_since", None)
        d = cron.decide(state, at(cron.SUPERSEDE_AFTER_HOURS + 1), None, None, supported, None, newest=self.NEW)
        self.assertEqual(d["action"], "finish")
        self.assertEqual({cur["parts"][n]["state"] for n in ("wake", "power")}, {"superseded"})
        state["current"] = None
        cron.decide(state, at(26), self.NEW, None, supported, None)
        order = cron.part_order(state, state["current"]["parts_todo"], at(26))
        self.assertEqual([p for p in order if cron.is_linux_part(p)][0], linux, "the unread Linux part runs first")

class LinuxControllerRouteTests(unittest.TestCase):
    """The Linux parts go to the build controller first (Leo, 2026-11-19, on Blacksmith: "stop ... relying on it"):
    the plan asks with a `perf cron request <sha> <part>` job, and a part whose requests go unanswered falls back to
    the runner job, then asks the controller again."""
    SHA = "c" * 40

    def cur(self):
        return cron.new_measurement(self.SHA, "tip", ["web-ui-god", "diff-viewer"], T0)

    def window(self, part="web-ui-god"):
        return datetime.timedelta(minutes=cron.linux_answer_minutes(part) + 1)

    def test_a_linux_part_is_requested_from_the_controller_first(self):
        cur = self.cur()
        self.assertEqual(cron.linux_route(cur, "web-ui-god", T0, True, True), "request")
        self.assertEqual(cur["linux_requests"]["web-ui-god"]["asked_at"], cron.iso(T0))

    def test_a_request_in_its_answer_window_runs_nothing_else(self):
        cur = self.cur()
        cron.linux_route(cur, "web-ui-god", T0, True, True)
        self.assertEqual(cron.linux_route(cur, "web-ui-god", at(0.5), True, True), "wait")

    def test_unanswered_requests_fall_back_to_the_runner_then_ask_again(self):
        cur, t = self.cur(), T0
        routes = []
        for _ in range(cron.LINUX_REQUESTS_MAX + 2):
            routes.append(cron.linux_route(cur, "web-ui-god", t, True, True))
            t += self.window()
        self.assertEqual(routes[:cron.LINUX_REQUESTS_MAX], ["request"] * cron.LINUX_REQUESTS_MAX)
        self.assertEqual(routes[cron.LINUX_REQUESTS_MAX], "runner", "Blacksmith only after the controller did not answer")
        self.assertEqual(routes[cron.LINUX_REQUESTS_MAX + 1], "request", "the runner is a fallback, not the new route")

    def test_a_waiting_part_holds_back_only_itself(self):
        cur = self.cur()
        cron.linux_route(cur, "web-ui-god", T0, True, True)
        runner, request, waiting = cron.linux_picks(cur, ["web-ui-god", "diff-viewer"], at(0.5), True, True)
        self.assertEqual((runner, request, waiting), ([], "diff-viewer", ["web-ui-god"]),
                         "coord-sim's wait held every Linux part back for hours (2026-11-23)")
        self.assertIn("diff-viewer", cur["linux_requests"], "the part picked is asked")
        self.assertEqual(cur["linux_requests"]["web-ui-god"]["asked_at"], cron.iso(T0), "the waiting one untouched")

    def test_one_tick_runs_a_fallen_back_part_and_asks_for_another(self):
        cur = self.cur()
        cur["linux_requests"] = {"web-ui-god": {"asked_at": cron.iso(T0), "unanswered": cron.LINUX_REQUESTS_MAX - 1}}
        t = T0 + self.window()
        runner, request, waiting = cron.linux_picks(cur, ["web-ui-god", "diff-viewer"], t, True, True)
        self.assertEqual((runner, request, waiting), (["web-ui-god"], "diff-viewer", []))
        self.assertTrue(cur["linux_requests"]["web-ui-god"].get("fell_back_at"))

    def test_every_part_waiting_picks_none_and_changes_nothing(self):
        cur = self.cur()
        for part in ("web-ui-god", "diff-viewer"):
            cron.linux_route(cur, part, T0, True, True)
        before = json.dumps(cur, sort_keys=True)
        self.assertEqual(cron.linux_picks(cur, ["web-ui-god", "diff-viewer"], at(0.5), True, True),
                         ([], "", ["web-ui-god", "diff-viewer"]))
        self.assertEqual(json.dumps(cur, sort_keys=True), before, "the plan then yields (linux_wait_yield)")

    def test_without_the_controller_every_part_runs_on_the_matrix_at_once(self):
        cur = self.cur()
        self.assertEqual(cron.linux_picks(cur, ["web-ui-god", "diff-viewer"], T0, False, True),
                         (["web-ui-god", "diff-viewer"], "", []))
        self.assertNotIn("linux_requests", cur)

    def test_cloud_claim_is_never_asked_of_the_controller(self):
        cur = self.cur()
        self.assertEqual(cron.linux_route(cur, "cloud-claim", T0, True, True), "runner",
                         "it needs the run's token, which a pool worker has not")
        self.assertNotIn("cloud-claim", cur.get("linux_requests") or {})

    def test_no_controller_or_an_older_commit_runs_on_the_runner(self):
        self.assertEqual(cron.linux_route(self.cur(), "web-ui-god", T0, False, True), "runner")
        self.assertEqual(cron.linux_route(self.cur(), "web-ui-god", T0, True, False), "runner",
                         "a commit without the step script cannot run on the controller")

    def test_an_answer_clears_the_request(self):
        cur = self.cur()
        cron.linux_route(cur, "web-ui-god", T0, True, True)
        cron.record_part(cur, "web-ui-god", {"state": "failed"}, "r")
        self.assertNotIn("web-ui-god", cur.get("linux_requests") or {})
        self.assertEqual(cron.linux_route(cur, "diff-viewer", at(0.1), True, True), "request")

    def test_a_yielded_controller_answer_is_an_unanswered_request_at_once(self):
        # Review of cmux#48328: a yield (not queued: no idle Linux worker; pre-empted; the step's queue timeout) cleared
        # the count, so MAX_YIELDS yields ended the part yielded_out and the runner never ran it.
        cur, t, routes = self.cur(), T0, []
        for _ in range(cron.MAX_YIELDS + 1):
            routes.append(cron.linux_route(cur, "web-ui-god", t, True, True))
            if routes[-1] == "runner":
                break
            t += datetime.timedelta(minutes=5)
            cron.record_part(cur, "web-ui-god", {"state": "yielded", "tail": ["pre-empted by a nightly build"]}, "r", t)
            self.assertIn("web-ui-god", cur["parts_todo"])
            self.assertNotEqual(cur["parts"]["web-ui-god"]["state"], "yielded_out")
        self.assertEqual(routes, ["request"] * cron.LINUX_REQUESTS_MAX + ["runner"],
                         "each yielded answer counts at once (no answer window), and the runner is the last try")
        self.assertLess(t - T0, datetime.timedelta(hours=1))

    POOL_FULL = ("not queued: cmux-linux-pool-1125-060400-1890ddf4 cannot run the step (labels, toolchain, class or disk); "
                 "cmux-linux-pool-1125-115313-c9b8f520 is not online and healthy; 145 more busy")

    def test_a_full_pool_sends_the_part_to_the_runner_and_the_parts_behind_it_with_it(self):
        # 2026-11-25: tip 6c8931ce22be's 23 Linux parts went to the controller one a tick; web-ui-power-user, first,
        # was asked again after each "not queued" answer, and web-ui-ladder and web-ui-fidelity (21st and 22nd) were
        # never asked. Now the part answered so runs on the runner, the next is asked, and the rest run beside it.
        order = ["web-ui-power-user", "web-ui-settled", "web-ui-flat", "web-ui-ladder", "web-ui-fidelity"]
        cur = cron.new_measurement(self.SHA, "tip", list(order), T0)
        self.assertEqual(cron.linux_picks(cur, order, T0, True, True), ([], "web-ui-power-user", []))
        t = T0 + datetime.timedelta(minutes=9)
        cron.record_part(cur, "web-ui-power-user", {"state": "yielded", "tail": [self.POOL_FULL]}, "r", t)
        self.assertTrue(cron.linux_pool_full(cur, t))
        runners, request, waiting = cron.linux_picks(cur, order, t, True, True)
        self.assertEqual((runners, request, waiting),
                         (["web-ui-power-user", "web-ui-flat", "web-ui-ladder", "web-ui-fidelity"], "web-ui-settled", []))
        self.assertEqual(sorted(cur["linux_requests"]), ["web-ui-power-user", "web-ui-settled"],
                         "the parts sent to the runner unasked keep no request")
        cron.record_part(cur, "web-ui-ladder", {"state": "done"}, "r", t + datetime.timedelta(minutes=30))
        self.assertNotIn("web-ui-ladder", cur["parts_todo"])
        self.assertTrue(cron.linux_pool_full(cur, t + datetime.timedelta(minutes=30)), "a runner result says nothing of the pool")

    def test_the_pool_takes_requests_again_after_it_runs_a_part_or_after_the_window(self):
        order = ["web-ui-god", "diff-viewer", "web-ui"]
        cur = cron.new_measurement(self.SHA, "tip", list(order), T0)
        cron.linux_picks(cur, order, T0, True, True)
        cron.record_part(cur, "web-ui-god", {"state": "yielded", "tail": [self.POOL_FULL]}, "r", T0)
        later = T0 + datetime.timedelta(minutes=cron.LINUX_POOL_FULL_MINUTES + 1)
        self.assertFalse(cron.linux_pool_full(cur, later))
        self.assertEqual(cron.linux_picks(cur, order, later, True, True), (["web-ui-god"], "diff-viewer", []),
                         "past the window only the part answered so goes to the runner")
        cur = cron.new_measurement(self.SHA, "tip", list(order), T0)
        cron.linux_picks(cur, order, T0, True, True)
        cron.record_part(cur, "web-ui-god", {"state": "yielded", "tail": [self.POOL_FULL]}, "r", T0)
        cron.linux_picks(cur, order, T0, True, True)  # diff-viewer asked
        cron.record_part(cur, "diff-viewer", {"state": "done"}, "r", T0)
        self.assertFalse(cron.linux_pool_full(cur, T0), "the pool ran a part: one request a tick again")

    def test_a_starved_linux_part_runs_on_the_runner_not_in_the_request_slot(self):
        # 2026-11-23 to 11-26: daemon-restart (stored 11-23 01:14Z) and web-ui-scale (11-21), the two stalest Linux
        # parts, were first in part_order, so each tick one of them was the one request asked of the controller, which
        # never ran it; each measurement ended before two unanswered windows sent it to the runner, and the NOW row
        # restart_chat_attach_daemon_ms read nothing for 3 days while every part behind them ran on the runner.
        t = T0
        fresh = cron.iso(t - datetime.timedelta(hours=5))
        state = {"part_stored": {"web-ui-scale": {"at": cron.iso(t - datetime.timedelta(hours=128))},
                                 "daemon-restart": {"at": cron.iso(t - datetime.timedelta(hours=93))},
                                 "diff-viewer": {"at": fresh}, "web-ui": {"at": fresh}}}
        order = ["web-ui-scale", "daemon-restart", "diff-viewer", "web-ui", "coord-sim"]
        starved = cron.linux_starved(state, order, t)
        self.assertEqual(starved, {"web-ui-scale", "daemon-restart", "coord-sim"}, "no stored rows is starved too")
        cur = cron.new_measurement(self.SHA, "tip", list(order), t)
        self.assertEqual(cron.linux_picks(cur, order, t, True, True, starved),
                         (["web-ui-scale", "daemon-restart", "coord-sim"], "diff-viewer", []))
        self.assertEqual(sorted(cur["linux_requests"]), ["diff-viewer"], "a starved part keeps no request")
        # Before: the stalest part takes the one request and nothing else runs.
        cur = cron.new_measurement(self.SHA, "tip", list(order), t)
        self.assertEqual(cron.linux_picks(cur, order, t, True, True), ([], "web-ui-scale", []))
        # A starved part already asked waits out its answer window, and then goes to the runner at once.
        cur = cron.new_measurement(self.SHA, "tip", list(order), t)
        cron.linux_picks(cur, ["daemon-restart"], t, True, True)
        self.assertEqual(cron.linux_picks(cur, ["daemon-restart"], t + datetime.timedelta(minutes=30), True, True,
                                          {"daemon-restart"}), ([], "", ["daemon-restart"]))
        later = t + datetime.timedelta(minutes=cron.linux_answer_minutes("daemon-restart") + 1)
        self.assertEqual(cron.linux_picks(cur, ["daemon-restart"], later, True, True, {"daemon-restart"}),
                         (["daemon-restart"], "", []))
        # Its runner result stores rows, and the next measurement asks the controller for it again.
        cron.record_part(cur, "daemon-restart", {"state": "done"}, "r", later)
        self.assertNotIn("daemon-restart", cur["parts_todo"])
        state["part_stored"]["daemon-restart"] = {"at": cron.iso(later)}
        self.assertNotIn("daemon-restart", cron.linux_starved(state, order, later))
        self.assertEqual(cron.linux_starved({}, ["web-ui"], t), {"web-ui"})
        self.assertEqual(cron.linux_starved({"part_stored": {"web-ui": {"at": None}}}, ["web-ui"], t), {"web-ui"})

    def test_a_yield_that_is_not_a_full_pool_keeps_the_request_count(self):
        cur = self.cur()
        cron.linux_route(cur, "web-ui-god", T0, True, True)
        cron.record_part(cur, "web-ui-god", {"state": "yielded", "tail": ["pre-empted by a nightly build"]}, "r", T0)
        self.assertFalse(cron.linux_pool_full(cur, T0))
        self.assertEqual(cron.linux_picks(cur, ["web-ui-god", "diff-viewer"], T0, True, True), ([], "web-ui-god", []))

    def test_the_runner_yield_after_a_fallback_counts_as_a_yield(self):
        cur, t = self.cur(), T0
        for _ in range(cron.LINUX_REQUESTS_MAX + 1):
            route = cron.linux_route(cur, "web-ui-god", t, True, True)
            t += self.window()
        self.assertEqual(route, "runner")
        cron.record_part(cur, "web-ui-god", {"state": "yielded"}, "r", t)
        self.assertEqual(cur["parts"]["web-ui-god"]["yields"], 1)
        self.assertNotIn("web-ui-god", cur["linux_requests"])

    def test_a_not_queued_answer_of_the_controller_is_a_result(self):
        raw = json.dumps({"sha": self.SHA, "part": "web-ui-god", "state": "yielded",
                          "error": "not queued: no idle cmux-next-linux mt-c4d-highcpu-32 worker"})
        value = cron.controller_result(raw)
        self.assertIsNotNone(value)
        self.assertEqual(cron.result_files(value)["state"], "yielded")

    def test_the_controller_result_of_a_linux_part_is_kept(self):
        raw = json.dumps({"sha": self.SHA, "part": "web-ui-god", "state": "done", "step_id": "s1",
                          "worker": "cmux-linux-pool-1120-215706-d01e49f4", "artifact_url": "https://store.example/a"})
        value = cron.controller_result(raw)
        self.assertIsNotNone(value)
        self.assertEqual(cron.result_files(value)["worker"], cron.LINUX_FLEET_CLASS,
                         "rows name the fleet class, never one VM: each VM is new, so no baseline would ever form")

    def fetch(self, artifact):
        out = tempfile.mkdtemp()
        raw = json.dumps({"sha": self.SHA, "part": "web-ui-god", "state": "done", "step_id": "s1",
                          "worker": "cmux-linux-pool-x", "artifact_url": "https://store.example/a"})

        class Answer(io.BytesIO):
            def __enter__(self):
                return self

            def __exit__(self, *a):
                return False
        with mock.patch.object(cron.urllib.request, "urlopen", lambda req, timeout=0: Answer(json.dumps(artifact).encode())):
            cron.cmd_fetch_result(argparse.Namespace(result=raw, out=out))
        with open(os.path.join(out, "result.json")) as f:
            result = json.load(f)
        report = None
        if os.path.exists(os.path.join(out, "report.json")):
            with open(os.path.join(out, "report.json")) as f:
                report = json.load(f)
        return result, report

    def test_fetch_result_unwraps_the_linux_steps_report_and_result(self):
        rows = {"rows": [{"name": "chat_open.compact.attach_to_latest_per_calibration", "p95": 0.75}]}
        result, report = self.fetch({"report": rows, "result": {"state": "done", "seconds": 812, "tail": ["ok"],
                                                                "worker": cron.LINUX_FLEET_CLASS}})
        self.assertEqual(report, rows, "run-linux-part's own report, unchanged")
        self.assertEqual((result["state"], result["worker"], result["seconds"]), ("done", cron.LINUX_FLEET_CLASS, 812))

    def test_a_linux_step_whose_part_failed_is_a_failed_part(self):
        result, _ = self.fetch({"report": {}, "result": {"state": "failed", "tail": ["web-ui-suite: exit 1"]}})
        self.assertEqual(result["state"], "failed")
        self.assertIn("web-ui-suite: exit 1", result["tail"])
        result, report = self.fetch({"rows": []})
        self.assertEqual(result["state"], "failed", "an artifact without the step's report and result")
        self.assertIsNone(report)

    def test_a_linux_step_whose_setup_failed_is_a_yield(self):
        # Review of cmux#48328: a setup failure (bun, packages, WebKit, Chrome, Rust) exited 1, a final failure; on the
        # runner job the same failure runs again.
        result, report = self.fetch({"report": None, "result": {"state": "yielded", "tail": ["setup: bun install failed"]}})
        self.assertEqual(result["state"], "yielded")
        self.assertIn("setup: bun install failed", result["tail"])
        self.assertIsNone(report)

    def test_the_step_script_answers_a_setup_failure_with_a_yield(self):
        with open(os.path.join(HERE, "..", "..", "measure", "perf-cron-linux.sh")) as f:
            text = f.read()
        self.assertIn('"state": "yielded"', text)
        self.assertNotIn("|| exit 1", text, "a setup failure writes the yield and exits 0")
        self.assertNotIn("--depth", text, "a shallow fetch would make the worker's warm clone shallow")
        self.assertNotIn("--optional", text, "the system Chrome is required, as on the runner job")

    def run_plan(self, d, t, decision):
        out = os.path.join(d, f"plan-{t:%H%M%S}.out")
        o = argparse.Namespace(dir=d, output=out, tip="feat-cmux-next", repo="o/r", no_mac=True, yield_mode="",
                               controller=False, linux_controller=True, perf_result="")
        branch = mock.Mock()
        branch.verified.return_value = []
        with mock.patch.object(cron, "now_utc", return_value=t), \
                mock.patch.object(cron, "git", return_value=self.SHA), \
                mock.patch.object(cron, "measure_version", return_value=7), \
                mock.patch.object(cron, "commit_on_branch", return_value=branch), \
                mock.patch.object(cron, "sanitize_state", return_value=[]), \
                mock.patch.object(cron, "not_measuring_reason", return_value=""), \
                mock.patch.object(cron, "drop_dead_measurement", return_value=None), \
                mock.patch.object(cron, "commit_has", return_value=True), \
                mock.patch.object(cron, "decide", return_value=dict(decision)):
            cron.plan(o)
        with open(out) as f:
            plan = dict(line.split("=", 1) for line in f.read().splitlines())
        with open(os.path.join(d, "state.json")) as f:
            return plan, json.load(f)

    def test_plan_requests_waits_and_falls_back_to_the_runner(self):
        d = tempfile.mkdtemp()
        state = cron.empty_state(T0)
        state["current"] = cron.new_measurement(self.SHA, "tip", ["web-ui-god"], T0)  # one part: nothing else runs while it waits
        state["part_stored"] = {"web-ui-god": {"at": cron.iso(T0)}}  # fresh rows: not starved (LINUX_STARVED_HOURS)
        state.pop("dirty", None)
        with open(os.path.join(d, "state.json"), "w") as f:
            json.dump(state, f)
        decision = {"action": "part", "sha": self.SHA, "kind": "tip", "part": "", "linux_parts": ["web-ui-god"],
                    "worker": "", "reason": "tip measurement"}
        ticks = [(T0, "request"), (T0 + datetime.timedelta(minutes=30), "wait"),
                 (T0 + self.window(), "request"), (T0 + 2 * self.window(), "runner")]
        for t, want in ticks:
            with open(os.path.join(d, "state.json")) as f:
                before = json.load(f)
            before["dirty"] = False
            with open(os.path.join(d, "state.json"), "w") as f:
                json.dump(before, f)
            plan, after = self.run_plan(d, t, decision)
            self.assertEqual(plan["linux_request"], "web-ui-god" if want == "request" else "", want)
            self.assertEqual([leg["part"] for leg in json.loads(plan["linux_matrix"])],
                             ["web-ui-god"] if want == "runner" else [], want)
            self.assertIn("web-ui-god", after["current"].get("configs") or {}, want)
            self.assertTrue(after.get("dirty"), f"the report job saves the {want} tick's state")
            if want == "wait":
                self.assertTrue(after["current"].get("yield_since"),
                                "a wait for the controller's answer does not count against ABANDON_HOURS")
            else:
                self.assertFalse(after["current"].get("yield_since"), want)
        self.assertGreater(after["current"].get("yield_hours", 0), 0)

    def test_a_fallen_back_part_joins_the_matrix_beside_the_other_runner_parts(self):
        cur = self.cur()
        cur["linux_requests"] = {"web-ui-god": {"asked_at": cron.iso(T0), "unanswered": cron.LINUX_REQUESTS_MAX - 1},
                                 "diff-viewer": {"asked_at": cron.iso(T0), "unanswered": cron.LINUX_REQUESTS_MAX - 1}}
        t = T0 + max(self.window("web-ui-god"), self.window("diff-viewer"))
        self.assertEqual(cron.linux_picks(cur, ["web-ui-god", "diff-viewer", "web-ui"], t, True, True),
                         (["web-ui-god", "diff-viewer"], "web-ui", []))

    def test_the_step_script_runs_the_unchanged_linux_part_with_the_fleet_class(self):
        with open(os.path.join(HERE, "..", "..", "measure", "perf-cron-linux.sh")) as f:
            text = f.read()
        self.assertIn("run-linux-part", text)
        self.assertIn(f"--runner-class {cron.LINUX_FLEET_CLASS}", text)
        self.assertIn(cron.LINUX_STEP_ARTIFACT, text)

    def test_the_workflow_asks_with_a_job_the_controller_reads(self):
        with open(os.path.join(HERE, "..", "..", "..", ".github", "workflows", "cmux-next-perf-budgets.yml")) as f:
            text = f.read()
        self.assertIn("name: perf cron request ${{ needs.plan.outputs.sha }} ${{ needs.plan.outputs.linux_request }}", text)
        self.assertIn("linux_request: ${{ steps.plan.outputs.linux_request }}", text)
        self.assertIn("CMUX_NEXT_PERF_CRON_LINUX_CONTROLLER", text)
        self.assertIn("--linux-controller", text)


class BatchTests(unittest.TestCase):
    """The controller route asks for a measurement's Mac parts back to back (BATCH_PREFIX) and stores their results
    from one result run. Leo, 2026-11-22, on the bench window: "does it need to take it for 2h tho? cant it be
    faster?" One part per round trip took a tip 3 to 14 h; back to back its Mac parts take about 1.5 h."""
    SHA = "c" * 40

    class Answer(io.BytesIO):
        def __enter__(self):
            return self

        def __exit__(self, *a):
            return False

    def plan_tick(self, d, now, parts):
        out = os.path.join(d, "plan.out")
        with mock.patch.object(cron, "now_utc", lambda: now), mock.patch.object(cron, "git", lambda *a, check=True: self.SHA), \
                mock.patch.object(cron, "measure_version", lambda sha: 2), \
                mock.patch.object(cron, "commit_on_branch", lambda repo, t, known=(): cron.is_sha), \
                mock.patch.object(cron, "tree_published", lambda sha, deadline=None: True), \
                mock.patch.object(cron, "github_busy", lambda *a: None), \
                mock.patch.object(cron, "frame_pacing_runs", lambda repo: []), \
                mock.patch.object(cron, "is_ancestor", lambda a, b: False), \
                mock.patch.object(cron, "supported_parts_at", lambda sha: parts), \
                mock.patch.object(cron, "controller_idle_hosts", lambda *a, **k: None):
            cron.cmd_plan(argparse.Namespace(repo="o/r", dir=d, tip="HEAD", yield_mode="queued", no_mac=False, output=out,
                                             controller=True))
        with open(out) as f:
            plan = dict(line.split("=", 1) for line in f.read().splitlines())
        os.remove(out)
        with open(os.path.join(d, "state.json")) as f:
            return plan, json.load(f)

    def result(self, part, state="done", step=None):
        return {"run": 5, "attempt": 1, "sha": self.SHA, "part": part, "step_id": step or f"s-{part}", "state": state,
                "worker": BENCH, "artifact_url": "https://store.example/" + part}

    def test_the_request_lists_the_mac_parts_still_to_do_the_requested_one_first(self):
        with tempfile.TemporaryDirectory() as d:
            state = cron.empty_state(T0)
            state["persisted"] = True
            with open(os.path.join(d, "state.json"), "w") as f:
                json.dump(state, f)
            plan, saved = self.plan_tick(d, T0, ["motion", "switch"])
            self.assertEqual((plan["action"], plan["part"]), ("part", "build"))
            self.assertEqual(plan["mac_parts"], "build motion switch")
            self.assertEqual(saved["current"]["batch"]["parts"], ["build", "motion", "switch"])
            self.assertEqual(sorted(saved["current"]["configs"]), ["build", "motion", "switch"],
                             "every listed part's rows carry this file's configuration")
            plan, again = self.plan_tick(d, at(0.5), ["motion", "switch"])
            self.assertEqual(again["current"]["batch"], saved["current"]["batch"], "a later tick keeps the batch asked for")
        with tempfile.TemporaryDirectory() as d:
            with open(os.path.join(d, "state.json"), "w") as f:
                json.dump({**cron.empty_state(T0), "persisted": True}, f)
            plan, saved = self.plan_tick(d, T0, [])
            self.assertEqual(plan["mac_parts"], "", "no other Mac part: one part, no line")

    def test_the_host_may_stay_silent_for_the_batchs_deadline(self):
        state = cron.empty_state(T0)
        state["current"] = cur = cron.new_measurement(self.SHA, "tip", ["build", "motion", "switch"], T0)
        cur["host"] = BENCH
        cur["host_asked_since"] = cron.iso(T0)
        self.assertEqual(cron.host_wait_hours(cur), cron.HOST_WAIT_HOURS)
        cur["batch"] = {"parts": ["build", "motion", "switch"], "asked_at": cron.iso(T0)}
        run = sum(cron.PART_BY_NAME[p].get("run_seconds", cron.PART_RUN_SECONDS) for p in cur["batch"]["parts"]) / 3600
        wait = cron.HOST_WAIT_HOURS + cron.BATCH_SLACK_HOURS + run
        self.assertAlmostEqual(cron.host_wait_hours(cur), wait)
        self.assertIsNone(cron.give_up_host(state, at(cron.HOST_WAIT_HOURS + 0.5)), "the batch runs: no result yet")
        self.assertIn("took no part", cron.give_up_host(state, at(wait + 0.1)))
        self.assertNotIn("batch", cur, "the next request lists again")

    def test_a_batchs_results_are_stored_from_one_result_run(self):
        state = cron.empty_state(T0)
        state["persisted"] = True
        state["current"] = cur = cron.new_measurement(self.SHA, "tip", ["build", "motion", "switch"], T0)
        cur["batch"] = {"parts": ["build", "motion", "switch"], "asked_at": cron.iso(T0)}
        cur["host_asked_since"] = cron.iso(T0)
        results = [self.result("build"), self.result("motion"), self.result("motion", step="dup"),
                   {**self.result("stress"), "sha": "d" * 40}, self.result("switch", "yielded")]
        raw = json.dumps({"results": results})
        self.assertEqual([v["part"] for v in cron.controller_results(raw)], ["build", "motion", "motion", "stress", "switch"])
        with tempfile.TemporaryDirectory() as d:
            with open(os.path.join(d, "state.json"), "w") as f:
                json.dump(state, f)
            out = os.path.join(d, "plan.out")
            with contextlib.redirect_stdout(io.StringIO()):
                cron.result_plan(argparse.Namespace(dir=d, output=out, perf_result=raw), state, at(1.5))
            with open(out) as f:
                plan = dict(line.split("=", 1) for line in f.read().splitlines())
            self.assertEqual((plan["action"], plan["part"], plan["result_parts"]), ("result", "build", "build motion switch"))
            parts = os.path.join(d, "result")
            with mock.patch.object(cron.urllib.request, "urlopen", lambda req, timeout=0: self.Answer(b'{"summary": []}')), \
                    contextlib.redirect_stdout(io.StringIO()):
                cron.cmd_fetch_result(argparse.Namespace(result=raw, out=parts, each=True))
            self.assertEqual(sorted(os.listdir(parts)), ["build", "motion", "stress", "switch"])
            with open(os.path.join(parts, "switch", "result.json")) as f:
                self.assertEqual(json.load(f)["state"], "yielded")
            specs = [f"{p}={os.path.join(parts, p)}" for p in plan["result_parts"].split()]
            with mock.patch.object(cron, "store_part_rows", lambda *a: None), contextlib.redirect_stdout(io.StringIO()), \
                    contextlib.redirect_stderr(io.StringIO()):
                cron.report(argparse.Namespace(repo="", dir=d, result=specs, run_url="u", finish=False, issues=False,
                                               output=os.path.join(d, "report.out")), t=at(1.5))
            with open(os.path.join(d, "state.json")) as f:
                cur = json.load(f)["current"]
            self.assertEqual(cur["parts_todo"], ["switch"], "the pre-empted part stays to do")
            self.assertEqual((cur["parts"]["build"]["state"], cur["parts"]["motion"]["state"]), ("done", "done"))
            self.assertNotIn("batch", cur)
            self.assertNotIn("host_asked_since", cur)

    def test_one_result_is_still_one_part(self):
        raw = json.dumps(self.result("motion"))
        self.assertEqual([v["part"] for v in cron.controller_results(raw)], ["motion"])
        self.assertEqual(cron.controller_results(json.dumps({"results": "x"})), [])
        self.assertEqual(cron.controller_results("{"), [])

    def test_the_workflow_prints_the_line_and_stores_every_result(self):
        with open(os.path.join(HERE, "..", "..", "..", ".github", "workflows", "cmux-next-perf-budgets.yml")) as f:
            text = f.read()
        self.assertIn('echo "perf-cron-batch: $MAC_PARTS"', text)
        self.assertEqual(cron.BATCH_PREFIX, "perf-cron-batch: ")
        self.assertIn("fetch-result --each", text)
        self.assertIn('for part in $RESULT_PARTS; do results+=(--result "$part=$RUNNER_TEMP/perf-cron-result/$part"); done', text)


if __name__ == "__main__":
    unittest.main()
