#!/usr/bin/env python3
"""Portable jobs: fleet Linux first, then a free mini with no nightly waiting, Blacksmith last.

scripts/ci/portable_job_placement.py places the cmux-next checks, the CI guard group, the
release-notary guards, the tooling tests and the cmux-tui macOS targets (Leo, 2026-10-31: "i mean
the linux things cant our minis just run them"). These cases pin its order and its refusals, and
the workflows' wiring of its outputs.
"""
from __future__ import annotations

import datetime as dt
import importlib.util
import os
import sys
import tempfile
import unittest
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


def snapshot(pools: dict | None = None, *, age_minutes: int = 2) -> dict:
    generated = (NOW - dt.timedelta(minutes=age_minutes)).strftime("%Y-%m-%dT%H:%M:%SZ")
    return {"generated_at": generated, "pools": pools or {}}


def env(**overrides: str) -> dict:
    return {"JOBS": JOBS, "SIDE_LABEL": SIDE, "FLEET_LINUX": "blacksmith-4vcpu-ubuntu-2404",
            "GITHUB_RUN_ATTEMPT": "1", **overrides}


def idle(count: int, label: str = SIDE) -> list[dict]:
    return [runner(f"cmux{index}-glaeda", label) for index in range(count)]


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
                self.assertIn("Blacksmith", placed.why)

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

    def test_fleet_linux_comes_before_the_minis(self):
        placed = placement.decide(env(FLEET_LINUX="gcp-linux-32"), idle(5), snapshot(), NOW)
        self.assertEqual(placed.linux_runner, "gcp-linux-32")
        self.assertEqual(placed.linux_jobs, tuple(JOBS.split()))
        self.assertEqual(placed.mini_jobs, ())

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
        # An absent Linux entry in macos-pool-load says nothing about Linux queue depth.
        # The former test treated it as a zero-queue proof; it must now fail closed.
        no_linux_queue = placement.decide(config, [live], snapshot(), NOW)
        self.assertEqual((no_linux_queue.linux_runner, no_linux_queue.linux_jobs), ("", ()))
        result = placement.decide(config, [live], snapshot({"cmux-fleet-linux-x64": {"queued": 0}}), NOW)
        self.assertEqual((result.linux_runner, result.linux_jobs), ("cmux-fleet-linux-x64", ("legacy-identity-target",)))
        for label in ("macos-26", "glaeda-std-xcode-26.6", "ubuntu-24.04", "blacksmith-32vcpu-ubuntu-2404"):
            result = placement.decide({**config, "FLEET_LINUX": label}, [live], snapshot(), NOW)
            self.assertEqual((result.linux_runner, result.mini_jobs), ("", ()))

    def test_linux_queue_absence_or_malformed_count_is_unknown_even_with_idle_linux(self):
        config = env(JOBS="legacy-identity-target", LINUX_ONLY="legacy-identity-target",
                     FLEET_LINUX="cmux-fleet-linux-x64", NIGHTLY="1",
                     NIGHTLY_WAIT_FOR_FLEET="1", REQUIRE_LIVE_CAPACITY="1")
        live = {"name": "gcp", "status": "online", "busy": False, "os": "linux",
                "labels": [{"name": "cmux-fleet-linux-x64"}]}
        # A fresh macOS-only snapshot has no entry for Linux demand. Do not
        # assume a free Linux runner has an empty queue; the job may wait behind it.
        for pools in ({}, {"cmux-fleet-linux-x64": {}},
                      {"cmux-fleet-linux-x64": {"queued": None}},
                      {"cmux-fleet-linux-x64": {"queued": -1}},
                      {"cmux-fleet-linux-x64": {"queued": "0"}},
                      {"cmux-fleet-linux-x64": {"queued": True}}):
            with self.subTest(pools=pools):
                placed = placement.decide(config, [live], snapshot(pools), NOW)
                self.assertEqual((placed.linux_runner, placed.linux_jobs), ("", ()))
                self.assertIn("Linux queue depth was not observed", placed.why)
        for queued in (0, 1, 2):
            with self.subTest(queued=queued):
                placed = placement.decide(config, [live],
                                          snapshot({"cmux-fleet-linux-x64": {"queued": queued}}), NOW)
                expected = ("cmux-fleet-linux-x64", ("legacy-identity-target",)) if queued == 0 else ("", ())
                self.assertEqual((placed.linux_runner, placed.linux_jobs), expected)

    def test_linux_only_no_start_wait_is_bounded_and_can_admit_before_deadline(self):
        config = env(JOBS="legacy-identity-target", LINUX_ONLY="legacy-identity-target",
                     FLEET_LINUX="cmux-fleet-linux-x64", NIGHTLY="1",
                     NIGHTLY_WAIT_FOR_FLEET="1", REQUIRE_LIVE_CAPACITY="1")
        live = {"status": "online", "busy": False, "os": "linux",
                "labels": [{"name": "cmux-fleet-linux-x64"}]}
        known_linux = snapshot({"cmux-fleet-linux-x64": {"queued": 0}})
        for second, expected in (([], ""), ([live], "cmux-fleet-linux-x64")):
            with self.subTest(second=second), \
                 mock.patch.object(placement, "read", side_effect=[([], known_linux), (second, known_linux)]) as read, \
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


def jobs(name: str) -> dict:
    return yaml.safe_load((WORKFLOWS / name).read_text(encoding="utf-8"))["jobs"]


class Wiring(unittest.TestCase):
    def test_early_nightly_controls_try_fleet_before_blacksmith_without_signing_secrets(self):
        nightly = jobs("nightly.yml")
        step = next(s for s in nightly["decide"]["steps"] if s.get("id") == "place-early")
        self.assertEqual(step["env"]["NIGHTLY_WAIT_FOR_FLEET"], "1")
        self.assertNotIn("signer-build", step["env"]["JOBS"].split())
        for name in step["env"]["JOBS"].split():
            with self.subTest(job=name):
                job = nightly[name]
                route = job["runs-on"]
                self.assertIn("decide", job["needs"])
                self.assertIn("needs.decide.outputs.early_attempt == format('{0}', github.run_attempt)", route)
                selected = f"needs.decide.outputs.early_{name.replace('cmux-', '').replace('-', '_')}_runner"
                self.assertIn(selected, route)
                self.assertLess(route.index(selected), route.index("'blacksmith-16vcpu-ubuntu-2404'"))
                self.assertIn("needs.decide.outputs.track == 'nightly-next'", route)
                self.assertNotIn("secrets.APPLE", yaml.safe_dump(job))
                self.assertNotIn("secrets.CMUX_RELEASE_APP_KEY", yaml.safe_dump(job))

    PLACED = {"cmux-next.yml": ["checks"], "cmux-next-guards.yml": ["ci-guard-group", "tooling-tests"]}

    def test_each_placed_job_reads_fleet_linux_then_its_mini_then_blacksmith(self):
        for workflow, names in self.PLACED.items():
            workflow_jobs = jobs(workflow)
            place = workflow_jobs["portable-placement"]
            listed = place["steps"][-1]["env"]["JOBS"].split()
            for name in names:
                with self.subTest(job=f"{workflow}#{name}"):
                    job = workflow_jobs[name]
                    self.assertIn(name, listed)
                    self.assertEqual(job["needs"], ["portable-placement"])
                    self.assertTrue(str(job["if"]).startswith("${{ !cancelled()"))
                    runs_on = job["runs-on"]
                    linux = runs_on.index(f"contains(needs.portable-placement.outputs.linux_jobs, ' {name} ')")
                    mini = runs_on.index(f"contains(needs.portable-placement.outputs.mini_jobs, ' {name} ')")
                    blacksmith = runs_on.rindex("'blacksmith-")
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

    def test_the_nightly_light_jobs_read_build_nightly_app_s_placement_then_blacksmith(self):
        nightly = jobs("nightly.yml")
        step = next(step for step in nightly["build-nightly-app"]["steps"] if step.get("id") == "place-light")
        self.assertEqual(step["env"]["NIGHTLY"], "1")
        for name in step["env"]["JOBS"].split():
            with self.subTest(job=name):
                job = nightly[name]
                self.assertIn("build-nightly-app", job["needs"])
                runs_on = job["runs-on"]
                mini = runs_on.index(f"contains(needs.build-nightly-app.outputs.light_mini_jobs, ' {name} ')")
                self.assertLess(mini, runs_on.rindex("'blacksmith-"))
                self.assertIn("needs.build-nightly-app.outputs.light_attempt == format('{0}', github.run_attempt)",
                              runs_on)

    def test_placement_runs_the_trusted_base_copy(self):
        for workflow in self.PLACED:
            with self.subTest(workflow=workflow):
                checkout = jobs(workflow)["portable-placement"]["steps"][0]
                self.assertEqual(checkout["with"]["ref"], "${{ github.event.pull_request.base.sha || github.sha }}")


if __name__ == "__main__":
    unittest.main()
