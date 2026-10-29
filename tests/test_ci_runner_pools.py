#!/usr/bin/env python3
"""scripts/ci/runner_pools.py keeps RUNNER_POOLS on a live member of every declared pool."""

from __future__ import annotations

import datetime as dt
import json
import sys
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
import runner_pools  # noqa: E402

NOW = dt.datetime(2026, 10, 28, 23, 0, tzinfo=dt.timezone.utc)
PIN = "/Applications/Xcode_26.6.app"
POOLS = {
    "linux": {"why": "x", "members": ["blacksmith-32vcpu-ubuntu-2404", "blacksmith-16vcpu-ubuntu-2404"]},
    "macos_26": {"why": "x", "owned": True, "members": ["blacksmith-6vcpu-macos-26", "{std}"]},
    "macos_signing": {"why": "x", "members": ["blacksmith-6vcpu-macos-26", "blacksmith-12vcpu-macos-26"]},
}


def owned() -> dict[str, str]:
    return runner_pools.owned_labels(PIN)


class Declared(unittest.TestCase):
    def test_the_declared_pools_are_valid(self) -> None:
        self.assertEqual(runner_pools.spec_problems(runner_pools.load_pools()), [])

    def test_the_linux_pool_is_the_runner_set(self) -> None:
        # Leo, 2026-10-28: "just pin the set of the shit that isn't hilariously slow".
        self.assertEqual(runner_pools.load_pools()["linux"]["members"],
                         ["blacksmith-32vcpu-ubuntu-2404", "blacksmith-16vcpu-ubuntu-2404"])

    def test_signing_never_resolves_to_a_reused_machine(self) -> None:
        pools = runner_pools.load_pools()
        for label in runner_pools.members(pools["macos_signing"], owned()):
            self.assertRegex(label, runner_pools.EPHEMERAL)

    def test_spec_problems_refuse_owned_hosted_and_unknown_labels(self) -> None:
        bad = {
            "a": {"why": "x", "members": ["{std}"]},
            "b": {"why": "x", "members": ["ubuntu-24.04"]},
            "c": {"why": "x", "hosted": True, "members": ["ubuntu-24.04"]},
            "d": {"why": "x", "members": ["some-host"]},
            "E": {"why": "x", "members": ["blacksmith-32vcpu-ubuntu-2404"]},
            "f": {"members": ["blacksmith-32vcpu-ubuntu-2404"]},
        }
        found = "\n".join(runner_pools.spec_problems(bad))
        for name in ("pools.a", "pools.b", "pools.c", "pools.d", "pools.E", "pools.f"):
            self.assertIn(name, found)

    def test_the_reconciler_runs_in_the_overflow_watch_with_the_switch_token(self) -> None:
        # No new credential: the token the overflow switch already mints writes RUNNER_POOLS.
        workflow = yaml.safe_load((ROOT / ".github/workflows/ci-cloud-overflow-probe.yml").read_text())
        steps = workflow["jobs"]["watch"]["steps"]
        [step] = [s for s in steps if "runner_pools.py" in str(s.get("run", ""))]
        self.assertEqual(step["env"]["SWITCH_TOKEN"], "${{ steps.switch-token.outputs.token }}")
        self.assertEqual(step["env"]["RUNNER_POOLS"], "${{ vars.RUNNER_POOLS }}")
        self.assertIn("always()", str(step.get("if")))


class Reconcile(unittest.TestCase):
    def run_once(self, current, dead=(), served=(), now=NOW):
        return runner_pools.reconcile(current, POOLS, owned=owned(), dead_now=dead, served_now=served, now=now)

    def test_first_pass_points_every_pool_at_its_first_member(self) -> None:
        value, _ = self.run_once({})
        self.assertEqual(value["linux"], "blacksmith-32vcpu-ubuntu-2404")
        self.assertEqual(value["macos_26"], "blacksmith-6vcpu-macos-26")
        self.assertEqual(value["_dead"], {})

    def test_a_dead_member_moves_its_pools_to_the_next(self) -> None:
        value, lines = self.run_once({}, dead={"blacksmith-6vcpu-macos-26"})
        self.assertEqual(value["macos_26"], "glaeda-std-xcode-26.6")
        self.assertEqual(value["macos_signing"], "blacksmith-12vcpu-macos-26")
        self.assertIn("pools.macos_26: unset -> glaeda-std-xcode-26.6", lines)

    def test_a_mark_holds_until_it_expires_or_the_probe_starts_there(self) -> None:
        first, _ = self.run_once({}, dead={"blacksmith-32vcpu-ubuntu-2404"})
        self.assertEqual(first["linux"], "blacksmith-16vcpu-ubuntu-2404")
        held, _ = self.run_once(first, now=NOW + dt.timedelta(minutes=20))
        self.assertEqual(held["linux"], "blacksmith-16vcpu-ubuntu-2404")
        expired, _ = self.run_once(first, now=NOW + runner_pools.DEAD_TTL)
        self.assertEqual(expired["linux"], "blacksmith-32vcpu-ubuntu-2404")
        probed, _ = self.run_once(first, served={"blacksmith-32vcpu-ubuntu-2404"}, now=NOW + dt.timedelta(minutes=5))
        self.assertEqual(probed["linux"], "blacksmith-32vcpu-ubuntu-2404")

    def test_every_member_dead_keeps_the_first(self) -> None:
        value, _ = self.run_once({}, dead={"blacksmith-32vcpu-ubuntu-2404", "blacksmith-16vcpu-ubuntu-2404"})
        self.assertEqual(value["linux"], "blacksmith-32vcpu-ubuntu-2404")

    def test_no_change_keeps_the_value_byte_for_byte(self) -> None:
        value, _ = self.run_once({})
        again, lines = self.run_once(value, now=NOW + dt.timedelta(minutes=10))
        self.assertEqual(runner_pools.render(again), runner_pools.render(value))
        self.assertEqual(lines, [])

    def test_no_pin_drops_owned_members(self) -> None:
        value, _ = runner_pools.reconcile({}, POOLS, owned={}, dead_now={"blacksmith-6vcpu-macos-26"},
                                          served_now=(), now=NOW)
        self.assertEqual(value["macos_26"], "blacksmith-6vcpu-macos-26")

    def test_janitor_snapshot_labels(self) -> None:
        snapshot = {"dead_labels": [{"label": "blacksmith-16vcpu-ubuntu-2404"}],
                    "starved": [{"label": "glaeda-gui-std-xcode-26.6"}]}
        self.assertEqual(runner_pools.dead_from_snapshot(snapshot),
                         {"blacksmith-16vcpu-ubuntu-2404", "glaeda-gui-std-xcode-26.6"})
        self.assertEqual(runner_pools.dead_from_snapshot(None), set())


class Check(unittest.TestCase):
    def test_value_problems(self) -> None:
        value, _ = runner_pools.reconcile({}, POOLS, owned=owned(), dead_now=(), served_now=(), now=NOW)
        self.assertEqual(runner_pools.value_problems(value, POOLS, owned()), [])
        self.assertTrue(runner_pools.value_problems({**value, "linux": "ubuntu-24.04"}, POOLS, owned()))
        missing = dict(value)
        del missing["macos_26"]
        self.assertTrue(runner_pools.value_problems(missing, POOLS, owned()))


class Main(unittest.TestCase):
    class Api:
        def __init__(self, snapshot):
            self._snapshot = snapshot

        def snapshot(self, *, now):
            return self._snapshot

    class Switch:
        def __init__(self):
            self.writes = []

        def set_variable(self, name, value):
            self.writes.append((name, value))

    def test_a_stalled_probe_and_the_snapshot_are_written_once(self) -> None:
        switch = self.Switch()
        with tempfile.TemporaryDirectory() as tmp:
            env = {"RUNNER_POOLS": "", "PROBE_LABEL": "blacksmith-32vcpu-ubuntu-2404", "PROBE_OUTCOME": "stalled",
                   "CMUX_CI_XCODE_APP_PR": PIN, "GITHUB_STEP_SUMMARY": f"{tmp}/summary"}
            code = runner_pools.main([], env, api=self.Api({"dead_labels": []}), switch=switch, now=NOW)
        self.assertEqual(code, 0)
        [(name, raw)] = switch.writes
        self.assertEqual(name, "RUNNER_POOLS")
        self.assertEqual(json.loads(raw)["linux"], "blacksmith-16vcpu-ubuntu-2404")

    def test_nothing_changed_writes_nothing(self) -> None:
        switch = self.Switch()
        env = {"RUNNER_POOLS": "", "CMUX_CI_XCODE_APP_PR": PIN}
        runner_pools.main([], env, api=self.Api(None), switch=switch, now=NOW)
        env["RUNNER_POOLS"] = switch.writes[0][1]
        runner_pools.main([], env, api=self.Api(None), switch=switch, now=NOW + dt.timedelta(minutes=10))
        self.assertEqual(len(switch.writes), 1)

    def test_check_fails_on_an_unset_variable(self) -> None:
        self.assertEqual(runner_pools.main(["--check"], {"RUNNER_POOLS": "", "CMUX_CI_XCODE_APP_PR": PIN}), 1)


if __name__ == "__main__":
    unittest.main()
