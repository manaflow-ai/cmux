#!/usr/bin/env python3
"""scripts/ci/linux_pool_spill.py: main's runner-pool policy, then a queue-aware spill of the linux pool.

The spill rules are tested on their own. The end-to-end cases run main's unchanged policy: set
RUNNER_POOL_POLICY_ROOT to a main checkout (the workflow's), as tests/test_ci_runner_pool_reconcile.py does.
2026-11-02 ~04:40Z: 4 vCPU had 428 queued beside 535 running (oldest ~45 min) while 16 vCPU had ~11 queued.
"""

from __future__ import annotations

import datetime as dt
import json
import os
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts" / "ci"))
import linux_pool_spill as spill  # noqa: E402

POLICY_ROOT = os.environ.get("RUNNER_POOL_POLICY_ROOT")
NOW = dt.datetime(2026, 11, 2, 4, 40, tzinfo=dt.timezone.utc)
FOUR, SIXTEEN = "blacksmith-4vcpu-ubuntu-2404", "blacksmith-16vcpu-ubuntu-2404"
TWO, EIGHT, THIRTY_TWO = "blacksmith-2vcpu-ubuntu-2404", "blacksmith-8vcpu-ubuntu-2404", "blacksmith-32vcpu-ubuntu-2404"
HOSTED = "ubuntu-24.04"
LINUX = [FOUR, SIXTEEN]
BACKED_UP = {FOUR: {"queued": 300, "running": 400, "waited": 200},
             SIXTEEN: {"queued": 2, "running": 100, "waited": 0}, spill.COMPLETE: False}


def ago(minutes: float) -> str:
    return spill.iso(NOW - dt.timedelta(minutes=minutes))


def choose(load, record=None, *, now=NOW, dead=(), base=FOUR):
    return spill.spill_choice("linux", LINUX, {label: "x" for label in dead}, base, record, load, now=now)


class SpillChoice(unittest.TestCase):
    def spilled(self):
        member, record, lines = choose(BACKED_UP)
        self.assertEqual(member, SIXTEEN)
        self.assertEqual(record, {"from": FOUR, "to": SIXTEEN, "since": spill.iso(NOW), "running": 400})
        self.assertTrue(any("spill to" in line for line in lines))
        return record

    def test_a_backed_up_member_spills_to_a_later_member_with_room(self):
        self.spilled()

    def test_a_short_queue_a_busy_or_dead_sibling_or_no_sample_does_not_spill(self):
        short = {FOUR: {"queued": 20, "running": 400, "waited": spill.SPILL_WAITED - 1}}
        self.assertEqual(choose(short)[:2], (FOUR, None))
        busy = {FOUR: BACKED_UP[FOUR], SIXTEEN: {"queued": 30, "running": 100, "waited": 10}}
        member, record, lines = choose(busy)
        self.assertEqual((member, record), (FOUR, None))
        self.assertTrue(any("no later live member has room" in line for line in lines))
        self.assertEqual(choose(BACKED_UP, dead={SIXTEEN})[:2], (FOUR, None))
        self.assertEqual(choose(None)[:2], (FOUR, None))

    def test_only_queue_aware_pools_spill(self):
        load = {"blacksmith-6vcpu-macos-26": {"queued": 99, "running": 1, "waited": 99}}
        self.assertEqual(spill.spill_choice("macos_26", ["blacksmith-6vcpu-macos-26", "blacksmith-12vcpu-macos-26"],
                                            {}, "blacksmith-6vcpu-macos-26", None, load, now=NOW)[:2],
                         ("blacksmith-6vcpu-macos-26", None))

    def test_it_holds_and_an_unread_sample_keeps_it(self):
        record = self.spilled()
        later = NOW + dt.timedelta(minutes=10)
        self.assertEqual(choose(BACKED_UP, record, now=later), (SIXTEEN, record, []))
        self.assertEqual(choose(None, record, now=later), (SIXTEEN, record, []))

    def test_a_drain_on_a_complete_sample_brings_it_back_after_the_min_hold(self):
        record = self.spilled()
        drained = {FOUR: {"queued": 0, "running": 100, "waited": 0}, spill.COMPLETE: True}
        early = NOW + spill.SPILL_MIN_HOLD - dt.timedelta(minutes=1)
        self.assertEqual(choose(drained, record, now=early)[0], SIXTEEN)
        at = NOW + spill.SPILL_MIN_HOLD
        self.assertEqual(choose(drained | {spill.COMPLETE: False}, record, now=at)[0], SIXTEEN)
        self.assertEqual(choose({FOUR: {"queued": 0, "running": 390, "waited": 0}, spill.COMPLETE: True},
                                record, now=at)[0], SIXTEEN)
        member, kept, lines = choose(drained, record, now=at)
        self.assertEqual((member, kept), (FOUR, None))
        self.assertTrue(any("drained" in line for line in lines))

    def test_a_backed_up_target_sends_it_back_only_on_a_complete_sample(self):
        record = self.spilled()
        later = NOW + dt.timedelta(minutes=10)
        flipped = {FOUR: {"queued": 3, "running": 200, "waited": 0},
                   SIXTEEN: {"queued": 80, "running": 300, "waited": 40}}
        self.assertEqual(choose(flipped | {spill.COMPLETE: False}, record, now=later)[0], SIXTEEN)
        self.assertEqual(choose(flipped | {spill.COMPLETE: True}, record, now=later)[:2], (FOUR, None))

    def test_the_max_hold_ends_any_spill(self):
        record = self.spilled()
        member, kept, lines = choose(None, record, now=NOW + spill.SPILL_MAX_HOLD)
        self.assertEqual((member, kept), (FOUR, None))
        self.assertTrue(any("reached" in line for line in lines))
        # Still backed up: the next pass spills again with a new record.
        self.assertEqual(choose(BACKED_UP, None, now=NOW + spill.SPILL_MAX_HOLD + dt.timedelta(minutes=10))[0],
                         SIXTEEN)

    def test_a_dead_target_or_a_new_first_member_ends_the_spill(self):
        record = self.spilled()
        self.assertEqual(choose(BACKED_UP, record, dead={SIXTEEN})[:2], (FOUR, None))
        self.assertEqual(choose(BACKED_UP, record, base=SIXTEEN)[:2], (SIXTEEN, None))

    def test_valid_spill(self):
        good = {"from": FOUR, "to": SIXTEEN, "since": ago(1), "running": 3}
        self.assertTrue(spill.valid_spill(good, LINUX))
        for bad in (good | {"to": FOUR}, good | {"to": "blacksmith-32vcpu-ubuntu-2404"}, good | {"since": "x"},
                    good | {"running": True}, good | {"running": -1}, "x", None):
            with self.subTest(bad=bad):
                self.assertFalse(spill.valid_spill(bad, LINUX))


class DownSpill(unittest.TestCase):
    """linux_16 also spills down to a smaller size main's policy accepts as its release valve.

    2026-11-18 02:58Z: gallery health's shards (RUNNER_POOLS.linux_16) waited 16,431 s at p90 over 2 h; 16 and 32 vCPU
    were both hours deep while 8 vCPU started jobs in a p50 of 646 s."""

    VALVES = [EIGHT, FOUR, TWO]
    MEMBERS = [SIXTEEN, THIRTY_TWO]

    def candidates(self):
        return spill.spill_candidates("linux_16", self.MEMBERS, self.VALVES)

    def choose(self, load, record=None, *, now=NOW, dead=(), base=SIXTEEN):
        return spill.spill_choice("linux_16", self.candidates(), {label: "x" for label in dead}, base, record, load,
                                  now=now, members=self.MEMBERS)

    @staticmethod
    def load(oldest, **waited):
        names = {"sixteen": SIXTEEN, "thirty_two": THIRTY_TWO, "eight": EIGHT, "four": FOUR}
        found = {names[key]: {"queued": count + 5, "running": 50, "waited": count} for key, count in waited.items()}
        found[spill.OLDEST] = {names[key]: minutes for key, minutes in oldest.items()}
        found[spill.COMPLETE] = True
        return found

    def test_candidates_are_the_members_then_the_valve_down_to_its_floor(self):
        self.assertEqual(self.candidates(), [SIXTEEN, THIRTY_TWO, EIGHT, FOUR])
        # The linux pool keeps its members only: no down-spill.
        self.assertEqual(spill.spill_candidates("linux", LINUX, [TWO]), LINUX)

    def test_both_members_hours_deep_spill_down_to_a_size_that_is_starting_jobs(self):
        load = self.load({"sixteen": 85, "thirty_two": 80, "eight": 12, "four": 9},
                         sixteen=60, thirty_two=40, eight=20, four=30)
        member, record, lines = self.choose(load)
        self.assertEqual(member, EIGHT)
        self.assertEqual(record, {"from": SIXTEEN, "to": EIGHT, "since": spill.iso(NOW), "running": 50})
        self.assertTrue(any("spill to" in line for line in lines))
        self.assertTrue(spill.valid_spill(record, self.candidates()))

    def test_a_down_target_needs_a_short_wait_beside_the_backlog(self):
        # 8 vCPU's oldest is past the bound: 4 vCPU next; both too old: stay.
        load = self.load({"sixteen": 85, "thirty_two": 80, "eight": 45, "four": 10},
                         sixteen=60, thirty_two=40, eight=20, four=30)
        self.assertEqual(self.choose(load)[0], FOUR)
        stuck = self.load({"sixteen": 85, "thirty_two": 80, "eight": 45, "four": 40},
                          sixteen=60, thirty_two=40, eight=20, four=30)
        member, record, lines = self.choose(stuck)
        self.assertEqual((member, record), (SIXTEEN, None))
        self.assertTrue(any("no later live member has room" in line for line in lines))
        # Not much faster than the backlog it would leave: stay.
        close = self.load({"sixteen": 20, "thirty_two": 20, "eight": 10, "four": 10},
                          sixteen=60, thirty_two=40, eight=20, four=20)
        self.assertEqual(self.choose(close)[:2], (SIXTEEN, None))

    def test_never_below_the_floor_and_never_onto_a_dead_size(self):
        load = self.load({"sixteen": 85, "thirty_two": 80, "eight": 45, "four": 45}, sixteen=60, thirty_two=40)
        self.assertNotIn(TWO, self.candidates())
        self.assertEqual(self.choose(load)[0], SIXTEEN)
        fresh = self.load({"sixteen": 85, "thirty_two": 80, "eight": 5}, sixteen=60, thirty_two=40)
        # A size with nothing queued in the sample has room: 8 vCPU dead, 4 vCPU next; both dead, stay.
        self.assertEqual(self.choose(fresh, dead={EIGHT})[0], FOUR)
        self.assertEqual(self.choose(fresh, dead={EIGHT, FOUR})[0], SIXTEEN)

    def test_a_drain_brings_it_back(self):
        load = self.load({"sixteen": 85, "thirty_two": 80, "eight": 5}, sixteen=60, thirty_two=40)
        record = self.choose(load)[1]
        drained = {SIXTEEN: {"queued": 0, "running": 10, "waited": 0}, spill.COMPLETE: True}
        member, kept, _ = self.choose(drained, record, now=NOW + spill.SPILL_MIN_HOLD)
        self.assertEqual((member, kept), (SIXTEEN, None))


class HostedValve(unittest.TestCase):
    """The hosted-first release valve: hosted light jobs leave a saturated GitHub-hosted queue on attempt 1.

    2026-11-18 01:40-02:10Z: jobs that finished on GitHub-hosted had waited a median 10,768 s; 2 vCPU, 23 s."""

    @staticmethod
    def load(waited, queued=None, complete=False):
        return {HOSTED: {"queued": waited if queued is None else queued, "running": 20, "waited": waited},
                spill.COMPLETE: complete}

    def test_a_backed_up_hosted_queue_opens_it_and_a_short_one_or_no_sample_does_not(self):
        since, lines = spill.valve_choice(None, self.load(spill.VALVE_ON_WAITED), now=NOW)
        self.assertEqual(since, spill.iso(NOW))
        self.assertTrue(any("saturated" in line and "linux_2" in line for line in lines))
        self.assertEqual(spill.valve_choice(None, self.load(spill.VALVE_ON_WAITED - 1), now=NOW), (None, []))
        self.assertEqual(spill.valve_choice(None, None, now=NOW), (None, []))
        # A Blacksmith backlog is the spill's business, never the valve's.
        self.assertEqual(spill.valve_choice(None, BACKED_UP, now=NOW), (None, []))

    def test_it_holds_then_closes_on_a_drain(self):
        opened = spill.iso(NOW)
        drained = self.load(spill.VALVE_OFF_WAITED, queued=4)
        early = NOW + spill.VALVE_MIN_HOLD - dt.timedelta(minutes=1)
        self.assertEqual(spill.valve_choice(opened, drained, now=early), (opened, []))
        at = NOW + spill.VALVE_MIN_HOLD
        self.assertEqual(spill.valve_choice(opened, None, now=at), (opened, []))
        self.assertEqual(spill.valve_choice(opened, self.load(spill.VALVE_OFF_WAITED + 1), now=at), (opened, []))
        since, lines = spill.valve_choice(opened, drained, now=at)
        self.assertIsNone(since)
        self.assertTrue(any("drained" in line for line in lines))
        # A sample with no hosted job at all is a drain too: nothing waits there.
        self.assertIsNone(spill.valve_choice(opened, {spill.COMPLETE: False}, now=at)[0])

    def test_an_unreadable_mark_is_closed(self):
        self.assertEqual(spill.valve_choice("yesterday", None, now=NOW), (None, []))
        self.assertEqual(spill.valve_choice(True, self.load(0), now=NOW), (None, []))

    def test_apply_carries_and_sets_the_mark_beside_mains_value(self):
        class Policy:
            DEAD_KEY = "_dead"

            @staticmethod
            def parse_value(raw, pools):
                value = json.loads(raw)
                return {key: value[key] for key in ("linux", "linux_2", "_dead") if key in value}, []

            @staticmethod
            def members(spec):
                return spec["members"]

        pools = {"linux": {"members": LINUX}, "linux_2": {"members": ["blacksmith-2vcpu-ubuntu-2404"]}}
        raw = json.dumps({"linux": FOUR, "linux_2": "blacksmith-2vcpu-ubuntu-2404", "_dead": {}})
        value, lines = spill.apply(Policy, raw, None, pools, self.load(40), now=NOW)
        self.assertEqual(value[spill.VALVE_KEY], spill.iso(NOW))
        self.assertEqual(value["linux"], FOUR)
        held = json.dumps(json.loads(raw) | {spill.VALVE_KEY: spill.iso(NOW)})
        value, _ = spill.apply(Policy, held, raw, pools, None, now=NOW + dt.timedelta(minutes=10))
        self.assertEqual(value[spill.VALVE_KEY], spill.iso(NOW))
        value, _ = spill.apply(Policy, held, None, pools, self.load(0), now=NOW + spill.VALVE_MIN_HOLD)
        self.assertNotIn(spill.VALVE_KEY, value)


class ServedMarks(unittest.TestCase):
    """2026-11-17: the probe marked 4 and 16 vCPU dead at 21:48Z and 21:54Z while the sample counted 20 and 7
    running there; the janitor snapshot that would have said so was over an hour old."""

    def test_a_marked_label_running_a_job_is_served(self):
        load = {FOUR: {"queued": 254, "running": 20, "waited": 254},
                SIXTEEN: {"queued": 117, "running": 0, "waited": 117}, spill.COMPLETE: False}
        self.assertEqual(spill.served_marks({FOUR: "x", SIXTEEN: "x"}, load), {FOUR})

    def test_no_sample_no_marks_or_a_non_linux_label_clear_nothing(self):
        running = {"queued": 0, "running": 3, "waited": 0}
        self.assertEqual(spill.served_marks({FOUR: "x"}, None), set())
        self.assertEqual(spill.served_marks({}, {FOUR: running}), set())
        self.assertEqual(spill.served_marks(None, {FOUR: running}), set())
        self.assertEqual(spill.served_marks({"blacksmith-6vcpu-macos-26": "x"},
                                            {"blacksmith-6vcpu-macos-26": running}), set())
        self.assertEqual(spill.served_marks({FOUR: "x"}, {FOUR: {"running": "many"}}), set())


class Client:
    def __init__(self, runs, jobs, fail=()):
        self._runs, self._jobs, self._fail = runs, jobs, set(fail)
        self.calls = 0

    def request(self, method, path):
        # GET /actions/runs?status=S&per_page=100&created=A..B, newest first, one page.
        import urllib.parse
        self.calls += 1
        if "runs" in self._fail:
            raise RuntimeError("GET /actions/runs failed (403)")
        query = dict(urllib.parse.parse_qsl(urllib.parse.urlsplit(path).query))
        start, end = (spill.parse_time(part) for part in query["created"].split(".."))
        found = [run for run in self._runs if run["status"] == query["status"]
                 and start <= spill.parse_time(run["created_at"]) <= end]
        found.sort(key=lambda run: run["created_at"], reverse=True)
        return {"workflow_runs": found[:int(query["per_page"])]}

    def jobs(self, run_id):
        self.calls += 1
        if run_id in self._fail:
            raise RuntimeError("GET /actions/runs/x/jobs failed (502)")
        return self._jobs.get(run_id, [])


class SampleLoad(unittest.TestCase):
    RUNS = [{"id": 1, "status": "in_progress", "created_at": ago(20)},
            {"id": 2, "status": "queued", "created_at": ago(5)},
            {"id": 3, "status": "queued", "created_at": ago(60 * 24)}]
    JOBS = {1: [{"status": "queued", "labels": [FOUR], "created_at": ago(15)},
                {"status": "queued", "labels": [FOUR], "created_at": ago(1)},
                {"status": "in_progress", "labels": [FOUR], "created_at": ago(15)},
                {"status": "completed", "labels": [FOUR], "created_at": ago(15)},
                {"status": "queued", "labels": ["blacksmith-6vcpu-macos-26"], "created_at": ago(15)},
                {"status": "queued", "labels": ["ubuntu-24.04"], "created_at": ago(15)}],
            2: [{"status": "queued", "labels": [SIXTEEN], "created_at": ago(4)}],
            3: [{"status": "queued", "labels": [FOUR], "created_at": ago(60 * 24)}]}

    def test_counts_per_linux_label_over_recent_runs(self):
        # GitHub-hosted Ubuntu is counted beside the Blacksmith sizes, for the hosted-first valve; macOS is not.
        load = spill.sample_load(Client(self.RUNS, self.JOBS), now=NOW)
        self.assertEqual(load, {FOUR: {"queued": 2, "running": 1, "waited": 1},
                                SIXTEEN: {"queued": 1, "running": 0, "waited": 1},
                                HOSTED: {"queued": 1, "running": 0, "waited": 1}, spill.COMPLETE: True,
                                spill.OLDEST: {FOUR: 15, SIXTEEN: 4, HOSTED: 15}})

    def test_a_capped_or_partly_unread_sample_is_incomplete_and_an_unread_listing_is_none(self):
        crowded = self.RUNS + [{"id": 9, "status": "in_progress", "created_at": ago(15)}]
        self.assertFalse(spill.sample_load(Client(crowded, self.JOBS), now=NOW, max_runs=3)[spill.COMPLETE])
        load = spill.sample_load(Client(self.RUNS, self.JOBS, fail={2}), now=NOW)
        self.assertFalse(load[spill.COMPLETE])
        self.assertEqual(load[FOUR]["queued"], 2)
        self.assertIsNone(spill.sample_load(Client(self.RUNS, self.JOBS, fail={"runs"}), now=NOW))

    def test_runs_too_young_to_have_waited_are_not_sampled(self):
        # 2026-11-02 07:13Z: the 60 newest runs were minutes old, so 84 queued 4 vCPU jobs read 0 waited.
        young = [{"id": 100 + i, "status": "in_progress", "created_at": ago(1)} for i in range(spill.MAX_RUNS)]
        old = {"id": 1, "status": "in_progress", "created_at": ago(30)}
        jobs = {1: [{"status": "queued", "labels": [FOUR], "created_at": ago(30)}] * 20}
        jobs.update({run["id"]: [{"status": "queued", "labels": [FOUR], "created_at": ago(1)}] for run in young})
        client = Client(young + [old], jobs)
        load = spill.sample_load(client, now=NOW)
        self.assertEqual(load[FOUR], {"queued": 20, "running": 0, "waited": 20})
        self.assertEqual(client.calls, 6 + 1)

    def test_a_full_page_of_jobs_is_an_incomplete_sample(self):
        # Review of #31884: 100 completed jobs could hide queued ones on the next page.
        jobs = {1: [{"status": "completed", "labels": [FOUR], "created_at": ago(5)}] * spill.JOB_PAGE}
        load = spill.sample_load(Client(self.RUNS[:1], jobs), now=NOW)
        self.assertFalse(load[spill.COMPLETE])

    def test_the_sample_is_bounded(self):
        runs = [{"id": i, "status": "in_progress", "created_at": ago(3 + i * 87 / 500)} for i in range(500)]
        client = Client(runs, {})
        self.assertFalse(spill.sample_load(client, now=NOW)[spill.COMPLETE])
        self.assertLessEqual(client.calls, 6 + spill.MAX_RUNS)

    def test_old_backed_up_runs_are_seen_beside_many_new_ones(self):
        # 2026-11-02 07:43Z: 44 4 vCPU jobs had waited over 10 minutes in runs about 45 minutes old, while the
        # newest runs (all a sample of the newest saw) had none queued.
        # 90 old runs, 30 of them (spread at random) with a waited 4 vCPU job: an even sample of 20 sees about 7
        # and scales them back to about 30.
        import random
        BACKED = set(random.Random(7).sample(range(90), 30))
        old = [{"id": i, "status": "in_progress", "created_at": ago(40 + i / 10)} for i in range(90)]
        new = [{"id": 1000 + i, "status": "in_progress", "created_at": ago(3.5 + i / 40)} for i in range(200)]
        jobs = {run["id"]: [{"status": "queued", "labels": [FOUR], "created_at": run["created_at"]}]
                for run in old if run["id"] in BACKED}
        load = spill.sample_load(Client(old + new, jobs), now=NOW)
        self.assertGreaterEqual(load[FOUR]["waited"], spill.SPILL_WAITED)
        self.assertLessEqual(abs(load[FOUR]["waited"] - 30), 12)
        self.assertFalse(load[spill.COMPLETE])


@unittest.skipUnless(POLICY_ROOT, "set RUNNER_POOL_POLICY_ROOT to a main checkout")
class WithMainPolicy(unittest.TestCase):
    """End to end with main's unchanged scripts/ci/runner_pools.py."""

    class Switch:
        def __init__(self, variables):
            self.variables, self.writes = dict(variables), []

        def get_variable(self, name):
            return self.variables.get(name)

        def set_variable(self, name, value):
            self.writes.append((name, value))
            self.variables[name] = value

    class Api:
        def snapshot(self, *, now):
            return None

    @classmethod
    def setUpClass(cls):
        import runner_pool_reconcile
        cls.policy = runner_pool_reconcile.load_policy(Path(POLICY_ROOT))

    def run_pass(self, switch, client, now):
        env = {"GH_REPO": "manaflow-ai/cmux"}
        return spill.main(["--policy-root", POLICY_ROOT], env, policy=self.policy, switch=switch, client=client,
                          api=self.Api(), now=now)

    def backlog_client(self, waited):
        jobs = [{"status": "queued", "labels": [FOUR], "created_at": ago(10)} for _ in range(waited)]
        return Client([{"id": 1, "status": "in_progress", "created_at": ago(10)}], {1: jobs})

    def test_spill_mirror_steady_state_and_return(self):
        start = self.policy.render({"linux": FOUR, "_dead": {}, "_updated": ago(60)})
        switch = self.Switch({"RUNNER_POOLS": start, "LINUX_RUNNER": FOUR, "CI_CLOUD_OVERFLOW_SAVED": ""})
        self.assertEqual(self.run_pass(switch, self.backlog_client(40), NOW), 0)
        names = [name for name, _ in switch.writes]
        self.assertEqual(names, ["RUNNER_POOLS", "LINUX_RUNNER"])
        value = json.loads(switch.variables["RUNNER_POOLS"])
        self.assertEqual(value["linux"], SIXTEEN)
        self.assertEqual(value["_spill"]["linux"]["from"], FOUR)
        self.assertEqual(switch.variables["LINUX_RUNNER"], SIXTEEN)
        # main's --check accepts the spilled value and mirror.
        check = {"RUNNER_POOLS": switch.variables["RUNNER_POOLS"], "LINUX_RUNNER": SIXTEEN,
                 "CI_CLOUD_OVERFLOW_SAVED": ""}
        self.assertEqual(self.policy.main(["--check"], check, now=NOW), 0)
        # Steady: main's policy alone would put linux back on 4 vCPU; the pass writes nothing.
        switch.writes.clear()
        self.assertEqual(self.run_pass(switch, self.backlog_client(40), NOW + dt.timedelta(minutes=10)), 0)
        self.assertEqual(switch.writes, [])
        # Drained on a complete sample after the hold: back to 4 vCPU, and LINUX_RUNNER with it.
        empty = Client([], {})
        self.assertEqual(self.run_pass(switch, empty, NOW + spill.SPILL_MIN_HOLD), 0)
        self.assertEqual(json.loads(switch.variables["RUNNER_POOLS"])["linux"], FOUR)
        self.assertNotIn("_spill", json.loads(switch.variables["RUNNER_POOLS"]))
        self.assertEqual(switch.variables["LINUX_RUNNER"], FOUR)

    def test_the_valve_opens_holds_and_mains_check_accepts_it(self):
        start = self.policy.render({"linux": FOUR, "_dead": {}, "_updated": ago(60)})
        switch = self.Switch({"RUNNER_POOLS": start, "LINUX_RUNNER": FOUR, "CI_CLOUD_OVERFLOW_SAVED": ""})
        jobs = [{"status": "queued", "labels": [HOSTED], "created_at": ago(10)} for _ in range(30)]
        hosted = Client([{"id": 1, "status": "in_progress", "created_at": ago(10)}], {1: jobs})
        self.assertEqual(self.run_pass(switch, hosted, NOW), 0)
        value = json.loads(switch.variables["RUNNER_POOLS"])
        self.assertEqual(value[spill.VALVE_KEY], spill.iso(NOW))
        self.assertEqual(value["linux"], FOUR)
        check = {"RUNNER_POOLS": switch.variables["RUNNER_POOLS"], "LINUX_RUNNER": FOUR, "CI_CLOUD_OVERFLOW_SAVED": ""}
        self.assertEqual(self.policy.main(["--check"], check, now=NOW), 0)
        # main's policy alone drops the key; the pass carries it, so a steady pass writes nothing.
        switch.writes.clear()
        self.assertEqual(self.run_pass(switch, hosted, NOW + dt.timedelta(minutes=10)), 0)
        self.assertEqual(switch.writes, [])
        self.assertEqual(self.run_pass(switch, Client([], {}), NOW + spill.VALVE_MIN_HOLD), 0)
        self.assertNotIn(spill.VALVE_KEY, json.loads(switch.variables["RUNNER_POOLS"]))

    def test_linux_16_spills_down_and_mains_check_accepts_it(self):
        start = self.policy.render({"linux": FOUR, "_dead": {}, "_updated": ago(60)})
        switch = self.Switch({"RUNNER_POOLS": start, "LINUX_RUNNER": FOUR, "CI_CLOUD_OVERFLOW_SAVED": ""})
        jobs = ([{"status": "queued", "labels": [SIXTEEN], "created_at": ago(80)} for _ in range(30)]
                + [{"status": "queued", "labels": [THIRTY_TWO], "created_at": ago(80)} for _ in range(30)]
                + [{"status": "queued", "labels": [EIGHT], "created_at": ago(5)} for _ in range(3)])
        client = Client([{"id": 1, "status": "in_progress", "created_at": ago(85)}], {1: jobs})
        self.assertEqual(self.run_pass(switch, client, NOW), 0)
        value = json.loads(switch.variables["RUNNER_POOLS"])
        self.assertEqual(value["linux_16"], EIGHT)
        self.assertEqual(value["_spill"]["linux_16"]["from"], SIXTEEN)
        self.assertEqual(value["linux"], FOUR)
        check = {"RUNNER_POOLS": switch.variables["RUNNER_POOLS"], "LINUX_RUNNER": FOUR, "CI_CLOUD_OVERFLOW_SAVED": ""}
        self.assertEqual(self.policy.main(["--check"], check, now=NOW), 0)
        switch.writes.clear()
        self.assertEqual(self.run_pass(switch, client, NOW + dt.timedelta(minutes=10)), 0)
        self.assertEqual(switch.writes, [])

    def test_a_dead_member_is_still_mains_call(self):
        start = self.policy.render({"linux": FOUR, "_dead": {FOUR: spill.iso(NOW)}, "_updated": ago(60)})
        switch = self.Switch({"RUNNER_POOLS": start, "LINUX_RUNNER": FOUR, "CI_CLOUD_OVERFLOW_SAVED": ""})
        self.assertEqual(self.run_pass(switch, Client([], {}), NOW + dt.timedelta(minutes=1)), 0)
        self.assertEqual(json.loads(switch.variables["RUNNER_POOLS"])["linux"], SIXTEEN)
        self.assertNotIn("_spill", json.loads(switch.variables["RUNNER_POOLS"]))

    def test_a_mark_on_a_label_the_sample_sees_running_clears(self):
        thirty_two = "blacksmith-32vcpu-ubuntu-2404"
        marks = {FOUR: spill.iso(NOW), SIXTEEN: spill.iso(NOW)}
        start = self.policy.render({"linux": FOUR, "linux_16": thirty_two, "_dead": marks, "_updated": ago(1)})
        switch = self.Switch({"RUNNER_POOLS": start, "LINUX_RUNNER": FOUR, "CI_CLOUD_OVERFLOW_SAVED": ""})
        jobs = [{"status": "in_progress", "labels": [label], "created_at": ago(10)} for label in (FOUR, SIXTEEN)]
        client = Client([{"id": 1, "status": "in_progress", "created_at": ago(10)}], {1: jobs})
        self.assertEqual(self.run_pass(switch, client, NOW + dt.timedelta(minutes=1)), 0)
        value = json.loads(switch.variables["RUNNER_POOLS"])
        self.assertEqual(value["_dead"], {})
        self.assertEqual(value["linux_16"], SIXTEEN)
        self.assertEqual(value["linux"], FOUR)

    def test_a_value_changed_during_the_pass_is_not_overwritten(self):
        # Review of #31884: a concurrent writer's dead mark must survive this pass.
        start = self.policy.render({"linux": FOUR, "_dead": {}, "_updated": ago(60)})
        changed = self.policy.render({"linux": FOUR, "_dead": {SIXTEEN: spill.iso(NOW)}, "_updated": ago(1)})

        class Racing(self.Switch):
            reads = 0

            def get_variable(inner, name):
                if name == "RUNNER_POOLS":
                    inner.reads += 1
                    return start if inner.reads == 1 else changed
                return super().get_variable(name)

        switch = Racing({"LINUX_RUNNER": FOUR, "CI_CLOUD_OVERFLOW_SAVED": ""})
        self.assertEqual(self.run_pass(switch, self.backlog_client(40), NOW), 0)
        self.assertEqual(switch.writes, [])

    def test_dry_run_writes_nothing(self):
        start = self.policy.render({"linux": FOUR, "_dead": {}, "_updated": ago(60)})
        switch = self.Switch({"RUNNER_POOLS": start, "LINUX_RUNNER": FOUR, "CI_CLOUD_OVERFLOW_SAVED": ""})
        env = {"GH_REPO": "manaflow-ai/cmux", "DRY_RUN": "true"}
        self.assertEqual(spill.main(["--policy-root", POLICY_ROOT], env, policy=self.policy, switch=switch,
                                    client=self.backlog_client(40), api=self.Api(), now=NOW), 0)
        self.assertEqual(switch.writes, [])


if __name__ == "__main__":
    unittest.main()
