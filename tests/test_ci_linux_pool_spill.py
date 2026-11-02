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
        load = spill.sample_load(Client(self.RUNS, self.JOBS), now=NOW)
        self.assertEqual(load, {FOUR: {"queued": 2, "running": 1, "waited": 1},
                                SIXTEEN: {"queued": 1, "running": 0, "waited": 1}, spill.COMPLETE: True})

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

    def test_a_dead_member_is_still_mains_call(self):
        start = self.policy.render({"linux": FOUR, "_dead": {FOUR: spill.iso(NOW)}, "_updated": ago(60)})
        switch = self.Switch({"RUNNER_POOLS": start, "LINUX_RUNNER": FOUR, "CI_CLOUD_OVERFLOW_SAVED": ""})
        self.assertEqual(self.run_pass(switch, Client([], {}), NOW + dt.timedelta(minutes=1)), 0)
        self.assertEqual(json.loads(switch.variables["RUNNER_POOLS"])["linux"], SIXTEEN)
        self.assertNotIn("_spill", json.loads(switch.variables["RUNNER_POOLS"]))

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
