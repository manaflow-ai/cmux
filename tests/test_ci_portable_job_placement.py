#!/usr/bin/env python3
"""Portable jobs: fleet Linux first, then a free mini with no nightly waiting, Blacksmith last.

scripts/ci/portable_job_placement.py places the cmux-next checks, the CI guard group, the
release-notary guards, the tooling tests and the cmux-tui macOS targets (Leo, 2026-10-31: "i mean
the linux things cant our minis just run them"). These cases pin its order and its refusals, and
the workflows' wiring of its outputs.
"""
from __future__ import annotations

import base64
import contextlib
import datetime as dt
import gzip
import importlib.util
import io
import json
import os
import re
import sys
import tempfile
import unittest
import urllib.error
from unittest import mock
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/portable_job_placement.py"
WORKFLOWS = ROOT / ".github/workflows"
SIDE = "glaeda-side-light-xcode-26.6"
STD_SIDE = "glaeda-side-std-xcode-26.6"
NOW = dt.datetime(2026, 10, 31, 12, 0, tzinfo=dt.timezone.utc)
JOBS = "ci-guard-group tooling-tests release-notary"


def load():
    spec = importlib.util.spec_from_file_location("portable_job_placement", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    sys.modules["portable_job_placement"] = module
    spec.loader.exec_module(module)
    return module


placement = load()


def runner(name: str, label: str = SIDE, *, busy: bool = False, status: str = "online") -> dict:
    owned = label.replace("glaeda-side-", "glaeda-")
    return {"name": name, "status": status, "busy": busy,
            "labels": [{"name": item} for item in ("self-hosted", owned, label)]}


def fleet_runner(name: str = "cmux-fleet-1", *, busy: bool = False, status: str = "online") -> dict:
    return {"name": name, "status": status, "busy": busy, "os": "Linux",
            "labels": [{"name": item} for item in ("self-hosted", "cmux-fleet-linux-x64")]}


def snapshot(pools: dict | None = None, *, age_minutes: int = 2) -> dict:
    generated = (NOW - dt.timedelta(minutes=age_minutes)).strftime("%Y-%m-%dT%H:%M:%SZ")
    return {"generated_at": generated, "pools": pools or {}}


def env(**overrides: str) -> dict:
    return {"JOBS": JOBS, "SIDE_LABEL": SIDE, "FLEET_LINUX": "blacksmith-4vcpu-ubuntu-2404",
            "GITHUB_RUN_ATTEMPT": "1", **overrides}


def idle(count: int, label: str = SIDE) -> list[dict]:
    return [runner(f"cmux{index}-glaeda", label) for index in range(count)]


NIGHTLY_ONLY = "glaeda-nightly-only-m4pro"
LIGHT = "prepare-nightly-variant-primary prepare-nightly-variant await-nightly-tree-marker"


def nightly_only(name: str, *, busy: bool = False, builder: bool = False) -> dict:
    label = "glaeda-nightly-only-m4pro-builder" if builder else NIGHTLY_ONLY
    return {"name": name, "status": "online", "busy": busy,
            "labels": [{"name": item} for item in ("self-hosted", label, f"glaeda-runner-{name}")]}


class NightlyOnly(unittest.TestCase):
    """The all-nightly reservation's light runners take nightly-next's light jobs while they are idle."""

    def config(self, **overrides: str) -> dict:
        return env(**{"JOBS": LIGHT, "NIGHTLY": "1", "NIGHTLY_WAIT_FOR_FLEET": "1", "REQUIRE_LIVE_CAPACITY": "1",
                      "FLEET_LINUX": "", "NIGHTLY_ONLY_LABEL": NIGHTLY_ONLY, **overrides})

    def test_idle_reservation_runners_take_the_jobs_while_side_minis_are_busy(self):
        runners = [runner("cmux1-glaeda", busy=True), nightly_only("cmux15-glaeda-nightly-only-2"),
                   nightly_only("cmux15-glaeda-nightly-only-3"), nightly_only("cmux7s-glaeda-nightly-only-4")]
        result = placement.decide(self.config(), runners, snapshot(), NOW)
        self.assertEqual(result.mini_runner, NIGHTLY_ONLY)
        self.assertEqual(result.mini_jobs, tuple(LIGHT.split()))

    def test_only_idle_reservation_runners_less_its_queue_count_and_the_builder_never(self):
        runners = [nightly_only("cmux15-glaeda-nightly-only-1", builder=True),
                   nightly_only("cmux15-glaeda-nightly-only-2", busy=True),
                   nightly_only("cmux15-glaeda-nightly-only-3"), nightly_only("cmux7s-glaeda-nightly-only-2")]
        result = placement.decide(self.config(), runners, snapshot(), NOW)
        self.assertEqual(result.mini_jobs, tuple(LIGHT.split())[:2])
        queued = snapshot({NIGHTLY_ONLY: {"queued": 1}})
        self.assertEqual(placement.decide(self.config(), runners, queued, NOW).mini_jobs, tuple(LIGHT.split())[:1])

    def test_busy_unread_unset_or_later_attempt_falls_back_to_the_side_route(self):
        busy = [nightly_only("cmux15-glaeda-nightly-only-2", busy=True), runner("cmux1-glaeda")]
        for config, runners in ((self.config(), busy), (self.config(), None),
                                (self.config(NIGHTLY_ONLY_LABEL=""), [nightly_only("cmux15-glaeda-nightly-only-2")]),
                                (self.config(GITHUB_RUN_ATTEMPT="2"), [nightly_only("cmux15-glaeda-nightly-only-2")]),
                                (self.config(NIGHTLY=""), [nightly_only("cmux15-glaeda-nightly-only-2")])):
            with self.subTest(config=config, runners=runners):
                result = placement.decide(config, runners, snapshot(), NOW)
                self.assertNotEqual(result.mini_runner, NIGHTLY_ONLY)

    def test_reservation_route_reads_capacity_without_a_side_label(self):
        """decide's place-reserved offers the reservation; an unset side label must not skip the read."""
        calls = []

        class Client:
            def __init__(self, token, repo, **kwargs):
                calls.append(token)

            def runners(self, use_state=True):
                return [nightly_only("cmux15-glaeda-nightly-only-2")]

            def snapshot(self, now):
                return snapshot()

        config = self.config(SIDE_LABEL="", GITHUB_REPOSITORY="manaflow-ai/cmux", ROUTE_TOKEN="route",
                             SNAPSHOT_TOKEN="snapshot")
        with mock.patch.object(placement.pool, "GitHub", Client):
            runners, _ = placement.read(config, NOW)
        self.assertEqual(len(runners), 1)
        self.assertEqual(placement.decide(config, runners, snapshot(), NOW).mini_runner, NIGHTLY_ONLY)
        # Not a nightly, no reservation offered, or an attempt that may not move: no read, as before.
        for changes in ({"NIGHTLY": ""}, {"NIGHTLY_ONLY_LABEL": ""}, {"GITHUB_RUN_ATTEMPT": "2"}):
            with self.subTest(changes=changes), mock.patch.object(placement.pool, "GitHub", Client):
                calls.clear()
                self.assertEqual(placement.read({**config, **changes}, NOW), (None, None))
                self.assertEqual(calls, [])

    def test_reservation_with_no_idle_runner_waits_three_minutes_then_leaves_jobs_unplaced(self):
        """Run 41481821056: a reservation Mac started nothing for 11 minutes. Placement re-reads for at
        most 180 s and leaves the jobs to their runs-on tail (hosted Ubuntu on attempt 1)."""
        busy = [nightly_only("cmux15-glaeda-nightly-only-2", busy=True)]
        fresh = {"generated_at": dt.datetime.now(dt.timezone.utc).isoformat(), "pools": {}}
        with mock.patch.object(placement, "read", return_value=(busy, fresh)) as read, \
             mock.patch.object(placement.time, "monotonic", side_effect=[0, 0, 30, 60, 90, 120, 150, 180]), \
             mock.patch.object(placement.time, "sleep") as sleep, \
             mock.patch.object(placement, "write") as write, \
             mock.patch.object(placement.signal, "setitimer"):
            self.assertEqual(placement.main(self.config(SIDE_LABEL="")), 0)
        self.assertEqual(sum(call.args[0] for call in sleep.call_args_list), 180)
        self.assertEqual(read.call_count, 7)
        self.assertEqual(write.call_args.args[0].mini_jobs, ())

    def test_decide_light_jobs_wait_one_re_read_not_three_minutes(self):
        """Run 41655282358: place-reserved waited 163 s in decide, on the feed's critical path."""
        busy = [nightly_only("cmux15-glaeda-nightly-only-2", busy=True)]
        fresh = {"generated_at": dt.datetime.now(dt.timezone.utc).isoformat(), "pools": {}}
        for seconds, slept in (("30", 30), ("600", 180), ("", 180)):
            with self.subTest(seconds=seconds), \
                 mock.patch.object(placement, "read", return_value=(busy, fresh)), \
                 mock.patch.object(placement.time, "monotonic", side_effect=[0, 0, 30, 60, 90, 120, 150, 180]), \
                 mock.patch.object(placement.time, "sleep") as sleep, \
                 mock.patch.object(placement, "write"), \
                 mock.patch.object(placement.signal, "setitimer"):
                placement.main(self.config(SIDE_LABEL="", NIGHTLY_WAIT_SECONDS=seconds))
                self.assertEqual(sum(call.args[0] for call in sleep.call_args_list), slept)
        workflow = yaml.safe_load((ROOT / ".github/workflows/nightly.yml").read_text())
        step = next(s for s in workflow["jobs"]["decide"]["steps"] if s.get("id") == "place-reserved")
        self.assertEqual(step["env"]["NIGHTLY_WAIT_SECONDS"], "30")

    def test_reservation_runner_freed_during_the_wait_takes_the_jobs(self):
        busy = [nightly_only("cmux15-glaeda-nightly-only-2", busy=True)]
        freed = [nightly_only(f"cmux15-glaeda-nightly-only-{index}") for index in range(3)]
        fresh = {"generated_at": dt.datetime.now(dt.timezone.utc).isoformat(), "pools": {}}
        with mock.patch.object(placement, "read", side_effect=[(busy, fresh), (freed, fresh)]), \
             mock.patch.object(placement.time, "monotonic", side_effect=[0, 0]), \
             mock.patch.object(placement.time, "sleep") as sleep, \
             mock.patch.object(placement, "write") as write, \
             mock.patch.object(placement.signal, "setitimer"):
            self.assertEqual(placement.main(self.config(SIDE_LABEL="")), 0)
        sleep.assert_called_once_with(30)
        self.assertEqual(write.call_args.args[0].mini_runner, NIGHTLY_ONLY)
        self.assertEqual(write.call_args.args[0].mini_jobs, tuple(LIGHT.split()))

    def test_nightly_light_placement_reads_the_reservation_variable(self):
        text = (WORKFLOWS / "nightly.yml").read_text(encoding="utf-8")
        step = text[text.index("- name: Place the light jobs on a free mini"):]
        step = step[:step.index("run: bash scripts/ci/nightly-steps/light-placement.sh start")]
        self.assertIn("NIGHTLY_ONLY_LABEL: ${{ vars.CI_NIGHTLY_ONLY_RUNNER }}", step)


class Decide(unittest.TestCase):
    def test_linux_signer_binary_is_never_built_on_a_mini(self):
        config = env(JOBS="control signer-build", LINUX_ONLY="signer-build", NIGHTLY="1")
        result = placement.decide(config, idle(5), snapshot(), NOW)
        self.assertEqual(result.mini_jobs, ("control",))
        result = placement.decide({**config, "FLEET_LINUX": "cmux-fleet-linux-x64"}, idle(5), snapshot(), NOW)
        self.assertEqual(result.linux_jobs, ("control", "signer-build"))
        self.assertEqual(result.mini_jobs, ())

    def test_early_nightly_unknown_capacity_uses_blacksmith_overflow(self):
        config = env(JOBS="control signer-build", LINUX_ONLY="signer-build",
                     NIGHTLY="1", NIGHTLY_WAIT_FOR_FLEET="1", REQUIRE_LIVE_CAPACITY="1")
        for runners, snap in ((None, None), (idle(2), None),
                              (idle(2), snapshot(age_minutes=120))):
            with self.subTest(runners=runners, snapshot=snap):
                placed = placement.decide(config, runners, snap, NOW)
                self.assertEqual((placed.mini_runner, placed.mini_jobs), ("", ()))
                self.assertEqual(placed.linux_jobs, ())

    def test_offline_runner_without_snapshot_does_not_queue_all_owned_jobs(self):
        config = env(JOBS="prepare-one prepare-two prepare-three prepare-four", NIGHTLY="1", NIGHTLY_WAIT_FOR_FLEET="1", REQUIRE_LIVE_CAPACITY="1")
        placed = placement.decide(config, idle(4), None, NOW)
        self.assertEqual(placed.mini_jobs, ())
        self.assertEqual(placed.mini_runner, "")
        self.assertIn("Blacksmith", placed.why)

    def test_live_only_nightly_picker_waits_without_emitting_an_unverified_pool(self):
        config = env(JOBS="pick-nightly-build-runner", NIGHTLY="1",
                     NIGHTLY_WAIT_FOR_FLEET="1", REQUIRE_LIVE_CAPACITY="1")
        for runners, snap in ((None, None), (idle(2), None),
                              (idle(2), snapshot(age_minutes=120)), ([], snapshot())):
            with self.subTest(runners=runners, snapshot=snap):
                placed = placement.decide(config, runners, snap, NOW)
                self.assertEqual((placed.mini_runner, placed.mini_jobs), ("", ()))
        with mock.patch.object(placement, "read", return_value=(None, None)), \
             mock.patch.object(placement.time, "monotonic", side_effect=[0, 180]), \
             mock.patch.object(placement, "write") as write:
            self.assertEqual(placement.main(config), 0)
        self.assertEqual(write.call_args.args[0].mini_runner, "")
        placed = placement.decide(config, idle(1), snapshot(), NOW)
        self.assertEqual(placed.mini_jobs, ("pick-nightly-build-runner",))

    def test_unknown_nightly_capacity_does_not_bypass_runner_eligibility(self):
        for overrides in ({"SIDE_LABEL": ""}, {"SIDE_LABEL": "blacksmith-16vcpu-ubuntu-2404"},
                          {"SIDE_LABEL": "glaeda-aws-side-std-xcode-26.6"},
                          {"GITHUB_RUN_ATTEMPT": "3"}, {"NIGHTLY": "0"}):
            with self.subTest(overrides=overrides):
                config = env(NIGHTLY="1", NIGHTLY_WAIT_FOR_FLEET="1")
                config.update(overrides)
                self.assertEqual(placement.decide(config, None, None, NOW).mini_jobs, ())

    def test_quota_failure_does_not_wait_then_send_controls_to_blacksmith(self):
        config = env(JOBS="control signer-build", LINUX_ONLY="signer-build",
                     NIGHTLY="1", NIGHTLY_WAIT_FOR_FLEET="1")
        with mock.patch.object(placement, "read", return_value=(None, None)) as read, \
             mock.patch.object(placement.time, "monotonic", side_effect=[0, 180]), \
             mock.patch.object(placement.time, "sleep") as sleep, \
             mock.patch.object(placement, "write") as write, \
             mock.patch.object(placement.signal, "setitimer"):
            self.assertEqual(placement.main(config), 0)
        read.assert_called_once()
        sleep.assert_not_called()
        self.assertEqual(write.call_args.args[0].mini_jobs, ("control",))

    def test_nightly_read_deadline_keeps_the_fleet_fallback_and_clears_alarm(self):
        config = env(JOBS="control signer-build", LINUX_ONLY="signer-build",
                     NIGHTLY="1", NIGHTLY_WAIT_FOR_FLEET="1")
        with mock.patch.object(placement, "read", side_effect=placement.Deadline), \
             mock.patch.object(placement, "write") as write, \
             mock.patch.object(placement.signal, "setitimer") as timer:
            self.assertEqual(placement.main(config), 0)
        self.assertEqual(write.call_args.args[0].mini_jobs, ("control",))
        self.assertEqual(timer.call_args.args, (placement.signal.ITIMER_REAL, 0))

    def test_nightly_waits_for_fleet_capacity_then_uses_the_latest_read(self):
        config = env(JOBS="control", NIGHTLY="1", NIGHTLY_WAIT_FOR_FLEET="1")
        fresh = {"generated_at": dt.datetime.now(dt.timezone.utc).isoformat(), "pools": {}}
        with mock.patch.object(placement, "read", side_effect=[([], fresh), (idle(1), fresh)]), \
             mock.patch.object(placement.time, "monotonic", side_effect=[0, 0]), \
             mock.patch.object(placement.time, "sleep") as sleep, \
             mock.patch.object(placement, "write") as write, \
             mock.patch.object(placement.signal, "setitimer"):
            self.assertEqual(placement.main(config), 0)
        sleep.assert_called_once_with(30)
        self.assertEqual(write.call_args.args[0].mini_jobs, ("control",))

    def test_nightly_wait_stops_when_a_re_read_can_no_longer_see_runners(self):
        """Run 41437704107: the first read came from the runner-state document, then every
        live re-read hit an exhausted API quota, and the build job waited out all 180 s."""
        config = env(JOBS="control", NIGHTLY="1", NIGHTLY_WAIT_FOR_FLEET="1", REQUIRE_LIVE_CAPACITY="1")
        fresh = {"generated_at": dt.datetime.now(dt.timezone.utc).isoformat(), "pools": {}}
        with mock.patch.object(placement, "read", side_effect=[([], fresh), (None, None)]) as read, \
             mock.patch.object(placement.time, "monotonic", side_effect=[0, 0, 30]), \
             mock.patch.object(placement.time, "sleep") as sleep, \
             mock.patch.object(placement, "write") as write, \
             mock.patch.object(placement.signal, "setitimer"):
            self.assertEqual(placement.main(config), 0)
        # One sleep and one re-read, not six: the unread re-read ends the wait. With live capacity
        # required, nothing goes to a mini without a fresh read, so the job takes the overflow.
        self.assertEqual(read.call_count, 2)
        sleep.assert_called_once_with(30)
        self.assertEqual(write.call_args.args[0].mini_jobs, ())

    def test_nightly_overflow_wait_is_bounded_to_three_minutes(self):
        config = env(JOBS="control", NIGHTLY="1", NIGHTLY_WAIT_FOR_FLEET="1")
        fresh = {"generated_at": dt.datetime.now(dt.timezone.utc).isoformat(), "pools": {}}
        with mock.patch.object(placement, "read", return_value=([], fresh)) as read, \
             mock.patch.object(placement.time, "monotonic", side_effect=[0, 0, 30, 60, 90, 120, 150, 180]), \
             mock.patch.object(placement.time, "sleep") as sleep, \
             mock.patch.object(placement, "write") as write, \
             mock.patch.object(placement.signal, "setitimer") as timer:
            self.assertEqual(placement.main(config), 0)
        self.assertEqual(sum(call.args[0] for call in sleep.call_args_list), 180)
        self.assertEqual(read.call_count, 7)
        self.assertEqual(write.call_args.args[0].mini_jobs, ())
        self.assertEqual(timer.call_args.args, (placement.signal.ITIMER_REAL, 0))

    def test_idle_minis_take_the_jobs_in_order_when_there_is_no_fleet_linux(self):
        placed = placement.decide(env(), idle(2), snapshot(), NOW)
        self.assertEqual(placed.mini_runner, SIDE)
        self.assertEqual(placed.mini_jobs, ("ci-guard-group", "tooling-tests"))
        self.assertEqual((placed.linux_runner, placed.linux_jobs), ("", ()))
        self.assertIn("release-notary take Blacksmith", placed.why)

    def test_live_linux_capacity_places_only_one_job_per_idle_runner(self):
        config = env(JOBS="size ui-review split", FLEET_LINUX="cmux-fleet-linux-x64",
                     REQUIRE_LIVE_CAPACITY="1")
        placed = placement.decide(config, [fleet_runner(), *idle(2)], snapshot(), NOW)
        self.assertEqual(placed.linux_jobs, ("size",))
        self.assertEqual(placed.mini_jobs, ("ui-review", "split"))

    def test_fleet_linux_comes_before_the_minis(self):
        placed = placement.decide(env(FLEET_LINUX="gcp-linux-32"), idle(5), snapshot(), NOW)
        self.assertEqual(placed.linux_runner, "gcp-linux-32")
        self.assertEqual(placed.linux_jobs, tuple(JOBS.split()))
        self.assertEqual(placed.mini_jobs, ())

    def test_live_capacity_requirement_rejects_an_unserved_fleet_label(self):
        config = env(JOBS="cmux-next-daemon-tests", LINUX_ONLY="cmux-next-daemon-tests",
                     FLEET_LINUX="cmux-fleet-linux-x64", REQUIRE_LIVE_CAPACITY="1")
        for runners in (None, [], [fleet_runner(status="offline")]):
            with self.subTest(runners=runners):
                placed = placement.decide(config, runners, snapshot(), NOW)
                self.assertEqual(placed.linux_runner, "")
                self.assertEqual(placed.linux_jobs, ())

    def test_live_capacity_requirement_emits_the_registered_fleet_label(self):
        config = env(JOBS="cmux-next-daemon-tests", LINUX_ONLY="cmux-next-daemon-tests",
                     FLEET_LINUX="cmux-fleet-linux-x64", REQUIRE_LIVE_CAPACITY="1")
        placed = placement.decide(config, [fleet_runner()], snapshot(), NOW)
        self.assertEqual(placed.linux_runner, "cmux-fleet-linux-x64")
        self.assertEqual(placed.linux_jobs, ("cmux-next-daemon-tests",))

    def test_a_mac_first_job_takes_a_mini_before_fleet_linux(self):
        placed = placement.decide(env(FLEET_LINUX="gcp-linux-32", MAC_FIRST="tooling-tests"),
                                  idle(1), snapshot(), NOW)
        self.assertEqual(placed.linux_jobs, ("ci-guard-group", "release-notary"))
        self.assertEqual(placed.mini_jobs, ("tooling-tests",))

    def test_blacksmith_and_hosted_labels_are_not_fleet_linux(self):
        for label in ("blacksmith-32vcpu-ubuntu-2404", "ubuntu-24.04", "macos-26", "", "  "):
            with self.subTest(label=label):
                self.assertEqual(placement.fleet_linux(label), "")
        self.assertEqual(placement.fleet_linux("gcp-linux-32"), "gcp-linux-32")
        self.assertEqual(placement.fleet_linux("glaeda-std-xcode-26.6"), "")

    def test_live_linux_requires_fresh_idle_linux_capacity_beyond_queue(self):
        config = env(JOBS="legacy-identity-target", LINUX_ONLY="legacy-identity-target",
                     FLEET_LINUX="cmux-fleet-linux-x64", NIGHTLY="1",
                     NIGHTLY_WAIT_FOR_FLEET="1", REQUIRE_LIVE_CAPACITY="1")
        live = {"name": "gcp", "status": "online", "busy": False, "os": "linux",
                "labels": [{"name": "cmux-fleet-linux-x64"}]}
        cases = [(None, snapshot()), ([], snapshot()), ([live], None),
                 ([live], snapshot(age_minutes=120)), ([{**live, "busy": True}], snapshot()),
                 ([{**live, "status": "offline"}], snapshot()),
                 ([{**live, "os": "macOS"}], snapshot()), ([{**live, "os": ""}], snapshot()),
                 ([live, {**live, "os": "macOS"}], snapshot()),
                 ([live], snapshot({"cmux-fleet-linux-x64": {"queued": 1, "oldest_queued_minutes": 4}}))]
        for runners, snap in cases:
            with self.subTest(runners=runners, snapshot=snap):
                result = placement.decide(config, runners, snap, NOW)
                self.assertEqual((result.linux_runner, result.linux_jobs, result.mini_jobs), ("", (), ()))
        result = placement.decide(config, [live], snapshot(), NOW)
        self.assertEqual((result.linux_runner, result.linux_jobs), ("cmux-fleet-linux-x64", ("legacy-identity-target",)))
        for label in ("macos-26", "glaeda-std-xcode-26.6", "ubuntu-24.04", "blacksmith-32vcpu-ubuntu-2404"):
            result = placement.decide({**config, "FLEET_LINUX": label}, [live], snapshot(), NOW)
            self.assertEqual((result.linux_runner, result.mini_jobs), ("", ()))

    def test_linux_only_no_start_wait_is_bounded_and_can_admit_before_deadline(self):
        config = env(JOBS="legacy-identity-target", LINUX_ONLY="legacy-identity-target",
                     FLEET_LINUX="cmux-fleet-linux-x64", NIGHTLY="1",
                     NIGHTLY_WAIT_FOR_FLEET="1", REQUIRE_LIVE_CAPACITY="1")
        live = {"status": "online", "busy": False, "os": "linux",
                "labels": [{"name": "cmux-fleet-linux-x64"}]}
        for second, expected in (([], ""), ([live], "cmux-fleet-linux-x64")):
            with self.subTest(second=second), \
                 mock.patch.object(placement, "read", side_effect=[([], snapshot()), (second, snapshot())]) as read, \
                 mock.patch.object(placement.dt, "datetime", wraps=dt.datetime) as clock, \
                 mock.patch.object(placement.time, "monotonic", side_effect=[0, 150, 180]), \
                 mock.patch.object(placement.time, "sleep") as sleep, \
                 mock.patch.object(placement, "write") as write:
                clock.now.return_value = NOW
                self.assertEqual(placement.main(config), 0)
                sleep.assert_called_once_with(30)
                self.assertEqual(read.call_count, 2)
                self.assertEqual(write.call_args.args[0].linux_runner, expected)

    def test_a_nightly_waiting_on_the_family_keeps_every_job_off_the_minis(self):
        # Nightly jobs come first on the fleet: one queued on any label of the family (here the root
        # label) holds the minis for it.
        pools = {"glaeda-root-light-xcode-26.6": {"queued": 1, "reserved_queued": 1}}
        placed = placement.decide(env(), idle(4), snapshot(pools), NOW)
        self.assertEqual(placed.mini_jobs, ())
        self.assertIn("nightly", placed.why)

    def test_a_nightly_runs_own_jobs_are_not_held_off_by_waiting_nightly_jobs(self):
        # nightly.yml's light jobs (NIGHTLY=1) are the nightly jobs that come first; they still take
        # only runners idle beyond the label's own queue.
        pools = {"glaeda-root-light-xcode-26.6": {"queued": 1, "reserved_queued": 1},
                 SIDE: {"queued": 1, "reserved_queued": 1}}
        placed = placement.decide(env(NIGHTLY="1", FLEET_LINUX="", JOBS="build-nightly-remote-daemon await-nightly-tree-marker"),
                                  idle(2), snapshot(pools), NOW)
        self.assertEqual((placed.mini_runner, placed.mini_jobs), (SIDE, ("build-nightly-remote-daemon",)))
        self.assertIn("await-nightly-tree-marker take Blacksmith", placed.why)
        nothing = placement.decide(env(NIGHTLY="1", FLEET_LINUX=""), [runner("busy", busy=True)], snapshot(), NOW)
        self.assertEqual(nothing.mini_jobs, ())

    def test_another_familys_nightly_does_not_hold_these_minis(self):
        pools = {"glaeda-std-xcode-26.6": {"queued": 1, "reserved_queued": 1}}
        placed = placement.decide(env(), idle(1), snapshot(pools), NOW)
        self.assertEqual(placed.mini_jobs, ("ci-guard-group",))

    def test_jobs_already_queued_on_the_label_take_its_idle_runners_first(self):
        pools = {SIDE: {"queued": 2}}
        placed = placement.decide(env(), idle(3), snapshot(pools), NOW)
        self.assertEqual(placed.mini_jobs, ("ci-guard-group",))

    def test_busy_or_offline_minis_take_nothing(self):
        runners = [runner("a", busy=True), runner("b", status="offline")]
        placed = placement.decide(env(), runners, snapshot(), NOW)
        self.assertEqual(placed.mini_jobs, ())

    def test_a_starved_light_pool_spills_onto_idle_std_side_runners(self):
        runners = [runner("a", busy=True), *idle(2, STD_SIDE)]
        placed = placement.decide(env(), runners, snapshot(), NOW)
        self.assertEqual(placed.mini_runner, STD_SIDE)
        self.assertEqual(placed.mini_jobs, ("ci-guard-group", "tooling-tests"))

    def test_all_or_none_places_nothing_short_of_every_job(self):
        placed = placement.decide(env(JOBS="darwin-aarch64 darwin-x86_64", MAC_FIRST="darwin-aarch64 darwin-x86_64",
                                      MINI_ALL_OR_NONE="1"), idle(1), snapshot(), NOW)
        self.assertEqual(placed.mini_jobs, ())
        placed = placement.decide(env(JOBS="darwin-aarch64 darwin-x86_64", MAC_FIRST="darwin-aarch64 darwin-x86_64",
                                      MINI_ALL_OR_NONE="1"), idle(2), snapshot(), NOW)
        self.assertEqual(placed.mini_jobs, ("darwin-aarch64", "darwin-x86_64"))

    def test_uncertainty_places_nothing_on_a_mini(self):
        cases = {
            "unread runners": (env(), None, snapshot()),
            "no snapshot": (env(), idle(3), None),
            "stale snapshot": (env(), idle(3), snapshot(age_minutes=120)),
            "a person's re-run": (env(GITHUB_RUN_ATTEMPT="2", GITHUB_TRIGGERING_ACTOR="leo"), idle(3), snapshot()),
            "attempt 3": (env(GITHUB_RUN_ATTEMPT="3", GITHUB_TRIGGERING_ACTOR="cmux-bot[bot]"), idle(3), snapshot()),
            "no side label": (env(SIDE_LABEL=""), idle(3), snapshot()),
            "a fork's placeholder": (env(SIDE_LABEL="ubuntu-24.04"), idle(3), snapshot()),
            "the AWS pool": (env(SIDE_LABEL="glaeda-aws-side-std-xcode-26.6"), idle(3), snapshot()),
        }
        for name, (environment, runners, snap) in cases.items():
            with self.subTest(name):
                self.assertEqual(placement.decide(environment, runners, snap, NOW).mini_jobs, ())

    def test_the_rescue_bots_attempt_two_is_placed_afresh(self):
        placed = placement.decide(env(GITHUB_RUN_ATTEMPT="2", GITHUB_TRIGGERING_ACTOR="github-actions[bot]"),
                                  idle(1), snapshot(), NOW)
        self.assertEqual(placed.mini_jobs, ("ci-guard-group",))

    def test_supported_light_rescue_bots_attempt_three_is_placed_afresh(self):
        for actor in sorted(placement.pool.RESCUE_ACTORS):
            with self.subTest(actor=actor):
                placed = placement.decide(env(GITHUB_RUN_ATTEMPT="3", GITHUB_TRIGGERING_ACTOR=actor,
                                              PORTABLE_ATTEMPT3_RESCUE="1"),
                                          idle(1), snapshot(), NOW)
                self.assertEqual(placed.mini_jobs, ("ci-guard-group",))

    def test_attempt_three_without_the_light_workflow_marker_stays_fail_closed(self):
        for actor in sorted(placement.pool.RESCUE_ACTORS):
            with self.subTest(actor=actor):
                environment = env(GITHUB_RUN_ATTEMPT="3", GITHUB_TRIGGERING_ACTOR=actor)
                self.assertEqual(placement.attempt_refusal(environment), "attempt 3 keeps its Blacksmith route")
                self.assertEqual(placement.decide(environment, idle(1), snapshot(), NOW).mini_jobs, ())
        for actor in ("leo", "austinywang"):
            with self.subTest(actor=actor):
                environment = env(GITHUB_RUN_ATTEMPT="3", GITHUB_TRIGGERING_ACTOR=actor,
                                  PORTABLE_ATTEMPT3_RESCUE="1")
                self.assertEqual(placement.attempt_refusal(environment), "attempt 3 keeps its Blacksmith route")

    def test_outputs_delimit_whole_job_keys(self):
        with tempfile.TemporaryDirectory() as scratch:
            output = Path(scratch) / "out"
            placement.write(placement.Placement("", (), SIDE, ("checks",), "why"), {"GITHUB_OUTPUT": str(output)})
            self.assertEqual(output.read_text(),
                             f"linux_runner=\nlinux_jobs=\nmini_runner={SIDE}\nmini_jobs= checks \n")

    def test_main_with_no_tokens_writes_empty_routes(self):
        with tempfile.TemporaryDirectory() as scratch:
            output = Path(scratch) / "out"
            environment = {**env(), "GITHUB_OUTPUT": str(output), "GITHUB_REPOSITORY": "manaflow-ai/cmux"}
            self.assertEqual(placement.main(environment), 0)
            self.assertIn("mini_runner=\nmini_jobs=\n", output.read_text())

    def test_linux_picker_without_route_token_keeps_measured_overflow(self):
        with tempfile.TemporaryDirectory() as scratch:
            output = Path(scratch) / "out"
            summary = Path(scratch) / "summary"
            environment = {
                **env(JOBS="cmux-next-daemon-tests", LINUX_ONLY="cmux-next-daemon-tests",
                      FLEET_LINUX="cmux-fleet-linux-x64", REQUIRE_LIVE_CAPACITY="1"),
                "GITHUB_OUTPUT": str(output),
                "GITHUB_STEP_SUMMARY": str(summary),
                "GITHUB_REPOSITORY": "manaflow-ai/cmux",
            }
            self.assertEqual(placement.main(environment), 0)
            text = output.read_text()
            self.assertIn("linux_runner=\n", text)


def jobs(name: str) -> dict:
    return yaml.safe_load((WORKFLOWS / name).read_text(encoding="utf-8"))["jobs"]


class SharedWait(unittest.TestCase):
    def test_wait_uses_document_once_then_observes_idle_capacity_live(self):
        idle_row = dict(runner("synthetic-glaeda"), id=1, os="macOS")
        doc = dict(schema="runner-state/v1", repository="manaflow-ai/cmux", complete=True,
                   generated_at=dt.datetime.now(dt.timezone.utc).isoformat(), repository_runners=[],
                   runner_groups={"glaeda-minis": [dict(idle_row, busy=True)]}, scale_sets={})
        raw = base64.b64encode(gzip.compress(json.dumps(doc).encode())).decode()
        config = env(GITHUB_REPOSITORY="manaflow-ai/cmux", ROUTE_TOKEN="synthetic-token",
                     SNAPSHOT_TOKEN="synthetic-snapshot", JOBS="control", NIGHTLY="1",
                     NIGHTLY_WAIT_FOR_FLEET="1", REQUIRE_LIVE_CAPACITY="1", CI_RUNNER_STATE=raw)
        clock, paths = [0.0], []
        def api(path):
            paths.append(path)
            if "visible_to_repository" in path:
                return {"runner_groups": [{"name": "glaeda-minis", "id": 10}]}
            return {"runners": [idle_row]} if "/10/runners" in path else {}
        fresh = {"generated_at": dt.datetime.now(dt.timezone.utc).isoformat(), "pools": {}}
        with mock.patch.dict(os.environ, config, clear=True), \
             mock.patch.object(placement.pool.GitHub, "get_api", side_effect=api), \
             mock.patch.object(placement.pool.GitHub, "snapshot", return_value=fresh), \
             mock.patch.object(placement.time, "monotonic", side_effect=lambda: clock[0]), \
             mock.patch.object(placement.time, "sleep", side_effect=lambda s: clock.__setitem__(0, clock[0] + s)), \
             mock.patch.object(placement.signal, "setitimer"), \
             mock.patch.object(placement, "write") as write, contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(placement.main(config), 0)
        self.assertEqual(write.call_args.args[0].mini_jobs, ("control",))
        self.assertEqual(clock[0], 30)
        self.assertEqual(sum("/10/runners" in path for path in paths), 1)


class OrganizationFallback(unittest.TestCase):
    def observe(self):
        config = env(GITHUB_REPOSITORY="manaflow-ai/cmux", ROUTE_TOKEN="spent",
                     ROUTE_TOKEN_FALLBACK="org-only", SNAPSHOT_TOKEN="snapshot", JOBS="control")
        calls = []

        def api(client, path):
            token = client.headers["Authorization"].split()[-1]
            calls.append((token, path))
            if token == "spent" or path.startswith("/repos/"):
                remaining = "0" if token == "spent" else "4258"
                raise urllib.error.HTTPError(path, 403, "Forbidden", {"X-RateLimit-Remaining": remaining}, None)
            if "visible_to_repository" in path:
                return {"runner_groups": [{"name": "glaeda-minis", "id": 10}]}
            if "/10/runners" in path:
                return {"runners": [dict(runner("synthetic-glaeda"), id=1, os="macOS")]}
            raise AssertionError(path)

        with mock.patch.dict(os.environ, {}, clear=True), \
             mock.patch.object(placement.pool.GitHub, "get_api", autospec=True, side_effect=api), \
             mock.patch.object(placement.pool.GitHub, "snapshot", return_value=snapshot()), \
             contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            runners, fresh = placement.read(config, NOW)
        return placement.decide(config, runners, fresh, NOW), calls

    def test_org_only_fallback_places_an_idle_mini_when_the_routing_budget_is_spent(self):
        placed, calls = self.observe()
        self.assertEqual(placed.mini_jobs, ("control",))
        self.assertEqual(placed.mini_runner, SIDE)
        self.assertFalse(any(token == "org-only" and path.startswith("/repos/") for token, path in calls))
        self.assertTrue(any("visible_to_repository=cmux" in path for _, path in calls))


class Wiring(unittest.TestCase):
    def test_next_portable_bootstrap_needs_no_private_app_credentials(self):
        bootstrap = jobs("cmux-next.yml")["portable-placement"]
        self.assertNotIn("secrets.", yaml.safe_dump(bootstrap))
        self.assertNotIn("environment", bootstrap)
        self.assertFalse(any("actions/create-github-app-token@" in step.get("uses", "")
                             for step in bootstrap["steps"]))
        config = bootstrap["steps"][-1]["env"]
        self.assertNotIn("ROUTE_TOKEN", config)
        self.assertNotIn("ROUTE_TOKEN_FALLBACK", config)
        runners = json.loads((ROOT / ".github/runners.json").read_text())
        self.assertNotIn("allowed_secrets", runners["hosted_light_jobs"]["cmux-next.yml#portable-placement"])

    def test_next_secretless_bootstrap_uses_only_fresh_registered_capacity(self):
        bootstrap = jobs("cmux-next.yml")["portable-placement"]
        config = env(JOBS=bootstrap["steps"][-1]["env"]["JOBS"],
                     GITHUB_REPOSITORY="manaflow-ai/cmux", REQUIRE_LIVE_CAPACITY="1",
                     SNAPSHOT_TOKEN="ordinary-token")
        state = {
            "schema": "runner-state/v1", "repository": "manaflow-ai/cmux", "complete": True,
            "generated_at": NOW.isoformat(), "repository_runners": [],
            "runner_groups": {"glaeda-minis": [dict(row, id=index, os="macOS")
                                               for index, row in enumerate(idle(2), 1)]},
            "scale_sets": {},
            "queue_snapshot": {
                "artifact": {"id": 7, "name": placement.pool.ARTIFACT_NAME, "expired": False,
                             "created_at": NOW.isoformat(),
                             "workflow_run": {"id": 8, "head_branch": placement.pool.SNAPSHOT_BRANCH,
                                              "repository_id": 1, "head_repository_id": 1}},
                "snapshot": snapshot(),
            },
        }
        cases = [(state, ("checks", "path_route")),
                 ({**state, "generated_at": (NOW - dt.timedelta(minutes=6)).isoformat()}, ()),
                 ({**state, "complete": False}, ()),
                 ({**state, "queue_snapshot": {}}, ())]
        for document, expected in cases:
            with self.subTest(expected=expected, document=document), \
                 mock.patch.dict(os.environ, {}, clear=True), \
                 mock.patch.object(placement.pool, "GitHub", side_effect=AssertionError("API client")):
                raw = base64.b64encode(gzip.compress(json.dumps(document).encode())).decode()
                runners, queue = placement.read({**config, "CI_RUNNER_STATE": raw}, NOW)
                self.assertEqual(placement.decide(config, runners, queue, NOW).mini_jobs, expected)

    def test_status_reports_consume_live_capacity_without_a_routing_app(self):
        offered = 0
        for workflow, name in (("pr-red-checks-comment.yml", "comment"),
                               ("ci-guards.yml", "guard-status")):
            with self.subTest(workflow=workflow):
                workflow_jobs = jobs(workflow)
                bootstrap = workflow_jobs.get("portable-placement")
                if bootstrap is None:
                    continue
                step = bootstrap["steps"][-1]
                config = {key: str(value) for key, value in step["env"].items() if "${{" not in str(value)}
                config.update(SIDE_LABEL=SIDE, FLEET_LINUX="", GITHUB_RUN_ATTEMPT="1")
                placed = placement.decide(config, idle(1), snapshot(), NOW)
                self.assertEqual(placed.mini_jobs, (name,))
                self.assertEqual(placed.mini_runner, SIDE)
                self.assertEqual(placement.decide(config, idle(0), snapshot(), NOW).mini_jobs, ())
                job = workflow_jobs[name]
                needs = job["needs"] if isinstance(job["needs"], list) else [job["needs"]]
                self.assertIn("portable-placement", needs)
                self.assertIn("always()", job["if"])
                self.assertIn("!cancelled()", job["if"])
                self.assertIn("needs.portable-placement.outputs.placed_attempt == format('{0}', github.run_attempt)",
                              job["runs-on"])
                self.assertIn(f"contains(needs.portable-placement.outputs.mini_jobs, ' {name} ')", job["runs-on"])
                self.assertEqual(bootstrap["permissions"], {"contents": "read"})
                self.assertNotIn("secrets.", yaml.safe_dump(bootstrap))
                self.assertIn("CI_PORTABLE_LIGHT_JOBS_OFF != '1'", bootstrap["if"])
                offered += len(placed.mini_jobs)
        print(f"status reports offered an idle mini: {offered}/2")
        self.assertEqual(offered, 2)

    PLACED = {"cmux-next.yml": {"checks": "linux_16"},
              "cmux-next-guards.yml": {"ci-guard-group": "linux_8", "tooling-tests": "linux_4"}}

    def test_each_placed_job_reads_fleet_linux_then_its_mini_then_blacksmith(self):
        for workflow, expected_pools in self.PLACED.items():
            workflow_jobs = jobs(workflow)
            place = workflow_jobs["portable-placement"]
            listed = place["steps"][-1]["env"]["JOBS"].split()
            for name, pool in expected_pools.items():
                with self.subTest(job=f"{workflow}#{name}"):
                    job = workflow_jobs[name]
                    self.assertIn(name, listed)
                    self.assertEqual(job["needs"], ["portable-placement"])
                    self.assertTrue(str(job["if"]).startswith("${{ !cancelled()"))
                    runs_on = job["runs-on"]
                    linux = runs_on.index(f"contains(needs.portable-placement.outputs.linux_jobs, ' {name} ')")
                    mini = runs_on.index(f"contains(needs.portable-placement.outputs.mini_jobs, ' {name} ')")
                    blacksmith = runs_on.rindex(f"fromJSON(vars.RUNNER_POOLS).{pool}")
                    self.assertLess(linux, mini)
                    self.assertLess(mini, blacksmith)
                    self.assertIn("needs.portable-placement.outputs.placed_attempt == format('{0}', github.run_attempt)",
                                  runs_on)

    def test_release_notary_takes_the_placement_through_ci_guards(self):
        guards = jobs("cmux-next-guards.yml")
        self.assertIn("release-notary", guards["portable-placement"]["steps"][-1]["env"]["JOBS"].split())
        runner = guards["nightly-guards"]["with"]["guard_tests_runner"]
        self.assertIn("contains(needs.portable-placement.outputs.mini_jobs, ' release-notary ')", runner)
        tests = jobs("ci-guards.yml")["workflow-guard-tests"]["runs-on"]
        self.assertIn("inputs.guard_tests_runner != '' && inputs.guard_tests_runner", tests)
        self.assertLess(tests.index("head.repo.full_name != github.repository"), tests.index("inputs.guard_tests_runner"))

    def test_the_cmux_tui_macos_targets_take_a_free_mini_before_the_linux_cross_build(self):
        preflight = jobs("cmux-tui-artifacts.yml")["tree-preflight"]
        step = next(step for step in preflight["steps"] if step.get("id") == "darwin-mac")
        self.assertEqual(step["env"]["MAC_FIRST"].split(), ["darwin-aarch64", "darwin-x86_64"])
        self.assertEqual(step["env"]["MINI_ALL_OR_NONE"], "1")
        self.assertIn("steps.darwin-mac.outputs.mini_runner", preflight["outputs"]["darwin_mac_runner"])
        build = jobs("cmux-tui-artifacts.yml")["build"]["with"]
        self.assertEqual(build["darwin_mac_runner"], "${{ needs.tree-preflight.outputs.darwin_mac_runner }}")
        plan = (WORKFLOWS / "cmux-tui-build-package.yml").read_text(encoding="utf-8")
        self.assertIn('target["runner"] = darwin_mac_runner', plan)

    def test_cmux_tui_daemon_uses_live_gcp_output_before_measured_overflow(self):
        workflow = jobs("cmux-tui-artifacts.yml")
        preflight = workflow["tree-preflight"]
        picker = next(step for step in preflight["steps"] if step.get("id") == "linux-placement")
        self.assertEqual(picker["env"]["FLEET_LINUX"], "cmux-fleet-linux-x64")
        self.assertEqual(picker["env"]["REQUIRE_LIVE_CAPACITY"], "1")
        daemon = workflow["cmux-next-daemon-tests"]["runs-on"]
        live = daemon.index("needs.tree-preflight.outputs.linux_runner")
        fallback = daemon.index("fromJSON(vars.RUNNER_POOLS).linux_8")
        self.assertLess(live, fallback)
        self.assertEqual(workflow["tree-preflight"]["outputs"]["linux_runner"],
                         "${{ steps.linux-placement.outputs.linux_runner }}")
        # The placement counts room for the daemon job only, so no build leg takes its label.
        for name in ("build", "build-windows"):
            self.assertNotIn("linux_runner", workflow[name].get("with", {}))

    def test_the_cmux_tui_mini_pick_spends_routing_reads_only_when_the_macos_targets_may_build(self):
        # The pick reads the runners on the routing App (4 requests); a run whose tree is published, that
        # is stale, or that defers to a live owner builds nothing, so it must not spend them.
        steps = jobs("cmux-tui-artifacts.yml")["tree-preflight"]["steps"]
        ids = [step.get("id") for step in steps]
        self.assertLess(ids.index("inspect"), ids.index("route-token"))
        self.assertLess(ids.index("route-token"), ids.index("darwin-mac"))
        for name in ("route-token", "darwin-mac"):
            with self.subTest(step=name):
                self.assertIn("steps.inspect.outputs.place_macos == 'true'", steps[ids.index(name)]["if"])
        inspect = steps[ids.index("inspect")]["run"]
        decide = inspect[inspect.index("place_macos=false"):]
        self.assertIn('[[ "$run_macos" == true ]]', decide)
        self.assertIn('[[ "$owns_key" == true ]]', decide)
        self.assertIn("refs/heads/feat-cmux-next", decide)
        self.assertIn('echo "place_macos=$place_macos" >> "$GITHUB_OUTPUT"', decide)
        self.assertLess(inspect.index('echo "run_macos=$run_macos"'), inspect.index("place_macos=false"))
        self.assertLess(inspect.index('echo "owns_key=$owns_key"'), inspect.index("place_macos=false"))

    def test_the_nightly_light_jobs_read_build_nightly_app_s_placement_then_our_nightly_macs(self):
        nightly = jobs("nightly.yml")
        step = next(step for step in nightly["build-nightly-app"]["steps"] if step.get("id") == "place-light-start")
        self.assertEqual(step["env"]["NIGHTLY"], "1")
        # Unplaced, each takes our nightly-only Macs, never Blacksmith (nightlies never use it).
        fallback = "vars.CI_NIGHTLY_ONLY_RUNNER || 'glaeda-nightly-only-m4pro' }}"
        for name in step["env"]["JOBS"].split():
            with self.subTest(job=name):
                job = nightly[name]
                self.assertIn("build-nightly-app", job["needs"])
                runs_on = job["runs-on"]
                mini = runs_on.index(f"contains(needs.build-nightly-app.outputs.light_mini_jobs, ' {name} ')")
                self.assertTrue(runs_on.endswith(fallback), runs_on)
                self.assertLess(mini, runs_on.rindex(fallback))
                self.assertNotIn("blacksmith", runs_on)
                self.assertNotIn("RUNNER_POOLS", runs_on)
                self.assertIn("needs.build-nightly-app.outputs.light_attempt == format('{0}', github.run_attempt)",
                              runs_on)


    def test_new_light_workflows_place_status_jobs_before_hosted_overflow(self):
        expected = {
            "pr-checks.yml": {"jobs": ("size", "ui-review", "split"), "fallback": "fromJSON(vars.RUNNER_POOLS).linux"},
            "cmux-next-fast-gates.yml": {"jobs": ("resolve", "post"), "fallback": "fromJSON(vars.RUNNER_POOLS).linux"},
            "web-validation.yml": {"jobs": ("web-validation",), "fallback": "fromJSON(vars.RUNNER_POOLS).linux"},
        }
        for workflow, spec in expected.items():
            with self.subTest(workflow=workflow):
                workflow_jobs = jobs(workflow)
                place = workflow_jobs["portable-placement"]
                self.assertEqual(place["steps"][-1]["env"]["JOBS"].split(), list(spec["jobs"]))
                for name in spec["jobs"]:
                    job = workflow_jobs[name]
                    needs = job["needs"] if isinstance(job["needs"], list) else [job["needs"]]
                    self.assertIn("portable-placement", needs)
                    route = job["runs-on"]
                    self.assertIn(f"contains(needs.portable-placement.outputs.linux_jobs, ' {name} ')", route)
                    self.assertIn(f"contains(needs.portable-placement.outputs.mini_jobs, ' {name} ')", route)
                    self.assertIn("needs.portable-placement.outputs.placed_attempt == format('{0}', github.run_attempt)", route)
                    self.assertIn(spec["fallback"], route)

    def test_remaining_light_routers_use_live_placement_before_hosted_or_paid_fallback(self):
        ci = jobs("ci.yml")
        placement = ci["portable-placement"]
        changes = ci["changes"]
        self.assertIn("CI_PORTABLE_LIGHT_JOBS_OFF != '1'", placement["if"])
        self.assertEqual(placement["steps"][-1]["env"]["JOBS"], "changes")
        self.assertEqual(placement["steps"][-1]["env"]["LINUX_ONLY"], "changes")
        self.assertEqual(placement["steps"][-1]["env"]["REQUIRE_LIVE_CAPACITY"], "1")
        self.assertEqual(changes["needs"], ["portable-placement"])
        self.assertIn("always()", changes["if"])
        self.assertIn("!cancelled()", changes["if"])
        changes_route = changes["runs-on"]
        live_linux = changes_route.index("contains(needs.portable-placement.outputs.linux_jobs, ' changes ')")
        hosted = changes_route.index("github.run_attempt == 1 && 'ubuntu-24.04'")
        paid = changes_route.rindex("fromJSON(vars.RUNNER_POOLS).linux_8")
        self.assertNotIn("contains(needs.portable-placement.outputs.mini_jobs, ' changes ')", changes_route)
        self.assertLess(live_linux, hosted)
        self.assertLess(hosted, paid)

        next_jobs = jobs("cmux-next.yml")
        path_route = next_jobs["path_route"]
        next_placement = next_jobs["portable-placement"]
        self.assertIn("CI_PORTABLE_LIGHT_JOBS_OFF != '1'", next_placement["if"])
        self.assertEqual(next_placement["steps"][-1]["env"]["JOBS"], "checks path_route")
        self.assertEqual(path_route["needs"], ["portable-placement"])
        self.assertIn("always()", path_route["if"])
        self.assertIn("!cancelled()", path_route["if"])
        route = path_route["runs-on"]
        live_linux = route.index("contains(needs.portable-placement.outputs.linux_jobs, ' path_route ')")
        live_mini = route.index("contains(needs.portable-placement.outputs.mini_jobs, ' path_route ')")
        hosted = route.index("github.run_attempt == 1 && 'ubuntu-24.04'")
        paid = route.rindex("fromJSON(vars.RUNNER_POOLS).linux_8")
        self.assertLess(live_linux, live_mini)
        self.assertLess(live_mini, hosted)
        self.assertLess(hosted, paid)

    def test_portable_bootstraps_are_bounded_and_kill_switch_skips_the_job(self):
        expected = {
            "pr-checks.yml": ("size", "ui-review", "split"),
            "cmux-next-fast-gates.yml": ("resolve", "post"),
            "web-validation.yml": ("web-validation",),
        }
        for workflow, consumers in expected.items():
            with self.subTest(workflow=workflow):
                workflow_jobs = jobs(workflow)
                placement_job = workflow_jobs["portable-placement"]
                placement_if = str(placement_job["if"])
                self.assertIn("CI_PORTABLE_LIGHT_JOBS_OFF != '1'", placement_if)
                if workflow == "web-validation.yml":
                    self.assertIn("github.event_name != 'merge_group'", placement_if)
                route = placement_job["runs-on"]
                self.assertIn("github.run_attempt == 1 && 'ubuntu-24.04'", route)
                self.assertIn("fromJSON(vars.RUNNER_POOLS).linux_2", route)
                self.assertNotIn("vars.CI_LIGHT_LANE_RUNNER", route)
                self.assertNotIn("vars.CI_SIDE_LANE_RUNNER", route)
                # Owned labels remain inputs to capacity validation, never the
                # bootstrap's assignment before that validation can run.
                side_label = placement_job["steps"][-1]["env"]["SIDE_LABEL"]
                self.assertIn("vars.CI_LIGHT_LANE_RUNNER", side_label)
                self.assertIn("vars.CI_SIDE_LANE_RUNNER", side_label)
                self.assertEqual(placement_job["steps"][-1]["env"]["PORTABLE_ATTEMPT3_RESCUE"], "1")
                for name in consumers:
                    condition = str(workflow_jobs[name]["if"])
                    if name == "web-validation":
                        self.assertEqual(condition, "always()")
                    else:
                        self.assertIn("always()", condition)
                        self.assertIn("!cancelled()", condition)

    def test_other_portable_callers_do_not_opt_into_bot_attempt_three(self):
        for workflow in ("ci.yml", "cmux-next.yml"):
            with self.subTest(workflow=workflow):
                step = jobs(workflow)["portable-placement"]["steps"][-1]
                self.assertNotIn("PORTABLE_ATTEMPT3_RESCUE", step.get("env", {}))

    def test_merge_group_skips_placement_but_keeps_web_rollup(self):
        workflow_jobs = jobs("web-validation.yml")
        self.assertIn("github.event_name != 'merge_group'", workflow_jobs["portable-placement"]["if"])
        self.assertEqual(workflow_jobs["web-validation"]["if"], "always()")

    def test_runner_state_bootstrap_does_not_fall_through_to_github_api(self):
        state = {
            "schema": "runner-state/v1", "repository": "manaflow-ai/cmux", "complete": True,
            "generated_at": NOW.isoformat(), "repository_runners": [],
            "runner_groups": {"glaeda-minis": [dict(runner("cmux1-glaeda"), id=1, os="macOS")]},
            "scale_sets": {},
        }
        raw = base64.b64encode(gzip.compress(json.dumps(state).encode())).decode()
        config = {**env(JOBS="control"), "GITHUB_REPOSITORY": "manaflow-ai/cmux",
                  "CI_RUNNER_STATE": raw, "SNAPSHOT_TOKEN": "github-token"}
        with mock.patch.dict(os.environ, config, clear=True), \
             mock.patch.object(placement.pool.GitHub, "get_api", side_effect=AssertionError("API read")), \
             mock.patch.object(placement.pool.GitHub, "download", side_effect=AssertionError("artifact read")):
            runners, queue = placement.read(config, NOW)
        self.assertEqual(len(runners), 1)
        self.assertIsNone(queue)

    def test_placement_runs_the_trusted_base_copy(self):
        for workflow in (*self.PLACED, "pr-checks.yml", "cmux-next-fast-gates.yml", "web-validation.yml"):
            with self.subTest(workflow=workflow):
                checkout = jobs(workflow)["portable-placement"]["steps"][0]
                self.assertEqual(checkout["with"]["ref"], "${{ github.event.pull_request.base.sha || github.sha }}")


class SkippedPlacementKeepsRouting(unittest.TestCase):
    """A skipped portable-placement never skips the jobs it only places.

    The bootstrap skips on a re-run (attempt 3, or a person's attempt 2), on a fork and under
    CI_PORTABLE_LIGHT_JOBS_OFF. A job whose if calls no status function gets GitHub's implicit
    success(), which reads every ancestor, not just its needs: so after `changes` (always())
    routed web=true, run 41892308895's whole-run attempt 3 skipped `web`, its shards and the webview
    verdict, and the verdict could not be refreshed without a new commit. Each descendant says
    !cancelled() (or always()) and checks the result of each job it needs instead.
    """

    WORKFLOWS = ("ci.yml", "cmux-next.yml", "cmux-next-guards.yml")
    STATUS = re.compile(r"\b(always|cancelled|failure)\(\)")
    # Push-only and gated on its needs' results already; its 'skipped' generated-files branch would
    # start running on a first attempt with a status function, so it keeps the implicit success().
    EXEMPT = {("cmux-next.yml", "swift-exports-cache")}
    # The jobs this guard was added for: each checks every need's result, so a failed or skipped
    # router still skips them as the implicit success() did on a first attempt.
    RESULT_CHECKED = {"ci.yml": ("guards", "ghosttykit-release-check", "browser", "remote-daemon", "web",
                                 "dogfood-build"),
                      "cmux-next.yml": ("web-bundles", "request-nightly-next")}

    @staticmethod
    def needs(job: dict) -> list[str]:
        value = job.get("needs") or []
        return [value] if isinstance(value, str) else list(value)

    def descendants(self, workflow_jobs: dict, root: str) -> set[str]:
        found: set[str] = set()
        changed = True
        while changed:
            changed = False
            for name, job in workflow_jobs.items():
                if name not in found and any(need == root or need in found for need in self.needs(job or {})):
                    found.add(name)
                    changed = True
        return found

    def test_no_job_skips_because_the_placement_bootstrap_skipped(self):
        checked = 0
        for workflow in self.WORKFLOWS:
            workflow_jobs = jobs(workflow)
            self.assertIn("portable-placement", workflow_jobs, workflow)
            for name in sorted(self.descendants(workflow_jobs, "portable-placement")):
                if (workflow, name) in self.EXEMPT:
                    continue
                with self.subTest(job=f"{workflow}#{name}"):
                    condition = str(workflow_jobs[name].get("if") or "")
                    self.assertRegex(condition, self.STATUS,
                                     "a skipped portable-placement skips this job through the implicit success()")
                    checked += 1
        self.assertGreater(checked, 20)

    def test_web_and_the_other_routed_jobs_still_skip_on_a_failed_need(self):
        for workflow, names in self.RESULT_CHECKED.items():
            workflow_jobs = jobs(workflow)
            for name in names:
                with self.subTest(job=f"{workflow}#{name}"):
                    job = workflow_jobs[name]
                    condition = " ".join(str(job["if"]).split())
                    self.assertIn("!cancelled()", condition)
                    for need in self.needs(job):
                        self.assertIn(f"needs.{need}.result == 'success'", condition)

    def test_the_skip_is_what_a_rerun_or_a_fork_gets(self):
        bootstrap = str(jobs("ci.yml")["portable-placement"]["if"])
        self.assertIn("github.run_attempt == 1", bootstrap)
        self.assertIn("head.repo.full_name == github.repository", bootstrap)
        changes = str(jobs("ci.yml")["changes"]["if"])
        self.assertIn("always()", changes)


if __name__ == "__main__":
    unittest.main()
