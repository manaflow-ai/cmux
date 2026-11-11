#!/usr/bin/env python3
"""CI_BLACKSMITH_OFF='1' moves every runner variable off Blacksmith; deleting it puts each one back.

Leo, 2026-11-10: "just stop using blacksmith temporarily". No runs-on changes for this: the switch works through
the two writers jobs already read, so it is checked here on those writers.

- runner_pools.py: every pool that has a Blacksmith member points at its declared `off` label (the GCP fleet's
  cmux-fleet-linux-x64, the owned std Mac pool, or GitHub-hosted arm64 Linux or Windows), and back at its members
  once the switch is unset.
- cloud_overflow_switch.py: with the switch on, the watch probes nothing and writes LINUX_RUNNER,
  CI_TRUSTED_RUNNER and the macOS variables off Blacksmith through its record; with it unset again and every
  probe started, it restores exactly what the record holds.
"""
from __future__ import annotations

import datetime as dt
import json
import sys
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
import cloud_overflow_switch as switch  # noqa: E402
import runner_pools  # noqa: E402

NOW = dt.datetime(2026, 11, 11, 1, 0, tzinfo=dt.timezone.utc)
XCODE = "/Applications/Xcode_26.6.app"


def blacksmith(label: object) -> bool:
    return isinstance(label, str) and label.startswith("blacksmith-")


class Pools(unittest.TestCase):
    def test_every_blacksmith_pool_declares_a_non_blacksmith_off_label(self):
        pools = runner_pools.load_pools()
        self.assertEqual(runner_pools.spec_problems(pools), [])
        for name, spec in pools.items():
            if spec.get("hosted"):
                continue
            with self.subTest(pool=name):
                self.assertTrue(any(blacksmith(member) for member in spec["members"]))
                self.assertFalse(blacksmith(spec.get("off")), spec.get("off"))
                self.assertTrue(spec.get("off"), "a Blacksmith pool names where it goes while the switch is on")

    def test_on_every_pool_reads_off_blacksmith_and_unset_goes_back(self):
        pools = runner_pools.load_pools()
        off, lines = runner_pools.reconcile({}, pools, dead_now=[], served_now=[], now=NOW, off=True)
        for name in pools:
            with self.subTest(pool=name):
                self.assertFalse(blacksmith(off[name]), off[name])
        self.assertEqual(off["linux"], "cmux-fleet-linux-x64")
        self.assertEqual(off["macos_26"], "glaeda-std-xcode-26.6")
        # The value written while on is valid (parse_value keeps it, --check passes) ...
        current, dropped = runner_pools.parse_value(runner_pools.render(off), pools)
        self.assertEqual(dropped, [])
        self.assertEqual(runner_pools.value_problems(current, pools), [])
        # ... and the first pass with the switch unset points each pool back at its first member.
        back, _ = runner_pools.reconcile(current, pools, dead_now=[], served_now=[], now=NOW)
        for name, spec in pools.items():
            with self.subTest(pool=name):
                self.assertEqual(back[name], spec["members"][0])

    def test_unset_changes_nothing(self):
        pools = runner_pools.load_pools()
        plain, _ = runner_pools.reconcile({}, pools, dead_now=[], served_now=[], now=NOW)
        self.assertEqual({name: plain[name] for name in pools}, {name: spec["members"][0] for name, spec in pools.items()})
        self.assertFalse(runner_pools.blacksmith_off({}))
        self.assertFalse(runner_pools.blacksmith_off({"CI_BLACKSMITH_OFF": "0"}))
        self.assertTrue(runner_pools.blacksmith_off({"CI_BLACKSMITH_OFF": "1"}))

    def test_spec_refuses_a_blacksmith_or_unexplained_hosted_off_label(self):
        bad = {
            "a": {"why": "x", "members": ["blacksmith-4vcpu-ubuntu-2404"], "off": "blacksmith-16vcpu-ubuntu-2404"},
            "b": {"why": "x", "members": ["blacksmith-4vcpu-windows-2025"], "off": "windows-2025"},
            "c": {"why": "x", "members": ["blacksmith-6vcpu-macos-26"], "off": "some-host"},
        }
        found = "\n".join(runner_pools.spec_problems(bad))
        for name in bad:
            self.assertIn(f"pools.{name}:", found)


class FakeSwitch:
    def __init__(self, values):
        self.values = dict(values)
        self.writes = []

    def set_variable(self, name, value):
        self.values[name] = value
        self.writes.append((name, value))

    def delete_variable(self, name):
        self.values.pop(name, None)
        self.writes.append((name, None))


def env_for(values, **extra):
    block = "\n".join(f"{name}={values.get(name, '')}" for name in switch.SWITCHED_VARIABLES)
    env = {"GH_REPO": "manaflow-ai/cmux", "GITHUB_RUN_ID": "1", "GH_TOKEN": "x",
           "CMUX_CI_RUNNER_VARIABLES": block, "VAR_CMUX_CI_XCODE_APP_PR": XCODE,
           "VAR_CI_CLOUD_OVERFLOW_SAVED": values.get(switch.RECORD_VARIABLE, "")}
    env.update(extra)
    return env


class StartedProbes:
    """Every probe job of this run has started."""

    def jobs(self, run_id, attempt=None):
        return [{"name": switch.probe_job_name(label), "status": "in_progress", "runner_name": "r",
                 "started_at": "2026-11-11T00:59:00Z", "created_at": "2026-11-11T00:58:00Z"}
                for label in switch.PROBE_LABELS]


class NoApi:
    def jobs(self, *args, **kwargs):
        raise AssertionError("the switch probes nothing while CI_BLACKSMITH_OFF is on")


class OverflowSwitch(unittest.TestCase):
    LIVE = {"LINUX_RUNNER": "blacksmith-4vcpu-ubuntu-2404", "CI_TRUSTED_RUNNER": "blacksmith-2vcpu-ubuntu-2404",
            "MACOS_RUNNER_15": "blacksmith-6vcpu-macos-15"}

    def test_off_values_name_no_blacksmith_label(self):
        failover, _ = switch.failover_values(XCODE, None)
        values = switch.off_values(failover)
        self.assertEqual(values["LINUX_RUNNER"], "cmux-fleet-linux-x64")
        self.assertEqual(values["CI_TRUSTED_RUNNER"], "ubuntu-24.04")
        for name, value in values.items():
            with self.subTest(variable=name):
                self.assertFalse(blacksmith(value), value)
                self.assertTrue(switch.signing_safe(name, value))

    def test_on_moves_every_variable_off_blacksmith_then_unset_restores_exactly(self):
        fake = FakeSwitch(self.LIVE)
        code = switch.main([], env_for(fake.values, CI_BLACKSMITH_OFF="1"), api=NoApi(), switch=fake,
                           now=lambda: NOW, sleep=lambda _: None)
        self.assertEqual(code, 0)
        record = json.loads(fake.values[switch.RECORD_VARIABLE])
        self.assertTrue(record[switch.OFF_RECORD_KEY])
        for name in switch.SWITCHED_VARIABLES:
            value = fake.values.get(name)
            with self.subTest(variable=name):
                # Unset readers fall back to Blacksmith literals, so a variable with an off value must hold it,
                # except one signing jobs read (it keeps its value; the PR names it as not covered).
                if switch.signing_safe(name, "glaeda-std-xcode-26.6") or name in switch.LINUX_VARIABLES:
                    self.assertTrue(value, name)
                    self.assertFalse(blacksmith(value), value)
        self.assertEqual(fake.values["LINUX_RUNNER"], "cmux-fleet-linux-x64")
        self.assertEqual(fake.values["CI_TRUSTED_RUNNER"], "ubuntu-24.04")
        # A second pass with the switch still on writes nothing.
        writes = len(fake.writes)
        switch.main([], env_for(fake.values, CI_BLACKSMITH_OFF="1"), api=NoApi(), switch=fake,
                    now=lambda: NOW, sleep=lambda _: None)
        self.assertEqual(len(fake.writes), writes)
        # Unset: the probes run, all start, and each variable goes back to exactly its value before.
        switch.main([], env_for(fake.values), api=StartedProbes(), switch=fake,
                    now=lambda: NOW, sleep=lambda _: None)
        self.assertNotIn(switch.RECORD_VARIABLE, fake.values)
        for name in switch.SWITCHED_VARIABLES:
            with self.subTest(variable=name):
                self.assertEqual(fake.values.get(name), self.LIVE.get(name))

    def test_on_during_an_outage_failover_keeps_the_original_befores(self):
        outage = {"since": "2026-11-11T00:00:00Z", "probe": "x", "changed": {
            "LINUX_RUNNER": {"before": "blacksmith-4vcpu-ubuntu-2404", "after": "blacksmith-16vcpu-ubuntu-2404"}}}
        current = {"LINUX_RUNNER": "blacksmith-16vcpu-ubuntu-2404", "CI_TRUSTED_RUNNER": None}
        changed = switch.plan_blacksmith_off(outage, current, {"LINUX_RUNNER": "cmux-fleet-linux-x64",
                                                               "CI_TRUSTED_RUNNER": "ubuntu-24.04"})
        self.assertEqual(changed["LINUX_RUNNER"], {"before": "blacksmith-4vcpu-ubuntu-2404",
                                                   "after": "cmux-fleet-linux-x64"})
        self.assertEqual(changed["CI_TRUSTED_RUNNER"], {"before": None, "after": "ubuntu-24.04"})
        # A variable someone pointed elsewhere by hand is left alone.
        mine = switch.plan_blacksmith_off(None, {"LINUX_RUNNER": "my-runner"}, {"LINUX_RUNNER": "cmux-fleet-linux-x64"})
        self.assertEqual(mine, {})


class Workflow(unittest.TestCase):
    def test_the_probe_is_skipped_and_the_pools_take_off_labels_while_on(self):
        text = (ROOT / ".github/workflows/ci-cloud-overflow-probe.yml").read_text(encoding="utf-8")
        jobs = yaml.safe_load(text)["jobs"]
        self.assertIn("vars.CI_BLACKSMITH_OFF != '1'", jobs["probe"]["if"])
        self.assertIn("vars.CI_BLACKSMITH_OFF == '1' && 'ubuntu-24.04'", jobs["watch"]["runs-on"])
        steps = {step.get("name"): step for step in jobs["watch"]["steps"]}
        self.assertEqual(steps["Probe and switch"]["env"]["CI_BLACKSMITH_OFF"], "${{ vars.CI_BLACKSMITH_OFF }}")
        pools = steps["Point the runner pools at live members"]
        self.assertEqual(pools["env"]["CI_BLACKSMITH_OFF"], "${{ vars.CI_BLACKSMITH_OFF }}")
        self.assertIn('if [ "$CI_BLACKSMITH_OFF" = 1 ]; then\n  python3 scripts/ci/runner_pools.py', pools["run"])
        self.assertIn("steps.switch.outputs.outcome != 'off'", steps["End this run's stuck probe"]["if"])


if __name__ == "__main__":
    sys.exit(unittest.main())
