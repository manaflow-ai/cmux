#!/usr/bin/env python3
"""scripts/ci/runner_pools.py keeps RUNNER_POOLS on a live member of every declared pool."""

from __future__ import annotations

import copy
import datetime as dt
import importlib.util
import json
import os
import re
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
import runner_pools  # noqa: E402

# The queue janitor's macos-pool-load snapshot as main's janitor wrote it at 22:53Z on 2026-10-28
# (runner names and warm state dropped). Its starved and unserved are empty: they describe owned
# glaeda-* labels, never pool members.
# CI_CLOUD_OVERFLOW_SAVED as the switch wrote it at 04:23Z on 2026-11-01 (trimmed): only macOS variables.
MACOS_ONLY_RECORD = json.dumps({"changed": {"MACOS_RUNNER_PR": {"after": "glaeda-std-xcode-26.6",
                                                                "before": "blacksmith-6vcpu-macos-26"}},
                                "since": "2026-11-01T04:23:40Z"})
SWITCHED_LINUX = json.dumps({"changed": {"LINUX_RUNNER": {"after": "blacksmith-16vcpu-ubuntu-2404",
                                                          "before": "blacksmith-32vcpu-ubuntu-2404"}}})
RECORDED = json.loads((ROOT / "tests/fixtures/runner-pools/macos-pool-load-2026-10-28T2253Z.json").read_text())
SNAPSHOT_AT = dt.datetime(2026, 10, 28, 22, 53, 37, tzinfo=dt.timezone.utc)
NOW = SNAPSHOT_AT + dt.timedelta(minutes=2)
POOLS = {
    "linux": {"why": "x", "members": ["blacksmith-32vcpu-ubuntu-2404", "blacksmith-16vcpu-ubuntu-2404"]},
    "macos_26": {"why": "x", "members": ["blacksmith-6vcpu-macos-26", "blacksmith-12vcpu-macos-26"]},
    "macos_26_large": {"why": "x", "members": ["blacksmith-12vcpu-macos-26", "blacksmith-6vcpu-macos-26"]},
}

# These unit tests exercise the legacy Blacksmith-only writer in this checkout.
# The live declaration now also carries the secretless fleet Linux route and is
# validated separately by AdapterWiring below. Keeping an explicit fixture
# here means the writer tests retain their original contract while the wiring
# test covers the schema the workflow actually invokes.
LEGACY_POOLS = {
    "linux": {"why": "x", "members": ["blacksmith-4vcpu-ubuntu-2404", "blacksmith-16vcpu-ubuntu-2404"]},
    "macos_26": {"why": "x", "members": ["blacksmith-6vcpu-macos-26", "blacksmith-12vcpu-macos-26"]},
    "macos_26_large": {"why": "x", "members": ["blacksmith-12vcpu-macos-26", "blacksmith-6vcpu-macos-26"]},
}


def legacy_pools():
    return copy.deepcopy(LEGACY_POOLS)


def reviewed_adapter():
    """Load the exact adapter checkout used by the guarded workflows."""
    root = Path(os.environ.get("RUNNER_POOL_TOOLING_ROOT", ""))
    path = root / "scripts/ci/runner_pool_reconcile.py"
    if not path.is_file():
        raise AssertionError(
            "RUNNER_POOL_TOOLING_ROOT must point at the reviewed feat adapter "
            f"(missing {path})"
        )
    spec = importlib.util.spec_from_file_location("reviewed_runner_pool_reconcile", path)
    if spec is None or spec.loader is None:
        raise AssertionError(f"cannot load reviewed adapter {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class LegacyWriter(unittest.TestCase):
    """Keep legacy writer tests on their explicit pre-fleet schema fixture."""

    def setUp(self):
        self._load_pools = runner_pools.load_pools
        runner_pools.load_pools = legacy_pools

    def tearDown(self):
        runner_pools.load_pools = self._load_pools


class AdapterWiring(unittest.TestCase):
    """The workflow's checked-out feat adapter must consume main's schema."""

    def test_reviewed_adapter_accepts_the_declared_fleet_schema(self):
        adapter = reviewed_adapter()
        policy = adapter.load_policy(ROOT)
        pools = policy.load_pools()
        self.assertEqual(adapter.spec_problems(policy, pools), [])
        self.assertIn("cmux-fleet-linux-x64", pools["linux"]["members"])
        self.assertIn("linux_ephemeral", pools)

    def test_reviewed_adapter_keeps_fleet_route_when_probe_started(self):
        adapter = reviewed_adapter()
        policy = adapter.load_policy(ROOT)
        pools = policy.load_pools()
        health = {"checked": policy.iso(NOW), "minutes": 3,
                  "labels": {"cmux-fleet-linux-x64": "started"}}
        value, _ = adapter.plan(policy, None, pools, health, None, now=NOW)
        self.assertEqual(value["linux"], "cmux-fleet-linux-x64")
        self.assertIn(value["linux_ephemeral"], pools["linux_ephemeral"]["members"])


def health(labels, checked=NOW):
    # Exactly what the overflow switch writes to CI_CLOUD_LABEL_HEALTH (cloud_overflow_switch.label_health()).
    import cloud_overflow_switch as switch
    stalled = [label for label, state in labels.items() if state == "stalled"]
    return switch.label_health(list(labels), stalled, checked=runner_pools.iso(checked),
                               run="https://github.com/x/y/actions/runs/1", minutes=5)


class Declared(unittest.TestCase):
    def test_the_declared_pools_are_valid(self) -> None:
        adapter = reviewed_adapter()
        policy = adapter.load_policy(ROOT)
        self.assertEqual(adapter.spec_problems(policy, policy.load_pools()), [])

    def test_the_linux_pool_is_the_runner_set(self) -> None:
        # Leo, 2026-10-28: "just pin the set of the shit that isn't hilariously slow".
        # Smallest first: Blacksmith caps vCPUs at once, so the live member is the small size (2026-11-01).
        pools = runner_pools.load_pools()
        self.assertEqual(pools["linux"]["members"][0], "cmux-fleet-linux-x64")
        self.assertEqual(pools["linux_ephemeral"]["members"],
                         ["blacksmith-8vcpu-ubuntu-2404", "blacksmith-16vcpu-ubuntu-2404",
                          "blacksmith-4vcpu-ubuntu-2404"])

    def test_every_bounded_selector_accepts_every_linux_member(self) -> None:
        # Review of #30340: a member a bounded selector refuses (contains([...], vars.LINUX_RUNNER) && ... || '<4 vCPU>')
        # sends its readers back to the stalled size when the pool steps onto it.
        selector = re.compile(r"contains\(fromJSON\('(\[[^']*\])'\), (?:vars\.LINUX_RUNNER|fromJSON\(vars\.RUNNER_POOLS[^)]*\)\.linux)\)"
                              r" && (?:vars\.LINUX_RUNNER|fromJSON\(vars\.RUNNER_POOLS[^)]*\)\.linux) \|\| '(blacksmith-4vcpu-ubuntu-2404)'")
        # Selector arrays must cover the live secret-bearing mirror, including
        # the measured 8-vCPU overflow member. The fleet label itself is only
        # for the adapter's secretless route.
        members = runner_pools.load_pools()["linux_ephemeral"]["members"]
        found = 0
        for workflow in sorted((ROOT / ".github/workflows").glob("*.y*ml")):
            for match in selector.finditer(workflow.read_text(encoding="utf-8")):
                found += 1
                with self.subTest(workflow=workflow.name):
                    self.assertLessEqual(set(members), set(json.loads(match.group(1))))
        self.assertGreater(found, 0)

    def test_no_pool_names_a_reused_machine(self) -> None:
        # A job reading a pool, a fork's pull request included, never lands on an owned Mac:
        # those come only through a picker.
        for name, spec in runner_pools.load_pools().items():
            if name == "linux":
                continue  # the fleet member is admitted by the reviewed adapter
            for label in runner_pools.members(spec):
                with self.subTest(pool=name, label=label):
                    self.assertRegex(label, runner_pools.HOSTED if spec.get("hosted") else runner_pools.EPHEMERAL)

    def test_spec_problems_refuse_owned_hosted_and_unknown_labels(self) -> None:
        bad = {
            "a": {"why": "x", "members": ["glaeda-std-xcode-26.6"]},
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
        [step] = [s for s in steps if "runner_pool_reconcile.py" in str(s.get("run", ""))
                  and "--source-root" in str(s.get("run", ""))
                  and "--probe" not in str(s.get("run", ""))]
        self.assertEqual(step["env"]["SWITCH_TOKEN"], "${{ steps.switch-token.outputs.token }}")
        self.assertEqual(step["env"]["RUNNER_POOLS"], "${{ vars.RUNNER_POOLS }}")
        self.assertIn("always()", str(step.get("if")))
        names = [s.get("name") for s in steps]
        self.assertLess(names.index(step["name"]), names.index("End this run's stuck probe"))


class Evidence(LegacyWriter):
    def test_it_reads_the_variable_the_switch_writes(self) -> None:
        import cloud_overflow_switch as switch
        self.assertEqual(runner_pools.HEALTH_VARIABLE, switch.HEALTH_VARIABLE)
        # The switch probes every member of the linux pool, so each one has health of its own.
        self.assertTrue(set(switch.PROBE_LABELS) <= set(legacy_pools()["linux"]["members"]))

    def test_the_recorded_snapshot_marks_nothing(self) -> None:
        dead, started, _ = runner_pools.label_evidence(None, RECORDED, now=NOW)
        self.assertEqual((dead, started), (set(), set()))

    def test_a_stalled_blacksmith_mac_in_the_snapshot_is_dead(self) -> None:
        # simple_pool_picker.blacksmith_stalled(): a queued job waited 10 minutes, so nothing started.
        snapshot = copy.deepcopy(RECORDED)
        snapshot["pools"]["blacksmith-6vcpu-macos-26"].update(queued=3, oldest_queued_minutes=9)
        dead, _, _ = runner_pools.label_evidence(None, snapshot, now=NOW)
        self.assertEqual(dead, {"blacksmith-6vcpu-macos-26"})
        # Owned labels in the snapshot are never pool members and are not read.
        snapshot["pools"]["glaeda-std-xcode-26.6"].update(queued=9, oldest_queued_minutes=60)
        snapshot["starved"] = [{"label": "glaeda-gui-std-xcode-26.6+glaeda-std-xcode-26.6", "queued": 1}]
        dead, _, _ = runner_pools.label_evidence(None, snapshot, now=NOW)
        self.assertEqual(dead, {"blacksmith-6vcpu-macos-26"})

    def test_dead_label_entries_split_on_comma_and_plus(self) -> None:
        # cmux#27114's DeadLabel.as_json(): label sets joined with ",", live members listed.
        snapshot = dict(RECORDED, dead_labels=[{
            "label": "blacksmith-16vcpu-ubuntu-2404", "family": "linux", "queued": 4,
            "oldest_queued_minutes": 6, "live": ["blacksmith-32vcpu-ubuntu-2404"]}])
        dead, started, _ = runner_pools.label_evidence(None, snapshot, now=NOW)
        self.assertEqual(dead, {"blacksmith-16vcpu-ubuntu-2404"})
        self.assertEqual(started, {"blacksmith-32vcpu-ubuntu-2404"})
        self.assertEqual(runner_pools._labels("a,b+c"), {"a", "b", "c"})

    def test_probe_health_per_label(self) -> None:
        dead, started, _ = runner_pools.label_evidence(health({
            "blacksmith-32vcpu-ubuntu-2404": "stalled", "blacksmith-16vcpu-ubuntu-2404": "started"}), None, now=NOW)
        self.assertEqual(dead, {"blacksmith-32vcpu-ubuntu-2404"})
        self.assertEqual(started, {"blacksmith-16vcpu-ubuntu-2404"})

    def test_no_evidence_retires_nothing(self) -> None:
        # Fail closed: with CI_CLOUD_LABEL_HEALTH absent (cmux#27121 not deployed) and no snapshot,
        # nothing is marked dead, and the pools stay on their first members.
        dead, started, _ = runner_pools.label_evidence(None, None, now=NOW)
        self.assertEqual((dead, started), (set(), set()))
        switch = Main.Switch()
        self.assertEqual(runner_pools.main([], {"RUNNER_POOLS": ""}, api=Main.Api(None), switch=switch, now=NOW), 0)
        value = json.loads(switch.writes[0][1])
        self.assertEqual(value["_dead"], {})
        for name, spec in legacy_pools().items():
            self.assertEqual(value[name], spec["members"][0])

    def test_an_undated_stale_or_future_snapshot_decides_nothing(self) -> None:
        stalled = copy.deepcopy(RECORDED)
        stalled["pools"]["blacksmith-6vcpu-macos-26"].update(queued=3, oldest_queued_minutes=30)
        stalled["dead_labels"] = [{"label": "blacksmith-16vcpu-ubuntu-2404", "live": []}]
        dead, _, _ = runner_pools.label_evidence(None, stalled, now=NOW)
        self.assertEqual(dead, {"blacksmith-6vcpu-macos-26", "blacksmith-16vcpu-ubuntu-2404"})
        for generated in (None, "yesterday", "2026-10-28T22:53:37",
                          runner_pools.iso(NOW - runner_pools.SNAPSHOT_MAX_AGE - dt.timedelta(minutes=1)),
                          runner_pools.iso(NOW + dt.timedelta(hours=1))):
            with self.subTest(generated=generated):
                snapshot = dict(stalled, generated_at=generated)
                dead, started, notes = runner_pools.label_evidence(None, snapshot, now=NOW)
                self.assertEqual((dead, started), (set(), set()))
                self.assertTrue(notes)

    def test_old_or_unreadable_health_decides_nothing(self) -> None:
        old = health({"blacksmith-32vcpu-ubuntu-2404": "stalled"}, checked=NOW - dt.timedelta(hours=1))
        future = health({"blacksmith-32vcpu-ubuntu-2404": "stalled"}, checked=NOW + dt.timedelta(hours=1))
        for value in (old, future, {"labels": []}, {"checked": "2026-10-28T22:00:00", "labels": {}}):
            dead, started, notes = runner_pools.label_evidence(value, None, now=NOW)
            self.assertEqual((dead, started), (set(), set()))
            self.assertTrue(notes)


class Reconcile(unittest.TestCase):
    def run_once(self, current, dead=(), served=(), now=NOW):
        return runner_pools.reconcile(current, POOLS, dead_now=dead, served_now=served, now=now)

    def test_first_pass_points_every_pool_at_its_first_member(self) -> None:
        value, _ = self.run_once({})
        self.assertEqual(value["linux"], "blacksmith-32vcpu-ubuntu-2404")
        self.assertEqual(value["macos_26"], "blacksmith-6vcpu-macos-26")
        self.assertEqual(value["macos_26_large"], "blacksmith-12vcpu-macos-26")
        self.assertEqual(value["_dead"], {})

    def test_a_dead_member_flips_its_pools_to_the_next(self) -> None:
        value, lines = self.run_once({}, dead={"blacksmith-6vcpu-macos-26"})
        self.assertEqual(value["macos_26"], "blacksmith-12vcpu-macos-26")
        self.assertEqual(value["macos_26_large"], "blacksmith-12vcpu-macos-26")
        self.assertIn("pools.macos_26: unset -> blacksmith-12vcpu-macos-26", lines)

    def test_a_mark_holds_until_it_expires_or_the_label_starts_a_job(self) -> None:
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


class NeverHosted(LegacyWriter):
    def test_a_non_hosted_pool_never_resolves_to_a_hosted_label(self) -> None:
        # Hosted runners are not in the declared set: whatever is dead, a pool not marked hosted
        # picks one of its own Blacksmith members, never ubuntu-* or macos-*.
        pools = legacy_pools()
        every = {label for spec in pools.values() for label in runner_pools.members(spec)}
        value, _ = runner_pools.reconcile({}, pools, dead_now=every, served_now=(), now=NOW)
        for name, spec in pools.items():
            if not spec.get("hosted"):
                self.assertRegex(value[name], runner_pools.EPHEMERAL)
        current, dropped = runner_pools.parse_value(json.dumps({"linux": "ubuntu-24.04"}), pools)
        self.assertNotIn("linux", current)
        self.assertTrue(dropped)

    def test_the_overflow_switch_never_writes_a_hosted_label(self) -> None:
        # The switch that moves the old variables (LINUX_RUNNER, CI_TRUSTED_RUNNER) never points one
        # at GitHub-hosted Ubuntu or macOS, with or without an override asking it to.
        import cloud_overflow_switch as switch
        for overrides in (None, json.dumps({"LINUX_RUNNER": "ubuntu-24.04"}),
                          json.dumps({"MACOS_RUNNER_15": "macos-15"})):
            values, _ = switch.failover_values("/Applications/Xcode_26.6.app", overrides)
            for name, value in values.items():
                with self.subTest(overrides=overrides, variable=name):
                    self.assertNotRegex(str(value), r"^(?:ubuntu|macos|windows)-")


class Schema(LegacyWriter):
    def test_malformed_values_are_repaired_not_crashed_on(self) -> None:
        good, _ = runner_pools.reconcile({}, POOLS, dead_now=(), served_now=(), now=NOW)
        for raw in ('{"_dead":[]}', '{"_dead":{"blacksmith-32vcpu-ubuntu-2404":"2026-10-28T22:00:00"}}',
                    '{"_dead":{"blacksmith-32vcpu-ubuntu-2404":7}}', '{"linux":"ubuntu-24.04"}', '{"linux":3}',
                    '[]', '"x"', 'not json'):
            with self.subTest(raw=raw):
                current, dropped = runner_pools.parse_value(raw, POOLS)
                self.assertTrue(dropped)
                value, _ = runner_pools.reconcile(current, POOLS, dead_now=(), served_now=(), now=NOW)
                self.assertEqual({k: value[k] for k in POOLS}, {k: good[k] for k in POOLS})
                self.assertEqual(value["_dead"], {})

    def test_a_valid_value_round_trips(self) -> None:
        value, _ = runner_pools.reconcile({}, POOLS, dead_now={"blacksmith-6vcpu-macos-26"}, served_now=(), now=NOW)
        current, dropped = runner_pools.parse_value(runner_pools.render(value), POOLS)
        self.assertEqual(dropped, [])
        self.assertEqual(runner_pools.render(current), runner_pools.render(value))

    def test_value_problems(self) -> None:
        value, _ = runner_pools.reconcile({}, POOLS, dead_now=(), served_now=(), now=NOW)
        self.assertEqual(runner_pools.value_problems(value, POOLS), [])
        self.assertTrue(runner_pools.value_problems({**value, "linux": "ubuntu-24.04"}, POOLS))
        missing = dict(value)
        del missing["macos_26"]
        self.assertTrue(runner_pools.value_problems(missing, POOLS))


class Main(LegacyWriter):
    class Api:
        def __init__(self, snapshot):
            self._snapshot = snapshot

        def snapshot(self, *, now):
            return self._snapshot

    class Switch:
        def __init__(self, variables=None):
            self.writes = []
            self.variables = dict(variables or {})

        def get_variable(self, name):
            return self.variables.get(name)

        def set_variable(self, name, value):
            self.writes.append((name, value))
            self.variables[name] = value

    def test_a_stalled_size_flips_linux_once(self) -> None:
        switch = self.Switch({runner_pools.HEALTH_VARIABLE: json.dumps(health({
            "blacksmith-4vcpu-ubuntu-2404": "stalled", "blacksmith-16vcpu-ubuntu-2404": "started"})),
            "LINUX_RUNNER": "blacksmith-4vcpu-ubuntu-2404"})
        with tempfile.TemporaryDirectory() as tmp:
            env = {"RUNNER_POOLS": "", "GITHUB_STEP_SUMMARY": f"{tmp}/summary"}
            self.assertEqual(runner_pools.main([], env, api=self.Api(RECORDED), switch=switch, now=NOW), 0)
        [(name, raw), mirrored] = switch.writes
        self.assertEqual(name, "RUNNER_POOLS")
        self.assertEqual(json.loads(raw)["linux"], "blacksmith-16vcpu-ubuntu-2404")
        # LINUX_RUNNER leaves the stalled size with the pool.
        self.assertEqual(mirrored, ("LINUX_RUNNER", "blacksmith-16vcpu-ubuntu-2404"))

    def test_linux_runner_on_a_size_outside_the_set_follows_the_pool(self) -> None:
        # 2026-10-31: RUNNER_POOLS.linux was live but LINUX_RUNNER still named a size outside the pool
        # (then the stalled 4 vCPU size; since the pool went smallest first, 32 vCPU).
        pools = {"linux": "blacksmith-4vcpu-ubuntu-2404"}
        current, _ = runner_pools.parse_value(json.dumps(pools), legacy_pools())
        value, _ = runner_pools.reconcile(current, legacy_pools(), dead_now=(), served_now=(), now=NOW)
        env = {"RUNNER_POOLS": runner_pools.render(value)}
        switch = self.Switch({"LINUX_RUNNER": "blacksmith-32vcpu-ubuntu-2404"})
        self.assertEqual(runner_pools.main([], env, api=self.Api(None), switch=switch, now=NOW), 0)
        self.assertEqual(switch.writes, [("LINUX_RUNNER", "blacksmith-4vcpu-ubuntu-2404")])

    def test_linux_runner_is_left_to_the_overflow_switch_and_to_a_deliberate_value(self) -> None:
        value = {"linux": "blacksmith-32vcpu-ubuntu-2404"}
        record = '{"changed": {"LINUX_RUNNER": {"was": "blacksmith-32vcpu-ubuntu-2404"}}}'
        self.assertEqual(runner_pools.mirror_writes(value, {"LINUX_RUNNER": "x"}, record=record), [])
        self.assertEqual(runner_pools.mirror_writes(value, {"LINUX_RUNNER": "glaeda-std-xcode-26.6"}, record=None), [])
        self.assertEqual(runner_pools.mirror_writes(value, {"LINUX_RUNNER": None}, record=None),
                         [("LINUX_RUNNER", "blacksmith-32vcpu-ubuntu-2404")])
        self.assertEqual(runner_pools.mirror_writes(value, {"LINUX_RUNNER": "blacksmith-32vcpu-ubuntu-2404"},
                                                    record=None), [])

    def test_unreadable_evidence_keeps_the_dead_marks(self) -> None:
        # Watch run 41279880300 (2026-11-01 06:12-06:23Z): every App-token read returned 403 (the job
        # listing, the janitor snapshot, CI_CLOUD_LABEL_HEALTH), the 32 vCPU mark passed DEAD_TTL with no
        # evidence about it, and RUNNER_POOLS.linux went from 16 back to the stalled 32 vCPU size.
        # Unknown stays unknown: the mark is kept and the pool stays where it was. The sizes come from the
        # declared pool (its first member dead, the pool on its second), whatever order it lists them in.
        marked = runner_pools.iso(NOW - runner_pools.DEAD_TTL - dt.timedelta(minutes=10))
        pools = legacy_pools()
        first, second = runner_pools.members(pools["linux"])[:2]
        held = {name: runner_pools.members(spec)[0] for name, spec in pools.items()}
        held["linux"] = second
        held["_dead"] = {first: marked}
        held["_updated"] = marked

        class Forbidden(self.Switch):
            def get_variable(self, name):
                raise RuntimeError(f"GET /actions/variables/{name} failed (403)")

        class NoSnapshot:
            def snapshot(self, *, now):
                raise RuntimeError("GET artifacts failed (403)")

        switch = Forbidden()
        env = {"RUNNER_POOLS": runner_pools.render(held)}
        self.assertEqual(runner_pools.main([], env, api=NoSnapshot(), switch=switch, now=NOW), 0)
        self.assertEqual(switch.writes, [])
        # The same with health that is only stale (the job's start value from 05:30Z) and no snapshot.
        stale = health({first: "stalled"}, checked=NOW - dt.timedelta(minutes=55))
        switch = self.Switch({runner_pools.HEALTH_VARIABLE: json.dumps(stale), "LINUX_RUNNER": second})
        self.assertEqual(runner_pools.main([], env, api=self.Api(None), switch=switch, now=NOW), 0)
        self.assertEqual(switch.writes, [])
        # A fresh snapshot is no evidence about a Linux size (it lists only macOS labels): still held.
        current, _ = runner_pools.parse_value(env["RUNNER_POOLS"], pools)
        covered = runner_pools.evidence_covers(None, RECORDED, pools, now=NOW)
        self.assertNotIn(first, covered)
        self.assertIn("blacksmith-6vcpu-macos-26", covered)
        value, lines = runner_pools.reconcile(current, pools, dead_now=(), served_now=(), now=NOW, covered=covered)
        self.assertEqual((value["linux"], value["_dead"]), (second, held["_dead"]))
        self.assertTrue(any("kept; no fresh evidence" in line for line in lines))
        # Fresh probe health that lists the dead size lets its expired mark go, as before.
        fresh = health({second: "started", first: "started"})
        covered = runner_pools.evidence_covers(fresh, None, pools, now=NOW)
        value, _ = runner_pools.reconcile(current, pools, dead_now=(), served_now=(), now=NOW, covered=covered)
        self.assertEqual((value["linux"], value["_dead"]), (first, {}))
        # Health that lists only the other size says nothing about the dead one: kept.
        covered = runner_pools.evidence_covers(health({second: "started"}), None, pools, now=NOW)
        value, _ = runner_pools.reconcile(current, pools, dead_now=(), served_now=(), now=NOW, covered=covered)
        self.assertEqual(value["linux"], second)

    def test_an_unreadable_linux_runner_is_not_overwritten(self) -> None:
        class Broken(self.Switch):
            def get_variable(self, name):
                if name == "LINUX_RUNNER":
                    raise RuntimeError("GET failed (502)")
                return super().get_variable(name)
        value, _ = runner_pools.reconcile({}, legacy_pools(), dead_now=(), served_now=(), now=NOW)
        switch = Broken()
        env = {"RUNNER_POOLS": runner_pools.render(value)}
        self.assertEqual(runner_pools.main([], env, api=self.Api(None), switch=switch, now=NOW), 0)
        self.assertEqual(switch.writes, [])

    def test_check_fails_while_linux_runner_is_outside_the_linux_pool(self) -> None:
        value, _ = runner_pools.reconcile({}, legacy_pools(), dead_now=(), served_now=(), now=NOW)
        env = {"RUNNER_POOLS": runner_pools.render(value)}
        self.assertEqual(runner_pools.main(["--check"], dict(env, LINUX_RUNNER="blacksmith-4vcpu-ubuntu-2404")), 0)
        self.assertEqual(runner_pools.main(["--check"], dict(env, LINUX_RUNNER="blacksmith-32vcpu-ubuntu-2404")), 1)
        self.assertEqual(runner_pools.main(["--check"], env), 1)
        self.assertEqual(runner_pools.main(["--check"], dict(env, LINUX_RUNNER="ubuntu-24.04",
                                                             CI_CLOUD_OVERFLOW_SAVED=SWITCHED_LINUX)), 0)
        # A record that left LINUX_RUNNER alone does not excuse it.
        self.assertEqual(runner_pools.main(["--check"], dict(env, LINUX_RUNNER="ubuntu-24.04",
                                                             CI_CLOUD_OVERFLOW_SAVED=MACOS_ONLY_RECORD)), 1)

    def test_a_macos_only_overflow_record_does_not_freeze_linux_runner_on_a_dead_member(self) -> None:
        # 2026-11-01: the record (04:23Z) changed only macOS variables; RUNNER_POOLS marked 32 vCPU dead at
        # 05:30Z and moved linux to 16 vCPU, but LINUX_RUNNER stayed on 32 and its jobs queued there.
        with patch.object(runner_pools, "load_pools", lambda: copy.deepcopy(POOLS)):
            current, _ = runner_pools.parse_value(json.dumps({"linux": "blacksmith-32vcpu-ubuntu-2404"}), POOLS)
            value, _ = runner_pools.reconcile(current, POOLS,
                                              dead_now={"blacksmith-32vcpu-ubuntu-2404"}, served_now=(), now=NOW)
            self.assertEqual(value["linux"], "blacksmith-16vcpu-ubuntu-2404")
            live = {"LINUX_RUNNER": "blacksmith-32vcpu-ubuntu-2404"}
            self.assertEqual(runner_pools.mirror_writes(value, live, record=MACOS_ONLY_RECORD),
                             [("LINUX_RUNNER", "blacksmith-16vcpu-ubuntu-2404")])
            # The switch's own change stays the switch's, and an unreadable record still defers everything.
            self.assertEqual(runner_pools.mirror_writes(value, live, record=SWITCHED_LINUX), [])
            self.assertEqual(runner_pools.mirror_writes(value, live, record="not json"), [])
            self.assertEqual(runner_pools.mirror_writes(value, live, record='{"since": "x"}'), [])
            env = {"RUNNER_POOLS": runner_pools.render(value)}
            switch = self.Switch({"LINUX_RUNNER": "blacksmith-32vcpu-ubuntu-2404",
                                  "CI_CLOUD_OVERFLOW_SAVED": MACOS_ONLY_RECORD})
            self.assertEqual(runner_pools.main([], env, api=self.Api(None), switch=switch, now=NOW), 0)
            self.assertEqual(switch.writes, [("LINUX_RUNNER", "blacksmith-16vcpu-ubuntu-2404")])

    def test_the_repo_variable_check_hands_in_what_the_mirror_check_reads(self) -> None:
        workflow = yaml.safe_load((ROOT / ".github/workflows/ci-repo-variables.yml").read_text())
        steps = [step for job in workflow["jobs"].values() for step in job.get("steps", [])
                 if "runner_pool_reconcile.py" in str(step.get("run", ""))
                 and "--check" in str(step.get("run", ""))]
        self.assertTrue(steps)
        for step in steps:
            for name in (*runner_pools.MIRRORS, runner_pools.OVERFLOW_RECORD):
                self.assertEqual(step["env"].get(name), "${{ vars.%s }}" % name)

    def test_no_switch_token_and_a_correct_linux_runner_is_not_a_failure(self) -> None:
        # Review of #28864: with no token and the variables not handed in, the mirror is unknown, not unset.
        value, _ = runner_pools.reconcile({}, legacy_pools(), dead_now=(), served_now=(), now=NOW)
        env = {"RUNNER_POOLS": runner_pools.render(value)}
        self.assertEqual(runner_pools.main([], env, api=self.Api(None), switch=None, now=NOW), 0)
        env.update(LINUX_RUNNER=value["linux"], CI_CLOUD_OVERFLOW_SAVED="")
        self.assertEqual(runner_pools.main([], env, api=self.Api(None), switch=None, now=NOW), 0)

    def test_the_overflow_watch_hands_in_what_the_mirror_reads(self) -> None:
        workflow = yaml.safe_load((ROOT / ".github/workflows/ci-cloud-overflow-probe.yml").read_text())
        steps = [step for job in workflow["jobs"].values() for step in job.get("steps", [])
                 if "runner_pool_reconcile.py" in str(step.get("run", ""))
                 and "--source-root" in str(step.get("run", ""))
                 and "--probe" not in str(step.get("run", ""))]
        self.assertTrue(steps)
        for step in steps:
            for name in (*runner_pools.MIRRORS, runner_pools.OVERFLOW_RECORD):
                self.assertEqual(step["env"].get(name), "${{ vars.%s }}" % name)

    def test_nothing_changed_writes_nothing(self) -> None:
        switch = self.Switch({"LINUX_RUNNER": "blacksmith-4vcpu-ubuntu-2404"})
        env = {"RUNNER_POOLS": ""}
        runner_pools.main([], env, api=self.Api(RECORDED), switch=switch, now=NOW)
        env["RUNNER_POOLS"] = switch.writes[0][1]
        runner_pools.main([], env, api=self.Api(RECORDED), switch=switch, now=NOW + dt.timedelta(minutes=10))
        self.assertEqual(len(switch.writes), 1)

    def test_a_malformed_variable_is_rewritten(self) -> None:
        switch = self.Switch()
        self.assertEqual(runner_pools.main([], {"RUNNER_POOLS": '{"_dead":[]}'}, api=self.Api(None),
                                           switch=switch, now=NOW), 0)
        self.assertEqual(runner_pools.value_problems(json.loads(switch.writes[0][1]), legacy_pools()), [])

    def test_check_fails_on_an_unset_or_malformed_variable(self) -> None:
        self.assertEqual(runner_pools.main(["--check"], {"RUNNER_POOLS": ""}), 1)
        self.assertEqual(runner_pools.main(["--check"], {"RUNNER_POOLS": '{"_dead":[]}'}), 1)


if __name__ == "__main__":
    unittest.main()


class TruncatedSnapshot(unittest.TestCase):
    def test_a_truncated_snapshot_is_no_snapshot_evidence(self) -> None:
        # A janitor sweep that listed part of the queue (queue_janitor.listing_state()) undercounts every pool.
        stalled = copy.deepcopy(RECORDED)
        stalled["pools"]["blacksmith-6vcpu-macos-26"].update(queued=3, oldest_queued_minutes=30)
        dead, _, _ = runner_pools.label_evidence(None, stalled, now=NOW)
        self.assertEqual(dead, {"blacksmith-6vcpu-macos-26"})
        dead, started, notes = runner_pools.label_evidence(None, dict(stalled, truncated=True), now=NOW)
        self.assertEqual((dead, started), (set(), set()))
        self.assertTrue(any("truncated" in note for note in notes))
