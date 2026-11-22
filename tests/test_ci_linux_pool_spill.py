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


class MembersOnly(unittest.TestCase):
    """A spill never names a size outside the pool's declared members.

    2026-11-18 from about 13:40Z: linux_16 and linux_8 named 2 vCPU and then linux_16 spilled down to 4 vCPU, neither a
    member. cmux-tui's thin legs took 25-44 min instead of 2-8 and 7 aarch64 legs failed with rustc OOM (job
    134837837144): a too-small size makes a memory-heavy job fail, not only wait."""

    MEMBERS = [SIXTEEN, EIGHT, THIRTY_TWO]

    def test_candidates_are_the_declared_members_only(self):
        self.assertEqual(spill.spill_candidates("linux_16", self.MEMBERS), self.MEMBERS)
        self.assertEqual(spill.spill_candidates("linux", LINUX), LINUX)

    def test_both_large_members_backed_up_spill_to_the_member_with_room_never_below(self):
        load = {SIXTEEN: {"queued": 65, "running": 50, "waited": 60},
                EIGHT: {"queued": 300, "running": 47, "waited": 288},
                THIRTY_TWO: {"queued": 45, "running": 4, "waited": 40},
                FOUR: {"queued": 2, "running": 35, "waited": 0}, TWO: {"queued": 0, "running": 199, "waited": 0},
                spill.COMPLETE: False}
        member, record, lines = spill.spill_choice("linux_16", spill.spill_candidates("linux_16", self.MEMBERS), {},
                                                   SIXTEEN, None, load, now=NOW, members=self.MEMBERS)
        self.assertEqual((member, record), (SIXTEEN, None))
        self.assertTrue(any("no later live member has room" in line for line in lines))
        roomy = load | {EIGHT: {"queued": 3, "running": 47, "waited": 1}}
        member, record, _ = spill.spill_choice("linux_16", spill.spill_candidates("linux_16", self.MEMBERS), {},
                                               SIXTEEN, None, roomy, now=NOW, members=self.MEMBERS)
        self.assertEqual(member, EIGHT)
        self.assertIn(member, self.MEMBERS)

    def test_has_room_refuses_a_size_outside_the_members(self):
        empty = {FOUR: {"queued": 0, "running": 0, "waited": 0}}
        self.assertFalse(spill.has_room(FOUR, self.MEMBERS, SIXTEEN, empty))
        self.assertTrue(spill.has_room(EIGHT, self.MEMBERS, SIXTEEN, empty))

    def test_a_recorded_spill_to_a_non_member_is_dropped(self):
        record = {"from": SIXTEEN, "to": FOUR, "since": ago(5), "running": 50}
        self.assertFalse(spill.valid_spill(record, spill.spill_candidates("linux_16", self.MEMBERS)))


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

    def test_a_marked_label_that_started_a_job_recently_is_served(self):
        # 2026-11-18 13:18Z: every probe but 2 vCPU waited out 5 minutes under the vCPU cap and main marked 4, 8, 16
        # and 32 vCPU dead. Short jobs there started and finished between passes, so nothing counted as running.
        load = {FOUR: {"queued": 300, "running": 0, "waited": 300, "started": 4},
                EIGHT: {"queued": 90, "running": 0, "waited": 90, "started": 0}, spill.COMPLETE: False}
        self.assertEqual(spill.served_marks({FOUR: "x", EIGHT: "x"}, load), {FOUR})


class SampleClient(unittest.TestCase):
    """2026-11-18 from 11:18Z the cmux-bot read token was refused (403), so the sample was unread and no served mark
    cleared; the policy checkout's client asks a refused read once more with the workflow token."""

    def module(self, init):
        return type("Switch", (), {"GitHub": type("GitHub", (), {"__init__": init})})

    def test_a_client_that_takes_a_fallback_gets_the_workflow_token(self):
        def init(self, token, repo, fallback_token=None):
            self.args = (token, repo, fallback_token)

        client = spill.sample_client(self.module(init), "bot", "o/r", "workflow")
        self.assertEqual(client.args, ("bot", "o/r", "workflow"))
        self.assertEqual(spill.sample_client(self.module(init), "bot", "o/r", None).args, ("bot", "o/r", None))

    def test_an_older_client_without_one_still_reads(self):
        def init(self, token, repo):
            self.args = (token, repo)

        self.assertEqual(spill.sample_client(self.module(init), "bot", "o/r", "workflow").args, ("bot", "o/r"))

    @unittest.skipUnless(POLICY_ROOT, "set RUNNER_POOL_POLICY_ROOT to a main checkout")
    def test_mains_client_takes_the_fallback(self):
        import importlib.util
        path = Path(POLICY_ROOT) / "scripts" / "ci" / "cloud_overflow_switch.py"
        found = importlib.util.spec_from_file_location("main_cloud_overflow_switch", path)
        module = importlib.util.module_from_spec(found)
        sys.modules[found.name] = module  # dataclasses look their module up while it loads
        sys.path.insert(0, str(path.parent))
        try:
            found.loader.exec_module(module)
        finally:
            sys.path.remove(str(path.parent))
            sys.modules.pop(found.name, None)
        self.assertEqual(spill.sample_client(module, "bot", "o/r", "workflow").fallback_token, "workflow")


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
        # Only the Blacksmith Linux sizes: GitHub-hosted Ubuntu and macOS are not sampled.
        load = spill.sample_load(Client(self.RUNS, self.JOBS), now=NOW)
        self.assertEqual(load, {FOUR: {"queued": 2, "running": 1, "waited": 1, "started": 0},
                                SIXTEEN: {"queued": 1, "running": 0, "waited": 1, "started": 0}, spill.COMPLETE: True,
                                spill.OLDEST: {FOUR: 15, SIXTEEN: 4}})

    def test_a_job_a_runner_took_recently_counts_as_started_finished_or_not(self):
        runs = [{"id": 1, "status": "in_progress", "created_at": ago(40)}]
        jobs = {1: [{"status": "completed", "conclusion": "success", "labels": [FOUR], "runner_name": "bs-1",
                     "created_at": ago(40), "started_at": ago(6)},
                    {"status": "in_progress", "labels": [SIXTEEN], "runner_id": 7, "created_at": ago(40),
                     "started_at": ago(2)},
                    # Too long ago, skipped, or never taken by a runner (GitHub sets started_at on queued jobs).
                    {"status": "completed", "conclusion": "success", "labels": [EIGHT], "runner_name": "bs-2",
                     "created_at": ago(60), "started_at": ago(16)},
                    {"status": "completed", "conclusion": "skipped", "labels": [EIGHT], "runner_name": "bs-3",
                     "created_at": ago(40), "started_at": ago(1)},
                    {"status": "queued", "labels": [THIRTY_TWO], "created_at": ago(40), "started_at": ago(40)}]}
        load = spill.sample_load(Client(runs, jobs), now=NOW)
        self.assertEqual(load[FOUR], {"queued": 0, "running": 0, "waited": 0, "started": 1})
        self.assertEqual(load[SIXTEEN], {"queued": 0, "running": 1, "waited": 0, "started": 1})
        self.assertNotIn(EIGHT, load)
        self.assertEqual(load[THIRTY_TWO], {"queued": 1, "running": 0, "waited": 1, "started": 0})

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
        self.assertEqual(load[FOUR], {"queued": 20, "running": 0, "waited": 20, "started": 0})
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

    def test_a_saturated_hosted_override_stays_off_the_paused_blacksmith_sizes(self):
        # CI_LINUX_HOSTED_RUNNER (the Blacksmith pause) puts ubuntu-24.04 first in every x64 Linux pool (main's
        # load_pools()); its later members are the paused Blacksmith sizes, so a saturated hosted label moves nowhere.
        from unittest import mock
        hosted = "ubuntu-24.04"
        start = self.policy.render({"linux": hosted, "_dead": {}, "_updated": ago(60)})
        switch = self.Switch({"RUNNER_POOLS": start, "LINUX_RUNNER": hosted, "CI_CLOUD_OVERFLOW_SAVED": ""})
        admission = {"_admission": {"at": spill.iso(NOW), "target_s": 300,
                                    "pools": {hosted: {"queued": 400, "running": 20, "slots": 20, "p50_s": 240,
                                                       "wait_s": 5040, "saturated": True}}},
                     "hosted_saturated": True}
        env = {"GH_REPO": "manaflow-ai/cmux", "CI_LINUX_HOSTED_RUNNER": hosted}
        with mock.patch.dict(os.environ, {"CI_LINUX_HOSTED_RUNNER": hosted}):
            code = spill.main(["--policy-root", POLICY_ROOT], env, policy=self.policy, switch=switch,
                              client=Client([], {}), api=self.Api(), now=NOW, admission=admission)
            self.assertEqual(code, 0)
            value = json.loads(switch.variables["RUNNER_POOLS"])
            pools = self.policy.load_pools(Path(POLICY_ROOT) / ".github" / "runners.json")
            self.assertEqual(pools["linux"]["members"][0], hosted)
            for name in spill.ADMISSION_POOLS:
                self.assertEqual(value[name], hosted, name)
            self.assertEqual(value["provenance"], hosted)
            self.assertIs(value["hosted_saturated"], True)
            self.assertEqual(value["_admission"], admission["_admission"])
            check = {"RUNNER_POOLS": switch.variables["RUNNER_POOLS"], "LINUX_RUNNER": switch.variables["LINUX_RUNNER"],
                     "CI_CLOUD_OVERFLOW_SAVED": "", "CI_LINUX_HOSTED_RUNNER": hosted}
            self.assertEqual(self.policy.main(["--check"], check, now=NOW), 0)

    def test_a_steady_verdict_writes_nothing_until_it_is_refresh_old(self):
        # The verdict's numbers move every pass; RUNNER_POOLS is rewritten only for routing or a REFRESH-old verdict.
        import expected_wait
        start = self.policy.render({"linux": FOUR, "_dead": {}, "_updated": ago(60)})
        switch = self.Switch({"RUNNER_POOLS": start, "LINUX_RUNNER": FOUR, "CI_CLOUD_OVERFLOW_SAVED": ""})

        def verdict(moment, queued):
            found = {"ubuntu-24.04": {"queued": queued, "running": 20, "slots": 20, "p50_s": 240,
                                      "wait_s": 3000, "saturated": True}}
            previous = json.loads(switch.variables["RUNNER_POOLS"]).get(spill.ADMISSION_KEY)
            return expected_wait.record(found, moment, previous=previous)

        def run(moment, queued):
            env = {"GH_REPO": "manaflow-ai/cmux"}
            return spill.main(["--policy-root", POLICY_ROOT], env, policy=self.policy, switch=switch,
                              client=Client([], {}), api=self.Api(), now=moment,
                              admission=verdict(moment, queued))

        self.assertEqual(run(NOW, 400), 0)
        self.assertIn(spill.ADMISSION_KEY, json.loads(switch.variables["RUNNER_POOLS"]))
        switch.writes.clear()
        self.assertEqual(run(NOW + dt.timedelta(minutes=10), 380), 0)
        self.assertEqual(switch.writes, [])
        self.assertEqual(run(NOW + expected_wait.REFRESH, 360), 0)
        self.assertEqual([name for name, _ in switch.writes], ["RUNNER_POOLS"])
        published = json.loads(switch.variables["RUNNER_POOLS"])[spill.ADMISSION_KEY]
        self.assertEqual(published["at"], spill.iso(NOW + expected_wait.REFRESH))

    def test_a_leftover_hosted_saturated_mark_is_dropped(self):
        # #45861's hosted-first valve wrote RUNNER_POOLS.hosted_saturated; no route reads it since every light job
        # left GitHub-hosted (cmux#45898), so the next pass drops a mark a live value may still hold.
        start = json.loads(self.policy.render({"linux": FOUR, "_dead": {}, "_updated": ago(60)}))
        start["hosted_saturated"] = spill.iso(NOW)
        switch = self.Switch({"RUNNER_POOLS": json.dumps(start), "LINUX_RUNNER": FOUR, "CI_CLOUD_OVERFLOW_SAVED": ""})
        self.assertEqual(self.run_pass(switch, Client([], {}), NOW), 0)
        self.assertNotIn("hosted_saturated", json.loads(switch.variables["RUNNER_POOLS"]))
        self.assertEqual(json.loads(switch.variables["RUNNER_POOLS"])["linux"], FOUR)

    def test_linux_16_spills_to_its_8_vcpu_member_and_mains_check_accepts_it(self):
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

    def test_probe_stalls_under_the_vcpu_cap_do_not_send_every_pool_to_2_vcpu(self):
        # 2026-11-18 13:18Z (run 44311300652): the 2 vCPU probe started in 65 s, the 4, 8, 16 and 32 vCPU probes
        # waited out their 5 minutes, there was no janitor snapshot, and main marked those four sizes dead, so every
        # Linux pool went to 2 vCPU. They were serving: a sampled job had started on each in the last 15 minutes.
        start = self.policy.render({"linux": FOUR, "_dead": {}, "_updated": ago(60)})
        health = json.dumps({"checked": spill.iso(NOW), "run": "44311300652",
                             "labels": {TWO: "started", FOUR: "stalled", EIGHT: "stalled", SIXTEEN: "stalled",
                                        THIRTY_TWO: "stalled"}})
        switch = self.Switch({"RUNNER_POOLS": start, "LINUX_RUNNER": FOUR, "CI_CLOUD_OVERFLOW_SAVED": "",
                              "CI_CLOUD_LABEL_HEALTH": health})
        jobs = [{"status": "completed", "conclusion": "success", "labels": [label], "runner_name": f"bs-{label}",
                 "created_at": ago(50), "started_at": ago(8)} for label in (FOUR, EIGHT, SIXTEEN, THIRTY_TWO)]
        jobs += [{"status": "queued", "labels": [label], "created_at": ago(30)}
                 for label in (FOUR, EIGHT, SIXTEEN, THIRTY_TWO) for _ in range(5)]
        client = Client([{"id": 1, "status": "in_progress", "created_at": ago(50)}], {1: jobs})
        self.assertEqual(self.run_pass(switch, client, NOW), 0)
        value = json.loads(switch.variables["RUNNER_POOLS"])
        self.assertEqual(value["_dead"], {})
        self.assertEqual({name: value[name] for name in ("linux", "linux_4", "linux_8", "linux_16", "linux_32")},
                         {"linux": FOUR, "linux_4": FOUR, "linux_8": EIGHT, "linux_16": SIXTEEN,
                          "linux_32": THIRTY_TWO})
        pools = self.policy.load_pools(Path(POLICY_ROOT) / ".github" / "runners.json")
        outside = {name: value[name] for name in pools if value.get(name) not in self.policy.members(pools[name])}
        self.assertEqual(outside, {})

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



HOSTED = "ubuntu-24.04"
FLEET = "cmux-fleet-linux-x64"


class Admission(unittest.TestCase):
    """Admission by expected wait (cmuxterm-hq#16113 step 3): a saturated capped member takes the next rung."""

    LINUX_LED_BY_HOSTED = [HOSTED, FLEET, FOUR, SIXTEEN]

    def full(self, *labels):
        return {spill.ADMISSION_KEY: {"at": spill.iso(NOW), "target_s": 300,
                                      "pools": {label: {"saturated": True} for label in labels}}}

    def test_a_saturated_member_takes_the_next_live_free_member(self):
        full = spill.saturated(self.full(HOSTED))
        self.assertEqual(spill.admit("linux", self.LINUX_LED_BY_HOSTED, {}, HOSTED, full)[0], FLEET)
        self.assertEqual(spill.admit("linux", self.LINUX_LED_BY_HOSTED, {FLEET: "x"}, HOSTED, full)[0], FOUR)
        both = spill.saturated(self.full(HOSTED, FLEET))
        self.assertEqual(spill.admit("linux_16", self.LINUX_LED_BY_HOSTED, {}, HOSTED, both)[0], FOUR)

    def test_no_free_later_member_stays(self):
        full = spill.saturated(self.full(HOSTED))
        member, lines = spill.admit("linux", [HOSTED], {}, HOSTED, full)
        self.assertEqual(member, HOSTED)
        self.assertTrue(any("staying" in line for line in lines))

    def test_a_member_with_no_verdict_or_a_free_one_is_kept(self):
        self.assertEqual(spill.admit("linux", self.LINUX_LED_BY_HOSTED, {}, HOSTED, set()), (HOSTED, []))
        free = {spill.ADMISSION_KEY: {"pools": {HOSTED: {"saturated": False}}}}
        self.assertEqual(spill.saturated(free), set())
        for bad in (None, {}, {spill.ADMISSION_KEY: "x"}, {spill.ADMISSION_KEY: {"pools": []}},
                    {spill.ADMISSION_KEY: {"pools": {HOSTED: {"saturated": "true"}}}}):
            with self.subTest(bad=bad):
                self.assertEqual(spill.saturated(bad), set())

    def test_provenance_promotion_and_other_pools_never_move(self):
        full = spill.saturated(self.full(HOSTED, FLEET))
        for name in ("provenance", "promotion", "linux_arm64", "macos_26", "macos_intel"):
            with self.subTest(name=name):
                self.assertEqual(spill.admit(name, [HOSTED, FOUR], {}, HOSTED, full), (HOSTED, []))
        self.assertNotIn("provenance", spill.ADMISSION_POOLS)
        self.assertNotIn("promotion", spill.ADMISSION_POOLS)

    class Policy:
        """The parts of main's runner_pools.py apply() calls, as main has them."""
        DEAD_KEY = "_dead"

        @staticmethod
        def parse_value(raw, pools):
            value = json.loads(raw) if (raw or "").strip() else {}
            clean = {name: value[name] for name in pools if isinstance(value.get(name), str)}
            clean["_dead"] = value.get("_dead") if isinstance(value.get("_dead"), dict) else {}
            return clean, []

        @staticmethod
        def members(spec):
            return list(spec["members"])

    POOLS = {"linux": {"members": [HOSTED, FLEET, FOUR, SIXTEEN]},
             "linux_4": {"members": [HOSTED, FLEET, FOUR, SIXTEEN]},
             "provenance": {"members": [HOSTED]}}

    def apply(self, admission, raw=None):
        raw = raw or json.dumps({"linux": HOSTED, "linux_4": HOSTED, "provenance": HOSTED, "_dead": {}})
        return spill.apply(self.Policy, raw, None, self.POOLS, None, now=NOW, admission=admission)

    def test_apply_moves_saturated_pools_and_publishes_the_verdict(self):
        admission = self.full(HOSTED) | {spill.HOSTED_SATURATED_KEY: True}
        value, lines = self.apply(admission)
        self.assertEqual((value["linux"], value["linux_4"], value["provenance"]), (FLEET, FLEET, HOSTED))
        self.assertEqual(value[spill.ADMISSION_KEY], admission[spill.ADMISSION_KEY])
        self.assertIs(value[spill.HOSTED_SATURATED_KEY], True)
        self.assertTrue(any("next rung" in line for line in lines))

    def test_apply_never_moves_a_pool_while_blacksmith_linux_is_paused(self):
        admission = self.full(HOSTED) | {spill.HOSTED_SATURATED_KEY: True}
        value, lines = spill.apply(self.Policy, json.dumps({"linux": HOSTED, "linux_4": HOSTED, "_dead": {}}),
                                   None, self.POOLS, None, now=NOW, admission=admission, paused=True)
        self.assertEqual((value["linux"], value["linux_4"]), (HOSTED, HOSTED))
        self.assertTrue(any("paused" in line for line in lines))
        # Main's load_pools() marks a pool the override leads `hosted`: that alone keeps it too.
        pools = {name: dict(spec, hosted=True) for name, spec in self.POOLS.items()}
        value, _ = spill.apply(self.Policy, json.dumps({"linux": HOSTED, "linux_4": HOSTED, "_dead": {}}),
                               None, pools, None, now=NOW, admission=admission)
        self.assertEqual((value["linux"], value["linux_4"]), (HOSTED, HOSTED))
        # The verdict is still published.
        self.assertIs(value[spill.HOSTED_SATURATED_KEY], True)

    def test_apply_without_a_verdict_routes_as_before_and_publishes_none(self):
        raw = json.dumps({"linux": HOSTED, "linux_4": HOSTED, "provenance": HOSTED, "_dead": {},
                          spill.HOSTED_SATURATED_KEY: True, spill.ADMISSION_KEY: self.full(HOSTED)[spill.ADMISSION_KEY]})
        for admission in (None, {}):
            with self.subTest(admission=admission):
                value, _ = self.apply(admission, raw)
                self.assertEqual((value["linux"], value["linux_4"]), (HOSTED, HOSTED))
                self.assertNotIn(spill.ADMISSION_KEY, value)
                self.assertNotIn(spill.HOSTED_SATURATED_KEY, value)


if __name__ == "__main__":
    unittest.main()
