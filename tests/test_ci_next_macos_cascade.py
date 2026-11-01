#!/usr/bin/env python3
"""cmux-next's macOS cascade: idle minis, Blacksmith 12 vCPU, 6 vCPU, hosted macos-26, then the minis' queue.

The placement decides from live counts (Blacksmith's scale-set runner groups)
and the janitor's queued counts and waits; the workflow's runs-on reads its outputs.
"""
from __future__ import annotations

import datetime as dt
import importlib.util
import contextlib
import io
import itertools
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import yaml

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "scripts/ci"
WORKFLOW = ROOT / ".github/workflows/cmux-next.yml"
LARGE, SMALL, HOSTED = "blacksmith-12vcpu-macos-26", "blacksmith-6vcpu-macos-26", "macos-26"
MACOS_15 = "blacksmith-6vcpu-macos-15"
SIDE = "glaeda-side-light-xcode-26.6"
GUI = "glaeda-gui-std-xcode-26.6"
CASCADED = ("fast-tier", "swift-canary", "cmux-scheme-compile", "release-compile")
PROMOTE = "glaeda-promote-side-trusted-std-xcode-26.6"
GUI_JOBS = ("swift-test", "daemon-test", "generated-files")
ALL_JOBS = "fast-tier swift-canary cmux-scheme-compile release-compile swift-test daemon-test generated-files"
NOW = dt.datetime(2026, 10, 19, 22, 0, tzinfo=dt.timezone.utc)
BOT = "github-actions[bot]"

sys.path.insert(0, str(ROOT / "tests"))
from test_seed_derived_data import evaluate, github_context  # noqa: E402


def load(name: str):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


cascade = load("next_macos_cascade")
placement = load("side_lane_placement")


def env(**overrides: str) -> dict:
    return {"SIDE_LABEL": SIDE, "JOBS": ALL_JOBS, "GITHUB_RUN_ATTEMPT": "1",
            "CASCADE_RUNS": " fast-tier swift-canary cmux-scheme-compile ", **overrides}


def snapshot(minutes_old: float = 2, oldest: dict | None = None, hosted: tuple[int, int] = (0, 0),
             **queued: int) -> dict:
    """A janitor snapshot; `oldest` maps "large"/"small" to oldest_queued_minutes, `hosted` is
    macos-26's (queued, running)."""
    generated = (NOW - dt.timedelta(minutes=minutes_old)).strftime("%Y-%m-%dT%H:%M:%SZ")
    oldest = oldest or {}
    return {"generated_at": generated,
            "pools": {LARGE: {"queued": queued.get("large", 0), "running": 0,
                              "oldest_queued_minutes": oldest.get("large", 0)},
                      SMALL: {"queued": queued.get("small", 0), "running": 0,
                              "oldest_queued_minutes": oldest.get("small", 0)},
                      HOSTED: {"queued": hosted[0], "running": hosted[1], "oldest_queued_minutes": 0}}}


def none_placed(**jobs: tuple) -> dict:
    return {LARGE: (), SMALL: (), **jobs}



# The DEV daily placement (dev-daily-place) hands cmux-scheme-compile a runs-on that may be a label list
# ([a pool label, glaeda-runner-<name>]); the job's label copy reads that list's first label instead.
DAILY_PICK = ("needs.dev-daily-place.outputs.runs_on != '' && fromJSON(needs.dev-daily-place.outputs.runs_on)",
              "needs.dev-daily-place.outputs.runner_label != '' && needs.dev-daily-place.outputs.runner_label")


def label_copy(runs_on: str) -> str:
    """runs-on as the job's own CMUX_NEXT_RUNNER copy states it."""
    return runs_on.replace(*DAILY_PICK)

class Counts(unittest.TestCase):
    GROUPS = [{"id": 15, "name": f"Blacksmith scale sets - {LARGE}"},
              {"id": 10, "name": f"Blacksmith scale sets - {SMALL}"},
              {"id": 8, "name": "Blacksmith scale sets - blacksmith-6vcpu-macos-15"}]

    def test_in_flight_counts_each_labels_online_runners(self):
        runners = {15: [{"status": "online", "busy": True}] * 4 + [{"status": "offline", "busy": False}] * 3,
                   10: [{"status": "online", "busy": True}] * 9 + [{"status": "online", "busy": False}],
                   8: [{"status": "online", "busy": True}] * 7}
        # The macOS 15 label draws on the same organization pool, so its runners count too.
        self.assertEqual(cascade.in_flight(self.GROUPS, runners.__getitem__),
                         {LARGE: 4, SMALL: 10, MACOS_15: 7})
        # Its group is optional: without it the snapshot's running jobs stand in (with_running()).
        self.assertEqual(cascade.in_flight(self.GROUPS[:2], runners.__getitem__), {LARGE: 4, SMALL: 10})

    def test_a_missing_scale_set_group_counts_nothing(self):
        self.assertIsNone(cascade.in_flight(self.GROUPS[1:], lambda group: []))

    def test_queued_comes_from_a_fresh_snapshot_only(self):
        self.assertEqual(cascade.queued(snapshot(large=3, small=1), NOW), {LARGE: 3, SMALL: 1})
        self.assertIsNone(cascade.queued(snapshot(minutes_old=cascade.QUEUE_SNAPSHOT_MINUTES + 1), NOW))
        self.assertIsNone(cascade.queued({"generated_at": "not a time", "pools": {}}, NOW))
        self.assertIsNone(cascade.queued(None, NOW))
        # A label the janitor saw nothing on has nothing queued.
        self.assertEqual(cascade.queued({"generated_at": "2026-10-19T21:58:00Z", "pools": {}}, NOW),
                         {LARGE: 0, SMALL: 0})

    def test_legacy_health_record_with_no_queue_keeps_live_route(self):
        shot = snapshot(minutes_old=1)
        shot["pools"][GUI] = {"queued": 0, "running": 1, "oldest_queued_minutes": 0}
        self.assertFalse(cascade.owned_label_full(shot, GUI, NOW))

    def test_authoritative_gates_replace_legacy_pool_queue_counts(self):
        shot = snapshot(minutes_old=1, large=99)
        shot["gates"] = {"version": 1, "as_of": "2026-10-19T21:59:00Z", "labels": {
            GUI: {"listening": 0, "busy": 9, "held_offline": {"total": 9, "units": 9, "cpu": 0, "livelock": 0, "other": 0},
                  "down": 0, "unreported": 0, "queued": 2, "oldest_queued_s": 240,
                  "as_of": "2026-10-19T21:59:00Z"}}}
        self.assertTrue(cascade.owned_label_full(shot, GUI, NOW))
        shot["gates"]["labels"][GUI].update(listening=1, held_offline={"total": 0}, queued=0, oldest_queued_s=0)
        self.assertFalse(cascade.owned_label_full(shot, GUI, NOW))

    def test_fresh_gate_listener_does_not_depend_on_artifact_age(self):
        gates = {"version": 1, "labels": {GUI: {
            "as_of": "2026-10-19T21:59:00Z", "listening": 1,
            "held_offline": {"total": 0}, "queued": 1, "oldest_queued_s": 240}}}
        for shot in ({"gates": gates}, {**snapshot(minutes_old=20), "gates": gates}):
            with self.subTest(shot=shot):
                self.assertFalse(cascade.owned_label_full(shot, GUI, NOW, queued_wait_s=300))
                seen = cascade.seen(shot, NOW)
                self.assertTrue(seen.owned_full_known[GUI])
                self.assertFalse(seen.owned_full[GUI])
                self.assertEqual(seen.owned[GUI], 5)

    def test_gate_reading_preserves_stale_nightly_reservations(self):
        shot = snapshot(minutes_old=20)
        shot["pools"][SMALL]["reserved_queued"] = 1
        shot["gates"] = {"version": 1, "labels": {GUI: {
            "as_of": "2026-10-19T21:59:00Z", "listening": 1, "queued": 0}}}
        seen = cascade.seen(shot, NOW)
        self.assertTrue(seen.stale)
        self.assertEqual(seen.reserved, {SMALL: 1})
        self.assertFalse(seen.owned_full[GUI])

    def test_slow_runner_read_still_evaluates_local_fleet_gates(self):
        gates = {"version": 1, "labels": {GUI: {
            "as_of": "2026-10-19T21:59:00Z", "listening": 0,
            "held_offline": {"total": 1}, "queued": 1, "oldest_queued_s": 240}}}
        clock = iter([0, cascade.READ_BUDGET_SECONDS + 1])
        with mock.patch.object(cascade, "Api") as api:
            api.return_value.in_flight.return_value = {LARGE: 0, SMALL: 0}
            live, waiting, seen = cascade.read(
                env(CI_FLEET_GATES=json.dumps(gates), ROUTE_TOKEN="test", GITHUB_REPOSITORY="manaflow-ai/cmux"),
                mock.Mock(), now=NOW, clock=lambda: next(clock), log=lambda _: None)
        self.assertIsNone(waiting)
        self.assertTrue(seen.owned_full[GUI])

    def test_gate_missing_timestamp_does_not_claim_a_live_listener(self):
        shot = {"gates": {"labels": {GUI: {"listening": 1}}}}
        self.assertTrue(cascade.owned_label_full(shot, GUI, NOW, queued_wait_s=240))

    def test_gate_variable_is_read_when_artifact_is_unavailable(self):
        gates = {"version": 1, "labels": {GUI: {
            "as_of": "2026-10-19T21:59:00Z", "listening": 1, "queued": 0}}}
        live, waiting, seen = cascade.read(env(CI_FLEET_GATES=json.dumps(gates)),
                                           mock.Mock(), now=NOW, log=lambda _: None)
        self.assertIsNone(waiting)
        self.assertTrue(seen.owned_full_known[GUI])
        self.assertFalse(seen.owned_full[GUI])

    def test_gate_queue_does_not_add_age_to_rescues_live_wait(self):
        shot = {"gates": {"labels": {GUI: {
            "as_of": "2026-10-19T21:58:00Z", "listening": 0,
            "held_offline": {"total": 1}, "queued": 1, "oldest_queued_s": 120}}}}
        self.assertFalse(cascade.owned_label_full(shot, GUI, NOW, queued_wait_s=120))
        self.assertTrue(cascade.owned_label_full(shot, GUI, NOW))

    def test_owned_health_full_then_overflows(self):
        shot = snapshot(minutes_old=1)
        shot["pools"][GUI] = {"listening": 0, "busy": 9,
                               "held_offline": {"units": 9, "cpu": 0, "livelock": 0},
                               "queued": 2, "oldest_queued_s": 240,
                               "as_of": "2026-10-19T21:59:00Z"}
        self.assertTrue(cascade.owned_label_full(shot, GUI, NOW))

    def test_owned_health_stale_then_overflows(self):
        shot = snapshot(minutes_old=6)
        shot["pools"][GUI] = {"listening": 0, "busy": 9,
                               "held_offline": {"units": 9}, "queued": 1,
                               "oldest_queued_s": 240,
                               "as_of": "2026-10-19T21:54:00Z"}
        self.assertTrue(cascade.owned_label_full(shot, GUI, NOW))

    def test_stale_health_does_not_invent_a_queue(self):
        for label in (GUI, SIDE):
            shot = {"gates": {"labels": {label: {
                "as_of": "2026-10-19T21:54:00Z", "listening": 1,
                "queued": 0, "oldest_queued_s": 0}}}}
            with self.subTest(label=label):
                self.assertFalse(cascade.owned_label_full(shot, label, NOW))
                self.assertFalse(cascade.owned_label_full(shot, label, NOW, queued_wait_s=120))
                self.assertTrue(cascade.owned_label_full(shot, label, NOW, queued_wait_s=181))

    def test_stale_snapshot_queue_includes_snapshot_age(self):
        shot = {"gates": {"labels": {GUI: {
            "as_of": "2026-10-19T21:54:00Z", "listening": 1,
            "queued": 1, "oldest_queued_s": 120}}}}
        self.assertTrue(cascade.owned_label_full(shot, GUI, NOW))

    def test_stale_artifact_age_overflows_even_when_health_as_of_is_fresh(self):
        shot = snapshot(minutes_old=6)
        shot["pools"][GUI] = {"listening": 0, "busy": 1,
                               "held_offline": {"units": 1, "cpu": 0, "livelock": 0},
                               "queued": 1, "oldest_queued_s": 120,
                               "as_of": "2026-10-19T21:59:00Z"}
        self.assertTrue(cascade.owned_label_full(shot, GUI, NOW))

    def test_owned_health_with_a_listening_runner_waits(self):
        shot = snapshot(minutes_old=1)
        shot["pools"][GUI] = {"listening": 1, "busy": 1,
                               "held_offline": {"units": 0, "cpu": 0, "livelock": 0},
                               "queued": 1, "oldest_queued_s": 240,
                               "as_of": "2026-10-19T21:59:00Z"}
        self.assertFalse(cascade.owned_label_full(shot, GUI, NOW))

    def test_blacksmith_label_outage_over_thirty_minutes_is_dead(self):
        shot = snapshot(minutes_old=1, large=2)
        shot["bs_health"] = {"label_outages": [{"pool": LARGE, "queued": 2,
                                                    "oldest_wait_s": 120,
                                                    "last_start_s": 1900}]}
        self.assertTrue(cascade.label_full_or_dead(LARGE, shot, live=0, queued=2, now=NOW))

    def test_fresh_owned_gates_do_not_extend_expired_blacksmith_outages(self):
        for minutes_old, expected in ((1, True), (20, False)):
            with self.subTest(minutes_old=minutes_old):
                shot = snapshot(minutes_old=minutes_old, large=2)
                shot["bs_health"] = {"label_outages": [
                    {"pool": LARGE, "queued": 2, "last_start_s": 1900}]}
                shot["gates"] = {"version": 1, "labels": {GUI: {
                    "listening": 1, "queued": 0, "as_of": NOW.isoformat()}}}
                reading = cascade.seen(shot, NOW)
                self.assertIsNotNone(reading)
                self.assertEqual(cascade.label_full_or_dead(
                    LARGE, reading.snapshot, now=NOW), expected)
                # Capacity counts from the same expired artifact expire too.
                shot["bs_health"] = {}
                shot["pools"][LARGE].update(cap=5, running=5)
                self.assertEqual(cascade.label_full_or_dead(
                    LARGE, shot, now=NOW), expected)

    def test_blacksmith_label_at_cap_with_backlog_is_full(self):
        shot = snapshot(minutes_old=1, small=1)
        shot["pools"][SMALL]["cap"] = 5
        shot["pools"][SMALL]["running"] = 5
        self.assertTrue(cascade.label_full_or_dead(SMALL, shot, live=0, queued=1, now=NOW))

    def test_blacksmith_recent_start_is_not_dead(self):
        shot = snapshot(minutes_old=1, large=2)
        shot["bs_health"] = {"label_outages": [{"pool": LARGE, "queued": 2,
                                                    "oldest_wait_s": 2400,
                                                    "last_start_s": 120}]}
        self.assertFalse(cascade.label_full_or_dead(LARGE, shot, live=0, queued=2, now=NOW))

    def test_the_pools_other_labels_count_from_the_snapshot(self):
        shot = snapshot(large=1, small=2)
        shot["pools"][MACOS_15] = {"queued": 4, "running": 3}
        shot["pools"]["glaeda-side-std-xcode-26.6"] = {"queued": 121, "running": 10}
        # Queued counts every Blacksmith macOS label, never an owned or hosted one.
        self.assertEqual(cascade.queued(shot, NOW), {LARGE: 1, SMALL: 2, MACOS_15: 4})
        self.assertEqual(cascade.pool_queued(cascade.queued(shot, NOW)), 7)
        # A label no visible scale-set group counted takes the snapshot's running jobs; a live count wins.
        self.assertEqual(cascade.with_running({LARGE: 0, SMALL: 5}, shot, NOW), {LARGE: 0, SMALL: 5, MACOS_15: 3})
        self.assertEqual(cascade.with_running({LARGE: 0, SMALL: 5, MACOS_15: 1}, shot, NOW),
                         {LARGE: 0, SMALL: 5, MACOS_15: 1})
        self.assertEqual(cascade.with_running({LARGE: 0, SMALL: 5}, None, NOW), {LARGE: 0, SMALL: 5})
        self.assertEqual((cascade.vcpus(LARGE), cascade.vcpus(SMALL), cascade.vcpus(MACOS_15)), (12, 6, 6))
        self.assertFalse(cascade.pool_label(HOSTED) or cascade.pool_label("blacksmith-4vcpu-ubuntu-2404"))


class Cascade(unittest.TestCase):
    def test_twelve_vcpu_first_then_six_then_the_queue(self):
        # 30 of the pool's 60 vCPU are free: two 12 vCPU jobs (this run's share), then one 6 vCPU job.
        placed = cascade.cascade(CASCADED, {LARGE: 1, SMALL: 3}, {LARGE: 0, SMALL: 0})
        self.assertEqual(placed, none_placed(**{LARGE: ("fast-tier", "swift-canary"),
                                                SMALL: ("cmux-scheme-compile",)}))

    def test_a_queue_anywhere_sends_the_jobs_to_six_not_twelve(self):
        # A 12 vCPU job needs twelve vCPUs freed at once; while 6 vCPU jobs queue, they take each one first.
        placed = cascade.cascade(CASCADED[:2], {LARGE: 0, SMALL: 2}, {LARGE: 0, SMALL: 1})
        self.assertEqual(placed, none_placed(**{SMALL: CASCADED[:2]}))
        # A queue on the macOS 15 label is the same pool's queue.
        placed = cascade.cascade(CASCADED[:2], {LARGE: 0, SMALL: 2}, {LARGE: 0, SMALL: 0, MACOS_15: 1})
        self.assertEqual(placed, none_placed(**{SMALL: CASCADED[:2]}))

    def test_twelve_vcpu_waits_behind_a_pool_its_own_count_calls_free(self):
        """Runs 40386035282 and 40386506758 (2026-10-26): the placement read 12 vCPU as "0 in flight + 0
        queued of 5" and 6 vCPU as "9 in flight + 3 queued of 10", sent both DEV Release compiles to 12 vCPU,
        and they queued from 19:25Z to 20:42Z and 20:52Z. 6 vCPU's nine are 54 of the pool's 60 vCPU."""
        live, waiting = {LARGE: 0, SMALL: 9}, {LARGE: 0, SMALL: 3}
        self.assertEqual(cascade.cascade(("cmux-scheme-compile",), live, waiting), none_placed())
        self.assertEqual(cascade.retry_label(live, waiting), "")
        result = cascade.place(env(CASCADE_RUNS=" cmux-scheme-compile "), (), live, waiting)
        self.assertEqual(result.jobs, none_placed())
        self.assertIn("pool 72 of 60 vCPU in flight or queued", result.why)
        self.assertIn("cmux-scheme-compile stay queued on the owned label", result.why)
        # The pool's other label holds vCPUs as well: five 6 vCPU jobs on each fill it.
        self.assertEqual(cascade.cascade(("cmux-scheme-compile",), {LARGE: 0, SMALL: 5, MACOS_15: 5},
                                         {LARGE: 0, SMALL: 0}), none_placed())
        # With room for twelve and nothing queued anywhere, 12 vCPU still comes first.
        self.assertEqual(cascade.cascade(("cmux-scheme-compile",), {LARGE: 0, SMALL: 8}, {LARGE: 0, SMALL: 0}),
                         none_placed(**{LARGE: ("cmux-scheme-compile",)}))

    def test_a_stalled_twelve_vcpu_queue_holds_no_six_vcpu_room(self):
        # 2026-10-26 20:38Z to 20:47Z: six jobs queued on 12 vCPU for 78 to 83 minutes while 6 vCPU ran
        # seven and five with no queue, so a 12 vCPU job that waits does not hold the pool's vCPUs.
        self.assertEqual(cascade.pool_room({LARGE: 0, SMALL: 7}, {LARGE: 6, SMALL: 0}), 18)
        placed = cascade.cascade(CASCADED[:2], {LARGE: 0, SMALL: 7}, {LARGE: 6, SMALL: 0})
        self.assertEqual(placed, none_placed(**{SMALL: CASCADED[:2]}))

    def test_one_run_takes_at_most_max_per_run_slots_on_a_label(self):
        # A burst of runs in one snapshot window sees the same free slots; each takes few of them.
        placed = cascade.cascade(CASCADED, {LARGE: 0, SMALL: 0}, {LARGE: 0, SMALL: 0})
        self.assertEqual(cascade.MAX_PER_RUN, 2)
        self.assertEqual(placed, none_placed(**{LARGE: ("fast-tier", "swift-canary"),
                                                SMALL: ("cmux-scheme-compile", "release-compile")}))

    def test_queued_jobs_take_free_slots_first(self):
        # Five free 12 vCPU slots on the runner count, but five jobs already wait for them.
        placed = cascade.cascade(CASCADED, {LARGE: 0, SMALL: 10}, {LARGE: 5, SMALL: 0})
        self.assertEqual(placed, none_placed())

    def test_retry_goes_to_the_least_loaded_label(self):
        self.assertEqual(cascade.retry_label({LARGE: 1, SMALL: 4}, {LARGE: 1, SMALL: 0}), SMALL)
        # No free slot anywhere: no Blacksmith label, so the overflow waits on the owned label.
        self.assertEqual(cascade.retry_label({LARGE: 5, SMALL: 10}, {LARGE: 6, SMALL: 0}), "")
        self.assertEqual(cascade.retry_label({LARGE: 0, SMALL: 0}, {LARGE: 0, SMALL: 0}), LARGE)
        # Ten 6 vCPU jobs fill the pool: 12 vCPU's five idle slots are no room.
        self.assertEqual(cascade.retry_label({LARGE: 0, SMALL: 10}, {LARGE: 0, SMALL: 0}), "")

    def test_a_full_fleet_overflows_to_6_vcpu_whose_slots_turn_over(self):
        # 2026-10-20 01:04-02:35Z: other workflows' long jobs held 12 vCPU's five slots. The
        # overflow sent 25 cmux-next jobs there by load ratio and none started (14 queued over
        # 15 minutes, up to 89, then cancelled) while 6 vCPU started 69 at a median 2.5 minutes.
        # Both full: never a Blacksmith queue (5+ hour waits on 12 vCPU, 2026-10-20); the owned label.
        self.assertEqual(cascade.retry_label({LARGE: 5, SMALL: 10}, {LARGE: 0, SMALL: 0}), "")
        self.assertEqual(cascade.retry_label({LARGE: 0, SMALL: 9}, {LARGE: 0, SMALL: 0}), SMALL)
        # The placement log of run 39358219316: 12 vCPU 5 + 1 of 5, 6 vCPU 10 + 4 of 10.
        self.assertEqual(cascade.retry_label({LARGE: 5, SMALL: 10}, {LARGE: 1, SMALL: 4}), "")
        self.assertEqual(cascade.retry_label({LARGE: 7, SMALL: 30}, {LARGE: 0, SMALL: 9}), "")
        # A stalled label is never the overflow, however free it looks.
        self.assertEqual(cascade.retry_label({LARGE: 0, SMALL: 9}, {LARGE: 0, SMALL: 0}, (LARGE,)), SMALL)
        self.assertEqual(cascade.retry_label({LARGE: 0, SMALL: 0}, {LARGE: 0, SMALL: 0}, (LARGE, SMALL)), "")


class FleetGateway(unittest.TestCase):
    def test_all_full_routes_reserve_only_requested_fleet_jobs(self):
        shot = snapshot(minutes_old=1, large=1, small=1)
        for label in (LARGE, SMALL, SIDE):
            shot["pools"][label] = {"cap": 1, "running": 1, "queued": 1,
                                     "listening": 0, "held_offline": {"units": 1, "cpu": 0, "livelock": 0},
                                     "oldest_queued_s": 240, "as_of": "2026-10-19T21:59:00Z"}
        result = cascade.place(env(FLEET_CLIENT_JOBS="fast-tier"), (),
                               {LARGE: 5, SMALL: 10}, {LARGE: 1, SMALL: 1}, cascade.seen(shot, NOW), saturated=True)
        self.assertEqual(result.fleet_jobs, ("fast-tier",))

    def test_no_tier_runs_on_the_gateway_itself(self):
        """fleet_jobs never sends a whole Mac job (checkout, build) to gateway_runner: a listed tier's
        <tier>-fleet client runs there (the checks-workflow guard GatewayRunsOnlyTheFleetClient)
        and the tier only reports its verdict."""
        jobs = yaml.safe_load(WORKFLOW.read_text())["jobs"]
        self.assertEqual(jobs["macos-placement"]["outputs"]["fleet_jobs"], "${{ steps.place.outputs.fleet_jobs }}")
        wiring = Wiring()
        for tier in (*CASCADED, *GUI_JOBS):
            self.assertNotIn("outputs.fleet_jobs", jobs[tier]["runs-on"])
            with self.subTest(tier=tier):
                self.assertNotIn("gateway_runner", str(jobs[tier]["runs-on"]))
                context = wiring.context()
                context["needs"]["macos-placement"]["outputs"].update(
                    fleet_jobs=f" {tier} ", gateway_runner="gateway-test", placed_attempt="1")
                self.assertNotEqual(evaluate(jobs[tier]["runs-on"], context), "gateway-test")

    def test_gateway_reservation_is_empty_without_requested_jobs(self):
        shot = snapshot(minutes_old=1)
        result = cascade.place(env(), (), {LARGE: 5, SMALL: 10}, {LARGE: 1, SMALL: 1}, cascade.seen(shot, NOW), saturated=True)
        self.assertEqual(result.fleet_jobs, ())

class Place(unittest.TestCase):
    def test_bot_rerun_can_place_after_a_refusal_but_a_person_rerun_stays_owned(self):
        result = cascade.place(env(GITHUB_RUN_ATTEMPT="2", GITHUB_TRIGGERING_ACTOR=BOT), (),
                               {LARGE: 0, SMALL: 0}, {LARGE: 0, SMALL: 0})
        self.assertTrue(result.jobs[LARGE] or result.jobs[SMALL])
        person = cascade.place(env(GITHUB_RUN_ATTEMPT="2", GITHUB_TRIGGERING_ACTOR="teamleaderleo"), (),
                               {LARGE: 0, SMALL: 0}, {LARGE: 0, SMALL: 0})
        self.assertEqual(person.why, "a person re-run keeps its own route")

    def test_jobs_an_idle_mini_took_and_gui_jobs_stay_off_blacksmith(self):
        result = cascade.place(env(), ("fast-tier",), {LARGE: 0, SMALL: 0}, {LARGE: 0, SMALL: 0})
        self.assertEqual(result.jobs, none_placed(**{LARGE: ("swift-canary", "cmux-scheme-compile")}))
        # 12 vCPU is now 2 of 5 with this run's jobs, 6 vCPU 0 of 10.
        self.assertEqual(result.retry_runner, SMALL)

    def test_an_idle_mini_given_a_job_that_does_not_run_still_takes_one_that_does(self):
        # fast-tier is on its fast-lane runner (not in CASCADE_RUNS), yet idle_placement named it for
        # the one idle mini: that mini still takes swift-canary, and only the scheme compile pays Blacksmith.
        result = cascade.place(env(CASCADE_RUNS=" swift-canary cmux-scheme-compile "), ("fast-tier",),
                               {LARGE: 0, SMALL: 0}, {LARGE: 0, SMALL: 0})
        self.assertEqual(result.jobs, none_placed(**{LARGE: ("cmux-scheme-compile",)}))

    def test_only_jobs_that_run_on_this_route_take_a_slot(self):
        # fast-tier on its own fast-lane runner, or a canary the pull request's labels skip, spends no slot.
        result = cascade.place(env(CASCADE_RUNS=" cmux-scheme-compile "), (), {LARGE: 4, SMALL: 0},
                               {LARGE: 0, SMALL: 0})
        self.assertEqual(result.jobs, none_placed(**{LARGE: ("cmux-scheme-compile",)}))
        self.assertEqual(cascade.place(env(CASCADE_RUNS=""), (), {LARGE: 0, SMALL: 0},
                                       {LARGE: 0, SMALL: 0}).jobs, none_placed())
        # A Release compile that does not run (a same-repository PR without full-ci) takes no slot either.
        result = cascade.place(env(CASCADE_RUNS=" cmux-scheme-compile "), (), {LARGE: 0, SMALL: 0},
                               {LARGE: 0, SMALL: 0})
        self.assertNotIn("release-compile", result.jobs[LARGE] + result.jobs[SMALL])

    def test_a_release_compile_no_idle_mini_took_overflows_to_blacksmith(self):
        """2026-10-21 ~20:10Z: 76 Release compiles queued on the minis. The CEF shim check it skips off a
        mini is advisory (a Blacksmith re-run already skips it)."""
        self.assertIn("release-compile", cascade.CASCADE_JOBS)
        runs = " swift-canary cmux-scheme-compile release-compile "
        result = cascade.place(env(CASCADE_RUNS=runs), (), {LARGE: 0, SMALL: 0}, {LARGE: 0, SMALL: 0})
        self.assertEqual(result.jobs, none_placed(**{LARGE: ("swift-canary", "cmux-scheme-compile"),
                                                     SMALL: ("release-compile",)}))
        # Two idle minis take the canary and the scheme compile; the Release compile gets 12 vCPU.
        result = cascade.place(env(CASCADE_RUNS=runs), ("fast-tier", "swift-canary"), {LARGE: 0, SMALL: 0},
                               {LARGE: 0, SMALL: 0})
        self.assertEqual(result.jobs, none_placed(**{LARGE: ("release-compile",)}))

    def test_a_feat_push_release_compile_keeps_an_idle_promotion_mini(self):
        # Attempt 1 of a feat-cmux-next push compiles on vars.CI_NEXT_PROMOTE_POOL; while one of its
        # runners is idle the Release compile stays there and takes no side mini's share or Blacksmith slot.
        runs = " cmux-scheme-compile release-compile "
        free = {LARGE: 0, SMALL: 0}
        idle = cascade.place(env(CASCADE_RUNS=runs, PROMOTE_LABEL=PROMOTE), (), free, free, promote_busy=False)
        self.assertEqual(idle.jobs, none_placed(**{LARGE: ("cmux-scheme-compile",)}))
        # One idle side mini takes the scheme compile, not the promoted Release compile's turn.
        self.assertEqual(cascade.place(env(CASCADE_RUNS=runs, PROMOTE_LABEL=PROMOTE), ("fast-tier",), free, free,
                                       promote_busy=False).jobs, none_placed())

    def test_a_feat_push_release_compile_takes_the_runs_first_slot(self):
        # Run 40298786351 (2026-10-26 09:21Z): 6 vCPU had room, but MAX_PER_RUN went to fast-tier and the
        # scheme compile ahead of it in JOBS, and the Release compile queued on the owned label.
        runs = " fast-tier cmux-scheme-compile release-compile "
        live, waiting = {LARGE: 0, SMALL: 5}, {LARGE: 7, SMALL: 0}
        stalled = cascade.Seen(waits={LARGE: 227.0}, age=1.0)
        before = cascade.place(env(CASCADE_RUNS=runs), (), live, waiting, stalled)
        self.assertEqual(before.jobs[SMALL], ("fast-tier", "cmux-scheme-compile"))
        first = env(CASCADE_RUNS=runs, FIRST_JOBS="release-compile")
        self.assertEqual(cascade.place(first, (), live, waiting, stalled).jobs[SMALL], ("release-compile", "fast-tier"))
        # The idle minis are spent on the run's other jobs first: one idle mini, and the Release compile still
        # has its slot (fast-tier races for the mini); as many idle minis as side jobs, and nothing cascades.
        one = cascade.place(first, ("fast-tier",), live, waiting, stalled)
        self.assertEqual(one.jobs[SMALL], ("release-compile", "cmux-scheme-compile"))
        three = cascade.place(first, ("fast-tier", "swift-canary", "cmux-scheme-compile"), live, waiting, stalled)
        self.assertEqual(three.jobs, none_placed())
        two = cascade.place(first, ("fast-tier", "swift-canary"), live, waiting, stalled)
        self.assertEqual(two.jobs[SMALL], ("release-compile",))

    def test_the_placement_names_the_first_jobs_only_on_a_feat_push_attempt_1(self):
        jobs = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]
        place = next(step for step in jobs["macos-placement"]["steps"] if step.get("id") == "place")
        expression = place["env"]["FIRST_JOBS"]
        for event, ref, attempt, expected in (("push", "refs/heads/feat-cmux-next", "1", "release-compile"),
                                              ("push", "refs/heads/feat-cmux-next", "2", ""),
                                              ("push", "refs/heads/next-batch/abc", "1", ""),
                                              ("pull_request", "refs/pull/1/merge", "1", "")):
            with self.subTest(event=event, ref=ref, attempt=attempt):
                context = {"github": {"event_name": event, "ref": ref, "run_attempt": attempt}}
                self.assertEqual(evaluate(expression, context), expected)

    def test_a_busy_promotion_mini_sends_the_feat_push_release_compile_to_blacksmith_first(self):
        runs = " swift-canary cmux-scheme-compile release-compile "
        free = {LARGE: 0, SMALL: 0}
        busy = cascade.place(env(CASCADE_RUNS=runs, PROMOTE_LABEL=PROMOTE), (), free, free, promote_busy=True)
        # It gates the nightly-next request, so it goes first; it never counts against an idle side mini.
        self.assertEqual(busy.jobs, none_placed(**{LARGE: ("release-compile", "swift-canary"),
                                                   SMALL: ("cmux-scheme-compile",)}))
        busy = cascade.place(env(CASCADE_RUNS=runs, PROMOTE_LABEL=PROMOTE), ("fast-tier", "swift-canary", "x"),
                             free, free, promote_busy=True)
        self.assertEqual(busy.jobs, none_placed(**{LARGE: ("release-compile",)}))

    def test_a_partly_free_fleet_splits_and_leaves_the_rest_queued(self):
        result = cascade.place(env(), (), {LARGE: 1, SMALL: 5}, {LARGE: 0, SMALL: 0})
        self.assertEqual(result.jobs, none_placed(**{LARGE: ("fast-tier",), SMALL: ("swift-canary",)}))
        self.assertIn("cmux-scheme-compile stay queued on the owned label", result.why)

    def test_the_overflow_counts_the_slots_this_run_just_took(self):
        # The pool had one 6 vCPU job's room and this run's fast-tier took it: the overflow has none left.
        result = cascade.place(env(), (), {LARGE: 0, SMALL: 9}, {LARGE: 0, SMALL: 0})
        self.assertEqual(result.jobs, none_placed(**{SMALL: ("fast-tier",)}))
        self.assertEqual(result.retry_runner, "")

    def test_a_feeds_run_never_takes_hosted(self):
        """Leo, 2026-10-27: "THE GITHUB HOSTED MACS / ARE THE SLOWEST THINGS". #25798 sent a DEV daily's compile
        to hosted macos-26 while Blacksmith was full; with hosted free it now keeps the owned label."""
        full = {LARGE: 5, SMALL: 10}
        seen = cascade.Seen(waits={LARGE: 0.0, SMALL: 0.0})
        dev = env(CASCADE_RUNS=" cmux-scheme-compile ", FRESH_JOBS="cmux-scheme-compile")
        self.assertEqual(cascade.place(dev, (), full, {LARGE: 0, SMALL: 0}, seen).jobs, none_placed())
        # A PR's scheme compile keeps the owned label too.
        self.assertEqual(cascade.place(env(CASCADE_RUNS=" cmux-scheme-compile "), (), full, {LARGE: 0, SMALL: 0},
                                       seen).jobs, none_placed())
        # Neither a feed's run nor a PR's run sends a job to hosted macos-26: the cascade has no hosted route.
        both = " fast-tier swift-canary cmux-scheme-compile "
        self.assertEqual(cascade.place(env(CASCADE_RUNS=both, FRESH_JOBS="cmux-scheme-compile"), (), full,
                                       {LARGE: 0, SMALL: 0}, seen).jobs, none_placed())
        self.assertEqual(cascade.place(env(CASCADE_RUNS=both), (), full, {LARGE: 0, SMALL: 0}, seen).jobs,
                         none_placed())
        # A free Blacksmith slot still comes first.
        self.assertEqual(cascade.place(dev, (), {LARGE: 0, SMALL: 0}, {LARGE: 0, SMALL: 0}, seen).jobs,
                         none_placed(**{LARGE: ("cmux-scheme-compile",)}))
        # A push's Release compile, whose runs-on reads no hosted route, still takes 6 vCPU unread.
        push = env(CASCADE_RUNS=" release-compile ", FRESH_JOBS="release-compile")
        self.assertEqual(cascade.place(push, (), None, None).jobs, none_placed(**{SMALL: ("release-compile",)}))

    def test_unread_counts_place_nothing(self):
        self.assertEqual(cascade.place(env(), (), None, None).jobs, none_placed())
        result = cascade.place(env(), (), {LARGE: 0, SMALL: 0}, None)
        self.assertEqual(result.jobs, none_placed())
        # Without the queue count no slot is known free: the overflow keeps the owned label.
        self.assertEqual(result.retry_runner, "")

    def test_unread_counts_send_a_feeds_compile_to_the_last_resort(self):
        """2026-10-26: the route token read 403 and the snapshot was stale, so DEV daily 40415036753's Release
        compile (cmux-scheme-compile) queued on the owned label behind ~260 jobs and the DEV feed fell 100
        minutes behind. A feed's compile (FRESH_JOBS) takes 6 vCPU when the counts cannot be read."""
        dev = env(CASCADE_RUNS=" cmux-scheme-compile ", FRESH_JOBS="cmux-scheme-compile")
        for live, waiting in ((None, None), ({LARGE: 0, SMALL: 0}, None)):
            with self.subTest(live=live, waiting=waiting):
                # A DEV compile takes 6 vCPU too, never hosted macos-26 (Leo, 2026-10-27: hosted Macs are the
                # slowest); a stalled 6 vCPU queue keeps it on the owned label (below).
                result = cascade.place(dev, (), live, waiting)
                self.assertEqual(result.jobs, none_placed(**{SMALL: ("cmux-scheme-compile",)}))
                self.assertEqual(result.retry_runner, "")
                self.assertIn(f"take `{SMALL}`", result.why)
        push = env(CASCADE_RUNS=" fast-tier cmux-scheme-compile release-compile ", FRESH_JOBS="release-compile")
        self.assertEqual(cascade.place(push, (), None, None).jobs, none_placed(**{SMALL: ("release-compile",)}))
        # An idle mini is spent on the run's other jobs first; as many idle minis as jobs, and nothing moves.
        self.assertEqual(cascade.place(push, ("fast-tier",), None, None).jobs,
                         none_placed(**{SMALL: ("release-compile",)}))
        self.assertEqual(cascade.place(push, ("a", "b", "c"), None, None).jobs, none_placed())
        # A job that does not run here, or a run with no FRESH_JOBS, still places nothing.
        self.assertEqual(cascade.place(env(FRESH_JOBS="release-compile"), (), None, None).jobs, none_placed())
        self.assertEqual(cascade.place(env(), (), None, None).jobs, none_placed())
        # A person's re-run reads nothing and keeps its own route, as before.
        self.assertEqual(cascade.place(env(GITHUB_RUN_ATTEMPT="2", GITHUB_TRIGGERING_ACTOR="teamleaderleo",
                                           FRESH_JOBS="cmux-scheme-compile",
                                           CASCADE_RUNS=" cmux-scheme-compile "), (), None, None).jobs,
                         none_placed())

    def test_a_feeds_compile_counts_a_label_stalled_fifteen_minutes_as_full(self):
        """2026-10-27 01:11Z: 92 jobs queued on 6 vCPU (oldest 148 min) and 27 on 12 vCPU (oldest 165 min, no
        runner online). A feed's compile treats a label whose oldest job waited FRESH_STALL_MINUTES as full."""
        minutes = float(cascade.FRESH_STALL_MINUTES)
        stuck = cascade.Seen(waits={LARGE: 0.0, SMALL: minutes})
        moving = cascade.Seen(waits={LARGE: 0.0, SMALL: minutes - 1})
        self.assertEqual(cascade.fresh_stalled(stuck.waits), (SMALL,))
        self.assertEqual(cascade.fresh_stalled(moving.waits), ())
        # One rule (simple_pool_picker.blacksmith_stalled): the same wait stalls the label for every job.
        self.assertEqual(cascade.FRESH_STALL_MINUTES, cascade.STALL_MINUTES)
        live, waiting = {LARGE: 0, SMALL: 4}, {LARGE: 0, SMALL: 1}
        self.assertEqual(cascade.stalled(live, waiting, stuck.waits), (SMALL,))
        self.assertEqual(cascade.stalled(live, waiting, moving.waits), ())
        self.assertEqual(cascade.place(env(CASCADE_RUNS=" fast-tier "), (), live, waiting, moving).jobs,
                         none_placed(**{SMALL: ("fast-tier",)}))
        # A DEV daily's compile and a push's Release compile both stay on the owned label, never hosted.
        dev = env(CASCADE_RUNS=" cmux-scheme-compile ", FRESH_JOBS="cmux-scheme-compile")
        self.assertEqual(cascade.place(dev, (), live, waiting, stuck).jobs, none_placed())
        self.assertEqual(cascade.place(dev, (), live, waiting, moving).jobs,
                         none_placed(**{SMALL: ("cmux-scheme-compile",)}))
        push = env(CASCADE_RUNS=" release-compile ", FRESH_JOBS="release-compile")
        self.assertEqual(cascade.place(push, (), live, waiting, stuck).jobs, none_placed())
        self.assertEqual(cascade.place(push, (), live, waiting, moving).jobs,
                         none_placed(**{SMALL: ("release-compile",)}))
        # Runner groups unread: the last resort skips a stalled 6 vCPU queue the snapshot saw.
        result = cascade.place(push, (), None, None, stuck)
        self.assertEqual(result.jobs, none_placed())
        self.assertIn("no job leaves the minis' queue", result.why)
        self.assertEqual(cascade.place(push, (), None, None, moving).jobs, none_placed(**{SMALL: ("release-compile",)}))
        self.assertEqual(cascade.place(dev, (), None, None, stuck).jobs, none_placed())
        # The overflow skips the stalled label, a feed's compile and every other run's alike (one rule).
        free = {LARGE: 0, SMALL: 2}, {LARGE: 0, SMALL: 1}
        self.assertEqual(cascade.place(push, ("release-compile",), *free, stuck).retry_runner, "")
        self.assertEqual(cascade.place(env(CASCADE_RUNS=" fast-tier "), ("fast-tier",), *free, stuck).retry_runner, "")
        self.assertEqual(cascade.place(env(CASCADE_RUNS=" fast-tier "), ("fast-tier",), *free, moving).retry_runner,
                         SMALL)
        self.assertEqual(cascade.place(push, (), live, waiting, stuck).fresh_stall, (SMALL,))
        self.assertEqual(cascade.place(push, (), None, None, stuck).fresh_stall, (SMALL,))
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "out"
            cascade.write(cascade.place(push, (), live, waiting, stuck), {"GITHUB_OUTPUT": str(output)})
            self.assertIn(f"fresh_stalled= {SMALL} \n", output.read_text(encoding="utf-8"))

    def test_queued_freshness_work_keeps_a_blacksmith_label_for_feed_compiles(self):
        """2026-10-26: nightly-next's build-sign-notarize-nightly queued on blacksmith-6vcpu-macos-26 from 19:38Z
        behind 68 PR compiles. While the snapshot shows release or nightly work queued for a label
        (`reserved_queued`), a PR's jobs take no slot there, nor its overflow, and a feed's compile still does."""
        snap = snapshot(large=1, small=1)
        snap["pools"][LARGE]["reserved_queued"] = snap["pools"][SMALL]["reserved_queued"] = 1
        found = cascade.seen(snap, NOW)
        self.assertEqual(found.reserved, {LARGE: 1, SMALL: 1})
        free, waiting = {LARGE: 0, SMALL: 0}, {LARGE: 1, SMALL: 1}
        pr = cascade.place(env(CASCADE_RUNS=" cmux-scheme-compile release-compile "), (), free, waiting, found)
        self.assertEqual(pr.jobs, none_placed())
        self.assertEqual(pr.retry_runner, "")
        self.assertIn("freshness work is queued", pr.why)
        dev = cascade.place(env(CASCADE_RUNS=" cmux-scheme-compile ", FRESH_JOBS="cmux-scheme-compile"), (), free,
                            waiting, found)
        self.assertEqual(sum(len(jobs) for jobs in dev.jobs.values()), 1)
        self.assertIn("cmux-scheme-compile", dev.jobs[LARGE] + dev.jobs[SMALL])
        # A label with no freshness work queued is open to PR jobs as before.
        clear = cascade.seen(snapshot(large=1, small=1), NOW)
        self.assertEqual(clear.reserved, {})
        self.assertNotEqual(cascade.place(env(CASCADE_RUNS=" release-compile "), (), free, waiting, clear).jobs,
                            none_placed())

    def test_a_feeds_compile_leads_the_runs_other_jobs(self):
        dev = env(CASCADE_RUNS=" fast-tier swift-canary cmux-scheme-compile ", FRESH_JOBS="cmux-scheme-compile")
        result = cascade.place(dev, (), {LARGE: 4, SMALL: 0}, {LARGE: 0, SMALL: 0})
        self.assertEqual(result.jobs, none_placed(**{LARGE: ("cmux-scheme-compile",)}))

    def test_the_placement_names_the_fresh_jobs_on_attempt_1_of_a_feed_run_only(self):
        jobs = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]
        place = next(step for step in jobs["macos-placement"]["steps"] if step.get("id") == "place")
        expression = place["env"]["FRESH_JOBS"]
        for event, ref, attempt, dev_daily, expected in (
                ("push", "refs/heads/feat-cmux-next", "1", False, "release-compile"),
                ("push", "refs/heads/feat-cmux-next", "2", False, ""),
                ("push", "refs/heads/next-batch/abc", "1", False, ""),
                ("workflow_dispatch", "refs/heads/feat-cmux-next", "1", True, "cmux-scheme-compile"),
                ("workflow_dispatch", "refs/heads/feat-cmux-next", "2", True, ""),
                ("workflow_dispatch", "refs/heads/feat-cmux-next", "1", False, ""),
                ("pull_request", "refs/pull/1/merge", "1", False, "")):
            with self.subTest(event=event, ref=ref, attempt=attempt, dev_daily=dev_daily):
                context = {"github": {"event_name": event, "ref": ref, "run_attempt": attempt},
                           "inputs": {"dev_daily": dev_daily}}
                self.assertEqual(evaluate(expression, context), expected)

    def test_only_attempt_1_of_an_owned_side_label_cascades(self):
        free = {LARGE: 0, SMALL: 0}
        for overrides in ({"GITHUB_RUN_ATTEMPT": "2"}, {"SIDE_LABEL": "blacksmith-6vcpu-macos-26"}, {"SIDE_LABEL": ""}):
            with self.subTest(**overrides):
                self.assertEqual(cascade.place(env(**overrides), (), free, free).jobs, none_placed())

    def test_a_skipped_run_reads_nothing(self):
        pool = mock.Mock()
        with mock.patch.object(cascade, "Api") as api:
            self.assertEqual(cascade.read(env(GITHUB_RUN_ATTEMPT="2", ROUTE_TOKEN="t", SNAPSHOT_TOKEN="s",
                                              GITHUB_REPOSITORY="manaflow-ai/cmux"), pool, now=NOW), (None, None, None))
        api.assert_not_called()
        pool.GitHub.assert_not_called()

    def test_reads_fail_closed(self):
        pool = mock.Mock()
        pool.GitHub.return_value.snapshot.return_value = snapshot(large=1, oldest={"large": 3})
        live_env = env(ROUTE_TOKEN="t", SNAPSHOT_TOKEN="s", GITHUB_REPOSITORY="manaflow-ai/cmux")
        with mock.patch.object(cascade.Api, "in_flight", return_value={LARGE: 2, SMALL: 3}):
            self.assertEqual(cascade.read(live_env, pool, now=NOW, log=lambda _: None),
                             ({LARGE: 2, SMALL: 3}, {LARGE: 1, SMALL: 0},
                              cascade.Seen(waits={LARGE: 5.0, SMALL: 0.0}, age=2.0)))
        # A refused runner read (the route token's 403s, 2026-10-26 22:47Z) is not replaced by the snapshot,
        # which counts only this repository's share of the organization's pool.
        # Its waits are still read, so a feed's compile can skip a stalled queue (fresh_stalled()).
        with mock.patch.object(cascade.Api, "in_flight", side_effect=OSError("HTTP Error 403: Forbidden")):
            self.assertEqual(cascade.read(live_env, pool, now=NOW, log=lambda _: None),
                             (None, None, cascade.Seen(waits={LARGE: 5.0, SMALL: 0.0}, age=2.0)))
        # cmux-bot's token (ROUTE_TOKEN_FALLBACK) reads again when the routing App's read is refused.
        tokens = []

        def in_flight(api):
            tokens.append(api.route_token)
            if api.route_token == "t":
                raise OSError("HTTP Error 403: Forbidden")
            return {LARGE: 2, SMALL: 3}

        with mock.patch.object(cascade.Api, "in_flight", autospec=True, side_effect=in_flight):
            live, waiting, _ = cascade.read({**live_env, "ROUTE_TOKEN_FALLBACK": "bot"}, pool, now=NOW,
                                            log=lambda _: None)
        self.assertEqual((tokens, live, waiting), (["t", "bot"], {LARGE: 2, SMALL: 3}, {LARGE: 1, SMALL: 0}))
        tokens.clear()
        with mock.patch.object(cascade.Api, "in_flight", autospec=True, side_effect=in_flight):
            cascade.read({**live_env, "ROUTE_TOKEN": "ok", "ROUTE_TOKEN_FALLBACK": "bot"}, pool, now=NOW,
                         log=lambda _: None)
        self.assertEqual(tokens, ["ok"])
        pool.GitHub.return_value.snapshot.side_effect = OSError("boom")
        with mock.patch.object(cascade.Api, "in_flight", return_value={LARGE: 2, SMALL: 3}):
            self.assertEqual(cascade.read(live_env, pool, now=NOW, log=lambda _: None),
                             ({LARGE: 2, SMALL: 3}, None, None))

    def test_the_reads_hit_the_scale_set_groups_and_the_snapshot(self):
        calls = []
        groups = {"runner_groups": [{"id": 15, "name": f"Blacksmith scale sets - {LARGE}"},
                                    {"id": 10, "name": f"Blacksmith scale sets - {SMALL}"}]}
        runners = {15: [{"status": "online"}] * 3, 10: [{"status": "online"}, {"status": "offline"}]}

        def get(_self, path):
            calls.append(path)
            if "/runner-groups?" in path:
                return groups
            return {"runners": runners[int(path.split("/runner-groups/")[1].split("/")[0])]}

        class Snapshots:
            def __init__(self, token, repository):
                self.token, self.repository = token, repository

            def snapshot(self, *, now, branch="main"):  # pr_runner_pool.GitHub.snapshot's signature
                calls.append(("snapshot", self.token, self.repository))
                return snapshot(large=2)

        pool = mock.Mock(GitHub=Snapshots)
        with mock.patch.object(cascade.Api, "_get", get):
            live, waiting, seen = cascade.read(env(ROUTE_TOKEN="route", SNAPSHOT_TOKEN="gh",
                                                   GITHUB_REPOSITORY="manaflow-ai/cmux"), pool, now=NOW)
        self.assertEqual((live, waiting), ({LARGE: 3, SMALL: 1}, {LARGE: 2, SMALL: 0}))
        self.assertEqual(seen, cascade.Seen(waits={LARGE: 2.0, SMALL: 0.0}, age=2.0))
        self.assertEqual(calls, ["/orgs/manaflow-ai/actions/runner-groups?per_page=100&visible_to_repository=cmux",
                                 "/orgs/manaflow-ai/actions/runner-groups/15/runners?per_page=100",
                                 "/orgs/manaflow-ai/actions/runner-groups/10/runners?per_page=100",
                                 ("snapshot", "gh", "manaflow-ai/cmux")])

    def test_slow_group_reads_skip_the_snapshot(self):
        pool = mock.Mock()
        ticks = iter([0.0, cascade.READ_BUDGET_SECONDS + 1])
        with mock.patch.object(cascade.Api, "in_flight", return_value={LARGE: 0, SMALL: 0}):
            result = cascade.read(env(ROUTE_TOKEN="t", SNAPSHOT_TOKEN="s", GITHUB_REPOSITORY="manaflow-ai/cmux"),
                                  pool, now=NOW, log=lambda _: None, clock=lambda: next(ticks))
        self.assertEqual(result, ({LARGE: 0, SMALL: 0}, None, None))
        pool.GitHub.assert_not_called()

    def test_side_lane_placement_writes_the_cascade_outputs(self):
        runners = [{"name": "mini", "status": "online", "busy": False,
                    "labels": [{"name": label} for label in ("self-hosted", "glaeda-light-xcode-26.6", SIDE)]}]
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "out"
            fake = mock.Mock()
            fake.return_value.runners.return_value = runners
            with mock.patch.object(placement.pool, "GitHub", fake), \
                    mock.patch.object(placement.cascade, "read",
                                      return_value=({LARGE: 0, SMALL: 7}, {LARGE: 0, SMALL: 0}, None)):
                placement.main(env(ROUTE_TOKEN="t", GITHUB_REPOSITORY="manaflow-ai/cmux", GITHUB_OUTPUT=str(output)))
            lines = dict(line.split("=", 1) for line in output.read_text().splitlines())
        # The idle mini takes the first job; the pool's 18 free vCPU take one 12 vCPU job, then one 6 vCPU job.
        self.assertEqual(lines["owned_jobs"], " fast-tier ")
        self.assertEqual(lines["blacksmith_12_jobs"], " swift-canary ")
        self.assertEqual(lines["blacksmith_6_jobs"], " cmux-scheme-compile ")
        self.assertEqual(lines["retry_runner"], "")
        self.assertEqual(lines["retry_jobs"], "")
        self.assertNotIn("hosted_jobs", lines)

    def test_side_lane_placement_reads_the_promotion_minis_load(self):
        side = {"name": "side-mini", "status": "online", "busy": True,
                "labels": [{"name": label} for label in ("self-hosted", "glaeda-light-xcode-26.6", SIDE)]}

        def outputs(promote_busy: bool | None, **extra: str) -> dict:
            runners = [side]
            if promote_busy is not None:
                runners.append({"name": "cmux14-glaeda", "status": "online", "busy": promote_busy,
                                "labels": [{"name": label} for label in
                                           ("self-hosted", "glaeda-promote-trusted-std-xcode-26.6", PROMOTE)]})
            with tempfile.TemporaryDirectory() as tmp:
                output = Path(tmp) / "out"
                fake = mock.Mock()
                fake.return_value.runners.return_value = runners
                with mock.patch.object(placement.pool, "GitHub", fake), \
                        mock.patch.object(placement.cascade, "read",
                                          return_value=({LARGE: 0, SMALL: 0}, {LARGE: 0, SMALL: 0}, None)):
                    placement.main(env(ROUTE_TOKEN="t", GITHUB_REPOSITORY="manaflow-ai/cmux", GITHUB_OUTPUT=str(output),
                                       CASCADE_RUNS=" release-compile ", **extra))
                return dict(line.split("=", 1) for line in output.read_text().splitlines())

        # A feat-cmux-next push (PROMOTE_LABEL set) with the promotion mini busy: Blacksmith 12 vCPU.
        self.assertEqual(outputs(True, PROMOTE_LABEL=PROMOTE)["blacksmith_12_jobs"], " release-compile ")
        # No online promotion runner at all (the mini is down) overflows the same way.
        self.assertEqual(outputs(None, PROMOTE_LABEL=PROMOTE)["blacksmith_12_jobs"], " release-compile ")
        # An idle promotion mini keeps it.
        self.assertEqual(outputs(False, PROMOTE_LABEL=PROMOTE)["blacksmith_12_jobs"], "")
        # Any other run (no promotion label) cascades it as a side job: the side mini is busy.
        self.assertEqual(outputs(False)["blacksmith_12_jobs"], " release-compile ")

    def test_dedicated_nightly_builder_gets_release_compile_before_blacksmith(self):
        side = {"name": "side-mini", "status": "online", "busy": True,
                "labels": [{"name": label} for label in ("self-hosted", "glaeda-light-xcode-26.6", SIDE)]}
        dedicated = {"name": "cmux22", "status": "online", "busy": False,
                     "labels": [{"name": label} for label in
                                ("self-hosted", "glaeda-trusted-light-xcode-26.6",
                                 "glaeda-runner-cmux22-nightly-next", "glaeda-trusted-next-nightly")]}

        def run(busy: bool):
            dedicated_copy = {**dedicated, "busy": busy}
            with tempfile.TemporaryDirectory() as tmp:
                output = Path(tmp) / "out"
                fake = mock.Mock()
                fake.return_value.runners.return_value = [side, dedicated_copy]
                with mock.patch.object(placement.pool, "GitHub", fake), \
                        mock.patch.object(placement.cascade, "read",
                                          return_value=({LARGE: 0, SMALL: 0}, {LARGE: 0, SMALL: 0}, None)):
                    placement.main(env(ROUTE_TOKEN="t", GITHUB_REPOSITORY="manaflow-ai/cmux",
                                       GITHUB_OUTPUT=str(output), CASCADE_RUNS=" release-compile ",
                                       PROMOTE_LABEL=PROMOTE,
                                       NIGHTLY_POOL="glaeda-trusted-light-xcode-26.6",
                                       NIGHTLY_RUNNER="glaeda-runner-cmux22-nightly-next"))
                return dict(line.split("=", 1) for line in output.read_text().splitlines())

        ready = run(False)
        self.assertEqual(ready["nightly_runner_ready"], "true")
        self.assertEqual(ready["blacksmith_12_jobs"], "")
        overflow = run(True)
        self.assertEqual(overflow["nightly_runner_ready"], "")
        self.assertEqual(overflow["blacksmith_12_jobs"], " release-compile ")


class Stall(unittest.TestCase):
    """A Blacksmith label whose queue is not moving gets no job; the overflow stays on the owned label."""

    # Run 39409184395's placement, 2026-10-20 10:38Z, during Blacksmith's macOS start delay:
    # neither label had a runner online, 12 vCPU's oldest queued job had waited 41 min,
    # and the cascade still sent fast-tier to 12 vCPU, where it never started.
    INCIDENT_LIVE = {LARGE: 0, SMALL: 0}
    INCIDENT_QUEUED = {LARGE: 4, SMALL: 6}

    def incident_seen(self):
        return cascade.Seen(waits={LARGE: 46.0, SMALL: 13.0})

    def test_seen_reads_each_labels_wait_by_now(self):
        shot = snapshot(5, oldest={"large": 41, "small": 8}, hosted=(1, 2), large=3, small=6)
        shot["pools"]["macos-15"] = {"queued": 0, "running": 1}
        shot["pools"]["blacksmith-6vcpu-macos-15"] = {"queued": 4, "running": 3}
        seen = cascade.seen(shot, NOW)
        # The oldest job has waited the snapshot's age longer by now; a hosted macOS pool counts for nothing.
        self.assertEqual(seen, cascade.Seen(waits={LARGE: 46.0, SMALL: 13.0}, age=5.0))
        # An empty queue has no wait, whatever a stale oldest field says.
        self.assertEqual(cascade.seen(snapshot(5, oldest={"large": 41}), NOW).waits, {LARGE: 0.0, SMALL: 0.0})
        self.assertIsNone(cascade.seen(snapshot(minutes_old=cascade.QUEUE_SNAPSHOT_MINUTES + 1), NOW))
        self.assertIsNone(cascade.seen(None, NOW))

    def test_the_stall_figure_is_the_pickers_one_rule(self):
        """pick-nightly-sign-runner, cmux-next's placement and ci.yml's pick read one stall figure."""
        sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts/ci"))
        import simple_pool_picker

        self.assertEqual(cascade.STALL_MINUTES, simple_pool_picker.BLACKSMITH_STALL_MINUTES)
        self.assertEqual(cascade.STALL_MINUTES, 10)
        # 2026-10-27 06:13Z: both macOS 26 labels queued for hours with 3 running.
        self.assertEqual(cascade.stalled({LARGE: 0, SMALL: 3}, {LARGE: 44, SMALL: 38},
                                         {LARGE: 396.0, SMALL: 359.0}), (LARGE, SMALL))

    def test_a_long_wait_or_an_unserved_queue_is_a_stall(self):
        self.assertEqual(cascade.stalled(self.INCIDENT_LIVE, self.INCIDENT_QUEUED, self.incident_seen().waits),
                         (LARGE, SMALL))
        # Busy but moving: jobs start within minutes.
        self.assertEqual(cascade.stalled({LARGE: 5, SMALL: 3}, {LARGE: 1, SMALL: 1}, {LARGE: cascade.STALL_MINUTES - 1.0, SMALL: 3.0}), ())
        # A queue nobody serves for IDLE_STALL_MINUTES is a stall even before STALL_MINUTES.
        idle = cascade.IDLE_STALL_MINUTES
        self.assertEqual(cascade.stalled({LARGE: 0, SMALL: 2}, {LARGE: 1, SMALL: 1},
                                         {LARGE: float(idle), SMALL: float(idle)}), (LARGE,))
        self.assertEqual(cascade.stalled({LARGE: 0, SMALL: 0}, {LARGE: 1, SMALL: 0},
                                         {LARGE: idle - 1.0, SMALL: 0.0}), ())
        # An idle scale set has no runner online: a job the snapshot saw queued only briefly
        # is not a stall however old the snapshot is (it may have run since).
        self.assertEqual(cascade.stalled({LARGE: 0, SMALL: 0}, {LARGE: 1, SMALL: 0},
                                         {LARGE: cascade.STALL_MINUTES - 1.0, SMALL: 0.0}, age=7.0), ())
        # A runner online does not excuse a queue that has waited STALL_MINUTES.
        self.assertEqual(cascade.stalled({LARGE: 3, SMALL: 0}, {LARGE: 1, SMALL: 0},
                                         {LARGE: float(cascade.STALL_MINUTES), SMALL: 0.0}), (LARGE,))
        # Nothing queued is never a stall.
        self.assertEqual(cascade.stalled({LARGE: 0, SMALL: 0}, {LARGE: 0, SMALL: 0}, {LARGE: 90.0, SMALL: 90.0}), ())

    def test_unread_blacksmith_counts_still_honor_declared_outage(self):
        shot = snapshot(minutes_old=1)
        shot["bs_health"] = {"label_outages": [{"pool": SMALL, "queued": 3,
                                                    "last_start_s": 1900}]}
        seen = cascade.Seen(waits={LARGE: 0.0, SMALL: 0.0}, snapshot=shot, observed_at=NOW)
        result = cascade.place(env(), (), None, {LARGE: 0, SMALL: 3}, seen)
        self.assertEqual(result.jobs, none_placed())
        self.assertIn("could not be read", result.why)

    def test_the_incident_sends_nothing_to_blacksmith_or_hosted(self):
        result = cascade.place(env(), (), self.INCIDENT_LIVE, self.INCIDENT_QUEUED, self.incident_seen())
        self.assertEqual(result.jobs, none_placed())
        self.assertIn("fast-tier, swift-canary, cmux-scheme-compile stay queued on the owned label", result.why)
        self.assertIn("stalled", result.why)
        self.assertNotIn(f"`{HOSTED}`", result.why)

    def test_a_full_blacksmith_keeps_the_owned_label(self):
        # Free, moving Blacksmith slots come first.
        result = cascade.place(env(), (), {LARGE: 0, SMALL: 0}, {LARGE: 0, SMALL: 0},
                               cascade.Seen(waits={LARGE: 0.0, SMALL: 0.0}))
        self.assertEqual(result.jobs, none_placed(**{LARGE: ("fast-tier", "swift-canary"),
                                                     SMALL: ("cmux-scheme-compile",)}))
        # A full but moving fleet places nothing: the jobs wait behind the fleet on the owned label, never on
        # GitHub-hosted macos-26 (Leo, 2026-10-27: "THE GITHUB HOSTED MACS / ARE THE SLOWEST THINGS").
        result = cascade.place(env(), (), {LARGE: 5, SMALL: 10}, {LARGE: 0, SMALL: 0},
                               cascade.Seen(waits={LARGE: 0.0, SMALL: 0.0}))
        self.assertEqual(result.jobs, none_placed())

    def test_the_cascade_has_no_hosted_route(self):
        for name in ("HOSTED", "HOSTED_CAPACITY", "HOSTED_JOBS"):
            self.assertFalse(hasattr(cascade, name), name)
        self.assertEqual(cascade.LABELS, (LARGE, SMALL))
        self.assertTrue(all(label.startswith("blacksmith-") for label in cascade.LABELS))

    def test_without_the_snapshots_waits_nothing_changes(self):
        # Fail toward the current behavior: no stall known, no hosted spill.
        result = cascade.place(env(), (), {LARGE: 4, SMALL: 0}, {LARGE: 0, SMALL: 0}, None)
        self.assertEqual(result.jobs, none_placed(**{LARGE: ("fast-tier",)}))

    def test_the_bots_overflow_avoids_a_stalled_label(self):
        live, waiting = {LARGE: 0, SMALL: 9}, {LARGE: 1, SMALL: 0}
        # A job already waits on 12 vCPU, so the overflow takes the pool's last 6 vCPU job instead.
        self.assertEqual(cascade.retry_label(live, waiting), SMALL)
        seen = cascade.Seen(waits={LARGE: 30.0, SMALL: 0.0})
        self.assertEqual(cascade.place(env(), (), {LARGE: 0, SMALL: 5}, waiting, seen).retry_runner, SMALL)
        # The one free 6 vCPU slot goes to this run's fast-tier, so no label is left for the overflow.
        self.assertEqual(cascade.place(env(), (), live, waiting, seen).retry_runner, "")
        # Both stalled: no Blacksmith label; the overflow waits on the owned label.
        both = cascade.Seen(waits={LARGE: 30.0, SMALL: 30.0})
        self.assertEqual(cascade.place(env(), (), live, {LARGE: 1, SMALL: 1}, both).retry_runner, "")

    def test_no_job_reads_a_hosted_route(self):
        text = WORKFLOW.read_text(encoding="utf-8")
        for key in ("hosted_jobs", "hosted_runner"):
            self.assertNotIn(f"outputs.{key}", text)
        jobs = yaml.safe_load(text)["jobs"]
        # The fast tier and the canary keep their own budget: no cold hosted build needs 45 minutes.
        # (Five while it only reports its build-fleet client's verdict: GatewayRunsOnlyTheFleetClient.)
        fast = jobs["fast-tier"]["timeout-minutes"]
        self.assertEqual(evaluate(fast, {"needs": {"fast-tier-fleet": {"result": "skipped"}}}), 20)
        canary = jobs["swift-canary"]["timeout-minutes"]
        self.assertEqual(evaluate(canary, {"needs": {"swift-canary-fleet": {"outputs": {"verdict": ""}}}}), 20)
        self.assertEqual(jobs["cmux-scheme-compile"]["timeout-minutes"], 60)

    def test_the_placement_writes_no_hosted_route(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "out"
            placed = cascade.place(env(), (), self.INCIDENT_LIVE, self.INCIDENT_QUEUED, self.incident_seen())
            cascade.write(placed, {"GITHUB_OUTPUT": str(output)})
            lines = dict(line.split("=", 1) for line in output.read_text().splitlines())
        self.assertNotIn("hosted_jobs", lines)
        self.assertNotIn("hosted_runner", lines)
        self.assertNotIn(HOSTED, lines.values())
        self.assertEqual((lines["blacksmith_12_jobs"], lines["blacksmith_6_jobs"]), ("", ""))


class FeedNeverHosted(unittest.TestCase):
    """Leo, 2026-10-27: "THE GITHUB HOSTED MACS / ARE THE SLOWEST THINGS". No DEV, nightly or promote path
    resolves to hosted macos-26: a run with FRESH_JOBS places nothing there, whatever Blacksmith's state."""

    def test_no_feed_run_places_a_job_on_hosted(self):
        runs = " fast-tier swift-canary cmux-scheme-compile release-compile swift-test daemon-test generated-files "
        waits = (0.0, float(cascade.FRESH_STALL_MINUTES), float(cascade.STALL_MINUTES) + 60)
        counts = (None, ({LARGE: 0, SMALL: 0}, None), ({LARGE: 0, SMALL: 0}, {LARGE: 0, SMALL: 0}),
                  ({LARGE: 5, SMALL: 10}, {LARGE: 0, SMALL: 0}), ({LARGE: 0, SMALL: 0}, {LARGE: 9, SMALL: 40}))
        for fresh in ("cmux-scheme-compile", "release-compile"):
            for count in counts:
                live, waiting = count if count is not None else (None, None)
                for large, small in ((a, b) for a in waits for b in waits):
                    for owned in ((), ("fast-tier",)):
                        seen = cascade.Seen(waits={LARGE: large, SMALL: small})
                        with self.subTest(fresh=fresh, live=live, waiting=waiting, waits=(large, small), owned=owned):
                            placed = cascade.place(env(CASCADE_RUNS=runs, FRESH_JOBS=fresh), owned, live, waiting,
                                                   seen)
                            self.assertEqual(placed.jobs.get(HOSTED, ()), ())
                            self.assertFalse(set(placed.jobs.get(HOSTED, ())) & set(cascade.CASCADE_JOBS))

    def test_no_feed_compile_reads_the_hosted_route(self):
        jobs = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]
        for name in ("cmux-scheme-compile", "release-compile"):
            with self.subTest(job=name):
                self.assertNotIn("hosted_runner", str(jobs[name]["runs-on"]))
                self.assertNotIn("hosted_jobs", str(jobs[name]["runs-on"]))
                self.assertNotIn("hosted", str(jobs[name].get("env", {}).get("CMUX_NEXT_RUNNER", "")))
                self.assertNotIn("hosted_jobs", str(jobs[name].get("timeout-minutes", "")))


class Rerun(unittest.TestCase):
    """The rescue's full re-run (attempt 2 by github-actions[bot]) is placed afresh.

    Until 2026-10-26 every attempt after 1 skipped the placement's steps, so the re-run's outputs were
    empty and its cascade jobs rejoined the end of the side queue they had waited in. Run 40287033454's
    DEV Release compile (DEV daily 7cf3398a) waited on glaeda-side-std-xcode-26.6 from 07:39Z and a
    mini refused it at 08:02Z; a re-run would have queued there again.
    """

    RUNS = " cmux-scheme-compile "

    def rerun(self, **overrides: str) -> dict:
        return env(**{"CASCADE_RUNS": self.RUNS, "GITHUB_RUN_ATTEMPT": "2", "GITHUB_TRIGGERING_ACTOR": BOT,
                      **overrides})

    def test_the_rescues_attempt_2_reads_what_is_free_now(self):
        live, waiting = {LARGE: 0, SMALL: 5}, {LARGE: 0, SMALL: 0}
        self.assertTrue(cascade.bot_rerun(self.rerun()))
        self.assertEqual(cascade.skipped(self.rerun()), "")
        result = cascade.place(self.rerun(), (), live, waiting)
        self.assertEqual(result.jobs, none_placed(**{LARGE: ("cmux-scheme-compile",)}))
        self.assertIn("the rescue's re-run (attempt 2) is placed afresh", result.why)
        # The same pool rule as attempt 1: with a queue, 6 vCPU; with no room, the owned label.
        self.assertEqual(cascade.place(self.rerun(), (), live, {LARGE: 0, SMALL: 1}).jobs,
                         none_placed(**{SMALL: ("cmux-scheme-compile",)}))
        self.assertEqual(cascade.place(self.rerun(), (), {LARGE: 0, SMALL: 10}, waiting).jobs, none_placed())

    def test_a_persons_rerun_and_later_attempts_keep_their_route(self):
        free = {LARGE: 0, SMALL: 0}
        for attempt, actor in (("2", "teamleaderleo"), ("3", BOT), ("2", "")):
            with self.subTest(attempt=attempt, actor=actor):
                overrides = self.rerun(GITHUB_RUN_ATTEMPT=attempt, GITHUB_TRIGGERING_ACTOR=actor)
                self.assertFalse(cascade.bot_rerun(overrides))
                # Attempt 3 by the bot too: it is the rescue's last overflow attempt, not a fresh placement.
                self.assertEqual(cascade.skipped(overrides), "a person re-run keeps its own route")
                self.assertEqual(cascade.place(overrides, (), free, free).jobs, none_placed())

    def test_an_idle_mini_still_comes_first_on_the_rerun(self):
        # A re-run job no Blacksmith label lists takes the overflow label before the side label, so while
        # an idle mini would take one the overflow is empty and that job takes the side label.
        runs = " fast-tier cmux-scheme-compile "
        free = {LARGE: 0, SMALL: 0}
        result = cascade.place(self.rerun(CASCADE_RUNS=runs), ("fast-tier",), free, free)
        self.assertEqual(result.jobs, none_placed(**{LARGE: ("cmux-scheme-compile",)}))
        self.assertEqual(result.retry_runner, "")
        self.assertIn("an idle mini takes the re-run", result.why)
        # With no idle mini the overflow is the free label, as on attempt 1.
        self.assertEqual(cascade.place(self.rerun(CASCADE_RUNS=runs), (), free, free).retry_runner, SMALL)

    def placement_job(self) -> dict:
        return yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]["macos-placement"]

    def route_context(self, attempt: str, actor: str) -> dict:
        context = github_context("workflow_dispatch", CI_PR_POOL_OWNED="1", CI_SIDE_LANE_RUNNER=SIDE,
                                 MACOS_RUNNER_26=SMALL)
        context["github"].update(repository="manaflow-ai/cmux", run_attempt=attempt, triggering_actor=actor)
        return context

    def test_the_placement_steps_run_on_the_rescues_rerun_only(self):
        workflow = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
        job = workflow["jobs"]["macos-placement"]
        own, shared = job["env"]["CMUX_NEXT_SIDE_ROUTE"], workflow["env"]["CMUX_NEXT_SIDE_ROUTE"]
        for attempt, actor, expected in (("1", "teamleaderleo", SIDE), ("2", BOT, SIDE),
                                         ("2", "teamleaderleo", SMALL), ("3", BOT, SMALL)):
            with self.subTest(attempt=attempt, actor=actor):
                context = self.route_context(attempt, actor)
                self.assertEqual(evaluate(own, context), expected)
                # Every other case is the workflow's route, which the Mac jobs restate.
                if (attempt, actor) != ("2", BOT):
                    self.assertEqual(evaluate(own, context), evaluate(shared, context))
                # The job itself runs on attempt 1 and the bot's attempt 2.
                self.assertIn("github.run_attempt == 2 && contains(fromJSON('[\"github-actions[bot]\",\"cmux-bot[bot]\"]'), github.triggering_actor)",
                              job["if"])
        place = next(step for step in job["steps"] if step.get("id") == "place")
        self.assertEqual(place["env"]["SIDE_LABEL"], "${{ env.CMUX_NEXT_SIDE_ROUTE }}")

    def test_the_rerun_writes_the_cascade_and_only_its_allocated_side_route(self):
        place = next(step for step in self.placement_job()["steps"] if step.get("id") == "place")
        call = "python3 scripts/ci/side_lane_placement.py\n"
        self.assertEqual(place["run"].count(call), 1)
        shell = place["run"].replace(call, ":\n")
        idle = {"name": "mini", "status": "online", "busy": False,
                "labels": [{"name": label} for label in ("self-hosted", "glaeda-light-xcode-26.6", SIDE)]}
        for attempt, actor in (("2", BOT), ("1", "teamleaderleo")):
            with self.subTest(attempt=attempt), tempfile.TemporaryDirectory() as tmp:
                output = Path(tmp) / "out"
                values = env(ROUTE_TOKEN="t", GITHUB_REPOSITORY="manaflow-ai/cmux", GITHUB_OUTPUT=str(output),
                             GITHUB_RUN_ATTEMPT=attempt, GITHUB_TRIGGERING_ACTOR=actor,
                             CASCADE_RUNS=" swift-canary cmux-scheme-compile ")
                fake = mock.Mock()
                fake.return_value.runners.return_value = [idle]
                with mock.patch.object(placement.pool, "GitHub", fake), \
                        mock.patch.object(placement.cascade, "read",
                                          return_value=({LARGE: 0, SMALL: 0}, {LARGE: 0, SMALL: 0}, None)), \
                        contextlib.redirect_stdout(io.StringIO()):
                    placement.main(values)
                subprocess.run(["bash", "-e", "-c", shell], check=True,
                               env={"PATH": os.environ.get("PATH", "/usr/bin:/bin"), **values})
                lines = dict(line.split("=", 1) for line in output.read_text().splitlines())
                # The idle mini races for the canary; the scheme compile gets 12 vCPU either way.
                self.assertEqual(lines["owned_jobs"], " fast-tier ")
                self.assertEqual(lines["blacksmith_12_jobs"], " cmux-scheme-compile ")
                routes = ("fast_runner", "gateway_runner", "gateway_attempt", "nightly_runner_ready")
                if attempt == "2":
                    # The fast and gateway jobs keep the routes a re-run always had.
                    self.assertEqual({key: lines[key] for key in routes if key in lines}, {})
                    # No GUI or session runner is idle (the mini carries none), so the GUI jobs take Blacksmith.
                    self.assertEqual({key: lines[key] for key in ("gui_runner", "session_runner", "free_gui_runner",
                                                                    "free_session_runner")},
                                     dict.fromkeys(("gui_runner", "session_runner", "free_gui_runner",
                                                    "free_session_runner"), ""))
                    self.assertEqual(lines["gui_overflow"], SMALL)
                    self.assertEqual(lines["retry_runner"], "")
                    self.assertEqual(lines["runner"], SIDE)
                else:
                    self.assertEqual(lines["runner"], SIDE)

    def test_bot_fast_tier_uses_actual_fresh_owned_placement(self):
        idle = {"name": "side-mini", "status": "online", "busy": False,
                "labels": [{"name": label} for label in ("self-hosted", "glaeda-light-xcode-26.6", SIDE)]}
        runs_on = yaml.safe_load(WORKFLOW.read_text())["jobs"]["fast-tier"]["runs-on"]
        for runners, expected in (([idle], SIDE), ([], SMALL)):
            with self.subTest(idle=bool(runners)):
                outputs = self.rerun_outputs(runners, {LARGE: 5, SMALL: 10}, {LARGE: 10, SMALL: 10},
                                             CASCADE_RUNS=" fast-tier ")
                context = self.route_context("2", BOT)
                outputs["placed_attempt"] = evaluate(self.placement_job()["outputs"]["placed_attempt"], context)
                context["needs"] = {"macos-placement": {"outputs": outputs}}
                self.assertEqual(evaluate(runs_on, context), expected)
                outputs["placed_attempt"] = "1"
                self.assertEqual(evaluate(runs_on, context), SIDE)

    def rerun_outputs(self, runners: list, live: dict, waiting: dict, **extra: str) -> dict:
        """placement.main() on the bot's attempt 2, then the step's shell, as the runner runs them."""
        place = next(step for step in self.placement_job()["steps"] if step.get("id") == "place")
        call = "python3 scripts/ci/side_lane_placement.py\n"
        shell = place["run"].replace(call, ":\n")
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "out"
            values = env(**{"ROUTE_TOKEN": "t", "GITHUB_REPOSITORY": "manaflow-ai/cmux",
                            "GITHUB_OUTPUT": str(output), "GITHUB_RUN_ATTEMPT": "2",
                            "GITHUB_TRIGGERING_ACTOR": BOT, **extra})
            fake = mock.Mock()
            fake.return_value.runners.return_value = runners
            with mock.patch.object(placement.pool, "GitHub", fake), \
                    mock.patch.object(placement.cascade, "read", return_value=(live, waiting, None)), \
                    contextlib.redirect_stdout(io.StringIO()):
                placement.main(values)
            subprocess.run(["bash", "-e", "-c", shell], check=True, cwd=ROOT,
                           env={"PATH": os.environ.get("PATH", "/usr/bin:/bin"), **values})
            return dict(line.split("=", 1) for line in output.read_text().splitlines())

    def test_the_rerun_counts_idle_minis_only_on_the_label_it_asks_for(self):
        # Review of #25707: attempt 1 counts a wider class's idle runners (side_route()), but a re-run's
        # cascade jobs fall back to SIDE_LABEL itself, so an idle std mini is no room for a light re-run.
        std = SIDE.replace("-light-", "-std-")
        idle_std = {"name": "std-mini", "status": "online", "busy": False,
                    "labels": [{"name": label} for label in ("self-hosted", "glaeda-std-xcode-26.6", std)]}
        busy_light = {"name": "light-mini", "status": "online", "busy": True,
                      "labels": [{"name": label} for label in ("self-hosted", "glaeda-light-xcode-26.6", SIDE)]}
        free = {LARGE: 0, SMALL: 0}
        lines = self.rerun_outputs([idle_std, busy_light], free, dict(free), CASCADE_RUNS=" cmux-scheme-compile ")
        self.assertEqual(lines["owned_jobs"], "")
        self.assertEqual(lines["blacksmith_12_jobs"], " cmux-scheme-compile ")
        self.assertEqual(lines["runner"], "")

    def test_a_feat_push_rerun_places_no_release_compile(self):
        # Its runs-on reads the placement on attempt 1 only and takes 6 vCPU on a re-run, so a slot
        # placed for it would be spent on nothing.
        free = {LARGE: 0, SMALL: 0}
        runs = " cmux-scheme-compile release-compile "
        push = self.rerun_outputs([], free, dict(free), CASCADE_RUNS=runs, GITHUB_EVENT_NAME="push",
                                  GITHUB_REF="refs/heads/feat-cmux-next")
        self.assertEqual(push["blacksmith_12_jobs"], " cmux-scheme-compile ")
        self.assertEqual(push["blacksmith_6_jobs"], "")
        dispatch = self.rerun_outputs([], free, dict(free), CASCADE_RUNS=runs, GITHUB_EVENT_NAME="workflow_dispatch",
                                      GITHUB_REF="refs/heads/feat-cmux-next")
        self.assertEqual(dispatch["blacksmith_12_jobs"], " cmux-scheme-compile release-compile ")
        jobs = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]
        context = Wiring().context("2", BOT, large=" release-compile ", runner="")
        context["github"].update(event_name="push", ref="refs/heads/feat-cmux-next", event={})
        context["needs"]["release-compile-fast"] = {"result": "skipped", "outputs": {"verdict": ""}}
        self.assertEqual(evaluate(jobs["release-compile"]["runs-on"], context), SMALL)
        # 6 vCPU fresh-stalled (next_macos_cascade.fresh_stalled()): the re-run takes the owned label instead.
        # (A feat-cmux-next push's re-run lists no release-compile on a Blacksmith label, as above.)
        context["needs"]["macos-placement"]["outputs"].update(fresh_stalled=f" {SMALL} ", blacksmith_12_jobs="")
        for key in ("runs-on", "CMUX_NEXT_RUNNER"):
            expression = jobs["release-compile"]["runs-on"] if key == "runs-on" else jobs["release-compile"]["env"][key]
            self.assertEqual(evaluate(expression, context), SIDE, key)
        # The same with the fleet fast check failed with no verdict, and a carried (older) placement keeps 6 vCPU.
        context["needs"]["release-compile-fast"] = {"result": "failure", "outputs": {"verdict": ""}}
        self.assertEqual(evaluate(jobs["release-compile"]["runs-on"], context), SIDE)
        context["needs"]["macos-placement"]["outputs"]["placed_attempt"] = "1"
        self.assertEqual(evaluate(jobs["release-compile"]["runs-on"], context), SMALL)

    def test_a_feat_push_rerun_counts_no_idle_mini_for_release_compile(self):
        # Review of #25707: JOBS lists release-compile first, so an idle mini counted for it left the
        # scheme compile on the owned label with no mini to take it.
        idle = {"name": "light-mini", "status": "online", "busy": False,
                "labels": [{"name": label} for label in ("self-hosted", "glaeda-light-xcode-26.6", SIDE)]}
        free = {LARGE: 0, SMALL: 0}
        push = self.rerun_outputs([idle], free, dict(free), JOBS="release-compile cmux-scheme-compile",
                                  CASCADE_RUNS=" cmux-scheme-compile release-compile ", GITHUB_EVENT_NAME="push",
                                  GITHUB_REF="refs/heads/feat-cmux-next")
        self.assertEqual(push["owned_jobs"], " cmux-scheme-compile ")
        self.assertEqual(push["blacksmith_12_jobs"], "")
        self.assertEqual(push["blacksmith_6_jobs"], "")

    def test_the_rescues_dev_compile_leaves_the_queue_when_counts_are_unread(self):
        # #25739 sends a DEV daily's compile to the last resort (6 vCPU, never hosted) when attempt 1 cannot read the
        # counts; the rescue's attempt 2 is placed afresh, so it reads FRESH_JOBS too, and a person's re-run does not.
        place = next(step for step in self.placement_job()["steps"] if step.get("id") == "place")
        fresh = place["env"]["FRESH_JOBS"]
        context = github_context("workflow_dispatch", ref="refs/heads/feat-cmux-next")
        context["inputs"] = {"dev_daily": True}
        for attempt, actor, expected in (("1", "teamleaderleo", "cmux-scheme-compile"),
                                         ("2", BOT, "cmux-scheme-compile"), ("2", "teamleaderleo", ""),
                                         ("3", BOT, "")):
            with self.subTest(attempt=attempt, actor=actor):
                context["github"].update(run_attempt=attempt, triggering_actor=actor)
                self.assertEqual(evaluate(fresh, context), expected)
        values = self.rerun(JOBS="cmux-scheme-compile", FRESH_JOBS="cmux-scheme-compile")
        placed = cascade.place(values, (), None, None)
        self.assertEqual(placed.jobs[SMALL], ("cmux-scheme-compile",))
        self.assertNotIn(HOSTED, placed.jobs)
        # The workflow's own JOBS, through main(): idle_placement() names the first JOBS (here skipped ones)
        # once per idle mini, so `owned` is the idle-mini count. With no idle mini the compile takes the last
        # resort (6 vCPU); with one, it stays on the side label, where that mini takes it.
        jobs = self.placement_job()["steps"]
        jobs = next(step for step in jobs if step.get("id") == "place")["env"]["JOBS"]
        self.assertTrue(jobs.startswith("fast-tier swift-canary cmux-scheme-compile"))
        idle = {"name": "side-mini", "status": "online", "busy": False,
                "labels": [{"name": label} for label in ("self-hosted", "glaeda-light-xcode-26.6", SIDE)]}
        for runners, small, owned in (([], " cmux-scheme-compile ", ""),
                                     ([idle], "", " fast-tier "),
                                     ([idle, dict(idle, name="side-mini-2")], "", " fast-tier swift-canary ")):
            with self.subTest(idle=len(runners)):
                lines = self.rerun_outputs(runners, None, None, JOBS=jobs, CASCADE_RUNS=" cmux-scheme-compile ",
                                           FRESH_JOBS="cmux-scheme-compile", GITHUB_EVENT_NAME="workflow_dispatch",
                                           GITHUB_REF="refs/heads/feat-cmux-next")
                self.assertEqual(lines["owned_jobs"], owned)
                self.assertNotIn("hosted_jobs", lines)
                self.assertEqual(lines["blacksmith_6_jobs"], small)

    def test_an_older_trusted_placement_writes_nothing_on_the_rerun(self):
        # Review of #25707: the steps check out the base's script. One that predates rerun_main() would
        # write owned, GUI, session and gateway routes on attempt 2; the step's shell runs none of it.
        place = next(step for step in self.placement_job()["steps"] if step.get("id") == "place")
        with tempfile.TemporaryDirectory() as tmp:
            scripts = Path(tmp) / "scripts/ci"
            scripts.mkdir(parents=True)
            (scripts / "side_lane_placement.py").write_text(
                "import os\nopen(os.environ['GITHUB_OUTPUT'], 'a').write('runner=x\\ngui_runner=y\\n')\n")
            output = Path(tmp) / "out"
            output.write_text("")
            for attempt, written in (("2", ""), ("1", "runner=x\ngui_runner=y\n")):
                with self.subTest(attempt=attempt):
                    output.write_text("")
                    subprocess.run(["bash", "-e", "-c", place["run"]], check=True, cwd=tmp, capture_output=True,
                                   env={"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "GITHUB_OUTPUT": str(output),
                                        "GITHUB_RUN_ATTEMPT": attempt, "SIDE_LABEL": SIDE})
                    self.assertEqual(output.read_text(), written)

    def test_a_placement_with_no_gui_decision_sends_the_gui_jobs_to_the_last_resort(self):
        """Review of #28605 at 69c89e2c982: removing the `runner != ''` leg let a placement that names no GUI route
        and no GUI overflow (a trusted base predating the sized gui_overflow, or a runner read that failed closed)
        send attempt 1's GUI jobs to the owned GUI queue. The step's shell names Blacksmith 6 vCPU for them then."""
        workflow = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
        place = next(step for step in workflow["jobs"]["macos-placement"]["steps"] if step.get("id") == "place")
        outputs = workflow["jobs"]["macos-placement"]["outputs"]
        cases = (("runner=\ngui_runner=\ngui_overflow=\n", SMALL), ("", SMALL),
                 (f"gui_runner={GUI}\n", GUI), (f"gui_overflow={LARGE}\n", LARGE))
        with tempfile.TemporaryDirectory() as tmp:
            scripts = Path(tmp) / "scripts/ci"
            scripts.mkdir(parents=True)
            output = Path(tmp) / "out"
            for written, expected in cases:
                with self.subTest(written=written):
                    (scripts / "side_lane_placement.py").write_text(
                        f"import os\nopen(os.environ['GITHUB_OUTPUT'], 'a').write({written!r})\n")
                    output.write_text("")
                    subprocess.run(["bash", "-e", "-c", place["run"]], check=True, cwd=tmp, capture_output=True,
                                   env={"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "GITHUB_OUTPUT": str(output),
                                        "GITHUB_RUN_ATTEMPT": "1", "SIDE_LABEL": SIDE,
                                        "GUI_LAST_RESORT": evaluate(place["env"]["GUI_LAST_RESORT"],
                                                                    self.route_context("1", "teamleaderleo"))})
                    # GitHub keeps an output's last value.
                    step = dict(line.split("=", 1) for line in output.read_text().splitlines())
                    context = self.route_context("1", "teamleaderleo")
                    # Display placement remains in use on pushes; PR jobs use the side cascade.
                    context["github"]["event_name"] = "push"
                    context["needs"] = {"macos-placement": {"outputs": {
                        key: step.get(key, "") for key in ("runner", "gui_runner", "session_runner", "gui_overflow",
                                                           "free_gui_runner", "free_session_runner",
                                                           "session_lane_runner")}}}
                    context["needs"]["macos-placement"]["outputs"]["placed_attempt"] = evaluate(
                        outputs["placed_attempt"], context)
                    for name in ("swift-test", "daemon-test", "generated-files"):
                        self.assertEqual(evaluate(workflow["jobs"][name]["runs-on"], context), expected, name)

    def test_a_rerun_of_failed_jobs_never_takes_a_carried_blacksmith_reading(self):
        """Run 40398277457 (2026-10-26, #25446): the rescue re-ran the failed jobs as attempt 2 by
        github-actions[bot], so macos-placement was carried from attempt 1 (started 20:44:52) with its
        outputs. The Release compile read that 39-minute-old blacksmith_6_jobs, took
        blacksmith-6vcpu-macos-26, sat 55 minutes with no runner and was cancelled by the queue janitor.
        placed_attempt names the attempt a reading belongs to; a carried one routes to the owned label."""
        workflow = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
        self.assertEqual(workflow["jobs"]["macos-placement"]["outputs"]["placed_attempt"], "${{ github.run_attempt }}")
        gate = "needs.macos-placement.outputs.placed_attempt == format('{0}', github.run_attempt)"
        text = WORKFLOW.read_text(encoding="utf-8")
        # Every read of a placement-time Blacksmith or retry reading carries the gate.
        for key in ("blacksmith_12_jobs", "blacksmith_6_jobs", "retry_runner"):
            for match in re.finditer(r"[^|\n]*needs\.macos-placement\.outputs\." + key + r"\b[^|\n]*", text):
                line = text[:match.start()].count("\n") + 1
                with self.subTest(key=key, line=line):
                    self.assertIn(gate, match.group(0))
        wiring = Wiring()
        jobs = workflow["jobs"]
        for name in CASCADED:
            for attempt in ("2", "3", "4"):
                for actor in (BOT, "teamleaderleo"):
                    for key in ("large", "small", "retry", "hosted"):
                        value = {"large": f" {name} ", "small": f" {name} ", "hosted": f" {name} ",
                                 "retry": SMALL}[key]
                        with self.subTest(job=name, attempt=attempt, actor=actor, reading=key):
                            context = wiring.context(attempt, actor, runner="", placed="1", **{key: value})
                            for expression in (jobs[name]["runs-on"], jobs[name].get("env", {}).get("CMUX_NEXT_RUNNER")):
                                if expression is None:
                                    continue
                                # Exactly the label it takes with no reading at all: the owned side label
                                # (attempts 2 and 3), or attempt 4's configured fallback.
                                self.assertEqual(evaluate(expression, context),
                                                 evaluate(expression, wiring.context(attempt, actor, runner="",
                                                                                     placed="1")))
                    # The same reading, fresh (the bot's attempt 2 placed afresh), is taken.
                    if actor == BOT:
                        fresh = wiring.context("2", BOT, runner="", small=f" {name} ")
                        self.assertEqual(evaluate(jobs[name]["runs-on"], fresh), SMALL, name)

    def test_the_rerun_scheme_compile_takes_the_fresh_slot(self):
        jobs = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]
        runs_on = jobs["cmux-scheme-compile"]["runs-on"]
        wiring = Wiring()
        self.assertEqual(evaluate(runs_on, wiring.context("2", BOT, small=" cmux-scheme-compile ", runner="")), SMALL)
        self.assertEqual(evaluate(runs_on, wiring.context("2", BOT, large=" cmux-scheme-compile ", runner="")), LARGE)
        # No slot and no overflow: the owned side label, where an idle mini (or the queue) takes it.
        self.assertEqual(evaluate(runs_on, wiring.context("2", BOT, runner="")), SIDE)


class Wiring(unittest.TestCase):
    def setUp(self):
        self.jobs = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]

    def context(self, attempt: str = "1", actor: str = "teamleaderleo", large: str = "", small: str = "",
                retry: str = "", runner: str = SIDE, fork: bool = False, hosted: str = "",
                placed: str | None = None) -> dict:
        context = github_context("pull_request", ref="refs/pull/1/merge", CI_PR_POOL_OWNED="1",
                                 CI_SIDE_LANE_RUNNER=SIDE, MACOS_RUNNER_26=LARGE)
        context["vars"].pop("MACOS_RUNNER_PR", None)
        head = "someone/cmux" if fork else "manaflow-ai/cmux"
        context["github"].update(repository="manaflow-ai/cmux", run_attempt=attempt, triggering_actor=actor,
                                 event={"pull_request": {"head": {"repo": {"full_name": head}},
                                                         "labels": [{"name": "full-ci"}]}})
        context["needs"] = {"macos-placement": {"outputs": {
            "runner": runner, "gui_runner": GUI if runner else "", "fallback_jobs": "", "owned_jobs": " fast-tier ",
            "blacksmith_12_jobs": large, "blacksmith_6_jobs": small, "retry_runner": retry,
            "retry_jobs": " fast-tier swift-canary cmux-scheme-compile release-compile swift-test daemon-test generated-files " if retry else "",
            "hosted_jobs": hosted, "hosted_runner": HOSTED if hosted else "",
            # The attempt the placement ran in: by default where it really runs (attempt 1, the bot's
            # attempt 2); any other attempt carries attempt 1's job and outputs.
            "placed_attempt": placed if placed is not None else (
                attempt if attempt == "1" or attempt == "2" and actor == BOT else "1")}}}
        return context

    def test_attempt_1_takes_the_blacksmith_slot_the_placement_found(self):
        for name in CASCADED:
            runs_on = self.jobs[name]["runs-on"]
            with self.subTest(job=name):
                # Every cascade job, the PR's Release compile included, takes the slot the placement found:
                # the placement gives one only when no idle mini took the job, and the side label (`runner`)
                # is set whether or not a mini is free, so reading it first is a queue with no way off it.
                self.assertEqual(evaluate(runs_on, self.context(large=f" x {name} ")), LARGE)
                self.assertEqual(evaluate(runs_on, self.context(small=f" {name} y ")), SMALL)
                self.assertEqual(evaluate(runs_on, self.context(runner="", large=f" x {name} ")), LARGE)
                self.assertEqual(evaluate(runs_on, self.context(runner="", small=f" {name} y ")), SMALL)
                # Whole keys only: another job's slot is not this job's.
                self.assertEqual(evaluate(runs_on, self.context(large=f" {name}-x ", small=f" x{name} ")), SIDE)
                self.assertEqual(evaluate(runs_on, self.context()), SIDE)
                # The bot's attempt 2 (the rescue moved a stuck sibling) keeps the slot.
                self.assertEqual(evaluate(runs_on, self.context("2", BOT, large=f" {name} ")), LARGE)
                # A person's later retry cannot reuse the owned label; fast-tier falls to Blacksmith.
                self.assertEqual(evaluate(runs_on, self.context("2", large=f" {name} ")), LARGE if name == "fast-tier" else SIDE)
                self.assertEqual(evaluate(runs_on, self.context("3", large=f" {name} ")), LARGE if name == "fast-tier" else SIDE)
                self.assertEqual(evaluate(runs_on, self.context(fork=True, large=f" {name} ")), SMALL)

    def test_release_compile_pr_takes_an_idle_mini_else_the_placements_blacksmith_slot(self):
        """#25514 read the side label first for a same-repository PR's Release compile, calling it the free
        owned-Mac route. It is the side label busy or not, so on a saturated fleet the compile queued there
        with nothing to move it. An idle mini still comes first: the placement lists the compile for a
        Blacksmith label only when no idle mini took it."""
        runs_on = self.jobs["release-compile"]["runs-on"]
        self.assertEqual(self.jobs["release-compile"]["env"]["CMUX_NEXT_RUNNER"], runs_on)
        side = "glaeda-side-std-xcode-26.6"
        self.assertEqual(evaluate(runs_on, self.context(runner=side)), side)
        self.assertEqual(evaluate(runs_on, self.context(runner=side, large=" release-compile ")), LARGE)
        self.assertEqual(evaluate(runs_on, self.context(runner=side, small=" release-compile ")), SMALL)
        self.assertEqual(evaluate(runs_on, self.context(runner="", large=" release-compile ")), LARGE)

    def test_no_attempt_takes_a_hosted_spill(self):
        """An old placement's hosted_jobs/hosted_runner (a PR on an older base) is never read: the Mac jobs
        route as if it were empty (Leo, 2026-10-27: "THE GITHUB HOSTED MACS / ARE THE SLOWEST THINGS")."""
        for name in CASCADED:
            for expression in (self.jobs[name]["runs-on"], self.jobs[name].get("env", {}).get("CMUX_NEXT_RUNNER")):
                if expression is None:
                    continue
                with self.subTest(job=name):
                    self.assertEqual(evaluate(expression, self.context(hosted=f" x {name} ")),
                                     evaluate(expression, self.context()))
                    self.assertEqual(evaluate(expression, self.context("2", BOT, hosted=f" {name} ")),
                                     evaluate(expression, self.context("2", BOT)))
                    self.assertEqual(evaluate(expression, self.context(fork=True, hosted=f" {name} ")), SMALL)

    def test_a_feat_push_release_compile_uses_a_free_fleet_mac_then_blacksmith(self):
        runs_on = self.jobs["release-compile"]["runs-on"]

        def push(**outputs: str) -> dict:
            context = self.context(**outputs)
            context["github"].update(event_name="push", ref="refs/heads/feat-cmux-next")
            context["github"]["event"] = {}
            context["vars"]["CI_NEXT_PROMOTE_POOL"] = PROMOTE
            return context

        # An idle owned Mac wins: the cascade then gives the compile no Blacksmith slot and it takes the
        # owned label. The cascade places it on Blacksmith only when no idle mini took it, so its slot comes
        # before the owned label, which is then a queue (2026-10-26: 10-40 min on the std side label).
        self.assertEqual(evaluate(runs_on, push(runner="free-owned-mac")), "free-owned-mac")
        self.assertEqual(evaluate(runs_on, push()), SIDE)
        self.assertEqual(evaluate(runs_on, push(runner="")), SMALL)
        self.assertEqual(evaluate(runs_on, push(large=" release-compile ")), LARGE)
        self.assertEqual(evaluate(runs_on, push(small=" release-compile ")), SMALL)
        self.assertEqual(evaluate(runs_on, push(runner="", large=" release-compile ")), LARGE)
        self.assertEqual(evaluate(runs_on, push(runner="", small=" release-compile ")), SMALL)
        # Another job's slot is not the Release compile's.
        self.assertEqual(evaluate(runs_on, push(large=" cmux-scheme-compile ")), SIDE)
        # A re-run of the push does not reuse attempt 1's slot.
        rerun = push(large=" release-compile ")
        rerun["github"]["run_attempt"] = "2"
        self.assertEqual(evaluate(runs_on, rerun), SIDE)
        # The job's own label variable agrees with its runs-on.
        runner_env = self.jobs["release-compile"]["env"]["CMUX_NEXT_RUNNER"]
        for outputs in ({}, {"large": " release-compile "}, {"small": " release-compile "}, {"runner": ""}):
            self.assertEqual(evaluate(runner_env, push(**outputs)), evaluate(runs_on, push(**outputs)))
        self.assertEqual(evaluate(runs_on, self.context("2", BOT, retry=SMALL, runner="")), SMALL)
        self.assertEqual(evaluate(runs_on, self.context("3", BOT, retry=SMALL)), SIDE)
        # Release compile never targets the dedicated nightly runner.
        self.assertNotIn("CI_NIGHTLY_NEXT_TRUSTED_RUNNER", self.jobs["release-compile"]["runs-on"])
        self.assertNotIn("CI_NIGHTLY_NEXT_TRUSTED_RUNNER", self.jobs["release-compile"]["env"]["CMUX_NEXT_RUNNER"])

    NIGHTLY_POOL = "glaeda-trusted-light-xcode-26.6"
    NIGHTLY_RUNNER = "glaeda-runner-cmux22-nightly-next"

    # The events release-compile runs on: a push to either branch, a dispatch, and a same-repo or fork pull request.
    EVENTS = (("push", "refs/heads/feat-cmux-next", False), ("push", "refs/heads/main", False),
              ("workflow_dispatch", "refs/heads/feat-cmux-next", False), ("pull_request", "refs/pull/1/merge", False),
              ("pull_request", "refs/pull/1/merge", True))

    def nightly_push(self, ready: str, attempt: str = "1", fast: tuple[str, str] = ("skipped", ""),
                     event: tuple[str, str, bool] = EVENTS[0], actor: str = "teamleaderleo", config: str = "owned",
                     **outputs: str) -> dict:
        name, ref, fork = event
        context = self.context(attempt, actor, fork=fork, **outputs)
        if config == "another owner":
            context["github"]["repository_owner"] = "someone"
        elif config == "pool not owned":
            context["vars"].pop("CI_PR_POOL_OWNED")
        elif config == "no side route":
            context["vars"].update(CI_SIDE_LANE_RUNNER="", MACOS_RUNNER_26="")
        # The fleet fast check: skipped (no idle gateway), no verdict, or an unavailable fleet.
        context["needs"]["release-compile-fast"] = {"result": fast[0], "outputs": {"verdict": fast[1]}}
        context["github"].update(event_name=name, ref=ref)
        if name != "pull_request":
            context["github"]["event"] = {}
        context["vars"].update(CI_NIGHTLY_NEXT_TRUSTED_POOL=self.NIGHTLY_POOL,
                               CI_NIGHTLY_NEXT_TRUSTED_RUNNER=self.NIGHTLY_RUNNER, CI_NEXT_PROMOTE_POOL=PROMOTE)
        # The job sees placement's step outputs through the workflow's own `outputs:` mapping, evaluated here,
        # so a mapping that names a nightly variable reaches the runs-on.
        placed = dict(context["needs"]["macos-placement"]["outputs"], nightly_runner_ready=ready)
        mapping = self.jobs["macos-placement"]["outputs"]
        step = {}
        for key, expression in mapping.items():
            match = re.fullmatch(r"\$\{\{ steps\.place\.outputs\.(\w+) \}\}", expression)
            if match:
                step[match.group(1)] = placed.get(key, "")
        scope = dict(context, steps={"place": {"outputs": step}})
        context["needs"]["macos-placement"]["outputs"] = {key: evaluate(expression, scope)
                                                          for key, expression in mapping.items()}
        if config == "placement skipped":
            context["needs"]["macos-placement"] = {"result": "skipped", "outputs": {}}
        return context

    def off_the_nightly_runner(self, label) -> bool:
        """`label` (a runs-on value: one label, or a list every runner must carry) is set and names no nightly label."""
        labels = label if isinstance(label, list) else [label]
        return bool(labels) and all(isinstance(name, str) and name and name not in (self.NIGHTLY_POOL, self.NIGHTLY_RUNNER)
                                    and "nightly" not in name for name in labels)

    CONFIGS = ("owned", "another owner", "pool not owned", "no side route", "placement skipped")

    def test_a_feeds_compile_takes_the_freshness_slot_first(self):
        """The DEV compile slot (glaeda-dev-std-xcode-<v>), then the owned side label, then Blacksmith: the slot
        is taken only on attempt 1 and only when placement named the job and the label."""
        fresh = "glaeda-dev-std-xcode-26.6"
        feat = "refs/heads/" + "feat-cmux-next"
        # The slot's hook (glaeda#1636) admits cmux-scheme-compile and a push's Release compile, the
        # nightly-next promote gate.
        for name, event in (("cmux-scheme-compile", "workflow_dispatch"), ("release-compile", "push")):
            job = self.jobs[name]
            for attempt, outputs, expected in (
                    ("1", {"fresh_runner": fresh, "fresh_jobs": f" {name} "}, fresh),
                    ("1", {"fresh_runner": fresh, "fresh_jobs": " other "}, SIDE),
                    ("1", {"fresh_runner": "", "fresh_jobs": f" {name} "}, SIDE),
                    ("2", {"fresh_runner": fresh, "fresh_jobs": f" {name} "}, SIDE)):
                with self.subTest(job=name, attempt=attempt, outputs=outputs):
                    context = self.context(attempt)
                    context["github"].update(event_name=event, ref=feat, event={})
                    context["needs"]["macos-placement"]["outputs"].update(outputs)
                    context["needs"]["release-compile-fast"] = {"result": "skipped", "outputs": {"verdict": ""}}
                    context["inputs"] = {"dev_daily": event == "workflow_dispatch"}
                    self.assertEqual(evaluate(job["runs-on"], context), expected)
                    self.assertEqual(evaluate(job["env"]["CMUX_NEXT_RUNNER"], context), expected)
                    if name == "release-compile":
                        # A fleet fast check that failed without a verdict sends the compile to Blacksmith, but
                        # an idle slot placement named comes first (review of #25817).
                        context["needs"]["release-compile-fast"] = {"result": "failure", "outputs": {"verdict": ""}}
                        failed = expected if expected == fresh else "blacksmith-6vcpu-macos-26"
                        self.assertEqual(evaluate(job["runs-on"], context), failed)
                        self.assertEqual(evaluate(job["env"]["CMUX_NEXT_RUNNER"], context), failed)

    def test_release_compile_never_targets_the_dedicated_nightly_runner(self):
        """The nightly runner builds and signs nightly-next; the Release compile that gates it never takes it,
        whatever placement read about it. The runs-on and the job's own label variable are evaluated, as a
        single label or a label list, on every event the workflow runs on, for every attempt, owner and pool
        configuration, fast-check state and placement output it can see."""
        job = self.jobs["release-compile"]
        seen = {event: set() for event in self.EVENTS}
        failures = []
        attempts = (("1", "teamleaderleo"), ("2", "teamleaderleo"), ("2", BOT), ("3", "teamleaderleo"), ("3", BOT),
                    ("4", BOT))
        # Every fast-check state release-compile runs after: skipped, no verdict (failed, or the
        # continue-on-error step left success with none), or an unavailable fleet.
        fasts = (("skipped", ""), ("failure", ""), ("success", ""), ("success", "unavailable"),
                 ("failure", "unavailable"))
        placed = ({}, {"runner": ""}, {"large": " release-compile "}, {"small": " release-compile "}, {"retry": SMALL})
        for event, config, ready, (attempt, actor), fast, outputs in itertools.product(
                self.EVENTS, self.CONFIGS, ("true", ""), attempts, fasts, placed):
            context = self.nightly_push(ready, attempt, fast, event, actor, config, **outputs)
            label = evaluate(job["runs-on"], context)
            if config == "owned" and attempt in ("1", "2"):
                seen[event].add(tuple(label) if isinstance(label, list) else label)
            for name, value in (("runs-on", label), ("CMUX_NEXT_RUNNER", evaluate(job["env"]["CMUX_NEXT_RUNNER"],
                                                                                   context))):
                if not self.off_the_nightly_runner(value):
                    failures.append(f"{name}={value!r}: {event} {config} ready={ready!r} attempt={attempt} {actor} "
                                    f"fast={fast} outputs={outputs}")
        self.assertEqual(failures[:10], [], f"{len(failures)} cases name the nightly runner")
        # Every route each event can take was evaluated: the cascade's two slots and the owned side label
        # (a feat push also takes 6 vCPU with no placement runner, or a fast check that died before its
        # verdict); a fork pull request takes 6 vCPU only. side_lane_placement never writes a nightly label
        # into the runner outputs (test_ci_side_lane_placement.NightlyRunnerStaysOffTheRoutes).
        for event in self.EVENTS:
            self.assertEqual(seen[event], {SMALL} if event[2] else {LARGE, SMALL, SIDE}, event)
        self.assertEqual(evaluate(job["runs-on"], self.nightly_push("", fast=("failure", ""))), SMALL)

    def test_a_configured_but_unavailable_dedicated_runner_overflows_to_blacksmith(self):
        # Dedicated runner configured but not ready: the Blacksmith slot placement gave, else the owned route.
        runs_on = self.jobs["release-compile"]["runs-on"]
        self.assertEqual(evaluate(runs_on, self.nightly_push("", large=" release-compile ")), LARGE)
        self.assertEqual(evaluate(runs_on, self.nightly_push("", small=" release-compile ")), SMALL)
        self.assertEqual(evaluate(runs_on, self.nightly_push("")), SIDE)
        self.assertEqual(evaluate(runs_on, self.nightly_push("", runner="")), SMALL)

    def test_the_placement_knows_the_promotion_label_only_on_a_feat_push(self):
        place = next(step for step in self.jobs["macos-placement"]["steps"] if step.get("id") == "place")
        expression = place["env"]["PROMOTE_LABEL"]
        context = self.context()
        context["vars"]["CI_NEXT_PROMOTE_POOL"] = PROMOTE
        self.assertEqual(evaluate(expression, context), "")
        context["github"].update(event_name="push", ref="refs/heads/feat-cmux-next")
        self.assertEqual(evaluate(expression, context), PROMOTE)
        context["github"].update(ref="refs/heads/next-batch/abc")
        self.assertEqual(evaluate(expression, context), "")
        context["github"].update(ref="refs/heads/feat-cmux-next", run_attempt="2")
        self.assertEqual(evaluate(expression, context), "")

    def test_cascade_runs_names_only_jobs_that_run_on_this_route(self):
        place = next(step for step in self.jobs["macos-placement"]["steps"] if step.get("id") == "place")
        expression = place["env"]["CASCADE_RUNS"]

        def runs(event="pull_request", labels=("full-ci",), fast_lane="", canary="true", scheme="true",
                 association="MEMBER", inputs=None, native="true"):
            context = self.context()
            context["inputs"] = inputs or {"same_tree_sha": ""}
            context["github"]["event"]["pull_request"]["author_association"] = association
            context["github"].update(event_name=event, base_ref="feat-cmux-next",
                                     ref="refs/heads/feat-cmux-next" if event == "push" else "refs/pull/1/merge")
            context["github"]["event"]["pull_request"]["labels"] = [{"name": label} for label in labels]
            context["vars"]["CI_FAST_LANE_RUNNER"] = fast_lane
            context["needs"]["path_route"] = {"outputs": {"swift_canary": canary, "scheme": scheme, "native": native}}
            return set(evaluate(expression, context).split())

        self.assertEqual(runs(), set(CASCADED))
        self.assertEqual(runs(native="false"), set(CASCADED) - {"release-compile"})
        # A same-repository pull request runs its routed canary with no label (#22303); the two heavy
        # compiles need full-ci again, except a member's dev-build scheme compile (its dogfood app).
        self.assertEqual(runs(labels=()), {"fast-tier", "swift-canary"})
        self.assertEqual(runs(labels=(), canary="false", scheme="false"), {"fast-tier"})
        # The fast lane's label is a preference the placement takes only while it is idle
        # (side_lane_placement.fast_route()), so the fast tier is always a cascade candidate.
        self.assertEqual(runs(fast_lane="glaeda-fast-std-xcode-26.6"), set(CASCADED))
        self.assertEqual(runs("push", labels=(), canary="false"), {"fast-tier", "cmux-scheme-compile", "release-compile"})
        self.assertEqual(runs(labels=("dev-build",), association="CONTRIBUTOR"), {"fast-tier", "swift-canary"})
        self.assertEqual(runs(labels=("dev-build",)), {"fast-tier", "swift-canary", "cmux-scheme-compile"})
        # A same-tree dispatch asking for the scheme tier has no path routing output.
        self.assertEqual(runs("workflow_dispatch", labels=(), canary="", scheme="", native="",
                              inputs={"same_tree_sha": "a" * 40, "same_tree_state": "ready",
                                      "same_tree_tiers": "scheme,swift"}), {"cmux-scheme-compile"})

    def test_the_bots_overflow_takes_the_placements_retry_label(self):
        for name in CASCADED:
            runs_on = self.jobs[name]["runs-on"]
            with self.subTest(job=name):
                expected_without_retry = LARGE if name == "fast-tier" else SIDE
                # The bot's attempt 2, placed afresh, takes its retry label; an earlier reading never.
                self.assertEqual(evaluate(runs_on, self.context("2", BOT, retry=SMALL, runner="")), SMALL)
                self.assertEqual(evaluate(runs_on, self.context("3", BOT, retry=SMALL)), expected_without_retry)
                self.assertEqual(evaluate(runs_on, self.context("2", BOT, retry=SMALL, runner="", placed="1")), SIDE if name == "fast-tier" else expected_without_retry)
                # With no slot or a carried placement, preserve the base's
                # owned queue rather than bypassing Blacksmith exclusions.
                self.assertEqual(evaluate(runs_on, self.context("3", BOT)), expected_without_retry)
                self.assertEqual(evaluate(runs_on, self.context("3", BOT, retry="")), expected_without_retry)

    def test_retry_runner_is_limited_to_the_placement_retry_set(self):
        runs_on = self.jobs["release-compile"]["runs-on"]
        capped = self.context("2", BOT, retry=SMALL, runner="")
        capped["needs"]["macos-placement"]["outputs"]["retry_jobs"] = " fast-tier swift-canary "
        self.assertEqual(evaluate(runs_on, capped), SIDE)
        capped["needs"]["macos-placement"]["outputs"]["retry_jobs"] = " release-compile "
        self.assertEqual(evaluate(runs_on, capped), SMALL)

    def test_retry_jobs_are_capped_by_the_placement_limit(self):
        runs = " fast-tier swift-canary cmux-scheme-compile release-compile swift-test daemon-test generated-files "
        result = cascade.place(env(CASCADE_RUNS=runs,
                                   CASCADE_JOBS="swift-test daemon-test generated-files",
                                   JOBS="fast-tier swift-canary cmux-scheme-compile release-compile swift-test daemon-test generated-files"), (),
                               {LARGE: 0, SMALL: 0}, {LARGE: 0, SMALL: 0})
        self.assertEqual(result.retry_runner, SMALL)
        self.assertEqual(result.retry_jobs, ())
        self.assertLessEqual(len(result.jobs[SMALL]) + len(result.retry_jobs), cascade.MAX_PER_RUN)

    def test_fast_tier_keeps_fork_and_disabled_pool_routes(self):
        runs_on = self.jobs["fast-tier"]["runs-on"]
        self.assertEqual(evaluate(runs_on, self.context(fork=True, runner="", placed="1")), SMALL)
        disabled = self.context(runner="", placed="1")
        disabled["vars"]["CI_PR_POOL_OWNED"] = "0"
        self.assertEqual(evaluate(runs_on, disabled), LARGE)

    def test_fast_tier_bot_retry_with_carried_placement_keeps_base_queue(self):
        runs_on = self.jobs["fast-tier"]["runs-on"]
        self.assertEqual(evaluate(runs_on, self.context("2", BOT, runner="", placed="1")), SIDE)

    def test_all_excluded_without_fleet_client_preserves_base_queue_and_coverage(self):
        busy = {"name": "side-mini", "status": "online", "busy": True,
                "labels": [{"name": label} for label in ("self-hosted", "glaeda-light-xcode-26.6", SIDE)]}
        for reason in ("outage", "nightly"):
            with self.subTest(reason=reason), tempfile.TemporaryDirectory() as tmp, contextlib.redirect_stdout(io.StringIO()):
                shot = snapshot(large=1, small=1)
                if reason == "outage":
                    shot["bs_health"] = {"label_outages": [
                        {"pool": label, "queued": 1, "last_start_s": 1900} for label in (LARGE, SMALL)]}
                else:
                    for label in (LARGE, SMALL):
                        shot["pools"][label]["reserved_queued"] = 1
                output = Path(tmp) / "out"
                with mock.patch.object(placement.pool, "GitHub") as api, \
                        mock.patch.object(placement.cascade, "read", return_value=(
                            {LARGE: 5, SMALL: 10}, {LARGE: 1, SMALL: 1},
                            cascade.seen(shot, NOW))):
                    api.return_value.runners.return_value = [busy]
                    placement.main(env(ROUTE_TOKEN="test", GITHUB_REPOSITORY="manaflow-ai/cmux",
                                       GITHUB_OUTPUT=str(output), CASCADE_RUNS=" fast-tier "))
                outputs = dict(line.split("=", 1) for line in output.read_text().splitlines())
                self.assertEqual(outputs["fleet_jobs"], "")
                self.assertEqual(outputs["free_retry_runner"], "")
                self.assertEqual(outputs["blacksmith_12_jobs"] + outputs["blacksmith_6_jobs"], "")
                self.assertEqual(outputs["deferred_runner"], SIDE)
                context = self.context()
                context["needs"]["macos-placement"]["outputs"].update(outputs, placed_attempt="1")
                self.assertEqual(evaluate(self.jobs["fast-tier"]["runs-on"], context), SIDE)
                context["inputs"] = {"same_tree_sha": "", "dev_daily": False}
                context["github"].update(base_ref="feat-cmux-next")
                context["needs"].update(path_route={"outputs": {"macos": "true", "fast_tier": "true"}},
                                         **{"push-head-preflight": {"outputs": {"current": "true"}}})
                self.assertTrue(evaluate(self.jobs["fast-tier"]["if"].replace("!cancelled()", "true"), context))

    def test_display_jobs_keep_push_routes_and_take_allocated_pr_overflow(self):
        for name in GUI_JOBS:
            runs_on = self.jobs[name]["runs-on"]
            with self.subTest(job=name):
                context = self.context(large=f" {name} ", small=f" {name} ")
                self.assertEqual(evaluate(runs_on, context), LARGE)
                context["github"]["event_name"] = "push"
                self.assertEqual(evaluate(runs_on, context), GUI)

    def test_each_jobs_own_label_copy_matches_runs_on(self):
        for name in CASCADED:
            job_env = self.jobs[name].get("env") or {}
            if "CMUX_NEXT_RUNNER" in job_env and name != "release-compile":
                self.assertEqual(job_env["CMUX_NEXT_RUNNER"], label_copy(self.jobs[name]["runs-on"]), name)

    def test_the_placement_job_reads_the_snapshot_and_exports_the_cascade(self):
        job = self.jobs["macos-placement"]
        self.assertEqual(job["permissions"].get("actions"), "read")
        place = next(step for step in job["steps"] if step.get("id") == "place")
        # The pool snapshot reads with the glaeda read token (its own budget), else GITHUB_TOKEN.
        self.assertEqual(place["env"]["SNAPSHOT_TOKEN"], "${{ steps.snapshot-read-token.outputs.token || github.token }}")
        for output in ("blacksmith_12_jobs", "blacksmith_6_jobs", "nightly_runner_ready"):
            self.assertEqual(job["outputs"][output], f"${{{{ steps.place.outputs.{output} }}}}")
        self.assertFalse({"hosted_jobs", "hosted_runner"} & set(job["outputs"]))
        # A placement script that predates the free-slot rule (a pull request's old base) writes only
        # retry_runner, which may name a full label; the job reads the key only the new rule writes.
        self.assertEqual(job["outputs"]["retry_runner"], "${{ steps.place.outputs.free_retry_runner }}")
        self.assertEqual(set(cascade.CASCADE_JOBS), set(CASCADED))
        self.assertTrue(set(cascade.CASCADE_JOBS) <= set(place["env"]["JOBS"].split()))


class SaturatedOwnedPool(unittest.TestCase):
    """No placement path leaves a job on the owned side label with no way off it once the owned pool is full.

    Leo (rulebook, routing order): "No job waits on one reserved machine: every reservation (a label one
    host serves) has a fallback within minutes ... The target is zero queue (Leo, 2026-10-24: 'THERE SHOULD
    BE 0 QUEUE EVER HERE')." GitHub never moves a queued job, and a run with no free Blacksmith slot takes
    the refusals-only marker, so the rescue leaves its queue alone: the placement is the only lever.
    cmux#26723's fast tier (run 40810932618, 2026-10-29) queued on glaeda-side-std-xcode-26.6 from 03:14Z
    for hours: no idle side runner, a stale pool snapshot, and so "no job leaves the minis' queue".
    """

    RUNS = " fast-tier swift-canary cmux-scheme-compile release-compile "
    BOT_RERUN = {"GITHUB_RUN_ATTEMPT": "2", "GITHUB_TRIGGERING_ACTOR": BOT}

    def left(self, result: "cascade.Placement", jobs) -> list[str]:
        return [job for job in jobs if not any(job in names for names in result.jobs.values())]

    def test_the_incidents_fast_tier_takes_6_vcpu_when_the_counts_are_unread(self):
        for live in (None, {LARGE: 0, SMALL: 0}):
            with self.subTest(live=live):
                result = cascade.place(env(CASCADE_RUNS=" fast-tier "), (), live, None, None, saturated=True)
                self.assertEqual(result.jobs, none_placed(**{SMALL: ("fast-tier",)}))
                self.assertIn("no idle mini can take them", result.why)
                # Runners that could not be read are no evidence the minis are full: the old route.
                self.assertEqual(cascade.place(env(CASCADE_RUNS=" fast-tier "), (), live, None).jobs, none_placed())
        # Unread, the last resort is blind, so one run sends at most MAX_PER_RUN there, in priority order.
        result = cascade.place(env(CASCADE_RUNS=self.RUNS), (), None, None, saturated=True)
        self.assertEqual(result.jobs[SMALL], ("fast-tier", "swift-canary")[:cascade.MAX_PER_RUN])
        # Freshness work queued for 6 vCPU, seen in a snapshot read while the runner groups were refused,
        # keeps it for a feed's compile: the PR jobs stay on the owned label.
        held = cascade.Seen(waits={LARGE: 0.0, SMALL: 1.0}, reserved={SMALL: 1})
        self.assertEqual(cascade.place(env(CASCADE_RUNS=self.RUNS), (), None, {LARGE: 0, SMALL: 1}, held,
                                       saturated=True).jobs, none_placed())
        feed = env(CASCADE_RUNS=self.RUNS, FRESH_JOBS="cmux-scheme-compile")
        self.assertEqual(cascade.place(feed, (), None, {LARGE: 0, SMALL: 1}, held, saturated=True).jobs[SMALL],
                         ("cmux-scheme-compile",))
        # A snapshot that still shows 6 vCPU's queue stalled keeps the owned label.
        stalled = cascade.Seen(waits={LARGE: 0.0, SMALL: float(cascade.STALL_MINUTES)})
        self.assertEqual(cascade.place(env(CASCADE_RUNS=" fast-tier "), (), None, {LARGE: 0, SMALL: 1}, stalled,
                                       saturated=True).jobs, none_placed())

    def test_a_full_but_moving_6_vcpu_queue_takes_the_overflow(self):
        moving = cascade.Seen(waits={LARGE: 0.0, SMALL: 3.0})
        result = cascade.place(env(), (), {LARGE: 5, SMALL: 10}, {LARGE: 0, SMALL: 3}, moving, saturated=True)
        self.assertEqual(result.jobs, none_placed(**{SMALL: ("fast-tier", "swift-canary")}))
        self.assertIn("queue on `blacksmith-6vcpu-macos-26`, which is moving (3 queued ahead", result.why)
        self.assertIn("cmux-scheme-compile stay queued on the owned label", result.why)
        # The overflow is no free slot: the bot's overflow label stays owned, and so does the marker.
        self.assertEqual(result.retry_runner, "")
        # An idle mini still comes first: it takes the run's first job, the overflow the next.
        result = cascade.place(env(), ("a",), {LARGE: 5, SMALL: 10}, {LARGE: 0, SMALL: 3}, moving, saturated=True)
        self.assertEqual(result.jobs[SMALL], ("swift-canary", "cmux-scheme-compile"))
        # Free 6 vCPU slots this run took count against the same MAX_PER_RUN.
        result = cascade.place(env(CASCADE_RUNS=self.RUNS), (), {LARGE: 0, SMALL: 7}, {LARGE: 1, SMALL: 1},
                               cascade.Seen(waits={LARGE: 2.0, SMALL: 2.0}), saturated=True)
        self.assertEqual(len(result.jobs[SMALL]), cascade.MAX_PER_RUN)
        # Never 12 vCPU: a 12 vCPU job waits behind every queued 6 vCPU job.
        result = cascade.place(env(), (), {LARGE: 0, SMALL: 10}, {LARGE: 0, SMALL: 3}, moving, saturated=True)
        self.assertEqual(result.jobs[LARGE], ())

    def test_a_stalled_backed_up_or_reserved_6_vcpu_keeps_the_owned_label(self):
        full = {LARGE: 5, SMALL: 10}
        cases = {
            "stalled": ({LARGE: 0, SMALL: 2}, cascade.Seen(waits={LARGE: 0.0, SMALL: 30.0}), "its queue is stalled"),
            "backed up": ({LARGE: 0, SMALL: cascade.OVERFLOW_BACKLOG}, cascade.Seen(waits={LARGE: 0.0, SMALL: 4.0}),
                          f"{cascade.OVERFLOW_BACKLOG} jobs already queue ahead"),
            "reserved": ({LARGE: 0, SMALL: 1}, cascade.Seen(waits={LARGE: 0.0, SMALL: 1.0}, reserved={SMALL: 1}),
                         "freshness work is queued for it"),
        }
        for name, (waiting, seen, why) in cases.items():
            with self.subTest(name):
                result = cascade.place(env(), (), full, waiting, seen, saturated=True)
                self.assertEqual(result.jobs, none_placed())
                self.assertIn(why, result.why)
        # The other macOS 26 6 vCPU-sized labels' queues take 6 vCPU's freed slots too: they count ahead.
        self.assertEqual(cascade.overflow(["fast-tier"], {LARGE: 0, SMALL: 5, MACOS_15: 5}), ())
        self.assertEqual(cascade.overflow(["fast-tier"], {LARGE: 121, SMALL: 0}), ("fast-tier",))
        # A reserved label still takes a feed's compile; a fresh-stalled one takes none.
        self.assertEqual(cascade.overflow(["cmux-scheme-compile"], {SMALL: 1}, reserved=(SMALL,),
                                          fresh=("cmux-scheme-compile",)), ("cmux-scheme-compile",))
        self.assertEqual(cascade.overflow(["cmux-scheme-compile"], {SMALL: 1}, fresh=("cmux-scheme-compile",),
                                          fresh_stall=(SMALL,)), ())

    def test_no_placement_leaves_a_job_owned_while_6_vcpu_is_a_live_overflow(self):
        """The invariant, over every state: with the owned pool read saturated, a cascade job stays on the
        owned label only when 6 vCPU is no live overflow for it (stalled by the pickers' rule, OVERFLOW_BACKLOG
        queued ahead, or reserved for a feed's compile) or the run already sent MAX_PER_RUN there; and the
        run's first job (the fast tier, which every PR waits on) is never left while 6 vCPU is live."""
        lives = ({LARGE: 0, SMALL: 0}, {LARGE: 5, SMALL: 10}, {LARGE: 2, SMALL: 7}, {LARGE: 0, SMALL: 0, MACOS_15: 3})
        waitings = ({LARGE: 0, SMALL: 0}, {LARGE: 121, SMALL: 0}, {LARGE: 0, SMALL: 4}, {LARGE: 3, SMALL: 9},
                    {LARGE: 0, SMALL: 11}, {LARGE: 0, SMALL: 2, MACOS_15: 8})
        waits = (0.0, 3.0, 6.0, 30.0)
        runs = (" fast-tier ", " fast-tier swift-canary ", " swift-canary cmux-scheme-compile ", self.RUNS)
        extras = ({}, {"FRESH_JOBS": "cmux-scheme-compile"}, self.BOT_RERUN)
        checked = 0
        for live, waiting, wait, run, extra, reserved in itertools.product(lives, waitings, waits, runs, extras,
                                                                           (0, 1)):
            seen = cascade.Seen(waits={LARGE: wait if waiting.get(LARGE) else 0.0,
                                       SMALL: wait if waiting.get(SMALL) else 0.0},
                                reserved={SMALL: reserved} if reserved else {})
            run_env = env(CASCADE_RUNS=run, **extra)
            result = cascade.place(run_env, (), live, waiting, seen, saturated=True)
            jobs = cascade.candidates(run_env, ())
            # One run never holds more than MAX_PER_RUN of 6 vCPU, free slots and overflow together.
            self.assertLessEqual(len(result.jobs[SMALL]), cascade.MAX_PER_RUN, (live, waiting, run, result.why))
            left = self.left(result, jobs)
            if not left:
                continue
            checked += 1
            fresh = set(extra.get("FRESH_JOBS", "").split())
            stalled = SMALL in cascade.stalled(live, waiting, seen.waits)
            backed_up = cascade._pool_backlog(waiting) + len(result.jobs[SMALL]) >= cascade.OVERFLOW_BACKLOG
            with self.subTest(live=live, waiting=waiting, wait=wait, run=run, extra=extra, reserved=reserved):
                self.assertIn("stay queued on the owned label", result.why)
                for job in left:
                    live_for_job = not stalled and not backed_up and not (reserved and job not in fresh)
                    if live_for_job:
                        # Only the per-run cap may leave it: MAX_PER_RUN of this run's jobs already took 6 vCPU.
                        self.assertGreaterEqual(len(result.jobs[SMALL]), cascade.MAX_PER_RUN, (job, result.why))
                        self.assertNotEqual(job, jobs[0], result.why)
        self.assertGreater(checked, 50)

    def test_every_mac_job_that_can_take_the_side_label_reads_the_placements_blacksmith_slot(self):
        """A runs-on that resolves to the placement's side label on attempt 1 must take the Blacksmith label
        the placement lists the job for: otherwise the placement's overflow is never read and the job has
        no way off a saturated side label (the PR Release compile's owned-first branch, #25514)."""
        jobs = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]
        wiring = Wiring()
        wiring.jobs = jobs
        found = []
        for name, job in jobs.items():
            runs_on = job.get("runs-on")
            if not isinstance(runs_on, str) or "macos-placement.outputs.runner" not in runs_on:
                continue
            for attempt, actor in (("1", "teamleaderleo"), ("2", BOT)):
                context = wiring.context(attempt, actor)
                context["needs"].setdefault("path_route", {"outputs": {}})
                if evaluate(runs_on, context) != SIDE:
                    continue
                found.append(name)
                with self.subTest(job=name, attempt=attempt):
                    place = next(step for step in jobs["macos-placement"]["steps"] if step.get("id") == "place")
                    declared = cascade.cascade_jobs({"CASCADE_JOBS": evaluate(place["env"]["CASCADE_JOBS"], context)})
                    self.assertIn(name, declared,
                                  f"{name} can take the side label but the cascade never places it off it")
                    self.assertEqual(evaluate(runs_on, wiring.context(attempt, actor, small=f" {name} ")), SMALL)
                    self.assertEqual(evaluate(runs_on, wiring.context(attempt, actor, large=f" {name} ")), LARGE)
        self.assertTrue(set(cascade.CASCADE_JOBS) <= set(found), found)

    def side_outputs(self, runners, counts, **extra: str) -> dict:
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "out"
            fake = mock.Mock()
            fake.return_value.runners.return_value = runners
            with mock.patch.object(placement.pool, "GitHub", fake), \
                    mock.patch.object(placement.cascade, "read", return_value=counts), \
                    contextlib.redirect_stdout(io.StringIO()):
                placement.main(env(GITHUB_REPOSITORY="manaflow-ai/cmux", GITHUB_OUTPUT=str(output), **extra))
            return dict(line.split("=", 1) for line in output.read_text().splitlines())

    def test_the_placement_marks_the_owned_pool_saturated_only_when_it_read_the_runners(self):
        busy = [{"name": "mini", "status": "online", "busy": True,
                 "labels": [{"name": label} for label in ("self-hosted", "glaeda-light-xcode-26.6", SIDE)]}]
        moving = ({LARGE: 5, SMALL: 10}, {LARGE: 0, SMALL: 2}, cascade.Seen(waits={LARGE: 0.0, SMALL: 2.0}))
        for extra in ({}, self.BOT_RERUN):
            with self.subTest(extra=extra):
                self.assertEqual(self.side_outputs(busy, moving, ROUTE_TOKEN="t", **extra)["blacksmith_6_jobs"],
                                 " fast-tier swift-canary ")
                self.assertEqual(self.side_outputs(busy, (None, None, None), ROUTE_TOKEN="t",
                                                   **extra)["blacksmith_6_jobs"], " fast-tier swift-canary ")
                # No runner read (no token): nothing is known about the minis, so the jobs keep the old route.
                self.assertEqual(self.side_outputs(busy, moving, **extra)["blacksmith_6_jobs"], "")


class NightlyFirstOnAStaleSnapshot(unittest.TestCase):
    """Rulebook: "a waiting nightly, promote or nightly sign/verify job is admitted ... ahead of every PR, DEV
    and side job". On 2026-10-30 from 12:20Z the janitor's snapshot landed 22 to 25 minutes apart, so every
    cmux-next placement read none under 15 minutes ("no pool snapshot under 15 min old to count Blacksmith's
    queue") and sent its fast tier to blacksmith-6vcpu-macos-26 blind (runs 41053956129, 41054963820,
    41056535837, 41056990103). nightly-next's sign-nightly-identity-legacy and generate-nightly-deltas
    queued there behind them. A snapshot up to RESERVED_SNAPSHOT_MINUTES old still holds the label for the
    freshness work it shows queued."""

    RUNS = " fast-tier swift-canary cmux-scheme-compile release-compile "

    def shot(self, minutes_old: float, reserved_small: int = 1) -> dict:
        # A moving 6 vCPU queue (oldest 2 min when the snapshot was made): only the reservation holds it.
        shot = snapshot(minutes_old=minutes_old, small=3, oldest={"small": 2})
        shot["pools"][SMALL]["reserved_queued"] = reserved_small
        return shot

    def test_a_late_snapshot_still_reads_its_reservation(self):
        late = cascade.QUEUE_SNAPSHOT_MINUTES + 10
        self.assertIsNone(cascade.seen(self.shot(late), NOW), "too old for counts")
        held = cascade.reserved_from(self.shot(late), NOW)
        self.assertEqual(held, cascade.Seen(waits={SMALL: 2.0}, age=float(late), reserved={SMALL: 1}, stale=True))
        self.assertIsNone(cascade.reserved_from(self.shot(late, reserved_small=0), NOW), "nothing reserved")
        self.assertIsNone(cascade.reserved_from(self.shot(cascade.RESERVED_SNAPSHOT_MINUTES + 1), NOW))
        self.assertIsNone(cascade.reserved_from({"generated_at": "not a time", "pools": {}}, NOW))
        self.assertIsNone(cascade.reserved_from(None, NOW))

    def test_the_read_returns_it_when_the_counts_are_stale(self):
        late = self.shot(cascade.QUEUE_SNAPSHOT_MINUTES + 10)
        pool = mock.Mock()
        pool.GitHub.return_value.snapshot.return_value = late
        with mock.patch.object(cascade.Api, "in_flight", return_value={LARGE: 0, SMALL: 10}):
            live, waiting, seen = cascade.read(env(ROUTE_TOKEN="t", SNAPSHOT_TOKEN="s",
                                                   GITHUB_REPOSITORY="manaflow-ai/cmux"),
                                               pool, now=NOW, log=lambda _: None)
        self.assertIsNone(waiting)
        self.assertTrue(seen.stale)
        self.assertEqual(seen.reserved, {SMALL: 1})
        # A fresh snapshot is read as before, never as stale.
        pool.GitHub.return_value.snapshot.return_value = self.shot(2)
        with mock.patch.object(cascade.Api, "in_flight", return_value={LARGE: 0, SMALL: 10}):
            _, waiting, seen = cascade.read(env(ROUTE_TOKEN="t", SNAPSHOT_TOKEN="s",
                                                GITHUB_REPOSITORY="manaflow-ai/cmux"), pool, now=NOW, log=lambda _: None)
        self.assertEqual(waiting, {LARGE: 0, SMALL: 3})
        self.assertFalse(seen.stale)

    def test_pr_jobs_keep_the_owned_label_while_nightly_waits_on_6_vcpu(self):
        held = cascade.reserved_from(self.shot(cascade.QUEUE_SNAPSHOT_MINUTES + 10), NOW)
        for live in (None, {LARGE: 0, SMALL: 10}):
            with self.subTest(live=live):
                result = cascade.place(env(CASCADE_RUNS=" fast-tier "), (), live, None, held, saturated=True)
                self.assertEqual(result.jobs, none_placed())
                self.assertIn("snapshot shows freshness work queued", result.why)
                # Without the reservation the incident's route stands: the fast tier takes the last resort.
                self.assertEqual(cascade.place(env(CASCADE_RUNS=" fast-tier "), (), live, None, None,
                                               saturated=True).jobs, none_placed(**{SMALL: ("fast-tier",)}))
        # A feed's compile is freshness work itself and still takes it.
        feed = env(CASCADE_RUNS=self.RUNS, FRESH_JOBS="cmux-scheme-compile")
        self.assertEqual(cascade.place(feed, (), None, None, held, saturated=True).jobs[SMALL],
                         ("cmux-scheme-compile",))

    def test_a_stale_reading_is_no_owned_queue_reading(self):
        """The side placement reads `seen` for the owned route's wait: a stale Seen says nothing there."""
        held = cascade.reserved_from(self.shot(cascade.QUEUE_SNAPSHOT_MINUTES + 10), NOW)
        runners = [{"name": f"cmux{n}-glaeda", "status": "online", "busy": True,
                    "labels": [{"name": label} for label in ("self-hosted", SIDE)]} for n in (1, 2)]
        self.assertIsNone(placement.route_wait(SIDE, runners, held))
        fresh = cascade.Seen(waits={}, owned={SIDE: 12.0})
        self.assertEqual(placement.route_wait(SIDE, runners, fresh), 12.0)


class LateSnapshotStall(unittest.TestCase):
    """Blacksmith is a stall-aware overflow only (rulebook, routing order: Linux, owned Macs, Blacksmith last).
    On 2026-10-31 from about 04:00Z every cmux-next placement found no snapshot under 15 minutes ("no pool
    snapshot under 15 min old to count Blacksmith's queue") and sent swift test, daemon tests, the fast tier
    and the Release compile to blacksmith-6vcpu-macos-26 blind (run 41175923956), while the 06:17Z snapshot
    showed it with 166 queued and its oldest job waiting 179 min. A snapshot up to RESERVED_SNAPSHOT_MINUTES
    old still shows a queue that was already stalled when it was made (late_waits())."""

    def read(self, shot: dict):
        pool = mock.Mock()
        pool.GitHub.return_value.snapshot.return_value = shot
        with mock.patch.object(cascade.Api, "in_flight", return_value={LARGE: 0, SMALL: 12}):
            return cascade.read(env(ROUTE_TOKEN="t", SNAPSHOT_TOKEN="s", GITHUB_REPOSITORY="manaflow-ai/cmux"),
                                pool, now=NOW, log=lambda _: None)

    def test_a_late_snapshot_keeps_jobs_off_a_stalled_6_vcpu(self):
        live, waiting, seen = self.read(snapshot(cascade.QUEUE_SNAPSHOT_MINUTES + 10, oldest={"small": 179},
                                                 small=166))
        self.assertIsNone(waiting, "too old for the counts")
        self.assertTrue(seen.stale)
        self.assertEqual(seen.waits, {SMALL: 179.0})
        result = cascade.place(env(CASCADE_RUNS=" fast-tier "), (), live, waiting, seen, saturated=True)
        self.assertEqual(result.jobs, none_placed(), result.why)
        self.assertIn(SMALL, result.fresh_stall)
        self.assertIn("has waited 179 min", result.why)
        # A feed's compile stays off it too, as with a fresh reading (fresh_stalled()).
        feed = env(CASCADE_RUNS=" cmux-scheme-compile ", FRESH_JOBS="cmux-scheme-compile")
        self.assertEqual(cascade.place(feed, (), live, None, seen).jobs, none_placed())

    def test_a_late_snapshot_of_a_moving_queue_keeps_the_last_resort(self):
        live, waiting, seen = self.read(snapshot(cascade.QUEUE_SNAPSHOT_MINUTES + 10, oldest={"small": 2}, small=3))
        self.assertEqual(seen.waits, {SMALL: 2.0}, "the snapshot's own figure, without its 25-min age")
        result = cascade.place(env(CASCADE_RUNS=" fast-tier "), (), live, waiting, seen, saturated=True)
        self.assertEqual(result.jobs, none_placed(**{SMALL: ("fast-tier",)}), result.why)

    def test_the_late_window(self):
        stalled = {"oldest": {"small": 179}, "small": 1}
        self.assertEqual(cascade.late_waits(snapshot(2, **stalled), NOW), {}, "fresh: seen() reads it, age added")
        self.assertEqual(cascade.late_waits(snapshot(cascade.RESERVED_SNAPSHOT_MINUTES + 1, **stalled), NOW), {})
        self.assertEqual(cascade.late_waits(snapshot(20, oldest={"small": 179}), NOW), {}, "no queue, no wait")
        self.assertEqual(cascade.late_waits(None, NOW), {})
        self.assertEqual(cascade.late_waits({"generated_at": "not a time", "pools": {}}, NOW), {})
        self.assertIsNone(cascade.stale_seen(snapshot(cascade.RESERVED_SNAPSHOT_MINUTES + 1, **stalled), NOW))


class DeadEndRoute(unittest.TestCase):
    """A job never stays on an owned route that is a longer queue than Blacksmith 6 vCPU's, or that one host
    alone serves.

    Leo (rulebook, routing order): "No job waits on one reserved machine: every reservation (a label one host
    serves) has a fallback within minutes ... a CI test fails on a runs-on that can resolve to a single-host
    label with no fallback." On 2026-10-29 cmux#26723's fast tier (run 40841809952, job 123340021719) queued on
    glaeda-side-std-xcode-26.6 from 08:24Z behind 96 jobs, the oldest 443 minutes old, while
    blacksmith-6vcpu-macos-26 ran 4 with its oldest queued 27 minutes: overflow() called that queue stalled and
    kept the job on the longer one.
    """

    FULL = {LARGE: 5, SMALL: 4}
    BUSY_SMALL = {LARGE: 42, SMALL: 36}
    INCIDENT = cascade.Seen(waits={LARGE: 1223.0, SMALL: 27.0})

    def test_the_incident_takes_6_vcpu_the_shorter_queue(self):
        result = cascade.place(env(), (), self.FULL, self.BUSY_SMALL, self.INCIDENT, saturated=True,
                               route_wait=443.0)
        self.assertEqual(result.jobs, none_placed(**{SMALL: ("fast-tier", "swift-canary")}))
        self.assertIn("the shorter queue", result.why)
        # Before: the same reads with no dead end kept every job on the owned label.
        self.assertEqual(cascade.place(env(), (), self.FULL, self.BUSY_SMALL, self.INCIDENT, saturated=True).jobs,
                         none_placed())

    def test_a_single_host_route_is_always_a_dead_end(self):
        self.assertTrue(cascade.dead_end(float("inf"), self.FULL, self.BUSY_SMALL, self.INCIDENT))
        result = cascade.place(env(CASCADE_RUNS=" fast-tier "), (), self.FULL, self.BUSY_SMALL, self.INCIDENT,
                               saturated=True, route_wait=float("inf"))
        self.assertEqual(result.jobs[SMALL], ("fast-tier",))
        self.assertIn("one host serves it", result.why)

    def test_a_moving_owned_queue_or_a_longer_6_vcpu_queue_keeps_the_owned_label(self):
        cases = {
            "the owned queue moves": (5.0, self.FULL, self.INCIDENT),
            "6 vCPU waited longer": (20.0, self.FULL, cascade.Seen(waits={LARGE: 0.0, SMALL: 30.0})),
            # No 6 vCPU runner in flight and a queue: a Blacksmith outage, not a shorter queue.
            "6 vCPU starts nothing": (443.0, {LARGE: 0, SMALL: 0}, self.INCIDENT),
            "unknown": (None, self.FULL, self.INCIDENT),
        }
        for name, (wait, live, seen) in cases.items():
            with self.subTest(name):
                self.assertFalse(cascade.dead_end(wait, live, self.BUSY_SMALL, seen))
                result = cascade.place(env(), (), live, self.BUSY_SMALL, seen, saturated=True, route_wait=wait)
                self.assertEqual(result.jobs, none_placed())
        # Runners unread: nothing is known saturated, so nothing moves.
        self.assertEqual(cascade.place(env(), (), self.FULL, self.BUSY_SMALL, self.INCIDENT,
                                       route_wait=443.0).jobs, none_placed())

    def test_a_dead_end_still_keeps_the_per_run_cap_and_freshness_work(self):
        result = cascade.place(env(CASCADE_RUNS=" fast-tier swift-canary cmux-scheme-compile release-compile "),
                               (), self.FULL, self.BUSY_SMALL, self.INCIDENT, saturated=True, route_wait=443.0)
        self.assertEqual(len(result.jobs[SMALL]), cascade.MAX_PER_RUN)
        held = cascade.Seen(waits={LARGE: 0.0, SMALL: 27.0}, reserved={SMALL: 9})
        self.assertEqual(cascade.place(env(), (), self.FULL, self.BUSY_SMALL, held, saturated=True,
                                       route_wait=443.0).jobs, none_placed())

    def test_seen_reads_the_owned_labels_waits(self):
        snap = snapshot(minutes_old=5)
        snap["pools"]["glaeda-side-std-xcode-26.6"] = {"queued": 96, "running": 0, "oldest_queued_minutes": 438}
        snap["pools"]["glaeda-gui-std-xcode-26.6"] = {"queued": 0, "running": 10, "oldest_queued_minutes": 0}
        seen = cascade.seen(snap, NOW)
        self.assertEqual(seen.owned, {"glaeda-side-std-xcode-26.6": 443.0})
        self.assertEqual(seen.owned_queued, {"glaeda-side-std-xcode-26.6": 96})


def observed_dead(minutes_old: float = 2, *, dead: str = LARGE, **overrides: dict) -> dict:
    """The queue janitor's 2026-10-30 snapshot, `minutes_old` old: `dead` runs nothing and started no job (absent
    from label_started), its queue cleared; the other label runs 5 and started one a minute before."""
    generated = NOW - dt.timedelta(minutes=minutes_old)
    alive = SMALL if dead == LARGE else LARGE
    pools = {dead: {"queued": 0, "running": 0, "oldest_queued_minutes": 0},
             alive: {"queued": 0, "running": 5, "oldest_queued_minutes": 0}}
    for label, entry in overrides.items():
        pools[label] = {**pools[label], **entry}
    return {"generated_at": generated.strftime("%Y-%m-%dT%H:%M:%SZ"), "pools": pools,
            "label_started": {alive: (generated - dt.timedelta(minutes=1)).strftime("%Y-%m-%dT%H:%M:%SZ")}}


class DeadLabel(unittest.TestCase):
    """A label that started nothing for an hour is dead, not busy (simple_pool_picker.blacksmith_dead()). On
    2026-10-30 blacksmith-12vcpu-macos-26 had started nothing for about a day while the cascade, reading only the
    oldest-wait stall rule, still counted its five slots free once its queue was cleared."""

    RUNS = " fast-tier swift-canary cmux-scheme-compile "

    def placed(self, snap: dict, live: dict, **kwargs):
        return cascade.place(env(CASCADE_RUNS=self.RUNS), (), live, cascade.queued(snap, NOW),
                             cascade.seen(snap, NOW), **kwargs)

    def test_a_dead_label_with_its_queue_cleared_takes_no_job_and_is_no_retry_runner(self):
        snap = observed_dead()
        result = self.placed(snap, {LARGE: 0, SMALL: 0})
        self.assertEqual(result.jobs[LARGE], (), result.why)
        self.assertNotEqual(result.retry_runner, LARGE)
        self.assertIn("dead", result.why)
        # The same counts without the start evidence (an older janitor): 12 vCPU takes the first job, as before.
        older = dict(snap)
        del older["label_started"]
        self.assertEqual(self.placed(older, {LARGE: 0, SMALL: 0}).jobs[LARGE], ("fast-tier", "swift-canary"))

    def test_a_dead_6_vcpu_takes_no_overflow_even_beside_a_dead_end_owned_route(self):
        snap = observed_dead(dead=SMALL)
        result = self.placed(snap, {LARGE: 2, SMALL: 0}, saturated=True, route_wait=float("inf"))
        self.assertEqual(result.jobs[SMALL], (), result.why)
        self.assertIn(SMALL, result.fresh_stall)

    def test_a_stale_snapshot_still_keeps_a_feed_compile_off_a_dead_6_vcpu(self):
        """No count under 15 minutes: a feed's compile used to take 6 vCPU blind."""
        late = observed_dead(38, dead=SMALL)
        pool = mock.Mock()
        pool.GitHub.return_value.snapshot.return_value = late
        feed = env(CASCADE_RUNS=" cmux-scheme-compile ", FRESH_JOBS="cmux-scheme-compile",
                   SNAPSHOT_TOKEN="s", GITHUB_REPOSITORY="manaflow-ai/cmux")
        live, waiting, seen = cascade.read(feed, pool, now=NOW, log=lambda _: None)
        self.assertIsNone(waiting)
        self.assertEqual(seen.dead, frozenset({SMALL}))
        result = cascade.place(feed, (), live, waiting, seen)
        self.assertEqual(result.jobs, none_placed(), result.why)
        self.assertIn(SMALL, result.fresh_stall)
        # A dead 12 vCPU leaves the feed's last resort as it was.
        _, _, seen = cascade.read(feed, mock.Mock(GitHub=mock.Mock(return_value=mock.Mock(
            snapshot=mock.Mock(return_value=observed_dead(38))))), now=NOW, log=lambda _: None)
        self.assertEqual(cascade.place(feed, (), None, None, seen).jobs[SMALL], ("cmux-scheme-compile",))

    def test_no_evidence_changes_nothing(self):
        """A truncated listing, a snapshot past the six-hour evidence window, or every label dead proves nothing."""
        truncated = dict(observed_dead(), truncated=True)
        expired = observed_dead(7 * 60)
        both = observed_dead(**{SMALL: {"running": 0}})
        both["label_started"] = {}
        for snap in (truncated, expired, both):
            with self.subTest(snap=snap):
                self.assertEqual(cascade.dead(snap, NOW), frozenset())
        self.assertEqual(self.placed(truncated, {LARGE: 0, SMALL: 0}).jobs[LARGE], ("fast-tier", "swift-canary"))
        self.assertEqual(self.placed(both, {LARGE: 0, SMALL: 0}).jobs[LARGE], ("fast-tier", "swift-canary"))
        self.assertIsNone(cascade.stale_seen(expired, NOW))

    def test_the_sign_runner_reads_the_same_rule(self):
        # Loaded without replacing sys.modules' copy: nightly_build_runner's tests patch that one.
        spec = importlib.util.spec_from_file_location("nightly_sign_runner_dead_label", SCRIPTS / "nightly_sign_runner.py")
        sign = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(sign)
        snap = observed_dead(38)
        self.assertEqual(sign.dead(snap, NOW), set(cascade.dead(snap, NOW)))


class FleetClientJobs(unittest.TestCase):
    """With every owned and Blacksmith macOS label full or dead, only the jobs that have a build-fleet client
    (FLEET_CLIENT_JOBS: cmux-next.yml's <job>-fleet) are listed in fleet_jobs; nothing is while any label
    can take the job, and the workflow lists only jobs that have their client."""

    LIVE, WAITING = {LARGE: 5, SMALL: 10}, {LARGE: 1, SMALL: 1}

    def shot(self, **side: object) -> dict:
        shot = snapshot(minutes_old=1, large=1, small=1)
        for label in (LARGE, SMALL, SIDE):
            shot["pools"][label] = {"cap": 1, "running": 1, "queued": 1,
                                    "listening": 0, "held_offline": {"units": 1, "cpu": 0, "livelock": 0},
                                    "oldest_queued_s": 240, "as_of": "2026-10-19T21:59:00Z"}
        shot["pools"][SIDE].update(side)
        return shot

    def place(self, owned=(), shot=None, live=None, **overrides):
        return cascade.place(env(**overrides), owned, live or self.LIVE, self.WAITING,
                             cascade.seen(shot or self.shot(), NOW), saturated=True)

    def test_only_listed_jobs_take_the_fleet(self):
        self.assertEqual(self.place(FLEET_CLIENT_JOBS="fast-tier").fleet_jobs, ("fast-tier",))
        self.assertEqual(self.place(FLEET_CLIENT_JOBS="fast-tier swift-canary").fleet_jobs,
                         ("fast-tier", "swift-canary"))
        self.assertEqual(self.place().fleet_jobs, ())
        self.assertEqual(self.place(FLEET_CLIENT_JOBS="").fleet_jobs, ())

    def test_nothing_is_listed_while_a_label_can_take_the_job(self):
        # A Blacksmith label under its declared cap.
        shot = self.shot()
        shot["pools"][LARGE].update(cap=5, running=1)
        self.assertEqual(self.place(shot=shot, live={LARGE: 1, SMALL: 10}, FLEET_CLIENT_JOBS="fast-tier").fleet_jobs,
                         ())
        # The side label has a listener, by a fresh health record (a stale record or snapshot reads full).
        fresh = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        listening = self.shot(listening=1, held_offline={"units": 0, "cpu": 0, "livelock": 0}, as_of=fresh)
        listening["generated_at"] = fresh
        self.assertEqual(self.place(shot=listening, FLEET_CLIENT_JOBS="fast-tier").fleet_jobs, ())
        # No snapshot: nothing is known full.
        self.assertEqual(cascade.place(env(FLEET_CLIENT_JOBS="fast-tier"), (), self.LIVE, self.WAITING, None,
                                       saturated=True).fleet_jobs, ())

    def test_the_output_is_space_delimited_like_the_blacksmith_lists(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "out"
            cascade.write(self.place(FLEET_CLIENT_JOBS="fast-tier"), {"GITHUB_OUTPUT": str(out)})
            self.assertIn("fleet_jobs= fast-tier \n", out.read_text())

    def test_the_workflow_lists_only_jobs_with_a_client(self):
        jobs = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]
        place = next(step for step in jobs["macos-placement"]["steps"] if step.get("id") == "place")
        listed = str(place["env"]["FLEET_CLIENT_JOBS"]).split()
        self.assertEqual(listed, ["fast-tier"])
        for job in listed:
            with self.subTest(job=job):
                self.assertIn(job, cascade.CASCADE_JOBS, "only a cascade job is ever left unplaced")
                self.assertIn(f"{job}-fleet", jobs, "a listed job needs its <job>-fleet client")


class GuiOverflow(unittest.TestCase):
    """The GUI jobs' Blacksmith leg (swift-test, daemon-test, generated-files): the largest size that starts them now.

    Run 41123927916 (cmux#28497, 2026-10-30) sent swift-test to 6 vCPU on both attempts, where tests that take
    under a second idle took 78-227 s and the 300 s stall watchdog cut them. 12 vCPU was stalled that day, so
    6 vCPU was the right pick then; the leg was 6 vCPU whatever 12 vCPU's state, though.
    """

    MOVING = cascade.Seen(waits={LARGE: 0.0, SMALL: 0.0})

    def free(self) -> dict:
        return {LARGE: 0, SMALL: 0}

    def test_the_large_size_while_it_moves_and_starts_every_gui_job(self):
        self.assertEqual(cascade.gui_overflow_label(self.free(), self.free(), self.MOVING), LARGE)
        self.assertEqual(cascade.gui_overflow_label({LARGE: 1, SMALL: 2}, self.free(), self.MOVING, jobs=3), LARGE)

    def test_the_small_size_when_the_large_one_cannot_start_them_now(self):
        cases = {
            # Run 41123927916's attempt 1 placement: 0 in flight + 158 queued, oldest queued 1431 min.
            "stalled": ({LARGE: 0, SMALL: 4}, {LARGE: 158, SMALL: 0},
                        cascade.Seen(waits={LARGE: 1431.0, SMALL: 0.0})),
            # A cleared queue on a label that started nothing for an hour reads as free slots.
            "dead": (self.free(), self.free(), cascade.Seen(waits={LARGE: 0.0, SMALL: 0.0}, dead=frozenset({LARGE}))),
            "full": ({LARGE: 5, SMALL: 0}, self.free(), self.MOVING),
            "no slot for each job": ({LARGE: 3, SMALL: 0}, self.free(), self.MOVING),
            # Ten 6 vCPU jobs hold the 60 vCPU pool: twelve are not free at once.
            "pool full": ({LARGE: 0, SMALL: 10}, self.free(), self.MOVING),
            # A queued Blacksmith job takes each freed slot first (fits()).
            "pool queue": ({LARGE: 0, SMALL: 2}, {LARGE: 0, SMALL: 1}, self.MOVING),
            "freshness work queued for it": (self.free(), self.free(),
                                             cascade.Seen(waits={LARGE: 0.0, SMALL: 0.0}, reserved={LARGE: 1})),
            "runner groups unread": (None, self.free(), self.MOVING),
            "snapshot unread": (self.free(), None, None),
            "no snapshot waits": (self.free(), self.free(), None),
            "stale snapshot": (self.free(), self.free(), cascade.Seen(waits={}, stale=True)),
        }
        for name, (live, waiting, seen) in cases.items():
            with self.subTest(name):
                self.assertEqual(cascade.gui_overflow_label(live, waiting, seen, jobs=3), SMALL)


if __name__ == "__main__":
    unittest.main()
