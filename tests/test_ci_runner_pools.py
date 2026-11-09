#!/usr/bin/env python3
"""scripts/ci/runner_pools.py keeps RUNNER_POOLS on a live member of every declared pool."""

from __future__ import annotations

import copy
import datetime as dt
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

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


def health(labels, checked=NOW):
    # Exactly what the overflow switch writes to CI_CLOUD_LABEL_HEALTH (cloud_overflow_switch.label_health()).
    import cloud_overflow_switch as switch
    stalled = [label for label, state in labels.items() if state == "stalled"]
    return switch.label_health(list(labels), stalled, checked=runner_pools.iso(checked),
                               run="https://github.com/x/y/actions/runs/1", minutes=5)


class Declared(unittest.TestCase):
    def test_the_declared_pools_are_valid(self) -> None:
        self.assertEqual(runner_pools.spec_problems(runner_pools.load_pools()), [])

    def test_the_linux_pool_is_the_runner_set(self) -> None:
        # Leo, 2026-10-28: "just pin the set of the shit that isn't hilariously slow".
        # Smallest first: Blacksmith caps vCPUs at once, so the live member is the small size (2026-11-01).
        self.assertEqual(runner_pools.load_pools()["linux"]["members"],
                         ["blacksmith-4vcpu-ubuntu-2404", "blacksmith-16vcpu-ubuntu-2404"])

    def test_every_blacksmith_linux_size_has_its_own_pool(self) -> None:
        # Leo, 2026-10-28: "Where the f***ing are the generalized solution to all these problems that these
        # incessant pins?" A job measured at one size reads that size's pool, so a stalled size moves by declaration.
        pools = runner_pools.load_pools()
        for size, name in ((2, "linux_2"), (4, "linux_4"), (8, "linux_8"), (16, "linux_16"), (32, "linux_32")):
            with self.subTest(pool=name):
                listed = runner_pools.members(pools[name])
                self.assertEqual(listed[0], f"blacksmith-{size}vcpu-ubuntu-2404")
                self.assertGreater(len(listed), 1, f"{name} needs a member to fail over to")

    def test_every_bounded_selector_accepts_every_linux_member(self) -> None:
        # Review of #30340: a member a bounded selector refuses (contains([...], vars.LINUX_RUNNER) && ... || '<4 vCPU>')
        # sends its readers back to the stalled size when the pool steps onto it.
        selector = re.compile(r"contains\(fromJSON\('(\[[^']*\])'\), (?:vars\.LINUX_RUNNER|fromJSON\(vars\.RUNNER_POOLS[^)]*\)\.linux)\)"
                              r" && (?:vars\.LINUX_RUNNER|fromJSON\(vars\.RUNNER_POOLS[^)]*\)\.linux) \|\| '(blacksmith-4vcpu-ubuntu-2404)'")
        members = runner_pools.load_pools()["linux"]["members"]
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
        [step] = [s for s in steps if "runner_pools.py" in str(s.get("run", ""))]
        self.assertEqual(step["env"]["SWITCH_TOKEN"], "${{ steps.switch-token.outputs.token }}")
        self.assertEqual(step["env"]["RUNNER_POOLS"], "${{ vars.RUNNER_POOLS }}")
        self.assertIn("always()", str(step.get("if")))
        names = [s.get("name") for s in steps]
        self.assertLess(names.index(step["name"]), names.index("End this run's stuck probe"))

    def test_the_reconciler_reads_as_cmux_bot_not_the_shared_workflow_token(self) -> None:
        # Its GH_TOKEN only reads (queue sample, pool snapshot artifact): cmux-bot's read-only token, minted
        # earlier in the same job, keeps those reads off the repository GITHUB_TOKEN pool every workflow shares.
        workflow = yaml.safe_load((ROOT / ".github/workflows/ci-cloud-overflow-probe.yml").read_text())
        steps = workflow["jobs"]["watch"]["steps"]
        [step] = [s for s in steps if "runner_pools.py" in str(s.get("run", ""))]
        [mint] = [s for s in steps if s.get("id") == "cmux-bot-token"]
        self.assertEqual(mint["with"]["permission-actions"], "read")
        self.assertEqual(step["env"]["GH_TOKEN"], "${{ steps.cmux-bot-token.outputs.token || github.token }}")
        self.assertNotIn("GLAEDA_ROUTE", step["env"]["GH_TOKEN"])
        names = [s.get("name") for s in steps]
        self.assertLess(names.index(mint["name"]), names.index(step["name"]))

    def test_the_watch_runs_the_pinned_linux_pool_spill_with_main_as_fallback(self) -> None:
        # cmux#31884: the queue-aware spill runs from a reviewed feat-cmux-next commit beside main's policy.
        workflow = yaml.safe_load((ROOT / ".github/workflows/ci-cloud-overflow-probe.yml").read_text())
        steps = workflow["jobs"]["watch"]["steps"]
        [checkout] = [s for s in steps if s.get("id") == "spill-tooling"]
        self.assertRegex(checkout["with"]["ref"], r"^[0-9a-f]{40}$")
        self.assertEqual(checkout["with"]["persist-credentials"], False)
        self.assertEqual(set(checkout["with"]["sparse-checkout"].split()),
                         {"scripts/ci/linux_pool_spill.py", "scripts/ci/runner_pool_reconcile.py"})
        self.assertTrue(checkout.get("continue-on-error"))
        [step] = [s for s in steps if "runner_pools.py" in str(s.get("run", ""))]
        self.assertIn('--policy-root "$GITHUB_WORKSPACE"', step["run"])
        # Without the checkout, or when the spill fails, main's policy still runs alone.
        self.assertEqual(step["run"].count("python3 scripts/ci/runner_pools.py"), 2)
        names = [s.get("name") for s in steps]
        self.assertLess(names.index(checkout["name"]), names.index(step["name"]))


    def test_hosted_light_rescue_runs_without_the_overflow_probe(self) -> None:
        # A queued probe must not hold the recovery that moves other queued light jobs.
        path = ROOT / ".github/workflows/ci-hosted-light-rescue.yml"
        self.assertTrue(path.is_file(), "hosted light rescue needs an independent scheduler")
        workflow = yaml.safe_load(path.read_text())
        events = workflow.get("on", workflow.get(True))
        self.assertEqual(events["schedule"], [{"cron": "*/5 * * * *"}])
        self.assertNotEqual(workflow["concurrency"]["group"], "ci-cloud-overflow-probe")
        self.assertFalse(workflow["concurrency"]["cancel-in-progress"])
        rescue = workflow["jobs"]["rescue"]
        self.assertNotIn("needs", rescue)
        self.assertEqual(rescue["permissions"], {"actions": "write", "contents": "read"})
        self.assertNotIn("secrets.", path.read_text())
        self.assertNotIn("CI_LIGHT_LANE_RUNNER", rescue["runs-on"])
        self.assertNotIn("CI_SIDE_LANE_RUNNER", rescue["runs-on"])
        self.assertIn("vars.CI_TRUSTED_RUNNER", rescue["runs-on"])
        self.assertIn("ephemeral-required", path.read_text())
        self.assertEqual(rescue["steps"][0]["with"]["ref"], "main")
        self.assertTrue((ROOT / "scripts/ci/hosted_light_rescue.py").is_file())
        old = yaml.safe_load((ROOT / ".github/workflows/ci-cloud-overflow-probe.yml").read_text())
        self.assertNotIn("hosted_light_rescue.py", str(old["jobs"]))

    def test_the_independent_schedule_only_wakes_the_single_sweeper(self) -> None:
        workflow = yaml.safe_load((ROOT / ".github/workflows/ci-hosted-light-rescue.yml").read_text())
        steps = workflow["jobs"]["rescue"]["steps"]
        [step] = [s for s in steps if "hosted_light_rescue.py" in str(s.get("run", ""))]
        self.assertIn("python3 scripts/ci/hosted_light_rescue.py", step["run"])
        self.assertEqual(step["env"]["GH_TOKEN"], "${{ github.token }}")
        self.assertIn("--wake-sweeper", step["run"])
        self.assertNotIn("--runners", step["run"])
        self.assertNotIn(".rescue-workflows", str(steps))

    def test_a_failed_optional_policy_checkout_does_not_stop_the_primary_sweep(self) -> None:
        doc = yaml.safe_load((ROOT / ".github/workflows/ci-owned-pool-rescue.yml").read_text())
        steps = doc["jobs"]["rescue"]["steps"]
        [policy] = [s for s in steps if s.get("with", {}).get("path") == ".rescue-workflows"]
        # Actions skips subsequent ordinary steps after a fatal action failure. This optional
        # checkout must clear that failure so the existing owned-pool sweeper can still start.
        self.assertTrue(policy.get("continue-on-error"))
        self.assertLessEqual(policy.get("timeout-minutes", 360), 2)
        [watch] = [s for s in steps if "owned_pool_rescue.py" in str(s.get("run", ""))]
        self.assertLess(steps.index(policy), steps.index(watch))

    def test_the_minute_sweeper_isolates_light_rescue_from_the_routing_app(self) -> None:
        doc = yaml.safe_load((ROOT / ".github/workflows/ci-owned-pool-rescue.yml").read_text())
        [step] = [s for s in doc["jobs"]["rescue"]["steps"] if "owned_pool_rescue.py" in str(s.get("run", ""))]
        # cmux-bot first (its own installation pool), the workflow token as fallback; never the routing App.
        self.assertEqual(step["env"]["HOSTED_LIGHT_TOKEN"], "${{ steps.cmux-bot-token.outputs.token || github.token }}")
        self.assertEqual(step["env"]["HOSTED_LIGHT_FALLBACK_TOKEN"], "${{ github.token }}")
        self.assertNotIn("GLAEDA_ROUTE", str(step["env"]["HOSTED_LIGHT_TOKEN"]))
        self.assertEqual(step["env"]["HOSTED_LIGHT_DISABLED"], "${{ vars.CI_HOSTED_LIGHT_RESCUE_DISABLED }}")
        self.assertEqual(step["env"]["HOSTED_LIGHT_POLICY"], ".rescue-workflows/.github")


class Evidence(unittest.TestCase):
    def test_it_reads_the_variable_the_switch_writes(self) -> None:
        import cloud_overflow_switch as switch
        self.assertEqual(runner_pools.HEALTH_VARIABLE, switch.HEALTH_VARIABLE)
        # The switch probes every member of the linux pool, so each one has health of its own.
        self.assertEqual(set(switch.PROBE_LABELS), set(runner_pools.load_pools()["linux"]["members"]))

    def test_the_recorded_snapshot_marks_nothing(self) -> None:
        dead, started, _ = runner_pools.label_evidence(None, RECORDED, now=NOW)
        self.assertEqual((dead, started), (set(), set()))

    def test_a_stalled_blacksmith_mac_in_the_snapshot_is_dead(self) -> None:
        # simple_pool_picker.blacksmith_stalled(): a queued job waited 10 minutes, nothing runs there, and the
        # janitor's label_started shows no start since that job began to wait.
        snapshot = copy.deepcopy(RECORDED)
        snapshot["pools"]["blacksmith-6vcpu-macos-26"].update(queued=3, running=0, oldest_queued_minutes=9)
        snapshot["label_started"] = {"blacksmith-6vcpu-macos-26": runner_pools.iso(SNAPSHOT_AT - dt.timedelta(minutes=40))}
        dead, _, _ = runner_pools.label_evidence(None, snapshot, now=NOW)
        self.assertEqual(dead, {"blacksmith-6vcpu-macos-26"})
        # Owned labels in the snapshot are never pool members and are not read.
        snapshot["pools"]["glaeda-std-xcode-26.6"].update(queued=9, oldest_queued_minutes=60)
        snapshot["starved"] = [{"label": "glaeda-gui-std-xcode-26.6+glaeda-std-xcode-26.6", "queued": 1}]
        dead, _, _ = runner_pools.label_evidence(None, snapshot, now=NOW)
        self.assertEqual(dead, {"blacksmith-6vcpu-macos-26"})

    def test_a_busy_blacksmith_mac_that_starts_jobs_is_not_dead(self) -> None:
        # 2026-11-08: blacksmith-6vcpu-macos-15 started four jobs of run 42503576472 at 17:28-17:31Z, one
        # still running, yet RUNNER_POOLS marked it dead at 17:34:13Z: other jobs had queued there over 10
        # minutes. A long queue on a label that starts jobs is load, not death; only a label that runs
        # nothing and started nothing while its oldest job waited is dead.
        stalled = copy.deepcopy(RECORDED)
        stalled["pools"]["blacksmith-6vcpu-macos-26"].update(queued=6, running=0, oldest_queued_minutes=25)
        stalled["label_started"] = {}
        # A start it shows is evidence it serves: that clears a mark the old rule wrote, at once.
        # No label_started map is no evidence either way.
        label = {"blacksmith-6vcpu-macos-26"}
        for name, change, served in [
            ("a job runs there", {"running": 1}, label),
            ("a job started after the oldest began to wait",
             {"label_started": runner_pools.iso(SNAPSHOT_AT - dt.timedelta(minutes=3))}, label),
            ("no start evidence in the snapshot", {"no_label_started": True}, set()),
        ]:
            with self.subTest(name):
                snapshot = copy.deepcopy(stalled)
                if "running" in change:
                    snapshot["pools"]["blacksmith-6vcpu-macos-26"]["running"] = change["running"]
                if "label_started" in change:
                    snapshot["label_started"] = {"blacksmith-6vcpu-macos-26": change["label_started"]}
                if change.get("no_label_started"):
                    del snapshot["label_started"]
                dead, started, _ = runner_pools.label_evidence(None, snapshot, now=NOW)
                self.assertEqual(dead, set())
                self.assertEqual(started, served)
        # The control: nothing runs, and the last start is older than the oldest wait.
        dead, _, _ = runner_pools.label_evidence(None, stalled, now=NOW)
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
        for name, spec in runner_pools.load_pools().items():
            self.assertEqual(value[name], spec["members"][0])

    def test_an_undated_stale_or_future_snapshot_decides_nothing(self) -> None:
        stalled = copy.deepcopy(RECORDED)
        stalled["pools"]["blacksmith-6vcpu-macos-26"].update(queued=3, running=0, oldest_queued_minutes=30)
        stalled["label_started"] = {}
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


class NeverHosted(unittest.TestCase):
    def test_a_non_hosted_pool_never_resolves_to_a_hosted_label(self) -> None:
        # Hosted runners are not in the declared set: whatever is dead, a pool not marked hosted
        # picks one of its own Blacksmith members, never ubuntu-* or macos-*.
        pools = runner_pools.load_pools()
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


class Schema(unittest.TestCase):
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


class Main(unittest.TestCase):
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
        current, _ = runner_pools.parse_value(json.dumps(pools), runner_pools.load_pools())
        value, _ = runner_pools.reconcile(current, runner_pools.load_pools(), dead_now=(), served_now=(), now=NOW)
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
        pools = runner_pools.load_pools()
        first, second = runner_pools.members(pools["linux"])[:2]
        # Every pool on its first member that is not the dead one (linux_4 lists the same 4 vCPU size first).
        held = {name: next(m for m in runner_pools.members(spec) if m != first) for name, spec in pools.items()}
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
        value, _ = runner_pools.reconcile({}, runner_pools.load_pools(), dead_now=(), served_now=(), now=NOW)
        switch = Broken()
        env = {"RUNNER_POOLS": runner_pools.render(value)}
        self.assertEqual(runner_pools.main([], env, api=self.Api(None), switch=switch, now=NOW), 0)
        self.assertEqual(switch.writes, [])

    def test_check_fails_while_linux_runner_is_outside_the_linux_pool(self) -> None:
        value, _ = runner_pools.reconcile({}, runner_pools.load_pools(), dead_now=(), served_now=(), now=NOW)
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
        # The declared linux pool is now 4 then 16 vCPU (32 vCPU left it on 2026-11-01), so the dead member is 4.
        current, _ = runner_pools.parse_value(json.dumps({"linux": "blacksmith-4vcpu-ubuntu-2404"}),
                                              runner_pools.load_pools())
        value, _ = runner_pools.reconcile(current, runner_pools.load_pools(),
                                          dead_now={"blacksmith-4vcpu-ubuntu-2404"}, served_now=(), now=NOW)
        self.assertEqual(value["linux"], "blacksmith-16vcpu-ubuntu-2404")
        live = {"LINUX_RUNNER": "blacksmith-4vcpu-ubuntu-2404"}
        self.assertEqual(runner_pools.mirror_writes(value, live, record=MACOS_ONLY_RECORD),
                         [("LINUX_RUNNER", "blacksmith-16vcpu-ubuntu-2404")])
        # The switch's own change stays the switch's, and an unreadable record still defers everything.
        self.assertEqual(runner_pools.mirror_writes(value, live, record=SWITCHED_LINUX), [])
        self.assertEqual(runner_pools.mirror_writes(value, live, record="not json"), [])
        self.assertEqual(runner_pools.mirror_writes(value, live, record='{"since": "x"}'), [])
        env = {"RUNNER_POOLS": runner_pools.render(value)}
        switch = self.Switch({"LINUX_RUNNER": "blacksmith-4vcpu-ubuntu-2404",
                              "CI_CLOUD_OVERFLOW_SAVED": MACOS_ONLY_RECORD})
        self.assertEqual(runner_pools.main([], env, api=self.Api(None), switch=switch, now=NOW), 0)
        self.assertEqual(switch.writes, [("LINUX_RUNNER", "blacksmith-16vcpu-ubuntu-2404")])

    def test_the_repo_variable_check_hands_in_what_the_mirror_check_reads(self) -> None:
        workflow = yaml.safe_load((ROOT / ".github/workflows/ci-repo-variables.yml").read_text())
        steps = [step for job in workflow["jobs"].values() for step in job.get("steps", [])
                 if "runner_pools.py --check" in str(step.get("run", ""))]
        self.assertTrue(steps)
        for step in steps:
            for name in (*runner_pools.MIRRORS, runner_pools.OVERFLOW_RECORD):
                self.assertEqual(step["env"].get(name), "${{ vars.%s }}" % name)

    def test_runner_pool_check_defers_once_for_a_new_declaration(self) -> None:
        workflow = yaml.safe_load((ROOT / ".github/workflows/ci-repo-variables.yml").read_text())
        steps = [step for job in workflow["jobs"].values() for step in job.get("steps", [])]
        declaration = next(step for step in steps if step.get("id") == "declaration")
        check = next(step for step in steps if "runner_pools.py --check" in str(step.get("run", "")))
        self.assertIn("github.event_name == 'push'", declaration["if"])
        self.assertIn("steps.declaration.outputs.pending != 'true'", check["if"])
        # Review of #30627: a depth-1 clone lacks event.before, so the diff must have it or call it pending.
        checkout = next(step for step in steps if step.get("name") == "Checkout")
        self.assertEqual(checkout["with"].get("fetch-depth"), 2)
        self.assertIn("BEFORE", declaration["env"])
        self.assertIn("SHA", declaration["env"])
        self.assertIn("check_runner_pool_declaration.sh", declaration["run"])
        declaration_script = (ROOT / "scripts/ci/check_runner_pool_declaration.sh").read_text()
        self.assertIn(".github/runners.json", declaration_script)

    def test_runner_pool_declaration_diff_failure_fails_closed(self) -> None:
        script = ROOT / "scripts/ci/check_runner_pool_declaration.sh"
        with tempfile.TemporaryDirectory() as tmp:
            fake_git = Path(tmp) / "git"
            fake_git.write_text("""#!/bin/sh
if [ "$1" = diff ]; then
  exit 128
fi
exit 0
""", encoding="utf-8")
            fake_git.chmod(0o755)
            output = Path(tmp) / "github-output"
            env = dict(os.environ, PATH=f"{tmp}:{os.environ['PATH']}", BEFORE="before", SHA="after",
                       GITHUB_OUTPUT=str(output))
            result = subprocess.run(["bash", str(script)], env=env, text=True,
                                    capture_output=True, check=False)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(output.exists())
            self.assertIn("git diff exited 128", result.stderr)

    def test_no_switch_token_and_a_correct_linux_runner_is_not_a_failure(self) -> None:
        # Review of #28864: with no token and the variables not handed in, the mirror is unknown, not unset.
        value, _ = runner_pools.reconcile({}, runner_pools.load_pools(), dead_now=(), served_now=(), now=NOW)
        env = {"RUNNER_POOLS": runner_pools.render(value)}
        self.assertEqual(runner_pools.main([], env, api=self.Api(None), switch=None, now=NOW), 0)
        env.update(LINUX_RUNNER=value["linux"], CI_CLOUD_OVERFLOW_SAVED="")
        self.assertEqual(runner_pools.main([], env, api=self.Api(None), switch=None, now=NOW), 0)

    def test_the_overflow_watch_hands_in_what_the_mirror_reads(self) -> None:
        workflow = yaml.safe_load((ROOT / ".github/workflows/ci-cloud-overflow-probe.yml").read_text())
        steps = [step for job in workflow["jobs"].values() for step in job.get("steps", [])
                 if "python3 scripts/ci/runner_pools.py" in str(step.get("run", ""))]
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
        self.assertEqual(runner_pools.value_problems(json.loads(switch.writes[0][1]), runner_pools.load_pools()), [])

    def test_check_fails_on_an_unset_or_malformed_variable(self) -> None:
        self.assertEqual(runner_pools.main(["--check"], {"RUNNER_POOLS": ""}), 1)
        self.assertEqual(runner_pools.main(["--check"], {"RUNNER_POOLS": '{"_dead":[]}'}), 1)


if __name__ == "__main__":
    unittest.main()


class TruncatedSnapshot(unittest.TestCase):
    def test_a_truncated_snapshot_is_no_snapshot_evidence(self) -> None:
        # A janitor sweep that listed part of the queue (queue_janitor.listing_state()) undercounts every pool.
        stalled = copy.deepcopy(RECORDED)
        stalled["pools"]["blacksmith-6vcpu-macos-26"].update(queued=3, running=0, oldest_queued_minutes=30)
        stalled["label_started"] = {}
        dead, _, _ = runner_pools.label_evidence(None, stalled, now=NOW)
        self.assertEqual(dead, {"blacksmith-6vcpu-macos-26"})
        dead, started, notes = runner_pools.label_evidence(None, dict(stalled, truncated=True), now=NOW)
        self.assertEqual((dead, started), (set(), set()))
        self.assertTrue(any("truncated" in note for note in notes))
